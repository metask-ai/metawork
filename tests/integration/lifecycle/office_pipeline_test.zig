//! Canonical binary, production callback/pump and Product projection/drain.
//! Only the remote provider and credential vault are synthetic local effects.
const f = @import("lifecycle_fixture");
const std = f.std;
const agent = f.lifecycle;
const control_api = f.product_control;
const task_api = f.product_task;
const state = task_api.testing.state_module;
const options = @import("office_pipeline_options");
const builtin = @import("builtin");

const Provider = struct {
    child: std.process.Child,
    endpoint: []u8,

    fn start(root: []const u8, mode: []const u8) !Provider {
        const trace = try std.fs.path.join(std.testing.allocator, &.{ root, "trace.jsonl" });
        defer std.testing.allocator.free(trace);
        var child = try std.process.spawn(std.testing.io, .{
            .argv = &.{ options.node_path, options.fixture_path, trace, mode, options.office_archive },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .inherit,
            .create_no_window = true,
        });
        errdefer child.kill(std.testing.io);
        var storage: [1024]u8 = undefined;
        var reader = child.stdout.?.readerStreaming(std.testing.io, &storage);
        const line = try reader.interface.takeDelimiterExclusive('\n');
        if (try reader.interface.takeByte() != '\n') return error.InvalidFixtureHandshake;
        const ready = try std.json.parseFromSlice(struct { endpoint: []const u8 }, std.testing.allocator, line, .{});
        defer ready.deinit();
        return .{ .child = child, .endpoint = try std.testing.allocator.dupe(u8, ready.value.endpoint) };
    }
    fn deinit(self: *Provider) void {
        self.child.kill(std.testing.io);
        std.testing.allocator.free(self.endpoint);
    }
};

test "canonical finalizing Stop can abort while terminal Stop preserves authentication failure" {
    const Consumer = struct {
        runtime: *agent.Runtime = undefined,
        session: *agent.Session = undefined,
        phase: agent.RunStatePhase,
        requested: bool = false,
        fn notify(context: ?*anyopaque) agent.EventReadyNotification {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            while (self.runtime.takeEvent()) |value| {
                var event = value;
                defer event.deinit();
                if (!self.requested and event.event.value == .known and event.event.value.known == .run_state and
                    event.event.value.known.run_state.phase == self.phase)
                {
                    self.requested = true;
                    self.session.requestTermination(event.run_id, .{ .interrupted = .user_cancel }) catch unreachable;
                }
            }
            return .scheduled;
        }
    };
    for ([_]agent.RunStatePhase{ .finalizing, .failed }) |phase| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        const root = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(root);
        var provider = try Provider.start(root, "boundary-auth");
        defer provider.deinit();
        var consumer: Consumer = .{ .phase = phase };
        const runtime = try agent.Runtime.init(std.testing.io, std.testing.allocator, .{ .max_sessions = 1, .event_ready_notifier = .{ .context = &consumer, .notify_fn = Consumer.notify } });
        defer {
            runtime.shutdown() catch unreachable;
            runtime.deinit();
        }
        consumer.runtime = runtime;
        const session = try runtime.createSession(.{
            .model_binding = .{ .target = .{ .provider_id = "boundary-fixture", .protocol = .anthropic_messages, .base_url = provider.endpoint, .model = "claude-sonnet-4-20250514" }, .credential = "synthetic-boundary-key" },
            .permission_mode = .default,
            .shell_policy = .unrestricted,
            .workspace = .{ .canonical_root = root, .trust = .explicitly_trusted },
            .canonical_user_home = root,
        });
        consumer.session = session;
        const id = try session.prepareRun(.{ .text = "Exercise authentication failure and Stop ordering." });
        var run = try session.beginRun(id);
        var terminal = run.execute();
        run.deinit();
        defer terminal.deinit();
        try std.testing.expect(consumer.requested);
        try std.testing.expect(terminal.failure == null);
        const decision = task_api.testing.policy_module.classifyAgentTerminal(&terminal);
        if (phase == .finalizing) {
            try std.testing.expectEqual(.ok, terminal.abort_status.?);
            try std.testing.expectEqual(.aborted, terminal.stop_reason.?);
            try std.testing.expect(terminal.model_error == null);
            try std.testing.expectEqual(.cancelled, decision.outcome);
        } else {
            try std.testing.expectEqual(.too_late, terminal.abort_status.?);
            try std.testing.expectEqual(.api_error, terminal.stop_reason.?);
            try std.testing.expectEqual(.authentication, terminal.model_error.?.category);
            try std.testing.expectEqual(.failed, decision.outcome);
            try std.testing.expectEqual(.provider_failure, decision.cause.?);
        }
        try std.testing.expectEqual(.reusable, terminal.session_disposition_at_completion);
        try session.close(.session_close);
    }
}

