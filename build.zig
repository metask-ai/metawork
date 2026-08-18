//! This build belongs to your app, written once by `native eject`:
//! the `native` CLI stops generating a build graph and
//! drives this file through `zig build` instead, and it will
//! never rewrite it. `addApp` wires the complete standard app
//! build — executable, `zig build run`, `zig build test`, and
//! the -Dplatform/-Dweb-engine/-Dautomation/-Doptimize flags —
//! from the framework's build/app.zig, so a framework upgrade
//! still upgrades your build. Extend from here with
//! `addAppArtifacts` when you need extra sources or steps.

const std = @import("std");
const native_sdk = @import("native_sdk");
const agentcore_bundle = @import("build_support/agentcore_bundle.zig");

pub fn build(b: *std.Build) void {
    const artifacts = native_sdk.addAppArtifacts(b, b.dependency("native_sdk", .{}), .{ .name = "metawork" });
    const frontend_assets = b.addInstallDirectory(.{
        .source_dir = b.path("frontend/dist"),
        .install_dir = .bin,
        .install_subdir = "frontend/dist",
    });
    b.getInstallStep().dependOn(&frontend_assets.step);
    const root = b.pathFromRoot(".agentcore/bundle");
    const bundle = agentcore_bundle.verify(b, root);
    const modules = wireAgentCore(b, artifacts.exe.root_module, bundle);
    const test_modules = if (artifacts.tests.root_module != artifacts.exe.root_module)
        wireAgentCore(b, artifacts.tests.root_module, bundle)
    else
        modules;
    const lifecycle_fixture = createLifecycleFixture(b, test_modules, bundle.link_libc);
    test_modules.app.addImport("lifecycle_fixture", lifecycle_fixture);
    test_modules.bridge.addImport("lifecycle_fixture", lifecycle_fixture);
    addLifecycleTests(b, test_modules, lifecycle_fixture, bundle.link_libc);
    addMcpConnectorTests(b, test_modules, bundle.link_libc);
    addMcpStdioTests(b, test_modules, bundle.link_libc);
    addMcpHttpTests(b, test_modules, bundle.link_libc);
    addMcpRuntimeTests(b, test_modules, bundle.link_libc);
    addMcpCatalogTests(b, test_modules, bundle.link_libc);
    addMcpConfigurationTests(b, test_modules, bundle.link_libc);
    addMcpPlatformTests(b, test_modules, bundle.link_libc);
    addMcpOauthTests(b, test_modules, bundle.link_libc);
    addMcpAppTests(b, test_modules, bundle.link_libc);
    addWorkbenchMcpTests(b, test_modules, bundle.link_libc);
    artifacts.tests.step.dependOn(addMcpInteropTests(
        b,
        test_modules,
        bundle.link_libc,
    ));
    const module_tests = [_]struct {
        name: []const u8,
        root_module: *std.Build.Module,
    }{
        .{ .name = "metawork-account-contract", .root_module = test_modules.account_contract },
        .{ .name = "metawork-account-oauth", .root_module = test_modules.account_oauth },
        .{ .name = "metawork-metask-client", .root_module = test_modules.metask_client },
        .{ .name = "metawork-account-credential-store", .root_module = test_modules.account_credential_store },
        .{ .name = "metawork-account-model-connections", .root_module = test_modules.account_model_connections },
        .{ .name = "metawork-account-platform", .root_module = test_modules.account_platform },
        .{ .name = "metawork-account-loopback", .root_module = test_modules.account_loopback },
        .{ .name = "metawork-account-login-attempt", .root_module = test_modules.account_login_attempt },
        .{ .name = "metawork-account-catalog", .root_module = test_modules.account_catalog },
        .{ .name = "metawork-account-credentials-runtime", .root_module = test_modules.account_credentials_runtime },
        .{ .name = "metawork-account-network-attempt", .root_module = test_modules.account_network_attempt },
        .{ .name = "metawork-account-state", .root_module = test_modules.account_state },
        .{ .name = "metawork-account-runtime", .root_module = test_modules.account_runtime },
        .{ .name = "metawork-account", .root_module = test_modules.account },
        .{ .name = "metawork-app", .root_module = test_modules.app },
        .{ .name = "metawork-automation-enabled", .root_module = test_modules.automation_enabled },
        .{ .name = "metawork-bridge", .root_module = test_modules.bridge },
        .{ .name = "metawork-agent-mcp-connector", .root_module = test_modules.agent_mcp_connector },
        .{ .name = "metawork-agent-provider-probe", .root_module = test_modules.agent_provider_probe },
        .{ .name = "metawork-agent-mcp-catalog", .root_module = test_modules.agent_mcp_catalog },
        .{ .name = "metawork-agent-mcp-http", .root_module = test_modules.agent_mcp_http },
        .{ .name = "metawork-agent-mcp-runtime", .root_module = test_modules.agent_mcp_runtime },
        .{ .name = "metawork-agent-mcp-stdio", .root_module = test_modules.agent_mcp_stdio },
        .{ .name = "metawork-agent-checkpoint-restore", .root_module = test_modules.agent_checkpoint_restore },
        .{ .name = "metawork-agent-catalog", .root_module = test_modules.agent_catalog },
        .{ .name = "metawork-agent-checkpoint", .root_module = test_modules.agent_checkpoint },
        .{ .name = "metawork-agent-session", .root_module = test_modules.agent_session },
        .{ .name = "metawork-workbench", .root_module = test_modules.workbench_projection },
        .{ .name = "metawork-workbench-executor", .root_module = test_modules.workbench_executor },
        .{ .name = "metawork-automatic-workspace-allocator", .root_module = test_modules.workbench_automatic_workspace_allocator },
        .{ .name = "metawork-scheduled-task-persistence", .root_module = test_modules.workbench_scheduled_persistence },
        .{ .name = "metawork-skill-package", .root_module = test_modules.workbench_skill_package },
        .{ .name = "metawork-skill-management", .root_module = test_modules.workbench_skill_management },
        .{ .name = "metawork-mcp-configuration", .root_module = test_modules.workbench_mcp_configuration },
        .{ .name = "metawork-mcp-platform", .root_module = test_modules.mcp_platform },
        .{ .name = "metawork-mcp-oauth", .root_module = test_modules.mcp_oauth },
        .{ .name = "metawork-task-persistence", .root_module = test_modules.workbench_task_persistence },
        .{ .name = "metawork-checkpoint-store", .root_module = test_modules.workbench_checkpoint_store },
        .{ .name = "metawork-checkpoint-record", .root_module = test_modules.workbench_checkpoint_record },
        .{ .name = "metawork-task-runtime", .root_module = test_modules.workbench_task_runtime },
        .{ .name = "metawork-task-recovery", .root_module = test_modules.workbench_task_recovery },
        .{ .name = "metawork-task-recovery-job", .root_module = test_modules.workbench_task_recovery_job },
    };
    for (module_tests) |spec| {
        spec.root_module.link_libc = bundle.link_libc;
        const tests = b.addTest(.{ .name = spec.name, .root_module = spec.root_module });
        artifacts.tests.step.dependOn(&b.addRunArtifact(tests).step);
    }
}

