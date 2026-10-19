const std = @import("std");
const agent = @import("metawork_agent");
const backend = @import("image_http_backend");
const options = @import("image_fixture_options");
const sdk = @import("lifecycle_fixture").sdk;
const workspace_output = @import("image_output");

// Pass-through instrumentation over the exact staged binary. No result, issue,
// checkpoint or status is fabricated; only the schema-change case changes the
// one fixed GenerateImage descriptor while creating its isolated Runtime.
const CoreProbe = struct {
    var active: *CoreProbe = undefined;
    api: sdk.types.ApiV1,
    runtime_api: sdk.types.RuntimeApiV1,
    control_api: sdk.types.SessionControlApiV1,
    original: sdk.Api,
    changed_schema: bool = false,
    report: [8192]u8 = undefined,
    report_len: usize = 0,
    description: [8192]u8 = undefined,
    description_len: usize = 0,

    fn init(self: *CoreProbe, changed: bool) !void {
        const original = try sdk.Api.discover();
        self.* = .{ .api = original.raw.*, .runtime_api = original.raw.runtime.?.*, .control_api = original.raw.session_control.?.*, .original = original, .changed_schema = changed };
        self.runtime_api.create = create;
        self.control_api.restore = restore;
        self.control_api.describe = describe;
        self.api.runtime = &self.runtime_api;
        self.api.session_control = &self.control_api;
        active = self;
    }
    fn create(config: ?*const sdk.types.RuntimeConfigV1, plugins: ?*const sdk.types.RuntimePluginConfigV1, output: ?*?*sdk.types.RuntimeHandle, diagnostic: ?*sdk.types.OwnedBytesV1) callconv(.c) u32 {
        var copy = config.?.*;
        if (active.changed_schema) {
            std.debug.assert(copy.host_tool_count == 1);
            var tool = copy.host_tools.?[0];
            tool.input_schema_json = sdk.bytesView("{\"type\":\"object\",\"properties\":{\"prompt\":{\"type\":\"string\",\"maxLength\":1000}},\"required\":[\"prompt\"],\"additionalProperties\":false}");
            copy.host_tools = @ptrCast(&tool);
            return active.original.runtime().create()(&copy, plugins, output, diagnostic);
        }
        return active.original.runtime().create()(config, plugins, output, diagnostic);
    }
    fn restore(runtime: ?*sdk.types.RuntimeHandle, config: ?*const sdk.types.SessionRestoreConfigV1, callbacks: ?*const sdk.types.SessionCallbacksV1, output: ?*?*sdk.types.SessionHandle, report: ?*sdk.types.OwnedBytesV1, diagnostic: ?*sdk.types.OwnedBytesV1) callconv(.c) u32 {
        const status = active.original.sessionControl().restore()(runtime, config, callbacks, output, report, diagnostic);
        if (report) |value| if (value.ptr) |ptr| {
            active.report_len = @min(value.len, active.report.len);
            @memcpy(active.report[0..active.report_len], ptr[0..active.report_len]);
        };
        return status;
    }
    fn describe(session: ?*sdk.types.SessionHandle, output: ?*sdk.types.OwnedBytesV1, diagnostic: ?*sdk.types.OwnedBytesV1) callconv(.c) u32 {
        const status = active.original.sessionControl().describe()(session, output, diagnostic);
        if (output) |value| if (value.ptr) |ptr| {
            active.description_len = @min(value.len, active.description.len);
            @memcpy(active.description[0..active.description_len], ptr[0..active.description_len]);
        };
        return status;
    }
};

const Fixture = struct {
    child: std.process.Child,
    endpoint: []u8,
    provider_endpoint: []u8,

    fn start(trace: []const u8, mode: []const u8) !Fixture {
        var child = try std.process.spawn(std.testing.io, .{
            .argv = &.{ options.node_path, options.fixture_path, trace, mode },
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .inherit,
            .create_no_window = true,
        });
        errdefer child.kill(std.testing.io);
        var storage: [1024]u8 = undefined;
        var reader = child.stdout.?.readerStreaming(std.testing.io, &storage);
        const line = try reader.interface.takeDelimiterExclusive('\n');
        if (try reader.interface.takeByte() != '\n') return error.InvalidHandshake;
        const ready = try std.json.parseFromSlice(struct { endpoint: []const u8, providerEndpoint: []const u8 }, std.testing.allocator, line, .{});
        defer ready.deinit();
        const endpoint = try std.testing.allocator.dupe(u8, ready.value.endpoint);
        errdefer std.testing.allocator.free(endpoint);
        return .{ .child = child, .endpoint = endpoint, .provider_endpoint = try std.testing.allocator.dupe(u8, ready.value.providerEndpoint) };
    }

    fn deinit(self: *Fixture) void {
        self.child.kill(std.testing.io);
        std.testing.allocator.free(self.endpoint);
        std.testing.allocator.free(self.provider_endpoint);
    }
};

