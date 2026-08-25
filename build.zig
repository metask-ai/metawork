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
    const app_target = (artifacts.exe.root_module.resolved_target orelse @panic("Native SDK app target is unresolved")).result;
    const target_id = agentCoreTargetId(app_target);
    const root = b.pathFromRoot(b.pathJoin(&.{ ".agentcore/bundles", target_id }));
    const bundle = agentcore_bundle.verify(b, root);
    const modules = wireAgentCore(b, artifacts.exe.root_module, bundle);
    const test_modules = if (artifacts.tests.root_module != artifacts.exe.root_module)
        wireAgentCore(b, artifacts.tests.root_module, bundle)
    else
        modules;
    if (test_modules.app.resolved_target.?.result.os.tag == .macos) {
        if (b.sysroot) |sysroot| test_modules.app.addFrameworkPath(.{
            .cwd_relative = b.pathJoin(&.{ sysroot, "System/Library/Frameworks" }),
        });
        test_modules.app.linkFramework("AppKit", .{});
    }
    const lifecycle_fixture = createLifecycleFixture(b, test_modules, bundle.link_libc);
    test_modules.app.addImport("lifecycle_fixture", lifecycle_fixture);
    test_modules.bridge.addImport("lifecycle_fixture", lifecycle_fixture);
    addLifecycleTests(
        b,
        test_modules,
        lifecycle_fixture,
        bundle.link_libc,
        &artifacts.tests.step,
    );
    addMcpConnectorTests(b, test_modules, bundle.link_libc);
    addMcpStdioTests(b, test_modules, bundle.link_libc);
    addMcpHttpTests(b, test_modules, bundle.link_libc);
    addMcpRuntimeTests(b, test_modules, bundle.link_libc);
    addMcpCatalogTests(b, test_modules, bundle.link_libc);
    addMcpConfigurationTests(b, test_modules, bundle.link_libc);
    addProductMcpStateTests(b, test_modules, bundle.link_libc);
    addProductMcpPolicyTests(b, test_modules, bundle.link_libc);
    addProductMcpViewTests(b, test_modules, bundle.link_libc);
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
        .{ .name = "metawork-account-ports", .root_module = test_modules.account_ports },
        .{ .name = "metawork-account-loopback", .root_module = test_modules.account_loopback },
        .{ .name = "metawork-oauth-loopback-transport", .root_module = test_modules.oauth_loopback_transport },
        .{ .name = "metawork-account-login-attempt", .root_module = test_modules.account_login_attempt },
        .{ .name = "metawork-account-catalog", .root_module = test_modules.account_catalog },
        .{ .name = "metawork-account-credentials-runtime", .root_module = test_modules.account_credentials_runtime },
        .{ .name = "metawork-account-network-attempt", .root_module = test_modules.account_network_attempt },
        .{ .name = "metawork-account-state", .root_module = test_modules.account_state },
        .{ .name = "metawork-account-runtime", .root_module = test_modules.account_runtime },
        .{ .name = "metawork-account", .root_module = test_modules.account },
        .{ .name = "metawork-storage", .root_module = test_modules.storage },
        .{ .name = "metawork-app", .root_module = test_modules.app },
        .{ .name = "metawork-automation-enabled", .root_module = test_modules.automation_enabled },
        .{ .name = "metawork-bridge", .root_module = test_modules.bridge },
        .{ .name = "metawork-agent-mcp-connector", .root_module = test_modules.agent_mcp_connector },
        .{ .name = "metawork-agent-provider", .root_module = test_modules.agent_provider },
        .{ .name = "metawork-agent-completion", .root_module = test_modules.agent_completion },
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
        .{ .name = "metawork-product-skill-package", .root_module = test_modules.product_skill_package },
        .{ .name = "metawork-product-skill-management", .root_module = test_modules.product_skill_management },
        .{ .name = "metawork-product-skill-enablement", .root_module = test_modules.product_skill_enablement },
        .{ .name = "metawork-product-skill-state", .root_module = test_modules.product_skill_state },
        .{ .name = "metawork-product-skill-policy", .root_module = test_modules.product_skill_policy },
        .{ .name = "metawork-product-skill-runtime", .root_module = test_modules.product_skill_runtime },
        .{ .name = "metawork-product-skill-view", .root_module = test_modules.product_skill_view },
        .{ .name = "metawork-product-mcp-configuration", .root_module = test_modules.product_mcp_configuration },
        .{ .name = "metawork-product-mcp-state", .root_module = test_modules.product_mcp_state },
        .{ .name = "metawork-product-mcp-policy", .root_module = test_modules.product_mcp_policy },
        .{ .name = "metawork-product-mcp-view", .root_module = test_modules.product_mcp_view },
        .{ .name = "metawork-mcp-platform", .root_module = test_modules.mcp_platform },
        .{ .name = "metawork-mcp-oauth", .root_module = test_modules.mcp_oauth },
        .{ .name = "metawork-product-task-persistence", .root_module = test_modules.product_task_persistence },
        .{ .name = "metawork-product-task-checkpoint-store", .root_module = test_modules.product_task_checkpoint_store },
        .{ .name = "metawork-product-task-checkpoint-record", .root_module = test_modules.product_task_checkpoint_record },
        .{ .name = "metawork-product-task-agent-session", .root_module = test_modules.product_task_agent_session },
        .{ .name = "metawork-product-skill-catalog", .root_module = test_modules.product_skill_catalog },
        .{ .name = "metawork-product-task-runtime", .root_module = test_modules.product_task_runtime },
        .{ .name = "metawork-product-task-deletion", .root_module = test_modules.product_task_deletion },
        .{ .name = "metawork-product-task-recovery", .root_module = test_modules.product_task_recovery },
        .{ .name = "metawork-product-task-recovery-job", .root_module = test_modules.product_task_recovery_job },
        .{ .name = "metawork-product-task-state", .root_module = test_modules.product_task_state },
        .{ .name = "metawork-product-task-policy", .root_module = test_modules.product_task_policy },
        .{ .name = "metawork-product-task-view", .root_module = test_modules.product_task_view },
    };
    for (module_tests) |spec| {
        spec.root_module.link_libc = bundle.link_libc;
        const tests = b.addTest(.{ .name = spec.name, .root_module = spec.root_module });
        artifacts.tests.step.dependOn(&b.addRunArtifact(tests).step);
    }
    const storage_tests = b.addTest(.{
        .name = "metawork-storage",
        .root_module = test_modules.storage,
    });
    b.step(
        "test-storage",
        "Run the backend-independent Storage contract and SQLite backend tests",
    ).dependOn(&b.addRunArtifact(storage_tests).step);
}

