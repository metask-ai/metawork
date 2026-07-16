const std = @import("std");

const Manifest = struct {
    schema_version: u32,
    name: []const u8,
    version: []const u8,
    source: struct {
        cc_zig_commit: []const u8,
        dirty: bool,
        dirty_source_sha256: []const u8,
    },
    toolchain: struct { zig_version: []const u8 },
    build: struct {
        resolved_target: []const u8,
        architecture: []const u8,
        os: []const u8,
        macos_deployment_target: []const u8,
        optimize: []const u8,
        strip: bool,
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

pub const Bundle = struct {
    root: []const u8,
    library_path: []const u8,
    sdk_path: []const u8,
    protocol_path: []const u8,
    types_path: []const u8,
    deployment_target: std.SemanticVersion,
    link_libc: bool,
};

pub fn verify(b: *std.Build, root: []const u8) Bundle {
    if (!std.fs.path.isAbsolute(root)) @panic("AgentCore bundle root must be absolute");
    verifyLayout(b, root);
    const lock_path = "spikes/agentcore-contract/bundle.lock.json";
    const lock = readManifest(b, lock_path, "cannot read AgentCore bundle lock");
    const manifest_path = b.pathJoin(&.{ root, "manifest.json" });
    const actual = readManifest(b, manifest_path, "cannot read AgentCore bundle manifest");
    requireSameManifest(lock, actual);

    if (lock.schema_version != 1 or !std.mem.eql(u8, lock.name, "metacodes-agentcore") or
        lock.source.dirty or lock.contract.binary_abi_version != 1 or
        !std.mem.eql(u8, lock.contract.ui_request_mode, "synchronous") or
        !std.mem.eql(u8, lock.toolchain.zig_version, @import("builtin").zig_version_string))
        @panic("unsupported locked AgentCore bundle contract");
    if (!std.mem.eql(u8, lock.build.os, "macos") or
        !std.mem.eql(u8, lock.build.architecture, "aarch64") or
        !std.mem.eql(u8, lock.build.optimize, "ReleaseSafe") or
        !lock.build.strip)
        @panic("unsupported locked AgentCore build identity");

    var link_libc = false;
    for (lock.contract.required_system_link_inputs) |input| {
        if (std.mem.eql(u8, input, "libc")) {
            link_libc = true;
        } else @panic("unsupported AgentCore system link input");
    }

    const files = [_]struct { path: []const u8, sha256: []const u8 }{
        .{ .path = "lib/libmetacodes_agentcore.a", .sha256 = lock.files.@"lib/libmetacodes_agentcore.a".sha256 },
        .{ .path = "include/metacodes_agentcore.h", .sha256 = lock.files.@"include/metacodes_agentcore.h".sha256 },
        .{ .path = "sdk/metacodes_agentcore.zig", .sha256 = lock.files.@"sdk/metacodes_agentcore.zig".sha256 },
        .{ .path = "sdk/metacodes_agentcore_protocol.zig", .sha256 = lock.files.@"sdk/metacodes_agentcore_protocol.zig".sha256 },
        .{ .path = "sdk/metacodes_agentcore_types.zig", .sha256 = lock.files.@"sdk/metacodes_agentcore_types.zig".sha256 },
    };
    for (files) |file| verifySha256(b, b.pathJoin(&.{ root, file.path }), file.sha256);

    const deployment_text = if (std.mem.count(u8, lock.build.macos_deployment_target, ".") == 1)
        b.fmt("{s}.0", .{lock.build.macos_deployment_target})
    else
        lock.build.macos_deployment_target;
    const deployment_target = std.SemanticVersion.parse(deployment_text) catch
        @panic("invalid AgentCore macOS deployment target");
    return .{
        .root = root,
        .library_path = b.pathJoin(&.{ root, "lib", "libmetacodes_agentcore.a" }),
        .sdk_path = b.pathJoin(&.{ root, "sdk", "metacodes_agentcore.zig" }),
        .protocol_path = b.pathJoin(&.{ root, "sdk", "metacodes_agentcore_protocol.zig" }),
        .types_path = b.pathJoin(&.{ root, "sdk", "metacodes_agentcore_types.zig" }),
        .deployment_target = deployment_target,
        .link_libc = link_libc,
    };
}

const ExpectedEntry = struct { name: []const u8, kind: std.Io.File.Kind };

fn verifyLayout(b: *std.Build, root: []const u8) void {
    verifyDirectoryEntries(b, root, &.{
        .{ .name = "include", .kind = .directory },
        .{ .name = "lib", .kind = .directory },
        .{ .name = "manifest.json", .kind = .file },
        .{ .name = "sdk", .kind = .directory },
    });
    verifyDirectoryEntries(b, b.pathJoin(&.{ root, "include" }), &.{
        .{ .name = "metacodes_agentcore.h", .kind = .file },
    });
    verifyDirectoryEntries(b, b.pathJoin(&.{ root, "lib" }), &.{
        .{ .name = "libmetacodes_agentcore.a", .kind = .file },
    });
    verifyDirectoryEntries(b, b.pathJoin(&.{ root, "sdk" }), &.{
        .{ .name = "metacodes_agentcore.zig", .kind = .file },
        .{ .name = "metacodes_agentcore_protocol.zig", .kind = .file },
        .{ .name = "metacodes_agentcore_types.zig", .kind = .file },
    });
}

fn verifyDirectoryEntries(b: *std.Build, path: []const u8, expected: []const ExpectedEntry) void {
    var directory = std.Io.Dir.openDirAbsolute(b.graph.io, path, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch @panic("invalid AgentCore bundle directory");
    defer directory.close(b.graph.io);
    var seen: usize = 0;
    var iterator = directory.iterate();
    while (iterator.next(b.graph.io) catch @panic("cannot enumerate AgentCore bundle")) |entry| {
        const required = for (expected) |candidate| {
            if (std.mem.eql(u8, entry.name, candidate.name)) break candidate;
        } else @panic("unexpected AgentCore bundle filesystem entry");
        if (entry.kind != required.kind) @panic("AgentCore bundle entry has invalid file type");
        seen += 1;
    }
    if (seen != expected.len) @panic("AgentCore bundle filesystem entry is missing");
}

fn readManifest(b: *std.Build, path: []const u8, comptime message: []const u8) Manifest {
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        b.graph.io,
        path,
        b.allocator,
        .limited(1024 * 1024),
    ) catch @panic(message);
    return (std.json.parseFromSlice(
        Manifest,
        b.allocator,
        bytes,
        .{ .ignore_unknown_fields = false },
    ) catch @panic("invalid AgentCore manifest JSON")).value;
}

fn requireSameManifest(expected: Manifest, actual: Manifest) void {
    if (expected.schema_version != actual.schema_version or
        !std.mem.eql(u8, expected.name, actual.name) or
        !std.mem.eql(u8, expected.version, actual.version) or
        !std.mem.eql(u8, expected.source.cc_zig_commit, actual.source.cc_zig_commit) or
        expected.source.dirty != actual.source.dirty or
        !std.mem.eql(u8, expected.source.dirty_source_sha256, actual.source.dirty_source_sha256) or
        !std.mem.eql(u8, expected.toolchain.zig_version, actual.toolchain.zig_version) or
        !std.mem.eql(u8, expected.build.resolved_target, actual.build.resolved_target) or
        !std.mem.eql(u8, expected.build.architecture, actual.build.architecture) or
        !std.mem.eql(u8, expected.build.os, actual.build.os) or
        !std.mem.eql(u8, expected.build.macos_deployment_target, actual.build.macos_deployment_target) or
        !std.mem.eql(u8, expected.build.optimize, actual.build.optimize) or
        expected.build.strip != actual.build.strip or
        expected.contract.binary_abi_version != actual.contract.binary_abi_version or
        !stringListsEqual(expected.contract.required_system_link_inputs, actual.contract.required_system_link_inputs) or
        !std.mem.eql(u8, expected.contract.ui_request_mode, actual.contract.ui_request_mode) or
        !std.mem.eql(u8, expected.files.@"lib/libmetacodes_agentcore.a".sha256, actual.files.@"lib/libmetacodes_agentcore.a".sha256) or
        !std.mem.eql(u8, expected.files.@"include/metacodes_agentcore.h".sha256, actual.files.@"include/metacodes_agentcore.h".sha256) or
        !std.mem.eql(u8, expected.files.@"sdk/metacodes_agentcore.zig".sha256, actual.files.@"sdk/metacodes_agentcore.zig".sha256) or
        !std.mem.eql(u8, expected.files.@"sdk/metacodes_agentcore_protocol.zig".sha256, actual.files.@"sdk/metacodes_agentcore_protocol.zig".sha256) or
        !std.mem.eql(u8, expected.files.@"sdk/metacodes_agentcore_types.zig".sha256, actual.files.@"sdk/metacodes_agentcore_types.zig".sha256))
        @panic("AgentCore manifest does not match the repository lock");
}

fn stringListsEqual(left: []const []const u8, right: []const []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| if (!std.mem.eql(u8, a, b)) return false;
    return true;
}

fn verifySha256(b: *std.Build, path: []const u8, expected: []const u8) void {
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        b.graph.io,
        path,
        b.allocator,
        .limited(128 * 1024 * 1024),
    ) catch @panic("cannot read AgentCore bundle file");
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const actual = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &actual, expected)) @panic("AgentCore bundle SHA-256 mismatch");
}
