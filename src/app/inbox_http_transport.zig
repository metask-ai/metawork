//! Application-owned MetaTeam open API requests over the shared HTTP engine,
//! and the only inbox file that touches it. The device key travels only as a
//! Bearer header to the bound service base: never in the URL, never across a
//! redirect (the engine follows none) and never in a log line.
const std = @import("std");
const http = @import("metawork_http_transport");
const inbox = @import("metawork_product_inbox");

pub const Cancellation = struct {
    io: std.Io,
    state: std.atomic.Value(u32) = .init(0),

    pub fn cancel(self: *Cancellation) void {
        self.state.store(1, .release);
        self.io.futexWake(u32, &self.state.raw, std.math.maxInt(u32));
    }
};

/// Where a request goes and with what. Borrowed for the call.
pub const Target = struct {
    base: []const u8,
    key: []const u8,
    isolation: http.Isolation,
};

pub const Response = struct { status: u16, body_len: usize = 0 };
pub const Error = error{ Network, Timeout, Cancelled, InvalidResponse, ResponseTooLarge };

pub const Transport = struct {
    context: *anyopaque,
    /// `diagnostic` receives the execution evidence when the request itself
    /// failed, and stays null when a response arrived.
    perform_fn: *const fn (*anyopaque, Target, inbox.Request, []u8, *const Cancellation, *?inbox.Diagnostic) Error!Response,
};

pub const max_url_bytes = 8192;
const max_authorization_bytes = 4096 + "Bearer ".len;

pub const Adapter = struct {
    http: *http.Engine,

    pub fn transport(self: *Adapter) Transport {
        return .{ .context = self, .perform_fn = perform };
    }

    /// Closes idle connections of a binding that ended; Application calls
    /// this when the key it was opened with is forgotten.
    pub fn retire(context: *anyopaque, isolation: http.Isolation) void {
        const self: *Adapter = @ptrCast(@alignCast(context));
        self.http.retire(isolation);
    }

    fn perform(context: *anyopaque, target: Target, request: inbox.Request, output: []u8, cancellation: *const Cancellation, diagnostic: *?inbox.Diagnostic) Error!Response {
        const self: *Adapter = @ptrCast(@alignCast(context));
        diagnostic.* = null;
        if (cancellation.state.load(.acquire) != 0) return error.Cancelled;
        var url_buffer: [max_url_bytes]u8 = undefined;
        var url = std.Io.Writer.fixed(&url_buffer);
        inbox.writeUrl(&url, target.base, request) catch return error.InvalidResponse;
        const seconds: i64 = if (request == .messages) 15 else 10;
        return self.performAt(target, url.buffered(), output, cancellation, .fromSeconds(seconds), diagnostic);
    }

    fn performAt(self: *Adapter, target: Target, url: []const u8, output: []u8, cancellation: *const Cancellation, timeout: std.Io.Duration, diagnostic: *?inbox.Diagnostic) Error!Response {
        if (target.key.len == 0 or target.key.len > max_authorization_bytes - "Bearer ".len) return error.InvalidResponse;
        var authorization: [max_authorization_bytes]u8 = undefined;
        defer std.crypto.secureZero(u8, &authorization);
        @memcpy(authorization[0.."Bearer ".len], "Bearer ");
        @memcpy(authorization["Bearer ".len..][0..target.key.len], target.key);
        const header = authorization[0 .. "Bearer ".len + target.key.len];
        const result = self.http.run(.{
            .consumer = .inbox,
            .isolation = target.isolation,
            .budget = .{ .deadline = .fromNow(self.http.io, .{ .raw = timeout, .clock = .boot }) },
            .cancellation = .atomic(&cancellation.state),
        }, fetch, .{ url, header, output });
        // Typed facts only: the engine reports no endpoint, address or header.
        diagnostic.* = if (result.diagnostic) |evidence| .{
            .phase = evidence.phase,
            .cause = evidence.cause,
            .elapsed = .fromMilliseconds(evidence.elapsed_ms),
        } else null;
        return switch (result.outcome) {
            .completed => |response| response catch |err| mapError(err),
            .failed => |err| mapError(err),
        };
    }

    fn fetch(operation: *http.Operation, url: []const u8, authorization: []const u8, output: []u8) http.Error!Response {
        const uri = std.Uri.parse(url) catch return operation.fail(error.InvalidRequest);
        var request = try operation.open(.GET, uri, .{ .headers = &.{
            .{ .name = "Accept", .value = "application/json" },
            .{ .name = "Accept-Encoding", .value = "identity" },
            .{ .name = "Cache-Control", .value = "no-cache" },
            .{ .name = "Authorization", .value = authorization },
        } });
        defer request.deinit();
        try request.send(null);
        var response = try request.receiveHead();
        const status: u16 = @intFromEnum(response.head.status);
        // A refusal or a server error is the whole fact; its body is not read.
        if (status < 200 or status > 299) return .{ .status = status };
        if (response.head.content_encoding != .identity) return operation.fail(error.InvalidResponse);
        const body = try request.readAll(&response, output);
        return .{ .status = status, .body_len = body.len };
    }

    fn mapError(err: http.Error) Error {
        return switch (err) {
            error.Cancelled => error.Cancelled,
            error.DeadlineExceeded => error.Timeout,
            error.ResponseTooLarge => error.ResponseTooLarge,
            error.InvalidRequest, error.InvalidResponse => error.InvalidResponse,
            else => error.Network,
        };
    }
};