fn addLifecycleTests(
    b: *std.Build,
    modules: WiredModules,
    fixture: *std.Build.Module,
    link_libc: bool,
) void {
    const test_filter = b.option([]const u8, "tfilter", "Lifecycle test name filter");
    const step = b.step("test-lifecycle", "Run invariant-grouped lifecycle tests");
    const agent_step = b.step(
        "test-agent-lifecycle",
        "Run the Agent Runtime and MCP lifecycle root",
    );
    const roots = [_][]const u8{
        "tests/agent/lifecycle_test.zig",
        "tests/agent/event_pump_test.zig",
        "tests/workbench/executor_lifecycle_test.zig",
        "tests/integration/lifecycle/lifecycle_test.zig",
    };
    for (roots) |root| {
        const cases = b.createModule(.{
            .root_source_file = b.path(root),
            .target = modules.app.resolved_target,
            .optimize = modules.app.optimize,
            .link_libc = link_libc,
        });
        cases.addImport("lifecycle_fixture", fixture);
        const artifact = b.addTest(.{
            .root_module = cases,
            .filters = if (test_filter) |filter| &.{filter} else &.{},
        });
        const run = b.addRunArtifact(artifact);
        step.dependOn(&run.step);
        if (std.mem.eql(u8, root, "tests/agent/lifecycle_test.zig"))
            agent_step.dependOn(&run.step);
    }

    const source_tests = b.addTest(.{
        .root_module = modules.workbench_projection,
        .filters = if (test_filter) |filter|
            &.{filter}
        else
            &.{ "terminal publication", "Workbench outcomes", "Agent terminal facts" },
    });
    step.dependOn(&b.addRunArtifact(source_tests).step);
}

