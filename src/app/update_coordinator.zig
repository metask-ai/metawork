//! Update-only lifecycle coordinator. Jobs hold owned requests and a narrow
//! transport, never Product state, Account credentials or a Native Runtime.
const std = @import("std");
const update = @import("metawork_product_update");
const http = @import("update_http_transport.zig");

pub const timer_id: u64 = 0x4d575550;
pub const Outcome = update.CommandOutcome;
pub const Host = struct {
    context: ?*anyopaque,
    now_ns_fn: *const fn (?*anyopaque) u64,
    wake_fn: *const fn (?*anyopaque) anyerror!void,
    start_timer_fn: *const fn (?*anyopaque, u64, u64, bool) anyerror!void,
    cancel_timer_fn: *const fn (?*anyopaque, u64) anyerror!void,
    open_fn: *const fn (?*anyopaque, []const u8) anyerror!void,
    on_main_thread_fn: *const fn (?*anyopaque) bool,
};

const Work = union(enum) { check: update.CheckPreparation, download: update.DownloadPreparation };
const Job = struct {
    allocator: std.mem.Allocator,
    transport: http.Transport,
    work: Work,
    cancellation: http.Cancellation,
    wake_context: ?*anyopaque,
    wake_fn: *const fn (?*anyopaque) anyerror!void,
    finished: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    check_completion: update.CheckCompletion = .{ .failed = .unavailable },
    head_result: update.HeadResult = .network,

    fn run(self: *Job) void {
        defer {
            self.finished.store(true, .release);
            self.wake_fn(self.wake_context) catch {};
        }
        var buffer: [update.Limits.manifest_bytes]u8 = undefined;
        const request: http.Request = switch (self.work) {
            .check => .manifest,
            .download => |value| .{ .download = value.url },
        };
        const response = self.transport.perform_fn(self.transport.context, request, &buffer, &self.cancellation) catch |err| {
            self.check_completion = .{ .failed = switch (err) {
                error.Timeout => .timeout,
                error.InvalidResponse => .invalid_manifest,
                else => .network,
            } };
            self.head_result = if (err == error.Timeout) .timeout else .network;
            return;
        };
        switch (self.work) {
            .check => |input| {
                if (response.status != 200) {
                    self.check_completion = .{ .failed = .network };
                    return;
                }
                if (response.body_len > buffer.len) {
                    self.check_completion = .{ .failed = .invalid_manifest };
                    return;
                }
                const release = update.parseManifest(self.allocator, buffer[0..response.body_len], input.target) catch {
                    self.check_completion = .{ .failed = .invalid_manifest };
                    return;
                };
                self.check_completion = .{ .release = release };
            },
            .download => self.head_result = update.headResult(response.status),
        }
    }

    fn join(self: *Job) void {
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }

    fn destroy(self: *Job) void {
        std.debug.assert(self.thread == null);
        self.allocator.destroy(self);
    }
};

