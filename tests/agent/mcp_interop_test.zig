const std = @import("std");
const account_contract = @import("metawork_account_contract");
const models_contract = @import("metawork_product_models_contract");
const agent = @import("metawork_agent");
const mcp_platform = @import("metawork_mcp_platform");
const options = @import("mcp_interop_options");
const product_control = @import("metawork_product_control");
const mcp_configuration = @import("metawork_product_mcp").contract;
const mcp_types = @import("metawork_product_mcp");

const Fixture = struct {
    transport_owner: agent.McpTransportOwner = undefined,
    bound: bool = false,

    fn init() !Fixture {
        return .{};
    }

    fn bind(self: *Fixture, arguments: []const []const u8) !void {
        var environment = std.process.Environ.Map.init(std.testing.allocator);
        defer environment.deinit();
        if (options.windows_system_root) |system_root|
            try environment.put("SystemRoot", system_root);
        self.transport_owner = try mcp_platform.createStdioTransportOwner(
            std.testing.io,
            std.testing.allocator,
            arguments,
            .inherit,
            &environment,
        );
        self.bound = true;
    }

    fn owner(self: *Fixture) agent.McpTransportOwner {
        self.bound = false;
        return self.transport_owner.take();
    }

    fn deinit(self: *Fixture) void {
        if (self.bound) self.transport_owner.deinit();
        self.* = undefined;
    }
};

const HttpFixture = struct {
    child: std.process.Child,
    endpoint: []u8,
    provider_endpoint: []u8,

    fn start(protocol_version: []const u8, framing: []const u8, trace_path: []const u8) !HttpFixture {
        return startWithTtl(protocol_version, framing, trace_path, 60_000);
    }

    fn startWithTtl(
        protocol_version: []const u8,
        framing: []const u8,
        trace_path: []const u8,
        ttl_ms: u64,
    ) !HttpFixture {
        return startWithResult(protocol_version, framing, trace_path, ttl_ms, "text");
    }

    fn startWithResult(
        protocol_version: []const u8,
        framing: []const u8,
        trace_path: []const u8,
        ttl_ms: u64,
        result_kind: []const u8,
    ) !HttpFixture {
        var ttl_storage: [32]u8 = undefined;
        const ttl = try std.fmt.bufPrint(&ttl_storage, "{d}", .{ttl_ms});
        const arguments = [_][]const u8{
            options.node_path,
            options.fixture_path,
            "--transport",
            "http",
            "--protocol",
            protocol_version,
            "--framing",
            framing,
            "--trace",
            trace_path,
            "--ttl-ms",
            ttl,
            "--result-kind",
            result_kind,
        };
        var child = try std.process.spawn(std.testing.io, .{
            .argv = &arguments,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .inherit,
            .create_no_window = true,
        });
        errdefer child.kill(std.testing.io);
        var read_buffer: [1024]u8 = undefined;
        var reader = child.stdout.?.readerStreaming(std.testing.io, &read_buffer);
        const line = try reader.interface.takeDelimiterExclusive('\n');
        if (try reader.interface.takeByte() != '\n') return error.InvalidFixtureHandshake;
        const ready = try std.json.parseFromSlice(
            struct { endpoint: []const u8, providerEndpoint: []const u8 },
            std.testing.allocator,
            line,
            .{},
        );
        defer ready.deinit();
        const endpoint = try std.testing.allocator.dupe(u8, ready.value.endpoint);
        errdefer std.testing.allocator.free(endpoint);
        return .{
            .child = child,
            .endpoint = endpoint,
            .provider_endpoint = try std.testing.allocator.dupe(
                u8,
                ready.value.providerEndpoint,
            ),
        };
    }

    fn deinit(self: *HttpFixture) void {
        self.child.kill(std.testing.io);
        std.testing.allocator.free(self.endpoint);
        std.testing.allocator.free(self.provider_endpoint);
        self.* = undefined;
    }
};

const McpRefreshTimerProbe = struct {
    now_ms: u64 = 100_000,
    armed_at_ms: ?u64 = null,
    arm_count: usize = 0,
    cancel_count: usize = 0,

    fn now(context: ?*anyopaque) ?u64 {
        const self: *@This() = @ptrCast(@alignCast(context orelse return null));
        return self.now_ms;
    }

    fn arm(context: ?*anyopaque, deadline_ms: u64) bool {
        const self: *@This() = @ptrCast(@alignCast(context orelse return false));
        self.armed_at_ms = deadline_ms;
        self.arm_count += 1;
        return true;
    }

    fn cancel(context: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(context orelse return));
        self.armed_at_ms = null;
        self.cancel_count += 1;
    }

    fn capability(self: *@This()) mcp_types.McpRefreshTimer {
        return .{
            .context = self,
            .enabled = true,
            .now_monotonic_ms = now,
            .arm_at = arm,
            .cancel = cancel,
        };
    }
};

