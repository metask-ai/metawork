const std = @import("std");

const ManifestFile = struct {
    path: []const u8,
    sha256: []const u8,
};

const Manifest = struct {
    schema_version: u32,
    vendor: []const u8,
    name: []const u8,
    version: []const u8,
    source: struct {
        commit: []const u8,
        dirty: bool,
    },
    toolchain: struct { zig_version: []const u8 },
    target: struct {
        id: []const u8,
        architecture: []const u8,
        os: []const u8,
        abi: []const u8,
        zig_target: []const u8,
        rust_target: []const u8,
    },
    build: struct {
        optimize: []const u8,
        strip: bool,
    },
    link: struct {
        requires_c_runtime: bool,
        system_libraries: []const []const u8,
        system_frameworks: []const []const u8,
    },
    contract: struct {
        binary_abi_status: []const u8,
        binary_abi_version: u32,
        binary_abi_revision: u32,
    },
    files: []const ManifestFile,
};

pub const Bundle = struct {
    deployment_target: std.SemanticVersion,
    link_libc: bool,
};

pub fn verify(b: *std.Build, root: []const u8) Bundle {
    if (!std.fs.path.isAbsolute(root)) @panic("AgentCore bundle root must be absolute");
    const lock_path = "spikes/agentcore-contract/bundle.lock.json";
    const lock_bytes = readFile(b, lock_path, 1024 * 1024, "cannot read AgentCore bundle lock");
    const manifest_path = b.pathJoin(&.{ root, "manifest.json" });
    const manifest_bytes = readFile(b, manifest_path, 1024 * 1024, "cannot read AgentCore bundle manifest");
    if (!std.mem.eql(u8, lock_bytes, manifest_bytes))
        @panic("AgentCore manifest bytes do not match the repository lock");
    const lock = parseManifest(b, lock_bytes);

    if (lock.schema_version != 1 or
        !std.mem.eql(u8, lock.vendor, "metask") or
        !std.mem.eql(u8, lock.name, "agentcore") or
        lock.source.commit.len != 40 or
        !lock.source.dirty or
        !std.mem.eql(u8, lock.toolchain.zig_version, @import("builtin").zig_version_string) or
        lock.contract.binary_abi_version != 1 or
        lock.contract.binary_abi_revision != 3 or
        !std.mem.eql(u8, lock.contract.binary_abi_status, "experimental"))
        @panic("unsupported locked AgentCore bundle contract");
    if (!std.mem.eql(u8, lock.target.id, "aarch64-macos") or
        !std.mem.eql(u8, lock.target.os, "macos") or
        !std.mem.eql(u8, lock.target.architecture, "aarch64") or
        !std.mem.eql(u8, lock.target.abi, "none") or
        !std.mem.eql(u8, lock.target.rust_target, "aarch64-apple-darwin") or
        !std.mem.eql(u8, lock.build.optimize, "ReleaseSafe") or
        !lock.build.strip)
        @panic("unsupported locked AgentCore build identity");
    if (!lock.link.requires_c_runtime or
        lock.link.system_libraries.len != 0 or
        lock.link.system_frameworks.len != 0)
        @panic("unsupported AgentCore system link inputs");
    if (lock.files.len == 0 or lock.files.len > 256)
        @panic("AgentCore manifest file count is out of bounds");

    for (lock.files) |file| {
        verifyPayloadPath(file.path);
        verifySha256(b, b.pathJoin(&.{ root, file.path }), file.sha256);
    }

    return .{
        .deployment_target = deploymentTargetFromZigTarget(
            b,
            lock.target.zig_target,
            lock.target.architecture,
        ),
        .link_libc = lock.link.requires_c_runtime,
    };
}

fn readFile(
    b: *std.Build,
    path: []const u8,
    limit: usize,
    comptime message: []const u8,
) []const u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        b.graph.io,
        path,
        b.allocator,
        .limited(limit),
    ) catch @panic(message);
}

fn parseManifest(b: *std.Build, bytes: []const u8) Manifest {
    return (std.json.parseFromSlice(
        Manifest,
        b.allocator,
        bytes,
        .{
            .ignore_unknown_fields = false,
            .duplicate_field_behavior = .@"error",
        },
    ) catch @panic("invalid AgentCore manifest JSON")).value;
}

fn verifyPayloadPath(path: []const u8) void {
    if (path.len == 0 or path.len > 1024 or
        std.fs.path.isAbsolute(path) or
        std.mem.indexOfScalar(u8, path, '\\') != null or
        std.mem.indexOfScalar(u8, path, 0) != null or
        std.mem.eql(u8, path, "manifest.json"))
        @panic("unsafe AgentCore manifest payload path");
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (component.len == 0 or
            std.mem.eql(u8, component, ".") or
            std.mem.eql(u8, component, ".."))
            @panic("unsafe AgentCore manifest payload path");
        for (component) |byte| {
            if (!std.ascii.isAlphanumeric(byte) and
                byte != '.' and byte != '_' and byte != '-')
                @panic("unsupported AgentCore manifest payload path character");
        }
    }
}

fn deploymentTargetFromZigTarget(
    b: *std.Build,
    zig_target: []const u8,
    architecture: []const u8,
) std.SemanticVersion {
    const prefix = b.fmt("{s}-macos.", .{architecture});
    if (!std.mem.startsWith(u8, zig_target, prefix) or
        !std.mem.endsWith(u8, zig_target, "-none"))
        @panic("invalid AgentCore resolved macOS target");
    const range_start = std.mem.indexOfPos(u8, zig_target, prefix.len, "...") orelse
        @panic("AgentCore resolved target is missing its supported OS range");
    const minimum = zig_target[prefix.len..range_start];
    const semantic = if (std.mem.count(u8, minimum, ".") == 1)
        b.fmt("{s}.0", .{minimum})
    else
        minimum;
    return std.SemanticVersion.parse(semantic) catch
        @panic("invalid AgentCore resolved macOS deployment target");
}

fn verifySha256(b: *std.Build, path: []const u8, expected: []const u8) void {
    if (expected.len != 64) @panic("invalid AgentCore manifest SHA-256");
    const bytes = readFile(b, path, 128 * 1024 * 1024, "cannot read AgentCore bundle file");
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const actual = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &actual, expected))
        @panic("AgentCore bundle SHA-256 mismatch");
}
