const std = @import("std");
const agent = @import("metawork_agent");
const backend = @import("image_http_backend");
const options = @import("image_fixture_options");
const sdk = @import("lifecycle_fixture").sdk;
const workspace_output = @import("image_output");

// Pass-through instrumentation over the exact staged binary. No result, issue,
// checkpoint or status is fabricated. Test-only inputs reproduce the previous
// zero-Host-tool release and a changed GenerateImage schema.
const CoreProbe = struct {
    var active: *CoreProbe = undefined;
    api: sdk.types.ApiV1,
    runtime_api: sdk.types.RuntimeApiV1,
    session_api: sdk.types.SessionApiV1,
    control_api: sdk.types.SessionControlApiV1,
    original: sdk.Api,
    changed_schema: bool = false,
    legacy_tools: bool = false,
    legacy_host_count: usize = 0,
    report: [8192]u8 = undefined,
    report_len: usize = 0,
    description: [8192]u8 = undefined,
    description_len: usize = 0,

    fn init(self: *CoreProbe, changed: bool) !void {
        const original = try sdk.Api.discover();
        self.* = .{ .api = original.raw.*, .runtime_api = original.raw.runtime.?.*, .session_api = original.raw.session.?.*, .control_api = original.raw.session_control.?.*, .original = original, .changed_schema = changed };
        self.runtime_api.create = create;
        self.session_api.create = createSession;
        self.control_api.restore = restore;
        self.control_api.describe = describe;
        self.api.runtime = &self.runtime_api;
        self.api.session = &self.session_api;
        self.api.session_control = &self.control_api;
        active = self;
    }
    fn create(config: ?*const sdk.types.RuntimeConfigV1, plugins: ?*const sdk.types.RuntimePluginConfigV1, output: ?*?*sdk.types.RuntimeHandle, diagnostic: ?*sdk.types.OwnedBytesV1) callconv(.c) u32 {
        var copy = config.?.*;
        if (active.legacy_tools) {
            copy.host_tools = if (active.legacy_host_count == 0) null else copy.host_tools;
            copy.host_tool_count = active.legacy_host_count;
            return active.original.runtime().create()(&copy, plugins, output, diagnostic);
        }
        if (active.changed_schema) {
            std.debug.assert(copy.host_tool_count == 2);
            var tools = [_]sdk.types.HostToolV1{ copy.host_tools.?[0], copy.host_tools.?[1] };
            const tool = &tools[0];
            tool.input_schema_json = sdk.bytesView("{\"type\":\"object\",\"properties\":{\"prompt\":{\"type\":\"string\",\"maxLength\":1000}},\"required\":[\"prompt\"],\"additionalProperties\":false}");
            copy.host_tools = &tools;
            return active.original.runtime().create()(&copy, plugins, output, diagnostic);
        }
        return active.original.runtime().create()(config, plugins, output, diagnostic);
    }
    fn createSession(runtime: ?*sdk.types.RuntimeHandle, config: ?*const sdk.types.SessionCreateConfigV1, callbacks: ?*const sdk.types.SessionCallbacksV1, output: ?*?*sdk.types.SessionHandle, diagnostic: ?*sdk.types.OwnedBytesV1) callconv(.c) u32 {
        var copy = config.?.*;
        var host = copy.host.?.*;
        if (active.legacy_tools) {
            std.debug.assert(host.allowed_tool_count == 12);
            std.debug.assert(std.mem.eql(u8, sdk.borrowedBytes(host.allowed_tools.?[10]) catch "", "GenerateImage"));
            host.allowed_tool_count -= 2 - active.legacy_host_count;
            copy.host = &host;
        }
        return active.original.session().create()(runtime, &copy, callbacks, output, diagnostic);
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
        var image_limit_buffer: [32]u8 = undefined;
        const image_limit = try std.fmt.bufPrint(&image_limit_buffer, "{d}", .{agent.multimodal_input_limits.max_image_raw_bytes});
        var child = try std.process.spawn(std.testing.io, .{
            .argv = &.{ options.node_path, options.fixture_path, trace, mode, image_limit },
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
    fn commitResult(context: *anyopaque, bytes: []const u8, format: agent.ImageGenerationFormat, cancellation: *const agent.CompletionCancellation) agent.ImageGenerationOutputResult {
        return .{ .saved = commit(context, bytes, format, cancellation) catch |err|
            return .{ .failed = .{ .code = if (err == error.Cancelled) .cancelled else .write_failed } } };
    }
    fn commit(context: *anyopaque, bytes: []const u8, format: agent.ImageGenerationFormat, cancellation: *const agent.CompletionCancellation) !agent.ImageGenerationReceipt {
        const self: *Sink = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(std.testing.io);
        defer self.mutex.unlock(std.testing.io);
        self.attempts += 1;
        var name_storage: [200]u8 = @splat('a');
        const name = if (self.long_name) &name_storage else try std.fmt.bufPrint(&name_storage, "image-{d}.{s}", .{ if (self.force_conflict) @as(usize, 1) else self.attempts, format.extension() });
        const receipt = try agent.ImageGenerationReceipt.init(name, bytes.len, format);
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

fn checkpointTools(old_host_count: usize, grant: bool, changed_schema: bool) !void {
    var h: Harness = undefined;
    try h.init("restore", .{});
    defer h.deinit();
    var legacy_probe: CoreProbe = undefined;
    if (old_host_count < 2) {
        try h.runtime.shutdown();
        h.runtime.deinit();
        try legacy_probe.init(false);
        legacy_probe.legacy_tools = true;
        legacy_probe.legacy_host_count = old_host_count;
        h.runtime = try agent.Runtime.initWithApi(std.testing.io, std.testing.allocator, &legacy_probe.api, .{ .max_sessions = 2 });
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
    const restored = try h.runtime.restoreSessionRoute(.{
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
    });
    var report = try sdk.decodeRestoreReport(std.testing.allocator, probe.report[0..probe.report_len]);
    defer report.deinit();
    var described = try sdk.decodeSessionDescription(std.testing.allocator, probe.description[0..probe.description_len]);
    defer described.deinit();
    // Changing only GenerateImage's schema does not invalidate an unrelated
    // built-in Write grant. Host tools cannot have persisted Session grants.
    const changed = old_host_count < 2 and grant;
    try std.testing.expectEqual(if (changed) agent.CheckpointRestoreHealth.degraded else .complete, restored.report.health);
    try std.testing.expectEqual(@as(u32, if (changed) 1 else 0), restored.report.invalidated_permission_rules);
    try std.testing.expectEqual(@as(u32, if (grant and !changed) 1 else 0), restored.report.restored_permission_rules);
    try std.testing.expectEqual(@as(usize, if (changed) 1 else 0), report.value.issues.len);
    if (changed) {
        try std.testing.expectEqual(sdk.protocol.AuthorityIssueReason.policy_changed, report.value.issues[0].reason);
        try std.testing.expectEqualStrings("Write", report.value.issues[0].canonical_name.?);
    }
    try std.testing.expectEqual(report.value.health, described.value.restore.health);
    try std.testing.expectEqual(report.value.permission.invalidated_rules, described.value.restore.invalidated_permission_rules);
    try std.testing.expectEqualStrings(checkpoint.description.session_id, described.value.session_id);
    try std.testing.expectEqual(checkpoint.checkpoint.generation, report.value.checkpoint_generation);
    try std.testing.expectEqual(last_run_id, described.value.last_run_id);
    const answers = try permissionRunText(h.runtime, restored.session, "Write the checkpoint fixture.", .allow_once, false);
    try std.testing.expectEqual(@as(usize, if (!grant or changed) 1 else 0), answers);
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
    try checkpointTools(0, true, false);
    try checkpointTools(2, true, false);
    try checkpointTools(2, true, true);
}

test "GenerateImage legacy checkpoint without grants restores complete and requires fresh approval" {
    try checkpointTools(0, false, false);
}

test "GenerateImage accept_edits still requires once-only Host approval" {
    var h: Harness = undefined;
    try h.init("repeat", .{});
    defer h.deinit();
    const session = try h.session(.accept_edits, true);
    try std.testing.expectEqual(@as(usize, 2), try permissionRun(&h, session, .allow_once));
    try h.evidence(2, 2, "saved");
}

test "GenerateImage ordinary Runtime exposes the tool without requiring image configuration for text" {
    var h: Harness = undefined;
    try h.init("success", .{});
    defer h.deinit();
    try h.runtime.shutdown();
    h.runtime.deinit();
    h.runtime = try agent.Runtime.init(std.testing.io, std.testing.allocator, .{ .max_sessions = 2 });
    const session = try h.session(.accept_edits, false);
    try std.testing.expectEqual(@as(usize, 1), try permissionRun(&h, session, .allow_once));
    try h.evidence(0, 0, "unavailable");
    try std.testing.expectEqual(@as(usize, 0), h.sink.attempts);
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

test "GenerateImage per-Run input freezes borrowed data and effects and never inherits a prior Run" {
    const Forward = struct {
        network: *backend.Backend,
        endpoint: []const u8,
        calls: std.atomic.Value(usize) = .init(0),

        fn transport(self: *@This()) agent.CompletionTransport {
            return .{ .context = self, .perform_fn = perform, .signal_cancellation_fn = signal };
        }
        fn perform(context: ?*anyopaque, request: agent.CompletionHttpRequest, cancellation: *const agent.CompletionCancellation, buffer: []u8) agent.CompletionTransportError!agent.CompletionTransportResponse {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (!std.mem.eql(u8, request.url, "https://image-policy.example.test/v1/images/generations")) return error.InvalidHttp;
            _ = self.calls.fetchAdd(1, .monotonic);
            // Test effect only: assert the frozen HTTPS policy target, then
            // route synthetic credentials to the one local fixture listener.
            return self.network.transport().perform(.{ .url = self.endpoint, .headers = request.headers, .body = request.body }, cancellation, buffer);
        }
        fn signal(context: ?*anyopaque, cancellation: *agent.CompletionCancellation) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            const network = self.network.transport();
            network.signal_cancellation_fn.?(network.context, cancellation);
        }
    };
    var h: Harness = undefined;
    try h.init("success", .{ .timeout_ms = 1000 });
    defer h.deinit();
    const session = try h.session(.full_access, true);
    var first: Forward = .{ .network = &h.network, .endpoint = h.fixture.endpoint };
    var second: Forward = .{ .network = &h.network, .endpoint = h.fixture.endpoint };
    var alternate_sink: Sink = .{ .dir = h.tmp.dir };
    var endpoint = "https://image-policy.example.test/v1/images/generations".*;
    var model = "fixture-image".*;
    var credential = "synthetic-image-key".*;
    var input: agent.ImageGenerationRunInput = .{
        .binding = .{ .endpoint = &endpoint, .model = &model, .credential = &credential, .output = h.sink.output() },
        .transport = first.transport(),
    };
    const id = try session.prepareRunWithTools(.{ .text = "Generate the fixture image." }, input, null);
    @memset(&endpoint, 'x');
    @memset(&model, 'x');
    @memset(&credential, 0);
    input.binding.output = alternate_sink.output();
    input.transport = second.transport();
    var work: Work = .{ .session = session, .id = id };
    const thread = try std.Thread.spawn(.{}, Work.run, .{&work});
    thread.join();
    defer work.result.?.deinit();
    try std.testing.expectEqual(@as(?agent.TerminalFailure, null), work.result.?.failure);
    try std.testing.expectEqual(@as(usize, 1), first.calls.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), second.calls.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), alternate_sink.saved);
    try std.testing.expect(session.run_image == null);
    try h.evidence(1, 1, "saved");

    // Explicit unavailability also overrides the Session's synthetic fixture
    // source. Neither the previous production input nor the fixture is reused.
    var missing: Work = .{ .session = session, .id = try session.prepareRunWithTools(.{ .text = "Generate the fixture image." }, null, null) };
    const missing_thread = try std.Thread.spawn(.{}, Work.run, .{&missing});
    missing_thread.join();
    defer missing.result.?.deinit();
    try std.testing.expectEqual(@as(?agent.TerminalFailure, null), missing.result.?.failure);
    try h.evidence(1, 1, "unavailable");
    const next: agent.ImageGenerationRunInput = .{
        .binding = .{
            .endpoint = "https://image-policy.example.test/v1/images/generations",
            .model = "fixture-image",
            .credential = "synthetic-image-key",
            .output = h.sink.output(),
        },
        .transport = second.transport(),
    };
    const cancelled = try session.prepareRunWithTools(.{ .text = "Generate the fixture image." }, next, null);
    try session.cancelPreparedRun(cancelled);
    try std.testing.expect(session.run_image == null);
    try std.testing.expectEqual(@as(usize, 0), second.calls.load(.acquire));
    var renewed: Work = .{ .session = session, .id = try session.prepareRunWithTools(.{ .text = "Generate the fixture image." }, next, null) };
    const renewed_thread = try std.Thread.spawn(.{}, Work.run, .{&renewed});
    renewed_thread.join();
    defer renewed.result.?.deinit();
    try std.testing.expectEqual(@as(?agent.TerminalFailure, null), renewed.result.?.failure);
    try std.testing.expectEqual(@as(usize, 1), first.calls.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), second.calls.load(.acquire));
    try std.testing.expect(session.run_image == null);
    try h.evidence(2, 2, "saved");
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

test "GenerateImage HTTP 401 429 and 503 never retry implicitly and permit a later explicit Run" {
    const cases = .{
        .{ "reject-401", @as(u16, 401) },
        .{ "reject-429", @as(u16, 429) },
        .{ "reject-503", @as(u16, 503) },
    };
    inline for (cases) |case| {
        var h: Harness = undefined;
        try h.init(case[0], .{});
        defer h.deinit();
        const session = try h.session(.full_access, true);
        for (1..3) |requests| {
            try execute(session);
            try h.evidence(requests, 0, "provider_rejected");
            try std.testing.expectEqual(@as(usize, 0), h.sink.attempts);
            try std.testing.expectError(error.FileNotFound, h.tmp.dir.openFile(std.testing.io, "image-1.png", .{}));
        }
        const trace = try h.trace();
        defer std.testing.allocator.free(trace);
        var marker: [96]u8 = undefined;
        const rejection = try std.fmt.bufPrint(&marker, "\"kind\":\"image_rejected\",\"status\":{d}", .{case[1]});
        try std.testing.expectEqual(@as(usize, 2), count(trace, rejection));
        try std.testing.expectEqual(@as(usize, 2), count(trace, "provider_rejected"));
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

const image_product = struct {
    const fixture_api = @import("lifecycle_fixture");
    const control_api = fixture_api.product_control;
    const task_api = fixture_api.product_task;
    const models = fixture_api.models_contract;
    const ports = fixture_api.models_ports;
    const account_api = @import("metawork_account");
    const coordinator_api = @import("models_coordinator");
    const catalog_transport = @import("metask_transport");

    const Effects = struct {
        network: *backend.Backend,
        endpoint: []const u8,
        trace_dir: std.Io.Dir,
        fallback: bool = false,
        image_calls: std.atomic.Value(usize) = .init(0),
        catalog_calls: std.atomic.Value(usize) = .init(0),
        key: [64]u8 = undefined,
        key_len: usize = 0,
        fn imageTransport(self: *@This()) agent.CompletionTransport {
            return .{ .context = self, .perform_fn = image, .signal_cancellation_fn = signal };
        }
        fn serverRecordedImage(self: *@This()) !bool {
            const bytes = self.trace_dir.readFileAlloc(std.testing.io, "trace.jsonl", std.testing.allocator, .limited(1024 * 1024)) catch |err| return if (err == error.FileNotFound) false else err;
            defer std.testing.allocator.free(bytes);
            return std.mem.indexOf(u8, bytes, "\"kind\":\"image\"") != null;
        }
        fn image(context: ?*anyopaque, request: agent.CompletionHttpRequest, cancellation: *const agent.CompletionCancellation, output: []u8) agent.CompletionTransportError!agent.CompletionTransportResponse {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (!std.mem.eql(u8, request.url, models.metask_images_generations_url)) return error.InvalidHttp;
            const body = std.json.parseFromSlice(struct { model: []const u8 }, std.testing.allocator, request.body, .{ .ignore_unknown_fields = true }) catch return error.InvalidHttp;
            defer body.deinit();
            if (!std.mem.eql(u8, body.value.model, if (self.fallback) "fixture-image" else models.metask_default_image_model)) return error.InvalidHttp;
            _ = self.image_calls.fetchAdd(1, .monotonic);
            // This test effect is the only target rewrite. No real credential
            // or formal service is used; production Models supplies the target.
            return self.network.transport().perform(.{ .url = self.endpoint, .body = request.body, .headers = request.headers }, cancellation, output);
        }
        fn signal(context: ?*anyopaque, cancellation: *agent.CompletionCancellation) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            const transport = self.network.transport();
            transport.signal_cancellation_fn.?(transport.context, cancellation);
        }
        fn catalog(context: *anyopaque, request: catalog_transport.Request, output: []u8) catalog_transport.TransportError!catalog_transport.Response {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (request.kind != .models or !std.mem.eql(u8, request.bearer orelse "", "synthetic-image-key")) return error.ProtocolFailed;
            _ = self.catalog_calls.fetchAdd(1, .monotonic);
            const body = if (self.fallback)
                "{\"object\":\"list\",\"has_more\":false,\"data\":[{\"id\":\"fixture-image\",\"object\":\"model\",\"type\":\"model\",\"capabilities\":{\"endpoints\":{\"images_generations\":{\"supported\":true}}}}]}"
            else
                "{\"object\":\"list\",\"has_more\":false,\"data\":[{\"id\":\"" ++ models.metask_default_image_model ++ "\",\"object\":\"model\",\"type\":\"model\",\"capabilities\":{\"endpoints\":{\"images_generations\":{\"supported\":true}}}}]}";
            @memcpy(output[0..body.len], body);
            return .{ .status = 200, .body = output[0..body.len] };
        }
        fn account(_: *anyopaque, request: account_api.TransportRequest, buffer: []u8) account_api.TransportError!account_api.TransportResponse {
            if (request.kind != .refresh_token) return error.ProtocolFailed;
            const body = "{\"access_token\":\"synthetic-image-key-b\",\"refresh_token\":\"synthetic-refresh-key-b\",\"token_type\":\"Bearer\",\"expires_in\":3600}";
            @memcpy(buffer[0..body.len], body);
            return .{ .status = 200, .body = buffer[0..body.len] };
        }
        fn notify(_: *anyopaque) void {}
        fn generate(_: *anyopaque, slot: *[ports.credential_slot_bytes]u8) anyerror!void {
            @memcpy(slot, ports.credential_slot_prefix ++ ("1" ** 32));
        }
        fn store(context: *anyopaque, _: []const u8, key: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (key.len > self.key.len) return error.CapacityReached;
            @memcpy(self.key[0..key.len], key);
            self.key_len = key.len;
        }
        fn get(context: *anyopaque, _: []const u8, output: []u8) anyerror!?[]const u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.key_len == 0) return null;
            @memcpy(output[0..self.key_len], self.key[0..self.key_len]);
            return output[0..self.key_len];
        }
        fn delete(context: *anyopaque, _: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            std.crypto.secureZero(u8, &self.key);
            self.key_len = 0;
        }
        fn vault(self: *@This()) ports.CredentialVault {
            return .{ .context = self, .generate_slot_fn = generate, .store_fn = store, .get_fn = get, .delete_fn = delete };
        }
    };

    const History = @import("lifecycle_fixture").TypedHistory;

    fn configureDialogue(control: *control_api.Runtime, endpoint: []const u8, image_input: bool) !void {
        try std.testing.expect(control.createCustomProviderWithCredential("synthetic-dialogue-key", .{
            .display_name = "Local dialogue fixture",
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
            .model = .{ .id = model, .metadata = .{ .capabilities = .{ .image_input = image_input } } },
        } }).accepted);
        const configured = control.modelsView().custom_providers[0];
        const command: models.CustomModelTestCommand = .{
            .model = .{ .source_id = id, .model_id = model },
            .expected_provider_revision = configured.provider_revision,
            .expected_source_generation = configured.source_generation,
            .expected_catalog_generation = configured.catalog_generation,
        };
        var candidate = switch (control.beginCustomProviderProbe(command)) {
            .ready => |value| value,
            .rejected => return error.TestUnexpectedResult,
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

    fn finish(control: *control_api.Runtime, task_id: u64, id: u64, stop_effects: ?*Effects) !void {
        const task = control.task_runtime.find(task_id).?;
        var answered: ?u64 = null;
        var stopped = false;
        for (0..10000) |_| {
            try control.drainAgentEvents();
            var access = try task.runtime.acquireAccess();
            defer access.deinit();
            if (access.pendingUiObservation()) |request| if (answered != request.request_id) {
                try control.respondUi(task_id, id, request.request_id, .{ .permission = .allow_once });
                answered = request.request_id;
            };
            if (stop_effects) |effects| if (!stopped and effects.image_calls.load(.acquire) != 0 and try effects.serverRecordedImage()) {
                try control.cancel(task_id, id);
                stopped = true;
            };
            if (task.runtime.active_operation == .none and !task.runtime.worker_leases.hasLive()) {
                const run = task_api.testing.state_module.findRun(task.durable.runs, id).?;
                const terminal = task_api.testing.state_module.productTerminalFacts(run) orelse return error.TestUnexpectedResult;
                try std.testing.expectEqual(if (stop_effects != null) task_api.RunOutcome.cancelled else .completed, terminal.outcome);
                try std.testing.expect(run.image_execution == null);
                try std.testing.expect(answered != null);
                return;
            }
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        }
        return error.TestUnexpectedResult;
    }
};

test "GenerateImage canonical Product Run freezes authorization and restores without image authority" {
    try expectCanonicalImageProduct("success", false, true);
}

test "GenerateImage canonical Product preserves JPEG and WebP files and receipts" {
    try expectCanonicalImageProduct("jpeg", false, true);
    try expectCanonicalImageProduct("webp", false, true);
}

test "GenerateImage canonical Product reads a full-size image through Core and restores its receipt without Base64 history" {
    try expectCanonicalImageProduct("read-large", false, true);
}

test "GenerateImage canonical Product stop joins image HTTP and releases its owned preparation" {
    try expectCanonicalImageProduct("hold", false, true);
}

test "GenerateImage canonical Product sends the eligible fallback model when the default is absent" {
    try expectCanonicalImageProduct("success", true, true);
}

test "GenerateImage canonical Product keeps projection authority stable with Custom Provider and logged-in Metask" {
    try expectCanonicalImageProduct("success", false, false);
}

test "GenerateImage canonical Product renews image credentials during Custom Provider approval wait" {
    try expectCanonicalImageProduct("rotated", false, false);
}

fn expectCanonicalImageProduct(mode: []const u8, fallback: bool, logout_after_admission: bool) !void {
    const rotate_after_admission = std.mem.eql(u8, mode, "rotated");
    var h: Harness = undefined;
    try h.init(mode, .{ .timeout_ms = 10000 });
    defer h.deinit();
    // Exercise the ordinary product initializer and production limits. Only
    // per-Run effects use local fixtures; registration has no test override.
    try h.runtime.shutdown();
    h.runtime.deinit();
    h.runtime = try agent.Runtime.init(std.testing.io, std.testing.allocator, .{ .max_sessions = 2 });
    var effects: image_product.Effects = .{ .network = &h.network, .endpoint = h.fixture.endpoint, .trace_dir = h.tmp.dir, .fallback = fallback };
    var account = image_product.account_api.Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId(), .{ .context = &effects, .perform_fn = image_product.Effects.account }, image_product.account_api.TestSupport.loopbackEndpoint(), .{ .context = &effects, .notify_fn = image_product.Effects.notify });
    var platform: image_product.account_api.TestSupport.Platform = .{};
    image_product.account_api.TestSupport.attachPlatform(&account, &platform);
    defer {
        image_product.account_api.TestSupport.detachPlatform(&account);
        account.deinit();
    }
    var authenticated = try image_product.account_api.TestSupport.prepareAuthenticated(&account, "image-account", "Image User", "synthetic-image-key", "synthetic-refresh-key", 1000);
    defer authenticated.deinit();
    account.commit(&authenticated);
    var history = try image_product.task_api.history.FileStore.init(std.testing.io, h.root);
    defer history.deinit();
    var typed_history: image_product.History = .{ .file_store = &history };
    defer typed_history.deinit();
    var checkpoints = try image_product.task_api.checkpoint_store.FileStore.init(std.testing.io, h.root);
    defer checkpoints.deinit();
    var configuration = image_product.fixture_api.productControlConfiguration();
    configuration.task_persistence = typed_history.capability();
    configuration.checkpoint_store = .{ .file_store = &checkpoints };
    configuration.directories.canonical_user_home = h.root;
    var control = try image_product.control_api.Runtime.init(std.testing.allocator, std.testing.io, h.runtime, .{ .worker_count = 1, .queue_capacity = 2, .max_tasks = 1, .max_workspaces = 1, .max_runs_per_task = 4 }, configuration);
    var control_live = true;
    defer if (control_live) control.deinit();
    control.setAccountProjectionCredentials(account.accessTokenProjection());
    try control.startCustomProviders(h.root, effects.vault());
    const large_read = std.mem.eql(u8, mode, "read-large");
    try image_product.configureDialogue(&control, h.fixture.provider_endpoint, large_read);
    var coordinator = image_product.coordinator_api.Coordinator.init(&account, .{ .context = &effects, .perform_fn = image_product.Effects.catalog }, control.modelsManagement(), std.Thread.getCurrentId(), std.testing.io);
    coordinator.setProbeNotifier(.{ .context = &effects, .notify_fn = image_product.Effects.notify });
    coordinator.setCompletionTransport(effects.imageTransport());
    control.setMetaskAuthorizationCheck(coordinator.metaskAuthorizationCheck());
    coordinator.setCredentialRenewal(control.metaskCredentialRenewal());
    var coordinator_live = true;
    defer if (coordinator_live) {
        control.setImageRunPreparation(null);
        coordinator.shutdown();
        coordinator.drain();
    };
    try std.testing.expect(coordinator.refreshCatalog().accepted);
    for (0..5000) |_| {
        coordinator.drain();
        const current = control.modelsView().providers[0];
        if (current.catalog_state == .ready) break;
        if (current.catalog_state != .loading) {
            std.debug.print("image catalog fixture rejected state={s} error={s}\n", .{ @tagName(current.catalog_state), @tagName(current.error_code) });
            return error.TestUnexpectedResult;
        }
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    } else return error.TestUnexpectedResult;
    control.setImageRunPreparation(coordinator.imageRunPreparation());
    const task_id = try control.createTask(.{ .workspace_root = h.root, .trust = .{ .explicitly_trusted = {} }, .approval_mode = .manual });
    for (0..5000) |_| {
        control.syncLifecycle();
        if (control.task_runtime.catalogProjection(task_id).?.availability != .loading) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    {
        var access = try control.task_runtime.find(task_id).?.runtime.acquireAccess();
        defer access.deinit();
        try expectImageDeclaration(h.runtime, access.session.?, large_read, .host);
    }
    try std.testing.expectEqual(.custom_provider, control.execution_state.activeSource().?);
    const projection_epoch = control.projectionSecurityEpoch();
    const first_id = try @import("lifecycle_fixture").runPreparedTask(&control, task_id, .{ .text = "Generate the fixture image." });
    if (!logout_after_admission and !rotate_after_admission) try std.testing.expectEqual(projection_epoch, control.projectionSecurityEpoch());
    const task = control.task_runtime.find(task_id).?;
    try std.testing.expect(task.durable.runs[0].?.image_execution != null);
    // The Core cannot send the image request before manual once approval.
    try std.testing.expectEqual(@as(usize, 0), effects.image_calls.load(.acquire));
    if (logout_after_admission) {
        control.custom_providers.setMetaskAuthorizationUnavailable();
        var logout = image_product.account_api.TestSupport.prepareLoggedOutAfterExternalCommit(&account);
        defer logout.deinit();
        account.commit(&logout);
        coordinator.authorizationChanged();
    }
    if (rotate_after_admission) {
        const scope = account.authorizationState().?.scope;
        var refresh = switch (account.prepareTokenRefresh()) {
            .prepared => |value| value,
            else => return error.TestUnexpectedResult,
        };
        defer refresh.deinit();
        try std.testing.expect(account.admitEffect(&refresh));
        account.commit(&refresh);
        try std.testing.expect(account.dispatchCommitted(&refresh) == null);
        image_product.account_api.TestSupport.joinNetwork(&account);
        var rotated = switch (account.prepareNextCompletion().?) {
            .prepared => |value| value,
            else => return error.TestUnexpectedResult,
        };
        defer rotated.deinit();
        try std.testing.expect(account.admitEffect(&rotated));
        account.commit(&rotated);
        try std.testing.expect(account.dispatchCommitted(&rotated) == null);
        control.commitAccountFactNoFail(account.preparedFact(&rotated));
        control.finishAccountCommitNoFail();
        coordinator.authorizationChanged();
        for (0..5000) |_| {
            coordinator.drain();
            if (coordinator.catalog_job == null) break;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        } else return error.TestUnexpectedResult;
        try std.testing.expectEqual(scope, account.authorizationState().?.scope);
        try std.testing.expectEqualStrings("synthetic-dialogue-key", task.runtime.executionConst().?.secret);
        try std.testing.expectEqual(@as(usize, 1), task.durable.runs[0].?.image_execution.?.credential_versions.items.len);
    }
    const cancelled = std.mem.eql(u8, mode, "hold");
    try image_product.finish(&control, task_id, first_id, if (cancelled) &effects else null);
    if (!logout_after_admission and !rotate_after_admission) try std.testing.expectEqual(projection_epoch, control.projectionSecurityEpoch());
    try std.testing.expect(task.durable.checkpoint != null);
    if (!cancelled) try expectProductGeneratedImagePreview(&control, task_id, first_id);
    try std.testing.expectEqual(@as(usize, 1), effects.image_calls.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), effects.catalog_calls.load(.acquire));
    const trace = try h.trace();
    defer std.testing.allocator.free(trace);
    try std.testing.expectEqual(@as(usize, 1), count(trace, "\"kind\":\"image\""));
    try std.testing.expectEqual(@as(usize, 0), count(trace, "fixture_error"));
    try std.testing.expectEqual(!cancelled, std.mem.indexOf(u8, trace, "\\\"status\\\":\\\"saved\\\"") != null);
    const format: agent.ImageGenerationFormat = if (std.mem.eql(u8, mode, "jpeg")) .jpeg else if (std.mem.eql(u8, mode, "webp")) .webp else .png;
    const expected_path = try std.fs.path.join(std.testing.allocator, &.{ std.fs.path.dirname(options.png_path).?, switch (format) {
        .png => "generated.png",
        .jpeg => "generated.jpg",
        .webp => "generated.webp",
    } });
    defer std.testing.allocator.free(expected_path);
    const expected_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, expected_path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(expected_bytes);
    var media_needle: [80]u8 = undefined;
    if (!cancelled) try std.testing.expect(std.mem.indexOf(u8, trace, try std.fmt.bufPrint(&media_needle, "\\\"media_type\\\":\\\"{s}\\\"", .{format.mediaType()})) != null);
    const directory: ?std.Io.Dir = h.tmp.dir.openDir(std.testing.io, "generated-images", .{ .iterate = true }) catch |err| if (cancelled and err == error.FileNotFound) null else return err;
    var files: usize = 0;
    if (directory) |dir| {
        defer dir.close(std.testing.io);
        var entries = dir.iterate();
        while (try entries.next(std.testing.io)) |entry| {
            const bytes = try dir.readFileAlloc(std.testing.io, entry.name, std.testing.allocator, .limited(agent.multimodal_input_limits.max_image_raw_bytes + 1));
            defer std.testing.allocator.free(bytes);
            if (large_read) {
                try std.testing.expectEqual(agent.multimodal_input_limits.max_image_raw_bytes, bytes.len);
                try std.testing.expect(std.mem.startsWith(u8, bytes, expected_bytes[0 .. expected_bytes.len - 12]));
                try std.testing.expect(std.mem.endsWith(u8, bytes, expected_bytes[expected_bytes.len - 12 ..]));
            } else try std.testing.expectEqualSlices(u8, expected_bytes, bytes);
            var extension: [8]u8 = undefined;
            try std.testing.expect(std.mem.endsWith(u8, entry.name, try std.fmt.bufPrint(&extension, ".{s}", .{format.extension()})));
            files += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, if (cancelled) 0 else 1), files);
    var snapshot: [256 * 1024]u8 = undefined;
    const encoded = try control.writeAggregateFixture(&snapshot);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "synthetic-image-key") == null);
    if (large_read) {
        try std.testing.expectEqual(@as(usize, 1), count(trace, "\"kind\":\"model_image\""));
        const run = task.durable.runs[0].?;
        var read_seen = false;
        for (run.tools) |entry| if (entry) |tool| {
            if (!std.mem.eql(u8, tool.name, "Read")) continue;
            try std.testing.expectEqualStrings("[Image read: image/png]", tool.content);
            try std.testing.expectEqual(image_product.task_api.testing.state_module.ToolState.completed, tool.state);
            try std.testing.expect(!tool.content_truncated);
            read_seen = true;
        };
        try std.testing.expect(read_seen);
        try std.testing.expect(std.mem.indexOf(u8, encoded, "iVBORw0KGgo") == null);
    }
    try std.testing.expectEqual(@as(usize, 0), h.runtime.image_budget.used.load(.acquire));
    try std.testing.expectEqual(h.runtime.image_results_created.load(.acquire), h.runtime.image_results_released.load(.acquire));
    // Restart Product from its real history and opaque canonical checkpoint.
    // This exercises the same fixed tool set; legacy tool-set migration is
    // covered separately by the canonical checkpoint tests above.
    control.setImageRunPreparation(null);
    coordinator.shutdown();
    coordinator.drain();
    coordinator_live = false;
    control.shutdownExecutor();
    try control.drainAgentEvents();
    control.deinit();
    control_live = false;
    const restored = (try history.loadAlloc(std.testing.allocator)).?;
    defer std.testing.allocator.free(restored);
    try std.testing.expect(std.mem.indexOf(u8, restored, "synthetic-image-key") == null);
    try std.testing.expect(std.mem.indexOf(u8, restored, "image_execution") == null);
    typed_history.fixture_restore = restored;
    control = try image_product.control_api.Runtime.init(std.testing.allocator, std.testing.io, h.runtime, .{ .worker_count = 1, .queue_capacity = 2, .max_tasks = 1, .max_workspaces = 1, .max_runs_per_task = 4 }, configuration);
    control_live = true;
    control.setAccountProjectionCredentials(account.accessTokenProjection());
    try control.startCustomProviders(h.root, effects.vault());
    coordinator = image_product.coordinator_api.Coordinator.init(&account, .{ .context = &effects, .perform_fn = image_product.Effects.catalog }, control.modelsManagement(), std.Thread.getCurrentId(), std.testing.io);
    coordinator.setCompletionTransport(effects.imageTransport());
    coordinator_live = true;
    control.setImageRunPreparation(coordinator.imageRunPreparation());
    const recovered = control.task_runtime.find(task_id).?;
    try std.testing.expect(!recovered.runtime.hasAttachedSession());
    try std.testing.expect(recovered.durable.runs[0].?.image_execution == null);
    _ = try control.restoreTaskConversation(task_id, recovered.durable.binding_epoch);
    for (0..10000) |_| {
        try control.drainAgentEvents();
        if (recovered.runtime.restore_job == null and !recovered.runtime.worker_leases.hasLive()) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    } else return error.TestUnexpectedResult;
    if (recovered.runtime.last_restore_failure) |failure| std.debug.print("image Product restore failed: {s}\n", .{@tagName(failure)});
    try std.testing.expect(recovered.runtime.last_restore_failure == null);
    try std.testing.expect(recovered.runtime.hasAttachedSession());
    if (!cancelled) try expectProductGeneratedImagePreview(&control, task_id, first_id);
    {
        var access = try recovered.runtime.acquireAccess();
        defer access.deinit();
        try expectImageDeclaration(h.runtime, access.session.?, large_read, .host);
    }
    const second_id = try @import("lifecycle_fixture").runPreparedTask(&control, task_id, .{ .text = "Generate the fixture image." });
    try std.testing.expect(recovered.durable.runs[1].?.image_execution == null);
    try image_product.finish(&control, task_id, second_id, null);
    try std.testing.expectEqual(@as(usize, 1), effects.image_calls.load(.acquire));
    const final_trace = try h.trace();
    defer std.testing.allocator.free(final_trace);
    try std.testing.expectEqual(@as(usize, 0), count(final_trace, "fixture_error"));
    try std.testing.expect(std.mem.indexOf(u8, final_trace, "unavailable") != null);
    try std.testing.expectEqual(@as(usize, 0), h.runtime.image_budget.used.load(.acquire));
    try std.testing.expectEqual(h.runtime.image_results_created.load(.acquire), h.runtime.image_results_released.load(.acquire));
}

fn expectImageDeclaration(runtime: *agent.Runtime, session: *agent.Session, supported: bool, source: sdk.protocol.ImageInputSource) !void {
    var encoded = std.mem.zeroes(sdk.types.OwnedBytesV1);
    defer if (encoded.ptr != null) runtime.api.bufferRelease()(&encoded);
    var diagnostic = std.mem.zeroes(sdk.types.OwnedBytesV1);
    defer if (diagnostic.ptr != null) runtime.api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(sdk.types.STATUS_OK, runtime.api.sessionControl().describe()(session.raw, &encoded, &diagnostic));
    var parsed = try sdk.decodeSessionDescription(std.testing.allocator, try sdk.borrowedBytes(.{ .ptr = encoded.ptr, .len = encoded.len }));
    defer parsed.deinit();
    try std.testing.expectEqual(supported, parsed.value.image_input.supported);
    try std.testing.expectEqual(source, parsed.value.image_input.source);
}

test "model image declarations reach canonical Core create restore and set_model without a provider call" {
    var h: Harness = undefined;
    try h.init("success", .{});
    defer h.deinit();
    var declarations = [_]agent.ModelImageCapability{
        .{ .model = "glm-5.3-flash", .supported = true },
        .{ .model = "gpt-4o", .supported = false },
    };
    var options_value = openOptions(h.root, &h.fixture, .full_access);
    options_value.model_binding.target.model = "glm-5.3-flash";
    options_value.model_binding.image_capabilities = &declarations;
    const session = try h.runtime.createSession(options_value);
    // Core must own the borrowed declarations before this call returns.
    declarations[0].supported = false;
    try expectImageDeclaration(h.runtime, session, true, .host);
    try session.setModel("gpt-4o");
    try expectImageDeclaration(h.runtime, session, false, .host);
    try session.setModel("glm-5.3-flash");
    try expectImageDeclaration(h.runtime, session, true, .host);
    const limits: agent.CheckpointLimits = .{ .hard_bytes = 1024 * 1024, .max_section_bytes = 1024 * 1024, .max_string_bytes = 512 * 1024, .max_messages = 128, .max_blocks_per_message = 128, .chunk_bytes = 64 * 1024 };
    var bytes: RestoreBytes = .{};
    defer bytes.bytes.deinit(std.testing.allocator);
    var exported = try session.exportCheckpoint(limits, .{ .context = &bytes, .write_fn = RestoreBytes.write }, 0, 0, "glm-5.3-flash");
    defer exported.deinit();
    const checkpoint = switch (exported) {
        .success => |value| value,
        .failure => return error.TestUnexpectedResult,
    };
    try session.close(.session_close);
    try h.runtime.releaseClosedSession(session);
    declarations[1].supported = true;
    const restored = try h.runtime.restoreSessionRoute(.{
        .session = options_value,
        .checkpoint_limits = limits,
        .source = .{ .context = &bytes, .read_fn = RestoreBytes.read },
        .expectation = .{ .logical_session_id = checkpoint.description.session_id, .checkpoint_generation = checkpoint.checkpoint.generation, .last_run_id = 0, .last_compact_id = 0, .model = "glm-5.3-flash" },
    });
    try std.testing.expectEqual(agent.CheckpointRestoreHealth.complete, restored.report.health);
    // Restore uses current Host facts rather than the checkpoint's old facts.
    try expectImageDeclaration(h.runtime, restored.session, false, .host);
    try restored.session.setModel("gpt-4o");
    try expectImageDeclaration(h.runtime, restored.session, true, .host);
    options_value.model_binding.target.model = "metawork-unknown-vision-model";
    options_value.model_binding.image_capabilities = &.{};
    const unknown = try h.runtime.createSession(options_value);
    try expectImageDeclaration(h.runtime, unknown, false, .unknown);
    // The fixture creates its trace only when a request arrives.
    try std.testing.expectError(error.FileNotFound, h.trace());
}

fn expectProductGeneratedImagePreview(control: *image_product.control_api.Runtime, task_id: u64, run_id: u64) !void {
    const task = control.task_runtime.find(task_id).?;
    var reference: ?[]const u8 = null;
    for (task.durable.runs[0].?.tools) |entry| {
        const tool = entry orelse continue;
        if (tool.file_refs) |refs| for (refs) |item| {
            const ref = item orelse continue;
            if (ref.generated_image) reference = ref.id;
        };
    }
    try std.testing.expect(reference != null);
    const Capture = struct {
        calls: usize = 0,
        state: image_product.control_api.FilePreviewState = .failed,
        image_len: usize = 0,
        image_id: u64 = 0,
        fn receive(context: *anyopaque, result: image_product.control_api.FilePreviewResult) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            self.state = result.state;
            std.debug.assert(result.content.len == 0 and !result.truncated and !result.redacted);
            if (result.image) |image| {
                self.image_len = image.size_bytes;
                self.image_id = image.id;
            }
        }
    };
    var capture: Capture = .{};
    switch (control.beginFilePreview(77, task_id, run_id, reference.?)) {
        .queued => {},
        .immediate => return error.TestUnexpectedResult,
    }
    for (0..5000) |_| {
        control.drainFilePreviewCompletions(.{ .context = &capture, .complete_fn = Capture.receive });
        if (capture.calls != 0) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqual(image_product.control_api.FilePreviewState.ready, capture.state);
    try std.testing.expect(capture.image_len > 0);
    const chunk = try control.readFilePreviewImage(capture.image_id, 0);
    try std.testing.expect(chunk.len > 0);
    try std.testing.expect(control.releaseFilePreview(capture.image_id));
    var snapshot: [256 * 1024]u8 = undefined;
    const json = try control.writeAggregateFixture(&snapshot);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"generatedImage\":true") != null);
}

