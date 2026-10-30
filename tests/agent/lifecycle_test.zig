const fixture = @import("lifecycle_fixture");
const std = fixture.std;
const lifecycle = fixture.lifecycle;
const product_control_executor = fixture.product_control_executor;
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

const CatalogSourceTracker = struct {
    references: std.atomic.Value(usize) = .init(1),
    deny: bool = false,

    fn lifetime(self: *@This()) lifecycle.CatalogSourceLifetime {
        return .{ .context = self, .retain_fn = retain, .release_fn = release };
    }

    fn retain(context: *anyopaque) bool {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (self.deny) return false;
        _ = self.references.fetchAdd(1, .monotonic);
        return true;
    }

    fn release(context: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        std.debug.assert(self.references.fetchSub(1, .acq_rel) > 1);
    }
};

test "GenerateImage fixture initializer uses the same fixed tool as product init" {
    const Http = struct {
        fn perform(_: ?*anyopaque, _: lifecycle.CompletionHttpRequest, _: *const lifecycle.CompletionCancellation, _: []u8) lifecycle.CompletionTransportError!lifecycle.CompletionTransportResponse {
            return error.Unexpected;
        }
    };
    fake_core.reset();
    const runtime = try lifecycle.Runtime.initImageGenerationWithApiForTesting(std.testing.io, std.testing.allocator, &fake_api, .{ .max_sessions = 1 }, .{
        .transport = .{ .perform_fn = Http.perform },
    });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    try std.testing.expect(fake_core.image_tool_seen);
    const session = try openSession(runtime);
    try std.testing.expectEqual(@as(usize, 12), fake_core.last_allowed_tool_count);
    try std.testing.expectEqualStrings("GenerateImage", std.mem.sliceTo(&fake_core.last_allowed_tool_names[10], 0));
    const run_id = try session.prepareRun(.{ .text = "ordinary text remains available" });
    var run = try session.beginRun(run_id);
    defer run.deinit();
    var terminal = run.execute();
    defer terminal.deinit();
    try std.testing.expectEqual(@as(?lifecycle.TerminalFailure, null), terminal.failure);
    try std.testing.expectEqual(@as(usize, 0), runtime.image_budget.used.load(.acquire));
}
const deinitTestComposition = fixture.deinitTestComposition;
const createTestComposition = fixture.createTestComposition;
const createTestRuntime = fixture.createTestRuntime;
const closeOnThread = fixture.closeOnThread;
const cancelOnThread = fixture.cancelOnThread;
const failPipelineOnThread = fixture.failPipelineOnThread;
const CallbackSignal = fixture.CallbackSignal;

const ImageRunWork = struct {
    session: *lifecycle.Session,
    id: u64,
    result: ?lifecycle.TerminalResult = null,
    fn execute(self: *@This()) void {
        var run = self.session.beginRun(self.id) catch @panic("image fake Run failed");
        self.result = run.execute();
        run.deinit();
    }
};

const ImageInvocation = struct {
    tool: wire.HostToolV1,
    identity: wire.RunContextV1,
    result: wire.OwnedBytesV1 = .{ .ptr = null, .len = 0 },
    status: u32 = wire.HOST_FATAL,
    fn execute(self: *@This()) void {
        self.status = self.tool.execute.?(self.tool.ctx, &self.identity, sdk.bytesView("{\"prompt\":\"red pixel\"}"), &self.result);
    }
    fn release(self: *@This()) void {
        self.tool.release_result.?(self.tool.ctx, &self.result);
    }
};

fn imageIdentity(session: *lifecycle.Session, id: u64) wire.RunContextV1 {
    const raw: *fixture.FakeSession = @ptrCast(@alignCast(session.raw.?));
    var result = std.mem.zeroes(wire.RunContextV1);
    result.struct_size = @sizeOf(wire.RunContextV1);
    result.session = session.raw;
    result.run_id = id;
    result.session_id = sdk.bytesView(raw.session_id[0..raw.session_id_len]);
    return result;
}

const ImageNoEffects = struct {
    calls: usize = 0,
    fn perform(context: ?*anyopaque, _: lifecycle.CompletionHttpRequest, _: *const lifecycle.CompletionCancellation, _: []u8) lifecycle.CompletionTransportError!lifecycle.CompletionTransportResponse {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        return error.Unexpected;
    }
    fn commit(_: *anyopaque, _: []const u8, _: lifecycle.ImageGenerationFormat, _: *const lifecycle.CompletionCancellation) lifecycle.ImageGenerationOutputResult {
        return .{ .failed = .{ .code = .write_failed } };
    }
};

test "GenerateImage fake Core rejects wrong Run Session identity and callbacks after close" {
    for (0..4) |fault| {
        fake_core.reset();
        fake_core.setNextPlan(.controlled);
        var network: ImageNoEffects = .{};
        const runtime = try lifecycle.Runtime.initImageGenerationWithApiForTesting(std.testing.io, std.testing.allocator, &fake_api, .{ .max_sessions = 1 }, .{ .transport = .{ .context = &network, .perform_fn = ImageNoEffects.perform } });
        defer {
            runtime.shutdown() catch unreachable;
            runtime.deinit();
        }
        const session = try openSession(runtime);
        const id = try session.prepareRun(.{ .text = "identity injection" });
        var work: ImageRunWork = .{ .session = session, .id = id };
        const thread = try std.Thread.spawn(.{}, ImageRunWork.execute, .{&work});
        fake_core.waitRunEntered();
        var invocation: ImageInvocation = .{ .tool = fake_core.image_tool.?, .identity = imageIdentity(session, id) };
        // Bind the same identity through a legitimate, unavailable image result.
        invocation.execute();
        try std.testing.expectEqual(wire.HOST_FAILED, invocation.status);
        try std.testing.expect(std.mem.indexOf(u8, try sdk.borrowedBytes(.{ .ptr = invocation.result.ptr, .len = invocation.result.len }), "unavailable") != null);
        invocation.release();
        try std.testing.expect(invocation.result.ptr == null and invocation.result.len == 0);
        switch (fault) {
            0 => invocation.identity.run_id += 1,
            1 => invocation.identity.session = @ptrFromInt(1),
            2 => invocation.identity.session_id = sdk.bytesView("different-session"),
            3 => try session.close(.session_close),
            else => unreachable,
        }
        invocation.execute();
        try std.testing.expectEqual(wire.HOST_FATAL, invocation.status);
        try std.testing.expect(invocation.result.ptr == null and invocation.result.len == 0);
        fake_core.releaseControlled();
        thread.join();
        work.result.?.deinit();
        try std.testing.expectEqual(@as(usize, 0), network.calls);
        try std.testing.expectEqual(@as(usize, 1), runtime.image_results_created.load(.acquire));
        try std.testing.expectEqual(@as(usize, 1), runtime.image_results_released.load(.acquire));
    }
}

const ImageAllocationGate = struct {
    parent: std.mem.Allocator = std.testing.allocator,
    armed: std.atomic.Value(bool) = .init(false),
    entered: std.Io.Semaphore = .{},
    proceed: std.Io.Semaphore = .{},
    watched: ?[]const u8 = null,
    watched_freed: bool = false,
    watched_zero: bool = false,
    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (self.armed.swap(false, .acq_rel)) {
            self.entered.post(std.testing.io);
            self.proceed.waitUncancelable(std.testing.io);
        }
        return self.parent.rawAlloc(len, alignment, ra);
    }
    fn resize(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) bool {
        const self: *@This() = @ptrCast(@alignCast(context));
        return self.parent.rawResize(bytes, alignment, len, ra);
    }
    fn remap(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        return self.parent.rawRemap(bytes, alignment, len, ra);
    }
    fn free(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (self.watched) |target| if (bytes.ptr == target.ptr and bytes.len == target.len) {
            self.watched_freed = true;
            self.watched_zero = true;
            for (bytes) |byte| if (byte != 0) {
                self.watched_zero = false;
                break;
            };
            self.watched = null;
        };
        self.parent.rawFree(bytes, alignment, ra);
    }
};

test "GenerateImage per-Run credentials are zeroed on every exit including product init" {
    for (0..5) |action| {
        fake_core.reset();
        var observing: ImageAllocationGate = .{};
        var network: ImageNoEffects = .{};
        const runtime = if (action == 4)
            try lifecycle.Runtime.initWithApi(std.testing.io, observing.allocator(), &fake_api, .{ .max_sessions = 1 })
        else
            try lifecycle.Runtime.initImageGenerationWithApiForTesting(std.testing.io, observing.allocator(), &fake_api, .{ .max_sessions = 1 }, .{ .transport = .{ .context = &network, .perform_fn = ImageNoEffects.perform } });
        defer {
            runtime.shutdown() catch unreachable;
            runtime.deinit();
        }
        const session = try openSession(runtime);
        const id = try session.prepareRunWithTools(.{ .text = "one frozen image Run" }, .{
            .binding = .{
                .endpoint = "https://image-policy.example.test/v1/images/generations",
                .model = "fixture-image",
                .credential = "owned-run-secret",
                .output = .{ .context = &network, .commit_fn = ImageNoEffects.commit },
            },
            .transport = .{ .context = &network, .perform_fn = ImageNoEffects.perform },
        }, null);
        observing.watched = session.run_image.?.binding.credential;
        switch (action) {
            0 => try session.cancelPreparedRun(id),
            1 => try session.close(.session_close),
            2, 3, 4 => {
                var run = try session.beginRun(id);
                defer run.deinit();
                if (action == 2) _ = try session.requestTermination(id, .{ .interrupted = .user_cancel });
                var terminal = run.execute();
                defer terminal.deinit();
                if (action == 2) try std.testing.expect(terminal.termination_signal.? == .interrupted);
            },
            else => unreachable,
        }
        try std.testing.expect(observing.watched_freed);
        try std.testing.expect(observing.watched_zero);
        try std.testing.expect(session.run_image == null);
        try std.testing.expectEqual(@as(usize, 0), network.calls);
        try std.testing.expectEqual(@as(usize, 0), runtime.image_budget.used.load(.acquire));
        if (action == 4) {
            try std.testing.expect(fake_core.image_tool_seen);
            try std.testing.expect(fake_core.image_tool != null);
        }
    }
}

test "GenerateImage failed per-Run preparation releases copies and leaves the Session reusable" {
    for (0..5) |offset| {
        fake_core.reset();
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var network: ImageNoEffects = .{};
        const runtime = try lifecycle.Runtime.initImageGenerationWithApiForTesting(std.testing.io, failing.allocator(), &fake_api, .{ .max_sessions = 1 }, .{ .transport = .{ .context = &network, .perform_fn = ImageNoEffects.perform } });
        defer {
            runtime.shutdown() catch unreachable;
            runtime.deinit();
        }
        const session = try openSession(runtime);
        const input: lifecycle.ImageGenerationRunInput = .{
            .binding = .{
                .endpoint = "https://image-policy.example.test/v1/images/generations",
                .model = "fixture-image",
                .credential = "owned-run-secret",
                .output = .{ .context = &network, .commit_fn = ImageNoEffects.commit },
            },
            .transport = .{ .context = &network, .perform_fn = ImageNoEffects.perform },
        };
        failing.fail_index = failing.alloc_index + offset;
        try std.testing.expectError(error.OutOfMemory, session.prepareRunWithTools(.{ .text = "prepared text" }, input, null));
        try std.testing.expect(session.run_image == null);
        try std.testing.expectEqual(lifecycle.SessionState.idle, session.snapshot().state);
        failing.fail_index = std.math.maxInt(usize);
        const next = try session.prepareRunWithTools(.{ .text = "still usable" }, null, null);
        try session.cancelPreparedRun(next);
        try std.testing.expectEqual(@as(usize, 0), network.calls);
    }
}

test "GenerateImage callback holding lease before registration observes close and sends nothing" {
    fake_core.reset();
    fake_core.setNextPlan(.controlled);
    var gate: ImageAllocationGate = .{};
    var network: ImageNoEffects = .{};
    const runtime = try lifecycle.Runtime.initImageGenerationWithApiForTesting(std.testing.io, gate.allocator(), &fake_api, .{ .max_sessions = 1 }, .{ .transport = .{ .context = &network, .perform_fn = ImageNoEffects.perform } });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    const session = try openSession(runtime);
    try session.configureImageGenerationForTesting(.{ .endpoint = "http://127.0.0.1:1/v1/images/generations", .model = "fixture-image", .credential = "synthetic-image-key", .output = .{ .context = &network, .commit_fn = ImageNoEffects.commit } });
    const id = try session.prepareRun(.{ .text = "close registration race" });
    var work: ImageRunWork = .{ .session = session, .id = id };
    const run_thread = try std.Thread.spawn(.{}, ImageRunWork.execute, .{&work});
    fake_core.waitRunEntered();
    var invocation: ImageInvocation = .{ .tool = fake_core.image_tool.?, .identity = imageIdentity(session, id) };
    gate.armed.store(true, .release);
    const callback_thread = try std.Thread.spawn(.{}, ImageInvocation.execute, .{&invocation});
    gate.entered.waitUncancelable(std.testing.io);
    const close_thread = try std.Thread.spawn(.{}, fixture.closeOnThread, .{session});
    while (session.snapshot().state != .closing) std.testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
    gate.proceed.post(std.testing.io);
    callback_thread.join();
    invocation.release();
    close_thread.join();
    run_thread.join();
    work.result.?.deinit();
    try std.testing.expectEqual(wire.HOST_FAILED, invocation.status);
    try std.testing.expectEqual(@as(usize, 0), network.calls);
    try std.testing.expectEqual(@as(usize, 0), session.image_sends);
    try std.testing.expectEqual(@as(usize, 0), runtime.image_budget.used.load(.acquire));
}

test "GenerateImage preallocates result before sending and performs no allocation after commit" {
    const Probe = struct {
        allocator: *std.testing.FailingAllocator,
        runtime: *lifecycle.Runtime = undefined,
        body: []const u8,
        requests: usize = 0,
        commits: usize = 0,
        fn fetch(context: ?*anyopaque, _: lifecycle.CompletionHttpRequest, _: *const lifecycle.CompletionCancellation, buffer: []u8) lifecycle.CompletionTransportError!lifecycle.CompletionTransportResponse {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.requests += 1;
            @memcpy(buffer[0..self.body.len], self.body);
            return .{ .status = 200, .body = buffer[0..self.body.len] };
        }
        fn commit(context: *anyopaque, bytes: []const u8, _: lifecycle.ImageGenerationFormat, _: *const lifecycle.CompletionCancellation) lifecycle.ImageGenerationOutputResult {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.commits += 1;
            // The minimum budget is still held, including result capacity.
            std.testing.expectEqual(self.runtime.image_budget.limit, self.runtime.image_budget.used.load(.acquire)) catch return .{ .failed = .{ .code = .write_failed } };
            std.testing.expect(!self.runtime.image_budget.acquire(1)) catch return .{ .failed = .{ .code = .write_failed } };
            // Everything after commit must succeed with all future allocations disabled.
            self.allocator.fail_index = self.allocator.alloc_index;
            return .{ .saved = lifecycle.ImageGenerationReceipt.init("saved.png", bytes.len, .png) catch unreachable };
        }
    };
    const png = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/agent/testdata/generated.png", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(png);
    const b64 = try std.testing.allocator.alloc(u8, std.base64.standard.Encoder.calcSize(png.len));
    defer std.testing.allocator.free(b64);
    _ = std.base64.standard.Encoder.encode(b64, png);
    const body = try std.json.Stringify.valueAlloc(std.testing.allocator, .{ .data = .{.{ .b64_json = b64 }} }, .{});
    defer std.testing.allocator.free(body);
    fake_core.reset();
    fake_core.setNextPlan(.controlled);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var probe: Probe = .{ .allocator = &failing, .body = body };
    var limits: lifecycle.ImageGenerationLimits = .{};
    limits.memory_bytes = limits.workingBytes();
    const runtime = try lifecycle.Runtime.initImageGenerationWithApiForTesting(std.testing.io, failing.allocator(), &fake_api, .{ .max_sessions = 1 }, .{ .transport = .{ .context = &probe, .perform_fn = Probe.fetch }, .limits = limits });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    probe.runtime = runtime;
    const session = try openSession(runtime);
    try session.configureImageGenerationForTesting(.{ .endpoint = "http://127.0.0.1:1/v1/images/generations", .model = "fixture-image", .credential = "synthetic-image-key", .output = .{ .context = &probe, .commit_fn = Probe.commit } });
    const id = try session.prepareRun(.{ .text = "result ownership under pressure" });
    var work: ImageRunWork = .{ .session = session, .id = id };
    const thread = try std.Thread.spawn(.{}, ImageRunWork.execute, .{&work});
    defer {
        failing.fail_index = std.math.maxInt(usize);
        fake_core.releaseControlled();
        thread.join();
        work.result.?.deinit();
    }
    fake_core.waitRunEntered();
    var invocation: ImageInvocation = .{ .tool = fake_core.image_tool.?, .identity = imageIdentity(session, id) };
    failing.fail_index = failing.alloc_index;
    invocation.execute();
    try std.testing.expectEqual(wire.HOST_FAILED, invocation.status);
    try std.testing.expectEqualStrings("{\"status\":\"capacity\"}", try sdk.borrowedBytes(.{ .ptr = invocation.result.ptr, .len = invocation.result.len }));
    try std.testing.expectEqual(@as(usize, 0), probe.requests);
    try std.testing.expectEqual(@as(usize, 0), probe.commits);
    invocation.release();
    failing.fail_index = std.math.maxInt(usize);
    invocation.execute();
    try std.testing.expectEqual(wire.HOST_OK, invocation.status);
    try std.testing.expectEqual(@as(usize, 1), probe.requests);
    try std.testing.expectEqual(@as(usize, 1), probe.commits);
    try std.testing.expect(std.mem.indexOf(u8, try sdk.borrowedBytes(.{ .ptr = invocation.result.ptr, .len = invocation.result.len }), "\"status\":\"saved\"") != null);
    try std.testing.expect(runtime.image_budget.used.load(.acquire) > 0);
    var blocked: ImageInvocation = .{ .tool = invocation.tool, .identity = invocation.identity };
    blocked.execute(); // A retained result leaves insufficient working capacity.
    try std.testing.expectEqual(wire.HOST_FAILED, blocked.status);
    try std.testing.expectEqualStrings("{\"status\":\"capacity\"}", try sdk.borrowedBytes(.{ .ptr = blocked.result.ptr, .len = blocked.result.len }));
    try std.testing.expectEqual(@as(usize, 1), probe.requests);
    blocked.release();
    invocation.release();
    try std.testing.expectEqual(@as(usize, 0), runtime.image_budget.used.load(.acquire));
    try std.testing.expectEqual(@as(usize, 3), runtime.image_results_created.load(.acquire));
    try std.testing.expectEqual(@as(usize, 3), runtime.image_results_released.load(.acquire));
}

