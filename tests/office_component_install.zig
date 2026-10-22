//! Qualification only: local source and optional unsigned-development witness.
//! Normal Application composition always uses the strict signature validator.
const std = @import("std");
const component = @import("office_component_store");
const office = @import("office_process");
const platform = @import("office_component_windows");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len == 3 and std.mem.eql(u8, args[1], "signatures")) {
        for ([_][]const u8{ "bin/office.exe", "python/bin/python.exe", "node/node.exe", "engine/program/soffice.com" }) |relative| {
            const path = try std.fs.path.join(allocator, &.{ args[2], relative });
            const status = try platform.signatureStatus(allocator, path);
            std.debug.print("{s}: 0x{x}\n", .{ relative, @as(u32, @bitCast(status)) });
        }
        return;
    }
    if (args.len != 6) return error.UsageArchiveMetadataManifestDigestNewStoreAndMode;
    const cache = try std.Io.Dir.cwd().createDirPathOpen(init.io, ".zig-cache/office-install-qualification", .{});
    cache.close(init.io);
    const allowed = try std.Io.Dir.cwd().realPathFileAlloc(init.io, ".zig-cache/office-install-qualification", allocator);
    const parent = try std.Io.Dir.realPathFileAbsoluteAlloc(init.io, std.fs.path.dirname(args[4]) orelse return error.InvalidQualificationStore, allocator);
    if (!std.mem.eql(u8, allowed, parent)) return error.QualificationMustStayInPrivateCache;
    const Metadata = struct { schema: u32, target: []const u8, bytes: u64, sha256: []const u8, unpackedBytes: u64, files: usize, format: []const u8, tarFormat: []const u8 };
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, args[2], allocator, .limited(16 * 1024));
    const metadata = (try std.json.parseFromSlice(Metadata, allocator, bytes, .{})).value;
    if (metadata.schema != 1 or !std.mem.eql(u8, metadata.format, "tar.gz") or !std.mem.eql(u8, metadata.tarFormat, "ustar")) return error.InvalidMetadata;
    var release: component.Release = .{ .url = "https://example.invalid/qualified-local-source", .expected = .{
        .target = metadata.target,
        .archive_bytes = metadata.bytes,
        .unpacked_bytes = metadata.unpackedBytes,
        .files = metadata.files,
        .sha256 = undefined,
    }, .manifest_sha256 = undefined };
    _ = try std.fmt.hexToBytes(&release.expected.sha256, metadata.sha256);
    _ = try std.fmt.hexToBytes(&release.manifest_sha256, args[3]);
    const dev = std.mem.eql(u8, args[5], "unsigned-development-witness");
    if (!dev and !std.mem.eql(u8, args[5], "strict")) return error.InvalidMode;
    var store = try component.Store.open(init.gpa, init.io, args[4]);
    defer store.deinit();
    try store.recover();
    var context: Context = .{ .archive_path = args[1], .environment = init.environ_map };
    const cancellation: office.Cancellation = .{};
    const receipt = store.install(release, .{ .context = &context, .read_fn = Context.read }, .{
        .context = &context,
        .parent_environment = init.environ_map,
        .test_fn = if (dev) Context.developmentWitness else null,
    }, .{ .context = &context, .observe_fn = Context.progress }, &cancellation) catch |failure| {
        const pending = try store.current();
        var output_buffer: [1024]u8 = undefined;
        var output = std.Io.File.stdout().writer(init.io, &output_buffer);
        try std.json.Stringify.value(.{ .failure = @errorName(failure), .current_preserved = pending != null }, .{}, &output.interface);
        try output.interface.writeByte('\n');
        try output.interface.flush();
        return;
    };
    const path = try store.versionPath(receipt.record);
    defer init.gpa.free(path);
    var output_buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &output_buffer);
    try std.json.Stringify.value(.{ .installed_path = path, .cleanup_pending = receipt.cleanup_pending, .development_only = dev }, .{}, &output.interface);
    try output.interface.writeByte('\n');
    try output.interface.flush();
}

const Context = struct {
    archive_path: []const u8,
    environment: *const std.process.Environ.Map,
    phase: ?component.Phase = null,

    fn progress(context: ?*anyopaque, value: component.Progress) bool {
        const self: *Context = @ptrCast(@alignCast(context.?));
        if (self.phase != value.phase) std.debug.print("Qualification phase: {s}\n", .{@tagName(value.phase)});
        self.phase = value.phase;
        return true;
    }

    fn read(context: ?*anyopaque, _: std.mem.Allocator, io: std.Io, _: component.Release, writer: *std.Io.Writer, _: *const office.Cancellation) !void {
        const self: *Context = @ptrCast(@alignCast(context.?));
        const file = try std.Io.Dir.cwd().openFile(io, self.archive_path, .{});
        defer file.close(io);
        var buffer: [64 * 1024]u8 = undefined;
        var reader = file.reader(io, &buffer);
        _ = try reader.interface.streamRemaining(writer);
    }

    fn developmentWitness(context: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, _: component.Release, root: []const u8, scratch: []const u8, cancellation: *const office.Cancellation) component.ValidationResult {
        const self: *Context = @ptrCast(@alignCast(context.?));
        // Explicit local qualification: the development entry must really be
        // unsigned, while every vendor anchor still needs Windows trust.
        const entry = std.fs.path.join(allocator, &.{ root, "bin/office.exe" }) catch return .rejected;
        defer allocator.free(entry);
        platform.verifySignature(allocator, entry) catch |failure| {
            if (failure != error.InvalidAuthenticode) return .rejected;
            for ([_][]const u8{ "python/bin/python.exe", "node/node.exe", "engine/program/soffice.com" }) |relative| {
                const path = std.fs.path.join(allocator, &.{ root, relative }) catch return .rejected;
                defer allocator.free(path);
                const status = platform.signatureStatus(allocator, path) catch return .rejected;
                if (status != 0) {
                    std.debug.print("Qualification vendor signature rejected: {s} status=0x{x}\n", .{ relative, @as(u32, @bitCast(status)) });
                    return .rejected;
                }
            }
            var result = office.run(allocator, io, root, .selftest, .{ .parent_environment = self.environment, .scratch_root = scratch }, 120_000, cancellation) catch |problem| {
                std.debug.print("Qualification selftest failed: {s}\n", .{@errorName(problem)});
                return .cleanup_incomplete;
            };
            defer result.deinit(allocator);
            if (result.term == .exited and result.term.exited == 0) return .ready;
            std.debug.print("Qualification selftest nonzero at {s}: stdout={s} stderr={s}\n", .{ root, result.stdout, result.stderr });
            return .rejected;
        };
        return .rejected; // never confuse this witness with a signed release
    }
};