test "DeliverFile previous GenerateImage-only checkpoints restore without recreating file authority" {
    try checkpointTools(1, false, false);
    try checkpointTools(1, true, false);
}

const DeliveryReader = struct {
    root: []const u8,
    main_thread_id: std.Thread.Id,
    entered: std.atomic.Value(bool) = .init(false),
    hold: bool = false,

    fn input(self: *@This()) agent.FileDeliveryInput {
        return .{ .context = self, .inspect_fn = inspect };
    }
    fn inspect(context: *anyopaque, path: []const u8, cancelled: *const std.atomic.Value(bool)) agent.FileDeliveryInspection {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.entered.store(true, .release);
        if (self.hold) {
            while (!cancelled.load(.acquire)) std.Thread.yield() catch {};
            return .{ .failed = .cancelled };
        }
        const value = @import("app_output_file").inspect(std.testing.io, .{ .workspace_root = self.root, .relative_path = path, .main_thread_id = self.main_thread_id }, cancelled) catch |err| return .{ .failed = switch (err) {
            error.FileNotFound => .missing,
            error.Cancelled => .cancelled,
            else => .read_failed,
        } };
        return .{ .verified = .{ .size_bytes = value.size_bytes, .sha256 = value.sha256 } };
    }
};

test "DeliverFile canonical Core checks actual Workspace bytes and sends one trusted receipt to Product ingress" {
    var h: Harness = undefined;
    try h.init("delivery", .{});
    defer h.deinit();
    const session = try h.session(.full_access, false);
    const content = "verified document bytes";
    const file = try h.tmp.dir.createFile(std.testing.io, "result.docx", .{});
    try file.writeStreamingAll(std.testing.io, content);
    file.close(std.testing.io);
    var reader: DeliveryReader = .{ .root = h.root, .main_thread_id = std.Thread.getCurrentId() };
    for (0..3) |index| {
        if (index == 2) try h.tmp.dir.deleteFile(std.testing.io, "result.docx");
        const id = try session.prepareRunWithTools(.{ .text = "Explicitly deliver the fixture file." }, null, if (index == 1) null else reader.input());
        var work: Work = .{ .session = session, .id = id };
        const thread = try std.Thread.spawn(.{}, Work.run, .{&work});
        thread.join();
        defer work.result.?.deinit();
        try std.testing.expectEqual(@as(?agent.TerminalFailure, null), work.result.?.failure);
        var records: usize = 0;
        var results: usize = 0;
        while (h.runtime.takeEvent()) |value| {
            var event = value;
            defer event.deinit();
            if (event.delivered_file) |receipt| {
                records += 1;
                try std.testing.expectEqual(id, event.run_id);
                try std.testing.expectEqualStrings("result.docx", receipt.pathView());
                try std.testing.expectEqual(content.len, receipt.size_bytes);
                var expected: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(content, &expected, .{});
                try std.testing.expectEqualSlices(u8, &expected, &receipt.sha256);
                try std.testing.expect(std.mem.indexOf(u8, event.json, "delivered_file") == null);
            }
            if (event.event.value == .known and event.event.value.known == .tool_result and
                std.mem.eql(u8, event.event.value.known.tool_result.name, "DeliverFile"))
            {
                results += 1;
                const result = event.event.value.known.tool_result;
                try std.testing.expectEqual(index != 0, result.is_error);
                try std.testing.expect(std.mem.indexOf(u8, result.content, switch (index) {
                    0 => "verified_for_delivery",
                    1 => "unavailable",
                    else => "missing",
                }) != null);
            }
        }
        try std.testing.expectEqual(@as(usize, if (index == 0) 1 else 0), records);
        try std.testing.expectEqual(@as(usize, 1), results);
        try std.testing.expect(session.run_delivery == null);
        try std.testing.expectEqual(@as(usize, 0), h.runtime.delivery_results_outstanding.load(.acquire));
    }
}