const DurableRegistry = struct {
    storage: []u8,
    len: usize = 0,
    identity_counter: u8 = 0,

    fn persistence(self: *DurableRegistry) mcp_configuration.MutationPersistence {
        return .{
            .context = self,
            .available = true,
            .commit_journal_fn = commitJournal,
            .commit_registry_fn = commitRegistry,
            .clear_journal_fn = clearJournal,
        };
    }

    fn credentials(self: *DurableRegistry) mcp_configuration.CredentialEffects {
        return .{
            .context = self,
            .available = true,
            .probe_fn = probeCredential,
            .create_fn = createCredential,
            .delete_fn = deleteCredential,
        };
    }

    fn identityGenerator(self: *DurableRegistry) mcp_configuration.FreshServerIdentityGenerator {
        return .{
            .context = self,
            .available = true,
            .fill_fn = fillIdentity,
        };
    }

    fn commitJournal(_: ?*anyopaque, _: []const u8) mcp_configuration.PersistenceEffect {
        return .committed;
    }

    fn commitRegistry(context: ?*anyopaque, bytes: []const u8) mcp_configuration.PersistenceEffect {
        const self: *DurableRegistry = @ptrCast(@alignCast(context orelse return .failed));
        if (bytes.len > self.storage.len) return .failed;
        @memcpy(self.storage[0..bytes.len], bytes);
        self.len = bytes.len;
        return .committed;
    }

    fn clearJournal(_: ?*anyopaque) mcp_configuration.PersistenceEffect {
        return .committed;
    }

    fn probeCredential(_: ?*anyopaque, _: []const u8) mcp_configuration.CredentialPresence {
        return .missing;
    }

    fn createCredential(_: ?*anyopaque, _: []const u8, _: []const u8) bool {
        return true;
    }

    fn deleteCredential(_: ?*anyopaque, _: []const u8) bool {
        return true;
    }

    fn fillIdentity(context: ?*anyopaque, output: *[16]u8) bool {
        const self: *DurableRegistry = @ptrCast(@alignCast(context orelse return false));
        self.identity_counter +%= 1;
        @memset(output, self.identity_counter);
        return true;
    }
};

const product_mcp_limits: mcp_configuration.Limits = .{
    .max_servers = 8,
    .max_tools_per_server = 32,
    .max_namespace_bytes = 128,
    .max_credential_locators = 64,
    .max_runtime_secrets_per_server = (agent.McpRuntimeLimits{}).max_secrets,
    .max_runtime_secret_bytes_per_server = (agent.McpRuntimeLimits{}).max_secret_bytes,
};

fn managementConfiguration(
    store: *DurableRegistry,
    manifest: *mcp_configuration.RuntimeManifest,
) mcp_configuration.ManagementConfiguration {
    return .{
        .persistence = store.persistence(),
        .credentials = store.credentials(),
        .identity_generator = store.identityGenerator(),
        .limits = product_mcp_limits,
        .runtime_manifest = manifest,
    };
}

fn installExecution(workbench_value: *product_control.Runtime) !void {
    try product_control.TestSupport.installMetaskExecution(workbench_value, 1);
}

fn shutdownProduct(workbench_value: *product_control.Runtime, runtime: *agent.Runtime) void {
    workbench_value.shutdownExecutor();
    runtime.shutdown() catch unreachable;
    workbench_value.syncLifecycle();
    workbench_value.deinit();
    runtime.deinit();
}

fn waitForMcpSnapshot(workbench_value: *product_control.Runtime, expected: []const u8) !void {
    var storage: [512 * 1024]u8 = undefined;
    for (0..400) |_| {
        const snapshot = try workbench_value.writeSnapshot(&storage);
        if (std.mem.indexOf(u8, snapshot, expected) != null) return;
        std.Io.Timeout.sleep(.{ .duration = .{
            .raw = std.Io.Duration.fromMilliseconds(5),
            .clock = .awake,
        } }, std.testing.io) catch return error.TestUnexpectedResult;
    }
    return error.TestUnexpectedResult;
}

fn prepareHttpFixture(
    endpoint: []const u8,
    protocol_version: []const u8,
) !mcp_configuration.Preparation {
    const negotiation = if (std.mem.eql(u8, protocol_version, "2026-07-28"))
        "modern_only"
    else
        "compat_only";
    return prepareHttpFixtureWithNegotiation(endpoint, negotiation);
}

