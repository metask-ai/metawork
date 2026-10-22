//! Connection-scoped document grants, transport and native deadline wakes.
//! Product owns physical resources and content checks; this owner never gets
//! file paths, filesystem handles, component roots or process authority.
const std = @import("std");
const sdk = @import("native_sdk");
const product = @import("metawork_product_control");
const handlers = @import("handlers.zig");
pub const timer_id: u64 = 0x4d57444f;
pub const event_name = "metawork:document-preview-invalidated";
pub const Connection = struct { generation: u64, window_id: sdk.platform.WindowId };
pub const Platform = struct {
    context: ?*anyopaque,
    random_fn: *const fn (?*anyopaque, []u8) bool,
    emit_fn: *const fn (?*anyopaque, sdk.platform.WindowId, []const u8, []const u8) anyerror!void,
    start_timer_fn: *const fn (?*anyopaque, u64, u64, bool) anyerror!void,
    cancel_timer_fn: *const fn (?*anyopaque, u64) anyerror!void,
};
const Pending = struct {
    responder: sdk.bridge.AsyncResponder,
    request: [sdk.bridge.max_id_bytes]u8,
    length: usize,
    completion_id: u64,
    kind: enum { open, page, region, close },
    fn init(responder: sdk.bridge.AsyncResponder, request: []const u8, completion: u64, kind: @FieldType(Pending, "kind")) !Pending {
        if (request.len > sdk.bridge.max_id_bytes) return error.InvalidBridgeId;
        var result: Pending = .{ .responder = responder, .request = undefined, .length = request.len, .completion_id = completion, .kind = kind };
        @memcpy(result.request[0..request.len], request);
        return result;
    }
    fn state(self: Pending, value: product.DocumentPreviewState) void {
        respondState(self.responder, self.request[0..self.length], value);
    }
};
const Grant = struct {
    connection: Connection,
    preview_id: u64,
    resource_id: u64,
    security_epoch: u64,
    token: [48]u8,
    pending: ?Pending,
    close_waiter: ?Pending = null,
    last_read: u64 = 0,
    page_held: bool = false,
    opened: bool = false,
    closing: bool = false,
    debt: bool = false,
};