const WiredModules = struct {
    account: *std.Build.Module,
    account_runtime: *std.Build.Module,
    account_catalog: *std.Build.Module,
    account_credentials_runtime: *std.Build.Module,
    account_model_connections: *std.Build.Module,
    account_contract: *std.Build.Module,
    account_credential_store: *std.Build.Module,
    account_loopback: *std.Build.Module,
    account_login_attempt: *std.Build.Module,
    account_network_attempt: *std.Build.Module,
    account_oauth: *std.Build.Module,
    account_platform: *std.Build.Module,
    account_state: *std.Build.Module,
    metask_client: *std.Build.Module,
    app: *std.Build.Module,
    mcp_platform: *std.Build.Module,
    mcp_oauth: *std.Build.Module,
    agent: *std.Build.Module,
    agent_session: *std.Build.Module,
    agent_catalog: *std.Build.Module,
    agent_checkpoint: *std.Build.Module,
    agent_provider_probe: *std.Build.Module,
    agent_mcp_connector: *std.Build.Module,
    agent_mcp_catalog: *std.Build.Module,
    agent_mcp_http: *std.Build.Module,
    agent_mcp_runtime: *std.Build.Module,
    agent_mcp_stdio: *std.Build.Module,
    agent_checkpoint_restore: *std.Build.Module,
    automation_enabled: *std.Build.Module,
    bridge: *std.Build.Module,
    event_pump: *std.Build.Module,
    sdk: *std.Build.Module,
    workbench: *std.Build.Module,
    workbench_projection: *std.Build.Module,
    workbench_executor: *std.Build.Module,
    workbench_automatic_workspace_allocator: *std.Build.Module,
    workbench_scheduled_persistence: *std.Build.Module,
    workbench_skill_package: *std.Build.Module,
    workbench_skill_management: *std.Build.Module,
    workbench_mcp_configuration: *std.Build.Module,
    workbench_task_persistence: *std.Build.Module,
    workbench_checkpoint_store: *std.Build.Module,
    workbench_checkpoint_record: *std.Build.Module,
    workbench_catalog_snapshot: *std.Build.Module,
    workbench_owned_task_execution: *std.Build.Module,
    workbench_task_runtime: *std.Build.Module,
    workbench_task_recovery: *std.Build.Module,
    workbench_task_recovery_job: *std.Build.Module,
};

fn createLifecycleFixture(
    b: *std.Build,
    modules: WiredModules,
    link_libc: bool,
) *std.Build.Module {
    const fixture = b.createModule(.{
        .root_source_file = b.path("tests/support/lifecycle_fixture.zig"),
        .target = modules.app.resolved_target,
        .optimize = modules.app.optimize,
        .link_libc = link_libc,
    });
    fixture.addImport("metawork_agent", modules.agent);
    fixture.addImport("metawork_workbench", modules.workbench);
    fixture.addImport("metawork_account_contract", modules.account_contract);
    fixture.addImport("event_pump", modules.event_pump);
    fixture.addImport("metask_agentcore", modules.sdk);
    fixture.addImport("workbench_executor", modules.workbench_executor);
    return fixture;
}

fn addMcpConnectorTests(
    b: *std.Build,
    modules: WiredModules,
    link_libc: bool,
) void {
    const step = b.step(
        "test-mcp-connector",
        "Run Agent-private MCP connector adapter tests",
    );
    modules.agent_mcp_connector.link_libc = link_libc;
    const tests = b.addTest(.{
        .name = "metawork-agent-mcp-connector",
        .root_module = modules.agent_mcp_connector,
    });
    step.dependOn(&b.addRunArtifact(tests).step);
}

fn addMcpStdioTests(
    b: *std.Build,
    modules: WiredModules,
    link_libc: bool,
) void {
    const step = b.step(
        "test-mcp-stdio",
        "Run Agent-private MCP stdio backend tests",
    );
    modules.agent_mcp_stdio.link_libc = link_libc;
    const tests = b.addTest(.{
        .name = "metawork-agent-mcp-stdio",
        .root_module = modules.agent_mcp_stdio,
    });
    step.dependOn(&b.addRunArtifact(tests).step);
}

fn addMcpHttpTests(
    b: *std.Build,
    modules: WiredModules,
    link_libc: bool,
) void {
    const step = b.step(
        "test-mcp-http",
        "Run Agent-private MCP authorized HTTP backend tests",
    );
    modules.agent_mcp_http.link_libc = link_libc;
    const tests = b.addTest(.{
        .name = "metawork-agent-mcp-http",
        .root_module = modules.agent_mcp_http,
    });
    step.dependOn(&b.addRunArtifact(tests).step);
}

fn addMcpRuntimeTests(
    b: *std.Build,
    modules: WiredModules,
    link_libc: bool,
) void {
    const step = b.step("test-mcp-runtime", "Run Agent-private MCP Runtime owner tests");
    modules.agent_mcp_runtime.link_libc = link_libc;
    const tests = b.addTest(.{
        .name = "metawork-agent-mcp-runtime",
        .root_module = modules.agent_mcp_runtime,
    });
    step.dependOn(&b.addRunArtifact(tests).step);
}