fn prepareHttpFixtureWithNegotiation(
    endpoint: []const u8,
    negotiation: []const u8,
) !mcp_configuration.Preparation {
    const registry_json = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"schema_version\":2,\"generation\":1,\"oauth_operation\":null,\"servers\":[{{\"id\":\"deterministic-http\",\"namespace\":\"fixture\",\"display_name\":\"Deterministic HTTP\",\"enabled\":true,\"negotiation\":\"{s}\",\"timeout_ms\":2000,\"transport\":{{\"kind\":\"streamable_http\",\"url\":\"{s}\",\"headers\":[]}},\"auth\":{{\"kind\":\"none\",\"oauth\":null}},\"connection_approval\":{{\"fingerprint\":\"fixture\"}},\"tools\":[\"echo\"]}}]}}",
        .{ negotiation, endpoint },
    );
    defer std.testing.allocator.free(registry_json);
    const parsed = try std.json.parseFromSlice(
        mcp_configuration.RegistryWire,
        std.testing.allocator,
        registry_json,
        .{ .allocate = .alloc_always },
    );
    errdefer parsed.deinit();
    const states = try std.testing.allocator.alloc(mcp_configuration.ServerPreparationState, 1);
    states[0] = .eligible;
    return .{
        .allocator = std.testing.allocator,
        .state = .available,
        .registry = parsed,
        .server_states = states,
    };
}

fn activateHttpFixture(protocol_version: []const u8, framing: []const u8) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_storage: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_storage);
    var trace_storage: [std.fs.max_path_bytes]u8 = undefined;
    const trace_path = try std.fmt.bufPrint(
        &trace_storage,
        "{s}/http-trace.jsonl",
        .{root_storage[0..root_len]},
    );
    var fixture = try HttpFixture.start(protocol_version, framing, trace_path);
    defer fixture.deinit();
    var preparation = try prepareHttpFixture(fixture.endpoint, protocol_version);
    defer preparation.deinit();
    var runtime_build = try mcp_platform.buildRuntime(
        std.testing.io,
        std.testing.allocator,
        &preparation,
        .{},
    );
    defer runtime_build.deinit();
    const runtime = try agent.Runtime.init(std.testing.io, std.testing.allocator, .{
        .run_time_source = agent.RunTimeSource.unavailable,
        .max_sessions = 1,
        .mcp_input = &runtime_build.input.?,
    });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    const activation = switch (try runtime.activateMcp()) {
        .activated => |value| value,
        else => return error.TestUnexpectedResult,
    };
    defer activation.deinit();
    try std.testing.expectEqual(agent.McpActivationState.ready, activation.state());
    try std.testing.expectEqual(@as(usize, 1), activation.catalogTools().len);
    try std.testing.expectEqualStrings("echo", activation.catalogTools()[0].name);
    try std.testing.expectEqual(@as(usize, 1), activation.selectedTools().len);
}

fn initializeRequestOffset(trace: []const u8, protocol_version: []const u8) ?usize {
    var version_storage: [64]u8 = undefined;
    const version_field = std.fmt.bufPrint(
        &version_storage,
        "\"protocolVersion\":\"{s}\"",
        .{protocol_version},
    ) catch return null;
    var offset: usize = 0;
    var lines = std.mem.splitScalar(u8, trace, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "\"direction\":\"request\"") != null and
            std.mem.indexOf(u8, line, "\"method\":\"initialize\"") != null and
            std.mem.indexOf(u8, line, version_field) != null)
            return offset;
        offset += line.len + 1;
    }
    return null;
}

fn runCatalogInterop(
    negotiation: agent.McpNegotiationPolicy,
    protocol_version: []const u8,
) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_storage: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_storage);
    var trace_storage: [std.fs.max_path_bytes]u8 = undefined;
    const trace_path = try std.fmt.bufPrint(
        &trace_storage,
        "{s}/trace.jsonl",
        .{root_storage[0..root_len]},
    );
    const arguments = [_][]const u8{
        options.node_path,
        options.fixture_path,
        "--protocol",
        protocol_version,
        "--trace",
        trace_path,
    };
    var fixture = try Fixture.init();
    try fixture.bind(&arguments);
    var owner = fixture.owner();
    var input = try agent.McpRuntimeInput.init(std.testing.allocator, 1, &.{.{
        .id = "deterministic-stdio",
        .transport_owner = &owner,
        .transport = .stdio,
        .namespace = "fixture",
        .client_name = "MetaWork",
        .client_version = "test",
        .timeout_ms = 2000,
        .configuration_fingerprint = [_]u8{1} ** 32,
        .negotiation = negotiation,
        .allowed_tools = &.{"echo"},
    }});
    defer input.deinit();
    const runtime = try agent.Runtime.init(std.testing.io, std.testing.allocator, .{
        .run_time_source = agent.RunTimeSource.unavailable,
        .max_sessions = 1,
        .mcp_input = &input,
    });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    const activation = switch (try runtime.activateMcp()) {
        .activated => |value| value,
        else => return error.TestUnexpectedResult,
    };
    defer activation.deinit();
    if (activation.state() != .ready) {
        std.debug.print("catalog servers={d} tools={d} issues={d} selected={d}\n", .{
            activation.catalogServers().len,
            activation.catalogTools().len,
            activation.catalogIssues().len,
            activation.selectedTools().len,
        });
        for (activation.serverHealth()) |health| std.debug.print(
            "server state={s} configured={d} selected={d} issues={d}\n",
            .{ @tagName(health.state), health.configured_tool_count, health.selected_tool_count, health.issue_count },
        );
        const trace = try tmp.dir.readFileAlloc(
            std.testing.io,
            "trace.jsonl",
            std.testing.allocator,
            .limited(1024 * 1024),
        );
        defer std.testing.allocator.free(trace);
        std.debug.print("MCP fixture trace:\n{s}\n", .{trace});
    }
    try std.testing.expectEqual(agent.McpActivationState.ready, activation.state());
    try std.testing.expectEqual(@as(usize, 1), activation.catalogServers().len);
    try std.testing.expect(activation.catalogServers()[0].fresh);
    try std.testing.expectEqual(@as(usize, 1), activation.catalogTools().len);
    try std.testing.expectEqualStrings("echo", activation.catalogTools()[0].name);
    try std.testing.expectEqual(@as(usize, 0), activation.catalogIssues().len);
    try std.testing.expectEqual(@as(usize, 1), activation.selectedTools().len);
    if (std.mem.eql(u8, protocol_version, "2025-06-18")) {
        const trace = try tmp.dir.readFileAlloc(
            std.testing.io,
            "trace.jsonl",
            std.testing.allocator,
            .limited(1024 * 1024),
        );
        defer std.testing.allocator.free(trace);
        const initial = initializeRequestOffset(trace, "2025-11-25");
        const exact = initializeRequestOffset(trace, "2025-06-18");
        const exact_reopen = initial != null and exact != null and initial.? < exact.?;
        if (!exact_reopen) std.debug.print("MCP fixture trace:\n{s}\n", .{trace});
        try std.testing.expect(exact_reopen);
    }
}