pub const Controller = struct {
    allocator: std.mem.Allocator,
    platform: Platform = undefined,
    control: ?*product.Runtime = null,
    connection: ?Connection = null,
    grants: [2]?*Grant = @splat(null),
    high_water: u64 = 0,
    next_completion: u64 = 1,
    timer_armed: bool = false,
    transport_failed: bool = false,

    pub fn bind(self: *Controller, control: *product.Runtime, platform: Platform) void {
        self.control = control;
        self.platform = platform;
    }
    pub fn connect(self: *Controller, connection: Connection) void {
        self.disconnect();
        self.connection = connection;
        self.high_water = 0;
    }
    pub fn disconnect(self: *Controller) void {
        self.connection = null;
        for (self.grants) |entry| if (entry) |grant| self.revoke(grant);
    }
    fn current(self: *const Controller, connection: Connection) bool {
        const connected = self.connection orelse return false;
        return std.meta.eql(connected, connection);
    }
    fn require(self: *const Controller, connection: Connection, generation: u64, preview_id: u64) !void {
        if (preview_id == 0 or generation == 0 or generation != connection.generation or !self.current(connection)) return error.InvalidBridgeId;
    }
    fn find(self: *Controller, connection: Connection, preview_id: u64) ?*Grant {
        for (self.grants) |entry| if (entry) |grant| if (grant.preview_id == preview_id and std.meta.eql(grant.connection, connection)) return grant;
        return null;
    }
    fn authorized(self: *Controller, connection: Connection, generation: u64, preview_id: u64, token: []const u8, epoch: u64) !*Grant {
        try self.require(connection, generation, preview_id);
        try handlers.validateDocumentToken(token);
        const grant = self.find(connection, preview_id) orelse return error.MissingPreview;
        if (!std.mem.eql(u8, &grant.token, token)) return error.RestrictedPreview;
        const control = self.control orelse return error.ExecutorShuttingDown;
        if (epoch == 0 or epoch != grant.security_epoch or epoch != control.projectionSecurityEpoch()) {
            self.revoke(grant);
            return error.StaleSecurityEpoch;
        }
        if (grant.closing or grant.debt or !grant.opened) return error.RestrictedPreview;
        return grant;
    }
    fn sequence(self: *Controller) !u64 {
        if (self.next_completion == std.math.maxInt(u64)) return error.PreviewCapacity;
        const result = self.next_completion;
        self.next_completion += 1;
        return result;
    }
    pub fn open(self: *Controller, connection: Connection, request: handlers.DocumentOpen, responder: sdk.bridge.AsyncResponder, request_id: []const u8) !void {
        try self.require(connection, request.generation.value, request.previewId.value);
        if (request.previewId.value <= self.high_water) return error.InvalidBridgeId;
        const selector = try request.target.selector();
        if (request.taskId.value == 0 or request.runId.value == 0) return error.InvalidBridgeId;
        self.high_water = request.previewId.value;
        const slot = for (&self.grants) |*entry| {
            if (entry.* == null) break entry;
        } else {
            respondState(responder, request_id, .busy);
            return;
        };
        const completion = try self.sequence();
        const grant = try self.allocator.create(Grant);
        var kept = false;
        defer if (!kept) self.allocator.destroy(grant);
        var random: [24]u8 = undefined;
        if (!self.platform.random_fn(self.platform.context, &random)) return error.RandomUnavailable;
        const control = self.control orelse return error.ExecutorShuttingDown;
        grant.* = .{ .connection = connection, .preview_id = request.previewId.value, .resource_id = 0, .security_epoch = control.projectionSecurityEpoch(), .token = std.fmt.bytesToHex(random, .lower), .pending = try Pending.init(responder, request_id, completion, .open) };
        switch (control.beginDocumentPreview(completion, request.taskId.value, request.runId.value, selector)) {
            .immediate => |state| respondState(responder, request_id, state),
            .queued => |id| {
                grant.resource_id = id;
                slot.* = grant;
                kept = true;
                self.updateTimer();
            },
        }
    }
    pub fn read(self: *Controller, connection: Connection, request: handlers.DocumentRead, responder: sdk.bridge.AsyncResponder, request_id: []const u8) !void {
        const grant = try self.authorized(connection, request.generation.value, request.previewId.value, request.token.value, request.securityEpoch.value);
        if (request.readId.value == 0 or request.readId.value <= grant.last_read) return error.InvalidBridgeId;
        if (grant.pending != null or grant.page_held) {
            respondState(responder, request_id, .busy);
            return;
        }
        const completion = try self.sequence();
        const kind: @FieldType(Pending, "kind") = switch (request.selection.value) {
            .page => .page,
            .region => .region,
        };
        const pending = try Pending.init(responder, request_id, completion, kind);
        (self.control orelse return error.ExecutorShuttingDown).readDocumentPreview(grant.resource_id, completion, request.selection.value) catch |failure| {
            respondState(responder, request_id, stateFor(failure));
            return;
        };
        grant.last_read = request.readId.value;
        grant.pending = pending;
        self.updateTimer();
    }
    pub fn chunk(self: *Controller, connection: Connection, request: handlers.DocumentChunk, output: []u8) ![]const u8 {
        const grant = self.authorized(connection, request.generation.value, request.previewId.value, request.token.value, request.securityEpoch.value) catch |failure| return writeState(output, stateFor(failure));
        if (request.readId.value != grant.last_read or !grant.page_held or grant.pending != null) return writeState(output, .restricted);
        const offset = std.math.cast(usize, request.offset.value) orelse return writeState(output, .restricted);
        const bytes = self.control.?.readDocumentPreviewChunk(grant.resource_id, offset) catch |failure| {
            self.revoke(grant);
            return writeState(output, stateFor(failure));
        };
        errdefer self.revoke(grant);
        var writer = std.Io.Writer.fixed(output);
        try writer.print("{{\"state\":\"ready\",\"readId\":\"{d}\",\"offset\":\"{d}\",\"bytes\":\"{d}\",\"dataBase64\":\"", .{ grant.last_read, offset, bytes.len });
        const encoded = try writer.writableSlice(std.base64.standard.Encoder.calcSize(bytes.len));
        _ = std.base64.standard.Encoder.encode(encoded, bytes);
        try writer.writeAll("\"}");
        return writer.buffered();
    }
    pub fn releaseRead(self: *Controller, connection: Connection, request: handlers.DocumentReadKey, output: []u8) ![]const u8 {
        const grant = self.authorized(connection, request.generation.value, request.previewId.value, request.token.value, request.securityEpoch.value) catch |failure| return writeState(output, stateFor(failure));
        if (request.readId.value == 0 or request.readId.value != grant.last_read) return writeState(output, .restricted);
        if (grant.pending != null) return writeState(output, .busy);
        self.control.?.releaseDocumentPreviewRead(grant.resource_id);
        grant.page_held = false;
        return std.fmt.bufPrint(output, "{{\"state\":\"ready\",\"readId\":\"{d}\",\"released\":true}}", .{grant.last_read});
    }
    pub fn close(self: *Controller, connection: Connection, request: handlers.DocumentKey, responder: sdk.bridge.AsyncResponder, request_id: []const u8) !void {
        try self.require(connection, request.generation.value, request.previewId.value);
        self.high_water = @max(self.high_water, request.previewId.value);
        const waiter = try Pending.init(responder, request_id, 0, .close);
        const grant = self.find(connection, request.previewId.value) orelse {
            respondClose(waiter, connection.generation, request.previewId.value, true);
            return;
        };
        if (grant.debt) {
            respondClose(waiter, connection.generation, grant.preview_id, false);
            return;
        }
        if (grant.close_waiter != null) {
            waiter.state(.busy);
            return;
        }
        grant.close_waiter = waiter;
        self.revoke(grant);
        self.updateTimer();
    }
    fn revoke(self: *Controller, grant: *Grant) void {
        grant.closing = true;
        grant.page_held = false;
        if (self.control) |control| _ = control.closeDocumentPreview(grant.resource_id);
    }
    pub fn sink(self: *Controller) product.DocumentPreviewSink {
        return .{ .context = self, .active_fn = active, .complete_fn = complete, .released_fn = released };
    }
    fn active(context: *anyopaque, resource_id: u64) bool {
        const self: *Controller = @ptrCast(@alignCast(context));
        for (self.grants) |entry| if (entry) |grant| if (grant.resource_id == resource_id) return !grant.closing and !grant.debt and self.current(grant.connection);
        return false;
    }
    fn complete(context: *anyopaque, result: product.DocumentPreviewResult) void {
        const self: *Controller = @ptrCast(@alignCast(context));
        const control = self.control orelse return;
        for (self.grants) |entry| if (entry) |grant| {
            if (grant.resource_id != result.resource_id) continue;
            const pending = grant.pending orelse return;
            if (pending.completion_id != result.request_id) return;
            grant.pending = null;
            const state: product.DocumentPreviewState = if (!self.current(grant.connection) or grant.closing) .cancelled else if (grant.security_epoch != control.projectionSecurityEpoch()) .stale_security else result.state;
            if (state != .ready) {
                pending.state(state);
                if (state != .limit and state != .busy) self.revoke(grant);
                return;
            }
            const buffer = self.allocator.alloc(u8, sdk.bridge.max_result_bytes) catch {
                pending.state(.failed);
                self.revoke(grant);
                return;
            };
            defer {
                std.crypto.secureZero(u8, buffer);
                self.allocator.free(buffer);
            }
            var writer = std.Io.Writer.fixed(buffer);
            encodeResult(&writer, grant, pending, result) catch {
                pending.state(.failed);
                self.revoke(grant);
                return;
            };
            if (pending.kind == .open) grant.opened = true;
            if (pending.kind == .page) grant.page_held = true;
            pending.responder.success(pending.request[0..pending.length], writer.buffered()) catch {
                self.revoke(grant);
            };
            return;
        };
    }
    fn released(context: *anyopaque, resource_id: u64, reason: product.DocumentPreviewState) void {
        const self: *Controller = @ptrCast(@alignCast(context));
        for (&self.grants) |*entry| if (entry.*) |grant| {
            if (grant.resource_id != resource_id) continue;
            grant.closing = true;
            grant.page_held = false;
            grant.debt = reason == .restart_required;
            if (grant.pending) |pending| {
                grant.pending = null;
                pending.state(reason);
            }
            if (grant.close_waiter) |waiter| {
                grant.close_waiter = null;
                respondClose(waiter, grant.connection.generation, grant.preview_id, !grant.debt);
            }
            if (self.current(grant.connection)) {
                var buffer: [512]u8 = undefined;
                const bytes = std.fmt.bufPrint(&buffer, "{{\"generation\":\"{d}\",\"previewId\":\"{d}\",\"token\":\"{s}\",\"reason\":\"{s}\"}}", .{ grant.connection.generation, grant.preview_id, grant.token, stateName(reason) }) catch unreachable;
                self.platform.emit_fn(self.platform.context, grant.connection.window_id, event_name, bytes) catch {
                    self.transport_failed = true;
                };
            }
            if (!grant.debt) {
                self.allocator.destroy(grant);
                entry.* = null;
            }
            return;
        };
    }
    pub fn drain(self: *Controller) void {
        if (self.control) |control| control.drainDocumentPreviews(self.sink());
        self.updateTimer();
    }
    fn updateTimer(self: *Controller) void {
        const needed = if (self.control) |control| control.documentPreviewNeedsWake() else false;
        if (needed and !self.timer_armed) {
            self.platform.start_timer_fn(self.platform.context, timer_id, 250 * std.time.ns_per_ms, true) catch {
                self.transport_failed = true;
                self.disconnect();
                return;
            };
            self.timer_armed = true;
        } else if (!needed and self.timer_armed) {
            self.platform.cancel_timer_fn(self.platform.context, timer_id) catch {};
            self.timer_armed = false;
        }
    }
    /// Application joined Product document execution before settling SDK
    /// responders. restart_required never claims physical resources released.
    pub fn settle(self: *Controller) void {
        self.disconnect();
        for (&self.grants) |*entry| if (entry.*) |grant| {
            const physically_released = if (self.control) |control| control.documentPreviewResourceReleased(grant.resource_id) else false;
            if (grant.pending) |pending| pending.state(if (physically_released) .cancelled else .restart_required);
            if (grant.close_waiter) |waiter| respondClose(waiter, grant.connection.generation, grant.preview_id, physically_released);
            self.allocator.destroy(grant);
            entry.* = null;
        };
        if (self.timer_armed) self.platform.cancel_timer_fn(self.platform.context, timer_id) catch {};
        self.timer_armed = false;
    }
};

