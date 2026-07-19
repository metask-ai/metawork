const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "tfilter", "Test name filter");
    const bundle_root = b.option([]const u8, "bundle-root", "Validated AgentCore bundle root") orelse
        @panic("-Dbundle-root is required");
    if (!std.fs.path.isAbsolute(bundle_root)) @panic("-Dbundle-root must be absolute");

    const types = b.createModule(.{
        .root_source_file = .{ .cwd_relative = b.pathJoin(&.{ bundle_root, "sdk", "metacodes_agentcore_types.zig" }) },
        .target = target,
        .optimize = optimize,
    });
    const protocol = b.createModule(.{
        .root_source_file = .{ .cwd_relative = b.pathJoin(&.{ bundle_root, "sdk", "metacodes_agentcore_protocol.zig" }) },
        .target = target,
        .optimize = optimize,
    });
    const sdk = b.createModule(.{
        .root_source_file = .{ .cwd_relative = b.pathJoin(&.{ bundle_root, "sdk", "metacodes_agentcore.zig" }) },
        .target = target,
        .optimize = optimize,
    });
    sdk.addImport("metacodes_agentcore_types", types);
    sdk.addImport("metacodes_agentcore_protocol", protocol);

    const event_sink = b.createModule(.{
        .root_source_file = b.path("../src/agent/event_sink.zig"),
        .target = target,
        .optimize = optimize,
    });
    event_sink.addImport("metacodes_agentcore", sdk);
    const event_pump = b.createModule(.{
        .root_source_file = b.path("../src/agent/event_pump.zig"),
        .target = target,
        .optimize = optimize,
    });
    event_pump.addImport("metacodes_agentcore", sdk);
    event_pump.addImport("event_sink", event_sink);
    const session = b.createModule(.{
        .root_source_file = b.path("../src/agent/session.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    session.addImport("metacodes_agentcore", sdk);
    session.addImport("event_pump", event_pump);
    const agent = b.createModule(.{
        .root_source_file = b.path("../src/agent.zig"),
        .target = target,
        .optimize = optimize,
    });
    agent.addImport("agent_session", session);

    const executor = b.createModule(.{
        .root_source_file = b.path("../src/workbench/executor.zig"),
        .target = target,
        .optimize = optimize,
    });
    const workbench = b.createModule(.{
        .root_source_file = b.path("../src/workbench/projection.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    workbench.addImport("metawork_agent", agent);
    workbench.addImport("workbench_executor", executor);
    const contract_fixture = b.addOptions();
    contract_fixture.addOption([]const u8, "snapshot", "");
    workbench.addOptions("workbench_contract_fixture", contract_fixture);

    const automation_delivery = b.createModule(.{
        .root_source_file = b.path("../src/automation/delivery.zig"),
        .target = target,
        .optimize = optimize,
    });
    const fixture = b.createModule(.{
        .root_source_file = b.path("support/lifecycle_fixture.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    fixture.addImport("metawork_agent", agent);
    fixture.addImport("metawork_workbench", workbench);
    fixture.addImport("event_pump", event_pump);
    fixture.addImport("automation_delivery", automation_delivery);
    fixture.addImport("metacodes_agentcore", sdk);
    fixture.addImport("workbench_executor", executor);

    const step = b.step("test", "Run invariant-grouped lifecycle tests");
    const roots = [_][]const u8{
        "agent/lifecycle_test.zig",
        "agent/event_pump_test.zig",
        "workbench/executor_lifecycle_test.zig",
        "bridge/automation_delivery_test.zig",
        "integration/lifecycle/lifecycle_test.zig",
    };
    for (roots) |root| {
        const cases = b.createModule(.{
            .root_source_file = b.path(root),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        cases.addImport("lifecycle_fixture", fixture);
        const artifact = b.addTest(.{
            .root_module = cases,
            .filters = if (test_filter) |filter| &.{filter} else &.{},
        });
        step.dependOn(&b.addRunArtifact(artifact).step);
    }

    const source_tests = b.addTest(.{
        .root_module = workbench,
        .filters = if (test_filter) |filter|
            &.{filter}
        else
            &.{ "terminal publication", "Workbench outcomes", "Agent terminal facts" },
    });
    step.dependOn(&b.addRunArtifact(source_tests).step);
}