test "canonical AgentCore negotiates the 2026-07-28 stdio fixture" {
    try runCatalogInterop(.modern_only, "2026-07-28");
}

test "canonical AgentCore negotiates 2025-11-25 and accepts draft-07 tools" {
    try runCatalogInterop(.compat_only, "2025-11-25");
}

test "canonical AgentCore reopens the exact 2025-06-18 stdio era" {
    try runCatalogInterop(.automatic, "2025-06-18");
}

test "canonical AgentCore negotiates 2026 Streamable HTTP JSON framing" {
    try activateHttpFixture("2026-07-28", "json");
}

test "canonical AgentCore negotiates 2025 Streamable HTTP SSE framing" {
    try activateHttpFixture("2025-11-25", "sse");
}

test "canonical AgentCore AUTO downgrades a bare HTTP 400 probe" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_storage: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_storage);
    var trace_storage: [std.fs.max_path_bytes]u8 = undefined;
    const trace_path = try std.fmt.bufPrint(
        &trace_storage,
        "{s}/http-auto-trace.jsonl",
        .{root_storage[0..root_len]},
    );
    var fixture = try HttpFixture.start("2025-11-25", "json", trace_path);
    defer fixture.deinit();
    var preparation = try prepareHttpFixtureWithNegotiation(
        fixture.endpoint,
        "automatic",
    );
    defer preparation.deinit();
    var runtime_build = try mcp_platform.buildRuntime(
        std.testing.io,
        std.testing.allocator,
        &preparation,
        .{},
    );
    defer runtime_build.deinit();
    const runtime = try agent.Runtime.init(std.testing.io, std.testing.allocator, .{
        .run_time_source = agent.RunTimeSource.unavailable,
        .max_sessions = 1,
        .mcp_input = &runtime_build.input.?,
    });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    const activation = switch (try runtime.activateMcp()) {
        .activated => |value| value,
        else => return error.TestUnexpectedResult,
    };
    defer activation.deinit();
    try std.testing.expectEqual(agent.McpActivationState.ready, activation.state());
    try std.testing.expectEqual(@as(usize, 1), activation.catalogTools().len);
    try std.testing.expectEqualStrings("echo", activation.catalogTools()[0].name);

    const trace = try tmp.dir.readFileAlloc(
        std.testing.io,
        "http-auto-trace.jsonl",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(trace);
    const modern_rejection = std.mem.indexOf(
        u8,
        trace,
        "\"direction\":\"error\",\"error\":\"unexpected MCP protocol header\"",
    );
    const classic = initializeRequestOffset(trace, "2025-11-25");
    try std.testing.expect(modern_rejection != null);
    try std.testing.expect(classic != null);
    try std.testing.expect(modern_rejection.? < classic.?);
}

test "canonical AgentCore executes a selected Streamable HTTP tool" {
    try expectSelectedHttpToolResult("text");
}

test "canonical AgentCore preserves MCP image payload as opaque tool-result text" {
    try expectSelectedHttpToolResult("image");
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
        const count = @min(output.len, self.bytes.items.len - self.offset);
        if (count == 0) return .eof;
        @memcpy(output[0..count], self.bytes.items[self.offset..][0..count]);
        self.offset += count;
        return .{ .bytes = count };
    }
};

