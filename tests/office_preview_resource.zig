//! Real resource qualification only. Production receives validated registry
//! leases and frozen Product identities, never these CLI paths or fake leases.
const std = @import("std");
const preview = @import("office_preview");
const process = @import("office_process");
const document = @import("product_document_preview");
const Mode = enum { normal, current, current_changed, hold, sweep, changed, cancel, cancel_live, tamper, root_swap, poison, collision, path_limit, engine_fail };
const Lease = struct {
    main: std.Thread.Id,
    released: bool = false,
    fn release(context: *anyopaque) void {
        const self: *Lease = @ptrCast(@alignCast(context));
        std.debug.assert(std.Thread.getCurrentId() == self.main and !self.released);
        self.released = true;
    }
};
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 9) return error.UsageComponentSourceRootRelativeDataRootSizeShaComponentIdentityMode;
    var digest: [32]u8 = undefined;
    var identity: [32]u8 = undefined;
    if (args[6].len != 64 or args[7].len != 64) return error.InvalidDigest;
    _ = try std.fmt.hexToBytes(&digest, args[6]);
    _ = try std.fmt.hexToBytes(&identity, args[7]);
    const mode = std.meta.stringToEnum(Mode, args[8]) orelse return error.InvalidMode;
    if (mode == .sweep) {
        var work: Sweep = .{ .allocator = init.gpa, .io = init.io, .main_thread = std.Thread.getCurrentId(), .root = args[4] };
        const thread = try std.Thread.spawn(.{}, Sweep.run, .{&work});
        thread.join();
        const result = try work.result;
        try emit(init.io, result);
        return;
    }
    var operation: [16]u8 = undefined;
    try std.Io.randomSecure(init.io, &operation);
    var lease: Lease = .{ .main = std.Thread.getCurrentId() };
    var resource = try preview.Resource.init(init.gpa, init.io, lease.main, init.environ_map, args[4], .{ .root = args[1], .identity = identity, .context = &lease, .release_fn = Lease.release }, .{ .root = args[2], .relative = args[3], .expected = if (mode == .current or mode == .current_changed) null else .{ .size_bytes = try std.fmt.parseInt(u64, args[5], 10), .sha256 = digest } }, operation);
    if (mode == .normal or mode == .current) return qualifyLane(init, &resource, &lease, args[5], digest, mode);
    const cancellation: process.Cancellation = .{};
    if (resource.prepare(&cancellation)) |_| return error.MainThreadEffectAccepted else |failure| if (failure != error.MainThreadFileEffect) return failure;
    var blocker: ?process.ResourceScope = if (mode == .collision) try process.ResourceScope.initOperation(operation) else null;
    defer if (blocker) |*scope| scope.deinit();
    var work: Work = .{ .resource = &resource, .mode = mode };
    if (mode == .cancel) work.cancellation.requested.store(true, .release);
    const timer = if (mode == .cancel_live) try std.Thread.spawn(.{}, Work.cancelLater, .{&work}) else null;
    const thread = try std.Thread.spawn(.{}, Work.run, .{&work});
    thread.join();
    if (timer) |handle| handle.join();
    if (work.failure) |failure| return failure;
    if (mode == .hold) {
        try emit(init.io, .{ .ready = true, .operation = resource.name[0..] });
        var stop: [1]u8 = undefined;
        _ = try std.Io.File.stdin().readStreaming(init.io, &.{&stop});
    }
    if (mode == .poison) {
        if (lease.released) return error.LeaseReleasedTooEarly;
        if (resource.deinit()) |_| return error.PoisonedResourceReleased else |failure| if (failure != error.PreviewResourcesOutstanding) return failure;
    } else {
        if (resource.root != null) {
            if (resource.deinit()) |_| return error.ResourceReleasedBeforeCleanup else |failure| if (failure != error.PreviewResourcesOutstanding) return failure;
        }
        const cleanup = try std.Thread.spawn(.{}, Work.clean, .{&work});
        cleanup.join();
        if (work.failure) |failure| return failure;
        try resource.deinit();
        if (!lease.released) return error.ComponentLeaseNotReleased;
    }
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buffer);
    try std.json.Stringify.value(.{ .mode = @tagName(mode), .pages = work.pages, .cells = work.cells, .source_text_bytes = work.text_bytes, .read_count = work.read_count, .lease_released = lease.released, .guard = true, .failure_observed = work.observed }, .{}, &writer.interface);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
}
const Work = struct {
    resource: *preview.Resource,
    mode: Mode,
    cancellation: process.Cancellation = .{},
    failure: ?anyerror = null,
    observed: ?[]const u8 = null,
    pages: usize = 0,
    cells: usize = 0,
    text_bytes: usize = 0,
    read_count: usize = 0,
    done: std.atomic.Value(bool) = .init(false),
    fn run(self: *Work) void {
        defer self.done.store(true, .release);
        self.execute() catch |failure| {
            self.failure = failure;
        };
    }
    fn cancelLater(self: *Work) void {
        const started: std.Io.Timestamp = .now(self.resource.io, .awake);
        while (!self.done.load(.acquire)) {
            if (started.durationTo(.now(self.resource.io, .awake)).toMilliseconds() >= 800) {
                self.cancellation.requested.store(true, .release);
                return;
            }
            std.Io.Timeout.sleep(.{ .duration = .{ .raw = .fromMilliseconds(5), .clock = .awake } }, self.resource.io) catch return;
        }
    }
    fn clean(self: *Work) void {
        self.resource.cleanup() catch |failure| {
            self.failure = failure;
        };
    }
    fn execute(self: *Work) !void {
        self.resource.prepare(&self.cancellation) catch |failure| {
            if (self.mode == .collision and failure == error.JobInUse) {
                if (self.resource.root != null or self.resource.operation_scope != null) return error.CollidingScopeAdopted;
                self.observed = @errorName(failure);
                return;
            }
            if (((self.mode == .cancel or self.mode == .cancel_live) and failure == error.Cancelled) or
                (self.mode == .path_limit and failure == error.PreviewPathTooLong) or
                (self.mode == .engine_fail and failure == error.PreviewPreparationFailed))
            {
                self.observed = @errorName(failure);
                return;
            }
            return failure;
        };
        const metadata = try self.resource.prepared();
        self.pages = if (metadata.pages) |pages| pages.len else 0;
        self.text_bytes = self.resource.source_text.len;
        if (process.ResourceScope.initOperation(self.resource.operation)) |unprotected| {
            var unexpected = unprotected;
            unexpected.deinit();
            return error.ReadyResourceLostLifetimeOwner;
        } else |failure| if (failure != error.JobInUse) return failure;

        if (self.mode == .hold) return;
        if (self.mode == .poison) {
            // A completed process does not authorize cleanup after the owner's
            // kernel observation is lost. Inject that failure on our own Job.
            self.resource.operation_scope.?.deinit();
            if (self.resource.cleanup()) |_| return error.PoisonedCleanupAccepted else |failure| if (failure != error.PreviewRestartRequired) return failure;
            if (self.resource.cleanup()) |_| return error.PoisonedCleanupAccepted else |failure| if (failure != error.PreviewRestartRequired) return failure;
            self.observed = "PreviewRestartRequired";
            return;
        }

        if (self.resource.prepare(&self.cancellation)) |_| return error.PreparationRepeated else |failure| if (failure != error.InvalidPreviewState) return failure;
        if (self.mode == .changed or self.mode == .current_changed) {
            const source_path = try std.fs.path.join(self.resource.allocator, &.{ self.resource.source.root, self.resource.source.relative });
            defer self.resource.allocator.free(source_path);
            const file = try std.Io.Dir.cwd().openFile(self.resource.io, source_path, .{ .mode = .read_write });
            defer file.close(self.resource.io);
            try file.writePositionalAll(self.resource.io, "changed", 0);
        }
        if (self.mode == .tamper and metadata.kind == .pages) {
            const root = self.resource.root.?;
            try root.directory.?.writeFile(self.resource.io, .{ .sub_path = "prepared/page-0001.png", .data = "tampered" });
        }
        if (self.mode == .root_swap) {
            const root = self.resource.root.?;
            try root.parent.renamePreserve(&self.resource.name, root.parent, "original", self.resource.io);
            defer root.parent.renamePreserve("original", root.parent, &self.resource.name, self.resource.io) catch @panic("fixture root restore failed");
            try root.parent.createDir(self.resource.io, &self.resource.name, .default_dir);
            defer root.parent.deleteDir(self.resource.io, &self.resource.name) catch @panic("fixture replacement removal failed");
            if (self.resource.cleanup()) |_| return error.ReplacementDeleted else |failure| {
                if (failure != error.PreviewRootChanged) return failure;
                self.observed = @errorName(failure);
            }
            return;
        }
        for (0..3) |index| {
            self.read() catch |failure| {
                if (((self.mode == .changed or self.mode == .current_changed) and failure == error.OutputChanged) or
                    (self.mode == .tamper and (failure == error.PreviewResourceDigest or failure == error.InvalidPreviewImage)))
                {
                    self.observed = @errorName(failure);
                    return;
                }
                return failure;
            };
            _ = index;
            self.read_count += 1;
        }
        if (self.mode == .changed or self.mode == .current_changed or self.mode == .tamper) return error.TamperingAccepted;
    }
    fn read(self: *Work) !void {
        if (self.pages != 0) {
            const bytes = try self.resource.page(0, &self.cancellation);
            self.resource.allocator.free(bytes);
        } else {
            const cells = try self.resource.region(.{ .sheet = 1, .row = 1, .column = 1, .rows = 10, .columns = 5 }, &self.cancellation);
            defer self.resource.allocator.free(cells);
            self.cells = cells.len;
        }
    }
};

