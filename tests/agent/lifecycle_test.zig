const fixture = @import("lifecycle_fixture");
const std = fixture.std;
const lifecycle = fixture.lifecycle;
const workbench_executor = fixture.workbench_executor;
const sdk = fixture.sdk;
const wire = fixture.wire;
const textChunk = fixture.textChunk;
const Plan = fixture.Plan;
const fake_core = &fixture.fake_core;
const diagnostic_byte: u8 = 0xA5;
const diagnostic = fixture.diagnostic;
const runtimeDestroy = fixture.runtimeDestroy;
const bufferRelease = fixture.bufferRelease;
const fake_api = fixture.fake_api;
const openSession = fixture.openSession;
const unavailableEventConsumer = fixture.unavailableEventConsumer;
const registerTestComposition = fixture.registerTestComposition;
const submitSession = fixture.submitSession;
const cancelSession = fixture.cancelSession;
const closeSession = fixture.closeSession;
const takeTestTerminal = fixture.takeTestTerminal;
const shutdownTestComposition = fixture.shutdownTestComposition;
const deinitTestComposition = fixture.deinitTestComposition;
const createTestComposition = fixture.createTestComposition;
const closeOnThread = fixture.closeOnThread;
const cancelOnThread = fixture.cancelOnThread;
const failPipelineOnThread = fixture.failPipelineOnThread;
const CallbackSignal = fixture.CallbackSignal;

test "Runtime rejects revision 4 tables without required Skill capabilities" {
    var api = fake_api;
    api.capabilities &= ~wire.CAP_SKILL_CATALOG;
    try std.testing.expectError(
        error.UnsupportedAbi,
        lifecycle.Runtime.initWithApi(
            std.testing.io,
            std.testing.allocator,
            &api,
            .{ .max_sessions = 1 },
        ),
    );

    api = fake_api;
    api.capabilities &= ~wire.CAP_TYPED_RUN_INPUT;
    try std.testing.expectError(
        error.UnsupportedAbi,
        lifecycle.Runtime.initWithApi(
            std.testing.io,
            std.testing.allocator,
            &api,
            .{ .max_sessions = 1 },
        ),
    );
}

const UiAnswerThenIdentityMismatch = struct {
    session: ?*lifecycle.Session = null,
    invoked: bool = false,
    failed: bool = false,
    mismatch_status: ?u32 = null,

    fn notify(context: ?*anyopaque) lifecycle.EventReadyNotification {
        const self: *UiAnswerThenIdentityMismatch = @ptrCast(@alignCast(context orelse
            return .unavailable));
        if (self.invoked) return .already_pending;
        const session = self.session orelse return .already_pending;
        const request_id = session.pendingUiRequest() orelse return .already_pending;
        self.invoked = true;
        const run_id = session.snapshot().active_run_id;
        session.respondUi(
            run_id,
            request_id,
            .{ .permission = .allow_once },
        ) catch {
            self.failed = true;
            return .unavailable;
        };
        self.mismatch_status = fake_core.invokeRunningIdentityMismatch();
        if (self.mismatch_status == null) self.failed = true;
        return .scheduled;
    }
};

test "RunControlLease remains safe after natural completion" {
    fake_core.reset();
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);
    const run_id = try session.prepareRun("complete before the retained lease is released");
    var run = try session.beginRun(run_id);
    var lease = run.control().tryAcquireLease().?;
    var terminal = run.execute();
    defer terminal.deinit();
    run.deinit();

    try std.testing.expectEqual(
        lifecycle.TerminationRequestResult.already_terminal,
        lease.requestTermination(.{ .interrupted = .user_cancel }),
    );
    lease.deinit();
    try closeSession(session, .session_close);
}

test "RunControlLease rejects a stale generation after slot reuse" {
    fake_core.reset();
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);

    const first_id = try session.prepareRun("first generation");
    var first = try session.beginRun(first_id);
    var stale = first.control().tryAcquireLease().?;
    var first_terminal = first.execute();
    defer first_terminal.deinit();
    first.deinit();

    const second_id = try session.prepareRun("second generation");
    var second = try session.beginRun(second_id);
    try std.testing.expectEqual(
        lifecycle.TerminationRequestResult.stale_run,
        stale.requestTermination(.{ .interrupted = .user_cancel }),
    );
    stale.deinit();
    var second_terminal = second.execute();
    defer second_terminal.deinit();
    second.deinit();
    try closeSession(session, .session_close);
}

