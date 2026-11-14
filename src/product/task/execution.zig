//! Task-owned executor payloads and worker callbacks.
//! Jobs borrow only stable records, scoped Agent Session access, narrow effect
//! capabilities, and the specific atomics that keep their records alive. They
//! never retain a composition aggregate or Task runtime pointer.

const std = @import("std");
const thread_stack = @import("metawork_thread_stack");
const credential_match = @import("product_credential_match");
const agent = @import("metawork_agent");
const checkpoint_record = @import("product_task_checkpoint_record");
const checkpoint_store = @import("product_task_checkpoint_store");
const execution_binding = @import("product_task_execution_binding");
const agent_session = @import("product_task_agent_session");
const state = @import("product_task_state");
const policy = @import("product_task_policy");
const worker_lease = @import("product_task_worker_lease");
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
        agent.ModelBinding,
    ) anyerror!*agent.Completion = null,

    fn create(
        self: CompletionFactory,
        allocator: std.mem.Allocator,
        binding: agent.ModelBinding,
    ) anyerror!*agent.Completion {
        if (self.create_fn) |create_fn|
            return create_fn(self.context, allocator, binding);
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
    secrets: []const []const u8,
) Projection {
    var read: usize = 0;
    var write: usize = 0;
    var redacted = false;
    while (read < value.len) {
        if (credentialsEndAtCodepoint(value, read, secrets)) |redaction_end| {
            const marker_len = @min(redaction_end - read, 3);
            if (marker_len > destination.len - write) break;
            @memset(destination[write..][0..marker_len], '*');
            write += marker_len;
            read = redaction_end;
            redacted = true;
            continue;
        }
        const sequence_len = credential_match.codepointLen(value, read);
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

fn credentialsEndAtCodepoint(value: []const u8, start: usize, secrets: []const []const u8) ?usize {
    var end: usize = 0;
    var cursor = start;
    // Merge overlaps using the original bytes, never a previously masked copy.
    while (cursor == start or cursor < end) : (cursor += credential_match.codepointLen(value, cursor)) {
        for (secrets) |secret| if (credential_match.matchEnd(value, cursor, secret)) |match_end| {
            end = @max(end, match_end);
        };
    }
    return if (end == 0) null else end;
}

test "image Run projection masks both credentials and their overlapping original bytes" {
    var output: [128]u8 = undefined;
    const result = projectSanitized(&output, "prefix abcdef suffix image-token", &.{ "abcd", "cdef", "image-token" });
    try std.testing.expectEqualStrings("prefix *** suffix ***", output[0..result.len]);
    try std.testing.expect(result.redacted);
    try std.testing.expect(!result.truncated);
    const short = projectSanitized(output[0..2], "image-token", &.{"image-token"});
    try std.testing.expect(short.truncated);
    try std.testing.expectEqual(@as(usize, 0), short.len);
}

pub const TextProjector = struct {
    project_fn: *const fn ([]u8, []const u8, []const []const u8) Projection,

    fn project(
        self: TextProjector,
        destination: []u8,
        value: []const u8,
        secrets: []const []const u8,
    ) Projection {
        return self.project_fn(destination, value, secrets);
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
    lease: worker_lease.WorkerLease,
    checkpoint_lease: ?worker_lease.WorkerLease,
    notifier: Notifier,
    projector: TextProjector,
    completion_factory: CompletionFactory,
    checkpoint: CheckpointResources,
    title_execution: ?execution_binding.OwnedTaskExecution = null,
    title_credential: ?*execution_binding.credential.Source = null,
    access: ?agent_session.Access = null,

    pub fn sessionAccess(self: *RunJob) *agent_session.Access {
        return if (self.access) |*value| value else unreachable;
    }

    fn releaseSessionAccess(self: *RunJob) void {
        if (self.access) |*access| access.deinit();
        self.access = null;
    }

    fn finish(self: *RunJob) void {
        // Notifier lifetime extends through every worker join. No job/Task access follows release.
        const notifier = self.notifier;
        self.destroy();
        if (!notifier.notify_fn(notifier.context)) @panic("required Run cleanup wake failed");
    }

    pub fn destroy(self: *RunJob) void {
        self.releaseSessionAccess();
        if (self.title_execution) |*execution| execution.deinit();
        self.title_execution = null;
        if (self.title_credential) |reader| reader.release();
        self.title_credential = null;
        if (self.checkpoint_lease) |*lease| lease.deinit();
        self.checkpoint_lease = null;
        self.lease.deinit();
        std.heap.c_allocator.destroy(self);
    }
};

pub const CompactJob = struct {
    compact: *state.CompactRecord,
    lease: worker_lease.WorkerLease,
    checkpoint_lease: ?worker_lease.WorkerLease,
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
        if (self.checkpoint_lease) |*lease| lease.deinit();
        self.checkpoint_lease = null;
        self.lease.deinit();
        std.heap.c_allocator.destroy(self);
    }
};

const automatic_title_result_capacity = state.automatic_title_result_capacity;
const automatic_title_timeout_ms: u32 = 15_000;
/// DNS, TCP and TLS share at most 15 s of the title budget.
const automatic_title_connect_timeout_ms: u32 = @min(automatic_title_timeout_ms, 15_000);
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
    defer job.finish();
    const run = job.run;
    const claimed = run.agent_handoff.cmpxchgStrong(.queued, .starting, .acq_rel, .acquire);
    std.debug.assert(claimed == null);
    var agent_run = switch (job.sessionAccess().beginRunOutcome(run.id)) {
        .run => |value| value,
        .failure => |failure| {
            run.agent_handoff.store(.finishing, .release);
            commitBeginFailure(job.projector, run, failure);
            publishAutomaticTitleFallback(run);
            job.notifier.notify();
            return;
        },
    };
    run.execution.?.run_control = agent_run.control();
    // Pair with requestRunTermination so both sides cannot miss the handoff.
    run.agent_handoff.store(.running, .seq_cst);
    if (run.pending_termination.load(.seq_cst) != .none) {
        if (run.execution.?.run_control.tryAcquireLease()) |lease_value| {
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
    const checkpoint_eligible = terminal.coreWasInvoked() and
        terminal.session_disposition_at_completion == .reusable;
    terminal.deinit();
    agent_run.deinit();
    _ = checkpoint_eligible and postprocessCheckpoint(
        job.checkpoint,
        job.sessionAccess(),
        &run.checkpoint,
        run.execution.?.checkpoint_export_context,
        &job.checkpoint_lease,
    );
    job.releaseSessionAccess();
    job.notifier.notify();
    generateAutomaticTitle(job);
    job.notifier.notify();
}

pub fn cancelRun(context: *anyopaque) void {
    const job: *RunJob = @ptrCast(@alignCast(context));
    defer job.finish();
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
        true,
        null,
        false,
    );
    publishAutomaticTitleFallback(run);
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
            true,
        );
        job.notifier.notify();
        return;
    };
    compact.agent_handoff.store(.finishing, .release);
    commitCompactTerminal(job.projector, compact, &terminal);
    const checkpoint_eligible = terminal.coreWasInvoked() and
        terminal.session_disposition_at_completion == .reusable;
    terminal.deinit();
    _ = checkpoint_eligible and postprocessCheckpoint(
        job.checkpoint,
        job.sessionAccess(),
        &compact.checkpoint,
        compact.checkpoint_export_context,
        &job.checkpoint_lease,
    );
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
        true,
    );
    job.notifier.notify();
}

