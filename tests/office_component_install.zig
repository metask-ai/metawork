//! Qualification only: local source and optional unsigned-development witness.
//! Normal Application composition always uses the strict signature validator.
const std = @import("std");
const component = @import("office_component_store");
const office = @import("office_process");
const platform = @import("office_component_windows");
const releases = component.release_input;
const download = component.public_download;

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
    if (args.len != 6) return error.UsageReleaseJsonSeedNewStoreModeAndSourceDirectoryOrHttpsOrCheck;
    const cache = try std.Io.Dir.cwd().createDirPathOpen(init.io, ".zig-cache/office-install-qualification", .{});
    cache.close(init.io);
    const allowed = try std.Io.Dir.cwd().realPathFileAlloc(init.io, ".zig-cache/office-install-qualification", allocator);
    const parent = try std.Io.Dir.realPathFileAbsoluteAlloc(init.io, std.fs.path.dirname(args[3]) orelse return error.InvalidQualificationStore, allocator);
    if (!std.mem.eql(u8, allowed, parent)) return error.QualificationMustStayInPrivateCache;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], allocator, .limited(16 * 1024));
    var input = try releases.parse(allocator, bytes);
    defer input.deinit();
    const release = (try input.release()) orelse return error.NoOfferedQualificationRelease;
    const seed = try std.Io.Dir.cwd().readFileAlloc(init.io, args[2], allocator, .limited(1024 * 1024));
    const dev = std.mem.eql(u8, args[4], "unsigned-development-witness");
    if (!dev and !std.mem.eql(u8, args[4], "strict")) return error.InvalidMode;
    var store = try component.Store.open(init.gpa, init.io, args[3]);
    defer store.deinit();
    try store.recover();
    try store.bindHostScope(try office.hostScope());
    var context: Context = .{ .source_directory = args[5], .environment = init.environ_map };
    const cancellation: office.Cancellation = .{};
    const validation: component.Validation = .{ .context = &context, .parent_environment = init.environ_map, .test_fn = if (dev) Context.developmentWitness else null };
    const observer: component.Observer = .{ .context = &context, .observe_fn = Context.progress };
    const workflow = std.mem.eql(u8, args[5], "--workflow-witness");
    const checking = workflow or std.mem.eql(u8, args[5], "--check-current");
    const source: component.Download = if (std.mem.eql(u8, args[5], "--https")) .{ .context = &context, .read_fn = Context.https } else .{ .context = &context, .read_fn = Context.read };
    const operation = if (checking)
        store.verifyCurrent(release.identity(), (try store.current()) orelse return error.MissingQualificationCurrent, validation, observer, &cancellation)
    else
        store.install(release, seed, source, validation, observer, &cancellation);
    const receipt = operation catch |failure| {
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
    if (workflow) {
        // The standalone checker is a Shell consumer. Keep the same native
        // Host and version authority alive until all of its calls finish.
        var scope = try office.ResourceScope.initVersion(receipt.record.install_id);
        defer scope.deinit();
        const node = try std.fs.path.join(allocator, &.{ path, "node", "node.exe" });
        const script = try std.Io.Dir.cwd().realPathFileAlloc(init.io, "scripts/check-office-skills.mjs", allocator);
        const result = std.process.run(init.gpa, init.io, .{
            .argv = &.{ node, script, "--component", path },
            .stdout_limit = .limited(4 * 1024 * 1024),
            .stderr_limit = .limited(4 * 1024 * 1024),
            .timeout = .{ .duration = .{ .raw = .fromSeconds(900), .clock = .awake } },
        }) catch |failure| {
            try scope.settle(init.io);
            return failure;
        };
        defer init.gpa.free(result.stdout);
        defer init.gpa.free(result.stderr);
        try scope.settle(init.io);
        std.debug.print("{s}{s}", .{ result.stdout, result.stderr });
        if (result.term != .exited or result.term.exited != 0) return error.QualificationWorkflowFailed;
    }
    var output_buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &output_buffer);
    try std.json.Stringify.value(.{ .installed_path = path, .cleanup_pending = receipt.cleanup_pending, .development_only = dev, .workflow_verified = workflow }, .{}, &output.interface);
    try output.interface.writeByte('\n');
    try output.interface.flush();
}