test "RunControlLease termination before execute avoids the Core call" {
    fake_core.reset();
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);
    const run_id = try session.prepareRun("cancel before entering Core");
    var run = try session.beginRun(run_id);
    var lease = run.control().tryAcquireLease().?;
    try std.testing.expectEqual(
        lifecycle.TerminationRequestResult.requested,
        lease.requestTermination(.{ .interrupted = .user_cancel }),
    );
    lease.deinit();
    var terminal = run.execute();
    defer terminal.deinit();
    run.deinit();

    try std.testing.expectEqual(@as(?u32, null), terminal.raw_status_code);
    try std.testing.expectEqual(
        lifecycle.TerminationSignal{ .interrupted = .user_cancel },
        terminal.termination_signal.?,
    );
    fake_core.lock();
    const run_calls = fake_core.run_calls;
    const abort_calls = fake_core.abort_calls;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 0), run_calls);
    try std.testing.expectEqual(@as(usize, 0), abort_calls);
    try closeSession(session, .session_close);
}

test "RunControlLease close disables acquisition and waits for quiescence" {
    fake_core.reset();
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);
    const run_id = try session.prepareRun("retain control across close");
    var run = try session.beginRun(run_id);
    const control = run.control();
    var lease = control.tryAcquireLease().?;
    var terminal = run.execute();
    terminal.deinit();
    run.deinit();

    const close_thread = try std.Thread.spawn(.{}, closeOnThread, .{session});
    try session.waitForState(.closing);
    try std.testing.expect(control.tryAcquireLease() == null);
    fake_core.lock();
    const destroyed_while_leased = fake_core.session_destroyed;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 0), destroyed_while_leased);
    lease.deinit();
    close_thread.join();
    try std.testing.expectEqual(lifecycle.SessionState.closed, session.snapshot().state);
}

test "Agent Runtime creates and destroys an idle Session" {
    fake_core.reset();
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 2,
        .max_sessions = 2,
    });
    defer deinitTestComposition(runtime);
    const session = try openSession(runtime);
    try std.testing.expect(fake_core.credential_seen);
    try std.testing.expect(fake_core.zero_host_tools_seen);
    try std.testing.expect(fake_core.builtin_allowlist_seen);
    try std.testing.expectEqual(lifecycle.SessionState.idle, session.snapshot().state);
    try closeSession(session, .session_close);
    try closeSession(session, .session_close);
    try shutdownTestComposition(runtime);
    try shutdownTestComposition(runtime);
    try std.testing.expectEqual(@as(usize, 1), fake_core.runtime_created);
    try std.testing.expectEqual(@as(usize, 1), fake_core.runtime_destroyed);
    try std.testing.expectEqual(@as(usize, 1), fake_core.session_destroyed);
}

test "Workspace requires an absolute temporary or explicit trusted root" {
    fake_core.reset();
    const outside_temporary = if (std.fs.path.sep == '\\') "C:\\var\\not-temp" else "/var/not-temp";
    const temporary_root = if (std.fs.path.sep == '\\') "C:\\tmp" else "/tmp";
    const non_canonical = if (std.fs.path.sep == '\\') "C:\\tmp\\..\\etc" else "/tmp/../etc";
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    try std.testing.expectError(error.InvalidWorkspace, runtime.createSession(.{
        .provider = .anthropic,
        .permission_mode = .default,
        .shell_policy = .disabled,
        .credential = "fixture-secret",
        .model = "fixture-model",
        .workspace = .{ .canonical_root = "relative", .trust = .explicitly_trusted },
    }));
    try std.testing.expectError(error.WorkspaceNotTrusted, runtime.createSession(.{
        .provider = .anthropic,
        .permission_mode = .default,
        .shell_policy = .disabled,
        .credential = "fixture-secret",
        .model = "fixture-model",
        .workspace = .{
            .canonical_root = outside_temporary,
            .trust = .{ .temporary = temporary_root },
        },
    }));
    try std.testing.expectError(error.InvalidWorkspace, runtime.createSession(.{
        .provider = .anthropic,
        .permission_mode = .default,
        .shell_policy = .disabled,
        .credential = "fixture-secret",
        .model = "fixture-model",
        .workspace = .{
            .canonical_root = non_canonical,
            .trust = .{ .temporary = temporary_root },
        },
    }));
}

test "queued prompt memory is bounded before allocation" {
    fake_core.reset();
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
        .max_prompt_bytes = 4,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);
    try std.testing.expectError(error.PromptTooLarge, submitSession(session, "12345"));
    try std.testing.expectEqual(lifecycle.SessionState.idle, session.snapshot().state);
    try closeSession(session, .session_close);
}