const Vault = struct {
    key: [64]u8 = @splat(0),
    len: usize = 0,
    fn generate(_: *anyopaque, slot: *[f.models_ports.credential_slot_bytes]u8) anyerror!void {
        @memcpy(slot, f.models_ports.credential_slot_prefix ++ ("1" ** 32));
    }
    fn store(context: *anyopaque, _: []const u8, value: []const u8) anyerror!void {
        const self: *Vault = @ptrCast(@alignCast(context));
        if (value.len > self.key.len) return error.CapacityReached;
        @memcpy(self.key[0..value.len], value);
        self.len = value.len;
    }
    fn get(context: *anyopaque, _: []const u8, output: []u8) anyerror!?[]const u8 {
        const self: *Vault = @ptrCast(@alignCast(context));
        if (self.len == 0) return null;
        @memcpy(output[0..self.len], self.key[0..self.len]);
        return output[0..self.len];
    }
    fn delete(context: *anyopaque, _: []const u8) anyerror!void {
        const self: *Vault = @ptrCast(@alignCast(context));
        std.crypto.secureZero(u8, &self.key);
        self.len = 0;
    }
    fn capability(self: *Vault) f.models_ports.CredentialVault {
        return .{ .context = self, .generate_slot_fn = generate, .store_fn = store, .get_fn = get, .delete_fn = delete };
    }
};

fn configureProvider(control: *control_api.Runtime, endpoint: []const u8) !void {
    try std.testing.expect(control.createCustomProviderWithCredential("office-pipeline-synthetic-key", .{
        .display_name = "Office local provider fixture",
        .protocol = .anthropic_messages,
        .normalized_base_url = endpoint,
    }).accepted);
    const created = control.modelsView().custom_providers[0];
    const id = try std.testing.allocator.dupe(u8, created.id);
    defer std.testing.allocator.free(id);
    const model = "claude-sonnet-4-20250514";
    try std.testing.expect(control.submitCustomProviderCommand(.{ .add_custom_model = .{
        .source_id = id,
        .expected_provider_revision = created.provider_revision,
        .expected_catalog_generation = created.catalog_generation,
        .model = .{ .id = model },
    } }).accepted);
    const configured = control.modelsView().custom_providers[0];
    const command: f.models_contract.CustomModelTestCommand = .{
        .model = .{ .source_id = id, .model_id = model },
        .expected_provider_revision = configured.provider_revision,
        .expected_source_generation = configured.source_generation,
        .expected_catalog_generation = configured.catalog_generation,
    };
    var candidate = switch (control.beginCustomProviderProbe(command)) {
        .ready => |value| value,
        .rejected => return error.FixtureProviderRejected,
    };
    candidate.deinit();
    try std.testing.expect(control.completeCustomModelTest(command, true).accepted);
    try std.testing.expect(control.custom_providers.rememberPreference(.{ .source_id = id, .model_id = model }).accepted);
}

// Test-only latency injection around the existing real history writer.
const SlowHistory = struct {
    inner: *f.TypedHistory,
    enabled: std.atomic.Value(bool) = .init(false),
    max_commit_ns: std.atomic.Value(u64) = .init(0),

    fn commit(raw: ?*anyopaque, candidate: *task_api.history.Candidate) task_api.history.Commit {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        const started = std.Io.Timestamp.now(std.testing.io, .awake);
        const slow = self.enabled.load(.acquire);
        if (slow) std.Io.sleep(std.testing.io, .fromMilliseconds(20), .awake) catch return .failed;
        const result = self.inner.capability().commit(candidate);
        if (slow) _ = self.max_commit_ns.fetchMax(@intCast(started.durationTo(std.Io.Timestamp.now(std.testing.io, .awake)).nanoseconds), .monotonic);
        return result;
    }
    fn resolve(raw: ?*anyopaque, token: task_api.history.CommitToken) task_api.history.Commit {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        return self.inner.capability().resolveCommit(token);
    }
    fn capability(self: *@This()) task_api.history.Capability {
        return .{ .context = self, .enabled = true, .commit_fn = commit, .confirmed_commit_fn = commit, .resolve_commit_fn = resolve };
    }
};