fn generateAutomaticTitle(job: *RunJob) void {
    const run = job.run;
    const claimed = run.execution.?.automatic_title.state.cmpxchgStrong(.pending, .running, .acq_rel, .acquire);
    if (claimed != null) return;
    defer run.execution.?.automatic_title.state.store(.ready, .release);
    if (run.execution.?.automatic_title.cancel_requested.load(.acquire)) return;
    const source = automaticTitleCompletionInput(&run.input) orelse return;
    const execution = &(job.title_execution orelse return);
    const config = execution.input();
    var credential = (job.title_credential orelse return).copy(std.heap.c_allocator) catch return;
    defer credential.deinit();
    const owner = job.completion_factory.create(std.heap.c_allocator, .{
        .target = .{
            .provider_id = config.target.provider_id,
            .protocol = agent_protocol.toAgent(config.target.protocol),
            .base_url = config.target.base_url,
            .model = config.target.model,
        },
        .credential = credential.bytes,
    }) catch return;
    defer owner.deinit();
    const messages = [_]agent.CompletionMessage{.{ .role = .user, .text = source }};
    var request_cancellation = owner.newCancellation();
    var watchdog = AutomaticTitleWatchdog{
        .io = job.checkpoint.io,
        .title = &run.execution.?.automatic_title,
        .request_cancellation = &request_cancellation,
    };
    const watchdog_thread = std.Thread.spawn(thread_stack.config, AutomaticTitleWatchdog.run, .{&watchdog}) catch {
        return;
    };
    var completion_outcome = owner.complete(.{
        .system = automatic_title_system_prompt,
        .messages = &messages,
        .max_output_tokens = 4096,
        .connect_timeout_ms = automatic_title_connect_timeout_ms,
    }, &request_cancellation);
    watchdog.finished.store(true, .release);
    watchdog_thread.join();
    if (watchdog.timed_out.load(.acquire) or
        run.execution.?.automatic_title.cancel_requested.load(.acquire) or
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
    const initial = run.initialRedactionSecrets();
    const projected = job.projector.project(
        &run.execution.?.automatic_title.result,
        result.text,
        &.{ initial[0], initial[1], credential.bytes },
    );
    run.execution.?.automatic_title.result_len = projected.len;
    run.execution.?.automatic_title.generated_redacted = projected.redacted;
    run.execution.?.automatic_title.generated = true;
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
    const execution = run.execution orelse return;
    _ = execution.automatic_title.state.cmpxchgStrong(.pending, .ready, .acq_rel, .acquire);
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
    exclude_on_product_terminal: bool,
    model_error: ?state.RunModelError,
    event_delivery_lost: bool,
) bool {
    std.debug.assert(state.isTerminalPhase(phase));
    if (run.terminal_publication.cmpxchgStrong(.open, .publishing, .acq_rel, .acquire) == null) {
        const projected = projector.project(run.terminal_diagnostic, diagnostic, &run.initialRedactionSecrets());
        run.terminal_payload = .{
            .exclude_on_product_terminal = exclude_on_product_terminal,
            .phase = phase,
            .outcome = outcome,
            .cause = cause,
            .session_disposition_at_completion = session_disposition,
            .diagnostic_len = projected.len,
            .diagnostic_truncated = source_diagnostic_truncated or projected.truncated,
            .diagnostic_redacted = projected.redacted,
            .event_delivery_lost = event_delivery_lost,
            .model_error = if (model_error) |value| saved: {
                const storage = run.model_error_storage.?;
                storage.* = value;
                storage.source = run.model_error_source;
                break :saved storage;
            } else null,
        };
        run.terminal_publication.store(.published, .release);
        return true;
    }
    _ = state.terminalPayload(run).?;
    return false;
}

fn commitAgentTerminal(projector: TextProjector, run: *state.RunRecord, result: *const agent.TerminalResult) bool {
    if (!result.receipts.isEmpty() and state.terminalPayload(run) == null)
        run.execution.?.terminal_receipts = result.receipts;
    run.completed_input_counts = result.input_counts;
    if (result.file_changes_lost and run.file_change_observation != null) {
        run.file_changes_known_loss = true;
        run.file_change_observation = .incomplete;
    }
    var decision = policy.classifyAgentTerminal(result);
    decision.cause = policy.productCancelCause(run, decision.cause);
    var safe_diagnostic: [1024]u8 = undefined;
    var diagnostic = result.diagnostic();
    var truncated = result.diagnostic_truncated;
    if (result.first_callback_rejection != null or result.failure == .dependency_contract or result.abi_status == .callback_failed) {
        const rejection = result.first_callback_rejection;
        var prefix_truncated = false;
        const prefix = std.fmt.bufPrint(&safe_diagnostic, "agent.callback_rejection core_manifest_sha256={s} boundary={s} reason={s} event={s} error={s} bytes={?d} host_run={d} observed_run={?d} state={s} handle_matches={?} identity_matches={?}; ", .{
            agent.core_manifest_sha256,
            if (rejection) |value| @tagName(value.boundary) else "unobserved",
            if (rejection) |value| @tagName(value.reason) else "unknown",
            if (rejection) |value| if (value.event) |kind| @tagName(kind) else "unknown" else "unknown",
            if (rejection) |value| if (value.failure) |failure| @errorName(failure) else "none" else "none",
            if (rejection) |value| value.encoded_bytes else null,
            if (rejection) |value| value.host_run_id else run.id,
            if (rejection) |value| value.observed_run_id else null,
            if (rejection) |value| @tagName(value.state) else "unknown",
            if (rejection) |value| value.session_handle_matches else null,
            if (rejection) |value| value.session_identity_matches else null,
        }) catch prefix_failure: {
            prefix_truncated = true;
            break :prefix_failure "agent.callback_rejection details=unavailable; ";
        };
        // Prefix formatting and output capacity are diagnostic limits only.
        // Neither can fail or change the immutable Agent terminal decision.
        if (prefix.ptr != safe_diagnostic[0..].ptr) @memcpy(safe_diagnostic[0..prefix.len], prefix);
        const count = @min(safe_diagnostic.len - prefix.len, diagnostic.len);
        @memcpy(safe_diagnostic[prefix.len..][0..count], diagnostic[0..count]);
        truncated = truncated or prefix_truncated or count != diagnostic.len;
        diagnostic = safe_diagnostic[0 .. prefix.len + count];
    }
    return commitRunTerminal(
        projector,
        run,
        decision.phase,
        decision.outcome,
        decision.cause,
        result.session_disposition_at_completion,
        diagnostic,
        truncated,
        false,
        if (result.model_error) |detail| projectModelError(projector, detail, &run.initialRedactionSecrets()) else null,
        result.event_delivery_lost,
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
        true,
        null,
        false,
    );
}

fn projectModelError(projector: TextProjector, value: agent.ModelError, secrets: []const []const u8) state.RunModelError {
    var result: state.RunModelError = .{ .detail = value };
    const source = value.view();
    const message = projector.project(&result.detail.message.bytes, source.message, secrets);
    result.detail.message.len = message.len;
    @memset(result.detail.message.bytes[message.len..], 0);
    result.host_redacted = message.redacted;
    result.host_truncated = message.truncated;
    inline for (.{ "code", "type", "request_id" }) |field| {
        if (@field(result.detail, field)) |*target| {
            const projected = projector.project(&target.bytes, @field(source, field).?, secrets);
            target.len = projected.len;
            @memset(target.bytes[projected.len..], 0);
            result.host_redacted = result.host_redacted or projected.redacted;
            result.host_truncated = result.host_truncated or projected.truncated;
        }
    }
    return result;
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
        false,
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
    exclude_on_product_terminal: bool,
) bool {
    std.debug.assert(state.isTerminalCompactPhase(phase));
    if (compact.terminal_publication.cmpxchgStrong(.open, .publishing, .acq_rel, .acquire) == null) {
        const projected = projector.project(
            compact.terminal_diagnostic,
            diagnostic,
            &.{compact.redaction_secret},
        );
        compact.terminal_payload = .{
            .exclude_on_product_terminal = exclude_on_product_terminal,
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
    checkpoint_lease: *?worker_lease.WorkerLease,
) bool {
    if (resources.store_health.load(.acquire) != .ready) return false;
    const store = resources.store orelse return false;
    std.debug.assert(postprocess.lease == null);
    if (checkpoint_lease.*) |*lease| {
        postprocess.lease = lease.take();
    } else unreachable;
    checkpoint_lease.* = null;
    postprocess.binding_epoch = context.binding_epoch;
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
        postprocess.session_disposition = switch (access.sessionState()) {
            .poisoned => .poisoned,
            .closing, .closed => .closing,
            else => .reusable,
        };
        publishCheckpointFailure(postprocess, .export_failed);
        return true;
    };
    const finished = std.Io.Timestamp.now(resources.io, .awake);
    const duration_ns: i128 = @intCast(started.durationTo(finished).nanoseconds);
    switch (outcome) {
        .failure => |failure| {
            const attempt = policy.checkpointFailureAttempt(failure);
            postprocess.session_disposition = switch (failure.disposition) {
                .reusable => .reusable,
                .poisoned => .poisoned,
            };
            outcome.deinit();
            publishCheckpointFailure(postprocess, attempt);
            return true;
        },
        .success => |*success| {
            postprocess.session_disposition = .reusable;
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
                    candidate.record.deinit(resources.allocator);
                    publishCheckpointFailure(postprocess, .outcome_unknown);
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
        .approval => .{ .approval = terminal_id },
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

test "callback diagnostic enrichment preserves terminal decisions and bounded credential redaction" {
    for ([_]bool{ false, true }) |observed| {
        for ([_]usize{ 1, 512 }) |capacity| {
            var storage: [512]u8 = undefined;
            var record: state.RunRecord = .{
                .id = 7,
                .generation = 1,
                .execution_generation = 1,
                .execution_protocol = .anthropic_messages,
                .execution_model = "fixture",
                .permission_profile = .approval_required,
                .permission_interaction = .interactive,
                .input = .{ .text = .{ .value = &.{} } },
                .commentary_ends = &.{},
                .tools = &.{},
                .terminal_diagnostic = storage[0..capacity],
                .initial_credentials = .{ "SECRET-KEY", &.{}, &.{} },
            };
            const run = &record;
            var result: agent.TerminalResult = .{
                .allocator = std.testing.allocator,
                .diagnostic_storage = try std.testing.allocator.dupe(u8, "SECRET-KEY"),
                .diagnostic_len = "SECRET-KEY".len,
                .diagnostic_truncated = false,
                .abi_status = .callback_failed,
                .raw_status_code = null,
                .stop_reason = null,
                .raw_stop_reason_code = null,
                .abort_status = null,
                .raw_abort_status_code = null,
                .termination_signal = .{ .event_pump_failure = .invalid_event },
                .failure = .abi_status,
                .session_disposition_at_completion = .poisoned,
                .first_callback_rejection = if (observed) .{ .boundary = .event_decode, .reason = .decode_failed, .failure = error.InvalidPayload, .encoded_bytes = 2 } else null,
            };
            defer result.deinit();
            const decision = policy.classifyAgentTerminal(&result);
            try std.testing.expect(commitAgentTerminal(.{ .project_fn = projectSanitized }, run, &result));
            const terminal = state.terminalPayload(run).?;
            try std.testing.expectEqual(decision.phase, terminal.phase);
            try std.testing.expectEqual(decision.outcome, terminal.outcome);
            try std.testing.expectEqual(decision.cause, terminal.cause);
            try std.testing.expectEqual(agent.SessionDisposition.poisoned, terminal.session_disposition_at_completion);
            const diagnostic = run.terminal_diagnostic[0..terminal.diagnostic_len];
            try std.testing.expect(std.mem.indexOf(u8, diagnostic, "SECRET-KEY") == null);
            if (capacity == 1) try std.testing.expect(terminal.diagnostic_truncated) else {
                try std.testing.expect(std.mem.indexOf(u8, diagnostic, agent.core_manifest_sha256) != null);
                try std.testing.expect(std.mem.indexOf(u8, diagnostic, if (observed) "decode_failed" else "unobserved") != null);
            }
        }
    }
}

test "terminal file observation loss is retained even without a file record" {
    var run: state.RunRecord = .{
        .id = 7,
        .generation = 1,
        .execution_generation = 1,
        .execution_protocol = .openai_chat_completions,
        .execution_model = "fixture",
        .permission_profile = .approval_required,
        .permission_interaction = .interactive,
        .input = .{ .text = .{ .value = &.{} } },
        .commentary_ends = &.{},
        .tools = &.{},
        .file_change_observation = .collecting,
        .terminal_diagnostic = &.{},
    };
    const result: agent.TerminalResult = .{
        .allocator = std.testing.allocator,
        .diagnostic_storage = &.{},
        .diagnostic_len = 0,
        .diagnostic_truncated = false,
        .abi_status = .ok,
        .raw_status_code = null,
        .stop_reason = .end_turn,
        .raw_stop_reason_code = null,
        .abort_status = null,
        .raw_abort_status_code = null,
        .termination_signal = null,
        .failure = null,
        .session_disposition_at_completion = .reusable,
        .file_changes_lost = true,
    };
    try std.testing.expect(commitAgentTerminal(.{ .project_fn = projectSanitized }, &run, &result));
    run.event_stream_finalized = true;
    try std.testing.expectEqual(@as(usize, 0), run.file_changes.len);
    try std.testing.expect(run.file_changes_known_loss);
    try std.testing.expectEqual(state.FileChangeObservation.incomplete, state.finalizedFileChangeObservation(&run));
    try std.testing.expectEqual(state.RunOutcome.completed, state.productTerminalFacts(&run).?.outcome);
}

test "model error publication owns sanitized fields and preserves primary and supplemental terminal facts" {
    for ([_]bool{ false, true }) |callback_failed| {
        var storage: [32]u8 = undefined;
        var model_error_storage: state.RunModelError = undefined;
        var run: state.RunRecord = .{
            .id = 7,
            .generation = 1,
            .execution_generation = 1,
            .execution_protocol = .openai_chat_completions,
            .execution_model = "fixture",
            .permission_profile = .approval_required,
            .permission_interaction = .interactive,
            .input = .{ .text = .{ .value = &.{} } },
            .commentary_ends = &.{},
            .tools = &.{},
            .terminal_diagnostic = &storage,
            .model_error_storage = &model_error_storage,
            .initial_credentials = .{ "SECRET", "SECRET-LONG", &.{} },
        };
        var result: agent.TerminalResult = .{
            .allocator = std.testing.allocator,
            .diagnostic_storage = &.{},
            .diagnostic_len = 0,
            .diagnostic_truncated = false,
            .abi_status = if (callback_failed) .callback_failed else .ok,
            .raw_status_code = null,
            .stop_reason = if (callback_failed) null else .api_error,
            .raw_stop_reason_code = null,
            .abort_status = null,
            .raw_abort_status_code = null,
            .termination_signal = if (callback_failed) .{ .event_pump_failure = .invalid_event } else null,
            .failure = if (callback_failed) .abi_status else null,
            .session_disposition_at_completion = if (callback_failed) .poisoned else .reusable,
            .model_error = try agent.ModelError.init(.{
                .run_id = 900,
                .category = .authentication,
                .message = "服务 SECRET-LONG refused",
                .code = "SECRET-code",
                .type = "SECRET-type",
                .request_id = "SECRET-request",
                .retry = .unknown,
                .attempts = 2,
                .http_status = 200,
                .truncated = true,
            }),
        };
        try std.testing.expect(commitAgentTerminal(.{ .project_fn = projectSanitized }, &run, &result));
        result.deinit();
        const terminal = state.terminalPayload(&run).?;
        const observation = terminal.model_error.?;
        const detail = observation.detail.view();
        try std.testing.expectEqual(@as(u64, 900), detail.run_id);
        try std.testing.expectEqual(.authentication, detail.category);
        try std.testing.expectEqualStrings("服务 *** refused", detail.message);
        inline for (.{ "code", "type", "request_id" }) |field|
            try std.testing.expect(std.mem.indexOf(u8, @field(detail, field).?, "SECRET") == null);
        try std.testing.expect(observation.host_redacted);
        try std.testing.expect(!observation.host_truncated);
        try std.testing.expect(detail.truncated);
        try std.testing.expectEqual(@as(u32, 2), detail.attempts);
        try std.testing.expectEqual(@as(?u16, 200), detail.http_status);
        try std.testing.expect(std.mem.indexOf(u8, &observation.detail.message.bytes, "SECRET") == null);
        if (callback_failed) {
            try std.testing.expect(terminal.cause != .provider_failure);
        } else try std.testing.expectEqual(state.RunCause.provider_failure, terminal.cause.?);
        run.event_stream_finalized = true;
        run.event_projection_failure = .dependency_contract_failure;
        try std.testing.expectEqual(state.RunOutcome.dependency_contract_failure, state.productTerminalFacts(&run).?.outcome);
        try std.testing.expect(state.terminalPayload(&run).?.model_error != null);
        try std.testing.expect(!commitAgentTerminal(.{ .project_fn = projectSanitized }, &run, &.{
            .allocator = std.testing.allocator,
            .diagnostic_storage = &.{},
            .diagnostic_len = 0,
            .diagnostic_truncated = false,
            .abi_status = .ok,
            .raw_status_code = null,
            .stop_reason = .end_turn,
            .raw_stop_reason_code = null,
            .abort_status = null,
            .raw_abort_status_code = null,
            .termination_signal = null,
            .failure = null,
            .session_disposition_at_completion = .reusable,
        }));
        try std.testing.expectEqualStrings(detail.message, state.terminalPayload(&run).?.model_error.?.detail.view().message);
    }
}
