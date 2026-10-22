//! Pure component release contract shared by build acceptance and Application.
const std = @import("std");
const archive = @import("office_component_archive.zig");

pub const Release = struct {
    url: []const u8,
    expected: archive.Expected,
    manifest_sha256: [32]u8,

    pub fn validate(self: Release) !void {
        const limits: archive.Limits = .{};
        const uri = std.Uri.parse(self.url) catch return error.InvalidComponentRelease;
        if (self.url.len > 2048 or !std.ascii.eqlIgnoreCase(uri.scheme, "https") or uri.host == null or
            uri.user != null or uri.password != null or uri.fragment != null or uri.query != null or
            !std.mem.eql(u8, self.expected.target, "x86_64-windows-msvc") or
            self.expected.archive_bytes == 0 or self.expected.archive_bytes > limits.compressed_bytes or
            self.expected.unpacked_bytes == 0 or self.expected.unpacked_bytes > limits.unpacked_bytes or
            self.expected.files == 0 or self.expected.files > limits.members or
            std.mem.allEqual(u8, &self.expected.sha256, 0) or std.mem.allEqual(u8, &self.manifest_sha256, 0))
            return error.InvalidComponentRelease;
        for (self.url) |character| if (std.ascii.isControl(character)) return error.InvalidComponentRelease;
    }
};
