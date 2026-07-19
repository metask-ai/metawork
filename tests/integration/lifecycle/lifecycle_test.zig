const fixture = @import("lifecycle_fixture");
const std = fixture.std;
const lifecycle = fixture.lifecycle;
const event_pump = fixture.event_pump;
const automation_delivery = fixture.automation_delivery;
const wire = fixture.wire;
const pumpEnvelope = fixture.pumpEnvelope;
const ingestPumpEvent = fixture.ingestPumpEvent;
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

test "Agent event pump transfers inline and retained objects into automation delivery" {
    var pump = try event_pump.EventPump.init(std.testing.io, std.testing.allocator, .{
        .global_count = 8,
        .global_bytes = 4096,
        .global_control_reserved_count = 2,
        .global_control_reserved_bytes = 512,
        .per_session_count = 8,
        .per_session_bytes = 4096,
        .per_session_control_reserved_count = 2,
        .per_session_control_reserved_bytes = 512,
        .session_slots = 1,
    });
    defer pump.deinit();
    var delivery = try automation_delivery.Delivery.init(std.testing.allocator, .{
        .inline_event_bytes = 64,
        .batch_count = 4,
        .batch_bytes = 512,
        .batch_sessions = 1,
        .batch_per_session = 4,
        .retention_count = 8,
        .retention_bytes = 4096,
        .retention_ns = 100,
        .object_count = 2,
        .object_bytes = 2048,
        .per_session_object_count = 2,
        .per_session_object_bytes = 2048,
        .max_object_bytes = 1024,
        .route_slots = 1,
    });
    defer delivery.deinit();

    try pump.enqueue(try pumpEnvelope(1, 7, "{\"text_chunk\":\"small\"}"));
    const large =
        "{\"text_chunk\":\"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\"}";
    try pump.enqueue(try pumpEnvelope(1, 7, large));
    try ingestPumpEvent(&delivery, &pump);
    try ingestPumpEvent(&delivery, &pump);
    const first_generation = try delivery.connect();
    var first_batch = (try delivery.buildBatch(first_generation)).?;
    defer first_batch.deinit();
    try std.testing.expectEqual(@as(usize, 2), first_batch.item_count);
    try std.testing.expect(std.mem.indexOf(u8, first_batch.json, "\"generation\":\"1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_batch.json, "\"event\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_batch.json, "\"object\":{\"id\":\"1\"") != null);
    var fetch_buffer: [2048]u8 = undefined;
    try std.testing.expectError(
        error.UnknownObject,
        delivery.fetchObject(first_generation, 1, 7, 1, &fetch_buffer),
    );
    var uncommitted_retry = (try delivery.buildBatch(first_generation)).?;
    defer uncommitted_retry.deinit();
    try std.testing.expectEqual(@as(usize, 2), uncommitted_retry.item_count);
    try delivery.commitBatch(&first_batch);

    const fetched = try delivery.fetchObject(first_generation, 1, 7, 1, &fetch_buffer);
    try std.testing.expect(std.mem.indexOf(u8, fetched, large) != null);
    try delivery.acknowledge(first_generation, 1, 7, 1);
    try delivery.acknowledge(first_generation, 1, 7, 1);
    try std.testing.expectEqual(@as(usize, 1), delivery.stats().retained_count);
    try std.testing.expectError(
        error.OutOfOrderAcknowledgement,
        delivery.acknowledge(first_generation, 1, 7, 3),
    );
    try delivery.detach(first_generation, 10);
    const second_generation = try delivery.connect();
    try std.testing.expectError(
        error.StaleConnection,
        delivery.fetchObject(first_generation, 1, 7, 1, &fetch_buffer),
    );
    var replay = (try delivery.buildBatch(second_generation)).?;
    defer replay.deinit();
    try std.testing.expectEqual(@as(usize, 1), replay.item_count);
    try delivery.commitBatch(&replay);
    try std.testing.expect(delivery.firstExpired(100) == null);
    try delivery.detach(second_generation, 100);
    try std.testing.expect(delivery.firstExpired(199) == null);
    const expired = delivery.firstExpired(200).?;
    try std.testing.expectEqual(@as(u64, 1), expired.session_id);
    try std.testing.expectEqual(@as(u64, 7), expired.run_id);
    const third_generation = try delivery.connect();
    var final_replay = (try delivery.buildBatch(third_generation)).?;
    defer final_replay.deinit();
    try delivery.commitBatch(&final_replay);
    delivery.cleanupRun(1, 7);
    try std.testing.expectError(
        error.UnknownObject,
        delivery.fetchObject(third_generation, 1, 7, 1, &fetch_buffer),
    );
}

test "Gate 6 all executor workers waiting on UI remain controllable" {
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
