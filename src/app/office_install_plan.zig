//! Data from the main-pinned self-owned seed only, never a remote manifest.
//! Own the exact verified plan bytes before deriving network authority.
const std = @import("std");
const contract = @import("office_component_contract.zig");
const archive = @import("office_component_archive.zig");
const builtin = @import("builtin");

const Raw = struct {
    schema: u32,
    target: []const u8,
    manifestSha256: []const u8,
    downloads: []const struct { name: []const u8, path: []const u8, url: []const u8, bytes: u64, algorithm: []const u8, digest: []const u8 },
};
pub const Entry = struct { name: []const u8, path: []const u8, source: contract.Source };
pub const Plan = struct {
    raw: std.json.Parsed(Raw),
    entries: []Entry,
    bootstrap: usize,

    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
        self.raw.deinit();
    }
};

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8, release: contract.Release) !Plan {
    if (bytes.len > 128 * 1024) return error.InvalidComponentPlan;
    var raw = try std.json.parseFromSlice(Raw, allocator, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true, .max_value_len = 2048, .duplicate_field_behavior = .@"error" });
    errdefer raw.deinit();
    if (raw.value.schema != 1 or !std.mem.eql(u8, raw.value.target, release.expected.target) or raw.value.manifestSha256.len != 64 or
        raw.value.downloads.len == 0 or raw.value.downloads.len > 64) return error.InvalidComponentPlan;
    var manifest: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&manifest, raw.value.manifestSha256) catch return error.InvalidComponentPlan;
    if (!std.mem.eql(u8, &manifest, &release.manifest_sha256)) return error.ComponentManifestIdentity;
    const entries = try allocator.alloc(Entry, raw.value.downloads.len);
    errdefer allocator.free(entries);
    var bootstrap: ?usize = null;
    var total: u64 = 0;
    for (raw.value.downloads, entries, 0..) |item, *entry, index| {
        try archive.checkPath(item.path);
        if (item.name.len == 0 or item.name.len > 256) return error.InvalidComponentPlan;
        for (entries[0..index]) |previous| if (std.ascii.eqlIgnoreCase(previous.path, item.path) or std.mem.eql(u8, previous.name, item.name)) return error.InvalidComponentPlan;
        var digest: contract.Digest = undefined;
        if (std.mem.eql(u8, item.algorithm, "sha256") and item.digest.len == 64) {
            digest = .{ .sha256 = undefined };
            _ = std.fmt.hexToBytes(&digest.sha256, item.digest) catch return error.InvalidComponentPlan;
        } else if (std.mem.eql(u8, item.algorithm, "sha512") and item.digest.len == 128) {
            digest = .{ .sha512 = undefined };
            _ = std.fmt.hexToBytes(&digest.sha512, item.digest) catch return error.InvalidComponentPlan;
        } else return error.InvalidComponentPlan;
        entry.* = .{ .name = item.name, .path = item.path, .source = .{ .url = item.url, .bytes = item.bytes, .digest = digest } };
        try entry.source.validate();
        total += item.bytes;
        if (total > release.download_bytes) return error.InvalidComponentPlan;
        if (std.mem.eql(u8, item.name, "bootstrapPython")) {
            if (digest != .sha256 or item.bytes > 32 * 1024 * 1024) return error.InvalidComponentPlan;
            bootstrap = index;
        }
    }
    if (total != release.download_bytes) return error.InvalidComponentPlan;
    return .{ .raw = raw, .entries = entries, .bootstrap = bootstrap orelse return error.InvalidComponentPlan };
}