const Sink = struct {
    dir: std.Io.Dir,
    mutex: std.Io.Mutex = .init,
    attempts: usize = 0,
    saved: usize = 0,
    force_conflict: bool = false,
    fail_write: bool = false,
    cancel_before_commit: bool = false,
    cancel_after_commit: bool = false,
    long_name: bool = false,

    fn output(self: *Sink) agent.ImageGenerationOutput {
        return .{ .context = self, .commit_fn = commitResult };
    }
    fn commitResult(context: *anyopaque, bytes: []const u8, cancellation: *const agent.CompletionCancellation) agent.ImageGenerationOutputResult {
        return .{ .saved = commit(context, bytes, cancellation) catch |err|
            return .{ .failed = .{ .code = if (err == error.Cancelled) .cancelled else .write_failed } } };
    }
    fn commit(context: *anyopaque, bytes: []const u8, cancellation: *const agent.CompletionCancellation) !agent.ImageGenerationReceipt {
        const self: *Sink = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(std.testing.io);
        defer self.mutex.unlock(std.testing.io);
        self.attempts += 1;
        var name_storage: [200]u8 = @splat('a');
        const name = if (self.long_name) &name_storage else try std.fmt.bufPrint(&name_storage, "image-{d}.png", .{if (self.force_conflict) @as(usize, 1) else self.attempts});
        const receipt = try agent.ImageGenerationReceipt.init(name, bytes.len);
        const file = try self.dir.createFile(std.testing.io, name, .{ .exclusive = true });
        var closed = false;
        defer if (!closed) file.close(std.testing.io);
        errdefer {
            if (!closed) {
                file.close(std.testing.io);
                closed = true;
            }
            self.dir.deleteFile(std.testing.io, name) catch @panic("uncommitted image cleanup failed");
        }
        if (self.fail_write) {
            try file.writeStreamingAll(std.testing.io, bytes[0..1]);
            return error.InjectedWriteFailure;
        }
        try file.writeStreamingAll(std.testing.io, bytes);
        if (self.cancel_before_commit) @constCast(cancellation).request();
        if (cancellation.isRequested()) return error.Cancelled;
        file.close(std.testing.io);
        closed = true;
        self.saved += 1;
        if (self.cancel_after_commit) @constCast(cancellation).request();
        return receipt;
    }
};

fn open(runtime: *agent.Runtime, root: []const u8, fixture: *Fixture, mode: agent.PermissionMode) !*agent.Session {
    return runtime.createSession(openOptions(root, fixture, mode));
}

fn openOptions(root: []const u8, fixture: *Fixture, mode: agent.PermissionMode) agent.SessionOpenOptions {
    return .{
        .model_binding = .{ .target = .{ .provider_id = "fixture", .protocol = .anthropic_messages, .base_url = fixture.provider_endpoint, .model = "claude-sonnet-4-20250514" }, .credential = "synthetic-dialogue-key" },
        .permission_mode = mode,
        .shell_policy = .unrestricted,
        .workspace = .{ .canonical_root = root, .trust = .explicitly_trusted },
        .canonical_user_home = root,
    };
}

fn execute(session: *agent.Session) !void {
    const id = try session.prepareRun(.{ .text = "Generate the fixture image." });
    var run = try session.beginRun(id);
    defer run.deinit();
    var terminal = run.execute();
    defer terminal.deinit();
    try std.testing.expectEqual(@as(?agent.TerminalFailure, null), terminal.failure);
    try std.testing.expectEqual(@as(?agent.StopReason, .end_turn), terminal.stop_reason);
}

fn executeWorker(session: *agent.Session) !void {
    var work: Work = .{ .session = session, .id = try session.prepareRun(.{ .text = "Generate the fixture image." }) };
    const thread = try std.Thread.spawn(.{}, Work.run, .{&work});
    thread.join();
    defer work.result.?.deinit();
    try std.testing.expectEqual(@as(?agent.TerminalFailure, null), work.result.?.failure);
    try std.testing.expectEqual(@as(?agent.StopReason, .end_turn), work.result.?.stop_reason);
}

fn count(trace: []const u8, needle: []const u8) usize {
    return std.mem.count(u8, trace, needle);
}

fn successful(mode: []const u8, expected: usize) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const trace_path = try std.fs.path.join(std.testing.allocator, &.{ root, "trace.jsonl" });
    defer std.testing.allocator.free(trace_path);
    var fixture = try Fixture.start(trace_path, mode);
    defer fixture.deinit();
    var network: backend.Backend = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    const runtime = try agent.Runtime.initImageGenerationForTesting(std.testing.io, std.testing.allocator, .{ .max_sessions = 2 }, .{ .transport = network.transport() });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    var sink: Sink = .{ .dir = tmp.dir };
    const session = try open(runtime, root, &fixture, .full_access);
    try session.configureImageGenerationForTesting(.{ .endpoint = fixture.endpoint, .model = "fixture-image", .credential = "synthetic-image-key", .output = sink.output() });
    try execute(session);
    try std.testing.expectEqual(expected, sink.saved);
    const png = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, options.png_path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(png);
    for (0..expected) |i| {
        var name: [64]u8 = undefined;
        const bytes = try tmp.dir.readFileAlloc(std.testing.io, try std.fmt.bufPrint(&name, "image-{d}.png", .{i + 1}), std.testing.allocator, .limited(1024));
        defer std.testing.allocator.free(bytes);
        try std.testing.expectEqualSlices(u8, png, bytes);
    }
    const trace = try tmp.dir.readFileAlloc(std.testing.io, "trace.jsonl", std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(trace);
    try std.testing.expectEqual(expected, count(trace, "\"kind\":\"image\""));
    try std.testing.expectEqual(@as(usize, 0), count(trace, "fixture_error"));
    try std.testing.expectEqual(expected, count(trace, "\\\"status\\\":\\\"saved\\\""));
    try std.testing.expectEqual(expected, count(trace, "\"credentialMatched\":true"));
    for (0..expected) |i| {
        var path: [96]u8 = undefined;
        try std.testing.expect(std.mem.indexOf(u8, trace, try std.fmt.bufPrint(&path, "\\\"path\\\":\\\"image-{d}.png\\\"", .{i + 1})) != null);
    }
    try std.testing.expectEqual(expected, runtime.image_results_created.load(.acquire));
    try std.testing.expectEqual(expected, runtime.image_results_released.load(.acquire));
    if (std.mem.eql(u8, mode, "concurrent")) try std.testing.expect(std.mem.indexOf(u8, trace, "\"active\":2") != null);
}

test "GenerateImage canonical Core writes PNG and model consumes exact receipt" {
    try successful("success", 1);
}

