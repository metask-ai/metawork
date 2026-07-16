const std = @import("std");

const Manifest = struct {
    toolchain: struct { zig_version: []const u8 },
    build: struct {
        architecture: []const u8,
        os: []const u8,
        macos_deployment_target: []const u8,
    },
    contract: struct {
        binary_abi_version: u32,
        required_system_link_inputs: []const []const u8,
        ui_request_mode: []const u8,
    },
    files: struct {
        @"lib/libmetacodes_agentcore.a": struct { sha256: []const u8 },
        @"include/metacodes_agentcore.h": struct { sha256: []const u8 },
        @"sdk/metacodes_agentcore.zig": struct { sha256: []const u8 },
        @"sdk/metacodes_agentcore_protocol.zig": struct { sha256: []const u8 },
        @"sdk/metacodes_agentcore_types.zig": struct { sha256: []const u8 },
    },
};

fn verifySha256(b: *std.Build, file_path: []const u8, expected: []const u8) void {
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        b.graph.io,
        file_path,
        b.allocator,
        .limited(128 * 1024 * 1024),
    ) catch @panic("cannot read AgentCore bundle file");
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const actual = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &actual, expected)) @panic("AgentCore bundle SHA-256 mismatch");
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const bundle_root = b.option([]const u8, "bundle-root", "Installed AgentCore bundle root") orelse
        @panic("-Dbundle-root is required");
    if (!std.fs.path.isAbsolute(bundle_root)) @panic("-Dbundle-root must be absolute");

    const lib_path = b.pathJoin(&.{ bundle_root, "lib", "libmetacodes_agentcore.a" });
    const header_path = b.pathJoin(&.{ bundle_root, "include", "metacodes_agentcore.h" });
    const sdk_path = b.pathJoin(&.{ bundle_root, "sdk", "metacodes_agentcore.zig" });
    const protocol_path = b.pathJoin(&.{ bundle_root, "sdk", "metacodes_agentcore_protocol.zig" });
    const types_path = b.pathJoin(&.{ bundle_root, "sdk", "metacodes_agentcore_types.zig" });
    const manifest_path = b.pathJoin(&.{ bundle_root, "manifest.json" });
    const manifest_bytes = std.Io.Dir.cwd().readFileAlloc(
        b.graph.io,
        manifest_path,
        b.allocator,
        .limited(1024 * 1024),
    ) catch @panic("cannot read AgentCore manifest.json");
    const parsed = std.json.parseFromSlice(
        Manifest,
        b.allocator,
        manifest_bytes,
        .{ .ignore_unknown_fields = true },
    ) catch @panic("invalid AgentCore manifest.json");
    const manifest = parsed.value;

    if (!std.mem.eql(u8, manifest.toolchain.zig_version, builtin.zig_version_string))
        @panic("AgentCore bundle and consumer Zig versions differ");
    if (manifest.contract.binary_abi_version != 1 or
        !std.mem.eql(u8, manifest.contract.ui_request_mode, "synchronous"))
        @panic("unsupported AgentCore contract");
    const resolved_target = target.result.zigTriple(b.allocator) catch @panic("OOM");
    const expected_prefix = b.fmt("{s}-macos.{s}", .{
        manifest.build.architecture,
        manifest.build.macos_deployment_target,
    });
    if (!std.mem.eql(u8, manifest.build.os, "macos") or
        !std.mem.startsWith(u8, resolved_target, expected_prefix))
        @panic("consumer target does not match AgentCore bundle target");

    verifySha256(b, lib_path, manifest.files.@"lib/libmetacodes_agentcore.a".sha256);
    verifySha256(b, header_path, manifest.files.@"include/metacodes_agentcore.h".sha256);
    verifySha256(b, sdk_path, manifest.files.@"sdk/metacodes_agentcore.zig".sha256);
    verifySha256(b, protocol_path, manifest.files.@"sdk/metacodes_agentcore_protocol.zig".sha256);
    verifySha256(b, types_path, manifest.files.@"sdk/metacodes_agentcore_types.zig".sha256);

    var link_libc = false;
    for (manifest.contract.required_system_link_inputs) |input| {
        if (std.mem.eql(u8, input, "libc")) {
            link_libc = true;
        } else {
            @panic("unsupported AgentCore system link input");
        }
    }

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

    const probe_module = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = link_libc,
    });
    probe_module.addImport("metacodes_agentcore", sdk);
    const event_sink = b.createModule(.{
        .root_source_file = b.path("../../src/host/event_sink.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = link_libc,
    });
    event_sink.addImport("metacodes_agentcore", sdk);
    const event_pump = b.createModule(.{
        .root_source_file = b.path("../../src/host/event_pump.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = link_libc,
    });
    event_pump.addImport("metacodes_agentcore", sdk);
    event_pump.addImport("event_sink", event_sink);
    const host_lifecycle = b.createModule(.{
        .root_source_file = b.path("../../src/host/lifecycle.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = link_libc,
    });
    host_lifecycle.addImport("metacodes_agentcore", sdk);
    host_lifecycle.addImport("event_pump", event_pump);
    probe_module.addImport("host_lifecycle", host_lifecycle);
    probe_module.addObjectFile(.{ .cwd_relative = lib_path });
    const probe = b.addExecutable(.{
        .name = "metawork-agentcore-contract-probe",
        .root_module = probe_module,
    });
    const run_probe = b.addRunArtifact(probe);

    const header_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = link_libc,
    });
    header_module.addCSourceFile(.{
        .file = b.path("header_smoke.c"),
        .flags = &.{"-std=c11"},
    });
    header_module.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ bundle_root, "include" }) });
    header_module.addObjectFile(.{ .cwd_relative = lib_path });
    const header_probe = b.addExecutable(.{
        .name = "metawork-agentcore-header-probe",
        .root_module = header_module,
    });
    const run_header_probe = b.addRunArtifact(header_probe);

    const test_step = b.step("test", "Run the isolated source-free AgentCore contract probe");
    test_step.dependOn(&run_probe.step);
    test_step.dependOn(&run_header_probe.step);
}

const builtin = @import("builtin");
