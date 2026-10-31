//! Isolated real-file measurement. Occupied workers model shared-pool pressure,
//! not AgentCore Runs; desktop event-pump acceptance remains a separate gate.
const std = @import("std");
const builtin = @import("builtin");
const product = @import("metawork_product_control");
const management = @import("product_skill_management");
const package = @import("product_skill_package");

const Workload = enum { small, large_files, many_files, stored_zip };
const Blocker = struct {
    entered: std.atomic.Value(bool) = .init(false),
    released: std.atomic.Value(bool) = .init(false),
    fn execute(context: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.entered.store(true, .release);
        while (!self.released.load(.acquire)) std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch {};
    }
    fn cancel(context: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.released.store(true, .release);
    }
};

fn elapsed(start: std.Io.Timestamp) i96 {
    return start.durationTo(std.Io.Timestamp.now(std.testing.io, .awake)).nanoseconds;
}

fn measure(workload: Workload, occupied_workers: usize, sample: usize) !void {
    var home = std.testing.tmpDir(.{});
    defer home.cleanup();
    var source = std.testing.tmpDir(.{ .iterate = true });
    defer source.cleanup();
    var archives = std.testing.tmpDir(.{});
    defer archives.cleanup();
    const home_path = try home.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home_path);
    const source_path = try source.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(source_path);
    try source.dir.writeFile(std.testing.io, .{ .sub_path = "SKILL.md", .data = "---\nname: measured-skill\ndescription: File lifecycle measurement\n---\nRead resource-0.\n" });
    const count: usize = switch (workload) {
        .small => 1,
        .large_files => 4,
        .many_files, .stored_zip => 511,
    };
    const size: usize = switch (workload) {
        .small => 1024,
        .large_files => 16 * 1024 * 1024 - 1024,
        .many_files => 128 * 1024,
        .stored_zip => 60 * 1024,
    };
    const bytes = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 'x');
    for (0..count) |index| {
        var name: [40]u8 = undefined;
        try source.dir.writeFile(std.testing.io, .{ .sub_path = try std.fmt.bufPrint(&name, "resource-{d}", .{index}), .data = bytes });
    }
    const archive_path = try archives.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(archive_path);
    const zip_path = try std.fs.path.join(std.testing.allocator, &.{ archive_path, "source.skill" });
    defer std.testing.allocator.free(zip_path);
    if (workload == .stored_zip) {
        var manifest = try package.inspectDirectory(std.testing.io, std.testing.allocator, source.dir, .{});
        defer manifest.deinit();
        const zip = try archives.dir.createFile(std.testing.io, "source.skill", .{});
        defer zip.close(std.testing.io);
        try package.exportArchive(std.testing.io, source.dir, zip, &manifest);
    }
    var store: management.FileStore = .{ .io = std.testing.io, .dir = home.dir };
    const control = try std.testing.allocator.create(product.Runtime);
    defer std.testing.allocator.destroy(control);
    try product.TestSupport.skillImportFixture(control, home_path, &store);
    defer control.deinit();
    product.TestSupport.finishSkillImportFixture(control);
    var blockers: [4]Blocker = .{ .{}, .{}, .{}, .{} };
    defer for (&blockers) |*blocker| blocker.released.store(true, .release);
    for (blockers[0..occupied_workers]) |*blocker| try control.executor.enqueue(.{ .identity = blocker, .context = blocker, .execute_fn = Blocker.execute, .cancel_fn = Blocker.cancel });
    for (blockers[0..occupied_workers]) |*blocker| {
        for (0..10000) |_| {
            if (blocker.entered.load(.acquire)) break;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        } else return error.WorkerDidNotEnter;
    }
    const start = std.Io.Timestamp.now(std.testing.io, .awake);
    const prepared = try control.prepareSkillImport(if (workload == .stored_zip) zip_path else source_path, if (workload == .stored_zip) .local_package else .local_directory, .{ .scope = .personal });
    const prepare_ns = elapsed(start);
    const preflight_start = std.Io.Timestamp.now(std.testing.io, .awake);
    try control.preflightSkillImport(prepared.id, prepared.revision, prepared.effect);
    const preflight_ns = elapsed(preflight_start);
    const commit_start = std.Io.Timestamp.now(std.testing.io, .awake);
    const result = try control.commitSkillImport(prepared.id, prepared.revision, prepared.effect);
    const commit_ns = elapsed(commit_start);
    try std.testing.expect(result.verification_pending);
    _ = try home.dir.statFile(std.testing.io, ".agents/skills/measured-skill/SKILL.md", .{ .follow_symlinks = false });
    std.debug.print("\nSKILL_FILE_MEASURE {{\"workload\":\"{s}\",\"optimize\":\"{s}\",\"sample\":{d},\"occupiedWorkers\":{d},\"files\":{d},\"sourceBytes\":{d},\"prepareNs\":{d},\"preflightNs\":{d},\"commitNs\":{d}}}\n", .{ @tagName(workload), @tagName(builtin.mode), sample, occupied_workers, prepared.file_count, prepared.total_bytes, prepare_ns, preflight_ns, commit_ns });
}

test "Skill file lifecycle isolated measurements" {
    inline for (std.meta.tags(Workload)) |workload| {
        for ([_]usize{ 0, 4 }) |workers| {
            for (0..3) |sample| try measure(workload, workers, sample);
        }
    }
}