const Harness = struct {
    tmp: std.testing.TmpDir,
    root: [:0]u8,
    fixture: Fixture,
    network: backend.Backend,
    runtime: *agent.Runtime,
    sink: Sink,

    fn init(self: *Harness, mode: []const u8, limits: agent.ImageGenerationLimits) !void {
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.root = try self.tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        errdefer std.testing.allocator.free(self.root);
        const trace_path = try std.fs.path.join(std.testing.allocator, &.{ self.root, "trace.jsonl" });
        defer std.testing.allocator.free(trace_path);
        self.fixture = try Fixture.start(trace_path, mode);
        errdefer self.fixture.deinit();
        self.network = .{ .allocator = std.testing.allocator, .io = std.testing.io };
        self.runtime = try agent.Runtime.initImageGenerationForTesting(std.testing.io, std.testing.allocator, .{ .max_sessions = 2 }, .{ .transport = self.network.transport(), .limits = limits });
        self.sink = .{ .dir = self.tmp.dir };
    }
    fn deinit(self: *Harness) void {
        self.runtime.shutdown() catch unreachable;
        self.runtime.deinit();
        self.fixture.deinit();
        std.testing.allocator.free(self.root);
        self.tmp.cleanup();
    }
    fn session(self: *Harness, permission: agent.PermissionMode, binding: bool) !*agent.Session {
        const value = try open(self.runtime, self.root, &self.fixture, permission);
        if (binding) try value.configureImageGenerationForTesting(.{ .endpoint = self.fixture.endpoint, .model = "fixture-image", .credential = "synthetic-image-key", .output = self.sink.output() });
        return value;
    }
    fn trace(self: *Harness) ![]u8 {
        return self.tmp.dir.readFileAlloc(std.testing.io, "trace.jsonl", std.testing.allocator, .limited(1024 * 1024));
    }
    fn evidence(self: *Harness, requests: usize, saved: usize, status: []const u8) !void {
        const bytes = try self.trace();
        defer std.testing.allocator.free(bytes);
        try std.testing.expectEqual(requests, count(bytes, "\"kind\":\"image\""));
        try std.testing.expectEqual(@as(usize, 0), count(bytes, "fixture_error"));
        try std.testing.expectEqual(saved, self.sink.saved);
        if (status.len != 0) try std.testing.expect(std.mem.indexOf(u8, bytes, status) != null);
        try std.testing.expectEqual(self.runtime.image_results_created.load(.acquire), self.runtime.image_results_released.load(.acquire));
        try std.testing.expectEqual(@as(usize, 0), self.runtime.image_budget.used.load(.acquire));
        const png = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, options.png_path, std.testing.allocator, .limited(1024));
        defer std.testing.allocator.free(png);
        for (0..saved) |i| {
            var name: [64]u8 = undefined;
            const file_bytes = try self.tmp.dir.readFileAlloc(std.testing.io, try std.fmt.bufPrint(&name, "image-{d}.png", .{i + 1}), std.testing.allocator, .limited(1024));
            defer std.testing.allocator.free(file_bytes);
            try std.testing.expectEqualSlices(u8, png, file_bytes);
        }
    }
};

const Work = struct {
    session: *agent.Session,
    id: u64,
    done: std.atomic.Value(bool) = .init(false),
    result: ?agent.TerminalResult = null,
    fn run(self: *Work) void {
        defer self.done.store(true, .release);
        var value = self.session.beginRun(self.id) catch @panic("beginRun failed");
        self.result = value.execute();
        value.deinit();
    }
};

fn permissionRun(h: *Harness, session: *agent.Session, choice: agent.PermissionChoice) !usize {
    return permissionRunText(h.runtime, session, "Generate the fixture image.", choice, true);
}

