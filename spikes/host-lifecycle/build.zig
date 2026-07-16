const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "tfilter", "Test name filter");
    const bundle_root = b.option([]const u8, "bundle-root", "Validated AgentCore bundle root") orelse
        @panic("-Dbundle-root is required");
    if (!std.fs.path.isAbsolute(bundle_root)) @panic("-Dbundle-root must be absolute");

    const sdk_path = b.pathJoin(&.{ bundle_root, "sdk", "metacodes_agentcore.zig" });
    const types_path = b.pathJoin(&.{ bundle_root, "sdk", "metacodes_agentcore_types.zig" });
    const types = b.createModule(.{
        .root_source_file = .{ .cwd_relative = types_path },
        .target = target,
        .optimize = optimize,
    });
    const sdk = b.createModule(.{
        .root_source_file = .{ .cwd_relative = sdk_path },
        .target = target,
        .optimize = optimize,
    });
    sdk.addImport("metacodes_agentcore_types", types);

    const lifecycle = b.createModule(.{
        .root_source_file = b.path("../../src/host/lifecycle.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    lifecycle.addImport("metacodes_agentcore", sdk);

    const tests = b.createModule(.{
        .root_source_file = b.path("lifecycle_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    tests.addImport("host_lifecycle", lifecycle);
    tests.addImport("metacodes_agentcore", sdk);
    const test_artifact = b.addTest(.{
        .root_module = tests,
        .filters = if (test_filter) |filter| &.{filter} else &.{},
    });
    const run = b.addRunArtifact(test_artifact);
    const step = b.step("test", "Run deterministic Host lifecycle and security tests");
    step.dependOn(&run.step);
}