const Context = struct {
    source_directory: []const u8,
    environment: *const std.process.Environ.Map,
    phase: ?component.Phase = null,
    https_index: usize = 0,

    fn https(context: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, source: component.Source, writer: *std.Io.Writer, cancellation: *const office.Cancellation) !void {
        const self: *Context = @ptrCast(@alignCast(context.?));
        self.https_index += 1;
        std.debug.print("Qualification HTTPS source {d}: expected {d} bytes\n", .{ self.https_index, source.bytes });
        const public = download.source();
        public.read_fn(public.context, allocator, io, source, writer, cancellation) catch |failure| {
            std.debug.print("Qualification HTTPS source {d} failed: {s}\n", .{ self.https_index, @errorName(failure) });
            return failure;
        };
    }

    fn progress(context: ?*anyopaque, value: component.Progress) bool {
        const self: *Context = @ptrCast(@alignCast(context.?));
        if (self.phase != value.phase) std.debug.print("Qualification phase: {s}\n", .{@tagName(value.phase)});
        self.phase = value.phase;
        return true;
    }

    fn read(context: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, source: component.Source, writer: *std.Io.Writer, _: *const office.Cancellation) !void {
        const self: *Context = @ptrCast(@alignCast(context.?));
        const name = switch (source.digest) {
            .sha256 => |hash| try std.fmt.allocPrint(allocator, "{x}", .{&hash}),
            .sha512 => |hash| try std.fmt.allocPrint(allocator, "{x}", .{&hash}),
        };
        defer allocator.free(name);
        const directory = try std.Io.Dir.cwd().openDir(io, self.source_directory, .{ .follow_symlinks = false });
        defer directory.close(io);
        var file = try directory.openFile(io, name, .{ .follow_symlinks = false, .resolve_beneath = true });
        defer file.close(io);
        file.flags.nonblocking = true;
        var buffer: [64 * 1024]u8 = undefined;
        var reader = file.reader(io, &buffer);
        _ = try reader.interface.streamRemaining(writer);
    }

    fn developmentWitness(context: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, stage: component.ValidationStage, _: component.Identity, root: []const u8, scratch: []const u8, cancellation: *const office.Cancellation) component.ValidationResult {
        const self: *Context = @ptrCast(@alignCast(context.?));
        // Explicit local qualification: the development entry must really be
        // unsigned, while every vendor anchor still needs Windows trust.
        const entry = std.fs.path.join(allocator, &.{ root, "bin/office.exe" }) catch return .rejected;
        defer allocator.free(entry);
        const entry_status = platform.signatureStatus(allocator, entry) catch return .rejected;
        if (@as(u32, @bitCast(entry_status)) != 0x800b0100) return .rejected; // TRUST_E_NOSIGNATURE only
        for ([_][]const u8{ "python/bin/python.exe", "node/node.exe", "engine/program/soffice.com" }) |relative| {
            const path = std.fs.path.join(allocator, &.{ root, relative }) catch return .rejected;
            defer allocator.free(path);
            const status = platform.signatureStatus(allocator, path) catch return .rejected;
            if (status != 0) {
                std.debug.print("Qualification vendor signature rejected: {s} status=0x{x}\n", .{ relative, @as(u32, @bitCast(status)) });
                return .rejected;
            }
        }
        if (stage == .authentication) return .ready;
        var result = switch (office.run(allocator, io, root, .selftest, .{ .parent_environment = self.environment, .scratch_root = scratch }, 120_000, cancellation)) {
            .completed => |output| output,
            .failed => |problem| {
                std.debug.print("Qualification selftest failed: {s}\n", .{@errorName(problem.cause)});
                return if (problem.quiescent) .rejected else .cleanup_incomplete;
            },
        };
        defer result.deinit(allocator);
        if (result.term == .exited and result.term.exited == 0) return .ready;
        std.debug.print("Qualification selftest nonzero at {s}: stdout={s} stderr={s}\n", .{ root, result.stdout, result.stderr });
        return .rejected;
    }
};
