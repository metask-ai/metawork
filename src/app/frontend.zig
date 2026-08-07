const std = @import("std");
const native_sdk = @import("native_sdk");
const bridge_api = @import("metawork_bridge");

pub const url_env = "NATIVE_SDK_FRONTEND_URL";
pub const dist = "frontend/dist";
pub const entry = "index.html";
pub const Mode = bridge_api.policy.Mode;

pub fn source(
    env_map: *std.process.Environ.Map,
    asset_root: []const u8,
) !native_sdk.WebViewSource {
    return native_sdk.frontend.sourceFromEnv(env_map, .{
        .dist = asset_root,
        .entry = entry,
    });
}

pub fn mode(env_map: *std.process.Environ.Map) Mode {
    return if (env_map.get(url_env) != null) .development else .release;
}

pub fn resolveAssetRoot(
    io: std.Io,
    allocator: std.mem.Allocator,
) ![]u8 {
    const executable_dir = try std.process.executableDirPathAlloc(io, allocator);
    defer allocator.free(executable_dir);

    const candidates = [_][]const []const u8{
        &.{ executable_dir, "frontend", "dist" },
        &.{ executable_dir, "..", "resources", "frontend", "dist" },
        &.{ executable_dir, "..", "Resources", "frontend", "dist" },
        &.{ executable_dir, "..", "..", "frontend", "dist" },
    };
    for (candidates) |segments| {
        const candidate = try std.fs.path.resolve(allocator, segments);
        if (entryExists(io, allocator, candidate)) return candidate;
        allocator.free(candidate);
    }
    return error.FrontendAssetsNotFound;
}

fn entryExists(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
) bool {
    const entry_path = std.fs.path.join(allocator, &.{ root, entry }) catch return false;
    defer allocator.free(entry_path);
    var file = std.Io.Dir.cwd().openFile(io, entry_path, .{}) catch return false;
    file.close(io);
    return true;
}