test "active input correlates adoption before receipt and never changes the Run" {
    const Mode = struct { adopt: bool, omit_event: bool = false, fail_run: bool = false };
    for ([_]Mode{ .{ .adopt = false }, .{ .adopt = true }, .{ .adopt = true, .omit_event = true }, .{ .adopt = true, .fail_run = true } }) |mode| {
        fake_core.reset();
        fake_core.input_enabled = true;
        fake_core.adopt_input_before_receipt = mode.adopt;
        fake_core.omit_input_adopted_event = mode.omit_event;
        if (mode.fail_run) fake_core.forced_input_run_status = wire.STATUS_RESOURCE_LIMIT;
        fake_core.setNextPlan(.controlled);
        const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
        defer {
            shutdownTestComposition(runtime) catch unreachable;
            deinitTestComposition(runtime);
        }
        const session = try openSession(runtime);
        const run_id = try submitSession(session, "original");
        fake_core.waitRunEntered();
        const handle = lifecycle.RunControl{ .block = session.control_block, .run_id = run_id, .generation = session.active_run_generation };
        var lease = handle.tryAcquireLease().?;
        defer lease.deinit();
        // The fake announces run entry before the starting callback is delivered.
        while (!lease.inputObservation().ready) std.Thread.yield() catch {};
        try std.testing.expectEqual(lifecycle.InputSubmission{ .accepted = 1 }, lease.submitInput(77, "new constraint"));
        try std.testing.expectEqual(lifecycle.InputSubmission{ .rejected = .invalid_input }, lease.submitInput(77, "duplicate"));
        try std.testing.expectEqual(!mode.adopt or mode.omit_event, lease.inputObservation().blocksAutomaticAllow());
        fake_core.forced_input_status = wire.STATUS_RESOURCE_LIMIT;
        try std.testing.expectEqual(lifecycle.InputSubmission{ .rejected = .resource_limit }, lease.submitInput(78, "refused"));
        fake_core.forced_input_status = null;
        fake_core.releaseControlled();
        try session.waitRun(run_id);
        var terminal = takeTestTerminal(session, run_id);
        defer terminal.deinit();
        try std.testing.expectEqual(@as(?lifecycle.TerminalFailure, if (mode.fail_run) .abi_status else null), terminal.failure);
        try std.testing.expectEqual(@as(u32, 1), terminal.input_counts.?.accepted);
        try std.testing.expectEqual(@as(u32, @intFromBool(mode.adopt)), terminal.input_counts.?.adopted);
        try std.testing.expectEqual(lifecycle.InputSubmission{ .rejected = .too_late }, lease.submitInput(79, "late"));
        try std.testing.expectEqual(@as(usize, 1), fake_core.run_calls);
    }
}

test "active input rejects a lease before Core startup without retaining the message" {
    fake_core.reset();
    const runtime = try createTestRuntime(.{ .max_sessions = 1 });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    const session = try openSession(runtime);
    const id = try session.prepareRun(.{ .text = "root" });
    var run = try session.beginRun(id);
    var lease = run.control().tryAcquireLease().?;
    try std.testing.expectEqual(lifecycle.InputSubmission{ .rejected = .not_ready }, lease.submitInput(1, "early"));
    lease.deinit();
    var terminal = run.execute();
    terminal.deinit();
    run.deinit();
}

test "active input call must return before Run completion is published" {
    fake_core.reset();
    fake_core.input_enabled = true;
    var signal: CallbackSignal = .{};
    signal.arm();
    fake_core.input_signal = &signal;
    fake_core.setNextPlan(.controlled);
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);
    const id = try submitSession(session, "root");
    fake_core.waitRunEntered();
    const handle = lifecycle.RunControl{ .block = session.control_block, .run_id = id, .generation = session.active_run_generation };
    var lease = handle.tryAcquireLease().?;
    defer lease.deinit();
    while (!lease.inputObservation().ready) std.Thread.yield() catch {};
    const Submission = struct {
        lease: *const lifecycle.RunControlLease,
        result: lifecycle.InputSubmission = .unknown,
        fn run(self: *@This()) void {
            self.result = self.lease.submitInput(1, "still in SDK");
        }
    };
    var submission: Submission = .{ .lease = &lease };
    const thread = try std.Thread.spawn(.{}, Submission.run, .{&submission});
    signal.waitUntilEntered();
    fake_core.releaseControlled();
    // Observe the worker after it has closed input admission, not after a sleep.
    while (true) {
        session.lock();
        const running = session.core_call_in_progress;
        const done = session.run_done;
        session.unlock();
        try std.testing.expect(!done);
        if (!running) break;
        std.Thread.yield() catch {};
    }
    try std.testing.expect(lease.inputObservation().submitting);
    try std.testing.expect(!lease.inputObservation().ready);
    signal.markFinished();
    thread.join();
    try std.testing.expectEqual(lifecycle.InputSubmission{ .accepted = 1 }, submission.result);
    try session.waitRun(id);
    var terminal = takeTestTerminal(session, id);
    defer terminal.deinit();
    try std.testing.expect(terminal.failure == null);
    try std.testing.expectEqual(@as(u32, 1), terminal.input_counts.?.accepted);
    try std.testing.expectEqual(@as(u32, 0), terminal.input_counts.?.adopted);
}

test "recovery capacity observation counts only an owned route scheduled for release" {
    fake_core.reset();
    const runtime = try createTestRuntime(.{ .max_sessions = 1 });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    try std.testing.expect(runtime.restoreAdmission(null) == .available);
    try std.testing.expect(runtime.restoreAdmission(0) != .available);
    try std.testing.expectEqual(.unavailable, runtime.restoreAdmission(std.math.maxInt(u64)));
    const session = try openSession(runtime);
    const route = session.id;
    try std.testing.expect(runtime.restoreAdmission(null) != .available);
    try std.testing.expect(runtime.restoreAdmission(route) == .available);
    try std.testing.expect(runtime.restoreAdmission(route + 1) != .available);
    // Pure refresh preserves admission. Apply has a distinct busy result,
    // which must never be interpreted as Session capacity pressure.
    runtime.mcp_refresh_running = true;
    try std.testing.expectEqual(.available, runtime.restoreAdmission(route));
    runtime.mcp_configuration_applying = true;
    try std.testing.expectEqual(.mcp_busy, runtime.restoreAdmission(route));
    try std.testing.expectEqual(.mcp_busy, runtime.restoreAdmission(null));
    runtime.mcp_configuration_applying = false;
    runtime.mcp_refresh_running = false;
    try session.close(.session_close);
    try runtime.releaseClosedSession(session);
    try std.testing.expect(runtime.restoreAdmission(route) != .available);
    try std.testing.expect(runtime.restoreAdmission(null) == .available);
    const next = try openSession(runtime);
    try std.testing.expect(runtime.restoreAdmission(route) != .available);
    try std.testing.expect(runtime.restoreAdmission(next.id) == .available);
    const next_route = next.id;
    try runtime.shutdown();
    try std.testing.expect(runtime.restoreAdmission(null) != .available);
    try std.testing.expect(runtime.restoreAdmission(next_route) != .available);
}

const CheckpointCollector = struct {
    bytes: [256]u8 = undefined,
    len: usize = 0,
    result: lifecycle.CheckpointSinkWriteResult = .ok,

    fn sink(self: *CheckpointCollector) lifecycle.CheckpointSink {
        return .{ .context = self, .write_fn = write };
    }

    fn write(context: ?*anyopaque, chunk: []const u8) lifecycle.CheckpointSinkWriteResult {
        const self: *CheckpointCollector = @ptrCast(@alignCast(context orelse return .contract_failed));
        if (self.result != .ok) return self.result;
        if (chunk.len > self.bytes.len - self.len) return .io_failed;
        @memcpy(self.bytes[self.len..][0..chunk.len], chunk);
        self.len += chunk.len;
        return .ok;
    }
};

const CheckpointRestoreSource = struct {
    bytes: []const u8,
    offset: usize = 0,
    max_read: usize = 3,
    cancelled: bool = false,

    fn source(self: *CheckpointRestoreSource) lifecycle.CheckpointSource {
        return .{ .context = self, .read_fn = read };
    }

    fn read(context: ?*anyopaque, destination: []u8) lifecycle.CheckpointSourceReadResult {
        const self: *CheckpointRestoreSource = @ptrCast(@alignCast(context.?));
        if (self.cancelled) return .cancelled;
        if (self.offset == self.bytes.len) return .eof;
        const count = @min(
            @min(destination.len, self.max_read),
            self.bytes.len - self.offset,
        );
        @memcpy(destination[0..count], self.bytes[self.offset..][0..count]);
        self.offset += count;
        return .{ .bytes = count };
    }
};

const checkpoint_test_limits: lifecycle.CheckpointLimits = .{
    .hard_bytes = 1024,
    .max_section_bytes = 1024,
    .max_string_bytes = 512,
    .max_messages = 32,
    .max_blocks_per_message = 16,
    .chunk_bytes = 512,
};

const session_protocol_cases = [_]struct {
    protocol: lifecycle.Protocol,
    provider_code: u32,
    protocol_code: u32,
}{
    .{ .protocol = .openai_responses, .provider_code = wire.PROVIDER_OPENAI, .protocol_code = wire.OPENAI_PROTOCOL_RESPONSES },
    .{ .protocol = .openai_chat_completions, .provider_code = wire.PROVIDER_OPENAI, .protocol_code = wire.PROTOCOL_DEFAULT },
    .{ .protocol = .anthropic_messages, .provider_code = wire.PROVIDER_ANTHROPIC, .protocol_code = wire.PROTOCOL_DEFAULT },
    .{ .protocol = .gemini_native, .provider_code = wire.PROVIDER_GEMINI, .protocol_code = wire.PROTOCOL_DEFAULT },
};

fn fixtureModelBinding(protocol: lifecycle.Protocol) lifecycle.ModelBinding {
    return .{
        .target = .{
            .provider_id = "fixture-provider",
            .protocol = protocol,
            .base_url = "",
            .model = "fixture-model",
        },
        .credential = "fixture-secret",
    };
}

fn restoreOptions(
    source: lifecycle.CheckpointSource,
    logical_session_id: []const u8,
    last_run_id: u64,
    last_compact_id: u64,
) lifecycle.SessionRestoreOptions {
    const workspace_root = if (std.fs.path.sep == '\\') "C:\\tmp\\metawork-gate2" else "/tmp/metawork-gate2";
    const temporary_root = if (std.fs.path.sep == '\\') "C:\\tmp" else "/tmp";
    return .{
        .session = .{
            .model_binding = fixtureModelBinding(.anthropic_messages),
            .permission_mode = .default,
            .shell_policy = .disabled,
            .workspace = .{
                .canonical_root = workspace_root,
                .trust = .{ .temporary = temporary_root },
            },
            .operation_id_floor = .{
                .last_run_id = last_run_id,
                .last_compact_id = last_compact_id,
            },
        },
        .checkpoint_limits = checkpoint_test_limits,
        .source = source,
        .expectation = .{
            .logical_session_id = logical_session_id,
            .checkpoint_generation = 3,
            .last_run_id = last_run_id,
            .last_compact_id = last_compact_id,
            .model = "fixture-model",
        },
    };
}

const McpFixtureTransport = struct {
    fn descriptor(self: *McpFixtureTransport) lifecycle.McpTransport {
        return .{ .context = self, .open_fn = open, .request_fn = request, .notify_fn = notify, .close_fn = close };
    }
    fn open(context: *anyopaque, _: lifecycle.McpPurpose, _: lifecycle.McpEra, _: u32) lifecycle.McpOpenOutcome {
        return .{ .connection = context };
    }
    fn request(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: u32, _: lifecycle.McpCancellation) lifecycle.McpExchangeOutcome {
        return .{ .failure = .fatal };
    }
    fn notify(_: *anyopaque, _: []const u8, _: u32, _: lifecycle.McpCancellation) ?lifecycle.McpTransportFailure {
        return .fatal;
    }
    fn close(_: *anyopaque) void {}
    fn deinit(_: *anyopaque) void {}
};

const CanonicalUnavailableMcpTransport = struct {
    opens: std.atomic.Value(usize) = .init(0),

    fn descriptor(self: *CanonicalUnavailableMcpTransport) lifecycle.McpTransport {
        return .{ .context = self, .open_fn = open, .request_fn = request, .notify_fn = notify, .close_fn = close };
    }
    fn open(context: *anyopaque, _: lifecycle.McpPurpose, _: lifecycle.McpEra, _: u32) lifecycle.McpOpenOutcome {
        const self: *CanonicalUnavailableMcpTransport = @ptrCast(@alignCast(context));
        _ = self.opens.fetchAdd(1, .acq_rel);
        return .{ .failure = .network };
    }
    fn request(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: u32, _: lifecycle.McpCancellation) lifecycle.McpExchangeOutcome {
        return .{ .failure = .fatal };
    }
    fn notify(_: *anyopaque, _: []const u8, _: u32, _: lifecycle.McpCancellation) ?lifecycle.McpTransportFailure {
        return .fatal;
    }
    fn close(_: *anyopaque) void {}
    fn deinit(_: *anyopaque) void {}
};

test "canonical AgentCore refresh invokes the Host MCP connector and returns a bounded unavailable catalog" {
    var transport: CanonicalUnavailableMcpTransport = .{};
    var transport_owner = lifecycle.McpTransportOwner.init(
        transport.descriptor(),
        CanonicalUnavailableMcpTransport.deinit,
    );
    var input = try lifecycle.McpRuntimeInput.init(std.testing.allocator, 1, &.{.{
        .id = "offline",
        .transport_owner = &transport_owner,
        .transport = .streamable_http,
        .namespace = "offline",
        .client_name = "MetaWork",
        .client_version = "test",
        .timeout_ms = 100,
        .configuration_fingerprint = [_]u8{1} ** 32,
    }});
    defer input.deinit();
    const runtime = try lifecycle.Runtime.init(std.testing.io, std.testing.allocator, .{
        .max_sessions = 1,
        .mcp_input = &input,
    });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    try std.testing.expectEqual(@as(usize, 0), transport.opens.load(.acquire));
    const activation = switch (try runtime.activateMcp()) {
        .activated => |value| value,
        else => return error.TestUnexpectedResult,
    };
    defer activation.deinit();
    try std.testing.expect(transport.opens.load(.acquire) > 0);
    try std.testing.expectEqual(lifecycle.McpActivationState.unavailable, activation.state());
    try std.testing.expectEqual(@as(usize, 0), activation.catalogServers().len);
    try std.testing.expect(activation.catalogIssues().len > 0);
    try std.testing.expectEqualDeep(
        lifecycle.mcpBindingIdentity("offline"),
        activation.catalogIssues()[0].binding_identity,
    );
}

test "canonical AgentCore accepts an empty complete MCP Session replacement" {
    const runtime = try lifecycle.Runtime.init(std.testing.io, std.testing.allocator, .{
        .max_sessions = 1,
    });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    const workspace_root = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(workspace_root);
    const session = try runtime.createSession(.{
        .model_binding = fixtureModelBinding(.anthropic_messages),
        .permission_mode = .default,
        .shell_policy = .unrestricted,
        .workspace = .{
            .canonical_root = workspace_root,
            .trust = .explicitly_trusted,
        },
        .canonical_user_home = workspace_root,
        .workspace_epoch = "canonical-mcp-empty-replacement",
    });
    try session.updateMcpSelection(null);
    try std.testing.expectEqual(lifecycle.SessionState.idle, session.snapshot().state);
}

test "MCP Runtime takes one complete input and activation publishes unavailable health" {
    fake_core.reset();
    var transport: McpFixtureTransport = .{};
    var transport_owner = lifecycle.McpTransportOwner.init(
        transport.descriptor(),
        McpFixtureTransport.deinit,
    );
    var input = try lifecycle.McpRuntimeInput.init(std.testing.allocator, 1, &.{.{
        .id = "fixture",
        .transport_owner = &transport_owner,
        .transport = .stdio,
        .namespace = "fixture",
        .client_name = "MetaWork",
        .client_version = "test",
        .timeout_ms = 1000,
        .configuration_fingerprint = [_]u8{1} ** 32,
    }});
    defer input.deinit();
    const runtime = try createTestRuntime(.{
        .max_sessions = 1,
        .mcp_input = &input,
    });
    const activation = switch (try runtime.activateMcp()) {
        .activated => |value| value,
        else => return error.TestUnexpectedResult,
    };
    defer activation.deinit();
    try std.testing.expectEqual(lifecycle.McpActivationState.unavailable, activation.state());
    try std.testing.expectEqual(@as(usize, 1), activation.serverHealth().len);
    try std.testing.expectEqual(
        lifecycle.McpActivationServerState.unavailable,
        activation.serverHealth()[0].state,
    );
    try std.testing.expectEqual(@as(?*lifecycle.McpSelection, null), activation.takeSelection());
    fake_core.forceNextMcpRefreshStatus(wire.STATUS_CORE_ERROR);
    switch (try runtime.activateMcp()) {
        .unavailable => |reason| try std.testing.expectEqual(
            lifecycle.McpActivationUnavailableReason.refresh_failed,
            reason,
        ),
        else => return error.TestUnexpectedResult,
    }
    try runtime.shutdown();
    runtime.deinit();
    fake_core.lock();
    const count = fake_core.mcp_server_count;
    const valid = fake_core.mcp_descriptor_valid;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expect(valid);
}

test "MCP empty Runtime accepts the initial declarative configuration apply" {
    fake_core.reset();
    const runtime = try lifecycle.Runtime.initWithApi(
        std.testing.io,
        std.testing.allocator,
        &fake_api,
        .{ .max_sessions = 1 },
    );
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    var transport: McpFixtureTransport = .{};
    var owner = lifecycle.McpTransportOwner.init(
        transport.descriptor(),
        McpFixtureTransport.deinit,
    );
    var replacement = try lifecycle.McpRuntimeInput.init(std.testing.allocator, 1, &.{.{
        .id = "initial",
        .transport_owner = &owner,
        .transport = .stdio,
        .namespace = "initial",
        .client_name = "MetaWork",
        .client_version = "test",
        .timeout_ms = 100,
        .configuration_fingerprint = [_]u8{1} ** 32,
    }});
    defer replacement.deinit();
    try std.testing.expectEqual(
        lifecycle.McpConfigurationApplyOutcome.applied,
        try runtime.applyMcpConfiguration(&replacement),
    );
    try std.testing.expectEqual(@as(usize, 1), fake_core.mcp_configuration_applies);
    try std.testing.expectEqual(@as(usize, 1), fake_core.last_mcp_apply_server_count);
    const activation = switch (try runtime.activateMcp()) {
        .activated => |value| value,
        else => return error.TestUnexpectedResult,
    };
    activation.deinit();
}

test "MCP Runtime declaratively applies a replacement configuration" {
    fake_core.reset();
    var first_transport: McpFixtureTransport = .{};
    var first_owner = lifecycle.McpTransportOwner.init(
        first_transport.descriptor(),
        McpFixtureTransport.deinit,
    );
    var initial = try lifecycle.McpRuntimeInput.init(std.testing.allocator, 1, &.{.{
        .id = "first",
        .transport_owner = &first_owner,
        .transport = .stdio,
        .namespace = "first",
        .client_name = "MetaWork",
        .client_version = "test",
        .timeout_ms = 100,
        .configuration_fingerprint = [_]u8{1} ** 32,
    }});
    defer initial.deinit();
    const runtime = try lifecycle.Runtime.initWithApi(
        std.testing.io,
        std.testing.allocator,
        &fake_api,
        .{
            .max_sessions = 1,
            .mcp_input = &initial,
        },
    );
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }

    var second_transport: McpFixtureTransport = .{};
    var second_owner = lifecycle.McpTransportOwner.init(
        second_transport.descriptor(),
        McpFixtureTransport.deinit,
    );
    var replacement = try lifecycle.McpRuntimeInput.init(std.testing.allocator, 2, &.{.{
        .id = "second",
        .transport_owner = &second_owner,
        .transport = .stdio,
        .namespace = "second",
        .client_name = "MetaWork",
        .client_version = "test",
        .timeout_ms = 100,
        .configuration_fingerprint = [_]u8{2} ** 32,
    }});
    defer replacement.deinit();
    try std.testing.expectEqual(
        lifecycle.McpConfigurationApplyOutcome.applied,
        try runtime.applyMcpConfiguration(&replacement),
    );
    try std.testing.expectEqual(@as(usize, 1), fake_core.mcp_configuration_applies);
    try std.testing.expectEqual(@as(usize, 1), fake_core.last_mcp_apply_server_count);

    var rejected_transport: McpFixtureTransport = .{};
    var rejected_owner = lifecycle.McpTransportOwner.init(
        rejected_transport.descriptor(),
        McpFixtureTransport.deinit,
    );
    var rejected = try lifecycle.McpRuntimeInput.init(std.testing.allocator, 3, &.{.{
        .id = "rejected",
        .transport_owner = &rejected_owner,
        .transport = .stdio,
        .namespace = "rejected",
        .client_name = "MetaWork",
        .client_version = "test",
        .timeout_ms = 100,
        .configuration_fingerprint = [_]u8{3} ** 32,
    }});
    defer rejected.deinit();
    fake_core.forceNextMcpApplyDisposition(wire.MCP_APPLY_REJECTED);
    try std.testing.expectEqual(
        lifecycle.McpConfigurationApplyOutcome.rejected,
        try runtime.applyMcpConfiguration(&rejected),
    );
}