fn addMcpCatalogTests(
    b: *std.Build,
    modules: WiredModules,
    link_libc: bool,
) void {
    const step = b.step("test-mcp-catalog", "Run Agent-private MCP catalog tests");
    modules.agent_mcp_catalog.link_libc = link_libc;
    const tests = b.addTest(.{
        .name = "metawork-agent-mcp-catalog",
        .root_module = modules.agent_mcp_catalog,
    });
    step.dependOn(&b.addRunArtifact(tests).step);
}

fn addMcpConfigurationTests(
    b: *std.Build,
    modules: WiredModules,
    link_libc: bool,
) void {
    const step = b.step(
        "test-mcp-configuration",
        "Run Workbench-owned MCP registry and preparation tests",
    );
    modules.workbench_mcp_configuration.link_libc = link_libc;
    const tests = b.addTest(.{
        .name = "metawork-mcp-configuration",
        .root_module = modules.workbench_mcp_configuration,
    });
    step.dependOn(&b.addRunArtifact(tests).step);
}

fn addWorkbenchMcpTests(
    b: *std.Build,
    modules: WiredModules,
    link_libc: bool,
) void {
    const step = b.step(
        "test-workbench-mcp",
        "Run Workbench MCP binding and safe projection tests",
    );
    modules.workbench_projection.link_libc = link_libc;
    const tests = b.addTest(.{
        .name = "metawork-workbench-mcp",
        .root_module = modules.workbench_projection,
        .filters = &.{"MCP"},
    });
    step.dependOn(&b.addRunArtifact(tests).step);
}

fn addMcpPlatformTests(
    b: *std.Build,
    modules: WiredModules,
    link_libc: bool,
) void {
    const step = b.step(
        "test-mcp-platform",
        "Run App-owned MCP credential and transport composition tests",
    );
    modules.mcp_platform.link_libc = link_libc;
    const tests = b.addTest(.{
        .name = "metawork-mcp-platform",
        .root_module = modules.mcp_platform,
    });
    step.dependOn(&b.addRunArtifact(tests).step);
}

fn addMcpOauthTests(
    b: *std.Build,
    modules: WiredModules,
    link_libc: bool,
) void {
    const step = b.step(
        "test-mcp-oauth",
        "Run App-owned MCP OAuth protocol and boundary tests",
    );
    modules.mcp_oauth.link_libc = link_libc;
    const tests = b.addTest(.{
        .name = "metawork-mcp-oauth",
        .root_module = modules.mcp_oauth,
    });
    step.dependOn(&b.addRunArtifact(tests).step);
}

fn addMcpAppTests(
    b: *std.Build,
    modules: WiredModules,
    link_libc: bool,
) void {
    const step = b.step(
        "test-mcp-app",
        "Compile App MCP startup composition and run its focused tests",
    );
    modules.app.link_libc = link_libc;
    const tests = b.addTest(.{
        .name = "metawork-mcp-app",
        .root_module = modules.app,
        .filters = &.{"MCP"},
    });
    step.dependOn(&b.addRunArtifact(tests).step);
}

fn addMcpInteropTests(
    b: *std.Build,
    modules: WiredModules,
    link_libc: bool,
) *std.Build.Step {
    const node_path = b.findProgram(&.{"node"}, &.{}) catch
        @panic("Node.js is required for deterministic MCP interoperability tests");
    const fixture_options = b.addOptions();
    fixture_options.addOption([]const u8, "node_path", node_path);
    fixture_options.addOption(
        ?[]const u8,
        "windows_system_root",
        b.graph.environ_map.get("SystemRoot"),
    );
    fixture_options.addOption(
        []const u8,
        "fixture_path",
        b.pathFromRoot("tests/fixtures/mcp_server.mjs"),
    );
    const cases = b.createModule(.{
        .root_source_file = b.path("tests/agent/mcp_interop_test.zig"),
        .target = modules.app.resolved_target,
        .optimize = modules.app.optimize,
        .link_libc = link_libc,
    });
    cases.addImport("metawork_agent", modules.agent);
    cases.addImport("metawork_account_contract", modules.account_contract);
    cases.addImport("metawork_mcp_platform", modules.mcp_platform);
    cases.addImport("metawork_workbench", modules.workbench);
    cases.addOptions("mcp_interop_options", fixture_options);
    const tests = b.addTest(.{
        .name = "metawork-mcp-interop",
        .root_module = cases,
    });
    const run = b.addRunArtifact(tests);
    b.step(
        "test-mcp-interop",
        "Run deterministic real-server MCP interoperability tests",
    ).dependOn(&run.step);
    return &run.step;
}

