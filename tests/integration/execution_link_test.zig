//! The execution process, started for real.
//!
//! Everything here needs a second process, so none of it belongs in a unit
//! test: a spawn that fails, an identity exchange over inherited pipes, a
//! child that exits on end-of-stream, and a refusal that must leave no running
//! peer behind. A missing fixture fails the run rather than skipping it, for
//! the same reason the fault-capture fixture does: a silently skipped
//! cross-process test is indistinguishable from a passing one.

const std = @import("std");

const agent = @import("metawork_agent");
const contract = @import("metawork_agent_contract");
const execution_host = @import("app_execution_host");
const execution_link = @import("app_execution_link");
const execution_link_fixture = @import("execution_link_fixture");
const execution_mode = @import("app_execution_mode");
const agent_link = @import("metawork_agent_link");
const fault = @import("app_fault");
const product = @import("lifecycle_fixture");

/// The limits the fixture states. Each side enforces its own, so they need
/// not agree -- but a response larger than this half's bound is refused as a
/// protocol violation, so a test that drives real calls uses the same numbers
/// rather than a smaller guess.
const fixture_message_limits: agent_link.MessageLimits = .{
    .event = 1 << 20,
    .request = 1 << 20,
    .response = 1 << 20,
    .ui_request = 1 << 16,
    .ui_response = 1 << 16,
};

const io = std.testing.io;
const allocator = std.testing.allocator;

const matching_identity: agent_link.Identity = .{
    .version = "fixture-0",
    .core_manifest_sha256 = @splat('1'),
    .core_abi_revision = 28,
};

const fixture_variable = "METAWORK_EXECUTION_LINK_FIXTURE";
const fault_root_variable = "METAWORK_EXEC_LINK_FAULT_ROOT";

/// A missing fixture is a misconfigured build entry, never a reason to pass.
fn fixturePath() ![]u8 {
    return std.process.Environ.getAlloc(std.testing.environ, allocator, fixture_variable);
}

/// Stands in for the Application's event-ready coordinator. Counting the
/// wakes is the point: a wake is how the UI half learns there is something to
/// drain, so a test that reads events has to show one arrived.
const Wake = struct {
    count: std.atomic.Value(usize) = .init(0),

    fn notifier(self: *Wake) agent.EventReadyNotifier {
        return .{ .context = self, .notify_fn = notify };
    }

    fn notify(context: ?*anyopaque) agent.EventReadyNotification {
        const self: *Wake = @ptrCast(@alignCast(context.?));
        _ = self.count.fetchAdd(1, .monotonic);
        return .scheduled;
    }
};

/// How long a test waits for the far side to say something, in ticks of
/// `event_tick_ms`.
///
/// Generous: what is being waited for is a process starting a Run, not
/// anything whose timing a test controls. The point of the bound is not the
/// number -- it is that a far side which stopped answering fails here with a
/// sentence instead of running out the CI job's clock.
const event_wait_ticks: usize = 1_000;
const event_tick_ms: u64 = 10;

/// Waits until the execution half has reported an event.
///
/// The held Run announces itself with a `run_state` the moment it begins, so
/// this is the observable form of "the far side is inside `execute`" -- which
/// is a different fact from "the request was sent", and the only one worth
/// waiting for.
fn waitForEvent(runtime: agent.RuntimePort, what: []const u8) !void {
    var ticks: usize = 0;
    while (!runtime.hasPendingEvents()) : (ticks += 1) {
        if (ticks >= event_wait_ticks) {
            std.debug.print("no event from the execution half: {s}\n", .{what});
            return error.ExecutionHalfReportedNothing;
        }
        var tick: std.Io.Event = .unset;
        tick.waitTimeout(io, .{ .duration = .{
            .raw = .fromMilliseconds(event_tick_ms),
            .clock = .awake,
        } }) catch {};
    }
}

/// The exit a child that saw its link end and tidied up reports.
const exited_on_link_close: execution_host.Stopped = .{
    .exited = @intFromEnum(execution_mode.Exit.link_closed),
};

/// And the exit of one that could not finish tidying up and went anyway.
///
/// A separate code, which is why these tests can say which of the two
/// happened. While both were `link_closed`, a test asserting the child exited
/// could not tell the fix from the backstop that covers it -- and neither
/// could anyone reading a production exit.
const exited_on_deadline: execution_host.Stopped = .{
    .exited = @intFromEnum(execution_mode.Exit.cleanup_deadline),
};

test "the execution half starts, agrees on identity and exits on end of stream" {
    const fixture = try fixturePath();
    defer allocator.free(fixture);

    var host: execution_host.Host = undefined;
    const failure = try host.start(
        io,
        allocator,
        matching_identity,
        .{},
        .{ .explicit = &.{fixture} },
    );
    if (failure) |value| {
        std.debug.print("start failed: {any}\n", .{value});
        return error.StartFailed;
    }
    defer host.deinit();

    // The peer states the same four facts, and the role it claims is the one
    // the UI half expects rather than whatever it says it is.
    try std.testing.expectEqual(agent_link.Role.exec, host.peer.role);
    try std.testing.expectEqual(agent_link.revision, host.peer.revision);
    try std.testing.expectEqual(@as(u16, 28), host.peer.core_abi_revision);
    try std.testing.expectEqualStrings("fixture-0", host.peer.version());

    // Closing our end is the child's exit signal, so a clean stop needs no
    // kill and the child's own status comes back.
    const stopped = host.stop(null);
    try std.testing.expectEqual(
        execution_host.Stopped{ .exited = @intFromEnum(execution_mode.Exit.link_closed) },
        stopped,
    );
}