test "pre-admission resource limit leaves the Session reusable" {
    fake_core.reset();
    fake_core.setNextPlan(.resource_limit);
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);
    const first_run = try submitSession(session, "exceed a Core resource limit");
    try session.waitRun(first_run);
    var first_terminal = takeTestTerminal(session, first_run);
    defer first_terminal.deinit();
    const first = session.snapshot();
    try std.testing.expectEqual(@as(?u32, wire.STATUS_RESOURCE_LIMIT), first_terminal.raw_status_code);
    try std.testing.expectEqual(@as(?lifecycle.TerminalFailure, .abi_status), first_terminal.failure);
    try std.testing.expectEqual(lifecycle.SessionDisposition.reusable, first_terminal.session_disposition_at_completion);
    try std.testing.expectEqualSlices(u8, &.{diagnostic_byte}, first_terminal.diagnostic());
    try std.testing.expect(!first_terminal.diagnostic_truncated);
    try std.testing.expectEqual(lifecycle.SessionState.idle, first.state);

    const second_run = try submitSession(session, "the Session remains admitted");
    try session.waitRun(second_run);
    try std.testing.expectEqual(lifecycle.SessionState.idle, session.snapshot().state);
    try closeSession(session, .session_close);
}

test "closing an active Run aborts, joins, and preserves the first termination signal" {
    fake_core.reset();
    fake_core.setNextPlan(.controlled_callback_failed);
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);
    const run_id = try submitSession(session, "race cancel with callback failure");
    try session.waitForState(.running);

    const cancel_thread = try std.Thread.spawn(.{}, cancelOnThread, .{ session, run_id });
    const failure_thread = try std.Thread.spawn(.{}, failPipelineOnThread, .{session});
    cancel_thread.join();
    failure_thread.join();
    try session.waitRun(run_id);

    var terminal = takeTestTerminal(session, run_id);
    defer terminal.deinit();
    const signal = terminal.termination_signal.?;
    try std.testing.expect(switch (signal) {
        .interrupted => |value| value == .user_cancel,
        .event_pump_failure => |value| value == .consumer_rejected,
        else => false,
    });
    try std.testing.expectEqual(@as(?u32, wire.STATUS_CALLBACK_FAILED), terminal.raw_status_code);
    session.recordTerminationSignal(.{ .interrupted = .timeout });
    try closeSession(session, .session_close);
    fake_core.lock();
    const abort_calls = fake_core.abort_calls;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), abort_calls);
}

test "malformed Core events fail the Run instead of entering the bounded sink" {
    fake_core.reset();
    fake_core.setNextPlan(.malformed_event_callback);
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);
    const run_id = try submitSession(session, "emit malformed event");
    try session.waitRun(run_id);
    var terminal = takeTestTerminal(session, run_id);
    defer terminal.deinit();
    const snapshot = session.snapshot();
    try std.testing.expectEqual(@as(?u32, wire.STATUS_CALLBACK_FAILED), terminal.raw_status_code);
    try std.testing.expectEqual(
        lifecycle.TerminationSignal{ .event_pump_failure = .invalid_event },
        terminal.termination_signal.?,
    );
    try std.testing.expectEqual(lifecycle.SessionState.poisoned, snapshot.state);
    try std.testing.expectError(error.SessionPoisoned, submitSession(session, "must not continue"));
    try std.testing.expect(runtime.takeEvent() == null);
    try closeSession(session, .session_close);
    fake_core.lock();
    const releases = fake_core.buffer_releases;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), releases);
}

test "RunContext identity violations fail closed and poison the Session" {
    fake_core.reset();
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 4,
        .event_capacity = 8,
        .per_session_event_capacity = 2,
        .control_reserved_capacity = 0,
        .per_session_control_reserved_capacity = 0,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }

    const plans = [_]Plan{
        .wrong_event_session_handle,
        .wrong_event_run_id,
        .same_run_session_id_mismatch,
        .concurrent_session_id_mismatch,
    };
    for (plans) |plan| {
        fake_core.setNextPlan(plan);
        const session = try openSession(runtime);
        const run_id = try submitSession(session, "reject invalid callback identity");
        try session.waitRun(run_id);
        var terminal = takeTestTerminal(session, run_id);
        defer terminal.deinit();
        try std.testing.expectEqual(
            @as(?u32, wire.STATUS_CALLBACK_FAILED),
            terminal.raw_status_code,
        );
        try std.testing.expectEqual(
            @as(?lifecycle.TerminalFailure, .dependency_contract),
            terminal.failure,
        );
        try std.testing.expectEqual(lifecycle.SessionState.poisoned, session.snapshot().state);
        try std.testing.expectError(
            error.SessionPoisoned,
            submitSession(session, "identity failure is permanent"),
        );
        try closeSession(session, .session_close);
    }
    while (runtime.takeEvent()) |event| {
        var owned = event;
        owned.deinit();
    }
}

