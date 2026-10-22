//! Standalone qualification of Application's real bootstrap against a produced
//! component. It deliberately links neither Python nor the Office engine.
const std = @import("std");
const archive = @import("office_component_archive");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    const installed = args.len == 5 and std.mem.eql(u8, args[1], "--installed");
    if (args.len != 4 and !installed) return error.UsageArchiveMetadataAndExistingParent;
    const raw = try std.Io.Dir.cwd().readFileAlloc(init.io, args[2], allocator, .limited(16 * 1024));
    const Metadata = struct {
        schema: u32,
        target: []const u8,
        bytes: u64,
        sha256: []const u8,
        unpackedBytes: u64,
        files: usize,
        format: []const u8,
        tarFormat: []const u8,
    };
    const parsed = try std.json.parseFromSlice(Metadata, allocator, raw, .{});
    const metadata = parsed.value;
    if (metadata.schema != 1 or !std.mem.eql(u8, metadata.format, "tar.gz") or
        !std.mem.eql(u8, metadata.tarFormat, "ustar") or metadata.sha256.len != 64)
        return error.InvalidProducerMetadata;
    var sha256: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&sha256, metadata.sha256);
    const parent = try std.Io.Dir.cwd().openDir(init.io, args[3], .{ .iterate = true, .follow_symlinks = false });
    defer parent.close(init.io);
    const expected: archive.Expected = .{ .sha256 = sha256, .archive_bytes = metadata.bytes, .unpacked_bytes = metadata.unpackedBytes, .files = metadata.files, .target = metadata.target };
    const result = if (installed) verified: {
        if (args[4].len != 64) return error.InvalidManifestIdentity;
        var pinned_manifest: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&pinned_manifest, args[4]);
        break :verified try archive.verifyInstalled(allocator, init.io, parent, expected, pinned_manifest, .{}, .{});
    } else unpacked: {
        const input = try std.Io.Dir.cwd().openFile(init.io, args[1], .{});
        defer input.close(init.io);
        var buffer: [64 * 1024]u8 = undefined;
        var reader = input.reader(init.io, &buffer);
        break :unpacked try archive.unpack(allocator, init.io, &reader.interface, parent, "component", expected, .{}, .{});
    };
    const manifest_digest = std.fmt.bytesToHex(result.manifest_sha256, .lower);
    var output_buffer: [1024]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &output_buffer);
    try std.json.Stringify.value(.{ .files = result.files, .unpackedBytes = result.unpacked_bytes, .manifestSha256 = manifest_digest[0..] }, .{}, &output.interface);
    try output.interface.writeByte('\n');
    try output.interface.flush();
}
