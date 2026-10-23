//! One offered release and bounded retained installed identities, pinned by the main.
//! A null release means no offered download;
//! neither a remote manifest nor Renderer/Agent data can add accepted releases.
const std = @import("std");
const contract = @import("office_component_contract.zig");

const Input = struct {
    schema: u32,
    protocolRevision: u32,
    target: []const u8,
    seed: struct { archiveSha256: []const u8, manifestSha256: []const u8, archiveBytes: u64, unpackedBytes: u64, files: usize },
    retained: []const struct {
        archiveSha256: []const u8,
        manifestSha256: []const u8,
        archiveBytes: u64,
        unpackedBytes: u64,
        files: usize,
    },
    release: ?struct {
        downloadBytes: u64,
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
        const result: contract.Release = .{ .expected = accepted_identity.expected, .manifest_sha256 = accepted_identity.manifest_sha256, .seed = try self.seed(), .download_bytes = value.downloadBytes };
        try result.validate();
        return result;
    }

    pub fn seed(self: *const Parsed) !contract.Identity {
        const result = try decodeIdentity(self.raw.value.seed, self.raw.value.target);
        if (result.expected.archive_bytes > 1024 * 1024 or result.expected.unpacked_bytes > 8 * 1024 * 1024 or result.expected.files > 512) return error.InvalidComponentRelease;
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
    if (result.raw.value.schema != 2 or result.raw.value.protocolRevision != 1 or
        !std.mem.eql(u8, result.raw.value.target, "x86_64-windows-msvc")) return error.InvalidComponentRelease;
    _ = try result.seed();
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

test "Office input pins the seed independently of an offered public installation" {
    const document = @embedFile("office_component_archive_fixtures/install-input.json");
    var parsed = try parse(std.testing.allocator, document);
    defer parsed.deinit();
    const offered = (try parsed.release()).?;
    try std.testing.expectEqual(@as(u64, 268), offered.download_bytes);
    try std.testing.expectEqual(@as(u64, 268), offered.expected.archive_bytes);
    try std.testing.expect(try parsed.accepted(offered.expected.sha256) != null);
    var invalid = offered;
    invalid.seed.expected.archive_bytes = 1024 * 1024 + 1;
    try std.testing.expectError(error.InvalidComponentRelease, invalid.validate());
    invalid = offered;
    invalid.download_bytes = 0;
    try std.testing.expectError(error.InvalidComponentRelease, invalid.validate());
    try std.testing.expectError(error.MissingField, parse(std.testing.allocator, "{\"schema\":1,\"protocolRevision\":1,\"target\":\"x86_64-windows-msvc\",\"release\":null,\"retained\":[]}"));
}

test "an unpublished Office input never offers an implicit download" {
    const document = "{\"schema\":2,\"protocolRevision\":1,\"target\":\"x86_64-windows-msvc\",\"seed\":{\"archiveSha256\":\"" ++ "1" ** 64 ++ "\",\"manifestSha256\":\"" ++ "2" ** 64 ++ "\",\"archiveBytes\":123,\"unpackedBytes\":456,\"files\":2},\"release\":null,\"retained\":[]}";
    var parsed = try parse(std.testing.allocator, document);
    defer parsed.deinit();
    try std.testing.expect(try parsed.release() == null);
    try std.testing.expect(try parsed.accepted(@splat(1)) == null);
}

test "retained identities accept exact current records without offering an old download" {
    const allocator = std.testing.allocator;
    var fixture = try parse(allocator, @embedFile("office_component_archive_fixtures/install-input.json"));
    defer fixture.deinit();
    const seed_json = try std.json.Stringify.valueAlloc(allocator, fixture.raw.value.seed, .{});
    defer allocator.free(seed_json);
    const retained = "{\"archiveSha256\":\"" ++ "3" ** 64 ++ "\",\"manifestSha256\":\"" ++ "4" ** 64 ++ "\",\"archiveBytes\":100,\"unpackedBytes\":300,\"files\":2}";
    const template = "{{\"schema\":2,\"protocolRevision\":1,\"target\":\"x86_64-windows-msvc\",\"seed\":{s},\"release\":null,\"retained\":[{s}]}}";
    const document = try std.fmt.allocPrint(allocator, template, .{ seed_json, retained });
    defer allocator.free(document);
    var parsed = try parse(allocator, document);
    defer parsed.deinit();
    try std.testing.expect(try parsed.release() == null);
    try std.testing.expectEqual(@as([32]u8, @splat(0x44)), (try parsed.accepted(@splat(0x33))).?.manifest_sha256);
    try std.testing.expect(try parsed.accepted(@splat(0x55)) == null);
    const duplicate = try std.fmt.allocPrint(allocator, template, .{ seed_json, retained ++ "," ++ retained });
    defer allocator.free(duplicate);
    try std.testing.expectError(error.InvalidComponentRelease, parse(allocator, duplicate));
    const unknown = try std.fmt.allocPrint(allocator, template, .{ seed_json, "{\"url\":\"https://example.invalid/old\"," ++ retained[1..] });
    defer allocator.free(unknown);
    try std.testing.expectError(error.UnknownField, parse(allocator, unknown));
}
