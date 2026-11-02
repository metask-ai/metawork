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

const ArtifactOption = enum {
    development,
    release,
    automation,
};

pub fn build(b: *std.Build) void {
    // The SDK follows Zig's GNU host default on Windows. Supply our canonical
    // ABI only when the caller has not selected a target; explicit GNU fails below.
    if (b.graph.host.result.os.tag == .windows and !b.user_input_options.contains("target")) {
        _ = b.addUserInputOption("target", b.fmt("{s}-windows.win10...win11_dt-msvc", .{
            @tagName(b.graph.host.result.cpu.arch),
        })) catch @panic("cannot configure the Windows MSVC target");
    }
    addRendererWireGenerator(b);
    if (b.option([]const u8, "install-prefix", "Independent output directory for this artifact")) |prefix|
        b.resolveInstallPrefix(prefix, .{});
    const artifacts = native_sdk.addAppArtifacts(b, b.dependency("native_sdk", .{}), .{ .name = "metawork" });
    const artifact = selectedArtifact(b);
    const automatic_update_checks = b.option(bool, "automatic-update-check", "Enable periodic official version checks for this distribution artifact") orelse false;
    if (artifact == .automation and automatic_update_checks)
        @panic("automation artifacts must not enable official update checks");
    // Include the ICO in the generated resource path's cache identity.
    const windows_resources = b.addWriteFiles();
    _ = windows_resources.addCopyFile(b.path("assets/icons/app-icon.ico"), "app-icon.ico");
    artifacts.exe.root_module.addWin32ResourceFile(.{
        .file = windows_resources.addCopyFile(b.path("packaging/windows/metawork.rc"), "metawork.rc"),
        .include_paths = &.{b.path("assets/icons")},
    });
    const frontend_dist = b.option([]const u8, "frontend-dist", "Built Renderer assets for this artifact");
    const frontend_assets = b.addInstallDirectory(.{
        .source_dir = if (frontend_dist) |path| .{ .cwd_relative = path } else b.path("frontend/dist"),
        .install_dir = .bin,
        .install_subdir = "frontend/dist",
    });
    b.getInstallStep().dependOn(&frontend_assets.step);
    const app_target = (artifacts.exe.root_module.resolved_target orelse @panic("Native SDK app target is unresolved")).result;
    // codesign adds LC_CODE_SIGNATURE to unsigned x86_64 executables.
    // Reserve space so that the new load command cannot overwrite __text.
    if (app_target.os.tag == .macos and app_target.cpu.arch == .x86_64)
        artifacts.exe.headerpad_size = 0x1000;
    const target_id = agentCoreTargetId(app_target);
    const root = b.pathFromRoot(b.pathJoin(&.{ ".agentcore/bundles", target_id }));
    const bundle = agentcore_bundle.verify(b, root);
    const office_skill_shell_step = b.step("build-office-skill-shell", "Build canonical Core materialized Office Skill qualification");
    for (bundle.runtime_files) |file| {
        const install = b.addInstallBinFile(.{ .cwd_relative = file }, std.fs.path.basename(file));
        b.getInstallStep().dependOn(&install.step);
        office_skill_shell_step.dependOn(&install.step);
    }
    const modules = wireAgentCore(b, artifacts.exe.root_module, bundle, artifact, automatic_update_checks);
    const test_modules = if (artifacts.tests.root_module != artifacts.exe.root_module)
        wireAgentCore(b, artifacts.tests.root_module, bundle, artifact, automatic_update_checks)
    else
        modules;
    const update_tests = b.addTest(.{ .name = "metawork-updates", .root_module = test_modules.product_update });
    const run_update_tests = b.addRunArtifact(update_tests);
    b.step("test-updates", "Run bounded Product update policy tests").dependOn(&run_update_tests.step);
    artifacts.tests.step.dependOn(&run_update_tests.step);
    const office_publish_tests = b.addTest(.{
        .name = "metawork-office-resource-publish",
        .root_module = existingImport(test_modules.app, "metawork_office_resource_publish_compat"),
    });
    artifacts.tests.step.dependOn(&b.addRunArtifact(office_publish_tests).step);
    const office_app_tests = b.addTest(.{
        .name = "metawork-office-resources",
        .root_module = test_modules.app,
        .filters = &.{"full Office resources"},
    });
    const office_resources_step = b.step("test-office-resources", "Verify Office resource publication and complete Skill entries");
    office_resources_step.dependOn(&b.addRunArtifact(office_publish_tests).step);
    office_resources_step.dependOn(&b.addRunArtifact(office_app_tests).step);
    if (test_modules.app.resolved_target.?.result.os.tag == .macos) {
        if (b.sysroot) |sysroot| test_modules.app.addFrameworkPath(.{
            .cwd_relative = b.pathJoin(&.{ sysroot, "System/Library/Frameworks" }),
        });
        test_modules.app.linkFramework("AppKit", .{});
    }
    const lifecycle_fixture = createLifecycleFixture(b, test_modules, bundle.link_libc);
    const office_pipeline_options = b.addOptions();
    office_pipeline_options.addOption([]const u8, "node_path", b.findProgram(&.{"node"}, &.{}) catch @panic("Node.js required for Office pipeline fixture"));
    office_pipeline_options.addOption([]const u8, "fixture_path", b.pathFromRoot("tests/fixtures/office_pipeline.mjs"));
    office_pipeline_options.addOption([]const u8, "office_archive", b.pathFromRoot("src/app/office-skills.tar.gz"));
    const office_pipeline_cases = b.createModule(.{
        .root_source_file = b.path("tests/integration/lifecycle/office_pipeline_test.zig"),
        .target = test_modules.app.resolved_target,
        .optimize = test_modules.app.optimize,
        .link_libc = bundle.link_libc,
    });
    office_pipeline_cases.addImport("lifecycle_fixture", lifecycle_fixture);
    office_pipeline_cases.addOptions("office_pipeline_options", office_pipeline_options);
    const office_pipeline_tests = b.addRunArtifact(b.addTest(.{ .name = "metawork-office-pipeline", .root_module = office_pipeline_cases }));
    b.step("test-office-pipeline", "Run canonical Core and Product Office event pipeline qualification").dependOn(&office_pipeline_tests.step);
    const skill_resource_tests = b.addRunArtifact(b.addTest(.{
        .name = "metawork-skill-resource-context",
        .root_module = office_pipeline_cases,
        .filters = &.{"Skill resource context"},
    }));
    b.step("test-skill-resource-context", "Verify managed Skill resource reads through both canonical Core inputs").dependOn(&skill_resource_tests.step);
    artifacts.tests.step.dependOn(&office_pipeline_tests.step);
    const office_skill_shell = b.addExecutable(.{ .name = "office-skill-shell", .root_module = b.createModule(.{
        .root_source_file = b.path("tests/office_skill_shell.zig"),
        .target = test_modules.app.resolved_target,
        .optimize = test_modules.app.optimize,
        .link_libc = bundle.link_libc,
    }) });
    office_skill_shell.root_module.addImport("lifecycle_fixture", lifecycle_fixture);
    office_skill_shell_step.dependOn(&b.addInstallArtifact(office_skill_shell, .{}).step);

    const image_unit = b.createModule(.{
        .root_source_file = b.path("src/agent/generate_image.zig"),
        .target = test_modules.agent.resolved_target,
        .optimize = test_modules.agent.optimize,
        .link_libc = bundle.link_libc,
    });
    image_unit.addImport("agent_http_transport", test_modules.agent_http_transport);
    image_unit.addImport("image_container", test_modules.image_container);
    const image_tests = b.addTest(.{ .name = "metawork-generate-image-unit", .root_module = image_unit });
    const image_unit_run = b.addRunArtifact(image_tests);
    b.step("test-generate-image-unit", "Run GenerateImage codec and argument tests").dependOn(&image_unit_run.step);
    artifacts.tests.step.dependOn(&image_unit_run.step);
    const image_codec_unit = b.createModule(.{
        .root_source_file = b.path("src/agent/image_generation.zig"),
        .target = test_modules.agent.resolved_target,
        .optimize = test_modules.agent.optimize,
        .link_libc = bundle.link_libc,
    });
    image_codec_unit.addImport("agent_http_transport", test_modules.agent_http_transport);
    image_codec_unit.addImport("image_container", test_modules.image_container);
    artifacts.tests.step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = test_modules.image_container })).step);
    const image_codec_tests = b.addTest(.{ .name = "metawork-image-generation-unit", .root_module = image_codec_unit });
    const image_codec_run = b.addRunArtifact(image_codec_tests);
    b.step("test-image-generation-unit", "Run bounded Images Generation tests").dependOn(&image_codec_run.step);
    artifacts.tests.step.dependOn(&image_codec_run.step);
    test_modules.app.addImport("lifecycle_fixture", lifecycle_fixture);
    test_modules.bridge.addImport("lifecycle_fixture", lifecycle_fixture);
    const sdk_consumption_tests = b.addTest(.{
        .name = "metawork-sdk-consumption",
        .root_module = test_modules.app,
        .filters = &.{"SDK consumption"},
    });
    b.step("test-sdk-consumption", "Run Application Native SDK effect bindings")
        .dependOn(&b.addRunArtifact(sdk_consumption_tests).step);
    const update_host_step = b.step("test-updates-host", "Run update HTTP, lifecycle and Bridge tests");
    update_host_step.dependOn(&run_update_tests.step);
    update_host_step.dependOn(&b.addRunArtifact(b.addTest(.{ .name = "metawork-updates-control", .root_module = test_modules.product_control_runtime, .filters = &.{ "updates", "snapshot serializer matches", "Automatic Workspace snapshot exposes" } })).step);
    update_host_step.dependOn(&b.addRunArtifact(b.addTest(.{ .name = "metawork-updates-host", .root_module = test_modules.app, .filters = &.{"updates"} })).step);
    update_host_step.dependOn(&b.addRunArtifact(b.addTest(.{ .name = "metawork-updates-bridge", .root_module = test_modules.bridge, .filters = &.{ "updates", "Dispatcher validates authority" } })).step);
    const window_chrome_tests = b.addTest(.{
        .name = "metawork-window-chrome",
        .root_module = test_modules.app,
        .filters = &.{ "window", "Window", "titlebar", "resize", "disconnect", "refresh" },
    });
    const window_chrome_step = b.step("test-window-chrome", "Run Application window-chrome, compatibility and Bridge tests");
    window_chrome_step.dependOn(&b.addRunArtifact(window_chrome_tests).step);
    const window_chrome_bridge_tests = b.addTest(.{
        .name = "metawork-window-chrome-bridge",
        .root_module = test_modules.bridge,
        .filters = &.{ "window chrome", "Dispatcher validates authority", "external link validation" },
    });
    window_chrome_step.dependOn(&b.addRunArtifact(window_chrome_bridge_tests).step);
    addLifecycleTests(
        b,
        test_modules,
        lifecycle_fixture,
        bundle.link_libc,
        &artifacts.tests.step,
    );
    const multimodal_probe = b.addExecutable(.{
        .name = "metawork-agent-multimodal-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("scripts/probes/agent-multimodal-test.zig"),
            .target = test_modules.agent.resolved_target,
            .optimize = test_modules.agent.optimize,
            .link_libc = bundle.link_libc,
        }),
    });
    multimodal_probe.root_module.addImport("metawork_agent", test_modules.agent);
    const multimodal_run = b.addRunArtifact(multimodal_probe);
    if (b.args) |args| multimodal_run.addArgs(args);
    b.step("test-agent-multimodal", "Run Agent multimodal acceptance against the provider fixture")
        .dependOn(&multimodal_run.step);
    addMcpConnectorTests(b, test_modules, bundle.link_libc);
    addMcpStdioTests(b, test_modules, bundle.link_libc);
    addMcpHttpTests(b, test_modules, bundle.link_libc);
    addMcpRuntimeTests(b, test_modules, bundle.link_libc);
    addMcpCatalogTests(b, test_modules, bundle.link_libc);
    addMcpConfigurationTests(b, test_modules, bundle.link_libc);
    addProductMcpStateTests(b, test_modules, bundle.link_libc);
    addProductMcpPolicyTests(b, test_modules, bundle.link_libc);
    addProductMcpViewTests(b, test_modules, bundle.link_libc);
    addProductMcpRefreshJobTests(b, test_modules, bundle.link_libc);
    addProductMcpRuntimeTests(b, test_modules, bundle.link_libc);
    addMcpPlatformTests(b, test_modules, bundle.link_libc);
    addMcpOauthTests(b, test_modules, bundle.link_libc);
    addMcpAppTests(b, test_modules, bundle.link_libc);
    addProductControlMcpTests(b, test_modules, bundle.link_libc);
    artifacts.tests.step.dependOn(addMcpInteropTests(
        b,
        test_modules,
        bundle.link_libc,
    ));
    artifacts.tests.step.dependOn(addImageGenerationTests(b, test_modules, bundle.link_libc));
    const module_tests = [_]struct {
        name: []const u8,
        root_module: *std.Build.Module,
    }{
        .{ .name = "metawork-oauth-mechanics", .root_module = test_modules.oauth_mechanics },
        .{ .name = "metawork-oauth-loopback", .root_module = test_modules.oauth_loopback },
        .{ .name = "metawork-product-models-contract", .root_module = test_modules.models_contract },
        .{ .name = "metawork-product-agent-protocol-adapter", .root_module = test_modules.product_agent_protocol_adapter },
        .{ .name = "metawork-account-contract", .root_module = test_modules.account_contract },
        .{ .name = "metawork-account-summary", .root_module = test_modules.account_summary },
        .{ .name = "metawork-account-oauth", .root_module = test_modules.account_oauth },
        .{ .name = "metawork-metask-client", .root_module = test_modules.metask_client },
        .{ .name = "metawork-account-credential-store", .root_module = test_modules.account_credential_store },
        .{ .name = "metawork-product-models-providers", .root_module = test_modules.models_providers },
        .{ .name = "metawork-product-models-ports", .root_module = test_modules.models_ports },
        .{ .name = "metawork-product-models-runtime", .root_module = test_modules.models_runtime },
        .{ .name = "metawork-product-models", .root_module = test_modules.models },
        .{ .name = "metawork-account-ports", .root_module = test_modules.account_ports },
        .{ .name = "metawork-account-loopback", .root_module = test_modules.account_loopback },
        .{ .name = "metawork-oauth-loopback-transport", .root_module = test_modules.oauth_loopback_transport },
        .{ .name = "metawork-select-start", .root_module = existingImport(test_modules.oauth_loopback_transport, "app_select_start") },
        .{ .name = "metawork-account-login-attempt", .root_module = test_modules.account_login_attempt },
        .{ .name = "metawork-product-models-metask", .root_module = test_modules.models_metask },
        .{ .name = "metawork-account-credentials-runtime", .root_module = test_modules.account_credentials_runtime },
        .{ .name = "metawork-account-network-attempt", .root_module = test_modules.account_network_attempt },
        .{ .name = "metawork-account-state", .root_module = test_modules.account_state },
        .{ .name = "metawork-account-runtime", .root_module = test_modules.account_runtime },
        .{ .name = "metawork-account", .root_module = test_modules.account },
        .{ .name = "metawork-app", .root_module = test_modules.app },
        .{ .name = "metawork-app-models-coordinator", .root_module = test_modules.models_coordinator },
        .{ .name = "metawork-automation-enabled", .root_module = test_modules.automation_enabled },
        .{ .name = "metawork-bridge", .root_module = test_modules.bridge },
        .{ .name = "metawork-agent-mcp-connector", .root_module = test_modules.agent_mcp_connector },
        .{ .name = "metawork-agent-model-binding", .root_module = test_modules.agent_model_binding },
        .{ .name = "metawork-agent-completion", .root_module = test_modules.agent_completion },
        .{ .name = "metawork-product-permission-review", .root_module = test_modules.product_permission_review },
        .{ .name = "metawork-agent-provider-probe", .root_module = test_modules.agent_provider_probe },
        .{ .name = "metawork-agent-mcp-catalog", .root_module = test_modules.agent_mcp_catalog },
        .{ .name = "metawork-agent-mcp-http", .root_module = test_modules.agent_mcp_http },
        .{ .name = "metawork-agent-mcp-runtime", .root_module = test_modules.agent_mcp_runtime },
        .{ .name = "metawork-agent-mcp-stdio", .root_module = test_modules.agent_mcp_stdio },
        .{ .name = "metawork-agent-checkpoint-restore", .root_module = test_modules.agent_checkpoint_restore },
        .{ .name = "metawork-agent-catalog", .root_module = test_modules.agent_catalog },
        .{ .name = "metawork-agent-checkpoint", .root_module = test_modules.agent_checkpoint },
        .{ .name = "metawork-agent-session", .root_module = test_modules.agent_session },
        .{ .name = "metawork-agent-file-delivery", .root_module = test_modules.agent_file_delivery },
        .{ .name = "metawork-product-attachment", .root_module = test_modules.product_attachment },
        .{ .name = "metawork-product-control", .root_module = test_modules.product_control_runtime },
        .{ .name = "metawork-product-control-executor", .root_module = test_modules.product_control_executor },
        .{ .name = "metawork-product-control-file-preview", .root_module = test_modules.product_control_file_preview },
        .{ .name = "metawork-product-control-attachment-staging", .root_module = test_modules.product_control_attachment_staging },
        .{ .name = "metawork-product-control-file-change-io", .root_module = test_modules.product_control_file_change_io },
        .{ .name = "metawork-product-workspace-automatic-root", .root_module = test_modules.product_workspace_automatic_root },
        .{ .name = "metawork-product-workspace-configuration", .root_module = test_modules.product_workspace_configuration },
        .{ .name = "metawork-product-workspace", .root_module = test_modules.product_workspace_runtime },
        .{ .name = "metawork-app-image-output", .root_module = test_modules.image_output },
        .{ .name = "metawork-app-output-file", .root_module = test_modules.output_file },
        .{ .name = "metawork-product-workspace-view", .root_module = test_modules.product_workspace_view },
        .{ .name = "metawork-product-schedule", .root_module = test_modules.product_schedule },
        .{ .name = "metawork-product-schedule-state", .root_module = test_modules.product_schedule_state },
        .{ .name = "metawork-product-schedule-persistence", .root_module = test_modules.product_schedule_persistence },
        .{ .name = "metawork-product-schedule-view", .root_module = test_modules.product_schedule_view },
        .{ .name = "metawork-product-schedule-runtime", .root_module = test_modules.product_schedule_runtime },
        .{ .name = "metawork-product-skill-package", .root_module = test_modules.product_skill_package },
        .{ .name = "metawork-product-skill-management", .root_module = test_modules.product_skill_management },
        .{ .name = "metawork-product-skill-enablement", .root_module = test_modules.product_skill_enablement },
        .{ .name = "metawork-product-skill-sources", .root_module = test_modules.product_skill_sources },
        .{ .name = "metawork-product-skill-state", .root_module = test_modules.product_skill_state },
        .{ .name = "metawork-product-skill-policy", .root_module = test_modules.product_skill_policy },
        .{ .name = "metawork-product-skill-runtime", .root_module = test_modules.product_skill_runtime },
        .{ .name = "metawork-product-skill-view", .root_module = test_modules.product_skill_view },
        .{ .name = "metawork-product-mcp-configuration", .root_module = test_modules.product_mcp_configuration },
        .{ .name = "metawork-product-mcp-state", .root_module = test_modules.product_mcp_state },
        .{ .name = "metawork-product-mcp-policy", .root_module = test_modules.product_mcp_policy },
        .{ .name = "metawork-product-mcp-view", .root_module = test_modules.product_mcp_view },
        .{ .name = "metawork-product-mcp-refresh-job", .root_module = test_modules.product_mcp_refresh_job },
        .{ .name = "metawork-product-mcp-runtime", .root_module = test_modules.product_mcp_runtime },
        .{ .name = "metawork-mcp-platform", .root_module = test_modules.mcp_platform },
        .{ .name = "metawork-mcp-oauth", .root_module = test_modules.mcp_oauth },
        .{ .name = "metawork-product-task-persistence", .root_module = test_modules.product_task_persistence },
        .{ .name = "metawork-product-task-checkpoint-store", .root_module = test_modules.product_task_checkpoint_store },
        .{ .name = "metawork-product-task-file-change-store", .root_module = test_modules.product_task_file_change_store },
        .{ .name = "metawork-product-task-checkpoint-record", .root_module = test_modules.product_task_checkpoint_record },
        .{ .name = "metawork-product-task-worker-lease", .root_module = test_modules.product_task_worker_lease },
        .{ .name = "metawork-product-task-agent-session", .root_module = test_modules.product_task_agent_session },
        .{ .name = "metawork-product-task-attachment", .root_module = test_modules.product_task_attachment },
        .{ .name = "metawork-product-skill-catalog", .root_module = test_modules.product_skill_catalog },
        .{ .name = "metawork-product-task-runtime", .root_module = test_modules.product_task_runtime },
        .{ .name = "metawork-product-task-deletion", .root_module = test_modules.product_task_deletion },
        .{ .name = "metawork-product-task-recovery", .root_module = test_modules.product_task_recovery },
        .{ .name = "metawork-product-task-recovery-job", .root_module = test_modules.product_task_recovery_job },
        .{ .name = "metawork-product-task-approval-job", .root_module = test_modules.product_task_approval_job },
        .{ .name = "metawork-product-task-state", .root_module = test_modules.product_task_state },
        .{ .name = "metawork-product-task-policy", .root_module = test_modules.product_task_policy },
        .{ .name = "metawork-product-task-execution", .root_module = test_modules.product_task_execution },
        .{ .name = "metawork-product-task-view", .root_module = test_modules.product_task_view },
    };
    for (module_tests) |spec| {
        spec.root_module.link_libc = bundle.link_libc;
        const tests = b.addTest(.{ .name = spec.name, .root_module = spec.root_module });
        artifacts.tests.step.dependOn(&b.addRunArtifact(tests).step);
        if (spec.root_module == test_modules.product_skill_runtime)
            b.step("test-product-skill-runtime", "Run Product Skill runtime tests").dependOn(&b.addRunArtifact(tests).step);
        if (spec.root_module == test_modules.product_skill_policy)
            b.step("test-product-skill-policy", "Run Product Skill authority policy tests").dependOn(&b.addRunArtifact(tests).step);
        if (spec.root_module == test_modules.product_task_persistence)
            b.step("test-product-task-persistence", "Run Product Task history codec and restore tests").dependOn(&b.addRunArtifact(tests).step);
        if (spec.root_module == test_modules.product_task_runtime)
            b.step("test-product-task-runtime", "Run Product Task runtime kernel tests").dependOn(&b.addRunArtifact(tests).step);
        if (spec.root_module == test_modules.product_task_execution)
            b.step("test-product-task-execution", "Run Product Task executor and terminal publication tests").dependOn(&b.addRunArtifact(tests).step);
        if (spec.root_module == test_modules.product_control_runtime)
            b.step("test-product-control", "Run the complete Product Control test root").dependOn(&b.addRunArtifact(tests).step);
        if (spec.root_module == test_modules.image_output)
            b.step("test-image-output", "Run Workspace image output tests").dependOn(&b.addRunArtifact(tests).step);
        if (spec.root_module == test_modules.oauth_loopback_transport)
            b.step("test-oauth-loopback-transport", "Run real OAuth callback concurrency and cancellation tests").dependOn(&b.addRunArtifact(tests).step);
        if (spec.root_module == existingImport(test_modules.oauth_loopback_transport, "app_select_start"))
            b.step("test-select-start", "Run partial Select registration cleanup tests").dependOn(&b.addRunArtifact(tests).step);
    }
    const projection_performance_module = b.createModule(.{
        .root_source_file = b.path("tests/product/projection_performance_test.zig"),
        .target = modules.product_control.resolved_target.?,
        .optimize = modules.product_control.optimize.?,
    });
    projection_performance_module.addImport("metawork_product_control", modules.product_control);
    projection_performance_module.addImport("metawork_bridge", modules.bridge);
    projection_performance_module.link_libc = bundle.link_libc;
    const projection_performance_tests = b.addTest(.{
        .root_module = projection_performance_module,
        .filters = &.{"Product projection legal maximum performance"},
    });
    // Compile the acceptance surface in the normal graph; measure it separately
    // so unrelated parallel suites cannot distort the latency samples.
    artifacts.tests.step.dependOn(&projection_performance_tests.step);
    b.step("test-projection-performance", "Measure legal maximum scoped Product presentation budgets").dependOn(&b.addRunArtifact(projection_performance_tests).step);
    const skill_import_measurement_module = b.createModule(.{
        .root_source_file = b.path("tests/product/skill_import_performance_test.zig"),
        .target = modules.product_control.resolved_target.?,
        .optimize = modules.product_control.optimize.?,
    });
    skill_import_measurement_module.addImport("metawork_product_control", modules.product_control);
    skill_import_measurement_module.addImport("product_skill_management", modules.product_skill_management);
    skill_import_measurement_module.addImport("product_skill_package", modules.product_skill_package);
    skill_import_measurement_module.link_libc = bundle.link_libc;
    const skill_import_measurement_tests = b.addTest(.{ .root_module = skill_import_measurement_module, .filters = &.{"Skill file lifecycle isolated measurements"} });
    artifacts.tests.step.dependOn(&skill_import_measurement_tests.step);
    b.step("test-skill-import-performance", "Measure Skill file lifecycle apart from presentation and Run execution").dependOn(&b.addRunArtifact(skill_import_measurement_tests).step);
    const attachments_step = b.step("test-attachments", "Run attachment resources, staging and Bridge admission tests");
    for ([_]*std.Build.Module{ test_modules.product_attachment, test_modules.product_control_attachment_staging }) |module|
        attachments_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = module })).step);
    for ([_]*std.Build.Module{ test_modules.bridge, test_modules.product_control_runtime }) |module|
        attachments_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = module, .filters = &.{ "attachment", "Attachment", "unified add", "add debt" } })).step);
    const product_views_step = b.step("test-product-views", "Run scoped Product view and strict Bridge request tests");
    const file_preview_step = b.step("test-file-preview", "Run image container, preview lane and Product resource tests");
    file_preview_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = test_modules.image_container })).step);
    file_preview_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = test_modules.bridge, .filters = &.{"file preview"} })).step);
    file_preview_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = test_modules.product_control_file_preview })).step);
    file_preview_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = test_modules.product_control_runtime, .filters = &.{ "file preview", "File Preview" } })).step);
    for ([_]*std.Build.Module{ test_modules.bridge, test_modules.product_task_runtime, test_modules.product_control_runtime }) |module| {
        product_views_step.dependOn(&b.addRunArtifact(b.addTest(.{
            .root_module = module,
            .filters = &.{ "Product view", "Product Control snapshot serializer matches" },
        })).step);
    }
    const image_preparation_step = b.step("test-image-run-preparation", "Run image authorization, ownership and projection tests");
    for ([_]*std.Build.Module{ test_modules.models_coordinator, test_modules.product_task_runtime, test_modules.product_task_execution }) |module| {
        image_preparation_step.dependOn(&b.addRunArtifact(b.addTest(.{
            .root_module = module,
            .filters = &.{"image Run"},
        })).step);
    }
    const model_metadata_step = b.step("test-model-metadata", "Run Models declarations, resolution and Host/Renderer contract tests");
    for ([_]*std.Build.Module{ test_modules.models_contract, test_modules.models_metask, test_modules.models_providers, test_modules.models_runtime }) |module| {
        model_metadata_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = module })).step);
    }
    model_metadata_step.dependOn(&b.addRunArtifact(b.addTest(.{
        .root_module = test_modules.product_control_runtime,
        .filters = &.{ "complete model metadata", "snapshot serializer", "Automatic Workspace snapshot" },
    })).step);
    model_metadata_step.dependOn(&b.addRunArtifact(b.addTest(.{
        .root_module = test_modules.bridge,
        .filters = &.{ "complete model metadata", "Dispatcher validates authority" },
    })).step);
    const task_model_step = b.step("test-task-model-selection", "Run Task model intent, selection and strict Bridge tests");
    task_model_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = test_modules.product_task_persistence })).step);
    task_model_step.dependOn(&b.addRunArtifact(b.addTest(.{
        .root_module = test_modules.product_task_runtime,
        .filters = &.{ "Task model", "pending model rebind" },
    })).step);
    task_model_step.dependOn(&b.addRunArtifact(b.addTest(.{
        .root_module = test_modules.product_control_runtime,
        .filters = &.{ "Task model", "default replacement preserves", "same-source default model", "snapshot serializer" },
    })).step);
    task_model_step.dependOn(&b.addRunArtifact(b.addTest(.{
        .root_module = test_modules.bridge,
        .filters = &.{ "Task model", "Dispatcher validates authority", "mutation response encoders" },
    })).step);
    const permission_review_tests = b.addTest(.{
        .name = "metawork-product-permission-review-focused",
        .root_module = test_modules.product_permission_review,
    });
    b.step("test-completion", "Run Completion codecs and typed failure regressions")
        .dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = test_modules.agent_completion })).step);
    b.step("test-app-paths", "Verify Application canonical path allocation and artifact isolation")
        .dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = test_modules.app, .filters = &.{ "Application canonical paths test roots", "canonical user home", "product and automation data roots" } })).step);
    b.step("test-permission-review", "Run the independent permission reviewer tests")
        .dependOn(&b.addRunArtifact(permission_review_tests).step);
    const review_http_backend = b.createModule(.{ .root_source_file = b.path("src/app/completion_http_transport.zig"), .target = modules.agent.resolved_target, .optimize = modules.agent.optimize });
    review_http_backend.addImport("metawork_agent", modules.agent);
    review_http_backend.addImport("app_select_start", existingImport(modules.oauth_loopback_transport, "app_select_start"));
    const completion_http_tests = b.addRunArtifact(b.addTest(.{ .root_module = review_http_backend }));
    b.step("test-completion-http-transport", "Run Completion HTTP registration and cancellation tests").dependOn(&completion_http_tests.step);
    artifacts.tests.step.dependOn(&completion_http_tests.step);
    const review_http_options = b.addOptions();
    review_http_options.addOption([]const u8, "node_path", b.findProgram(&.{"node"}, &.{}) catch @panic("Node.js required for review HTTP fixture"));
    review_http_options.addOption([]const u8, "fixture_path", b.pathFromRoot("tests/fixtures/permission_review_http.mjs"));
    const review_http_cases = b.createModule(.{ .root_source_file = b.path("tests/permission_review_http.zig"), .target = modules.agent.resolved_target, .optimize = modules.agent.optimize, .link_libc = bundle.link_libc });
    review_http_cases.addImport("metawork_agent", modules.agent);
    review_http_cases.addImport("permission_review", modules.product_permission_review);
    review_http_cases.addImport("completion_http_backend", review_http_backend);
    review_http_cases.addOptions("review_http_fixture_options", review_http_options);
    const review_http_run = b.addRunArtifact(b.addTest(.{ .root_module = review_http_cases }));
    b.step("test-permission-review-http", "Verify real HTTP permission review cancellation and response isolation").dependOn(&review_http_run.step);
    artifacts.tests.step.dependOn(&review_http_run.step);
    const review_eval_module = b.createModule(.{
        .root_source_file = b.path("tests/permission_review_eval.zig"),
        .target = modules.agent.resolved_target,
        .optimize = modules.agent.optimize,
        .link_libc = bundle.link_libc,
    });
    review_eval_module.addImport("metawork_agent", modules.agent);
    review_eval_module.addImport("permission_review", modules.product_permission_review);
    const review_network_trace = b.createModule(.{ .root_source_file = b.path("tests/permission_review_network_trace.zig"), .target = modules.agent.resolved_target, .optimize = modules.agent.optimize });
    review_network_trace.addImport("metawork_agent", modules.agent);
    review_eval_module.addImport("permission_review_network_trace", review_network_trace);
    review_http_cases.addImport("permission_review_network_trace", review_network_trace);
    review_http_cases.addImport("permission_review_evaluation", review_eval_module);
    const review_eval_main = b.createModule(.{ .root_source_file = b.path("tests/permission_review_eval_main.zig"), .target = modules.agent.resolved_target, .optimize = modules.agent.optimize, .link_libc = bundle.link_libc });
    review_eval_main.addImport("metawork_agent", modules.agent);
    review_eval_main.addImport("completion_http_backend", review_http_backend);
    review_eval_main.addImport("permission_review_evaluation", review_eval_module);
    review_eval_main.addImport("permission_review_network_trace", review_network_trace);
    modules.app.addImport("permission_review_evaluation", review_eval_module);
    modules.app.addImport("permission_review_network_trace", review_network_trace);
    const schema_probe = b.createModule(.{ .root_source_file = b.path("tests/permission_schema_probe.zig"), .target = modules.agent.resolved_target, .optimize = modules.agent.optimize, .link_libc = bundle.link_libc });
    schema_probe.addImport("metawork_agent", modules.agent);
    schema_probe.addImport("permission_review", modules.product_permission_review);
    modules.app.addImport("permission_schema_probe", schema_probe);
    b.step("test-permission-schema-probe", "Verify the Account-only format capability probe")
        .dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = schema_probe })).step);
    const review_eval_test_step = b.step("test-permission-review-evaluation", "Verify the live evaluation's safe observations and failure stop");
    review_eval_test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = review_eval_module })).step);
    const account_review_eval = b.option(bool, "permission-review-account-eval", "Build an opt-in Account-owned live permission evaluation instead of the desktop entry") orelse false;
    if (account_review_eval) {
        if (artifact != .development) @panic("Account evaluation requires the development credential owner; automation credentials remain isolated");
        artifacts.exe.root_module.root_source_file = b.path("tests/permission_review_account_main.zig");
    }
    const review_eval = b.addExecutable(.{ .name = "permission-review-eval", .root_module = review_eval_main });
    const review_eval_failure_check = b.addSystemCommand(&.{ b.findProgram(&.{"node"}, &.{}) catch @panic("Node.js required for evaluation regression"), b.pathFromRoot("tests/permission_review_eval_failfast.mjs") });
    review_eval_failure_check.addArtifactArg(review_eval);
    review_eval_test_step.dependOn(&review_eval_failure_check.step);
    artifacts.tests.step.dependOn(&review_eval_failure_check.step);
    b.step("check-permission-review-eval", "Compile the opt-in live-model permission evaluation")
        .dependOn(&review_eval.step);
    b.step("eval-permission-review", "Run opt-in live-model permission evaluation (requires explicit test credentials)")
        .dependOn(&b.addRunArtifact(review_eval).step);
    const task_permission_step = b.step("test-task-permission", "Run Task permission state, history and approval tests");
    for ([_]*std.Build.Module{
        test_modules.product_task_attachment,
        test_modules.product_task_approval_job,
        test_modules.product_task_state,
        test_modules.product_task_persistence,
        test_modules.product_task_runtime,
    }) |module| {
        const tests = b.addTest(.{ .root_module = module });
        task_permission_step.dependOn(&b.addRunArtifact(tests).step);
    }
    const account_test_step = b.step(
        "test-account",
        "Run Account owner and Application coordinator tests",
    );
    const account_focused_modules = [_]struct {
        name: []const u8,
        root_module: *std.Build.Module,
    }{
        .{ .name = "metawork-account-contract-focused", .root_module = test_modules.account_contract },
        .{ .name = "metawork-account-summary-focused", .root_module = test_modules.account_summary },
        .{ .name = "metawork-account-oauth-focused", .root_module = test_modules.account_oauth },
        .{ .name = "metawork-metask-client-focused", .root_module = test_modules.metask_client },
        .{ .name = "metawork-account-credential-store-focused", .root_module = test_modules.account_credential_store },
        .{ .name = "metawork-account-ports-focused", .root_module = test_modules.account_ports },
        .{ .name = "metawork-account-loopback-focused", .root_module = test_modules.account_loopback },
        .{ .name = "metawork-account-login-attempt-focused", .root_module = test_modules.account_login_attempt },
        .{ .name = "metawork-account-credentials-runtime-focused", .root_module = test_modules.account_credentials_runtime },
        .{ .name = "metawork-account-network-attempt-focused", .root_module = test_modules.account_network_attempt },
        .{ .name = "metawork-account-state-focused", .root_module = test_modules.account_state },
        .{ .name = "metawork-account-runtime-focused", .root_module = test_modules.account_runtime },
        .{ .name = "metawork-account-focused", .root_module = test_modules.account },
    };
    for (account_focused_modules) |spec| {
        const tests = b.addTest(.{
            .name = spec.name,
            .root_module = spec.root_module,
        });
        account_test_step.dependOn(&b.addRunArtifact(tests).step);
    }
    const account_coordinator_tests = b.addTest(.{
        .name = "metawork-account-coordinator-focused",
        .root_module = test_modules.app,
        .filters = &.{"Account"},
    });
    account_test_step.dependOn(&b.addRunArtifact(account_coordinator_tests).step);
    const account_bridge_tests = b.addTest(.{
        .name = "metawork-account-bridge-focused",
        .root_module = test_modules.bridge,
        .filters = &.{
            "Account command response encoding",
            "Dispatcher validates authority",
        },
    });
    account_test_step.dependOn(&b.addRunArtifact(account_bridge_tests).step);
    const app_history_tests = b.addTest(.{ .name = "metawork-app-history", .root_module = test_modules.app, .filters = &.{"SQLite history"} });
    b.step("test-app-history", "Verify Application SQLite history lifecycle").dependOn(&b.addRunArtifact(app_history_tests).step);
    const storage_tests = b.addTest(.{
        .name = "metawork-storage",
        .root_module = test_modules.storage,
    });
    const storage_crash_fixture_module = b.createModule(.{
        .root_source_file = b.path("tests/support/storage_crash_fixture.zig"),
        .target = test_modules.storage.resolved_target,
        .optimize = test_modules.storage.optimize,
    });
    storage_crash_fixture_module.addImport("storage", test_modules.storage);
    storage_crash_fixture_module.link_libc = bundle.link_libc;
    const storage_crash_fixture = b.addExecutable(.{
        .name = "metawork-storage-crash-fixture",
        .root_module = storage_crash_fixture_module,
    });
    const install_storage_crash_fixture = b.addInstallArtifact(
        storage_crash_fixture,
        .{},
    );
    const storage_tests_run = b.addRunArtifact(storage_tests);
    storage_tests_run.step.dependOn(&install_storage_crash_fixture.step);
    const storage_crash_fixture_name = if (test_modules.storage.resolved_target.?.result.os.tag == .windows) "metawork-storage-crash-fixture.exe" else "metawork-storage-crash-fixture";
    storage_tests_run.setEnvironmentVariable(
        "METAWORK_STORAGE_CRASH_FIXTURE",
        b.getInstallPath(.bin, storage_crash_fixture_name),
    );
    artifacts.tests.step.dependOn(&storage_tests_run.step);
    b.step(
        "test-storage",
        "Run the backend-independent Storage contract and SQLite backend tests",
    ).dependOn(&storage_tests_run.step);
    // Isolated, opt-in Stage A probes. Not part of the app or the default test graph.
    const sqlite_a_module = b.createModule(.{
        .root_source_file = b.path("tests/probes/sqlite_history_a_memory.zig"),
        .target = test_modules.storage.resolved_target,
        .optimize = test_modules.storage.optimize,
        .link_libc = true,
    });
    sqlite_a_module.addImport("product_task_persistence", test_modules.product_task_persistence);
    sqlite_a_module.addImport("product_task_runtime", test_modules.product_task_runtime);
    sqlite_a_module.addImport("product_task_state", test_modules.product_task_state);
    sqlite_a_module.addImport("storage", test_modules.storage);
    const sqlite_a_memory = b.addTest(.{ .name = "sqlite-history-a-memory", .root_module = sqlite_a_module, .filters = &.{"stage A"} });
    const sqlite_a_sql_module = b.createModule(.{
        .root_source_file = b.path("tests/probes/sqlite_history_a_backend.zig"),
        .target = test_modules.storage.resolved_target,
        .optimize = test_modules.storage.optimize,
        .link_libc = true,
    });
    sqlite_a_sql_module.addImport("storage", test_modules.storage);
    const sqlite_a_backend = b.addTest(.{ .name = "sqlite-history-a-backend", .root_module = sqlite_a_sql_module, .filters = &.{"stage A"} });
    const sqlite_a_step = b.step("build-sqlite-history-a-probes", "Build isolated SQLite stage A memory and existing-backend measurements");
    sqlite_a_step.dependOn(&b.addInstallArtifact(sqlite_a_memory, .{}).step);
    sqlite_a_step.dependOn(&b.addInstallArtifact(sqlite_a_backend, .{}).step);
    const sqlite_a_primitives_module = b.createModule(.{
        .root_source_file = b.path("tests/probes/sqlite_history_a_primitives.zig"),
        .target = test_modules.storage.resolved_target,
        .optimize = test_modules.storage.optimize,
        .link_libc = true,
    });
    sqlite_a_primitives_module.addImport("storage", test_modules.storage);
    sqlite_a_primitives_module.addIncludePath(b.dependency("sqlite", .{}).path("."));
    sqlite_a_primitives_module.addCSourceFile(.{ .file = b.path("tests/probes/sqlite_history_a_primitives.c"), .flags = &.{"-std=c11"} });
    const sqlite_a_primitives = b.addTest(.{ .name = "sqlite-history-a-primitives", .root_module = sqlite_a_primitives_module, .filters = &.{"stage A"} });
    sqlite_a_step.dependOn(&b.addInstallArtifact(sqlite_a_primitives, .{}).step);
    for ([_]bool{ false, true }) |engine| {
        const sqlite_a_size_options = b.addOptions();
        sqlite_a_size_options.addOption(bool, "engine", engine);
        const sqlite_a_size_module = b.createModule(.{
            .root_source_file = b.path("tests/probes/sqlite_history_a_size.zig"),
            .target = test_modules.storage.resolved_target,
            .optimize = test_modules.storage.optimize,
            .link_libc = true,
        });
        sqlite_a_size_module.addOptions("stage_a_size_options", sqlite_a_size_options);
        if (engine) sqlite_a_size_module.addImport("storage", test_modules.storage);
        const sqlite_a_size = b.addExecutable(.{ .name = if (engine) "sqlite-history-a-size-engine" else "sqlite-history-a-size-base", .root_module = sqlite_a_size_module });
        sqlite_a_step.dependOn(&b.addInstallArtifact(sqlite_a_size, .{}).step);
    }
    const history_schema_fixture_module = b.createModule(.{
        .root_source_file = b.path("tests/support/history_schema.zig"),
        .target = test_modules.storage.resolved_target,
        .optimize = test_modules.storage.optimize,
    });
    history_schema_fixture_module.addImport("metawork_storage_sql", test_modules.storage_sql);
    history_schema_fixture_module.addImport("product_task_persistence", test_modules.product_task_persistence);
    const history_schema_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/product/history_schema_test.zig"),
        .target = test_modules.storage.resolved_target,
        .optimize = test_modules.storage.optimize,
    });
    history_schema_tests_module.addImport("product_control_history_schema", test_modules.product_control_history_schema);
    history_schema_tests_module.addImport("metawork_storage_sql", test_modules.storage_sql);
    history_schema_tests_module.addImport("storage", test_modules.storage);
    history_schema_tests_module.addImport("history_schema_fixture", history_schema_fixture_module);
    const history_schema_tests = b.addTest(.{
        .name = "metawork-product-history-schema",
        .root_module = history_schema_tests_module,
    });
    const history_schema_tests_run = b.addRunArtifact(history_schema_tests);
    artifacts.tests.step.dependOn(&history_schema_tests_run.step);
    b.step("test-product-history-schema", "Run Product history schema and real Storage persistence tests").dependOn(&history_schema_tests_run.step);
    const single_instance_tests = b.addTest(.{
        .name = "metawork-app-single-instance",
        .root_module = test_modules.app,
        .filters = &.{ "single-instance coordinator", "activation queue", "main-loop wake" },
    });
    b.step(
        "test-single-instance",
        "Run Application single-instance lifecycle race tests",
    ).dependOn(&b.addRunArtifact(single_instance_tests).step);
}