test "DeliverFile canonical Core cancellation joins file callbacks on stop close and shutdown" {
    for (0..3) |action| {
        var h: Harness = undefined;
        try h.init("delivery", .{});
        defer h.deinit();
        const session = try h.session(.full_access, false);
        var reader: DeliveryReader = .{ .root = h.root, .main_thread_id = std.Thread.getCurrentId(), .hold = true };
        const id = try session.prepareRunWithTools(.{ .text = "Explicitly deliver the fixture file." }, null, reader.input());
        var work: Work = .{ .session = session, .id = id };
        const thread = try std.Thread.spawn(.{}, Work.run, .{&work});
        defer {
            if (!work.done.load(.acquire)) _ = session.requestTermination(id, .{ .interrupted = .user_cancel }) catch {};
            thread.join();
            if (work.result) |*result| result.deinit();
        }
        for (0..20_000) |_| {
            if (reader.entered.load(.acquire) or work.done.load(.acquire)) break;
            std.testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
        }
        try std.testing.expect(reader.entered.load(.acquire));
        switch (action) {
            0 => _ = try session.requestTermination(id, .{ .interrupted = .user_cancel }),
            1 => try session.close(.session_close),
            else => try h.runtime.shutdown(),
        }
        for (0..20_000) |_| {
            if (work.done.load(.acquire)) break;
            std.testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
        }
        try std.testing.expect(work.done.load(.acquire));
        try std.testing.expect(session.run_delivery == null);
        for (session.delivery_calls) |call| try std.testing.expect(call == null);
        for (session.delivery_receipts) |receipt| try std.testing.expect(receipt == null);
        while (h.runtime.takeEvent()) |value| {
            var event = value;
            defer event.deinit();
            try std.testing.expect(event.delivered_file == null);
        }
        try std.testing.expectEqual(@as(usize, 0), h.runtime.delivery_results_outstanding.load(.acquire));
    }
}

