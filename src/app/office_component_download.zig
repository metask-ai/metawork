//! Fixed-release HTTPS transfer. Only the official LibreOffice archive may
//! delegate to up to three HTTPS mirrors; byte identity remains main-pinned.
const std = @import("std");
const store = @import("office_component_store.zig");
const process = @import("office_process");

pub fn source() store.Download {
    return .{ .read_fn = read };
}

const Attempt = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    source: store.Source,
    writer: *std.Io.Writer,
    cancellation: *const process.Cancellation,
    started: std.Io.Timestamp,
    body_started: bool = false,

    fn transfer(self: *Attempt) anyerror!void {
        var number: usize = 0;
        while (true) : (number += 1) {
            self.body_started = false;
            self.transferOnce() catch |failure| {
                if (!retryable(number, self.body_started, failure)) return failure;
                try std.Io.Timeout.sleep(.{ .duration = .{ .raw = .fromMilliseconds(250), .clock = .awake } }, self.io);
                continue;
            };
            return;
        }
    }

    fn transferOnce(self: *Attempt) anyerror!void {
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        var url = self.source.url;
        var hops: usize = 0;
        while (true) {
            var client: std.http.Client = .{ .allocator = self.allocator, .io = self.io };
            defer client.deinit();
            var request = try client.request(.GET, try std.Uri.parse(url), .{
                .redirect_behavior = .unhandled,
                .keep_alive = false,
                .headers = .{ .accept_encoding = .{ .override = "identity" } },
            });
            defer request.deinit();
            try request.sendBodiless();
            var response = try request.receiveHead(&.{});
            switch (response.head.status) {
                .moved_permanently, .found, .see_other, .temporary_redirect, .permanent_redirect => {
                    const target = response.head.location orelse return error.ComponentDownloadRejected;
                    try validateRedirect(self.source, target, hops);
                    url = try arena.allocator().dupe(u8, target);
                    hops += 1;
                    continue;
                },
                .ok => {},
                else => return error.ComponentDownloadRejected,
            }
            if (response.head.content_encoding != .identity) return error.ComponentDownloadRejected;
            self.body_started = true;
            try streamBody(&response, self.writer);
            return;
        }
    }

    fn stop(self: *Attempt) anyerror {
        while (!self.cancellation.requested.load(.acquire)) {
            if (self.started.durationTo(.now(self.io, .awake)).toMilliseconds() >= 15 * 60 * 1000)
                return error.ComponentDownloadTimedOut;
            std.Io.Timeout.sleep(.{ .duration = .{ .raw = .fromMilliseconds(10), .clock = .awake } }, self.io) catch return error.Cancelled;
        }
        return error.Cancelled;
    }
};

fn streamBody(response: *std.http.Client.Response, writer: *std.Io.Writer) !void {
    var buffer: [4096]u8 = undefined;
    const reader = response.reader(&buffer);
    _ = reader.streamRemaining(writer) catch |failure| switch (failure) {
        // Transport cancellation can return ReadFailed without a protocol error.
        error.ReadFailed => return response.bodyErr() orelse failure,
        else => return failure,
    };
}

test "response transport failure without an HTTP body error cannot panic" {
    const FailedInput = struct {
        fn stream(_: *std.Io.Reader, _: *std.Io.Writer, _: std.Io.Limit) std.Io.Reader.StreamError!usize {
            return error.ReadFailed;
        }
    };
    var input: std.Io.Reader = .{ .vtable = &.{ .stream = FailedInput.stream }, .buffer = &.{}, .seek = 0, .end = 0 };
    // Only method and HTTP reader are consumed by Response.reader/bodyErr.
    var request: std.http.Client.Request = undefined;
    request.method = .GET;
    request.reader = .{ .in = &input, .interface = undefined, .state = .received_head, .max_head_len = 4096 };
    var response: std.http.Client.Response = .{
        .request = &request,
        .head = try .parse("HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\n"),
    };
    var bytes: [16]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&bytes);
    try std.testing.expectError(error.ReadFailed, streamBody(&response, &writer));
    try std.testing.expect(response.bodyErr() == null);
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
}

