//! Task-owned executor payloads and worker callbacks.
//! Jobs borrow only stable records, scoped Agent Session access, narrow effect
//! capabilities, and the specific atomics that keep their records alive. They
//! never retain a composition aggregate or Task runtime pointer.

const std = @import("std");
const agent = @import("metawork_agent");
const checkpoint_record = @import("product_task_checkpoint_record");
const checkpoint_store = @import("product_task_checkpoint_store");
const execution_binding = @import("product_task_execution_binding");
const agent_session = @import("product_task_agent_session");
const state = @import("product_task_state");
const policy = @import("product_task_policy");
const agent_protocol = @import("product_agent_protocol_adapter");

pub const Notifier = struct {
    context: ?*anyopaque = null,
    notify_fn: *const fn (?*anyopaque) bool,

    pub fn notify(self: Notifier) void {
        _ = self.notify_fn(self.context);
    }
};

pub const CompletionFactory = struct {
    context: ?*anyopaque = null,
    create_fn: ?*const fn (
        ?*anyopaque,
        std.mem.Allocator,
        agent.CompletionConfig,
    ) anyerror!*agent.Completion = null,

    fn create(
        self: CompletionFactory,
        allocator: std.mem.Allocator,
        config: agent.CompletionConfig,
    ) anyerror!*agent.Completion {
        if (self.create_fn) |create_fn|
            return create_fn(self.context, allocator, config);
        return error.CompletionUnavailable;
    }
};

pub const Projection = struct {
    len: usize,
    truncated: bool,
    redacted: bool,
};

/// Projects Task-owned text into a fixed destination while replacing any
/// credential match with a short marker. Worker jobs and the live aggregate
/// share this implementation so credential handling cannot drift across the
/// executor boundary.
pub fn projectSanitized(
    destination: []u8,
    value: []const u8,
    secret: []const u8,
) Projection {
    var read: usize = 0;
    var write: usize = 0;
    var redacted = false;
    while (read < value.len) {
        if (credentialEndAtCodepoint(value, read, secret)) |redaction_end| {
            const marker_len = @min(redaction_end - read, 3);
            if (marker_len > destination.len - write) break;
            @memset(destination[write..][0..marker_len], '*');
            write += marker_len;
            read = redaction_end;
            redacted = true;
            continue;
        }
        const sequence_len = utf8CodepointLen(value, read);
        if (sequence_len > value.len - read or sequence_len > destination.len - write)
            break;
        @memcpy(
            destination[write..][0..sequence_len],
            value[read..][0..sequence_len],
        );
        write += sequence_len;
        read += sequence_len;
    }
    return .{
        .len = write,
        .truncated = read != value.len,
        .redacted = redacted,
    };
}

fn utf8CodepointLen(value: []const u8, start: usize) usize {
    return @min(
        std.unicode.utf8ByteSequenceLength(value[start]) catch 1,
        value.len - start,
    );
}

fn credentialEndAtCodepoint(
    value: []const u8,
    codepoint_start: usize,
    credential: []const u8,
) ?usize {
    if (credential.len == 0) return null;
    const codepoint_len = utf8CodepointLen(value, codepoint_start);
    var match_end: usize = 0;
    for (0..codepoint_len) |offset| {
        if (std.mem.startsWith(
            u8,
            value[codepoint_start + offset ..],
            credential,
        )) match_end = @max(
            match_end,
            codepoint_start + offset + credential.len,
        );
    }
    if (match_end == 0) return null;
    var end = @min(value.len, match_end);
    while (end < value.len and value[end] & 0xc0 == 0x80) end += 1;
    return end;
}

pub const TextProjector = struct {
    project_fn: *const fn ([]u8, []const u8, []const u8) Projection,

    fn project(
        self: TextProjector,
        destination: []u8,
        value: []const u8,
        secret: []const u8,
    ) Projection {
        return self.project_fn(destination, value, secret);
    }
};

pub const CheckpointResources = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    store: ?*checkpoint_store.FileStore,
    store_health: *std.atomic.Value(checkpoint_store.Health),
    limits: agent.CheckpointLimits,
};

