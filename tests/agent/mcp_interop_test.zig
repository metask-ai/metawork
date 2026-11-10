const std = @import("std");
const sdk = @import("lifecycle_fixture").sdk;
const wire = sdk.types;
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
        return startWithGate(protocol_version, framing, trace_path, ttl_ms, result_kind, "");
    }

    fn startWithGate(
        protocol_version: []const u8,
        framing: []const u8,
        trace_path: []const u8,
        ttl_ms: u64,
        result_kind: []const u8,
        gate_path: []const u8,
    ) !HttpFixture {
        return startWithDelay(protocol_version, framing, trace_path, ttl_ms, result_kind, gate_path, 0);
    }

    fn startWithDelay(protocol_version: []const u8, framing: []const u8, trace_path: []const u8, ttl_ms: u64, result_kind: []const u8, gate_path: []const u8, delay_ms: u32) !HttpFixture {
        return startWithBearer(protocol_version, framing, trace_path, ttl_ms, result_kind, gate_path, delay_ms, "");
    }

    fn startWithBearer(protocol_version: []const u8, framing: []const u8, trace_path: []const u8, ttl_ms: u64, result_kind: []const u8, gate_path: []const u8, delay_ms: u32, bearer: []const u8) !HttpFixture {
        return startForInstallation(protocol_version, framing, trace_path, ttl_ms, result_kind, gate_path, delay_ms, bearer, "", "", "");
    }

    fn startForInstallation(protocol_version: []const u8, framing: []const u8, trace_path: []const u8, ttl_ms: u64, result_kind: []const u8, gate_path: []const u8, delay_ms: u32, bearer: []const u8, query: []const u8, request_file: []const u8, empty_catalog_file: []const u8) !HttpFixture {
        var delay_storage: [32]u8 = undefined;
        const delay = try std.fmt.bufPrint(&delay_storage, "{d}", .{delay_ms});
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
            "--refresh-gate",
            gate_path,
            "--delay-ms",
            delay,
            "--expected-bearer",
            bearer,
            "--expected-query",
            query,
            "--install-request-file",
            request_file,
            "--empty-catalog-file",
            empty_catalog_file,
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
    credential_locator: [256]u8 = undefined,
    credential_locator_len: usize = 0,
    credential: [128]u8 = undefined,
    credential_len: usize = 0,

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

    fn probeCredential(raw: ?*anyopaque, locator: []const u8) mcp_configuration.CredentialPresence {
        const self: *DurableRegistry = @ptrCast(@alignCast(raw.?));
        return if (self.credential_locator_len != 0 and std.mem.eql(u8, locator, self.credential_locator[0..self.credential_locator_len])) .present else .missing;
    }
    fn createCredential(raw: ?*anyopaque, locator: []const u8, value: []const u8) bool {
        const self: *DurableRegistry = @ptrCast(@alignCast(raw.?));
        if (locator.len > self.credential_locator.len or value.len > self.credential.len) return false;
        @memcpy(self.credential_locator[0..locator.len], locator);
        self.credential_locator_len = locator.len;
        @memcpy(self.credential[0..value.len], value);
        self.credential_len = value.len;
        return true;
    }
    fn deleteCredential(raw: ?*anyopaque, locator: []const u8) bool {
        const self: *DurableRegistry = @ptrCast(@alignCast(raw.?));
        if (probeCredential(raw, locator) == .present) {
            std.crypto.secureZero(u8, &self.credential);
            self.credential_len = 0;
            self.credential_locator_len = 0;
        }
        return true;
    }
    fn resolveCredential(raw: ?*anyopaque, allocator: std.mem.Allocator, locator: []const u8) mcp_configuration.CredentialResolution {
        const self: *DurableRegistry = @ptrCast(@alignCast(raw.?));
        if (probeCredential(raw, locator) != .present) return .missing;
        return .{ .value = allocator.dupe(u8, self.credential[0..self.credential_len]) catch return .out_of_memory };
    }
    fn resolver(self: *DurableRegistry) mcp_configuration.CredentialResolver {
        return .{ .available = true, .context = self, .resolve_fn = resolveCredential };
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
        .locator_generator = .{ .available = true, .context = store, .fill_fn = DurableRegistry.fillIdentity },
        .limits = product_mcp_limits,
        .runtime_manifest = manifest,
    };
}

fn installExecution(workbench_value: *product_control.Runtime) !void {
    try product_control.TestSupport.configureMetaskSource(workbench_value, 1);
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
        try workbench_value.drainAgentEvents();
        const snapshot = try workbench_value.writeAggregateFixture(&storage);
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
        "{{\"schema_version\":{d},\"generation\":1,\"oauth_operation\":null,\"servers\":[{{\"id\":\"deterministic-http\",\"namespace\":\"fixture\",\"display_name\":\"Deterministic HTTP\",\"enabled\":true,\"negotiation\":\"{s}\",\"timeout_ms\":2000,\"transport\":{{\"kind\":\"streamable_http\",\"url\":\"{s}\",\"headers\":[]}},\"auth\":{{\"kind\":\"none\",\"oauth\":null}},\"connection_approval\":{{\"fingerprint\":\"fixture\"}},\"tools\":[\"echo\"]}}]}}",
        .{ mcp_configuration.schema_version, negotiation, endpoint },
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
    framing: []const u8,
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
        "--framing",
        framing,
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
    try runCatalogInterop(.modern_only, "2026-07-28", "json");
}

test "canonical MCP uses bare npx and Windows command shims with an offline local package" {
    const builtin = @import("builtin");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "package space");
    try tmp.dir.createDirPath(std.testing.io, "Program Files");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "package space/package.json", .data = "{\"name\":\"metawork-mcp-process-fixture\",\"version\":\"1.0.0\",\"bin\":{\"metawork-mcp-process-fixture\":\"mcp.mjs\"}}" });
    const fixture_path = try std.json.Stringify.valueAlloc(std.testing.allocator, options.fixture_path, .{});
    defer std.testing.allocator.free(fixture_path);
    const script = try std.fmt.allocPrint(std.testing.allocator, "#!/usr/bin/env node\nimport{{pathToFileURL}}from'node:url';await import(pathToFileURL({s}).href);\n", .{fixture_path});
    defer std.testing.allocator.free(script);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "package space/mcp.mjs", .data = script });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const package = try std.fs.path.join(std.testing.allocator, &.{ root, "package space" });
    defer std.testing.allocator.free(package);
    const cache = try std.fs.path.join(std.testing.allocator, &.{ root, "npm-cache" });
    defer std.testing.allocator.free(cache);
    const trace = try std.fs.path.join(std.testing.allocator, &.{ root, "trace.jsonl" });
    defer std.testing.allocator.free(trace);
    const node_dir = std.fs.path.dirname(options.node_path).?;
    const npx_cmd = try std.fs.path.join(std.testing.allocator, &.{ node_dir, "npx.cmd" });
    defer std.testing.allocator.free(npx_cmd);
    const space_cmd = try std.fs.path.join(std.testing.allocator, &.{ root, "Program Files", "npx.cmd" });
    defer std.testing.allocator.free(space_cmd);
    if (builtin.os.tag == .windows) {
        const wrapper = try std.fmt.allocPrint(std.testing.allocator, "@call \"{s}\" %*\r\n", .{npx_cmd});
        defer std.testing.allocator.free(wrapper);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Program Files/npx.cmd", .data = wrapper });
    }
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put(if (builtin.os.tag == .windows) "Path" else "PATH", node_dir);
    if (options.windows_system_root) |system_root| try environment.put("SystemRoot", system_root);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "empty.npmrc", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "empty-global.npmrc", .data = "" });
    const global_npmrc = try std.fs.path.join(std.testing.allocator, &.{ root, "empty-global.npmrc" });
    defer std.testing.allocator.free(global_npmrc);
    const npmrc = try std.fs.path.join(std.testing.allocator, &.{ root, "empty.npmrc" });
    defer std.testing.allocator.free(npmrc);
    const commands: []const []const u8 = if (builtin.os.tag == .windows) &.{ "npx", npx_cmd, space_cmd } else &.{"npx"};
    for (commands) |command| {
        const arguments = [_][]const u8{ command, "--offline", "--yes", "--userconfig", npmrc, "--globalconfig", global_npmrc, "--cache", cache, "--package", package, "metawork-mcp-process-fixture", "--protocol", "2026-07-28", "--trace", trace };
        var owner = try mcp_platform.createStdioTransportOwner(std.testing.io, std.testing.allocator, &arguments, .inherit, &environment);
        var input = try agent.McpRuntimeInput.init(std.testing.allocator, 1, &.{.{ .id = "npx-fixture", .transport_owner = &owner, .transport = .stdio, .namespace = "fixture", .client_name = "MetaWork", .client_version = "test", .timeout_ms = 20000, .configuration_fingerprint = @splat(1), .negotiation = .modern_only, .allowed_tools = &.{"echo"} }});
        defer input.deinit();
        const runtime = try agent.Runtime.init(std.testing.io, std.testing.allocator, .{ .max_sessions = 1, .mcp_input = &input });
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
    }
    if (options.npx_release_probe) {
        const release_cache = try std.fs.path.join(std.testing.allocator, &.{ root, "release-cache" });
        defer std.testing.allocator.free(release_cache);
        const argv = [_][]const u8{ "npx", "--yes", "--userconfig", npmrc, "--globalconfig", global_npmrc, "--cache", release_cache, "--package", "@modelcontextprotocol/server-filesystem@1.0.0", "mcp-server-filesystem", root };
        var owner = try mcp_platform.createStdioTransportOwner(std.testing.io, std.testing.allocator, &argv, .inherit, &environment);
        var input = try agent.McpRuntimeInput.init(std.testing.allocator, 1, &.{.{ .id = "npx-release", .transport_owner = &owner, .transport = .stdio, .namespace = "filesystem", .client_name = "MetaWork", .client_version = "test", .timeout_ms = 120000, .configuration_fingerprint = @splat(2), .negotiation = .automatic, .allowed_tools = &.{"list_allowed_directories"} }});
        defer input.deinit();
        const runtime = try agent.Runtime.init(std.testing.io, std.testing.allocator, .{ .max_sessions = 1, .mcp_input = &input });
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
            std.debug.print("Pinned npx probe: state={s} catalog={d} selected={d} issues={d}\n", .{ @tagName(activation.state()), activation.catalogTools().len, activation.selectedTools().len, activation.catalogIssues().len });
            for (activation.serverHealth()) |health| std.debug.print("Pinned npx server state={s}\n", .{@tagName(health.state)});
            for (activation.catalogIssues()) |issue| std.debug.print("Pinned npx catalog issue tool={s}\n", .{issue.tool_name orelse "(server)"});
        }
        try std.testing.expectEqual(agent.McpActivationState.ready, activation.state());
        try std.testing.expect(activation.catalogTools().len > 0);
        try std.testing.expectEqual(@as(usize, 1), activation.selectedTools().len);
    }
}

test "canonical AgentCore negotiates 2025-11-25 and accepts draft-07 tools" {
    try runCatalogInterop(.compat_only, "2025-11-25", "json");
}

test "canonical AgentCore reopens the exact 2025-06-18 stdio era" {
    try runCatalogInterop(.automatic, "2025-06-18", "json");
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
    try expectSelectedHttpToolResult("text", "json");
}

test "canonical AgentCore preserves MCP image payload as opaque tool-result text" {
    try expectSelectedHttpToolResult("image", "json");
}

test "canonical MCP allow once asks again for identical calls across Runs" {
    try expectRepeatedMcpPermission("2026-07-28", .valid);
}

test "canonical compatible MCP allow once asks again for identical calls across Runs" {
    try expectRepeatedMcpPermission("2025-11-25", .valid);
}

test "canonical MCP expiry rejects historical tool calls without another permission callback" {
    try expectRepeatedMcpPermission("2026-07-28", .expired);
}

test "canonical MCP catalog refresh restores the original Session without selection replacement" {
    try expectRepeatedMcpPermission("2026-07-28", .refreshed);
}

test "canonical MCP catalog refresh preserves original session allow grants" {
    try expectRepeatedMcpPermission("2026-07-28", .refreshed_allow);
}

test "canonical MCP catalog refresh preserves original session deny grants" {
    try expectRepeatedMcpPermission("2026-07-28", .refreshed_deny);
}

test "canonical MCP schema change narrows the original Session" {
    try expectRepeatedMcpPermission("2026-07-28", .schema_changed);
}

test "canonical MCP catalog expansion does not expand the original Session" {
    try expectRepeatedMcpPermission("2026-07-28", .expanded);
}

// Source replacement must revoke the previous origin's Session grant. The
// existing Session can still route to the new origin after fresh approval;
// this is not proof of pinned source isolation. Keep issue #29 open.
test "canonical MCP same binding source replacement requires a new Session grant" {
    try expectRepeatedMcpPermission("2026-07-28", .source_replaced);
}

// Dependency qualification intentionally calls the official SDK directly:
// the production Agent refresh fence must not determine what Core accepts.
const RawMcpAdmissionProbe = struct {
    api: sdk.Api,
    runtime: *wire.RuntimeHandle,
    workspace: []const u8,
    endpoint: []const u8,
    selector: wire.McpSelectorV1,
    bytes: RestoreBytes = .{},
    execute_tool: bool = false,
    execute_restored_tool: bool = false,

    fn event(_: ?*anyopaque, _: ?*const wire.RunContextV1, _: wire.BytesViewV1) callconv(.c) u32 {
        return wire.EVENT_CONTINUE;
    }

    fn write(context: ?*anyopaque, chunk: wire.BytesViewV1) callconv(.c) u32 {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.bytes.bytes.appendSlice(std.testing.allocator, sdk.borrowedBytes(chunk) catch return wire.CHECKPOINT_IO_FATAL) catch return wire.CHECKPOINT_IO_FAILED;
        return wire.CHECKPOINT_IO_OK;
    }

    fn read(context: ?*anyopaque, destination: ?[*]u8, capacity: u64, out_len: ?*u64) callconv(.c) u32 {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        const count = @min(@as(usize, @intCast(capacity)), self.bytes.bytes.items.len - self.bytes.offset);
        if (count > 0) @memcpy(destination.?[0..count], self.bytes.bytes.items[self.bytes.offset..][0..count]);
        self.bytes.offset += count;
        out_len.?.* = count;
        return wire.CHECKPOINT_IO_OK;
    }

    fn describe(self: *@This(), session: *wire.SessionHandle, tool_count: usize) !void {
        var encoded = std.mem.zeroes(wire.OwnedBytesV1);
        defer self.api.bufferRelease()(&encoded);
        try std.testing.expectEqual(sdk.Status.ok, try sdk.Status.fromCode(self.api.sessionControl().describe()(session, &encoded, null)));
        var description = try sdk.decodeSessionDescription(std.testing.allocator, try sdk.borrowedBytes(.{ .ptr = encoded.ptr, .len = encoded.len }));
        defer description.deinit();
        try std.testing.expectEqual(tool_count, description.value.mcp.tools.len);
    }

    fn runTool(self: *@This(), session: *wire.SessionHandle, run_id: u64, prompt: []const u8) !void {
        var run_options = std.mem.zeroes(wire.RunOptionsV1);
        run_options.struct_size = @sizeOf(wire.RunOptionsV1);
        run_options.max_turns = 4;
        var result = std.mem.zeroes(wire.RunResultV1);
        result.struct_size = @sizeOf(wire.RunResultV1);
        try std.testing.expectEqual(sdk.Status.ok, try sdk.Status.fromCode(self.api.session().runText(session, run_id, sdk.bytesView(prompt), &run_options, &result, null)));
        try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
        try std.testing.expectEqual(@as(u32, 1), result.tool_calls);
    }

    fn check(self: *@This(), ready: bool) !void {
        var selection = std.mem.zeroes(wire.McpSelectionV1);
        selection.struct_size = @sizeOf(wire.McpSelectionV1);
        selection.selectors = @ptrCast(&self.selector);
        selection.selector_count = 1;
        var host = std.mem.zeroes(wire.SessionHostConfigV1);
        host.struct_size = @sizeOf(wire.SessionHostConfigV1);
        host.provider_kind_code = wire.PROVIDER_ANTHROPIC;
        host.protocol_kind_code = wire.PROTOCOL_DEFAULT;
        host.permission_mode_code = wire.PERMISSION_FULL_ACCESS;
        host.shell_policy_code = wire.SHELL_UNRESTRICTED;
        host.api_key = sdk.bytesView("fixture-credential");
        host.base_url = sdk.bytesView(self.endpoint);
        host.workspace_root = sdk.bytesView(self.workspace);
        host.workspace_home = sdk.bytesView(self.workspace);
        host.mcp_selection = &selection;
        host.run_journal_mode_code = wire.RUN_JOURNAL_EPHEMERAL;
        var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
        callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
        callbacks.on_event = event;
        var config = std.mem.zeroes(wire.SessionCreateConfigV1);
        config.struct_size = @sizeOf(wire.SessionCreateConfigV1);
        config.host = &host;
        config.model = sdk.bytesView("fixture-model");
        var created: ?*wire.SessionHandle = null;
        const status = try sdk.Status.fromCode(self.api.session().create()(self.runtime, &config, &callbacks, &created, null));
        defer if (created) |session| std.debug.assert(self.api.session().destroy()(session, null) == wire.STATUS_OK);
        if (ready) {
            try std.testing.expectEqual(sdk.Status.ok, status);
            try self.describe(created.?, 1);
            if (self.execute_tool)
                try self.runTool(created.?, 1, "Call the selected echo tool.");
        } else {
            try std.testing.expectEqual(sdk.Status.invalid_mcp_selection, status);
            try std.testing.expect(created == null);
        }
        var limits = std.mem.zeroes(wire.CheckpointLimitsV1);
        limits.struct_size = @sizeOf(wire.CheckpointLimitsV1);
        limits.hard_bytes = 1024 * 1024;
        limits.max_section_bytes = 1024 * 1024;
        limits.max_string_bytes = 64 * 1024;
        limits.max_messages = 128;
        limits.max_blocks_per_message = 128;
        limits.chunk_bytes = 4096;
        if (self.bytes.bytes.items.len == 0) {
            var sink = std.mem.zeroes(wire.CheckpointSinkV1);
            sink.struct_size = @sizeOf(wire.CheckpointSinkV1);
            sink.ctx = self;
            sink.write = write;
            var export_config = std.mem.zeroes(wire.CheckpointExportConfigV1);
            export_config.struct_size = @sizeOf(wire.CheckpointExportConfigV1);
            export_config.sink = &sink;
            export_config.limits = &limits;
            var result = std.mem.zeroes(wire.CheckpointExportResultV1);
            try std.testing.expectEqual(sdk.Status.ok, try sdk.Status.fromCode(self.api.sessionControl().exportCheckpoint()(created.?, &export_config, &result, null)));
        }
        if (created) |session| {
            try std.testing.expectEqual(sdk.Status.ok, try sdk.Status.fromCode(self.api.session().destroy()(session, null)));
            created = null;
        }
        self.bytes.offset = 0;
        var source = std.mem.zeroes(wire.CheckpointSourceV1);
        source.struct_size = @sizeOf(wire.CheckpointSourceV1);
        source.ctx = self;
        source.read = read;
        var restore_config = std.mem.zeroes(wire.SessionRestoreConfigV1);
        restore_config.struct_size = @sizeOf(wire.SessionRestoreConfigV1);
        restore_config.host = &host;
        restore_config.source = &source;
        restore_config.limits = &limits;
        var restored: ?*wire.SessionHandle = null;
        defer if (restored) |session| std.debug.assert(self.api.session().destroy()(session, null) == wire.STATUS_OK);
        var report = std.mem.zeroes(wire.OwnedBytesV1);
        defer self.api.bufferRelease()(&report);
        try std.testing.expectEqual(sdk.Status.ok, try sdk.Status.fromCode(self.api.sessionControl().restore()(self.runtime, &restore_config, &callbacks, &restored, &report, null)));
        var decoded_report = try sdk.decodeRestoreReport(std.testing.allocator, try sdk.borrowedBytes(.{ .ptr = report.ptr, .len = report.len }));
        defer decoded_report.deinit();
        try std.testing.expectEqual(if (ready) sdk.protocol.RestoreHealth.complete else sdk.protocol.RestoreHealth.degraded, decoded_report.value.health);
        try std.testing.expectEqual(@as(u32, if (ready) 1 else 0), decoded_report.value.mcp.restored_bindings);
        try std.testing.expectEqual(@as(u32, if (ready) 0 else 1), decoded_report.value.mcp.invalidated_bindings);
        try self.describe(restored.?, if (ready) 1 else 0);
        if (ready and self.execute_restored_tool)
            try self.runTool(restored.?, 2, "Call the restored echo tool.");
    }
};

const ConfigurationApplyProbe = struct {
    runtime: *agent.Runtime,
    input: *agent.McpRuntimeInput,
    done: std.atomic.Value(bool) = .init(false),
    result: ?agent.McpConfigurationApplyOutcome = null,
    failure: ?anyerror = null,

    fn run(self: *@This()) void {
        defer self.done.store(true, .release);
        self.result = self.runtime.applyMcpConfiguration(self.input) catch |err| {
            self.failure = err;
            return;
        };
    }
};

fn appendHttpCandidate(preparation: *mcp_configuration.Preparation, endpoint: []const u8) !void {
    const registry = &preparation.registry.?;
    const servers = try registry.arena.allocator().alloc(mcp_configuration.ServerWire, 2);
    servers[0] = registry.value.servers[0];
    servers[1] = servers[0];
    servers[1].id = "candidate-http";
    servers[1].namespace = "candidate";
    servers[1].transport.url = endpoint;
    servers[1].timeout_ms = 10_000;
    registry.value.servers = servers;
    preparation.allocator.free(preparation.server_states);
    preparation.server_states = try preparation.allocator.alloc(mcp_configuration.ServerPreparationState, 2);
    @memset(preparation.server_states, .eligible);
}