// Normal resources go through the same narrow owned effect and independent
// Product scheduler. Runtime admission is separate; fault injection above
// remains resource-only.
fn qualifyLane(init: std.process.Init, resource: *preview.Resource, lease: *Lease, size_text: []const u8, digest: [32]u8, mode: Mode) !void {
    var lane: document.Lane = .{ .io = init.io, .allocator = init.gpa, .main_thread = lease.main, .notifier = .{ .context = null, .wake_fn = laneWake } };
    defer lane.deinit() catch @panic("qualification cleanup failed");
    const effect = try resource.intoOwned();
    lane.open(1, effect) catch |failure| {
        effect.release_fn(effect.context);
        return failure;
    };
    const prepared = try nextLane(init.io, &lane);
    const preparation_failure = prepared.failure;
    lane.finish(prepared);
    if (preparation_failure) |failure| return failure;
    const material = try lane.material(1);
    if (material.source.size_bytes != try std.fmt.parseInt(u64, size_text, 10) or !std.mem.eql(u8, &material.source.sha256, &digest)) return error.CapturedSourceMismatch;
    const pages = if (material.manifest.pages) |items| items.len else 0;
    const text_bytes = material.source_text.len;
    var cells: usize = 0;
    for (0..3) |index| {
        try lane.read(1, if (pages != 0 and (material.grid == null or index != 1)) .{ .page = 0 } else .{ .region = .{ .sheet = 1, .row = 1, .column = 1, .rows = 10, .columns = 5 } });
        const taken = try nextLane(init.io, &lane);
        const failure = taken.failure;
        if (taken.read) |read| switch (read.value) {
            .page => {},
            .region => |items| cells = items.len,
        };
        lane.finish(taken);
        if (failure) |problem| return problem;
    }
    if (lease.released) return error.LeaseReleasedBeforeCleanup;
    _ = lane.close(1);
    while (lane.hasResources()) {
        const taken = try nextLane(init.io, &lane);
        const failure = taken.failure;
        lane.finish(taken);
        if (failure) |problem| return problem;
    }
    if (!lease.released) return error.LeaseNotReleased;
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buffer);
    try std.json.Stringify.value(.{ .mode = @tagName(mode), .pages = pages, .cells = cells, .source_text_bytes = text_bytes, .read_count = 3, .lease_released = lease.released, .guard = true, .failure_observed = @as(?[]const u8, null), .product_lane = true, .captured_source = true }, .{}, &writer.interface);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
}
fn laneWake(_: ?*anyopaque) bool {
    return true;
}
fn nextLane(io: std.Io, lane: *document.Lane) !document.Taken {
    const start: std.Io.Timestamp = .now(io, .awake);
    while (start.durationTo(.now(io, .awake)).toMilliseconds() < 150_000) {
        if (lane.take()) |taken| return taken;
        try std.Io.Timeout.sleep(.{ .duration = .{ .raw = .fromMilliseconds(2), .clock = .awake } }, io);
    }
    return error.QualificationTimeout;
}

const Sweep = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    main_thread: std.Thread.Id,
    root: []const u8,
    result: anyerror!preview.Collection = error.NotStarted,
    fn run(self: *Sweep) void {
        const cancellation: process.Cancellation = .{};
        self.result = preview.collectAbandoned(self.allocator, self.io, self.main_thread, self.root, &cancellation);
    }
};
fn emit(io: std.Io, value: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    try std.json.Stringify.value(value, .{}, &writer.interface);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
}