fn expectSelectedHttpToolResult(result_kind: []const u8) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_storage: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_storage);
    var trace_storage: [std.fs.max_path_bytes]u8 = undefined;
    const trace_path = try std.fmt.bufPrint(
        &trace_storage,
        "{s}/execution-trace.jsonl",
        .{root_storage[0..root_len]},
    );
    var fixture = try HttpFixture.startWithResult("2026-07-28", "json", trace_path, 60_000, result_kind);
    defer fixture.deinit();
    var preparation = try prepareHttpFixture(fixture.endpoint, "2026-07-28");
    defer preparation.deinit();
    var runtime_build = try mcp_platform.buildRuntime(
        std.testing.io,
        std.testing.allocator,
        &preparation,
        .{},
    );
    defer runtime_build.deinit();
    const runtime = try agent.Runtime.init(std.testing.io, std.testing.allocator, .{
        .run_time_source = agent.RunTimeSource.unavailable,
        .max_sessions = 1,
        .mcp_input = &runtime_build.input.?,
    });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    const activation = switch (try runtime.activateMcp()) {
        .activated => |value| value,
        else => return error.TestUnexpectedResult,
    };
    defer activation.deinit();
    try std.testing.expectEqual(agent.McpActivationState.ready, activation.state());
    const selection = activation.takeSelection() orelse return error.TestUnexpectedResult;
    defer selection.deinit();
    const workspace_root = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(workspace_root);
    const open_options: agent.SessionOpenOptions = .{
        .model_binding = .{
            .target = .{
                .provider_id = "fixture-provider",
                .protocol = .anthropic_messages,
                .base_url = fixture.provider_endpoint,
                .model = "claude-sonnet-4-20250514",
            },
            .credential = "fixture-credential",
        },
        .permission_mode = .full_access,
        .shell_policy = .unrestricted,
        .workspace = .{
            .canonical_root = workspace_root,
            .trust = .explicitly_trusted,
        },
        .mcp_selection = selection,
    };
    const session = try runtime.createSession(open_options);
    const run_id = try session.prepareRun(.{ .text = "Call the selected echo tool." });
    var run = try session.beginRun(run_id);
    var terminal = run.execute();
    run.deinit();
    defer terminal.deinit();
    try std.testing.expectEqual(@as(?agent.TerminalFailure, null), terminal.failure);
    try std.testing.expectEqual(@as(?agent.Status, .ok), terminal.abi_status);
    try std.testing.expectEqual(@as(?agent.StopReason, .end_turn), terminal.stop_reason);
    while (runtime.takeEvent()) |event_value| {
        var event = event_value;
        event.deinit();
    }
    const saved = (try session.captureMcpRestoreSelection()).?;
    defer saved.deinit();
    const limits: agent.CheckpointLimits = .{
        .hard_bytes = 16 * 1024 * 1024,
        .max_section_bytes = 16 * 1024 * 1024,
        .max_string_bytes = 8 * 1024 * 1024,
        .max_messages = 1024,
        .max_blocks_per_message = 128,
        .chunk_bytes = 64 * 1024,
    };
    var bytes = RestoreBytes{};
    defer bytes.bytes.deinit(std.testing.allocator);
    var exported = try session.exportCheckpoint(limits, .{ .context = &bytes, .write_fn = RestoreBytes.write }, run_id, 0, open_options.model_binding.target.model);
    defer exported.deinit();
    const checkpoint = switch (exported) {
        .success => |value| value,
        .failure => return error.TestUnexpectedResult,
    };
    try session.close(.session_close);
    try runtime.releaseClosedSession(session);
    const current = switch (try runtime.activateMcp()) {
        .activated => |value| value,
        else => return error.TestUnexpectedResult,
    };
    defer current.deinit();
    const prepared = try runtime.prepareMcpRestoreSelection(saved, current);
    defer prepared.deinit();
    try std.testing.expectEqual(@as(usize, 1), prepared.selectedTools().len);
    try std.testing.expectEqualStrings("echo", prepared.selectedTools()[0].name);
    var restore_options = open_options;
    restore_options.mcp_selection = prepared;
    restore_options.operation_id_floor.last_run_id = run_id;
    const restored = try runtime.restoreSessionRoute(.{
        .session = restore_options,
        .checkpoint_limits = limits,
        .source = .{ .context = &bytes, .read_fn = RestoreBytes.read },
        .expectation = .{
            .logical_session_id = checkpoint.description.session_id,
            .checkpoint_generation = checkpoint.checkpoint.generation,
            .last_run_id = run_id,
            .last_compact_id = 0,
            .model = open_options.model_binding.target.model,
        },
    });
    try std.testing.expectEqual(agent.CheckpointRestoreHealth.complete, restored.report.health);
    const next = try restored.session.prepareRun(.{ .text = "Call the restored echo tool." });
    try std.testing.expect(next > run_id);
    var continuation = try restored.session.beginRun(next);
    var continued = continuation.execute();
    continuation.deinit();
    defer continued.deinit();
    if (continued.failure != null) std.debug.print("restored MCP run status={any} stop={any} signal={any} diagnostic={s}\n", .{ continued.abi_status, continued.stop_reason, continued.termination_signal, continued.diagnostic() });
    try std.testing.expectEqual(@as(?agent.TerminalFailure, null), continued.failure);
    try std.testing.expectEqual(@as(?agent.StopReason, .end_turn), continued.stop_reason);
    const trace = try tmp.dir.readFileAlloc(
        std.testing.io,
        "execution-trace.jsonl",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(trace);
    if (std.mem.indexOf(u8, trace, "\"method\":\"tools/call\"") == null)
        std.debug.print("MCP execution trace:\n{s}\n", .{trace});
    try std.testing.expect(std.mem.indexOf(u8, trace, "\"method\":\"tools/call\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "echo-from-agentcore") != null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, trace, "\"method\":\"tools/call\""));
}