test "RunContext session identity remains stable across Runs" {
    fake_core.reset();
    fake_core.setNextPlan(.cross_run_session_id_mismatch);
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
        .event_capacity = 2,
        .per_session_event_capacity = 2,
        .control_reserved_capacity = 0,
        .per_session_control_reserved_capacity = 0,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);

    const first_run = try submitSession(session, "bind Core session identity");
    try session.waitRun(first_run);
    var first_terminal = takeTestTerminal(session, first_run);
    defer first_terminal.deinit();
    try std.testing.expectEqual(@as(?u32, wire.STATUS_OK), first_terminal.raw_status_code);
    var first_event = runtime.takeEvent().?;
    first_event.deinit();

    const second_run = try submitSession(session, "reject changed Core session identity");
    try session.waitRun(second_run);
    var second_terminal = takeTestTerminal(session, second_run);
    defer second_terminal.deinit();
    try std.testing.expectEqual(
        @as(?u32, wire.STATUS_CALLBACK_FAILED),
        second_terminal.raw_status_code,
    );
    try std.testing.expectEqual(
        @as(?lifecycle.TerminalFailure, .dependency_contract),
        second_terminal.failure,
    );
    try std.testing.expectEqual(lifecycle.SessionState.poisoned, session.snapshot().state);
    try closeSession(session, .session_close);
}

test "valid unknown observations are ignored without consuming pump capacity" {
    fake_core.reset();
    fake_core.setNextPlan(.unknown_event_callback);
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
        .event_capacity = 1,
        .per_session_event_capacity = 1,
        .control_reserved_capacity = 0,
        .per_session_control_reserved_capacity = 0,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);
    const run_id = try submitSession(session, "emit a future observation");
    try session.waitRun(run_id);
    var terminal = takeTestTerminal(session, run_id);
    defer terminal.deinit();
    const snapshot = session.snapshot();
    try std.testing.expectEqual(@as(?u32, wire.STATUS_OK), terminal.raw_status_code);
    try std.testing.expectEqual(@as(?sdk.StopReason, .end_turn), terminal.stop_reason);
    try std.testing.expectEqual(lifecycle.SessionState.idle, snapshot.state);
    try std.testing.expect(runtime.takeEvent() == null);
    try closeSession(session, .session_close);
}

test "typed Core events are deep-copied into a bounded routed sink" {
    fake_core.reset();
    fake_core.setNextPlan(.event_callback);
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
        .event_capacity = 2,
        .per_session_event_capacity = 2,
        .control_reserved_capacity = 0,
        .per_session_control_reserved_capacity = 0,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);
    const first_run = try submitSession(session, "emit typed event");
    try session.waitRun(first_run);
    var first_terminal = takeTestTerminal(session, first_run);
    defer first_terminal.deinit();
    try std.testing.expectEqual(@as(?u32, wire.STATUS_OK), first_terminal.raw_status_code);
    try std.testing.expectEqual(@as(?u32, wire.STOP_END_TURN), first_terminal.raw_stop_reason_code);
    try std.testing.expectEqual(@as(?sdk.StopReason, .end_turn), first_terminal.stop_reason);

    const second_run = try submitSession(session, "preserve FIFO order");
    try session.waitRun(second_run);
    var second_terminal = takeTestTerminal(session, second_run);
    defer second_terminal.deinit();
    try std.testing.expectEqual(@as(?sdk.StopReason, .end_turn), second_terminal.stop_reason);

    var envelope = runtime.takeEvent().?;
    defer envelope.deinit();
    try std.testing.expect(envelope.session_id != 0);
    try std.testing.expectEqual(first_run, envelope.run_id);
    try std.testing.expectEqualStrings("{\"text_chunk\":\"typed event\"}", envelope.json);
    try std.testing.expectEqualStrings("typed event", try textChunk(envelope.event.value));
    var second = runtime.takeEvent().?;
    try std.testing.expectEqual(second_run, second.run_id);
    second.deinit();
    try closeSession(session, .session_close);
}

test "bounded event sink overflow returns callback fatal and preserves the pump failure" {
    fake_core.reset();
    fake_core.setNextPlan(.event_callback);
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
        .event_capacity = 1,
        .per_session_event_capacity = 1,
        .control_reserved_capacity = 0,
        .per_session_control_reserved_capacity = 0,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);
    const first_run = try submitSession(session, "retain first event");
    try session.waitRun(first_run);
    const second_run = try submitSession(session, "overflow sink");
    try session.waitRun(second_run);
    var terminal = takeTestTerminal(session, second_run);
    defer terminal.deinit();
    try std.testing.expectEqual(@as(?u32, wire.STATUS_CALLBACK_FAILED), terminal.raw_status_code);
    try std.testing.expectEqual(
        lifecycle.TerminationSignal{ .event_pump_failure = .capacity },
        terminal.termination_signal.?,
    );
    var retained = runtime.takeEvent().?;
    retained.deinit();
    try closeSession(session, .session_close);
}