fn permissionRunText(runtime: *agent.Runtime, session: *agent.Session, text: []const u8, choice: agent.PermissionChoice, host: bool) !usize {
    var work: Work = .{ .session = session, .id = try session.prepareRun(.{ .text = text }) };
    const thread = try std.Thread.spawn(.{}, Work.run, .{&work});
    defer {
        if (!work.done.load(.acquire)) {
            _ = session.requestTermination(work.id, .{ .interrupted = .user_cancel }) catch {};
        }
        thread.join();
        if (work.result) |*result| result.deinit();
    }
    var previous: ?u64 = null;
    var answers: usize = 0;
    for (0..20_000) |_| {
        while (runtime.takeEvent()) |event_value| {
            var event = event_value;
            event.deinit();
        }
        if (work.done.load(.acquire)) break;
        if (session.pendingUiRequest()) |request| if (previous == null or previous.? != request) {
            // Host tools have no stable session grant candidate.
            if (host) try std.testing.expectError(error.InvalidUiResponse, session.respondPermission(work.id, request, .allow_session));
            try session.respondPermission(work.id, request, choice);
            previous = request;
            answers += 1;
        };
        std.testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expect(work.done.load(.acquire));
    try std.testing.expectEqual(@as(?agent.TerminalFailure, null), work.result.?.failure);
    return answers;
}

const RestoreBytes = struct {
    bytes: std.ArrayList(u8) = .empty,
    offset: usize = 0,

    fn write(context: ?*anyopaque, value: []const u8) agent.CheckpointSinkWriteResult {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.bytes.appendSlice(std.testing.allocator, value) catch return .io_failed;
        return .ok;
    }
    fn read(context: ?*anyopaque, output: []u8) agent.CheckpointSourceReadResult {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        const n = @min(output.len, self.bytes.items.len - self.offset);
        if (n == 0) return .eof;
        @memcpy(output[0..n], self.bytes.items[self.offset..][0..n]);
        self.offset += n;
        return .{ .bytes = n };
    }
};

fn checkpointTools(old_image: bool, grant: bool, changed_schema: bool) !void {
    var h: Harness = undefined;
    try h.init("restore", .{});
    defer h.deinit();
    if (!old_image) {
        try h.runtime.shutdown();
        h.runtime.deinit();
        h.runtime = try agent.Runtime.init(std.testing.io, std.testing.allocator, .{ .max_sessions = 2 });
    }
    const session = try h.session(.default, false);
    try std.testing.expectEqual(@as(usize, 1), try permissionRunText(h.runtime, session, "Write the checkpoint fixture.", if (grant) .allow_session else .allow_once, false));
    const last_run_id = session.active_run_id;
    while (h.runtime.takeEvent()) |value| {
        var event = value;
        event.deinit();
    }
    const limits: agent.CheckpointLimits = .{
        .hard_bytes = 16 * 1024 * 1024,
        .max_section_bytes = 16 * 1024 * 1024,
        .max_string_bytes = 8 * 1024 * 1024,
        .max_messages = 1024,
        .max_blocks_per_message = 128,
        .chunk_bytes = 64 * 1024,
    };
    var bytes: RestoreBytes = .{};
    defer bytes.bytes.deinit(std.testing.allocator);
    var exported = try session.exportCheckpoint(limits, .{ .context = &bytes, .write_fn = RestoreBytes.write }, last_run_id, 0, "claude-sonnet-4-20250514");
    defer exported.deinit();
    const checkpoint = switch (exported) {
        .success => |value| value,
        .failure => return error.TestUnexpectedResult,
    };
    try h.runtime.shutdown();
    h.runtime.deinit();
    var probe: CoreProbe = undefined;
    try probe.init(changed_schema);
    h.runtime = try agent.Runtime.initImageGenerationWithApiForTesting(std.testing.io, std.testing.allocator, &probe.api, .{ .max_sessions = 2 }, .{ .transport = h.network.transport() });
    const restored = h.runtime.restoreSessionRoute(.{
        .session = .{
            .model_binding = .{ .target = .{ .provider_id = "fixture", .protocol = .anthropic_messages, .base_url = h.fixture.provider_endpoint, .model = "claude-sonnet-4-20250514" }, .credential = "synthetic-dialogue-key" },
            .permission_mode = .default,
            .shell_policy = .unrestricted,
            .workspace = .{ .canonical_root = h.root, .trust = .explicitly_trusted },
            .canonical_user_home = h.root,
            .operation_id_floor = .{ .last_run_id = last_run_id },
        },
        .checkpoint_limits = limits,
        .source = .{ .context = &bytes, .read_fn = RestoreBytes.read },
        .expectation = .{ .logical_session_id = checkpoint.description.session_id, .checkpoint_generation = checkpoint.checkpoint.generation, .last_run_id = last_run_id, .last_compact_id = 0, .model = "claude-sonnet-4-20250514" },
    }) catch |err| {
        if (old_image or grant or changed_schema) return err;
        // ABI rev 24 emits degraded with no invalidations and no issue when
        // the tool set changes but there are no persisted rules. Its own SDK
        // rejects that contradiction. Preserve this fail-closed behavior;
        // this regression is evidence of an OPEN B0 gate, not recovery support.
        try std.testing.expectEqual(error.RestoreContractFailed, err);
        try std.testing.expectError(error.InvalidPayload, sdk.decodeRestoreReport(std.testing.allocator, probe.report[0..probe.report_len]));
        const raw = try std.json.parseFromSlice(sdk.protocol.RestoreReport, std.testing.allocator, probe.report[0..probe.report_len], .{});
        defer raw.deinit();
        try std.testing.expectEqual(sdk.protocol.RestoreHealth.degraded, raw.value.health);
        try std.testing.expectEqual(@as(u32, 0), raw.value.permission.invalidated_rules);
        try std.testing.expectEqual(@as(u32, 0), raw.value.skill.invalidated);
        try std.testing.expectEqual(@as(u32, 0), raw.value.mcp.invalidated_bindings);
        try std.testing.expectEqual(@as(usize, 0), raw.value.issues.len);
        try std.testing.expectEqual(@as(usize, 0), probe.description_len);
        for (h.runtime.sessions, h.runtime.session_reservations) |entry, reserved| {
            try std.testing.expect(entry == null);
            try std.testing.expect(!reserved);
        }
        try h.evidence(0, 0, "");
        return;
    };
    var report = try sdk.decodeRestoreReport(std.testing.allocator, probe.report[0..probe.report_len]);
    defer report.deinit();
    var described = try sdk.decodeSessionDescription(std.testing.allocator, probe.description[0..probe.description_len]);
    defer described.deinit();
    // Changing only GenerateImage's schema does not invalidate an unrelated
    // built-in Write grant. Host tools cannot have persisted Session grants.
    const changed = !old_image;
    try std.testing.expectEqual(if (changed) agent.CheckpointRestoreHealth.degraded else .complete, restored.report.health);
    try std.testing.expectEqual(@as(u32, if (changed) 1 else 0), restored.report.invalidated_permission_rules);
    try std.testing.expectEqual(@as(u32, if (changed) 0 else 1), restored.report.restored_permission_rules);
    try std.testing.expectEqual(@as(usize, if (changed) 1 else 0), report.value.issues.len);
    if (changed) {
        try std.testing.expectEqual(sdk.protocol.AuthorityIssueReason.policy_changed, report.value.issues[0].reason);
        try std.testing.expectEqualStrings("Write", report.value.issues[0].canonical_name.?);
    }
    try std.testing.expectEqual(report.value.health, described.value.restore.health);
    try std.testing.expectEqual(report.value.permission.invalidated_rules, described.value.restore.invalidated_permission_rules);
    const answers = try permissionRunText(h.runtime, restored.session, "Write the checkpoint fixture.", .allow_once, false);
    try std.testing.expectEqual(@as(usize, if (changed) 1 else 0), answers);
    // Host authorization must still be requested independently of any Write grant.
    try std.testing.expectEqual(@as(usize, 1), try permissionRunText(h.runtime, restored.session, "Generate the fixture image.", .allow_once, true));
    try h.evidence(0, 0, "unavailable");
    if (changed_schema) {
        const trace = try h.trace();
        defer std.testing.allocator.free(trace);
        try std.testing.expect(std.mem.indexOf(u8, trace, "\"maxLength\":1000") != null);
    }
}

test "GenerateImage canonical checkpoint invalidates changed tool authority and preserves unchanged grants" {
    try checkpointTools(false, true, false);
    try checkpointTools(true, true, false);
    try checkpointTools(true, true, true);
}

test "GenerateImage old checkpoint without grants exposes contradictory Core report and fails closed (B0 gate open)" {
    try checkpointTools(false, false, false);
}

test "GenerateImage accept_edits still requires once-only Host approval" {
    var h: Harness = undefined;
    try h.init("repeat", .{});
    defer h.deinit();
    const session = try h.session(.accept_edits, true);
    try std.testing.expectEqual(@as(usize, 2), try permissionRun(&h, session, .allow_once));
    try h.evidence(2, 2, "saved");
}

test "GenerateImage accept_edits denial and noninteractive permission stop have zero effects" {
    var denied: Harness = undefined;
    try denied.init("success", .{});
    defer denied.deinit();
    const interactive = try denied.session(.accept_edits, true);
    try std.testing.expectEqual(@as(usize, 1), try permissionRun(&denied, interactive, .deny_once));
    try denied.evidence(0, 0, "");
    try std.testing.expectEqual(@as(usize, 0), denied.sink.attempts);

    var h: Harness = undefined;
    try h.init("success", .{});
    defer h.deinit();
    var config = openOptions(h.root, &h.fixture, .accept_edits);
    config.permission_interaction = .noninteractive;
    const session = try h.runtime.createSession(config);
    try session.configureImageGenerationForTesting(.{ .endpoint = h.fixture.endpoint, .model = "fixture-image", .credential = "synthetic-image-key", .output = h.sink.output() });
    var run = try session.beginRun(try session.prepareRun(.{ .text = "Generate the fixture image." }));
    defer run.deinit();
    var terminal = run.execute();
    defer terminal.deinit();
    try std.testing.expectEqual(agent.TerminationSignal.permission_required, terminal.termination_signal.?);
    try std.testing.expect(session.pendingUiRequest() == null);
    try std.testing.expectEqual(@as(usize, 0), h.sink.attempts);
    try h.evidence(0, 0, "");
}

// Platform prerequisites only. These probes do not certify the future product
// sink: B2 must use and verify these checks on its actual output path.
test "GenerateImage output prerequisites exclusive creation preserves existing bytes and exposes file identity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try tmp.dir.createDirPathOpen(std.testing.io, "generated-images", .{ .open_options = .{ .follow_symlinks = false } });
    defer dir.close(std.testing.io);
    try std.testing.expectEqual(std.Io.File.Kind.directory, (try dir.stat(std.testing.io)).kind);
    const file = try dir.createFile(std.testing.io, "image-probe.png", .{ .read = true, .exclusive = true, .resolve_beneath = true });
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, "owned image bytes");
    const owned = try file.stat(std.testing.io);
    try std.testing.expectEqual(std.Io.File.Kind.file, owned.kind);
    const named = try dir.statFile(std.testing.io, "image-probe.png", .{ .follow_symlinks = false });
    try std.testing.expectEqual(owned.inode, named.inode);
    try std.testing.expectError(error.PathAlreadyExists, dir.createFile(std.testing.io, "image-probe.png", .{ .exclusive = true, .resolve_beneath = true }));
    const bytes = try dir.readFileAlloc(std.testing.io, "image-probe.png", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("owned image bytes", bytes);
    // A pathname may refer to a replacement while the original handle lives.
    // Cleanup must compare current identity, and must not unlink the replacement.
    try dir.rename("image-probe.png", dir, "moved.png", std.testing.io);
    const replacement = try dir.createFile(std.testing.io, "image-probe.png", .{ .exclusive = true });
    defer replacement.close(std.testing.io);
    try replacement.writeStreamingAll(std.testing.io, "replacement");
    const now = try dir.statFile(std.testing.io, "image-probe.png", .{ .follow_symlinks = false });
    try std.testing.expect(owned.inode != now.inode);
    try std.testing.expectEqual(owned.inode, (try file.stat(std.testing.io)).inode);
}