test "expired MCP authority is typed and the same model succeeds after refresh" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_storage: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_storage);
    var trace_storage: [std.fs.max_path_bytes]u8 = undefined;
    const trace_path = try std.fmt.bufPrint(
        &trace_storage,
        "{s}/ttl-trace.jsonl",
        .{root_storage[0..root_len]},
    );
    var fixture = try HttpFixture.startWithTtl(
        "2026-07-28",
        "json",
        trace_path,
        100,
    );
    defer fixture.deinit();
    var preparation = try prepareHttpFixture(fixture.endpoint, "2026-07-28");
    defer preparation.deinit();
    var runtime_build = try mcp_platform.buildRuntime(
        std.testing.io,
        std.testing.allocator,
        &preparation,
        .{},
    );
    defer runtime_build.deinit();
    const runtime = try agent.Runtime.init(std.testing.io, std.testing.allocator, .{
        .run_time_source = agent.RunTimeSource.unavailable,
        .max_sessions = 1,
        .mcp_input = &runtime_build.input.?,
    });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    const first_activation = switch (try runtime.activateMcp()) {
        .activated => |value| value,
        else => return error.TestUnexpectedResult,
    };
    defer first_activation.deinit();
    const expired_selection = first_activation.takeSelection() orelse
        return error.TestUnexpectedResult;
    defer expired_selection.deinit();
    const workspace_root = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(workspace_root);
    const open_options: agent.SessionOpenOptions = .{
        .model_binding = .{
            .target = .{
                .provider_id = "fixture-provider",
                .protocol = .anthropic_messages,
                .base_url = fixture.provider_endpoint,
                .model = "fixture-model",
            },
            .credential = "fixture-credential",
        },
        .permission_mode = .full_access,
        .shell_policy = .unrestricted,
        .workspace = .{
            .canonical_root = workspace_root,
            .trust = .explicitly_trusted,
        },
        .mcp_selection = expired_selection,
    };
    std.Io.Timeout.sleep(.{ .duration = .{
        .raw = std.Io.Duration.fromMilliseconds(250),
        .clock = .awake,
    } }, std.testing.io) catch return error.TestUnexpectedResult;
    try std.testing.expectError(
        error.McpNotRefreshed,
        runtime.createSession(open_options),
    );

    const refreshed_activation = switch (try runtime.activateMcp()) {
        .activated => |value| value,
        else => return error.TestUnexpectedResult,
    };
    defer refreshed_activation.deinit();
    const refreshed_selection = refreshed_activation.takeSelection() orelse
        return error.TestUnexpectedResult;
    defer refreshed_selection.deinit();
    var refreshed_options = open_options;
    refreshed_options.mcp_selection = refreshed_selection;
    const session = try runtime.createSession(refreshed_options);
    try session.close(.session_close);
    try runtime.releaseClosedSession(session);
}

