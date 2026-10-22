//! Main-thread preview sessions. Application effects and their physical lane
//! never receive this state, the policy callbacks, or a Product pointer.
const std = @import("std");
const physical = @import("product_document_preview");
pub const contract = physical.contract;
pub const Limits = struct {
    pub const prepare_ms = 150_000;
    pub const read_ms = 30_000;
    pub const transfer_ms = 15_000;
    pub const idle_ms = 120_000;
    pub const lifetime_ms = 900_000;
    pub const chunk_bytes = 262143;
};
pub const Selector = union(enum) { output: [16]u8, reference: []const u8 };
pub const Target = struct {
    allocator: std.mem.Allocator,
    storage: []u8,
    task_id: u64,
    run_id: u64,
    selector: Selector,
    workspace_id: u64,
    workspace_epoch: u64,
    security_epoch: u64,
    component: [32]u8,
    input: contract.Input,
    pub fn deinit(self: *Target) void {
        self.allocator.free(self.storage);
        self.* = undefined;
    }
};
pub const State = enum { ready, busy, missing, restricted, stale_security, unavailable, unsupported, changed, limit, cancelled, expired, restart_required, failed };
pub const Kind = enum { open, page, region };
pub const Sheet = struct { index: u16, name: []const u8, hidden: bool, rows: u32, columns: u16 };
pub const Summary = struct { format: contract.Format, kind: contract.Kind, source: contract.Source, page_count: u16, sheets: []const Sheet, omissions: []const []const u8, text_scope: []const u8, layout: ?contract.Layout = null };
pub const Page = struct { size_bytes: usize, width: u32, height: u32 };
/// All slices are callback-scoped. Raw source text is deliberately absent.
pub const Result = struct {
    request_id: u64,
    resource_id: u64,
    kind: Kind,
    state: State,
    summary: ?Summary = null,
    page: ?Page = null,
    region: ?struct { request: contract.Region, cells: []const contract.Cell } = null,
};
pub const Sink = struct {
    context: *anyopaque,
    active_fn: *const fn (*anyopaque, u64) bool,
    complete_fn: *const fn (*anyopaque, Result) void,
    released_fn: *const fn (*anyopaque, u64, State) void,
};
/// Borrowed only during a main-loop call, never stored in a session or worker.
pub const Policy = struct {
    context: *anyopaque,
    validate_fn: *const fn (*anyopaque, *const Target) anyerror!void,
    contains_fn: *const fn (*anyopaque, []const u8) bool,
    overlap_fn: *const fn (*anyopaque) anyerror!usize,
};
pub const Factory = contract.Preparation;
const Pending = struct { request_id: u64, request: ?contract.Request, started: std.Io.Timestamp };
const Phase = enum { preparing, scanning, ready, closing, debt };
const Dimensions = struct { width: u32, height: u32 };
const Session = struct {
    allocator: std.mem.Allocator,
    id: u64,
    target: Target,
    phase: Phase = .preparing,
    reason: State = .cancelled,
    pending: ?Pending,
    created: std.Io.Timestamp,
    touched: std.Io.Timestamp,
    cursor: physical.Scan.Cursor = .{},
    sheets: [64]Sheet = undefined,
    sheet_count: u16 = 0,
    pages: [100]Dimensions = undefined,
    page_count: u16 = 0,
    held: ?physical.Taken = null,
    next_offset: usize = 0,
    held_at: ?std.Io.Timestamp = null,
};
pub const Sessions = struct {
    lane: ?*physical.Lane = null,
    slots: [physical.max_resources]?*Session = @splat(null),
    next_id: u64 = 0,
    draining: bool = false,
    stopping: bool = false,

    fn find(self: *Sessions, id: u64) ?*Session {
        for (&self.slots) |*slot| if (slot.*) |session| {
            if (session.id == id) return session;
        };
        return null;
    }
    /// target is consumed only on success. No context or policy is retained.
    pub fn open(self: *Sessions, io: std.Io, allocator: std.mem.Allocator, notifier: physical.Notifier, policy: Policy, factory: Factory, target: Target, request_id: u64) !u64 {
        if (self.stopping) return error.ExecutorShuttingDown;
        if (request_id == 0) return error.InvalidPreviewIdentity;
        const slot = for (&self.slots) |*entry| {
            if (entry.* == null) break entry;
        } else return error.PreviewCapacity;
        const id = std.math.add(u64, self.next_id, 1) catch return error.PreviewCapacity;
        try policy.validate_fn(policy.context, &target);
        if (self.lane == null) {
            const lane = try allocator.create(physical.Lane);
            lane.* = .{ .io = io, .allocator = allocator, .main_thread = std.Thread.getCurrentId(), .notifier = notifier };
            self.lane = lane;
        }
        const session = try allocator.create(Session);
        errdefer allocator.destroy(session);
        const effect = try factory.prepare_fn(factory.context, target.input);
        var consumed = false;
        defer if (!consumed) effect.release_fn(effect.context);
        try policy.validate_fn(policy.context, &target);
        try self.lane.?.open(id, effect);
        consumed = true;
        const now: std.Io.Timestamp = .now(io, .awake);
        session.* = .{ .allocator = allocator, .id = id, .target = target, .pending = .{ .request_id = request_id, .request = null, .started = now }, .created = now, .touched = now };
        slot.* = session;
        self.next_id = id;
        return id;
    }
    pub fn read(self: *Sessions, policy: Policy, id: u64, request_id: u64, request: contract.Request) !void {
        const session = self.find(id) orelse return error.MissingPreview;
        try self.authorize(policy, session);
        if (session.phase != .ready or session.pending != null or session.held != null) return error.PreviewBusy;
        if (request_id == 0) return error.InvalidPreviewIdentity;
        switch (request) {
            .page => |index| if (index >= session.page_count) return error.InvalidPreviewRegion,
            .region => |region| if (region.sheet == 0 or region.sheet > session.sheet_count) return error.InvalidPreviewRegion,
        }
        try self.lane.?.read(id, request);
        const now: std.Io.Timestamp = .now(self.lane.?.io, .awake);
        session.pending = .{ .request_id = request_id, .request = request, .started = now };
        session.touched = now;
    }
    pub fn close(self: *Sessions, id: u64, reason: State) bool {
        const session = self.find(id) orelse return true;
        if (session.phase == .debt) return false;
        if (session.phase != .closing) session.reason = reason;
        session.phase = .closing;
        self.releaseRead(id);
        return self.lane.?.close(id);
    }
    pub fn releaseRead(self: *Sessions, id: u64) void {
        const session = self.find(id) orelse return;
        if (session.held) |taken| self.lane.?.finish(taken);
        session.held = null;
        session.held_at = null;
        session.next_offset = 0;
    }
    /// A chunk belongs to one previously checked immutable page read. Product
    /// authority and security are checked again; the Bridge also checks its
    /// connection/window grant on every chunk. No file IO happens here.
    pub fn chunk(self: *Sessions, policy: Policy, id: u64, offset: usize) ![]const u8 {
        const session = self.find(id) orelse return error.MissingPreview;
        try self.authorize(policy, session);
        const taken = session.held orelse return error.MissingPreview;
        const bytes = taken.read.?.value.page;
        if (offset != session.next_offset or offset >= bytes.len) return error.InvalidOffset;
        const end = offset + @min(Limits.chunk_bytes, bytes.len - offset);
        session.next_offset = end;
        session.touched = .now(self.lane.?.io, .awake);
        return bytes[offset..end];
    }
    fn authorize(self: *Sessions, policy: Policy, session: *Session) !void {
        if (session.phase == .closing or session.phase == .debt) return switch (session.reason) {
            .stale_security => error.StaleSecurityEpoch,
            .expired => error.PreviewExpired,
            .unavailable => error.OfficePreviewUnavailable,
            else => error.RestrictedPreview,
        };
        if (self.expired(session)) {
            _ = self.close(session.id, .expired);
            return error.PreviewExpired;
        }
        policy.validate_fn(policy.context, &session.target) catch |failure| {
            _ = self.close(session.id, failureState(failure));
            return failure;
        };
    }
    fn expired(self: *const Sessions, session: *const Session) bool {
        const now: std.Io.Timestamp = .now(self.lane.?.io, .awake);
        return session.created.durationTo(now).toMilliseconds() >= Limits.lifetime_ms or
            (if (session.pending) |pending| pending.started.durationTo(now).toMilliseconds() >= (if (pending.request == null) @as(i64, Limits.prepare_ms) else Limits.read_ms) else session.touched.durationTo(now).toMilliseconds() >= Limits.idle_ms) or
            (if (session.held_at) |start| start.durationTo(now).toMilliseconds() >= Limits.transfer_ms else false);
    }
    /// The caller supplies a real periodic wake while sessions are live. Work
    /// is bounded per drain; incomplete scans explicitly request another wake.
    pub fn drain(self: *Sessions, policy: Policy, sink: Sink) void {
        const lane = self.lane orelse return;
        if (self.draining) return;
        self.draining = true;
        defer self.draining = false;
        for (&self.slots) |*slot| if (slot.*) |session| {
            if (session.phase == .closing or session.phase == .debt) continue;
            if (!sink.active_fn(sink.context, session.id)) {
                _ = self.close(session.id, .cancelled);
                continue;
            }
            self.authorize(policy, session) catch continue;
        };
        while (lane.take()) |taken| {
            const session = self.find(taken.id) orelse unreachable;
            switch (taken.operation) {
                .cleanup => {
                    const reason = if (taken.failure == null) session.reason else State.restart_required;
                    lane.finish(taken);
                    completePending(session, sink, reason);
                    const id = session.id;
                    if (taken.failure == null) {
                        for (&self.slots) |*slot| if (slot.* != null and slot.*.?.id == id) {
                            const owned = slot.*.?;
                            const allocator = owned.allocator;
                            owned.target.deinit();
                            allocator.destroy(owned);
                            slot.* = null;
                            break;
                        };
                    } else session.phase = .debt;
                    sink.released_fn(sink.context, id, reason);
                },
                .prepare => {
                    lane.finish(taken);
                    if (session.phase == .closing) continue;
                    if (taken.failure) |failure| {
                        _ = self.close(session.id, failureState(failure));
                        continue;
                    }
                    session.phase = .scanning;
                },
                .read => |request| {
                    if (session.phase == .closing or taken.failure != null) {
                        lane.finish(taken);
                        if (session.phase != .closing) _ = self.close(session.id, failureState(taken.failure.?));
                        continue;
                    }
                    const pending = session.pending.?;
                    session.pending = null;
                    switch (request) {
                        .page => |index| {
                            session.held = taken;
                            session.held_at = .now(lane.io, .awake);
                            const page = session.pages[index];
                            sink.complete_fn(sink.context, .{ .request_id = pending.request_id, .resource_id = session.id, .kind = .page, .state = .ready, .page = .{ .size_bytes = taken.read.?.value.page.len, .width = page.width, .height = page.height } });
                        },
                        .region => |region| {
                            const cells = taken.read.?.value.region;
                            const allowed = regionBytes(cells) <= 128 * 1024;
                            sink.complete_fn(sink.context, .{ .request_id = pending.request_id, .resource_id = session.id, .kind = .region, .state = if (allowed) .ready else .limit, .region = if (allowed) .{ .request = region, .cells = cells } else null });
                            lane.finish(taken);
                        },
                    }
                },
            }
        }
        var budget: usize = physical.Scan.step_bytes;
        for (&self.slots) |*slot| if (slot.*) |session| {
            if (session.phase != .scanning) continue;
            const material = lane.material(session.id) catch {
                _ = self.close(session.id, .failed);
                continue;
            };
            const overlap = policy.overlap_fn(policy.context) catch {
                _ = self.close(session.id, .restricted);
                continue;
            };
            while (session.cursor.next(material, overlap, &budget) catch {
                _ = self.close(session.id, .restricted);
                break;
            }) |bytes| {
                if (policy.contains_fn(policy.context, bytes)) {
                    _ = self.close(session.id, .restricted);
                    break;
                }
            }
            if (session.phase == .closing) continue;
            if (!session.cursor.finished) {
                _ = lane.notifier.wake_fn(lane.notifier.context);
                continue;
            }
            const summary = buildSummary(session, material) catch |failure| {
                _ = self.close(session.id, if (failure == error.InvalidPreviewSource) .changed else .limit);
                continue;
            };
            const pending = session.pending.?;
            session.pending = null;
            session.phase = .ready;
            session.touched = .now(lane.io, .awake);
            sink.complete_fn(sink.context, .{ .request_id = pending.request_id, .resource_id = session.id, .kind = .open, .state = .ready, .summary = summary });
        };
    }
    pub fn hasSessions(self: *const Sessions) bool {
        for (self.slots) |slot| if (slot != null) return true;
        return false;
    }
    pub fn needsWake(self: *const Sessions) bool {
        for (self.slots) |slot| if (slot) |session| {
            if (session.phase != .debt) return true;
        };
        return false;
    }
    pub fn shutdown(self: *Sessions) !void {
        self.stopAdmission(.cancelled);
        const lane = self.lane orelse return;
        const result = lane.shutdown();
        // No worker uses Product target storage. Physical effects retain their
        // own copies and pins if cleanup could not be established.
        for (&self.slots) |*slot| if (slot.*) |session| {
            const allocator = session.allocator;
            session.target.deinit();
            allocator.destroy(session);
            slot.* = null;
        };
        try result;
    }
    pub fn closeAll(self: *Sessions, reason: State) void {
        for (self.slots) |slot| if (slot) |session| {
            _ = self.close(session.id, reason);
        };
    }
    pub fn stopAdmission(self: *Sessions, reason: State) void {
        self.stopping = true;
        self.closeAll(reason);
    }
    pub fn deinit(self: *Sessions) !void {
        try self.shutdown();
        if (self.lane) |lane| {
            const allocator = lane.allocator;
            try lane.deinit();
            allocator.destroy(lane);
        }
        self.* = .{};
    }
};

