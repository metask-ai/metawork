const std = @import("std");
const account_contract = @import("metawork_account_contract");
const models_contract = @import("metawork_product_models_contract");
const agent = @import("metawork_agent");
const mcp_platform = @import("metawork_mcp_platform");
const options = @import("mcp_interop_options");
const product_control = @import("metawork_product_control");
const product_task = @import("metawork_product_task");
const product_skill = @import("metawork_product_skill");
const models_ports = @import("product_models_ports");
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

const PermissionRun = struct {
    session: *agent.Session,
    run_id: u64,
    done: std.atomic.Value(bool) = .init(false),
    result: ?agent.TerminalResult = null,
    failure: ?anyerror = null,

    fn execute(self: *@This()) void {
        defer self.done.store(true, .release);
        var run = self.session.beginRun(self.run_id) catch |err| {
            self.failure = err;
            return;
        };
        self.result = run.execute();
        run.deinit();
    }
};

fn runWithPermission(runtime: *agent.Runtime, session: *agent.Session, run_id: u64, choice: agent.PermissionChoice) !struct { terminal: agent.TerminalResult, answers: usize } {
    var work = PermissionRun{ .session = session, .run_id = run_id };
    const thread = std.Thread.spawn(.{}, PermissionRun.execute, .{&work}) catch |err| {
        try session.cancelPreparedRun(run_id);
        return err;
    };
    var joined = false;
    defer if (!joined) {
        _ = session.requestTermination(run_id, .{ .interrupted = .user_cancel }) catch {};
        thread.join();
        if (work.result) |*result| result.deinit();
    };
    var previous_request: ?u64 = null;
    var answers: usize = 0;
    for (0..10_000) |_| {
        while (runtime.takeEvent()) |value| {
            var event = value;
            event.deinit();
        }
        if (work.done.load(.acquire)) break;
        if (session.pendingUiRequest()) |request| if (previous_request == null or previous_request.? != request) {
            try session.respondPermission(run_id, request, choice);
            previous_request = request;
            answers += 1;
        };
        std.testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    if (!work.done.load(.acquire)) return error.TestUnexpectedResult;
    thread.join();
    joined = true;
    if (work.failure) |err| return err;
    return .{ .terminal = work.result.?, .answers = answers };
}

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
    for ([_][]const u8{ "skill-source/restore-allowed", "skill-source/restore-blocked" }) |directory|
        try tmp.dir.createDirPath(std.testing.io, directory);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "skill-source/restore-allowed/SKILL.md",
        .data = "---\nname: restore-allowed\ndescription: Allowed pinned restore fixture\n---\nPINNED_RESTORE_SKILL: return the pinned skill result.\n",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "skill-source/restore-blocked/SKILL.md",
        .data = "---\nname: restore-blocked\ndescription: Blocked pinned restore fixture\n---\nThis skill must remain ungranted.\n",
    });
    const skill_source = try tmp.dir.realPathFileAlloc(std.testing.io, "skill-source", std.testing.allocator);
    defer std.testing.allocator.free(skill_source);
    const home = root_storage[0..root_len];
    const query: agent.CatalogQuery = .{
        .canonical_user_home = home,
        .target = .{ .workspace = .{ .canonical_root = workspace_root, .epoch = "restore-fixture" } },
        .additional_sources = &.{.{ .canonical_root = skill_source, .scope = .user, .source_instance_id = "restore-source" }},
    };
    var skills = try runtime.querySkillCatalog(query);
    defer skills.projection.deinit();
    var lease_owned = true;
    defer if (lease_owned) runtime.releaseSkillCatalog(skills.lease) catch unreachable;
    const allowed = for (skills.projection.skills) |skill| {
        if (std.mem.eql(u8, skill.invocation_name, "restore-allowed")) break skill;
    } else return error.TestUnexpectedResult;
    const blocked = for (skills.projection.skills) |skill| {
        if (std.mem.eql(u8, skill.invocation_name, "restore-blocked")) break skill;
    } else return error.TestUnexpectedResult;
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
        .permission_mode = .default,
        .shell_policy = .unrestricted,
        .workspace = .{
            .canonical_root = workspace_root,
            .trust = .explicitly_trusted,
        },
        .mcp_selection = selection,
        .canonical_user_home = home,
        .workspace_epoch = "restore-fixture",
        .skill_catalog = skills.lease,
        .skill_policy = .{ .granted_skill_ids = &.{allowed.skill_id} },
    };
    const session = try runtime.createSession(open_options);
    const run_id = try session.prepareRun(.{ .text = "Call the selected echo tool." });
    const allowed_run = try runWithPermission(runtime, session, run_id, .allow_session);
    var terminal = allowed_run.terminal;
    defer terminal.deinit();
    try std.testing.expectEqual(@as(usize, 1), allowed_run.answers);
    try std.testing.expectEqual(@as(?agent.TerminalFailure, null), terminal.failure);
    try std.testing.expectEqual(@as(?agent.Status, .ok), terminal.abi_status);
    try std.testing.expectEqual(@as(?agent.StopReason, .end_turn), terminal.stop_reason);
    while (runtime.takeEvent()) |event_value| {
        var event = event_value;
        event.deinit();
    }
    const deny_run_id = try session.prepareRun(.{ .text = "Deny this echo tool." });
    const refused_run = try runWithPermission(runtime, session, deny_run_id, .deny_session);
    var refused = refused_run.terminal;
    defer refused.deinit();
    try std.testing.expectEqual(@as(usize, 1), refused_run.answers);
    try std.testing.expectEqual(@as(?agent.StopReason, .end_turn), refused.stop_reason);
    var saved = try session.captureRestoreInputs();
    defer saved.deinit() catch unreachable;
    try std.testing.expectEqual(agent.PermissionMode.default, saved.permission_mode);
    try std.testing.expectEqual(@as(usize, 1), saved.skill.?.borrow().policy.granted_skill_ids.len);
    try runtime.releaseSkillCatalog(skills.lease);
    lease_owned = false;
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
    var exported = try session.exportCheckpoint(limits, .{ .context = &bytes, .write_fn = RestoreBytes.write }, deny_run_id, 0, open_options.model_binding.target.model);
    defer exported.deinit();
    const checkpoint = switch (exported) {
        .success => |value| value,
        .failure => return error.TestUnexpectedResult,
    };
    try session.close(.session_close);
    try runtime.releaseClosedSession(session);
    // A newly queried catalog has extra authority, but it cannot replace the
    // immutable lease and grant set captured from the original Session.
    try tmp.dir.createDirPath(std.testing.io, "skill-source/restore-extra");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "skill-source/restore-extra/SKILL.md",
        .data = "---\nname: restore-extra\ndescription: Newly available ungranted skill\n---\nThis new skill must not enter the old policy.\n",
    });
    var broader = try runtime.querySkillCatalog(query);
    defer broader.projection.deinit();
    defer runtime.releaseSkillCatalog(broader.lease) catch unreachable;
    try std.testing.expect(broader.projection.skills.len > skills.projection.skills.len);
    const current = switch (try runtime.activateMcp()) {
        .activated => |value| value,
        else => return error.TestUnexpectedResult,
    };
    var current_owned = true;
    defer if (current_owned) current.deinit();
    var current_preparation = try prepareHttpFixture(fixture.endpoint, "2026-07-28");
    var preparation_owned = true;
    defer if (preparation_owned) current_preparation.deinit();
    const current_registry = &current_preparation.registry.?;
    const fingerprint = mcp_configuration.connectionFingerprint(current_registry.value.servers[0]);
    current_registry.value.servers[0].connection_approval.?.fingerprint = try current_registry.arena.allocator().dupe(u8, &fingerprint);
    var control = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, .{
        .worker_count = 1,
        .queue_capacity = 2,
        .max_tasks = 1,
        .max_workspaces = 1,
    }, .{ .mcp = .{ .preparation = &current_preparation, .activation = current } });
    current_owned = false;
    preparation_owned = false;
    defer control.deinit();
    const product_mcp = &control.mcp.?;
    var prepared_authority = try product_mcp.restoreAuthority(saved.mcp.?);
    defer prepared_authority.deinit();
    const prepared = prepared_authority.selection.?;
    try std.testing.expectEqual(@as(usize, 1), prepared.selectedTools().len);
    try std.testing.expectEqualStrings("echo", prepared.selectedTools()[0].name);
    // A current catalog can keep advertising the same schema while Product
    // has withdrawn its connection grant. It must not restore old authority.
    const current_state = mcp_types.testing.state(product_mcp);
    const server = &current_state.preparation.registry.?.value.servers[0];
    {
        const approval = server.connection_approval;
        server.connection_approval = null;
        defer server.connection_approval = approval;
        var withdrawn = try product_mcp.restoreAuthority(saved.mcp.?);
        defer withdrawn.deinit();
        try std.testing.expectEqual(@as(usize, 0), withdrawn.selection.?.selectedTools().len);
    }
    var revoked_authority = revoked: {
        const tools = server.tools;
        server.tools = &.{};
        defer server.tools = tools;
        break :revoked try product_mcp.restoreAuthority(saved.mcp.?);
    };
    defer revoked_authority.deinit();
    try std.testing.expectEqual(@as(usize, 0), revoked_authority.selection.?.selectedTools().len);
    // A blocked refresh cannot turn a Task that originally had no MCP into
    // an MCP consumer, or make it depend on unrelated global readiness.
    {
        current_state.refresh_pending = true;
        defer current_state.refresh_pending = false;
        try std.testing.expectError(error.RecoveryUnavailable, product_mcp.restoreAuthority(saved.mcp.?));
        var absent = try product_mcp.restoreAuthority(null);
        defer absent.deinit();
        try std.testing.expect(absent.selection == null);
    }
    var restore_options = open_options;
    restore_options.mcp_selection = prepared;
    restore_options.permission_mode = saved.permission_mode;
    restore_options.shell_policy = saved.shell_policy;
    restore_options.permission_interaction = saved.permission_interaction;
    const pinned = saved.skill.?.borrow();
    restore_options.skill_catalog = pinned.catalog;
    restore_options.skill_policy = pinned.policy;
    restore_options.operation_id_floor.last_run_id = deny_run_id;
    const restored = try runtime.restoreSessionRoute(.{
        .session = restore_options,
        .checkpoint_limits = limits,
        .source = .{ .context = &bytes, .read_fn = RestoreBytes.read },
        .expectation = .{
            .logical_session_id = checkpoint.description.session_id,
            .checkpoint_generation = checkpoint.checkpoint.generation,
            .last_run_id = deny_run_id,
            .last_compact_id = 0,
            .model = open_options.model_binding.target.model,
        },
    });
    try std.testing.expectEqual(agent.CheckpointRestoreHealth.complete, restored.report.health);
    try std.testing.expect(restored.report.restored_permission_rules >= 2);
    const next = try restored.session.prepareRun(.{ .text = "Call the restored echo tool." });
    try std.testing.expect(next > deny_run_id);
    const continuation = try runWithPermission(runtime, restored.session, next, .allow_session);
    var continued = continuation.terminal;
    defer continued.deinit();
    try std.testing.expectEqual(@as(usize, 0), continuation.answers);
    if (continued.failure != null) std.debug.print("restored MCP run status={any} stop={any} signal={any} diagnostic={s}\n", .{ continued.abi_status, continued.stop_reason, continued.termination_signal, continued.diagnostic() });
    try std.testing.expectEqual(@as(?agent.TerminalFailure, null), continued.failure);
    try std.testing.expectEqual(@as(?agent.StopReason, .end_turn), continued.stop_reason);
    const repeat_denial_id = try restored.session.prepareRun(.{ .text = "Deny this echo tool." });
    const repeat_denial = try runWithPermission(runtime, restored.session, repeat_denial_id, .allow_session);
    var denied_again = repeat_denial.terminal;
    defer denied_again.deinit();
    try std.testing.expectEqual(@as(usize, 0), repeat_denial.answers);
    try std.testing.expectEqual(@as(?agent.StopReason, .end_turn), denied_again.stop_reason);
    while (runtime.takeEvent()) |event_value| {
        var event = event_value;
        event.deinit();
    }
    const skill_run_id = try restored.session.prepareRun(.{ .skill = .{ .skill_id = allowed.skill_id, .catalog_revision = skills.projection.revision, .argument_values = &.{} } });
    var skill_run = try restored.session.beginRun(skill_run_id);
    var skill_terminal = skill_run.execute();
    skill_run.deinit();
    defer skill_terminal.deinit();
    try std.testing.expectEqual(@as(?agent.TerminalFailure, null), skill_terminal.failure);
    try std.testing.expectEqual(@as(?agent.StopReason, .end_turn), skill_terminal.stop_reason);
    while (runtime.takeEvent()) |event_value| {
        var event = event_value;
        event.deinit();
    }
    const denied_id = try restored.session.prepareRun(.{ .skill = .{ .skill_id = blocked.skill_id, .catalog_revision = skills.projection.revision, .argument_values = &.{} } });
    var denied_run = try restored.session.beginRun(denied_id);
    var denied = denied_run.execute();
    denied_run.deinit();
    defer denied.deinit();
    try std.testing.expectEqual(@as(?agent.Status, .skill_policy_violation), denied.abi_status);
    try restored.session.close(.session_close);
    try runtime.releaseClosedSession(restored.session);
    const extra = for (broader.projection.skills) |skill| {
        if (std.mem.eql(u8, skill.invocation_name, "restore-extra")) break skill;
    } else return error.TestUnexpectedResult;
    const narrower = try saved.skill.?.narrow(.{ .granted_skill_ids = &.{extra.skill_id} });
    defer narrower.deinit() catch unreachable;
    try std.testing.expectEqual(@as(usize, 0), narrower.borrow().policy.granted_skill_ids.len);
    restore_options.skill_catalog = narrower.borrow().catalog;
    restore_options.skill_policy = narrower.borrow().policy;
    restore_options.mcp_selection = revoked_authority.selection;
    restore_options.operation_id_floor.last_run_id = denied_id;
    bytes.offset = 0;
    const degraded = try runtime.restoreSessionRoute(.{
        .session = restore_options,
        .checkpoint_limits = limits,
        .source = .{ .context = &bytes, .read_fn = RestoreBytes.read },
        .expectation = .{
            .logical_session_id = checkpoint.description.session_id,
            .checkpoint_generation = checkpoint.checkpoint.generation,
            .last_run_id = deny_run_id,
            .last_compact_id = 0,
            .model = open_options.model_binding.target.model,
        },
    });
    try std.testing.expectEqual(agent.CheckpointRestoreHealth.degraded, degraded.report.health);
    try std.testing.expect(degraded.report.invalidated_skill_authority > 0);
    try std.testing.expect(degraded.report.invalidated_mcp_bindings > 0);
    const revoked_id = try degraded.session.prepareRun(.{ .skill = .{ .skill_id = allowed.skill_id, .catalog_revision = skills.projection.revision, .argument_values = &.{} } });
    var revoked_run = try degraded.session.beginRun(revoked_id);
    var revoked = revoked_run.execute();
    revoked_run.deinit();
    defer revoked.deinit();
    try std.testing.expectEqual(@as(?agent.Status, .skill_policy_violation), revoked.abi_status);
    const revoked_mcp_id = try degraded.session.prepareRun(.{ .text = "Call the revoked echo tool." });
    const revoked_mcp = try runWithPermission(runtime, degraded.session, revoked_mcp_id, .deny_session);
    var revoked_mcp_terminal = revoked_mcp.terminal;
    defer revoked_mcp_terminal.deinit();
    try std.testing.expectEqual(@as(usize, 0), revoked_mcp.answers);
    try std.testing.expectEqual(@as(?agent.StopReason, .end_turn), revoked_mcp_terminal.stop_reason);
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
    try std.testing.expect(std.mem.indexOf(u8, trace, "PINNED_RESTORE_SKILL") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "revoked-from-agentcore") != null);
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

