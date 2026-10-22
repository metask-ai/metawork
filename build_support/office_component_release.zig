const std = @import("std");
const release = @import("../src/app/office_component_release.zig");

pub fn bind(b: *std.Build, app: *std.Build.Module) void {
    const path = b.pathFromRoot("build_support/office-component-release.windows-x64.json");
    const bytes = std.Io.Dir.cwd().readFileAlloc(b.graph.io, path, b.allocator, .limited(16 * 1024)) catch
        @panic("Office release input is missing or unreadable");
    var parsed = release.parse(b.allocator, bytes) catch
        @panic("Office release input violates the fixed release contract");
    defer parsed.deinit();
    const options = b.addOptions();
    options.addOption([]const u8, "json", bytes);
    app.addOptions("office_release_input", options);
}
