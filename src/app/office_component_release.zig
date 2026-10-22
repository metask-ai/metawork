//! One main-binary-pinned release input. A null release means not published;
//! neither a remote manifest nor Renderer/Agent data can add accepted releases.
const std = @import("std");
const contract = @import("office_component_contract.zig");

const Input = struct {
    schema: u32,
    protocolRevision: u32,
    target: []const u8,
    release: ?struct {
        url: []const u8,
        archiveSha256: []const u8,
        manifestSha256: []const u8,
        archiveBytes: u64,
        unpackedBytes: u64,
        files: usize,
    },
};

pub const Parsed = struct {
    raw: std.json.Parsed(Input),

    pub fn deinit(self: *Parsed) void {
        self.raw.deinit();
        self.* = undefined;
    }

    pub fn release(self: *const Parsed) !?contract.Release {
        const value = self.raw.value.release orelse return null;
        var result: contract.Release = .{
            .url = value.url,
            .expected = .{ .archive_bytes = value.archiveBytes, .unpacked_bytes = value.unpackedBytes, .files = value.files, .target = self.raw.value.target, .sha256 = undefined },
            .manifest_sha256 = undefined,
        };
        if (value.archiveSha256.len != 64 or value.manifestSha256.len != 64) return error.InvalidComponentRelease;
        _ = std.fmt.hexToBytes(&result.expected.sha256, value.archiveSha256) catch return error.InvalidComponentRelease;
        _ = std.fmt.hexToBytes(&result.manifest_sha256, value.manifestSha256) catch return error.InvalidComponentRelease;
        try result.validate();
        return result;
    }
};

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !Parsed {
    if (bytes.len > 16 * 1024) return error.InvalidComponentRelease;
    var result: Parsed = .{ .raw = try std.json.parseFromSlice(Input, allocator, bytes, .{ .max_value_len = 2048, .duplicate_field_behavior = .@"error" }) };
    errdefer result.deinit();
    if (result.raw.value.schema != 1 or result.raw.value.protocolRevision != 1 or
        !std.mem.eql(u8, result.raw.value.target, "x86_64-windows-msvc")) return error.InvalidComponentRelease;
    _ = try result.release();
    return result;
}

test "unpublished Office release has no implicit or development download fallback" {
    var parsed = try parse(std.testing.allocator, "{\"schema\":1,\"protocolRevision\":1,\"target\":\"x86_64-windows-msvc\",\"release\":null}");
    defer parsed.deinit();
    try std.testing.expect(try parsed.release() == null);
    try std.testing.expectError(error.InvalidComponentRelease, parse(std.testing.allocator, "{\"schema\":1,\"protocolRevision\":2,\"target\":\"x86_64-windows-msvc\",\"release\":null}"));
}

test "Office release accepts only the complete bounded main-pinned identity" {
    const document = "{\"schema\":1,\"protocolRevision\":1,\"target\":\"x86_64-windows-msvc\",\"release\":{\"url\":\"https://downloads.example.invalid/office.tar.gz\",\"archiveSha256\":\"" ++ "1" ** 64 ++ "\",\"manifestSha256\":\"" ++ "2" ** 64 ++ "\",\"archiveBytes\":123,\"unpackedBytes\":456,\"files\":7}}";
    var parsed = try parse(std.testing.allocator, document);
    defer parsed.deinit();
    const release = (try parsed.release()).?;
    try std.testing.expectEqual(@as(u64, 123), release.expected.archive_bytes);
    try std.testing.expectEqual(@as(usize, 7), release.expected.files);
    for ([_][]const u8{ "http://example.invalid/office", "https://user:password@example.invalid/office", "https://example.invalid/office?token=abc", "https://example.invalid/office#fragment" }) |url| {
        var rejected = release;
        rejected.url = url;
        try std.testing.expectError(error.InvalidComponentRelease, rejected.validate());
    }
    var rejected = release;
    rejected.expected.archive_bytes = 801 * 1024 * 1024;
    try std.testing.expectError(error.InvalidComponentRelease, rejected.validate());
    rejected = release;
    rejected.manifest_sha256 = @splat(0);
    try std.testing.expectError(error.InvalidComponentRelease, rejected.validate());
    try std.testing.expectError(error.DuplicateField, parse(std.testing.allocator, "{\"schema\":1,\"schema\":1,\"protocolRevision\":1,\"target\":\"x86_64-windows-msvc\",\"release\":null}"));
}