const TaskSwitchHistory = struct {
    fn commit(context: ?*anyopaque, bytes: []const u8) product_task.history.Commit {
        const store: *product_task.history.FileStore = @ptrCast(@alignCast(context.?));
        store.commit(bytes) catch |err| return if (err == error.PersistenceOutcomeUnknown) .outcome_unknown else .failed;
        return .committed;
    }
    fn confirmed(context: ?*anyopaque, bytes: []const u8) product_task.history.Commit {
        const store: *product_task.history.FileStore = @ptrCast(@alignCast(context.?));
        return store.commitConfirmed(std.testing.allocator, bytes);
    }
    fn resolve(context: ?*anyopaque, bytes: []const u8) product_task.history.Commit {
        const store: *product_task.history.FileStore = @ptrCast(@alignCast(context.?));
        return store.resolveCommit(std.testing.allocator, bytes);
    }
    fn capability(store: *product_task.history.FileStore) product_task.history.Capability {
        return .{ .context = store, .enabled = true, .commit_fn = commit, .confirmed_commit_fn = confirmed, .resolve_commit_fn = resolve };
    }
};

const TaskSwitchVault = struct {
    next: u8 = 0,
    keys: [2][128]u8 = undefined,
    lengths: [2]usize = .{ 0, 0 },
    fn generate(context: *anyopaque, output: *[models_ports.credential_slot_bytes]u8) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (self.next == 2) return error.CapacityReached;
        self.next += 1;
        @memcpy(output, models_ports.credential_slot_prefix ++ "0" ** 31 ++ "0");
        output[output.len - 1] = '0' + self.next;
    }
    fn index(slot: []const u8) usize {
        return slot[slot.len - 1] - '1';
    }
    fn store(context: *anyopaque, slot: []const u8, key: []const u8) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        const i = index(slot);
        if (key.len > self.keys[i].len) return error.CapacityReached;
        @memcpy(self.keys[i][0..key.len], key);
        self.lengths[i] = key.len;
    }
    fn get(context: *anyopaque, slot: []const u8, output: []u8) anyerror!?[]const u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        const i = index(slot);
        if (self.lengths[i] == 0) return null;
        @memcpy(output[0..self.lengths[i]], self.keys[i][0..self.lengths[i]]);
        return output[0..self.lengths[i]];
    }
    fn delete(context: *anyopaque, slot: []const u8) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        const i = index(slot);
        std.crypto.secureZero(u8, self.keys[i][0..self.lengths[i]]);
        self.lengths[i] = 0;
    }
    fn port(self: *@This()) models_ports.CredentialVault {
        return .{ .context = self, .generate_slot_fn = generate, .store_fn = store, .get_fn = get, .delete_fn = delete };
    }
};

