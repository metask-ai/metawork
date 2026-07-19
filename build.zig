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
    const root = b.option([]const u8, "agentcore-bundle-root", "Validated source-free AgentCore bundle root") orelse
        b.pathFromRoot(".agentcore/bundle");
    const bundle = agentcore_bundle.verify(b, root);
    const workbench = wireAgentCore(b, artifacts.exe.root_module, bundle);
    const test_workbench = if (artifacts.tests.root_module != artifacts.exe.root_module)
        wireAgentCore(b, artifacts.tests.root_module, bundle)
    else
        workbench;
    test_workbench.link_libc = true;
    const workbench_tests = b.addTest(.{ .name = "metawork-workbench", .root_module = test_workbench });
    artifacts.tests.step.dependOn(&b.addRunArtifact(workbench_tests).step);
}

fn wireAgentCore(b: *std.Build, root_module: *std.Build.Module, bundle: agentcore_bundle.Bundle) *std.Build.Module {
    var query = (root_module.resolved_target orelse @panic("Native SDK app target is unresolved")).query;
    query.os_version_min = .{ .semver = bundle.deployment_target };
    const target = b.resolveTargetQuery(query);
    root_module.resolved_target = target;

    const types = b.createModule(.{
        .root_source_file = .{ .cwd_relative = bundle.types_path },
        .target = target,
        .optimize = root_module.optimize,
    });
    const protocol = b.createModule(.{
        .root_source_file = .{ .cwd_relative = bundle.protocol_path },
        .target = target,
        .optimize = root_module.optimize,
    });
    const sdk = b.createModule(.{
        .root_source_file = .{ .cwd_relative = bundle.sdk_path },
        .target = target,
        .optimize = root_module.optimize,
    });
    sdk.addImport("metacodes_agentcore_types", types);
    sdk.addImport("metacodes_agentcore_protocol", protocol);
    const event_sink = b.createModule(.{
        .root_source_file = b.path("src/agent/event_sink.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    event_sink.addImport("metacodes_agentcore", sdk);
    const event_pump = b.createModule(.{
        .root_source_file = b.path("src/agent/event_pump.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    event_pump.addImport("metacodes_agentcore", sdk);
    event_pump.addImport("event_sink", event_sink);
    const session = b.createModule(.{
        .root_source_file = b.path("src/agent/session.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    session.addImport("metacodes_agentcore", sdk);
    session.addImport("event_pump", event_pump);
    const agent = b.createModule(.{
        .root_source_file = b.path("src/agent.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    agent.addImport("agent_session", session);
    const executor = b.createModule(.{
        .root_source_file = b.path("src/workbench/executor.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    const projection = b.createModule(.{
        .root_source_file = b.path("src/workbench/projection.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    projection.addImport("metawork_agent", agent);
    projection.addImport("workbench_executor", executor);
    const workbench_contract_fixture = b.addOptions();
    workbench_contract_fixture.addOption(
        []const u8,
        "snapshot",
        @embedFile("frontend/src/bridge/__fixtures__/workbench-snapshot-v5.fixture"),
    );
    projection.addOptions("workbench_contract_fixture", workbench_contract_fixture);
    const workbench = b.createModule(.{
        .root_source_file = b.path("src/workbench.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    workbench.addImport("workbench_projection", projection);

    const bridge = b.createModule(.{
        .root_source_file = b.path("src/bridge.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    bridge.addImport("native_sdk", existingImport(root_module, "native_sdk"));

    const automation_disabled = b.createModule(.{
        .root_source_file = b.path("src/automation/disabled.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    automation_disabled.addImport("native_sdk", existingImport(root_module, "native_sdk"));
    automation_disabled.addImport("metawork_bridge", bridge);
    const automation_delivery = b.createModule(.{
        .root_source_file = b.path("src/automation/delivery.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    const automation_enabled = b.createModule(.{
        .root_source_file = b.path("src/automation/enabled.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    automation_enabled.addImport("native_sdk", existingImport(root_module, "native_sdk"));
    automation_enabled.addImport("metawork_bridge", bridge);
    automation_enabled.addImport("automation_delivery", automation_delivery);
    const automation = b.createModule(.{
        .root_source_file = b.path("src/automation.zig"),
        .target = target,
        .optimize = root_module.optimize,
    });
    const runner = existingImport(root_module, "runner");
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

    root_module.addImport("metawork_app", app);
    root_module.addObjectFile(.{ .cwd_relative = bundle.library_path });
    root_module.link_libc = bundle.link_libc;
    return projection;
}

fn existingImport(module: *std.Build.Module, name: []const u8) *std.Build.Module {
    return module.import_table.get(name) orelse
        std.debug.panic("Native SDK root module does not expose required import '{s}'", .{name});
}
