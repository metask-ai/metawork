const std = @import("std");
const agent = @import("metawork_agent");
const backend = @import("image_http_backend");
const options = @import("image_fixture_options");

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

    fn output(self: *Sink) agent.ImageGenerationOutput {
        return .{ .context = self, .commit_fn = commit };
    }
    fn commit(context: *anyopaque, bytes: []const u8, cancellation: *const agent.CompletionCancellation) !agent.ImageGenerationReceipt {
        const self: *Sink = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(std.testing.io);
        defer self.mutex.unlock(std.testing.io);
        self.attempts += 1;
        var name_storage: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_storage, "image-{d}.png", .{if (self.force_conflict) @as(usize, 1) else self.attempts});
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
    return runtime.createSession(.{
        .model_binding = .{ .target = .{ .provider_id = "fixture", .protocol = .anthropic_messages, .base_url = fixture.provider_endpoint, .model = "claude-sonnet-4-20250514" }, .credential = "synthetic-dialogue-key" },
        .permission_mode = mode,
        .shell_policy = .unrestricted,
        .workspace = .{ .canonical_root = root, .trust = .explicitly_trusted },
        .canonical_user_home = root,
    });
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
    var work: Work = .{ .session = session, .id = try session.prepareRun(.{ .text = "Generate the fixture image." }) };
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
        while (h.runtime.takeEvent()) |event_value| {
            var event = event_value;
            event.deinit();
        }
        if (work.done.load(.acquire)) break;
        if (session.pendingUiRequest()) |request| if (previous == null or previous.? != request) {
            // Host tools have no stable session grant candidate.
            try std.testing.expectError(error.InvalidUiResponse, session.respondPermission(work.id, request, .allow_session));
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

test "GenerateImage identical prompts are separate requests and concurrent calls overlap" {
    try successful("repeat", 2);
    try successful("concurrent", 2);
    try successful("prompt-url", 1);
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
    const second = try h.session(.full_access, false);
    try h.tmp.dir.createDir(std.testing.io, "second", .default_dir);
    var second_dir = try h.tmp.dir.openDir(std.testing.io, "second", .{});
    defer second_dir.close(std.testing.io);
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