test "the execution half installs its own fault record, under its own name" {
    // The half the isolation exists to survive is the one whose crash record
    // matters, and until this ran `fault.install` happened after the fork in
    // `app.run` -- so the execution half had no handler at all. A unit test
    // can check the file names; only a real child can show that the install
    // succeeded in the process that has no window and no data root of its own.
    const fixture = try fixturePath();
    defer allocator.free(fixture);
    const root = try std.process.Environ.getAlloc(std.testing.environ, allocator, fault_root_variable);
    defer allocator.free(root);

    // The root outlives one run of the suite, so both names start absent --
    // otherwise the assertion below would be about what an earlier run left
    // rather than about what this child wrote.
    var exec_storage: [4096]u8 = undefined;
    const exec_record = try recordPath(&exec_storage, root, fault.recordFileName(.exec));
    var ui_storage: [4096]u8 = undefined;
    const ui_record = try recordPath(&ui_storage, root, fault.recordFileName(.ui));
    std.Io.Dir.deleteFileAbsolute(io, exec_record) catch {};
    std.Io.Dir.deleteFileAbsolute(io, ui_record) catch {};

    var host: execution_host.Host = undefined;
    const failure = try host.start(
        io,
        allocator,
        matching_identity,
        .{},
        .{ .explicit = &.{fixture} },
    );
    if (failure) |value| {
        std.debug.print("start failed: {any}\n", .{value});
        return error.StartFailed;
    }
    defer host.deinit();
    try std.testing.expectEqual(agent_link.Role.exec, host.peer.role);
    _ = host.stop(null);

    // The record file the execution role writes is there, and the one the UI
    // role writes is not: the role picks the file, so one half's later fault
    // cannot erase the other's evidence.
    const written = try std.Io.Dir.openFileAbsolute(io, exec_record, .{});
    written.close(io);
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.openFileAbsolute(io, ui_record, .{}),
    );
}

fn recordPath(storage: []u8, root: []const u8, name: []const u8) ![]const u8 {
    return std.fmt.bufPrint(storage, "{s}{c}{s}{c}{s}", .{
        root,
        std.fs.path.sep,
        fault.directory_name,
        std.fs.path.sep,
        name,
    });
}

test "a port call crosses the process, and the execution half's Runtime answers it" {
    // The first end-to-end call. Everything between Product's port and an
    // Agent Runtime in another process is on this path: the spawn, the
    // identity exchange, the caller's half encoding a request, the frame
    // queues, the execution half's reader queueing it, a worker dispatching
    // it against the one Runtime, the response coming back on its
    // correlation, and the stub handing Product a value. `restore_admission`
    // is the thinnest method that proves it -- a runtime method, so no
    // receiver has to exist yet, and an answer only the far side can give.
    const fixture = try fixturePath();
    defer allocator.free(fixture);

    var wake: Wake = .{};
    var supervisor: execution_link.Supervisor = undefined;
    const failure = try supervisor.start(io, allocator, .{
        .identity = matching_identity,
        .message_limits = fixture_message_limits,
        .spawn = .{ .explicit = &.{ fixture, execution_link_fixture.runtime_flag } },
        .tables = execution_link_fixture.fixture_tables,
        .wake = wake.notifier(),
    });
    if (failure) |value| {
        std.debug.print("start failed: {any}\n", .{value});
        return error.StartFailed;
    }
    defer supervisor.deinit();

    const runtime = supervisor.runtimePort();
    try std.testing.expectEqual(
        agent.RuntimePort.RestoreAdmission.available,
        runtime.restoreAdmission(null),
    );
    // Asked twice, because a stub that answered from its own side would
    // answer both the same way whatever the far side held -- and because the
    // correlation table has to hand back a second slot after the first
    // settled.
    try std.testing.expectEqual(
        agent.RuntimePort.RestoreAdmission.available,
        runtime.restoreAdmission(null),
    );

    // Nothing is owed afterwards: both correlations settled, and the link
    // never concluded anything was wrong with it.
    try std.testing.expectEqual(@as(usize, 0), supervisor.slots.liveCount());
    try std.testing.expectEqual(agent_link.client.LinkFault.none, supervisor.fault());

    const stopped = supervisor.stop();
    try std.testing.expectEqual(
        execution_host.Stopped{ .exited = @intFromEnum(execution_mode.Exit.link_closed) },
        stopped,
    );
}

test "a Session the far side's Runtime refuses answers in that method's own words" {
    // `create_session_route` is the first method whose result *puts something
    // into* the execution half's table, so it is the first one with a
    // reservation to get wrong. What this drives across a real process: the
    // request, the dispatcher taking a slot before the call, the real
    // AgentCore refusing these synthetic options, the refusal coming back as
    // the method's own error rather than as a link failure, and the promised
    // slot being given back.
    //
    // The refusal is the far side's, not a stand-in's. What is *not* covered
    // here is the success path: a Session AgentCore accepts needs options it
    // accepts, and the repository's own Session tests use a fake AgentCore
    // for exactly that reason -- a fake this fixture cannot link, because
    // `tests/support/lifecycle_fixture.zig` is written against `std.testing`
    // and does not compile into an executable.
    const fixture = try fixturePath();
    defer allocator.free(fixture);
    var workspace = std.testing.tmpDir(.{});
    defer workspace.cleanup();
    const root = try workspace.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    var wake: Wake = .{};
    var supervisor: execution_link.Supervisor = undefined;
    const failure = try supervisor.start(io, allocator, .{
        .identity = matching_identity,
        .message_limits = fixture_message_limits,
        .spawn = .{ .explicit = &.{ fixture, execution_link_fixture.runtime_flag } },
        .tables = execution_link_fixture.fixture_tables,
        .wake = wake.notifier(),
    });
    if (failure) |value| {
        std.debug.print("start failed: {any}\n", .{value});
        return error.StartFailed;
    }
    defer supervisor.deinit();

    const runtime = supervisor.runtimePort();
    const options: agent.SessionOpenOptions = .{
        .task_id = 41,
        .binding_epoch = 2,
        .model_binding = .{
            .target = .{
                .provider_id = "provider",
                .protocol = .anthropic_messages,
                .base_url = "https://example.invalid",
                .model = "model",
            },
            .credential = "secret",
        },
        .permission_mode = .default,
        .shell_policy = .disabled,
        .workspace = .{ .canonical_root = root, .trust = .{ .temporary = root } },
        .canonical_user_home = root,
        .workspace_epoch = "epoch",
    };

    // Three attempts against a two-slot table. If a refused create kept its
    // promised slot, the third would come back `SessionCapacity` from the
    // dispatcher instead -- so three identical answers is what shows the
    // reservation is released rather than spent.
    var attempt: usize = 0;
    while (attempt < 3) : (attempt += 1) {
        try std.testing.expectError(
            error.CoreCallFailed,
            runtime.createSessionRoute(options),
        );
    }

    // And the link itself never concluded anything was wrong with it: a
    // method's refusal is not a transport fault, which is the split the
    // caller's half exists to keep.
    try std.testing.expectEqual(agent_link.client.LinkFault.none, supervisor.fault());
    _ = supervisor.stop();
}

