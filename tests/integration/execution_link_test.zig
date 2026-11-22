//! The execution process, started for real.
//!
//! Everything here needs a second process, so none of it belongs in a unit
//! test: a spawn that fails, an identity exchange over inherited pipes, a
//! child that exits on end-of-stream, and a refusal that must leave no running
//! peer behind. A missing fixture fails the run rather than skipping it, for
//! the same reason the fault-capture fixture does: a silently skipped
//! cross-process test is indistinguishable from a passing one.

const std = @import("std");
const builtin = @import("builtin");

const execution_host = @import("app_execution_host");
const process_spawn = @import("app_process_spawn");
const execution_mode = @import("app_execution_mode");
const execution_client = @import("app_execution_client");
const agent_link = @import("metawork_agent_link");
const lifecycle = @import("lifecycle_fixture");
const fault = @import("app_fault");

const agent = lifecycle.lifecycle;
const product_control = lifecycle.product_control;

const io = std.testing.io;
const allocator = std.testing.allocator;

const matching_identity: agent_link.Identity = .{
    .version = "fixture-0",
    .core_manifest_sha256 = @splat('1'),
    .core_abi_revision = 28,
};

const fixture_variable = "METAWORK_EXECUTION_LINK_FIXTURE";

/// How long a direct start waits for the fixture to agree on identity.
const test_handshake_deadline_ms: u64 = 10_000;

/// A missing fixture is a misconfigured build entry, never a reason to pass.
fn fixturePath() ![]u8 {
    return std.process.Environ.getAlloc(std.testing.environ, allocator, fixture_variable);
}

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
        test_handshake_deadline_ms,
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
    const stopped = host.stop();
    try std.testing.expectEqual(
        execution_host.Stopped{ .exited = @intFromEnum(execution_mode.Exit.link_closed) },
        stopped,
    );
}

test "the execution process is started through the window's one spawn boundary" {
    // An MCP server started at the same moment as the execution process
    // must not inherit the link's pipe ends, and the only thing keeping it
    // from doing so is that both spawns take the same boundary.
    const Observer = struct {
        calls: u32 = 0,
        held: bool = false,

        fn call(context: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            self.held = process_spawn.testing.held();
        }
    };
    var observer: Observer = .{};
    process_spawn.testing.observer = .{ .context = &observer, .call_fn = Observer.call };
    defer process_spawn.testing.observer = null;

    const fixture = try fixturePath();
    defer allocator.free(fixture);
    var host: execution_host.Host = undefined;
    const failure = try host.start(io, allocator, matching_identity, .{}, .{ .explicit = &.{fixture} }, test_handshake_deadline_ms);
    if (failure) |value| {
        std.debug.print("start failed: {any}\n", .{value});
        return error.StartFailed;
    }
    defer host.deinit();
    try std.testing.expectEqual(@as(u32, 1), observer.calls);
    try std.testing.expect(observer.held);
}

/// Reads one whole frame the execution half sent. Only for the calls these
/// tests send by hand, which fit in one fragment.
fn readFrame(host: *execution_host.Host, buffer: []u8) !struct {
    kind: agent_link.Kind,
    correlation: u64,
    payload: []u8,
} {
    var header_bytes: [agent_link.frame.header_bytes]u8 = undefined;
    try host.reader.interface.readSliceAll(&header_bytes);
    const header = try agent_link.frame.decode(&header_bytes);
    if (!header.final or header.payload_len > buffer.len) return error.UnexpectedFrame;
    try host.reader.interface.readSliceAll(buffer[0..header.payload_len]);
    return .{ .kind = header.kind, .correlation = header.correlation, .payload = buffer[0..header.payload_len] };
}

test "the execution half answers a call from its own Runtime" {
    const fixture = try fixturePath();
    defer allocator.free(fixture);

    var host: execution_host.Host = undefined;
    const failure = try host.start(io, allocator, matching_identity, .{}, .{
        .explicit = &.{ fixture, "--with-runtime" },
    }, test_handshake_deadline_ms);
    if (failure) |value| {
        std.debug.print("start failed: {any}\n", .{value});
        return error.StartFailed;
    }
    defer host.deinit();

    const request = try agent_link.rpc.encodeRequest(.restore_admission, allocator, 0, .{ .releasing_route_id = null });
    defer allocator.free(request);
    try std.testing.expectEqual(agent_link.channel.Submission.queued, try host.outbound.submitWaiting(.request, 7, request));

    var buffer: [64]u8 = undefined;
    const received = try readFrame(&host, &buffer);
    try std.testing.expectEqual(agent_link.Kind.response, received.kind);
    try std.testing.expectEqual(@as(u64, 7), received.correlation);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const answer = try agent_link.rpc.decodeResponse(.restore_admission, arena.allocator(), received.payload);
    try std.testing.expectEqual(@TypeOf(answer.ok).available, answer.ok);

    // An orderly end: the Runtime shuts down and the process leaves on its
    // own, with the code that says so.
    try std.testing.expectEqual(
        execution_host.Stopped{ .exited = @intFromEnum(execution_mode.Exit.link_closed) },
        host.stop(),
    );
}

test "tidying up that does not finish costs the execution half its deadline, not its exit" {
    // Nothing the UI half holds can keep this process alive once the link
    // has ended: a Runtime whose shutdown never returns is the stand-in for
    // every way that could happen. The deadline is shorter than the UI's
    // grace period, so a process that left on its own reports the deadline's
    // code; one that had to be ended reports `.killed`.
    const fixture = try fixturePath();
    defer allocator.free(fixture);

    var host: execution_host.Host = undefined;
    const failure = try host.start(io, allocator, matching_identity, .{}, .{
        .explicit = &.{ fixture, "--with-runtime", "--hang-shutdown" },
    }, test_handshake_deadline_ms);
    if (failure) |value| {
        std.debug.print("start failed: {any}\n", .{value});
        return error.StartFailed;
    }
    defer host.deinit();

    try std.testing.expectEqual(
        execution_host.Stopped{ .exited = @intFromEnum(execution_mode.Exit.exit_deadline) },
        host.stop(),
    );
}

test "a child that ignores end of stream is ended, and the stop returns" {
    // The reaper waits on the child for its whole life, so ending the child
    // must not wait on it a second time. On POSIX `std.process.Child.kill`
    // did exactly that and the loser of the two `wait4` calls panicked with
    // ECHILD in Debug; `terminate` only sends the signal and the reaper
    // collects what it ends. Bounded by the grace period, so a regression
    // that leaves the child running fails on the assertion below.
    const fixture = try fixturePath();
    defer allocator.free(fixture);

    var host: execution_host.Host = undefined;
    const failure = try host.start(
        io,
        allocator,
        matching_identity,
        .{},
        .{ .explicit = &.{ fixture, "--ignore-eof" } },
        test_handshake_deadline_ms,
    );
    if (failure) |value| {
        std.debug.print("start failed: {any}\n", .{value});
        return error.StartFailed;
    }
    defer host.deinit();

    try std.testing.expectEqual(execution_host.Stopped.killed, host.stop());
    // The reaper has collected it: the stop joined the thread that waits.
    try std.testing.expect(host.term != null);
}

test "a child that stops reading with its pipe full is ended within the grace, and the stop returns" {
    // The writer finishes what is queued before it leaves, and this child
    // never reads: the writer sits in a write on a full pipe, so a stop whose
    // grace period started only after joining the writer would never end.
    // Bounded from outside, so a regression fails here instead of hanging
    // the test process: past the bound the test ends the child itself.
    const fixture = try fixturePath();
    defer allocator.free(fixture);
    var host: execution_host.Host = undefined;
    const failure = try host.start(io, allocator, matching_identity, .{}, .{
        .explicit = &.{ fixture, "--stop-reading" },
    }, test_handshake_deadline_ms);
    if (failure) |value| {
        std.debug.print("start failed: {any}\n", .{value});
        return error.StartFailed;
    }
    defer host.deinit();

    // Far more than any pipe holds (Windows 4 KiB, POSIX at most 64 KiB).
    const payload = try allocator.alloc(u8, 2 * 1024 * 1024);
    defer allocator.free(payload);
    @memset(payload, 0x42);
    try std.testing.expectEqual(agent_link.channel.Submission.queued, try host.outbound.submitWaiting(.request, 1, payload));

    const Stop = struct {
        done: std.Io.Event = .unset,
        result: execution_host.Stopped = .gone,

        fn run(self: *@This(), stopping: *execution_host.Host) void {
            self.result = stopping.stop();
            self.done.set(io);
        }
    };
    var stop: Stop = .{};
    const started = std.Io.Timestamp.now(io, .awake);
    const thread = try std.Thread.spawn(.{}, Stop.run, .{ &stop, &host });
    const bound_ms = execution_host.stop_grace_ms + 10_000;
    const returned = if (stop.done.waitTimeout(io, .{ .duration = .{
        .raw = .fromMilliseconds(@intCast(bound_ms)),
        .clock = .awake,
    } })) |_| true else |_| false;
    if (!returned) _ = host.terminate();
    thread.join();
    const elapsed_ms = started.durationTo(.now(io, .awake)).toMilliseconds();
    try std.testing.expect(returned);
    try std.testing.expectEqual(execution_host.Stopped.killed, stop.result);
    try std.testing.expect(elapsed_ms < @as(i64, @intCast(execution_host.stop_grace_ms + 3_000)));
}

