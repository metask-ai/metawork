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
    const effective_signal = effectiveTerminationSignal(result);
    if (result.failure == .abi_status) return .{
        .phase = .failed,
        .outcome = .failed,
        .cause = if (effective_signal) |signal|
            causeForSignal(signal)
        else if (result.abi_status) |status|
            switch (status) {
                .stale_catalog => .stale_catalog,
                .skill_not_found => .skill_not_found,
                .invalid_skill_arguments => .invalid_skill_arguments,
                .skill_policy_violation => .skill_policy_violation,
                .skill_unavailable => .skill_unavailable,
                .resource_limit, .checkpoint_budget_required => .resource_limit,
                .image_input_unsupported, .image_input_capability_unknown => .image_input_unsupported,
                else => null,
            }
        else
            null,
    };
    if (result.stop_reason) |reason| return switch (reason) {
        .end_turn => .{ .phase = .completed, .outcome = .completed, .cause = null },
        .max_turns => .{ .phase = .stopped, .outcome = .stopped, .cause = .resource_limit },
        .tool_loop => .{ .phase = .stopped, .outcome = .stopped, .cause = .tool_failure },
        .aborted => decisionForSignal(result.termination_signal),
        .tool_error => .{
            .phase = .failed,
            .outcome = .failed,
            .cause = if (effective_signal) |signal|
                causeForSignal(signal)
            else
                .tool_failure,
        },
        .api_error => .{
            .phase = .failed,
            .outcome = .failed,
            .cause = if (effective_signal) |signal|
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
    if (result.termination_signal != null and !result.coreWasInvoked())
        return decisionForSignal(result.termination_signal);
    return .{
        .phase = .failed,
        .outcome = .dependency_contract_failure,
        .cause = .dependency_contract_failure,
    };
}

fn effectiveTerminationSignal(result: *const agent.TerminalResult) ?agent.TerminationSignal {
    if (result.first_host_failure) |failure| return failure.asSignal();
    if (result.controlled_callback_close) |interruption|
        return .{ .interrupted = interruption };
    return switch (result.terminationEffect()) {
        .prevented_core_call, .aborted => result.termination_signal,
        .not_requested, .controlled_close, .not_aborted, .unknown => null,
    };
}

pub const RunGuidance = enum {
    none,
    account_settings,
    model_settings,
    review_context,
    revise_instruction,
    wait,
    prepare_retry,
    review_changes,
    review_permissions,
    review_image_input,
};

pub const RunFeedback = struct { guidance: RunGuidance, offer_input_preparation: bool };

/// Advice never grants execution, login, payment, or model mutation authority.
pub fn runFeedback(
    outcome: task_state.RunOutcome,
    cause: ?task_state.RunCause,
    detail: ?*const task_state.RunModelError,
) RunFeedback {
    const guidance: RunGuidance = switch (outcome) {
        .completed, .dependency_contract_failure => .none,
        .cancelled => if (cause == .timeout) .prepare_retry else .none,
        .stopped => if (cause) |reason| switch (reason) {
            .resource_limit => .revise_instruction,
            .tool_failure => .review_changes,
            .permission_required => .review_permissions,
            else => .none,
        } else .none,
        .interrupted => .prepare_retry,
        .failed => if (cause) |reason| switch (reason) {
            .provider_failure => if (detail) |observed| providerGuidance(observed) else .prepare_retry,
            .agent_failure => .prepare_retry,
            .tool_failure => .review_changes,
            .image_input_unsupported => .review_image_input,
            else => .none,
        } else .none,
    };
    return .{
        .guidance = guidance,
        .offer_input_preparation = switch (outcome) {
            .completed => false,
            .cancelled => cause == .timeout,
            .stopped => cause == .resource_limit or cause == .tool_failure,
            .interrupted, .failed, .dependency_contract_failure => true,
        },
    };
}

fn providerGuidance(detail: *const task_state.RunModelError) RunGuidance {
    return switch (detail.detail.category) {
        .authentication, .payment_required => if (detail.source == .metask) .account_settings else .model_settings,
        .permission, .not_found, .invalid_request => .model_settings,
        .context_window => .review_context,
        .output_limit => .revise_instruction,
        .rate_limited, .overloaded => .wait,
        .server_error, .timeout, .connection, .stream_interrupted => .prepare_retry,
        .unknown => .model_settings,
    };
}

test "model recovery advice respects exact source and primary cause without granting replay authority" {
    var detail: task_state.RunModelError = .{ .detail = try agent.ModelError.init(.{
        .run_id = 1,
        .category = .authentication,
        .message = "provider failure",
        .retry = .retryable,
        .attempts = 1,
    }) };
    inline for (.{ agent.ModelError.Category.authentication, .payment_required }) |category| {
        detail.detail.category = category;
        detail.source = .metask;
        try std.testing.expectEqual(.account_settings, runFeedback(.failed, .provider_failure, &detail).guidance);
        detail.source = .custom_provider;
        try std.testing.expectEqual(.model_settings, runFeedback(.failed, .provider_failure, &detail).guidance);
        detail.source = null;
        try std.testing.expectEqual(.model_settings, runFeedback(.failed, .provider_failure, &detail).guidance);
    }
    detail.source = .metask;
    try std.testing.expectEqual(.none, runFeedback(.dependency_contract_failure, .dependency_contract_failure, &detail).guidance);
    try std.testing.expectEqual(.none, runFeedback(.failed, .event_pipeline_failure, &detail).guidance);
    detail.detail.category = .context_window;
    try std.testing.expectEqual(.review_context, runFeedback(.failed, .provider_failure, &detail).guidance);
    for ([_]struct { category: agent.ModelError.Category, guidance: RunGuidance }{
        .{ .category = .permission, .guidance = .model_settings },
        .{ .category = .not_found, .guidance = .model_settings },
        .{ .category = .invalid_request, .guidance = .model_settings },
        .{ .category = .unknown, .guidance = .model_settings },
        .{ .category = .output_limit, .guidance = .revise_instruction },
        .{ .category = .rate_limited, .guidance = .wait },
        .{ .category = .overloaded, .guidance = .wait },
        .{ .category = .server_error, .guidance = .prepare_retry },
        .{ .category = .timeout, .guidance = .prepare_retry },
        .{ .category = .connection, .guidance = .prepare_retry },
        .{ .category = .stream_interrupted, .guidance = .prepare_retry },
    }) |case| {
        detail.detail.category = case.category;
        const feedback = runFeedback(.failed, .provider_failure, &detail);
        try std.testing.expectEqual(case.guidance, feedback.guidance);
        try std.testing.expect(feedback.offer_input_preparation);
    }
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
        .credential_update_failure,
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
            .event_too_large => .event_payload_too_large,
            .capacity => .queue_capacity_failure,
            .invalid_event, .allocation, .consumer_rejected => .event_pipeline_failure,
        },
        .event_consumer_notification_failure => .event_pipeline_failure,
        .credential_update_failure => |failure| switch (failure) {
            .rejected => .agent_failure,
            .resource_limit => .resource_limit,
            .dependency_contract => .dependency_contract_failure,
        },
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
    // A read-only Task cannot record acknowledgement, so it never reminds.
    if (task.durable.archived or task.read_only_history != null) return null;
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

pub const NavigationSignal = enum { attention, running, failed, interrupted };

pub fn navigationSignal(task: *const task_state.Task) ?NavigationSignal {
    if (currentRunPhase(task)) |phase| return switch (phase) {
        .waiting_ui => if (task.permissionReviewPhase() == .reviewing) .running else .attention,
        .queued, .running, .stopping => .running,
        else => unreachable,
    };
    switch (task.runtime.active_operation) {
        .compact, .restore => return .running,
        .none, .run => {},
    }
    if (task.deletion == .failed) return .failed;
    const run = latestTerminalRun(task.durable.runs) orelse return null;
    return switch (task_state.productTerminalFacts(run).?.outcome) {
        .failed, .dependency_contract_failure => .failed,
        .interrupted => .interrupted,
        .completed, .stopped, .cancelled => null,
    };
}

pub fn hasActiveOperation(task: *const task_state.Task) bool {
    if (task.approval_change != null) return true;
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

pub fn uiRequestHistoryHighWater(task: *const task_state.Task) u64 {
    var latest: u64 = 0;
    for (task.durable.ui_history) |entry| {
        const record = entry orelse continue;
        latest = @max(latest, record.request_id);
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
        // Like a compact anchor, an approval anchor is not tied to the
        // mutable Task model. Restore verifies the recorded model in Core.
        .approval => |revision| revision <= task.durable.approval_revision,
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

    terminal.stop_reason = .max_turns;
    try std.testing.expectEqual(
        TerminalDecision{ .phase = .stopped, .outcome = .stopped, .cause = .resource_limit },
        classifyAgentTerminal(&terminal),
    );
    terminal.stop_reason = .tool_loop;
    try std.testing.expectEqual(
        TerminalDecision{ .phase = .stopped, .outcome = .stopped, .cause = .tool_failure },
        classifyAgentTerminal(&terminal),
    );
    terminal.stop_reason = .end_turn;

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
    terminal.termination_signal = .{ .event_pump_failure = .event_too_large };
    terminal.first_host_failure = .{ .event_pump_failure = .event_too_large };
    try std.testing.expectEqual(
        TerminalDecision{ .phase = .failed, .outcome = .failed, .cause = .event_payload_too_large },
        classifyAgentTerminal(&terminal),
    );
    terminal.termination_signal = .{ .event_pump_failure = .capacity };
    terminal.first_host_failure = .{ .event_pump_failure = .capacity };
    try std.testing.expectEqual(
        TerminalDecision{ .phase = .failed, .outcome = .failed, .cause = .queue_capacity_failure },
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
    terminal.first_host_failure = null;

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
    terminal.first_host_failure = .{ .callback_failure = .ui };
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
    terminal.first_host_failure = null;
    terminal.abi_status = .ok;
    terminal.raw_status_code = @intFromEnum(agent.Status.ok);
    terminal.stop_reason = .api_error;
    terminal.raw_stop_reason_code = @intFromEnum(agent.StopReason.api_error);
    terminal.termination_signal = null;
    try std.testing.expectEqual(
        TerminalDecision{ .phase = .failed, .outcome = .failed, .cause = .provider_failure },
        classifyAgentTerminal(&terminal),
    );

    terminal.termination_signal = .{ .interrupted = .timeout };
    try std.testing.expectEqual(
        TerminalDecision{ .phase = .failed, .outcome = .failed, .cause = .provider_failure },
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

test "Host failure and controlled close stay attributable after an earlier Stop" {
    var terminal = agent.TerminalResult{
        .allocator = std.testing.allocator,
        .diagnostic_storage = &.{},
        .diagnostic_len = 0,
        .diagnostic_truncated = false,
        .abi_status = .callback_failed,
        .raw_status_code = @intFromEnum(agent.Status.callback_failed),
        .stop_reason = null,
        .raw_stop_reason_code = null,
        .abort_status = .too_late,
        .raw_abort_status_code = @intFromEnum(agent.Status.too_late),
        .termination_signal = .{ .interrupted = .user_cancel },
        .failure = .abi_status,
        .session_disposition_at_completion = .poisoned,
        .first_host_failure = .{ .event_pump_failure = .allocation },
    };
    try std.testing.expectEqual(@as(?task_state.RunCause, .event_pipeline_failure), classifyAgentTerminal(&terminal).cause);
    terminal.first_host_failure = null;
    terminal.controlled_callback_close = .session_close;
    try std.testing.expectEqual(@as(?task_state.RunCause, .session_close), classifyAgentTerminal(&terminal).cause);
    terminal.controlled_callback_close = null;
    terminal.abi_status = .ok;
    terminal.raw_status_code = @intFromEnum(agent.Status.ok);
    terminal.stop_reason = .api_error;
    terminal.failure = null;
    try std.testing.expectEqual(@as(?task_state.RunCause, .provider_failure), classifyAgentTerminal(&terminal).cause);
    terminal.first_host_failure = .{ .credential_update_failure = .rejected };
    try std.testing.expectEqual(@as(?task_state.RunCause, .agent_failure), classifyAgentTerminal(&terminal).cause);
    terminal.first_host_failure = .{ .credential_update_failure = .resource_limit };
    try std.testing.expectEqual(@as(?task_state.RunCause, .resource_limit), classifyAgentTerminal(&terminal).cause);
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
            .exclude_on_product_terminal = false,
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
            .exclude_on_product_terminal = false,
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

test "approval checkpoint survives a later Task model change but keeps revision and frontier exact" {
    var runs = [_]?task_state.RunRecord{
        terminalRun(1, .covered),
        terminalRun(2, .excluded),
    };
    runs[1].?.execution_model = @constCast("next-model");
    var compacts: [0]?task_state.CompactRecord = .{};
    var ui_history: [0]?task_state.UiRecord = .{};
    var task = task_state.Task{
        .durable = .{
            .id = 3,
            .recent_order = 1,
            .execution_generation = 1,
            .execution_protocol = .anthropic_messages,
            .execution_model = @constCast("next-model"),
            .permission_profile = .approval_required,
            .permission_interaction = .interactive,
            .approval_revision = 2,
            .workspace_id = 2,
            .workspace_root = @constCast("root"),
            .title = @constCast("title"),
            .runs = &runs,
            .compacts = &compacts,
            .ui_history = &ui_history,
        },
        .runtime = .{},
    };
    // A rebind or approval export anchors this checkpoint to `model`; the
    // interrupted next Run was admitted with a newly selected model.
    var record: checkpoint_record.Record = .{
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
        .anchor = .{ .terminal = .{ .approval = 2 }, .binding_epoch = 1 },
    };
    try std.testing.expect(checkpointMatchesCurrentHistory(&task, record));

    record.anchor.terminal = .{ .approval = 3 };
    try std.testing.expect(!checkpointMatchesCurrentHistory(&task, record));
    record.anchor.terminal = .{ .approval = 2 };
    task.durable.runs[1].?.coverage = .covered;
    try std.testing.expect(!checkpointMatchesCurrentHistory(&task, record));
    task.durable.runs[1].?.coverage = .pending;
    try std.testing.expect(!checkpointMatchesCurrentHistory(&task, record));
}

test "UI request history high-water follows the bounded ring contents" {
    var runs: [0]?task_state.RunRecord = .{};
    var compacts: [0]?task_state.CompactRecord = .{};
    var ui_history = [_]?task_state.UiRecord{
        .{ .request_id = 8, .run_id = 1, .kind = .permission, .state = .allowed_once },
        .{ .request_id = 11, .run_id = 3, .kind = .permission, .state = .cancelled },
        .{ .request_id = 9, .run_id = 2, .kind = .permission, .state = .denied },
    };
    const task = task_state.Task{
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
            .ui_history_count = ui_history.len,
            .ui_history_next = 1,
        },
        .runtime = .{},
    };

    try std.testing.expectEqual(@as(u64, 11), uiRequestHistoryHighWater(&task));
}
