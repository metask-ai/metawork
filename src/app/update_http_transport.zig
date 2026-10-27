//! Application-owned, unauthenticated update HTTP. Production endpoints are
//! selected by Product policy; this adapter never follows redirects or saves a package.
const std = @import("std");
const update = @import("metawork_product_update");

pub const Cancellation = struct {
    io: std.Io,
    state: std.atomic.Value(u32) = .init(0),

    pub fn cancel(self: *Cancellation) void {
        self.state.store(1, .release);
        self.io.futexWake(u32, &self.state.raw, std.math.maxInt(u32));
    }

    fn wait(self: *const Cancellation) void {
        while (self.state.load(.acquire) == 0) self.io.futexWait(u32, &self.state.raw, 0) catch return;
    }
};

pub const Request = union(enum) { manifest, download: update.Url };
pub const Response = struct { status: u16, body_len: usize = 0 };
pub const Error = error{ Network, Timeout, Cancelled, InvalidResponse };
pub const Transport = struct {
    context: *anyopaque,
    perform_fn: *const fn (*anyopaque, Request, []u8, *const Cancellation) Error!Response,
};

pub const Adapter = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    const Fetch = union(enum) { response: Response, failed, invalid };
    const Outcome = union(enum) { fetched: Fetch, deadline, cancelled };

    pub fn transport(self: *Adapter) Transport {
        return .{ .context = self, .perform_fn = perform };
    }

    fn perform(context: *anyopaque, request: Request, output: []u8, cancellation: *const Cancellation) Error!Response {
        const self: *Adapter = @ptrCast(@alignCast(context));
        if (cancellation.state.load(.acquire) != 0) return error.Cancelled;
        const url = switch (request) {
            .manifest => update.manifest_url,
            .download => |*value| value.slice(),
        };
        if (request == .download and !update.validDownloadUrl(url)) return error.InvalidResponse;
        const seconds: i64 = if (request == .manifest) 10 else 5;
        return self.performAt(url, request == .download, output, cancellation, .fromSeconds(seconds));
    }

    fn performAt(self: *Adapter, url: []const u8, head: bool, output: []u8, cancellation: *const Cancellation, timeout: std.Io.Duration) Error!Response {
        const deadline = std.Io.Clock.Timestamp.fromNow(self.io, .{ .raw = timeout, .clock = .boot });
        var storage: [3]Outcome = undefined;
        var selection = std.Io.Select(Outcome).init(self.io, &storage);
        selection.async(.fetched, fetch, .{ self, url, head, output });
        selection.async(.deadline, waitDeadline, .{ self.io, deadline });
        selection.async(.cancelled, Cancellation.wait, .{cancellation});
        const outcome = selection.await() catch {
            selection.cancelDiscard();
            return error.Cancelled;
        };
        // Joins the losing operations before any output buffer can be released.
        selection.cancelDiscard();
        if (cancellation.state.load(.acquire) != 0) return error.Cancelled;
        return switch (outcome) {
            .deadline => error.Timeout,
            .cancelled => error.Cancelled,
            .fetched => |result| switch (result) {
                .response => |value| value,
                .failed => error.Network,
                .invalid => error.InvalidResponse,
            },
        };
    }

    fn fetch(self: *Adapter, url: []const u8, head: bool, output: []u8) Fetch {
        var client: std.http.Client = .{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();
        return fetchHttp(&client, url, head, output);
    }

    fn fetchHttp(client: *std.http.Client, url: []const u8, head: bool, output: []u8) Fetch {
        const uri = std.Uri.parse(url) catch return .invalid;
        var request = client.request(if (head) .HEAD else .GET, uri, .{
            .redirect_behavior = .unhandled,
            .extra_headers = &.{
                .{ .name = "Accept", .value = "application/json" },
                .{ .name = "Accept-Encoding", .value = "identity" },
                .{ .name = "Cache-Control", .value = "no-cache" },
            },
        }) catch return .failed;
        defer request.deinit();
        request.sendBodiless() catch return .failed;
        var response = request.receiveHead(&.{}) catch return .failed;
        const status: u16 = @intFromEnum(response.head.status);
        // No package body, redirect target, or error response is consumed.
        if (head or status != 200) return .{ .response = .{ .status = status } };
        if (response.head.content_encoding != .identity) return .invalid;
        var transfer_buffer: [256]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const reader = response.readerDecompressing(&transfer_buffer, &decompress, &.{});
        var writer = std.Io.Writer.fixed(output);
        _ = reader.streamRemaining(&writer) catch |err| return switch (err) {
            error.WriteFailed => .invalid,
            error.ReadFailed => .failed,
        };
        return .{ .response = .{ .status = status, .body_len = writer.buffered().len } };
    }

    fn waitDeadline(io: std.Io, deadline: std.Io.Clock.Timestamp) void {
        deadline.wait(io) catch {};
    }
};

test "updates HTTP refuses cancellation and untrusted download before any network work" {
    var adapter: Adapter = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    var cancellation: Cancellation = .{ .io = std.testing.io };
    var buffer: [8]u8 = undefined;
    var bad_url: update.Url = .{ .len = "https://evil.test/package.exe".len };
    @memcpy(bad_url.bytes[0..bad_url.len], "https://evil.test/package.exe");
    try std.testing.expectError(error.InvalidResponse, adapter.transport().perform_fn(&adapter, .{ .download = bad_url }, &buffer, &cancellation));
    cancellation.cancel();
    try std.testing.expectError(error.Cancelled, adapter.transport().perform_fn(&adapter, .manifest, &buffer, &cancellation));
}