// Test the Application transport-port option without adding cancellation to
// the official apply ABI. All callbacks share one monotonic deadline.
const CandidateBudgetProbe = struct {
    underlying: agent.McpTransport,
    deadline_ns: i96,
    limited_calls: usize = 0,

    fn remaining(self: *@This(), requested: u32) ?u32 {
        const left = self.deadline_ns - std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds;
        if (left < std.time.ns_per_ms) return null;
        const remaining_ms: u32 = @intCast(@min(@as(i96, std.math.maxInt(u32)), @divFloor(left, std.time.ns_per_ms)));
        if (remaining_ms < requested) self.limited_calls += 1;
        return @min(requested, remaining_ms);
    }

    fn transport(self: *@This()) agent.McpTransport {
        return .{ .context = self, .open_fn = open, .request_fn = request, .notify_fn = notify, .close_fn = close };
    }

    fn open(raw: *anyopaque, purpose: agent.McpPurpose, era: agent.McpEra, timeout_ms: u32) agent.McpOpenOutcome {
        const self: *@This() = @ptrCast(@alignCast(raw));
        const timeout = self.remaining(timeout_ms) orelse return .{ .failure = .timeout };
        const result = self.underlying.open_fn(self.underlying.context, purpose, era, timeout);
        return switch (result) {
            .failure => result,
            .connection => |connection| blk: {
                const wrapped = std.testing.allocator.create(Connection) catch {
                    self.underlying.close_fn(connection);
                    return .{ .failure = .fatal };
                };
                wrapped.* = .{ .budget = self, .underlying = connection };
                break :blk .{ .connection = wrapped };
            },
        };
    }

    const Connection = struct { budget: *CandidateBudgetProbe, underlying: *anyopaque };

    fn request(raw: *anyopaque, allocator: std.mem.Allocator, bytes: []const u8, timeout_ms: u32, cancellation: agent.McpCancellation) agent.McpExchangeOutcome {
        const connection: *Connection = @ptrCast(@alignCast(raw));
        const self = connection.budget;
        const timeout = self.remaining(timeout_ms) orelse return .{ .failure = .timeout };
        return self.underlying.request_fn(connection.underlying, allocator, bytes, timeout, cancellation);
    }

    fn notify(raw: *anyopaque, bytes: []const u8, timeout_ms: u32, cancellation: agent.McpCancellation) ?agent.McpTransportFailure {
        const connection: *Connection = @ptrCast(@alignCast(raw));
        const self = connection.budget;
        const timeout = self.remaining(timeout_ms) orelse return .timeout;
        return self.underlying.notify_fn(connection.underlying, bytes, timeout, cancellation);
    }

    fn close(raw: *anyopaque) void {
        const connection: *Connection = @ptrCast(@alignCast(raw));
        connection.budget.underlying.close_fn(connection.underlying);
        std.testing.allocator.destroy(connection);
    }
};

test "canonical MCP ABI rejects a hanging candidate within its transport budget and preserves the published catalog" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const trace = try std.fmt.allocPrint(std.testing.allocator, "{s}/healthy.jsonl", .{root});
    defer std.testing.allocator.free(trace);
    const candidate_trace = try std.fmt.allocPrint(std.testing.allocator, "{s}/candidate.jsonl", .{root});
    defer std.testing.allocator.free(candidate_trace);
    const gate = try std.fmt.allocPrint(std.testing.allocator, "{s}/candidate", .{root});
    defer std.testing.allocator.free(gate);
    var healthy = try HttpFixture.start("2026-07-28", "json", trace);
    defer healthy.deinit();
    var candidate = try HttpFixture.startWithGate("2026-07-28", "json", candidate_trace, 60_000, "text", gate);
    defer candidate.deinit();
    var preparation = try prepareHttpFixture(healthy.endpoint, "2026-07-28");
    defer preparation.deinit();
    var initial_build = try mcp_platform.buildRuntime(std.testing.io, std.testing.allocator, &preparation, .{});
    defer initial_build.deinit();
    const runtime = try agent.Runtime.init(std.testing.io, std.testing.allocator, .{ .max_sessions = 1 });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    try std.testing.expectEqual(.applied, try runtime.applyMcpConfiguration(&initial_build.input.?));
    const activation = switch (try runtime.activateMcp()) {
        .activated => |value| value,
        else => return error.TestUnexpectedResult,
    };
    defer activation.deinit();
    try appendHttpCandidate(&preparation, candidate.endpoint);
    preparation.registry.?.value.servers[1].timeout_ms = std.math.maxInt(u32);
    var candidate_build = try mcp_platform.buildRuntime(std.testing.io, std.testing.allocator, &preparation, .{});
    defer candidate_build.deinit();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "candidate.armed", .data = "armed" });
    defer tmp.dir.writeFile(std.testing.io, .{ .sub_path = "candidate.release", .data = "release" }) catch {};
    const started = std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds;
    const candidate_adapter = &candidate_build.input.?.servers.?.members[1].adapter;
    var budget: CandidateBudgetProbe = .{ .underlying = candidate_adapter.transport, .deadline_ns = started + 300 * std.time.ns_per_ms };
    candidate_adapter.transport = budget.transport();
    try std.testing.expectEqual(.rejected, try runtime.applyMcpConfiguration(&candidate_build.input.?));
    const elapsed = std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds - started;
    try std.testing.expect(elapsed < 3 * std.time.ns_per_s);
    try std.testing.expect(budget.limited_calls > 0);
    _ = try tmp.dir.statFile(std.testing.io, "candidate.waiting", .{});
    // Describe without refreshing: neither a replacement generation nor a
    // revived TTL may be manufactured after the rejected candidate.
    var descriptor = std.mem.zeroes(wire.OwnedBytesV1);
    defer runtime.api.bufferRelease()(&descriptor);
    try std.testing.expectEqual(sdk.Status.ok, try sdk.Status.fromCode(runtime.api.mcp().describe()(runtime.runtime.?, &descriptor, null)));
    var catalog = try sdk.decodeMcpCatalog(std.testing.allocator, try sdk.borrowedBytes(.{ .ptr = descriptor.ptr, .len = descriptor.len }));
    defer catalog.deinit();
    try std.testing.expectEqual(activation.catalogGeneration(), catalog.value.catalog_generation);
    try std.testing.expectEqual(@as(usize, 1), catalog.value.servers.len);
    try std.testing.expect(catalog.value.servers[0].ttl_remaining_ms < activation.catalogServers()[0].ttl_remaining_ms);
    var probe: RawMcpAdmissionProbe = .{ .api = runtime.api, .runtime = runtime.runtime.?, .workspace = root, .endpoint = healthy.provider_endpoint, .selector = std.mem.zeroes(wire.McpSelectorV1), .execute_tool = true };
    defer probe.bytes.bytes.deinit(std.testing.allocator);
    probe.selector.struct_size = @sizeOf(wire.McpSelectorV1);
    probe.selector.server_binding_identity = agent.mcpBindingIdentity("deterministic-http");
    probe.selector.tool_name = sdk.bytesView("echo");
    try probe.check(true);
    const healthy_trace = try tmp.dir.readFileAlloc(std.testing.io, "healthy.jsonl", std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(healthy_trace);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, healthy_trace, "\"method\":\"tools/call\""));
}

test "production candidate timeout preserves healthy tool RPC and restore" {
    try expectProductionCatalogBudget(false);
}

test "production MCP adds healthy B when an already loaded A reaches its configured timeout" {
    try expectProductionCatalogBudget(true);
}

fn expectProductionCatalogBudget(hanging_loaded: bool) !void {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    const trace = try std.fmt.allocPrint(a, "{s}/budget.jsonl", .{root});
    defer a.free(trace);
    const a_gate = try std.fmt.allocPrint(a, "{s}/a", .{root});
    defer a.free(a_gate);
    const b_gate = try std.fmt.allocPrint(a, "{s}/b", .{root});
    defer a.free(b_gate);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.armed", .data = "armed" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.release", .data = "release" });
    var source_a = try HttpFixture.startWithGate("2026-07-28", "json", trace, 2_000, "text", a_gate);
    defer source_a.deinit();
    var source_b = try HttpFixture.startWithGate("2026-07-28", "json", trace, 2_000, "text", b_gate);
    defer source_b.deinit();
    const runtime = try agent.Runtime.init(std.testing.io, a, .{ .max_sessions = 1 });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    const budget = try mcp_platform.CatalogBudget.init(a, std.testing.io, runtime);
    defer budget.release();
    var preparation = try prepareHttpFixture(source_a.endpoint, "2026-07-28");
    defer preparation.deinit();
    preparation.registry.?.value.servers[0].timeout_ms = 350;
    var initial = try mcp_platform.buildRuntime(std.testing.io, a, &preparation, .{ .catalog_budget = budget });
    defer initial.deinit();
    try budget.begin(0, false);
    const initial_result = runtime.applyMcpConfiguration(&initial.input.?) catch |err| {
        budget.end();
        return err;
    };
    budget.applied();
    budget.end();
    try std.testing.expectEqual(.applied, initial_result);
    const original = switch (try budget.catalog().activate()) {
        .activated => |value| value,
        else => return error.TestUnexpectedResult,
    };
    defer original.deinit();
    if (hanging_loaded) try tmp.dir.deleteFile(std.testing.io, "a.release");
    try tmp.dir.deleteFile(std.testing.io, "a.waiting");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "b.armed", .data = "armed" });
    if (hanging_loaded) try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "b.release", .data = "release" });
    try appendHttpCandidate(&preparation, source_b.endpoint);
    preparation.registry.?.value.generation = 2;
    preparation.registry.?.value.servers[1].timeout_ms = 350;
    preparation.server_states[0] = .disabled;
    var candidate = try mcp_platform.buildRuntime(std.testing.io, a, &preparation, .{ .catalog_budget = budget });
    defer candidate.deinit();
    var input = try runtime.prepareMcpMembership(2, &candidate.input.?, &.{ "deterministic-http", "candidate-http" });
    defer input.deinit();
    try budget.begin(2, false);
    defer budget.end();
    const started = std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds;
    const result = try runtime.applyMcpConfiguration(&input);
    if (hanging_loaded) {
        try std.testing.expectEqual(.applied, result);
        budget.applied();
        const activation = switch (try runtime.activateMcp()) {
            .activated => |value| value,
            else => return error.TestUnexpectedResult,
        };
        defer activation.deinit();
        const selected = try runtime.createMcpAdmissionSelection(activation, &.{ .{ .id = "deterministic-http", .tools = &.{} }, .{ .id = "candidate-http", .tools = &.{"echo"} } });
        defer if (selected) |value| value.deinit();
        try std.testing.expectEqual(@as(usize, 1), selected.?.selectedTools().len);
        try std.testing.expectEqualStrings("candidate-http", selected.?.selectedTools()[0].server_id);
        const waiting = try tmp.dir.readFileAlloc(std.testing.io, "a.waiting", a, .limited(32));
        a.free(waiting);
    } else {
        try std.testing.expectEqual(.rejected, result);
        // Keep the management scope expired while actually executing and
        // restoring a healthy tool. A shared timeout must not poison tools.
        try std.Io.sleep(std.testing.io, .fromMilliseconds(500), .awake);
    }
    try std.testing.expect(std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds - started < 3 * std.time.ns_per_s);
    var probe: RawMcpAdmissionProbe = .{ .api = runtime.api, .runtime = runtime.runtime.?, .workspace = root, .endpoint = if (hanging_loaded) source_b.provider_endpoint else source_a.provider_endpoint, .selector = std.mem.zeroes(wire.McpSelectorV1), .execute_tool = true, .execute_restored_tool = true };
    defer probe.bytes.bytes.deinit(a);
    probe.selector.struct_size = @sizeOf(wire.McpSelectorV1);
    probe.selector.server_binding_identity = agent.mcpBindingIdentity(if (hanging_loaded) "candidate-http" else "deterministic-http");
    probe.selector.tool_name = sdk.bytesView("echo");
    try probe.check(true);
}

test "canonical MCP ABI keeps original Selection usable while a new candidate apply is in flight" {
    try expectMcpAdmissionDuringApply(false);
    try expectMcpAdmissionDuringApply(true);
}

fn expectMcpAdmissionDuringApply(reject_candidate: bool) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const trace = try std.fmt.allocPrint(std.testing.allocator, "{s}/healthy.jsonl", .{root});
    defer std.testing.allocator.free(trace);
    const candidate_trace = try std.fmt.allocPrint(std.testing.allocator, "{s}/candidate.jsonl", .{root});
    defer std.testing.allocator.free(candidate_trace);
    const gate = try std.fmt.allocPrint(std.testing.allocator, "{s}/candidate", .{root});
    defer std.testing.allocator.free(gate);
    var healthy = try HttpFixture.start("2026-07-28", "json", trace);
    defer healthy.deinit();
    var candidate = try HttpFixture.startWithGate("2026-07-28", "json", candidate_trace, 60_000, "text", gate);
    defer candidate.deinit();
    var preparation = try prepareHttpFixture(healthy.endpoint, "2026-07-28");
    defer preparation.deinit();
    var initial_build = try mcp_platform.buildRuntime(std.testing.io, std.testing.allocator, &preparation, .{});
    defer initial_build.deinit();
    const runtime = try agent.Runtime.init(std.testing.io, std.testing.allocator, .{ .max_sessions = 1 });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    try std.testing.expectEqual(.applied, try runtime.applyMcpConfiguration(&initial_build.input.?));
    const activation = switch (try runtime.activateMcp()) {
        .activated => |value| value,
        else => return error.TestUnexpectedResult,
    };
    defer activation.deinit();
    var probe: RawMcpAdmissionProbe = .{
        .api = runtime.api,
        .runtime = runtime.runtime.?,
        .workspace = root,
        .endpoint = healthy.provider_endpoint,
        .selector = std.mem.zeroes(wire.McpSelectorV1),
        .execute_tool = true,
    };
    defer probe.bytes.bytes.deinit(std.testing.allocator);
    probe.selector.struct_size = @sizeOf(wire.McpSelectorV1);
    probe.selector.server_binding_identity = agent.mcpBindingIdentity("deterministic-http");
    probe.selector.tool_name = sdk.bytesView("echo");
    try appendHttpCandidate(&preparation, candidate.endpoint);
    var candidate_build = try mcp_platform.buildRuntime(std.testing.io, std.testing.allocator, &preparation, .{});
    defer candidate_build.deinit();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "candidate.armed", .data = "armed" });
    var apply: ConfigurationApplyProbe = .{ .runtime = runtime, .input = &candidate_build.input.? };
    const thread = try std.Thread.spawn(.{}, ConfigurationApplyProbe.run, .{&apply});
    var joined = false;
    defer if (!joined) {
        tmp.dir.writeFile(std.testing.io, .{ .sub_path = "candidate.release", .data = "release" }) catch {};
        thread.join();
    };
    for (0..1000) |_| {
        _ = tmp.dir.statFile(std.testing.io, "candidate.waiting", .{}) catch {
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
            continue;
        };
        break;
    } else return error.TestUnexpectedResult;
    try std.testing.expect(!apply.done.load(.acquire));
    // The official SDK, rather than Host generation guards, decides whether
    // the previously published selectors remain usable during candidate I/O.
    try probe.check(true);
    try std.testing.expect(!apply.done.load(.acquire));
    const host_selection = activation.takeSelection() orelse return error.TestUnexpectedResult;
    defer host_selection.deinit();
    const host_options: agent.SessionOpenOptions = .{
        .model_binding = .{ .target = .{ .provider_id = "fixture-provider", .protocol = .anthropic_messages, .base_url = healthy.provider_endpoint, .model = "fixture-model" }, .credential = "fixture-credential" },
        .permission_mode = .full_access,
        .shell_policy = .unrestricted,
        .workspace = .{ .canonical_root = root, .trust = .explicitly_trusted },
        .mcp_selection = host_selection,
    };
    try expectHostMcpCreateAndRestore(runtime, host_options);
    try std.testing.expect(!apply.done.load(.acquire));
    const during_apply = try tmp.dir.readFileAlloc(std.testing.io, "healthy.jsonl", std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(during_apply);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, during_apply, "\"method\":\"tools/call\""));
    if (reject_candidate)
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "candidate.fail", .data = "fail" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "candidate.release", .data = "release" });
    thread.join();
    joined = true;
    if (apply.failure) |err| return err;
    try std.testing.expectEqual(if (reject_candidate) agent.McpConfigurationApplyOutcome.rejected else .applied, apply.result.?);
    // Core has settled, while Host has not performed another Activation.
    // Rejection must not need a refresh to make the old selectors usable.
    probe.execute_tool = false;
    probe.execute_restored_tool = true;
    try probe.check(true);
    try expectHostMcpCreateAndRestore(runtime, host_options);
    const settled_trace = try tmp.dir.readFileAlloc(std.testing.io, "healthy.jsonl", std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(settled_trace);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, settled_trace, "\"method\":\"tools/call\""));
}

test "canonical MCP ABI adds a healthy server after an already loaded server becomes unreachable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const first_trace = try std.fmt.allocPrint(std.testing.allocator, "{s}/first.jsonl", .{root});
    defer std.testing.allocator.free(first_trace);
    const next_trace = try std.fmt.allocPrint(std.testing.allocator, "{s}/next.jsonl", .{root});
    defer std.testing.allocator.free(next_trace);
    var first = try HttpFixture.start("2026-07-28", "json", first_trace);
    var first_running = true;
    defer if (first_running) first.deinit();
    var next = try HttpFixture.start("2026-07-28", "json", next_trace);
    defer next.deinit();
    var preparation = try prepareHttpFixture(first.endpoint, "2026-07-28");
    defer preparation.deinit();
    preparation.registry.?.value.servers[0].timeout_ms = 200;
    var initial_build = try mcp_platform.buildRuntime(std.testing.io, std.testing.allocator, &preparation, .{});
    defer initial_build.deinit();
    const runtime = try agent.Runtime.init(std.testing.io, std.testing.allocator, .{ .max_sessions = 1 });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    try std.testing.expectEqual(.applied, try runtime.applyMcpConfiguration(&initial_build.input.?));
    const first_activation = switch (try runtime.activateMcp()) {
        .activated => |value| value,
        else => return error.TestUnexpectedResult,
    };
    defer first_activation.deinit();
    try std.testing.expectEqual(agent.McpActivationState.ready, first_activation.state());
    first.deinit();
    first_running = false;
    try appendHttpCandidate(&preparation, next.endpoint);
    var next_build = try mcp_platform.buildRuntime(std.testing.io, std.testing.allocator, &preparation, .{});
    defer next_build.deinit();
    try std.testing.expectEqual(.applied, try runtime.applyMcpConfiguration(&next_build.input.?));
    const next_activation = switch (try runtime.activateMcp()) {
        .activated => |value| value,
        else => return error.TestUnexpectedResult,
    };
    defer next_activation.deinit();
    var healthy_next = false;
    for (next_activation.serverHealth()) |server| {
        if (std.mem.eql(u8, server.id, "candidate-http")) {
            try std.testing.expectEqual(agent.McpActivationServerState.ready, server.state);
            healthy_next = true;
        }
    }
    try std.testing.expect(healthy_next);
    var probe: RawMcpAdmissionProbe = .{
        .api = runtime.api,
        .runtime = runtime.runtime.?,
        .workspace = root,
        .endpoint = next.provider_endpoint,
        .selector = std.mem.zeroes(wire.McpSelectorV1),
        .execute_tool = true,
    };
    defer probe.bytes.bytes.deinit(std.testing.allocator);
    probe.selector.struct_size = @sizeOf(wire.McpSelectorV1);
    probe.selector.server_binding_identity = agent.mcpBindingIdentity("candidate-http");
    probe.selector.tool_name = sdk.bytesView("echo");
    try probe.check(true);
    const trace = try tmp.dir.readFileAlloc(std.testing.io, "next.jsonl", std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(trace);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, trace, "\"method\":\"tools/call\""));
}

test "canonical MCP shared members survive more than the retired configuration limit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const trace = try std.fmt.allocPrint(std.testing.allocator, "{s}/shared.jsonl", .{root});
    defer std.testing.allocator.free(trace);
    var fixture = try HttpFixture.start("2026-07-28", "json", trace);
    defer fixture.deinit();
    var preparation = try prepareHttpFixture(fixture.endpoint, "2026-07-28");
    defer preparation.deinit();
    var build = try mcp_platform.buildRuntime(std.testing.io, std.testing.allocator, &preparation, .{});
    defer build.deinit();
    const runtime = try agent.Runtime.init(std.testing.io, std.testing.allocator, .{ .max_sessions = 1 });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    try std.testing.expectEqual(.applied, try runtime.applyMcpConfiguration(&build.input.?));
    const connector_context = runtime.mcp_servers.descriptors[0].connector.ctx;
    for (0..150) |_| {
        var input = try runtime.prepareMcpMembership(1, null, &.{"deterministic-http"});
        defer input.deinit();
        try std.testing.expectEqual(.applied, try runtime.applyMcpConfiguration(&input));
        try std.testing.expectEqual(connector_context, runtime.mcp_servers.descriptors[0].connector.ctx);
        try std.testing.expect(runtime.retired_mcp_servers.items.len <= 1);
    }
    const activation = switch (try runtime.activateMcp()) {
        .activated => |value| value,
        else => return error.TestUnexpectedResult,
    };
    defer activation.deinit();
    try std.testing.expectEqual(agent.McpActivationState.ready, activation.state());
    var probe: RawMcpAdmissionProbe = .{ .api = runtime.api, .runtime = runtime.runtime.?, .workspace = root, .endpoint = fixture.provider_endpoint, .selector = std.mem.zeroes(wire.McpSelectorV1), .execute_tool = true };
    defer probe.bytes.bytes.deinit(std.testing.allocator);
    probe.selector.struct_size = @sizeOf(wire.McpSelectorV1);
    probe.selector.server_binding_identity = agent.mcpBindingIdentity("deterministic-http");
    probe.selector.tool_name = sdk.bytesView("echo");
    try probe.check(true);
    const calls = try tmp.dir.readFileAlloc(std.testing.io, "shared.jsonl", std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(calls);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, calls, "\"method\":\"tools/call\""));
}

