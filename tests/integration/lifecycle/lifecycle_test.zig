const fixture = @import("lifecycle_fixture");
const std = fixture.std;
const lifecycle = fixture.lifecycle;
const wire = fixture.wire;
const fake_core = &fixture.fake_core;
const openSession = fixture.openSession;
const submitSession = fixture.submitSession;
const cancelSession = fixture.cancelSession;
const closeSession = fixture.closeSession;
const takeTestTerminal = fixture.takeTestTerminal;
const shutdownTestComposition = fixture.shutdownTestComposition;
const deinitTestComposition = fixture.deinitTestComposition;
const createTestComposition = fixture.createTestComposition;
const shutdownOnThread = fixture.shutdownOnThread;

test "all executor workers waiting on UI remain controllable" {
    fake_core.reset();
    const runtime = try createTestComposition(.{ .worker_count = 4, .queue_capacity = 4, .max_sessions = 4 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var sessions: [4]*lifecycle.Session = undefined;
    var run_ids: [4]u64 = undefined;
    for (&sessions, 0..) |*session, index| {
        fake_core.setNextPlan(.ui_wait);
        session.* = try openSession(runtime);
        run_ids[index] = try submitSession(session.*, "occupy executor with synchronous UI");
    }
    for (sessions) |session| try session.waitForState(.waiting_ui);

    const first_request = sessions[0].pendingUiRequest().?;
    try sessions[0].respondUi(run_ids[0], first_request, .{ .permission = .allow_once });
    try cancelSession(sessions[1], run_ids[1], .user_cancel);
    try closeSession(sessions[2], .session_close);
    fake_core.releaseControlled();
    try sessions[0].waitRun(run_ids[0]);
    try sessions[1].waitRun(run_ids[1]);
    try closeSession(sessions[0], .session_close);
    try closeSession(sessions[1], .session_close);

    try shutdownTestComposition(runtime);
    fake_core.lock();
    const destroyed = fake_core.session_destroyed;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 4), destroyed);
}

test "composition shutdown closes active queued and idle Sessions before Runtime" {
    fake_core.reset();
    fake_core.setNextPlan(.controlled);
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 2, .max_sessions = 3 });
    defer deinitTestComposition(runtime);
    const active = try openSession(runtime);
    const queued = try openSession(runtime);
    _ = try openSession(runtime);
    _ = try submitSession(active, "active");
    try active.waitForState(.running);
    _ = try submitSession(queued, "queued");

    try shutdownTestComposition(runtime);
    fake_core.lock();
    const session_destroyed = fake_core.session_destroyed;
    const runtime_destroyed = fake_core.runtime_destroyed;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 3), session_destroyed);
    try std.testing.expectEqual(@as(usize, 1), runtime_destroyed);
}

test "concurrent composition shutdown serializes executor and Runtime destruction" {
    fake_core.reset();
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 2 });
    const session = try openSession(runtime);
    const not_yet_closed = try openSession(runtime);
    try std.testing.expect(session.retainReference());
    const first = try std.Thread.spawn(.{}, shutdownOnThread, .{runtime});
    try session.waitForState(.closing);
    try std.testing.expectError(error.RuntimeShuttingDown, submitSession(not_yet_closed, "too late"));
    const second = try std.Thread.spawn(.{}, shutdownOnThread, .{runtime});
    std.Thread.yield() catch {};
    session.releaseReference();
    first.join();
    second.join();
    deinitTestComposition(runtime);

    fake_core.lock();
    const runtime_destroyed = fake_core.runtime_destroyed;
    const session_destroyed = fake_core.session_destroyed;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 2), session_destroyed);
    try std.testing.expectEqual(@as(usize, 1), runtime_destroyed);
}

test "post-callback canonical pipeline failure aborts the routed Run as failed" {
    fake_core.reset();
    fake_core.setNextPlan(.controlled);
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);
    const run_id = try submitSession(session, "fail after callback returned");
    try session.waitForState(.running);
    const session_id = session.snapshot().session_id;
    try runtime.requestRunTermination(
        session_id,
        run_id,
        .{ .event_pump_failure = .consumer_rejected },
    );
    try session.waitRun(run_id);
    var terminal = takeTestTerminal(session, run_id);
    defer terminal.deinit();
    try std.testing.expectEqual(
        lifecycle.TerminationSignal{ .event_pump_failure = .consumer_rejected },
        terminal.termination_signal.?,
    );
    try std.testing.expectEqual(@as(?u32, wire.STATUS_OK), terminal.raw_abort_status_code);
    try closeSession(session, .session_close);
}