test "updates HTTP real GET and HEAD enforce byte bounds and never follow redirects" {
    const Server = struct {
        listener: *std.Io.net.Server,
        mode: enum { get, head, oversized, redirect, invalid_encoding },
        failure: ?anyerror = null,

        fn run(self: *@This()) void {
            self.serve() catch |err| {
                self.failure = err;
            };
        }
        fn serve(self: *@This()) !void {
            var connection = try self.listener.accept(std.testing.io);
            defer connection.close(std.testing.io);
            var reads: [4096]u8 = undefined;
            var writes: [4096]u8 = undefined;
            var reader = connection.reader(std.testing.io, &reads);
            var writer = connection.writer(std.testing.io, &writes);
            var server: std.http.Server = .init(&reader.interface, &writer.interface);
            var request = try server.receiveHead();
            try std.testing.expectEqual(if (self.mode == .head) std.http.Method.HEAD else .GET, request.head.method);
            var headers = request.iterateHeaders();
            var cache = false;
            var auth = false;
            while (headers.next()) |header| {
                if (std.ascii.eqlIgnoreCase(header.name, "Cache-Control")) cache = std.mem.eql(u8, header.value, "no-cache");
                if (std.ascii.eqlIgnoreCase(header.name, "Authorization")) auth = true;
            }
            try std.testing.expect(cache and !auth);
            if (self.mode == .redirect) {
                try request.respond("", .{ .status = .found, .keep_alive = false, .extra_headers = &.{.{ .name = "Location", .value = "https://evil.test/package" }} });
            } else if (self.mode == .invalid_encoding) {
                try request.respond("invalid compressed content", .{ .keep_alive = false, .extra_headers = &.{.{ .name = "Content-Encoding", .value = "gzip" }} });
            } else {
                try request.respond(if (self.mode == .oversized) "123456789" else "{}", .{ .keep_alive = false });
            }
        }
    };
    for ([_]@FieldType(Server, "mode"){ .get, .head, .oversized, .redirect, .invalid_encoding }) |mode| {
        const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        var listener = try address.listen(std.testing.io, .{ .kernel_backlog = 1 });
        defer listener.deinit(std.testing.io);
        var server: Server = .{ .listener = &listener, .mode = mode };
        const thread = try std.Thread.spawn(.{}, Server.run, .{&server});
        const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/manifest.json", .{listener.socket.address.getPort()});
        defer std.testing.allocator.free(url);
        var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
        defer client.deinit();
        var buffer: [2]u8 = undefined;
        const result = Adapter.fetchHttp(&client, url, mode == .head, &buffer);
        thread.join();
        try std.testing.expectEqual(@as(?anyerror, null), server.failure);
        switch (mode) {
            .get => {
                try std.testing.expectEqual(@as(u16, 200), result.response.status);
                try std.testing.expectEqual(@as(usize, 2), result.response.body_len);
                try std.testing.expectEqualStrings("{}", &buffer);
            },
            .head => {
                try std.testing.expectEqual(@as(u16, 200), result.response.status);
                try std.testing.expectEqual(@as(usize, 0), result.response.body_len);
            },
            .redirect => try std.testing.expectEqual(@as(u16, 302), result.response.status),
            .oversized, .invalid_encoding => try std.testing.expect(result == .invalid),
        }
    }
}

test "updates HTTP deadline and cancellation join a real blocked response before returning" {
    const Server = struct {
        listener: *std.Io.net.Server,
        cancellation: *Cancellation,
        cancel_after_request: bool,
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            self.serve() catch |err| {
                self.failure = err;
            };
        }
        fn serve(self: *@This()) !void {
            var connection = try self.listener.accept(std.testing.io);
            defer connection.close(std.testing.io);
            var reads: [4096]u8 = undefined;
            var writes: [256]u8 = undefined;
            var reader = connection.reader(std.testing.io, &reads);
            var writer = connection.writer(std.testing.io, &writes);
            var server: std.http.Server = .init(&reader.interface, &writer.interface);
            _ = try server.receiveHead();
            if (self.cancel_after_request) self.cancellation.cancel();
            // EOF proves the losing HTTP operation closed its connection.
            _ = reader.interface.takeByte() catch |err| switch (err) {
                error.EndOfStream => return,
                else => return err,
            };
            return error.UnexpectedRequestBody;
        }
    };
    for ([_]bool{ false, true }) |cancel| {
        var cancellation: Cancellation = .{ .io = std.testing.io };
        const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        var listener = try address.listen(std.testing.io, .{ .kernel_backlog = 1 });
        defer listener.deinit(std.testing.io);
        var server: Server = .{ .listener = &listener, .cancellation = &cancellation, .cancel_after_request = cancel };
        const thread = try std.Thread.spawn(.{}, Server.run, .{&server});
        const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/manifest.json", .{listener.socket.address.getPort()});
        defer std.testing.allocator.free(url);
        var adapter: Adapter = .{ .allocator = std.testing.allocator, .io = std.testing.io };
        var buffer: [8]u8 = undefined;
        const result = adapter.performAt(url, false, &buffer, &cancellation, .fromMilliseconds(500));
        thread.join();
        try std.testing.expectEqual(@as(?anyerror, null), server.failure);
        if (cancel) try std.testing.expectError(error.Cancelled, result) else try std.testing.expectError(error.Timeout, result);
    }
}