test "MCP refresh failure immediately invalidates the previous selection generation" {
    fake_core.reset();
    const runtime = try createTestRuntime(.{ .max_sessions = 1 });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    const projection = try runtime.refreshMcpCatalog();
    defer projection.deinit();
    const selection = try runtime.createMcpSelection(projection, &.{});
    defer selection.deinit();
    fake_core.forceNextMcpRefreshStatus(wire.STATUS_CORE_ERROR);
    try std.testing.expectError(error.McpRefreshFailed, runtime.refreshMcpCatalog());
    try std.testing.expectError(
        error.StaleMcpSelection,
        runtime.createMcpSelection(projection, &.{}),
    );
}

test "MCP typed refresh rejection retains the published generation without extending it" {
    for ([_]u32{ wire.STATUS_BUSY, wire.STATUS_OUT_OF_MEMORY, wire.STATUS_RESOURCE_LIMIT }) |status| {
        fake_core.reset();
        const runtime = try createTestRuntime(.{ .max_sessions = 1 });
        defer {
            runtime.shutdown() catch unreachable;
            runtime.deinit();
        }
        const projection = try runtime.refreshMcpCatalog();
        defer projection.deinit();
        fake_core.forceNextMcpRefreshStatus(status);
        try std.testing.expectError(error.McpRefreshRejected, runtime.refreshMcpCatalog());
        const retained = try runtime.createMcpSelection(projection, &.{});
        retained.deinit();
    }
}

test "MCP catalog refresh binds explicit Session selection and idle replacement" {
    fake_core.reset();
    const runtime = try createTestRuntime(.{ .max_sessions = 1 });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    const projection = try runtime.refreshMcpCatalog();
    defer projection.deinit();
    try std.testing.expectEqual(@as(u64, 7), projection.catalogGeneration());
    const selection = try runtime.createMcpSelection(projection, &.{});
    defer selection.deinit();
    const workspace_root = if (std.fs.path.sep == '\\')
        "C:\\tmp\\metawork-mcp-selection"
    else
        "/tmp/metawork-mcp-selection";
    const temporary_root = if (std.fs.path.sep == '\\') "C:\\tmp" else "/tmp";
    const session = try runtime.createSession(.{
        .model_binding = fixtureModelBinding(.anthropic_messages),
        .permission_mode = .default,
        .shell_policy = .disabled,
        .workspace = .{
            .canonical_root = workspace_root,
            .trust = .{ .temporary = temporary_root },
        },
        .mcp_selection = selection,
    });
    var saved = try session.captureRestoreInputs();
    defer saved.deinit() catch unreachable;
    try std.testing.expect(saved.mcp != null);
    try session.updateMcpSelection(null);
    var empty = try session.captureRestoreInputs();
    defer empty.deinit() catch unreachable;
    try std.testing.expect(empty.mcp == null);
    fake_core.lock();
    const updates_after_clear = fake_core.mcp_updates;
    const selectors_after_clear = fake_core.last_mcp_update_selector_count;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), updates_after_clear);
    try std.testing.expectEqual(@as(?u64, 0), selectors_after_clear);
    try session.updateMcpSelection(selection);
    const queued_run = try session.prepareRun(.{ .text = "hold selection" });
    try std.testing.expectError(
        error.SessionNotIdle,
        session.updateMcpSelection(null),
    );
    try session.cancelPreparedRun(queued_run);
    var retained = try session.captureRestoreInputs();
    try std.testing.expect(retained.mcp != null);
    try retained.deinit();
    fake_core.lock();
    const refreshes = fake_core.mcp_refreshes;
    const descriptions = fake_core.mcp_descriptions;
    const updates = fake_core.mcp_updates;
    const last_selector_count = fake_core.last_mcp_update_selector_count;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), refreshes);
    try std.testing.expectEqual(@as(usize, 1), descriptions);
    try std.testing.expectEqual(@as(usize, 2), updates);
    try std.testing.expectEqual(@as(?u64, 0), last_selector_count);
}

test "MCP selection mutation preserves reusable and poison status contracts" {
    fake_core.reset();
    const runtime = try createTestRuntime(.{ .max_sessions = 1 });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    const projection = try runtime.refreshMcpCatalog();
    defer projection.deinit();
    const selection = try runtime.createMcpSelection(projection, &.{});
    defer selection.deinit();
    const session = try runtime.createSession(.{
        .model_binding = fixtureModelBinding(.anthropic_messages),
        .permission_mode = .default,
        .shell_policy = .disabled,
        .workspace = .{
            .canonical_root = if (std.fs.path.sep == '\\') "C:\\tmp\\metawork-mcp-status" else "/tmp/metawork-mcp-status",
            .trust = .{ .temporary = if (std.fs.path.sep == '\\') "C:\\tmp" else "/tmp" },
        },
        .mcp_selection = selection,
    });
    fake_core.forceNextMcpUpdateStatus(wire.STATUS_BUSY);
    try std.testing.expectError(error.SessionNotIdle, session.updateMcpSelection(null));
    var after_busy = try session.captureRestoreInputs();
    try std.testing.expect(after_busy.mcp != null);
    try after_busy.deinit();
    try std.testing.expectEqual(lifecycle.SessionState.idle, session.snapshot().state);
    fake_core.forceNextMcpUpdateStatus(wire.STATUS_CHECKPOINT_BUDGET_REQUIRED);
    try std.testing.expectError(
        error.McpCheckpointBudgetRequired,
        session.updateMcpSelection(selection),
    );
    try std.testing.expectEqual(lifecycle.SessionState.idle, session.snapshot().state);
    try session.updateMcpSelection(null);
    var empty = try session.captureRestoreInputs();
    defer empty.deinit() catch unreachable;
    try std.testing.expect(empty.mcp == null);
    fake_core.forceNextMcpUpdateStatus(wire.STATUS_STALE_CATALOG);
    try std.testing.expectError(
        error.McpSelectionUpdateFailed,
        session.updateMcpSelection(selection),
    );
    try std.testing.expectEqual(lifecycle.SessionState.poisoned, session.snapshot().state);
}

const CompactThreadContext = struct {
    session: *lifecycle.Session,
    operation_id: u64,
    result: ?lifecycle.CompactTerminalResult = null,
};

fn compactOnThread(context: *CompactThreadContext) void {
    context.result = context.session.executePreparedCompact(
        context.operation_id,
    ) catch unreachable;
}

test "manual compact is a typed Session operation and preserves Run identity" {
    fake_core.reset();
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);
    const operation_id = try session.prepareCompact();
    try std.testing.expectEqual(@as(u64, 1), operation_id);
    try std.testing.expectEqual(
        lifecycle.SessionState.compact_queued,
        session.snapshot().state,
    );
    try std.testing.expectError(
        error.SessionNotIdle,
        session.prepareRun(.{ .text = "must wait" }),
    );
    var terminal = try session.executePreparedCompact(operation_id);
    defer terminal.deinit();
    try std.testing.expectEqual(@as(?lifecycle.CompactOutcome, .compacted), terminal.outcome);
    try std.testing.expectEqual(@as(u64, 100), terminal.before_context_tokens);
    try std.testing.expectEqual(@as(u64, 40), terminal.after_context_tokens);
    try std.testing.expectEqual(@as(u64, 5), terminal.input_tokens);
    try std.testing.expectEqual(lifecycle.SessionDisposition.reusable, terminal.session_disposition_at_completion);
    try std.testing.expectEqual(lifecycle.SessionState.idle, session.snapshot().state);

    const run_id = try submitSession(session, "continue after compact");
    try session.waitRun(run_id);
    var run_terminal = takeTestTerminal(session, run_id);
    defer run_terminal.deinit();
    try std.testing.expectEqual(@as(u64, 1), run_id);

    fake_core.forceNextCompactStatus(wire.STATUS_CHECKPOINT_BUDGET_REQUIRED);
    const budget_operation_id = try session.prepareCompact();
    var budget_terminal = try session.executePreparedCompact(budget_operation_id);
    defer budget_terminal.deinit();
    try std.testing.expectEqual(
        @as(?sdk.Status, .checkpoint_budget_required),
        budget_terminal.abi_status,
    );
    try std.testing.expectEqual(
        @as(?lifecycle.TerminalFailure, .abi_status),
        budget_terminal.failure,
    );
    try std.testing.expectEqual(
        lifecycle.SessionDisposition.reusable,
        budget_terminal.session_disposition_at_completion,
    );
    try std.testing.expectEqual(lifecycle.SessionState.idle, session.snapshot().state);

    const retry_run_id = try submitSession(session, "continue after compact budget rejection");
    try session.waitRun(retry_run_id);
    var retry_terminal = takeTestTerminal(session, retry_run_id);
    defer retry_terminal.deinit();
    try std.testing.expectEqual(@as(?sdk.StopReason, .end_turn), retry_terminal.stop_reason);
    try closeSession(session, .session_close);
}

test "manual compact cancellation waits for the typed aborted result" {
    fake_core.reset();
    fake_core.setNextPlan(.controlled);
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);
    const operation_id = try session.prepareCompact();
    var context = CompactThreadContext{
        .session = session,
        .operation_id = operation_id,
    };
    {
        const thread = try std.Thread.spawn(.{}, compactOnThread, .{&context});
        defer thread.join();
        defer fake_core.releaseControlled();
        // Host phase publication precedes the SDK call. This test exercises
        // aborting an entered compact, so synchronize on the fake Core fact.
        var entered = false;
        for (0..5000) |_| {
            fake_core.lock();
            entered = fake_core.compact_calls == 1;
            fake_core.unlock();
            if (entered) break;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        }
        try std.testing.expect(entered);
        try session.requestCompactCancellation(operation_id, .user_cancel);
    }
    var terminal = context.result.?;
    defer terminal.deinit();
    try std.testing.expectEqual(@as(?lifecycle.CompactOutcome, .aborted), terminal.outcome);
    try std.testing.expectEqual(@as(?sdk.Status, .ok), terminal.abort_status);
    try std.testing.expectEqual(@as(?lifecycle.ExternalInterruption, .user_cancel), terminal.interruption);
    fake_core.lock();
    const abort_calls = fake_core.compact_abort_calls;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), abort_calls);
    try closeSession(session, .session_close);
}

test "accepted compact cancellation requires the typed aborted result" {
    fake_core.reset();
    fake_core.setNextPlan(.controlled);
    fake_core.forceNextCompactAbortStatus(wire.STATUS_OK);
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);
    const operation_id = try session.prepareCompact();
    var context = CompactThreadContext{
        .session = session,
        .operation_id = operation_id,
    };
    const thread = try std.Thread.spawn(.{}, compactOnThread, .{&context});
    try session.waitForState(.compacting);
    try session.requestCompactCancellation(operation_id, .user_cancel);
    fake_core.releaseControlled();
    thread.join();
    var terminal = context.result.?;
    defer terminal.deinit();
    try std.testing.expectEqual(
        @as(?lifecycle.TerminalFailure, .dependency_contract),
        terminal.failure,
    );
    try std.testing.expectEqual(@as(?sdk.Status, .ok), terminal.abort_status);
    try std.testing.expectEqual(
        lifecycle.SessionDisposition.poisoned,
        terminal.session_disposition_at_completion,
    );
    try std.testing.expectEqual(lifecycle.SessionState.poisoned, session.snapshot().state);
    try closeSession(session, .session_close);
}

test "malformed compact result poisons Session and queued compact can be cancelled" {
    fake_core.reset();
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);
    const cancelled_id = try session.prepareCompact();
    try session.cancelPreparedCompact(cancelled_id);
    try std.testing.expectEqual(lifecycle.SessionState.idle, session.snapshot().state);
    fake_core.makeNextCompactResultMalformed();
    const operation_id = try session.prepareCompact();
    var terminal = try session.executePreparedCompact(operation_id);
    defer terminal.deinit();
    try std.testing.expectEqual(
        @as(?lifecycle.TerminalFailure, .dependency_contract),
        terminal.failure,
    );
    try std.testing.expectEqual(lifecycle.SessionDisposition.poisoned, terminal.session_disposition_at_completion);
    try std.testing.expectEqual(lifecycle.SessionState.poisoned, session.snapshot().state);
    try closeSession(session, .session_close);
}

test "Runtime rejects missing revision 26 child tables and entries" {
    var api = fake_api;
    api.skill = null;
    try std.testing.expectError(
        error.UnsupportedAbi,
        lifecycle.Runtime.initWithApi(
            std.testing.io,
            std.testing.allocator,
            &api,
            .{ .max_sessions = 1 },
        ),
    );

    var session_api = api.session.?.*;
    session_api.submit_input = null;
    api = fake_api;
    api.session = &session_api;
    try std.testing.expectError(error.UnsupportedAbi, lifecycle.Runtime.initWithApi(
        std.testing.io,
        std.testing.allocator,
        &api,
        .{ .max_sessions = 1 },
    ));
    session_api = fake_api.session.?.*;
    session_api.update_credential = null;
    api = fake_api;
    api.session = &session_api;
    try std.testing.expectError(error.UnsupportedAbi, lifecycle.Runtime.initWithApi(
        std.testing.io,
        std.testing.allocator,
        &api,
        .{ .max_sessions = 1 },
    ));
    inline for (.{ "goal", "team" }) |field| {
        api = fake_api;
        @field(api, field) = null;
        try std.testing.expectError(error.UnsupportedAbi, lifecycle.Runtime.initWithApi(
            std.testing.io,
            std.testing.allocator,
            &api,
            .{ .max_sessions = 1 },
        ));
    }
    inline for (.{ "get", "set", "update", "clear" }) |field| {
        var table = fake_api.goal.?.*;
        @field(table, field) = null;
        api = fake_api;
        api.goal = &table;
        try std.testing.expectError(error.UnsupportedAbi, lifecycle.Runtime.initWithApi(
            std.testing.io,
            std.testing.allocator,
            &api,
            .{ .max_sessions = 1 },
        ));
    }
    inline for (.{ "describe", "poll" }) |field| {
        var table = fake_api.team.?.*;
        @field(table, field) = null;
        api = fake_api;
        api.team = &table;
        try std.testing.expectError(error.UnsupportedAbi, lifecycle.Runtime.initWithApi(
            std.testing.io,
            std.testing.allocator,
            &api,
            .{ .max_sessions = 1 },
        ));
    }
    session_api = fake_api.session.?.*;
    session_api.run_input = null;
    api = fake_api;
    api.session = &session_api;
    try std.testing.expectError(
        error.UnsupportedAbi,
        lifecycle.Runtime.initWithApi(
            std.testing.io,
            std.testing.allocator,
            &api,
            .{ .max_sessions = 1 },
        ),
    );

    var session_control_api = api.session_control.?.*;
    session_control_api.describe = null;
    api = fake_api;
    api.session_control = &session_control_api;
    try std.testing.expectError(
        error.UnsupportedAbi,
        lifecycle.Runtime.initWithApi(
            std.testing.io,
            std.testing.allocator,
            &api,
            .{ .max_sessions = 1 },
        ),
    );

    session_control_api = fake_api.session_control.?.*;
    session_control_api.set_prompt_profile = null;
    api = fake_api;
    api.session_control = &session_control_api;
    try std.testing.expectError(error.UnsupportedAbi, lifecycle.Runtime.initWithApi(
        std.testing.io,
        std.testing.allocator,
        &api,
        .{ .max_sessions = 1 },
    ));
    session_control_api = fake_api.session_control.?.*;
    session_control_api.update_permission_mode = null;
    try std.testing.expectError(error.UnsupportedAbi, lifecycle.Runtime.initWithApi(
        std.testing.io,
        std.testing.allocator,
        &api,
        .{ .max_sessions = 1 },
    ));
    session_control_api = fake_api.session_control.?.*;
    session_control_api.struct_size = 72;
    try std.testing.expectError(error.UnsupportedAbi, lifecycle.Runtime.initWithApi(
        std.testing.io,
        std.testing.allocator,
        &api,
        .{ .max_sessions = 1 },
    ));

    var mcp_api = api.mcp.?.*;
    mcp_api.apply_configuration = null;
    api = fake_api;
    api.mcp = &mcp_api;
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

test "Catalog leases copy descriptors and block Runtime destroy until exactly-once release" {
    fake_core.reset();
    const runtime = try createTestRuntime(.{ .max_sessions = 1 });
    var runtime_done = false;
    var lease: ?*lifecycle.CatalogLease = null;
    var projection: ?lifecycle.CatalogProjection = null;
    defer {
        if (projection) |*value| value.deinit();
        if (lease) |value| runtime.releaseSkillCatalog(value) catch {};
        if (!runtime_done) runtime.shutdown() catch {};
        runtime.deinit();
    }
    const root = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(root);

    const acquisition = try runtime.querySkillCatalog(.{
        .canonical_user_home = root,
        .target = .{ .workspace = .{ .canonical_root = root, .epoch = "workspace-1" } },
    });
    lease = acquisition.lease;
    projection = acquisition.projection;
    try std.testing.expectEqualStrings(
        fixture.fixture_catalog_revision,
        projection.?.revision,
    );
    try std.testing.expectEqual(lifecycle.CatalogHealth.healthy, projection.?.health);
    try std.testing.expectEqual(@as(usize, 1), projection.?.skills.len);
    try std.testing.expectEqualStrings("review", projection.?.skills[0].invocation_name);
    try std.testing.expectEqualStrings("target", projection.?.skills[0].argument_names[0]);

    fake_core.lock();
    const queried = fake_core.catalog_queries;
    const released_before = fake_core.catalog_releases;
    const descriptor_releases = fake_core.buffer_releases;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), queried);
    try std.testing.expectEqual(@as(usize, 0), released_before);
    try std.testing.expectEqual(@as(usize, 1), descriptor_releases);
    try std.testing.expectError(
        error.CatalogLeasesOutstanding,
        runtime.shutdown(),
    );

    projection.?.deinit();
    projection = null;
    try runtime.releaseSkillCatalog(lease.?);
    lease = null;
    fake_core.lock();
    const released_after = fake_core.catalog_releases;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), released_after);
    try runtime.shutdown();
    runtime_done = true;
}