test "a child that leaves by itself is reported as exited even when the deadline passes after it is collected" {
    // The stop's deadline keeps running through the waits after the reap.
    // A settle that outlasts it -- here on purpose, under load by accident --
    // must not turn a child that had already left on its own into a killed
    // one: what it exited with is decided when it is collected.
    const fixture = try fixturePath();
    defer allocator.free(fixture);
    var host: execution_host.Host = undefined;
    const failure = try host.start(io, allocator, matching_identity, .{}, .{ .explicit = &.{fixture} }, test_handshake_deadline_ms);
    if (failure) |value| {
        std.debug.print("start failed: {any}\n", .{value});
        return error.StartFailed;
    }
    defer host.deinit();
    const SlowSettle = struct {
        fn settle(_: ?*anyopaque) void {
            std.Io.sleep(io, .fromMilliseconds(@intCast(execution_host.stop_grace_ms + 500)), .awake) catch {};
        }
    };
    host.settle = .{ .context = null, .settle_fn = SlowSettle.settle };
    try std.testing.expectEqual(
        execution_host.Stopped{ .exited = @intFromEnum(execution_mode.Exit.link_closed) },
        host.stop(),
    );
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
        test_handshake_deadline_ms,
    );
    const value = failure orelse {
        _ = host.stop();
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
        test_handshake_deadline_ms,
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
        test_handshake_deadline_ms,
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

// ---------------------------------------------------------------------------
// Product over the link
// ---------------------------------------------------------------------------
//
// These drive Product Control against the caller's half of the link, with
// the execution half running a real Agent Runtime over the lifecycle
// fixture's fake Core in the other process. What fails here fails across
// three owners -- Product, the link, the Agent Runtime -- which is why it is
// an integration test.

const Wake = struct {
    calls: std.atomic.Value(u64) = .init(0),

    fn notifier(self: *Wake) agent.EventReadyNotifier {
        return .{ .context = self, .notify_fn = notify };
    }

    fn notify(context: ?*anyopaque) agent.EventReadyNotification {
        const self: *Wake = @ptrCast(@alignCast(context.?));
        _ = self.calls.fetchAdd(1, .monotonic);
        return .scheduled;
    }
};

/// The fixture's own limits, restated: importing the fixture executable's
/// root here would compile a second `main`.
const fixture_message_limits: agent_link.MessageLimits = .{
    .event = 1 << 20,
    .request = 1 << 20,
    .response = 1 << 20,
    .ui_request = 1 << 16,
    .ui_response = 1 << 16,
};

const fixture_large_message_limits: agent_link.MessageLimits = .{
    .event = 1 << 20,
    .request = 4 << 20,
    .response = 4 << 20,
    .ui_request = 1 << 16,
    .ui_response = 1 << 16,
};

fn startOwner(
    owner: *execution_client.Owner,
    wake: *Wake,
    argv: []const []const u8,
    limits: agent_link.MessageLimits,
    credit_count_override: ?u64,
) !void {
    try owner.init(io, allocator, .{
        .identity = matching_identity,
        .message_limits = limits,
        .queue_limits = .{},
        .spawn = .{ .explicit = argv },
        .wake = wake.notifier(),
        .credit_count_override = credit_count_override,
    });
}

const product_limits: product_control.Limits = .{
    .worker_count = 1,
    .queue_capacity = 1,
    .max_tasks = 2,
    .max_runs_per_task = 3,
    .max_tools_per_run = 1,
};

/// One turn of what the application's main loop does with the link.
fn turn(control: *product_control.Runtime, owner: *execution_client.Owner) !void {
    try control.drainAgentEvents();
    if (owner.takeLoss()) |range| {
        control.abandonSessionsInRouteRange(range.first, range.end);
        control.expireMcpCatalog();
        control.expireSkillCatalogs();
    }
    control.syncLifecycle();
    owner.sweep();
}

const wait_limit_ms: u64 = 20_000;
const wait_tick_ms: u64 = 10;

fn printSnapshot(control: *product_control.Runtime) void {
    const output = allocator.alloc(u8, 256 * 1024) catch return;
    defer allocator.free(output);
    const snapshot = control.writeAggregateFixture(output) catch return;
    const start = std.mem.indexOf(u8, snapshot, "\"tasks\"") orelse 0;
    std.debug.print("snapshot: {s}\n", .{snapshot[start..@min(snapshot.len, start + 6000)]});
}

/// Turns the loop until the aggregate snapshot contains `needle`, or fails on
/// a line after `wait_limit_ms`.
fn waitSnapshot(control: *product_control.Runtime, owner: *execution_client.Owner, needle: []const u8) !void {
    const output = try allocator.alloc(u8, 256 * 1024);
    defer allocator.free(output);
    var waited: u64 = 0;
    while (waited < wait_limit_ms) : (waited += wait_tick_ms) {
        try turn(control, owner);
        const snapshot = try control.writeAggregateFixture(output);
        if (std.mem.indexOf(u8, snapshot, needle) != null) return;
        try std.Io.sleep(io, .fromMilliseconds(wait_tick_ms), .awake);
    }
    std.debug.print("never saw {s}\n", .{needle});
    printSnapshot(control);
    return error.SnapshotNeverMatched;
}

fn waitDetached(control: *product_control.Runtime, owner: *execution_client.Owner, task_id: u64) !void {
    var waited: u64 = 0;
    while (waited < wait_limit_ms) : (waited += wait_tick_ms) {
        try turn(control, owner);
        const task = control.testTask(task_id) orelse return error.TaskGone;
        if (task.runtime.attachment == .detached) return;
        try std.Io.sleep(io, .fromMilliseconds(wait_tick_ms), .awake);
    }
    printSnapshot(control);
    return error.TaskNeverDetached;
}

fn waitEvents(owner: *execution_client.Owner, count: u64) !void {
    var waited: u64 = 0;
    while (waited < wait_limit_ms) : (waited += wait_tick_ms) {
        if (owner.events_received.load(.acquire) >= count) return;
        try std.Io.sleep(io, .fromMilliseconds(wait_tick_ms), .awake);
    }
    return error.EventsNeverArrived;
}

fn createRunningTask(control: *product_control.Runtime, text: []const u8) !u64 {
    try lifecycle.installProductControlExecution(control);
    const task_id = try control.createTask(
        lifecycle.productControlTaskInput(),
        try product_control.TestSupport.fixtureModelSelection(control),
    );
    _ = try lifecycle.runPreparedTask(control, task_id, .{ .text = text });
    return task_id;
}

test "a Run crosses into the execution process and its events arrive ahead of its terminal" {
    // The execution half waits before sending each event, so a terminal that
    // did not wait for its Session's events would reach Product first, and
    // Product would seal the Run on a count of zero with its text missing.
    const fixture = try fixturePath();
    defer allocator.free(fixture);
    var wake: Wake = .{};
    var owner: execution_client.Owner = undefined;
    try startOwner(&owner, &wake, &.{ fixture, "--with-runtime", "--text-events", "--slow-events" }, fixture_message_limits, null);
    defer owner.deinit();
    {
        var control = try product_control.Runtime.init(allocator, io, owner.runtimePort(), product_limits, lifecycle.productControlConfiguration());
        defer control.deinit();
        const task_id = try createRunningTask(&control, "Say something short");
        try waitSnapshot(&control, &owner, "\"terminal\":{\"outcome\":\"completed\"");
        try std.testing.expect(owner.currentProcess() != null);
        const task = control.testTask(task_id).?;
        const run = task.durable.runs[0].?;
        try std.testing.expect(run.event_projection_failure == null);
        const output = try allocator.alloc(u8, 256 * 1024);
        defer allocator.free(output);
        const snapshot = try control.writeAggregateFixture(output);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "typed event") != null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"recordingIncomplete\":true") == null);
    }
}

test "a shutdown whose Run's terminal waits behind events the window has not made room for still finishes" {
    // The execution half sends a Run's terminal only after every event its
    // Session queued, and sends an event only into room the window granted,
    // which only the consuming thread grants. With room for one event, the
    // Run's second event stays over there, and the terminal with it: a
    // shutdown that joins its workers without consuming waits on itself.
    // Bounded from outside; past the bound the test ends the process, which
    // ends every wait on it, and fails.
    const fixture = try fixturePath();
    defer allocator.free(fixture);
    var wake: Wake = .{};
    var owner: execution_client.Owner = undefined;
    try startOwner(&owner, &wake, &.{ fixture, "--with-runtime", "--text-events" }, fixture_message_limits, 1);
    defer owner.deinit();
    var control = try product_control.Runtime.init(allocator, io, owner.runtimePort(), product_limits, lifecycle.productControlConfiguration());
    defer control.deinit();
    const task_id = try createRunningTask(&control, "Say something short");
    try waitEvents(&owner, 1);

    // The Run has finished over there -- both its events produced, the
    // second held for room -- once its Session is idle again. Asked
    // directly: a snapshot is answered at once, not held behind events.
    const session = control.testTask(task_id).?.runtime.attached().?.binding.owner.?.session;
    var waited: u64 = 0;
    while (session.snapshot().state != .idle) : (waited += wait_tick_ms) {
        if (waited >= wait_limit_ms) return error.RunNeverFinished;
        try std.Io.sleep(io, .fromMilliseconds(wait_tick_ms), .awake);
    }
    try std.testing.expectEqual(@as(u64, 1), owner.events_received.load(.acquire));

    const Shutdown = struct {
        done: std.Io.Event = .unset,

        fn run(self: *@This(), shutting: *product_control.Runtime) void {
            shutting.shutdownExecutor();
            self.done.set(io);
        }
    };
    var shutdown: Shutdown = .{};
    const thread = try std.Thread.spawn(.{}, Shutdown.run, .{ &shutdown, &control });
    const returned = if (shutdown.done.waitTimeout(io, .{ .duration = .{
        .raw = .fromMilliseconds(10_000),
        .clock = .awake,
    } })) |_| true else |_| false;
    if (!returned) execution_client.TestSupport.killCurrent(&owner);
    thread.join();
    try std.testing.expect(returned);

    // Nothing was lost: the events held back reached Product after all, and
    // the Run is sealed complete with no gap in its recording.
    try std.testing.expect(owner.events_received.load(.acquire) > 1);
    const run = control.testTask(task_id).?.durable.runs[0].?;
    try std.testing.expect(run.event_projection_failure == null);
    const output = try allocator.alloc(u8, 256 * 1024);
    defer allocator.free(output);
    const snapshot = try control.writeAggregateFixture(output);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"terminal\":{\"outcome\":\"completed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "typed event") != null);
    owner.shutdown();
    control.syncLifecycle();
    control.relinquishAgentSessionsAfterRuntimeShutdown();
}