test "DeliverFile canonical Core approval gates file reads and refuses Session grants" {
    for ([_]agent.PermissionChoice{ .allow_once, .deny_once }) |choice| {
        var h: Harness = undefined;
        try h.init("delivery", .{});
        defer h.deinit();
        const session = try h.session(.accept_edits, false);
        const file = try h.tmp.dir.createFile(std.testing.io, "result.docx", .{});
        try file.writeStreamingAll(std.testing.io, "approved bytes");
        file.close(std.testing.io);
        var reader: DeliveryReader = .{ .root = h.root, .main_thread_id = std.Thread.getCurrentId() };
        const id = try session.prepareRunWithTools(.{ .text = "Explicitly deliver the fixture file." }, null, reader.input());
        var work: Work = .{ .session = session, .id = id };
        const thread = try std.Thread.spawn(.{}, Work.run, .{&work});
        defer {
            if (!work.done.load(.acquire)) _ = session.requestTermination(id, .{ .interrupted = .user_cancel }) catch {};
            thread.join();
            if (work.result) |*result| result.deinit();
        }
        var previous: ?u64 = null;
        var answers: usize = 0;
        for (0..20_000) |_| {
            if (work.done.load(.acquire)) break;
            if (session.pendingUiRequest()) |request| if (previous == null or previous.? != request) {
                try std.testing.expect(!reader.entered.load(.acquire));
                try std.testing.expectError(error.InvalidUiResponse, session.respondPermission(id, request, .allow_session));
                try session.respondPermission(id, request, choice);
                previous = request;
                answers += 1;
            };
            std.testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
        }
        try std.testing.expect(work.done.load(.acquire));
        try std.testing.expectEqual(@as(usize, 1), answers);
        try std.testing.expectEqual(choice == .allow_once, reader.entered.load(.acquire));
        var receipts: usize = 0;
        while (h.runtime.takeEvent()) |value| {
            var event = value;
            defer event.deinit();
            if (event.delivered_file != null) receipts += 1;
        }
        try std.testing.expectEqual(@as(usize, if (choice == .allow_once) 1 else 0), receipts);
    }
}