test "an untrusted report after real MCP adoption retains resources and fences further MCP effects" {
    const CorruptReport = struct {
        var original: wire.RuntimeApplyMcpConfigurationFnV1 = undefined;

        fn apply(runtime: ?*wire.RuntimeHandle, configuration: ?*const wire.McpConfigurationV1, report: ?*wire.McpApplyReportV1, diagnostic: ?*wire.OwnedBytesV1) callconv(.c) u32 {
            const status = original(runtime, configuration, report, diagnostic);
            if (status == wire.STATUS_OK) report.?.reserved[0] = 1;
            return status;
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const trace = try std.fmt.allocPrint(std.testing.allocator, "{s}/uncertain.jsonl", .{root});
    defer std.testing.allocator.free(trace);
    var fixture = try HttpFixture.start("2026-07-28", "json", trace);
    defer fixture.deinit();
    var preparation = try prepareHttpFixture(fixture.endpoint, "2026-07-28");
    defer preparation.deinit();
    var build = try mcp_platform.buildRuntime(std.testing.io, std.testing.allocator, &preparation, .{});
    defer build.deinit();
    const api = try sdk.Api.discover();
    var raw = api.raw.*;
    var mcp_api = raw.mcp.?.*;
    CorruptReport.original = mcp_api.apply_configuration.?;
    mcp_api.apply_configuration = CorruptReport.apply;
    raw.mcp = &mcp_api;
    const runtime = try agent.Runtime.initWithApi(std.testing.io, std.testing.allocator, &raw, .{ .max_sessions = 1 });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    try std.testing.expectError(error.McpConfigurationApplyUncertain, runtime.applyMcpConfiguration(&build.input.?));
    try std.testing.expect(runtime.mcp_configuration_uncertain);
    try std.testing.expectEqual(@as(usize, 0), runtime.mcp_servers.expectedServers().len);
    try std.testing.expectEqual(@as(usize, 1), runtime.retired_mcp_servers.items.len);
    try std.testing.expect(!runtime.retired_mcp_servers.items[0].isQuiescent());
    try std.testing.expectError(error.McpConfigurationApplyUncertain, runtime.activateMcp());
    try std.testing.expectError(error.McpConfigurationApplyUncertain, runtime.prepareMcpMembership(1, null, &.{}));
    // Optional MCP failure does not close ordinary text Session admission.
    const session = try runtime.createSession(.{
        .model_binding = .{ .target = .{ .provider_id = "fixture-provider", .protocol = .anthropic_messages, .base_url = fixture.provider_endpoint, .model = "fixture-model" }, .credential = "fixture-credential" },
        .permission_mode = .full_access,
        .shell_policy = .unrestricted,
        .workspace = .{ .canonical_root = root, .trust = .explicitly_trusted },
    });
    try session.close(.session_close);
    try runtime.releaseClosedSession(session);
}

fn expectHostMcpCreateAndRestore(runtime: *agent.Runtime, options_value: agent.SessionOpenOptions) !void {
    const session = try runtime.createSession(options_value);
    const limits: agent.CheckpointLimits = .{
        .hard_bytes = 1024 * 1024,
        .max_section_bytes = 1024 * 1024,
        .max_string_bytes = 64 * 1024,
        .max_messages = 128,
        .max_blocks_per_message = 128,
        .chunk_bytes = 4096,
    };
    var bytes = RestoreBytes{};
    defer bytes.bytes.deinit(std.testing.allocator);
    var exported = try session.exportCheckpoint(limits, .{ .context = &bytes, .write_fn = RestoreBytes.write }, 0, 0, options_value.model_binding.target.model);
    defer exported.deinit();
    const checkpoint = switch (exported) {
        .success => |value| value,
        .failure => return error.TestUnexpectedResult,
    };
    try session.close(.session_close);
    try runtime.releaseClosedSession(session);
    const restored = try runtime.restoreSessionRoute(.{
        .session = options_value,
        .checkpoint_limits = limits,
        .source = .{ .context = &bytes, .read_fn = RestoreBytes.read },
        .expectation = .{
            .logical_session_id = checkpoint.description.session_id,
            .checkpoint_generation = checkpoint.checkpoint.generation,
            .last_run_id = 0,
            .last_compact_id = 0,
            .model = options_value.model_binding.target.model,
        },
    });
    try std.testing.expectEqual(agent.CheckpointRestoreHealth.complete, restored.report.health);
    try std.testing.expectEqual(@as(u32, 0), restored.report.invalidated_mcp_bindings);
    var inputs = try restored.session.captureRestoreInputs();
    defer inputs.deinit() catch unreachable;
    try std.testing.expect(inputs.mcp != null);
    try restored.session.close(.session_close);
    try runtime.releaseClosedSession(restored.session);
}

test "canonical MCP ABI accepts original selectors during refresh and after publication" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const trace = try std.fmt.allocPrint(std.testing.allocator, "{s}/refresh-trace.jsonl", .{root});
    defer std.testing.allocator.free(trace);
    const gate = try std.fmt.allocPrint(std.testing.allocator, "{s}/refresh", .{root});
    defer std.testing.allocator.free(gate);
    var fixture = try HttpFixture.startWithGate("2026-07-28", "json", trace, 60_000, "text", gate);
    defer fixture.deinit();
    var preparation = try prepareHttpFixture(fixture.endpoint, "2026-07-28");
    defer preparation.deinit();
    var build = try mcp_platform.buildRuntime(std.testing.io, std.testing.allocator, &preparation, .{});
    defer build.deinit();
    const runtime = try agent.Runtime.init(std.testing.io, std.testing.allocator, .{ .max_sessions = 1, .mcp_input = &build.input.? });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    const first = switch (try runtime.activateMcp()) {
        .activated => |value| value,
        else => return error.TestUnexpectedResult,
    };
    defer first.deinit();
    const host_selection = first.takeSelection() orelse return error.TestUnexpectedResult;
    defer host_selection.deinit();
    const host_options: agent.SessionOpenOptions = .{
        .model_binding = .{
            .target = .{ .provider_id = "fixture-provider", .protocol = .anthropic_messages, .base_url = fixture.provider_endpoint, .model = "fixture-model" },
            .credential = "fixture-credential",
        },
        .permission_mode = .full_access,
        .shell_policy = .unrestricted,
        .workspace = .{ .canonical_root = root, .trust = .explicitly_trusted },
        .mcp_selection = host_selection,
    };
    var probe: RawMcpAdmissionProbe = .{
        .api = runtime.api,
        .runtime = runtime.runtime.?,
        .workspace = root,
        .endpoint = fixture.provider_endpoint,
        .selector = std.mem.zeroes(wire.McpSelectorV1),
    };
    defer probe.bytes.bytes.deinit(std.testing.allocator);
    probe.selector.struct_size = @sizeOf(wire.McpSelectorV1);
    probe.selector.server_binding_identity = agent.mcpBindingIdentity("deterministic-http");
    probe.selector.tool_name = sdk.bytesView("echo");
    try probe.check(true);
    const Refresh = struct {
        runtime: *agent.Runtime,
        result: ?agent.McpActivationOutcome = null,
        failure: ?anyerror = null,

        fn run(self: *@This()) void {
            self.result = self.runtime.activateMcp() catch |err| {
                self.failure = err;
                return;
            };
        }
    };
    var refresh: Refresh = .{ .runtime = runtime };
    const thread = try std.Thread.spawn(.{}, Refresh.run, .{&refresh});
    var joined = false;
    defer if (!joined) {
        tmp.dir.writeFile(std.testing.io, .{ .sub_path = "refresh.release", .data = "release" }) catch {};
        thread.join();
        if (refresh.result) |outcome| if (outcome == .activated) outcome.activated.deinit();
    };
    for (0..1000) |_| {
        _ = tmp.dir.statFile(std.testing.io, "refresh.waiting", .{}) catch {
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
            continue;
        };
        break;
    } else return error.TestUnexpectedResult;
    // Qualify Core through the official ABI independently of Host admission
    // guards, using the same selectors and checkpoint in every phase.
    try probe.check(true);
    try std.testing.expectEqual(.available, runtime.restoreAdmission(null));
    try expectHostMcpCreateAndRestore(runtime, host_options);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "refresh.release", .data = "release" });
    thread.join();
    joined = true;
    if (refresh.failure) |err| return err;
    const second = switch (refresh.result.?) {
        .activated => |value| value,
        else => return error.TestUnexpectedResult,
    };
    defer second.deinit();
    try std.testing.expect(first.catalogGeneration() != second.catalogGeneration());
    try probe.check(true);
    try expectHostMcpCreateAndRestore(runtime, host_options);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "refresh.fail", .data = "fail" });
    const failed_server = switch (try runtime.activateMcp()) {
        .activated => |value| value,
        else => return error.TestUnexpectedResult,
    };
    defer failed_server.deinit();
    try std.testing.expectEqual(agent.McpActivationState.unavailable, failed_server.state());
    try probe.check(false);
    try std.testing.expectError(error.StaleMcpSelection, runtime.createSession(host_options));
}

test "real Product MCP allow once asks again across checkpoints and approval modes" {
    try expectProductMcpPermission(false, false);
}

test "real Product refresh progresses while the only Run worker waits for permission and its queue is full" {
    try expectProductMcpPermission(true, false);
}

test "real Product shutdown joins an in-flight MCP refresh while a Run waits for permission" {
    try expectProductMcpPermission(true, true);
}

fn expectProductMcpPermission(refresh_pressure: bool, shutdown_inflight: bool) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);
    try tmp.dir.createDirPath(std.testing.io, "workspace");
    try tmp.dir.createDirPath(std.testing.io, ".agents/skills/fixture");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = ".agents/skills/fixture/SKILL.md",
        .data = "---\nname: fixture\ndescription: MCP permission fixture\n---\nNo additional actions.\n",
    });
    const workspace_root = try tmp.dir.realPathFileAlloc(std.testing.io, "workspace", std.testing.allocator);
    defer std.testing.allocator.free(workspace_root);
    const trace_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/product-repeat-trace.jsonl", .{home});
    defer std.testing.allocator.free(trace_path);
    const gate = try std.fmt.allocPrint(std.testing.allocator, "{s}/pressure", .{home});
    defer std.testing.allocator.free(gate);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "pressure.release", .data = "release" });
    var fixture = try HttpFixture.startWithGate("2025-11-25", "json", trace_path, 60_000, "text", gate);
    defer fixture.deinit();
    var preparation = try prepareHttpFixtureWithNegotiation(fixture.endpoint, "automatic");
    var preparation_owned = true;
    defer if (preparation_owned) preparation.deinit();
    const approved = &preparation.registry.?.value.servers[0];
    const fingerprint = mcp_configuration.connectionFingerprint(approved.*);
    approved.connection_approval = .{ .fingerprint = try preparation.registry.?.arena.allocator().dupe(u8, &fingerprint) };
    var runtime_manifest = (try mcp_configuration.RuntimeManifest.candidate(std.testing.allocator, &preparation)).?;
    var manifest_owned = true;
    defer if (manifest_owned) runtime_manifest.deinit();
    const registry_storage = try std.testing.allocator.alloc(u8, mcp_configuration.max_store_bytes);
    defer std.testing.allocator.free(registry_storage);
    var durable_registry: DurableRegistry = .{ .storage = registry_storage };
    var runtime_build = try mcp_platform.buildRuntime(std.testing.io, std.testing.allocator, &preparation, .{});
    defer runtime_build.deinit();
    const runtime = try agent.Runtime.init(std.testing.io, std.testing.allocator, .{ .max_sessions = 1 });
    var runtime_owned = true;
    defer if (runtime_owned) {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    };
    try std.testing.expectEqual(.applied, try runtime.applyMcpConfiguration(&runtime_build.input.?));
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
    var typed_history: TaskSwitchHistory = .{ .file_store = &history };
    defer typed_history.deinit();
    var enablement = try product_skill.enablement.FileStore.init(std.testing.io, home);
    defer enablement.deinit();
    var vault = TaskSwitchVault{};
    defer for (0..2) |index| std.crypto.secureZero(u8, vault.keys[index][0..vault.lengths[index]]);
    var control = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, .{ .worker_count = 1, .queue_capacity = if (refresh_pressure) 1 else 4, .max_tasks = 1, .max_workspaces = 1 }, .{
        .directories = .{ .canonical_user_home = home },
        .task_persistence = typed_history.capability(),
        .checkpoint_store = .{ .file_store = &checkpoints },
        .skill_enablement = .{ .file_store = &enablement },
        .skill_sources = .{ .restored = .{ .loaded = .{ .ready = .{} } } },
        .mcp = .{ .preparation = &preparation, .activation = activation, .management = managementConfiguration(&durable_registry, &runtime_manifest) },
    });
    preparation_owned = false;
    manifest_owned = false;
    activation_owned = false;
    runtime_owned = false;
    defer shutdownProduct(&control, runtime);
    try control.startCustomProviders(home, vault.port());
    defer control.stopCustomProviders();
    const provider = try configureTaskSwitchProvider(&control, fixture.provider_endpoint, "source-model", .anthropic_messages);
    const workspace = try control.openWorkspace(.{ .workspace_root = workspace_root, .trust = .explicitly_trusted });
    const catalog = try waitTaskSwitchCatalog(&control, workspace, 1);
    const task_id = try control.createTaskInWorkspace(workspace, try control.workspaceEpoch(workspace), provider, catalog.revision, catalog.selection_revision, .{ .interactive = if (refresh_pressure) .manual else .auto_review });
    try std.testing.expectEqual(product_control.TaskMcpAuthorityAtCreation.ready_with_selection, try control.taskMcpAuthority(task_id));
    if (refresh_pressure) {
        const run_id = try @import("lifecycle_fixture").runPreparedTask(&control, task_id, .{ .text = "Call the selected echo tool." });
        defer control.cancel(task_id, run_id) catch {};
        const task = control.task_runtime.find(task_id).?;
        const request_id = pending: {
            for (0..2000) |_| {
                try control.drainAgentEvents();
                control.syncLifecycle();
                var access = try task.runtime.acquireAccess();
                defer access.deinit();
                if (access.pendingUiObservation()) |request| break :pending request.request_id;
                try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
            }
            return error.TestUnexpectedResult;
        };
        const Queued = struct {
            ran: std.atomic.Value(bool) = .init(false),
            fn execute(context: *anyopaque) void {
                const self: *@This() = @ptrCast(@alignCast(context));
                self.ran.store(true, .release);
            }
            fn cancel(_: *anyopaque) void {}
        };
        var queued: Queued = .{};
        try control.executor.enqueue(.{ .identity = &queued, .context = &queued, .execute_fn = Queued.execute, .cancel_fn = Queued.cancel });
        const before = mcp_types.testing.state(&control.mcp.?).activation.?.catalogGeneration();
        try control.refreshMcpCatalog();
        for (0..2000) |_| {
            try control.drainAgentEvents();
            control.syncLifecycle();
            if (mcp_types.testing.state(&control.mcp.?).activation.?.catalogGeneration() != before) break;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        } else return error.TestUnexpectedResult;
        try std.testing.expect(!queued.ran.load(.acquire));
        var access = try task.runtime.acquireAccess();
        const still_pending = access.pendingUiObservation().?;
        try std.testing.expectEqual(request_id, still_pending.request_id);
        access.deinit();
        if (shutdown_inflight) {
            try tmp.dir.deleteFile(std.testing.io, "pressure.release");
            tmp.dir.deleteFile(std.testing.io, "pressure.waiting") catch {};
            defer tmp.dir.writeFile(std.testing.io, .{ .sub_path = "pressure.release", .data = "release" }) catch {};
            try control.refreshMcpCatalog();
            for (0..2000) |_| {
                _ = tmp.dir.statFile(std.testing.io, "pressure.waiting", .{}) catch {
                    try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
                    continue;
                };
                break;
            } else return error.TestUnexpectedResult;
            try std.testing.expectEqual(.running, mcp_types.testing.refreshJob(&control.mcp.?).?.state.load(.acquire));
            const Release = struct {
                directory: std.Io.Dir,
                released: std.atomic.Value(bool) = .init(false),
                fn run(self: *@This()) void {
                    std.Io.sleep(std.testing.io, .fromMilliseconds(50), .awake) catch unreachable;
                    self.released.store(true, .release);
                    self.directory.writeFile(std.testing.io, .{ .sub_path = "pressure.release", .data = "release" }) catch unreachable;
                }
            };
            var release: Release = .{ .directory = tmp.dir };
            const thread = try std.Thread.spawn(.{}, Release.run, .{&release});
            defer thread.join();
            control.shutdownExecutor();
            try std.testing.expect(release.released.load(.acquire));
            try std.testing.expect(!control.mcp.?.hasRefreshJob());
            try std.testing.expectEqual(.shutting_down, mcp_types.testing.state(&control.mcp.?).admission.blocked);
            try std.testing.expect(mcp_types.testing.state(&control.mcp.?).activation == null);
            try std.testing.expectError(error.ExecutorShuttingDown, control.refreshMcpCatalog());
            const trace = try tmp.dir.readFileAlloc(std.testing.io, "product-repeat-trace.jsonl", std.testing.allocator, .limited(1024 * 1024));
            defer std.testing.allocator.free(trace);
            try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, trace, "\"method\":\"tools/call\""));
            return;
        }
        try control.respondUi(task_id, run_id, request_id, .{ .permission = .allow_once });
        for (0..2000) |_| {
            try control.drainAgentEvents();
            control.syncLifecycle();
            if (task.runtime.active_operation == .none and !task.runtime.worker_leases.hasLive() and queued.ran.load(.acquire)) break;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        } else return error.TestUnexpectedResult;
        const trace = try tmp.dir.readFileAlloc(std.testing.io, "product-repeat-trace.jsonl", std.testing.allocator, .limited(1024 * 1024));
        defer std.testing.allocator.free(trace);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, trace, "\"method\":\"tools/call\""));
        return;
    }
    for (0..3) |index| {
        if (index == 2) {
            const task = control.task_runtime.find(task_id).?;
            _ = try control.setApprovalMode(task_id, .manual, task.durable.binding_epoch, task.durable.approval_revision);
            for (0..2000) |_| {
                try control.drainAgentEvents();
                control.syncLifecycle();
                if (task.approval_change == null) break;
                try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
            } else return error.TestUnexpectedResult;
            try std.testing.expectEqual(.manual, try control.taskApprovalMode(task_id));
        }
        const text = if (index == 0) "Call the selected echo tool." else "Call the restored echo tool.";
        try std.testing.expectEqual(@as(usize, 1), try executeTaskSwitchRun(&control, task_id, .{ .text = text }, .allow_once));
    }
    const trace = try tmp.dir.readFileAlloc(std.testing.io, "product-repeat-trace.jsonl", std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(trace);
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, trace, "\"method\":\"tools/call\""));
}

const McpRepeatTiming = enum { valid, expired, refreshed, refreshed_allow, refreshed_deny, schema_changed, expanded, source_replaced };

