//! Canonical binary, production callback/pump and Product projection/drain.
//! Only the remote provider and credential vault are synthetic local effects.
const f = @import("lifecycle_fixture");
const std = f.std;
const agent = f.lifecycle;
const control_api = f.product_control;
const task_api = f.product_task;
const state = task_api.testing.state_module;
const options = @import("office_pipeline_options");

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
    const view = control.modelsView();
    const ready = view.custom_providers[0];
    try std.testing.expect(control.selectModelsDefault(.{
        .selection = .{ .source_id = id, .model_id = model },
        .expected_selection_revision = view.selection_revision,
        .expected_source_generation = ready.source_generation,
        .expected_catalog_generation = ready.catalog_generation,
    }).accepted);
}

fn finish(control: *control_api.Runtime, task_id: u64, id: u64, mode: []const u8) !void {
    const task = control.task_runtime.find(task_id).?;
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
            if (run.first_event_rejection != null or run.terminal_drain_rejection != null) {
                std.debug.print("Office pipeline mode={s} first={any} drain={any} terminal={any}\n", .{ mode, run.first_event_rejection, run.terminal_drain_rejection, terminal });
            }
            const expected_outcome: task_api.RunOutcome = if (std.mem.eql(u8, mode, "cancel")) .cancelled else if (std.mem.eql(u8, mode, "stream-interruption")) .failed else .completed;
            try std.testing.expectEqual(expected_outcome, terminal.outcome);
            try std.testing.expect(run.event_stream_finalized);
            try std.testing.expect(run.output_segment_protocol_seen);
            try std.testing.expect(run.first_event_rejection == null);
            try std.testing.expect(run.terminal_drain_rejection == null);
            try std.testing.expect(run.open_output_segment == null);
            if (std.mem.eql(u8, mode, "stream-interruption")) {
                try std.testing.expect(run.assistant_output_kind != .final);
                try std.testing.expect(terminal.cause != .dependency_contract_failure);
                try std.testing.expect(terminal.cause != .event_pipeline_failure);
            } else if (!std.mem.eql(u8, mode, "cancel")) {
                try std.testing.expect(answered != null);
                try std.testing.expect(run.commentary_count > 0);
                try std.testing.expect(run.assistant_output_kind == .final);
                try std.testing.expect(run.next_output_segment_index >= 2);
                const tool_failed = std.mem.eql(u8, mode, "nonzero") or std.mem.eql(u8, mode, "missing-environment") or std.mem.eql(u8, mode, "deny");
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
    var checkpoints = try task_api.checkpoint_store.FileStore.init(std.testing.io, root);
    defer checkpoints.deinit();
    var configuration = f.productControlConfiguration();
    configuration.directories.canonical_user_home = root;
    configuration.task_persistence = typed_history.capability();
    configuration.checkpoint_store = .{ .file_store = &checkpoints };
    var control = try control_api.Runtime.init(std.testing.allocator, std.testing.io, runtime, .{
        .worker_count = 1,
        .queue_capacity = 2,
        .max_tasks = 1,
        .max_workspaces = 1,
        .max_runs_per_task = 3,
        .max_tools_per_run = 4,
    }, configuration);
    defer control.deinit();
    try control.startCustomProviders(root, vault.capability());
    defer control.stopCustomProviders();
    try configureProvider(&control, provider.endpoint);
    const task_id = try control.createTask(.{ .workspace_root = root, .trust = .explicitly_trusted, .approval_mode = .manual });
    const repetitions: usize = if (std.mem.eql(u8, mode, "multi-run")) 2 else 1;
    for (0..repetitions) |_| {
        const id = try f.runPreparedTask(&control, task_id, .{ .text = "Run the synthetic Office pipeline operation." });
        try finish(&control, task_id, id, mode);
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
        try std.testing.expect(std.mem.indexOf(u8, trace, "fixture_error") == null);
        if (std.mem.eql(u8, mode, "missing-environment")) try std.testing.expect(std.mem.indexOf(u8, trace, "Office environment missing or unavailable") != null);
    }
    if (std.mem.eql(u8, mode, "deny")) try std.testing.expectError(error.FileNotFound, temporary.dir.statFile(std.testing.io, "denied.txt", .{}));
    var snapshot: [256 * 1024]u8 = undefined;
    const encoded = try control.writeAggregateFixture(&snapshot);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "office-pipeline-synthetic-key") == null);
}

test "Office canonical Product pipeline tools, legitimate failures, denial and multi-run" {
    for ([_][]const u8{ "success", "nonzero", "missing-environment", "deny", "multi-run" }) |mode| try qualify(mode);
}

test "Office canonical Product pipeline retries and closes streaming cancellation" {
    for ([_][]const u8{ "retry", "stream-interruption", "cancel" }) |mode| try qualify(mode);
}

test "Office canonical Product executor retains real callback rejection identity in terminal history" {
    try qualify("callback-budget");
}
