//! Application-owned update policy over the shared HTTP execution layer.
const std = @import("std");
const http = @import("metawork_http_transport");
const update = @import("metawork_product_update");

pub const Cancellation = struct {
    io: std.Io,
    state: std.atomic.Value(u32) = .init(0),

    pub fn cancel(self: *Cancellation) void {
        self.state.store(1, .release);
        self.io.futexWake(u32, &self.state.raw, std.math.maxInt(u32));
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
    http: *http.Engine,

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
        const result = self.http.run(.{
            .consumer = .update,
            .isolation = .public,
            .budget = .{ .deadline = .fromNow(self.http.io, .{ .raw = timeout, .clock = .boot }) },
            .cancellation = .atomic(&cancellation.state),
        }, fetch, .{ url, head, output });
        return switch (result.outcome) {
            .completed => |response| response catch |err| mapError(err),
            .failed => |err| mapError(err),
        };
    }

    fn fetch(operation: *http.Operation, url: []const u8, head: bool, output: []u8) http.Error!Response {
        const uri = std.Uri.parse(url) catch return operation.fail(error.InvalidRequest);
        var request = try operation.open(if (head) .HEAD else .GET, uri, .{ .headers = &.{
            .{ .name = "Accept", .value = "application/json" },
            .{ .name = "Accept-Encoding", .value = "identity" },
            .{ .name = "Cache-Control", .value = "no-cache" },
        } });
        defer request.deinit();
        try request.send(null);
        var response = try request.receiveHead();
        const status: u16 = @intFromEnum(response.head.status);
        // Product chooses endpoints. No package, redirect or error body is read.
        if (head or status != 200) return .{ .status = status };
        if (response.head.content_encoding != .identity) return operation.fail(error.InvalidResponse);
        const body = try request.readAll(&response, output);
        return .{ .status = status, .body_len = body.len };
    }

    fn mapError(err: http.Error) Error {
        return switch (err) {
            error.Cancelled => error.Cancelled,
            error.DeadlineExceeded => error.Timeout,
            error.InvalidRequest, error.InvalidResponse, error.ResponseTooLarge => error.InvalidResponse,
            else => error.Network,
        };
    }
};

test "updates HTTP refuses cancellation and untrusted download before any network work" {
    var engine: http.Engine = undefined;
    engine.init(std.testing.allocator, std.testing.io);
    defer engine.deinit();
    var adapter: Adapter = .{ .http = &engine };
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
        var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .async_limit = .nothing });
        defer threaded.deinit();
        const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        var listener = try address.listen(std.testing.io, .{ .kernel_backlog = 1 });
        defer listener.deinit(std.testing.io);
        var server: Server = .{ .listener = &listener, .mode = mode };
        const thread = try std.Thread.spawn(.{}, Server.run, .{&server});
        const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/manifest.json", .{listener.socket.address.getPort()});
        defer std.testing.allocator.free(url);
        var engine: http.Engine = undefined;
        engine.init(std.testing.allocator, threaded.io());
        defer engine.deinit();
        var adapter: Adapter = .{ .http = &engine };
        var cancellation: Cancellation = .{ .io = threaded.io() };
        var buffer: [2]u8 = undefined;
        const result = adapter.performAt(url, mode == .head, &buffer, &cancellation, .fromSeconds(5));
        thread.join();
        try std.testing.expectEqual(@as(?anyerror, null), server.failure);
        switch (mode) {
            .get => {
                try std.testing.expectEqual(@as(u16, 200), (try result).status);
                try std.testing.expectEqual(@as(usize, 2), (try result).body_len);
                try std.testing.expectEqualStrings("{}", &buffer);
            },
            .head => {
                try std.testing.expectEqual(@as(u16, 200), (try result).status);
                try std.testing.expectEqual(@as(usize, 0), (try result).body_len);
            },
            .redirect => try std.testing.expectEqual(@as(u16, 302), (try result).status),
            .oversized, .invalid_encoding => try std.testing.expectError(error.InvalidResponse, result),
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
        var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .async_limit = .nothing });
        defer threaded.deinit();
        var cancellation: Cancellation = .{ .io = threaded.io() };
        const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        var listener = try address.listen(std.testing.io, .{ .kernel_backlog = 1 });
        defer listener.deinit(std.testing.io);
        var server: Server = .{ .listener = &listener, .cancellation = &cancellation, .cancel_after_request = cancel };
        const thread = try std.Thread.spawn(.{}, Server.run, .{&server});
        const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/manifest.json", .{listener.socket.address.getPort()});
        defer std.testing.allocator.free(url);
        var engine: http.Engine = undefined;
        engine.init(std.testing.allocator, threaded.io());
        defer engine.deinit();
        var adapter: Adapter = .{ .http = &engine };
        var buffer: [8]u8 = undefined;
        const result = adapter.performAt(url, false, &buffer, &cancellation, .fromMilliseconds(500));
        thread.join();
        try std.testing.expectEqual(@as(?anyerror, null), server.failure);
        if (cancel) try std.testing.expectError(error.Cancelled, result) else try std.testing.expectError(error.Timeout, result);
    }
}

test "updates HTTP registration failure is a network failure rather than cancellation" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .async_limit = .nothing, .concurrent_limit = .nothing });
    defer threaded.deinit();
    var engine: http.Engine = undefined;
    engine.init(std.testing.allocator, threaded.io());
    defer engine.deinit();
    var adapter: Adapter = .{ .http = &engine };
    var cancellation: Cancellation = .{ .io = threaded.io() };
    var buffer: [8]u8 = undefined;
    try std.testing.expectError(error.Network, adapter.performAt("http://127.0.0.1:1/fixture", false, &buffer, &cancellation, .fromSeconds(30)));
}