pub const RunJob = struct {
    run: *state.RunRecord,
    worker_references: *std.atomic.Value(usize),
    notifier: Notifier,
    projector: TextProjector,
    completion_factory: CompletionFactory,
    checkpoint: CheckpointResources,
    title_execution: ?execution_binding.OwnedTaskExecution = null,
    access: ?agent_session.Access = null,

    pub fn sessionAccess(self: *RunJob) *agent_session.Access {
        return if (self.access) |*value| value else unreachable;
    }

    fn releaseSessionAccess(self: *RunJob) void {
        if (self.access) |*access| access.deinit();
        self.access = null;
    }

    pub fn destroy(self: *RunJob) void {
        self.releaseSessionAccess();
        if (self.title_execution) |*execution| execution.deinit();
        self.title_execution = null;
        std.heap.c_allocator.destroy(self);
    }
};

pub const CompactJob = struct {
    compact: *state.CompactRecord,
    worker_references: *std.atomic.Value(usize),
    notifier: Notifier,
    projector: TextProjector,
    checkpoint: CheckpointResources,
    access: ?agent_session.Access = null,

    pub fn sessionAccess(self: *CompactJob) *agent_session.Access {
        return if (self.access) |*value| value else unreachable;
    }

    pub fn destroy(self: *CompactJob) void {
        if (self.access) |*access| access.deinit();
        self.access = null;
        std.heap.c_allocator.destroy(self);
    }
};

const automatic_title_result_capacity = state.automatic_title_result_capacity;
const automatic_title_timeout_ms: u32 = 15_000;
const automatic_title_watchdog_poll_ms: u32 = 10;
const automatic_title_system_prompt =
    "Generate a concise title for this task. Return only one plain-text title " ++
    "in the user's language, without quotes or Markdown. Use at most 32 Unicode characters.";

const AutomaticTitleWatchdog = struct {
    io: std.Io,
    title: *state.AutomaticTitle,
    request_cancellation: *agent.CompletionCancellation,
    finished: std.atomic.Value(bool) = .init(false),
    timed_out: std.atomic.Value(bool) = .init(false),

    fn run(self: *AutomaticTitleWatchdog) void {
        var elapsed_ms: u32 = 0;
        while (elapsed_ms < automatic_title_timeout_ms) : (elapsed_ms += automatic_title_watchdog_poll_ms) {
            if (self.finished.load(.acquire)) return;
            if (self.title.cancel_requested.load(.acquire)) {
                self.request_cancellation.request();
                return;
            }
            std.Io.Timeout.sleep(.{ .duration = .{
                .raw = std.Io.Duration.fromMilliseconds(automatic_title_watchdog_poll_ms),
                .clock = .awake,
            } }, self.io) catch break;
        }
        if (self.finished.load(.acquire)) return;
        if (self.title.cancel_requested.load(.acquire)) {
            self.request_cancellation.request();
            return;
        }
        self.timed_out.store(true, .release);
        self.request_cancellation.request();
    }
};

pub fn executeRun(context: *anyopaque) void {
    const job: *RunJob = @ptrCast(@alignCast(context));
    defer job.destroy();
    const run = job.run;
    const claimed = run.agent_handoff.cmpxchgStrong(.queued, .starting, .acq_rel, .acquire);
    std.debug.assert(claimed == null);
    var agent_run = switch (job.sessionAccess().beginRunOutcome(run.id)) {
        .run => |value| value,
        .failure => |failure| {
            run.agent_handoff.store(.finishing, .release);
            commitBeginFailure(job.projector, run, failure);
            publishAutomaticTitleFallback(run);
            releaseRunWorkerReference(job.worker_references, run);
            job.notifier.notify();
            return;
        },
    };
    run.run_control = agent_run.control();
    run.agent_handoff.store(.running, .release);
    if (run.pending_termination.load(.acquire) != .none) {
        if (run.run_control.tryAcquireLease()) |lease_value| {
            var lease = lease_value;
            const result = lease.requestTermination(policy.pendingTerminationSignal(run));
            lease.deinit();
            if (result == .stale_run) std.debug.panic(
                "newly published RunControl for Run {d} was already stale",
                .{run.id},
            );
        }
    }
    var terminal = agent_run.execute();
    run.agent_handoff.store(.finishing, .release);
    _ = commitAgentTerminal(job.projector, run, &terminal);
    const checkpoint_eligible = terminal.raw_status_code != null and
        terminal.session_disposition_at_completion == .reusable;
    terminal.deinit();
    agent_run.deinit();
    const checkpoint_started = checkpoint_eligible and postprocessCheckpoint(
        job.checkpoint,
        job.sessionAccess(),
        &run.checkpoint,
        run.checkpoint_export_context,
    );
    job.releaseSessionAccess();
    job.notifier.notify();
    generateAutomaticTitle(job);
    if (!checkpoint_started)
        releaseRunWorkerReference(job.worker_references, run);
    job.notifier.notify();
}