test "a Run executes in the other process, and its event arrives before its terminal" {
    // The vertical slice. A Session created in the execution process, a Run
    // prepared, begun and executed there, the event it produced carried back,
    // and the terminal arriving *after* that event -- which is the ordering
    // rule `method.zig` pins and the execution half keeps by flushing its
    // pump before every response. A terminal that overtook its events would
    // read, on this side, as a complete conversation with nothing in it.
    const fixture = try fixturePath();
    defer allocator.free(fixture);
    var workspace = std.testing.tmpDir(.{});
    defer workspace.cleanup();
    const root = try workspace.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    var wake: Wake = .{};
    var supervisor: execution_link.Supervisor = undefined;
    const failure = try supervisor.start(io, allocator, .{
        .identity = matching_identity,
        .message_limits = fixture_message_limits,
        // No drain thread, so the only thing that can carry an event is the
        // flush the execution half performs before every response. With the
        // thread running it wins the race on every machine I can test, and
        // the ordering rule would be held by luck as far as this test could
        // tell -- removing the race is what makes the rule observable.
        .spawn = .{ .explicit = &.{
            fixture,
            execution_link_fixture.runtime_flag,
            execution_link_fixture.fake_core_flag,
            execution_link_fixture.no_drain_flag,
        } },
        .tables = execution_link_fixture.fixture_tables,
        .wake = wake.notifier(),
    });
    if (failure) |value| {
        std.debug.print("start failed: {any}\n", .{value});
        return error.StartFailed;
    }
    defer supervisor.deinit();

    const runtime = supervisor.runtimePort();
    const route = runtime.createSessionRoute(.{
        .task_id = 41,
        .binding_epoch = 2,
        .model_binding = .{
            .target = .{
                .provider_id = "provider",
                .protocol = .anthropic_messages,
                .base_url = "https://example.invalid",
                .model = "model",
            },
            .credential = "secret",
        },
        .permission_mode = .default,
        .shell_policy = .disabled,
        .workspace = .{ .canonical_root = root, .trust = .{ .temporary = root } },
        .canonical_user_home = root,
        .workspace_epoch = "epoch",
    }) catch |err| {
        std.debug.print("create across the link: {s}\n", .{@errorName(err)});
        return err;
    };
    const session = route.session;

    // Nothing has been delivered yet, so a buffer that already held something
    // would mean this half invented it.
    try std.testing.expect(!runtime.hasPendingEvents());

    const run_id = session.prepareRun(.{ .text = "hello" }) catch |err| {
        std.debug.print("prepare across the link: {s}\n", .{@errorName(err)});
        return err;
    };
    try std.testing.expect(run_id != 0);

    var begun = switch (session.beginRunOutcome(run_id)) {
        .run => |value| value,
        .failure => |value| {
            std.debug.print("begin across the link: {any}\n", .{value.err});
            return error.BeginRefused;
        },
    };
    try std.testing.expectEqual(run_id, begun.run_id);

    // Blocks in the other process until the Run reaches a terminal, on a
    // thread of its own there -- which is what keeps a Stop able to arrive
    // while this is outstanding.
    const terminal = begun.execute();
    begun.deinit();

    // The ordering assertion. By the time the terminal is back, the event is
    // already here: both travelled the same ordered queue, and the execution
    // half flushes its pump before it answers.
    try std.testing.expect(runtime.hasPendingEvents());
    const pending_before = runtime.pendingEventCount(route.id);
    try std.testing.expect(pending_before > 0);

    // Drained the way Product drains, and counted: what the buffer said it
    // held is what it hands over, so the per-Session count is a fact about
    // this buffer rather than a guess.
    var drained: usize = 0;
    var saw_text = false;
    while (runtime.takeEvent()) |taken| {
        var event = taken;
        defer event.deinit();
        drained += 1;
        try std.testing.expectEqual(run_id, event.run_id);
        // The bytes are this side's copy of what the Agent produced over
        // there, parsed here with the Agent's own decoder.
        if (std.mem.indexOf(u8, event.json, "text_chunk") != null) saw_text = true;
    }
    try std.testing.expectEqual(pending_before, drained);
    try std.testing.expect(saw_text);
    try std.testing.expect(!runtime.hasPendingEvents());

    // And the wake came with it, which is how Product's consumer would have
    // been told there was something to drain.
    try std.testing.expect(wake.count.load(.acquire) > 0);

    // The terminal is the far side's, not a value this half could have made:
    // Core was invoked over there and reported a stop reason, and the Session
    // it ran in is still usable afterwards.
    try std.testing.expect(terminal.coreWasInvoked());
    try std.testing.expect(terminal.failure == null);
    try std.testing.expect(terminal.stop_reason != null);
    try std.testing.expectEqual(
        agent.SessionDisposition.reusable,
        terminal.session_disposition_at_completion,
    );
    // And nothing was lost on the way: the two flags that would say a
    // conversation is short are the ones a dropped event would set.
    try std.testing.expect(!terminal.event_delivery_lost);
    try std.testing.expect(!terminal.file_changes_lost);

    // Close it the way Product does, and the caller's names come back.
    switch (session.closeOutcome(.session_close)) {
        .closed => {},
        .failure => |value| {
            std.debug.print("close across the link: {any}\n", .{value.err});
            return error.CloseFailed;
        },
    }
    try runtime.releaseClosedSession(session);
    try std.testing.expectEqual(@as(usize, 0), supervisor.half.boxes.liveCount());
    try std.testing.expectEqual(agent_link.client.LinkFault.none, supervisor.fault());

    _ = supervisor.stop();
}

