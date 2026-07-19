const std = @import("std");

const ManifestFile = struct {
    path: []const u8,
    sha256: []const u8,
};

const Manifest = struct {
    schema_version: u32,
    name: []const u8,
    version: []const u8,
    source: struct {
        commit: []const u8,
        dirty: bool,
        dirty_source_sha256: []const u8,
    },
    toolchain: struct { zig_version: []const u8 },
    build: struct {
        resolved_target: []const u8,
        architecture: []const u8,
        os: []const u8,
        abi: []const u8,
        optimize: []const u8,
        strip: bool,
    },
    contract: struct {
        binary_abi_version: u32,
        required_system_link_inputs: []const []const u8,
        ui_request_mode: []const u8,
    },
    files: []const ManifestFile,
};

const bundle_file_paths = [_][]const u8{
    "lib/libmetacodes_agentcore.a",
    "include/metacodes_agentcore.h",
    "sdk/metacodes_agentcore.zig",
    "sdk/metacodes_agentcore_protocol.zig",
    "sdk/metacodes_agentcore_types.zig",
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
        .{ .ignore_unknown_fields = false },
    ) catch @panic("invalid AgentCore manifest.json");
    const manifest = parsed.value;

    if (manifest.schema_version != 1 or
        !std.mem.eql(u8, manifest.name, "metacodes-agentcore") or
        manifest.source.commit.len != 40 or manifest.source.dirty)
        @panic("unsupported AgentCore bundle identity");
    if (!std.mem.eql(u8, manifest.toolchain.zig_version, builtin.zig_version_string))
        @panic("AgentCore bundle and consumer Zig versions differ");
    if (manifest.contract.binary_abi_version != 1 or
        !std.mem.eql(u8, manifest.contract.ui_request_mode, "synchronous"))
        @panic("unsupported AgentCore contract");
    if (!std.mem.eql(u8, manifest.build.os, "macos") or
        !std.mem.eql(u8, manifest.build.abi, "none") or
        !std.mem.eql(u8, manifest.build.optimize, "ReleaseSafe") or
        !manifest.build.strip)
        @panic("unsupported AgentCore build identity");
    const resolved_target = target.result.zigTriple(b.allocator) catch @panic("OOM");
    if (!std.mem.eql(u8, resolved_target, manifest.build.resolved_target))
        @panic("consumer target does not match AgentCore bundle target");

    validateManifestFiles(manifest.files);
    verifySha256(b, lib_path, checksumFor(manifest.files, bundle_file_paths[0]));
    verifySha256(b, header_path, checksumFor(manifest.files, bundle_file_paths[1]));
    verifySha256(b, sdk_path, checksumFor(manifest.files, bundle_file_paths[2]));
    verifySha256(b, protocol_path, checksumFor(manifest.files, bundle_file_paths[3]));
    verifySha256(b, types_path, checksumFor(manifest.files, bundle_file_paths[4]));

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

    const probe_module = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = link_libc,
    });
    probe_module.addImport("metacodes_agentcore", sdk);
    const event_sink = b.createModule(.{
        .root_source_file = b.path("../../src/agent/event_sink.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = link_libc,
    });
    event_sink.addImport("metacodes_agentcore", sdk);
    const event_pump = b.createModule(.{
        .root_source_file = b.path("../../src/agent/event_pump.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = link_libc,
    });
    event_pump.addImport("metacodes_agentcore", sdk);
    event_pump.addImport("event_sink", event_sink);
    const agent_session = b.createModule(.{
        .root_source_file = b.path("../../src/agent/session.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = link_libc,
    });
    agent_session.addImport("metacodes_agentcore", sdk);
    agent_session.addImport("event_pump", event_pump);
    const agent = b.createModule(.{
        .root_source_file = b.path("../../src/agent.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = link_libc,
    });
    agent.addImport("agent_session", agent_session);
    const executor = b.createModule(.{
        .root_source_file = b.path("../../src/workbench/executor.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = link_libc,
    });
    probe_module.addImport("metawork_agent", agent);
    probe_module.addImport("workbench_executor", executor);
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

fn validateManifestFiles(files: []const ManifestFile) void {
    if (files.len != bundle_file_paths.len)
        @panic("AgentCore manifest file set is incomplete or contains unknown files");
    var seen: [bundle_file_paths.len]bool = @splat(false);
    for (files) |file| {
        const index = for (bundle_file_paths, 0..) |expected, i| {
            if (std.mem.eql(u8, file.path, expected)) break i;
        } else @panic("AgentCore manifest contains an unknown file");
        if (seen[index]) @panic("AgentCore manifest contains a duplicate file");
        seen[index] = true;
    }
}

fn checksumFor(files: []const ManifestFile, path: []const u8) []const u8 {
    for (files) |file| if (std.mem.eql(u8, file.path, path)) return file.sha256;
    @panic("AgentCore manifest file is missing");
}

const builtin = @import("builtin");