fn expectRepeatedMcpPermission(protocol_version: []const u8, timing: McpRepeatTiming) !void {
    const expire_between_runs = timing == .expired or timing == .refreshed;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const trace_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/repeat-trace.jsonl", .{root});
    defer std.testing.allocator.free(trace_path);
    const gate = try std.fmt.allocPrint(std.testing.allocator, "{s}/catalog", .{root});
    defer std.testing.allocator.free(gate);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "catalog.release", .data = "release" });
    var fixture = try HttpFixture.startWithGate(protocol_version, "json", trace_path, if (expire_between_runs) 1_000 else 60_000, "text", gate);
    defer fixture.deinit();
    const replacement_trace = try std.fmt.allocPrint(std.testing.allocator, "{s}/replacement-trace.jsonl", .{root});
    defer std.testing.allocator.free(replacement_trace);
    var replacement_fixture: ?HttpFixture = null;
    defer if (replacement_fixture) |*value| value.deinit();
    var preparation = try prepareHttpFixture(fixture.endpoint, protocol_version);
    defer preparation.deinit();
    if (timing == .expanded) preparation.registry.?.value.servers[0].tools = &.{ "echo", "new_echo" };
    var runtime_build = try mcp_platform.buildRuntime(std.testing.io, std.testing.allocator, &preparation, .{});
    defer runtime_build.deinit();
    const runtime = try agent.Runtime.init(std.testing.io, std.testing.allocator, .{
        .max_sessions = 1,
    });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    try std.testing.expectEqual(.applied, try runtime.applyMcpConfiguration(&runtime_build.input.?));
    const activation = switch (try runtime.activateMcp()) {
        .activated => |value| value,
        else => return error.TestUnexpectedResult,
    };
    defer activation.deinit();
    const selection = activation.takeSelection() orelse return error.TestUnexpectedResult;
    defer selection.deinit();
    const session = try runtime.createSession(.{
        .model_binding = .{
            .target = .{
                .provider_id = "fixture-provider",
                .protocol = .anthropic_messages,
                .base_url = fixture.provider_endpoint,
                .model = "fixture-model",
            },
            .credential = "fixture-credential",
        },
        .permission_mode = .accept_edits,
        .shell_policy = .unrestricted,
        .workspace = .{ .canonical_root = root, .trust = .explicitly_trusted },
        .mcp_selection = selection,
    });
    for (0..3) |index| {
        if (index == 1 or (timing == .refreshed_deny and index == 2)) {
            if (expire_between_runs) try std.Io.sleep(std.testing.io, .fromMilliseconds(1_250), .awake);
            if (timing == .schema_changed) try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "catalog.schema", .data = "schema" });
            if (timing == .expanded) try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "catalog.extra", .data = "extra" });
            if (timing == .source_replaced) {
                replacement_fixture = try HttpFixture.start(protocol_version, "json", replacement_trace);
                var replaced_preparation = try prepareHttpFixture(replacement_fixture.?.endpoint, protocol_version);
                defer replaced_preparation.deinit();
                var replaced_build = try mcp_platform.buildRuntime(std.testing.io, std.testing.allocator, &replaced_preparation, .{});
                defer replaced_build.deinit();
                try std.testing.expectEqual(.applied, try runtime.applyMcpConfiguration(&replaced_build.input.?));
            }
            if (timing != .valid and timing != .expired) {
                const refreshed = switch (try runtime.activateMcp()) {
                    .activated => |value| value,
                    else => return error.TestUnexpectedResult,
                };
                if (timing == .expanded) try std.testing.expectEqual(@as(usize, 2), refreshed.catalogTools().len);
                refreshed.deinit();
            }
        }
        const expired = (timing == .expired or timing == .schema_changed) and index > 0;
        const deny = timing == .refreshed_deny and index > 0;
        const run_id = try session.prepareRun(.{ .text = if (index == 0) "Call the selected echo tool." else if (expired) "Call the expired echo tool." else if (deny) "Deny this echo tool." else "Call the restored echo tool." });
        const choice: agent.PermissionChoice = if (deny) .deny_session else if (timing == .refreshed_allow or timing == .source_replaced) .allow_session else .allow_once;
        const result = try runWithPermission(runtime, session, run_id, choice);
        var terminal = result.terminal;
        defer terminal.deinit();
        const cached = (timing == .refreshed_allow and index > 0) or
            (timing == .source_replaced and index > 1) or
            (timing == .refreshed_deny and index == 2);
        try std.testing.expectEqual(@as(usize, if (expired or cached) 0 else 1), result.answers);
        try std.testing.expectEqual(@as(?agent.TerminalFailure, null), terminal.failure);
        try std.testing.expectEqual(@as(?agent.StopReason, .end_turn), terminal.stop_reason);
    }
    const trace = try tmp.dir.readFileAlloc(std.testing.io, "repeat-trace.jsonl", std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(trace);
    const narrowed = timing == .expired or timing == .schema_changed or timing == .refreshed_deny or timing == .source_replaced;
    try std.testing.expectEqual(@as(usize, if (narrowed) 1 else 3), std.mem.count(u8, trace, "\"method\":\"tools/call\""));
    if (timing == .expired or timing == .schema_changed)
        try std.testing.expect(std.mem.indexOf(u8, trace, "permission_denied") != null);
    if (timing == .source_replaced) {
        const replacement_calls = try tmp.dir.readFileAlloc(std.testing.io, "replacement-trace.jsonl", std.testing.allocator, .limited(1024 * 1024));
        defer std.testing.allocator.free(replacement_calls);
        try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, replacement_calls, "\"method\":\"tools/call\""));
    }
}

test "canonical MCP rejected configuration preserves healthy server authority" {
    try expectIsolatedMcpActivation("2026-07-28");
}

test "canonical compatible MCP rejected configuration preserves healthy server authority" {
    try expectIsolatedMcpActivation("2025-11-25");
}

fn expectIsolatedMcpActivation(protocol_version: []const u8) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const trace_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/isolation-trace.jsonl", .{root});
    defer std.testing.allocator.free(trace_path);
    var fixture = try HttpFixture.start(protocol_version, "json", trace_path);
    defer fixture.deinit();
    var stopped = try HttpFixture.start(protocol_version, "json", trace_path);
    const stopped_endpoint = try std.testing.allocator.dupe(u8, stopped.endpoint);
    defer std.testing.allocator.free(stopped_endpoint);
    stopped.deinit();
    var preparation = try prepareHttpFixture(fixture.endpoint, protocol_version);
    defer preparation.deinit();
    var healthy_build = try mcp_platform.buildRuntime(std.testing.io, std.testing.allocator, &preparation, .{});
    defer healthy_build.deinit();
    const registry = &preparation.registry.?;
    const servers = try registry.arena.allocator().alloc(mcp_configuration.ServerWire, 2);
    servers[0] = registry.value.servers[0];
    servers[1] = servers[0];
    servers[1].id = "unreachable-http";
    servers[1].namespace = "unreachable";
    servers[1].transport.url = stopped_endpoint;
    servers[1].timeout_ms = 200;
    registry.value.servers = servers;
    std.testing.allocator.free(preparation.server_states);
    preparation.server_states = try std.testing.allocator.alloc(mcp_configuration.ServerPreparationState, 2);
    @memset(preparation.server_states, .eligible);
    var runtime_build = try mcp_platform.buildRuntime(std.testing.io, std.testing.allocator, &preparation, .{});
    defer runtime_build.deinit();
    const runtime = try agent.Runtime.init(std.testing.io, std.testing.allocator, .{ .max_sessions = 1 });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    try std.testing.expectEqual(.applied, try runtime.applyMcpConfiguration(&healthy_build.input.?));
    try std.testing.expectEqual(.rejected, try runtime.applyMcpConfiguration(&runtime_build.input.?));
    const activation = switch (try runtime.activateMcp()) {
        .activated => |value| value,
        .unavailable => |reason| {
            std.debug.print("MCP isolation activation unavailable: {s}\n", .{@tagName(reason)});
            return error.TestUnexpectedResult;
        },
        .empty => return error.TestUnexpectedResult,
    };
    defer activation.deinit();
    try std.testing.expectEqual(agent.McpActivationState.ready, activation.state());
    try std.testing.expectEqual(@as(usize, 1), activation.serverHealth().len);
    try std.testing.expectEqualStrings("deterministic-http", activation.serverHealth()[0].id);
    try std.testing.expectEqual(agent.McpActivationServerState.ready, activation.serverHealth()[0].state);
    const selection = activation.takeSelection() orelse return error.TestUnexpectedResult;
    defer selection.deinit();
    try std.testing.expectEqual(@as(usize, 1), selection.selectedTools().len);
    try std.testing.expectEqualStrings("deterministic-http", selection.selectedTools()[0].server_id);
}

test "real Product converges healthy members with a rejected candidate in either order" {
    try expectProductIncrementalConvergence(false);
    try expectProductIncrementalConvergence(true);
}

fn expectProductIncrementalConvergence(bad_first: bool) !void {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    const trace = try std.fmt.allocPrint(a, "{s}/converge.jsonl", .{root});
    defer a.free(trace);
    var fixture = try HttpFixture.start("2026-07-28", "json", trace);
    defer fixture.deinit();
    var stopped = try HttpFixture.start("2026-07-28", "json", trace);
    const bad_endpoint = try a.dupe(u8, stopped.endpoint);
    defer a.free(bad_endpoint);
    stopped.deinit();
    var preparation = try mcp_configuration.prepare(a, null, true, false, .{}, product_mcp_limits);
    var preparation_owned = true;
    defer if (preparation_owned) preparation.deinit();
    var manifest = (try mcp_configuration.RuntimeManifest.candidate(a, &preparation)).?;
    var manifest_owned = true;
    defer if (manifest_owned) manifest.deinit();
    const storage = try a.alloc(u8, mcp_configuration.max_store_bytes);
    defer a.free(storage);
    var durable: DurableRegistry = .{ .storage = storage };
    const runtime = try agent.Runtime.init(std.testing.io, a, .{ .max_sessions = 1 });
    var runtime_owned = true;
    defer if (runtime_owned) {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    };
    var control = try product_control.Runtime.init(a, std.testing.io, runtime, .{ .worker_count = 1, .queue_capacity = 4 }, .{ .mcp = .{
        .preparation = &preparation,
        .management = managementConfiguration(&durable, &manifest),
        .host_capabilities = .{ .connection_approval = true },
    } });
    runtime_owned = false;
    preparation_owned = false;
    manifest_owned = false;
    defer shutdownProduct(&control, runtime);
    for (0..2) |index| {
        const bad = (index == 0) == bad_first;
        try std.testing.expectEqual(.saved, (try control.createMcpHttpServer(index, .{ .display_name = if (bad) "Bad" else "Healthy", .url = if (bad) bad_endpoint else fixture.endpoint, .timeout_ms = 200, .negotiation = "modern_only" })).outcome);
    }
    var desired = try mcp_configuration.decode(a, durable.storage[0..durable.len], product_mcp_limits);
    defer desired.deinit();
    const healthy_id = desired.value.servers[if (bad_first) 1 else 0].id;
    try std.testing.expectEqual(.saved, try control.setMcpAllowedTools(2, .{ .server_id = healthy_id, .tools = &.{"echo"} }));
    var attempts: usize = 0;
    while (try control.prepareMcpConfigurationStep(3, .automatic)) |value| {
        var step = value;
        var step_owned = true;
        defer if (step_owned) step.deinit();
        attempts += 1;
        {
            var output: [128 * 1024]u8 = undefined;
            const snapshot = try control.writeAggregateFixture(&output);
            const parsed = try std.json.parseFromSlice(std.json.Value, a, snapshot, .{});
            defer parsed.deinit();
            const projected = parsed.value.object.get("mcp").?.object;
            var applying: usize = 0;
            for (projected.get("servers").?.array.items) |row| {
                if (std.mem.eql(u8, row.object.get("applyStatus").?.string, "applying")) {
                    applying += 1;
                    try std.testing.expectEqualStrings(step.target.id(), row.object.get("id").?.string);
                }
            }
            try std.testing.expectEqual(@as(usize, 1), applying);
        }
        try std.testing.expect(attempts <= 2);
        var candidate = try mcp_configuration.prepare(a, durable.storage[0..durable.len], true, false, .{}, product_mcp_limits);
        defer candidate.deinit();
        for (candidate.registry.?.value.servers, candidate.server_states) |server, *state| {
            if (!std.mem.eql(u8, server.id, step.candidate_id.?)) state.* = .disabled;
        }
        var build = try mcp_platform.buildRuntime(std.testing.io, a, &candidate, .{});
        defer build.deinit();
        var input = try runtime.prepareMcpMembership(3, &build.input.?, step.member_ids);
        defer input.deinit();
        const outcome = try runtime.applyMcpConfiguration(&input);
        if (outcome == .rejected) {
            control.failMcpConfigurationApply(3, .rejected);
            continue;
        }
        try std.testing.expectEqual(.applied, outcome);
        var applied_manifest = (try mcp_configuration.RuntimeManifest.candidate(a, &step.preparation)).?;
        var applied_manifest_owned = true;
        defer if (applied_manifest_owned) applied_manifest.deinit();
        const activation = switch (try runtime.activateMcp()) {
            .activated => |activated| activated,
            else => return error.TestUnexpectedResult,
        };
        const selection = activation.takeSelection();
        const installed = control.completeMcpConfigurationApply(3, &step.preparation, &applied_manifest, activation, selection, false);
        if (!installed) {
            if (selection) |selected| selected.deinit();
            activation.deinit();
            return error.TestUnexpectedResult;
        }
        step_owned = false;
        applied_manifest_owned = false;
    }
    try std.testing.expectEqual(@as(usize, 2), attempts);
    {
        var output: [128 * 1024]u8 = undefined;
        const snapshot = try control.writeAggregateFixture(&output);
        const parsed = try std.json.parseFromSlice(std.json.Value, a, snapshot, .{});
        defer parsed.deinit();
        const projected = parsed.value.object.get("mcp").?.object;
        try std.testing.expectEqual(@as(i64, 1), projected.get("applyFailureCount").?.integer);
        try std.testing.expect(!projected.get("runtimeUncertain").?.bool);
        for (projected.get("servers").?.array.items) |row| {
            const healthy = std.mem.eql(u8, healthy_id, row.object.get("id").?.string);
            try std.testing.expectEqualStrings(if (healthy) "current" else "rejected", row.object.get("applyStatus").?.string);
            try std.testing.expectEqualStrings(if (healthy) "ready" else "not_loaded", row.object.get("runtimeStatus").?.string);
        }
    }
    try std.testing.expectEqual(mcp_configuration.RuntimeAlignment.current, control.inspectMcpDesiredConfiguration().?.runtime_alignment);
    try std.testing.expectEqual(@as(usize, 1), runtime.mcp_servers.expectedServers().len);
    try std.testing.expectEqualStrings(healthy_id, runtime.mcp_servers.expectedServers()[0].id);
    const admission = control.mcp.?.selectionForNewTask();
    try std.testing.expect(admission.available);
    try std.testing.expect(admission.selection != null);
    try expectHostMcpCreateAndRestore(runtime, .{
        .model_binding = .{ .target = .{ .provider_id = "fixture-provider", .protocol = .anthropic_messages, .base_url = fixture.provider_endpoint, .model = "fixture-model" }, .credential = "fixture-credential" },
        .permission_mode = .full_access,
        .shell_policy = .unrestricted,
        .workspace = .{ .canonical_root = root, .trust = .explicitly_trusted },
        .mcp_selection = admission.selection,
    });
    var probe: RawMcpAdmissionProbe = .{ .api = runtime.api, .runtime = runtime.runtime.?, .workspace = root, .endpoint = fixture.provider_endpoint, .selector = std.mem.zeroes(wire.McpSelectorV1), .execute_tool = true };
    defer probe.bytes.bytes.deinit(a);
    probe.selector.struct_size = @sizeOf(wire.McpSelectorV1);
    probe.selector.server_binding_identity = agent.mcpBindingIdentity(healthy_id);
    probe.selector.tool_name = sdk.bytesView("echo");
    try probe.check(true);
    const calls = try tmp.dir.readFileAlloc(std.testing.io, "converge.jsonl", a, .limited(1024 * 1024));
    defer a.free(calls);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, calls, "\"method\":\"tools/call\""));
}

test "real Product cold mixed configuration failure does not invent server network failures" {
    try expectProductAtomicApplyFailure(false);
}

test "real Product adding a bad server preserves formal health and can recover by disabling it" {
    try expectProductAtomicApplyFailure(true);
}

fn expectProductAtomicApplyFailure(healthy_loaded: bool) !void {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    const trace = try std.fmt.allocPrint(a, "{s}/apply-trace.jsonl", .{root});
    defer a.free(trace);
    var fixture = try HttpFixture.start("2026-07-28", "json", trace);
    defer fixture.deinit();
    var stopped = try HttpFixture.start("2026-07-28", "json", trace);
    const bad_endpoint = try a.dupe(u8, stopped.endpoint);
    defer a.free(bad_endpoint);
    stopped.deinit();
    var preparation = try prepareHttpFixture(fixture.endpoint, "2026-07-28");
    var preparation_owned = true;
    defer if (preparation_owned) preparation.deinit();
    const approved = &preparation.registry.?.value.servers[0];
    const fingerprint = mcp_configuration.connectionFingerprint(approved.*);
    approved.connection_approval = .{ .fingerprint = try preparation.registry.?.arena.allocator().dupe(u8, &fingerprint) };
    var healthy_build = try mcp_platform.buildRuntime(std.testing.io, a, &preparation, .{});
    defer healthy_build.deinit();
    const runtime = try agent.Runtime.init(std.testing.io, a, .{ .max_sessions = 1 });
    var runtime_owned = true;
    defer if (runtime_owned) {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    };
    var activation: ?*agent.McpActivation = null;
    var activation_owned = true;
    defer if (activation_owned) {
        if (activation) |value| value.deinit();
    };
    if (healthy_loaded) {
        try std.testing.expectEqual(.applied, try runtime.applyMcpConfiguration(&healthy_build.input.?));
        activation = switch (try runtime.activateMcp()) {
            .activated => |value| value,
            else => return error.TestUnexpectedResult,
        };
    }
    var empty: mcp_configuration.Preparation = .{ .allocator = a, .state = .empty };
    var manifest = (try mcp_configuration.RuntimeManifest.candidate(a, if (healthy_loaded) &preparation else &empty)).?;
    var manifest_owned = true;
    defer if (manifest_owned) manifest.deinit();
    const storage = try a.alloc(u8, mcp_configuration.max_store_bytes);
    defer a.free(storage);
    var durable: DurableRegistry = .{ .storage = storage };
    var control = try product_control.Runtime.init(a, std.testing.io, runtime, .{ .worker_count = 1, .queue_capacity = 4 }, .{ .mcp = .{
        .preparation = &preparation,
        .activation = activation,
        .management = managementConfiguration(&durable, &manifest),
        .host_capabilities = .{ .connection_approval = true },
    } });
    runtime_owned = false;
    preparation_owned = false;
    activation_owned = false;
    manifest_owned = false;
    defer shutdownProduct(&control, runtime);
    try std.testing.expectEqual(.saved, (try control.createMcpHttpServer(1, .{ .display_name = "Unreachable candidate", .url = bad_endpoint, .timeout_ms = 200, .negotiation = "modern_only" })).outcome);
    var candidate = try mcp_configuration.prepare(a, durable.storage[0..durable.len], true, false, .{}, product_mcp_limits);
    defer candidate.deinit();
    const bad_id = try a.dupe(u8, candidate.registry.?.value.servers[1].id);
    defer a.free(bad_id);
    var candidate_build = try mcp_platform.buildRuntime(std.testing.io, a, &candidate, .{});
    defer candidate_build.deinit();
    try control.beginMcpConfigurationApply(2);
    try std.testing.expectEqual(.rejected, try runtime.applyMcpConfiguration(&candidate_build.input.?));
    control.failMcpConfigurationApply(2, .rejected);
    var output: [512 * 1024]u8 = undefined;
    const snapshot = try control.writeAggregateFixture(&output);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, snapshot, .{});
    defer parsed.deinit();
    const mcp = parsed.value.object.get("mcp").?.object;
    try std.testing.expectEqualStrings(if (healthy_loaded) "degraded" else "unavailable", mcp.get("availability").?.string);
    try std.testing.expectEqualStrings("failed", mcp.get("configurationApply").?.string);
    const servers = mcp.get("servers").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), servers.len);
    try std.testing.expectEqualStrings(if (healthy_loaded) "ready" else "not_loaded", servers[0].object.get("runtimeStatus").?.string);
    try std.testing.expectEqualStrings("not_loaded", servers[1].object.get("runtimeStatus").?.string);
    for (servers, 0..) |server, index| {
        try std.testing.expectEqualStrings(if (healthy_loaded) (if (index == 0) "available" else "not_allowed") else "restart_required", server.object.get("newTaskAccess").?.string);
        try std.testing.expect(!std.mem.eql(u8, "Server is unavailable", server.object.get("safeDiagnostic").?.string));
    }
    // A disabled bad descriptor is omitted from the complete candidate. The
    // same atomic apply route can then accept the remaining healthy server.
    try std.testing.expectEqual(.saved, try control.setMcpServerEnabled(2, .{ .server_id = bad_id, .enabled = false }));
    var recovered = try mcp_configuration.prepare(a, durable.storage[0..durable.len], true, false, .{}, product_mcp_limits);
    var recovered_owned = true;
    defer if (recovered_owned) recovered.deinit();
    var recovered_manifest = (try mcp_configuration.RuntimeManifest.candidate(a, &recovered)).?;
    var recovered_manifest_owned = true;
    defer if (recovered_manifest_owned) recovered_manifest.deinit();
    var recovered_build = try mcp_platform.buildRuntime(std.testing.io, a, &recovered, .{});
    defer recovered_build.deinit();
    try control.beginMcpConfigurationApply(3);
    try std.testing.expectEqual(.applied, try runtime.applyMcpConfiguration(&recovered_build.input.?));
    const recovered_activation = switch (try runtime.activateMcp()) {
        .activated => |value| value,
        else => return error.TestUnexpectedResult,
    };
    var recovered_activation_owned = true;
    defer if (recovered_activation_owned) recovered_activation.deinit();
    const selection = recovered_activation.takeSelection();
    var selection_owned = true;
    defer if (selection_owned) {
        if (selection) |value| value.deinit();
    };
    try std.testing.expect(control.completeMcpConfigurationApply(3, &recovered, &recovered_manifest, recovered_activation, selection, false));
    recovered_owned = false;
    recovered_manifest_owned = false;
    recovered_activation_owned = false;
    selection_owned = false;
    const recovered_snapshot = try control.writeAggregateFixture(&output);
    try std.testing.expect(std.mem.indexOf(u8, recovered_snapshot, "\"availability\":\"ready\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, recovered_snapshot, "\"configurationApply\":\"idle\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, recovered_snapshot, "\"runtimeStatus\":\"disabled\"") != null);
    try std.testing.expectEqual(.saved, try control.updateMcpHttpConnection(3, .{
        .server_id = "deterministic-http",
        .display_name = "Replaced origin",
        .negotiation = "modern_only",
        .timeout_ms = 2000,
        .url = bad_endpoint,
        .auth_mode = .none,
    }));
    const replaced_snapshot = try control.writeAggregateFixture(&output);
    try std.testing.expect(std.mem.indexOf(u8, replaced_snapshot, "\"runtimeStatus\":\"ready\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, replaced_snapshot, "\"discovered\":true") == null);
    try std.testing.expect(std.mem.indexOf(u8, replaced_snapshot, "\"availability\":\"unavailable\"") != null);
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