/// Executes a Run on a thread of its own, so the test can drive the link
/// while that call is outstanding -- which is the whole condition under test.
const Executing = struct {
    run: *contract.RunPort,
    done: std.Io.Event = .unset,
    signal: ?agent.TerminationSignal = null,
    reached: bool = false,

    fn main(self: *Executing) void {
        const terminal = self.run.execute();
        self.signal = terminal.termination_signal;
        self.reached = true;
        self.done.set(io);
    }
};

test "a Stop is answered while a Run is still executing in the other process" {
    // The deadlock the thread split prevents. `execute` blocks until its Run
    // reaches a terminal, and the Stop that ends it is an ordinary request on
    // the execution side -- so under one shared pool the Run occupies a
    // thread and the Stop queues behind the very call it is meant to end.
    // Product runs sixteen workers and each can be inside `execute`, so four
    // Runs were enough.
    //
    // The fixture runs with a single pool thread and holds every Run, which
    // makes one Run enough to prove it: with the split the blocking request
    // is on its own thread and the pool is free, and without it this test
    // does not return at all.
    const fixture = try fixturePath();
    defer allocator.free(fixture);
    var workspace = std.testing.tmpDir(.{});
    defer workspace.cleanup();
    const root = try workspace.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    var wake: Wake = .{};
    var supervisor: execution_link.Supervisor = undefined;
    const failure = try supervisor.start(io, allocator, .{
        .identity = matching_identity,
        .message_limits = fixture_message_limits,
        .spawn = .{ .explicit = &.{
            fixture,
            execution_link_fixture.runtime_flag,
            execution_link_fixture.fake_core_flag,
            execution_link_fixture.hold_runs_flag,
        } },
        .tables = execution_link_fixture.fixture_tables,
        .wake = wake.notifier(),
    });
    if (failure) |value| {
        std.debug.print("start failed: {any}\n", .{value});
        return error.StartFailed;
    }
    defer supervisor.deinit();

    const runtime = supervisor.runtimePort();
    const route = try runtime.createSessionRoute(.{
        .task_id = 42,
        .binding_epoch = 1,
        .model_binding = .{
            .target = .{
                .provider_id = "provider",
                .protocol = .anthropic_messages,
                .base_url = "https://example.invalid",
                .model = "model",
            },
            .credential = "secret",
        },
        .permission_mode = .default,
        .shell_policy = .disabled,
        .workspace = .{ .canonical_root = root, .trust = .{ .temporary = root } },
        .canonical_user_home = root,
        .workspace_epoch = "epoch",
    });
    const session = route.session;

    const run_id = try session.prepareRun(.{ .text = "hold" });
    var begun = switch (session.beginRunOutcome(run_id)) {
        .run => |value| value,
        .failure => |value| {
            std.debug.print("begin across the link: {any}\n", .{value.err});
            return error.BeginRefused;
        },
    };

    var executing: Executing = .{ .run = &begun };
    var thread = try std.Thread.spawn(.{}, Executing.main, .{&executing});

    // Wait until the Run has *started* over there, not merely until its
    // request was sent. Without this the Stop usually goes out first and the
    // test proves nothing: a Stop that arrives before `execute` is answered
    // by a free thread whatever the design. The held Run announces itself
    // with a `run_state` event, and that event arriving is the proof that the
    // far side is inside `execute` with the call outstanding.
    try waitForEvent(runtime, "the held Run never started");

    // The Stop travels on the control transport, which is what lets it
    // overtake queued fragments -- and it has to be *answered*, which is what
    // needs a thread that is not the one inside `execute`.
    try runtime.requestRunTermination(
        run_id,
        begun.generation,
        .{ .interrupted = .user_cancel },
    );

    // Answered, so the Run ends: the far side's abort releases the held Run
    // and `execute` returns on its own thread.
    executing.done.wait(io) catch |err| return err;
    thread.join();
    begun.deinit();

    // The terminal carries the interruption, and that is what makes this a
    // test of the split rather than of a Run that happened to finish before
    // the Stop arrived: a Run nobody stopped reaches its terminal with no
    // signal at all. So this assertion says three things at once -- the Run
    // was still running, the Stop was delivered while it was, and answering
    // it is what ended the Run.
    try std.testing.expect(executing.reached);
    const signal = executing.signal orelse return error.RunWasNotStopped;
    try std.testing.expectEqual(
        agent.ExternalInterruption.user_cancel,
        signal.interrupted,
    );

    try std.testing.expectEqual(agent_link.client.LinkFault.none, supervisor.fault());

    // The Session is still open and the Run still named, which is the state a
    // UI that exited mid-Run leaves -- and the child has to *exit* on it
    // rather than trip an assertion on the way out. Its status is the whole
    // assertion: a panicking child is how this test passed while proving
    // nothing, before the status was checked.
    try std.testing.expectEqual(exited_on_link_close, supervisor.stop());
}