test "MCP product chain reaches new Task authority after add restart refresh and allowlist" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_storage: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_storage);
    var trace_storage: [std.fs.max_path_bytes]u8 = undefined;
    const trace_path = try std.fmt.bufPrint(
        &trace_storage,
        "{s}/product-trace.jsonl",
        .{root_storage[0..root_len]},
    );
    var fixture = try HttpFixture.startWithTtl(
        "2026-07-28",
        "json",
        trace_path,
        2_000,
    );
    defer fixture.deinit();
    const registry_storage = try std.testing.allocator.alloc(
        u8,
        mcp_configuration.max_store_bytes,
    );
    defer std.testing.allocator.free(registry_storage);
    var durable_registry: DurableRegistry = .{ .storage = registry_storage };

    const initial_runtime = try agent.Runtime.init(
        std.testing.io,
        std.testing.allocator,
        .{ .run_time_source = agent.RunTimeSource.unavailable, .max_sessions = 2 },
    );
    var initial_runtime_owned = true;
    errdefer if (initial_runtime_owned) {
        initial_runtime.shutdown() catch unreachable;
        initial_runtime.deinit();
    };
    var initial_preparation = try mcp_configuration.prepare(
        std.testing.allocator,
        null,
        true,
        false,
        .{},
        product_mcp_limits,
    );
    var initial_preparation_owned = true;
    errdefer if (initial_preparation_owned) initial_preparation.deinit();
    var initial_manifest = (try mcp_configuration.RuntimeManifest.candidate(
        std.testing.allocator,
        &initial_preparation,
    )).?;
    var initial_manifest_owned = true;
    errdefer if (initial_manifest_owned) initial_manifest.deinit();
    var initial_workbench = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        initial_runtime,
        .{ .worker_count = 1, .queue_capacity = 4 },
        .{ .mcp = .{
            .preparation = &initial_preparation,
            .management = managementConfiguration(
                &durable_registry,
                &initial_manifest,
            ),
            .host_capabilities = .{ .connection_approval = true },
        } },
    );
    initial_runtime_owned = false;
    initial_preparation_owned = false;
    initial_manifest_owned = false;
    var initial_product_live = true;
    defer if (initial_product_live) shutdownProduct(
        &initial_workbench,
        initial_runtime,
    );
    try std.testing.expectEqual(
        mcp_configuration.ManagementOutcome.saved,
        try initial_workbench.createMcpHttpServer(0, .{
            .display_name = "Deterministic HTTP",
            .negotiation = "modern_only",
            .timeout_ms = 2000,
            .url = fixture.endpoint,
        }),
    );
    var created = try mcp_configuration.decode(
        std.testing.allocator,
        durable_registry.storage[0..durable_registry.len],
        product_mcp_limits,
    );
    const server_id = try std.testing.allocator.dupe(u8, created.value.servers[0].id);
    created.deinit();
    defer std.testing.allocator.free(server_id);
    try std.testing.expectEqual(
        mcp_configuration.RuntimeAlignment.restart_required,
        initial_workbench.inspectMcpDesiredConfiguration().?.runtime_alignment,
    );
    shutdownProduct(&initial_workbench, initial_runtime);
    initial_product_live = false;

    var restarted_preparation = try mcp_configuration.prepare(
        std.testing.allocator,
        durable_registry.storage[0..durable_registry.len],
        true,
        false,
        .{},
        product_mcp_limits,
    );
    var restarted_preparation_owned = true;
    errdefer if (restarted_preparation_owned) restarted_preparation.deinit();
    var runtime_build = try mcp_platform.buildRuntime(
        std.testing.io,
        std.testing.allocator,
        &restarted_preparation,
        .{},
    );
    defer runtime_build.deinit();
    var restarted_manifest = (try mcp_configuration.RuntimeManifest.candidate(
        std.testing.allocator,
        &restarted_preparation,
    )).?;
    var restarted_manifest_owned = true;
    errdefer if (restarted_manifest_owned) restarted_manifest.deinit();
    const restarted_runtime = try agent.Runtime.init(
        std.testing.io,
        std.testing.allocator,
        .{
            .run_time_source = agent.RunTimeSource.unavailable,
            .max_sessions = 2,
            .mcp_input = &runtime_build.input.?,
        },
    );
    var restarted_runtime_owned = true;
    errdefer if (restarted_runtime_owned) {
        restarted_runtime.shutdown() catch unreachable;
        restarted_runtime.deinit();
    };
    const restarted_activation = switch (try restarted_runtime.activateMcp()) {
        .activated => |value| value,
        else => return error.TestUnexpectedResult,
    };
    var restarted_activation_owned = true;
    errdefer if (restarted_activation_owned) restarted_activation.deinit();
    try std.testing.expectEqual(agent.McpActivationState.ready, restarted_activation.state());
    var refresh_timer: McpRefreshTimerProbe = .{};
    var restarted_workbench = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        restarted_runtime,
        .{ .worker_count = 1, .queue_capacity = 4 },
        .{
            .mcp_refresh_timer = refresh_timer.capability(),
            .mcp = .{
                .preparation = &restarted_preparation,
                .activation = restarted_activation,
                .management = managementConfiguration(
                    &durable_registry,
                    &restarted_manifest,
                ),
                .host_capabilities = .{ .connection_approval = true },
            },
        },
    );
    restarted_runtime_owned = false;
    restarted_activation_owned = false;
    restarted_preparation_owned = false;
    restarted_manifest_owned = false;
    var restarted_product_live = true;
    defer if (restarted_product_live) shutdownProduct(
        &restarted_workbench,
        restarted_runtime,
    );
    try installExecution(&restarted_workbench);
    try std.testing.expectEqual(@as(?u64, null), refresh_timer.armed_at_ms);
    try std.testing.expectEqual(@as(usize, 0), refresh_timer.arm_count);
    try std.testing.expectEqual(
        mcp_configuration.ManagementOutcome.saved,
        try restarted_workbench.setMcpAllowedTools(1, .{
            .server_id = server_id,
            .tools = &.{"echo"},
        }),
    );
    try waitForMcpSnapshot(
        &restarted_workbench,
        "\"desiredAllowed\":true,\"availableToNewTasks\":true",
    );
    const workspace_root = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(workspace_root);
    const workspace_id = try restarted_workbench.openWorkspace(.{
        .workspace_root = workspace_root,
        .trust = .explicitly_trusted,
    });
    const workspace_epoch = try restarted_workbench.workspaceEpoch(workspace_id);
    std.Io.Timeout.sleep(.{ .duration = .{
        .raw = std.Io.Duration.fromMilliseconds(2_500),
        .clock = .awake,
    } }, std.testing.io) catch return error.TestUnexpectedResult;
    const task_id = try restarted_workbench.createTaskInWorkspace(
        workspace_id,
        workspace_epoch,
        1,
        restarted_workbench.newTaskAdmissionView().active_selection_revision,
        null,
        null,
        null,
        .{ .interactive = null },
    );
    try std.testing.expectEqual(
        product_control.TaskMcpAuthorityAtCreation.unavailable,
        try restarted_workbench.taskMcpAuthority(task_id),
    );
    try waitForMcpSnapshot(
        &restarted_workbench,
        "\"mcp\":{\"availability\":\"ready\",\"managementHealth\":\"ready\",\"operation\":\"idle\"",
    );
    try std.testing.expectEqual(
        product_control.TaskMcpAuthorityAtCreation.unavailable,
        try restarted_workbench.taskMcpAuthority(task_id),
    );
    try std.testing.expectEqual(@as(usize, 0), refresh_timer.arm_count);
    var snapshot_storage: [512 * 1024]u8 = undefined;
    const snapshot = try restarted_workbench.writeSnapshot(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(
        u8,
        snapshot,
        "\"newTaskAccess\":\"available\"",
    ) != null);
    shutdownProduct(&restarted_workbench, restarted_runtime);
    restarted_product_live = false;
}