pub fn cancelRun(context: *anyopaque) void {
    const job: *RunJob = @ptrCast(@alignCast(context));
    defer job.destroy();
    const run = job.run;
    _ = run.pending_termination.cmpxchgStrong(.none, .app_shutdown, .acq_rel, .acquire);
    const signal = policy.pendingTerminationSignal(run);
    const decision = policy.decisionForSignal(signal);
    const interruption = switch (signal) {
        .interrupted => |value| value,
        else => unreachable,
    };
    cancelPreparedRunOrPanic(job.sessionAccess(), run.id);
    _ = commitRunTerminal(
        job.projector,
        run,
        decision.phase,
        decision.outcome,
        decision.cause,
        switch (interruption) {
            .user_cancel, .timeout => .reusable,
            .session_close, .app_shutdown => .closing,
        },
        "",
        false,
    );
    publishAutomaticTitleFallback(run);
    releaseRunWorkerReference(job.worker_references, run);
    job.notifier.notify();
}

pub fn executeCompact(context: *anyopaque) void {
    const job: *CompactJob = @ptrCast(@alignCast(context));
    defer job.destroy();
    const compact = job.compact;
    compact.agent_handoff.store(.starting, .release);
    job.notifier.notify();
    compact.agent_handoff.store(.running, .release);
    var terminal = job.sessionAccess().executePreparedCompact(compact.id) catch |err| {
        compact.agent_handoff.store(.finishing, .release);
        _ = commitCompactProductTerminal(
            job.projector,
            compact,
            .failed,
            if (err == error.SessionClosing) .session_close else .dependency_contract_failure,
            if (err == error.SessionClosing) .closing else .poisoned,
            .{},
            0,
            0,
            "",
            false,
        );
        releaseCompactWorkerReference(job.worker_references, compact);
        job.notifier.notify();
        return;
    };
    compact.agent_handoff.store(.finishing, .release);
    commitCompactTerminal(job.projector, compact, &terminal);
    const checkpoint_eligible = terminal.raw_status_code != null and
        terminal.session_disposition_at_completion == .reusable;
    terminal.deinit();
    if (!checkpoint_eligible or !postprocessCheckpoint(
        job.checkpoint,
        job.sessionAccess(),
        &compact.checkpoint,
        compact.checkpoint_export_context,
    )) releaseCompactWorkerReference(job.worker_references, compact);
    job.notifier.notify();
}

pub fn cancelCompact(context: *anyopaque) void {
    const job: *CompactJob = @ptrCast(@alignCast(context));
    defer job.destroy();
    const compact = job.compact;
    _ = compact.pending_interruption.cmpxchgStrong(.none, .app_shutdown, .acq_rel, .acquire);
    const interruption = policy.pendingExternalInterruption(compact);
    cancelPreparedCompactOrPanic(job.sessionAccess(), compact.id);
    _ = commitCompactProductTerminal(
        job.projector,
        compact,
        .aborted,
        policy.compactCauseForInterruption(interruption),
        if (interruption == .user_cancel) .reusable else .closing,
        .{},
        0,
        0,
        "",
        false,
    );
    releaseCompactWorkerReference(job.worker_references, compact);
    job.notifier.notify();
}