fn encodeResult(writer: *std.Io.Writer, grant: *const Grant, pending: Pending, result: product.DocumentPreviewResult) !void {
    switch (pending.kind) {
        .open => {
            const summary = result.summary orelse return error.InvalidDocumentResult;
            try writer.print("{{\"state\":\"ready\",\"generation\":\"{d}\",\"previewId\":\"{d}\",\"token\":\"{s}\",\"securityEpoch\":\"{d}\",\"sourceVersion\":\"{s}\",\"sourceBytes\":\"{d}\",\"idleMs\":\"{d}\",\"lifetimeMs\":\"{d}\",\"format\":\"{s}\",\"kind\":\"{s}\",\"pageCount\":{d},\"sheets\":", .{ grant.connection.generation, grant.preview_id, grant.token, grant.security_epoch, std.fmt.bytesToHex(summary.source.sha256, .lower), summary.source.size_bytes, product.DocumentPreviewLimits.idle_ms, product.DocumentPreviewLimits.lifetime_ms, @tagName(summary.format), @tagName(summary.kind), summary.page_count });
            try std.json.Stringify.value(summary.sheets, .{}, writer);
            try writer.writeAll(",\"omissions\":");
            try std.json.Stringify.value(summary.omissions, .{}, writer);
            try writer.writeAll(",\"textScope\":");
            try std.json.Stringify.value(summary.text_scope, .{}, writer);
            try writer.writeAll(",\"layout\":");
            try std.json.Stringify.value(summary.layout, .{}, writer);
            try writer.writeByte('}');
        },
        .page => {
            const page = result.page orelse return error.InvalidDocumentResult;
            try writer.print("{{\"state\":\"ready\",\"kind\":\"page\",\"readId\":\"{d}\",\"securityEpoch\":\"{d}\",\"transferMs\":\"{d}\",\"image\":{{\"mediaType\":\"image/png\",\"sizeBytes\":\"{d}\",\"chunkBytes\":\"{d}\",\"width\":{d},\"height\":{d}}}}}", .{ grant.last_read, grant.security_epoch, product.DocumentPreviewLimits.transfer_ms, page.size_bytes, product.DocumentPreviewLimits.chunk_bytes, page.width, page.height });
        },
        .region => {
            const region = result.region orelse return error.InvalidDocumentResult;
            try writer.print("{{\"state\":\"ready\",\"kind\":\"region\",\"readId\":\"{d}\",\"securityEpoch\":\"{d}\",\"sheet\":{d},\"row\":{d},\"column\":{d},\"rows\":{d},\"columns\":{d},\"cells\":", .{ grant.last_read, grant.security_epoch, region.request.sheet, region.request.row, region.request.column, region.request.rows, region.request.columns });
            try std.json.Stringify.value(region.cells, .{}, writer);
            try writer.writeByte('}');
        },
        .close => return error.InvalidDocumentResult,
    }
}
pub fn stateName(state: product.DocumentPreviewState) []const u8 {
    return if (state == .failed) "error" else @tagName(state);
}
fn stateFor(failure: anyerror) product.DocumentPreviewState {
    return switch (failure) {
        error.StaleSecurityEpoch => .stale_security,
        error.MissingPreview, error.UnknownOutput => .missing,
        error.PreviewBusy, error.PreviewCapacity => .busy,
        error.PreviewExpired => .expired,
        error.OfficePreviewUnavailable => .unavailable,
        error.RestrictedPreview, error.RestrictedOutput, error.InvalidOffset => .restricted,
        else => .failed,
    };
}
pub fn respondState(responder: sdk.bridge.AsyncResponder, request_id: []const u8, state: product.DocumentPreviewState) void {
    var buffer: [96]u8 = undefined;
    responder.success(request_id, writeState(&buffer, state) catch unreachable) catch {};
}
fn writeState(output: []u8, state: product.DocumentPreviewState) ![]const u8 {
    return std.fmt.bufPrint(output, "{{\"state\":\"{s}\"}}", .{stateName(state)});
}
fn respondClose(pending: Pending, generation: u64, preview_id: u64, released: bool) void {
    var buffer: [256]u8 = undefined;
    const bytes = std.fmt.bufPrint(&buffer, "{{\"state\":\"{s}\",\"generation\":\"{d}\",\"previewId\":\"{d}\",\"released\":{}}}", .{ if (released) "ready" else "restart_required", generation, preview_id, released }) catch unreachable;
    pending.responder.success(pending.request[0..pending.length], bytes) catch {};
}

