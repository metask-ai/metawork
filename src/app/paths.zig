const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const native_sdk = @import("native_sdk");
const product_identity = @import("metawork_product_identity");

const path_capacity = 4096;
const windows_data_directory_name = "MetaWork";
const automation_data_directory_name = "MetaWork Automation";

// Paths owns the backing storage for every returned slice. Keep this value at
// one stable address for its full lifetime and pass it only by pointer.
pub const Paths = struct {
    allocator: std.mem.Allocator = undefined,
    data_buffer: [path_capacity]u8 = undefined,
    automatic_workspace_buffer: [path_capacity]u8 = undefined,
    account_buffer: [path_capacity]u8 = undefined,
    workbench_buffer: [path_capacity]u8 = undefined,
    checkpoints_buffer: [path_capacity]u8 = undefined,
    skill_staging_buffer: [path_capacity]u8 = undefined,
    mcp_buffer: [path_capacity]u8 = undefined,
    data_len: usize = 0,
    automatic_workspace_len: ?usize = null,
    account_len: usize = 0,
    workbench_len: usize = 0,
    checkpoints_len: usize = 0,
    skill_staging_len: usize = 0,
    mcp_len: usize = 0,
    canonical_user_home: ?[]u8 = null,

    pub fn init(
        self: *Paths,
        io: std.Io,
        allocator: std.mem.Allocator,
        env_map: *std.process.Environ.Map,
        configured_user_home: ?[]const u8,
    ) !void {
        self.* = .{ .allocator = allocator };

        const data = try native_sdk.app_dirs.resolveOne(
            .{ .name = dataDirectoryName(builtin.os.tag) },
            native_sdk.app_dirs.currentPlatform(),
            native_sdk.debug.envFromMap(env_map),
            .data,
            &self.data_buffer,
        );
        self.data_len = data.len;

        const automatic_workspace = native_sdk.app_dirs.join(
            native_sdk.app_dirs.currentPlatform(),
            &self.automatic_workspace_buffer,
            &.{ self.dataDir(), "workspaces" },
        ) catch null;
        self.automatic_workspace_len = if (automatic_workspace) |value| value.len else null;

        self.account_len = (try native_sdk.app_dirs.join(
            native_sdk.app_dirs.currentPlatform(),
            &self.account_buffer,
            &.{ self.dataDir(), "account" },
        )).len;
        self.workbench_len = (try native_sdk.app_dirs.join(
            native_sdk.app_dirs.currentPlatform(),
            &self.workbench_buffer,
            &.{ self.dataDir(), "workbench" },
        )).len;
        self.checkpoints_len = (try native_sdk.app_dirs.join(
            native_sdk.app_dirs.currentPlatform(),
            &self.checkpoints_buffer,
            &.{ self.workbenchDir(), "checkpoints" },
        )).len;
        self.skill_staging_len = (try native_sdk.app_dirs.join(
            native_sdk.app_dirs.currentPlatform(),
            &self.skill_staging_buffer,
            &.{ self.workbenchDir(), "skill-staging" },
        )).len;
        self.mcp_len = (try native_sdk.app_dirs.join(
            native_sdk.app_dirs.currentPlatform(),
            &self.mcp_buffer,
            &.{ self.dataDir(), "mcp" },
        )).len;

        self.canonical_user_home = if (configured_user_home) |home|
            resolveCanonicalDirectory(io, allocator, home)
        else
            resolveCanonicalUserHome(io, allocator, env_map);
    }

    pub fn deinit(self: *Paths) void {
        if (self.canonical_user_home) |home| self.allocator.free(home);
        self.canonical_user_home = null;
    }

    pub fn dataDir(self: *const Paths) []const u8 {
        return self.data_buffer[0..self.data_len];
    }

    pub fn automaticWorkspaceDir(self: *const Paths) ?[]const u8 {
        const len = self.automatic_workspace_len orelse return null;
        return self.automatic_workspace_buffer[0..len];
    }

    pub fn accountDir(self: *const Paths) []const u8 {
        return self.account_buffer[0..self.account_len];
    }

    pub fn workbenchDir(self: *const Paths) []const u8 {
        return self.workbench_buffer[0..self.workbench_len];
    }

    pub fn skillStagingDir(self: *const Paths) []const u8 {
        return self.skill_staging_buffer[0..self.skill_staging_len];
    }

    pub fn checkpointsDir(self: *const Paths) []const u8 {
        return self.checkpoints_buffer[0..self.checkpoints_len];
    }

    pub fn mcpDir(self: *const Paths) []const u8 {
        return self.mcp_buffer[0..self.mcp_len];
    }
};

pub fn dataDirectoryName(os_tag: @TypeOf(builtin.os.tag)) []const u8 {
    if (build_options.automation) return automation_data_directory_name;
    return if (os_tag == .macos)
        product_identity.macos_data_directory_name
    else
        windows_data_directory_name;
}

fn resolveCanonicalUserHome(
    io: std.Io,
    allocator: std.mem.Allocator,
    env_map: *std.process.Environ.Map,
) ?[]u8 {
    const configured = switch (builtin.os.tag) {
        .windows => env_map.get("USERPROFILE"),
        else => env_map.get("HOME"),
    } orelse return null;
    return resolveCanonicalDirectory(io, allocator, configured);
}

fn resolveCanonicalDirectory(
    io: std.Io,
    allocator: std.mem.Allocator,
    configured: []const u8,
) ?[]u8 {
    if (configured.len == 0 or !std.fs.path.isAbsolute(configured) or
        !std.unicode.utf8ValidateSlice(configured))
        return null;
    const canonical = std.Io.Dir.realPathFileAbsoluteAlloc(
        io,
        configured,
        allocator,
    ) catch return null;
    const stat = std.Io.Dir.cwd().statFile(io, canonical, .{}) catch {
        allocator.free(canonical);
        return null;
    };
    if (stat.kind != .directory) {
        allocator.free(canonical);
        return null;
    }
    return canonical;
}

test "product and automation data roots are compile-time isolated" {
    try std.testing.expectEqualStrings(
        "com.metask.metawork.dev",
        product_identity.bundle_id,
    );
    if (build_options.automation) {
        try std.testing.expectEqualStrings(
            automation_data_directory_name,
            dataDirectoryName(.macos),
        );
        try std.testing.expectEqualStrings(
            automation_data_directory_name,
            dataDirectoryName(.windows),
        );
    } else {
        try std.testing.expectEqualStrings(
            product_identity.macos_data_directory_name,
            dataDirectoryName(.macos),
        );
        try std.testing.expectEqualStrings(
            windows_data_directory_name,
            dataDirectoryName(.windows),
        );
    }
}
