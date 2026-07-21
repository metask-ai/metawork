const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const bundle_root = b.option([]const u8, "bundle-root", "Validated AgentCore bundle root") orelse
        @panic("-Dbundle-root is required");
    if (!std.fs.path.isAbsolute(bundle_root)) @panic("-Dbundle-root must be absolute");

    const module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addCSourceFile(.{
        .file = b.path("header_smoke.c"),
        .flags = &.{"-std=c11"},
    });
    module.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ bundle_root, "include" }) });
    const library_file = if (target.result.os.tag == .windows)
        "metask_agentcore.lib"
    else
        "libmetask_agentcore.a";
    module.addObjectFile(.{
        .cwd_relative = b.pathJoin(&.{ bundle_root, "lib", library_file }),
    });
    if (target.result.os.tag == .windows) {
        module.linkSystemLibrary("advapi32", .{ .use_pkg_config = .no });
        module.linkSystemLibrary("crypt32", .{ .use_pkg_config = .no });
    }
    const probe = b.addExecutable(.{
        .name = "metawork-agentcore-header-probe",
        .root_module = module,
    });
    const step = b.step("test", "Run the isolated raw C AgentCore contract probe");
    step.dependOn(&b.addRunArtifact(probe).step);
}