const ProductDeliveryEffect = struct {
    reader: DeliveryReader,
    released: usize = 0,
    fn prepare(context: *anyopaque, authority: image_product.fixture_api.product_workspace.TaskAuthority) ?image_product.task_api.OwnedFileDelivery {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, self.reader.root, authority.canonical_root)) return null;
        return .{ .input = .{ .context = self, .inspect_fn = inspect }, .release_fn = release };
    }
    fn inspect(context: *anyopaque, path: []const u8, cancelled: *const std.atomic.Value(bool)) agent.FileDeliveryInspection {
        const self: *@This() = @ptrCast(@alignCast(context));
        return DeliveryReader.inspect(&self.reader, path, cancelled);
    }
    fn release(context: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.released += 1;
    }
};

test "DeliverFile canonical Product registers real Core receipt and restores its metadata from actual history" {
    var h: Harness = undefined;
    try h.init("delivery", .{});
    defer h.deinit();
    try h.runtime.shutdown();
    h.runtime.deinit();
    h.runtime = try agent.Runtime.init(std.testing.io, std.testing.allocator, .{ .max_sessions = 2 });
    const content = "explicit delivered file bytes";
    const file = try h.tmp.dir.createFile(std.testing.io, "result.docx", .{});
    try file.writeStreamingAll(std.testing.io, content);
    file.close(std.testing.io);
    var history = try image_product.task_api.history.FileStore.init(std.testing.io, h.root);
    defer history.deinit();
    var typed_history: image_product.History = .{ .file_store = &history };
    defer typed_history.deinit();
    var checkpoints = try image_product.task_api.checkpoint_store.FileStore.init(std.testing.io, h.root);
    defer checkpoints.deinit();
    var configuration = image_product.fixture_api.productControlConfiguration();
    configuration.task_persistence = typed_history.capability();
    configuration.checkpoint_store = .{ .file_store = &checkpoints };
    configuration.directories.canonical_user_home = h.root;
    const limits: image_product.control_api.Limits = .{ .worker_count = 1, .queue_capacity = 2, .max_tasks = 1, .max_workspaces = 1, .max_runs_per_task = 4 };
    var control = try image_product.control_api.Runtime.init(std.testing.allocator, std.testing.io, h.runtime, limits, configuration);
    var control_live = true;
    defer if (control_live) {
        control.stopCustomProviders();
        control.deinit();
    };
    var effects: image_product.Effects = .{ .network = &h.network, .endpoint = h.fixture.endpoint, .trace_dir = h.tmp.dir };
    try control.startCustomProviders(h.root, effects.vault());
    try image_product.configureDialogue(&control, h.fixture.provider_endpoint, false);
    var delivery: ProductDeliveryEffect = .{ .reader = .{ .root = h.root, .main_thread_id = std.Thread.getCurrentId() } };
    control.setFileDeliveryPreparation(.{ .context = &delivery, .prepare_fn = ProductDeliveryEffect.prepare });
    const task_id = try control.createTask(.{ .workspace_root = h.root, .trust = .{ .explicitly_trusted = {} }, .approval_mode = .manual });
    for (0..5000) |_| {
        control.syncLifecycle();
        if (control.task_runtime.catalogProjection(task_id).?.availability != .loading) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    const id = try @import("lifecycle_fixture").runPreparedTask(&control, task_id, .{ .text = "Explicitly deliver the finished file." });
    try image_product.finish(&control, task_id, id, null);
    const task = control.task_runtime.find(task_id).?;
    const run = &task.durable.runs[0].?;
    try std.testing.expectEqualStrings("result.docx", run.outputs[0].?.locator);
    try std.testing.expectEqual(content.len, run.outputs[0].?.size_bytes);
    const receipt_id = run.outputs[0].?.id;
    const digest = run.outputs[0].?.sha256;
    var expected: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(content, &expected, .{});
    try std.testing.expectEqualSlices(u8, &expected, &digest);
    try std.testing.expect(run.outputs[1] == null);
    try std.testing.expect(run.file_delivery == null);
    try std.testing.expectEqual(@as(usize, 1), delivery.released);
    try std.testing.expect(task.durable.checkpoint != null);
    control.setFileDeliveryPreparation(null);
    control.stopCustomProviders();
    control.shutdownExecutor();
    try control.drainAgentEvents();
    control.deinit();
    control_live = false;
    const saved = (try history.loadAlloc(std.testing.allocator)).?;
    defer std.testing.allocator.free(saved);
    try std.testing.expect(std.mem.indexOf(u8, saved, "file_delivery") == null);
    typed_history.fixture_restore = saved;
    control = try image_product.control_api.Runtime.init(std.testing.allocator, std.testing.io, h.runtime, limits, configuration);
    control_live = true;
    const restored = control.task_runtime.find(task_id).?;
    try std.testing.expect(!restored.runtime.hasAttachedSession());
    const recovered = &restored.durable.runs[0].?;
    try std.testing.expect(recovered.file_delivery == null);
    try std.testing.expectEqualStrings("result.docx", recovered.outputs[0].?.locator);
    try std.testing.expectEqualSlices(u8, &receipt_id, &recovered.outputs[0].?.id);
    try std.testing.expectEqualSlices(u8, &digest, &recovered.outputs[0].?.sha256);
    try std.testing.expectEqual(@as(usize, 0), h.runtime.delivery_results_outstanding.load(.acquire));
}

test "Session pressure canonical Product preserves checkpoint history with one live Session" {
    var h: Harness = undefined;
    try h.init("delivery", .{});
    defer h.deinit();
    try h.runtime.shutdown();
    h.runtime.deinit();
    h.runtime = try agent.Runtime.init(std.testing.io, std.testing.allocator, .{ .max_sessions = 1 });
    const file = try h.tmp.dir.createFile(std.testing.io, "result.docx", .{});
    try file.writeStreamingAll(std.testing.io, "session pressure receipt");
    file.close(std.testing.io);
    var history = try image_product.task_api.history.FileStore.init(std.testing.io, h.root);
    defer history.deinit();
    var typed_history: image_product.History = .{ .file_store = &history };
    defer typed_history.deinit();
    var checkpoints = try image_product.task_api.checkpoint_store.FileStore.init(std.testing.io, h.root);
    defer checkpoints.deinit();
    var configuration = image_product.fixture_api.productControlConfiguration();
    configuration.task_persistence = typed_history.capability();
    configuration.checkpoint_store = .{ .file_store = &checkpoints };
    configuration.directories.canonical_user_home = h.root;
    var control = try image_product.control_api.Runtime.init(std.testing.allocator, std.testing.io, h.runtime, .{ .worker_count = 1, .queue_capacity = 2, .max_tasks = 3, .max_workspaces = 1, .max_runs_per_task = 4 }, configuration);
    defer {
        control.stopCustomProviders();
        control.deinit();
    }
    var effects: image_product.Effects = .{ .network = &h.network, .endpoint = h.fixture.endpoint, .trace_dir = h.tmp.dir };
    try control.startCustomProviders(h.root, effects.vault());
    try image_product.configureDialogue(&control, h.fixture.provider_endpoint, false);
    var delivery: ProductDeliveryEffect = .{ .reader = .{ .root = h.root, .main_thread_id = std.Thread.getCurrentId() } };
    control.setFileDeliveryPreparation(.{ .context = &delivery, .prepare_fn = ProductDeliveryEffect.prepare });
    const input: image_product.control_api.TaskCreateInput = .{ .workspace_root = h.root, .trust = .{ .explicitly_trusted = {} }, .approval_mode = .manual };
    const initial_search = control.task_runtime.searchRevision();
    const first = try control.createTask(input);
    try std.testing.expect(control.task_runtime.searchRevision() > initial_search);
    for (0..5000) |_| {
        control.syncLifecycle();
        if (control.task_runtime.catalogProjection(first).?.availability != .loading) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    } else return error.TestUnexpectedResult;
    const before_run_search = control.task_runtime.searchRevision();
    const run_id = try @import("lifecycle_fixture").runPreparedTask(&control, first, .{ .text = "Deliver the finished file before releasing this Session." });
    try std.testing.expect(control.task_runtime.searchRevision() > before_run_search);
    const streaming_search = control.task_runtime.searchRevision();
    try image_product.finish(&control, first, run_id, null);
    try std.testing.expect(control.task_runtime.searchRevision() > streaming_search);
    const task = control.task_runtime.find(first).?;
    for (0..5000) |_| {
        control.syncLifecycle();
        if (task.durable.runs[0].?.execution == null) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    } else return error.TestUnexpectedResult;
    const receipt = task.durable.runs[0].?.outputs[0].?.id;
    const old_epoch = task.durable.binding_epoch;
    const before_close_search = control.task_runtime.searchRevision();
    try std.testing.expectError(error.SessionReleasing, control.createTask(input));
    for (0..5000) |_| {
        control.syncLifecycle();
        if (task.runtime.attachment == .detached) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    } else return error.TestUnexpectedResult;
    try std.testing.expect(task.runtime.parked_capabilities != null);
    try std.testing.expectEqual(before_close_search, control.task_runtime.searchRevision());
    const second = try control.createTask(input);
    for (0..5000) |_| {
        control.syncLifecycle();
        if (control.task_runtime.catalogProjection(second).?.availability != .loading) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    } else return error.TestUnexpectedResult;
    // Actual UI resume path: accepted input fails visibly while capacity is released.
    const accepted = try control.sendInput("pressure-send", first, .{ .text = "Keep my draft" });
    try std.testing.expectEqual(.accepted, accepted.outcome);
    const failed = task.input_submissions.items[0];
    try std.testing.expectEqual(.failed, failed.state);
    try std.testing.expectEqual(.session_releasing, failed.reason.?);
    try std.testing.expect(failed.blocking_task_id == null);
    try std.testing.expect(failed.payload == null);
    for (0..5000) |_| {
        control.syncLifecycle();
        if (control.task_runtime.find(second).?.runtime.attachment == .detached) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    } else return error.TestUnexpectedResult;
    // Closing the other Session must not replay the failed message.
    try std.testing.expect(task.durable.runs[1] == null);
    _ = try control.restoreTaskConversation(first, old_epoch);
    for (0..5000) |_| {
        control.syncLifecycle();
        if (task.runtime.restore_job == null) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    } else return error.TestUnexpectedResult;
    try std.testing.expect(task.runtime.hasAttachedSession());
    try std.testing.expect(task.runtime.last_restore_failure == null);
    try std.testing.expect(task.runtime.parked_capabilities == null);
    try std.testing.expect(task.runtime.last_restore_report != null);
    try std.testing.expectEqualSlices(u8, &receipt, &task.durable.runs[0].?.outputs[0].?.id);
    try std.testing.expectEqual(run_id, task.durable.runs[0].?.id);
    try std.testing.expect(control.task_runtime.find(second) != null);
    try std.testing.expect(task.durable.checkpoint != null);
}