fn generateAutomaticTitle(job: *RunJob) void {
    const run = job.run;
    const claimed = run.automatic_title.state.cmpxchgStrong(.pending, .running, .acq_rel, .acquire);
    if (claimed != null) return;
    defer run.automatic_title.state.store(.ready, .release);
    if (run.automatic_title.cancel_requested.load(.acquire)) return;
    const source = automaticTitleCompletionInput(&run.input) orelse return;
    const execution = &(job.title_execution orelse return);
    const config = execution.input();
    const owner = job.completion_factory.create(std.heap.c_allocator, .{
        .provider_id = config.target.provider_id,
        .protocol = agent_protocol.toAgent(config.target.protocol),
        .credential = config.api_key,
        .base_url = config.target.base_url,
        .model = config.target.model,
    }) catch return;
    defer owner.deinit();
    const messages = [_]agent.CompletionMessage{.{ .role = .user, .text = source }};
    var request_cancellation = owner.newCancellation();
    var watchdog = AutomaticTitleWatchdog{
        .io = job.checkpoint.io,
        .title = &run.automatic_title,
        .request_cancellation = &request_cancellation,
    };
    const watchdog_thread = std.Thread.spawn(.{}, AutomaticTitleWatchdog.run, .{&watchdog}) catch {
        return;
    };
    var completion_outcome = owner.complete(.{
        .system = automatic_title_system_prompt,
        .messages = &messages,
    }, &request_cancellation);
    watchdog.finished.store(true, .release);
    watchdog_thread.join();
    if (watchdog.timed_out.load(.acquire) or
        run.automatic_title.cancel_requested.load(.acquire) or
        request_cancellation.isRequested())
    {
        switch (completion_outcome) {
            .result => |*result| result.deinit(),
            .failure => {},
        }
        return;
    }
    var result = switch (completion_outcome) {
        .result => |value| value,
        .failure => return,
    };
    defer result.deinit();
    if (result.stop_reason != .end_turn or
        result.text.len > automatic_title_result_capacity)
        return;
    const projected = job.projector.project(
        &run.automatic_title.result,
        result.text,
        config.api_key,
    );
    run.automatic_title.result_len = projected.len;
    run.automatic_title.generated_redacted = projected.redacted;
    run.automatic_title.generated = true;
}