test "a reference the caller never gave back does not keep this half alive" {
    // The leak the first Product Run over a real link died of, and the only
    // crossing that could leak this way. Every other thing the link hands
    // out is a name in a table, so a link that ends can give it back;
    // `retain_reference` moves a number on a Session and names no holder, so
    // a caller that took one and then died left `Session.close` waiting out
    // a reference nobody would ever return. The process stayed alive after
    // its link died -- holding the pipe it had inherited, which is how it
    // took a build runner down with it.
    //
    // The ordinary deadline, because the deadline's exit has a code of its
    // own: a close that waits for good still ends the process, but it ends it
    // as `cleanup_deadline`, so this test cannot pass on the backstop
    // instead of on the fix.
    const fixture = try fixturePath();
    defer allocator.free(fixture);
    var workspace = std.testing.tmpDir(.{});
    defer workspace.cleanup();
    const root = try workspace.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    var wake: Wake = .{};
    var supervisor: execution_link.Supervisor = undefined;
    const failure = try supervisor.start(io, allocator, .{
        .identity = matching_identity,
        .message_limits = fixture_message_limits,
        .spawn = .{ .explicit = &.{
            fixture,
            execution_link_fixture.runtime_flag,
            execution_link_fixture.fake_core_flag,
        } },
        .tables = execution_link_fixture.fixture_tables,
        .wake = wake.notifier(),
    });
    if (failure) |value| {
        std.debug.print("start failed: {any}\n", .{value});
        return error.StartFailed;
    }
    defer supervisor.deinit();

    const runtime = supervisor.runtimePort();
    const route = try runtime.createSessionRoute(.{
        .task_id = 42,
        .binding_epoch = 1,
        .model_binding = .{
            .target = .{
                .provider_id = "provider",
                .protocol = .anthropic_messages,
                .base_url = "https://example.invalid",
                .model = "model",
            },
            .credential = "secret",
        },
        .permission_mode = .default,
        .shell_policy = .disabled,
        .workspace = .{ .canonical_root = root, .trust = .{ .temporary = root } },
        .canonical_user_home = root,
        .workspace_epoch = "epoch",
    });

    // What Product's own Session access does before every call it makes, and
    // the reason this is reachable at all: `acquireAccess` retains, the
    // `defer` releases, and a process that aborts between them runs no
    // `defer` at all.
    try std.testing.expect(route.session.retainReference());

    // No goodbye and no release: the caller is simply gone, holding a
    // reference the far side is counting.
    execution_link.TestSupport.abandonLink(&supervisor);

    // Exits *cleanly* by itself, which it can only do if this half gave the
    // reference back on the way out. Without that it waits in
    // `Session.close` until the deadline and comes back `cleanup_deadline`.
    try std.testing.expectEqual(exited_on_link_close, supervisor.stop());
}

test "cleanup that does not finish costs this half its deadline, not its exit" {
    // The bound itself, with the leak taken out of it. The fixture's Runtime
    // refuses to be destroyed, which is the shape of the hang without being
    // the one instance of it -- a bound that only survives the leak it was
    // found through is not a bound, and the wait that hung this half was four
    // frames below the only join anybody would have thought to put a timeout
    // on.
    //
    // The deadline here is the ordinary one, so it falls well inside the UI
    // half's grace period: the child decides to go before the UI gives up on
    // it, and the stop sees a process that exited rather than one it killed
    // -- with the code that says it went on the deadline, which is the whole
    // of what this test claims.
    const fixture = try fixturePath();
    defer allocator.free(fixture);

    var wake: Wake = .{};
    var supervisor: execution_link.Supervisor = undefined;
    const failure = try supervisor.start(io, allocator, .{
        .identity = matching_identity,
        .message_limits = fixture_message_limits,
        .spawn = .{ .explicit = &.{
            fixture,
            execution_link_fixture.runtime_flag,
            execution_link_fixture.fake_core_flag,
            execution_link_fixture.hang_cleanup_flag,
        } },
        .tables = execution_link_fixture.fixture_tables,
        .wake = wake.notifier(),
    });
    if (failure) |value| {
        std.debug.print("start failed: {any}\n", .{value});
        return error.StartFailed;
    }
    defer supervisor.deinit();

    execution_link.TestSupport.abandonLink(&supervisor);
    try std.testing.expectEqual(exited_on_deadline, supervisor.stop());
}

test "the deadline's exit runs none of the C runtime's exit handlers" {
    // The deadline fires in exactly one state: a thread of this process is
    // stuck somewhere it will not come back from. An ordinary exit runs
    // `atexit` handlers and C++ static destructors before it goes, so on that
    // path those run beside live threads and under whatever locks they hold
    // -- a crash on the way out, or a second hang in a handler, which is the
    // hang the deadline exists to end.
    //
    // So the fixture registers a handler that never returns and refuses to
    // finish its cleanup, which is the pairing that matters: without the
    // hang the half tidies up and leaves through `main`, where running those
    // handlers is the correct thing to do.
    //
    // Without libc there is nothing to register, and nothing was ever at
    // risk: this then asserts the same exit for a plainer reason.
    const fixture = try fixturePath();
    defer allocator.free(fixture);

    var wake: Wake = .{};
    var supervisor: execution_link.Supervisor = undefined;
    const failure = try supervisor.start(io, allocator, .{
        .identity = matching_identity,
        .message_limits = fixture_message_limits,
        .spawn = .{ .explicit = &.{
            fixture,
            execution_link_fixture.runtime_flag,
            execution_link_fixture.fake_core_flag,
            execution_link_fixture.hang_cleanup_flag,
            execution_link_fixture.wedge_at_exit_flag,
        } },
        .tables = execution_link_fixture.fixture_tables,
        .wake = wake.notifier(),
    });
    if (failure) |value| {
        std.debug.print("start failed: {any}\n", .{value});
        return error.StartFailed;
    }
    defer supervisor.deinit();

    execution_link.TestSupport.abandonLink(&supervisor);
    try std.testing.expectEqual(exited_on_deadline, supervisor.stop());
}