fn expectSelectedHttpToolResult(result_kind: []const u8, framing: []const u8) !void {
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
    var fixture = try HttpFixture.startWithResult("2026-07-28", framing, trace_path, 60_000, result_kind);
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
        var while_refreshing = try product_mcp.restoreAuthority(saved.mcp.?);
        defer while_refreshing.deinit();
        try std.testing.expect(while_refreshing.selection != null);
        try std.testing.expectEqual(@as(usize, 1), while_refreshing.selection.?.selectedTools().len);
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
    if (std.mem.eql(u8, framing, "ping")) {
        const pings = std.mem.count(u8, trace, "\"direction\":\"ping\"");
        try std.testing.expect(pings != 0);
        try std.testing.expectEqual(pings, std.mem.count(u8, trace, "\"direction\":\"pong\""));
        try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, trace, "\"direction\":\"error\""));
    }
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
    try expectMcpProductAdmission("2026-07-28", .streamable_http);
}

test "compatible MCP product chain admits a new Task after tool authorization" {
    try expectMcpProductAdmission("2025-11-25", .streamable_http);
}

test "2025-06-18 MCP product chain admits a new Task after tool authorization" {
    try expectMcpProductAdmission("2025-06-18", .streamable_http);
}

test "healthy STDIO catalog expiry and paused refresh never revive startup diagnostics" {
    try expectMcpProductAdmission("2026-07-28", .stdio);
}

test "compatible STDIO MCP product chain admits a new Task after tool authorization" {
    try expectMcpProductAdmission("2025-11-25", .stdio);
}

test "real Product creates a null MCP Task after Core withdrawal before Host publication" {
    try expectMcpProductAdmissionCase("2026-07-28", .streamable_http, .core_withdrawal);
}

test "real Product creates a null MCP Task when Admission exceeds the bounded generation handoff" {
    try expectMcpProductAdmissionCase("2026-07-28", .streamable_http, .stale_host);
}

test "real Product proactive refresh preserves new Task authority and quiet background projection" {
    try expectMcpProductAdmissionCase("2026-07-28", .streamable_http, .proactive);
}

test "real Product HTTP429 refresh retries are bounded and explicit refresh resumes" {
    try expectMcpProductAdmissionCase("2026-07-28", .streamable_http, .rate_limit);
}

test "real Product retains disabled members for Task restore and removes the last reference" {
    try expectMcpProductAdmissionCase("2026-07-28", .streamable_http, .retain_disabled);
}

test "real Product retains deleted members for Task restore without reviving revoked grants" {
    try expectMcpProductAdmissionCase("2026-07-28", .streamable_http, .retain_deleted);
    try expectMcpProductAdmissionCase("2026-07-28", .streamable_http, .revoked_then_deleted);
}

test "real Product editing a disabled referenced member keeps the applied version" {
    try expectMcpProductAdmissionCase("2026-07-28", .streamable_http, .disabled_edit);
}

test "real Product keeps B admission when a retained unselected A reaches its earlier TTL" {
    try expectMcpProductAdmissionCase("2026-07-28", .streamable_http, .unrelated_expiry);
}

test "real Product narrows selected A on expiry and admits a Task with still-fresh B" {
    try expectMcpProductAdmissionCase("2026-07-28", .streamable_http, .selected_expiry);
}

const McpCreationRace = enum { expiry, core_withdrawal, stale_host, proactive, rate_limit, retain_disabled, retain_deleted, revoked_then_deleted, disabled_edit, unrelated_expiry, selected_expiry };

fn expectMcpProductAdmission(protocol_version: []const u8, transport: agent.McpTransportKind) !void {
    try expectMcpProductAdmissionCase(protocol_version, transport, .expiry);
}

fn expectMcpProductAdmissionCase(protocol_version: []const u8, transport: agent.McpTransportKind, race: McpCreationRace) !void {
    try expectMcpProductAdmissionWithAuth(protocol_version, transport, race, false);
}

test "static HTTP header and STDIO env reach a new Product Task real MCP call" {
    try expectMcpProductAdmissionWithAuth("2025-11-25", .streamable_http, .expiry, true);
    try expectMcpProductAdmissionWithAuth("2025-11-25", .stdio, .expiry, true);
}

fn verifyProtectedHttpDraft(workbench: *product_control.Runtime, registry: *DurableRegistry, endpoint: []const u8) !mcp_configuration.CreateResult {
    const header = "Bearer mcp-static-fixture-secret";
    var draft = try workbench.prepareMcpHttpDraftCreate(0, "Deterministic HTTP", endpoint, &.{.{
        .name = "Authorization",
        .value = header,
    }});
    defer draft.deinit();
    if (draft != .prepared) return error.TestUnexpectedResult;
    var candidate = (try draft.prepared.httpDraftPreparation(product_mcp_limits)) orelse return error.TestUnexpectedResult;
    defer candidate.deinit();
    var built = try mcp_platform.buildRuntime(std.testing.io, std.testing.allocator, &candidate, .{});
    defer built.deinit();
    const runtime = try agent.Runtime.init(std.testing.io, std.testing.allocator, .{ .max_sessions = 1, .mcp_input = &built.input.? });
    defer runtime.deinit();
    defer runtime.shutdown() catch unreachable;
    const activation = switch (try runtime.activateMcp()) {
        .activated => |value| value,
        else => return error.TestUnexpectedResult,
    };
    defer activation.deinit();
    try std.testing.expectEqual(agent.McpActivationState.ready, activation.state());
    try std.testing.expectEqual(@as(usize, 0), registry.len);
    try std.testing.expectEqual(@as(usize, 0), registry.credential_len);
    const port = workbench.mcpManagementPort();
    const result = try port.commit_http_draft_fn(port.context, 0, &draft);
    try std.testing.expectEqualStrings(header, registry.credential[0..registry.credential_len]);
    try std.testing.expect(std.mem.indexOf(u8, registry.storage[0..registry.len], header) == null);
    return result;
}

fn expectMcpProductAdmissionWithAuth(protocol_version: []const u8, transport: agent.McpTransportKind, race: McpCreationRace, static_auth: bool) !void {
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
    const gate = try std.fmt.allocPrint(std.testing.allocator, "{s}/publication", .{root_storage[0..root_len]});
    defer std.testing.allocator.free(gate);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "publication.release", .data = "release" });
    var fixture = try HttpFixture.startWithBearer(protocol_version, "json", trace_path, 2_000, "text", gate, 0, if (static_auth and transport == .streamable_http) "mcp-static-fixture-secret" else "");
    defer fixture.deinit();
    const registry_storage = try std.testing.allocator.alloc(
        u8,
        mcp_configuration.max_store_bytes,
    );
    defer std.testing.allocator.free(registry_storage);
    var durable_registry: DurableRegistry = .{ .storage = registry_storage };
    defer std.crypto.secureZero(u8, &durable_registry.credential);

    const initial_runtime = try agent.Runtime.init(
        std.testing.io,
        std.testing.allocator,
        .{ .max_sessions = 2 },
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
        if (transport == .stdio) (try initial_workbench.createMcpStdioServer(0, .{
            .display_name = "Deterministic STDIO",
            .negotiation = "automatic",
            .timeout_ms = 2000,
            .command = options.node_path,
            .arguments = if (static_auth) &.{ options.fixture_path, "--protocol", protocol_version, "--trace", trace_path, "--require-env" } else &.{ options.fixture_path, "--protocol", protocol_version, "--trace", trace_path, "--ttl-ms", "2000" },
            .auth_mode = if (static_auth) .static else .none,
            .environment_names = if (static_auth) &.{"MCP_FIXTURE_TOKEN"} else &.{},
        })).outcome else if (static_auth) (try verifyProtectedHttpDraft(&initial_workbench, &durable_registry, fixture.endpoint)).outcome else (try initial_workbench.createMcpHttpServer(0, .{
            .display_name = "Deterministic HTTP",
            .negotiation = if (std.mem.eql(u8, protocol_version, "2026-07-28")) "modern_only" else "automatic",
            .timeout_ms = 2000,
            .url = fixture.endpoint,
        })).outcome,
    );
    var created = try mcp_configuration.decode(
        std.testing.allocator,
        durable_registry.storage[0..durable_registry.len],
        product_mcp_limits,
    );
    const server_id = try std.testing.allocator.dupe(u8, created.value.servers[0].id);
    created.deinit();
    defer std.testing.allocator.free(server_id);
    if (static_auth and transport == .stdio) {
        var secret_buffer: [128]u8 = undefined;
        const secret = try std.fmt.bufPrint(&secret_buffer, "mcp-static-fixture-secret", .{});
        try std.testing.expectEqual(.saved, try initial_workbench.captureMcpStaticSecret(1, .{ .server_id = server_id, .slot_name = "MCP_FIXTURE_TOKEN", .secret = secret }));
        for (secret) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
        try std.testing.expect(std.mem.indexOf(u8, durable_registry.storage[0..durable_registry.len], "mcp-static-fixture-secret") == null);
    }

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
        durable_registry.resolver(),
        product_mcp_limits,
    );
    var restarted_preparation_owned = true;
    errdefer if (restarted_preparation_owned) restarted_preparation.deinit();
    var runtime_build = try mcp_platform.buildRuntime(
        std.testing.io,
        std.testing.allocator,
        &restarted_preparation,
        .{
            .executable_search_path = std.fs.path.dirname(options.node_path),
            .windows_system_root = options.windows_system_root,
        },
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
            .max_sessions = 3,
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
            .directories = .{ .canonical_user_home = if (static_auth) root_storage[0..root_len] else null },
            .skill_sources = if (static_auth) .{ .restored = .{ .loaded = .{ .ready = .{} } } } else .{},
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
    if (!static_auth) try installExecution(&restarted_workbench);
    try std.testing.expect(refresh_timer.armed_at_ms != null);
    try std.testing.expect(refresh_timer.arm_count > 0);
    try std.testing.expectEqual(
        mcp_configuration.ManagementOutcome.saved,
        try restarted_workbench.setMcpAllowedTools(if (static_auth and transport == .stdio) 2 else 1, .{
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
    var vault: TaskSwitchVault = .{};
    defer for (&vault.keys) |*key| std.crypto.secureZero(u8, key);
    defer if (static_auth) restarted_workbench.stopCustomProviders();
    const model_selection = if (static_auth) model: {
        try restarted_workbench.startCustomProviders(root_storage[0..root_len], vault.port());
        break :model try configureTaskSwitchProvider(&restarted_workbench, fixture.provider_endpoint, "source-model", .anthropic_messages);
    } else try product_control.TestSupport.fixtureModelSelection(&restarted_workbench);
    const fresh_task_id = try restarted_workbench.createTaskInWorkspace(workspace_id, workspace_epoch, model_selection, null, null, .{ .interactive = if (static_auth) .manual else null });
    try std.testing.expectEqual(
        product_control.TaskMcpAuthorityAtCreation.ready_with_selection,
        try restarted_workbench.taskMcpAuthority(fresh_task_id),
    );
    if (static_auth) {
        const run_id = try @import("lifecycle_fixture").runPreparedTask(&restarted_workbench, fresh_task_id, .{ .text = "Call the selected echo tool." });
        const task = restarted_workbench.task_runtime.find(fresh_task_id).?;
        var previous: ?u64 = null;
        for (0..10000) |_| {
            try restarted_workbench.drainAgentEvents();
            restarted_workbench.syncLifecycle();
            var access = try task.runtime.acquireAccess();
            defer access.deinit();
            if (access.pendingUiObservation()) |request| if (previous == null or previous.? != request.request_id) {
                try restarted_workbench.respondUi(fresh_task_id, run_id, request.request_id, .{ .permission = .allow_once });
                previous = request.request_id;
            };
            if (task.runtime.active_operation == .none and !task.runtime.worker_leases.hasLive()) {
                const run = product_task.testing.state_module.findRun(task.durable.runs, run_id).?;
                try std.testing.expectEqual(.completed, product_task.testing.state_module.productTerminalFacts(run).?.outcome);
                break;
            }
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        } else return error.TestUnexpectedResult;
        const trace = try tmp.dir.readFileAlloc(std.testing.io, "product-trace.jsonl", std.testing.allocator, .limited(4 * 1024 * 1024));
        defer std.testing.allocator.free(trace);
        try std.testing.expect(std.mem.indexOf(u8, trace, "tools/call") != null);
        try std.testing.expect(std.mem.indexOf(u8, trace, "mcp-static-fixture-secret") == null);
        return;
    }
    if (transport == .stdio and std.mem.eql(u8, protocol_version, "2026-07-28")) {
        const server = mcp_types.testing.state(&restarted_workbench.mcp.?).management.?.desiredRegistry().?.servers[0];
        var observation: mcp_configuration.ProcessObservation = .{ .server_id = server_id, .source = mcp_configuration.runtimeDescriptorFingerprint(server), .attempt = 1, .fact = .pending };
        try std.testing.expect(try restarted_workbench.mcp.?.observeProcess(observation));
        observation.fact = .spawned;
        try std.testing.expect(try restarted_workbench.mcp.?.observeProcess(observation));
        var output: [512 * 1024]u8 = undefined;
        const ready = try restarted_workbench.writeAggregateFixture(&output);
        try std.testing.expect(std.mem.indexOf(u8, ready, "\"runtimeStatus\":\"ready\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, ready, "did not complete the MCP handshake") == null);
    }
    if (race == .retain_disabled or race == .retain_deleted or race == .revoked_then_deleted or race == .disabled_edit) {
        const mcp = &restarted_workbench.mcp.?;
        const task = restarted_workbench.task_runtime.find(fresh_task_id).?;
        var access = try task.runtime.acquireAccess();
        var original = access.captureRestoreInputs() catch |err| {
            access.deinit();
            return err;
        };
        access.deinit();
        defer original.deinit() catch unreachable;
        try std.testing.expectEqual(@as(u32, 1), mcp.state.management.?.runtime_manifest.?.entries[0].task_references);
        if (race == .retain_disabled) {
            var extra_tasks: [2]u64 = undefined;
            for (&extra_tasks) |*extra| extra.* = try restarted_workbench.createTaskInWorkspace(workspace_id, workspace_epoch, try product_control.TestSupport.fixtureModelSelection(&restarted_workbench), null, null, .{ .interactive = null });
            try std.testing.expectEqual(@as(u32, 3), mcp.state.management.?.runtime_manifest.?.entries[0].task_references);
            try std.testing.expectError(error.SessionCapacity, restarted_workbench.createTaskInWorkspace(workspace_id, workspace_epoch, try product_control.TestSupport.fixtureModelSelection(&restarted_workbench), null, null, .{ .interactive = null }));
            try std.testing.expectEqual(@as(u32, 3), mcp.state.management.?.runtime_manifest.?.entries[0].task_references);
            for (extra_tasks) |extra| {
                try restarted_workbench.deleteTask(extra);
                for (0..2000) |_| {
                    try restarted_workbench.drainAgentEvents();
                    restarted_workbench.syncLifecycle();
                    if (restarted_workbench.task_runtime.find(extra) == null) break;
                    try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
                } else return error.TestUnexpectedResult;
            }
            try std.testing.expectEqual(@as(u32, 1), mcp.state.management.?.runtime_manifest.?.entries[0].task_references);
        }
        if (race == .revoked_then_deleted)
            try std.testing.expectEqual(.saved, try restarted_workbench.setMcpAllowedTools(2, .{ .server_id = server_id, .tools = &.{} }));
        var generation = restarted_workbench.inspectMcpDesiredConfiguration().?.desired_generation.?;
        if (race == .retain_deleted or race == .revoked_then_deleted) {
            try std.testing.expectEqual(.saved, try restarted_workbench.removeMcpServer(generation, server_id));
        } else {
            try std.testing.expectEqual(.saved, try restarted_workbench.setMcpServerEnabled(generation, .{ .server_id = server_id, .enabled = false }));
        }
        generation = restarted_workbench.inspectMcpDesiredConfiguration().?.desired_generation.?;
        if (race == .disabled_edit) {
            try std.testing.expectEqual(.saved, try restarted_workbench.updateMcpHttpConnection(generation, .{ .server_id = server_id, .display_name = "Edited disabled", .negotiation = "modern_only", .timeout_ms = 2_000, .url = "https://disabled.example.test/mcp", .auth_mode = .none }));
            generation += 1;
        }
        try std.testing.expectEqual(mcp_configuration.RuntimeAlignment.current, restarted_workbench.inspectMcpDesiredConfiguration().?.runtime_alignment);
        try std.testing.expect((try restarted_workbench.prepareMcpConfigurationStep(generation, .automatic)) == null);
        {
            var output: [128 * 1024]u8 = undefined;
            const snapshot = try restarted_workbench.writeAggregateFixture(&output);
            const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, snapshot, .{});
            defer parsed.deinit();
            const projected = parsed.value.object.get("mcp").?.object;
            try std.testing.expectEqual(@as(i64, 1), projected.get("retainedMemberCount").?.integer);
            const rows = projected.get("servers").?.array.items;
            if (race == .retain_deleted or race == .revoked_then_deleted) {
                try std.testing.expectEqual(@as(usize, 0), rows.len);
            } else {
                try std.testing.expectEqual(@as(usize, 1), rows.len);
                try std.testing.expectEqual(@as(i64, 1), rows[0].object.get("taskReferenceCount").?.integer);
                try std.testing.expectEqualStrings("current", rows[0].object.get("applyStatus").?.string);
                try std.testing.expectEqualStrings("disabled", rows[0].object.get("runtimeStatus").?.string);
            }
        }
        // Retained membership must still produce a fresh, complete catalog
        // after Desired removal/edit; its tools remain excluded from new Tasks.
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "publication.release", .data = "release" });
        const previous_generation = mcp.state.activation.?.catalogGeneration();
        refresh_timer.now_ms = @max(refresh_timer.now_ms, mcp.state.refresh_not_before_ms orelse refresh_timer.now_ms);
        restarted_workbench.refreshMcpCatalog() catch |err| switch (err) {
            error.CatalogLoading => try std.testing.expect(mcp.hasRefreshJob() or mcp.state.refresh_pending),
            else => return err,
        };
        if (mcp.state.refresh_pending and !mcp.hasRefreshJob()) restarted_workbench.onMcpRefreshTimer();
        for (0..2000) |_| {
            try restarted_workbench.drainAgentEvents();
            restarted_workbench.syncLifecycle();
            if (!mcp.hasRefreshJob() and !mcp.state.refresh_pending) break;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        } else return error.TestUnexpectedResult;
        try std.testing.expect(mcp.state.activation != null);
        try std.testing.expect(mcp.state.activation.?.catalogGeneration() != previous_generation);
        const admission = mcp.selectionForNewTask();
        try std.testing.expect(admission.available);
        try std.testing.expect(admission.selection == null or admission.selection.?.selectedTools().len == 0);
        var restored = try mcp.restoreAuthorityForTask(fresh_task_id, original.mcp);
        defer restored.deinit();
        try std.testing.expectEqual(@as(usize, if (race == .revoked_then_deleted) 0 else 1), restored.selection.?.selectedTools().len);
        if (race != .revoked_then_deleted) {
            var probe: RawMcpAdmissionProbe = .{ .api = restarted_runtime.api, .runtime = restarted_runtime.runtime.?, .workspace = workspace_root, .endpoint = fixture.provider_endpoint, .selector = std.mem.zeroes(wire.McpSelectorV1), .execute_tool = true, .execute_restored_tool = true };
            defer probe.bytes.bytes.deinit(std.testing.allocator);
            probe.selector.struct_size = @sizeOf(wire.McpSelectorV1);
            probe.selector.server_binding_identity = agent.mcpBindingIdentity(server_id);
            probe.selector.tool_name = sdk.bytesView("echo");
            try probe.check(true);
        }
        try restarted_workbench.deleteTask(fresh_task_id);
        for (0..2000) |_| {
            try restarted_workbench.drainAgentEvents();
            restarted_workbench.syncLifecycle();
            if (restarted_workbench.task_runtime.find(fresh_task_id) == null) break;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        } else return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(u32, 0), mcp.state.management.?.runtime_manifest.?.entries[0].task_references);
        var removal = (try restarted_workbench.prepareMcpConfigurationStep(generation, .automatic)).?;
        var removal_owned = true;
        defer if (removal_owned) removal.deinit();
        try std.testing.expectEqual(.remove, removal.target.kind);
        var input = try restarted_runtime.prepareMcpMembership(generation, null, removal.member_ids);
        defer input.deinit();
        try std.testing.expectEqual(.applied, try restarted_runtime.applyMcpConfiguration(&input));
        var removed_manifest = (try mcp_configuration.RuntimeManifest.candidate(std.testing.allocator, &removal.preparation)).?;
        var removed_manifest_owned = true;
        defer if (removed_manifest_owned) removed_manifest.deinit();
        try std.testing.expect(try restarted_runtime.activateMcp() == .empty);
        try std.testing.expect(restarted_workbench.completeMcpConfigurationApply(generation, &removal.preparation, &removed_manifest, null, null, false));
        removal_owned = false;
        removed_manifest_owned = false;
        try std.testing.expectEqual(@as(usize, 0), restarted_runtime.mcp_servers.expectedServers().len);
        try std.testing.expectError(error.RecoveryUnavailable, mcp.restoreAuthorityForTask(fresh_task_id, original.mcp));
        try std.testing.expect((try mcp.restoreAuthorityForTask(fresh_task_id, null)).selection == null);
        return;
    }
    if (race == .unrelated_expiry or race == .selected_expiry) {
        // Keep both metadata sources healthy. Only A's shorter observation
        // expires in Product's clock; A is retained for the original Task.
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "publication.release", .data = "release" });
        // The workspace is the repository; fixture files belong in tmp.
        const fixture_root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(fixture_root);
        const b_trace = try std.fmt.allocPrint(std.testing.allocator, "{s}/b.jsonl", .{fixture_root});
        defer std.testing.allocator.free(b_trace);
        const b_gate = try std.fmt.allocPrint(std.testing.allocator, "{s}/healthy-b", .{fixture_root});
        defer std.testing.allocator.free(b_gate);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "healthy-b.release", .data = "release" });
        var healthy_b = try HttpFixture.startWithGate("2026-07-28", "json", b_trace, 5_000, "text", b_gate);
        defer healthy_b.deinit();
        try std.testing.expectEqual(.saved, (try restarted_workbench.createMcpHttpServer(2, .{ .display_name = "Healthy B", .url = healthy_b.endpoint, .negotiation = "modern_only" })).outcome);
        var current = try mcp_configuration.decode(std.testing.allocator, durable_registry.storage[0..durable_registry.len], product_mcp_limits);
        defer current.deinit();
        const b_id = current.value.servers[1].id;
        try std.testing.expectEqual(.saved, try restarted_workbench.setMcpAllowedTools(3, .{ .server_id = b_id, .tools = &.{"echo"} }));
        if (race == .unrelated_expiry)
            try std.testing.expectEqual(.saved, try restarted_workbench.setMcpServerEnabled(4, .{ .server_id = server_id, .enabled = false }));
        const generation = restarted_workbench.inspectMcpDesiredConfiguration().?.desired_generation.?;
        var step = (try restarted_workbench.prepareMcpConfigurationStep(generation, .automatic)).?;
        var step_owned = true;
        defer if (step_owned) step.deinit();
        var candidate = try mcp_configuration.prepare(std.testing.allocator, durable_registry.storage[0..durable_registry.len], true, false, .{}, product_mcp_limits);
        defer candidate.deinit();
        for (candidate.registry.?.value.servers, candidate.server_states) |server, *state|
            if (!std.mem.eql(u8, server.id, b_id)) {
                state.* = .disabled;
            };
        var built = try mcp_platform.buildRuntime(std.testing.io, std.testing.allocator, &candidate, .{});
        defer built.deinit();
        var input = try restarted_runtime.prepareMcpMembership(generation, &built.input.?, step.member_ids);
        defer input.deinit();
        try std.testing.expectEqual(.applied, try restarted_runtime.applyMcpConfiguration(&input));
        const activated = switch (try restarted_runtime.activateMcp()) {
            .activated => |value| value,
            else => return error.TestUnexpectedResult,
        };
        if (activated.takeSelection()) |old| old.deinit();
        const allowlists = try std.testing.allocator.alloc(agent.McpServerAllowlist, step.grants.len);
        defer std.testing.allocator.free(allowlists);
        for (step.grants, allowlists) |grant, *allowlist| allowlist.* = .{ .id = grant.id, .tools = grant.tools };
        const selected = try restarted_runtime.createMcpAdmissionSelection(activated, allowlists);
        var applied = (try mcp_configuration.RuntimeManifest.candidate(std.testing.allocator, &step.preparation)).?;
        var applied_owned = true;
        defer if (applied_owned) applied.deinit();
        try std.testing.expect(restarted_workbench.completeMcpConfigurationApply(generation, &step.preparation, &applied, activated, selected, false));
        step_owned = false;
        applied_owned = false;
        const mcp = &restarted_workbench.mcp.?;
        if (race == .selected_expiry) try std.testing.expectEqual(@as(usize, 2), mcp.selectionForNewTask().selection.?.selectedTools().len);
        refresh_timer.now_ms += 2_500;
        try std.testing.expect(mcp.state.refresh_deadline_ms.? <= refresh_timer.now_ms);
        if (race == .selected_expiry) try std.testing.expect(mcp.state.expiry_deadline_ms.? <= refresh_timer.now_ms);
        const admission = mcp.selectionForNewTask();
        try std.testing.expect(mcp.state.expiry_deadline_ms.? > refresh_timer.now_ms);
        try std.testing.expect(admission.available);
        try std.testing.expectEqual(@as(usize, 1), admission.selection.?.selectedTools().len);
        try std.testing.expectEqualStrings(b_id, admission.selection.?.selectedTools()[0].server_id);
        const next_task = try restarted_workbench.createTaskInWorkspace(workspace_id, workspace_epoch, try product_control.TestSupport.fixtureModelSelection(&restarted_workbench), null, null, .{ .interactive = null });
        try std.testing.expectEqual(product_control.TaskMcpAuthorityAtCreation.ready_with_selection, try restarted_workbench.taskMcpAuthority(next_task));
        for (mcp.state.task_references.items) |reference| if (reference.task_id == next_task) {
            try std.testing.expectEqual(@as(usize, 1), reference.tools.len);
            try std.testing.expectEqualStrings(b_id, reference.tools[0].server_id);
        };
        shutdownProduct(&restarted_workbench, restarted_runtime);
        restarted_product_live = false;
        return;
    }
    if (race == .rate_limit) {
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "publication.rate_limit", .data = "429" });
        for (0..5) |attempt| {
            refresh_timer.now_ms = refresh_timer.armed_at_ms.?;
            restarted_workbench.onMcpRefreshTimer();
            for (0..2000) |_| {
                try restarted_workbench.drainAgentEvents();
                restarted_workbench.syncLifecycle();
                if (!restarted_workbench.mcp.?.hasRefreshJob() and mcp_types.testing.state(&restarted_workbench.mcp.?).refresh_failures == attempt + 1) break;
                try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
            } else return error.TestUnexpectedResult;
            if (attempt < 4) {
                const delay = @as(u64, 1_000) << @as(u6, @intCast(attempt));
                try std.testing.expectEqual(refresh_timer.now_ms + delay, refresh_timer.armed_at_ms.?);
            }
        }
        const state = mcp_types.testing.state(&restarted_workbench.mcp.?);
        try std.testing.expect(state.refresh_paused);
        try std.testing.expect(!restarted_workbench.mcp.?.authorityStable());
        const rejected = try tmp.dir.readFileAlloc(std.testing.io, "product-trace.jsonl", std.testing.allocator, .limited(1024 * 1024));
        defer std.testing.allocator.free(rejected);
        try std.testing.expectEqual(@as(usize, 5), std.mem.count(u8, rejected, "\"direction\":\"rate_limited\""));
        const lists_before = std.mem.count(u8, rejected, "\"method\":\"tools/list\"");
        refresh_timer.now_ms += 60_000;
        for (0..10) |_| {
            restarted_workbench.onMcpRefreshTimer();
            _ = restarted_workbench.mcp.?.selectionForNewTask();
        }
        const unavailable_task = try restarted_workbench.createTaskInWorkspace(workspace_id, workspace_epoch, try product_control.TestSupport.fixtureModelSelection(&restarted_workbench), null, null, .{ .interactive = null });
        try std.testing.expectEqual(.unavailable, try restarted_workbench.taskMcpAuthority(unavailable_task));
        try std.testing.expect(state.refresh_paused);
        try std.testing.expect(!restarted_workbench.mcp.?.hasRefreshJob());
        const paused = try tmp.dir.readFileAlloc(std.testing.io, "product-trace.jsonl", std.testing.allocator, .limited(1024 * 1024));
        defer std.testing.allocator.free(paused);
        try std.testing.expectEqual(lists_before, std.mem.count(u8, paused, "\"method\":\"tools/list\""));
        try tmp.dir.deleteFile(std.testing.io, "publication.rate_limit");
        try restarted_workbench.refreshMcpCatalog();
        for (0..2000) |_| {
            try restarted_workbench.drainAgentEvents();
            restarted_workbench.syncLifecycle();
            if (!restarted_workbench.mcp.?.hasRefreshJob() and restarted_workbench.mcp.?.authorityStable()) break;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        } else return error.TestUnexpectedResult;
        try std.testing.expect(!state.refresh_paused);
        try std.testing.expectEqual(@as(u8, 0), state.refresh_failures);
        try std.testing.expectEqual(.unavailable, try restarted_workbench.taskMcpAuthority(unavailable_task));
        const recovered_task = try restarted_workbench.createTaskInWorkspace(workspace_id, workspace_epoch, try product_control.TestSupport.fixtureModelSelection(&restarted_workbench), null, null, .{ .interactive = null });
        try std.testing.expectEqual(.ready_with_selection, try restarted_workbench.taskMcpAuthority(recovered_task));
        return;
    }
    if (race == .proactive) {
        try tmp.dir.deleteFile(std.testing.io, "publication.release");
        tmp.dir.deleteFile(std.testing.io, "publication.waiting") catch {};
        defer tmp.dir.writeFile(std.testing.io, .{ .sub_path = "publication.release", .data = "release" }) catch {};
        refresh_timer.now_ms = refresh_timer.armed_at_ms.?;
        restarted_workbench.onMcpRefreshTimer();
        for (0..1000) |_| {
            _ = tmp.dir.statFile(std.testing.io, "publication.waiting", .{}) catch {
                try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
                continue;
            };
            break;
        } else return error.TestUnexpectedResult;
        try std.testing.expect(restarted_workbench.mcp.?.authorityStable());
        const during = try restarted_workbench.createTaskInWorkspace(workspace_id, workspace_epoch, try product_control.TestSupport.fixtureModelSelection(&restarted_workbench), null, null, .{ .interactive = null });
        try std.testing.expectEqual(product_control.TaskMcpAuthorityAtCreation.ready_with_selection, try restarted_workbench.taskMcpAuthority(during));
        var output: [512 * 1024]u8 = undefined;
        const snapshot = try restarted_workbench.writeAggregateFixture(&output);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"operation\":\"refreshing\"") == null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"newTaskAccess\":\"available\"") != null);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "publication.release", .data = "release" });
        for (0..1000) |_| {
            const job = mcp_types.testing.refreshJob(&restarted_workbench.mcp.?) orelse return error.TestUnexpectedResult;
            if (job.state.load(.acquire) == .completed) break;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        } else return error.TestUnexpectedResult;
        const before_delivery = refresh_timer.now_ms;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(50), .awake);
        refresh_timer.now_ms += 50;
        restarted_workbench.syncLifecycle();
        try std.testing.expect(refresh_timer.armed_at_ms.? <= before_delivery + 1_500);
        return;
    }
    if (race != .expiry) {
        if (race == .core_withdrawal) {
            try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "publication.fail", .data = "fail" });
            // Stop at the actual ABI publication boundary: Core has narrowed
            // its catalog, while both Agent and Product still own the prior
            // generation. This must exercise InvalidMcpSelection, not only
            // the Host StaleMcpSelection check.
            var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
            defer restarted_runtime.api.bufferRelease()(&diagnostic);
            var generation: u64 = 0;
            try std.testing.expectEqual(sdk.Status.ok, try sdk.Status.fromCode(restarted_runtime.api.mcp().refresh()(restarted_runtime.runtime.?, &generation, &diagnostic)));
        } else {
            // One predecessor is deliberately accepted during installation.
            // An older historical proof must still be rejected.
            for (0..2) |_| {
                const newer = switch (try restarted_runtime.activateMcp()) {
                    .activated => |value| value,
                    else => return error.TestUnexpectedResult,
                };
                newer.deinit();
            }
        }
        const task_id = try restarted_workbench.createTaskInWorkspace(workspace_id, workspace_epoch, try product_control.TestSupport.fixtureModelSelection(&restarted_workbench), null, null, .{ .interactive = null });
        try std.testing.expectEqual(fresh_task_id + 1, task_id);
        try std.testing.expectEqual(product_control.TaskMcpAuthorityAtCreation.unavailable, try restarted_workbench.taskMcpAuthority(task_id));
        try std.testing.expect(restarted_workbench.mcp.?.hasRefreshJob() or mcp_types.testing.state(&restarted_workbench.mcp.?).refresh_pending);
        // A failed candidate must leave the third and last Session slot free.
        const third = try restarted_workbench.createTaskInWorkspace(workspace_id, workspace_epoch, try product_control.TestSupport.fixtureModelSelection(&restarted_workbench), null, null, .{ .interactive = null });
        try std.testing.expectEqual(task_id + 1, third);
        try std.testing.expectEqual(product_control.TaskMcpAuthorityAtCreation.unavailable, try restarted_workbench.taskMcpAuthority(task_id));
        var output: [512 * 1024]u8 = undefined;
        const snapshot = try restarted_workbench.writeAggregateFixture(&output);
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, snapshot, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(@as(usize, 3), parsed.value.object.get("tasks").?.array.items.len);
        var found_unavailable = false;
        for (parsed.value.object.get("tasks").?.array.items) |task| {
            const id = task.object.get("id").?.string;
            var id_storage: [32]u8 = undefined;
            const expected_id = try std.fmt.bufPrint(&id_storage, "{d}", .{task_id});
            if (std.mem.eql(u8, id, expected_id)) {
                try std.testing.expectEqualStrings("unavailable", task.object.get("mcpAuthority").?.object.get("kind").?.string);
                found_unavailable = true;
            }
        }
        try std.testing.expect(found_unavailable);
        return;
    }
    if (!std.mem.eql(u8, protocol_version, "2026-07-28")) return;
    std.Io.Timeout.sleep(.{ .duration = .{
        .raw = std.Io.Duration.fromMilliseconds(2_500),
        .clock = .awake,
    } }, std.testing.io) catch return error.TestUnexpectedResult;
    refresh_timer.now_ms += 2_500;
    if (transport == .stdio) {
        const mcp = &restarted_workbench.mcp.?;
        const state = mcp_types.testing.state(mcp);
        const server = state.management.?.desiredRegistry().?.servers[0];
        for ([_]mcp_configuration.ProcessFact{ .spawned, .stdio_closed }) |fact| {
            _ = try mcp.observeProcess(.{ .server_id = server_id, .source = mcp_configuration.runtimeDescriptorFingerprint(server), .attempt = 1, .fact = fact });
            for ([_]bool{ false, true }) |paused| {
                state.refresh_paused = paused;
                var output: [512 * 1024]u8 = undefined;
                const expired = try restarted_workbench.writeAggregateFixture(&output);
                const decoded = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, expired, .{});
                defer decoded.deinit();
                const projected = decoded.value.object.get("mcp").?.object.get("servers").?.array.items[0].object;
                try std.testing.expectEqualStrings("not_loaded", projected.get("runtimeStatus").?.string);
                try std.testing.expectEqualStrings(if (paused) "Tool catalog refresh paused after repeated failures. Select Refresh to retry." else "Tool catalog expired", projected.get("safeDiagnostic").?.string);
            }
        }
        state.refresh_paused = false;
    }
    const task_id = try restarted_workbench.createTaskInWorkspace(workspace_id, workspace_epoch, try product_control.TestSupport.fixtureModelSelection(&restarted_workbench), null, null, .{ .interactive = null });
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
    try std.testing.expect(refresh_timer.arm_count > 0);
    var snapshot_storage: [512 * 1024]u8 = undefined;
    const snapshot = try restarted_workbench.writeAggregateFixture(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(
        u8,
        snapshot,
        "\"newTaskAccess\":\"available\"",
    ) != null);
    const refreshed_task_id = try restarted_workbench.createTaskInWorkspace(workspace_id, workspace_epoch, try product_control.TestSupport.fixtureModelSelection(&restarted_workbench), null, null, .{ .interactive = null });
    try std.testing.expectEqual(
        product_control.TaskMcpAuthorityAtCreation.ready_with_selection,
        try restarted_workbench.taskMcpAuthority(refreshed_task_id),
    );
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

