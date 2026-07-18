const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "tfilter", "Test name filter");
    const bundle_root = b.option([]const u8, "bundle-root", "Validated AgentCore bundle root") orelse
        @panic("-Dbundle-root is required");
    if (!std.fs.path.isAbsolute(bundle_root)) @panic("-Dbundle-root must be absolute");

    const sdk_path = b.pathJoin(&.{ bundle_root, "sdk", "metacodes_agentcore.zig" });
    const protocol_path = b.pathJoin(&.{ bundle_root, "sdk", "metacodes_agentcore_protocol.zig" });
    const types_path = b.pathJoin(&.{ bundle_root, "sdk", "metacodes_agentcore_types.zig" });
    const types = b.createModule(.{
        .root_source_file = .{ .cwd_relative = types_path },
        .target = target,
        .optimize = optimize,
    });
    const protocol = b.createModule(.{
        .root_source_file = .{ .cwd_relative = protocol_path },
        .target = target,
        .optimize = optimize,
    });
    const sdk = b.createModule(.{
        .root_source_file = .{ .cwd_relative = sdk_path },
        .target = target,
        .optimize = optimize,
    });
    sdk.addImport("metacodes_agentcore_types", types);
    sdk.addImport("metacodes_agentcore_protocol", protocol);

    const event_sink = b.createModule(.{
        .root_source_file = b.path("../../src/agent/event_sink.zig"),
        .target = target,
        .optimize = optimize,
    });
    event_sink.addImport("metacodes_agentcore", sdk);
    const lifecycle = b.createModule(.{
        .root_source_file = b.path("../../src/agent/session.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    lifecycle.addImport("metacodes_agentcore", sdk);
    const event_pump = b.createModule(.{
        .root_source_file = b.path("../../src/agent/event_pump.zig"),
        .target = target,
        .optimize = optimize,
    });
    event_pump.addImport("metacodes_agentcore", sdk);
    event_pump.addImport("event_sink", event_sink);
    lifecycle.addImport("event_pump", event_pump);
    const agent = b.createModule(.{
        .root_source_file = b.path("../../src/agent.zig"),
        .target = target,
        .optimize = optimize,
    });
    agent.addImport("agent_session", lifecycle);
    const executor = b.createModule(.{
        .root_source_file = b.path("../../src/workbench/executor.zig"),
        .target = target,
        .optimize = optimize,
    });
    executor.addImport("metawork_agent", agent);
    const workbench = b.createModule(.{
        .root_source_file = b.path("../../src/workbench/projection.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    workbench.addImport("metacodes_agentcore", sdk);
    workbench.addImport("metawork_agent", agent);
    const bridge_delivery = b.createModule(.{
        .root_source_file = b.path("../../src/bridge/delivery.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.createModule(.{
        .root_source_file = b.path("lifecycle_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    tests.addImport("metawork_agent", agent);
    tests.addImport("metawork_workbench", workbench);
    tests.addImport("event_pump", event_pump);
    tests.addImport("bridge_delivery", bridge_delivery);
    tests.addImport("metacodes_agentcore", sdk);
    tests.addImport("workbench_executor", executor);
    const test_artifact = b.addTest(.{
        .root_module = tests,
        .filters = if (test_filter) |filter| &.{filter} else &.{},
    });
    const run = b.addRunArtifact(test_artifact);
    const step = b.step("test", "Run deterministic Host lifecycle and security tests");
    step.dependOn(&run.step);
}