fn finish(control: *control_api.Runtime, task_id: u64, id: u64, mode: []const u8) !void {
    const task = control.testTask(task_id).?;
    var answered: ?u64 = null;
    var cancelled = false;
    for (0..15000) |_| {
        try control.drainAgentEvents();
        const run = state.findRun(task.durable.runs, id).?;
        if (std.mem.eql(u8, mode, "cancel") and !cancelled and run.output_segment.list.items.len != 0) {
            try control.cancel(task_id, id);
            cancelled = true;
        }
        if (task.runtime.active_operation == .none and !task.runtime.worker_leases.hasLive()) {
            const terminal = state.productTerminalFacts(run) orelse return error.MissingProductTerminal;
            if (std.mem.eql(u8, mode, "callback-budget")) {
                try std.testing.expect(terminal.phase == .failed);
                try std.testing.expectEqual(task_api.RunOutcome.failed, terminal.outcome);
                try std.testing.expect(terminal.cause == .event_payload_too_large);
                const diagnostic = run.terminal_diagnostic[0..state.terminalPayload(run).?.diagnostic_len];
                try std.testing.expect(std.mem.indexOf(u8, diagnostic, "boundary=event_decode reason=oversized") != null);
                try std.testing.expect(std.mem.indexOf(u8, diagnostic, agent.core_manifest_sha256) != null);
                try std.testing.expect(run.event_stream_finalized);
                return;
            }
            if (std.mem.eql(u8, mode, "consumer-starvation")) {
                try std.testing.expectEqual(task_api.RunOutcome.completed, terminal.outcome);
                try std.testing.expect(run.event_stream_finalized);
                try std.testing.expect(run.first_event_rejection == null);
                try std.testing.expectEqual(@as(usize, 256), std.mem.count(u8, run.assistant.list.items, "Synthetic stream chunk. "));
                try std.testing.expectEqual(state.AssistantOutputKind.final, run.assistant_output_kind.?);
                try std.testing.expectEqual(agent.SessionDisposition.reusable, state.terminalPayload(run).?.session_disposition_at_completion);
                return;
            }
            if (std.mem.eql(u8, mode, "long-run")) {
                try std.testing.expectEqual(task_api.RunOutcome.completed, terminal.outcome);
                try std.testing.expect(run.event_stream_finalized);
                try std.testing.expectEqual(state.EventProjectionFailure.consumer_rejected, run.event_projection_failure.?);
                try std.testing.expect(run.first_event_rejection == null);
                try std.testing.expect(!run.output_segment_open);
                try std.testing.expect(std.mem.endsWith(u8, run.assistant.list.items, "Long run completed."));
                try std.testing.expectEqual(agent.SessionDisposition.reusable, state.terminalPayload(run).?.session_disposition_at_completion);
                return;
            }
            if (std.mem.eql(u8, mode, "slow-stop")) {
                try std.testing.expectEqual(task_api.RunOutcome.cancelled, terminal.outcome);
                try std.testing.expectEqual(state.RunCause.user_cancel, terminal.cause.?);
                try std.testing.expect(run.event_stream_finalized);
                try std.testing.expect(!state.terminalPayload(run).?.event_delivery_lost);
                try std.testing.expectEqual(agent.SessionDisposition.reusable, state.terminalPayload(run).?.session_disposition_at_completion);
                return;
            }
            if (std.mem.eql(u8, mode, "fixture-error")) {
                try std.testing.expectEqual(task_api.RunOutcome.failed, terminal.outcome);
                try std.testing.expect(terminal.cause == .provider_failure);
                try std.testing.expect(run.event_stream_finalized);
                try std.testing.expect(run.first_event_rejection == null);
                return;
            }
            if (run.first_event_rejection != null) {
                std.debug.print("Office pipeline mode={s} first={any} terminal={any}\n", .{ mode, run.first_event_rejection, terminal });
            }
            const expected_outcome: task_api.RunOutcome = if (std.mem.eql(u8, mode, "cancel")) .cancelled else if (std.mem.eql(u8, mode, "stream-interruption")) .failed else .completed;
            try std.testing.expectEqual(expected_outcome, terminal.outcome);
            try std.testing.expect(run.event_stream_finalized);
            try std.testing.expect(run.first_event_rejection == null);
            try std.testing.expect(!run.output_segment_open);
            if (std.mem.eql(u8, mode, "stream-interruption")) {
                try std.testing.expect(run.assistant_output_kind != .final);
                try std.testing.expect(terminal.cause != .dependency_contract_failure);
                try std.testing.expect(terminal.cause != .event_pipeline_failure);
            } else if (!std.mem.eql(u8, mode, "cancel")) {
                try std.testing.expect(answered != null);
                try std.testing.expect(run.commentary_count > 0);
                try std.testing.expect(run.assistant_output_kind == .final);
                const tool_failed = std.mem.eql(u8, mode, "nonzero") or std.mem.eql(u8, mode, "missing-environment") or
                    std.mem.eql(u8, mode, "stale-entry") or std.mem.eql(u8, mode, "unreachable-preparation") or std.mem.eql(u8, mode, "deny");
                try std.testing.expectEqualStrings(if (tool_failed)
                    "Checking the requested operation. The controlled tool failed as expected."
                else
                    "Checking the requested operation. The controlled tool completed.", run.assistant.list.items);
            } else try std.testing.expect(cancelled);
            return;
        }
        var access = try task.runtime.acquireAccess();
        defer access.deinit();
        if (access.pendingUiObservation()) |request| if (answered != request.request_id) {
            try control.respondUi(task_id, id, request.request_id, .{ .permission = if (std.mem.eql(u8, mode, "deny")) .deny_once else .allow_once });
            answered = request.request_id;
        };
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    return error.OfficePipelineTimeout;
}

fn qualify(mode: []const u8) !void {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var provider = try Provider.start(root, mode);
    defer provider.deinit();
    var agent_limits: agent.Limits = .{ .max_sessions = 1 };
    if (std.mem.eql(u8, mode, "callback-budget")) agent_limits.max_event_bytes = 32;
    const runtime = try agent.Runtime.init(std.testing.io, std.testing.allocator, agent_limits);
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    var vault: Vault = .{};
    defer std.crypto.secureZero(u8, &vault.key);
    var history = try task_api.history.FileStore.init(std.testing.io, root);
    defer history.deinit();
    var typed_history: f.TypedHistory = .{ .file_store = &history };
    defer typed_history.deinit();
    var slow_history: SlowHistory = .{ .inner = &typed_history };
    var checkpoints = try task_api.checkpoint_store.FileStore.init(std.testing.io, root);
    defer checkpoints.deinit();
    var configuration = f.productControlConfiguration();
    configuration.directories.canonical_user_home = root;
    configuration.task_persistence = if (std.mem.eql(u8, mode, "slow-stop")) slow_history.capability() else typed_history.capability();
    configuration.checkpoint_store = .{ .file_store = &checkpoints };
    var control = try control_api.Runtime.init(std.testing.allocator, std.testing.io, runtime, .{
        .worker_count = 1,
        .queue_capacity = 2,
        .max_tasks = 1,
        .max_workspaces = 1,
        .max_runs_per_task = 3,
        .max_tools_per_run = if (std.mem.eql(u8, mode, "long-run")) 32 else 4,
    }, configuration);
    defer control.deinit();
    try control.startCustomProviders(root, vault.capability());
    defer control.stopCustomProviders();
    try configureProvider(&control, provider.endpoint);
    const task_id = try control.createTask(.{ .workspace_root = root, .trust = .explicitly_trusted, .approval_mode = if (std.mem.eql(u8, mode, "slow-stop")) .full_access else .manual }, try control_api.TestSupport.fixtureModelSelection(&control));
    const repetitions: usize = if (std.mem.eql(u8, mode, "multi-run")) 2 else 1;
    for (0..repetitions) |_| {
        const id = try f.runPreparedTask(&control, task_id, .{ .text = "Run the synthetic Office pipeline operation." });
        if (std.mem.eql(u8, mode, "consumer-starvation")) {
            // Deliberately withhold the sole Product consumer while actual Core
            // receives a bounded legal stream. Keep all production queue limits
            // unchanged. This models an occupied Native loop, not an actual
            // OS dialog. Resume after the former fatal deadline has passed.
            var ready = false;
            for (0..5000) |_| {
                if (temporary.dir.statFile(std.testing.io, "starvation-ready", .{})) |_| {
                    ready = true;
                    break;
                } else |err| if (err != error.FileNotFound) return err;
                try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
            }
            try std.testing.expect(ready);
            try std.Io.sleep(std.testing.io, .fromMilliseconds(300), .awake);
            const task = control.testTask(task_id).?;
            try std.testing.expect(runtime.pendingEventCount(task.runtime.routeId()) != 0);
            try std.testing.expect(state.terminalPayload(state.findRun(task.durable.runs, id).?) == null);
        }
        var stop_started: ?std.Io.Timestamp = null;
        if (std.mem.eql(u8, mode, "slow-stop")) {
            const task = control.testTask(task_id).?;
            for (0..10000) |_| {
                if (runtime.pendingEventCount(task.runtime.routeId()) >= 100) break;
                try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
            }
            try std.testing.expect(runtime.pendingEventCount(task.runtime.routeId()) >= 100);
            slow_history.enabled.store(true, .release);
            const started = std.Io.Timestamp.now(std.testing.io, .awake);
            try control.drainAgentEvents();
            const elapsed = started.durationTo(std.Io.Timestamp.now(std.testing.io, .awake)).nanoseconds;
            try std.testing.expect(elapsed < std.time.ns_per_s);
            try std.testing.expect(runtime.pendingEventCount(task.runtime.routeId()) != 0);
            stop_started = std.Io.Timestamp.now(std.testing.io, .awake);
            try control.cancel(task_id, id);
            std.debug.print("slow-stop drain_ns={d} max_commit_ns={d} pending_after_stop={d}\n", .{ elapsed, slow_history.max_commit_ns.load(.monotonic), runtime.pendingEventCount(task.runtime.routeId()) });
        }
        finish(&control, task_id, id, mode) catch |err| {
            const trace = temporary.dir.readFileAlloc(std.testing.io, "trace.jsonl", std.testing.allocator, .limited(2 * 1024 * 1024)) catch return err;
            defer std.testing.allocator.free(trace);
            var lines = std.mem.splitScalar(u8, trace, '\n');
            while (lines.next()) |line| {
                if (std.mem.startsWith(u8, line, "{\"kind\":\"fixture_error\""))
                    std.debug.print("Office fixture mode={s}: {s}\n", .{ mode, line });
            }
            return err;
        };
        if (stop_started) |started| {
            const elapsed = started.durationTo(std.Io.Timestamp.now(std.testing.io, .awake)).nanoseconds;
            std.debug.print("slow-stop terminal_ns={d}\n", .{elapsed});
            try std.testing.expect(elapsed < 10 * std.time.ns_per_s);
        }
    }
    if (std.mem.eql(u8, mode, "callback-budget")) {
        // The first actual Core event exceeds the deliberately tiny fixture
        // limit, before any Provider request. History must retain its identity.
        try std.testing.expectError(error.FileNotFound, temporary.dir.statFile(std.testing.io, "trace.jsonl", .{}));
        const saved = (try history.loadAlloc(std.testing.allocator)).?;
        defer std.testing.allocator.free(saved);
        try std.testing.expect(std.mem.indexOf(u8, saved, "boundary=event_decode reason=oversized") != null);
        try std.testing.expect(std.mem.indexOf(u8, saved, agent.core_manifest_sha256) != null);
    } else {
        const trace = try temporary.dir.readFileAlloc(std.testing.io, "trace.jsonl", std.testing.allocator, .limited(2 * 1024 * 1024));
        defer std.testing.allocator.free(trace);
        if (std.mem.eql(u8, mode, "fixture-error")) {
            try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, trace, "\"kind\":\"request\""));
            try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, trace, "\"kind\":\"fixture_error\""));
            try std.testing.expect(std.mem.indexOf(u8, trace, "Controlled fixture assertion") != null);
        } else try std.testing.expect(std.mem.indexOf(u8, trace, "fixture_error") == null);
        if (std.mem.eql(u8, mode, "missing-environment")) {
            const message = if (builtin.os.tag == .windows) "Office environment missing." else "Office environment missing or unavailable";
            try std.testing.expect(std.mem.indexOf(u8, trace, message) != null);
        }
        if (std.mem.eql(u8, mode, "unreachable-preparation")) try std.testing.expect(std.mem.indexOf(u8, trace, "preparation-cleanup") != null);
        if (std.mem.eql(u8, mode, "long-run")) {
            try std.testing.expectEqual(@as(usize, 41), std.mem.count(u8, trace, "\"kind\":\"request\""));
            const saved = (try history.loadAlloc(std.testing.allocator)).?;
            defer std.testing.allocator.free(saved);
            try std.testing.expect(std.mem.indexOf(u8, saved, "Long run completed.") != null);
            try std.testing.expect(std.mem.indexOf(u8, saved, "consumer_rejected") != null);
        }
        if (std.mem.eql(u8, mode, "consumer-starvation")) {
            const saved = (try history.loadAlloc(std.testing.allocator)).?;
            defer std.testing.allocator.free(saved);
            try std.testing.expect(std.mem.indexOf(u8, saved, "Synthetic stream chunk.") != null);
            try std.testing.expect(std.mem.indexOf(u8, saved, "queue_capacity_failure") == null);
            try std.testing.expect(std.mem.indexOf(u8, saved, "event_pipeline_failure") == null);
        }
    }
    if (std.mem.eql(u8, mode, "deny")) try std.testing.expectError(error.FileNotFound, temporary.dir.statFile(std.testing.io, "denied.txt", .{}));
    var snapshot: [256 * 1024]u8 = undefined;
    const encoded = try control.writeAggregateFixture(&snapshot);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "office-pipeline-synthetic-key") == null);
}