fn buildSummary(session: *Session, material: contract.Material) !Summary {
    if (material.source.size_bytes == 0 or std.mem.allEqual(u8, &material.source.sha256, 0)) return error.InvalidPreviewSource;
    if (session.target.input.expected) |expected| if (expected.size_bytes != material.source.size_bytes or !std.mem.eql(u8, &expected.sha256, &material.source.sha256)) return error.InvalidPreviewSource;
    const manifest = material.manifest;
    var count: usize = 0;
    if (material.grid) |grid| {
        if (grid.sheets.len > session.sheets.len) return error.PreviewLimit;
        for (grid.sheets, 0..) |sheet, index| {
            if (sheet.name.len > 512) return error.PreviewLimit;
            session.sheets[index] = .{ .index = @intCast(index + 1), .name = sheet.name, .hidden = sheet.hidden, .rows = sheet.rows, .columns = sheet.columns };
        }
        count = grid.sheets.len;
        session.sheet_count = @intCast(count);
    }
    if (manifest.pages) |pages| {
        if (pages.len > session.pages.len) return error.PreviewLimit;
        for (pages, 0..) |page, index| session.pages[index] = .{ .width = page.width, .height = page.height };
        session.page_count = @intCast(pages.len);
    }
    return .{ .format = manifest.format, .kind = manifest.kind, .source = material.source, .page_count = @intCast(if (manifest.pages) |pages| pages.len else 0), .sheets = session.sheets[0..count], .omissions = manifest.omissions, .text_scope = manifest.textScope, .layout = manifest.layout };
}
fn completePending(session: *Session, sink: Sink, state: State) void {
    const pending = session.pending orelse return;
    session.pending = null;
    sink.complete_fn(sink.context, .{ .request_id = pending.request_id, .resource_id = session.id, .kind = if (pending.request) |request| switch (request) {
        .page => .page,
        .region => .region,
    } else .open, .state = state });
}
fn regionBytes(cells: []const contract.Cell) usize {
    var total: usize = cells.len * 256;
    for (cells) |cell| {
        for ([_]?[]const u8{ cell.formula, cell.display, cell.formatCode, cell.alignment }) |text| if (text) |value| {
            total += value.len;
        };
        if (cell.value) |value| total += value.text.len;
    }
    return total;
}
pub fn failureState(failure: anyerror) State {
    return switch (failure) {
        error.StaleSecurityEpoch => .stale_security,
        error.UnknownOutput, error.MissingPreview, error.FileNotFound, error.NotDir => .missing,
        error.RestrictedOutput, error.RestrictedPreview, error.AccessDenied, error.InvalidOutputPath => .restricted,
        error.PreviewCapacity, error.PreviewBusy, error.QueueFull => .busy,
        error.OfficePreviewUnavailable => .unavailable,
        error.UnsupportedPreview => .unsupported,
        error.OutputChanged, error.PreviewResourceChanged, error.PreviewResourceDigest => .changed,
        error.PreviewSourceLimit, error.PreviewResourceLimit, error.PreviewPathTooLong, error.InvalidPreviewInput => .limit,
        error.Cancelled, error.Canceled => .cancelled,
        error.PreviewExpired, error.TimedOut => .expired,
        error.PreviewRestartRequired, error.PreviewResourcesOutstanding => .restart_required,
        else => .failed,
    };
}