test "canonical AgentCore resolves additional Skill sources conflicts and Workspace precedence" {
    var source: CatalogSourceTracker = .{};
    defer std.testing.expectEqual(@as(usize, 1), source.references.load(.acquire)) catch unreachable;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "home", "workspace", "source-a/review", "source-b/review" }) |dir|
        try tmp.dir.createDirPath(std.testing.io, dir);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "source-a/review/SKILL.md",
        .data = "---\nname: Review A\ndescription: Review from source A\n---\nInspect the requested file.\n",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "source-b/review/SKILL.md",
        .data = "---\nname: Review B\ndescription: Review from source B\n---\nInspect the requested change.\n",
    });
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, "home", std.testing.allocator);
    defer std.testing.allocator.free(home);
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, "workspace", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const source_a = try tmp.dir.realPathFileAlloc(std.testing.io, "source-a", std.testing.allocator);
    defer std.testing.allocator.free(source_a);
    const source_b = try tmp.dir.realPathFileAlloc(std.testing.io, "source-b", std.testing.allocator);
    defer std.testing.allocator.free(source_b);
    const runtime = try lifecycle.Runtime.init(std.testing.io, std.testing.allocator, .{ .max_sessions = 1 });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    var sources = [_]lifecycle.CatalogSource{
        .{ .canonical_root = source_a, .scope = .user, .source_instance_id = "compat.a" },
        .{ .canonical_root = source_b, .scope = .user, .source_instance_id = "compat.b" },
    };
    var query: lifecycle.CatalogQuery = .{
        .canonical_user_home = home,
        .target = .{ .workspace = .{ .canonical_root = root, .epoch = "sources" } },
        .additional_sources = sources[0..1],
        .source_lifetime = source.lifetime(),
    };
    var first = try runtime.querySkillCatalog(query);
    defer first.projection.deinit();
    defer runtime.releaseSkillCatalog(first.lease) catch unreachable;
    try std.testing.expectEqual(@as(usize, 1), first.projection.skills.len);
    try std.testing.expectEqualStrings("compat.a", first.projection.skills[0].source_instance_id);
    try std.testing.expectEqualStrings("Review A", first.projection.skills[0].display_name);
    query.additional_sources = &sources;
    var conflict = try runtime.querySkillCatalog(query);
    defer conflict.projection.deinit();
    // The projection remains valid after the Core lease is released.
    try runtime.releaseSkillCatalog(conflict.lease);
    try std.testing.expectEqual(lifecycle.CatalogHealth.degraded, conflict.projection.health);
    try std.testing.expectEqual(@as(usize, 0), conflict.projection.skills.len);
    try std.testing.expectEqual(@as(usize, 1), conflict.projection.issues.len);
    try std.testing.expectEqual(lifecycle.CatalogIssueCode.source_conflict, conflict.projection.issues[0].code);
    try std.testing.expectEqualStrings("review", conflict.projection.issues[0].skill_policy_key.?);
    std.mem.swap(lifecycle.CatalogSource, &sources[0], &sources[1]);
    var reversed = try runtime.querySkillCatalog(query);
    defer reversed.projection.deinit();
    try runtime.releaseSkillCatalog(reversed.lease);
    try std.testing.expectEqualStrings(conflict.projection.revision, reversed.projection.revision);
    sources[0].scope = .workspace;
    var winner = try runtime.querySkillCatalog(query);
    defer winner.projection.deinit();
    defer runtime.releaseSkillCatalog(winner.lease) catch unreachable;
    try std.testing.expectEqual(@as(usize, 1), winner.projection.skills.len);
    try std.testing.expectEqualStrings("compat.b", winner.projection.skills[0].source_instance_id);
    try std.testing.expectEqual(lifecycle.CatalogSourceScope.workspace, winner.projection.skills[0].source_scope);
    const session = try runtime.createSession(.{
        .model_binding = fixtureModelBinding(.anthropic_messages),
        .permission_mode = .default,
        .shell_policy = .unrestricted,
        .workspace = .{ .canonical_root = root, .trust = .explicitly_trusted },
        .canonical_user_home = home,
        .workspace_epoch = "sources",
        .skill_catalog = first.lease,
        .skill_policy = .{ .granted_skill_ids = &.{first.projection.skills[0].skill_id} },
    });
    defer session.close(.session_close) catch unreachable;
    try session.refreshSkillCatalog(winner.lease, .{ .granted_skill_ids = &.{winner.projection.skills[0].skill_id} });
    try std.testing.expectEqual(lifecycle.SessionState.idle, session.snapshot().state);
}

test "captured Skill restore inputs retain the exact lease policy and Runtime shutdown fence" {
    fake_core.reset();
    var source: CatalogSourceTracker = .{};
    const runtime = try createTestRuntime(.{ .max_sessions = 1 });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    const root = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var acquisition = try runtime.querySkillCatalog(.{
        .canonical_user_home = root,
        .target = .{ .workspace = .{ .canonical_root = root, .epoch = "restore-inputs" } },
        .source_lifetime = source.lifetime(),
    });
    try std.testing.expectEqual(@as(usize, 2), source.references.load(.acquire));
    const expected = try std.testing.allocator.dupe(u8, acquisition.projection.skills[0].skill_id);
    defer std.testing.allocator.free(expected);
    const session = try runtime.createSession(.{
        .model_binding = fixtureModelBinding(.anthropic_messages),
        .permission_mode = .default,
        .shell_policy = .unrestricted,
        .workspace = .{ .canonical_root = root, .trust = .explicitly_trusted },
        .canonical_user_home = root,
        .workspace_epoch = "restore-inputs",
        .skill_catalog = acquisition.lease,
        .skill_policy = .{ .granted_skill_ids = &.{acquisition.projection.skills[0].skill_id} },
    });
    var captured = try session.captureRestoreInputs();
    try std.testing.expectEqual(lifecycle.PermissionMode.default, captured.permission_mode);
    try std.testing.expectEqual(lifecycle.ShellPolicy.unrestricted, captured.shell_policy);
    try std.testing.expectEqual(lifecycle.PermissionInteraction.interactive, captured.permission_interaction);
    try runtime.releaseSkillCatalog(acquisition.lease);
    acquisition.projection.deinit();
    try std.testing.expectEqual(@as(usize, 0), fake_core.catalog_releases);
    try session.close(.session_close);
    try runtime.releaseClosedSession(session);
    const restored = captured.skill.?.borrow();
    try std.testing.expectEqual(@as(usize, 1), restored.policy.granted_skill_ids.len);
    try std.testing.expectEqualStrings(expected, restored.policy.granted_skill_ids[0]);
    try std.testing.expectError(error.CatalogLeasesOutstanding, runtime.shutdown());
    try std.testing.expectEqual(@as(usize, 2), source.references.load(.acquire));
    try captured.deinit();
    try std.testing.expectEqual(@as(usize, 1), source.references.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), fake_core.catalog_releases);
    try runtime.shutdown();
}

test "catalog source pin refusal rolls back acquisition and a consumed Core release error unpins once" {
    fake_core.reset();
    var source: CatalogSourceTracker = .{ .deny = true };
    const runtime = try createTestRuntime(.{ .max_sessions = 1 });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    const root = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const query: lifecycle.CatalogQuery = .{
        .canonical_user_home = root,
        .target = .{ .workspace = .{ .canonical_root = root, .epoch = "source-pin" } },
        .source_lifetime = source.lifetime(),
    };
    try std.testing.expectError(error.CatalogResourceLimit, runtime.querySkillCatalog(query));
    try std.testing.expectEqual(@as(usize, 1), source.references.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), fake_core.catalog_releases);
    source.deny = false;
    var acquired = try runtime.querySkillCatalog(query);
    defer acquired.projection.deinit();
    try std.testing.expectEqual(@as(usize, 2), source.references.load(.acquire));
    fake_core.catalog_release_failures = 1;
    try std.testing.expectError(error.CatalogReleaseFailed, runtime.releaseSkillCatalog(acquired.lease));
    try std.testing.expectEqual(@as(usize, 1), source.references.load(.acquire));
    try std.testing.expectEqual(@as(usize, 2), fake_core.catalog_releases);
    try runtime.shutdown();
}

test "final Skill restore reference release failure retains the closing Session for retry" {
    fake_core.reset();
    const runtime = try createTestRuntime(.{ .max_sessions = 1 });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    const root = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var acquisition = try runtime.querySkillCatalog(.{ .canonical_user_home = root, .target = .{ .workspace = .{ .canonical_root = root, .epoch = "release-failure" } } });
    defer acquisition.projection.deinit();
    const session = try runtime.createSession(.{
        .model_binding = fixtureModelBinding(.anthropic_messages),
        .permission_mode = .default,
        .shell_policy = .disabled,
        .workspace = .{ .canonical_root = root, .trust = .explicitly_trusted },
        .canonical_user_home = root,
        .workspace_epoch = "release-failure",
        .skill_catalog = acquisition.lease,
        .skill_policy = .{},
    });
    try runtime.releaseSkillCatalog(acquisition.lease);
    fake_core.catalog_release_failures = 1;
    const destroyed = fake_core.session_destroyed;
    try std.testing.expectError(error.CatalogReleaseFailed, session.close(.session_close));
    try std.testing.expectEqual(lifecycle.SessionState.closing, session.snapshot().state);
    try std.testing.expectEqual(destroyed, fake_core.session_destroyed);
    try std.testing.expectEqual(@as(usize, 1), fake_core.catalog_releases);
    try session.close(.session_close);
    try std.testing.expectEqual(destroyed + 1, fake_core.session_destroyed);
    try std.testing.expectEqual(@as(usize, 1), fake_core.catalog_releases);
    try runtime.releaseClosedSession(session);
}

test "Skill restore capture allocation failures preserve Session authority and lease ownership" {
    fake_core.reset();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const runtime = try lifecycle.Runtime.initWithApi(std.testing.io, failing.allocator(), &fake_api, .{
        .max_sessions = 1,
    });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    const root = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var acquisition = try runtime.querySkillCatalog(.{ .canonical_user_home = root, .target = .{ .workspace = .{ .canonical_root = root, .epoch = "capture-allocation" } } });
    defer acquisition.projection.deinit();
    defer runtime.releaseSkillCatalog(acquisition.lease) catch unreachable;
    const session = try runtime.createSession(.{
        .model_binding = fixtureModelBinding(.anthropic_messages),
        .permission_mode = .default,
        .shell_policy = .disabled,
        .workspace = .{ .canonical_root = root, .trust = .explicitly_trusted },
        .canonical_user_home = root,
        .workspace_epoch = "capture-allocation",
        .skill_catalog = acquisition.lease,
        .skill_policy = .{ .granted_skill_ids = &.{acquisition.projection.skills[0].skill_id} },
    });
    defer session.close(.session_close) catch unreachable;
    for (0..256) |offset| {
        failing.fail_index = failing.alloc_index + offset;
        failing.has_induced_failure = false;
        var captured = session.captureRestoreInputs() catch |err| {
            failing.fail_index = std.math.maxInt(usize);
            try std.testing.expect(err == error.OutOfMemory or err == error.PermissionModeUpdateFailed);
            try std.testing.expect(failing.has_induced_failure);
            try std.testing.expectEqual(lifecycle.SessionState.idle, session.snapshot().state);
            try std.testing.expectEqual(@as(usize, 0), fake_core.catalog_releases);
            continue;
        };
        failing.fail_index = std.math.maxInt(usize);
        try std.testing.expect(offset != 0);
        try std.testing.expectEqualStrings(acquisition.projection.skills[0].skill_id, captured.skill.?.borrow().policy.granted_skill_ids[0]);
        try captured.deinit();
        return;
    }
    return error.TestUnexpectedResult;
}

test "Catalog additional sources are encoded exactly and borrowed only for the query" {
    fake_core.reset();
    const runtime = try createTestRuntime(.{ .max_sessions = 1 });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    const root = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var expected_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(root, &expected_hash, .{});
    var source_id = "compat.source".*;
    const source = lifecycle.CatalogSource{
        .canonical_root = root,
        .scope = .user,
        .source_instance_id = &source_id,
    };
    var sources: [wire.MAX_SKILL_SOURCES_V1 + 1]lifecycle.CatalogSource = @splat(source);
    sources[0].scope = .workspace;
    for ([_]usize{ 0, 1, 4, wire.MAX_SKILL_SOURCES_V1 }) |count| {
        var acquisition = try runtime.querySkillCatalog(.{
            .canonical_user_home = root,
            .target = .{ .workspace = .{ .canonical_root = root, .epoch = "sources" } },
            .additional_sources = sources[0..count],
        });
        defer acquisition.projection.deinit();
        try runtime.releaseSkillCatalog(acquisition.lease);
        try std.testing.expectEqual(count, fake_core.catalog_source_count);
        for (fake_core.catalog_sources[0..count], 0..) |seen, index| {
            try std.testing.expectEqual(if (index == 0) wire.SKILL_SOURCE_WORKSPACE else wire.SKILL_SOURCE_USER, seen.scope);
            try std.testing.expectEqualDeep(expected_hash, seen.root_hash);
            try std.testing.expectEqualStrings(&source_id, seen.id[0..seen.id_len]);
        }
        try std.testing.expectEqualStrings("review", acquisition.projection.skills[0].invocation_name);
    }
    @memset(&source_id, 'x');
    try std.testing.expectEqualStrings("compat.source", fake_core.catalog_sources[0].id[0..13]);
    try std.testing.expectError(error.CatalogResourceLimit, runtime.querySkillCatalog(.{
        .canonical_user_home = root,
        .target = .{ .workspace = .{ .canonical_root = root, .epoch = "" } },
        .additional_sources = &sources,
    }));
    try std.testing.expectEqual(@as(usize, 4), fake_core.catalog_queries);
}

test "Management catalog encodes personal additions at the shared default priority" {
    fake_core.reset();
    const runtime = try createTestRuntime(.{ .max_sessions = 1 });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    const root = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const sources: [4]lifecycle.CatalogSource = @splat(.{
        .canonical_root = root,
        .scope = .user,
        .source_instance_id = "personal",
    });
    var acquisition = try runtime.querySkillCatalog(.{
        .canonical_user_home = root,
        .target = .management,
        .additional_sources = &sources,
    });
    defer acquisition.projection.deinit();
    defer runtime.releaseSkillCatalog(acquisition.lease) catch unreachable;
    try std.testing.expectEqual(@as(usize, 4), fake_core.catalog_source_count);
    for (fake_core.catalog_sources[0..4]) |seen|
        try std.testing.expectEqual(wire.SKILL_SOURCE_WORKSPACE, seen.scope);
    for (sources) |source| try std.testing.expectEqual(lifecycle.CatalogSourceScope.user, source.scope);
}

test "canonical AgentCore management and Workspace resolve all personal and project source selections" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dirs = [_][]const u8{
        "home/.claude/skills", "workspace/.claude/skills", "home/.codex/skills", "workspace/.codex/skills",
    };
    for (dirs ++ .{"home/.agents/skills"}) |dir| {
        const entry = try std.fs.path.join(std.testing.allocator, &.{ dir, "review" });
        defer std.testing.allocator.free(entry);
        try tmp.dir.createDirPath(std.testing.io, entry);
        const file = try std.fs.path.join(std.testing.allocator, &.{ entry, "SKILL.md" });
        defer std.testing.allocator.free(file);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = file, .data = "---\nname: Review\ndescription: Review this change\n---\nInspect the requested file.\n" });
    }
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, "home", std.testing.allocator);
    defer std.testing.allocator.free(home);
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, "workspace", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var roots: [4][:0]u8 = undefined;
    var root_count: usize = 0;
    defer for (roots[0..root_count]) |path| std.testing.allocator.free(path);
    for (dirs, 0..) |dir, index| {
        roots[index] = try tmp.dir.realPathFileAlloc(std.testing.io, dir, std.testing.allocator);
        root_count += 1;
    }
    const runtime = try lifecycle.Runtime.init(std.testing.io, std.testing.allocator, .{ .max_sessions = 1 });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    const ids = [_][]const u8{ "compat.claude.user", "compat.claude.workspace", "compat.codex.user", "compat.codex.workspace" };
    for (0..32) |variation| {
        const mask = variation % 16;
        var personal: [2]lifecycle.CatalogSource = undefined;
        var workspace: [4]lifecycle.CatalogSource = undefined;
        var personal_count: usize = 0;
        var workspace_count: usize = 0;
        var project_count: usize = 0;
        var project_id: []const u8 = "";
        for (roots, ids, 0..) |path, id, index| {
            if (mask & (@as(usize, 1) << @intCast(index)) == 0) continue;
            const source: lifecycle.CatalogSource = .{
                .canonical_root = path,
                .scope = if (index % 2 == 0) .user else .workspace,
                .source_instance_id = id,
            };
            workspace[workspace_count] = source;
            workspace_count += 1;
            if (source.scope == .user) {
                personal[personal_count] = source;
                personal_count += 1;
            } else {
                project_count += 1;
                project_id = id;
            }
        }
        if (variation >= 16) {
            std.mem.reverse(lifecycle.CatalogSource, personal[0..personal_count]);
            std.mem.reverse(lifecycle.CatalogSource, workspace[0..workspace_count]);
        }
        var management = try runtime.querySkillCatalog(.{
            .canonical_user_home = home,
            .target = .management,
            .additional_sources = personal[0..personal_count],
        });
        defer management.projection.deinit();
        defer runtime.releaseSkillCatalog(management.lease) catch unreachable;
        var effective = try runtime.querySkillCatalog(.{
            .canonical_user_home = home,
            .target = .{ .workspace = .{ .canonical_root = root, .epoch = "selection" } },
            .additional_sources = workspace[0..workspace_count],
        });
        defer effective.projection.deinit();
        defer runtime.releaseSkillCatalog(effective.lease) catch unreachable;
        try std.testing.expectEqual(@as(usize, if (personal_count == 0) 1 else 0), management.projection.skills.len);
        try std.testing.expectEqual(@as(usize, if (personal_count == 0) 0 else 1), management.projection.issues.len);
        if (personal_count != 0)
            try std.testing.expectEqual(lifecycle.CatalogIssueCode.source_conflict, management.projection.issues[0].code);
        const conflict = project_count > 1 or (project_count == 0 and personal_count != 0);
        try std.testing.expectEqual(@as(usize, if (conflict) 0 else 1), effective.projection.skills.len);
        try std.testing.expectEqual(@as(usize, if (conflict) 1 else 0), effective.projection.issues.len);
        if (conflict)
            try std.testing.expectEqual(lifecycle.CatalogIssueCode.source_conflict, effective.projection.issues[0].code)
        else
            try std.testing.expectEqualStrings(if (project_count == 1) project_id else "agents.user.default", effective.projection.skills[0].source_instance_id);
    }
    // A malformed higher-priority definition must not reveal a lower winner.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "workspace/.claude/skills/review/SKILL.md", .data = "\xff" });
    var broken = try runtime.querySkillCatalog(.{
        .canonical_user_home = home,
        .target = .{ .workspace = .{ .canonical_root = root, .epoch = "broken" } },
        .additional_sources = &.{.{ .canonical_root = roots[1], .scope = .workspace, .source_instance_id = ids[1] }},
    });
    defer broken.projection.deinit();
    defer runtime.releaseSkillCatalog(broken.lease) catch unreachable;
    try std.testing.expectEqual(@as(usize, 0), broken.projection.skills.len);
    try std.testing.expectEqual(@as(usize, 1), broken.projection.issues.len);
    try std.testing.expectEqual(lifecycle.CatalogIssueCode.invalid_definition, broken.projection.issues[0].code);
    // Product deduplicates compatible roots when home equals Workspace. The
    // one retained rule's selected scope must still follow Core priority.
    for ([_]lifecycle.CatalogSourceScope{ .user, .workspace }) |scope| {
        var shared = try runtime.querySkillCatalog(.{
            .canonical_user_home = home,
            .target = .{ .workspace = .{ .canonical_root = home, .epoch = "shared" } },
            .additional_sources = &.{.{ .canonical_root = roots[0], .scope = scope, .source_instance_id = if (scope == .user) ids[0] else ids[1] }},
        });
        defer shared.projection.deinit();
        defer runtime.releaseSkillCatalog(shared.lease) catch unreachable;
        try std.testing.expectEqual(@as(usize, if (scope == .user) 1 else 0), shared.projection.skills.len);
        if (scope == .user)
            try std.testing.expectEqualStrings("agents.workspace.default", shared.projection.skills[0].source_instance_id)
        else
            try std.testing.expectEqual(lifecycle.CatalogIssueCode.source_conflict, shared.projection.issues[0].code);
    }
}