test "Office canonical Product pipeline tools, legitimate failures, denial and multi-run" {
    for ([_][]const u8{ "success", "nonzero", "missing-environment", "deny", "multi-run" }) |mode| try qualify(mode);
}

test "Office macOS original preparation errors remain ordinary tool results" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    try qualify("stale-entry");
    try qualify("unreachable-preparation");
}

test "Office canonical Product pipeline retries and closes streaming cancellation" {
    for ([_][]const u8{ "retry", "stream-interruption", "cancel" }) |mode| try qualify(mode);
}

test "Office fixture assertions fail without Provider retries" {
    try qualify("fixture-error");
}

test "Office canonical Product executor retains real callback rejection identity in terminal history" {
    try qualify("callback-budget");
}

test "Office canonical stream survives consumer backpressure and retains the full response" {
    try qualify("consumer-starvation");
}

// Same canonical runtime, Product executor and local Provider infrastructure;
// the asset is the issue's relative-only definition, imported through Product.
test "Skill resource context reads a managed import through tool and typed inputs" {
    for ([_][]const u8{ "skill-resource-tool", "skill-resource-typed" }) |mode| {
        var temporary = std.testing.tmpDir(.{ .iterate = true });
        defer temporary.cleanup();
        const root = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(root);
        for ([_][]const u8{ "source", "stage", "work" }) |dir| try temporary.dir.createDir(std.testing.io, dir, .default_dir);
        const source = try std.fs.path.join(std.testing.allocator, &.{ root, "source" });
        defer std.testing.allocator.free(source);
        const stage = try std.fs.path.join(std.testing.allocator, &.{ root, "stage" });
        defer std.testing.allocator.free(stage);
        const work = try std.fs.path.join(std.testing.allocator, &.{ root, "work" });
        defer std.testing.allocator.free(work);
        try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "source/SKILL.md", .data = "---\nname: qa-resource-context\ndescription: QA-only marker\n---\n" ++
            "When explicitly invoked, read the bundled qa-reference.txt, then reply exactly QA_SKILL_OK_7429 followed by its reference marker. Do not modify files or access links.\n" });
        try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "source/qa-reference.txt", .data = "QA028_DIRECTORY_REFERENCE_7429" });
        var provider = try Provider.start(root, mode);
        defer provider.deinit();
        const runtime = try agent.Runtime.init(std.testing.io, std.testing.allocator, .{ .max_sessions = 1 });
        defer {
            runtime.shutdown() catch unreachable;
            runtime.deinit();
        }
        var vault: Vault = .{};
        defer std.crypto.secureZero(u8, &vault.key);
        var store: f.product_skill.management.FileStore = .{ .io = std.testing.io, .dir = temporary.dir };
        var enablement: f.product_skill.enablement.FileStore = .{ .io = std.testing.io, .dir = temporary.dir };
        var configuration = f.productControlConfiguration();
        configuration.directories.canonical_user_home = root;
        configuration.run_clock.now_unix_ms_fn = struct {
            fn now(_: ?*anyopaque) ?u64 {
                return 1_800_000_000_000;
            }
        }.now;
        configuration.skill_management = .{ .file_store = &store, .staging_root = stage };
        configuration.skill_enablement = .{ .file_store = &enablement };
        configuration.skill_sources = .{ .restored = .{ .loaded = .{ .ready = .{} } } };
        var control = try control_api.Runtime.init(std.testing.allocator, std.testing.io, runtime, .{
            .worker_count = 1,
            .queue_capacity = 4,
            .max_tasks = 1,
            .max_workspaces = 1,
            .max_runs_per_task = 2,
        }, configuration);
        defer control.deinit();
        try control.startCustomProviders(root, vault.capability());
        defer control.stopCustomProviders();
        try configureProvider(&control, provider.endpoint);
        const preparation = try control.prepareSkillImport(source, .local_directory, .{ .scope = .personal });
        try control.preflightSkillImport(preparation.id, preparation.revision, preparation.effect);
        _ = try control.commitSkillImport(preparation.id, preparation.revision, preparation.effect);
        for (0..5000) |_| {
            try control.drainAgentEvents();
            const available = control.skillCatalog();
            if (available.availability == .ready or available.availability == .degraded) break;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        } else return error.SkillCatalogTimeout;
        const task_id = try control.createTask(.{ .workspace_root = work, .trust = .explicitly_trusted, .approval_mode = .full_access }, try control_api.TestSupport.fixtureModelSelection(&control));
        const task = control.testTask(task_id).?;
        const workspace_id = task.durable.workspace_id;
        for (0..5000) |_| {
            try control.drainAgentEvents();
            const available = try control.workspaceCatalog(workspace_id);
            if (available.availability == .ready or available.availability == .degraded) break;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        } else return error.SkillCatalogTimeout;
        const catalog = try control.workspaceCatalog(workspace_id);
        try std.testing.expectEqual(@as(usize, 1), catalog.skills.len);
        const input: control_api.TaskRunInput = if (std.mem.eql(u8, mode, "skill-resource-typed")) .{ .skill = .{
            .skill_id = catalog.skills[0].skill_id,
            .catalog_revision = catalog.revision,
            .selection_revision = catalog.selection_revision.?,
            .argument_values = &.{},
        } } else .{ .text = "Invoke qa-resource-context, read the bundled qa-reference.txt and return its marker. Do not search outside the Skill." };
        const id = try f.runPreparedTask(&control, task_id, input);
        for (0..10000) |_| {
            try control.drainAgentEvents();
            if (task.runtime.active_operation == .none and !task.runtime.worker_leases.hasLive()) break;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        } else return error.SkillResourceTimeout;
        const run = state.findRun(task.durable.runs, id).?;
        const terminal = state.productTerminalFacts(run).?;
        try std.testing.expectEqual(task_api.RunOutcome.completed, terminal.outcome);
        try std.testing.expect(std.mem.indexOf(u8, run.assistant.list.items, "QA_SKILL_OK_7429 QA028_DIRECTORY_REFERENCE_7429") != null);
        try std.testing.expect(run.event_stream_finalized);
        const trace = try temporary.dir.readFileAlloc(std.testing.io, "trace.jsonl", std.testing.allocator, .limited(256 * 1024));
        defer std.testing.allocator.free(trace);
        try std.testing.expect(std.mem.indexOf(u8, trace, "fixture_error") == null);
        try std.testing.expect(std.mem.indexOf(u8, trace, "skill-resource-read") != null);
    }
}

test "canonical single Run passes 16 turns and 32 Tool records without replay" {
    try qualify("long-run");
}

test "canonical saturated stream and slow history return to the main loop for Stop" {
    try qualify("slow-stop");
}