test "a Skill selected with attachments crosses into the execution process as the Run's Host block" {
    // The fake Core in the execution process streams the block it received
    // back as the Run's text, so what Core got is read from Product's view.
    const fixture = try fixturePath();
    defer allocator.free(fixture);
    var wake: Wake = .{};
    var owner: execution_client.Owner = undefined;
    try startOwner(&owner, &wake, &.{ fixture, "--with-runtime", "--text-events" }, fixture_message_limits, null);
    defer owner.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    var skill_enablement_store = try lifecycle.product_skill.enablement.FileStore.init(io, root);
    defer skill_enablement_store.deinit();
    var attachment_store = try product_control.AttachmentFileStore.init(io, allocator, root);
    defer attachment_store.deinit();
    {
        var control = try product_control.Runtime.init(allocator, io, owner.runtimePort(), product_limits, .{
            .directories = .{ .canonical_user_home = root },
            .skill_enablement = .{ .file_store = &skill_enablement_store },
            .attachment_store = &attachment_store,
            .attachment_images = .{ .prepare_fn = lifecycle.prepareTestAttachmentImage },
        });
        defer control.deinit();
        try lifecycle.installProductControlExecution(&control);
        const workspace_id = try control.openWorkspace(lifecycle.productControlTaskInput());
        const catalog = catalog: {
            var waited: u64 = 0;
            while (waited < wait_limit_ms) : (waited += wait_tick_ms) {
                try turn(&control, &owner);
                const projection = try control.workspaceCatalog(workspace_id);
                switch (projection.availability) {
                    .ready, .degraded => break :catalog projection,
                    .unavailable => return error.CatalogUnavailable,
                    .uninitialized, .loading => try std.Io.sleep(io, .fromMilliseconds(wait_tick_ms), .awake),
                }
            }
            return error.CatalogNeverReady;
        };
        const task_id = try control.createTaskInWorkspace(workspace_id, try control.workspaceEpoch(workspace_id), try product_control.TestSupport.fixtureModelSelection(&control), catalog.revision, catalog.selection_revision, .{ .interactive = null });
        const files = [_]product_control.AttachmentCandidate{.{ .display_name = "sales.xlsx", .bytes = "PK\x03\x04sheet" }};
        var descriptor_storage: [1]product_control.AttachmentDescriptor = undefined;
        const descriptors = try control.stageAttachments(&files, &descriptor_storage);
        const ids = [_]u64{descriptors[0].id};
        _ = try lifecycle.runPreparedTask(&control, task_id, .{ .multimodal = .{
            .text = "Summarize by month",
            .attachment_ids = &ids,
            .skill = .{ .skill_id = lifecycle.fixture_skill_id, .catalog_revision = catalog.revision, .selection_revision = catalog.selection_revision.? },
        } });
        try waitSnapshot(&control, &owner, "\"terminal\":{\"outcome\":\"completed\"");
        try waitSnapshot(&control, &owner, "For this message the user explicitly selected the Skill \\\"review\\\" (skill_id " ++
            lifecycle.fixture_skill_id ++ ") in the composer. Invoke the Skill \\\"review\\\" first");
        try std.testing.expect(owner.currentProcess() != null);
    }
}

test "a process killed under a running Task leaves Product up and the cut Run interrupted" {
    const fixture = try fixturePath();
    defer allocator.free(fixture);
    var wake: Wake = .{};
    var owner: execution_client.Owner = undefined;
    try startOwner(&owner, &wake, &.{ fixture, "--with-runtime", "--hold-runs" }, fixture_message_limits, null);
    defer owner.deinit();
    {
        var control = try product_control.Runtime.init(allocator, io, owner.runtimePort(), product_limits, lifecycle.productControlConfiguration());
        defer control.deinit();
        const task_id = try createRunningTask(&control, "Say something short");
        // The held Run reports that it is executing tools: a worker is now
        // inside `execute` over there.
        try waitEvents(&owner, 1);
        execution_client.TestSupport.killCurrent(&owner);

        // Interrupted, not failed, and not sealed as complete.
        try waitSnapshot(&control, &owner, "\"outcome\":\"interrupted\"");
        try waitDetached(&control, &owner, task_id);
        const task = control.testTask(task_id).?;
        const cut = task.durable.runs[0].?;
        try std.testing.expect(cut.event_projection_failure != null);
        try std.testing.expect(cut.coverage == .excluded);
        try std.testing.expect(owner.currentProcess() == null);

        // The next Task's Session lives in a new process, numbered above
        // every id the dead one handed out.
        const second = try control.createTask(
            lifecycle.productControlTaskInput(),
            try product_control.TestSupport.fixtureModelSelection(&control),
        );
        _ = try lifecycle.runPreparedTask(&control, second, .{ .text = "Say something short" });
        try waitSnapshot(&control, &owner, "\"terminal\":{\"outcome\":\"completed\"");
        try std.testing.expect(owner.currentProcess() != null);
        try std.testing.expect(control.testTask(second).?.runtime.routeId() > execution_client.generation_span);
    }
}

/// Counts the bytes the Owner holds, so a test can say what a dead process
/// left behind.
const CountingAllocator = struct {
    child: std.mem.Allocator,
    live: std.atomic.Value(isize) = .init(0),

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    fn of(context: *anyopaque) *CountingAllocator {
        return @ptrCast(@alignCast(context));
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self = of(context);
        const memory = self.child.rawAlloc(len, alignment, ret) orelse return null;
        _ = self.live.fetchAdd(@intCast(len), .monotonic);
        return memory;
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) bool {
        const self = of(context);
        if (!self.child.rawResize(memory, alignment, new_len, ret)) return false;
        _ = self.live.fetchAdd(@as(isize, @intCast(new_len)) - @as(isize, @intCast(memory.len)), .monotonic);
        return true;
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) ?[*]u8 {
        const self = of(context);
        const moved = self.child.rawRemap(memory, alignment, new_len, ret) orelse return null;
        _ = self.live.fetchAdd(@as(isize, @intCast(new_len)) - @as(isize, @intCast(memory.len)), .monotonic);
        return moved;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self = of(context);
        self.child.rawFree(memory, alignment, ret);
        _ = self.live.fetchSub(@intCast(memory.len), .monotonic);
    }
};

test "nothing of a dead execution process is left once its Session is released" {
    // Each crash would otherwise cost the window whatever the dead process's
    // bookkeeping held: its pipes' buffers, its correlation table, the
    // Session objects Product named it by. Once Product has released the
    // Session, the main loop's sweep has to give all of it back.
    const fixture = try fixturePath();
    defer allocator.free(fixture);
    var wake: Wake = .{};
    var counting: CountingAllocator = .{ .child = allocator };
    var owner: execution_client.Owner = undefined;
    try owner.init(io, counting.allocator(), .{
        .identity = matching_identity,
        .message_limits = fixture_message_limits,
        .queue_limits = .{},
        .spawn = .{ .explicit = &.{ fixture, "--with-runtime", "--hold-runs" } },
        .wake = wake.notifier(),
    });
    defer owner.deinit();
    // The event pump, which lives as long as the Owner.
    const baseline = counting.live.load(.acquire);
    {
        var control = try product_control.Runtime.init(allocator, io, owner.runtimePort(), product_limits, lifecycle.productControlConfiguration());
        defer control.deinit();
        const task_id = try createRunningTask(&control, "Say something short");
        try waitEvents(&owner, 1);
        execution_client.TestSupport.killCurrent(&owner);
        try waitDetached(&control, &owner, task_id);

        // What may stay is the Owner's own list of processes: its buffer is
        // allocated by the first start and reused, so it does not grow with
        // each crash. Everything the dead process itself held is gone.
        var waited: u64 = 0;
        while (true) : (waited += wait_tick_ms) {
            try turn(&control, &owner);
            const list_bytes: isize = @intCast(owner.generations.capacity * @sizeOf(*anyopaque));
            const retained = counting.live.load(.acquire) - baseline - list_bytes;
            if (retained == 0 and owner.generations.items.len == 0) break;
            if (waited >= wait_limit_ms) {
                std.debug.print("a dead process still holds {d} bytes\n", .{retained});
                return error.DeadProcessStillHeld;
            }
            try std.Io.sleep(io, .fromMilliseconds(wait_tick_ms), .awake);
        }
    }
}