test "UI request validates identity and close wakes a suspended callback" {
    fake_core.reset();
    fake_core.setNextPlan(.ui_wait);
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 3 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const answered = try openSession(runtime);
    const run_id = try submitSession(answered, "request UI");
    try answered.waitForState(.waiting_ui);
    const request_id = answered.pendingUiRequest().?;
    var pending = try answered.copyPendingUiRequest(std.testing.allocator);
    defer pending.deinit();
    try std.testing.expectEqual(run_id, pending.run_id);
    try std.testing.expectEqual(request_id, pending.request_id);
    var decoded = try sdk.decodeUiRequest(std.testing.allocator, pending.json);
    defer decoded.deinit();
    try std.testing.expectEqual(std.meta.Tag(sdk.UiRequest).permission, std.meta.activeTag(decoded.value));
    const response = sdk.UiResponse{ .permission = .allow_once };
    try std.testing.expectError(error.StaleUiResponse, answered.respondUi(run_id + 1, request_id, response));
    try std.testing.expectError(error.StaleUiResponse, answered.respondUi(run_id, request_id + 1, response));
    try std.testing.expectError(
        error.InvalidUiResponse,
        answered.respondUi(run_id, request_id, .{
            .answers = &.{.{ .values = &.{"Yes"} }},
        }),
    );
    try answered.respondUi(run_id, request_id, response);
    try std.testing.expectError(error.StaleUiResponse, answered.respondUi(run_id, request_id, response));
    fake_core.releaseControlled();
    try answered.waitRun(run_id);
    try closeSession(answered, .session_close);

    fake_core.setNextPlan(.ui_wait);
    const closing = try openSession(runtime);
    _ = try submitSession(closing, "close while UI waits");
    const closing_run = closing.snapshot().active_run_id;
    try closing.waitForState(.waiting_ui);
    try closeSession(closing, .session_close);
    var closing_terminal = takeTestTerminal(closing, closing_run);
    defer closing_terminal.deinit();
    const snapshot = closing.snapshot();
    try std.testing.expectEqual(lifecycle.SessionState.closed, snapshot.state);
    try std.testing.expectEqual(
        lifecycle.TerminationSignal{ .interrupted = .session_close },
        closing_terminal.termination_signal.?,
    );

    fake_core.setNextPlan(.ui_wait);
    const cancelled = try openSession(runtime);
    const cancelled_run = try submitSession(cancelled, "cancel while UI waits");
    try cancelled.waitForState(.waiting_ui);
    try cancelSession(cancelled, cancelled_run, .user_cancel);
    try cancelled.waitRun(cancelled_run);
    var cancelled_terminal = takeTestTerminal(cancelled, cancelled_run);
    defer cancelled_terminal.deinit();
    try std.testing.expectEqual(
        lifecycle.TerminationSignal{ .interrupted = .user_cancel },
        cancelled_terminal.termination_signal.?,
    );
    try closeSession(cancelled, .session_close);
}

test "Core identity failure discards an accepted UI permission response" {
    fake_core.reset();
    fake_core.setNextPlan(.ui_wait);
    var notifier = UiAnswerThenIdentityMismatch{};
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
        .event_ready_notifier = .{
            .context = &notifier,
            .notify_fn = UiAnswerThenIdentityMismatch.notify,
        },
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);
    notifier.session = session;

    const run_id = try submitSession(session, "reject permission after identity failure");
    try session.waitRun(run_id);
    var terminal = takeTestTerminal(session, run_id);
    defer terminal.deinit();

    try std.testing.expect(notifier.invoked);
    try std.testing.expect(!notifier.failed);
    try std.testing.expectEqual(@as(?u32, wire.EVENT_FATAL), notifier.mismatch_status);
    try std.testing.expectEqual(@as(?u32, wire.STATUS_CALLBACK_FAILED), terminal.raw_status_code);
    try std.testing.expectEqual(
        @as(?lifecycle.TerminalFailure, .dependency_contract),
        terminal.failure,
    );
    try std.testing.expectEqual(lifecycle.SessionState.poisoned, session.snapshot().state);
    try std.testing.expect(session.pendingUiRequest() == null);

    fake_core.lock();
    const answered_callbacks = fake_core.ui_answered_callbacks;
    const fatal_callbacks = fake_core.ui_fatal_callbacks;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 0), answered_callbacks);
    try std.testing.expectEqual(@as(usize, 1), fatal_callbacks);
    try std.testing.expectError(error.SessionPoisoned, submitSession(session, "must remain poisoned"));
    try closeSession(session, .session_close);
}