const TaskSwitchHistory = @import("lifecycle_fixture").TypedHistory;

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
    const model = if (std.mem.eql(u8, name, "install-model")) "install-model" else if (std.mem.eql(u8, name, "source-model")) "gpt-4o" else "gpt-4o-mini";
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
        try control.drainAgentEvents();
        const catalog = try control.workspaceCatalog(workspace);
        if ((catalog.availability == .ready or catalog.availability == .degraded) and catalog.skills.len == skill_count) return catalog;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    return error.TestUnexpectedResult;
}

fn executeTaskSwitchRun(control: *product_control.Runtime, task_id: u64, input: product_control.TaskRunInput, choice: product_task.PermissionChoice) !usize {
    const run_id = try @import("lifecycle_fixture").runPreparedTask(control, task_id, input);
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
fn prepareTaskSwitchPng(_: ?*anyopaque, allocator: std.mem.Allocator, bytes: []const u8, _: usize) anyerror![]u8 {
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

test "real Core Product rebind preserves full access and restore ceilings before next Run Skill preparation" {
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
    const runtime = try agent.Runtime.init(std.testing.io, std.testing.allocator, .{ .max_sessions = 1, .mcp_input = &runtime_build.input.? });
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
    var typed_history: TaskSwitchHistory = .{ .file_store = &history };
    defer typed_history.deinit();
    var enablement = try product_skill.enablement.FileStore.init(std.testing.io, home);
    defer enablement.deinit();
    var originals = try product_control.AttachmentFileStore.init(std.testing.io, std.testing.allocator, home);
    defer originals.deinit();
    var vault = TaskSwitchVault{};
    defer for (0..2) |i| std.crypto.secureZero(u8, vault.keys[i][0..vault.lengths[i]]);
    var control = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, .{ .worker_count = 1, .queue_capacity = 4, .max_tasks = 1, .max_workspaces = 1 }, .{
        .directories = .{ .canonical_user_home = home },
        .task_persistence = typed_history.capability(),
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
    const task_id = try control.createTaskInWorkspace(workspace, try control.workspaceEpoch(workspace), initial, catalog.revision, catalog.selection_revision, .{ .interactive = approval_mode });
    const task = control.task_runtime.find(task_id).?;
    var original_catalog = try task.runtime.pinnedCatalogConst().?.clone(std.testing.allocator, .{
        .max_catalog_skills = control.limits.max_catalog_skills,
        .max_catalog_issues = control.limits.max_catalog_issues,
        .max_skill_arguments = control.limits.max_skill_arguments,
        .max_catalog_projection_bytes = control.limits.max_catalog_projection_bytes,
    }, control.limits.max_projection_bytes);
    defer original_catalog.deinit();
    const pinned = original_catalog.view();
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
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".agents/skills/extra/SKILL.md", .data = "---\nname: extra\ndescription: Newly available ungranted Skill\n---\nThis new Skill is eligible for the next Run; restore alone cannot widen its grants.\n" });
    try control.refreshWorkspaceCatalog(workspace, try control.workspaceEpoch(workspace));
    const wider = try waitTaskSwitchCatalog(&control, workspace, 3);
    try std.testing.expectEqual(@as(usize, 3), wider.skills.len);
    try control.refreshMcpCatalog();
    try waitForMcpSnapshot(&control, "\"operation\":\"idle\",\"configurationApply\":\"idle\"");
    _ = try control.selectTaskModel(task_id, .{ .expected_selection_revision = task.durable.model_intent.?.revision, .target = selected.target, .expected_source_generation = selected.expected_source_generation, .expected_catalog_generation = selected.expected_catalog_generation });
    // The full one-slot Runtime can offer rebind through the same Snapshot
    // consumed by Renderer, because this Task owns the slot it will release.
    try std.testing.expect(runtime.restoreAdmission(null) != .available);
    var snapshot_bytes: [128 * 1024]u8 = undefined;
    const snapshot = try control.writeAggregateFixture(&snapshot_bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, snapshot, .{});
    defer parsed.deinit();
    const projected = parsed.value.object.get("tasks").?.array.items[0].object;
    try std.testing.expect(projected.get("continuationRecoveryAvailable").?.bool);
    try std.testing.expectEqualStrings("session_recovery_required", projected.get("continuationUnavailableReason").?.string);
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
    // A confirmed replacement retires the superseded blob through the
    // existing cleanup worker, while its new canonical witness stays usable.
    for (0..5000) |_| {
        control.syncLifecycle();
        checkpoints.verify(before.blob) catch |err| {
            try std.testing.expectEqual(error.BlobMissing, err);
            break;
        };
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    } else return error.TestUnexpectedResult;
    try checkpoints.verify(task.durable.checkpoint.?.blob);
    const after_switch_file = try tmp.dir.statFile(std.testing.io, "permission-boundary.txt", .{});
    try std.testing.expectEqual(original_file.mtime, after_switch_file.mtime);
    // Restore itself preserves its captured ceiling. A new Run separately
    // adopts currently authorized Skills; it never broadens restored MCP tools.
    try std.testing.expectEqualStrings(pinned.revision, (try control.taskCatalog(task_id)).revision);
    {
        var restored_access = try task.runtime.acquireAccess();
        defer restored_access.deinit();
        var ceiling = try restored_access.captureRestoreInputs();
        defer ceiling.deinit() catch unreachable;
        try std.testing.expectEqual(@as(usize, 1), ceiling.skill.?.borrow().policy.granted_skill_ids.len);
    }
    try std.testing.expectEqual(@as(usize, 0), try executeTaskSwitchRun(&control, task_id, .{ .text = "Continue on the new connection." }, .allow_session));
    try std.testing.expectEqual(@as(usize, 0), try executeTaskSwitchRun(&control, task_id, .{ .text = "Deny this echo tool." }, .allow_session));
    // A one-shot Write decision must not become a restored Session grant.
    try std.testing.expectEqual(@as(usize, if (manual) 1 else 0), try executeTaskSwitchRun(&control, task_id, .{ .text = "Write the permission boundary file." }, .allow_once));
    const restored_catalog = try control.taskCatalog(task_id);
    try std.testing.expectEqualStrings((try control.workspaceCatalog(workspace)).revision, restored_catalog.revision);
    try std.testing.expectEqual(@as(usize, 3), restored_catalog.skills.len);
    try std.testing.expectEqual(@as(usize, 0), try executeTaskSwitchRun(&control, task_id, .{ .skill = .{ .skill_id = retained.skill_id, .catalog_revision = restored_catalog.revision, .selection_revision = restored_catalog.selection_revision.?, .argument_values = &.{} } }, .allow_session));
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
    try std.testing.expectEqual(@as(usize, 2), ids.len);
    try std.testing.expect(for (ids) |id| {
        if (std.mem.eql(u8, id, retained.skill_id)) break true;
    } else false);
    for (ids) |id| try std.testing.expect(!std.mem.eql(u8, id, blocked.skill_id));
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
    for (narrowed.skills) |skill| try std.testing.expectEqual(std.mem.eql(u8, skill.skill_policy_key, "extra"), skill.enabled);
    const current_policy = try control.workspaceCatalog(workspace);
    try std.testing.expectError(error.SkillUnavailable, control.runTask(task_id, .{ .skill = .{ .skill_id = retained.skill_id, .catalog_revision = current_policy.revision, .selection_revision = current_policy.selection_revision.?, .argument_values = &.{} } }));
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

test "canonical MCP STDIO routes notifications and replies ping before resuming" {
    try runCatalogInterop(.modern_only, "2026-07-28", "interleaved");
}

test "canonical MCP SSE interleaving preserves tool envelope permission counts and RPC counts" {
    try expectSelectedHttpToolResult("text", "interleaved");
}

test "canonical MCP SSE waits for pong before original tool response with exact permission and RPC counts" {
    try expectSelectedHttpToolResult("text", "ping");
}

test "canonical MCP timeout bounds each RPC rather than the complete configuration apply" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    const trace = try std.fmt.allocPrint(a, "{s}/timeout.jsonl", .{root});
    defer a.free(trace);
    var source = try HttpFixture.startWithDelay("2026-07-28", "json", trace, 60_000, "text", "", 1200);
    defer source.deinit();
    var preparation = try prepareHttpFixture(source.endpoint, "2026-07-28");
    defer preparation.deinit();
    preparation.registry.?.value.servers[0].timeout_ms = 2000;
    const runtime = try agent.Runtime.init(std.testing.io, a, .{ .max_sessions = 1 });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    var build = try mcp_platform.buildRuntime(std.testing.io, a, &preparation, .{});
    defer build.deinit();
    const start = std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds;
    const outcome = try runtime.applyMcpConfiguration(&build.input.?);
    const elapsed = std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds - start;
    try std.testing.expectEqual(.applied, outcome);
    try std.testing.expect(elapsed > 2000 * std.time.ns_per_ms);
}

const management_coordinator = @import("mcp_management_coordinator");

const CoordinatorHost = struct {
    notifications: std.atomic.Value(usize) = .init(0),
    fn request(_: *anyopaque, _: u64, _: product_control.NativeDialog.Message, _: *const product_control.NativeDialog.Completion) !u64 {
        return error.UnexpectedDialog;
    }
    fn open(_: *anyopaque, _: []const u8) bool {
        return false;
    }
    fn now(_: *anyopaque) ?u64 {
        return null;
    }
    fn notify(raw: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        _ = self.notifications.fetchAdd(1, .release);
    }
    fn host(self: *@This()) management_coordinator.Host {
        return .{ .context = self, .request_dialog_fn = request, .open_url_fn = open, .now_unix_ms_fn = now, .notify_fn = notify };
    }
};

fn settleCoordinator(coordinator: *management_coordinator.Coordinator) !void {
    const deadline = std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds + 10 * std.time.ns_per_s;
    while (std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds < deadline) {
        _ = coordinator.drain();
        if (coordinator.configuration_apply_job == null and !coordinator.apply_pending and coordinator.control.inspectMcpDesiredConfiguration().?.runtime_alignment == .current) return;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake);
    }
    return error.CoordinatorDidNotSettle;
}