test "document encoder matches the cross-language fixture without private material" {
    var fixture = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, @embedFile("document_preview.fixture"), .{});
    defer fixture.deinit();
    const grant: Grant = .{ .connection = .{ .generation = 1, .window_id = 3 }, .preview_id = 2, .resource_id = 1, .security_epoch = 1, .token = [_]u8{ '0', '7' } ** 24, .pending = null, .last_read = 1 };
    var pending: Pending = .{ .responder = undefined, .request = undefined, .length = 0, .completion_id = 1, .kind = .open };
    const result: product.DocumentPreviewResult = .{ .request_id = 1, .resource_id = 1, .kind = .open, .state = .ready, .summary = .{ .format = .docx, .kind = .pages, .source = .{ .size_bytes = 42, .sha256 = @splat(2) }, .page_count = 1, .sheets = &.{}, .omissions = &.{}, .text_scope = "ooxml_xml_text_and_attributes_without_ocr" } };
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try encodeResult(&writer, &grant, pending, result);
    const expected = try std.json.Stringify.valueAlloc(std.testing.allocator, fixture.value.object.get("open").?, .{});
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, writer.buffered());
    var pdf_result = result;
    pdf_result.summary.?.format = .pdf;
    pdf_result.summary.?.text_scope = "pdf_reachable_strings_xmp_and_decoded_page_text_without_ocr";
    writer = .fixed(&buffer);
    try encodeResult(&writer, &grant, pending, pdf_result);
    const pdf_expected = try std.json.Stringify.valueAlloc(std.testing.allocator, fixture.value.object.get("openPdf").?, .{});
    defer std.testing.allocator.free(pdf_expected);
    try std.testing.expectEqualStrings(pdf_expected, writer.buffered());
    var workbook = result;
    workbook.summary.?.format = .xlsx;
    workbook.summary.?.kind = .grid;
    workbook.summary.?.page_count = 2;
    workbook.summary.?.sheets = &.{.{ .index = 1, .name = "Data", .hidden = false, .rows = 2, .columns = 2 }};
    workbook.summary.?.omissions = &.{"charts"};
    workbook.summary.?.text_scope = "ooxml_xml_and_available_layout_pdf_text_without_ocr";
    workbook.summary.?.layout = .{ .state = .ready, .omissions = &.{"missing_formula_caches"} };
    writer = .fixed(&buffer);
    try encodeResult(&writer, &grant, pending, workbook);
    const workbook_expected = try std.json.Stringify.valueAlloc(std.testing.allocator, fixture.value.object.get("openWorkbook").?, .{});
    defer std.testing.allocator.free(workbook_expected);
    try std.testing.expectEqualStrings(workbook_expected, writer.buffered());
    pending.kind = .page;
    writer = .fixed(&buffer);
    try encodeResult(&writer, &grant, pending, .{ .request_id = 1, .resource_id = 1, .kind = .page, .state = .ready, .page = .{ .size_bytes = 4, .width = 1280, .height = 1656 } });
    const page = try std.json.Stringify.valueAlloc(std.testing.allocator, fixture.value.object.get("page").?, .{});
    defer std.testing.allocator.free(page);
    try std.testing.expectEqualStrings(page, writer.buffered());
}

