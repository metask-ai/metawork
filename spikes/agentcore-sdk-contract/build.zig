const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const bundle_root = b.option([]const u8, "bundle-root", "Validated AgentCore bundle root") orelse
        @panic("-Dbundle-root is required");
    if (!std.fs.path.isAbsolute(bundle_root)) @panic("-Dbundle-root must be absolute");

    const sdk_path = b.pathJoin(&.{ bundle_root, "sdk", "metacodes_agentcore.zig" });
    const types_path = b.pathJoin(&.{ bundle_root, "sdk", "metacodes_agentcore_types.zig" });
    const library_path = b.pathJoin(&.{ bundle_root, "lib", "libmetacodes_agentcore.a" });

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

    const tests = b.createModule(.{
        .root_source_file = b.path("sdk_contract_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    tests.addImport("metacodes_agentcore", sdk);
    tests.addObjectFile(.{ .cwd_relative = library_path });

    const artifact = b.addTest(.{ .root_module = tests });
    const run = b.addRunArtifact(artifact);
    const step = b.step("test", "Run source-free AgentCore typed SDK contract tests");
    step.dependOn(&run.step);
}