pub const Coordinator = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    management: update.Management,
    transport: http.Transport,
    host: Host,
    check: ?*Job = null,
    download: ?*Job = null,
    stopped: bool = true,

    fn now(self: *const Coordinator) u64 {
        return self.host.now_ns_fn(self.host.context) / std.time.ns_per_ms;
    }

    fn assertMain(self: *const Coordinator) void {
        std.debug.assert(self.host.on_main_thread_fn(self.host.context));
    }

    pub fn start(self: *Coordinator, automatic: bool) void {
        self.assertMain();
        self.stopped = false;
        self.management.start_fn(self.management.context, self.now(), automatic);
        self.reconcileTimer();
    }

    fn startJob(self: *Coordinator, work: Work) !*Job {
        const job = try self.allocator.create(Job);
        errdefer self.allocator.destroy(job);
        job.* = .{ .allocator = self.allocator, .transport = self.transport, .work = work, .cancellation = .{ .io = self.io }, .wake_context = self.host.context, .wake_fn = self.host.wake_fn };
        job.thread = try std.Thread.spawn(.{}, Job.run, .{job});
        return job;
    }

    pub fn requestCheck(self: *Coordinator) Outcome {
        self.assertMain();
        if (self.stopped) return .unavailable;
        if (self.check != null) return .accepted;
        const input = self.management.begin_check_fn(self.management.context, self.now()) orelse return .unavailable;
        self.check = self.startJob(.{ .check = input }) catch {
            self.management.complete_check_fn(self.management.context, input.id, .{ .failed = .unavailable });
            return .unavailable;
        };
        self.reconcileTimer();
        return if (self.stopped) .unavailable else .accepted;
    }

    pub fn requestDownload(self: *Coordinator, expected_version: []const u8) Outcome {
        self.assertMain();
        if (self.stopped) return .unavailable;
        if (self.download) |job| {
            // A new document cannot coalesce onto a revoked old document's
            // job, even while that job is finishing its cancellation drain.
            if (job.cancellation.state.load(.acquire) != 0) return .unavailable;
            return if (std.mem.eql(u8, expected_version, job.work.download.version.text.slice())) .accepted else .rejected;
        }
        const input = self.management.begin_download_fn(self.management.context, expected_version) orelse return .rejected;
        self.download = self.startJob(.{ .download = input }) catch {
            _ = self.management.complete_download_fn(self.management.context, input.id, .network);
            return .unavailable;
        };
        self.reconcileTimer();
        return if (self.stopped) .unavailable else .accepted;
    }

    pub fn openWebsite(self: *Coordinator) bool {
        self.assertMain();
        if (self.stopped) return false;
        self.host.open_fn(self.host.context, update.website_url) catch return false;
        return true;
    }

    pub fn cancelDownload(self: *Coordinator) void {
        self.assertMain();
        if (self.download) |job| job.cancellation.cancel();
        self.management.cancel_download_fn(self.management.context);
    }

    pub fn drain(self: *Coordinator) void {
        self.assertMain();
        if (self.stopped) return;
        if (self.check) |job| if (job.finished.load(.acquire)) {
            job.join();
            self.management.complete_check_fn(self.management.context, job.work.check.id, job.check_completion);
            job.destroy();
            self.check = null;
        };
        if (self.download) |job| if (job.finished.load(.acquire)) {
            job.join();
            if (self.management.complete_download_fn(self.management.context, job.work.download.id, job.head_result)) |url| {
                const opened = if (self.host.open_fn(self.host.context, url.slice())) |_| true else |_| false;
                self.management.browser_result_fn(self.management.context, opened);
            }
            job.destroy();
            self.download = null;
        };
        self.reconcileTimer();
    }

    pub fn onTimer(self: *Coordinator) void {
        self.assertMain();
        if (self.stopped) return;
        self.drain();
        if (self.management.next_check_fn(self.management.context)) |at| if (self.now() >= at) {
            _ = self.requestCheck();
        };
        self.reconcileTimer();
    }

    fn reconcileTimer(self: *Coordinator) void {
        if (self.stopped) return;
        const busy = self.check != null or self.download != null;
        const next = self.management.next_check_fn(self.management.context);
        const ms: u64 = if (busy) 50 else if (next) |at| @max(1, at -| self.now()) else {
            self.host.cancel_timer_fn(self.host.context, timer_id) catch {};
            return;
        };
        // This short timer is also the completion wake recovery path. No
        // Renderer polling or Agent worker is needed to finish a request.
        self.host.start_timer_fn(self.host.context, timer_id, ms *| std.time.ns_per_ms, false) catch self.shutdown();
    }

    pub fn shutdown(self: *Coordinator) void {
        self.assertMain();
        if (self.stopped) return;
        self.stopped = true;
        self.management.stop_fn(self.management.context);
        self.host.cancel_timer_fn(self.host.context, timer_id) catch {};
        if (self.check) |job| job.cancellation.cancel();
        if (self.download) |job| job.cancellation.cancel();
        if (self.check) |job| {
            job.join();
            job.destroy();
        }
        if (self.download) |job| {
            job.join();
            job.destroy();
        }
        self.check = null;
        self.download = null;
    }
};