const TestHost = struct {
    timer_starts: usize = 0,
    timer_stops: usize = 0,
    invalidated: usize = 0,
    calls: usize = 0,
    response: ?[]u8 = null,
    fn get(context: *anyopaque) *TestHost {
        return @ptrCast(@alignCast(context));
    }
    fn random(_: ?*anyopaque, bytes: []u8) bool {
        @memset(bytes, 7);
        return true;
    }
    fn timer(context: ?*anyopaque, id: u64, interval: u64, repeating: bool) !void {
        const self = get(context.?);
        try std.testing.expectEqual(timer_id, id);
        try std.testing.expectEqual(@as(u64, 250 * std.time.ns_per_ms), interval);
        try std.testing.expect(repeating);
        self.timer_starts += 1;
    }
    fn cancelTimer(context: ?*anyopaque, _: u64) !void {
        get(context.?).timer_stops += 1;
    }
    fn emit(context: ?*anyopaque, window: u64, name: []const u8, _: []const u8) !void {
        try std.testing.expectEqual(@as(u64, 3), window);
        try std.testing.expectEqualStrings(event_name, name);
        get(context.?).invalidated += 1;
    }
    fn platform(self: *TestHost) Platform {
        return .{ .context = self, .random_fn = random, .emit_fn = emit, .start_timer_fn = timer, .cancel_timer_fn = cancelTimer };
    }
    fn receive(context: *anyopaque, _: sdk.bridge.Source, bytes: []const u8) !void {
        const self = get(context);
        if (self.response) |old| std.testing.allocator.free(old);
        self.response = try std.testing.allocator.dupe(u8, bytes);
        self.calls += 1;
    }
    fn responder(self: *TestHost) sdk.bridge.AsyncResponder {
        return .{ .context = self, .source = .{ .origin = "zero://app", .window_id = 3 }, .respond_fn = receive };
    }
    fn deinit(self: *TestHost) void {
        if (self.response) |bytes| std.testing.allocator.free(bytes);
    }
    fn wait(self: *TestHost, boundary: *Controller, count: usize) !void {
        const start: std.Io.Timestamp = .now(std.testing.io, .awake);
        while (start.durationTo(.now(std.testing.io, .awake)).toMilliseconds() < 5000) {
            boundary.drain();
            if (self.calls >= count) return;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        }
        return error.TestTimeout;
    }
};
fn testOpenRequest(preview_id: u64) handlers.DocumentOpen {
    return .{ .generation = .{ .value = 1 }, .previewId = .{ .value = preview_id }, .taskId = .{ .value = 3 }, .runId = .{ .value = 7 }, .target = .{ .kind = .{ .value = .output }, .id = .{ .value = "03030303030303030303030303030303" } } };
}

