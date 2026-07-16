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

fn wireAgentCore(b: *std.Build, app: *std.Build.Module, bundle: agentcore_bundle.Bundle) *std.Build.Module {
    var query = (app.resolved_target orelse @panic("Native SDK app target is unresolved")).query;
    query.os_version_min = .{ .semver = bundle.deployment_target };
    const target = b.resolveTargetQuery(query);
    app.resolved_target = target;

    const types = b.createModule(.{
        .root_source_file = .{ .cwd_relative = bundle.types_path },
        .target = target,
        .optimize = app.optimize,
    });
    const protocol = b.createModule(.{
        .root_source_file = .{ .cwd_relative = bundle.protocol_path },
        .target = target,
        .optimize = app.optimize,
    });
    const sdk = b.createModule(.{
        .root_source_file = .{ .cwd_relative = bundle.sdk_path },
        .target = target,
        .optimize = app.optimize,
    });
    sdk.addImport("metacodes_agentcore_types", types);
    sdk.addImport("metacodes_agentcore_protocol", protocol);
    const event_sink = b.createModule(.{
        .root_source_file = b.path("src/agentcore/event_sink.zig"),
        .target = target,
        .optimize = app.optimize,
    });
    event_sink.addImport("metacodes_agentcore", sdk);
    const event_pump = b.createModule(.{
        .root_source_file = b.path("src/agentcore/event_pump.zig"),
        .target = target,
        .optimize = app.optimize,
    });
    event_pump.addImport("metacodes_agentcore", sdk);
    event_pump.addImport("event_sink", event_sink);
    const session = b.createModule(.{
        .root_source_file = b.path("src/agentcore/session.zig"),
        .target = target,
        .optimize = app.optimize,
    });
    session.addImport("metacodes_agentcore", sdk);
    session.addImport("event_pump", event_pump);
    const agentcore = b.createModule(.{
        .root_source_file = b.path("src/agentcore.zig"),
        .target = target,
        .optimize = app.optimize,
    });
    agentcore.addImport("agentcore_session", session);
    const executor = b.createModule(.{
        .root_source_file = b.path("src/workbench/executor.zig"),
        .target = target,
        .optimize = app.optimize,
    });
    executor.addImport("metawork_agentcore", agentcore);
    const projection = b.createModule(.{
        .root_source_file = b.path("src/workbench/projection.zig"),
        .target = target,
        .optimize = app.optimize,
    });
    projection.addImport("metacodes_agentcore", sdk);
    projection.addImport("metawork_agentcore", agentcore);
    const workbench_contract_fixture = b.addOptions();
    workbench_contract_fixture.addOption(
        []const u8,
        "snapshot",
        @embedFile("frontend/src/host/__fixtures__/workbench-snapshot-v1.fixture"),
    );
    projection.addOptions("workbench_contract_fixture", workbench_contract_fixture);
    const workbench = b.createModule(.{
        .root_source_file = b.path("src/workbench.zig"),
        .target = target,
        .optimize = app.optimize,
    });
    workbench.addImport("workbench_projection", projection);
    workbench.addImport("workbench_executor", executor);

    app.addImport("metacodes_agentcore", sdk);
    app.addImport("metawork_agentcore", agentcore);
    app.addImport("metawork_workbench", workbench);
    app.addObjectFile(.{ .cwd_relative = bundle.library_path });
    app.link_libc = bundle.link_libc;
    return projection;
}