test "UI deadline returns unavailable and malformed UI fails the Run" {
    fake_core.reset();
    fake_core.setNextPlan(.ui_wait);
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 2,
        .ui_request_timeout = .fromMilliseconds(20),
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const timed_out = try openSession(runtime);
    const timeout_run = try submitSession(timed_out, "let UI expire");
    try timed_out.waitForState(.waiting_ui);
    try timed_out.waitForState(.running);
    try std.testing.expect(timed_out.pendingUiRequest() == null);
    fake_core.releaseControlled();
    try timed_out.waitRun(timeout_run);
    var timeout_terminal = takeTestTerminal(timed_out, timeout_run);
    defer timeout_terminal.deinit();
    try std.testing.expectEqual(@as(?sdk.StopReason, .end_turn), timeout_terminal.stop_reason);
    try closeSession(timed_out, .session_close);

    fake_core.setNextPlan(.malformed_ui_callback);
    const malformed = try openSession(runtime);
    const malformed_run = try submitSession(malformed, "malformed UI request");
    try malformed.waitRun(malformed_run);
    var malformed_terminal = takeTestTerminal(malformed, malformed_run);
    defer malformed_terminal.deinit();
    try std.testing.expectEqual(@as(?u32, wire.STATUS_CALLBACK_FAILED), malformed_terminal.raw_status_code);
    try std.testing.expectEqual(
        lifecycle.TerminationSignal{ .callback_failure = .ui },
        malformed_terminal.termination_signal.?,
    );
    try closeSession(malformed, .session_close);
}

test "UI notification failure is a typed fatal terminal signal" {
    fake_core.reset();
    fake_core.setNextPlan(.ui_wait);
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
        .event_ready_notifier = .{
            .context = null,
            .notify_fn = unavailableEventConsumer,
        },
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);
    const run_id = try submitSession(session, "notification cannot reach canonical consumer");
    try session.waitRun(run_id);
    var terminal = takeTestTerminal(session, run_id);
    defer terminal.deinit();
    try std.testing.expectEqual(@as(?u32, wire.STATUS_CALLBACK_FAILED), terminal.raw_status_code);
    try std.testing.expectEqual(
        lifecycle.TerminationSignal{
            .event_consumer_notification_failure = .unavailable,
        },
        terminal.termination_signal.?,
    );
    try closeSession(session, .session_close);
}

test "event notification deadline preserves the pump-owned event" {
    fake_core.reset();
    fake_core.setNextPlan(.event_callback);
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
        .event_ready_notifier = .{
            .context = null,
            .notify_fn = unavailableEventConsumer,
        },
        .event_ready_retry_interval = .fromNanoseconds(1),
        .event_ready_timeout = .fromNanoseconds(2),
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);
    const run_id = try submitSession(session, "notification deadline retains owned event");
    try session.waitRun(run_id);
    var terminal = takeTestTerminal(session, run_id);
    defer terminal.deinit();
    try std.testing.expectEqual(
        lifecycle.TerminationSignal{
            .event_consumer_notification_failure = .unavailable,
        },
        terminal.termination_signal.?,
    );
    var retained = runtime.takeEvent() orelse return error.ExpectedOwnedEvent;
    defer retained.deinit();
    try std.testing.expectEqual(session.id, retained.session_id);
    try std.testing.expectEqual(run_id, retained.run_id);
    try closeSession(session, .session_close);
}

test "UI response encoding is bounded before ownership transfer" {
    fake_core.reset();
    fake_core.setNextPlan(.ui_wait);
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
        .max_ui_response_bytes = 8,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);
    const run_id = try submitSession(session, "bound response");
    try session.waitForState(.waiting_ui);
    const request_id = session.pendingUiRequest().?;
    try std.testing.expectError(
        error.InvalidUiResponse,
        session.respondUi(run_id, request_id, .{ .permission = .allow_once }),
    );
    try std.testing.expectEqual(request_id, session.pendingUiRequest().?);
    try cancelSession(session, run_id, .user_cancel);
    try session.waitRun(run_id);
    var terminal = takeTestTerminal(session, run_id);
    defer terminal.deinit();
    try std.testing.expectEqual(
        lifecycle.TerminationSignal{ .interrupted = .user_cancel },
        terminal.termination_signal.?,
    );
    try closeSession(session, .session_close);
}