const TestPolicy = struct {
    epoch: u64 = 1,
    allowed: bool = true,
    component: [32]u8 = @splat(1),
    fn get(context: *anyopaque) *TestPolicy {
        return @ptrCast(@alignCast(context));
    }
    fn validate(context: *anyopaque, target: *const Target) !void {
        const self = get(context);
        if (self.epoch != target.security_epoch) return error.StaleSecurityEpoch;
        if (!self.allowed) return error.RestrictedPreview;
        if (!std.mem.eql(u8, &self.component, &target.component)) return error.OfficePreviewUnavailable;
    }
    fn contains(_: *anyopaque, bytes: []const u8) bool {
        return std.mem.indexOf(u8, bytes, "SECRET-KEY") != null;
    }
    fn overlap(_: *anyopaque) !usize {
        return "SECRET-KEY".len - 1;
    }
    fn policy(self: *TestPolicy) Policy {
        return .{ .context = self, .validate_fn = validate, .contains_fn = contains, .overlap_fn = overlap };
    }
};
const TestEffect = struct {
    main_thread: std.Thread.Id,
    text: []const u8 = "safe source",
    grid: ?*const contract.Grid = null,
    manifest: ?*const contract.Manifest = null,
    blocked: bool = false,
    entered: std.Io.Event = .unset,
    gate: std.Io.Event = .unset,
    read_failure: ?anyerror = null,
    cancelled: std.atomic.Value(bool) = .init(false),
    cleaned: bool = false,
    releases: usize = 0,
    prepares: usize = 0,
    const pages = [_]contract.Page{.{ .file = "page-0001.png", .bytes = 4, .sha256 = "1" ** 64, .width = 1280, .height = 1656 }};
    const page_manifest: contract.Manifest = .{ .schema = 1, .format = .docx, .sourceText = .{ .file = "source-text.txt", .bytes = 1, .sha256 = "1" ** 64 }, .textScope = "fixture_without_ocr", .omissions = &.{}, .kind = .pages, .pages = @constCast(&pages) };
    const grid_manifest: contract.Manifest = .{ .schema = 1, .format = .xlsx, .sourceText = .{ .file = "source-text.txt", .bytes = 1, .sha256 = "1" ** 64 }, .textScope = "fixture_without_ocr", .omissions = &.{}, .kind = .grid, .sheetCount = 1 };
    fn get(context: *anyopaque) *TestEffect {
        return @ptrCast(@alignCast(context));
    }
    fn factory(self: *TestEffect) Factory {
        return .{ .context = self, .prepare_fn = create };
    }
    fn create(context: *anyopaque, _: contract.Input) !contract.Owned {
        const self = get(context);
        std.debug.assert(std.Thread.getCurrentId() == self.main_thread);
        return .{ .context = self, .prepare_fn = prepare, .material_fn = material, .read_fn = read, .cancel_fn = cancel, .cleanup_fn = cleanup, .release_fn = release };
    }
    fn prepare(context: *anyopaque) !void {
        const self = get(context);
        std.debug.assert(std.Thread.getCurrentId() != self.main_thread);
        self.prepares += 1;
        self.entered.set(std.testing.io);
        if (self.blocked) try self.gate.waitTimeout(std.testing.io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
        if (self.cancelled.load(.acquire)) return error.Cancelled;
    }
    fn material(context: *anyopaque) !contract.Material {
        const self = get(context);
        std.debug.assert(std.Thread.getCurrentId() == self.main_thread and !self.cleaned);
        return .{ .source = .{ .size_bytes = 1, .sha256 = @splat(1) }, .manifest = self.manifest orelse if (self.grid == null) &page_manifest else &grid_manifest, .grid = self.grid, .source_text = self.text };
    }
    fn read(context: *anyopaque, request: contract.Request) !contract.Read {
        const self = get(context);
        std.debug.assert(std.Thread.getCurrentId() != self.main_thread and !self.cleaned);
        if (self.read_failure) |failure| return failure;
        return .{ .allocator = std.testing.allocator, .value = switch (request) {
            .page => .{ .page = try std.testing.allocator.dupe(u8, "page") },
            .region => .{ .region = try std.testing.allocator.dupe(contract.Cell, self.grid.?.sheets[0].cells) },
        } };
    }
    fn cancel(context: *anyopaque) void {
        const self = get(context);
        self.cancelled.store(true, .release);
        self.gate.set(std.testing.io);
    }
    fn cleanup(context: *anyopaque) !void {
        const self = get(context);
        std.debug.assert(std.Thread.getCurrentId() != self.main_thread and !self.cleaned);
        self.cleaned = true;
    }
    fn release(context: *anyopaque) void {
        const self = get(context);
        std.debug.assert(std.Thread.getCurrentId() == self.main_thread and (self.cleaned or self.prepares == 0));
        self.releases += 1;
    }
};
const TestCapture = struct {
    effect: *const TestEffect,
    active: bool = true,
    calls: usize = 0,
    ready: usize = 0,
    released: usize = 0,
    last: State = .failed,
    last_kind: Kind = .open,
    page_count: u16 = 0,
    sheet_count: usize = 0,
    layout_ready: bool = false,
    fn get(context: *anyopaque) *TestCapture {
        return @ptrCast(@alignCast(context));
    }
    fn isActive(context: *anyopaque, _: u64) bool {
        return get(context).active;
    }
    fn complete(context: *anyopaque, result: Result) void {
        const self = get(context);
        if (result.state != .ready and result.state != .limit) std.debug.assert(self.effect.cleaned and self.effect.releases == 1);
        self.calls += 1;
        if (result.state == .ready) self.ready += 1;
        self.last = result.state;
        self.last_kind = result.kind;
        if (result.summary) |summary| {
            self.page_count = summary.page_count;
            self.sheet_count = summary.sheets.len;
            self.layout_ready = if (summary.layout) |layout| layout.state == .ready else false;
        }
    }
    fn releasedFn(context: *anyopaque, _: u64, _: State) void {
        get(context).released += 1;
    }
    fn sink(self: *TestCapture) Sink {
        return .{ .context = self, .active_fn = isActive, .complete_fn = complete, .released_fn = releasedFn };
    }
    fn wait(self: *TestCapture, sessions: *Sessions, policy: Policy, calls: usize, releases: usize) !void {
        const start: std.Io.Timestamp = .now(std.testing.io, .awake);
        while (start.durationTo(.now(std.testing.io, .awake)).toMilliseconds() < 5000) {
            sessions.drain(policy, self.sink());
            if (self.calls >= calls and self.released >= releases) return;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        }
        return error.TestTimeout;
    }
};
fn testTarget(expected: bool) !Target {
    const root = "C:/workspace";
    const relative = "report.docx";
    const storage = try std.testing.allocator.dupe(u8, root ++ relative);
    return .{ .allocator = std.testing.allocator, .storage = storage, .task_id = 3, .run_id = 7, .selector = .{ .output = @splat(2) }, .workspace_id = 1, .workspace_epoch = 2, .security_epoch = 1, .component = @splat(1), .input = .{ .workspace_root = storage[0..root.len], .relative_path = storage[root.len..], .expected = if (expected) .{ .size_bytes = 1, .sha256 = @splat(1) } else null } };
}
fn testWake(_: ?*anyopaque) bool {
    return true;
}
fn testOpen(sessions: *Sessions, policy: *TestPolicy, effect: *TestEffect) !u64 {
    var target = try testTarget(true);
    errdefer target.deinit();
    return sessions.open(std.testing.io, std.testing.allocator, .{ .context = null, .wake_fn = testWake }, policy.policy(), effect.factory(), target, 10);
}

test "session blocks all publication when source credential crosses scan steps" {
    var text: [physical.Scan.step_bytes + 64]u8 = @splat('x');
    @memcpy(text[physical.Scan.step_bytes - 4 ..][0.."SECRET-KEY".len], "SECRET-KEY");
    var effect: TestEffect = .{ .main_thread = std.Thread.getCurrentId(), .text = &text };
    var policy: TestPolicy = .{};
    var capture: TestCapture = .{ .effect = &effect };
    var sessions: Sessions = .{};
    defer sessions.deinit() catch unreachable;
    _ = try testOpen(&sessions, &policy, &effect);
    try capture.wait(&sessions, policy.policy(), 1, 1);
    try std.testing.expectEqual(State.restricted, capture.last);
    try std.testing.expectEqual(0, capture.ready);
    try std.testing.expectEqual(1, effect.releases);
}

test "session scans actual grid display before exposing a ready summary" {
    var cells = [_]contract.Cell{.{ .row = 1, .column = 1, .formula = null, .value = null, .display = "SECRET-KEY", .formatCode = "General", .formatSupported = true, .bold = false, .italic = false, .alignment = null }};
    var sheets = [_]contract.Sheet{.{ .id = "1", .name = "Sheet", .hidden = false, .rows = 1, .columns = 1, .cells = &cells }};
    const grid: contract.Grid = .{ .schema = 1, .calculation = "saved_values_only", .sheets = &sheets };
    var effect: TestEffect = .{ .main_thread = std.Thread.getCurrentId(), .grid = &grid };
    var policy: TestPolicy = .{};
    var capture: TestCapture = .{ .effect = &effect };
    var sessions: Sessions = .{};
    defer sessions.deinit() catch unreachable;
    _ = try testOpen(&sessions, &policy, &effect);
    try capture.wait(&sessions, policy.policy(), 1, 1);
    try std.testing.expectEqual(State.restricted, capture.last);
    try std.testing.expectEqual(0, capture.ready);
}

test "workbook session alternates regions and page transfers from one preparation" {
    var cells = [_]contract.Cell{.{ .row = 1, .column = 1, .formula = "=1+1", .value = .{ .kind = .number, .text = "2" }, .display = "2", .formatCode = "General", .formatSupported = true, .bold = false, .italic = false, .alignment = null }};
    var sheets = [_]contract.Sheet{.{ .id = "1", .name = "Sheet", .hidden = false, .rows = 1, .columns = 1, .cells = &cells }};
    const grid: contract.Grid = .{ .schema = 1, .calculation = "saved_values_only", .sheets = &sheets };
    var metadata = TestEffect.grid_manifest;
    metadata.pages = @constCast(&TestEffect.pages);
    metadata.layout = .{ .state = .ready, .omissions = &.{"missing_formula_caches"} };
    var effect: TestEffect = .{ .main_thread = std.Thread.getCurrentId(), .grid = &grid, .manifest = &metadata };
    var policy: TestPolicy = .{};
    var capture: TestCapture = .{ .effect = &effect };
    var sessions: Sessions = .{};
    defer sessions.deinit() catch unreachable;
    const id = try testOpen(&sessions, &policy, &effect);
    try capture.wait(&sessions, policy.policy(), 1, 0);
    try std.testing.expectEqual(1, capture.page_count);
    try std.testing.expectEqual(1, capture.sheet_count);
    try std.testing.expect(capture.layout_ready);
    const region: contract.Request = .{ .region = .{ .sheet = 1, .row = 1, .column = 1, .rows = 1, .columns = 1 } };
    try sessions.read(policy.policy(), id, 11, region);
    try capture.wait(&sessions, policy.policy(), 2, 0);
    try std.testing.expectEqual(Kind.region, capture.last_kind);
    try sessions.read(policy.policy(), id, 12, .{ .page = 0 });
    try capture.wait(&sessions, policy.policy(), 3, 0);
    try std.testing.expectEqualStrings("page", try sessions.chunk(policy.policy(), id, 0));
    sessions.releaseRead(id);
    try sessions.read(policy.policy(), id, 13, region);
    try capture.wait(&sessions, policy.policy(), 4, 0);
    try std.testing.expectEqual(Kind.region, capture.last_kind);
    try std.testing.expectEqual(1, effect.prepares);
    try std.testing.expectEqual(0, effect.releases);
    _ = sessions.close(id, .cancelled);
    try capture.wait(&sessions, policy.policy(), 4, 1);
    try std.testing.expectEqual(1, effect.releases);
}

test "page transfer revalidates security and keeps bytes until release" {
    var effect: TestEffect = .{ .main_thread = std.Thread.getCurrentId() };
    var policy: TestPolicy = .{};
    var capture: TestCapture = .{ .effect = &effect };
    var sessions: Sessions = .{};
    defer sessions.deinit() catch unreachable;
    const id = try testOpen(&sessions, &policy, &effect);
    try capture.wait(&sessions, policy.policy(), 1, 0);
    try std.testing.expectEqual(State.ready, capture.last);
    try sessions.read(policy.policy(), id, 11, .{ .page = 0 });
    try capture.wait(&sessions, policy.policy(), 2, 0);
    try std.testing.expectEqual(Kind.page, capture.last_kind);
    try std.testing.expectError(error.InvalidOffset, sessions.chunk(policy.policy(), id, 1));
    try std.testing.expectEqualStrings("page", try sessions.chunk(policy.policy(), id, 0));
    try std.testing.expectError(error.PreviewBusy, sessions.read(policy.policy(), id, 12, .{ .page = 0 }));
    policy.epoch += 1;
    try std.testing.expectError(error.StaleSecurityEpoch, sessions.chunk(policy.policy(), id, 4));
    try capture.wait(&sessions, policy.policy(), 2, 1);
    try std.testing.expectEqual(2, capture.calls);
    try std.testing.expectEqual(1, effect.releases);
}

test "connection revocation cancels preparation and settles after physical cleanup" {
    var effect: TestEffect = .{ .main_thread = std.Thread.getCurrentId(), .blocked = true };
    var policy: TestPolicy = .{};
    var capture: TestCapture = .{ .effect = &effect };
    var sessions: Sessions = .{};
    defer sessions.deinit() catch unreachable;
    defer effect.gate.set(std.testing.io);
    _ = try testOpen(&sessions, &policy, &effect);
    try effect.entered.waitTimeout(std.testing.io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
    capture.active = false;
    try capture.wait(&sessions, policy.policy(), 1, 1);
    try std.testing.expectEqual(State.cancelled, capture.last);
    try std.testing.expectEqual(0, capture.ready);
}

test "source failure and idle expiry each revoke sessions and release exactly once" {
    for ([_]bool{ false, true }) |expire| {
        var effect: TestEffect = .{ .main_thread = std.Thread.getCurrentId() };
        var policy: TestPolicy = .{};
        var capture: TestCapture = .{ .effect = &effect };
        var sessions: Sessions = .{};
        defer sessions.deinit() catch unreachable;
        const id = try testOpen(&sessions, &policy, &effect);
        try capture.wait(&sessions, policy.policy(), 1, 0);
        if (expire) {
            sessions.find(id).?.touched.nanoseconds -= 121 * std.time.ns_per_s;
            try capture.wait(&sessions, policy.policy(), 1, 1);
        } else {
            effect.read_failure = error.OutputChanged;
            try sessions.read(policy.policy(), id, 11, .{ .page = 0 });
            try capture.wait(&sessions, policy.policy(), 2, 1);
            try std.testing.expectEqual(State.changed, capture.last);
        }
        try std.testing.expectEqual(1, effect.releases);
        try std.testing.expect(!sessions.hasSessions());
    }
}

test "session refuses a mismatched delivered identity and component revocation" {
    for ([_]bool{ false, true }) |component_revoked| {
        var effect: TestEffect = .{ .main_thread = std.Thread.getCurrentId(), .blocked = true };
        var policy: TestPolicy = .{};
        var capture: TestCapture = .{ .effect = &effect };
        var sessions: Sessions = .{};
        defer sessions.deinit() catch unreachable;
        defer effect.gate.set(std.testing.io);
        var target = try testTarget(true);
        if (!component_revoked) target.input.expected.?.sha256[0] ^= 1;
        var owned = true;
        defer if (owned) target.deinit();
        _ = try sessions.open(std.testing.io, std.testing.allocator, .{ .context = null, .wake_fn = testWake }, policy.policy(), effect.factory(), target, 10);
        owned = false;
        try effect.entered.waitTimeout(std.testing.io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
        if (component_revoked) policy.component[0] ^= 1;
        effect.gate.set(std.testing.io);
        try capture.wait(&sessions, policy.policy(), 1, 1);
        try std.testing.expectEqual(if (component_revoked) State.unavailable else State.changed, capture.last);
        try std.testing.expectEqual(0, capture.ready);
    }
}