test "a Task idle when its process dies is given up, and its next message starts a new process" {
    const fixture = try fixturePath();
    defer allocator.free(fixture);
    var wake: Wake = .{};
    var owner: execution_client.Owner = undefined;
    try startOwner(&owner, &wake, &.{ fixture, "--with-runtime" }, fixture_message_limits, null);
    defer owner.deinit();
    // A checkpoint store and history, so the Run's checkpoint is exported
    // across the link and committed, and the next message has something to
    // restore from.
    var home_dir = std.testing.tmpDir(.{});
    defer home_dir.cleanup();
    const home = try home_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(home);
    var checkpoints = try lifecycle.product_task.checkpoint_store.FileStore.init(io, home);
    defer checkpoints.deinit();
    var history_store = try lifecycle.product_task.history.FileStore.init(io, home);
    defer history_store.deinit();
    var history: lifecycle.TypedHistory = .{ .file_store = &history_store };
    defer history.deinit();
    {
        var configuration = lifecycle.productControlConfiguration();
        configuration.checkpoint_store = .{ .file_store = &checkpoints };
        configuration.task_persistence = history.capability();
        configuration.directories.canonical_user_home = home;
        var control = try product_control.Runtime.init(allocator, io, owner.runtimePort(), product_limits, configuration);
        defer control.deinit();
        const task_id = try createRunningTask(&control, "Say something short");
        try waitSnapshot(&control, &owner, "\"terminal\":{\"outcome\":\"completed\"");
        var waited_for_checkpoint: u64 = 0;
        while (control.testTask(task_id).?.durable.checkpoint == null) : (waited_for_checkpoint += wait_tick_ms) {
            if (waited_for_checkpoint >= wait_limit_ms) return error.CheckpointNeverCommitted;
            try turn(&control, &owner);
            try std.Io.sleep(io, .fromMilliseconds(wait_tick_ms), .awake);
        }
        const first = owner.currentProcess().?;
        execution_client.TestSupport.killCurrent(&owner);
        // Nothing of this Task's was running, so only the loss the main loop
        // reports can hand it to the close that detaches it.
        try waitDetached(&control, &owner, task_id);

        // What the Renderer sends, which brings a detached Task's Session back
        // before running anything.
        _ = control.sendInput("after-the-crash", task_id, .{ .text = "Say something else" }) catch |err|
            std.debug.print("next message: {s}\n", .{@errorName(err)});
        var waited: u64 = 0;
        while (waited < wait_limit_ms) : (waited += wait_tick_ms) {
            try turn(&control, &owner);
            // By start number: the new process's OS handle can be the very
            // value the dead one's had, which made this wait run out.
            if (owner.currentProcess()) |number| if (number != first) break;
            try std.Io.sleep(io, .fromMilliseconds(wait_tick_ms), .awake);
        } else {
            const task = control.testTask(task_id).?;
            std.debug.print("attachment={s} restore_job={} last_restore_failure={any}\n", .{
                @tagName(task.runtime.attachment),
                task.runtime.restore_job != null,
                task.runtime.last_restore_failure,
            });
            printSnapshot(&control);
            return error.NoNewProcess;
        }
    }
}

const CallerSink = struct {
    thread: std.Thread.Id,
    bytes: std.ArrayList(u8) = .empty,
    largest_chunk: usize = 0,
    off_thread: bool = false,

    fn sink(self: *CallerSink) agent.CheckpointSink {
        return .{ .context = self, .write_fn = write };
    }

    fn write(context: ?*anyopaque, chunk: []const u8) agent.CheckpointSinkWriteResult {
        const self: *CallerSink = @ptrCast(@alignCast(context.?));
        if (std.Thread.getCurrentId() != self.thread) self.off_thread = true;
        self.largest_chunk = @max(self.largest_chunk, chunk.len);
        self.bytes.appendSlice(allocator, chunk) catch return .io_failed;
        return .ok;
    }
};

test "an export's bytes reach the caller's sink on the caller's own thread" {
    // The reader thread never touches a caller's sink: the bytes come back in
    // the export's answer, and the thread that asked writes them.
    const fixture = try fixturePath();
    defer allocator.free(fixture);
    const payload_bytes: usize = 2 * 1024 * 1024;
    var argument_storage: [64]u8 = undefined;
    const checkpoint_argument = try std.fmt.bufPrint(&argument_storage, "--checkpoint-bytes={d}", .{payload_bytes});
    var wake: Wake = .{};
    var owner: execution_client.Owner = undefined;
    try startOwner(&owner, &wake, &.{ fixture, "--with-runtime", "--large-messages", checkpoint_argument }, fixture_large_message_limits, null);
    defer owner.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const port = owner.runtimePort();
    const route = try port.createSessionRoute(.{
        .task_id = 1,
        .binding_epoch = 1,
        .model_binding = .{
            .target = .{
                .provider_id = "fixture-provider",
                .protocol = .anthropic_messages,
                .base_url = "",
                .model = "fixture-model",
            },
            .credential = "fixture-secret",
        },
        .permission_mode = .default,
        .shell_policy = .disabled,
        .workspace = .{ .canonical_root = root, .trust = .explicitly_trusted },
        .canonical_user_home = root,
        .workspace_epoch = "",
    });
    try std.testing.expect(route.id != 0);

    var sink: CallerSink = .{ .thread = std.Thread.getCurrentId() };
    defer sink.bytes.deinit(allocator);
    const limits: agent.CheckpointLimits = .{
        .hard_bytes = 64 * 1024 * 1024,
        .max_section_bytes = 16 * 1024 * 1024,
        .max_string_bytes = 5 * 1024 * 1024,
        .max_messages = 4096,
        .max_blocks_per_message = 256,
        .chunk_bytes = 1024 * 1024,
    };
    var outcome = try route.session.exportCheckpoint(limits, sink.sink(), 0, 0, "fixture-model");
    defer outcome.deinit();
    try std.testing.expect(outcome == .success);
    try std.testing.expectEqual(@as(u64, payload_bytes), outcome.success.checkpoint.total_bytes);
    try std.testing.expectEqual(payload_bytes, sink.bytes.items.len);
    for (sink.bytes.items, 0..) |byte, index| {
        if (byte != @as(u8, @truncate(index % 251))) return error.CheckpointBytesDiffer;
    }
    try std.testing.expect(!sink.off_thread);
    try std.testing.expect(sink.largest_chunk <= limits.chunk_bytes);

    try std.testing.expect(route.session.closeOutcome(.session_close) == .closed);
    try port.releaseClosedSession(route.session);
}

// ---------------------------------------------------------------------------
// Liveness
// ---------------------------------------------------------------------------

extern "ntdll" fn NtSuspendProcess(process: std.os.windows.HANDLE) callconv(.winapi) std.os.windows.NTSTATUS;

/// Stops the process without ending it, the way a hang looks from outside:
/// it neither answers nor exits.
fn suspendProcess(id: std.process.Child.Id) !void {
    switch (builtin.os.tag) {
        .windows => if (NtSuspendProcess(id) != .SUCCESS) return error.SuspendFailed,
        else => try std.posix.kill(id, std.posix.SIG.STOP),
    }
}

test "a process that stops answering is given up within the deadline, and a call waiting on it returns" {
    const fixture = try fixturePath();
    defer allocator.free(fixture);
    var wake: Wake = .{};
    var owner: execution_client.Owner = undefined;
    const deadline_ms: u64 = 300;
    try owner.init(io, allocator, .{
        .identity = matching_identity,
        .message_limits = fixture_message_limits,
        .queue_limits = .{},
        .spawn = .{ .explicit = &.{ fixture, "--with-runtime" } },
        .wake = wake.notifier(),
        .heartbeat_interval_ms = 50,
        .heartbeat_deadline_ms = deadline_ms,
    });
    defer owner.deinit();
    {
        var control = try product_control.Runtime.init(allocator, io, owner.runtimePort(), product_limits, lifecycle.productControlConfiguration());
        defer control.deinit();
        const task_id = try createRunningTask(&control, "Say something short");
        try waitSnapshot(&control, &owner, "\"terminal\":{\"outcome\":\"completed\"");
        const first = owner.currentProcess() orelse return error.NoProcess;

        // Answers for as long as it answers pings: well past the deadline,
        // the process is still the same one.
        try std.Io.sleep(io, .fromMilliseconds(@intCast(deadline_ms * 3)), .awake);
        try std.testing.expectEqual(first, owner.currentProcess().?);
        try std.testing.expect(owner.takeLoss() == null);

        try suspendProcess(execution_client.TestSupport.currentChild(&owner) orelse return error.NoProcess);
        // A call on the UI's own thread, as Product's projection makes on every
        // Task read. With the process stopped, nothing but the liveness check
        // can end this wait.
        const started = std.Io.Timestamp.now(io, .awake);
        const admission = owner.runtimePort().restoreAdmission(null);
        const waited_ms = started.durationTo(.now(io, .awake)).toMilliseconds();
        // The lost answer: the process holds nothing any more.
        try std.testing.expectEqual(agent.RuntimePort.RestoreAdmission.available, admission);
        // It did wait: nothing answered it but the end of the process.
        try std.testing.expect(waited_ms >= @as(i64, @intCast(deadline_ms / 2)));
        try std.testing.expect(waited_ms < 10_000);

        // Given up exactly as a crash is: the process is ended, and its Task
        // detached for the next message to restore.
        try waitDetached(&control, &owner, task_id);
        try std.testing.expect(owner.currentProcess() == null);
    }
}

// ---------------------------------------------------------------------------
// MCP over the link
// ---------------------------------------------------------------------------

/// The transport the UI half keeps: it records what reaches it.
const RecordingTransport = struct {
    mutex: std.Io.Mutex = .init,
    opens: u32 = 0,
    closes: u32 = 0,
    notified: u32 = 0,
    saw_cancellation: bool = false,
    destroyed: bool = false,
    messages: std.ArrayList([]u8) = .empty,

    fn owner(self: *RecordingTransport) agent.McpTransportOwner {
        return .init(.{
            .context = self,
            .open_fn = open,
            .request_fn = request,
            .tool_request_fn = request,
            .notify_fn = notify,
            .close_fn = close,
        }, destroy);
    }

    fn deinit(self: *RecordingTransport) void {
        for (self.messages.items) |message| allocator.free(message);
        self.messages.deinit(allocator);
    }

    fn open(context: *anyopaque, _: agent.McpPurpose, _: agent.McpEra, _: u32) agent.McpOpenOutcome {
        const self: *RecordingTransport = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.opens += 1;
        return .{ .connection = context };
    }

    fn request(context: *anyopaque, body_allocator: std.mem.Allocator, bytes: []const u8, _: u32, cancellation: agent.McpCancellation) agent.McpExchangeOutcome {
        const self: *RecordingTransport = @ptrCast(@alignCast(context));
        {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            self.messages.append(allocator, allocator.dupe(u8, bytes) catch return .{ .failure = .fatal }) catch
                return .{ .failure = .fatal };
        }
        if (std.mem.eql(u8, bytes, "withdrawn")) {
            // Answers only once its caller has withdrawn it.
            var waited: u64 = 0;
            while (!cancellation.isCancelled()) : (waited += wait_tick_ms) {
                if (waited >= wait_limit_ms) return .{ .failure = .timeout };
                std.Io.sleep(io, .fromMilliseconds(wait_tick_ms), .awake) catch {};
            }
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            self.saw_cancellation = true;
            return .{ .failure = .cancelled };
        }
        const body = if (std.mem.eql(u8, bytes, "first")) "reply" else "ok";
        return .{ .response = .{
            .http_status = 0,
            .body = body_allocator.dupe(u8, body) catch return .{ .failure = .fatal },
        } };
    }

    fn notify(context: *anyopaque, bytes: []const u8, _: u32, _: agent.McpCancellation) ?agent.McpTransportFailure {
        const self: *RecordingTransport = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (std.mem.eql(u8, bytes, "notified")) self.notified += 1;
        return null;
    }

    fn close(context: *anyopaque) void {
        const self: *RecordingTransport = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.closes += 1;
    }

    fn destroy(context: *anyopaque) void {
        const self: *RecordingTransport = @ptrCast(@alignCast(context));
        self.destroyed = true;
    }

    fn expectMessages(self: *RecordingTransport, expected: []const []const u8) !void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        try std.testing.expectEqual(expected.len, self.messages.items.len);
        for (expected, self.messages.items) |want, got| try std.testing.expectEqualStrings(want, got);
    }
};