test "status is validated before RunResult and invalid results poison the Session" {
    fake_core.reset();
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 3 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }

    const cases = [_]struct {
        plan: Plan,
        expected_status: u32,
        expected_stop: ?u32,
    }{
        .{ .plan = .unknown_stop_result, .expected_status = wire.STATUS_OK, .expected_stop = 42 },
        .{ .plan = .invalid_result_layout, .expected_status = wire.STATUS_OK, .expected_stop = null },
        .{ .plan = .unknown_status, .expected_status = 42, .expected_stop = null },
    };
    for (cases) |case| {
        fake_core.setNextPlan(case.plan);
        const session = try openSession(runtime);
        const run_id = try submitSession(session, "validate result boundary");
        try session.waitRun(run_id);
        var terminal = takeTestTerminal(session, run_id);
        defer terminal.deinit();
        const snapshot = session.snapshot();
        try std.testing.expectEqual(@as(?u32, case.expected_status), terminal.raw_status_code);
        try std.testing.expectEqual(case.expected_stop, terminal.raw_stop_reason_code);
        try std.testing.expectEqual(
            @as(?lifecycle.TerminalFailure, .dependency_contract),
            terminal.failure,
        );
        try std.testing.expectEqual(lifecycle.SessionState.poisoned, snapshot.state);
        try std.testing.expectError(error.SessionPoisoned, submitSession(session, "must not continue"));
        try closeSession(session, .session_close);
    }
}

test "run epilogue waits for an active Core callback before poisoning" {
    fake_core.reset();
    var signal = CallbackSignal{};
    fake_core.setCallbackSignal(&signal);
    defer fake_core.setCallbackSignal(null);
    fake_core.setNextPlan(.ui_callback_outlives_run);
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
        .event_ready_notifier = .{
            .context = &signal,
            .notify_fn = CallbackSignal.notify,
        },
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);
    const run_id = try submitSession(session, "wait for callback quiescence");
    try session.waitRun(run_id);
    signal.waitUntilFinished();
    var terminal = takeTestTerminal(session, run_id);
    defer terminal.deinit();
    try std.testing.expectEqual(@as(?u32, wire.STATUS_OK), terminal.raw_status_code);
    try std.testing.expectEqual(
        @as(?lifecycle.TerminalFailure, .dependency_contract),
        terminal.failure,
    );
    try std.testing.expectEqual(lifecycle.SessionState.poisoned, session.snapshot().state);
    try closeSession(session, .session_close);

    fake_core.lock();
    const destroys = fake_core.session_destroyed;
    const answered_callbacks = fake_core.ui_answered_callbacks;
    const fatal_callbacks = fake_core.ui_fatal_callbacks;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), destroys);
    try std.testing.expectEqual(@as(usize, 0), answered_callbacks);
    try std.testing.expectEqual(@as(usize, 1), fatal_callbacks);
}

test "concurrent close waits for retained Session references and destroys once" {
    fake_core.reset();
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);
    try std.testing.expect(session.retainReference());
    const first = try std.Thread.spawn(.{}, closeOnThread, .{session});
    try session.waitForState(.closing);
    const second = try std.Thread.spawn(.{}, closeOnThread, .{session});

    fake_core.lock();
    const destroys_while_retained = fake_core.session_destroyed;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 0), destroys_while_retained);
    session.releaseReference();
    first.join();
    second.join();
    fake_core.lock();
    const final_destroy_count = fake_core.session_destroyed;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), final_destroy_count);
}

test "Runtime destroy while a Session is live returns busy without consuming ownership" {
    fake_core.reset();
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);
    var diagnostic_buffer = wire.OwnedBytesV1{ .ptr = null, .len = 0 };
    try std.testing.expectEqual(
        wire.STATUS_BUSY,
        runtimeDestroy(runtime.runtime, &diagnostic_buffer),
    );
    bufferRelease(&diagnostic_buffer);
    try closeSession(session, .session_close);
    try shutdownTestComposition(runtime);

    fake_core.lock();
    const busy_attempts = fake_core.runtime_destroy_busy_attempts;
    const runtime_destroyed = fake_core.runtime_destroyed;
    const releases = fake_core.buffer_releases;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), busy_attempts);
    try std.testing.expectEqual(@as(usize, 1), runtime_destroyed);
    try std.testing.expectEqual(@as(usize, 1), releases);
}

test "transient Session and Runtime destroy failures are explicit and retryable" {
    fake_core.reset();
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);
    fake_core.failNextSessionDestroy();
    try std.testing.expectError(error.SessionDestroyFailed, closeSession(session, .session_close));
    try std.testing.expectEqual(lifecycle.SessionState.closing, session.snapshot().state);
    try closeSession(session, .session_close);

    fake_core.failNextRuntimeDestroy();
    try std.testing.expectError(error.RuntimeDestroyFailed, shutdownTestComposition(runtime));
    try shutdownTestComposition(runtime);
    fake_core.lock();
    const releases = fake_core.buffer_releases;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 2), releases);
}

test "Core Session creation failure releases diagnostics and leaves capacity reusable" {
    fake_core.reset();
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    fake_core.failNextSessionCreate();
    try std.testing.expectError(error.CoreCallFailed, openSession(runtime));
    const session = try openSession(runtime);
    try closeSession(session, .session_close);
    fake_core.lock();
    const releases = fake_core.buffer_releases;
    const creates = fake_core.session_created;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), creates);
    try std.testing.expectEqual(@as(usize, 1), releases);
}