test "Catalog invalid sources fail before Core and management rejects project sources" {
    fake_core.reset();
    const runtime = try createTestRuntime(.{ .max_sessions = 1 });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    const root = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    for ([_]lifecycle.CatalogSource{
        .{ .canonical_root = "", .scope = .user, .source_instance_id = "source" },
        .{ .canonical_root = "relative", .scope = .user, .source_instance_id = "source" },
        .{ .canonical_root = root, .scope = .user, .source_instance_id = "" },
        .{ .canonical_root = root, .scope = .user, .source_instance_id = "bad\x00id" },
        .{ .canonical_root = root, .scope = .user, .source_instance_id = "\xff" },
    }) |source| {
        try std.testing.expectError(error.InvalidCatalogQuery, runtime.querySkillCatalog(.{
            .canonical_user_home = root,
            .target = .{ .workspace = .{ .canonical_root = root, .epoch = "" } },
            .additional_sources = &.{source},
        }));
    }
    try std.testing.expectError(error.InvalidCatalogQuery, runtime.querySkillCatalog(.{
        .canonical_user_home = root,
        .target = .management,
        .additional_sources = &.{.{ .canonical_root = root, .scope = .workspace, .source_instance_id = "source" }},
    }));
    // This length alone exhausts the budget, before any bytes or files are read.
    const oversized = try std.testing.allocator.alloc(u8, wire.MAX_SESSION_METADATA_BYTES_V1 + 1);
    defer std.testing.allocator.free(oversized);
    try std.testing.expectError(error.CatalogResourceLimit, runtime.querySkillCatalog(.{
        .canonical_user_home = oversized,
        .target = .management,
    }));
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const temp_root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(temp_root);
    const missing_root = try std.fs.path.join(std.testing.allocator, &.{ temp_root, "missing-source" });
    defer std.testing.allocator.free(missing_root);
    try std.testing.expectError(error.InvalidCatalogQuery, runtime.querySkillCatalog(.{
        .canonical_user_home = root,
        .target = .{ .workspace = .{ .canonical_root = root, .epoch = "" } },
        .additional_sources = &.{.{ .canonical_root = missing_root, .scope = .user, .source_instance_id = "missing" }},
    }));
    try std.testing.expectEqual(@as(usize, 0), fake_core.catalog_queries);
}

test "Catalog additional source allocation failures release all owners and leave Runtime reusable" {
    fake_core.reset();
    var source: CatalogSourceTracker = .{};
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const runtime = try lifecycle.Runtime.initWithApi(std.testing.io, failing.allocator(), &fake_api, .{ .max_sessions = 1 });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    const root = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const query: lifecycle.CatalogQuery = .{
        .canonical_user_home = root,
        .target = .{ .workspace = .{ .canonical_root = root, .epoch = "allocation-failures" } },
        .additional_sources = &.{.{ .canonical_root = root, .scope = .user, .source_instance_id = "source" }},
        .source_lifetime = source.lifetime(),
    };
    for (0..256) |offset| {
        failing.fail_index = failing.alloc_index + offset;
        failing.has_induced_failure = false;
        var acquisition = runtime.querySkillCatalog(query) catch |err| {
            failing.fail_index = std.math.maxInt(usize);
            // Existing canonical-directory validation maps filesystem allocation
            // failure to InvalidCatalogQuery; subsequent allocations retain OOM.
            try std.testing.expect(err == error.OutOfMemory or err == error.InvalidCatalogQuery);
            try std.testing.expect(failing.has_induced_failure);
            try std.testing.expectEqual(fake_core.catalog_queries, fake_core.catalog_releases);
            try std.testing.expectEqual(fake_core.catalog_queries, fake_core.buffer_releases);
            try std.testing.expectEqual(@as(usize, 1), source.references.load(.acquire));
            continue;
        };
        failing.fail_index = std.math.maxInt(usize);
        defer acquisition.projection.deinit();
        try runtime.releaseSkillCatalog(acquisition.lease);
        try std.testing.expectEqual(@as(usize, 1), source.references.load(.acquire));
        try std.testing.expect(offset > 0);
        try std.testing.expectEqual(fake_core.catalog_queries, fake_core.catalog_releases);
        try std.testing.expectEqual(fake_core.catalog_queries, fake_core.buffer_releases);
        return;
    }
    return error.TestUnexpectedResult;
}

test "Management catalog leases cannot bind create restore or idle refresh even with matching paths" {
    fake_core.reset();
    const runtime = try createTestRuntime(.{ .max_sessions = 2 });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    const root = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var management = try runtime.querySkillCatalog(.{
        .canonical_user_home = root,
        .target = .management,
        .additional_sources = &.{.{ .canonical_root = root, .scope = .user, .source_instance_id = "personal" }},
    });
    defer management.projection.deinit();
    defer runtime.releaseSkillCatalog(management.lease) catch unreachable;
    var options: lifecycle.SessionOpenOptions = .{
        .model_binding = fixtureModelBinding(.anthropic_messages),
        .permission_mode = .default,
        .shell_policy = .disabled,
        .workspace = .{ .canonical_root = root, .trust = .explicitly_trusted },
        .canonical_user_home = root,
        .workspace_epoch = "",
        .skill_catalog = management.lease,
        .skill_policy = .{},
    };
    try std.testing.expectError(error.CatalogBindingMismatch, runtime.createSessionRoute(options));
    var source = CheckpointRestoreSource{ .bytes = "fixture-checkpoint" };
    var restore = restoreOptions(source.source(), "000000000000000000000001", 0, 0);
    restore.session = options;
    try std.testing.expectError(error.CatalogBindingMismatch, runtime.restoreSessionRoute(restore));
    options.skill_catalog = null;
    options.skill_policy = null;
    const session = try runtime.createSession(options);
    defer session.close(.session_close) catch unreachable;
    try std.testing.expectError(error.CatalogBindingMismatch, session.refreshSkillCatalog(management.lease, .{}));
    try std.testing.expectEqual(@as(usize, 1), fake_core.session_created);
    try std.testing.expectEqual(@as(usize, 0), fake_core.checkpoint_restores);
    try std.testing.expectEqual(@as(usize, 0), fake_core.catalog_refreshes);
    // The same root and empty epoch are valid for an explicitly Workspace lease.
    var workspace = try runtime.querySkillCatalog(.{
        .canonical_user_home = root,
        .target = .{ .workspace = .{ .canonical_root = root, .epoch = "" } },
        .additional_sources = &.{.{ .canonical_root = root, .scope = .workspace, .source_instance_id = "source" }},
    });
    defer workspace.projection.deinit();
    defer runtime.releaseSkillCatalog(workspace.lease) catch unreachable;
    try session.refreshSkillCatalog(workspace.lease, .{});
    try std.testing.expectEqual(@as(usize, 1), fake_core.catalog_refreshes);
}

test "invalid and duplicate catalog descriptors release every AgentCore owner" {
    inline for (.{ fixture.CatalogPlan.malformed, fixture.CatalogPlan.duplicate_skill_id }) |plan| {
        fake_core.reset();
        fake_core.setCatalogPlan(plan);
        const runtime = try createTestRuntime(.{ .max_sessions = 1 });
        defer {
            runtime.shutdown() catch unreachable;
            runtime.deinit();
        }
        const root = try std.Io.Dir.cwd().realPathFileAlloc(
            std.testing.io,
            ".",
            std.testing.allocator,
        );
        defer std.testing.allocator.free(root);
        try std.testing.expectError(error.InvalidCatalogDescriptor, runtime.querySkillCatalog(.{
            .canonical_user_home = root,
            .target = .{ .workspace = .{ .canonical_root = root, .epoch = "workspace-1" } },
            .additional_sources = &.{.{ .canonical_root = root, .scope = .user, .source_instance_id = "source" }},
        }));
        fake_core.lock();
        const releases = fake_core.catalog_releases;
        const buffers = fake_core.buffer_releases;
        fake_core.unlock();
        try std.testing.expectEqual(@as(usize, 1), releases);
        try std.testing.expectEqual(@as(usize, 1), buffers);
    }
}

test "Skill input is deep-copied and encoded only for the typed Core call" {
    fake_core.reset();
    const runtime = try createTestRuntime(.{ .max_sessions = 1 });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    const root = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(root);
    var acquisition = try runtime.querySkillCatalog(.{
        .canonical_user_home = root,
        .target = .{ .workspace = .{ .canonical_root = root, .epoch = "workspace-1" } },
    });
    defer acquisition.projection.deinit();
    const session = try runtime.createSession(.{
        .model_binding = fixtureModelBinding(.anthropic_messages),
        .permission_mode = .default,
        .shell_policy = .disabled,
        .workspace = .{
            .canonical_root = root,
            .trust = .explicitly_trusted,
        },
        .canonical_user_home = root,
        .workspace_epoch = "workspace-1",
        .skill_catalog = acquisition.lease,
        .skill_policy = .{ .granted_skill_ids = &.{fixture.fixture_skill_id} },
    });
    try runtime.releaseSkillCatalog(acquisition.lease);

    const skill_id = try std.testing.allocator.dupe(
        u8,
        fixture.fixture_skill_id,
    );
    defer std.testing.allocator.free(skill_id);
    const revision = try std.testing.allocator.dupe(
        u8,
        fixture.fixture_catalog_revision,
    );
    defer std.testing.allocator.free(revision);
    const target = try std.testing.allocator.dupe(u8, "src/main.zig");
    defer std.testing.allocator.free(target);
    const focus = try std.testing.allocator.dupe(u8, "correctness");
    defer std.testing.allocator.free(focus);
    const run_id = try session.prepareRun(.{ .skill = .{
        .skill_id = skill_id,
        .catalog_revision = revision,
        .argument_values = &.{ target, focus },
    } });
    @memset(skill_id, 'x');
    @memset(revision, 'x');
    @memset(target, 'x');
    @memset(focus, 'x');
    var run = try session.beginRun(run_id);
    var terminal = run.execute();
    defer terminal.deinit();
    run.deinit();
    try std.testing.expectEqual(lifecycle.Status.ok, terminal.abi_status.?);
    fake_core.lock();
    const saw_skill = fake_core.skill_run_seen;
    const input_matches = fake_core.skill_input_matches;
    const home_seen = fake_core.workspace_home_seen;
    const bound = fake_core.skill_session_bound;
    const policy_seen = fake_core.skill_policy_seen;
    const permission_rules_absent = fake_core.permission_rules_absent;
    fake_core.unlock();
    try std.testing.expect(saw_skill);
    try std.testing.expect(input_matches);
    try std.testing.expect(home_seen);
    try std.testing.expect(bound);
    try std.testing.expect(policy_seen);
    try std.testing.expect(permission_rules_absent);
    try session.close(.session_close);
}

test "Skill rejection statuses leave the Session reusable" {
    fake_core.reset();
    const runtime = try createTestRuntime(.{ .max_sessions = 1 });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    const root = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(root);
    const cases = [_]struct {
        plan: Plan,
        status: lifecycle.Status,
    }{
        .{ .plan = .stale_catalog, .status = .stale_catalog },
        .{ .plan = .skill_not_found, .status = .skill_not_found },
        .{ .plan = .invalid_skill_arguments, .status = .invalid_skill_arguments },
        .{ .plan = .skill_policy_violation, .status = .skill_policy_violation },
        .{ .plan = .skill_unavailable, .status = .skill_unavailable },
    };
    for (cases) |case| {
        fake_core.setNextPlan(case.plan);
        var acquisition = try runtime.querySkillCatalog(.{
            .canonical_user_home = root,
            .target = .{ .workspace = .{ .canonical_root = root, .epoch = "workspace-1" } },
        });
        const session = try runtime.createSession(.{
            .model_binding = fixtureModelBinding(.anthropic_messages),
            .permission_mode = .default,
            .shell_policy = .disabled,
            .workspace = .{
                .canonical_root = root,
                .trust = .explicitly_trusted,
            },
            .canonical_user_home = root,
            .workspace_epoch = "workspace-1",
            .skill_catalog = acquisition.lease,
            .skill_policy = .{ .granted_skill_ids = &.{fixture.fixture_skill_id} },
        });
        try runtime.releaseSkillCatalog(acquisition.lease);
        acquisition.projection.deinit();
        const run_id = try session.prepareRun(.{ .skill = .{
            .skill_id = fixture.fixture_skill_id,
            .catalog_revision = fixture.fixture_catalog_revision,
            .argument_values = &.{ "src/main.zig", "correctness" },
        } });
        var run = try session.beginRun(run_id);
        var terminal = run.execute();
        run.deinit();
        try std.testing.expectEqual(case.status, terminal.abi_status.?);
        try std.testing.expectEqual(
            lifecycle.SessionDisposition.reusable,
            terminal.session_disposition_at_completion,
        );
        terminal.deinit();
        const retry = try session.prepareRun(.{ .text = "still reusable" });
        try session.cancelPreparedRun(retry);
        try session.close(.session_close);
        try runtime.releaseClosedSession(session);
    }
}

test "Session catalog refresh binds explicit selection only while idle and rejects another Workspace epoch" {
    fake_core.reset();
    const runtime = try createTestRuntime(.{ .max_sessions = 1 });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    const root = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(root);
    var current = try runtime.querySkillCatalog(.{
        .canonical_user_home = root,
        .target = .{ .workspace = .{ .canonical_root = root, .epoch = "workspace-1" } },
    });
    defer current.projection.deinit();
    defer runtime.releaseSkillCatalog(current.lease) catch unreachable;
    const session = try runtime.createSession(.{
        .model_binding = fixtureModelBinding(.anthropic_messages),
        .permission_mode = .default,
        .shell_policy = .disabled,
        .workspace = .{
            .canonical_root = root,
            .trust = .explicitly_trusted,
        },
        .canonical_user_home = root,
        .workspace_epoch = "workspace-1",
    });

    const queued = try session.prepareRun(.{ .text = "queued" });
    try std.testing.expectError(
        error.SessionNotIdle,
        session.refreshSkillCatalog(current.lease, .{ .granted_skill_ids = &.{} }),
    );
    try session.cancelPreparedRun(queued);
    try session.refreshSkillCatalog(current.lease, .{
        .granted_skill_ids = &.{fixture.fixture_skill_id},
    });

    var other = try runtime.querySkillCatalog(.{
        .canonical_user_home = root,
        .target = .{ .workspace = .{ .canonical_root = root, .epoch = "workspace-2" } },
    });
    defer other.projection.deinit();
    defer runtime.releaseSkillCatalog(other.lease) catch unreachable;
    try std.testing.expectError(
        error.CatalogBindingMismatch,
        session.refreshSkillCatalog(other.lease, .{ .granted_skill_ids = &.{} }),
    );
    for ([_]u32{
        wire.STATUS_RESOURCE_LIMIT,
        wire.STATUS_CHECKPOINT_BUDGET_REQUIRED,
    }) |recoverable_status| {
        fake_core.forceNextSkillUpdateStatus(recoverable_status);
        try std.testing.expectError(
            error.CatalogRefreshFailed,
            session.refreshSkillCatalog(current.lease, .{ .granted_skill_ids = &.{} }),
        );
        try std.testing.expectEqual(lifecycle.SessionState.idle, session.snapshot().state);
        const reusable = try session.prepareRun(.{ .text = "still reusable" });
        try session.cancelPreparedRun(reusable);
    }
    fake_core.forceNextSkillUpdateStatus(wire.STATUS_STALE_COMPACT);
    try std.testing.expectError(
        error.CatalogRefreshFailed,
        session.refreshSkillCatalog(current.lease, .{ .granted_skill_ids = &.{} }),
    );
    try std.testing.expectEqual(lifecycle.SessionState.poisoned, session.snapshot().state);
    try std.testing.expectError(
        error.SessionPoisoned,
        session.prepareRun(.{ .text = "must not continue" }),
    );
    fake_core.lock();
    const refreshes = fake_core.catalog_refreshes;
    const policy_seen = fake_core.skill_policy_seen;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), refreshes);
    try std.testing.expect(policy_seen);
    try session.close(.session_close);
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
        session.respondPermission(
            run_id,
            request_id,
            .allow_once,
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
    const run_id = try session.prepareRun(.{
        .text = "complete before the retained lease is released",
    });
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

    const first_id = try session.prepareRun(.{ .text = "first generation" });
    var first = try session.beginRun(first_id);
    var stale = first.control().tryAcquireLease().?;
    var first_terminal = first.execute();
    defer first_terminal.deinit();
    first.deinit();

    const second_id = try session.prepareRun(.{ .text = "second generation" });
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
    const run_id = try session.prepareRun(.{
        .text = "cancel before entering Core",
    });
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
    const run_id = try session.prepareRun(.{
        .text = "retain control across close",
    });
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
    try std.testing.expect(fake_core.image_tool_seen);
    try std.testing.expect(fake_core.product_allowlist_seen);
    try std.testing.expectEqual(lifecycle.SessionState.idle, session.snapshot().state);
    try closeSession(session, .session_close);
    try closeSession(session, .session_close);
    try shutdownTestComposition(runtime);
    try shutdownTestComposition(runtime);
    try std.testing.expectEqual(@as(usize, 1), fake_core.runtime_created);
    try std.testing.expectEqual(@as(usize, 1), fake_core.runtime_destroyed);
    try std.testing.expectEqual(@as(usize, 1), fake_core.session_destroyed);
}

test "Session creation maps the selected protocol to the Core adapter and protocol codes" {
    const workspace_root = if (std.fs.path.sep == '\\') "C:\\tmp\\metawork-protocol" else "/tmp/metawork-protocol";
    const temporary_root = if (std.fs.path.sep == '\\') "C:\\tmp" else "/tmp";
    for (session_protocol_cases) |case| {
        fake_core.reset();
        const runtime = try createTestRuntime(.{ .max_sessions = 1 });
        defer {
            runtime.shutdown() catch unreachable;
            runtime.deinit();
        }
        var provider_id = "service-instance-a".*;
        const session = try runtime.createSession(.{
            .model_binding = .{
                .target = .{
                    .provider_id = &provider_id,
                    .protocol = case.protocol,
                    .base_url = "",
                    .model = "fixture-model",
                },
                .credential = "fixture-secret",
            },
            .permission_mode = .default,
            .shell_policy = .disabled,
            .workspace = .{
                .canonical_root = workspace_root,
                .trust = .{ .temporary = temporary_root },
            },
        });
        @memset(&provider_id, 'x');
        try std.testing.expectEqualStrings("service-instance-a", session.provider_id);
        try std.testing.expectEqual(case.protocol, session.protocol);
        try std.testing.expectEqual(@as(?u32, case.provider_code), fake_core.last_created_provider_kind_code);
        try std.testing.expectEqual(@as(?u32, case.protocol_code), fake_core.last_created_protocol_kind_code);
        try std.testing.expectEqual(@as(usize, 1), fake_core.session_created);
        try std.testing.expectEqual(lifecycle.SessionState.idle, session.snapshot().state);
        try session.close(.session_close);
        try runtime.releaseClosedSession(session);
    }
}