test "GenerateImage output prerequisites detect directory junction without traversing it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const trace = try std.fs.path.join(std.testing.allocator, &.{ root, "trace.jsonl" });
    defer std.testing.allocator.free(trace);
    var fixture = try Fixture.start(trace, "output-junction");
    defer fixture.deinit();
    // On Windows no-follow can OPEN the reparse object, rather than rejecting
    // it. The handle's kind check is essential before any descendant effects.
    const metadata = try tmp.dir.statFile(std.testing.io, "generated-images", .{ .follow_symlinks = false });
    try std.testing.expectEqual(std.Io.File.Kind.sym_link, metadata.kind);
    if (tmp.dir.openDir(std.testing.io, "generated-images", .{ .follow_symlinks = false })) |dir| {
        defer dir.close(std.testing.io);
        try std.testing.expectEqual(std.Io.File.Kind.sym_link, (try dir.stat(std.testing.io)).kind);
    } else |err| switch (err) {
        error.NotDir, error.SymLinkLoop => {},
        else => return err,
    }
    var outside = try tmp.dir.openDir(std.testing.io, "outside", .{ .iterate = true });
    defer outside.close(std.testing.io);
    var entries = outside.iterate();
    try std.testing.expectEqual(@as(?std.Io.Dir.Entry, null), try entries.next(std.testing.io));
}

test "GenerateImage identical prompts are separate requests and concurrent calls overlap" {
    try successful("repeat", 2);
    try successful("concurrent", 2);
    try successful("prompt-url", 1);
}

