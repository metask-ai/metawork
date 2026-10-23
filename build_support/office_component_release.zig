const std = @import("std");
const release = @import("../src/app/office_component_release.zig");

pub fn bind(b: *std.Build, app: *std.Build.Module) void {
    const path = b.pathFromRoot("build_support/office-component-release.windows-x64.json");
    const bytes = std.Io.Dir.cwd().readFileAlloc(b.graph.io, path, b.allocator, .limited(16 * 1024)) catch
        @panic("Office release input is missing or unreadable");
    var parsed = release.parse(b.allocator, bytes) catch
        @panic("Office release input violates the fixed release contract");
    defer parsed.deinit();
    const seed = std.Io.Dir.cwd().readFileAlloc(b.graph.io, b.pathFromRoot("build_support/office-install-seed.windows-x64.tar.gz"), b.allocator, .limited(1024 * 1024)) catch
        @panic("Office installation seed is missing or too large");
    const identity = parsed.seed() catch @panic("Office seed identity is invalid");
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(seed, &hash, .{});
    if (seed.len != identity.expected.archive_bytes or !std.mem.eql(u8, &hash, &identity.expected.sha256))
        @panic("Office installation seed does not match the main-pinned identity");
    const options = b.addOptions();
    options.addOption([]const u8, "json", bytes);
    options.addOption([]const u8, "seed_archive", seed);
    app.addOptions("office_release_input", options);
}