test "model binding limits reject before Session and checkpoint Core calls" {
    fake_core.reset();
    const runtime = try createTestRuntime(.{ .max_sessions = 2 });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    const workspace_root = if (std.fs.path.sep == '\\')
        "C:\\tmp\\metawork-model-binding-limits"
    else
        "/tmp/metawork-model-binding-limits";
    const temporary_root = if (std.fs.path.sep == '\\') "C:\\tmp" else "/tmp";

    var oversized_credential = [_]u8{0xff} ** 4097;
    var invalid_binding = fixtureModelBinding(.anthropic_messages);
    invalid_binding.credential = &oversized_credential;
    try std.testing.expectError(error.CoreCallFailed, runtime.createSession(.{
        .model_binding = invalid_binding,
        .permission_mode = .default,
        .shell_policy = .disabled,
        .workspace = .{
            .canonical_root = workspace_root,
            .trust = .{ .temporary = temporary_root },
        },
    }));
    try std.testing.expectEqual(@as(usize, 0), fake_core.session_created);

    var source = CheckpointRestoreSource{ .bytes = "fixture-checkpoint" };
    var oversized_model = [_]u8{'m'} ** 257;
    var restore_options = restoreOptions(
        source.source(),
        "000000000000000000000001",
        0,
        0,
    );
    restore_options.session.model_binding.target.model = &oversized_model;
    restore_options.expectation.model = &oversized_model;
    try std.testing.expectError(
        error.CoreCallFailed,
        runtime.restoreSessionRoute(restore_options),
    );
    try std.testing.expectEqual(@as(usize, 0), fake_core.checkpoint_restores);

    const session = try openSession(runtime);
    defer {
        closeSession(session, .session_close) catch unreachable;
        runtime.releaseClosedSession(session) catch unreachable;
    }
    try std.testing.expectError(error.CoreCallFailed, session.setModel(&oversized_model));
    var collector = CheckpointCollector{};
    try std.testing.expectError(error.InvalidLimits, session.exportCheckpoint(
        checkpoint_test_limits,
        collector.sink(),
        0,
        0,
        &oversized_model,
    ));
    try std.testing.expectEqual(@as(usize, 0), fake_core.checkpoint_exports);
}

test "Agent Runtime applies the fixed MetaWork built-in and Host tool surface to Session" {
    fake_core.reset();
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_storage);
    const workspace_root = root_storage[0..root_len];
    const session = try runtime.createSession(.{
        .model_binding = fixtureModelBinding(.anthropic_messages),
        .permission_mode = .default,
        .shell_policy = .unrestricted,
        .workspace = .{
            .canonical_root = workspace_root,
            .trust = .{ .temporary = workspace_root },
        },
        .canonical_user_home = workspace_root,
        .workspace_epoch = "metawork-agent-tools",
    });
    defer closeSession(session, .session_close) catch {};

    const expected = [_][]const u8{
        "Read", "Write", "Edit", "Glob", "Grep", "Bash", "BashOutput", "KillShell", "WebSearch", "WebFetch", "GenerateImage", "DeliverFile",
    };
    try std.testing.expectEqual(expected.len, fake_core.last_allowed_tool_count);
    for (expected, 0..) |name, index| {
        try std.testing.expectEqualStrings(
            name,
            fake_core.last_allowed_tool_names[index][0..name.len],
        );
    }
    for (fake_core.last_allowed_tool_names[0..fake_core.last_allowed_tool_count]) |storage|
        try std.testing.expect(std.mem.indexOf(u8, &storage, "AskUserQuestion") == null);
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
        .model_binding = fixtureModelBinding(.anthropic_messages),
        .permission_mode = .default,
        .shell_policy = .disabled,
        .workspace = .{ .canonical_root = "relative", .trust = .explicitly_trusted },
    }));
    try std.testing.expectError(error.WorkspaceNotTrusted, runtime.createSession(.{
        .model_binding = fixtureModelBinding(.anthropic_messages),
        .permission_mode = .default,
        .shell_policy = .disabled,
        .workspace = .{
            .canonical_root = outside_temporary,
            .trust = .{ .temporary = temporary_root },
        },
    }));
    try std.testing.expectError(error.InvalidWorkspace, runtime.createSession(.{
        .model_binding = fixtureModelBinding(.anthropic_messages),
        .permission_mode = .default,
        .shell_policy = .disabled,
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
    try std.testing.expectError(error.RunInputTooLarge, submitSession(session, "12345"));
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

test "oversized file changes degrade without terminating the Run" {
    fake_core.reset();
    fake_core.setNextPlan(.file_changes_callback);
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
        .max_event_bytes = 64,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);
    const run_id = try submitSession(session, "drop oversized supplemental changes");
    try session.waitRun(run_id);
    var terminal = takeTestTerminal(session, run_id);
    defer terminal.deinit();
    try std.testing.expectEqual(@as(?u32, wire.STATUS_OK), terminal.raw_status_code);
    try std.testing.expectEqual(@as(?sdk.StopReason, .end_turn), terminal.stop_reason);
    try std.testing.expect(terminal.termination_signal == null);
    try std.testing.expect(terminal.file_changes_lost);
    try std.testing.expectEqual(lifecycle.SessionState.idle, session.snapshot().state);
    try std.testing.expect(runtime.takeEvent() == null);

    fake_core.setSessionPlan(.event_callback);
    const next_run_id = try submitSession(session, "loss state is per Run");
    try session.waitRun(next_run_id);
    var next_terminal = takeTestTerminal(session, next_run_id);
    defer next_terminal.deinit();
    try std.testing.expect(!next_terminal.file_changes_lost);
    var retained = runtime.takeEvent() orelse return error.ExpectedOwnedEvent;
    retained.deinit();
    try closeSession(session, .session_close);
}

test "oversized non-file event remains fatal" {
    fake_core.reset();
    fake_core.setNextPlan(.event_callback);
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
        .max_event_bytes = 8,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);
    const run_id = try submitSession(session, "oversized control remains fatal");
    try session.waitRun(run_id);
    var terminal = takeTestTerminal(session, run_id);
    defer terminal.deinit();
    try std.testing.expectEqual(@as(?u32, wire.STATUS_CALLBACK_FAILED), terminal.raw_status_code);
    try std.testing.expectEqual(
        lifecycle.TerminationSignal{ .event_pump_failure = .event_too_large },
        terminal.termination_signal.?,
    );
    try std.testing.expect(!terminal.file_changes_lost);
    try closeSession(session, .session_close);
}

test "non-UTF-8 Core events fail the Run before entering the bounded sink" {
    fake_core.reset();
    fake_core.setNextPlan(.invalid_utf8_event_callback);
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);
    const run_id = try submitSession(session, "emit non-UTF-8 event");
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
    try std.testing.expect(runtime.takeEvent() == null);
    try closeSession(session, .session_close);
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

test "file changes capacity rejection degrades and preserves the original Run result" {
    fake_core.reset();
    fake_core.setNextPlan(.file_changes_callback);
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
        .event_capacity = 1,
        .per_session_event_capacity = 1,
        .control_reserved_capacity = 0,
        .per_session_control_reserved_capacity = 0,
        .event_enqueue_timeout = .fromNanoseconds(1),
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);
    const first_run = try submitSession(session, "retain first file changes event");
    try session.waitRun(first_run);
    var first_terminal = takeTestTerminal(session, first_run);
    defer first_terminal.deinit();
    try std.testing.expect(!first_terminal.file_changes_lost);

    const second_run = try submitSession(session, "degrade rejected file changes event");
    try session.waitRun(second_run);
    var second_terminal = takeTestTerminal(session, second_run);
    defer second_terminal.deinit();
    try std.testing.expectEqual(@as(?u32, wire.STATUS_OK), second_terminal.raw_status_code);
    try std.testing.expectEqual(@as(?sdk.StopReason, .end_turn), second_terminal.stop_reason);
    try std.testing.expect(second_terminal.termination_signal == null);
    try std.testing.expect(second_terminal.file_changes_lost);
    try std.testing.expectEqual(lifecycle.SessionState.idle, session.snapshot().state);

    var retained = runtime.takeEvent() orelse return error.ExpectedOwnedEvent;
    try std.testing.expectEqual(first_run, retained.run_id);
    retained.deinit();
    try std.testing.expect(runtime.takeEvent() == null);
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
    try std.testing.expectError(error.StaleUiResponse, answered.respondPermission(run_id + 1, request_id, .allow_once));
    try std.testing.expectError(error.StaleUiResponse, answered.respondPermission(run_id, request_id + 1, .allow_once));
    try answered.respondPermission(run_id, request_id, .allow_session);
    try std.testing.expectError(error.StaleUiResponse, answered.respondPermission(run_id, request_id, .allow_once));
    fake_core.releaseControlled();
    try answered.waitRun(run_id);
    fake_core.lock();
    const permission_response_valid = fake_core.permission_response_valid;
    fake_core.unlock();
    try std.testing.expect(permission_response_valid);
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

test "Product UI identity collision fails and poisons the active Run" {
    fake_core.reset();
    fake_core.setNextPlan(.ui_wait);
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);
    const run_id = try submitSession(session, "request colliding UI identity");
    try session.waitForState(.waiting_ui);

    try session.failUiRequestIdentityContract(run_id);
    try session.waitRun(run_id);
    var terminal = takeTestTerminal(session, run_id);
    defer terminal.deinit();
    try std.testing.expectEqual(
        @as(?lifecycle.TerminalFailure, .dependency_contract),
        terminal.failure,
    );
    try std.testing.expectEqual(
        lifecycle.SessionDisposition.poisoned,
        terminal.session_disposition_at_completion,
    );
    try std.testing.expectEqual(lifecycle.SessionState.poisoned, session.snapshot().state);
    try closeSession(session, .session_close);
}

test "Session UI requests allocate above the Product history floor" {
    fake_core.reset();
    fake_core.setNextPlan(.ui_wait);
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const workspace_root = if (std.fs.path.sep == '\\')
        "C:\\tmp\\metawork-gate2"
    else
        "/tmp/metawork-gate2";
    const temporary_root = if (std.fs.path.sep == '\\') "C:\\tmp" else "/tmp";
    const session = try runtime.createSession(.{
        .model_binding = fixtureModelBinding(.anthropic_messages),
        .permission_mode = .default,
        .shell_policy = .disabled,
        .workspace = .{
            .canonical_root = workspace_root,
            .trust = .{ .temporary = temporary_root },
        },
        .operation_id_floor = .{ .last_ui_request_id = 7 },
    });
    const run_id = try submitSession(session, "request UI after restored Product history");
    try session.waitForState(.waiting_ui);
    const request_id = session.pendingUiRequest().?;
    try std.testing.expectEqual(@as(u64, 8), request_id);
    try session.respondPermission(run_id, request_id, .allow_once);
    fake_core.releaseControlled();
    try session.waitRun(run_id);
    var terminal = takeTestTerminal(session, run_id);
    terminal.deinit();
    try closeSession(session, .session_close);
}

fn openNoninteractivePermissionSession(
    runtime: *lifecycle.Runtime,
) !*lifecycle.Session {
    const workspace_root = if (std.fs.path.sep == '\\')
        "C:\\tmp\\metawork-gate2"
    else
        "/tmp/metawork-gate2";
    const temporary_root = if (std.fs.path.sep == '\\') "C:\\tmp" else "/tmp";
    return runtime.createSession(.{
        .model_binding = fixtureModelBinding(.anthropic_messages),
        .permission_mode = .accept_edits,
        .shell_policy = .unrestricted,
        .permission_interaction = .noninteractive,
        .workspace = .{
            .canonical_root = workspace_root,
            .trust = .{ .temporary = temporary_root },
        },
    });
}

test "noninteractive permission request becomes a typed stop without pending UI" {
    fake_core.reset();
    fake_core.setNextPlan(.ui_wait);
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openNoninteractivePermissionSession(runtime);

    const run_id = try submitSession(session, "permission cannot suspend a schedule");
    var observed_stop = false;
    for (0..1000) |_| {
        if (session.permissionStopRequest()) |stopped_run_id| {
            try std.testing.expectEqual(run_id, stopped_run_id);
            observed_stop = true;
            break;
        }
        std.Io.Timeout.sleep(.{ .duration = .{
            .raw = std.Io.Duration.fromMilliseconds(1),
            .clock = .awake,
        } }, std.testing.io) catch {};
    }
    try std.testing.expect(observed_stop);
    try std.testing.expect(session.pendingUiRequest() == null);

    // This Agent-level test uses user cancellation only to finish the fake
    // Core Run after observing the stop fact. Product Control's automatic
    // consumption and abort are covered by its own lifecycle test.
    try cancelSession(session, run_id, .user_cancel);
    try session.waitRun(run_id);
    var terminal = takeTestTerminal(session, run_id);
    defer terminal.deinit();
    try std.testing.expectEqual(
        lifecycle.TerminationSignal.permission_required,
        terminal.termination_signal.?,
    );
    try std.testing.expect(session.pendingUiRequest() == null);
    try closeSession(session, .session_close);
}

test "noninteractive permission notification failure terminates without Product abort" {
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
        .event_ready_retry_interval = .fromNanoseconds(1),
        .event_ready_timeout = .fromNanoseconds(2),
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openNoninteractivePermissionSession(runtime);
    const run_id = try submitSession(
        session,
        "permission stop wake cannot reach Product Control",
    );
    var fatal_observed = false;
    for (0..1000) |_| {
        fake_core.lock();
        fatal_observed = fake_core.ui_fatal_callbacks == 1;
        fake_core.unlock();
        if (fatal_observed) break;
        std.Io.Timeout.sleep(.{ .duration = .{
            .raw = std.Io.Duration.fromMilliseconds(1),
            .clock = .awake,
        } }, std.testing.io) catch {};
    }
    if (!fatal_observed) {
        try cancelSession(session, run_id, .user_cancel);
        try session.waitRun(run_id);
        return error.TestUnexpectedResult;
    }

    try session.waitRun(run_id);
    var terminal = takeTestTerminal(session, run_id);
    defer terminal.deinit();
    try std.testing.expectEqual(
        @as(?u32, wire.STATUS_CALLBACK_FAILED),
        terminal.raw_status_code,
    );
    try std.testing.expectEqual(
        lifecycle.TerminationSignal.permission_required,
        terminal.termination_signal.?,
    );
    try std.testing.expectEqual(
        lifecycle.SessionDisposition.poisoned,
        terminal.session_disposition_at_completion,
    );
    try std.testing.expect(session.pendingUiRequest() == null);
    fake_core.lock();
    const abort_calls = fake_core.abort_calls;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 0), abort_calls);
    try closeSession(session, .session_close);
}

test "MetaWork Agent rejects structured questions before product projection" {
    fake_core.reset();
    fake_core.setNextPlan(.ask_question);
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);
    const run_id = try submitSession(session, "attempt structured question");
    try session.waitRun(run_id);
    var terminal = takeTestTerminal(session, run_id);
    defer terminal.deinit();
    try std.testing.expectEqual(
        lifecycle.TerminationSignal{ .callback_failure = .ui },
        terminal.termination_signal.?,
    );
    try std.testing.expect(session.pendingUiRequest() == null);
    fake_core.lock();
    const fatal_callbacks = fake_core.ui_fatal_callbacks;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), fatal_callbacks);
    try closeSession(session, .session_close);
}

test "Session permission grants are reused only by AgentCore within that Session" {
    fake_core.reset();
    fake_core.setNextPlan(.ui_wait_twice);
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 2, .max_sessions = 3 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }

    const session = try openSession(runtime);
    const first_run = try submitSession(session, "grant session permission");
    try session.waitForState(.waiting_ui);
    const first_request = session.pendingUiRequest().?;
    try session.respondPermission(first_run, first_request, .allow_session);
    fake_core.releaseControlled();
    try session.waitRun(first_run);
    var first_terminal = takeTestTerminal(session, first_run);
    first_terminal.deinit();

    const second_run = try submitSession(session, "reuse session permission");
    try session.waitRun(second_run);
    var second_terminal = takeTestTerminal(session, second_run);
    second_terminal.deinit();
    fake_core.lock();
    const same_session_callbacks = fake_core.permission_callback_count;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), same_session_callbacks);
    try closeSession(session, .session_close);

    fake_core.setNextPlan(.ui_wait_twice);
    const fresh_session = try openSession(runtime);
    const fresh_run = try submitSession(fresh_session, "fresh session permission");
    try fresh_session.waitForState(.waiting_ui);
    const fresh_request = fresh_session.pendingUiRequest().?;
    try fresh_session.respondPermission(fresh_run, fresh_request, .allow_session);
    fake_core.releaseControlled();
    try fresh_session.waitRun(fresh_run);
    var fresh_terminal = takeTestTerminal(fresh_session, fresh_run);
    fresh_terminal.deinit();
    fake_core.lock();
    const cross_session_callbacks = fake_core.permission_callback_count;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 2), cross_session_callbacks);
    try closeSession(fresh_session, .session_close);
}

test "permission callback request identity mismatch fails closed" {
    fake_core.reset();
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 2 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }

    for ([_]Plan{ .wrong_ui_request_run_id, .wrong_ui_request_session_id }) |plan| {
        fake_core.setNextPlan(plan);
        const session = try openSession(runtime);
        const run_id = try submitSession(session, "reject mismatched permission identity");
        try session.waitRun(run_id);
        var terminal = takeTestTerminal(session, run_id);
        defer terminal.deinit();
        try std.testing.expectEqual(@as(?u32, wire.STATUS_CALLBACK_FAILED), terminal.raw_status_code);
        try std.testing.expectEqual(
            @as(?lifecycle.TerminalFailure, .dependency_contract),
            terminal.failure,
        );
        try std.testing.expectEqual(lifecycle.SessionState.poisoned, session.snapshot().state);
        try closeSession(session, .session_close);
    }
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

