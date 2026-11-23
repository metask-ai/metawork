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
        const seconds: i64 = switch (request) {
            .messages, .send => 15,
            else => 10,
        };
        const send: ?inbox.Send = if (request == .send) request.send else null;
        if (send) |message| if (!inbox.validRequestKey(message.request_key)) return error.InvalidResponse;
        return self.performAt(target, url.buffered(), send, output, cancellation, .fromSeconds(seconds), diagnostic);
    }

    fn performAt(self: *Adapter, target: Target, url: []const u8, send: ?inbox.Send, output: []u8, cancellation: *const Cancellation, timeout: std.Io.Duration, diagnostic: *?inbox.Diagnostic) Error!Response {
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
        }, fetch, .{ url, header, send, output });
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

    /// A read is a GET. A send is a POST with its request key; the engine
    /// never replays a POST, and nothing here sends it a second time.
    fn fetch(operation: *http.Operation, url: []const u8, authorization: []const u8, send: ?inbox.Send, output: []u8) http.Error!Response {
        const uri = std.Uri.parse(url) catch return operation.fail(error.InvalidRequest);
        var request = if (send) |message| try operation.open(.POST, uri, .{
            .standard_headers = .{ .content_type = .{ .override = "application/json" } },
            .headers = &.{
                .{ .name = "Accept", .value = "application/json" },
                .{ .name = "Accept-Encoding", .value = "identity" },
                .{ .name = "X-Request-Id", .value = message.request_key },
                .{ .name = "Authorization", .value = authorization },
            },
        }) else try operation.open(.GET, uri, .{ .headers = &.{
            .{ .name = "Accept", .value = "application/json" },
            .{ .name = "Accept-Encoding", .value = "identity" },
            .{ .name = "Cache-Control", .value = "no-cache" },
            .{ .name = "Authorization", .value = authorization },
        } });
        defer request.deinit();
        try request.send(if (send) |message| message.body else null);
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

test "inbox HTTP sends a message once, as JSON with its request key, and never sends it again by itself" {
    const Server = struct {
        listener: *std.Io.net.Server,
        answer: bool,
        failure: ?anyerror = null,
        method: ?std.http.Method = null,
        target: [128]u8 = undefined,
        target_len: usize = 0,
        request_id: [80]u8 = undefined,
        request_id_len: usize = 0,
        content_type: [64]u8 = undefined,
        content_type_len: usize = 0,
        body: [256]u8 = undefined,
        body_len: usize = 0,
        /// What the next connection began with: a second attempt would be
        /// an HTTP request, the test's own sentinel is "STOP".
        next: [4]u8 = undefined,

        fn run(self: *@This()) void {
            self.serve() catch |err| {
                self.failure = err;
            };
        }
        fn copy(into: []u8, value: []const u8) usize {
            const length = @min(into.len, value.len);
            @memcpy(into[0..length], value[0..length]);
            return length;
        }
        fn serve(self: *@This()) !void {
            {
                var connection = try self.listener.accept(std.testing.io);
                defer connection.close(std.testing.io);
                var reads: [4096]u8 = undefined;
                var writes: [4096]u8 = undefined;
                var reader = connection.reader(std.testing.io, &reads);
                var writer = connection.writer(std.testing.io, &writes);
                var server: std.http.Server = .init(&reader.interface, &writer.interface);
                var request = try server.receiveHead();
                self.method = request.head.method;
                self.target_len = copy(&self.target, request.head.target);
                if (request.head.content_type) |value| self.content_type_len = copy(&self.content_type, value);
                var headers = request.iterateHeaders();
                while (headers.next()) |header| if (std.ascii.eqlIgnoreCase(header.name, "X-Request-Id")) {
                    self.request_id_len = copy(&self.request_id, header.value);
                };
                const length: usize = @intCast(request.head.content_length orelse 0);
                self.body_len = @min(length, self.body.len);
                var body_buffer: [64]u8 = undefined;
                try request.readerExpectNone(&body_buffer).readSliceAll(self.body[0..self.body_len]);
                // Without an answer the outcome is unknown to the client.
                if (self.answer) try request.respond("{\"data\":{\"sent\":[\"Ann\"]}}", .{ .keep_alive = false });
            }
            var connection = try self.listener.accept(std.testing.io);
            defer connection.close(std.testing.io);
            var reads: [64]u8 = undefined;
            var reader = connection.reader(std.testing.io, &reads);
            try reader.interface.readSliceAll(&self.next);
        }
    };
    const key = "mtk-SENTINEL-key";
    const request_key = "0b6f7c2e-7d1a-4c55-9f0e-2a4b6c8d0e1f";
    for ([_]bool{ true, false }) |answer| {
        var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .async_limit = .nothing });
        defer threaded.deinit();
        const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        var listener = try address.listen(std.testing.io, .{ .kernel_backlog = 4 });
        defer listener.deinit(std.testing.io);
        var server: Server = .{ .listener = &listener, .answer = answer };
        const thread = try std.Thread.spawn(.{}, Server.run, .{&server});
        const port = listener.socket.address.getPort();
        const base = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/team", .{port});
        defer std.testing.allocator.free(base);
        var engine: http.Engine = undefined;
        engine.init(std.testing.allocator, threaded.io());
        defer engine.deinit();
        var adapter: Adapter = .{ .http = &engine };
        var cancellation: Cancellation = .{ .io = threaded.io() };
        var buffer: [256]u8 = undefined;
        var diagnostic: ?inbox.Diagnostic = null;
        const body = "{\"to\":[\"ann\"],\"text\":\"hi\"}";
        const result = adapter.transport().perform_fn(&adapter, .{ .base = base, .key = key, .isolation = .of(.inbox, "server") }, .{ .send = .{ .body = body, .request_key = request_key } }, &buffer, &cancellation, &diagnostic);
        // The test's own sentinel connection: the server reads it next only
        // if the client opened no second connection for the same message.
        {
            const sentinel_address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
            var stream = try sentinel_address.connect(std.testing.io, .{ .mode = .stream });
            defer stream.close(std.testing.io);
            var writes: [16]u8 = undefined;
            var writer = stream.writer(std.testing.io, &writes);
            try writer.interface.writeAll("STOP");
            try writer.interface.flush();
        }
        thread.join();
        try std.testing.expectEqual(@as(?anyerror, null), server.failure);
        try std.testing.expectEqual(std.http.Method.POST, server.method.?);
        try std.testing.expectEqualStrings("/team/agent/v1/notify", server.target[0..server.target_len]);
        try std.testing.expectEqualStrings(request_key, server.request_id[0..server.request_id_len]);
        try std.testing.expectEqualStrings("application/json", server.content_type[0..server.content_type_len]);
        try std.testing.expectEqualStrings(body, server.body[0..server.body_len]);
        try std.testing.expectEqualStrings("STOP", &server.next);
        if (answer) {
            const response = try result;
            try std.testing.expectEqual(@as(u16, 200), response.status);
            try std.testing.expectEqualStrings("{\"data\":{\"sent\":[\"Ann\"]}}", buffer[0..response.body_len]);
        } else {
            try std.testing.expect(std.meta.isError(result));
        }
        try std.testing.expectEqual(@as(u64, 1), engine.stats().consumers.get(.inbox).requests);
    }
    // A request key that could break the header is never sent.
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .async_limit = .nothing });
    defer threaded.deinit();
    var engine: http.Engine = undefined;
    engine.init(std.testing.allocator, threaded.io());
    defer engine.deinit();
    var adapter: Adapter = .{ .http = &engine };
    var cancellation: Cancellation = .{ .io = threaded.io() };
    var buffer: [16]u8 = undefined;
    var diagnostic: ?inbox.Diagnostic = null;
    try std.testing.expectError(error.InvalidResponse, adapter.transport().perform_fn(&adapter, .{ .base = "http://127.0.0.1:9", .key = key, .isolation = .of(.inbox, "server") }, .{ .send = .{ .body = "{}", .request_key = "a\r\nX-Evil: 1" } }, &buffer, &cancellation, &diagnostic));
    try std.testing.expectEqual(@as(u64, 0), engine.stats().consumers.get(.inbox).requests);
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