test "canonical AgentCore contains an invalid real-server catalog" {
    const arguments = [_][]const u8{
        options.node_path,
        options.fixture_path,
        "--protocol",
        "2026-07-28",
        "--invalid-catalog",
    };
    var fixture = try Fixture.init();
    try fixture.bind(&arguments);
    var owner = fixture.owner();
    var input = try agent.McpRuntimeInput.init(std.testing.allocator, 1, &.{.{
        .id = "invalid-stdio",
        .transport_owner = &owner,
        .transport = .stdio,
        .namespace = "invalid",
        .client_name = "MetaWork",
        .client_version = "test",
        .timeout_ms = 2000,
        .configuration_fingerprint = [_]u8{1} ** 32,
        .negotiation = .modern_only,
    }});
    defer input.deinit();
    const runtime = try agent.Runtime.init(std.testing.io, std.testing.allocator, .{
        .run_time_source = agent.RunTimeSource.unavailable,
        .max_sessions = 1,
        .mcp_input = &input,
    });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    const activation = switch (try runtime.activateMcp()) {
        .activated => |value| value,
        else => return error.TestUnexpectedResult,
    };
    defer activation.deinit();
    try std.testing.expectEqual(agent.McpActivationState.unavailable, activation.state());
    try std.testing.expectEqual(@as(usize, 0), activation.catalogTools().len);
    try std.testing.expect(activation.catalogIssues().len > 0);
}

test "stdio real-server timeout and cancellation terminate the child" {
    const arguments = [_][]const u8{
        options.node_path,
        options.fixture_path,
        "--protocol",
        "2026-07-28",
        "--delay-ms",
        "250",
    };
    var fixture = try Fixture.init();
    try fixture.bind(&arguments);
    defer fixture.deinit();
    const transport = fixture.transport_owner.transport;

    const timeout_connection = switch (transport.open_fn(
        transport.context,
        .actual,
        .modern_2026_07_28,
        1000,
    )) {
        .connection => |connection| connection,
        else => return error.TestUnexpectedResult,
    };
    const timeout = transport.request_fn(
        timeout_connection,
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2026-07-28\"}}",
        25,
        .{},
    );
    switch (timeout) {
        .failure => |failure| try std.testing.expectEqual(agent.McpTransportFailure.timeout, failure),
        .response => |response| {
            if (response.body.len != 0) std.testing.allocator.free(response.body);
            return error.TestUnexpectedResult;
        },
    }
    transport.close_fn(timeout_connection);

    const cancellation_connection = switch (transport.open_fn(
        transport.context,
        .actual,
        .modern_2026_07_28,
        1000,
    )) {
        .connection => |connection| connection,
        else => return error.TestUnexpectedResult,
    };
    const Cancelled = struct {
        fn check(_: ?*const anyopaque) bool {
            return true;
        }
    };
    const cancelled = transport.request_fn(
        cancellation_connection,
        std.testing.allocator,
        "{}",
        1000,
        .{ .is_cancelled_fn = Cancelled.check },
    );
    switch (cancelled) {
        .failure => |failure| try std.testing.expectEqual(agent.McpTransportFailure.cancelled, failure),
        .response => |response| {
            if (response.body.len != 0) std.testing.allocator.free(response.body);
            return error.TestUnexpectedResult;
        },
    }
    transport.close_fn(cancellation_connection);
}
