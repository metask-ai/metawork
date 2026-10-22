//! One offered release and bounded retained installed identities, pinned by the main.
//! A null release means no offered download;
//! neither a remote manifest nor Renderer/Agent data can add accepted releases.
const std = @import("std");
const contract = @import("office_component_contract.zig");

const Input = struct {
    schema: u32,
    protocolRevision: u32,
    target: []const u8,
    retained: []const struct {
        archiveSha256: []const u8,
        manifestSha256: []const u8,
        archiveBytes: u64,
        unpackedBytes: u64,
        files: usize,
    },
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
        const accepted_identity = try decodeIdentity(value, self.raw.value.target);
        const result: contract.Release = .{ .url = value.url, .expected = accepted_identity.expected, .manifest_sha256 = accepted_identity.manifest_sha256 };
        try result.validate();
        return result;
    }

    /// Exact current-record lookup only. Retained identities have no download
    /// URL and cannot become an install fallback or directory-discovery source.
    pub fn accepted(self: *const Parsed, digest: [32]u8) !?contract.Identity {
        if (try self.release()) |offered| if (std.mem.eql(u8, &offered.expected.sha256, &digest)) return offered.identity();
        for (self.raw.value.retained) |retained| {
            const candidate = try decodeIdentity(retained, self.raw.value.target);
            if (std.mem.eql(u8, &candidate.expected.sha256, &digest)) return candidate;
        }
        return null;
    }
};

fn decodeIdentity(value: anytype, target: []const u8) !contract.Identity {
    var result: contract.Identity = .{
        .expected = .{ .archive_bytes = value.archiveBytes, .unpacked_bytes = value.unpackedBytes, .files = value.files, .target = target, .sha256 = undefined },
        .manifest_sha256 = undefined,
    };
    if (value.archiveSha256.len != 64 or value.manifestSha256.len != 64) return error.InvalidComponentRelease;
    _ = std.fmt.hexToBytes(&result.expected.sha256, value.archiveSha256) catch return error.InvalidComponentRelease;
    _ = std.fmt.hexToBytes(&result.manifest_sha256, value.manifestSha256) catch return error.InvalidComponentRelease;
    try result.validate();
    return result;
}

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !Parsed {
    if (bytes.len > 16 * 1024) return error.InvalidComponentRelease;
    var result: Parsed = .{ .raw = try std.json.parseFromSlice(Input, allocator, bytes, .{ .max_value_len = 2048, .duplicate_field_behavior = .@"error" }) };
    errdefer result.deinit();
    if (result.raw.value.schema != 1 or result.raw.value.protocolRevision != 1 or
        !std.mem.eql(u8, result.raw.value.target, "x86_64-windows-msvc")) return error.InvalidComponentRelease;
    const offered = try result.release();
    if (result.raw.value.retained.len > 8) return error.InvalidComponentRelease;
    for (result.raw.value.retained, 0..) |retained, index| {
        const identity = try decodeIdentity(retained, result.raw.value.target);
        if (offered) |current| if (std.mem.eql(u8, &current.expected.sha256, &identity.expected.sha256)) return error.InvalidComponentRelease;
        for (result.raw.value.retained[0..index]) |previous| {
            const previous_identity = try decodeIdentity(previous, result.raw.value.target);
            if (std.mem.eql(u8, &previous_identity.expected.sha256, &identity.expected.sha256)) return error.InvalidComponentRelease;
        }
    }
    return result;
}

test "unpublished Office release has no implicit or development download fallback" {
    var parsed = try parse(std.testing.allocator, "{\"schema\":1,\"protocolRevision\":1,\"target\":\"x86_64-windows-msvc\",\"retained\":[],\"release\":null}");
    defer parsed.deinit();
    try std.testing.expect(try parsed.release() == null);
    try std.testing.expectError(error.InvalidComponentRelease, parse(std.testing.allocator, "{\"schema\":1,\"protocolRevision\":2,\"target\":\"x86_64-windows-msvc\",\"retained\":[],\"release\":null}"));
}

test "Office release accepts only the complete bounded main-pinned identity" {
    const document = "{\"schema\":1,\"protocolRevision\":1,\"target\":\"x86_64-windows-msvc\",\"retained\":[],\"release\":{\"url\":\"https://downloads.example.invalid/office.tar.gz\",\"archiveSha256\":\"" ++ "1" ** 64 ++ "\",\"manifestSha256\":\"" ++ "2" ** 64 ++ "\",\"archiveBytes\":123,\"unpackedBytes\":456,\"files\":7}}";
    var parsed = try parse(std.testing.allocator, document);
    defer parsed.deinit();
    const release = (try parsed.release()).?;
    try std.testing.expectEqual(@as(u64, 123), release.expected.archive_bytes);
    try std.testing.expectEqual(@as(usize, 7), release.expected.files);
    for ([_][]const u8{ "http://example.invalid/office", "https:///office", "https://user:password@example.invalid/office", "https://example.invalid/office?token=abc", "https://example.invalid/office#fragment" }) |url| {
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
    try std.testing.expectError(error.DuplicateField, parse(std.testing.allocator, "{\"schema\":1,\"schema\":1,\"protocolRevision\":1,\"target\":\"x86_64-windows-msvc\",\"retained\":[],\"release\":null}"));
}

test "retained Office identities authorize only exact installed records and never offer an old download" {
    const retained = "{\"archiveSha256\":\"" ++ "3" ** 64 ++ "\",\"manifestSha256\":\"" ++ "4" ** 64 ++ "\",\"archiveBytes\":100,\"unpackedBytes\":300,\"files\":2}";
    const prefix = "{\"schema\":1,\"protocolRevision\":1,\"target\":\"x86_64-windows-msvc\",\"release\":null,\"retained\":[";
    var parsed = try parse(std.testing.allocator, prefix ++ retained ++ "]}");
    defer parsed.deinit();
    try std.testing.expect(try parsed.release() == null);
    const accepted = (try parsed.accepted(@splat(0x33))).?;
    try std.testing.expectEqual(@as([32]u8, @splat(0x44)), accepted.manifest_sha256);
    try std.testing.expect(try parsed.accepted(@splat(0x55)) == null);
    try std.testing.expectError(error.InvalidComponentRelease, parse(std.testing.allocator, prefix ++ retained ++ "," ++ retained ++ "]}"));
    try std.testing.expectError(error.UnknownField, parse(std.testing.allocator, prefix ++ "{\"url\":\"https://example.invalid/old\",\"archiveSha256\":\"" ++ "3" ** 64 ++ "\",\"manifestSha256\":\"" ++ "4" ** 64 ++ "\",\"archiveBytes\":100,\"unpackedBytes\":300,\"files\":2}]}"));
}