test "a Run still executing does not keep this half alive either" {
    // The other shape, and the one the isolation is actually for: a worker
    // inside `execute`, which returns when its Run reaches a terminal and
    // never otherwise. The held Run has nothing left to end it once the link
    // is gone, so the join that waits for that thread waits for good -- and
    // the exit deadline is the whole of what gets the process out of it.
    const fixture = try fixturePath();
    defer allocator.free(fixture);
    var workspace = std.testing.tmpDir(.{});
    defer workspace.cleanup();
    const root = try workspace.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    var wake: Wake = .{};
    var supervisor: execution_link.Supervisor = undefined;
    const failure = try supervisor.start(io, allocator, .{
        .identity = matching_identity,
        .message_limits = fixture_message_limits,
        .spawn = .{ .explicit = &.{
            fixture,
            execution_link_fixture.runtime_flag,
            execution_link_fixture.fake_core_flag,
            execution_link_fixture.hold_runs_flag,
        } },
        .tables = execution_link_fixture.fixture_tables,
        .wake = wake.notifier(),
    });
    if (failure) |value| {
        std.debug.print("start failed: {any}\n", .{value});
        return error.StartFailed;
    }
    defer supervisor.deinit();

    const runtime = supervisor.runtimePort();
    const route = try runtime.createSessionRoute(.{
        .task_id = 42,
        .binding_epoch = 1,
        .model_binding = .{
            .target = .{
                .provider_id = "provider",
                .protocol = .anthropic_messages,
                .base_url = "https://example.invalid",
                .model = "model",
            },
            .credential = "secret",
        },
        .permission_mode = .default,
        .shell_policy = .disabled,
        .workspace = .{ .canonical_root = root, .trust = .{ .temporary = root } },
        .canonical_user_home = root,
        .workspace_epoch = "epoch",
    });
    const session = route.session;

    const run_id = try session.prepareRun(.{ .text = "hold" });
    var begun = switch (session.beginRunOutcome(run_id)) {
        .run => |value| value,
        .failure => |value| {
            std.debug.print("begin across the link: {any}\n", .{value.err});
            return error.BeginRefused;
        },
    };

    var executing: Executing = .{ .run = &begun };
    var thread = try std.Thread.spawn(.{}, Executing.main, .{&executing});
    try waitForEvent(runtime, "the held Run never started");

    execution_link.TestSupport.abandonLink(&supervisor);

    // The stop before the join, and the order is the test's shape rather
    // than a convenience. Abandoning the link closes our write end and
    // nothing else, so the child is still alive with its output open and the
    // reader sees no end-of-stream -- which leaves our own caller waiting on
    // a correlation that will never be answered. `stop` is what answers it:
    // it closes the table first, for this case. Joining before stopping
    // makes a regression here a test that hangs instead of one that fails,
    // and a hang on CI is a job timeout with nothing in it to read.
    const stopped = supervisor.stop();

    executing.done.wait(io) catch |err| return err;
    thread.join();
    begun.deinit();

    // With a worker still inside `execute` over there, the child went on its
    // deadline rather than waiting for a Run nobody can end any more -- and
    // says so, which is what makes the cost of an in-flight Run a fact
    // somebody can read rather than a clean exit two seconds late.
    try std.testing.expectEqual(exited_on_deadline, stopped);
}

test "Product submits a Task and its Run reaches a terminal in the other process" {
    // The whole of the caller's half, driven by the thing it exists for.
    // Everything above this exercises one call or one failure; this submits a
    // Task the way the application does and asks for the Run's terminal --
    // route creation, the skill catalog, the Task's own queue, prepare,
    // begin, execute, the events, and the terminal, each crossing a real
    // process boundary.
    //
    // What it does not prove is the reference leak. Product tears itself
    // down below before the link is stopped, so it returns its own leases --
    // and if it did not, `drainEverything` would return them when the link
    // ended. The leak has a test of its own, where the caller is gone before
    // anything can tidy up.
    //
    // Product here is composed without the image, video, delivery or MCP
    // effects, which is what makes the Run's four tool capabilities absent
    // and the prepare answerable. A Task that wants one of them is refused by
    // `stubs.sessionPrepareRunWithTools` until the MCP step and the two
    // capability steps beside it land; the application always composes the
    // MCP input, so in link mode that refusal is what a real Run meets today.
    const fixture = try fixturePath();
    defer allocator.free(fixture);

    var wake: Wake = .{};
    var supervisor: execution_link.Supervisor = undefined;
    const failure = try supervisor.start(io, allocator, .{
        .identity = matching_identity,
        .message_limits = fixture_message_limits,
        .spawn = .{ .explicit = &.{
            fixture,
            execution_link_fixture.runtime_flag,
            execution_link_fixture.fake_core_flag,
        } },
        .tables = execution_link_fixture.fixture_tables,
        .wake = wake.notifier(),
    });
    if (failure) |value| {
        std.debug.print("start failed: {any}\n", .{value});
        return error.StartFailed;
    }
    defer supervisor.deinit();

    // Product in a scope of its own, so it is torn down *before* the link
    // is stopped. That order is the application's too -- the UI closes its
    // Tasks and then stops the child -- and it is not optional: closing a
    // Session is a call, so a Product torn down after the link is gone gets
    // the restricting answer and panics on a close it cannot complete.
    {
        var control = try product.product_control.Runtime.init(allocator, io, supervisor.runtimePort(), .{
            .worker_count = 1,
            .queue_capacity = 1,
            .max_tasks = 1,
            .max_runs_per_task = 1,
            .max_tools_per_run = 1,
        }, product.productControlConfiguration());
        defer control.deinit();
        try product.installProductControlExecution(&control);

        const task_id = try control.createTask(
            product.productControlTaskInput(),
            try product.product_control.TestSupport.fixtureModelSelection(&control),
        );
        try product.waitInitialTaskCatalog(&control, task_id);
        try product.settleWorkspaceSkillQueries(&control, try control.taskWorkspaceId(task_id));
        _ = try product.runPreparedTask(&control, task_id, .{ .text = "Say something short" });

        // The terminal, read off the aggregate Product publishes rather than
        // from the port: what this test is about is the whole path, and the
        // aggregate is where that path ends.
        try product.waitProductControlSnapshot(&control, "\"terminal\":{\"outcome\":\"completed\"");

        try std.testing.expectEqual(agent_link.client.LinkFault.none, supervisor.fault());
        // The events came back through the notifier, which is the half of the
        // stream a terminal alone would not prove.
        try std.testing.expect(wake.count.load(.acquire) > 0);
    }

    // A clean exit, not one on the deadline: Product tore down over a live
    // link, so nothing was left for the deadline to cut short.
    try std.testing.expectEqual(exited_on_link_close, supervisor.stop());
}