fn configureTaskSwitchProvider(control: *product_control.Runtime, endpoint: []const u8, name: []const u8, protocol: models_contract.Protocol) !product_control.NewTaskModelSelectionInput {
    const model = if (std.mem.eql(u8, name, "source-model")) "gpt-4o" else "gpt-4o-mini";
    const root = endpoint[0 .. endpoint.len - "/v1/messages".len];
    const address = try std.fmt.allocPrint(std.testing.allocator, "{s}{s}", .{ root, switch (protocol) {
        .anthropic_messages => "/v1/messages",
        .openai_chat_completions => "/v1/chat/completions",
        .openai_responses => "/v1/responses",
        .gemini_native => "",
    } });
    defer std.testing.allocator.free(address);
    const key = try std.fmt.allocPrint(std.testing.allocator, "synthetic-key-for-{s}", .{model});
    defer std.testing.allocator.free(key);
    try std.testing.expect(control.createCustomProviderWithCredential(key, .{
        .display_name = name,
        .protocol = protocol,
        .normalized_base_url = address,
    }).accepted);
    const view = control.modelsView();
    const created = view.custom_providers[view.custom_providers.len - 1];
    const id = try std.testing.allocator.dupe(u8, created.id);
    defer std.testing.allocator.free(id);
    try std.testing.expect(control.submitCustomProviderCommand(.{ .add_custom_model = .{
        .source_id = id,
        .expected_provider_revision = created.provider_revision,
        .expected_catalog_generation = created.catalog_generation,
        .model = .{ .id = model, .metadata = .{ .capabilities = .{ .image_input = true } } },
    } }).accepted);
    const configured = control.modelsView().custom_providers[view.custom_providers.len - 1];
    const probe: models_contract.CustomModelTestCommand = .{
        .model = .{ .source_id = id, .model_id = model },
        .expected_provider_revision = configured.provider_revision,
        .expected_source_generation = configured.source_generation,
        .expected_catalog_generation = configured.catalog_generation,
    };
    var prepared = switch (control.beginCustomProviderProbe(probe)) {
        .ready => |value| value,
        .rejected => return error.TestUnexpectedResult,
    };
    prepared.deinit();
    try std.testing.expect(control.completeCustomModelTest(probe, true).accepted);
    const ready = control.modelsView().custom_providers[view.custom_providers.len - 1];
    return .{ .target = .{ .source_id = ready.id, .model_id = model }, .expected_source_generation = ready.source_generation, .expected_catalog_generation = ready.catalog_generation };
}