fn wireAgentCore(b: *std.Build, root_module: *std.Build.Module, bundle: agentcore_bundle.Bundle) WiredModules {
    var query = (root_module.resolved_target orelse @panic("Native SDK app target is unresolved")).query;
    if (bundle.deployment_target) |deployment_target|
        query.os_version_min = .{ .semver = deployment_target };
    const target = b.resolveTargetQuery(query);
    root_module.resolved_target = target;

    const runner = existingImport(root_module, "runner");
    const product_identity = b.createModule(.{
        .root_source_file = b.path("src/product_identity.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    product_identity.addImport(
        "app_manifest_zon",
        existingImport(runner, "app_manifest_zon"),
    );
    const sdk = b.dependency("agentcore", .{
        .target = target,
        .optimize = root_module.optimize,
    }).module("metask_agentcore");
    const event_sink = b.createModule(.{
        .root_source_file = b.path("src/agent/event_sink.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    event_sink.addImport("metask_agentcore", sdk);
    const event_pump = b.createModule(.{
        .root_source_file = b.path("src/agent/event_pump.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    event_pump.addImport("metask_agentcore", sdk);
    event_pump.addImport("event_sink", event_sink);
    const agent_catalog = b.createModule(.{
        .root_source_file = b.path("src/agent/catalog.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    agent_catalog.addImport("metask_agentcore", sdk);
    const agent_mcp_connector = b.createModule(.{
        .root_source_file = b.path("src/agent/mcp/connector.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    agent_mcp_connector.addImport("metask_agentcore", sdk);
    const agent_mcp_http = b.createModule(.{
        .root_source_file = b.path("src/agent/mcp/http.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    agent_mcp_http.addImport("agent_mcp_connector", agent_mcp_connector);
    const agent_mcp_runtime = b.createModule(.{
        .root_source_file = b.path("src/agent/mcp/runtime.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    agent_mcp_runtime.addImport("metask_agentcore", sdk);
    agent_mcp_runtime.addImport("agent_mcp_connector", agent_mcp_connector);
    const agent_mcp_catalog = b.createModule(.{
        .root_source_file = b.path("src/agent/mcp/catalog.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    agent_mcp_catalog.addImport("metask_agentcore", sdk);
    agent_mcp_catalog.addImport("agent_mcp_runtime", agent_mcp_runtime);
    const agent_mcp_stdio = b.createModule(.{
        .root_source_file = b.path("src/agent/mcp/stdio.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    agent_mcp_stdio.addImport("agent_mcp_connector", agent_mcp_connector);
    const agent_checkpoint = b.createModule(.{
        .root_source_file = b.path("src/agent/checkpoint.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    agent_checkpoint.addImport("metask_agentcore", sdk);
    const agent_checkpoint_restore = b.createModule(.{
        .root_source_file = b.path("src/agent/checkpoint_restore.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    agent_checkpoint_restore.addImport("metask_agentcore", sdk);
    agent_checkpoint_restore.addImport("agent_checkpoint", agent_checkpoint);
    const session = b.createModule(.{
        .root_source_file = b.path("src/agent/session.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    session.addImport("metask_agentcore", sdk);
    session.addImport("event_pump", event_pump);
    session.addImport("agent_catalog", agent_catalog);
    session.addImport("agent_mcp_runtime", agent_mcp_runtime);
    session.addImport("agent_mcp_catalog", agent_mcp_catalog);
    session.addImport("agent_checkpoint", agent_checkpoint);
    session.addImport("agent_checkpoint_restore", agent_checkpoint_restore);
    const agent = b.createModule(.{
        .root_source_file = b.path("src/agent.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    agent.addImport("agent_session", session);
    agent.addImport("agent_mcp_connector", agent_mcp_connector);
    agent.addImport("agent_mcp_stdio", agent_mcp_stdio);
    agent.addImport("agent_mcp_http", agent_mcp_http);
    const agent_provider_probe = b.createModule(.{
        .root_source_file = b.path("src/agent/provider_probe.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    agent_provider_probe.addImport("metask_agentcore", sdk);
    agent.addImport("agent_provider_probe", agent_provider_probe);
    const account_contract = b.createModule(.{
        .root_source_file = b.path("src/account/contract.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    const account_state = b.createModule(.{
        .root_source_file = b.path("src/account/state.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    account_state.addImport("metawork_account_contract", account_contract);
    const account_oauth = b.createModule(.{
        .root_source_file = b.path("src/account/oauth.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    account_oauth.addImport("metawork_account_contract", account_contract);
    const account_loopback = b.createModule(.{
        .root_source_file = b.path("src/account/loopback.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    account_loopback.addImport("account_oauth", account_oauth);
    const metask_client = b.createModule(.{
        .root_source_file = b.path("src/account/metask_client.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    metask_client.addImport("metawork_account_contract", account_contract);
    metask_client.addImport("account_state", account_state);
    metask_client.addImport("account_oauth", account_oauth);
    const account_login_attempt = b.createModule(.{
        .root_source_file = b.path("src/account/login_attempt.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    account_login_attempt.addImport("metawork_account_contract", account_contract);
    account_login_attempt.addImport("account_state", account_state);
    account_login_attempt.addImport("account_oauth", account_oauth);
    account_login_attempt.addImport("account_loopback", account_loopback);
    account_login_attempt.addImport("metask_client", metask_client);
    const account_catalog = b.createModule(.{
        .root_source_file = b.path("src/account/catalog.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    account_catalog.addImport("metawork_account_contract", account_contract);
    account_catalog.addImport("metask_client", metask_client);
    const account_credentials_runtime = b.createModule(.{
        .root_source_file = b.path("src/account/credentials.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    account_credentials_runtime.addImport("account_state", account_state);
    account_credentials_runtime.addImport("account_oauth", account_oauth);
    account_credentials_runtime.addImport("metawork_account_contract", account_contract);
    account_credentials_runtime.addImport("metask_client", metask_client);
    account_credentials_runtime.addImport("account_catalog", account_catalog);
    const account_model_connections = b.createModule(.{
        .root_source_file = b.path("src/account/model_connections.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    account_model_connections.addImport("metawork_account_contract", account_contract);
    const account_network_attempt = b.createModule(.{
        .root_source_file = b.path("src/account/network_attempt.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    account_network_attempt.addImport("metawork_account_contract", account_contract);
    account_network_attempt.addImport("account_state", account_state);
    account_network_attempt.addImport("account_oauth", account_oauth);
    account_network_attempt.addImport("metask_client", metask_client);
    account_network_attempt.addImport("account_catalog", account_catalog);
    account_network_attempt.addImport("account_credentials_runtime", account_credentials_runtime);
    const account_credential_store = b.createModule(.{
        .root_source_file = b.path("src/account/credential_store.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    account_credential_store.addImport("metawork_account_contract", account_contract);
    account_credential_store.addImport("account_oauth", account_oauth);
    account_credential_store.addImport("metawork_product_identity", product_identity);
    account_credential_store.addImport(
        "build_options",
        existingImport(runner, "build_options"),
    );
    const account_platform = b.createModule(.{
        .root_source_file = b.path("src/account/platform.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    account_platform.addImport("native_sdk", existingImport(root_module, "native_sdk"));
    account_platform.addImport("account_oauth", account_oauth);
    account_platform.addImport("account_credential_store", account_credential_store);
    const account_runtime = b.createModule(.{
        .root_source_file = b.path("src/account/runtime.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    account_runtime.addImport("metawork_account_contract", account_contract);
    account_runtime.addImport("account_state", account_state);
    account_runtime.addImport("metask_client", metask_client);
    account_runtime.addImport("account_credential_store", account_credential_store);
    account_runtime.addImport("account_platform", account_platform);
    account_runtime.addImport("account_login_attempt", account_login_attempt);
    account_runtime.addImport("account_catalog", account_catalog);
    account_runtime.addImport("account_credentials_runtime", account_credentials_runtime);
    account_runtime.addImport("account_network_attempt", account_network_attempt);
    account_runtime.addImport("account_model_connections", account_model_connections);
    account_runtime.addImport("native_sdk", existingImport(root_module, "native_sdk"));
    const account = b.createModule(.{
        .root_source_file = b.path("src/account.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    account.addImport("account_state", account_state);
    account.addImport("account_oauth", account_oauth);
    account.addImport("metask_client", metask_client);
    account.addImport("account_credential_store", account_credential_store);
    account.addImport("account_platform", account_platform);
    account.addImport("account_loopback", account_loopback);
    account.addImport("account_login_attempt", account_login_attempt);
    account.addImport("account_catalog", account_catalog);
    account.addImport("account_credentials_runtime", account_credentials_runtime);
    account.addImport("account_network_attempt", account_network_attempt);
    account.addImport("account_runtime", account_runtime);
    const executor = b.createModule(.{
        .root_source_file = b.path("src/workbench/executor.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    const automatic_workspace_allocator = b.createModule(.{
        .root_source_file = b.path("src/workbench/automatic_workspace_allocator.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    const scheduled_tasks = b.createModule(.{
        .root_source_file = b.path("src/workbench/scheduled_tasks.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    const scheduled_task_persistence = b.createModule(.{
        .root_source_file = b.path("src/workbench/scheduled_task_persistence.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    scheduled_task_persistence.addImport(
        "workbench_scheduled_tasks",
        scheduled_tasks,
    );
    const skill_package = b.createModule(.{
        .root_source_file = b.path("src/workbench/skill_package.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    const skill_management = b.createModule(.{
        .root_source_file = b.path("src/workbench/skill_management.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    skill_management.addImport("workbench_skill_package", skill_package);
    const task_persistence = b.createModule(.{
        .root_source_file = b.path("src/workbench/task_persistence.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    const checkpoint_store = b.createModule(.{
        .root_source_file = b.path("src/workbench/checkpoint_store.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    const checkpoint_record = b.createModule(.{
        .root_source_file = b.path("src/workbench/checkpoint_record.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    checkpoint_record.addImport("workbench_checkpoint_store", checkpoint_store);
    const catalog_snapshot = b.createModule(.{
        .root_source_file = b.path("src/workbench/catalog_snapshot.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    catalog_snapshot.addImport("metawork_agent", agent);
    const owned_task_execution = b.createModule(.{
        .root_source_file = b.path("src/workbench/owned_task_execution.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    owned_task_execution.addImport("metawork_account_contract", account_contract);
    const task_runtime = b.createModule(.{
        .root_source_file = b.path("src/workbench/task_runtime.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    task_runtime.addImport("metawork_agent", agent);
    task_runtime.addImport("workbench_catalog_snapshot", catalog_snapshot);
    task_runtime.addImport("workbench_owned_task_execution", owned_task_execution);
    const task_recovery = b.createModule(.{
        .root_source_file = b.path("src/workbench/task_recovery.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    const task_recovery_job = b.createModule(.{
        .root_source_file = b.path("src/workbench/task_recovery_job.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    task_recovery_job.addImport("metawork_agent", agent);
    task_recovery_job.addImport("workbench_checkpoint_record", checkpoint_record);
    task_recovery_job.addImport("workbench_checkpoint_store", checkpoint_store);
    task_recovery_job.addImport("workbench_catalog_snapshot", catalog_snapshot);
    task_recovery_job.addImport("workbench_owned_task_execution", owned_task_execution);
    task_runtime.addImport("workbench_task_recovery_job", task_recovery_job);
    const mcp_configuration = b.createModule(.{
        .root_source_file = b.path("src/workbench/mcp_configuration.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    const projection = b.createModule(.{
        .root_source_file = b.path("src/workbench/projection.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    projection.addImport("metawork_agent", agent);
    projection.addImport("metawork_account_contract", account_contract);
    projection.addImport("workbench_executor", executor);
    projection.addImport("workbench_automatic_workspace_allocator", automatic_workspace_allocator);
    projection.addImport("workbench_scheduled_tasks", scheduled_tasks);
    projection.addImport(
        "workbench_scheduled_task_persistence",
        scheduled_task_persistence,
    );
    projection.addImport("workbench_skill_management", skill_management);
    projection.addImport("workbench_skill_package", skill_package);
    projection.addImport("workbench_task_persistence", task_persistence);
    projection.addImport("workbench_checkpoint_store", checkpoint_store);
    projection.addImport("workbench_checkpoint_record", checkpoint_record);
    projection.addImport("workbench_catalog_snapshot", catalog_snapshot);
    projection.addImport("workbench_owned_task_execution", owned_task_execution);
    projection.addImport("workbench_task_runtime", task_runtime);
    projection.addImport("workbench_task_recovery", task_recovery);
    projection.addImport("workbench_task_recovery_job", task_recovery_job);
    projection.addImport("workbench_mcp_configuration", mcp_configuration);
    projection.addImport(
        "build_options",
        existingImport(
            existingImport(root_module, "runner"),
            "build_options",
        ),
    );
    const workbench_contract_fixture = b.addOptions();
    workbench_contract_fixture.addOption(
        []const u8,
        "snapshot",
        @embedFile("frontend/src/bridge/__fixtures__/workbench-snapshot.fixture"),
    );
    projection.addOptions("workbench_contract_fixture", workbench_contract_fixture);
    const workbench = b.createModule(.{
        .root_source_file = b.path("src/workbench.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    workbench.addImport("workbench_projection", projection);
    workbench.addImport("workbench_automatic_workspace_allocator", automatic_workspace_allocator);
    workbench.addImport(
        "workbench_scheduled_task_persistence",
        scheduled_task_persistence,
    );
    workbench.addImport("workbench_skill_package", skill_package);
    workbench.addImport("workbench_skill_management", skill_management);
    workbench.addImport("workbench_mcp_configuration", mcp_configuration);
    workbench.addImport("workbench_task_persistence", task_persistence);
    workbench.addImport("workbench_checkpoint_store", checkpoint_store);
    workbench.addImport("workbench_checkpoint_record", checkpoint_record);

    const bridge = b.createModule(.{
        .root_source_file = b.path("src/bridge.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    bridge.addImport("native_sdk", existingImport(root_module, "native_sdk"));
    bridge.addImport("metawork_account_contract", account_contract);
    bridge.addImport("metawork_workbench", workbench);

    const automation_disabled = b.createModule(.{
        .root_source_file = b.path("src/automation/disabled.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    automation_disabled.addImport("native_sdk", existingImport(root_module, "native_sdk"));
    automation_disabled.addImport("metawork_bridge", bridge);
    automation_disabled.addImport("metawork_account_contract", account_contract);
    const automation_enabled = b.createModule(.{
        .root_source_file = b.path("src/automation/enabled.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    automation_enabled.addImport("native_sdk", existingImport(root_module, "native_sdk"));
    automation_enabled.addImport("metawork_bridge", bridge);
    automation_enabled.addImport("metawork_account_contract", account_contract);
    const automation = b.createModule(.{
        .root_source_file = b.path("src/automation.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    automation.addImport("build_options", existingImport(runner, "build_options"));
    automation.addImport("automation_enabled", automation_enabled);
    automation.addImport("automation_disabled", automation_disabled);

    const mcp_platform = b.createModule(.{
        .root_source_file = b.path("src/app/mcp_platform.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    mcp_platform.addImport("native_sdk", existingImport(root_module, "native_sdk"));
    mcp_platform.addImport("metawork_agent", agent);
    mcp_platform.addImport("metawork_workbench", workbench);
    mcp_platform.addImport("metawork_product_identity", product_identity);
    const mcp_oauth = b.createModule(.{
        .root_source_file = b.path("src/app/mcp_oauth.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    mcp_oauth.addImport("account_oauth", account_oauth);
    mcp_oauth.addImport("account_loopback", account_loopback);
    mcp_platform.addImport("metawork_mcp_oauth", mcp_oauth);

    const app = b.createModule(.{
        .root_source_file = b.path("src/app.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    app.addImport("runner", runner);
    app.addImport("build_options", existingImport(runner, "build_options"));
    app.addImport("native_sdk", existingImport(root_module, "native_sdk"));
    app.addImport("metawork_agent", agent);
    app.addImport("metawork_workbench", workbench);
    app.addImport("metawork_bridge", bridge);
    app.addImport("metawork_automation", automation);
    app.addImport("metawork_account_contract", account_contract);
    app.addImport("metawork_account", account);
    app.addImport("metawork_product_identity", product_identity);
    app.addImport("metawork_mcp_platform", mcp_platform);
    app.addImport("metawork_mcp_oauth", mcp_oauth);

    root_module.addImport("metawork_app", app);
    root_module.link_libc = bundle.link_libc;
    return .{
        .account = account,
        .account_runtime = account_runtime,
        .account_catalog = account_catalog,
        .account_credentials_runtime = account_credentials_runtime,
        .account_model_connections = account_model_connections,
        .account_contract = account_contract,
        .account_credential_store = account_credential_store,
        .account_loopback = account_loopback,
        .account_login_attempt = account_login_attempt,
        .account_network_attempt = account_network_attempt,
        .account_oauth = account_oauth,
        .account_platform = account_platform,
        .account_state = account_state,
        .metask_client = metask_client,
        .app = app,
        .mcp_platform = mcp_platform,
        .mcp_oauth = mcp_oauth,
        .agent = agent,
        .agent_session = session,
        .agent_catalog = agent_catalog,
        .agent_checkpoint = agent_checkpoint,
        .agent_provider_probe = agent_provider_probe,
        .agent_mcp_connector = agent_mcp_connector,
        .agent_mcp_catalog = agent_mcp_catalog,
        .agent_mcp_http = agent_mcp_http,
        .agent_mcp_runtime = agent_mcp_runtime,
        .agent_mcp_stdio = agent_mcp_stdio,
        .agent_checkpoint_restore = agent_checkpoint_restore,
        .automation_enabled = automation_enabled,
        .bridge = bridge,
        .event_pump = event_pump,
        .sdk = sdk,
        .workbench = workbench,
        .workbench_projection = projection,
        .workbench_executor = executor,
        .workbench_automatic_workspace_allocator = automatic_workspace_allocator,
        .workbench_scheduled_persistence = scheduled_task_persistence,
        .workbench_skill_package = skill_package,
        .workbench_skill_management = skill_management,
        .workbench_mcp_configuration = mcp_configuration,
        .workbench_task_persistence = task_persistence,
        .workbench_checkpoint_store = checkpoint_store,
        .workbench_checkpoint_record = checkpoint_record,
        .workbench_catalog_snapshot = catalog_snapshot,
        .workbench_owned_task_execution = owned_task_execution,
        .workbench_task_runtime = task_runtime,
        .workbench_task_recovery = task_recovery,
        .workbench_task_recovery_job = task_recovery_job,
    };
}

fn existingImport(module: *std.Build.Module, name: []const u8) *std.Build.Module {
    return module.import_table.get(name) orelse
        std.debug.panic("Native SDK root module does not expose required import '{s}'", .{name});
}