fn automaticTitleCompletionInput(input: *const state.RunInputRecord) ?[]const u8 {
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

pub fn publishAutomaticTitleFallback(run: *state.RunRecord) void {
    _ = run.automatic_title.state.cmpxchgStrong(.pending, .ready, .acq_rel, .acquire);
}

pub fn commitRunTerminal(
    projector: TextProjector,
    run: *state.RunRecord,
    phase: state.RunPhase,
    outcome: state.RunOutcome,
    cause: ?state.RunCause,
    session_disposition: agent.SessionDisposition,
    diagnostic: []const u8,
    source_diagnostic_truncated: bool,
) bool {
    std.debug.assert(state.isTerminalPhase(phase));
    if (run.terminal_publication.cmpxchgStrong(.open, .publishing, .acq_rel, .acquire) == null) {
        const projected = projector.project(run.terminal_diagnostic, diagnostic, run.redaction_secret);
        run.terminal_payload = .{
            .phase = phase,
            .outcome = outcome,
            .cause = cause,
            .session_disposition_at_completion = session_disposition,
            .diagnostic_len = projected.len,
            .diagnostic_truncated = source_diagnostic_truncated or projected.truncated,
            .diagnostic_redacted = projected.redacted,
        };
        run.terminal_publication.store(.published, .release);
        return true;
    }
    _ = state.terminalPayload(run).?;
    return false;
}

fn commitAgentTerminal(projector: TextProjector, run: *state.RunRecord, result: *const agent.TerminalResult) bool {
    if (result.file_changes_lost and run.file_change_observation != null) {
        run.file_changes_known_loss = true;
        run.file_change_observation = .incomplete;
    }
    const decision = policy.classifyAgentTerminal(result);
    return commitRunTerminal(
        projector,
        run,
        decision.phase,
        decision.outcome,
        decision.cause,
        result.session_disposition_at_completion,
        result.diagnostic(),
        result.diagnostic_truncated,
    );
}

fn commitBeginFailure(projector: TextProjector, run: *state.RunRecord, failure: agent.BeginRunFailure) void {
    const decision = policy.classifyBeginFailure(run, failure);
    _ = commitRunTerminal(
        projector,
        run,
        decision.phase,
        decision.outcome,
        decision.cause,
        failure.session_disposition,
        "",
        false,
    );
}

fn commitCompactTerminal(
    projector: TextProjector,
    compact: *state.CompactRecord,
    result: *const agent.CompactTerminalResult,
) void {
    const decision = policy.classifyCompactTerminal(result);
    _ = commitCompactProductTerminal(
        projector,
        compact,
        decision.phase,
        decision.cause,
        result.session_disposition_at_completion,
        .{
            .input_tokens = result.input_tokens,
            .output_tokens = result.output_tokens,
            .cache_read_input_tokens = result.cache_read_input_tokens,
            .cache_creation_input_tokens = result.cache_creation_input_tokens,
        },
        result.before_context_tokens,
        result.after_context_tokens,
        result.diagnostic(),
        result.diagnostic_truncated,
    );
}

pub fn commitCompactProductTerminal(
    projector: TextProjector,
    compact: *state.CompactRecord,
    phase: state.CompactPhase,
    cause: ?state.CompactCause,
    session_disposition: agent.SessionDisposition,
    usage: state.UsageView,
    before_context_tokens: u64,
    after_context_tokens: u64,
    diagnostic: []const u8,
    source_diagnostic_truncated: bool,
) bool {
    std.debug.assert(state.isTerminalCompactPhase(phase));
    if (compact.terminal_publication.cmpxchgStrong(.open, .publishing, .acq_rel, .acquire) == null) {
        const projected = projector.project(
            compact.terminal_diagnostic,
            diagnostic,
            compact.redaction_secret,
        );
        compact.terminal_payload = .{
            .phase = phase,
            .cause = cause,
            .before_context_tokens = before_context_tokens,
            .after_context_tokens = after_context_tokens,
            .usage = usage,
            .session_disposition_at_completion = session_disposition,
            .diagnostic_len = projected.len,
            .diagnostic_truncated = source_diagnostic_truncated or projected.truncated,
            .diagnostic_redacted = projected.redacted,
        };
        compact.terminal_publication.store(.published, .release);
        return true;
    }
    _ = state.compactTerminalPayload(compact).?;
    return false;
}

const CheckpointSinkContext = struct {
    writer: *checkpoint_store.Writer,
    cancelled: *std.atomic.Value(bool),

    fn write(context: ?*anyopaque, bytes: []const u8) agent.CheckpointSinkWriteResult {
        const self: *CheckpointSinkContext = @ptrCast(@alignCast(context orelse return .contract_failed));
        if (self.cancelled.load(.acquire)) return .cancelled;
        self.writer.write(bytes) catch |err| return switch (err) {
            error.ResourceLimit => .contract_failed,
            error.WriteFailed => .io_failed,
        };
        return .ok;
    }
};

fn postprocessCheckpoint(
    resources: CheckpointResources,
    access: *agent_session.Access,
    postprocess: *state.CheckpointPostprocess,
    context: state.CheckpointExportContext,
) bool {
    if (resources.store_health.load(.acquire) != .ready) return false;
    const store = resources.store orelse return false;
    postprocess.state.store(.exporting, .release);
    if (postprocess.cancelled.load(.acquire)) {
        publishCheckpointFailure(postprocess, .cancelled);
        return true;
    }
    var writer = store.begin(context.task_id, resources.limits.hard_bytes) catch {
        publishCheckpointFailure(postprocess, .io_failed);
        return true;
    };
    defer writer.deinit();
    var sink_context = CheckpointSinkContext{ .writer = &writer, .cancelled = &postprocess.cancelled };
    const started = std.Io.Timestamp.now(resources.io, .awake);
    var outcome = access.exportCheckpoint(
        resources.limits,
        .{ .context = &sink_context, .write_fn = CheckpointSinkContext.write },
        context.last_run_id,
        context.last_compact_id,
        context.model,
    ) catch {
        publishCheckpointFailure(postprocess, .export_failed);
        return true;
    };
    const finished = std.Io.Timestamp.now(resources.io, .awake);
    const duration_ns: i128 = @intCast(started.durationTo(finished).nanoseconds);
    switch (outcome) {
        .failure => |failure| {
            const attempt = policy.checkpointFailureAttempt(failure);
            outcome.deinit();
            publishCheckpointFailure(postprocess, attempt);
            return true;
        },
        .success => |*success| {
            const chunk_count = success.checkpoint.chunk_count;
            var candidate = state.CheckpointCandidate{
                .record = takeCheckpointRecord(
                    success,
                    context.task_id,
                    context.terminal_kind,
                    context.terminal_id,
                    context.binding_epoch,
                ),
                .metrics = .{ .chunk_count = chunk_count, .export_duration_ns = duration_ns },
            };
            outcome = undefined;
            const identity = writer.commit(
                candidate.record.blob.generation,
                candidate.record.blob.digest,
                candidate.record.blob.byte_size,
            ) catch |err| {
                if (err == error.PersistenceOutcomeUnknown) {
                    resources.store_health.store(.outcome_unknown, .release);
                    postprocess.payload = .{ .store_outcome_unknown = candidate };
                    postprocess.state.store(.store_outcome_unknown, .release);
                    return true;
                }
                candidate.record.deinit(resources.allocator);
                publishCheckpointFailure(postprocess, .io_failed);
                return true;
            };
            candidate.record.blob = identity;
            postprocess.payload = .{ .candidate = candidate };
            postprocess.state.store(.candidate_ready, .release);
            return true;
        },
    }
}

fn publishCheckpointFailure(postprocess: *state.CheckpointPostprocess, attempt: state.CheckpointAttempt) void {
    postprocess.payload = .{ .failure = attempt };
    postprocess.state.store(.failure_ready, .release);
}

fn takeCheckpointRecord(
    success: *agent.CheckpointSuccess,
    task_id: u64,
    terminal_kind: std.meta.Tag(checkpoint_record.Terminal),
    terminal_id: u64,
    binding_epoch: u64,
) checkpoint_record.Record {
    const description = &success.description;
    if (description.skill_catalog_revision) |value| description.allocator.free(value);
    description.allocator.free(description.mcp_selection_fingerprint);
    const terminal: checkpoint_record.Terminal = switch (terminal_kind) {
        .run => .{ .run = terminal_id },
        .compact => .{ .compact = terminal_id },
    };
    const result = checkpoint_record.Record{
        .blob = .{
            .task_id = task_id,
            .generation = success.checkpoint.generation,
            .byte_size = success.checkpoint.total_bytes,
            .digest = success.checkpoint.digest,
        },
        .session = .{
            .logical_session_id = description.session_id,
            .last_run_id = description.last_run_id,
            .last_compact_id = description.last_compact_id,
            .model = description.model,
        },
        .anchor = .{ .terminal = terminal, .binding_epoch = binding_epoch },
    };
    success.* = undefined;
    return result;
}

pub fn cancelPreparedRunOrPanic(access: *agent_session.Access, run_id: u64) void {
    access.cancelPreparedRun(run_id) catch |err| std.debug.panic(
        "Executor removed queued Run {d}, but Agent rejected prepared cancellation: {s}",
        .{ run_id, @errorName(err) },
    );
}

pub fn cancelPreparedCompactOrPanic(access: *agent_session.Access, operation_id: u64) void {
    access.cancelPreparedCompact(operation_id) catch |err| std.debug.panic(
        "Executor removed queued compact {d}, but Agent rejected prepared cancellation: {s}",
        .{ operation_id, @errorName(err) },
    );
}

pub fn releaseRunWorkerReference(references: *std.atomic.Value(usize), run: *state.RunRecord) void {
    std.debug.assert(run.worker_reference_held.swap(false, .acq_rel));
    const previous = references.fetchSub(1, .release);
    std.debug.assert(previous != 0);
}

pub fn releaseCompactWorkerReference(
    references: *std.atomic.Value(usize),
    compact: *state.CompactRecord,
) void {
    if (!compact.worker_reference_held.swap(false, .acq_rel)) return;
    const previous = references.fetchSub(1, .release);
    std.debug.assert(previous != 0);
}