test "GenerateImage canonical Core saves actual Workspace files and rejects output directory junctions" {
    for ([_][]const u8{ "success", "repeat", "concurrent", "output-junction" }) |mode| {
        var h: Harness = undefined;
        try h.init(mode, .{});
        defer h.deinit();
        var output = try workspace_output.Output.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId(), .{
            .id = 1,
            .epoch = 1,
            .kind = .manual,
            .canonical_root = h.root,
            .trust = .explicitly_trusted,
        });
        defer output.deinit();
        const session = try h.session(.full_access, false);
        try session.configureImageGenerationForTesting(.{
            .endpoint = h.fixture.endpoint,
            .model = "fixture-image",
            .credential = "synthetic-image-key",
            .output = output.port(),
        });
        try executeWorker(session);
        const trace = try h.trace();
        defer std.testing.allocator.free(trace);
        const junction = std.mem.eql(u8, mode, "output-junction");
        const expected: usize = if (std.mem.eql(u8, mode, "repeat") or std.mem.eql(u8, mode, "concurrent")) 2 else 1;
        try std.testing.expectEqual(expected, count(trace, "\"kind\":\"image\""));
        try std.testing.expectEqual(@as(usize, 0), count(trace, "fixture_error"));
        try std.testing.expectEqual(if (junction) @as(usize, 0) else expected, count(trace, "\\\"status\\\":\\\"saved\\\""));
        if (junction) {
            try std.testing.expect(std.mem.indexOf(u8, trace, "output_failed") != null);
            var outside = try h.tmp.dir.openDir(std.testing.io, "outside", .{ .iterate = true });
            defer outside.close(std.testing.io);
            var entries = outside.iterate();
            try std.testing.expectEqual(@as(?std.Io.Dir.Entry, null), try entries.next(std.testing.io));
        } else {
            const png = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, options.png_path, std.testing.allocator, .limited(1024));
            defer std.testing.allocator.free(png);
            var directory = try h.tmp.dir.openDir(std.testing.io, "generated-images", .{ .iterate = true });
            defer directory.close(std.testing.io);
            var entries = directory.iterate();
            var files: usize = 0;
            while (try entries.next(std.testing.io)) |entry| {
                try std.testing.expectEqual(std.Io.File.Kind.file, entry.kind);
                const bytes = try directory.readFileAlloc(std.testing.io, entry.name, std.testing.allocator, .limited(1024));
                defer std.testing.allocator.free(bytes);
                try std.testing.expectEqualSlices(u8, png, bytes);
                var path: [256]u8 = undefined;
                const receipt_path = try std.fmt.bufPrint(&path, "\\\"path\\\":\\\"generated-images/{s}\\\"", .{entry.name});
                try std.testing.expect(std.mem.indexOf(u8, trace, receipt_path) != null);
                files += 1;
            }
            try std.testing.expectEqual(expected, files);
        }
        try std.testing.expectEqual(h.runtime.image_results_created.load(.acquire), h.runtime.image_results_released.load(.acquire));
        try std.testing.expectEqual(@as(usize, 0), h.runtime.image_budget.used.load(.acquire));
    }
}

test "GenerateImage captured output root refuses an ancestor retargeted to a junction" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    try tmp.dir.createDirPath(std.testing.io, "redirect/nested");
    const captured = try std.fs.path.join(std.testing.allocator, &.{ root, "redirect", "nested" });
    defer std.testing.allocator.free(captured);
    var output = try workspace_output.Output.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId(), .{
        .id = 1,
        .epoch = 1,
        .kind = .manual,
        .canonical_root = captured,
        .trust = .explicitly_trusted,
    });
    defer output.deinit();
    const trace_path = try std.fs.path.join(std.testing.allocator, &.{ root, "trace.jsonl" });
    defer std.testing.allocator.free(trace_path);
    var fixture = try Fixture.start(trace_path, "output-root-junction");
    defer fixture.deinit();
    var network: backend.Backend = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    const runtime = try agent.Runtime.initImageGenerationForTesting(std.testing.io, std.testing.allocator, .{ .max_sessions = 1 }, .{ .transport = network.transport() });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    const session = try open(runtime, root, &fixture, .full_access);
    try session.configureImageGenerationForTesting(.{ .endpoint = fixture.endpoint, .model = "fixture-image", .credential = "synthetic-image-key", .output = output.port() });
    try executeWorker(session);
    const trace = try tmp.dir.readFileAlloc(std.testing.io, "trace.jsonl", std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(trace);
    try std.testing.expectEqual(@as(usize, 1), count(trace, "\"kind\":\"image\""));
    try std.testing.expect(std.mem.indexOf(u8, trace, "output_failed") != null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "outside/nested/generated-images", .{}));
}

test "GenerateImage canonical failures never synthesize a saved file or leak a credential" {
    const cases = .{
        .{ "invalid", @as(usize, 0), "invalid_arguments" },
        .{ "reject", @as(usize, 2), "provider_rejected" },
        .{ "redirect", @as(usize, 1), "provider_rejected" },
        .{ "url", @as(usize, 1), "unsupported_output" },
        .{ "bad-json", @as(usize, 1), "invalid_response" },
        .{ "bad-base64", @as(usize, 1), "invalid_response" },
        .{ "oversized", @as(usize, 1), "outcome_unknown" },
    };
    inline for (cases) |case| {
        var h: Harness = undefined;
        try h.init(case[0], .{});
        defer h.deinit();
        try execute(try h.session(.full_access, true));
        try h.evidence(case[1], 0, case[2]);
        try std.testing.expectError(error.FileNotFound, h.tmp.dir.openFile(std.testing.io, "image-1.png", .{}));
    }
}

test "GenerateImage missing binding and permission refusal produce zero image requests" {
    for ([_]bool{ false, true }) |binding| {
        var h: Harness = undefined;
        try h.init("success", .{});
        defer h.deinit();
        const session = try h.session(if (binding) .default else .full_access, binding);
        if (binding) try std.testing.expectEqual(@as(usize, 1), try permissionRun(&h, session, .deny_once)) else try execute(session);
        try h.evidence(0, 0, if (binding) "" else "unavailable");
    }
    var h: Harness = undefined;
    try h.init("repeat", .{});
    defer h.deinit();
    const session = try h.session(.default, true);
    try std.testing.expectEqual(@as(usize, 2), try permissionRun(&h, session, .allow_once));
    try h.evidence(2, 2, "saved");
}