test "document grants serialize reads and bind tokens window generation and release identity" {
    var effect: product.TestSupport.DocumentEffect = .{ .main_thread = std.Thread.getCurrentId(), .text = "safe" };
    var control = try product.TestSupport.documentPreviewFixture(&effect);
    defer control.deinit();
    var host: TestHost = .{};
    defer host.deinit();
    var boundary: Controller = .{ .allocator = std.testing.allocator };
    boundary.bind(&control, host.platform());
    defer boundary.settle();
    const connection: Connection = .{ .generation = 1, .window_id = 3 };
    boundary.connect(connection);
    try boundary.open(connection, testOpenRequest(2), host.responder(), "open");
    try host.wait(&boundary, 1);
    const grant = boundary.find(connection, 2).?;
    const token = grant.token;
    const epoch = grant.security_epoch;
    try std.testing.expect(grant.opened and boundary.timer_armed and host.timer_starts == 1);
    var selection: handlers.DocumentRead = .{ .generation = .{ .value = 1 }, .previewId = .{ .value = 2 }, .token = .{ .value = &token }, .securityEpoch = .{ .value = epoch }, .readId = .{ .value = 1 }, .selection = .{ .value = .{ .page = 0 } } };
    try std.testing.expectError(error.InvalidBridgeId, boundary.read(.{ .generation = 1, .window_id = 4 }, selection, host.responder(), "foreign"));
    selection.token.value = "00" ** 24;
    try std.testing.expectError(error.RestrictedPreview, boundary.read(connection, selection, host.responder(), "wrong-token"));
    selection.token.value = &token;
    try boundary.read(connection, selection, host.responder(), "page");
    try host.wait(&boundary, 2);
    var buffer: [1024]u8 = undefined;
    const read_key: handlers.DocumentReadKey = .{ .generation = .{ .value = 1 }, .previewId = .{ .value = 2 }, .token = .{ .value = &token }, .securityEpoch = .{ .value = epoch }, .readId = .{ .value = 1 } };
    const chunk_bytes = try boundary.chunk(connection, .{ .generation = read_key.generation, .previewId = read_key.previewId, .token = read_key.token, .securityEpoch = read_key.securityEpoch, .readId = read_key.readId, .offset = .{ .value = 0 } }, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, chunk_bytes, "cGFnZQ==") != null);
    _ = try boundary.releaseRead(connection, read_key, &buffer);
    selection.readId.value = 2;
    try boundary.read(connection, selection, host.responder(), "next-page");
    try host.wait(&boundary, 3);
    const stale = try boundary.releaseRead(connection, read_key, &buffer);
    try std.testing.expectEqualStrings("{\"state\":\"restricted\"}", stale);
    try std.testing.expect(grant.page_held);
    try boundary.close(connection, .{ .generation = .{ .value = 1 }, .previewId = .{ .value = 2 } }, host.responder(), "close");
    try host.wait(&boundary, 4);
    try std.testing.expectEqual(1, effect.releases);
    try std.testing.expectEqual(1, host.invalidated);
    try std.testing.expect(host.timer_stops != 0);
    try std.testing.expect(std.mem.indexOf(u8, host.response.?, "\"released\":true") != null);
}