fn agentCoreTargetId(target: std.Target) []const u8 {
    return switch (target.os.tag) {
        .macos => switch (target.cpu.arch) {
            .aarch64 => "aarch64-macos",
            .x86_64 => "x86_64-macos",
            else => @panic("unsupported macOS AgentCore architecture"),
        },
        .windows => switch (target.cpu.arch) {
            .x86_64 => "x86_64-windows-gnu",
            else => @panic("unsupported Windows AgentCore architecture"),
        },
        else => @panic("unsupported AgentCore operating system"),
    };
}

fn addLifecycleTests(
    b: *std.Build,
    modules: WiredModules,
    fixture: *std.Build.Module,
    link_libc: bool,
    default_step: *std.Build.Step,
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
        default_step.dependOn(&run.step);
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
    storage: *std.Build.Module,
    account: *std.Build.Module,
    account_runtime: *std.Build.Module,
    account_catalog: *std.Build.Module,
    account_credentials_runtime: *std.Build.Module,
    account_model_connections: *std.Build.Module,
    account_contract: *std.Build.Module,
    account_credential_store: *std.Build.Module,
    account_loopback: *std.Build.Module,
    oauth_loopback_transport: *std.Build.Module,
    account_login_attempt: *std.Build.Module,
    account_network_attempt: *std.Build.Module,
    account_oauth: *std.Build.Module,
    account_ports: *std.Build.Module,
    account_state: *std.Build.Module,
    metask_client: *std.Build.Module,
    app: *std.Build.Module,
    mcp_platform: *std.Build.Module,
    mcp_oauth: *std.Build.Module,
    agent: *std.Build.Module,
    agent_provider: *std.Build.Module,
    agent_completion: *std.Build.Module,
    agent_session: *std.Build.Module,
    agent_catalog: *std.Build.Module,
    agent_checkpoint: *std.Build.Module,
    agent_provider_probe: *std.Build.Module,
    agent_mcp_connector: *std.Build.Module,
    agent_mcp_catalog: *std.Build.Module,
    agent_mcp_http_protocol: *std.Build.Module,
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
    product_skill_package: *std.Build.Module,
    product_skill_management: *std.Build.Module,
    product_skill_enablement: *std.Build.Module,
    product_skill_state: *std.Build.Module,
    product_skill_policy: *std.Build.Module,
    product_skill_runtime: *std.Build.Module,
    product_skill_view: *std.Build.Module,
    product_mcp: *std.Build.Module,
    product_mcp_configuration: *std.Build.Module,
    product_mcp_state: *std.Build.Module,
    product_mcp_policy: *std.Build.Module,
    product_mcp_view: *std.Build.Module,
    product_skill: *std.Build.Module,
    product_skill_catalog: *std.Build.Module,
    product_task: *std.Build.Module,
    product_task_persistence: *std.Build.Module,
    product_task_checkpoint_store: *std.Build.Module,
    product_task_checkpoint_record: *std.Build.Module,
    product_task_execution_binding: *std.Build.Module,
    product_task_agent_session: *std.Build.Module,
    product_task_runtime: *std.Build.Module,
    product_task_deletion: *std.Build.Module,
    product_task_recovery: *std.Build.Module,
    product_task_recovery_job: *std.Build.Module,
    product_task_state: *std.Build.Module,
    product_task_policy: *std.Build.Module,
    product_task_view: *std.Build.Module,
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
    fixture.addImport("metawork_product_skill", modules.product_skill);
    fixture.addImport("metawork_product_task", modules.product_task);
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
        "Run Product MCP registry and preparation tests",
    );
    modules.product_mcp_configuration.link_libc = link_libc;
    const tests = b.addTest(.{
        .name = "metawork-product-mcp-configuration",
        .root_module = modules.product_mcp_configuration,
    });
    step.dependOn(&b.addRunArtifact(tests).step);
}