test "GenerateImage unknown outcome permits new intent while quota resets next Run" {
    var h: Harness = undefined;
    try h.init("drop-first", .{ .sends_per_run = 2 });
    defer h.deinit();
    const session = try h.session(.full_access, true);
    try execute(session);
    try h.evidence(2, 1, "outcome_unknown");
    try execute(session);
    try h.evidence(4, 3, "saved");
}

test "GenerateImage reserves concurrent sending quota before HTTP and isolates sessions" {
    var h: Harness = undefined;
    try h.init("quota", .{ .sends_per_run = 1 });
    defer h.deinit();
    const first = try h.session(.full_access, true);
    const second = try h.session(.full_access, false);
    try execute(first);
    try h.evidence(1, 1, "capacity");
    try execute(second);
    try h.evidence(1, 1, "unavailable");
    try execute(first);
    try h.evidence(2, 2, "capacity");
}

test "GenerateImage parallel quota reservation never sends a third request" {
    var h: Harness = undefined;
    try h.init("concurrent-quota", .{ .sends_per_run = 2 });
    defer h.deinit();
    try execute(try h.session(.full_access, true));
    try h.evidence(2, 2, "capacity");
    const trace = try h.trace();
    defer std.testing.allocator.free(trace);
    try std.testing.expect(std.mem.indexOf(u8, trace, "\"active\":2") != null);
    try std.testing.expectEqual(@as(usize, 3), h.runtime.image_results_created.load(.acquire));
}

test "GenerateImage owns binding buffers and concurrent sessions keep distinct output owners" {
    var h: Harness = undefined;
    try h.init("cross-session", .{ .sends_per_run = 1 });
    defer h.deinit();
    const first = try h.session(.full_access, true);
    try h.tmp.dir.createDir(std.testing.io, "second", .default_dir);
    var second_dir = try h.tmp.dir.openDir(std.testing.io, "second", .{});
    defer second_dir.close(std.testing.io);
    const second_root = try second_dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(second_root);
    const second = try open(h.runtime, second_root, &h.fixture, .full_access);
    var second_sink: Sink = .{ .dir = second_dir };
    const endpoint = try std.testing.allocator.dupe(u8, h.fixture.endpoint);
    defer std.testing.allocator.free(endpoint);
    var model = "fixture-image".*;
    var credential = "synthetic-image-key".*;
    try second.configureImageGenerationForTesting(.{ .endpoint = endpoint, .model = &model, .credential = &credential, .output = second_sink.output() });
    @memset(endpoint, 'x');
    @memset(&model, 'x');
    @memset(&credential, 'x');
    var a: Work = .{ .session = first, .id = try first.prepareRun(.{ .text = "Generate the fixture image." }) };
    var b: Work = .{ .session = second, .id = try second.prepareRun(.{ .text = "Generate the fixture image." }) };
    const thread_a = try std.Thread.spawn(.{}, Work.run, .{&a});
    const thread_b = try std.Thread.spawn(.{}, Work.run, .{&b});
    thread_a.join();
    thread_b.join();
    defer a.result.?.deinit();
    defer b.result.?.deinit();
    try std.testing.expectEqual(@as(?agent.TerminalFailure, null), a.result.?.failure);
    try std.testing.expectEqual(@as(?agent.TerminalFailure, null), b.result.?.failure);
    try h.evidence(2, 1, "saved");
    try std.testing.expectEqual(@as(usize, 1), second_sink.saved);
    const a_bytes = try h.tmp.dir.readFileAlloc(std.testing.io, "image-1.png", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(a_bytes);
    const b_bytes = try second_dir.readFileAlloc(std.testing.io, "image-1.png", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(b_bytes);
    try std.testing.expectEqualSlices(u8, a_bytes, b_bytes);
    const trace = try h.trace();
    defer std.testing.allocator.free(trace);
    try std.testing.expect(std.mem.indexOf(u8, trace, "\"active\":2") != null);
}

fn waitImage(h: *Harness) !void {
    for (0..5000) |_| {
        const trace = h.trace() catch |err| {
            if (err != error.FileNotFound) return err;
            std.testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
            continue;
        };
        defer std.testing.allocator.free(trace);
        if (count(trace, "\"kind\":\"image\"") != 0) return;
        std.testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    return error.ImageRequestNotObserved;
}

test "GenerateImage blocked HTTP is cancelled by stop close and Runtime shutdown without UI drain" {
    for (0..3) |action| {
        var h: Harness = undefined;
        try h.init("hold", .{});
        defer h.deinit();
        const session = try h.session(.full_access, true);
        var work: Work = .{ .session = session, .id = try session.prepareRun(.{ .text = "Generate the fixture image." }) };
        const thread = try std.Thread.spawn(.{}, Work.run, .{&work});
        defer {
            thread.join();
            if (work.result) |*result| result.deinit();
        }
        try waitImage(&h); // request received, rather than a guessed sleep
        const start = std.Io.Timestamp.now(std.testing.io, .awake);
        switch (action) {
            0 => {
                _ = try session.requestTermination(work.id, .{ .interrupted = .user_cancel });
            },
            1 => try session.close(.session_close),
            2 => try h.runtime.shutdown(),
            else => unreachable,
        }
        for (0..3000) |_| {
            if (work.done.load(.acquire)) break;
            std.testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
        }
        try std.testing.expect(work.done.load(.acquire));
        try std.testing.expect(start.durationTo(std.Io.Timestamp.now(std.testing.io, .awake)).nanoseconds < 3 * std.time.ns_per_s);
        try std.testing.expect(work.result.?.termination_signal.? == .interrupted);
        try h.evidence(1, 0, "");
    }
}

test "GenerateImage real Workspace output joins cancelled file work on stop close and shutdown" {
    for (0..3) |action| {
        var h: Harness = undefined;
        try h.init("success", .{});
        defer h.deinit();
        var output = try workspace_output.Output.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId(), .{
            .id = 1,
            .epoch = 1,
            .kind = .manual,
            .canonical_root = h.root,
            .trust = .explicitly_trusted,
        });
        defer output.deinit();
        var barrier: workspace_output.TestSupport.Barrier = .{ .io = std.testing.io };
        workspace_output.TestSupport.blockBeforeWrite(&output, &barrier);
        const session = try h.session(.full_access, false);
        try session.configureImageGenerationForTesting(.{ .endpoint = h.fixture.endpoint, .model = "fixture-image", .credential = "synthetic-image-key", .output = output.port() });
        var work: Work = .{ .session = session, .id = try session.prepareRun(.{ .text = "Generate the fixture image." }) };
        const thread = try std.Thread.spawn(.{}, Work.run, .{&work});
        var joined = false;
        defer {
            barrier.release();
            if (!joined) thread.join();
            if (work.result) |*result| result.deinit();
        }
        const deadline = std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds + 3 * std.time.ns_per_s;
        while (!barrier.entered.load(.acquire)) {
            if (std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds >= deadline) return error.ImageRequestNotObserved;
            std.testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
        }
        const start = std.Io.Timestamp.now(std.testing.io, .awake);
        switch (action) {
            0 => _ = try session.requestTermination(work.id, .{ .interrupted = .user_cancel }),
            1 => try session.close(.session_close),
            2 => try h.runtime.shutdown(),
            else => unreachable,
        }
        while (!work.done.load(.acquire)) {
            if (start.durationTo(std.Io.Timestamp.now(std.testing.io, .awake)).nanoseconds >= 3 * std.time.ns_per_s)
                return error.TestUnexpectedResult;
            std.testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
        }
        thread.join();
        joined = true;
        try std.testing.expect(work.result.?.termination_signal.? == .interrupted);
        var directory = try h.tmp.dir.openDir(std.testing.io, "generated-images", .{ .iterate = true });
        defer directory.close(std.testing.io);
        var entries = directory.iterate();
        try std.testing.expectEqual(@as(?std.Io.Dir.Entry, null), try entries.next(std.testing.io));
        try h.evidence(1, 0, "");
    }
}

test "GenerateImage independent deadline stops one request without cancelling another or the next Run" {
    var h: Harness = undefined;
    try h.init("deadline-mixed", .{ .timeout_ms = 500 });
    defer h.deinit();
    const session = try h.session(.full_access, true);
    try execute(session);
    try h.evidence(2, 1, "outcome_unknown");
    try execute(session);
    try h.evidence(4, 3, "saved");
}

test "GenerateImage test output refuses conflicts and cleans partial files before commit" {
    for (0..3) |fault| {
        var h: Harness = undefined;
        try h.init("success", .{});
        defer h.deinit();
        h.sink.force_conflict = fault == 0;
        h.sink.fail_write = fault == 1;
        h.sink.cancel_before_commit = fault == 2;
        if (fault == 0) try h.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "image-1.png", .data = "sentinel" });
        try execute(try h.session(.full_access, true));
        try h.evidence(1, 0, if (fault == 2) "outcome_unknown" else "output_failed");
        if (fault == 0) {
            const bytes = try h.tmp.dir.readFileAlloc(std.testing.io, "image-1.png", std.testing.allocator, .limited(100));
            defer std.testing.allocator.free(bytes);
            try std.testing.expectEqualStrings("sentinel", bytes);
        } else try std.testing.expectError(error.FileNotFound, h.tmp.dir.openFile(std.testing.io, "image-1.png", .{}));
    }
}

