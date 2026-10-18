//! Real Host acceptance. Driven by run-agentcore-provider-test.mjs --staged --host.
const std = @import("std");
const agent = @import("metawork_agent");

// Deterministic time source through the production Host adapter, including
// successive snapshots, missing identity, UTC-only and unavailable states.
const RunClock = struct {
    calls: usize = 0,

    fn sample(context: ?*anyopaque) agent.RunTimeSnapshot {
        const self: *RunClock = @ptrCast(@alignCast(context.?));
        const index = self.calls;
        self.calls += 1;
        return switch (index) {
            0 => .{ .unix_ms = 1791561599000, .utc_offset_seconds = 28800, .timezone = agent.RunTimeZoneIdentity.init(.iana, "Asia/Shanghai") },
            1 => .{ .unix_ms = 1791561601000, .utc_offset_seconds = 28800, .timezone = agent.RunTimeZoneIdentity.init(.iana, "Asia/Shanghai") },
            2 => .{ .unix_ms = 1791561601000, .utc_offset_seconds = -25200, .timezone = agent.RunTimeZoneIdentity.init(.windows, "Pacific Standard Time") },
            3 => .{ .unix_ms = 1791561601000, .utc_offset_seconds = 20700 },
            4 => .{ .unix_ms = 1791594000000 },
            else => .{},
        };
    }
};

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
    var manifests: usize = 0;
    while (runtime.takeEvent()) |event| {
        var owned = event;
        defer owned.deinit();
        var parsed = try agent.decodeCoreEvent(runtime.allocator, owned.json);
        defer parsed.deinit();
        switch (parsed.value) {
            .known => |known| switch (known) {
                .prompt_manifest => |manifest| {
                    try validateManifest(manifest, input == .skill);
                    manifests += 1;
                },
                else => {},
            },
            .unknown => {},
        }
        events += 1;
    }
    if (events == 0) return error.MissingHostEvents;
    if ((id == 1 or input == .skill) and manifests == 0) return error.MissingPromptManifest;
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
    var clock = RunClock{};
    const runtime = try agent.Runtime.init(init.io, allocator, .{ .max_sessions = 1, .run_time_source = .{ .context = &clock, .sample_fn = RunClock.sample } });
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
        if (rejected.abi_status != .image_input_capability_unknown or rejected.failure != .abi_status or
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
    try restored.session.close(.session_close);
    try runtime.releaseClosedSession(restored.session);
    checkpoint.len = 0;
    checkpoint.offset = 0;
    try legacyIdentity(runtime, options, limits, &checkpoint);
    checkpoint.len = 0;
    checkpoint.offset = 0;
    try isolatedIdentity(runtime, options, limits, &checkpoint);
    std.debug.print("Host identity, legacy restore and isolated Skill inheritance passed: {s}\n", .{provider});
    std.debug.print("Host multimodal history and checkpoint acceptance passed: {s}\n", .{provider});
}

fn validateManifest(manifest: anytype, child: bool) !void {
    var identity_seen = false;
    var env_seen = false;
    var safety_seen = false;
    var system_seen = false;
    for (manifest.sections) |section| {
        if (std.mem.eql(u8, section.id, if (child) "metacodes:subagent" else "metacodes:identity")) identity_seen = section.origin == .host;
        if (std.mem.eql(u8, section.id, "metacodes:env")) env_seen = section.class == .generated;
        if (std.mem.eql(u8, section.id, "metacodes:safety-policy")) safety_seen = section.class == .locked and section.origin == .kernel;
        if (std.mem.eql(u8, section.id, "metacodes:system")) system_seen = section.class == .locked and section.origin == .kernel;
    }
    if (!identity_seen or !env_seen or (!child and (!safety_seen or !system_seen))) return error.InvalidPromptManifest;
}