test "an execution process that dies under a live Task does not take Product with it" {
    // Issue 197, from the half it is for. A fatal fault on an AgentCore path
    // ends the execution process while Product is holding a Task, a Session
    // and a Run that is executing -- and what has to survive that is the
    // window.
    //
    // It did not. Every one of these paths treated a Session close as a thing
    // that cannot fail, because in process it cannot: `deinitCreateCandidate`
    // and the attachment release both panicked on a close that came back a
    // failure. Over the link the failure is ordinary -- the Session's process
    // is gone -- so the first Task detached after a crash ended the UI
    // process too, which is the whole of what the isolation was supposed to
    // prevent.
    //
    // The Run ends interrupted, which is the half of the disconnect
    // behaviour that needs nothing new: the Session is gone, so the stub's
    // answer for a lost `execute` is a `session_close` interruption, and
    // Product's own classifier turns that into the interrupted phase. What is
    // still missing is what happens next -- a respawn, and the next message
    // resuming from the checkpoint -- because both need the checkpoint path
    // and a fact that outlives the call that discovered the loss.
    const fixture = try fixturePath();
    defer allocator.free(fixture);

    var wake: Wake = .{};
    var supervisor: execution_link.Supervisor = undefined;
    const failure = try supervisor.start(io, allocator, .{
        .identity = matching_identity,
        .message_limits = fixture_message_limits,
        .spawn = .{ .explicit = &.{
            fixture,
            execution_link_fixture.runtime_flag,
            execution_link_fixture.fake_core_flag,
            execution_link_fixture.hold_runs_flag,
        } },
        .tables = execution_link_fixture.fixture_tables,
        .wake = wake.notifier(),
    });
    if (failure) |value| {
        std.debug.print("start failed: {any}\n", .{value});
        return error.StartFailed;
    }
    defer supervisor.deinit();

    {
        var control = try product.product_control.Runtime.init(allocator, io, supervisor.runtimePort(), .{
            .worker_count = 1,
            .queue_capacity = 1,
            .max_tasks = 1,
            // Two, because one of this test's operations after the crash is
            // trying to run the Task again.
            .max_runs_per_task = 2,
            .max_tools_per_run = 1,
        }, product.productControlConfiguration());
        // The teardown that used to end the process: releasing the Task's
        // attachment closes a Session whose Runtime is in a process that no
        // longer exists.
        defer control.deinit();
        try product.installProductControlExecution(&control);

        const task_id = try control.createTask(
            product.productControlTaskInput(),
            try product.product_control.TestSupport.fixtureModelSelection(&control),
        );
        try product.waitInitialTaskCatalog(&control, task_id);
        try product.settleWorkspaceSkillQueries(&control, try control.taskWorkspaceId(task_id));
        _ = try product.runPreparedTask(&control, task_id, .{ .text = "Say something short" });

        // The held Run announces itself the moment it begins, so this is the
        // observable form of "a worker is inside `execute` over there" --
        // which is the state the crash has to be survived *in*, and not the
        // same fact as "the request was sent".
        try waitForEvent(supervisor.runtimePort(), "the held Run never started");

        execution_link.TestSupport.killChild(&supervisor);

        // Product's own worker is waiting on that `execute`. The reader
        // thread reads end-of-stream, closes the table and answers it, so the
        // Run reaches a terminal with nothing crossing the link -- and the
        // terminal says it was interrupted, not that it failed. The
        // difference is the one a user acts on: a failed Run is over, and an
        // interrupted one is a conversation to carry on.
        try product.waitProductControlSnapshot(&control, "\"outcome\":\"interrupted\"");

        // And here is what this side knows about it: nothing.
        //
        // `LinkFault` is about this half's own failures to carry something --
        // a refused send, a full correlation table, dropped events. A peer
        // that died is end-of-stream, which is also how a peer that was told
        // to stop ends, so there is no fault to read and no signal anywhere
        // that says "the process serving this is gone". That is the gap the
        // UI side of the disconnect work has to fill, and asserting it here
        // rather than describing it means the day a signal exists, this line
        // is where somebody is told to come and use it.
        try std.testing.expectEqual(agent_link.client.LinkFault.none, supervisor.fault());

        // An ordinary operation afterwards. What matters is that it returns:
        // submitting into a Task whose execution process is gone is a
        // refusal, and a refusal is something Product can show.
        _ = product.runPreparedTask(&control, task_id, .{ .text = "Again" }) catch {};

        // Still none, after a call that did reach the link. The writer
        // thread failed on the closed pipe and marked the queue failed, and a
        // failed queue answers `.closed` -- which `client.zig` turns into
        // `error.Unreachable` and deliberately records no fault for, because
        // a link that has ended is not a link that mishandled something.
        //
        // So the whole of what this side has is a per-call error. Nothing
        // holds "the process behind this Task is gone", which is why there is
        // no respawn and no resume: those need a fact that outlives the call
        // that discovered it.
        try std.testing.expectEqual(agent_link.client.LinkFault.none, supervisor.fault());

        // And a read, which is what the Renderer does constantly.
        _ = try control.taskCatalog(task_id);
    }

    // Already dead, so this only reaps. Its value is not the claim here --
    // on Windows a terminated child reports the exit code the kill passed,
    // and which of the two shapes that is says nothing about Product.
    _ = supervisor.stop();
}