fn addProductMcpStateTests(
    b: *std.Build,
    modules: WiredModules,
    link_libc: bool,
) void {
    const step = b.step(
        "test-product-mcp-state",
        "Run Product MCP state and freshness tests",
    );
    modules.product_mcp_state.link_libc = link_libc;
    const tests = b.addTest(.{
        .name = "metawork-product-mcp-state",
        .root_module = modules.product_mcp_state,
    });
    step.dependOn(&b.addRunArtifact(tests).step);
}

fn addProductMcpPolicyTests(
    b: *std.Build,
    modules: WiredModules,
    link_libc: bool,
) void {
    const step = b.step(
        "test-product-mcp-policy",
        "Run Product MCP policy and state-transition tests",
    );
    modules.product_mcp_policy.link_libc = link_libc;
    const tests = b.addTest(.{
        .name = "metawork-product-mcp-policy",
        .root_module = modules.product_mcp_policy,
    });
    step.dependOn(&b.addRunArtifact(tests).step);
}

fn addProductMcpViewTests(
    b: *std.Build,
    modules: WiredModules,
    link_libc: bool,
) void {
    const step = b.step(
        "test-product-mcp-view",
        "Run Product MCP snapshot derivation tests",
    );
    modules.product_mcp_view.link_libc = link_libc;
    const tests = b.addTest(.{
        .name = "metawork-product-mcp-view",
        .root_module = modules.product_mcp_view,
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
        .filters = &.{ "MCP", "Workbench snapshot serializer" },
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
    cases.addImport("metawork_product_mcp", modules.product_mcp);
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
    const storage = b.createModule(.{
        .root_source_file = b.path("src/storage.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    const sqlite = b.dependency("sqlite", .{});
    storage.addIncludePath(sqlite.path("."));
    storage.addCSourceFile(.{
        .file = sqlite.path("sqlite3.c"),
        .flags = &.{
            "-DSQLITE_THREADSAFE=2",
            "-DSQLITE_OMIT_LOAD_EXTENSION",
            "-DSQLITE_DQS=0",
            "-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1",
            "-DSQLITE_DEFAULT_MEMSTATUS=0",
        },
    });
    storage.link_libc = true;
    product_identity.addImport(
        "app_manifest_zon",
        existingImport(runner, "app_manifest_zon"),
    );
    const dependency_options = .{
        .target = target,
        .optimize = root_module.optimize,
    };
    const sdk = switch (bundle.sdk_dependency) {
        .macos_arm64 => b.dependency("agentcore_macos_arm64", dependency_options),
        .macos_x64 => b.dependency("agentcore_macos_x64", dependency_options),
        .windows_x64 => b.dependency("agentcore_windows_x64", dependency_options),
    }.module("metask_agentcore");
    const agent_provider = b.createModule(.{
        .root_source_file = b.path("src/agent/provider.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    agent_provider.addImport("metask_agentcore", sdk);
    const agent_completion = b.createModule(.{
        .root_source_file = b.path("src/agent/completion.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    agent_completion.addImport("metask_agentcore", sdk);
    agent_completion.addImport("agent_provider", agent_provider);
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
    const agent_mcp_http_protocol = b.createModule(.{
        .root_source_file = b.path("src/agent/mcp/http_protocol.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    const agent_mcp_http = b.createModule(.{
        .root_source_file = b.path("src/agent/mcp/http.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    agent_mcp_http.addImport("agent_mcp_connector", agent_mcp_connector);
    agent_mcp_http.addImport("agent_mcp_http_protocol", agent_mcp_http_protocol);
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
    session.addImport("agent_provider", agent_provider);
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
    agent.addImport("agent_provider", agent_provider);
    agent.addImport("agent_completion", agent_completion);
    agent.addImport("agent_mcp_connector", agent_mcp_connector);
    agent.addImport("agent_mcp_stdio", agent_mcp_stdio);
    agent.addImport("agent_mcp_http", agent_mcp_http);
    const agent_provider_probe = b.createModule(.{
        .root_source_file = b.path("src/agent/provider_probe.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    agent_provider_probe.addImport("agent_completion", agent_completion);
    agent.addImport("agent_provider_probe", agent_provider_probe);
    const account_contract = b.createModule(.{
        .root_source_file = b.path("src/product/account/contract.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    const account_state = b.createModule(.{
        .root_source_file = b.path("src/product/account/state.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    account_state.addImport("metawork_account_contract", account_contract);
    const account_oauth = b.createModule(.{
        .root_source_file = b.path("src/product/account/oauth.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    account_oauth.addImport("metawork_account_contract", account_contract);
    const account_loopback = b.createModule(.{
        .root_source_file = b.path("src/product/account/loopback.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    account_loopback.addImport("account_oauth", account_oauth);
    const oauth_loopback_transport = b.createModule(.{
        .root_source_file = b.path("src/app/oauth_loopback_transport.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    oauth_loopback_transport.addImport("account_oauth", account_oauth);
    oauth_loopback_transport.addImport("account_loopback", account_loopback);
    const metask_client = b.createModule(.{
        .root_source_file = b.path("src/product/account/metask_client.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    metask_client.addImport("metawork_account_contract", account_contract);
    metask_client.addImport("account_state", account_state);
    metask_client.addImport("account_oauth", account_oauth);
    const account_login_attempt = b.createModule(.{
        .root_source_file = b.path("src/product/account/login_attempt.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    account_login_attempt.addImport("metawork_account_contract", account_contract);
    account_login_attempt.addImport("account_state", account_state);
    account_login_attempt.addImport("account_oauth", account_oauth);
    account_login_attempt.addImport("account_loopback", account_loopback);
    account_login_attempt.addImport("metask_client", metask_client);
    const account_catalog = b.createModule(.{
        .root_source_file = b.path("src/product/account/catalog.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    account_catalog.addImport("metawork_account_contract", account_contract);
    account_catalog.addImport("metask_client", metask_client);
    const account_credentials_runtime = b.createModule(.{
        .root_source_file = b.path("src/product/account/credentials.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    account_credentials_runtime.addImport("account_state", account_state);
    account_credentials_runtime.addImport("account_oauth", account_oauth);
    account_credentials_runtime.addImport("metawork_account_contract", account_contract);
    account_credentials_runtime.addImport("metask_client", metask_client);
    account_credentials_runtime.addImport("account_catalog", account_catalog);
    const account_model_connections = b.createModule(.{
        .root_source_file = b.path("src/product/account/model_connections.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    account_model_connections.addImport("metawork_account_contract", account_contract);
    const account_network_attempt = b.createModule(.{
        .root_source_file = b.path("src/product/account/network_attempt.zig"),
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
        .root_source_file = b.path("src/product/account/credential_store.zig"),
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
    const account_ports = b.createModule(.{
        .root_source_file = b.path("src/product/account/ports.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    account_ports.addImport("account_oauth", account_oauth);
    account_ports.addImport("account_credential_store", account_credential_store);
    const account_runtime = b.createModule(.{
        .root_source_file = b.path("src/product/account/runtime.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    account_runtime.addImport("metawork_account_contract", account_contract);
    account_runtime.addImport("account_state", account_state);
    account_runtime.addImport("metask_client", metask_client);
    account_runtime.addImport("account_credential_store", account_credential_store);
    account_runtime.addImport("account_ports", account_ports);
    account_runtime.addImport("account_loopback", account_loopback);
    account_runtime.addImport("account_login_attempt", account_login_attempt);
    account_runtime.addImport("account_catalog", account_catalog);
    account_runtime.addImport("account_credentials_runtime", account_credentials_runtime);
    account_runtime.addImport("account_network_attempt", account_network_attempt);
    account_runtime.addImport("account_model_connections", account_model_connections);
    const account = b.createModule(.{
        .root_source_file = b.path("src/product/account.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    account.addImport("account_state", account_state);
    account.addImport("account_oauth", account_oauth);
    account.addImport("metask_client", metask_client);
    account.addImport("account_credential_store", account_credential_store);
    account.addImport("account_ports", account_ports);
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
        .root_source_file = b.path("src/product/skill/package.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    const skill_management = b.createModule(.{
        .root_source_file = b.path("src/product/skill/management.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    skill_management.addImport("product_skill_package", skill_package);
    const skill_enablement = b.createModule(.{
        .root_source_file = b.path("src/product/skill/enablement.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    const task_persistence = b.createModule(.{
        .root_source_file = b.path("src/product/task/persistence.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    const checkpoint_store = b.createModule(.{
        .root_source_file = b.path("src/product/task/checkpoint_store.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    const checkpoint_record = b.createModule(.{
        .root_source_file = b.path("src/product/task/checkpoint_record.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    checkpoint_record.addImport("product_task_checkpoint_store", checkpoint_store);
    const catalog_snapshot = b.createModule(.{
        .root_source_file = b.path("src/product/skill/catalog.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    catalog_snapshot.addImport("metawork_agent", agent);
    const product_skill_state = b.createModule(.{
        .root_source_file = b.path("src/product/skill/state.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    product_skill_state.addImport("metawork_agent", agent);
    product_skill_state.addImport("product_skill_catalog", catalog_snapshot);
    product_skill_state.addImport("product_skill_enablement", skill_enablement);
    product_skill_state.addImport("product_skill_management", skill_management);
    const product_skill_policy = b.createModule(.{
        .root_source_file = b.path("src/product/skill/policy.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    product_skill_policy.addImport("metawork_agent", agent);
    product_skill_policy.addImport("product_skill_catalog", catalog_snapshot);
    product_skill_policy.addImport("product_skill_enablement", skill_enablement);
    product_skill_policy.addImport("product_skill_management", skill_management);
    product_skill_policy.addImport("product_skill_state", product_skill_state);
    const product_skill_management_runtime = b.createModule(.{
        .root_source_file = b.path("src/product/skill/management_runtime.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    product_skill_management_runtime.addImport("product_skill_catalog", catalog_snapshot);
    product_skill_management_runtime.addImport("product_skill_management", skill_management);
    product_skill_management_runtime.addImport("product_skill_package", skill_package);
    product_skill_management_runtime.addImport("product_skill_policy", product_skill_policy);
    product_skill_management_runtime.addImport("product_skill_state", product_skill_state);
    const product_skill_ports = b.createModule(.{
        .root_source_file = b.path("src/product/skill/ports.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    product_skill_ports.addImport("metawork_agent", agent);
    const product_skill_runtime = b.createModule(.{
        .root_source_file = b.path("src/product/skill/runtime.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    product_skill_runtime.addImport("metawork_agent", agent);
    product_skill_runtime.addImport("product_skill_catalog", catalog_snapshot);
    product_skill_runtime.addImport("product_skill_enablement", skill_enablement);
    product_skill_runtime.addImport("product_skill_management", skill_management);
    product_skill_runtime.addImport(
        "product_skill_management_runtime",
        product_skill_management_runtime,
    );
    product_skill_runtime.addImport("product_skill_package", skill_package);
    product_skill_runtime.addImport("product_skill_policy", product_skill_policy);
    product_skill_runtime.addImport("product_skill_ports", product_skill_ports);
    product_skill_runtime.addImport("product_skill_state", product_skill_state);
    const product_skill_view = b.createModule(.{
        .root_source_file = b.path("src/product/skill/view.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    product_skill_view.addImport("product_skill_catalog", catalog_snapshot);
    product_skill_view.addImport("product_skill_management", skill_management);
    product_skill_view.addImport("product_skill_policy", product_skill_policy);
    product_skill_view.addImport("product_skill_state", product_skill_state);
    const product_skill = b.createModule(.{
        .root_source_file = b.path("src/product/skill.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    product_skill.addImport("product_skill_catalog", catalog_snapshot);
    product_skill.addImport("product_skill_enablement", skill_enablement);
    product_skill.addImport("product_skill_management", skill_management);
    product_skill.addImport("product_skill_package", skill_package);
    product_skill.addImport("product_skill_policy", product_skill_policy);
    product_skill.addImport("product_skill_ports", product_skill_ports);
    product_skill.addImport("product_skill_runtime", product_skill_runtime);
    product_skill.addImport("product_skill_state", product_skill_state);
    product_skill.addImport("product_skill_view", product_skill_view);
    const owned_task_execution = b.createModule(.{
        .root_source_file = b.path("src/product/task/execution_binding.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    owned_task_execution.addImport("metawork_account_contract", account_contract);
    const task_agent_session = b.createModule(.{
        .root_source_file = b.path("src/product/task/agent_session.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    task_agent_session.addImport("metawork_agent", agent);
    const task_runtime = b.createModule(.{
        .root_source_file = b.path("src/product/task/runtime.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    task_runtime.addImport("product_task_agent_session", task_agent_session);
    task_runtime.addImport("metawork_product_skill", product_skill);
    task_runtime.addImport("product_task_execution_binding", owned_task_execution);
    const task_deletion = b.createModule(.{
        .root_source_file = b.path("src/product/task/deletion.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    const task_recovery = b.createModule(.{
        .root_source_file = b.path("src/product/task/recovery.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    const task_recovery_job = b.createModule(.{
        .root_source_file = b.path("src/product/task/recovery_job.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    task_recovery_job.addImport("metawork_agent", agent);
    task_recovery_job.addImport("product_task_agent_session", task_agent_session);
    task_recovery_job.addImport("product_task_checkpoint_record", checkpoint_record);
    task_recovery_job.addImport("product_task_checkpoint_store", checkpoint_store);
    task_recovery_job.addImport("metawork_product_skill", product_skill);
    task_recovery_job.addImport("product_task_execution_binding", owned_task_execution);
    task_runtime.addImport("product_task_recovery_job", task_recovery_job);
    const task_state = b.createModule(.{
        .root_source_file = b.path("src/product/task/state.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    task_state.addImport("metawork_agent", agent);
    task_state.addImport("product_task_checkpoint_record", checkpoint_record);
    task_state.addImport("product_task_execution_binding", owned_task_execution);
    task_state.addImport("product_task_runtime", task_runtime);
    task_state.addImport("product_task_deletion", task_deletion);
    task_state.addImport("product_task_recovery", task_recovery);
    task_persistence.addImport("metawork_agent", agent);
    task_persistence.addImport("product_task_checkpoint_record", checkpoint_record);
    task_persistence.addImport("product_task_checkpoint_store", checkpoint_store);
    task_persistence.addImport("product_task_state", task_state);
    const task_policy = b.createModule(.{
        .root_source_file = b.path("src/product/task/policy.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    task_policy.addImport("metawork_agent", agent);
    task_policy.addImport("product_task_state", task_state);
    task_policy.addImport("product_task_runtime", task_runtime);
    task_policy.addImport("product_task_recovery", task_recovery);
    task_policy.addImport("product_task_checkpoint_record", checkpoint_record);
    const task_view = b.createModule(.{
        .root_source_file = b.path("src/product/task/view.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    task_view.addImport("metawork_agent", agent);
    task_view.addImport("metawork_product_skill", product_skill);
    task_view.addImport("product_task_state", task_state);
    task_view.addImport("product_task_policy", task_policy);
    task_view.addImport("product_task_recovery", task_recovery);
    const product_task = b.createModule(.{
        .root_source_file = b.path("src/product/task.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    product_task.addImport("product_task_persistence", task_persistence);
    product_task.addImport("product_task_checkpoint_record", checkpoint_record);
    product_task.addImport("product_task_checkpoint_store", checkpoint_store);
    product_task.addImport("product_task_execution_binding", owned_task_execution);
    product_task.addImport("product_task_agent_session", task_agent_session);
    product_task.addImport("product_task_runtime", task_runtime);
    product_task.addImport("product_task_deletion", task_deletion);
    product_task.addImport("product_task_recovery", task_recovery);
    product_task.addImport("product_task_recovery_job", task_recovery_job);
    product_task.addImport("product_task_state", task_state);
    product_task.addImport("product_task_policy", task_policy);
    product_task.addImport("product_task_view", task_view);
    const mcp_configuration = b.createModule(.{
        .root_source_file = b.path("src/product/mcp/configuration.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    mcp_configuration.addImport("agent_mcp_http_protocol", agent_mcp_http_protocol);
    const product_mcp = b.createModule(.{
        .root_source_file = b.path("src/product/mcp.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    product_mcp.addImport("product_mcp_configuration", mcp_configuration);
    const product_mcp_state = b.createModule(.{
        .root_source_file = b.path("src/product/mcp/state.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    product_mcp_state.addImport("metawork_agent", agent);
    product_mcp_state.addImport("product_mcp_configuration", mcp_configuration);
    product_mcp.addImport("product_mcp_state", product_mcp_state);
    const product_mcp_policy = b.createModule(.{
        .root_source_file = b.path("src/product/mcp/policy.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    product_mcp_policy.addImport("metawork_agent", agent);
    product_mcp_policy.addImport("product_mcp_configuration", mcp_configuration);
    product_mcp_policy.addImport("product_mcp_state", product_mcp_state);
    product_mcp.addImport("product_mcp_policy", product_mcp_policy);
    const product_mcp_view = b.createModule(.{
        .root_source_file = b.path("src/product/mcp/view.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    product_mcp_view.addImport("product_mcp_configuration", mcp_configuration);
    product_mcp_view.addImport("product_mcp_state", product_mcp_state);
    product_mcp.addImport("product_mcp_view", product_mcp_view);
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
    projection.addImport("metawork_product_task", product_task);
    projection.addImport("metawork_product_skill", product_skill);
    projection.addImport("metawork_product_mcp", product_mcp);
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
    workbench.addImport("metawork_product_skill", product_skill);

    const bridge = b.createModule(.{
        .root_source_file = b.path("src/bridge.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    bridge.addImport("native_sdk", existingImport(root_module, "native_sdk"));
    bridge.addImport("metawork_account_contract", account_contract);
    bridge.addImport("metawork_workbench", workbench);
    bridge.addImport("metawork_product_mcp", product_mcp);
    bridge.addImport("metawork_product_skill", product_skill);

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
    mcp_platform.addImport("metawork_product_mcp", product_mcp);
    mcp_platform.addImport("metawork_product_identity", product_identity);
    const mcp_oauth = b.createModule(.{
        .root_source_file = b.path("src/app/mcp_oauth.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    mcp_oauth.addImport("account_oauth", account_oauth);
    mcp_oauth.addImport("account_loopback", account_loopback);
    mcp_oauth.addImport("oauth_loopback_transport", oauth_loopback_transport);
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
    app.addImport("metawork_product_mcp", product_mcp);
    app.addImport("metawork_product_skill", product_skill);
    app.addImport("metawork_product_task", product_task);
    app.addImport("metawork_bridge", bridge);
    app.addImport("metawork_automation", automation);
    app.addImport("metawork_account_contract", account_contract);
    app.addImport("metawork_account", account);
    app.addImport("account_oauth", account_oauth);
    app.addImport("account_loopback", account_loopback);
    app.addImport("oauth_loopback_transport", oauth_loopback_transport);
    app.addImport("account_ports", account_ports);
    app.addImport("account_credential_store", account_credential_store);
    app.addImport("metask_client", metask_client);
    app.addImport("metawork_product_identity", product_identity);
    app.addImport("metawork_mcp_platform", mcp_platform);
    app.addImport("metawork_mcp_oauth", mcp_oauth);

    root_module.addImport("metawork_app", app);
    root_module.link_libc = bundle.link_libc;
    return .{
        .storage = storage,
        .account = account,
        .account_runtime = account_runtime,
        .account_catalog = account_catalog,
        .account_credentials_runtime = account_credentials_runtime,
        .account_model_connections = account_model_connections,
        .account_contract = account_contract,
        .account_credential_store = account_credential_store,
        .account_loopback = account_loopback,
        .oauth_loopback_transport = oauth_loopback_transport,
        .account_login_attempt = account_login_attempt,
        .account_network_attempt = account_network_attempt,
        .account_oauth = account_oauth,
        .account_ports = account_ports,
        .account_state = account_state,
        .metask_client = metask_client,
        .app = app,
        .mcp_platform = mcp_platform,
        .mcp_oauth = mcp_oauth,
        .agent = agent,
        .agent_provider = agent_provider,
        .agent_completion = agent_completion,
        .agent_session = session,
        .agent_catalog = agent_catalog,
        .agent_checkpoint = agent_checkpoint,
        .agent_provider_probe = agent_provider_probe,
        .agent_mcp_connector = agent_mcp_connector,
        .agent_mcp_catalog = agent_mcp_catalog,
        .agent_mcp_http_protocol = agent_mcp_http_protocol,
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
        .product_skill_package = skill_package,
        .product_skill_management = skill_management,
        .product_skill_enablement = skill_enablement,
        .product_skill_state = product_skill_state,
        .product_skill_policy = product_skill_policy,
        .product_skill_runtime = product_skill_runtime,
        .product_skill_view = product_skill_view,
        .product_mcp = product_mcp,
        .product_mcp_configuration = mcp_configuration,
        .product_mcp_state = product_mcp_state,
        .product_mcp_policy = product_mcp_policy,
        .product_mcp_view = product_mcp_view,
        .product_skill = product_skill,
        .product_skill_catalog = catalog_snapshot,
        .product_task = product_task,
        .product_task_persistence = task_persistence,
        .product_task_checkpoint_store = checkpoint_store,
        .product_task_checkpoint_record = checkpoint_record,
        .product_task_execution_binding = owned_task_execution,
        .product_task_agent_session = task_agent_session,
        .product_task_runtime = task_runtime,
        .product_task_deletion = task_deletion,
        .product_task_recovery = task_recovery,
        .product_task_recovery_job = task_recovery_job,
        .product_task_state = task_state,
        .product_task_policy = task_policy,
        .product_task_view = task_view,
    };
}

fn existingImport(module: *std.Build.Module, name: []const u8) *std.Build.Module {
    return module.import_table.get(name) orelse
        std.debug.panic("Native SDK root module does not expose required import '{s}'", .{name});
}