const TestHost = struct {
    state: update.Runtime,
    main_thread: std.Thread.Id,
    now_ms: u64 = 0,
    timer_ns: ?u64 = null,
    timer_fails: bool = false,
    wake_fails: bool = false,
    browser_fails: bool = false,
    opened: usize = 0,
    last_url: [update.Limits.url_bytes]u8 = undefined,
    last_url_len: usize = 0,
    requests: std.atomic.Value(u32) = .init(0),
    head_status: u16 = 200,
    block_download: bool = false,
    block_check: bool = false,
    body: []const u8 = "{\"version\":\"0.2.8\",\"downloads\":{\"macos\":{\"arm64\":\"https://downloads.metask-ai.com/metawork/new.dmg?release=0.2.8\"}}}",

    fn init() !TestHost {
        return .{ .state = try update.Runtime.init("0.2.7", .{ .os = .macos, .arch = .arm64 }), .main_thread = std.Thread.getCurrentId() };
    }
    fn owner(context: *anyopaque) *TestHost {
        return @ptrCast(@alignCast(context));
    }
    fn start(context: *anyopaque, ms: u64, automatic: bool) void {
        owner(context).state.start(ms, automatic);
    }
    fn next(context: *anyopaque) ?u64 {
        return owner(context).state.next_check_ms;
    }
    fn beginCheck(context: *anyopaque, ms: u64) ?update.CheckPreparation {
        const self = owner(context);
        return .{ .id = self.state.beginCheck(ms) orelse return null, .target = self.state.target };
    }
    fn completeCheck(context: *anyopaque, id: u64, completion: update.CheckCompletion) void {
        const self = owner(context);
        std.debug.assert(std.Thread.getCurrentId() == self.main_thread);
        _ = self.state.completeCheck(id, completion);
    }
    fn beginDownload(context: *anyopaque, version: []const u8) ?update.DownloadPreparation {
        return owner(context).state.beginDownload(version);
    }
    fn completeDownload(context: *anyopaque, id: u64, result: update.HeadResult) ?update.Url {
        const self = owner(context);
        std.debug.assert(std.Thread.getCurrentId() == self.main_thread);
        return self.state.completeDownload(id, result);
    }
    fn browserResult(context: *anyopaque, opened: bool) void {
        owner(context).state.browserResult(opened);
    }
    fn cancel(context: *anyopaque) void {
        owner(context).state.cancelDownload();
    }
    fn stop(context: *anyopaque) void {
        owner(context).state.stop();
    }
    fn now(context: ?*anyopaque) u64 {
        return owner(context.?).now_ms * std.time.ns_per_ms;
    }
    fn wake(context: ?*anyopaque) !void {
        if (owner(context.?).wake_fails) return error.InjectedWakeFailure;
    }
    fn arm(context: ?*anyopaque, id: u64, ns: u64, repeating: bool) !void {
        const self = owner(context.?);
        try std.testing.expectEqual(timer_id, id);
        try std.testing.expect(!repeating);
        if (self.timer_fails) return error.InjectedTimerFailure;
        self.timer_ns = ns;
    }
    fn disarm(context: ?*anyopaque, id: u64) !void {
        try std.testing.expectEqual(timer_id, id);
        owner(context.?).timer_ns = null;
    }
    fn open(context: ?*anyopaque, url: []const u8) !void {
        const self = owner(context.?);
        try std.testing.expectEqual(self.main_thread, std.Thread.getCurrentId());
        if (self.browser_fails) return error.HandlerUnavailable;
        self.opened += 1;
        @memcpy(self.last_url[0..url.len], url);
        self.last_url_len = url.len;
    }
    fn onMain(context: ?*anyopaque) bool {
        return owner(context.?).main_thread == std.Thread.getCurrentId();
    }
    fn perform(context: *anyopaque, request: http.Request, output: []u8, cancellation: *const http.Cancellation) http.Error!http.Response {
        const self = owner(context);
        _ = self.requests.fetchAdd(1, .release);
        if ((request == .manifest and self.block_check) or (request == .download and self.block_download)) {
            while (cancellation.state.load(.acquire) == 0) std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch return error.Cancelled;
            return error.Cancelled;
        }
        if (request == .download) return .{ .status = self.head_status };
        @memcpy(output[0..self.body.len], self.body);
        return .{ .status = 200, .body_len = self.body.len };
    }
    fn coordinator(self: *TestHost) Coordinator {
        return .{ .allocator = std.testing.allocator, .io = std.testing.io, .management = .{ .context = self, .start_fn = start, .next_check_fn = next, .begin_check_fn = beginCheck, .complete_check_fn = completeCheck, .begin_download_fn = beginDownload, .complete_download_fn = completeDownload, .browser_result_fn = browserResult, .cancel_download_fn = cancel, .stop_fn = stop }, .transport = .{ .context = self, .perform_fn = perform }, .host = .{ .context = self, .now_ns_fn = now, .wake_fn = wake, .start_timer_fn = arm, .cancel_timer_fn = disarm, .open_fn = open, .on_main_thread_fn = onMain } };
    }
    fn settle(coordinator_value: *Coordinator) !void {
        for (0..1000) |_| {
            coordinator_value.drain();
            if (coordinator_value.check == null and coordinator_value.download == null) return;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        }
        return error.UpdateDidNotSettle;
    }
    fn awaitRequests(self: *TestHost, count: u32) !void {
        for (0..1000) |_| {
            if (self.requests.load(.acquire) >= count) return;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        }
        return error.UpdateDidNotStart;
    }
};

