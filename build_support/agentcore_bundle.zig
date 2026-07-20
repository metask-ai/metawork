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
        binary_abi_revision: u32,
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
        lock.contract.binary_abi_revision != 2 or
        !std.mem.eql(u8, lock.contract.ui_request_mode, "synchronous") or
        !std.mem.eql(u8, lock.toolchain.zig_version, @import("builtin").zig_version_string))
        @panic("unsupported locked AgentCore bundle contract");
    if (!std.mem.eql(u8, lock.build.os, "macos") or
        !std.mem.eql(u8, lock.build.architecture, "aarch64") or
        !std.mem.eql(u8, lock.build.abi, "none") or
        !std.mem.eql(u8, lock.build.optimize, "ReleaseSafe") or
        !lock.build.strip)
        @panic("unsupported locked AgentCore build identity");

    var link_libc = false;
    for (lock.contract.required_system_link_inputs) |input| {
        if (std.mem.eql(u8, input, "libc")) {
            link_libc = true;
        } else @panic("unsupported AgentCore system link input");
    }

    validateManifestFiles(lock.files);
    for (bundle_file_paths) |path|
        verifySha256(b, b.pathJoin(&.{ root, path }), checksumFor(lock.files, path));

    const deployment_target = deploymentTargetFromResolvedTarget(
        b,
        lock.build.resolved_target,
        lock.build.architecture,
    );
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
        !std.mem.eql(u8, expected.source.commit, actual.source.commit) or
        expected.source.dirty != actual.source.dirty or
        !std.mem.eql(u8, expected.source.dirty_source_sha256, actual.source.dirty_source_sha256) or
        !std.mem.eql(u8, expected.toolchain.zig_version, actual.toolchain.zig_version) or
        !std.mem.eql(u8, expected.build.resolved_target, actual.build.resolved_target) or
        !std.mem.eql(u8, expected.build.architecture, actual.build.architecture) or
        !std.mem.eql(u8, expected.build.os, actual.build.os) or
        !std.mem.eql(u8, expected.build.abi, actual.build.abi) or
        !std.mem.eql(u8, expected.build.optimize, actual.build.optimize) or
        expected.build.strip != actual.build.strip or
        expected.contract.binary_abi_version != actual.contract.binary_abi_version or
        expected.contract.binary_abi_revision != actual.contract.binary_abi_revision or
        !stringListsEqual(expected.contract.required_system_link_inputs, actual.contract.required_system_link_inputs) or
        !std.mem.eql(u8, expected.contract.ui_request_mode, actual.contract.ui_request_mode) or
        !manifestFilesEqual(expected.files, actual.files))
        @panic("AgentCore manifest does not match the repository lock");
}

fn manifestFilesEqual(left: []const ManifestFile, right: []const ManifestFile) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| {
        if (!std.mem.eql(u8, a.path, b.path) or !std.mem.eql(u8, a.sha256, b.sha256))
            return false;
    }
    return true;
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

fn deploymentTargetFromResolvedTarget(
    b: *std.Build,
    resolved_target: []const u8,
    architecture: []const u8,
) std.SemanticVersion {
    const prefix = b.fmt("{s}-macos.", .{architecture});
    if (!std.mem.startsWith(u8, resolved_target, prefix) or
        !std.mem.endsWith(u8, resolved_target, "-none"))
        @panic("invalid AgentCore resolved macOS target");
    const range_start = std.mem.indexOfPos(u8, resolved_target, prefix.len, "...") orelse
        @panic("AgentCore resolved target is missing its supported OS range");
    const minimum = resolved_target[prefix.len..range_start];
    const semantic = if (std.mem.count(u8, minimum, ".") == 1)
        b.fmt("{s}.0", .{minimum})
    else
        minimum;
    return std.SemanticVersion.parse(semantic) catch
        @panic("invalid AgentCore resolved macOS deployment target");
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