test "response streaming preserves protocol errors and complete body bytes" {
    for ([_]bool{ false, true }) |valid| {
        var input: std.Io.Reader = .fixed(if (valid) "ok" else "2\r\nx");
        var request: std.http.Client.Request = undefined;
        request.method = .GET;
        request.reader = .{ .in = &input, .interface = undefined, .state = .received_head, .max_head_len = 4096 };
        var response: std.http.Client.Response = .{
            .request = &request,
            .head = try .parse(if (valid) "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n" else "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"),
        };
        var bytes: [16]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&bytes);
        if (valid) {
            try streamBody(&response, &writer);
            try std.testing.expectEqualStrings("ok", writer.buffered());
        } else try std.testing.expectError(error.HttpChunkTruncated, streamBody(&response, &writer));
    }
}

fn validateRedirect(origin: store.Source, target: []const u8, hops: usize) !void {
    if (!std.mem.startsWith(u8, origin.url, "https://downloadarchive.documentfoundation.org/libreoffice/old/") or hops >= 3)
        return error.ComponentDownloadRejected;
    var next = origin;
    next.url = target;
    try next.validate();
}

fn retryable(number: usize, body_started: bool, failure: anyerror) bool {
    if (number >= 2 or body_started) return false;
    return switch (failure) {
        error.Unexpected, error.ConnectionTimedOut, error.ConnectionResetByPeer, error.ConnectionRefused, error.NetworkUnreachable, error.TemporaryNameServerFailure, error.HostLacksNetworkAddresses => true,
        else => false,
    };
}

test "only the official archive permits three HTTPS hops without credentials or parameters" {
    const origin: store.Source = .{ .url = "https://downloadarchive.documentfoundation.org/libreoffice/old/1/file.msi", .bytes = 1, .digest = .{ .sha256 = @splat(1) } };
    try validateRedirect(origin, "https://mirror.example.org/file.msi", 2);
    try std.testing.expectError(error.ComponentDownloadRejected, validateRedirect(origin, "https://mirror.example.org/file.msi", 3));
    for ([_][]const u8{ "http://mirror.example.org/file", "https://key@mirror.example.org/file", "https://mirror.example.org/file?q=1", "https://mirror.example.org/file#fragment" }) |target|
        try std.testing.expectError(error.InvalidComponentSource, validateRedirect(origin, target, 0));
    var direct = origin;
    direct.url = "https://nodejs.org/file.zip";
    try std.testing.expectError(error.ComponentDownloadRejected, validateRedirect(direct, "https://mirror.example.org/file", 0));
}

test "download retries are limited to transport failure before body writes" {
    try std.testing.expect(retryable(0, false, error.Unexpected)); // Windows IO_TIMEOUT
    try std.testing.expect(!retryable(2, false, error.Unexpected));
    try std.testing.expect(!retryable(0, true, error.ConnectionResetByPeer));
    try std.testing.expect(!retryable(0, false, error.ComponentDownloadRejected));
    try std.testing.expect(!retryable(0, false, error.ComponentDownloadDigest));
    try std.testing.expect(!retryable(0, false, error.Cancelled));
}

fn read(_: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, source_input: store.Source, writer: *std.Io.Writer, cancellation: *const process.Cancellation) !void {
    try source_input.validate();
    if (cancellation.requested.load(.acquire)) return error.Cancelled;
    var attempt: Attempt = .{ .allocator = allocator, .io = io, .source = source_input, .writer = writer, .cancellation = cancellation, .started = .now(io, .awake) };
    const Event = union(enum) { operation: anyerror!void, stopped: anyerror };
    var events: [2]Event = undefined;
    var selection = std.Io.Select(Event).init(io, &events);
    selection.async(.operation, Attempt.transfer, .{&attempt});
    selection.async(.stopped, Attempt.stop, .{&attempt});
    defer selection.cancelDiscard(); // joins every socket/write before file cleanup
    const result = try selection.await();
    return switch (result) {
        .operation => |outcome| outcome,
        .stopped => |failure| failure,
    };
}

test "component HTTPS transfer refuses cancellation before opening a network client" {
    const cancellation: process.Cancellation = .{ .requested = .init(true) };
    const input: store.Source = .{ .url = "https://example.invalid/blob", .bytes = 1, .digest = .{ .sha256 = @splat(1) } };
    var bytes: [16]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&bytes);
    try std.testing.expectError(error.Cancelled, read(null, std.testing.allocator, std.testing.io, input, &writer, &cancellation));
}