test "real Coordinator settles eligibility loss and edit without self waking" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    const trace = try std.fmt.allocPrint(a, "{s}/coordinator.jsonl", .{root});
    defer a.free(trace);
    var source = try HttpFixture.start("2026-07-28", "json", trace);
    defer source.deinit();
    var replacement = try HttpFixture.start("2026-07-28", "json", trace);
    defer replacement.deinit();
    var preparation = try mcp_configuration.prepare(a, null, true, false, .{}, product_mcp_limits);
    var preparation_owned = true;
    defer if (preparation_owned) preparation.deinit();
    var manifest = (try mcp_configuration.RuntimeManifest.candidate(a, &preparation)).?;
    var manifest_owned = true;
    defer if (manifest_owned) manifest.deinit();
    const storage = try a.alloc(u8, mcp_configuration.max_store_bytes);
    defer a.free(storage);
    var durable: DurableRegistry = .{ .storage = storage };
    const runtime = try agent.Runtime.init(std.testing.io, a, .{ .max_sessions = 1 });
    var runtime_owned = true;
    defer if (runtime_owned) {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    };
    const budget = try mcp_platform.CatalogBudget.init(a, std.testing.io, runtime);
    defer budget.release();
    var control = try product_control.Runtime.init(a, std.testing.io, runtime, .{ .worker_count = 1, .queue_capacity = 4 }, .{ .mcp = .{ .preparation = &preparation, .management = managementConfiguration(&durable, &manifest) } });
    runtime_owned = false;
    preparation_owned = false;
    manifest_owned = false;
    defer shutdownProduct(&control, runtime);
    // This test has no secrets. Only the native credential-availability
    // observation is supplied; no credential service operation is called.
    const NativeRuntime = @typeInfo(@FieldType(mcp_platform.CredentialStore, "runtime")).pointer.child;
    const native_runtime = try a.create(NativeRuntime);
    defer a.destroy(native_runtime);
    native_runtime.options.platform.services = .{};
    var credentials: mcp_platform.CredentialStore = .{ .io = std.testing.io, .runtime = native_runtime, .main_thread_id = std.Thread.getCurrentId() };
    var authorizations: mcp_platform.HttpAuthorizations = .{ .allocator = a };
    defer authorizations.deinit();
    var host: CoordinatorHost = .{};
    var coordinator = management_coordinator.Coordinator.init(a, std.testing.io, control.mcpManagementPort(), runtime, &credentials, &authorizations, host.host(), .{ .catalog_budget = budget });
    defer coordinator.deinit();
    try std.testing.expectEqual(.saved, (try control.createMcpHttpServer(0, .{ .display_name = "Source", .url = source.endpoint, .timeout_ms = 2000, .negotiation = "modern_only" })).outcome);
    try settleCoordinator(&coordinator);
    const state = mcp_types.testing.state(&control.mcp.?);
    const id = try a.dupe(u8, state.management.?.desiredRegistry().?.servers[0].id);
    defer a.free(id);
    try std.testing.expectEqual(.saved, try control.setMcpAllowedTools(1, .{ .server_id = id, .tools = &.{"echo"} }));
    const mcp = &control.mcp.?;
    try mcp.retainTaskReference(900, mcp.selectionForNewTask().selection);
    try std.testing.expectEqual(@as(u32, 1), state.management.?.runtime_manifest.?.entries[0].task_references);
    try std.testing.expectEqual(.saved, try control.updateMcpHttpConnection(2, .{ .server_id = id, .display_name = "Edited", .url = replacement.endpoint, .timeout_ms = 2000, .negotiation = "modern_only", .auth_mode = .none }));
    try settleCoordinator(&coordinator);
    try std.testing.expectEqualStrings(replacement.endpoint, state.preparation.registry.?.value.servers[0].transport.url.?);
    try std.testing.expectEqual(@as(u32, 1), state.management.?.runtime_manifest.?.entries[0].task_references);
    try std.testing.expectEqual(.saved, try control.setMcpServerEnabled(3, .{ .server_id = id, .enabled = false }));
    try settleCoordinator(&coordinator);
    try std.testing.expectEqual(@as(usize, 1), state.management.?.runtime_manifest.?.entries.len);
    try std.testing.expectEqual(@as(u32, 1), state.management.?.runtime_manifest.?.entries[0].task_references);
    try std.testing.expectEqual(.saved, try control.setMcpServerEnabled(4, .{ .server_id = id, .enabled = true }));
    try settleCoordinator(&coordinator);
    // Seed the valid post-commit observation of approval loss. The real Runtime
    // still owns the previously applied connector; Desired is no longer loadable.
    state.management.?.desired.?.value.generation += 1;
    state.management.?.desired.?.value.servers[0].connection_approval = null;
    try settleCoordinator(&coordinator);
    try std.testing.expectEqual(@as(usize, 1), state.management.?.runtime_manifest.?.entries.len);
    const notifications = host.notifications.load(.acquire);
    for (0..3) |_| {
        try std.testing.expect(!coordinator.drain());
        try std.testing.expect(coordinator.configuration_apply_job == null);
        try std.testing.expectEqual(.current, control.inspectMcpDesiredConfiguration().?.runtime_alignment);
    }
    try std.testing.expectEqual(notifications, host.notifications.load(.acquire));
    const ReleaseWake = struct {
        calls: usize = 0,
        fn notify(raw: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            return true;
        }
    };
    var release_wake: ReleaseWake = .{};
    const saved_notifier = mcp.ports.notifier;
    defer mcp.ports.notifier = saved_notifier;
    mcp.ports.notifier = .{ .context = &release_wake, .notify_fn = ReleaseWake.notify };
    mcp.releaseTaskReference(900);
    try std.testing.expectEqual(@as(usize, 1), release_wake.calls);
    try settleCoordinator(&coordinator);
    try std.testing.expectEqual(@as(usize, 0), state.management.?.runtime_manifest.?.entries.len);
}

test "production candidate budget admits a slow healthy source beside four existing members" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    const trace = try std.fmt.allocPrint(a, "{s}/slow.jsonl", .{root});
    defer a.free(trace);
    var healthy = try HttpFixture.start("2026-07-28", "json", trace);
    defer healthy.deinit();
    var slow = try HttpFixture.startWithDelay("2026-07-28", "json", trace, 60_000, "text", "", 1200);
    defer slow.deinit();
    var preparation = try prepareHttpFixture(healthy.endpoint, "2026-07-28");
    defer preparation.deinit();
    const alloc = preparation.registry.?.arena.allocator();
    const servers = try alloc.alloc(mcp_configuration.ServerWire, 5);
    var approvals: [5][64]u8 = undefined;
    const ids = [_][]const u8{ "first", "second", "third", "fourth", "slow" };
    for (servers, 0..) |*server, index| {
        server.* = preparation.registry.?.value.servers[0];
        server.id = ids[index];
        server.namespace = ids[index];
        server.timeout_ms = 2000;
        server.transport.url = if (index == 4) slow.endpoint else healthy.endpoint;
        approvals[index] = mcp_configuration.connectionFingerprint(server.*);
        server.connection_approval = .{ .fingerprint = &approvals[index] };
    }
    preparation.registry.?.value.servers = servers;
    a.free(preparation.server_states);
    preparation.server_states = try a.alloc(mcp_configuration.ServerPreparationState, 5);
    @memset(preparation.server_states, .eligible);
    preparation.server_states[4] = .disabled;
    servers[0].timeout_ms = std.math.maxInt(u32);
    const runtime = try agent.Runtime.init(std.testing.io, a, .{ .max_sessions = 1 });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    const budget = try mcp_platform.CatalogBudget.init(a, std.testing.io, runtime);
    defer budget.release();
    var first = try mcp_platform.buildRuntime(std.testing.io, a, &preparation, .{ .catalog_budget = budget });
    defer first.deinit();
    try std.testing.expectEqual(std.math.maxInt(u32), first.input.?.servers.?.descriptors[0].timeout_ms);
    try std.testing.expectEqual(std.math.maxInt(u32), servers[0].timeout_ms);
    try budget.begin(0, false);
    try std.testing.expectEqual(.applied, try runtime.applyMcpConfiguration(&first.input.?));
    budget.applied();
    @memset(preparation.server_states, .disabled);
    preparation.server_states[4] = .eligible;
    preparation.registry.?.value.generation = 2;
    var candidate = try mcp_platform.buildRuntime(std.testing.io, a, &preparation, .{ .catalog_budget = budget });
    defer candidate.deinit();
    var input = try runtime.prepareMcpMembership(2, &candidate.input.?, &ids);
    defer input.deinit();
    try budget.begin(4, false);
    defer budget.end();
    const start = std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds;
    try std.testing.expectEqual(.applied, try runtime.applyMcpConfiguration(&input));
    try std.testing.expect(std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds - start > 2000 * std.time.ns_per_ms);
    budget.applied();
}

test "real Core connects a restored expired grant only with committed new bearer and discovers tools" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    var trace_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const trace_path = try std.fmt.bufPrint(&trace_buffer, "{s}/oauth-new-bearer.jsonl", .{root_buffer[0..root_len]});
    var fixture = try HttpFixture.startWithBearer("2026-07-28", "json", trace_path, 60_000, "text", "", 0, "new-access-token");
    defer fixture.deinit();
    const Store = struct {
        durable: DurableRegistry,
        seconds: u64 = 80,
        new_locator: [64]u8 = undefined,
        new_locator_len: usize = 0,
        new_secret: [64]u8 = undefined,
        new_secret_len: usize = 0,
        old_retired: bool = false,
        fn now(raw: ?*anyopaque) ?u64 {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return self.seconds;
        }
        fn probe(raw: ?*anyopaque, locator: []const u8) mcp_configuration.CredentialPresence {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return if (self.secret(locator) != null) .present else .missing;
        }
        fn secret(self: *@This(), locator: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, locator, "oauth/refresh")) return "refresh-token";
            if (!self.old_retired and std.mem.eql(u8, locator, "oauth/access")) return "expired-access-token";
            if (self.new_locator_len != 0 and std.mem.eql(u8, locator, self.new_locator[0..self.new_locator_len])) return self.new_secret[0..self.new_secret_len];
            return null;
        }
        fn create(raw: ?*anyopaque, locator: []const u8, value: []const u8) bool {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (locator.len > self.new_locator.len or value.len > self.new_secret.len) return false;
            @memcpy(self.new_locator[0..locator.len], locator);
            self.new_locator_len = locator.len;
            @memcpy(self.new_secret[0..value.len], value);
            self.new_secret_len = value.len;
            return true;
        }
        fn delete(raw: ?*anyopaque, locator: []const u8) bool {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (std.mem.eql(u8, locator, "oauth/access")) self.old_retired = true;
            return true;
        }
        fn resolve(raw: ?*anyopaque, allocator: std.mem.Allocator, locator: []const u8) mcp_configuration.CredentialResolution {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            const value = self.secret(locator) orelse return .missing;
            return .{ .value = allocator.dupe(u8, value) catch return .out_of_memory };
        }
        fn resolver(self: *@This()) mcp_configuration.CredentialResolver {
            return .{ .available = true, .context = self, .resolve_fn = resolve };
        }
        const Owner = struct { control: product_control.Runtime, core: *agent.Runtime };
        fn restore(self: *@This()) !Owner {
            const allocator = std.testing.allocator;
            var preparation = try mcp_configuration.prepare(allocator, self.durable.storage[0..self.durable.len], true, false, self.resolver(), product_mcp_limits);
            errdefer preparation.deinit();
            var empty = try mcp_configuration.prepare(allocator, null, true, false, .{}, product_mcp_limits);
            defer empty.deinit();
            var manifest = (try mcp_configuration.RuntimeManifest.candidate(allocator, &empty)).?;
            errdefer manifest.deinit();
            const core = try agent.Runtime.init(std.testing.io, allocator, .{ .max_sessions = 1 });
            errdefer {
                core.shutdown() catch unreachable;
                core.deinit();
            }
            var management = managementConfiguration(&self.durable, &manifest);
            management.locator_generator = .{ .available = true, .context = &self.durable, .fill_fn = DurableRegistry.fillIdentity };
            management.credentials = .{ .available = true, .context = self, .probe_fn = probe, .create_fn = create, .delete_fn = delete };
            return .{ .core = core, .control = try product_control.Runtime.init(allocator, std.testing.io, core, .{ .worker_count = 1, .queue_capacity = 4 }, .{
                .schedule_timer = .{ .enabled = true, .context = self, .now_unix_seconds = now },
                .mcp = .{ .preparation = &preparation, .management = management, .host_capabilities = .{ .oauth = true, .connection_approval = true } },
            }) };
        }
        fn commit(_: *anyopaque) void {}
    };
    var durable_bytes: [8192]u8 = undefined;
    var store: Store = .{ .durable = .{ .storage = &durable_bytes } };
    // Loopback HTTP qualifies actual bearer consumption by Core. The token
    // response is a fixture; production HTTPS/token endpoint policy is unchanged.
    var seed = try prepareHttpFixture(fixture.endpoint, "2026-07-28");
    defer seed.deinit();
    const server = &seed.registry.?.value.servers[0];
    server.auth = .{ .kind = "oauth", .oauth = .{
        .status = "ready",
        .registration = .{ .kind = "pre_registered", .issuer = "https://issuer.example.test", .client_id = "fixture-client", .token_endpoint_auth_method = "none", .client_credential_revision = 1, .client_secret_ref = null },
        .consent = .{ .epoch = 1, .fingerprint = "", .resource = fixture.endpoint, .issuer = "https://issuer.example.test", .scopes = &.{}, .redirect_uri = "http://127.0.0.1:43123/auth/callback", .client_credential_revision = 1 },
        .grant = .{ .consent_epoch = 1, .token_revision = 1, .access_token_ref = "oauth/access", .refresh_token_ref = "oauth/refresh", .expires_at_unix_ms = 90_000 },
    } };
    var approval = mcp_configuration.connectionFingerprint(server.*);
    server.connection_approval = .{ .fingerprint = &approval };
    var consent = mcp_configuration.oauthConsentFingerprint(server.*, server.auth.oauth.?.consent.?).?;
    server.auth.oauth.?.consent.?.fingerprint = &consent;
    const encoded = try mcp_configuration.encode(&durable_bytes, seed.registry.?.value, product_mcp_limits);
    store.durable.len = encoded.len;
    // Destroy both Product and canonical Core, preserve only the serialized
    // registry and credential owner, then advance time while they are closed.
    var previous = try store.restore();
    shutdownProduct(&previous.control, previous.core);
    store.seconds = 100;
    var owner = try store.restore();
    defer shutdownProduct(&owner.control, owner.core);
    try std.testing.expect((try owner.control.prepareMcpConfigurationStep(1, .automatic)) == null);
    try std.testing.expect(owner.control.inspectMcpDesiredConfiguration().?.authorization_recovery_pending);
    var binding = (try owner.control.beginMcpOauthRefresh("deterministic-http")).started;
    defer binding.deinit();
    try std.testing.expectEqual(.absent, binding.runtime_binding);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "oauth-new-bearer.jsonl", .{}));
    var new_token = "new-access-token".*;
    try std.testing.expectEqual(.saved, try owner.control.completeMcpOauthRefresh(.{ .operation_id = binding.operation_id, .server_id = "deterministic-http", .access_token = &new_token, .expires_at_unix_ms = 999_000 }, .{ .context = &store, .commit_fn = Store.commit }));
    try std.testing.expect(store.old_retired);
    var step = (try owner.control.prepareMcpConfigurationStep(2, .automatic)).?;
    defer step.deinit();
    try std.testing.expectEqual(.add, step.target.kind);
    var candidate_bytes: [8192]u8 = undefined;
    const candidate_json = try mcp_configuration.encode(&candidate_bytes, step.preparation.registry.?.value, product_mcp_limits);
    var credentials = try mcp_configuration.prepare(a, candidate_json, true, false, store.resolver(), product_mcp_limits);
    defer credentials.deinit();
    var build = try mcp_platform.buildRuntime(std.testing.io, a, &credentials, .{});
    defer build.deinit();
    var input = try owner.core.prepareMcpMembership(2, &build.input.?, step.member_ids);
    defer input.deinit();
    try std.testing.expectEqual(.applied, try owner.core.applyMcpConfiguration(&input));
    var applied_manifest = (try mcp_configuration.RuntimeManifest.candidate(a, &step.preparation)).?;
    var manifest_owned = true;
    defer if (manifest_owned) applied_manifest.deinit();
    const activation = switch (try owner.core.activateMcp()) {
        .activated => |value| value,
        else => return error.TestUnexpectedResult,
    };
    var activation_owned = true;
    defer if (activation_owned) activation.deinit();
    try std.testing.expectEqual(.ready, activation.state());
    try std.testing.expectEqualStrings("echo", activation.catalogTools()[0].name);
    const selection = activation.takeSelection();
    try std.testing.expect(owner.control.completeMcpConfigurationApply(2, &step.preparation, &applied_manifest, activation, selection, false));
    step.preparation = .{ .allocator = a, .state = .empty };
    manifest_owned = false;
    activation_owned = false;
    const trace = try tmp.dir.readFileAlloc(std.testing.io, "oauth-new-bearer.jsonl", a, .limited(1024 * 1024));
    defer a.free(trace);
    try std.testing.expect(std.mem.count(u8, trace, "\"direction\":\"authorization\",\"matched\":true") >= 3);
    try std.testing.expect(std.mem.indexOf(u8, trace, "\"matched\":false") == null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "\"method\":\"tools/list\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "new-access-token") == null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "expired-access-token") == null);
}