fn addRendererWireGenerator(b: *std.Build) void {
    const encoding = b.createModule(.{ .root_source_file = b.path("src/product/control/view_encoding.zig"), .target = b.graph.host });
    const snapshot = b.createModule(.{ .root_source_file = b.path("src/bridge/snapshot_contract.zig"), .target = b.graph.host });
    snapshot.addImport("product_view_encoding", encoding);
    const task_view = b.createModule(.{ .root_source_file = b.path("src/product/task/view_contract.zig"), .target = b.graph.host });
    task_view.addImport("product_view_encoding", encoding);

    const module = b.createModule(.{ .root_source_file = b.path("build_support/renderer_wire_generator.zig"), .target = b.graph.host });
    module.addImport("snapshot_contract", snapshot);
    module.addImport("task_view_contract", task_view);
    module.addImport("product_update", b.createModule(.{ .root_source_file = b.path("src/product/update.zig"), .target = b.graph.host }));
    const generator = b.addExecutable(.{ .name = "metawork-renderer-wire-generator", .root_module = module });
    b.step("generate-renderer-wire", "Generate Renderer structures from actual Host wire types").dependOn(&b.addRunArtifact(generator).step);
}

fn agentCoreTargetId(target: std.Target) []const u8 {
    return switch (target.os.tag) {
        .macos => switch (target.cpu.arch) {
            .aarch64 => "aarch64-macos",
            .x86_64 => "x86_64-macos",
            else => @panic("unsupported macOS AgentCore architecture"),
        },
        .windows => blk: {
            if (target.abi != .msvc) @panic("Windows MetaWork requires the MSVC ABI");
            break :blk switch (target.cpu.arch) {
                .aarch64 => "aarch64-windows-msvc",
                .x86_64 => "x86_64-windows-msvc",
                else => @panic("unsupported Windows AgentCore architecture"),
            };
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
        "tests/agent/multimodal_test.zig",
        "tests/agent/event_pump_test.zig",
        "tests/product/control_lifecycle_test.zig",
        "tests/integration/lifecycle/lifecycle_test.zig",
        "tests/integration/lifecycle/metask_credential_test.zig",
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
        if (std.mem.eql(u8, root, "tests/agent/lifecycle_test.zig") or
            std.mem.eql(u8, root, "tests/agent/multimodal_test.zig"))
            agent_step.dependOn(&run.step);
    }

    const source_tests = b.addTest(.{
        .root_module = modules.product_control_runtime,
        .filters = if (test_filter) |filter|
            &.{filter}
        else
            &.{ "terminal publication", "Workbench outcomes", "Agent terminal facts" },
    });
    step.dependOn(&b.addRunArtifact(source_tests).step);
}

const WiredModules = struct {
    product_update: *std.Build.Module,
    storage: *std.Build.Module,
    storage_sql: *std.Build.Module,
    product_control_history_schema: *std.Build.Module,
    oauth_mechanics: *std.Build.Module,
    oauth_loopback: *std.Build.Module,
    models_contract: *std.Build.Module,
    product_agent_protocol_adapter: *std.Build.Module,
    account: *std.Build.Module,
    account_runtime: *std.Build.Module,
    models_metask: *std.Build.Module,
    account_credentials_runtime: *std.Build.Module,
    models_providers: *std.Build.Module,
    models_ports: *std.Build.Module,
    models_runtime: *std.Build.Module,
    models: *std.Build.Module,
    account_contract: *std.Build.Module,
    account_summary: *std.Build.Module,
    account_credential_store: *std.Build.Module,
    account_loopback: *std.Build.Module,
    oauth_loopback_transport: *std.Build.Module,
    account_login_attempt: *std.Build.Module,
    account_network_attempt: *std.Build.Module,
    account_oauth: *std.Build.Module,
    account_ports: *std.Build.Module,
    account_state: *std.Build.Module,
    metask_transport: *std.Build.Module,
    metask_client: *std.Build.Module,
    app: *std.Build.Module,
    mcp_platform: *std.Build.Module,
    mcp_oauth: *std.Build.Module,
    agent: *std.Build.Module,
    agent_model_binding: *std.Build.Module,
    agent_completion: *std.Build.Module,
    agent_http_transport: *std.Build.Module,
    image_container: *std.Build.Module,
    product_permission_review: *std.Build.Module,
    agent_session: *std.Build.Module,
    agent_file_delivery: *std.Build.Module,
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
    product_control: *std.Build.Module,
    product_control_account_projection: *std.Build.Module,
    product_attachment: *std.Build.Module,
    product_control_execution_state: *std.Build.Module,
    product_control_runtime: *std.Build.Module,
    product_control_executor: *std.Build.Module,
    product_control_file_preview: *std.Build.Module,
    product_control_attachment_staging: *std.Build.Module,
    product_control_file_change_io: *std.Build.Module,
    product_workspace_automatic_root: *std.Build.Module,
    product_workspace_configuration: *std.Build.Module,
    product_workspace: *std.Build.Module,
    product_workspace_runtime: *std.Build.Module,
    image_output: *std.Build.Module,
    output_file: *std.Build.Module,
    models_coordinator: *std.Build.Module,
    product_workspace_view: *std.Build.Module,
    product_schedule: *std.Build.Module,
    product_schedule_state: *std.Build.Module,
    product_schedule_persistence: *std.Build.Module,
    product_schedule_view: *std.Build.Module,
    product_schedule_runtime: *std.Build.Module,
    product_skill_package: *std.Build.Module,
    product_skill_management: *std.Build.Module,
    product_skill_enablement: *std.Build.Module,
    product_skill_sources: *std.Build.Module,
    product_skill_state: *std.Build.Module,
    product_skill_policy: *std.Build.Module,
    product_skill_runtime: *std.Build.Module,
    product_skill_view: *std.Build.Module,
    product_mcp: *std.Build.Module,
    product_mcp_configuration: *std.Build.Module,
    product_mcp_state: *std.Build.Module,
    product_mcp_policy: *std.Build.Module,
    product_mcp_view: *std.Build.Module,
    product_mcp_ports: *std.Build.Module,
    product_mcp_refresh_job: *std.Build.Module,
    product_mcp_runtime: *std.Build.Module,
    product_skill: *std.Build.Module,
    product_skill_catalog: *std.Build.Module,
    product_task: *std.Build.Module,
    product_task_persistence: *std.Build.Module,
    product_task_checkpoint_store: *std.Build.Module,
    product_task_file_change_store: *std.Build.Module,
    product_task_checkpoint_record: *std.Build.Module,
    product_task_worker_lease: *std.Build.Module,
    product_task_execution_binding: *std.Build.Module,
    product_task_agent_session: *std.Build.Module,
    product_task_attachment: *std.Build.Module,
    product_task_runtime: *std.Build.Module,
    product_task_deletion: *std.Build.Module,
    product_task_recovery: *std.Build.Module,
    product_task_recovery_job: *std.Build.Module,
    product_task_approval_job: *std.Build.Module,
    product_task_state: *std.Build.Module,
    product_task_policy: *std.Build.Module,
    product_task_execution: *std.Build.Module,
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
    fixture.addImport("metawork_product_control", modules.product_control);
    fixture.addImport("metawork_product_skill", modules.product_skill);
    fixture.addImport("metawork_product_task", modules.product_task);
    fixture.addImport("metawork_product_workspace", modules.product_workspace);
    fixture.addImport("metawork_account_contract", modules.account_contract);
    fixture.addImport("metawork_account", modules.account);
    fixture.addImport("models_coordinator", modules.models_coordinator);
    fixture.addImport("metask_transport", modules.metask_transport);
    fixture.addImport("metawork_product_models_contract", modules.models_contract);
    fixture.addImport("product_models_ports", modules.models_ports);
    fixture.addImport("event_pump", modules.event_pump);
    fixture.addImport("metask_agentcore", modules.sdk);
    fixture.addImport("product_control_executor", modules.product_control_executor);
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

fn addProductMcpRefreshJobTests(
    b: *std.Build,
    modules: WiredModules,
    link_libc: bool,
) void {
    const step = b.step(
        "test-product-mcp-refresh-job",
        "Run Product MCP refresh worker ownership tests",
    );
    modules.product_mcp_refresh_job.link_libc = link_libc;
    const tests = b.addTest(.{
        .name = "metawork-product-mcp-refresh-job",
        .root_module = modules.product_mcp_refresh_job,
    });
    step.dependOn(&b.addRunArtifact(tests).step);
}

fn addProductMcpRuntimeTests(
    b: *std.Build,
    modules: WiredModules,
    link_libc: bool,
) void {
    const step = b.step(
        "test-product-mcp-runtime",
        "Run Product MCP aggregate lifecycle tests",
    );
    modules.product_mcp_runtime.link_libc = link_libc;
    const tests = b.addTest(.{
        .name = "metawork-product-mcp-runtime",
        .root_module = modules.product_mcp_runtime,
    });
    step.dependOn(&b.addRunArtifact(tests).step);
}

fn addProductControlMcpTests(
    b: *std.Build,
    modules: WiredModules,
    link_libc: bool,
) void {
    const step = b.step(
        "test-product-control-mcp",
        "Run Product Control MCP binding and safe projection tests",
    );
    modules.product_control_runtime.link_libc = link_libc;
    const tests = b.addTest(.{
        .name = "metawork-product-control-mcp",
        .root_module = modules.product_control_runtime,
        .filters = &.{ "MCP", "Product Control snapshot serializer" },
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

fn addImageGenerationTests(b: *std.Build, modules: WiredModules, link_libc: bool) *std.Build.Step {
    const fixture_options = b.addOptions();
    fixture_options.addOption([]const u8, "node_path", b.findProgram(&.{"node"}, &.{}) catch @panic("Node.js required for image fixture"));
    fixture_options.addOption([]const u8, "fixture_path", b.pathFromRoot("tests/fixtures/image_generation.mjs"));
    fixture_options.addOption([]const u8, "png_path", b.pathFromRoot("src/agent/testdata/generated.png"));
    fixture_options.addOption([]const u8, "xlsx_path", b.pathFromRoot("tests/fixtures/office/checked-summary.xlsx"));
    fixture_options.addOption([]const u8, "xlsx_report_path", b.pathFromRoot("tests/fixtures/office/checked-summary-report.json"));
    const backend = b.createModule(.{ .root_source_file = b.path("src/app/completion_http_transport.zig"), .target = modules.agent.resolved_target, .optimize = modules.agent.optimize });
    backend.addImport("metawork_agent", modules.agent);
    backend.addImport("app_select_start", existingImport(modules.oauth_loopback_transport, "app_select_start"));
    const cases = b.createModule(.{ .root_source_file = b.path("tests/agent/image_generation_test.zig"), .target = modules.agent.resolved_target, .optimize = modules.agent.optimize, .link_libc = link_libc });
    cases.addImport("metawork_agent", modules.agent);
    cases.addImport("image_http_backend", backend);
    cases.addImport("image_output", modules.image_output);
    cases.addImport("app_output_file", modules.output_file);
    cases.addImport("models_coordinator", modules.models_coordinator);
    cases.addImport("metawork_account", modules.account);
    cases.addImport("product_models_metask", modules.models_metask);
    cases.addImport("metask_transport", modules.metask_transport);
    cases.addImport("lifecycle_fixture", createLifecycleFixture(b, modules, link_libc));
    cases.addOptions("image_fixture_options", fixture_options);
    const tests = b.addTest(.{ .name = "metawork-generate-image", .root_module = cases });
    const run = b.addRunArtifact(tests);
    b.step("test-generate-image", "Run canonical Core image tool and real HTTP lifecycle tests").dependOn(&run.step);
    b.step("test-generate-image-product", "Run canonical Product image lifecycle tests against local fixtures").dependOn(&b.addRunArtifact(b.addTest(.{
        .name = "metawork-generate-image-product",
        .root_module = cases,
        .filters = &.{"canonical Product"},
    })).step);
    return &run.step;
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
    cases.addImport("lifecycle_fixture", createLifecycleFixture(b, modules, link_libc));
    cases.addImport("metawork_agent", modules.agent);
    cases.addImport("metawork_account_contract", modules.account_contract);
    cases.addImport("metawork_product_models_contract", modules.models_contract);
    cases.addImport("metawork_mcp_platform", modules.mcp_platform);
    cases.addImport("metawork_product_control", modules.product_control);
    cases.addImport("metawork_product_mcp", modules.product_mcp);
    cases.addImport("metawork_product_task", modules.product_task);
    cases.addImport("metawork_product_skill", modules.product_skill);
    cases.addImport("product_models_ports", modules.models_ports);
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

fn wireAgentCore(
    b: *std.Build,
    root_module: *std.Build.Module,
    bundle: agentcore_bundle.Bundle,
    artifact: ArtifactOption,
    automatic_update_checks: bool,
) WiredModules {
    var query = (root_module.resolved_target orelse @panic("Native SDK app target is unresolved")).query;
    if (bundle.deployment_target) |deployment_target|
        query.os_version_min = .{ .semver = deployment_target };
    const target = b.resolveTargetQuery(query);
    root_module.resolved_target = target;

    const runner = existingImport(root_module, "runner");
    const artifact_options = b.addOptions();
    artifact_options.addOption([]const u8, "kind", @tagName(artifact));
    artifact_options.addOption(bool, "automatic_update_checks", automatic_update_checks);
    const product_identity = b.createModule(.{
        .root_source_file = b.path("src/product_identity.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    const app_single_instance_compat = b.createModule(.{
        .root_source_file = b.path("src/native_sdk_compat/app_single_instance.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    if (target.result.os.tag == .macos)
        app_single_instance_compat.linkFramework("CoreFoundation", .{});
    const office_resource_publish_compat = b.createModule(.{
        .root_source_file = b.path("src/native_sdk_compat/office_resource_publish.zig"),
        .target = target,
        .optimize = root_module.optimize,
        .link_libc = bundle.link_libc,
    });
    const storage_sql = b.createModule(.{
        .root_source_file = b.path("src/storage/sql.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    const product_control_history_schema = b.createModule(.{
        .root_source_file = b.path("src/product/control/persistence/schema.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    product_control_history_schema.addImport("metawork_storage_sql", storage_sql);
    const storage = b.createModule(.{
        .root_source_file = b.path("src/storage.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    storage.addImport("metawork_storage_sql", storage_sql);
    const sqlite = b.dependency("sqlite", .{});
    storage.addIncludePath(sqlite.path("."));
    storage.addCSourceFile(.{
        .file = sqlite.path("sqlite3.c"),
        .flags = &.{
            "-DSQLITE_THREADSAFE=2",
            "-DSQLITE_OMIT_LOAD_EXTENSION",
            "-DSQLITE_DQS=0",
            "-DSQLITE_TRUSTED_SCHEMA=0",
            "-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=2",
            "-DSQLITE_DEFAULT_MEMSTATUS=0",
        },
    });
    storage.link_libc = true;
    product_identity.addImport(
        "app_manifest_zon",
        existingImport(runner, "app_manifest_zon"),
    );
    product_identity.addOptions("metawork_artifact_options", artifact_options);
    const dependency_options = .{
        .target = target,
        .optimize = root_module.optimize,
    };
    const sdk = switch (bundle.sdk_dependency) {
        .macos_arm64 => b.dependency("agentcore_macos_arm64", dependency_options),
        .macos_x64 => b.dependency("agentcore_macos_x64", dependency_options),
        .windows_arm64 => b.dependency("agentcore_windows_arm64", dependency_options),
        .windows_x64 => b.dependency("agentcore_windows_x64", dependency_options),
    }.module("metask_agentcore");
    const agent_protocol = b.createModule(.{
        .root_source_file = b.path("src/agent/protocol.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    const agent_model_binding = b.createModule(.{
        .root_source_file = b.path("src/agent/model_binding.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    agent_model_binding.addImport("agent_protocol", agent_protocol);
    const agent_http_transport = b.createModule(.{
        .root_source_file = b.path("src/agent/completion/transport.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    const agent_completion = b.createModule(.{
        .root_source_file = b.path("src/agent/completion.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    const image_container = b.createModule(.{
        .root_source_file = b.path("src/image/container.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    agent_completion.addImport("agent_protocol", agent_protocol);
    agent_completion.addImport("agent_model_binding", agent_model_binding);
    agent_completion.addImport("agent_http_transport", agent_http_transport);
    const product_permission_review = b.createModule(.{
        .root_source_file = b.path("src/product/permission/review.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    product_permission_review.addImport("agent_completion", agent_completion);
    const agent_file_delivery = b.createModule(.{
        .root_source_file = b.path("src/agent/deliver_file.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    const event_sink = b.createModule(.{
        .root_source_file = b.path("src/agent/event_sink.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    event_sink.addImport("metask_agentcore", sdk);
    event_sink.addImport("agent_file_delivery", agent_file_delivery);
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
    agent_checkpoint_restore.addImport("agent_model_binding", agent_model_binding);
    const session = b.createModule(.{
        .root_source_file = b.path("src/agent/session.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    const core_identity = b.addOptions();
    core_identity.addOption([]const u8, "manifest_sha256", &bundle.manifest_sha256);
    session.addOptions("agentcore_identity", core_identity);
    session.addImport("metask_agentcore", sdk);
    session.addImport("agent_file_delivery", agent_file_delivery);
    session.addImport("app_manifest_zon", existingImport(runner, "app_manifest_zon"));
    session.addImport("agent_protocol", agent_protocol);
    session.addImport("agent_model_binding", agent_model_binding);
    session.addImport("agent_http_transport", agent_http_transport);
    session.addImport("image_container", image_container);
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
    agent.addImport("agent_protocol", agent_protocol);
    agent.addImport("agent_model_binding", agent_model_binding);
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
    agent_provider_probe.addImport("agent_model_binding", agent_model_binding);
    agent.addImport("agent_provider_probe", agent_provider_probe);
    const product_update = b.createModule(.{
        .root_source_file = b.path("src/product/update.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    const models_contract = b.createModule(.{
        .root_source_file = b.path("src/product/models/contract.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    const product_agent_protocol_adapter = b.createModule(.{
        .root_source_file = b.path("src/product/agent_protocol_adapter.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    product_agent_protocol_adapter.addImport("metawork_agent", agent);
    product_agent_protocol_adapter.addImport(
        "metawork_product_models_contract",
        models_contract,
    );
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
    const oauth_mechanics = b.createModule(.{
        .root_source_file = b.path("src/oauth/mechanics.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    const oauth_loopback = b.createModule(.{
        .root_source_file = b.path("src/oauth/loopback.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    const account_oauth = b.createModule(.{
        .root_source_file = b.path("src/product/account/oauth.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    account_oauth.addImport("metawork_account_contract", account_contract);
    account_oauth.addImport("oauth_mechanics", oauth_mechanics);
    const account_loopback = b.createModule(.{
        .root_source_file = b.path("src/product/account/loopback.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    account_loopback.addImport("account_oauth", account_oauth);
    account_loopback.addImport("oauth_loopback", oauth_loopback);
    const oauth_loopback_transport = b.createModule(.{
        .root_source_file = b.path("src/app/oauth_loopback_transport.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    const app_select_start = b.createModule(.{
        .root_source_file = b.path("src/app/select_start.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    oauth_loopback_transport.addImport("app_select_start", app_select_start);
    oauth_loopback_transport.addImport("oauth_loopback", oauth_loopback);
    const metask_transport = b.createModule(.{
        .root_source_file = b.path("src/product/metask_transport.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    const account_summary = b.createModule(.{
        .root_source_file = b.path("src/product/account/summary.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    account_summary.addImport("metawork_account_contract", account_contract);
    const metask_client = b.createModule(.{
        .root_source_file = b.path("src/product/account/metask_client.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    metask_client.addImport("metask_transport", metask_transport);
    metask_client.addImport("metawork_account_contract", account_contract);
    metask_client.addImport("account_state", account_state);
    metask_client.addImport("account_oauth", account_oauth);
    metask_client.addImport("account_summary", account_summary);
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
    const models_ports = b.createModule(.{
        .root_source_file = b.path("src/product/models/ports.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    const models_metask = b.createModule(.{
        .root_source_file = b.path("src/product/models/metask.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    models_metask.addImport("metawork_product_models_contract", models_contract);
    models_metask.addImport("product_models_ports", models_ports);
    models_metask.addImport("metask_transport", metask_transport);
    const models_builtin_providers = b.createModule(.{
        .root_source_file = b.path("src/product/models/builtin_providers.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    models_builtin_providers.addImport(
        "metawork_product_models_contract",
        models_contract,
    );
    const account_credentials_runtime = b.createModule(.{
        .root_source_file = b.path("src/product/account/credentials.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    account_credentials_runtime.addImport("account_state", account_state);
    account_credentials_runtime.addImport("account_oauth", account_oauth);
    account_credentials_runtime.addImport("metawork_account_contract", account_contract);
    account_credentials_runtime.addImport("metask_client", metask_client);
    const models_providers = b.createModule(.{
        .root_source_file = b.path("src/product/models/providers.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    models_providers.addImport(
        "metawork_product_models_contract",
        models_contract,
    );
    const models_runtime = b.createModule(.{
        .root_source_file = b.path("src/product/models/runtime.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    models_runtime.addImport("metawork_product_models_contract", models_contract);
    models_runtime.addImport("product_models_ports", models_ports);
    models_runtime.addImport("product_models_providers", models_providers);
    models_runtime.addImport("product_models_metask", models_metask);
    models_runtime.addImport(
        "product_models_builtin_providers",
        models_builtin_providers,
    );
    const models = b.createModule(.{
        .root_source_file = b.path("src/product/models.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    models.addImport("product_models_runtime", models_runtime);
    const account_network_attempt = b.createModule(.{
        .root_source_file = b.path("src/product/account/network_attempt.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    account_network_attempt.addImport("metawork_account_contract", account_contract);
    account_network_attempt.addImport("account_state", account_state);
    account_network_attempt.addImport("account_oauth", account_oauth);
    account_network_attempt.addImport("metask_client", metask_client);
    account_network_attempt.addImport("account_credentials_runtime", account_credentials_runtime);
    account_network_attempt.addImport("account_login_attempt", account_login_attempt);
    const account_credential_store = b.createModule(.{
        .root_source_file = b.path("src/product/account/credential_store.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    account_credential_store.addImport("metawork_account_contract", account_contract);
    account_credential_store.addImport("account_oauth", account_oauth);
    account_credential_store.addImport("metawork_product_identity", product_identity);
    const account_ports = b.createModule(.{
        .root_source_file = b.path("src/product/account/ports.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    account_ports.addImport("account_oauth", account_oauth);
    account_ports.addImport("account_credential_store", account_credential_store);
    account_ports.addImport("metawork_account_contract", account_contract);
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
    account_runtime.addImport("account_credentials_runtime", account_credentials_runtime);
    account_runtime.addImport("account_network_attempt", account_network_attempt);
    account_runtime.addImport("account_summary", account_summary);
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
    account.addImport("account_credentials_runtime", account_credentials_runtime);
    account.addImport("account_network_attempt", account_network_attempt);
    account.addImport("account_runtime", account_runtime);
    account.addImport("account_summary", account_summary);
    const executor = b.createModule(.{
        .root_source_file = b.path("src/product/control/executor.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    const product_attachment = b.createModule(.{
        .root_source_file = b.path("src/product/attachment.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    const attachment_staging = b.createModule(.{
        .root_source_file = b.path("src/product/control/attachment_staging.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    attachment_staging.addImport("metawork_product_attachment", product_attachment);

    const file_preview = b.createModule(.{
        .root_source_file = b.path("src/product/control/file_preview.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    file_preview.addImport("image_container", image_container);
    const product_workspace_automatic_root = b.createModule(.{
        .root_source_file = b.path("src/product/workspace/automatic_root.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    const product_workspace_configuration = b.createModule(.{
        .root_source_file = b.path("src/product/workspace/configuration.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    product_workspace_configuration.addImport(
        "product_workspace_automatic_root",
        product_workspace_automatic_root,
    );
    const product_schedule_state = b.createModule(.{
        .root_source_file = b.path("src/product/schedule/state.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    product_schedule_state.addImport("metawork_product_models_contract", models_contract);
    const product_schedule_persistence = b.createModule(.{
        .root_source_file = b.path("src/product/schedule/persistence.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    product_schedule_persistence.addImport(
        "product_schedule_state",
        product_schedule_state,
    );
    const product_schedule_view = b.createModule(.{
        .root_source_file = b.path("src/product/schedule/view.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    product_schedule_view.addImport("product_schedule_state", product_schedule_state);
    const product_schedule_runtime = b.createModule(.{
        .root_source_file = b.path("src/product/schedule/runtime.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    product_schedule_runtime.addImport("product_schedule_state", product_schedule_state);
    product_schedule_runtime.addImport("product_schedule_persistence", product_schedule_persistence);
    product_schedule_runtime.addImport("product_schedule_view", product_schedule_view);
    product_schedule_runtime.addImport("metawork_product_models_contract", models_contract);
    const product_schedule = b.createModule(.{
        .root_source_file = b.path("src/product/schedule.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    product_schedule.addImport("product_schedule_runtime", product_schedule_runtime);
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
    const file_change_store = b.createModule(.{
        .root_source_file = b.path("src/product/task/file_change_store.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    const file_change_io = b.createModule(.{
        .root_source_file = b.path("src/product/control/file_change_io.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    file_change_io.addImport("product_task_file_change_store", file_change_store);
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
    const product_skill_sources = b.createModule(.{
        .root_source_file = b.path("src/product/skill/sources.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    product_skill_sources.addImport("metawork_agent", agent);
    const product_skill_state = b.createModule(.{
        .root_source_file = b.path("src/product/skill/state.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    product_skill_state.addImport("metawork_agent", agent);
    product_skill_state.addImport("product_skill_catalog", catalog_snapshot);
    product_skill_state.addImport("product_skill_enablement", skill_enablement);
    product_skill_state.addImport("product_skill_management", skill_management);
    product_skill_state.addImport("product_skill_sources", product_skill_sources);
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
    product_skill_policy.addImport("product_skill_sources", product_skill_sources);
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
    product_skill_ports.addImport("product_skill_sources", product_skill_sources);
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
    product_skill_runtime.addImport("product_skill_sources", product_skill_sources);
    const product_skill_view = b.createModule(.{
        .root_source_file = b.path("src/product/skill/view.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    product_skill_view.addImport("product_skill_catalog", catalog_snapshot);
    product_skill_view.addImport("product_skill_management", skill_management);
    product_skill_view.addImport("product_skill_policy", product_skill_policy);
    product_skill_view.addImport("product_skill_state", product_skill_state);
    product_skill_view.addImport("product_skill_sources", product_skill_sources);
    product_skill_runtime.addImport("product_skill_view", product_skill_view);
    const product_skill = b.createModule(.{
        .root_source_file = b.path("src/product/skill.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    product_skill.addImport("product_skill_catalog", catalog_snapshot);
    product_skill.addImport("product_skill_enablement", skill_enablement);
    product_skill.addImport("product_skill_management", skill_management);
    product_skill.addImport("product_skill_ports", product_skill_ports);
    product_skill.addImport("product_skill_runtime", product_skill_runtime);
    product_skill.addImport("product_skill_sources", product_skill_sources);
    const owned_task_execution = b.createModule(.{
        .root_source_file = b.path("src/product/task/execution_binding.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    owned_task_execution.addImport("metawork_product_models_contract", models_contract);
    const task_worker_lease = b.createModule(.{
        .root_source_file = b.path("src/product/task/worker_lease.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    const task_agent_session = b.createModule(.{
        .root_source_file = b.path("src/product/task/agent_session.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    task_agent_session.addImport("metawork_agent", agent);
    const task_attachment = b.createModule(.{
        .root_source_file = b.path("src/product/task/attachment.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    task_attachment.addImport("metawork_agent", agent);
    task_attachment.addImport("product_task_agent_session", task_agent_session);
    task_attachment.addImport("metawork_product_skill", product_skill);
    task_attachment.addImport("product_task_execution_binding", owned_task_execution);
    task_attachment.addImport("product_task_worker_lease", task_worker_lease);
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
    task_recovery_job.addImport("metawork_product_models_contract", models_contract);
    task_recovery_job.addImport("product_task_agent_session", task_agent_session);
    task_recovery_job.addImport("product_task_checkpoint_record", checkpoint_record);
    task_recovery_job.addImport("product_task_checkpoint_store", checkpoint_store);
    task_recovery_job.addImport("product_task_execution_binding", owned_task_execution);
    task_recovery_job.addImport("product_task_worker_lease", task_worker_lease);
    task_recovery_job.addImport(
        "product_agent_protocol_adapter",
        product_agent_protocol_adapter,
    );
    task_attachment.addImport("product_task_recovery_job", task_recovery_job);
    const view_encoding = b.createModule(.{ .root_source_file = b.path("src/product/control/view_encoding.zig"), .target = target, .optimize = root_module.optimize });
    const task_view_contract = b.createModule(.{ .root_source_file = b.path("src/product/task/view_contract.zig"), .target = target, .optimize = root_module.optimize });
    task_view_contract.addImport("product_view_encoding", view_encoding);
    const task_state = b.createModule(.{
        .root_source_file = b.path("src/product/task/state.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    task_state.addImport("product_task_view_contract", task_view_contract);
    task_state.addImport("metawork_agent", agent);
    task_state.addImport("metawork_product_models_contract", models_contract);
    task_state.addImport("product_task_checkpoint_record", checkpoint_record);
    task_state.addImport("product_task_attachment", task_attachment);
    task_state.addImport("product_task_deletion", task_deletion);
    task_state.addImport("product_task_recovery", task_recovery);
    task_state.addImport("product_task_worker_lease", task_worker_lease);
    task_state.addImport("product_task_execution_binding", owned_task_execution);
    task_persistence.addImport("metawork_agent", agent);
    task_persistence.addImport("product_task_checkpoint_record", checkpoint_record);
    task_persistence.addImport("product_task_checkpoint_store", checkpoint_store);
    task_persistence.addImport("product_task_state", task_state);
    product_control_history_schema.addImport("product_task_persistence", task_persistence);
    const task_policy = b.createModule(.{
        .root_source_file = b.path("src/product/task/policy.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    task_policy.addImport("metawork_agent", agent);
    task_policy.addImport("product_task_state", task_state);
    task_policy.addImport("product_task_attachment", task_attachment);
    task_policy.addImport("product_task_recovery", task_recovery);
    task_policy.addImport("product_task_checkpoint_record", checkpoint_record);
    const task_approval_job = b.createModule(.{
        .root_source_file = b.path("src/product/task/approval_job.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    task_approval_job.addImport("metawork_agent", agent);
    task_approval_job.addImport("product_task_agent_session", task_agent_session);
    task_approval_job.addImport("product_task_checkpoint_record", checkpoint_record);
    task_approval_job.addImport("product_task_checkpoint_store", checkpoint_store);
    task_approval_job.addImport("product_task_persistence", task_persistence);
    task_approval_job.addImport("product_task_state", task_state);
    task_approval_job.addImport("product_task_worker_lease", task_worker_lease);
    const task_runtime = b.createModule(.{
        .root_source_file = b.path("src/product/task/runtime.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    task_runtime.addImport("product_task_state", task_state);
    task_runtime.addImport("product_task_approval_job", task_approval_job);
    task_runtime.addImport("product_permission_review", product_permission_review);
    task_runtime.addImport("product_task_persistence", task_persistence);
    task_runtime.addImport("metawork_agent", agent);
    task_runtime.addImport("metawork_product_models_contract", models_contract);
    task_runtime.addImport("product_task_policy", task_policy);
    task_runtime.addImport("metawork_product_skill", product_skill);
    task_runtime.addImport("product_task_recovery_job", task_recovery_job);
    task_runtime.addImport("product_task_checkpoint_store", checkpoint_store);
    task_runtime.addImport("product_task_checkpoint_record", checkpoint_record);
    task_runtime.addImport("product_task_file_change_store", file_change_store);
    task_runtime.addImport("product_task_attachment", task_attachment);
    task_runtime.addImport("product_task_deletion", task_deletion);
    task_runtime.addImport("product_task_recovery", task_recovery);
    task_runtime.addImport("product_task_agent_session", task_agent_session);
    task_runtime.addImport("product_task_execution_binding", owned_task_execution);
    task_runtime.addImport("product_task_worker_lease", task_worker_lease);
    task_runtime.addImport(
        "product_agent_protocol_adapter",
        product_agent_protocol_adapter,
    );
    const task_execution = b.createModule(.{
        .root_source_file = b.path("src/product/task/execution.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    task_execution.addImport("metawork_agent", agent);
    task_execution.addImport("product_task_checkpoint_record", checkpoint_record);
    task_execution.addImport("product_task_checkpoint_store", checkpoint_store);
    task_execution.addImport("product_task_execution_binding", owned_task_execution);
    task_execution.addImport("product_task_agent_session", task_agent_session);
    task_execution.addImport("product_task_state", task_state);
    task_execution.addImport("product_task_policy", task_policy);
    task_execution.addImport("product_task_worker_lease", task_worker_lease);
    task_execution.addImport(
        "product_agent_protocol_adapter",
        product_agent_protocol_adapter,
    );
    task_runtime.addImport("product_task_execution", task_execution);
    const task_view = b.createModule(.{
        .root_source_file = b.path("src/product/task/view.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    task_view.addImport("product_task_view_contract", task_view_contract);
    const task_view_fixture = b.addOptions();
    task_view_fixture.addOption([]const u8, "interrupted_compact", @embedFile("frontend/src/bridge/__fixtures__/compact-interrupted.fixture"));
    task_view.addOptions("task_view_fixture", task_view_fixture);
    task_view.addImport("metawork_agent", agent);
    task_view.addImport("metawork_product_skill", product_skill);
    task_view.addImport("product_task_state", task_state);
    task_view.addImport("product_task_policy", task_policy);
    task_view.addImport("product_task_recovery", task_recovery);
    task_runtime.addImport("product_task_view", task_view);
    const product_task = b.createModule(.{
        .root_source_file = b.path("src/product/task.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    product_task.addImport("product_task_persistence", task_persistence);
    product_task.addImport("product_task_checkpoint_store", checkpoint_store);
    product_task.addImport("product_task_file_change_store", file_change_store);
    product_task.addImport("product_task_execution_binding", owned_task_execution);
    product_task.addImport("product_task_agent_session", task_agent_session);
    product_task.addImport("product_task_attachment", task_attachment);
    product_task.addImport("product_task_runtime", task_runtime);
    product_task.addImport("product_task_deletion", task_deletion);
    product_task.addImport("product_task_state", task_state);
    product_task.addImport("product_task_policy", task_policy);
    product_task.addImport("product_task_execution", task_execution);
    product_task.addImport("product_task_worker_lease", task_worker_lease);
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
    const product_mcp_policy = b.createModule(.{
        .root_source_file = b.path("src/product/mcp/policy.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    product_mcp_policy.addImport("metawork_agent", agent);
    product_mcp_policy.addImport("product_mcp_configuration", mcp_configuration);
    product_mcp_policy.addImport("product_mcp_state", product_mcp_state);
    const product_mcp_view = b.createModule(.{
        .root_source_file = b.path("src/product/mcp/view.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    product_mcp_view.addImport("product_mcp_configuration", mcp_configuration);
    product_mcp_view.addImport("product_mcp_state", product_mcp_state);
    const product_mcp_ports = b.createModule(.{
        .root_source_file = b.path("src/product/mcp/ports.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    product_mcp_ports.addImport("metawork_agent", agent);
    const product_mcp_refresh_job = b.createModule(.{
        .root_source_file = b.path("src/product/mcp/refresh_job.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    product_mcp_refresh_job.addImport("metawork_agent", agent);
    product_mcp_refresh_job.addImport("product_mcp_ports", product_mcp_ports);
    const product_mcp_runtime = b.createModule(.{
        .root_source_file = b.path("src/product/mcp/runtime.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    product_mcp_runtime.addImport("metawork_agent", agent);
    product_mcp_runtime.addImport("product_mcp_configuration", mcp_configuration);
    product_mcp_runtime.addImport("product_mcp_state", product_mcp_state);
    product_mcp_runtime.addImport("product_mcp_policy", product_mcp_policy);
    product_mcp_runtime.addImport("product_mcp_view", product_mcp_view);
    product_mcp_runtime.addImport("product_mcp_ports", product_mcp_ports);
    product_mcp_runtime.addImport("product_mcp_refresh_job", product_mcp_refresh_job);
    product_mcp.addImport("product_mcp_ports", product_mcp_ports);
    product_mcp.addImport("product_mcp_runtime", product_mcp_runtime);
    const product_control_account_projection = b.createModule(.{
        .root_source_file = b.path("src/product/control/account_projection.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    product_control_account_projection.addImport(
        "metawork_account_contract",
        account_contract,
    );
    product_control_account_projection.addImport(
        "metawork_product_models_contract",
        models_contract,
    );
    const product_control_execution_state = b.createModule(.{
        .root_source_file = b.path("src/product/control/execution_state.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    product_control_execution_state.addImport(
        "metawork_product_models_contract",
        models_contract,
    );

    const product_control_ports = b.createModule(.{
        .root_source_file = b.path("src/product/control/ports.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    product_control_ports.addImport("metawork_agent", agent);
    product_control_ports.addImport("metawork_account_contract", account_contract);
    product_control_ports.addImport("metawork_product_models_contract", models_contract);
    product_control_ports.addImport("product_models_ports", models_ports);
    product_control_ports.addImport("metawork_product_mcp", product_mcp);
    product_control_ports.addImport("metawork_product_schedule", product_schedule);
    product_control_ports.addImport("metawork_product_task", product_task);
    const product_workspace_runtime = b.createModule(.{
        .root_source_file = b.path("src/product/workspace/runtime.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    product_workspace_runtime.addImport(
        "product_workspace_automatic_root",
        product_workspace_automatic_root,
    );
    const product_workspace_view = b.createModule(.{
        .root_source_file = b.path("src/product/workspace/view.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    product_workspace_view.addImport("product_workspace_runtime", product_workspace_runtime);
    const product_workspace = b.createModule(.{
        .root_source_file = b.path("src/product/workspace.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    product_workspace.addImport("product_workspace_runtime", product_workspace_runtime);
    product_workspace.addImport("product_workspace_view", product_workspace_view);
    product_workspace.addImport(
        "product_workspace_configuration",
        product_workspace_configuration,
    );
    const image_output = b.createModule(.{
        .root_source_file = b.path("src/app/image_output.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    const output_file = b.createModule(.{
        .root_source_file = b.path("src/app/output_file.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    product_control_ports.addImport("metawork_product_workspace", product_workspace);
    image_output.addImport("metawork_agent", agent);
    image_output.addImport("app_select_start", app_select_start);
    image_output.addImport("metawork_product_workspace", product_workspace);
    const product_control_runtime = b.createModule(.{
        .root_source_file = b.path("src/product/control/runtime.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    product_control_runtime.addImport("metawork_agent", agent);
    product_control_runtime.addImport("metawork_product_update", product_update);
    product_control_runtime.addImport("metawork_product_identity", product_identity);
    product_control_runtime.addImport("metawork_account_contract", account_contract);
    product_control_runtime.addImport("metawork_product_models_contract", models_contract);
    product_control_runtime.addImport("metawork_product_models", models);
    product_control_runtime.addImport("product_models_ports", models_ports);
    product_control_runtime.addImport(
        "product_control_account_projection",
        product_control_account_projection,
    );
    product_control_runtime.addImport(
        "product_control_execution_state",
        product_control_execution_state,
    );
    product_control_runtime.addImport("product_control_executor", executor);
    product_control_runtime.addImport("metawork_product_attachment", product_attachment);
    product_control_runtime.addImport("product_control_attachment_staging", attachment_staging);
    product_control_runtime.addImport("product_control_file_preview", file_preview);
    product_control_runtime.addImport("product_permission_review", product_permission_review);
    product_control_runtime.addImport("product_agent_protocol_adapter", product_agent_protocol_adapter);
    product_control_runtime.addImport("product_control_file_change_io", file_change_io);
    product_control_runtime.addImport("metawork_product_schedule", product_schedule);
    product_control_runtime.addImport("metawork_product_workspace", product_workspace);
    product_control_runtime.addImport("metawork_product_task", product_task);
    product_control_runtime.addImport("metawork_product_skill", product_skill);
    product_control_runtime.addImport("metawork_product_mcp", product_mcp);
    product_control_runtime.addImport("metawork_product_control_ports", product_control_ports);
    product_control_runtime.addImport(
        "build_options",
        existingImport(
            existingImport(root_module, "runner"),
            "build_options",
        ),
    );
    const product_control_contract_fixture = b.addOptions();
    product_control_contract_fixture.addOption([]const u8, "skill_import_preview", @embedFile("frontend/src/bridge/__fixtures__/skill-import-preview.fixture"));
    product_control_contract_fixture.addOption([]const u8, "task_open", @embedFile("frontend/src/bridge/__fixtures__/task-open.fixture"));
    product_control_contract_fixture.addOption([]const u8, "scheduled_occurrences", @embedFile("frontend/src/bridge/__fixtures__/scheduled-occurrences.fixture"));
    product_control_contract_fixture.addOption([]const u8, "output_save", @embedFile("frontend/src/bridge/__fixtures__/output-save.fixture"));
    product_control_contract_fixture.addOption([]const u8, "output_action", @embedFile("frontend/src/bridge/__fixtures__/output-action.fixture"));
    product_control_contract_fixture.addOption([]const u8, "delivered_output", @embedFile("frontend/src/bridge/__fixtures__/delivered-output.fixture"));
    product_control_contract_fixture.addOption([]const u8, "product_view", @embedFile("frontend/src/bridge/__fixtures__/product-view.fixture"));
    product_control_contract_fixture.addOption([]const u8, "session_pressure", @embedFile("frontend/src/bridge/__fixtures__/session-pressure.fixture"));
    product_control_contract_fixture.addOption([]const u8, "search_page", @embedFile("frontend/src/bridge/__fixtures__/search-page.fixture"));
    product_control_contract_fixture.addOption([]const u8, "attachments_unavailable", @embedFile("frontend/src/bridge/__fixtures__/attachments-unavailable.fixture"));
    product_control_contract_fixture.addOption([]const u8, "model_metadata", @embedFile("frontend/src/bridge/__fixtures__/model-metadata.fixture"));
    product_control_contract_fixture.addOption(
        []const u8,
        "snapshot",
        @embedFile("frontend/src/bridge/__fixtures__/workbench-snapshot.fixture"),
    );
    product_control_contract_fixture.addOption(
        []const u8,
        "models_unavailable",
        @embedFile("frontend/src/bridge/__fixtures__/models-unavailable.fixture"),
    );
    product_control_contract_fixture.addOption(
        []const u8,
        "permission_file_target",
        @embedFile("frontend/src/bridge/__fixtures__/permission-file-target.fixture"),
    );
    product_control_contract_fixture.addOption(
        []const u8,
        "skill_recovery_required",
        @embedFile("frontend/src/bridge/__fixtures__/skill-recovery-required.fixture"),
    );
    product_control_contract_fixture.addOption(
        []const u8,
        "skill_catalog_ready",
        @embedFile("frontend/src/bridge/__fixtures__/skill-catalog-ready.fixture"),
    );
    const shared_contract_fixture_module = product_control_contract_fixture.createModule();
    product_control_runtime.addImport("product_control_contract_fixture", shared_contract_fixture_module);
    const product_control = b.createModule(.{
        .root_source_file = b.path("src/product/control.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    product_control.addImport("product_control_runtime", product_control_runtime);
    product_control.addImport("metawork_product_attachment", product_attachment);
    product_control.addImport("metawork_product_workspace", product_workspace);
    product_control.addImport("metawork_product_skill", product_skill);

    const bridge = b.createModule(.{
        .root_source_file = b.path("src/bridge.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    bridge.addImport("product_view_encoding", view_encoding);
    bridge.addImport("contract_fixture", shared_contract_fixture_module);
    bridge.addImport("native_sdk", existingImport(root_module, "native_sdk"));
    bridge.addImport("metawork_account_contract", account_contract);
    bridge.addImport("metawork_product_models_contract", models_contract);
    bridge.addImport("metawork_product_control", product_control);
    bridge.addImport("metawork_product_update", product_update);
    bridge.addImport("metawork_product_mcp", product_mcp);
    bridge.addImport("metawork_product_skill", product_skill);

    const automation_disabled = b.createModule(.{
        .root_source_file = b.path("src/automation/disabled.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    automation_disabled.addImport("native_sdk", existingImport(root_module, "native_sdk"));
    automation_disabled.addImport("metawork_bridge", bridge);
    automation_disabled.addImport("metawork_product_models_contract", models_contract);
    const automation_enabled = b.createModule(.{
        .root_source_file = b.path("src/automation/enabled.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    automation_enabled.addImport("native_sdk", existingImport(root_module, "native_sdk"));
    automation_enabled.addImport("metawork_bridge", bridge);
    automation_enabled.addImport("metawork_product_models_contract", models_contract);
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
    mcp_platform.addImport("app_select_start", app_select_start);
    const mcp_platform_test_options = b.addOptions();
    mcp_platform_test_options.addOption([]const u8, "node_path", b.findProgram(&.{"node"}, &.{}) catch @panic("Node.js required for MCP process fixtures"));
    mcp_platform.addOptions("mcp_platform_test_options", mcp_platform_test_options);
    mcp_platform.addImport("metawork_product_mcp", product_mcp);
    mcp_platform.addImport("metawork_product_identity", product_identity);
    const mcp_oauth = b.createModule(.{
        .root_source_file = b.path("src/app/mcp_oauth.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    mcp_oauth.addImport("oauth_mechanics", oauth_mechanics);
    mcp_oauth.addImport("app_select_start", app_select_start);
    mcp_oauth.addImport("oauth_loopback", oauth_loopback);
    mcp_oauth.addImport("oauth_loopback_transport", oauth_loopback_transport);
    mcp_platform.addImport("metawork_mcp_oauth", mcp_oauth);

    const models_coordinator = b.createModule(.{
        .root_source_file = b.path("src/app/models_coordinator.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    models_coordinator.addImport("metawork_agent", agent);
    models_coordinator.addImport("metawork_account", account);
    models_coordinator.addImport("metawork_account_contract", account_contract);
    models_coordinator.addImport("metawork_product_models_contract", models_contract);
    models_coordinator.addImport("product_models_ports", models_ports);
    models_coordinator.addImport("product_models_metask", models_metask);
    models_coordinator.addImport("metask_transport", metask_transport);
    models_coordinator.addImport("metawork_product_control_ports", product_control_ports);
    models_coordinator.addImport("product_agent_protocol_adapter", product_agent_protocol_adapter);
    models_coordinator.addImport("metawork_product_task", product_task);
    models_coordinator.addImport("metawork_product_workspace", product_workspace);
    models_coordinator.addImport("image_output", image_output);
    const app = b.createModule(.{
        .root_source_file = b.path("src/app.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    product_control.addImport("product_control_history_schema", product_control_history_schema);
    app.addImport("storage", storage);
    app.addImport("runner", runner);
    app.addImport("build_options", existingImport(runner, "build_options"));
    app.addImport("native_sdk", existingImport(root_module, "native_sdk"));
    app.addImport("metawork_agent", agent);
    app.addImport("metawork_product_update", product_update);
    app.addImport("app_output_file", output_file);
    app.addImport("metawork_product_workspace", product_workspace);
    app.addImport("metawork_product_control", product_control);
    app.addImport(
        "product_schedule_persistence",
        product_schedule_persistence,
    );
    app.addImport("metawork_product_mcp", product_mcp);
    app.addImport("metawork_product_control_ports", product_control_ports);
    app.addImport("models_coordinator", models_coordinator);
    app.addImport("metawork_product_skill", product_skill);
    app.addImport("metawork_product_task", product_task);
    app.addImport("metawork_bridge", bridge);
    app.addImport("metawork_automation", automation);
    app.addImport("metawork_account_contract", account_contract);
    app.addImport("metawork_product_models_contract", models_contract);
    app.addImport("product_models_ports", models_ports);
    app.addImport("product_models_metask", models_metask);
    app.addImport("metask_transport", metask_transport);
    app.addImport(
        "product_agent_protocol_adapter",
        product_agent_protocol_adapter,
    );
    app.addImport("metawork_account", account);
    app.addImport("account_oauth", account_oauth);
    app.addImport("account_loopback", account_loopback);
    app.addImport("oauth_loopback_transport", oauth_loopback_transport);
    app.addImport("app_select_start", app_select_start);
    app.addImport("account_ports", account_ports);
    app.addImport("account_credential_store", account_credential_store);
    app.addImport("metask_client", metask_client);
    app.addImport("metawork_product_identity", product_identity);
    app.addImport("metawork_office_resource_publish_compat", office_resource_publish_compat);
    app.addImport(
        "metawork_app_single_instance_compat",
        app_single_instance_compat,
    );

    app.addImport("image_container", image_container);
    app.addImport("metawork_mcp_platform", mcp_platform);
    app.addImport("metawork_mcp_oauth", mcp_oauth);

    root_module.addImport("metawork_app", app);
    root_module.link_libc = bundle.link_libc;
    return .{
        .product_update = product_update,
        .storage = storage,
        .storage_sql = storage_sql,
        .product_control_history_schema = product_control_history_schema,
        .oauth_mechanics = oauth_mechanics,
        .oauth_loopback = oauth_loopback,
        .models_contract = models_contract,
        .product_agent_protocol_adapter = product_agent_protocol_adapter,
        .account = account,
        .account_runtime = account_runtime,
        .models_metask = models_metask,
        .account_credentials_runtime = account_credentials_runtime,
        .models_providers = models_providers,
        .models_ports = models_ports,
        .models_runtime = models_runtime,
        .models = models,
        .account_contract = account_contract,
        .account_summary = account_summary,
        .account_credential_store = account_credential_store,
        .account_loopback = account_loopback,
        .oauth_loopback_transport = oauth_loopback_transport,
        .account_login_attempt = account_login_attempt,
        .account_network_attempt = account_network_attempt,
        .account_oauth = account_oauth,
        .account_ports = account_ports,
        .account_state = account_state,
        .metask_transport = metask_transport,
        .metask_client = metask_client,
        .app = app,
        .mcp_platform = mcp_platform,
        .mcp_oauth = mcp_oauth,
        .agent = agent,
        .agent_model_binding = agent_model_binding,
        .agent_completion = agent_completion,
        .agent_http_transport = agent_http_transport,
        .image_container = image_container,
        .product_permission_review = product_permission_review,
        .agent_session = session,
        .agent_file_delivery = agent_file_delivery,
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
        .product_control = product_control,
        .product_control_account_projection = product_control_account_projection,
        .product_attachment = product_attachment,
        .product_control_execution_state = product_control_execution_state,
        .product_control_runtime = product_control_runtime,
        .product_control_executor = executor,
        .product_control_file_preview = file_preview,
        .product_control_attachment_staging = attachment_staging,
        .product_control_file_change_io = file_change_io,
        .product_workspace_automatic_root = product_workspace_automatic_root,
        .product_workspace_configuration = product_workspace_configuration,
        .product_workspace = product_workspace,
        .product_workspace_runtime = product_workspace_runtime,
        .image_output = image_output,
        .output_file = output_file,
        .models_coordinator = models_coordinator,
        .product_workspace_view = product_workspace_view,
        .product_schedule = product_schedule,
        .product_schedule_state = product_schedule_state,
        .product_schedule_persistence = product_schedule_persistence,
        .product_schedule_view = product_schedule_view,
        .product_schedule_runtime = product_schedule_runtime,
        .product_skill_package = skill_package,
        .product_skill_management = skill_management,
        .product_skill_enablement = skill_enablement,
        .product_skill_sources = product_skill_sources,
        .product_skill_state = product_skill_state,
        .product_skill_policy = product_skill_policy,
        .product_skill_runtime = product_skill_runtime,
        .product_skill_view = product_skill_view,
        .product_mcp = product_mcp,
        .product_mcp_configuration = mcp_configuration,
        .product_mcp_state = product_mcp_state,
        .product_mcp_policy = product_mcp_policy,
        .product_mcp_view = product_mcp_view,
        .product_mcp_ports = product_mcp_ports,
        .product_mcp_refresh_job = product_mcp_refresh_job,
        .product_mcp_runtime = product_mcp_runtime,
        .product_skill = product_skill,
        .product_skill_catalog = catalog_snapshot,
        .product_task = product_task,
        .product_task_persistence = task_persistence,
        .product_task_checkpoint_store = checkpoint_store,
        .product_task_file_change_store = file_change_store,
        .product_task_checkpoint_record = checkpoint_record,
        .product_task_worker_lease = task_worker_lease,
        .product_task_execution_binding = owned_task_execution,
        .product_task_agent_session = task_agent_session,
        .product_task_attachment = task_attachment,
        .product_task_runtime = task_runtime,
        .product_task_deletion = task_deletion,
        .product_task_recovery = task_recovery,
        .product_task_recovery_job = task_recovery_job,
        .product_task_approval_job = task_approval_job,
        .product_task_state = task_state,
        .product_task_policy = task_policy,
        .product_task_execution = task_execution,
        .product_task_view = task_view,
    };
}

fn parsedBooleanOption(b: *std.Build, name: []const u8) bool {
    const option = b.user_input_options.get(name) orelse return false;
    return switch (option.value) {
        .flag => true,
        .scalar => |value| std.mem.eql(u8, value, "true"),
        else => false,
    };
}

fn selectedArtifact(b: *std.Build) ArtifactOption {
    // Native SDK already declares and validates -Dautomation before the app
    // extends its graph. Read the parsed input instead of declaring the same
    // public build option a second time.
    const native_automation = parsedBooleanOption(b, "automation");
    const artifact: ArtifactOption = b.option(
        ArtifactOption,
        "artifact",
        "MetaWork artifact identity: development, release, automation",
    ) orelse if (native_automation) .automation else .development;
    if ((artifact == .automation) != native_automation)
        @panic("-Dartifact=automation and -Dautomation=true must be selected together");
    if (artifact == .release)
        @panic("MetaWork release identity is not configured; register the release Bundle ID, data directory, and credential services before enabling -Dartifact=release");
    return artifact;
}

fn existingImport(module: *std.Build.Module, name: []const u8) *std.Build.Module {
    return module.import_table.get(name) orelse
        std.debug.panic("Native SDK root module does not expose required import '{s}'", .{name});
}