test "closed Session storage is reused only after explicit Runtime release" {
    fake_core.reset();
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const first = try openSession(runtime);
    try std.testing.expectError(error.SessionNotClosed, runtime.releaseClosedSession(first));
    try closeSession(first, .session_close);
    try std.testing.expectError(error.SessionCapacity, openSession(runtime));
    try runtime.releaseClosedSession(first);

    const second = try openSession(runtime);
    try closeSession(second, .session_close);
}

test "abort stale and too-late statuses remain observable without losing diagnostics" {
    fake_core.reset();
    fake_core.setNextPlan(.controlled);
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);

    const first = try submitSession(session, "too late");
    try session.waitForState(.running);
    try std.testing.expectError(error.NoSuchRun, cancelSession(session, first + 1, .user_cancel));
    fake_core.forceNextAbortStatus(wire.STATUS_TOO_LATE);
    try cancelSession(session, first, .user_cancel);
    try cancelSession(session, first, .user_cancel);
    fake_core.releaseControlled();
    try session.waitRun(first);
    var first_terminal = takeTestTerminal(session, first);
    defer first_terminal.deinit();
    try std.testing.expectEqual(@as(?u32, wire.STATUS_TOO_LATE), first_terminal.raw_abort_status_code);

    fake_core.rearmControlled();
    const second = try submitSession(session, "stale");
    try session.waitForState(.running);
    fake_core.forceNextAbortStatus(wire.STATUS_STALE_RUN);
    try cancelSession(session, second, .user_cancel);
    try cancelSession(session, second, .user_cancel);
    fake_core.releaseControlled();
    try session.waitRun(second);
    var second_terminal = takeTestTerminal(session, second);
    defer second_terminal.deinit();
    try std.testing.expectEqual(@as(?u32, wire.STATUS_STALE_RUN), second_terminal.raw_abort_status_code);

    fake_core.rearmControlled();
    const third = try submitSession(session, "timeout");
    try session.waitForState(.running);
    try cancelSession(session, third, .timeout);
    try session.waitRun(third);
    var timeout_terminal = takeTestTerminal(session, third);
    defer timeout_terminal.deinit();
    try std.testing.expectEqual(@as(?u32, wire.STATUS_OK), timeout_terminal.raw_abort_status_code);
    try std.testing.expectEqual(
        lifecycle.TerminationSignal{ .interrupted = .timeout },
        timeout_terminal.termination_signal.?,
    );
    try closeSession(session, .session_close);

    fake_core.lock();
    const releases = fake_core.buffer_releases;
    const abort_calls = fake_core.abort_calls;
    const last_abort_reason = fake_core.last_abort_reason;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 2), releases);
    try std.testing.expectEqual(@as(usize, 3), abort_calls);
    try std.testing.expectEqual(@as(?u32, wire.ABORT_TIMEOUT), last_abort_reason);
}

test "Agent Runtime initialization OOM fails before acquiring the Runtime" {
    fake_core.reset();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 3 });
    try std.testing.expectError(error.OutOfMemory, lifecycle.Runtime.initWithApi(
        std.testing.io,
        failing.allocator(),
        &fake_api,
        .{ .max_sessions = 1 },
    ));
    try std.testing.expect(failing.has_induced_failure);
    fake_core.lock();
    const runtime_created = fake_core.runtime_created;
    const runtime_destroyed = fake_core.runtime_destroyed;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 0), runtime_created);
    try std.testing.expectEqual(@as(usize, 0), runtime_destroyed);
}

test "Session creation OOM leaves Runtime reusable and credential process-only" {
    fake_core.reset();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const executor = try workbench_executor.Executor.create(
        std.testing.io,
        std.testing.allocator,
        .{ .worker_count = 1, .queue_capacity = 1 },
    );
    var executor_registered = false;
    errdefer if (!executor_registered) executor.deinit();
    const runtime = try lifecycle.Runtime.initWithApi(
        std.testing.io,
        failing.allocator(),
        &fake_api,
        .{ .max_sessions = 1 },
    );
    try registerTestComposition(runtime, executor);
    executor_registered = true;
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, openSession(runtime));
    try std.testing.expect(failing.has_induced_failure);
    failing.fail_index = std.math.maxInt(usize);
    const session = try openSession(runtime);
    const snapshot = session.snapshot();
    const expected_workspace = if (std.fs.path.sep == '\\') "C:\\tmp\\metawork-gate2" else "/tmp/metawork-gate2";
    try std.testing.expectEqualStrings(expected_workspace, snapshot.workspace_root);
    try std.testing.expect(fake_core.credential_seen);
    try closeSession(session, .session_close);
}