test "UI wait has no deadline and malformed UI fails the Run" {
    fake_core.reset();
    fake_core.setNextPlan(.ui_wait);
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 2,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const waiting = try openSession(runtime);
    const wait_run = try submitSession(waiting, "wait for the user");
    try waiting.waitForState(.waiting_ui);
    // No expiry timer exists any more: well past the former test deadline
    // the request must still be pending, and only an answer ends the wait.
    std.Io.Timeout.sleep(.{ .duration = .{
        .raw = std.Io.Duration.fromMilliseconds(120),
        .clock = .awake,
    } }, std.testing.io) catch {};
    const request_id = waiting.pendingUiRequest() orelse
        return error.TestExpectedPendingUi;
    try waiting.respondPermission(wait_run, request_id, .allow_once);
    fake_core.releaseControlled();
    try waiting.waitRun(wait_run);
    var wait_terminal = takeTestTerminal(waiting, wait_run);
    defer wait_terminal.deinit();
    try std.testing.expectEqual(@as(?sdk.StopReason, .end_turn), wait_terminal.stop_reason);
    try closeSession(waiting, .session_close);

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
        session.respondPermission(run_id, request_id, .allow_once),
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
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 16 });
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
        .{ .plan = .invalid_checkpoint_outcome, .expected_status = wire.STATUS_OK, .expected_stop = null },
        .{ .plan = .invalid_result_flags, .expected_status = wire.STATUS_OK, .expected_stop = null },
        .{ .plan = .mismatched_checkpoint_outcome, .expected_status = wire.STATUS_OK, .expected_stop = wire.STOP_END_TURN },
        .{ .plan = .checkpoint_budget_required_invalid_result, .expected_status = wire.STATUS_CHECKPOINT_BUDGET_REQUIRED, .expected_stop = null },
        .{ .plan = .unknown_status, .expected_status = 42, .expected_stop = null },
        .{ .plan = .stale_compact_status, .expected_status = wire.STATUS_STALE_COMPACT, .expected_stop = null },
        .{ .plan = .image_input_unsupported_status, .expected_status = wire.STATUS_IMAGE_INPUT_UNSUPPORTED, .expected_stop = null },
        .{ .plan = .image_input_capability_unknown_status, .expected_status = wire.STATUS_IMAGE_INPUT_CAPABILITY_UNKNOWN, .expected_stop = null },
        .{ .plan = .unexpected_input_receipt, .expected_status = wire.STATUS_OK, .expected_stop = null },
        .{ .plan = .unexpected_input_receipt_failure, .expected_status = wire.STATUS_RESOURCE_LIMIT, .expected_stop = null },
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
        if (case.expected_status != wire.STATUS_OK and
            case.expected_status != wire.STATUS_CHECKPOINT_BUDGET_REQUIRED)
            try std.testing.expectEqual(
                @as(?lifecycle.DurableBudgetObservation, null),
                terminal.durable_budget,
            );
        try std.testing.expectEqual(lifecycle.SessionState.poisoned, snapshot.state);
        try std.testing.expectError(error.SessionPoisoned, submitSession(session, "must not continue"));
        try closeSession(session, .session_close);
    }
}

test "checkpoint outcomes are typed and budget admission remains retryable" {
    fake_core.reset();
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 3 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }

    fake_core.setNextPlan(.checkpoint_budget_required);
    const budget_session = try openSession(runtime);
    const budget_run = try submitSession(budget_session, "require checkpoint before admission");
    try budget_session.waitRun(budget_run);
    var budget_terminal = takeTestTerminal(budget_session, budget_run);
    defer budget_terminal.deinit();
    try std.testing.expectEqual(
        @as(?sdk.Status, .checkpoint_budget_required),
        budget_terminal.abi_status,
    );
    try std.testing.expectEqual(
        @as(?lifecycle.TerminalFailure, .abi_status),
        budget_terminal.failure,
    );
    try std.testing.expectEqualDeep(
        @as(?lifecycle.DurableBudgetObservation, .{
            .durable_usage_bytes = 4096,
            .required_checkpoint_bytes = 8192,
        }),
        budget_terminal.durable_budget,
    );
    try std.testing.expectEqual(lifecycle.SessionState.idle, budget_session.snapshot().state);
    fake_core.setSessionPlan(.immediate);
    const retry_run = try submitSession(budget_session, "retry after product checkpoint handling");
    try budget_session.waitRun(retry_run);
    var retry_terminal = takeTestTerminal(budget_session, retry_run);
    defer retry_terminal.deinit();
    try std.testing.expectEqual(@as(?sdk.StopReason, .end_turn), retry_terminal.stop_reason);
    try std.testing.expect(retry_terminal.durable_budget != null);
    try closeSession(budget_session, .session_close);

    const terminal_cases = [_]struct {
        plan: Plan,
        expected: sdk.StopReason,
    }{
        .{ .plan = .checkpoint_budget_exhausted, .expected = .checkpoint_budget_exhausted },
        .{ .plan = .checkpoint_resource_limit, .expected = .checkpoint_resource_limit },
    };
    for (terminal_cases) |case| {
        fake_core.setNextPlan(case.plan);
        const session = try openSession(runtime);
        const run_id = try submitSession(session, "validate checkpoint terminal outcome");
        try session.waitRun(run_id);
        var terminal = takeTestTerminal(session, run_id);
        defer terminal.deinit();
        try std.testing.expectEqual(@as(?sdk.StopReason, case.expected), terminal.stop_reason);
        try std.testing.expectEqual(@as(?lifecycle.TerminalFailure, null), terminal.failure);
        try closeSession(session, .session_close);
    }
}

test "checkpoint export streams bytes and accepts opaque generation zero" {
    fake_core.reset();
    const runtime = try createTestRuntime(.{ .max_sessions = 1 });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    const session = try openSession(runtime);
    defer closeSession(session, .session_close) catch unreachable;
    var collector = CheckpointCollector{};
    var outcome = try session.exportCheckpoint(
        checkpoint_test_limits,
        collector.sink(),
        0,
        0,
        "fixture-model",
    );
    defer outcome.deinit();
    switch (outcome) {
        .success => |success| {
            try std.testing.expectEqual(@as(u64, 0), success.checkpoint.generation);
            try std.testing.expectEqual(@as(u64, collector.len), success.checkpoint.total_bytes);
            try std.testing.expectEqualStrings("fixture-checkpoint", collector.bytes[0..collector.len]);
            try std.testing.expectEqualStrings("fixture-model", success.description.model);
        },
        .failure => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(lifecycle.SessionState.idle, session.snapshot().state);
}

test "checkpoint restore installs one exact logical Session and continues identities" {
    for (session_protocol_cases) |case| {
        fake_core.reset();
        fake_core.setCheckpointGeneration(3);
        fake_core.setRestoreHistory(7, 2);
        const runtime = try createTestRuntime(.{ .max_sessions = 2 });
        defer {
            runtime.shutdown() catch unreachable;
            runtime.deinit();
        }
        var source = CheckpointRestoreSource{ .bytes = "fixture-checkpoint" };
        var options = restoreOptions(
            source.source(),
            "000000000000000000000001",
            7,
            2,
        );
        options.session.model_binding.target.protocol = case.protocol;
        var provider_id = "service-instance-b".*;
        options.session.model_binding.target.provider_id = &provider_id;
        const route = try runtime.restoreSessionRoute(options);
        @memset(&provider_id, 'x');
        try std.testing.expectEqualStrings("service-instance-b", route.session.provider_id);
        try std.testing.expectEqual(case.protocol, route.session.protocol);
        try std.testing.expectEqual(@as(?u32, case.provider_code), fake_core.last_restored_provider_kind_code);
        try std.testing.expectEqual(@as(?u32, case.protocol_code), fake_core.last_restored_protocol_kind_code);
        try std.testing.expectEqual(@as(usize, 1), fake_core.checkpoint_restores);
        try std.testing.expectEqual(@as(u64, 1), route.id);
        try std.testing.expectEqual(lifecycle.CheckpointRestoreHealth.complete, route.report.health);
        try std.testing.expectEqual(@as(u64, 3), route.report.checkpoint_generation);
        try std.testing.expectEqual(source.bytes.len, source.offset);
        const next_run_id = try route.session.prepareRun(.{ .text = "continue" });
        try std.testing.expectEqual(@as(u64, 8), next_run_id);
        try route.session.cancelPreparedRun(next_run_id);
        try closeSession(route.session, .session_close);
        try runtime.releaseClosedSession(route.session);
    }
}

test "checkpoint restore keeps expectation at checkpoint while allocating above Product history" {
    fake_core.reset();
    fake_core.setCheckpointGeneration(3);
    fake_core.setRestoreHistory(1, 1);
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var source = CheckpointRestoreSource{ .bytes = "fixture-checkpoint" };
    var options = restoreOptions(
        source.source(),
        "000000000000000000000001",
        1,
        1,
    );
    options.session.operation_id_floor = .{
        .last_run_id = 3,
        .last_compact_id = 4,
        .last_ui_request_id = 7,
    };
    const route = try runtime.restoreSessionRoute(options);
    fake_core.setSessionPlan(.ui_wait);
    const run_id = try route.session.prepareRun(.{ .text = "continue after excluded history" });
    try std.testing.expectEqual(@as(u64, 4), run_id);
    try route.session.cancelPreparedRun(run_id);
    const compact_id = try route.session.prepareCompact();
    try std.testing.expectEqual(@as(u64, 5), compact_id);
    try route.session.cancelPreparedCompact(compact_id);
    const permission_run_id = try submitSession(route.session, "request UI after excluded history");
    try route.session.waitForState(.waiting_ui);
    const request_id = route.session.pendingUiRequest().?;
    try std.testing.expectEqual(@as(u64, 8), request_id);
    try route.session.respondPermission(permission_run_id, request_id, .allow_once);
    fake_core.releaseControlled();
    try route.session.waitRun(permission_run_id);
    var terminal = takeTestTerminal(route.session, permission_run_id);
    terminal.deinit();
    try closeSession(route.session, .session_close);
    try runtime.releaseClosedSession(route.session);
}

test "Runtime shutdown waits for restore and rejects its late candidate" {
    const RestoreHarness = struct {
        runtime: *lifecycle.Runtime,
        source: *CheckpointRestoreSource,
        result: std.atomic.Value(enum(u8) { pending, rejected, unexpected }) = .init(.pending),

        fn run(self: *@This()) void {
            _ = self.runtime.restoreSessionRoute(restoreOptions(
                self.source.source(),
                "000000000000000000000001",
                0,
                0,
            )) catch |err| {
                self.result.store(
                    if (err == error.RuntimeShuttingDown) .rejected else .unexpected,
                    .release,
                );
                return;
            };
            self.result.store(.unexpected, .release);
        }
    };
    const ShutdownHarness = struct {
        runtime: *lifecycle.Runtime,
        failed: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            self.runtime.shutdown() catch self.failed.store(true, .release);
        }
    };

    fake_core.reset();
    fake_core.setCheckpointGeneration(3);
    fake_core.setRestoreHistory(0, 0);
    fake_core.armControlledRestore();
    const runtime = try createTestRuntime(.{ .max_sessions = 1 });
    var runtime_live = true;
    defer if (runtime_live) {
        runtime.shutdown() catch {};
        runtime.deinit();
    };
    var source = CheckpointRestoreSource{ .bytes = "fixture-checkpoint" };
    var restore_harness = RestoreHarness{ .runtime = runtime, .source = &source };
    const restore_thread = try std.Thread.spawn(.{}, RestoreHarness.run, .{&restore_harness});
    fake_core.waitUntilRestoreEntered();
    try std.testing.expectError(error.SessionCapacity, openSession(runtime));

    var shutdown_harness = ShutdownHarness{ .runtime = runtime };
    const shutdown_thread = try std.Thread.spawn(.{}, ShutdownHarness.run, .{&shutdown_harness});
    // Yielding a fixed number of times does not establish that the other
    // thread entered shutdown. Observe its admission barrier before releasing
    // the restore candidate, otherwise this test races a valid early restore.
    while (!runtime.shutting_down.load(.acquire)) std.Thread.yield() catch {};
    fake_core.lock();
    const destroyed_while_restore_blocked = fake_core.runtime_destroyed;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 0), destroyed_while_restore_blocked);

    fake_core.releaseControlledRestore();
    restore_thread.join();
    shutdown_thread.join();
    try std.testing.expectEqual(.rejected, restore_harness.result.load(.acquire));
    try std.testing.expect(!shutdown_harness.failed.load(.acquire));
    fake_core.lock();
    const restored = fake_core.checkpoint_restores;
    const sessions_destroyed = fake_core.session_destroyed;
    const runtimes_destroyed = fake_core.runtime_destroyed;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), restored);
    try std.testing.expectEqual(@as(usize, 1), sessions_destroyed);
    try std.testing.expectEqual(@as(usize, 1), runtimes_destroyed);
    runtime.deinit();
    runtime_live = false;
}

test "Runtime shutdown waits for identity update and rejects its late candidate" {
    const RestoreHarness = struct {
        runtime: *lifecycle.Runtime,
        source: *CheckpointRestoreSource,
        result: std.atomic.Value(enum(u8) { pending, rejected, unexpected }) = .init(.pending),

        fn run(self: *@This()) void {
            _ = self.runtime.restoreSessionRoute(restoreOptions(
                self.source.source(),
                "000000000000000000000001",
                0,
                0,
            )) catch |err| {
                self.result.store(
                    if (err == error.RuntimeShuttingDown) .rejected else .unexpected,
                    .release,
                );
                return;
            };
            self.result.store(.unexpected, .release);
        }
    };
    const ShutdownHarness = struct {
        runtime: *lifecycle.Runtime,
        failed: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            self.runtime.shutdown() catch self.failed.store(true, .release);
        }
    };

    fake_core.reset();
    fake_core.setCheckpointGeneration(3);
    fake_core.setRestoreHistory(0, 0);
    fake_core.armControlledPrompt();
    const runtime = try createTestRuntime(.{ .max_sessions = 1 });
    var runtime_live = true;
    defer if (runtime_live) {
        runtime.shutdown() catch {};
        runtime.deinit();
    };
    var source = CheckpointRestoreSource{ .bytes = "fixture-checkpoint" };
    var restore_harness = RestoreHarness{ .runtime = runtime, .source = &source };
    const restore_thread = try std.Thread.spawn(.{}, RestoreHarness.run, .{&restore_harness});
    fake_core.waitUntilPromptEntered();
    try std.testing.expectError(error.SessionCapacity, openSession(runtime));

    var shutdown_harness = ShutdownHarness{ .runtime = runtime };
    const shutdown_thread = try std.Thread.spawn(.{}, ShutdownHarness.run, .{&shutdown_harness});
    // Yielding a fixed number of times does not establish that the other
    // thread entered shutdown. Observe its admission barrier before releasing
    // the restore candidate, otherwise this test races a valid early restore.
    while (!runtime.shutting_down.load(.acquire)) std.Thread.yield() catch {};
    fake_core.lock();
    const destroyed_while_restore_blocked = fake_core.runtime_destroyed;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 0), destroyed_while_restore_blocked);

    fake_core.releaseControlledPrompt();
    restore_thread.join();
    shutdown_thread.join();
    try std.testing.expectEqual(.rejected, restore_harness.result.load(.acquire));
    try std.testing.expect(!shutdown_harness.failed.load(.acquire));
    fake_core.lock();
    const restored = fake_core.checkpoint_restores;
    const sessions_destroyed = fake_core.session_destroyed;
    const runtimes_destroyed = fake_core.runtime_destroyed;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), restored);
    try std.testing.expectEqual(@as(usize, 1), sessions_destroyed);
    try std.testing.expectEqual(@as(usize, 1), runtimes_destroyed);
    runtime.deinit();
    runtime_live = false;
}

test "restore cleanup failure remains Runtime-owned until shutdown" {
    fake_core.reset();
    fake_core.setCheckpointGeneration(3);
    fake_core.setRestoreHistory(0, 0);
    fake_core.forceNextSessionDestroyStatus(wire.STATUS_BUSY);
    const runtime = try createTestRuntime(.{ .max_sessions = 1 });
    var runtime_live = true;
    defer if (runtime_live) {
        runtime.shutdown() catch {};
        runtime.deinit();
    };
    var source = CheckpointRestoreSource{ .bytes = "fixture-checkpoint" };
    try std.testing.expectError(
        error.RestoreContractFailed,
        runtime.restoreSessionRoute(restoreOptions(
            source.source(),
            "ffffffffffffffffffffffff",
            0,
            0,
        )),
    );
    fake_core.lock();
    const destroyed_before_shutdown = fake_core.session_destroyed;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 0), destroyed_before_shutdown);
    try runtime.shutdown();
    fake_core.lock();
    const destroyed_after_shutdown = fake_core.session_destroyed;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), destroyed_after_shutdown);
    runtime.deinit();
    runtime_live = false;
}