fn waitTaskSwitchCatalog(control: *product_control.Runtime, workspace: u64, skill_count: usize) !product_control.CatalogProjection {
    for (0..2000) |_| {
        const catalog = try control.workspaceCatalog(workspace);
        if ((catalog.availability == .ready or catalog.availability == .degraded) and catalog.skills.len == skill_count) return catalog;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    return error.TestUnexpectedResult;
}

fn executeTaskSwitchRun(control: *product_control.Runtime, task_id: u64, input: product_control.TaskRunInput, choice: product_task.PermissionChoice) !usize {
    const run_id = try control.runTask(task_id, input);
    const task = control.task_runtime.find(task_id).?;
    var previous: ?u64 = null;
    var answers: usize = 0;
    for (0..10000) |_| {
        try control.drainAgentEvents();
        control.syncLifecycle();
        if (task.runtime.hasAttachedSession()) {
            var access = try task.runtime.acquireAccess();
            defer access.deinit();
            if (access.pendingUiObservation()) |request| if (previous == null or previous.? != request.request_id) {
                try control.respondUi(task_id, run_id, request.request_id, .{ .permission = choice });
                previous = request.request_id;
                answers += 1;
            };
        }
        if (task.runtime.active_operation == .none and !task.runtime.worker_leases.hasLive()) {
            const run = product_task.testing.state_module.findRun(task.durable.runs, run_id) orelse return error.TestUnexpectedResult;
            const terminal = product_task.testing.state_module.productTerminalFacts(run) orelse return error.TestUnexpectedResult;
            if (terminal.outcome != .completed) std.debug.print("real Product Run failed outcome={s} cause={any}\n", .{ @tagName(terminal.outcome), terminal.cause });
            try std.testing.expectEqual(.completed, terminal.outcome);
            if (task.durable.checkpoint == null) std.debug.print("real Product Run checkpoint unavailable: {any}\n", .{task.durable.checkpoint_attempt});
            try std.testing.expect(task.durable.checkpoint != null);
            try std.testing.expect(task.runtime.last_restore_failure == null);
            return answers;
        }
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    return error.TestUnexpectedResult;
}

const task_switch_png_base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a3V8AAAAASUVORK5CYII=";

// The platform preview port receives one already encoded canonical PNG. Core,
// Product staging, owned originals, checkpoints and all protocol codecs are real;
// OS image decoding and preview generation belong to desktop acceptance.
fn prepareTaskSwitchPng(_: ?*anyopaque, allocator: std.mem.Allocator, bytes: []const u8) anyerror![]u8 {
    var expected: [128]u8 = undefined;
    const size = try std.base64.standard.Decoder.calcSizeForSlice(task_switch_png_base64);
    try std.base64.standard.Decoder.decode(expected[0..size], task_switch_png_base64);
    try std.testing.expectEqualSlices(u8, expected[0..size], bytes);
    return allocator.dupe(u8, bytes);
}

const task_switch_protocols = [_]models_contract.Protocol{ .anthropic_messages, .openai_chat_completions, .openai_responses, .gemini_native };

test "real Core Product rebind from Anthropic retains Skill MCP permissions and context" {
    for (task_switch_protocols) |target| try expectProductTaskSwitch(.anthropic_messages, target, .narrow, .manual);
}
test "real Core Product rebind from Chat retains Skill MCP permissions and context" {
    for (task_switch_protocols) |target| try expectProductTaskSwitch(.openai_chat_completions, target, .narrow, .manual);
}
test "real Core Product rebind from Responses retains Skill MCP permissions and context" {
    for (task_switch_protocols) |target| try expectProductTaskSwitch(.openai_responses, target, .narrow, .manual);
}
test "real Core Product rebind from Gemini retains Skill MCP permissions and context" {
    for (task_switch_protocols) |target| try expectProductTaskSwitch(.gemini_native, target, .narrow, .manual);
}

test "real Core Product rejects a different MCP origin before closing the original Session" {
    try expectProductTaskSwitch(.anthropic_messages, .openai_responses, .replace_connection, .manual);
}

test "real Core Product rebind preserves full access without adding Skill or MCP authority" {
    try expectProductTaskSwitch(.gemini_native, .openai_responses, .narrow, .full_access);
}

const TaskSwitchAuthority = enum { narrow, replace_connection };

fn expectProductTaskSwitch(source_protocol: models_contract.Protocol, target_protocol: models_contract.Protocol, authority_case: TaskSwitchAuthority, approval_mode: product_control.ApprovalMode) !void {
    const manual = approval_mode == .manual;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);
    try tmp.dir.createDirPath(std.testing.io, "workspace");
    const workspace_root = try tmp.dir.realPathFileAlloc(std.testing.io, "workspace", std.testing.allocator);
    defer std.testing.allocator.free(workspace_root);
    try tmp.dir.createDirPath(std.testing.io, ".agents/skills/retained");
    try tmp.dir.createDirPath(std.testing.io, ".agents/skills/blocked");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".agents/skills/retained/SKILL.md", .data = "---\nname: retained\ndescription: Original retained Skill\n---\nPINNED_PRODUCT_SKILL: report the retained original skill.\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".agents/skills/blocked/SKILL.md", .data = "---\nname: blocked\ndescription: Original ungranted Skill\n---\nThis skill must remain ungranted.\n" });
    const trace_a = try std.fmt.allocPrint(std.testing.allocator, "{s}/source-trace.jsonl", .{home});
    defer std.testing.allocator.free(trace_a);
    const trace_b = try std.fmt.allocPrint(std.testing.allocator, "{s}/target-trace.jsonl", .{home});
    defer std.testing.allocator.free(trace_b);
    var source = try HttpFixture.start("2026-07-28", "json", trace_a);
    defer source.deinit();
    var target = try HttpFixture.start("2026-07-28", "json", trace_b);
    defer target.deinit();
    var preparation = try prepareHttpFixture(source.endpoint, "2026-07-28");
    var preparation_owned = true;
    defer if (preparation_owned) preparation.deinit();
    const fingerprint = mcp_configuration.connectionFingerprint(preparation.registry.?.value.servers[0]);
    preparation.registry.?.value.servers[0].connection_approval = .{ .fingerprint = try preparation.registry.?.arena.allocator().dupe(u8, &fingerprint) };
    var manifest = (try mcp_configuration.RuntimeManifest.candidate(std.testing.allocator, &preparation)).?;
    var manifest_owned = true;
    defer if (manifest_owned) manifest.deinit();
    const registry_bytes = try std.testing.allocator.alloc(u8, mcp_configuration.max_store_bytes);
    defer std.testing.allocator.free(registry_bytes);
    var registry = DurableRegistry{ .storage = registry_bytes };
    var runtime_build = try mcp_platform.buildRuntime(std.testing.io, std.testing.allocator, &preparation, .{});
    defer runtime_build.deinit();
    const runtime = try agent.Runtime.init(std.testing.io, std.testing.allocator, .{ .run_time_source = agent.RunTimeSource.unavailable, .max_sessions = 1, .mcp_input = &runtime_build.input.? });
    var runtime_owned = true;
    defer if (runtime_owned) {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    };
    const activation = switch (try runtime.activateMcp()) {
        .activated => |value| value,
        else => return error.TestUnexpectedResult,
    };
    var activation_owned = true;
    defer if (activation_owned) activation.deinit();
    var checkpoints = try product_task.checkpoint_store.FileStore.init(std.testing.io, home);
    defer checkpoints.deinit();
    var history = try product_task.history.FileStore.init(std.testing.io, home);
    defer history.deinit();
    var enablement = try product_skill.enablement.FileStore.init(std.testing.io, home);
    defer enablement.deinit();
    var originals = try product_control.AttachmentFileStore.init(std.testing.io, std.testing.allocator, home);
    defer originals.deinit();
    var vault = TaskSwitchVault{};
    defer for (0..2) |i| std.crypto.secureZero(u8, vault.keys[i][0..vault.lengths[i]]);
    var control = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, .{ .worker_count = 1, .queue_capacity = 4, .max_tasks = 1, .max_workspaces = 1 }, .{
        .directories = .{ .canonical_user_home = home },
        .task_persistence = TaskSwitchHistory.capability(&history),
        .checkpoint_store = .{ .file_store = &checkpoints },
        .skill_enablement = .{ .file_store = &enablement },
        .skill_sources = .{ .restored = .{ .loaded = .{ .ready = .{} } } },
        .attachment_store = &originals,
        .attachment_images = .{ .prepare_fn = prepareTaskSwitchPng },
        .mcp = .{ .preparation = &preparation, .activation = activation, .management = managementConfiguration(&registry, &manifest), .host_capabilities = .{ .connection_approval = true } },
    });
    preparation_owned = false;
    manifest_owned = false;
    activation_owned = false;
    runtime_owned = false;
    defer shutdownProduct(&control, runtime);
    try control.startCustomProviders(home, vault.port());
    defer control.stopCustomProviders();
    const initial_borrowed = try configureTaskSwitchProvider(&control, source.provider_endpoint, "source-model", source_protocol);
    const source_id = try std.testing.allocator.dupe(u8, initial_borrowed.target.source_id);
    defer std.testing.allocator.free(source_id);
    var initial = initial_borrowed;
    initial.target.source_id = source_id;
    var selected = try configureTaskSwitchProvider(&control, target.provider_endpoint, "target-model", target_protocol);
    const target_id = try std.testing.allocator.dupe(u8, selected.target.source_id);
    defer std.testing.allocator.free(target_id);
    selected.target.source_id = target_id;
    try std.testing.expect(control.clearCustomProviderDefault().accepted);
    const workspace = try control.openWorkspace(.{ .workspace_root = workspace_root, .trust = .explicitly_trusted });
    var catalog = try waitTaskSwitchCatalog(&control, workspace, 2);
    try std.testing.expectEqual(@as(usize, 2), catalog.skills.len);
    _ = try control.setSkillEnabled(.{ .scope = .{ .project = .{ .workspace_id = workspace, .expected_workspace_epoch = try control.workspaceEpoch(workspace) } }, .skill_policy_key = "blocked", .state = .disabled, .expected_catalog_revision = catalog.revision, .expected_selection_revision = catalog.selection_revision.? });
    catalog = try control.workspaceCatalog(workspace);
    const task_id = try control.createTaskInWorkspace(workspace, try control.workspaceEpoch(workspace), control.newTaskAdmissionView().active_generation, control.newTaskAdmissionView().active_selection_revision, initial, catalog.revision, catalog.selection_revision, .{ .interactive = approval_mode });
    const task = control.task_runtime.find(task_id).?;
    const pinned = try control.taskCatalog(task_id);
    try std.testing.expectEqual(source_protocol, task.runtime.executionConst().?.protocol);
    const retained = for (pinned.skills) |skill| {
        if (std.mem.eql(u8, skill.invocation_name, "retained")) break skill;
    } else return error.TestUnexpectedResult;
    const blocked = for (pinned.skills) |skill| {
        if (std.mem.eql(u8, skill.invocation_name, "blocked")) break skill;
    } else return error.TestUnexpectedResult;
    try std.testing.expect(retained.enabled);
    try std.testing.expect(!blocked.enabled);
    const old_epoch = task.durable.binding_epoch;
    var png: [128]u8 = undefined;
    const png_len = try std.base64.standard.Decoder.calcSizeForSlice(task_switch_png_base64);
    try std.base64.standard.Decoder.decode(png[0..png_len], task_switch_png_base64);
    var staged: [1]product_control.AttachmentDescriptor = undefined;
    const attachments = try control.stageAttachments(&.{.{ .display_name = "original.png", .bytes = png[0..png_len] }}, &staged);
    try std.testing.expectEqual(.image, attachments[0].kind);
    try std.testing.expectEqual(@as(usize, if (manual) 1 else 0), try executeTaskSwitchRun(&control, task_id, .{ .multimodal = .{ .text = "Call the selected echo tool. ORIGINAL_TASK_CONTEXT", .attachment_ids = &.{attachments[0].id} } }, .allow_session));
    try std.testing.expectEqual(@as(usize, if (manual) 1 else 0), try executeTaskSwitchRun(&control, task_id, .{ .text = "Deny this echo tool." }, .deny_session));
    try std.testing.expectEqual(@as(usize, if (manual) 1 else 0), try executeTaskSwitchRun(&control, task_id, .{ .text = "Write the permission boundary file." }, .allow_once));
    const original_file = try tmp.dir.statFile(std.testing.io, "permission-boundary.txt", .{});
    const before = task.durable.checkpoint.?;
    const logical_id = try std.testing.allocator.dupe(u8, before.session.logical_session_id);
    defer std.testing.allocator.free(logical_id);
    try tmp.dir.createDirPath(std.testing.io, ".agents/skills/extra");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".agents/skills/extra/SKILL.md", .data = "---\nname: extra\ndescription: Newly available ungranted Skill\n---\nThis new global capability must not enter the original Task.\n" });
    try control.refreshWorkspaceCatalog(workspace, try control.workspaceEpoch(workspace));
    const wider = try waitTaskSwitchCatalog(&control, workspace, 3);
    try std.testing.expectEqual(@as(usize, 3), wider.skills.len);
    try control.refreshMcpCatalog();
    try waitForMcpSnapshot(&control, "\"operation\":\"idle\",\"configurationApply\":\"idle\"");
    _ = try control.selectTaskModel(task_id, .{ .expected_selection_revision = task.durable.model_intent.?.revision, .target = selected.target, .expected_source_generation = selected.expected_source_generation, .expected_catalog_generation = selected.expected_catalog_generation });
    _ = try control.restoreTaskConversation(task_id, old_epoch);
    for (0..5000) |_| {
        try control.drainAgentEvents();
        control.syncLifecycle();
        if (task.runtime.restore_job == null and !task.runtime.worker_leases.hasLive()) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    if (task.runtime.last_restore_failure) |failure| std.debug.print("real Product rebind failed: {s}\n", .{@tagName(failure)});
    try std.testing.expect(task.runtime.hasAttachedSession());
    try std.testing.expect(task.runtime.last_restore_failure == null);
    try std.testing.expectEqual(old_epoch + 1, task.durable.binding_epoch);
    try std.testing.expectEqualStrings("gpt-4o-mini", task.durable.execution_model);
    try std.testing.expectEqual(target_protocol, task.runtime.executionConst().?.protocol);
    try std.testing.expectEqual(target_protocol, task.durable.execution_protocol);
    try std.testing.expectEqualStrings(logical_id, task.durable.checkpoint.?.session.logical_session_id);
    const after_switch_file = try tmp.dir.statFile(std.testing.io, "permission-boundary.txt", .{});
    try std.testing.expectEqual(original_file.mtime, after_switch_file.mtime);
    try std.testing.expectEqual(@as(usize, 0), try executeTaskSwitchRun(&control, task_id, .{ .text = "Continue on the new connection." }, .allow_session));
    try std.testing.expectEqual(@as(usize, 0), try executeTaskSwitchRun(&control, task_id, .{ .text = "Deny this echo tool." }, .allow_session));
    // A one-shot Write decision must not become a restored Session grant.
    try std.testing.expectEqual(@as(usize, if (manual) 1 else 0), try executeTaskSwitchRun(&control, task_id, .{ .text = "Write the permission boundary file." }, .allow_once));
    const restored_catalog = try control.taskCatalog(task_id);
    try std.testing.expectEqualStrings(pinned.revision, restored_catalog.revision);
    try std.testing.expectEqual(@as(usize, 0), try executeTaskSwitchRun(&control, task_id, .{ .skill = .{ .skill_id = retained.skill_id, .catalog_revision = pinned.revision, .selection_revision = restored_catalog.selection_revision.?, .argument_values = &.{} } }, .allow_session));
    var access = try task.runtime.acquireAccess();
    var access_owned = true;
    defer if (access_owned) access.deinit();
    var restored_inputs = try access.captureRestoreInputs();
    defer restored_inputs.deinit() catch unreachable;
    try std.testing.expectError(error.SkillUnavailable, control.runTask(task_id, .{ .skill = .{ .skill_id = blocked.skill_id, .catalog_revision = restored_catalog.revision, .selection_revision = restored_catalog.selection_revision.?, .argument_values = &.{} } }));
    try std.testing.expectEqual(if (manual) agent.PermissionMode.accept_edits else agent.PermissionMode.full_access, restored_inputs.permission_mode);
    if (manual) try std.testing.expect(task.runtime.last_restore_report.?.restored_permission_rules >= 2);
    try std.testing.expectEqual(agent.ShellPolicy.unrestricted, restored_inputs.shell_policy);
    try std.testing.expectEqual(agent.PermissionInteraction.interactive, restored_inputs.permission_interaction);
    const ids = restored_inputs.skill.?.borrow().policy.granted_skill_ids;
    try std.testing.expectEqual(@as(usize, 1), ids.len);
    try std.testing.expectEqualStrings(retained.skill_id, ids[0]);
    var mcp_authority = try control.mcp.?.restoreAuthority(restored_inputs.mcp);
    defer mcp_authority.deinit();
    try std.testing.expectEqual(@as(usize, 1), mcp_authority.selection.?.selectedTools().len);
    if (authority_case == .replace_connection) {
        const route = task.runtime.attached().?.binding.routeId();
        const epoch = task.durable.binding_epoch;
        access.deinit();
        access_owned = false;
        try std.testing.expectEqual(mcp_configuration.ManagementOutcome.saved, try control.updateMcpHttpConnection(1, .{
            .server_id = "deterministic-http",
            .display_name = "Different origin, same echo schema",
            .negotiation = "modern_only",
            .timeout_ms = 2000,
            .url = target.endpoint,
            .auth_mode = .none,
        }));
        try waitForMcpSnapshot(&control, "\"operation\":\"idle\",\"configurationApply\":\"idle\"");
        // This one-slot Runtime still owns the live Task. Observe the MCP
        // owner directly so a capacity rejection cannot masquerade as origin
        // validation after the management transaction has settled.
        try std.testing.expect(!control.mcp.?.newTaskAuthorityReady());
        if (control.mcp.?.restoreAuthority(restored_inputs.mcp)) |value| {
            var unexpected = value;
            unexpected.deinit();
            return error.TestUnexpectedResult;
        } else |err| try std.testing.expectEqual(error.RecoveryUnavailable, err);
        _ = try control.selectTaskModel(task_id, .{ .expected_selection_revision = task.durable.model_intent.?.revision, .target = initial.target, .expected_source_generation = initial.expected_source_generation, .expected_catalog_generation = initial.expected_catalog_generation });
        try std.testing.expectError(error.RecoveryUnavailable, control.restoreTaskConversation(task_id, epoch));
        try std.testing.expect(task.runtime.restore_job == null);
        try std.testing.expect(task.runtime.hasAttachedSession());
        try std.testing.expectEqual(route, task.runtime.attached().?.binding.routeId());
        try std.testing.expectEqual(epoch, task.durable.binding_epoch);
        return;
    }
    // Revoke current Product authority through the public mutation paths.
    _ = try control.setSkillEnabled(.{ .scope = .{ .project = .{ .workspace_id = workspace, .expected_workspace_epoch = try control.workspaceEpoch(workspace) } }, .skill_policy_key = "retained", .state = .disabled, .expected_catalog_revision = wider.revision, .expected_selection_revision = wider.selection_revision.? });
    try std.testing.expectEqual(mcp_configuration.ManagementOutcome.saved, try control.setMcpAllowedTools(1, .{ .server_id = "deterministic-http", .tools = &.{} }));
    // Capture inputs above has its own Access. Release it before taking the
    // next operation slot; opaque captured owners intentionally remain alive.
    access.deinit();
    access_owned = false;
    _ = try control.selectTaskModel(task_id, .{ .expected_selection_revision = task.durable.model_intent.?.revision, .target = initial.target, .expected_source_generation = initial.expected_source_generation, .expected_catalog_generation = initial.expected_catalog_generation });
    _ = try control.restoreTaskConversation(task_id, task.durable.binding_epoch);
    for (0..5000) |_| {
        try control.drainAgentEvents();
        control.syncLifecycle();
        if (task.runtime.restore_job == null and !task.runtime.worker_leases.hasLive()) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    if (task.runtime.last_restore_failure) |failure| std.debug.print("reduced Product rebind failed: {s}\n", .{@tagName(failure)});
    try std.testing.expect(task.runtime.last_restore_failure == null);
    try std.testing.expectEqual(agent.CheckpointRestoreHealth.degraded, task.runtime.last_restore_report.?.health);
    try std.testing.expect(task.runtime.last_restore_report.?.invalidated_mcp_bindings > 0);
    try std.testing.expectEqual(source_protocol, task.runtime.executionConst().?.protocol);
    try std.testing.expectEqualStrings("gpt-4o", task.durable.execution_model);
    try std.testing.expectEqualStrings(logical_id, task.durable.checkpoint.?.session.logical_session_id);
    const narrowed = try control.taskCatalog(task_id);
    for (narrowed.skills) |skill| try std.testing.expect(!skill.enabled);
    try std.testing.expectError(error.SkillUnavailable, control.runTask(task_id, .{ .skill = .{ .skill_id = retained.skill_id, .catalog_revision = narrowed.revision, .selection_revision = narrowed.selection_revision.?, .argument_values = &.{} } }));
    try std.testing.expectEqual(@as(usize, 0), try executeTaskSwitchRun(&control, task_id, .{ .text = "Call the revoked echo tool." }, .allow_session));
    // A checkpoint's cached image cannot substitute for retaining the user's
    // original file in the Product Task namespace.
    var task_directory_name: [32]u8 = undefined;
    const task_directory = try std.fmt.bufPrint(&task_directory_name, "{d}", .{task_id});
    var original_directory = try originals.root.openDir(std.testing.io, task_directory, .{ .iterate = true });
    defer original_directory.close(std.testing.io);
    var iterator = original_directory.iterate();
    var original_count: usize = 0;
    while (try iterator.next(std.testing.io)) |entry| if (std.mem.endsWith(u8, entry.name, ".png")) {
        const original_bytes = try original_directory.readFileAlloc(std.testing.io, entry.name, std.testing.allocator, .limited(128));
        defer std.testing.allocator.free(original_bytes);
        try std.testing.expectEqualSlices(u8, png[0..png_len], original_bytes);
        original_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), original_count);
    const durable_bytes = (try history.loadAlloc(std.testing.allocator)) orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(durable_bytes);
    try std.testing.expect(std.mem.indexOf(u8, durable_bytes, "synthetic-key-for-gpt-4o") == null);
    const trace_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, trace_a, std.testing.allocator, .limited(4 * 1024 * 1024));
    defer std.testing.allocator.free(trace_source);
    const trace_target = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, trace_b, std.testing.allocator, .limited(4 * 1024 * 1024));
    defer std.testing.allocator.free(trace_target);
    try std.testing.expect(std.mem.indexOf(u8, trace_target, "ORIGINAL_TASK_CONTEXT") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace_target, task_switch_png_base64) != null);
    try std.testing.expect(std.mem.indexOf(u8, trace_target, "\"credentialMatched\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace_target, "PINNED_PRODUCT_SKILL") != null);
    try std.testing.expectEqual(@as(usize, if (manual) 2 else 4), std.mem.count(u8, trace_source, "\"method\":\"tools/call\""));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, trace_target, "\"method\":\"tools/call\""));
}