test "updates lifecycle starts after delay, coalesces requests and recovers a missed wake with its timer" {
    var host = try TestHost.init();
    host.wake_fails = true;
    var coordinator = host.coordinator();
    coordinator.start(true);
    defer coordinator.shutdown();
    try std.testing.expectEqual(30_000 * std.time.ns_per_ms, host.timer_ns.?);
    host.now_ms = 29_999;
    coordinator.onTimer();
    try std.testing.expectEqual(@as(u32, 0), host.requests.load(.acquire));
    host.now_ms = 30_000;
    coordinator.onTimer();
    try std.testing.expectEqual(Outcome.accepted, coordinator.requestCheck());
    try std.testing.expectEqual(50 * std.time.ns_per_ms, host.timer_ns.?);
    try TestHost.settle(&coordinator);
    try std.testing.expectEqual(@as(u32, 1), host.requests.load(.acquire));
    try std.testing.expect(host.state.view().updateAvailable);
    try std.testing.expectEqual(update.Limits.interval_ms * std.time.ns_per_ms, host.timer_ns.?);
}

test "updates download errors never auto-open the website and unsupported HEAD still hands off" {
    var host = try TestHost.init();
    var coordinator = host.coordinator();
    coordinator.start(false);
    defer coordinator.shutdown();
    try std.testing.expect(host.timer_ns == null);
    try std.testing.expectEqual(Outcome.accepted, coordinator.requestCheck());
    try TestHost.settle(&coordinator);
    host.head_status = 404;
    try std.testing.expectEqual(Outcome.accepted, coordinator.requestDownload("0.2.8"));
    try TestHost.settle(&coordinator);
    try std.testing.expectEqual(update.DownloadError.invalid_link, host.state.view().downloadError);
    try std.testing.expectEqual(@as(usize, 0), host.opened);
    try std.testing.expect(coordinator.openWebsite());
    try std.testing.expectEqualStrings(update.website_url, host.last_url[0..host.last_url_len]);
    host.head_status = 501;
    try std.testing.expectEqual(Outcome.accepted, coordinator.requestDownload("0.2.8"));
    try TestHost.settle(&coordinator);
    try std.testing.expectEqual(@as(usize, 2), host.opened);
    try std.testing.expectEqualStrings("https://downloads.metask-ai.com/metawork/new.dmg?release=0.2.8", host.last_url[0..host.last_url_len]);
    try std.testing.expectEqual(update.DownloadState.opened, host.state.view().downloadState);
    try std.testing.expect(host.state.view().updateAvailable);
    host.browser_fails = true;
    _ = coordinator.requestDownload("0.2.8");
    try TestHost.settle(&coordinator);
    try std.testing.expectEqual(update.DownloadError.browser_unavailable, host.state.view().downloadError);
}

test "updates disconnect cancels only the pending download, while shutdown joins all work" {
    var host = try TestHost.init();
    var coordinator = host.coordinator();
    coordinator.start(false);
    defer coordinator.shutdown();
    _ = coordinator.requestCheck();
    try TestHost.settle(&coordinator);
    host.block_download = true;
    _ = coordinator.requestDownload("0.2.8");
    try host.awaitRequests(2);
    coordinator.cancelDownload();
    try std.testing.expectEqual(Outcome.unavailable, coordinator.requestDownload("0.2.8"));
    try TestHost.settle(&coordinator);
    try std.testing.expectEqual(@as(usize, 0), host.opened);
    try std.testing.expectEqual(update.DownloadState.idle, host.state.view().downloadState);
    host.block_check = true;
    _ = coordinator.requestCheck();
    try host.awaitRequests(3);
    coordinator.shutdown();
    try std.testing.expect(coordinator.check == null and coordinator.download == null);
    try std.testing.expectEqual(update.CheckState.unavailable, host.state.view().checkState);
    try std.testing.expectEqual(Outcome.unavailable, coordinator.requestCheck());
    try std.testing.expect(!coordinator.openWebsite());
}

test "updates timer failure closes the capability instead of starting a parallel scheduling path" {
    var host = try TestHost.init();
    host.timer_fails = true;
    var coordinator = host.coordinator();
    coordinator.start(true);
    defer coordinator.shutdown();
    try std.testing.expectEqual(update.CheckState.unavailable, host.state.view().checkState);
    try std.testing.expectEqual(Outcome.unavailable, coordinator.requestCheck());
    try std.testing.expectEqual(@as(u32, 0), host.requests.load(.acquire));
}
