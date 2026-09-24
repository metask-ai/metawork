//! Real Host acceptance. Driven by run-agentcore-provider-test.mjs --staged --host.
const std = @import("std");
const agent = @import("metawork_agent");

const Checkpoint = struct {
    bytes: []u8,
    len: usize = 0,
    offset: usize = 0,

    fn write(ctx: ?*anyopaque, bytes: []const u8) agent.CheckpointSinkWriteResult {
        const self: *Checkpoint = @ptrCast(@alignCast(ctx.?));
        if (bytes.len > self.bytes.len - self.len) return .io_failed;
        @memcpy(self.bytes[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
        return .ok;
    }

    fn read(ctx: ?*anyopaque, destination: []u8) agent.CheckpointSourceReadResult {
        const self: *Checkpoint = @ptrCast(@alignCast(ctx.?));
        const count = @min(self.len - self.offset, destination.len);
        if (count == 0) return .eof;
        @memcpy(destination[0..count], self.bytes[self.offset..][0..count]);
        self.offset += count;
        return .{ .bytes = count };
    }
};

fn execute(session: *agent.Session, input: agent.RunInput) !agent.TerminalResult {
    const id = try session.prepareRun(input);
    var run = try session.beginRun(id);
    defer run.deinit();
    return run.execute();
}

fn success(runtime: *agent.Runtime, session: *agent.Session, input: agent.RunInput) !u64 {
    const id = try session.prepareRun(input);
    var run = try session.beginRun(id);
    defer run.deinit();
    var result = run.execute();
    defer result.deinit();
    if (result.failure != null or result.abi_status != .ok or result.stop_reason != .end_turn) {
        std.debug.print("Host Run failed: status={any}, stop={any}, failure={any}\n", .{ result.abi_status, result.stop_reason, result.failure });
        return error.HostRunFailed;
    }
    var events: usize = 0;
    while (runtime.takeEvent()) |event| {
        var owned = event;
        owned.deinit();
        events += 1;
    }
    if (events == 0) return error.MissingHostEvents;
    return id;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();
    _ = args.skip();
    const provider = args.next() orelse return error.MissingProvider;
    const endpoint = args.next() orelse return error.MissingEndpoint;
    const key = args.next() orelse return error.MissingFixtureKey;
    const model = args.next() orelse return error.MissingModel;
    const fixture_root = args.next() orelse return error.MissingFixtureDirectory;
    if (args.next() != null) return error.UnexpectedArgument;
    const protocol: agent.Protocol = if (std.mem.eql(u8, provider, "responses")) .openai_responses else if (std.mem.eql(u8, provider, "anthropic")) .anthropic_messages else if (std.mem.eql(u8, provider, "openai")) .openai_chat_completions else if (std.mem.eql(u8, provider, "gemini")) .gemini_native else return error.UnknownProvider;
    var dir = try std.Io.Dir.openDirAbsolute(init.io, fixture_root, .{});
    defer dir.close(init.io);
    const png = try dir.readFileAlloc(init.io, "image.png", allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(png);
    const gif = try dir.readFileAlloc(init.io, "image.gif", allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(gif);
    const large_png = try dir.readFileAlloc(init.io, "large.png", allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(large_png);
    const runtime = try agent.Runtime.init(init.io, allocator, .{ .max_sessions = 1 });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    const options = agent.SessionOpenOptions{
        .model_binding = .{
            .target = .{
                .provider_id = "local-multimodal-acceptance",
                .protocol = protocol,
                .model = model,
                .base_url = endpoint,
            },
            .credential = key,
        },
        .permission_mode = .default,
        // Match MetaWork's fixed builtin set, which includes shell tools.
        // The deterministic provider fixture never requests a tool call.
        .shell_policy = .unrestricted,
        .workspace = .{ .canonical_root = fixture_root, .trust = .explicitly_trusted },
        .canonical_user_home = fixture_root,
    };
    const session = try runtime.createSession(options);
    _ = try success(runtime, session, .{ .text = "Reply with one short sentence." });
    _ = try success(runtime, session, .{ .multimodal = &.{
        .{ .text = "First image." },
        .{ .image = .{ .format = .png, .bytes = png } },
        .{ .text = "Second image." },
        .{ .image = .{ .format = .gif, .bytes = gif } },
    } });
    _ = try success(runtime, session, .{ .text = "Continue with the images." });
    const last_run = try success(runtime, session, .{ .multimodal = &.{.{ .image = .{ .format = .png, .bytes = large_png } }} });

    var checkpoint = Checkpoint{ .bytes = try allocator.alloc(u8, 16 * 1024 * 1024) };
    defer allocator.free(checkpoint.bytes);
    var limits = agent.CheckpointLimits{
        .hard_bytes = checkpoint.bytes.len,
        .max_section_bytes = checkpoint.bytes.len,
        .max_string_bytes = 1024 * 1024,
        .max_messages = 4096,
        .max_blocks_per_message = 256,
        .chunk_bytes = 256 * 1024,
    };
    const sink = agent.CheckpointSink{ .context = &checkpoint, .write_fn = Checkpoint.write };
    var limited = try session.exportCheckpoint(limits, sink, last_run, 0, model);
    defer limited.deinit();
    if (limited != .failure or limited.failure.reason != .resource_limit or checkpoint.len != 0)
        return error.ExpectedCheckpointResourceLimit;
    if (session.snapshot().state != .idle) return error.CheckpointFailurePoisonedSession;
    limits.max_string_bytes = 2 * 1024 * 1024;
    var exported = try session.exportCheckpoint(limits, sink, last_run, 0, model);
    defer exported.deinit();
    if (exported != .success) return error.CheckpointExportFailed;
    const description = exported.success.description;
    try session.close(.session_close);
    try runtime.releaseClosedSession(session);
    var restore_options = options;
    restore_options.operation_id_floor = .{
        .last_run_id = description.last_run_id,
        .last_compact_id = description.last_compact_id,
    };
    const restored = try runtime.restoreSessionRoute(.{
        .session = restore_options,
        .checkpoint_limits = limits,
        .source = .{ .context = &checkpoint, .read_fn = Checkpoint.read },
        .expectation = .{
            .logical_session_id = description.session_id,
            .checkpoint_generation = exported.success.checkpoint.generation,
            .last_run_id = description.last_run_id,
            .last_compact_id = description.last_compact_id,
            .model = model,
        },
    });
    if (restored.report.health != .complete) return error.IncompleteRestore;
    _ = try success(runtime, restored.session, .{ .text = "Continue after restore." });
    if (protocol != .gemini_native) {
        try restored.session.setModel("unknown-provider-test-model");
        var rejected = try execute(restored.session, .{ .multimodal = &.{.{ .image = .{ .format = .png, .bytes = png } }} });
        defer rejected.deinit();
        if (rejected.abi_status != .image_input_unsupported or rejected.failure != .abi_status or
            rejected.stop_reason != null or rejected.durable_budget != null or
            restored.session.snapshot().state != .idle)
            return error.InvalidImageRejection;
        try restored.session.setModel(model);
    } else {
        if (restored.session.prepareRun(.{ .multimodal = &.{.{ .text = "" }} })) |_| {
            return error.AcceptedInvalidInput;
        } else |err| if (err != error.InvalidRunInput) return err;
    }
    _ = try success(runtime, restored.session, .{ .text = "Continue after rejection." });
    std.debug.print("Host multimodal history and checkpoint acceptance passed: {s}\n", .{provider});
}