test "closing before a late open prevents resource recreation" {
    var effect: product.TestSupport.DocumentEffect = .{ .main_thread = std.Thread.getCurrentId(), .text = "safe" };
    var control = try product.TestSupport.documentPreviewFixture(&effect);
    defer control.deinit();
    var host: TestHost = .{};
    defer host.deinit();
    var boundary: Controller = .{ .allocator = std.testing.allocator };
    boundary.bind(&control, host.platform());
    defer boundary.settle();
    const connection: Connection = .{ .generation = 1, .window_id = 3 };
    boundary.connect(connection);
    try boundary.close(connection, .{ .generation = .{ .value = 1 }, .previewId = .{ .value = 8 } }, host.responder(), "close-first");
    try std.testing.expectError(error.InvalidBridgeId, boundary.open(connection, testOpenRequest(8), host.responder(), "late-open"));
    try std.testing.expect(!control.documentPreviewNeedsWake());
}

test "shutdown never reports a retained physical resource released" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var effect: product.TestSupport.DocumentEffect = .{ .main_thread = std.Thread.getCurrentId(), .text = "safe", .cleanup_failure = true };
    var control = try product.TestSupport.documentPreviewFixture(&effect);
    defer control.deinit();
    var host: TestHost = .{};
    defer host.deinit();
    var boundary: Controller = .{ .allocator = std.testing.allocator };
    boundary.bind(&control, host.platform());
    defer boundary.settle();
    const connection: Connection = .{ .generation = 1, .window_id = 3 };
    boundary.connect(connection);
    // Only the deliberately retained physical fixture uses the arena. Product
    // history and the response/grant owner keep their normal allocators.
    control.allocator = arena.allocator();
    try boundary.open(connection, testOpenRequest(2), host.responder(), "open");
    control.allocator = std.testing.allocator;
    try host.wait(&boundary, 1);
    try boundary.close(connection, .{ .generation = .{ .value = 1 }, .previewId = .{ .value = 2 } }, host.responder(), "close");
    control.shutdownDocumentPreviews();
    boundary.settle();
    try std.testing.expectEqual(0, effect.releases);
    try std.testing.expect(std.mem.indexOf(u8, host.response.?, "\"released\":false") != null);
}
