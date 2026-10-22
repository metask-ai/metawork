//! Fixed-release HTTPS transfer. No redirects, credentials, remote manifest or
//! resume path can expand the release accepted by the main binary.
const std = @import("std");
const store = @import("office_component_store.zig");
const process = @import("office_process");

pub fn source() store.Download {
    return .{ .read_fn = read };
}

const Attempt = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    release: store.Release,
    writer: *std.Io.Writer,
    cancellation: *const process.Cancellation,
    started: std.Io.Timestamp,

    fn transfer(self: *Attempt) anyerror!void {
        var client: std.http.Client = .{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();
        const response = try client.fetch(.{
            .location = .{ .url = self.release.url },
            .method = .GET,
            .redirect_behavior = .unhandled,
            .response_writer = self.writer,
            .extra_headers = &.{.{ .name = "Accept-Encoding", .value = "identity" }},
        });
        if (response.status != .ok) return error.ComponentDownloadRejected;
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

fn read(_: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, release: store.Release, writer: *std.Io.Writer, cancellation: *const process.Cancellation) !void {
    try release.validate();
    if (cancellation.requested.load(.acquire)) return error.Cancelled;
    var attempt: Attempt = .{ .allocator = allocator, .io = io, .release = release, .writer = writer, .cancellation = cancellation, .started = .now(io, .awake) };
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
    const release: store.Release = .{ .url = "https://example.invalid/runtime.tar.gz", .expected = .{
        .target = "x86_64-windows-msvc",
        .archive_bytes = 1,
        .unpacked_bytes = 1,
        .files = 1,
        .sha256 = @splat(1),
    }, .manifest_sha256 = @splat(2) };
    var bytes: [16]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&bytes);
    try std.testing.expectError(error.Cancelled, read(null, std.testing.allocator, std.testing.io, release, &writer, &cancellation));
}