test "inbox HTTP sends the key only as a Bearer header and counts under its own consumer" {
    const Server = struct {
        listener: *std.Io.net.Server,
        status: std.http.Status,
        body: []const u8,
        failure: ?anyerror = null,
        target: [256]u8 = undefined,
        target_len: usize = 0,
        authorization: [256]u8 = undefined,
        authorization_len: usize = 0,

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
            try std.testing.expectEqual(std.http.Method.GET, request.head.method);
            self.target_len = request.head.target.len;
            @memcpy(self.target[0..self.target_len], request.head.target);
            var headers = request.iterateHeaders();
            while (headers.next()) |header| if (std.ascii.eqlIgnoreCase(header.name, "Authorization")) {
                self.authorization_len = header.value.len;
                @memcpy(self.authorization[0..header.value.len], header.value);
            };
            try request.respond(self.body, .{ .status = self.status, .keep_alive = false });
        }
    };
    const key = "mtk-SENTINEL-key";
    for ([_]struct { std.http.Status, []const u8, ?Error }{
        .{ .ok, "{\"data\":{\"unread\":0}}", null },
        .{ .unauthorized, "{\"error\":{\"code\":\"401\",\"message\":\"no\"}}", null },
        .{ .ok, "x" ** 64, error.ResponseTooLarge },
    }) |case| {
        var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .async_limit = .nothing });
        defer threaded.deinit();
        const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        var listener = try address.listen(std.testing.io, .{ .kernel_backlog = 1 });
        defer listener.deinit(std.testing.io);
        var server: Server = .{ .listener = &listener, .status = case[0], .body = case[1] };
        const thread = try std.Thread.spawn(.{}, Server.run, .{&server});
        const base = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/team", .{listener.socket.address.getPort()});
        defer std.testing.allocator.free(base);
        var engine: http.Engine = undefined;
        engine.init(std.testing.allocator, threaded.io());
        defer engine.deinit();
        var adapter: Adapter = .{ .http = &engine };
        var cancellation: Cancellation = .{ .io = threaded.io() };
        var buffer: [32]u8 = undefined;
        var diagnostic: ?inbox.Diagnostic = null;
        const result = adapter.transport().perform_fn(&adapter, .{ .base = base, .key = key, .isolation = .of(.inbox, "server") }, .{ .messages = .{ .peer = "u 1", .limit = 50 } }, &buffer, &cancellation, &diagnostic);
        thread.join();
        try std.testing.expectEqual(@as(?anyerror, null), server.failure);
        try std.testing.expectEqualStrings("/team/open/v1/messages?peer=u%201&limit=50", server.target[0..server.target_len]);
        try std.testing.expect(std.mem.indexOf(u8, server.target[0..server.target_len], key) == null);
        try std.testing.expectEqualStrings("Bearer " ++ key, server.authorization[0..server.authorization_len]);
        if (case[2]) |expected| {
            try std.testing.expectError(expected, result);
        } else {
            try std.testing.expectEqual(@as(u16, @intFromEnum(case[0])), (try result).status);
        }
        // A body that does not fit is a failure the engine records; an
        // answered refusal is not.
        if (case[2] == null) try std.testing.expect(diagnostic == null) else try std.testing.expect(diagnostic.?.cause == .response_too_large);
        const stats = engine.stats();
        try std.testing.expectEqual(@as(u64, 1), stats.consumers.get(.inbox).requests);
        try std.testing.expectEqual(@as(u64, 0), stats.consumers.get(.mcp).requests);
    }
}

test "inbox HTTP reports where an unreachable service stopped" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .async_limit = .nothing });
    defer threaded.deinit();
    // Bind and release a port so nothing listens on it.
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = try address.listen(std.testing.io, .{ .kernel_backlog = 1 });
    const port = listener.socket.address.getPort();
    listener.deinit(std.testing.io);
    const base = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{port});
    defer std.testing.allocator.free(base);
    var engine: http.Engine = undefined;
    engine.init(std.testing.allocator, threaded.io());
    defer engine.deinit();
    var adapter: Adapter = .{ .http = &engine };
    var cancellation: Cancellation = .{ .io = threaded.io() };
    var buffer: [32]u8 = undefined;
    var diagnostic: ?inbox.Diagnostic = null;
    try std.testing.expectError(error.Network, adapter.transport().perform_fn(&adapter, .{ .base = base, .key = "k", .isolation = .of(.inbox, "server") }, .unread, &buffer, &cancellation, &diagnostic));
    try std.testing.expect(diagnostic.?.phase == .connect);
    cancellation.cancel();
    try std.testing.expectError(error.Cancelled, adapter.transport().perform_fn(&adapter, .{ .base = base, .key = "k", .isolation = .of(.inbox, "server") }, .unread, &buffer, &cancellation, &diagnostic));
}
