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
    const module_tests = [_]struct {
        name: []const u8,
        root_module: *std.Build.Module,
    }{
        .{ .name = "metawork-account-contract", .root_module = test_modules.account_contract },
        .{ .name = "metawork-account-oauth", .root_module = test_modules.account_oauth },
        .{ .name = "metawork-metask-client", .root_module = test_modules.metask_client },
        .{ .name = "metawork-account-credential-store", .root_module = test_modules.account_credential_store },
        .{ .name = "metawork-account-windows-store", .root_module = test_modules.account_windows_store },
        .{ .name = "metawork-account-platform", .root_module = test_modules.account_platform },
        .{ .name = "metawork-account-loopback", .root_module = test_modules.account_loopback },
        .{ .name = "metawork-account-login-attempt", .root_module = test_modules.account_login_attempt },
        .{ .name = "metawork-account-catalog", .root_module = test_modules.account_catalog },
        .{ .name = "metawork-account-credentials-runtime", .root_module = test_modules.account_credentials_runtime },
        .{ .name = "metawork-account-network-attempt", .root_module = test_modules.account_network_attempt },
        .{ .name = "metawork-account-state", .root_module = test_modules.account_state },
        .{ .name = "metawork-account", .root_module = test_modules.account },
        .{ .name = "metawork-app", .root_module = test_modules.app },
        .{ .name = "metawork-automation-enabled", .root_module = test_modules.automation_enabled },
        .{ .name = "metawork-bridge", .root_module = test_modules.bridge },
        .{ .name = "metawork-workbench", .root_module = test_modules.workbench_projection },
        .{ .name = "metawork-workbench-executor", .root_module = test_modules.workbench_executor },
        .{ .name = "metawork-managed-workspace-store", .root_module = test_modules.workbench_managed_workspace_store },
        .{ .name = "metawork-scheduled-task-persistence", .root_module = test_modules.workbench_scheduled_persistence },
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
        step.dependOn(&b.addRunArtifact(artifact).step);
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
    account_catalog: *std.Build.Module,
    account_credentials_runtime: *std.Build.Module,
    account_contract: *std.Build.Module,
    account_credential_store: *std.Build.Module,
    account_windows_store: *std.Build.Module,
    account_loopback: *std.Build.Module,
    account_login_attempt: *std.Build.Module,
    account_network_attempt: *std.Build.Module,
    account_oauth: *std.Build.Module,
    account_platform: *std.Build.Module,
    account_state: *std.Build.Module,
    metask_client: *std.Build.Module,
    app: *std.Build.Module,
    agent: *std.Build.Module,
    automation_enabled: *std.Build.Module,
    bridge: *std.Build.Module,
    event_pump: *std.Build.Module,
    sdk: *std.Build.Module,
    workbench: *std.Build.Module,
    workbench_projection: *std.Build.Module,
    workbench_executor: *std.Build.Module,
    workbench_managed_workspace_store: *std.Build.Module,
    workbench_scheduled_persistence: *std.Build.Module,
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
    const session = b.createModule(.{
        .root_source_file = b.path("src/agent/session.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    session.addImport("metask_agentcore", sdk);
    session.addImport("event_pump", event_pump);
    session.addImport("agent_catalog", agent_catalog);
    const agent = b.createModule(.{
        .root_source_file = b.path("src/agent.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    agent.addImport("agent_session", session);
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
    account_credentials_runtime.addImport("metask_client", metask_client);
    account_credentials_runtime.addImport("account_catalog", account_catalog);
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
    account_credential_store.addImport("account_state", account_state);
    account_credential_store.addImport("account_oauth", account_oauth);
    account_credential_store.addImport("metawork_product_identity", product_identity);
    const account_windows_store = b.createModule(.{
        .root_source_file = b.path("src/account/windows_store.zig"),
        .target = root_module.resolved_target,
        .optimize = root_module.optimize,
    });
    account_windows_store.addImport("metawork_account_contract", account_contract);
    account_windows_store.addImport("account_state", account_state);
    account_windows_store.addImport("account_oauth", account_oauth);
    const account_platform = b.createModule(.{
        .root_source_file = b.path("src/account/platform.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    account_platform.addImport("native_sdk", existingImport(root_module, "native_sdk"));
    account_platform.addImport("metawork_account_contract", account_contract);
    account_platform.addImport("account_state", account_state);
    account_platform.addImport("account_oauth", account_oauth);
    account_platform.addImport("account_credential_store", account_credential_store);
    account_platform.addImport("account_windows_store", account_windows_store);
    const account = b.createModule(.{
        .root_source_file = b.path("src/account.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    account.addImport("account_state", account_state);
    account.addImport("account_oauth", account_oauth);
    account.addImport("metask_client", metask_client);
    account.addImport("account_credential_store", account_credential_store);
    account.addImport("account_windows_store", account_windows_store);
    account.addImport("account_platform", account_platform);
    account.addImport("account_loopback", account_loopback);
    account.addImport("account_login_attempt", account_login_attempt);
    account.addImport("account_catalog", account_catalog);
    account.addImport("account_credentials_runtime", account_credentials_runtime);
    account.addImport("account_network_attempt", account_network_attempt);
    const executor = b.createModule(.{
        .root_source_file = b.path("src/workbench/executor.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    const managed_workspace_store = b.createModule(.{
        .root_source_file = b.path("src/workbench/managed_workspace_store.zig"),
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
    const projection = b.createModule(.{
        .root_source_file = b.path("src/workbench/projection.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    projection.addImport("metawork_agent", agent);
    projection.addImport("metawork_account_contract", account_contract);
    projection.addImport("workbench_executor", executor);
    projection.addImport("workbench_managed_workspace_store", managed_workspace_store);
    projection.addImport("workbench_scheduled_tasks", scheduled_tasks);
    projection.addImport(
        "workbench_scheduled_task_persistence",
        scheduled_task_persistence,
    );
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
    workbench.addImport("workbench_managed_workspace_store", managed_workspace_store);
    workbench.addImport(
        "workbench_scheduled_task_persistence",
        scheduled_task_persistence,
    );

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

    const app = b.createModule(.{
        .root_source_file = b.path("src/app.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    app.addImport("runner", runner);
    app.addImport("native_sdk", existingImport(root_module, "native_sdk"));
    app.addImport("metawork_agent", agent);
    app.addImport("metawork_workbench", workbench);
    app.addImport("metawork_bridge", bridge);
    app.addImport("metawork_automation", automation);
    app.addImport("metawork_account_contract", account_contract);
    app.addImport("metawork_account", account);
    app.addImport("metawork_product_identity", product_identity);

    root_module.addImport("metawork_app", app);
    root_module.link_libc = bundle.link_libc;
    return .{
        .account = account,
        .account_catalog = account_catalog,
        .account_credentials_runtime = account_credentials_runtime,
        .account_contract = account_contract,
        .account_credential_store = account_credential_store,
        .account_windows_store = account_windows_store,
        .account_loopback = account_loopback,
        .account_login_attempt = account_login_attempt,
        .account_network_attempt = account_network_attempt,
        .account_oauth = account_oauth,
        .account_platform = account_platform,
        .account_state = account_state,
        .metask_client = metask_client,
        .app = app,
        .agent = agent,
        .automation_enabled = automation_enabled,
        .bridge = bridge,
        .event_pump = event_pump,
        .sdk = sdk,
        .workbench = workbench,
        .workbench_projection = projection,
        .workbench_executor = executor,
        .workbench_managed_workspace_store = managed_workspace_store,
        .workbench_scheduled_persistence = scheduled_task_persistence,
    };
}

fn existingImport(module: *std.Build.Module, name: []const u8) *std.Build.Module {
    return module.import_table.get(name) orelse
        std.debug.panic("Native SDK root module does not expose required import '{s}'", .{name});
}