/// One exercise as the fixture's execution half performs it, as this half
/// records it. The secret-bearing exchange is not here: it never left this
/// half's scan.
const exercised = [_][]const u8{ "first", "echo:0:reply", "secret:fatal", "withdrawn", "withdrawn:cancelled" };

test "an MCP server's transport stays in the UI half, and the execution process reaches it by calling back" {
    const fixture = try fixturePath();
    defer allocator.free(fixture);
    var recorder: RecordingTransport = .{};
    defer recorder.deinit();
    {
        var wake: Wake = .{};
        var owner: execution_client.Owner = undefined;
        try startOwner(&owner, &wake, &.{ fixture, "--with-runtime", "--exercise-mcp" }, fixture_message_limits, null);
        defer owner.deinit();
        const port = owner.runtimePort();

        var transport_owner = recorder.owner();
        var additions = try agent.McpRuntimeInput.init(allocator, 1, &.{.{
            .id = "fixture-server",
            .transport_owner = &transport_owner,
            .secrets = &.{"hunter2"},
            .transport = .stdio,
            .namespace = "fixture",
            .client_name = "MetaWork",
            .client_version = "1",
            .timeout_ms = 1_000,
            .configuration_fingerprint = @splat(1),
            .allowed_tools = &.{"echo"},
        }});
        defer additions.deinit();
        var membership = try port.prepareMcpMembership(1, &additions, &.{"fixture-server"});
        defer membership.deinit();
        try std.testing.expectEqual(agent.McpConfigurationApplyOutcome.applied, try port.applyMcpConfiguration(&membership));

        try recorder.expectMessages(&exercised);
        try std.testing.expectEqual(@as(u32, 1), recorder.opens);
        try std.testing.expectEqual(@as(u32, 1), recorder.closes);
        try std.testing.expectEqual(@as(u32, 1), recorder.notified);
        try std.testing.expect(recorder.saw_cancellation);

        // A new process is given the same servers, through the same
        // transport, before anything else uses it.
        execution_client.TestSupport.killCurrent(&owner);
        var waited: u64 = 0;
        while (owner.takeLoss() == null) : (waited += wait_tick_ms) {
            if (waited >= wait_limit_ms) return error.LossNeverReported;
            try std.Io.sleep(io, .fromMilliseconds(wait_tick_ms), .awake);
        }
        owner.sweep();
        switch (try port.activateMcp()) {
            .activated => |activation| activation.deinit(),
            .empty, .unavailable => {},
        }
        try recorder.expectMessages(&(exercised ++ exercised));
        try std.testing.expectEqual(@as(u32, 2), recorder.opens);
        try std.testing.expectEqual(@as(u32, 2), recorder.closes);
        // Still applied, so still held.
        try std.testing.expect(!recorder.destroyed);
    }
    try std.testing.expect(recorder.destroyed);
}

test "the owner's shutdown does not wait behind a new process's MCP replay, and the caller gets no process lost during it" {
    // A new process is given the MCP membership the last one held before
    // anyone uses it. Here that replay never returns in any process after
    // the first, while the process keeps answering pings: only the end of
    // the link ends it. The shutdown, which takes the same spawn lock as a
    // start, must not wait for it -- and the caller that started the process
    // must not be handed one that was lost during its replay.
    const fixture = try fixturePath();
    defer allocator.free(fixture);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    var recorder: RecordingTransport = .{};
    defer recorder.deinit();
    var wake: Wake = .{};
    var owner: execution_client.Owner = undefined;
    try startOwner(&owner, &wake, &.{ fixture, "--with-runtime", "--hang-mcp-replay" }, fixture_message_limits, null);
    defer owner.deinit();
    const port = owner.runtimePort();

    // A membership in the first process, which applies normally.
    var transport_owner = recorder.owner();
    var additions = try agent.McpRuntimeInput.init(allocator, 1, &.{.{
        .id = "fixture-server",
        .transport_owner = &transport_owner,
        .secrets = &.{},
        .transport = .stdio,
        .namespace = "fixture",
        .client_name = "MetaWork",
        .client_version = "1",
        .timeout_ms = 1_000,
        .configuration_fingerprint = @splat(1),
        .allowed_tools = &.{"echo"},
    }});
    defer additions.deinit();
    var membership = try port.prepareMcpMembership(1, &additions, &.{"fixture-server"});
    defer membership.deinit();
    try std.testing.expectEqual(agent.McpConfigurationApplyOutcome.applied, try port.applyMcpConfiguration(&membership));

    execution_client.TestSupport.killCurrent(&owner);
    var waited: u64 = 0;
    while (owner.takeLoss() == null) : (waited += wait_tick_ms) {
        if (waited >= wait_limit_ms) return error.LossNeverReported;
        try std.Io.sleep(io, .fromMilliseconds(wait_tick_ms), .awake);
    }
    owner.sweep();

    // Opening a Session starts the second process, which hangs in its replay.
    const Opener = struct {
        failure: ?anyerror = null,
        opened: bool = false,

        fn run(self: *@This(), opening: agent.RuntimePort, workspace: []const u8) void {
            if (opening.createSessionRoute(plainSessionOptions(workspace))) |_| {
                self.opened = true;
            } else |err| self.failure = err;
        }
    };
    var opener: Opener = .{};
    // The second process's id, held by the test: once the shutdown has
    // unpublished the process, this is the only way left to end it.
    var second_pid: ?u32 = null;
    const opening = try std.Thread.spawn(.{}, Opener.run, .{ &opener, port, root });
    var opening_joined = false;
    // Any failure from here ends the process the opener may be waiting on,
    // then waits for the opener, before the Owner goes: the opener is inside
    // the Owner until it returns.
    errdefer if (!opening_joined) {
        if (second_pid orelse execution_client.TestSupport.currentPid(&owner)) |pid| ForeignProcess.end(pid);
        opening.join();
    };
    waited = 0;
    while (owner.currentProcess() != 2) : (waited += wait_tick_ms) {
        if (waited >= wait_limit_ms) return error.SecondProcessNeverStarted;
        try std.Io.sleep(io, .fromMilliseconds(wait_tick_ms), .awake);
    }
    second_pid = execution_client.TestSupport.currentPid(&owner) orelse return error.SecondProcessNeverStarted;

    const Shutdown = struct {
        done: std.Io.Event = .unset,

        fn run(self: *@This(), shutting: *execution_client.Owner) void {
            shutting.shutdown();
            self.done.set(io);
        }
    };
    var shutdown: Shutdown = .{};
    const shutting = try std.Thread.spawn(.{}, Shutdown.run, .{ &shutdown, &owner });
    const returned = if (shutdown.done.waitTimeout(io, .{ .duration = .{
        .raw = .fromMilliseconds(@intCast(execution_host.stop_grace_ms + 5_000)),
        .clock = .awake,
    } })) |_| true else |_| false;
    // Past the bound, end the process: its link ends, the replay with it.
    if (!returned) ForeignProcess.end(second_pid.?);
    shutting.join();
    opening.join();
    opening_joined = true;
    try std.testing.expect(returned);

    // The caller got the lost answer, and got it from the start itself: the
    // process it started was lost during its replay and never handed over.
    try std.testing.expect(!opener.opened);
    try std.testing.expectEqual(@as(?anyerror, error.DependencyUnreachable), opener.failure);
    try std.testing.expectEqual(@as(u64, 1), owner.lost_before_use.load(.acquire));
}

test "a process that dies on every start is not started again on every ask" {
    // Whatever asks for a process -- a catalog refresh after a loss, a
    // schedule, a message -- asks the owner, so the bound has to be there.
    // The caller here asks again as soon as it hears of a loss, which is the
    // worst any of them does.
    const fixture = try fixturePath();
    defer allocator.free(fixture);
    var wake: Wake = .{};
    var owner: execution_client.Owner = undefined;
    try startOwner(&owner, &wake, &.{ fixture, "--with-runtime", "--no-runtime" }, fixture_message_limits, null);
    defer owner.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const port = owner.runtimePort();

    const window_ms: i64 = 4_000;
    const began = std.Io.Timestamp.now(io, .awake);
    var asks: u32 = 0;
    while (began.durationTo(.now(io, .awake)).toMilliseconds() < window_ms) : (asks += 1) {
        if (port.createSessionRoute(.{
            .task_id = 1,
            .binding_epoch = 1,
            .model_binding = .{
                .target = .{
                    .provider_id = "fixture-provider",
                    .protocol = .anthropic_messages,
                    .base_url = "",
                    .model = "fixture-model",
                },
                .credential = "fixture-secret",
            },
            .permission_mode = .default,
            .shell_policy = .disabled,
            .workspace = .{ .canonical_root = root, .trust = .explicitly_trusted },
            .canonical_user_home = root,
            .workspace_epoch = "",
        })) |_| return error.ProcessServed else |_| {}
        _ = owner.takeLoss();
        owner.sweep();
        try std.Io.sleep(io, .fromMilliseconds(10), .awake);
    }
    // Three quick deaths, then a two-second hold, one more, then a
    // four-second hold. Unheld, a start follows every ask.
    try std.testing.expect(owner.started >= 3);
    try std.testing.expect(owner.started <= 5);
    try std.testing.expect(asks > 50);
}