pub fn read(allocator: std.mem.Allocator, io: std.Io, seed: std.Io.Dir, release: contract.Release) !Plan {
    const manifest_bytes = try ownedRead(allocator, io, seed, "office-runtime.json", 128 * 1024);
    defer allocator.free(manifest_bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(manifest_bytes, &digest, .{});
    if (!std.mem.eql(u8, &digest, &release.seed.manifest_sha256)) return error.ComponentManifestIdentity;
    const Manifest = struct { files: []const struct { path: []const u8, bytes: u64, sha256: []const u8 } };
    const manifest = try std.json.parseFromSlice(Manifest, allocator, manifest_bytes, .{ .ignore_unknown_fields = true, .duplicate_field_behavior = .@"error" });
    defer manifest.deinit();
    for (manifest.value.files) |entry| if (std.mem.eql(u8, entry.path, "bootstrap/plan.json")) {
        if (entry.bytes == 0 or entry.bytes > 128 * 1024 or entry.sha256.len != 64) return error.InvalidComponentPlan;
        var pinned: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&pinned, entry.sha256);
        const plan = try ownedRead(allocator, io, seed, entry.path, @intCast(entry.bytes));
        defer allocator.free(plan);
        std.crypto.hash.sha2.Sha256.hash(plan, &digest, .{});
        if (plan.len != entry.bytes or !std.mem.eql(u8, &digest, &pinned)) return error.InvalidComponentPlan;
        return parse(allocator, plan, release);
    };
    return error.InvalidComponentPlan;
}

fn ownedRead(allocator: std.mem.Allocator, io: std.Io, root: std.Io.Dir, path: []const u8, maximum: usize) ![]u8 {
    var file = try root.openFile(io, path, .{ .follow_symlinks = false, .resolve_beneath = true });
    defer file.close(io);
    if (builtin.os.tag == .windows) file.flags.nonblocking = true;
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.size > maximum) return error.InvalidComponentPlan;
    const bytes = try allocator.alloc(u8, @intCast(stat.size));
    errdefer allocator.free(bytes);
    if (try file.readPositionalAll(io, bytes, 0) != bytes.len) return error.ComponentChanged;
    const after = try file.stat(io);
    if (after.kind != stat.kind or after.inode != stat.inode or after.size != stat.size or after.mtime.nanoseconds != stat.mtime.nanoseconds) return error.ComponentChanged;
    return bytes;
}

test "public installation plan rejects changed authority and aggregate identity" {
    const allocator = std.testing.allocator;
    var input = try @import("office_component_release.zig").parse(allocator, @embedFile("office_component_archive_fixtures/install-input.json"));
    defer input.deinit();
    const release = (try input.release()).?;
    const template = "{{\"schema\":1,\"target\":\"x86_64-windows-msvc\",\"manifestSha256\":\"{s}\",\"downloads\":[{s}]}}";
    const hash = std.fmt.bytesToHex(release.manifest_sha256, .lower);
    const source = "{\"name\":\"bootstrapPython\",\"path\":\"python.zip\",\"url\":\"https://example.invalid/python.zip\",\"bytes\":268,\"algorithm\":\"sha256\",\"digest\":\"" ++ "1" ** 64 ++ "\"}";
    const document = try std.fmt.allocPrint(allocator, template, .{ hash, source });
    defer allocator.free(document);
    var plan = try parse(allocator, document, release);
    defer plan.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), plan.bootstrap);
    var changed = release;
    changed.manifest_sha256[0] ^= 1;
    try std.testing.expectError(error.ComponentManifestIdentity, parse(allocator, document, changed));
    changed = release;
    changed.download_bytes += 1;
    try std.testing.expectError(error.InvalidComponentPlan, parse(allocator, document, changed));
    const duplicate = try std.fmt.allocPrint(allocator, template, .{ hash, source ++ "," ++ source });
    defer allocator.free(duplicate);
    changed = release;
    changed.download_bytes *= 2;
    try std.testing.expectError(error.InvalidComponentPlan, parse(allocator, duplicate, changed));
    for ([_][]const u8{ "http://example.invalid/file", "https:///file", "https://user:secret@example.invalid/file", "https://example.invalid/file?token=x", "https://example.invalid/file#x" }) |url| {
        const invalid: contract.Source = .{ .url = url, .bytes = 1, .digest = .{ .sha512 = @splat(1) } };
        try std.testing.expectError(error.InvalidComponentSource, invalid.validate());
    }
}