test "a start that refuses leaves no child running and nothing allocated" {
    // `StartFailure` is a return value and not an error, so `errdefer` never
    // fired for it: two of these paths left the child process running and
    // four objects allocated while the doc comment above `start` said the
    // opposite. Invalid message limits is the reachable one of the two -- the
    // other is a thread that will not spawn -- and it is reached after the
    // child is already up, which is what makes it the interesting one.
    //
    // The leak half of the assertion is the test allocator's: it fails this
    // test at the end if anything `start` took is still held.
    const fixture = try fixturePath();
    defer allocator.free(fixture);

    var wake: Wake = .{};
    var supervisor: execution_link.Supervisor = undefined;
    const failure = try supervisor.start(io, allocator, .{
        .identity = matching_identity,
        // Zero is not a size any kind may have, which `MessageLimits.valid`
        // refuses -- and the limits are the composition root's own constants,
        // so refusing is right: it is a wiring mistake, not a condition.
        .message_limits = .{
            .event = 0,
            .request = 1 << 20,
            .response = 1 << 20,
            .ui_request = 1 << 16,
            .ui_response = 1 << 16,
        },
        .spawn = .{ .explicit = &.{fixture} },
        .tables = execution_link_fixture.fixture_tables,
        .wake = wake.notifier(),
    });
    try std.testing.expectEqual(execution_host.StartFailure.resource_unavailable, failure.?);

    // No `deinit`: a refused start has nothing to tear down, which is the
    // claim. Calling it would hide the leak this test exists to catch.
}

test "a child that will not stop is killed, and the stop returns" {
    // The kill is the only reason the grace period exists, and it was the one
    // path that could not reach it: the reader thread was joined *before* the
    // wait, and that thread ends when the child's output closes -- which
    // happens when the child exits. So a child that would not exit, which is
    // exactly what the kill is for, hung the UI thread instead of being
    // killed. The real shape is a worker inside `run.execute`; the fixture
    // reproduces the observable part by staying alive after the link ends.
    const fixture = try fixturePath();
    defer allocator.free(fixture);

    var wake: Wake = .{};
    var supervisor: execution_link.Supervisor = undefined;
    const failure = try supervisor.start(io, allocator, .{
        .identity = matching_identity,
        .message_limits = fixture_message_limits,
        .spawn = .{ .explicit = &.{ fixture, execution_link_fixture.wedge_flag } },
        .tables = execution_link_fixture.fixture_tables,
        .wake = wake.notifier(),
    });
    if (failure) |value| {
        std.debug.print("start failed: {any}\n", .{value});
        return error.StartFailed;
    }
    defer supervisor.deinit();

    // Returns at all, which is the assertion -- and says the child was
    // killed rather than having exited on its own. The fixture outlives the
    // grace period by two orders of magnitude, so a stop that waited for it
    // would not reach this line within any timeout the suite has.
    //
    // The fixture runs with its exit deadline disarmed, because with the
    // deadline on there is no such child: it exits on the deadline and the
    // stop sees `.exited`. That is the point of the deadline and not a gap
    // in this test -- what this one still covers is the kill, which has to
    // keep working for the children the deadline cannot reach.
    const stopped = supervisor.stop();
    try std.testing.expectEqual(execution_host.Stopped.killed, stopped);
}

test "a peer built from other sources is refused, and does not keep running" {
    const fixture = try fixturePath();
    defer allocator.free(fixture);

    var host: execution_host.Host = undefined;
    var skewed = matching_identity;
    skewed.version = "0.0.0-other";
    const failure = try host.start(
        io,
        allocator,
        skewed,
        .{},
        .{ .explicit = &.{fixture} },
    );
    const value = failure orelse {
        _ = host.stop(null);
        host.deinit();
        return error.ExpectedRefusal;
    };
    // The field that differs is named, and nothing is negotiated around it.
    try std.testing.expectEqual(
        execution_host.StartFailure{ .refused = .{ .refused = .product_version } },
        value,
    );
    // `start` kills the child on a refused identity, so there is nothing left
    // holding the pipes. A second refusal in a row must behave identically.
    const again = try host.start(
        io,
        allocator,
        skewed,
        .{},
        .{ .explicit = &.{fixture} },
    );
    try std.testing.expect(again != null);
}

test "an executable that is not there is a start failure, not a hang" {
    var host: execution_host.Host = undefined;
    const failure = try host.start(
        io,
        allocator,
        matching_identity,
        .{},
        .{ .explicit = &.{"metawork-no-such-execution-half"} },
    );
    try std.testing.expectEqual(
        execution_host.StartFailure.spawn_failed,
        failure orelse return error.ExpectedFailure,
    );
}

test "the child refuses us too, rather than serving a peer it cannot match" {
    // The same skew seen from the other side: the fixture states a version the
    // UI half does not have, so the fixture's own comparison fails and it
    // exits with its identity-refused code instead of serving frames.
    const fixture = try fixturePath();
    defer allocator.free(fixture);

    var child = try std.process.spawn(io, .{
        .argv = &.{fixture},
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
    });
    const to_child = child.stdin.?;
    const from_child = child.stdout.?;
    child.stdin = null;
    child.stdout = null;
    defer from_child.close(io);

    const read_buffer = try allocator.alloc(u8, 4096);
    defer allocator.free(read_buffer);
    var reader = from_child.readerStreaming(io, read_buffer);

    var skewed = matching_identity;
    skewed.version = "0.0.0-other";
    const outcome = try agent_link.exchangeIdentityDetailed(
        io,
        to_child,
        &reader.interface,
        .ui,
        skewed,
    );
    // Our side refuses the fixture's version.
    try std.testing.expectEqual(
        agent_link.Failure{ .refused = .product_version },
        outcome.failure,
    );
    to_child.close(io);
    const term = try child.wait(io);
    try std.testing.expectEqual(std.process.Child.Term{
        .exited = @intFromEnum(execution_mode.Exit.identity_refused),
    }, term);
}