test "checkpoint description cannot change the bound logical Session identity" {
    fake_core.reset();
    const runtime = try createTestRuntime(.{ .max_sessions = 1 });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    const session = try openSession(runtime);
    defer closeSession(session, .session_close) catch unreachable;
    var collector = CheckpointCollector{};
    var first = try session.exportCheckpoint(
        checkpoint_test_limits,
        collector.sink(),
        0,
        0,
        "fixture-model",
    );
    switch (first) {
        .success => {},
        .failure => return error.TestUnexpectedResult,
    }
    first.deinit();

    fake_core.setCheckpointGeneration(1);
    fake_core.mismatchNextCheckpointDescriptionSessionId();
    collector = .{};
    var second = try session.exportCheckpoint(
        checkpoint_test_limits,
        collector.sink(),
        0,
        0,
        "fixture-model",
    );
    defer second.deinit();
    switch (second) {
        .failure => |failure| try std.testing.expectEqual(
            lifecycle.CheckpointFailureReason.dependency_contract,
            failure.reason,
        ),
        .success => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(lifecycle.SessionState.poisoned, session.snapshot().state);
}

test "checkpoint IO and product limits keep Session reusable" {
    const cases = [_]struct {
        status: ?u32 = null,
        sink_result: lifecycle.CheckpointSinkWriteResult,
        expected: lifecycle.CheckpointFailureReason,
    }{
        .{ .sink_result = .cancelled, .expected = .cancelled },
        .{ .sink_result = .io_failed, .expected = .io_failed },
        .{ .status = wire.STATUS_INVALID_ARGUMENT, .sink_result = .ok, .expected = .invalid_argument },
        .{ .status = wire.STATUS_RESOURCE_LIMIT, .sink_result = .ok, .expected = .resource_limit },
        .{ .status = wire.STATUS_BUSY, .sink_result = .ok, .expected = .busy },
    };
    for (cases) |case| {
        fake_core.reset();
        if (case.status) |status| fake_core.forceNextCheckpointExportStatus(status);
        const runtime = try createTestRuntime(.{ .max_sessions = 1 });
        defer {
            runtime.shutdown() catch unreachable;
            runtime.deinit();
        }
        const session = try openSession(runtime);
        defer closeSession(session, .session_close) catch unreachable;
        var collector = CheckpointCollector{ .result = case.sink_result };
        var outcome = try session.exportCheckpoint(
            checkpoint_test_limits,
            collector.sink(),
            0,
            0,
            "fixture-model",
        );
        defer outcome.deinit();
        switch (outcome) {
            .failure => |failure| {
                try std.testing.expectEqual(case.expected, failure.reason);
                try std.testing.expectEqual(lifecycle.SessionState.idle, session.snapshot().state);
            },
            .success => return error.TestUnexpectedResult,
        }
    }
}

test "checkpoint Core fatal and entry-illegal statuses close Session admission" {
    const statuses = [_]u32{
        wire.STATUS_OUT_OF_MEMORY,
        wire.STATUS_CORE_ERROR,
        wire.STATUS_CHECKPOINT_BUDGET_REQUIRED,
        wire.STATUS_CHECKPOINT_CORRUPT,
        wire.STATUS_CHECKPOINT_UNSUPPORTED,
        wire.STATUS_CHECKPOINT_INCOMPATIBLE,
        wire.STATUS_LOGICAL_SESSION_CONFLICT,
        wire.STATUS_IMAGE_INPUT_UNSUPPORTED,
    };
    for (statuses) |status| {
        fake_core.reset();
        fake_core.forceNextCheckpointExportStatus(status);
        const runtime = try createTestRuntime(.{ .max_sessions = 1 });
        defer {
            runtime.shutdown() catch unreachable;
            runtime.deinit();
        }
        const session = try openSession(runtime);
        defer closeSession(session, .session_close) catch unreachable;
        var collector = CheckpointCollector{};
        var outcome = try session.exportCheckpoint(
            checkpoint_test_limits,
            collector.sink(),
            0,
            0,
            "fixture-model",
        );
        defer outcome.deinit();
        switch (outcome) {
            .failure => |failure| {
                if (status == wire.STATUS_CHECKPOINT_BUDGET_REQUIRED or
                    status == wire.STATUS_CHECKPOINT_CORRUPT or
                    status == wire.STATUS_CHECKPOINT_UNSUPPORTED or
                    status == wire.STATUS_CHECKPOINT_INCOMPATIBLE or
                    status == wire.STATUS_LOGICAL_SESSION_CONFLICT or
                    status == wire.STATUS_IMAGE_INPUT_UNSUPPORTED)
                    try std.testing.expectEqual(lifecycle.CheckpointFailureReason.dependency_contract, failure.reason)
                else
                    try std.testing.expect(failure.reason == .out_of_memory or failure.reason == .core_error);
                try std.testing.expectEqual(lifecycle.SessionState.poisoned, session.snapshot().state);
            },
            .success => return error.TestUnexpectedResult,
        }
    }
}

test "checkpoint describe has an independent conservative status disposition" {
    const cases = [_]struct {
        status: u32,
        expected: lifecycle.CheckpointFailureReason,
        state: lifecycle.SessionState,
    }{
        .{ .status = wire.STATUS_INVALID_ARGUMENT, .expected = .invalid_argument, .state = .idle },
        .{ .status = wire.STATUS_RESOURCE_LIMIT, .expected = .resource_limit, .state = .idle },
        .{ .status = wire.STATUS_BUSY, .expected = .busy, .state = .idle },
        .{ .status = wire.STATUS_OUT_OF_MEMORY, .expected = .out_of_memory, .state = .poisoned },
        .{ .status = wire.STATUS_CORE_ERROR, .expected = .core_error, .state = .poisoned },
        .{ .status = wire.STATUS_CHECKPOINT_BUDGET_REQUIRED, .expected = .dependency_contract, .state = .poisoned },
    };
    for (cases) |case| {
        fake_core.reset();
        fake_core.forceNextCheckpointDescribeStatus(case.status);
        const runtime = try createTestRuntime(.{ .max_sessions = 1 });
        defer {
            runtime.shutdown() catch unreachable;
            runtime.deinit();
        }
        const session = try openSession(runtime);
        defer closeSession(session, .session_close) catch unreachable;
        var collector = CheckpointCollector{};
        var outcome = try session.exportCheckpoint(
            checkpoint_test_limits,
            collector.sink(),
            0,
            0,
            "fixture-model",
        );
        defer outcome.deinit();
        switch (outcome) {
            .failure => |failure| try std.testing.expectEqual(case.expected, failure.reason),
            .success => return error.TestUnexpectedResult,
        }
        try std.testing.expectEqual(case.state, session.snapshot().state);
    }
}

test "checkpoint malformed results and sink fatal are dependency contract failures" {
    const cases = [_]enum { result, description, sink_fatal, sink_missing }{
        .result,
        .description,
        .sink_fatal,
        .sink_missing,
    };
    for (cases) |case| {
        fake_core.reset();
        switch (case) {
            .result => fake_core.makeNextCheckpointResultMalformed(),
            .description => fake_core.makeNextCheckpointDescriptionMalformed(),
            .sink_fatal => {},
            .sink_missing => fake_core.forceNextCheckpointExportStatus(
                wire.STATUS_CHECKPOINT_IO,
            ),
        }
        const runtime = try createTestRuntime(.{ .max_sessions = 1 });
        defer {
            runtime.shutdown() catch unreachable;
            runtime.deinit();
        }
        const session = try openSession(runtime);
        defer closeSession(session, .session_close) catch unreachable;
        var collector = CheckpointCollector{
            .result = if (case == .sink_fatal) .contract_failed else .ok,
        };
        var outcome = try session.exportCheckpoint(
            checkpoint_test_limits,
            collector.sink(),
            0,
            0,
            "fixture-model",
        );
        defer outcome.deinit();
        switch (outcome) {
            .failure => |failure| try std.testing.expectEqual(
                lifecycle.CheckpointFailureReason.dependency_contract,
                failure.reason,
            ),
            .success => return error.TestUnexpectedResult,
        }
        try std.testing.expectEqual(lifecycle.SessionState.poisoned, session.snapshot().state);
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

test "Session and Runtime destroy failures are explicit and retryable" {
    fake_core.reset();
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 2 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);
    fake_core.failNextSessionDestroy();
    try std.testing.expectError(error.SessionDestroyFailed, closeSession(session, .session_close));
    try std.testing.expectEqual(lifecycle.SessionState.closing, session.snapshot().state);
    try closeSession(session, .session_close);

    const contract_session = try openSession(runtime);
    fake_core.forceNextSessionDestroyStatus(wire.STATUS_STALE_COMPACT);
    try std.testing.expectError(
        error.SessionDestroyFailed,
        closeSession(contract_session, .session_close),
    );
    try std.testing.expectEqual(
        lifecycle.SessionState.closing,
        contract_session.snapshot().state,
    );
    try closeSession(contract_session, .session_close);

    fake_core.failNextRuntimeDestroy();
    try std.testing.expectError(error.RuntimeDestroyFailed, shutdownTestComposition(runtime));
    try shutdownTestComposition(runtime);
    fake_core.lock();
    const releases = fake_core.buffer_releases;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 3), releases);
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

test "Session create preserves typed MCP rejections and fails closed for other statuses" {
    for ([_]struct { status: u32, failure: anyerror, malformed_handle: bool = false }{
        .{ .status = wire.STATUS_MCP_NOT_REFRESHED, .failure = error.McpNotRefreshed },
        .{ .status = wire.STATUS_INVALID_MCP_SELECTION, .failure = error.InvalidMcpSelection },
        .{ .status = wire.STATUS_INVALID_MCP_SELECTION, .failure = error.CoreCallFailed, .malformed_handle = true },
        .{ .status = wire.STATUS_CORE_ERROR, .failure = error.CoreCallFailed },
        .{ .status = 0xffffffff, .failure = error.CoreCallFailed },
    }) |case| {
        fake_core.reset();
        const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
        defer {
            shutdownTestComposition(runtime) catch unreachable;
            deinitTestComposition(runtime);
        }
        fake_core.forced_session_create_status = case.status;
        fake_core.malformed_session_create_handle = case.malformed_handle;
        try std.testing.expectError(case.failure, openSession(runtime));
        const session = try openSession(runtime);
        try closeSession(session, .session_close);
        try std.testing.expectEqual(@as(usize, 1), fake_core.session_created);
        try std.testing.expectEqual(@as(usize, 1), fake_core.buffer_releases);
    }
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
    fake_core.waitRunEntered();
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
    fake_core.waitRunEntered();
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
    fake_core.waitRunEntered();
    try cancelSession(session, third, .timeout);
    try session.waitRun(third);
    var timeout_terminal = takeTestTerminal(session, third);
    defer timeout_terminal.deinit();
    try std.testing.expectEqual(@as(?u32, wire.STATUS_OK), timeout_terminal.raw_abort_status_code);
    try std.testing.expectEqual(
        lifecycle.TerminationSignal{ .interrupted = .timeout },
        timeout_terminal.termination_signal.?,
    );

    fake_core.rearmControlled();
    const fourth = try submitSession(session, "wrong operation status");
    fake_core.waitRunEntered();
    fake_core.forceNextAbortStatus(wire.STATUS_STALE_COMPACT);
    try cancelSession(session, fourth, .user_cancel);
    fake_core.releaseControlled();
    try session.waitRun(fourth);
    var contract_terminal = takeTestTerminal(session, fourth);
    defer contract_terminal.deinit();
    try std.testing.expectEqual(
        @as(?u32, wire.STATUS_STALE_COMPACT),
        contract_terminal.raw_abort_status_code,
    );
    try std.testing.expectEqual(
        @as(?lifecycle.TerminalFailure, .dependency_contract),
        contract_terminal.failure,
    );
    try std.testing.expectEqual(lifecycle.SessionState.poisoned, session.snapshot().state);
    try closeSession(session, .session_close);

    fake_core.lock();
    const releases = fake_core.buffer_releases;
    const abort_calls = fake_core.abort_calls;
    const last_abort_reason = fake_core.last_abort_reason;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 3), releases);
    try std.testing.expectEqual(@as(usize, 4), abort_calls);
    try std.testing.expectEqual(@as(?u32, wire.ABORT_USER_REQUEST), last_abort_reason);
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
    const executor = try product_control_executor.Executor.create(
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

fn expectMetaWorkProfile(profile: fixture.FakePromptProfile) !void {
    try std.testing.expectEqual(@as(usize, 2), profile.count);
    try std.testing.expectEqualStrings("metacodes:identity", profile.ids[0][0..profile.id_lens[0]]);
    try std.testing.expectEqualStrings("metacodes:subagent", profile.ids[1][0..profile.id_lens[1]]);
    for (0..2) |i| {
        const text = profile.texts[i][0..profile.text_lens[i]];
        try std.testing.expect(std.mem.indexOf(u8, text, "MetaWork") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "Metask AgentCore") == null);
        try std.testing.expect(std.mem.indexOf(u8, text, "不主动介绍底层执行内核、模型名称或模型厂商") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "仅在用户明确询问相关技术信息时") != null);
        try std.testing.expect(std.unicode.utf8ValidateSlice(text));
    }
}

test "Agent identity survives borrowed create input and updates old or equal restore profiles" {
    for ([_]bool{ false, true }) |matching| {
        fake_core.reset();
        fake_core.setCheckpointGeneration(3);
        const runtime = try createTestRuntime(.{ .max_sessions = 1 });
        defer {
            runtime.shutdown() catch unreachable;
            runtime.deinit();
        }
        const fresh = try openSession(runtime);
        const raw: *fixture.FakeSession = @ptrCast(@alignCast(fresh.raw.?));
        const expected = raw.prompt_profile;
        try expectMetaWorkProfile(expected);
        try closeSession(fresh, .session_close);
        try runtime.releaseClosedSession(fresh);
        if (matching) fake_core.restored_prompt_profile = expected;
        var source = CheckpointRestoreSource{ .bytes = "fixture-checkpoint" };
        const restored = try runtime.restoreSessionRoute(restoreOptions(source.source(), "000000000000000000000002", 0, 0));
        const restored_raw: *fixture.FakeSession = @ptrCast(@alignCast(restored.session.raw.?));
        try std.testing.expect(std.meta.eql(expected, restored_raw.prompt_profile));
        try std.testing.expectEqual(@as(usize, 1), fake_core.prompt_updates);
        try std.testing.expectEqual(@as(usize, if (matching) 0 else 1), fake_core.prompt_changes);
    }
}

test "identity update refusal and malformed results never publish a usable restore" {
    const cases = [_]struct { status: ?u32 = null, malformed: bool = false, cleanup_fails: bool = false, expected: anyerror }{
        .{ .status = wire.STATUS_INVALID_ARGUMENT, .expected = error.RestoreFailed },
        .{ .status = wire.STATUS_RESOURCE_LIMIT, .expected = error.RestoreFailed },
        .{ .status = wire.STATUS_CHECKPOINT_BUDGET_REQUIRED, .expected = error.RestoreFailed },
        .{ .status = 0xffff, .expected = error.RestoreContractFailed },
        .{ .status = wire.STATUS_STALE_RUN, .expected = error.RestoreContractFailed },
        .{ .malformed = true, .expected = error.RestoreContractFailed },
        .{ .status = wire.STATUS_RESOURCE_LIMIT, .cleanup_fails = true, .expected = error.RestoreContractFailed },
    };
    for (cases) |case| {
        fake_core.reset();
        fake_core.setCheckpointGeneration(3);
        fake_core.forced_prompt_status = case.status;
        fake_core.malformed_prompt_diagnostic = case.malformed;
        if (case.cleanup_fails) fake_core.forceNextSessionDestroyStatus(wire.STATUS_BUSY);
        const runtime = try createTestRuntime(.{ .max_sessions = 1 });
        defer {
            runtime.shutdown() catch unreachable;
            runtime.deinit();
        }
        var source = CheckpointRestoreSource{ .bytes = "fixture-checkpoint" };
        try std.testing.expectError(case.expected, runtime.restoreSessionRoute(restoreOptions(source.source(), "000000000000000000000001", 0, 0)));
        try std.testing.expectEqual(@as(usize, 0), runtime.active_restore_calls);
        try std.testing.expect(!runtime.session_reservations[0]);
        try std.testing.expectEqual(@as(usize, 0), fake_core.prompt_changes);
        if (case.cleanup_fails) {
            try std.testing.expectEqual(lifecycle.SessionState.poisoned, runtime.sessions[0].?.snapshot().state);
            try std.testing.expectError(error.SessionCapacity, openSession(runtime));
        } else {
            try std.testing.expect(runtime.sessions[0] == null);
            try std.testing.expectEqual(@as(usize, 1), fake_core.session_destroyed);
            _ = try openSession(runtime);
        }
        try runtime.shutdown();
        try std.testing.expectEqual(fake_core.session_created, fake_core.session_destroyed);
    }
}

test "idle permission mode mutation validates authority and preserves same-mode generation" {
    fake_core.reset();
    const runtime = try createTestRuntime(.{ .max_sessions = 1 });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    const session = try openSession(runtime);
    const noop = try session.updatePermissionMode(.default, .default);
    try std.testing.expect(!noop.changed);
    try std.testing.expectEqual(@as(u64, 1), noop.policy_generation);
    const changed = try session.updatePermissionMode(.default, .full_access);
    try std.testing.expect(changed.changed);
    try std.testing.expectEqual(@as(u64, 2), changed.policy_generation);
    var captured = try session.captureRestoreInputs();
    defer captured.deinit() catch unreachable;
    try std.testing.expectEqual(lifecycle.PermissionMode.full_access, captured.permission_mode);
    const restored = try session.updatePermissionMode(.full_access, .accept_edits);
    try std.testing.expectEqual(@as(u64, 3), restored.policy_generation);
}

test "permission mode mutation rejects queued work and mismatched authority" {
    fake_core.reset();
    const runtime = try createTestRuntime(.{ .max_sessions = 1 });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    const session = try openSession(runtime);
    const id = try session.prepareRun(.{ .text = "hold admission" });
    try std.testing.expectError(error.SessionNotIdle, session.updatePermissionMode(.default, .full_access));
    try session.cancelPreparedRun(id);
    try std.testing.expectError(error.PermissionModeUpdateFailed, session.updatePermissionMode(.accept_edits, .full_access));
    try std.testing.expectEqual(lifecycle.SessionState.poisoned, session.snapshot().state);
}

test "permission mode failures preserve authority or close admission without reverse mutation" {
    const cases = [_]struct { status: u32, expected: anyerror, poisoned: bool = false }{
        .{ .status = wire.STATUS_BUSY, .expected = error.SessionNotIdle },
        .{ .status = wire.STATUS_INVALID_ARGUMENT, .expected = error.PermissionModeUpdateFailed },
        .{ .status = wire.STATUS_OUT_OF_MEMORY, .expected = error.PermissionModeUpdateFailed },
        .{ .status = wire.STATUS_RESOURCE_LIMIT, .expected = error.PermissionModeUpdateFailed },
        .{ .status = wire.STATUS_CHECKPOINT_BUDGET_REQUIRED, .expected = error.PermissionModeBudgetRequired },
        .{ .status = wire.STATUS_INVALID_STATE, .expected = error.PermissionModeUpdateFailed, .poisoned = true },
        .{ .status = wire.STATUS_CORE_ERROR, .expected = error.PermissionModeUpdateFailed, .poisoned = true },
        .{ .status = wire.STATUS_STALE_RUN, .expected = error.PermissionModeUpdateFailed, .poisoned = true },
        .{ .status = 0xffff, .expected = error.PermissionModeUpdateFailed, .poisoned = true },
    };
    for (cases) |case| {
        fake_core.reset();
        const runtime = try createTestRuntime(.{ .max_sessions = 1 });
        defer {
            runtime.shutdown() catch unreachable;
            runtime.deinit();
        }
        const session = try openSession(runtime);
        const raw: *fixture.FakeSession = @ptrCast(@alignCast(session.raw.?));
        raw.lock();
        raw.permission_session_granted = true;
        raw.forced_permission_mode_status = case.status;
        raw.unlock();
        try std.testing.expectError(case.expected, session.updatePermissionMode(.default, .full_access));
        try std.testing.expectEqual(@as(lifecycle.SessionState, if (case.poisoned) .poisoned else .idle), session.snapshot().state);
        raw.lock();
        const mode = raw.permission_mode_code;
        const generation = raw.policy_generation;
        const grant = raw.permission_session_granted;
        const consumed = raw.forced_permission_mode_status == null;
        raw.unlock();
        try std.testing.expectEqual(wire.PERMISSION_DEFAULT, mode);
        try std.testing.expectEqual(@as(u64, 1), generation);
        try std.testing.expect(grant and consumed);
        if (case.poisoned) {
            try std.testing.expectError(error.SessionPoisoned, session.updatePermissionMode(.default, .default));
        } else {
            const unchanged = try session.updatePermissionMode(.default, .default);
            try std.testing.expect(!unchanged.changed);
            try std.testing.expectEqual(@as(u64, 1), unchanged.policy_generation);
            const changed = try session.updatePermissionMode(.default, .full_access);
            try std.testing.expect(changed.changed);
            try std.testing.expectEqual(@as(u64, 2), changed.policy_generation);
        }
    }
}

test "canonical AgentCore loads builtin document and ZIP resources and binds their policy to a Session" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home");
    try tmp.dir.createDirPath(std.testing.io, "workspace");
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, "home", std.testing.allocator);
    defer std.testing.allocator.free(home);
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, "workspace", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const assets = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, "src/product/skill/assets", std.testing.allocator);
    defer std.testing.allocator.free(assets);
    const runtime = try lifecycle.Runtime.init(std.testing.io, std.testing.allocator, .{ .max_sessions = 1 });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    var acquired = try runtime.querySkillCatalog(.{
        .canonical_user_home = home,
        .target = .{ .workspace = .{ .canonical_root = root, .epoch = "office" } },
        .additional_sources = &.{.{ .canonical_root = assets, .scope = .user, .source_instance_id = "office-test" }},
    });
    defer acquired.projection.deinit();
    defer runtime.releaseSkillCatalog(acquired.lease) catch unreachable;
    try std.testing.expectEqual(lifecycle.CatalogHealth.healthy, acquired.projection.health);
    try std.testing.expectEqual(@as(usize, 3), acquired.projection.skills.len);
    var ids: [3][]const u8 = undefined;
    for (acquired.projection.skills, 0..) |skill, index| {
        try std.testing.expect(std.mem.eql(u8, skill.invocation_name, "docx") or std.mem.eql(u8, skill.invocation_name, "xlsx") or std.mem.eql(u8, skill.invocation_name, "pptx"));
        try std.testing.expectEqualStrings("office-test", skill.source_instance_id);
        try std.testing.expectEqual(lifecycle.CatalogSourceScope.user, skill.source_scope);
        ids[index] = skill.skill_id;
    }
    const session = try runtime.createSession(.{
        .model_binding = fixtureModelBinding(.anthropic_messages),
        .permission_mode = .default,
        .shell_policy = .unrestricted,
        .workspace = .{ .canonical_root = root, .trust = .explicitly_trusted },
        .canonical_user_home = home,
        .workspace_epoch = "office",
        .skill_catalog = acquired.lease,
        .skill_policy = .{ .granted_skill_ids = &ids },
    });
    defer session.close(.session_close) catch unreachable;
    try session.refreshSkillCatalog(acquired.lease, .{ .granted_skill_ids = &ids });
    try std.testing.expectEqual(lifecycle.SessionState.idle, session.snapshot().state);
}