// ---------------------------------------------------------------------------
// Skills over the link
// ---------------------------------------------------------------------------

fn skillSessionOptions(root: []const u8, lease: *agent.CatalogLease, grants: []const []const u8) agent.SessionOpenOptions {
    return .{
        .task_id = 1,
        .binding_epoch = 1,
        .model_binding = .{
            .target = .{
                .provider_id = "fixture-provider",
                .protocol = .anthropic_messages,
                .base_url = "",
                .model = "fixture-model",
            },
            .credential = "fixture-secret",
        },
        .permission_mode = .default,
        .shell_policy = .disabled,
        .workspace = .{ .canonical_root = root, .trust = .explicitly_trusted },
        .canonical_user_home = root,
        .workspace_epoch = "skills-over-the-link",
        .skill_catalog = lease,
        .skill_policy = .{ .granted_skill_ids = grants },
    };
}

/// Counts what the UI half's source lifetime is asked, as Product's pins an
/// Office version.
const SourcePin = struct {
    held: std.atomic.Value(i32) = .init(0),

    fn lifetime(self: *SourcePin) agent.CatalogSourceLifetime {
        return .{ .context = self, .retain_fn = retain, .release_fn = release };
    }

    fn retain(context: *anyopaque) bool {
        const self: *SourcePin = @ptrCast(@alignCast(context));
        _ = self.held.fetchAdd(1, .acq_rel);
        return true;
    }

    fn release(context: *anyopaque) void {
        const self: *SourcePin = @ptrCast(@alignCast(context));
        _ = self.held.fetchSub(1, .acq_rel);
    }
};

test "a skill catalog stays in the execution process, and a Session bound with it is bound again after the process is gone" {
    const fixture = try fixturePath();
    defer allocator.free(fixture);
    var pin: SourcePin = .{};
    {
        var wake: Wake = .{};
        var owner: execution_client.Owner = undefined;
        try startOwner(&owner, &wake, &.{ fixture, "--with-runtime" }, fixture_message_limits, null);
        defer owner.deinit();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(root);
        const port = owner.runtimePort();

        var acquisition = try port.querySkillCatalog(.{
            .canonical_user_home = root,
            .target = .{ .workspace = .{ .canonical_root = root, .epoch = "skills-over-the-link" } },
            .source_lifetime = pin.lifetime(),
        });
        defer acquisition.deinitProjection();
        try std.testing.expectEqual(@as(usize, 1), acquisition.projection.skills.len);
        const grants = [_][]const u8{lifecycle.fixture_skill_id};
        // The pin is this half's, held for as long as the lease is referred to.
        try std.testing.expectEqual(@as(i32, 1), pin.held.load(.acquire));

        const route = try port.createSessionRoute(skillSessionOptions(root, acquisition.lease, &grants));
        try std.testing.expect(route.session.skillPolicyMatches(acquisition.lease, .{ .granted_skill_ids = &grants }));

        // A capture is the lease the Session was bound with and its grants,
        // and narrowing, cloning and borrowing it happen here.
        var captured = try route.session.captureRestoreInputs();
        const borrow = port.borrowSkillRestoreInputs(captured.skill.?).?;
        try std.testing.expectEqual(acquisition.lease, borrow.catalog);
        try std.testing.expectEqualStrings(lifecycle.fixture_skill_id, borrow.policy.granted_skill_ids[0]);
        const narrowed = try port.narrowSkillRestoreInputs(captured.skill.?, .{});
        try std.testing.expectEqual(@as(usize, 0), port.borrowSkillRestoreInputs(narrowed).?.policy.granted_skill_ids.len);
        try port.releaseSkillRestoreInputs(narrowed);
        const kept = try port.cloneSkillRestoreInputs(captured.skill.?);
        try captured.release();

        try std.testing.expect(route.session.closeOutcome(.session_close) == .closed);
        try port.releaseClosedSession(route.session);

        // The process goes, and its catalog with it.
        execution_client.TestSupport.killCurrent(&owner);
        var waited: u64 = 0;
        while (owner.takeLoss() == null) : (waited += wait_tick_ms) {
            if (waited >= wait_limit_ms) return error.LossNeverReported;
            try std.Io.sleep(io, .fromMilliseconds(wait_tick_ms), .awake);
        }
        owner.sweep();

        // What a restore does with its capture: open with the borrowed lease
        // and grants. The lease is acquired again in the new process, as the
        // same catalog.
        const kept_borrow = port.borrowSkillRestoreInputs(kept).?;
        const reopened = try port.createSessionRoute(skillSessionOptions(root, kept_borrow.catalog, kept_borrow.policy.granted_skill_ids));
        try std.testing.expect(owner.currentProcess() != null);
        try std.testing.expect(reopened.session.skillPolicyMatches(acquisition.lease, .{ .granted_skill_ids = &grants }));
        try std.testing.expect(reopened.session.closeOutcome(.session_close) == .closed);
        try port.releaseClosedSession(reopened.session);
        try port.releaseSkillRestoreInputs(kept);

        try std.testing.expectEqual(@as(i32, 1), pin.held.load(.acquire));
        try port.releaseSkillCatalog(acquisition.lease);
    }
    // Nothing refers to the lease any more, here or there.
    try std.testing.expectEqual(@as(i32, 0), pin.held.load(.acquire));
}

// ---------------------------------------------------------------------------
// File delivery and media over the link
// ---------------------------------------------------------------------------

/// The Host's effects for one Run, recording what reaches them.
const RecordingEffects = struct {
    mutex: std.Io.Mutex = .init,
    inspected: [64]u8 = undefined,
    inspected_len: usize = 0,
    sensitive_headers: u32 = 0,
    image_bytes: [32]u8 = undefined,
    image_len: usize = 0,
    video_bytes: [32]u8 = undefined,
    video_len: usize = 0,
    report: [1024]u8 = undefined,
    report_len: usize = 0,

    fn of(context: ?*anyopaque) *RecordingEffects {
        return @ptrCast(@alignCast(context.?));
    }

    fn inspect(context: *anyopaque, path: []const u8, _: *const std.atomic.Value(bool)) agent.FileDeliveryInspection {
        const self = of(context);
        @memcpy(self.inspected[0..path.len], path);
        self.inspected_len = path.len;
        return .{ .verified = .{ .size_bytes = 42, .sha256 = @splat(1) } };
    }

    fn readCredential(_: *anyopaque, buffer: []u8) ?usize {
        const key = "renewed-key";
        @memcpy(buffer[0..key.len], key);
        return key.len;
    }

    fn perform(
        context: ?*anyopaque,
        request: agent.CompletionHttpRequest,
        _: *const agent.ImageGenerationCancellation,
        buffer: []u8,
    ) agent.CompletionTransportError!agent.CompletionTransportResponse {
        const self = of(context);
        for (request.headers) |header| if (header.sensitive) {
            self.sensitive_headers += 1;
        };
        if (std.mem.endsWith(u8, request.url, "/report")) {
            @memcpy(self.report[0..request.body.len], request.body);
            self.report_len = request.body.len;
            return .{ .status = 204, .body = buffer[0..0] };
        }
        if (request.stream) |receiver| {
            var reader = std.Io.Reader.fixed("MP4BYTES");
            receiver.receive_fn(receiver.context, "video/mp4", 8, &reader);
            return .{ .status = 200, .body = buffer[0..0] };
        }
        const body = "{\"ok\":1}";
        @memcpy(buffer[0..body.len], body);
        return .{ .status = 200, .body = buffer[0..body.len] };
    }

    fn commitImage(context: *anyopaque, bytes: []const u8, format: agent.ImageGenerationFormat, _: *const agent.ImageGenerationCancellation) agent.ImageGenerationOutputResult {
        const self = of(context);
        @memcpy(self.image_bytes[0..bytes.len], bytes);
        self.image_len = bytes.len;
        return .{ .saved = agent.ImageGenerationReceipt.init("images/a.png", bytes.len, format) catch unreachable };
    }

    fn commitVideo(context: *anyopaque, reader: *std.Io.Reader, _: ?u64, _: *const agent.ImageGenerationCancellation) agent.VideoGenerationOutcome {
        const self = of(context);
        self.video_len = reader.readSliceShort(&self.video_bytes) catch 0;
        return .{ .saved = agent.VideoGenerationReceipt.init("videos/a.mp4", 1024) catch unreachable };
    }
};