test "GenerateImage committed fact survives cancellation and long receipt is delivered" {
    var h: Harness = undefined;
    try h.init("success", .{});
    defer h.deinit();
    h.sink.cancel_after_commit = true;
    try execute(try h.session(.full_access, true));
    try h.evidence(1, 1, "saved");
    var long: Harness = undefined;
    try long.init("success", .{});
    defer long.deinit();
    long.sink.long_name = true;
    try execute(try long.session(.full_access, true));
    try std.testing.expectEqual(@as(usize, 1), long.sink.saved);
    try std.testing.expectEqual(@as(usize, 1), long.runtime.image_results_created.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), long.runtime.image_results_released.load(.acquire));
    const name = [_]u8{'a'} ** 200;
    const bytes = try long.tmp.dir.readFileAlloc(std.testing.io, &name, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(bytes);
    const png = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, options.png_path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(png);
    try std.testing.expectEqualSlices(u8, png, bytes);
    const trace = try long.trace();
    defer std.testing.allocator.free(trace);
    try std.testing.expectEqual(@as(usize, 1), count(trace, "\"kind\":\"image\""));
    try std.testing.expectEqual(@as(usize, 1), count(trace, "\\\"status\\\":\\\"saved\\\""));
    try std.testing.expect(std.mem.indexOf(u8, trace, &name) != null);
}

test "GenerateImage Runtime working budget bounds parallel calls and returns to zero" {
    var limits: agent.ImageGenerationLimits = .{ .timeout_ms = 300 };
    limits.memory_bytes = limits.workingBytes() + 10_000;
    var h: Harness = undefined;
    try h.init("concurrent", limits);
    defer h.deinit();
    try execute(try h.session(.full_access, true));
    try h.evidence(1, 0, "capacity");
}

test "GenerateImage unavailable permission callback sends nothing and closes normally" {
    const Ui = struct {
        fn notify(context: ?*anyopaque) agent.EventReadyNotification {
            const session: *agent.Session = @ptrCast(@alignCast(context.?));
            return if (session.pendingUiRequest() != null) .unavailable else .already_pending;
        }
    };
    var h: Harness = undefined;
    try h.init("success", .{});
    defer h.deinit();
    const session = try h.session(.default, true);
    h.runtime.event_ready_notifier = .{ .context = session, .notify_fn = Ui.notify };
    var run = try session.beginRun(try session.prepareRun(.{ .text = "Generate the fixture image." }));
    var terminal = run.execute();
    defer terminal.deinit();
    run.deinit();
    try std.testing.expect(terminal.termination_signal.? == .event_consumer_notification_failure);
    try h.evidence(0, 0, "");
    h.runtime.event_ready_notifier = null;
    try session.close(.session_close);
}
