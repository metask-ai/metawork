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
    deployment_target: ?std.SemanticVersion,
    link_libc: bool,
};

pub fn verify(b: *std.Build, root: []const u8) Bundle {
    if (!std.fs.path.isAbsolute(root)) @panic("AgentCore bundle root must be absolute");
    const manifest_path = b.pathJoin(&.{ root, "manifest.json" });
    const manifest_bytes = readFile(b, manifest_path, 1024 * 1024, "cannot read AgentCore bundle manifest");
    const manifest = parseManifest(b, manifest_bytes);
    const lock_path = lockPathForTarget(manifest.target.id);
    const lock_bytes = readFile(b, lock_path, 1024 * 1024, "cannot read AgentCore bundle lock");
    if (!std.mem.eql(u8, lock_bytes, manifest_bytes))
        @panic("AgentCore manifest bytes do not match the repository lock");
    const lock = parseManifest(b, lock_bytes);

    if (lock.schema_version != 1 or
        !std.mem.eql(u8, lock.vendor, "metask") or
        !std.mem.eql(u8, lock.name, "agentcore") or
        lock.source.commit.len != 40 or
        !std.mem.eql(u8, lock.toolchain.zig_version, @import("builtin").zig_version_string) or
        lock.contract.binary_abi_version != 1 or
        lock.contract.binary_abi_revision != 4 or
        !std.mem.eql(u8, lock.contract.binary_abi_status, "experimental"))
        @panic("unsupported locked AgentCore bundle contract");
    if (!std.mem.eql(u8, lock.build.optimize, "ReleaseSafe") or !lock.build.strip)
        @panic("unsupported locked AgentCore build identity");
    const deployment_target = validateTarget(lock);
    if (lock.files.len == 0 or lock.files.len > 256)
        @panic("AgentCore manifest file count is out of bounds");

    for (lock.files) |file| {
        verifyPayloadPath(file.path);
        verifySha256(b, b.pathJoin(&.{ root, file.path }), file.sha256);
    }

    return .{
        .deployment_target = deployment_target,
        .link_libc = lock.link.requires_c_runtime,
    };
}

fn lockPathForTarget(target_id: []const u8) []const u8 {
    if (std.mem.eql(u8, target_id, "aarch64-macos"))
        return "build_support/agentcore-bundle.macos.lock.json";
    if (std.mem.eql(u8, target_id, "x86_64-windows-gnu"))
        return "build_support/agentcore-bundle.windows.lock.json";
    @panic("unsupported AgentCore bundle target");
}

fn validateTarget(manifest: Manifest) ?std.SemanticVersion {
    if (!manifest.link.requires_c_runtime or manifest.link.system_frameworks.len != 0)
        @panic("unsupported AgentCore system link inputs");
    if (std.mem.eql(u8, manifest.target.id, "aarch64-macos") and
        std.mem.eql(u8, manifest.target.os, "macos") and
        std.mem.eql(u8, manifest.target.architecture, "aarch64") and
        std.mem.eql(u8, manifest.target.abi, "none") and
        std.mem.eql(u8, manifest.target.rust_target, "aarch64-apple-darwin") and
        manifest.link.system_libraries.len == 0)
    {
        return deploymentTargetFromZigTarget(
            manifest.target.zig_target,
            manifest.target.architecture,
        );
    }
    if (std.mem.eql(u8, manifest.target.id, "x86_64-windows-gnu") and
        std.mem.eql(u8, manifest.target.os, "windows") and
        std.mem.eql(u8, manifest.target.architecture, "x86_64") and
        std.mem.eql(u8, manifest.target.abi, "gnu") and
        std.mem.eql(u8, manifest.target.rust_target, "x86_64-pc-windows-gnu") and
        std.mem.eql(u8, manifest.target.zig_target, "x86_64-windows.win10...win11_dt-gnu") and
        stringListsEqual(manifest.link.system_libraries, &.{ "advapi32", "crypt32" }))
    {
        return null;
    }
    @panic("unsupported locked AgentCore target identity");
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
    zig_target: []const u8,
    architecture: []const u8,
) std.SemanticVersion {
    var prefix_storage: [64]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_storage, "{s}-macos.", .{architecture}) catch
        @panic("AgentCore architecture is too long");
    if (!std.mem.startsWith(u8, zig_target, prefix) or
        !std.mem.endsWith(u8, zig_target, "-none"))
        @panic("invalid AgentCore resolved macOS target");
    const range_start = std.mem.indexOfPos(u8, zig_target, prefix.len, "...") orelse
        @panic("AgentCore resolved target is missing its supported OS range");
    const minimum = zig_target[prefix.len..range_start];
    var semantic_storage: [32]u8 = undefined;
    const semantic = if (std.mem.count(u8, minimum, ".") == 1)
        std.fmt.bufPrint(&semantic_storage, "{s}.0", .{minimum}) catch
            @panic("AgentCore deployment target is too long")
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
    if (expected.len != 64) @panic("invalid AgentCore manifest SHA-256");
    const bytes = readFile(b, path, 128 * 1024 * 1024, "cannot read AgentCore bundle file");
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const actual = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &actual, expected))
        @panic("AgentCore bundle SHA-256 mismatch");
}