test "a Run's file delivery, image and video effects stay with the Host and are reached by calling back" {
    const fixture = try fixturePath();
    defer allocator.free(fixture);
    var wake: Wake = .{};
    var owner: execution_client.Owner = undefined;
    try startOwner(&owner, &wake, &.{ fixture, "--with-runtime", "--exercise-effects" }, fixture_message_limits, null);
    defer owner.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const port = owner.runtimePort();
    const route = try port.createSessionRoute(.{
        .task_id = 1,
        .binding_epoch = 1,
        .model_binding = .{
            .target = .{
                .provider_id = "fixture-provider",
                .protocol = .anthropic_messages,
                .base_url = "",
                .model = "fixture-model",
            },
            .credential = "fixture-secret",
        },
        .permission_mode = .default,
        .shell_policy = .disabled,
        .workspace = .{ .canonical_root = root, .trust = .explicitly_trusted },
        .canonical_user_home = root,
        .workspace_epoch = "",
    });

    var effects: RecordingEffects = .{};
    const reader: agent.ImageGenerationCredentialReader = .{ .context = &effects, .read_fn = RecordingEffects.readCredential };
    const transport: agent.CompletionTransport = .{ .context = &effects, .perform_fn = RecordingEffects.perform };
    const prepared = route.session.prepareRunWithTools(.{ .text = "hello" }, .{
        .binding = .{
            .endpoint = "https://media.example.test/v1/images/generations",
            .source = "fixture-source",
            .model = "fixture-image",
            .credential = "first-key",
            .credential_reader = reader,
            .output = .{ .context = &effects, .commit_fn = RecordingEffects.commitImage },
        },
        .transport = transport,
    }, .{ .context = &effects, .inspect_fn = RecordingEffects.inspect }, null, .{
        .endpoint = "https://media.example.test/v1/videos",
        .source = "fixture-source",
        .model = "fixture-video",
        .credential = reader,
        .transport = transport,
        .output = .{ .context = &effects, .commit_fn = RecordingEffects.commitVideo },
    });

    const run_id = prepared catch |err| {
        std.debug.print("prepare: {s}\n", .{@errorName(err)});
        return err;
    };
    // Cancelled, the fixture's execution half uses each effect first.
    try route.session.cancelPreparedRun(run_id);

    // What the execution half got back from each effect, as it reported it.
    try std.testing.expectEqualStrings(
        "inspect=verified:42;image_credential=renewed-key;image_http=200:{\"ok\":1};image_saved=images/a.png;" ++
            "video_credential=renewed-key;video_stream=MP4BYTES;video_saved=videos/a.mp4:1024;",
        effects.report[0..effects.report_len],
    );
    // And what reached the Host's.
    try std.testing.expectEqualStrings("out/report.txt", effects.inspected[0..effects.inspected_len]);
    try std.testing.expectEqualStrings("PNGBYTES", effects.image_bytes[0..effects.image_len]);
    try std.testing.expectEqualStrings("MP4BYTES", effects.video_bytes[0..effects.video_len]);
    try std.testing.expectEqual(@as(u32, 1), effects.sensitive_headers);

    try std.testing.expect(route.session.closeOutcome(.session_close) == .closed);
    try port.releaseClosedSession(route.session);
}

test "an execution process that faults in a Run leaves a record of its own, which the window reports when it loses it" {
    // The window passes its data root; the execution process installs fault
    // capture there under its own role and file, and names the Runs it is
    // executing. A Run that traps on the worker executing it must therefore
    // leave a record naming that process and that Task, and the window, on
    // losing the process, must find it and report it.
    const fixture = try fixturePath();
    defer allocator.free(fixture);
    var root_dir = std.testing.tmpDir(.{});
    defer root_dir.cleanup();
    const root = try root_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    var wake: Wake = .{};
    var owner: execution_client.Owner = undefined;
    try owner.init(io, allocator, .{
        .identity = matching_identity,
        .message_limits = fixture_message_limits,
        .queue_limits = .{},
        .spawn = .{ .explicit = &.{ fixture, "--with-runtime", "--crash-in-run" } },
        .wake = wake.notifier(),
        .data_root = root,
    });
    defer owner.deinit();
    {
        var control = try product_control.Runtime.init(allocator, io, owner.runtimePort(), product_limits, lifecycle.productControlConfiguration());
        defer control.deinit();
        const task_id = try createRunningTask(&control, "Say something short");

        var lost: ?execution_client.RouteRange = null;
        var waited: u64 = 0;
        while (lost == null) : (waited += wait_tick_ms) {
            if (waited >= wait_limit_ms) {
                printSnapshot(&control);
                return error.ProcessNeverLost;
            }
            try control.drainAgentEvents();
            if (owner.takeLoss()) |range| {
                lost = range;
                control.abandonSessionsInRouteRange(range.first, range.end);
                control.expireMcpCatalog();
                control.expireSkillCatalogs();
            }
            control.syncLifecycle();
            owner.sweep();
            try std.Io.sleep(io, .fromMilliseconds(wait_tick_ms), .awake);
        }
        try waitSnapshot(&control, &owner, "\"outcome\":\"interrupted\"");
        const range = lost.?;
        try std.testing.expect(range.process_id != 0);

        // The process's own record, under its own role.
        var record_storage: [fault.record_bytes]u8 = undefined;
        const record = fault.readRoleRecord(io, root, .execution, &record_storage) orelse
            return error.NoExecutionRecord;
        try std.testing.expectEqual(fault.Role.execution, record.role);
        try std.testing.expectEqual(range.process_id, record.pid);
        try std.testing.expect(record.process_started_at_unix_ms >= range.spawned_unix_ms);
        try std.testing.expect(record.fault != null);
        try std.testing.expectEqualStrings(matching_identity.version, record.version());
        var interrupted_storage: [fault.breadcrumb_capacity]fault.Breadcrumb = undefined;
        const interrupted = record.interruptedRuns(&interrupted_storage);
        try std.testing.expectEqual(@as(usize, 1), interrupted.len);
        try std.testing.expectEqual(task_id, interrupted[0].task_id);
        try std.testing.expectEqual(record.fault.?.thread_id, interrupted[0].thread_id);

        // The window's record is the window's: the execution process never
        // wrote to it.
        try std.testing.expectError(
            error.FileNotFound,
            root_dir.dir.access(io, fault.directory_name ++ std.fs.path.sep_str ++ fault.record_file_name, .{}),
        );

        // Reported for the process lost, and only for it: another id, or a
        // process spawned after this record was written, finds nothing.
        var summary_storage: [8 * 1024]u8 = undefined;
        try std.testing.expectEqualStrings("", fault.reportExecutionLoss(io, root, range.process_id +% 1, range.spawned_unix_ms, &summary_storage));
        try std.testing.expectEqualStrings("", fault.reportExecutionLoss(io, root, range.process_id, record.process_started_at_unix_ms + 1, &summary_storage));
        const summary = fault.reportExecutionLoss(io, root, range.process_id, range.spawned_unix_ms, &summary_storage);
        try std.testing.expect(std.mem.startsWith(u8, summary, "The execution process ended with a fault."));
        var task_text: [32]u8 = undefined;
        try std.testing.expect(std.mem.indexOf(u8, summary, try std.fmt.bufPrint(&task_text, "Task {d} Run", .{task_id})) != null);
        const written = try root_dir.dir.readFileAlloc(
            io,
            fault.directory_name ++ std.fs.path.sep_str ++ fault.execution_report_file_name,
            allocator,
            .limited(16 * 1024),
        );
        defer allocator.free(written);
        try std.testing.expectEqualStrings(summary, written);
    }
}

fn plainSessionOptions(root: []const u8) agent.SessionOpenOptions {
    return .{
        .task_id = 1,
        .binding_epoch = 1,
        .model_binding = .{
            .target = .{
                .provider_id = "fixture-provider",
                .protocol = .anthropic_messages,
                .base_url = "",
                .model = "fixture-model",
            },
            .credential = "fixture-secret",
        },
        .permission_mode = .default,
        .shell_policy = .disabled,
        .workspace = .{ .canonical_root = root, .trust = .explicitly_trusted },
        .canonical_user_home = root,
        .workspace_epoch = "",
    };
}

test "a process lost before it is published is never handed out, and the next ask starts another" {
    // The fixture agrees on identity and ends at once. The hook holds each
    // start until the reader has seen that, which is the order in which a
    // lost process used to be published and then handed out until restart.
    const fixture = try fixturePath();
    defer allocator.free(fixture);
    const Hold = struct {
        fn call(_: ?*anyopaque, lost: *const std.atomic.Value(bool)) void {
            var waited: u64 = 0;
            while (!lost.load(.acquire) and waited < wait_limit_ms) : (waited += 1)
                std.Io.sleep(io, .fromMilliseconds(1), .awake) catch {};
        }
    };
    var wake: Wake = .{};
    var owner: execution_client.Owner = undefined;
    try owner.init(io, allocator, .{
        .identity = matching_identity,
        .message_limits = fixture_message_limits,
        .queue_limits = .{},
        .spawn = .{ .explicit = &.{ fixture, "--with-runtime", "--no-runtime" } },
        .wake = wake.notifier(),
        .after_start = .{ .context = null, .call_fn = Hold.call },
    });
    defer owner.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const port = owner.runtimePort();

    if (port.createSessionRoute(plainSessionOptions(root))) |_| return error.ProcessServed else |_| {}
    try std.testing.expectEqual(@as(u32, 1), owner.started);
    // Not published at all: `currentProcess` would hide a lost one.
    try std.testing.expect(owner.current == null);
    // Asked again, a new process is started rather than the lost one used.
    if (port.createSessionRoute(plainSessionOptions(root))) |_| return error.ProcessServed else |_| {}
    try std.testing.expectEqual(@as(u32, 2), owner.started);
    try std.testing.expect(owner.currentProcess() == null);
}

/// Image effects whose commit outlasts the loss of the process that asked
/// for it: it waits for its cancellation, then takes a while to end, as a
/// write already under way does.
const LingeringCommit = struct {
    entered: std.atomic.Value(bool) = .init(false),
    cancelled: std.atomic.Value(bool) = .init(false),
    returned: std.atomic.Value(bool) = .init(false),

    fn of(context: ?*anyopaque) *LingeringCommit {
        return @ptrCast(@alignCast(context.?));
    }

    fn readCredential(_: *anyopaque, buffer: []u8) ?usize {
        const key = "renewed-key";
        @memcpy(buffer[0..key.len], key);
        return key.len;
    }

    fn perform(
        _: ?*anyopaque,
        _: agent.CompletionHttpRequest,
        _: *const agent.ImageGenerationCancellation,
        buffer: []u8,
    ) agent.CompletionTransportError!agent.CompletionTransportResponse {
        const body = "{\"ok\":1}";
        @memcpy(buffer[0..body.len], body);
        return .{ .status = 200, .body = buffer[0..body.len] };
    }

    fn commitImage(context: *anyopaque, bytes: []const u8, format: agent.ImageGenerationFormat, cancellation: *const agent.ImageGenerationCancellation) agent.ImageGenerationOutputResult {
        const self = of(context);
        self.entered.store(true, .release);
        var waited: u64 = 0;
        while (!cancellation.isRequested() and waited < wait_limit_ms) : (waited += 1)
            std.Io.sleep(io, .fromMilliseconds(1), .awake) catch {};
        self.cancelled.store(cancellation.isRequested(), .release);
        std.Io.sleep(io, .fromMilliseconds(300), .awake) catch {};
        self.returned.store(true, .release);
        return .{ .saved = agent.ImageGenerationReceipt.init("images/a.png", bytes.len, format) catch unreachable };
    }
};