// Simulate a historical unprofiled Session using the existing internal Runtime
// handle in this fixture only. Production never clears identity or edits bytes.
fn legacyIdentity(runtime: *agent.Runtime, options: agent.SessionOpenOptions, limits: agent.CheckpointLimits, checkpoint: *Checkpoint) !void {
    const session = try runtime.createSession(options);
    const status = try agent.Status.fromCode(runtime.api.sessionControl().setPromptProfile()(session.raw, null, null));
    if (status != .ok) return error.LegacyProfileFixtureFailed;
    var exported = try session.exportCheckpoint(limits, .{ .context = checkpoint, .write_fn = Checkpoint.write }, 0, 0, options.model_binding.target.model);
    defer exported.deinit();
    if (exported != .success) return error.LegacyExportFailed;
    const description = exported.success.description;
    try session.close(.session_close);
    try runtime.releaseClosedSession(session);
    const restored = try runtime.restoreSessionRoute(.{
        .session = options,
        .checkpoint_limits = limits,
        .source = .{ .context = checkpoint, .read_fn = Checkpoint.read },
        .expectation = .{
            .logical_session_id = description.session_id,
            .checkpoint_generation = exported.success.checkpoint.generation,
            .last_run_id = 0,
            .last_compact_id = 0,
            .model = options.model_binding.target.model,
        },
    });
    const last_run = try success(runtime, restored.session, .{ .text = "Legacy identity restore." });
    checkpoint.len = 0;
    checkpoint.offset = 0;
    var upgraded = try restored.session.exportCheckpoint(limits, .{ .context = checkpoint, .write_fn = Checkpoint.write }, last_run, 0, options.model_binding.target.model);
    defer upgraded.deinit();
    if (upgraded != .success) return error.UpgradedExportFailed;
    const upgraded_description = upgraded.success.description;
    try restored.session.close(.session_close);
    try runtime.releaseClosedSession(restored.session);
    var continued = options;
    continued.operation_id_floor = .{ .last_run_id = last_run };
    const roundtrip = try runtime.restoreSessionRoute(.{
        .session = continued,
        .checkpoint_limits = limits,
        .source = .{ .context = checkpoint, .read_fn = Checkpoint.read },
        .expectation = .{
            .logical_session_id = upgraded_description.session_id,
            .checkpoint_generation = upgraded.success.checkpoint.generation,
            .last_run_id = last_run,
            .last_compact_id = 0,
            .model = options.model_binding.target.model,
        },
    });
    _ = try success(runtime, roundtrip.session, .{ .text = "Legacy identity persisted." });
    try roundtrip.session.close(.session_close);
    try runtime.releaseClosedSession(roundtrip.session);
}

fn isolatedIdentity(runtime: *agent.Runtime, options: agent.SessionOpenOptions, limits: agent.CheckpointLimits, checkpoint: *Checkpoint) !void {
    var catalog = try runtime.querySkillCatalog(.{
        .canonical_user_home = options.canonical_user_home,
        .target = .{ .workspace = .{ .canonical_root = options.workspace.canonical_root, .epoch = "identity-proof" } },
    });
    defer catalog.deinitProjection();
    defer runtime.releaseSkillCatalog(catalog.lease) catch unreachable;
    if (catalog.projection.skills.len != 1) return error.MissingIsolatedSkill;
    const skill = catalog.projection.skills[0];
    var bound = options;
    bound.workspace_epoch = "identity-proof";
    bound.skill_catalog = catalog.lease;
    bound.skill_policy = .{ .granted_skill_ids = &.{skill.skill_id} };
    const session = try runtime.createSession(bound);
    const input = agent.RunInput{ .skill = .{
        .skill_id = skill.skill_id,
        .catalog_revision = catalog.projection.revision,
        .argument_values = &.{},
    } };
    const last_run = try success(runtime, session, input);
    var exported = try session.exportCheckpoint(limits, .{ .context = checkpoint, .write_fn = Checkpoint.write }, last_run, 0, bound.model_binding.target.model);
    defer exported.deinit();
    if (exported != .success) return error.SkillExportFailed;
    const description = exported.success.description;
    try session.close(.session_close);
    try runtime.releaseClosedSession(session);
    bound.operation_id_floor = .{ .last_run_id = description.last_run_id, .last_compact_id = description.last_compact_id };
    const restored = try runtime.restoreSessionRoute(.{
        .session = bound,
        .checkpoint_limits = limits,
        .source = .{ .context = checkpoint, .read_fn = Checkpoint.read },
        .expectation = .{
            .logical_session_id = description.session_id,
            .checkpoint_generation = exported.success.checkpoint.generation,
            .last_run_id = description.last_run_id,
            .last_compact_id = description.last_compact_id,
            .model = bound.model_binding.target.model,
        },
    });
    if (restored.report.health != .complete) return error.SkillRestoreDegraded;
    _ = try success(runtime, restored.session, input);
    try restored.session.close(.session_close);
    try runtime.releaseClosedSession(restored.session);
}
