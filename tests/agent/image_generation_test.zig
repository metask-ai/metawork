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
}

test "GenerateImage canonical Core writes PNG and model consumes exact receipt" {
    try successful("success", 1);
}