test "a Run's effects are released only after the callbacks using them return, when its process is lost" {
    // Product releases a Run's effects as soon as the Run is over. Over the
    // link a lost process ends the Run at once, while the window may still
    // be inside one of those effects on a callback thread.
    const fixture = try fixturePath();
    defer allocator.free(fixture);
    var wake: Wake = .{};
    var owner: execution_client.Owner = undefined;
    try startOwner(&owner, &wake, &.{ fixture, "--with-runtime", "--exercise-effects" }, fixture_message_limits, null);
    defer owner.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const port = owner.runtimePort();
    const route = try port.createSessionRoute(plainSessionOptions(root));

    var effects: LingeringCommit = .{};
    const run_id = try route.session.prepareRunWithTools(.{ .text = "hello" }, .{
        .binding = .{
            .endpoint = "https://media.example.test/v1/images/generations",
            .source = "fixture-source",
            .model = "fixture-image",
            .credential = "first-key",
            .credential_reader = .{ .context = &effects, .read_fn = LingeringCommit.readCredential },
            .output = .{ .context = &effects, .commit_fn = LingeringCommit.commitImage },
        },
        .transport = .{ .context = &effects, .perform_fn = LingeringCommit.perform },
    }, null, null, null);

    // Cancelled, the fixture's execution half uses the image effect first,
    // and the commit is still going when the process is lost.
    const Cancel = struct {
        effects_returned_first: bool = false,
        fn run(self: *@This(), session: agent.SessionPort, id: u64, lingering: *LingeringCommit) void {
            session.cancelPreparedRun(id) catch {};
            self.effects_returned_first = lingering.returned.load(.acquire);
        }
    };
    var cancel: Cancel = .{};
    const thread = try std.Thread.spawn(.{}, Cancel.run, .{ &cancel, route.session, run_id, &effects });
    var waited: u64 = 0;
    while (!effects.entered.load(.acquire)) : (waited += wait_tick_ms) {
        if (waited >= wait_limit_ms) return error.CommitNeverEntered;
        try std.Io.sleep(io, .fromMilliseconds(wait_tick_ms), .awake);
    }
    execution_client.TestSupport.killCurrent(&owner);
    thread.join();
    // The loss asked the effect to stop, and the Run's end waited for it.
    try std.testing.expect(effects.cancelled.load(.acquire));
    try std.testing.expect(cancel.effects_returned_first);

    _ = route.session.closeOutcome(.session_close);
    port.releaseClosedSession(route.session) catch {};
}

/// A process outside the Owner's reach, by id: the grandchild below.
const ForeignProcess = struct {
    const windows = std.os.windows;
    extern "kernel32" fn OpenProcess(access: windows.DWORD, inherit: windows.BOOL, pid: windows.DWORD) callconv(.winapi) ?windows.HANDLE;
    extern "kernel32" fn TerminateProcess(process: windows.HANDLE, code: windows.UINT) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn GetExitCodeProcess(process: windows.HANDLE, code: *windows.DWORD) callconv(.winapi) windows.BOOL;
    const process_terminate: windows.DWORD = 0x0001;
    const process_query_limited_information: windows.DWORD = 0x1000;
    const still_active: windows.DWORD = 259;

    fn alive(pid: u32) bool {
        if (builtin.os.tag != .windows) {
            std.posix.kill(@intCast(pid), @enumFromInt(0)) catch return false;
            return true;
        }
        const handle = OpenProcess(process_query_limited_information, .FALSE, pid) orelse return false;
        defer windows.CloseHandle(handle);
        var code: windows.DWORD = 0;
        if (GetExitCodeProcess(handle, &code) == .FALSE) return false;
        return code == still_active;
    }

    fn end(pid: u32) void {
        if (builtin.os.tag != .windows) {
            std.posix.kill(@intCast(pid), .KILL) catch {};
            return;
        }
        const handle = OpenProcess(process_terminate, .FALSE, pid) orelse return;
        defer windows.CloseHandle(handle);
        _ = TerminateProcess(handle, 1);
    }
};

test "a process the execution process starts does not hold the link once that process is gone" {
    // The fixture starts a long-lived grandchild with its standard handles
    // inherited, as AgentCore starts a tool. Ending the execution process must
    // still end the link: the liveness deadline here is a minute, so only the
    // end of the stream can report the loss in time, and the generation can
    // only be collected once its reader has seen that end.
    const fixture = try fixturePath();
    defer allocator.free(fixture);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const pid_path = try std.fs.path.join(allocator, &.{ root, "grandchild.pid" });
    defer allocator.free(pid_path);
    const flag = try std.mem.concat(allocator, u8, &.{ "--spawn-grandchild=", pid_path });
    defer allocator.free(flag);

    var wake: Wake = .{};
    var owner: execution_client.Owner = undefined;
    try owner.init(io, allocator, .{
        .identity = matching_identity,
        .message_limits = fixture_message_limits,
        .queue_limits = .{},
        .spawn = .{ .explicit = &.{ fixture, "--with-runtime", flag } },
        .wake = wake.notifier(),
        .heartbeat_deadline_ms = 60_000,
    });
    defer owner.deinit();
    const port = owner.runtimePort();
    _ = port.restoreAdmission(null);
    const route = try port.createSessionRoute(plainSessionOptions(root));

    var pid_text: [32]u8 = undefined;
    var waited: u64 = 0;
    const grandchild: u32 = while (true) : (waited += wait_tick_ms) {
        if (tmp.dir.readFile(io, "grandchild.pid", &pid_text)) |text| {
            if (text.len != 0) break try std.fmt.parseInt(u32, text, 10);
        } else |_| {}
        if (waited >= wait_limit_ms) return error.GrandchildNeverStarted;
        try std.Io.sleep(io, .fromMilliseconds(wait_tick_ms), .awake);
    };
    // Registered after the Owner's deinit, so it runs first: should the link
    // still be held, the Owner's stop would otherwise wait on it.
    defer ForeignProcess.end(grandchild);
    try std.testing.expect(ForeignProcess.alive(grandchild));

    execution_client.TestSupport.killCurrent(&owner);
    waited = 0;
    while (owner.takeLoss() == null) : (waited += wait_tick_ms) {
        if (waited >= 5_000) return error.EndOfStreamNeverSeen;
        try std.Io.sleep(io, .fromMilliseconds(wait_tick_ms), .awake);
    }
    _ = route.session.closeOutcome(.session_close);
    port.releaseClosedSession(route.session) catch {};
    waited = 0;
    while (owner.generations.items.len != 0) : (waited += wait_tick_ms) {
        owner.sweep();
        if (waited >= wait_limit_ms) return error.GenerationNeverCollected;
        try std.Io.sleep(io, .fromMilliseconds(wait_tick_ms), .awake);
    }
    // And all of it with the grandchild still running.
    try std.testing.expect(ForeignProcess.alive(grandchild));
}

test "a process stuck before it agrees on identity is ended within the deadline, and the ask answered" {
    // The start holds the spawn lock: without a bound on the exchange, every
    // later ask, and the Owner's shutdown at exit, would wait with it. The
    // fixture's own hang ends after eight seconds, so a missing bound shows
    // as a slow answer rather than a test that never returns.
    const fixture = try fixturePath();
    defer allocator.free(fixture);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    var wake: Wake = .{};
    var owner: execution_client.Owner = undefined;
    try owner.init(io, allocator, .{
        .identity = matching_identity,
        .message_limits = fixture_message_limits,
        .queue_limits = .{},
        .spawn = .{ .explicit = &.{ fixture, "--hang-before-hello=8000", "--with-runtime" } },
        .wake = wake.notifier(),
        .heartbeat_deadline_ms = 500,
    });
    defer owner.deinit();
    const port = owner.runtimePort();

    const asked = std.Io.Timestamp.now(io, .awake);
    if (port.createSessionRoute(plainSessionOptions(root))) |_| return error.ProcessServed else |_| {}
    const answered_ms = asked.durationTo(.now(io, .awake)).toMilliseconds();
    try std.testing.expect(answered_ms < 4_000);
    try std.testing.expectEqual(@as(u32, 1), owner.started);
    try std.testing.expect(owner.current == null);
    // The process was ended and reaped by the failed start, not left behind.
    try std.testing.expectEqual(@as(usize, 0), owner.generations.items.len);
}

test "a child the reaper has collected is not signalled: its pid may already name another process" {
    // A crash is usually reaped before the reader sees the end of the
    // stream, and the loss that follows asks the host to end the child.
    const fixture = try fixturePath();
    defer allocator.free(fixture);
    var host: execution_host.Host = undefined;
    const failure = try host.start(
        io,
        allocator,
        matching_identity,
        .{},
        .{ .explicit = &.{ fixture, "--with-runtime", "--no-runtime" } },
        test_handshake_deadline_ms,
    );
    if (failure) |value| {
        std.debug.print("start failed: {any}\n", .{value});
        return error.StartFailed;
    }
    defer host.deinit();
    var waited: u64 = 0;
    while (!host.reaped.isSet()) : (waited += wait_tick_ms) {
        if (waited >= wait_limit_ms) return error.NeverReaped;
        try std.Io.sleep(io, .fromMilliseconds(wait_tick_ms), .awake);
    }
    // On Windows the host ends the child through its own duplicate of the
    // process handle, which no other process can come to name.
    try std.testing.expectEqual(builtin.os.tag == .windows, host.terminate());
}