const InstallationVault = struct {
    const native = @import("native_sdk");
    values: std.StringHashMap([]u8),
    fn deinit(self: *@This()) void {
        var iterator = self.values.iterator();
        while (iterator.next()) |entry| {
            self.values.allocator.free(entry.key_ptr.*);
            std.crypto.secureZero(u8, entry.value_ptr.*);
            self.values.allocator.free(entry.value_ptr.*);
        }
        self.values.deinit();
    }
    fn set(raw: ?*anyopaque, credential: native.platform.Credential) !void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        const entry = try self.values.getOrPut(credential.account);
        if (entry.found_existing) {
            std.crypto.secureZero(u8, entry.value_ptr.*);
            self.values.allocator.free(entry.value_ptr.*);
        } else entry.key_ptr.* = try self.values.allocator.dupe(u8, credential.account);
        entry.value_ptr.* = try self.values.allocator.dupe(u8, credential.secret);
    }
    fn get(raw: ?*anyopaque, key: native.platform.CredentialKey, buffer: []u8) ![]const u8 {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        const value = self.values.get(key.account) orelse return error.CredentialNotFound;
        if (value.len > buffer.len) return error.NoSpaceLeft;
        @memcpy(buffer[0..value.len], value);
        return buffer[0..value.len];
    }
    fn delete(raw: ?*anyopaque, key: native.platform.CredentialKey) !void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        const removed = self.values.fetchRemove(key.account) orelse return error.CredentialNotFound;
        self.values.allocator.free(removed.key);
        std.crypto.secureZero(u8, removed.value);
        self.values.allocator.free(removed.value);
    }
};
const InstallationTestHost = struct {
    woken: std.atomic.Value(bool) = .init(true),
    refuse: bool = false,
    completion: ?*const product_control.NativeDialog.Completion = null,
    token: u64 = 0,
    confirmations: usize = 0,
    fetches: std.atomic.Value(usize) = .init(0),
    fn request(raw: *anyopaque, token: u64, _: product_control.NativeDialog.Message, completion: *const product_control.NativeDialog.Completion) !u64 {
        const self: *@This() = @ptrCast(@alignCast(raw));
        try std.testing.expectEqual(@as(usize, 0), self.fetches.load(.acquire));
        self.completion = completion;
        self.token = token;
        self.confirmations += 1;
        return token;
    }
    fn open(_: *anyopaque, _: []const u8) bool {
        return false;
    }
    fn now(_: *anyopaque) ?u64 {
        return 1000;
    }
    fn notify(raw: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.woken.store(true, .release);
    }
    fn takeWake(self: *@This()) bool {
        return self.woken.swap(false, .acq_rel);
    }
    fn productNotify(raw: ?*anyopaque) bool {
        notify(raw.?);
        return true;
    }
    fn fetch(raw: ?*anyopaque, request_value: @import("mcp_management_coordinator").InstallationTestTransportRequest, _: []u8, _: []u8) @import("mcp_management_coordinator").InstallationTestFetchError!@import("mcp_management_coordinator").InstallationTestTransportResponse {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        if (std.mem.eql(u8, request_value.url, "https://mcp.example.test/mcp")) return .{ .status = 401, .www_authenticate = "Bearer resource_metadata=\"https://mcp.example.test/oauth-resource\"" };
        if (std.mem.eql(u8, request_value.url, "https://mcp.example.test/oauth-resource")) return .{ .status = 200, .content_type = "application/json", .body = "{\"resource\":\"https://mcp.example.test/mcp\",\"authorization_servers\":[\"https://auth.example.test\"]}" };
        if (std.mem.eql(u8, request_value.url, "https://auth.example.test/.well-known/oauth-authorization-server")) return .{ .status = 200, .content_type = "application/json", .body = "{\"issuer\":\"https://auth.example.test\",\"authorization_endpoint\":\"https://auth.example.test/authorize\",\"token_endpoint\":\"https://auth.example.test/token\",\"registration_endpoint\":\"https://auth.example.test/register\",\"response_types_supported\":[\"code\"],\"grant_types_supported\":[\"authorization_code\",\"refresh_token\"],\"code_challenge_methods_supported\":[\"S256\"],\"token_endpoint_auth_methods_supported\":[\"none\"]}" };
        if (!std.mem.eql(u8, request_value.url, "https://credentials.example/key")) return error.InvalidResponse;
        _ = self.fetches.fetchAdd(1, .release);
        return .{ .status = 200, .content_type = "application/json", .body = "{\"data\":{\"key\":\"mcp-static-fixture-secret\"}}" };
    }
    fn approve(self: *@This()) void {
        if (self.completion) |completion| {
            self.completion = null;
            completion.result_fn(completion.context, self.token, .{ .button = if (self.refuse) .secondary else .primary });
        }
    }
};

const AutomaticInstallationCase = enum { public_http, failed_retry, no_tools_retry, catalog_refresh, manual_credential, oauth_cancel, credential_template, stdio_environment };
fn expectAutomaticInstallation(mode: AutomaticInstallationCase) !void {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    const trace = try std.fmt.allocPrint(a, "{s}/installation.jsonl", .{root});
    defer a.free(trace);
    const request_file = try std.fmt.allocPrint(a, "{s}/install-request.json", .{root});
    defer a.free(request_file);
    const empty_catalog_file = try std.fmt.allocPrint(a, "{s}/catalog.empty", .{root});
    defer a.free(empty_catalog_file);
    if (mode == .no_tools_retry) try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "catalog.empty", .data = "empty" });
    const refresh_gate = try std.fmt.allocPrint(a, "{s}/refresh", .{root});
    defer a.free(refresh_gate);
    var fixture = try HttpFixture.startForInstallation("2026-07-28", "json", trace, 60_000, "text", if (mode == .catalog_refresh) refresh_gate else "", 0, "", if (mode == .credential_template or mode == .manual_credential) "mcp-static-fixture-secret" else "", request_file, empty_catalog_file);
    defer fixture.deinit();
    const source_url = try std.fmt.allocPrint(a, "{s}#agent-install", .{fixture.endpoint});
    defer a.free(source_url);
    const template = try std.fmt.allocPrint(a, "{s}?api_key={{credential:token}}", .{fixture.endpoint});
    defer a.free(template);
    const invalid_endpoint = try std.fmt.allocPrint(a, "{s}/missing", .{fixture.endpoint});
    defer a.free(invalid_endpoint);
    const json = switch (mode) {
        .public_http, .failed_retry, .no_tools_retry, .catalog_refresh => try std.json.Stringify.valueAlloc(a, .{ .sourceUrl = source_url, .connection = .{ .displayName = "Automatic HTTP", .transport = "streamable_http", .endpoint = if (mode == .failed_retry) invalid_endpoint else fixture.endpoint, .authMode = "none" } }, .{}),
        .manual_credential => try std.json.Stringify.valueAlloc(a, .{ .sourceUrl = source_url, .connection = .{ .displayName = "Manual credential", .transport = "streamable_http", .endpoint = template, .authMode = "none" }, .credentials = .{.{ .slot = "token", .kind = "user_input", .target = "endpoint" }} }, .{}),
        .oauth_cancel => try std.json.Stringify.valueAlloc(a, .{ .sourceUrl = source_url, .connection = .{ .displayName = "Automatic OAuth", .transport = "streamable_http", .endpoint = "https://mcp.example.test/mcp", .authMode = "oauth" } }, .{}),
        .credential_template => try std.json.Stringify.valueAlloc(a, .{ .sourceUrl = source_url, .connection = .{ .displayName = "Automatic template", .transport = "streamable_http", .endpoint = template, .authMode = "none" }, .credentials = .{.{ .slot = "token", .kind = "http_json", .url = "https://credentials.example/key", .jsonPointer = "/data/key", .target = "endpoint" }} }, .{}),
        .stdio_environment => try std.json.Stringify.valueAlloc(a, .{ .sourceUrl = source_url, .connection = .{ .displayName = "Automatic STDIO", .transport = "stdio", .command = options.node_path, .arguments = .{ options.fixture_path, "--protocol", "2026-07-28", "--trace", trace, "--require-env" }, .authMode = "static", .environmentNames = .{"MCP_FIXTURE_TOKEN"} }, .credentials = .{.{ .slot = "token", .kind = "http_json", .url = "https://credentials.example/key", .jsonPointer = "/data/key", .target = "environment", .name = "MCP_FIXTURE_TOKEN" }} }, .{}),
    };
    defer a.free(json);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "install-request.json", .data = json });
    const native = @import("native_sdk");
    const native_runtime = try a.create(native.Runtime);
    defer a.destroy(native_runtime);
    var credential_vault: InstallationVault = .{ .values = std.StringHashMap([]u8).init(a) };
    defer credential_vault.deinit();
    native_runtime.options.platform.services = .{ .context = &credential_vault, .set_credential_fn = InstallationVault.set, .get_credential_fn = InstallationVault.get, .delete_credential_fn = InstallationVault.delete };
    var credentials: mcp_platform.CredentialStore = .{ .io = std.testing.io, .runtime = native_runtime, .main_thread_id = std.Thread.getCurrentId() };
    var preparation = try mcp_configuration.prepare(a, null, true, false, credentials.resolver(), product_mcp_limits);
    var preparation_owned = true;
    defer if (preparation_owned) preparation.deinit();
    var manifest = (try mcp_configuration.RuntimeManifest.candidate(a, &preparation)).?;
    var manifest_owned = true;
    defer if (manifest_owned) manifest.deinit();
    const bytes = try a.alloc(u8, mcp_configuration.max_store_bytes);
    defer a.free(bytes);
    var durable: DurableRegistry = .{ .storage = bytes };
    const runtime = try agent.Runtime.init(std.testing.io, a, .{ .max_sessions = 4 });
    var runtime_owned = true;
    defer if (runtime_owned) {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    };
    const budget = try mcp_platform.CatalogBudget.init(a, std.testing.io, runtime);
    defer budget.release();
    var configuration = managementConfiguration(&durable, &manifest);
    configuration.credentials = credentials.effects();
    configuration.locator_generator = credentials.locatorGenerator();
    var checkpoints = try product_task.checkpoint_store.FileStore.init(std.testing.io, root);
    defer checkpoints.deinit();
    var history = try product_task.history.FileStore.init(std.testing.io, root);
    defer history.deinit();
    var typed_history: TaskSwitchHistory = .{ .file_store = &history };
    defer typed_history.deinit();
    var enablement = try product_skill.enablement.FileStore.init(std.testing.io, root);
    defer enablement.deinit();
    var control = try product_control.Runtime.init(a, std.testing.io, runtime, .{ .worker_count = 1, .queue_capacity = 4 }, .{ .directories = .{ .canonical_user_home = root }, .task_persistence = typed_history.capability(), .checkpoint_store = .{ .file_store = &checkpoints }, .skill_enablement = .{ .file_store = &enablement }, .skill_sources = .{ .restored = .{ .loaded = .{ .ready = .{} } } }, .mcp = .{ .preparation = &preparation, .management = configuration } });
    runtime_owned = false;
    preparation_owned = false;
    manifest_owned = false;
    defer shutdownProduct(&control, runtime);
    var model_vault: TaskSwitchVault = .{};
    defer for (&model_vault.keys) |*key| std.crypto.secureZero(u8, key);
    try control.startCustomProviders(root, model_vault.port());
    defer control.stopCustomProviders();
    const install_model = try configureTaskSwitchProvider(&control, fixture.provider_endpoint, "install-model", .anthropic_messages);
    const workspace = try control.openWorkspace(.{ .workspace_root = root, .trust = .explicitly_trusted });
    const initial_catalog = blk: {
        for (0..2000) |_| {
            try control.drainAgentEvents();
            const catalog = try control.workspaceCatalog(workspace);
            if (catalog.availability == .ready or catalog.availability == .degraded) break :blk catalog;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        } else return error.CatalogDidNotComplete;
    };
    const source_task = try control.createTaskInWorkspace(workspace, try control.workspaceEpoch(workspace), install_model, initial_catalog.revision, initial_catalog.selection_revision, .{ .interactive = .full_access });
    try std.testing.expectEqual(.ready_without_selection, try control.taskMcpAuthority(source_task));
    _ = try executeTaskSwitchRun(&control, source_task, .{ .text = source_url }, .allow_once);
    var authorizations: mcp_platform.HttpAuthorizations = .{ .allocator = a };
    defer authorizations.deinit();
    var host: InstallationTestHost = .{ .refuse = mode == .oauth_cancel };
    var coordinator = management_coordinator.Coordinator.init(a, std.testing.io, control.mcpManagementPort(), runtime, &credentials, &authorizations, .{ .context = &host, .confirmation_available = true, .capture_available = true, .oauth_available = true, .request_dialog_fn = InstallationTestHost.request, .open_url_fn = InstallationTestHost.open, .now_unix_ms_fn = InstallationTestHost.now, .notify_fn = InstallationTestHost.notify }, .{ .catalog_budget = budget, .executable_search_path = std.fs.path.dirname(options.node_path), .windows_system_root = options.windows_system_root });
    defer coordinator.deinit();
    coordinator.transport_override = .{ .context = &host, .fetch_fn = InstallationTestHost.fetch };
    var retried = false;
    var manual_submitted = false;
    var retry_id: ?[mcp_configuration.created_identity_bytes]u8 = null;
    for (0..1000) |_| {
        if (!host.takeWake()) {
            try std.Io.sleep(std.testing.io, .fromMilliseconds(2), .awake);
            continue;
        }
        control.syncLifecycle();
        _ = coordinator.drain();
        host.approve();
        if (control.mcp.?.state.management.?.desiredRegistry()) |registry| if (registry.servers.len == 1) {
            const server = registry.servers[0];
            if (mode == .oauth_cancel and server.installation.?.phase == .cancelled and !server.installation.?.stop_pending) {
                for (0..20) |_| {
                    if (!host.takeWake()) break;
                    _ = coordinator.drain();
                }
                try std.testing.expectEqual(@as(usize, 1), host.confirmations);
                try std.testing.expect(coordinator.flow == null);
                try std.testing.expect(!control.mcp.?.state.management.?.desiredRegistry().?.servers[0].enabled);
                return;
            }
            if (mode == .manual_credential and server.installation.?.phase == .needs_credentials and !manual_submitted) {
                try std.testing.expectEqual(.saved, try coordinator.captureSecret(registry.generation, server.id, .{ .installation_credential = "token" }, "mcp-static-fixture-secret"));
                manual_submitted = true;
                continue;
            }
            if (control.mcp.?.installationReady(server.id)) break;
            if (server.installation.?.phase == .failed or server.installation.?.phase == .no_tools) {
                if (((mode == .failed_retry and server.installation.?.phase == .failed) or (mode == .no_tools_retry and server.installation.?.phase == .no_tools)) and !retried) {
                    retry_id = server.id[0..mcp_configuration.created_identity_bytes].*;
                    if (host.takeWake()) _ = coordinator.drain(); // Settle the notified terminal request.
                    if (mode == .no_tools_retry) try tmp.dir.deleteFile(std.testing.io, "catalog.empty");
                    const corrected = try std.json.Stringify.valueAlloc(a, .{ .sourceUrl = source_url, .connection = .{ .displayName = "Corrected HTTP", .transport = "streamable_http", .endpoint = fixture.endpoint, .authMode = "none" } }, .{});
                    defer a.free(corrected);
                    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "install-request.json", .data = corrected });
                    _ = try executeTaskSwitchRun(&control, source_task, .{ .text = source_url }, .allow_once);
                    InstallationTestHost.notify(&host); // A new user Run is an external main-loop event.
                    retried = true;
                    continue;
                }
                std.debug.print("automatic installation failed: {any}\n", .{server.installation.?.failure});
                return error.InstallationFailed;
            }
        };
    } else {
        const registry = control.mcp.?.state.management.?.desiredRegistry().?;
        std.debug.print("installation timed out: phase={any}, enabled={}, consent={}, flow={}, authorization={any}\n", .{ registry.servers[0].installation.?.phase, registry.servers[0].enabled, host.confirmations, coordinator.flow != null, control.mcpAuthorizationOperation() });
        return error.InstallationDidNotComplete;
    }
    if (mode == .failed_retry or mode == .no_tools_retry) {
        try std.testing.expect(retried);
        const registry = control.mcp.?.state.management.?.desiredRegistry().?;
        try std.testing.expectEqual(@as(usize, 1), registry.servers.len);
        try std.testing.expectEqualStrings(&retry_id.?, registry.servers[0].id);
    }
    if (mode == .manual_credential) try std.testing.expect(manual_submitted);
    const uses_credentials = mode == .credential_template or mode == .stdio_environment;
    try std.testing.expectEqual(@as(usize, if (uses_credentials) 1 else 0), host.fetches.load(.acquire));
    try std.testing.expectEqual(@as(usize, if (uses_credentials) 1 else 0), host.confirmations);
    try std.testing.expect(std.mem.indexOf(u8, durable.storage[0..durable.len], "mcp-static-fixture-secret") == null);
    try std.testing.expectEqual(.ready_without_selection, try control.taskMcpAuthority(source_task));
    const call_model = try configureTaskSwitchProvider(&control, fixture.provider_endpoint, "call-model", .anthropic_messages);
    const next_task = try control.createTaskInWorkspace(workspace, try control.workspaceEpoch(workspace), call_model, null, null, .{ .interactive = .manual });
    try std.testing.expectEqual(.ready_with_selection, try control.taskMcpAuthority(next_task));
    _ = try executeTaskSwitchRun(&control, next_task, .{ .text = "Call the selected echo tool." }, .allow_once);
    if (mode == .catalog_refresh) {
        if (host.takeWake()) _ = coordinator.drain();
        const installed = control.mcp.?.state.management.?.desiredRegistry().?.servers[0];
        const installed_id = installed.id[0..mcp_configuration.created_identity_bytes].*;
        const original_run = installed.installation.?.run_id;
        // Only refresh workers use this Product notifier. The other cases
        // deliberately rely on Host notifications so Product commits cannot
        // hide a missing continuation wake in the installation coordinator.
        control.mcp.?.ports.notifier = .{ .context = &host, .notify_fn = InstallationTestHost.productNotify };
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "refresh.armed", .data = "armed" });
        defer tmp.dir.writeFile(std.testing.io, .{ .sub_path = "refresh.release", .data = "release" }) catch {};
        try control.refreshMcpCatalog();
        for (0..1000) |_| {
            if (tmp.dir.statFile(std.testing.io, "refresh.waiting", .{})) |_| break else |_| {}
            try std.Io.sleep(std.testing.io, .fromMilliseconds(2), .awake);
        } else return error.RefreshDidNotStart;
        const correction = try std.json.Stringify.valueAlloc(a, .{ .sourceUrl = source_url, .serverId = &installed_id, .connection = .{ .displayName = "Retried during refresh", .transport = "streamable_http", .endpoint = fixture.endpoint, .authMode = "none" } }, .{});
        defer a.free(correction);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "install-request.json", .data = correction });
        _ = try executeTaskSwitchRun(&control, source_task, .{ .text = source_url }, .allow_once);
        InstallationTestHost.notify(&host);
        try std.testing.expect(host.takeWake());
        control.syncLifecycle();
        _ = coordinator.drain();
        const pending_id = control.pendingMcpInstallation().?.id;
        try std.testing.expect(control.mcp.?.hasRefreshJob());
        try std.testing.expectEqual(pending_id, control.pendingMcpInstallation().?.id);
        try std.testing.expectEqual(original_run, control.mcp.?.state.management.?.desiredRegistry().?.servers[0].installation.?.run_id);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "refresh.release", .data = "release" });
        for (0..1000) |_| {
            if (host.takeWake()) {
                control.syncLifecycle();
                _ = coordinator.drain();
                const current = control.mcp.?.state.management.?.desiredRegistry().?.servers[0];
                if (current.installation.?.run_id != original_run and control.mcp.?.installationReady(&installed_id)) break;
            }
            try std.Io.sleep(std.testing.io, .fromMilliseconds(2), .awake);
        } else return error.PendingInstallationDidNotResume;
    }
    const calls = try tmp.dir.readFileAlloc(std.testing.io, "installation.jsonl", a, .limited(4 * 1024 * 1024));
    defer a.free(calls);
    try std.testing.expect(std.mem.indexOf(u8, calls, "tools/call") != null);
    try std.testing.expect(std.mem.indexOf(u8, calls, "mcp-static-fixture-secret") == null);
    // A later disable changes live admission, not the completed installation
    // history, and must not keep its ingress slot occupied indefinitely.
    const completed = control.mcp.?.state.management.?.desiredRegistry().?;
    const completed_id = completed.servers[0].id[0..mcp_configuration.created_identity_bytes].*;
    try std.testing.expectEqual(.saved, try control.setMcpServerEnabled(completed.generation, .{ .server_id = &completed_id, .enabled = false }));
    _ = coordinator.drain();
    try std.testing.expect(coordinator.installation_server == null);
    try std.testing.expect(control.pendingMcpInstallation() == null);
    const snapshot_memory = try a.alloc(u8, 512 * 1024);
    defer a.free(snapshot_memory);
    const snapshot = try control.writeAggregateFixture(snapshot_memory);
    var projected = try std.json.parseFromSlice(std.json.Value, a, snapshot, .{});
    defer projected.deinit();
    const projected_operation = projected.value.object.get("mcpInstallation").?.object.get("operations").?.array.items[0].object;
    try std.testing.expectEqualStrings("ready", projected_operation.get("phase").?.string);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "mcp-static-fixture-secret") == null);
}

test "automatic installation public HTTP gives a new Task a real callable tool" {
    try expectAutomaticInstallation(.public_http);
}
test "automatic installation credential template keeps keys private and calls from a new Task" {
    try expectAutomaticInstallation(.credential_template);
}
test "automatic installation STDIO environment keeps keys private and calls from a new Task" {
    try expectAutomaticInstallation(.stdio_environment);
}

test "automatic installation corrected retry reuses the same failed server" {
    try expectAutomaticInstallation(.failed_retry);
}

test "automatic installation OAuth refusal settles without reopening consent" {
    try expectAutomaticInstallation(.oauth_cancel);
}

test "automatic installation manual credential resumes on notification and gives a new Task tools" {
    try expectAutomaticInstallation(.manual_credential);
}

test "automatic installation empty discovery can retry and grant its first tools" {
    try expectAutomaticInstallation(.no_tools_retry);
}

test "automatic installation retains a request during real catalog refresh and resumes on completion wake" {
    try expectAutomaticInstallation(.catalog_refresh);
}
