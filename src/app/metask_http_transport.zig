const std = @import("std");
const http = @import("app_http_transport");
const oauth = @import("account_oauth");
const account_metask = @import("metask_client");
const metask_transport = @import("metask_transport");
const models_metask = @import("product_models_metask");

/// Application-owned HTTP execution shared by Account's narrow transport port
/// and the Models Metask provider transport leaf. Account owns OAuth and
/// identity request policy; Models owns catalog request policy. This adapter
/// only maps their request kinds to network effects.
pub const Adapter = struct {
    http: *http.Engine,

    const default_request_timeout: std.Io.Clock.Duration = .{
        .raw = .fromSeconds(30),
        .clock = .boot,
    };

    const FetchResult = http.Error!struct { status: u16, body_len: usize };

    pub fn accountTransport(self: *Adapter) account_metask.Transport {
        return .{
            .context = self,
            .perform_fn = performAccount,
            .retire_fn = retireAccount,
        };
    }

    fn isolation(principal: ?[]const u8) http.Isolation {
        // Requests made before the identity exists share one key.
        return .of(.metask_account, principal orelse "");
    }

    fn retireAccount(context: *anyopaque, principal: []const u8) void {
        const self: *Adapter = @ptrCast(@alignCast(context));
        self.http.retire(isolation(principal));
    }

    pub fn modelsTransport(self: *Adapter) metask_transport.Transport {
        return .{
            .context = self,
            .perform_fn = performModels,
        };
    }

    fn performAccount(
        context: *anyopaque,
        request: account_metask.Request,
        response_buffer: []u8,
    ) account_metask.TransportError!account_metask.Response {
        return perform(
            context,
            .{
                .kind = switch (request.kind) {
                    .exchange_code => .exchange_code,
                    .refresh_token => .refresh_token,
                    .userinfo => .userinfo,
                    .usage_stats => .usage_stats,
                },
                .principal = request.principal,
                .body = request.body,
                .bearer = request.bearer,
                .control = request.control,
                .usage_stats_range = if (request.usage_stats_range) |range| .{
                    .since = range.since,
                    .before = range.before,
                } else null,
            },
            response_buffer,
        );
    }

    fn performModels(
        context: *anyopaque,
        request: metask_transport.Request,
        response_buffer: []u8,
    ) metask_transport.TransportError!metask_transport.Response {
        return perform(context, request, response_buffer);
    }

    fn perform(
        context: *anyopaque,
        request: metask_transport.Request,
        response_buffer: []u8,
    ) metask_transport.TransportError!metask_transport.Response {
        const self: *Adapter = @ptrCast(@alignCast(context));
        const result = self.http.run(.{
            .consumer = .metask,
            .isolation = isolation(request.principal),
            .budget = .{ .deadline = if (request.control) |control| control.deadline else .fromNow(self.http.io, default_request_timeout) },
            .cancellation = if (request.control) |control| http.Cancellation.atomic(&control.cancellation.state) else null,
        }, fetch, .{ request, response_buffer });
        const send_started = result.send == .may_have_been_sent;
        return switch (result.outcome) {
            .completed => |response| selectedFetch(request, response, response_buffer, send_started),
            .failed => |err| mapError(err, send_started),
        };
    }

    fn mapError(err: http.Error, send_started: bool) metask_transport.TransportError {
        return switch (err) {
            error.Cancelled => if (send_started) error.Cancelled else error.CancelledNotSent,
            error.DeadlineExceeded => if (send_started) error.DeadlineExceeded else error.DeadlineExceededNotSent,
            error.ResponseTooLarge => error.ResponseTooLarge,
            error.InvalidRequest, error.InvalidResponse => error.ProtocolFailed,
            else => if (send_started) error.NetworkFailed else error.NetworkNotSent,
        };
    }

    fn selectedFetch(request: metask_transport.Request, result: FetchResult, response_buffer: []u8, send_started: bool) metask_transport.TransportError!metask_transport.Response {
        const completed = result catch |err| {
            if (request.control) |control| if (control.cancellation.isCancelled()) return mapError(error.Cancelled, send_started);
            return mapError(err, send_started);
        };
        // Account retains authority over late cancellation of non-refresh work.
        // A complete selected refresh response must survive loser cleanup.
        if (request.kind != .refresh_token) if (request.control) |control| {
            if (control.cancellation.isCancelled()) return mapError(error.Cancelled, send_started);
        };
        return .{ .status = completed.status, .body = response_buffer[0..completed.body_len] };
    }

    fn fetch(operation: *http.Operation, request: metask_transport.Request, response_buffer: []u8) FetchResult {
        var authorization_storage: [oauth.Limits.secret_bytes + "Bearer ".len]u8 =
            undefined;
        defer std.crypto.secureZero(u8, &authorization_storage);
        var authorization: []const u8 = "";
        if (request.bearer) |bearer| {
            if (bearer.len == 0 or
                bearer.len > oauth.Limits.secret_bytes or
                std.mem.indexOfAny(u8, bearer, "\r\n") != null)
                return operation.fail(error.InvalidRequest);
            @memcpy(authorization_storage[0.."Bearer ".len], "Bearer ");
            @memcpy(
                authorization_storage["Bearer ".len .. "Bearer ".len + bearer.len],
                bearer,
            );
            authorization = authorization_storage[0 .. "Bearer ".len + bearer.len];
        }

        var endpoint_storage: [384]u8 = undefined;
        const endpoint, const method: std.http.Method = switch (request.kind) {
            .exchange_code, .refresh_token => .{ oauth.token_url, .POST },
            .userinfo => .{ account_metask.userinfo_url, .GET },
            .usage_stats => blk: {
                const range = request.usage_stats_range orelse
                    return operation.fail(error.InvalidRequest);
                const endpoint = std.fmt.bufPrint(
                    &endpoint_storage,
                    "{s}?scope=user&granularity=day&since={s}&before={s}",
                    .{
                        account_metask.usage_stats_url,
                        range.since,
                        range.before,
                    },
                ) catch return operation.fail(error.InvalidRequest);
                break :blk .{ endpoint, .GET };
            },
            .models => .{ models_metask.models_url, .GET },
        };
        var headers: [4]std.http.Header = undefined;
        var header_count: usize = 0;
        headers[header_count] = .{
            .name = "Accept",
            .value = "application/json",
        };
        header_count += 1;
        if (method == .POST) {
            headers[header_count] = .{
                .name = "Content-Type",
                .value = "application/x-www-form-urlencoded",
            };
            header_count += 1;
        }
        if (method == .GET) {
            if (authorization.len == 0) return operation.fail(error.InvalidRequest);
            headers[header_count] = .{
                .name = "Authorization",
                .value = authorization,
            };
            header_count += 1;
        } else if (request.bearer != null) {
            return operation.fail(error.InvalidRequest);
        }
        return fetchHttp(operation, endpoint, method, headers[0..header_count], request.body, response_buffer);
    }

    fn fetchHttp(operation: *http.Operation, endpoint: []const u8, method: std.http.Method, headers: []const std.http.Header, body: []const u8, output: []u8) FetchResult {
        const uri = std.Uri.parse(endpoint) catch return operation.fail(error.InvalidRequest);
        var request = try operation.open(method, uri, .{ .headers = headers });
        defer request.deinit();
        try request.send(if (method == .POST) body else null);
        var response = try request.receiveHead();
        const bytes = try request.readAll(&response, output);
        return .{ .status = @intFromEnum(response.head.status), .body_len = bytes.len };
    }
};

test "Account selected complete refresh response survives late cancellation" {
    var cancellation = metask_transport.Cancellation.init(std.testing.io);
    cancellation.cancel();
    var buffer: [2]u8 = .{ '{', '}' };
    const control: metask_transport.RequestControl = .{
        .cancellation = &cancellation,
        .deadline = std.Io.Clock.Timestamp.fromNow(std.testing.io, .{ .raw = .fromSeconds(30), .clock = .boot }),
    };
    const response = try Adapter.selectedFetch(.{ .kind = .refresh_token, .principal = null, .control = control }, .{ .status = 200, .body_len = 2 }, &buffer, true);
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqualStrings("{}", response.body);
    try std.testing.expectError(error.Cancelled, Adapter.selectedFetch(.{ .kind = .models, .principal = null, .control = control }, .{ .status = 200, .body_len = 2 }, &buffer, true));
    try std.testing.expectError(error.Cancelled, Adapter.selectedFetch(.{ .kind = .refresh_token, .principal = null, .control = control }, error.ReadFailed, &buffer, true));
}

test "Account DNS failure and connection refusal prove refresh was not sent" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .async_limit = .nothing });
    defer threaded.deinit();
    const Failures = struct {
        fn lookup(_: ?*anyopaque, _: std.Io.net.HostName, resolved: *std.Io.Queue(std.Io.net.HostName.LookupResult), _: std.Io.net.HostName.LookupOptions) std.Io.net.HostName.LookupError!void {
            defer resolved.close(std.testing.io);
            return error.UnknownHostName;
        }
        fn connect(_: ?*anyopaque, _: *const std.Io.net.IpAddress, _: std.Io.net.IpAddress.ConnectOptions) std.Io.net.IpAddress.ConnectError!std.Io.net.Socket {
            return error.ConnectionRefused;
        }
    };
    var vtable = threaded.io().vtable.*;
    vtable.netLookup = Failures.lookup;
    var engine: http.Engine = undefined;
    engine.init(std.testing.allocator, .{ .userdata = threaded.io().userdata, .vtable = &vtable });
    defer engine.deinit();
    var adapter: Adapter = .{ .http = &engine };
    var buffer: [64]u8 = undefined;
    try std.testing.expectError(error.NetworkNotSent, adapter.accountTransport().perform(.{ .kind = .refresh_token, .principal = null }, &buffer));

    vtable.netLookup = threaded.io().vtable.netLookup;
    vtable.netConnectIp = Failures.connect;
    const execution = engine.run(.{ .consumer = .metask, .isolation = .public, .budget = .{ .deadline = .fromNow(engine.io, .{ .raw = .fromSeconds(5), .clock = .awake }) } }, Adapter.fetchHttp, .{ "http://127.0.0.1:80/token", std.http.Method.POST, &.{}, "test-body", &buffer });
    const result = execution.outcome.completed;
    const send_started = execution.send == .may_have_been_sent;
    try std.testing.expectError(error.ConnectFailed, result);
    try std.testing.expect(!send_started);
    try std.testing.expectError(error.NetworkNotSent, Adapter.selectedFetch(.{ .kind = .refresh_token, .principal = null }, result, &buffer, send_started));
}

test "Account deadline and cancellation during connection prove refresh was not sent" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .async_limit = .nothing });
    defer threaded.deinit();
    const SlowDns = struct {
        fn lookup(_: ?*anyopaque, _: std.Io.net.HostName, resolved: *std.Io.Queue(std.Io.net.HostName.LookupResult), _: std.Io.net.HostName.LookupOptions) std.Io.net.HostName.LookupError!void {
            defer resolved.close(std.testing.io);
            try std.Io.sleep(std.testing.io, .fromSeconds(30), .awake);
            return error.UnknownHostName;
        }
    };
    var vtable = threaded.io().vtable.*;
    vtable.netLookup = SlowDns.lookup;
    var engine: http.Engine = undefined;
    engine.init(std.testing.allocator, .{ .userdata = threaded.io().userdata, .vtable = &vtable });
    defer engine.deinit();
    var adapter: Adapter = .{ .http = &engine };
    var buffer: [64]u8 = undefined;
    var cancellation = metask_transport.Cancellation.init(std.testing.io);
    var control: metask_transport.RequestControl = .{
        .cancellation = &cancellation,
        .deadline = std.Io.Clock.Timestamp.fromNow(std.testing.io, .{ .raw = .fromMilliseconds(20), .clock = .boot }),
    };
    try std.testing.expectError(error.DeadlineExceededNotSent, adapter.accountTransport().perform(.{ .kind = .refresh_token, .principal = null, .control = control }, &buffer));
    cancellation.cancel();
    control.deadline = std.Io.Clock.Timestamp.fromNow(std.testing.io, .{ .raw = .fromSeconds(30), .clock = .boot });
    try std.testing.expectError(error.CancelledNotSent, adapter.accountTransport().perform(.{ .kind = .refresh_token, .principal = null, .control = control }, &buffer));
}

test "Account HTTP registration failure settles workers before reporting not sent" {
    const Dns = struct {
        fn lookup(_: ?*anyopaque, _: std.Io.net.HostName, resolved: *std.Io.Queue(std.Io.net.HostName.LookupResult), _: std.Io.net.HostName.LookupOptions) std.Io.net.HostName.LookupError!void {
            defer resolved.close(std.testing.io);
            try std.Io.sleep(std.testing.io, .fromSeconds(60), .awake);
            return error.UnknownHostName;
        }
    };
    for (0..3) |capacity| {
        var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .async_limit = .nothing, .concurrent_limit = .limited(capacity) });
        defer threaded.deinit();
        var vtable = threaded.io().vtable.*;
        vtable.netLookup = Dns.lookup;
        var engine: http.Engine = undefined;
        engine.init(std.testing.allocator, .{ .userdata = threaded.io().userdata, .vtable = &vtable });
        defer engine.deinit();
        var adapter: Adapter = .{ .http = &engine };
        var cancellation = metask_transport.Cancellation.init(engine.io);
        var buffer: [32]u8 = undefined;
        try std.testing.expectError(error.NetworkNotSent, adapter.accountTransport().perform(.{ .kind = .refresh_token, .principal = null, .control = .{ .cancellation = &cancellation, .deadline = std.Io.Clock.Timestamp.fromNow(engine.io, .{ .raw = .fromSeconds(60), .clock = .boot }) } }, &buffer));
    }
}

test "Account HTTP send boundary preserves lost-response blocking and bounded responses" {
    const TestServer = struct {
        const Mode = enum { tls_failure, lost_response, complete, compressed, oversized };
        listener: *std.Io.net.Server,
        mode: Mode,
        received_body: bool = false,
        failure: ?anyerror = null,

        fn run(self: *@This()) void {
            self.serve() catch |err| {
                self.failure = err;
            };
        }
        fn serve(self: *@This()) !void {
            var connection = try self.listener.accept(std.testing.io);
            defer connection.close(std.testing.io);
            var read_buffer: [4096]u8 = undefined;
            var write_buffer: [4096]u8 = undefined;
            var reader = connection.reader(std.testing.io, &read_buffer);
            var writer = connection.writer(std.testing.io, &write_buffer);
            if (self.mode == .tls_failure) {
                var record_header: [5]u8 = undefined;
                try reader.interface.readSliceAll(&record_header);
                try reader.interface.discardAll(std.mem.readInt(u16, record_header[3..5], .big));
                // A fatal handshake_failure alert, before any HTTP request.
                try writer.interface.writeAll(&.{ 21, 3, 3, 0, 2, 2, 40 });
                try writer.interface.flush();
                return;
            }
            var server: std.http.Server = .init(&reader.interface, &writer.interface);
            var request = try server.receiveHead();
            const body = request.readerExpectNone(&.{});
            var bytes: [9]u8 = undefined;
            try body.readSliceAll(&bytes);
            if (!std.mem.eql(u8, &bytes, "test-body")) return error.UnexpectedBody;
            self.received_body = true;
            if (self.mode == .lost_response) return;
            if (self.mode == .compressed) {
                // gzip("{}"), to retain the existing compressed-response support.
                try request.respond(&.{ 31, 139, 8, 0, 0, 0, 0, 0, 2, 3, 171, 174, 5, 0, 67, 191, 166, 163, 2, 0, 0, 0 }, .{
                    .keep_alive = false,
                    .extra_headers = &.{.{ .name = "Content-Encoding", .value = "gzip" }},
                });
            } else {
                try request.respond(if (self.mode == .oversized) "123456789" else "{}", .{ .keep_alive = false });
            }
        }
    };
    for ([_]TestServer.Mode{ .tls_failure, .lost_response, .complete, .compressed, .oversized }) |mode| {
        const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        var listener = try address.listen(std.testing.io, .{ .kernel_backlog = 1 });
        defer listener.deinit(std.testing.io);
        var server: TestServer = .{ .listener = &listener, .mode = mode };
        const thread = try std.Thread.spawn(.{}, TestServer.run, .{&server});
        const endpoint = try std.fmt.allocPrint(std.testing.allocator, "{s}://127.0.0.1:{d}/token", .{ if (mode == .tls_failure) "https" else "http", listener.socket.address.getPort() });
        defer std.testing.allocator.free(endpoint);
        var engine: http.Engine = undefined;
        engine.init(std.testing.allocator, std.testing.io);
        defer engine.deinit();
        var buffer: [2]u8 = undefined;
        const execution = engine.run(.{ .consumer = .metask, .isolation = .public, .budget = .{ .deadline = .fromNow(engine.io, .{ .raw = .fromSeconds(5), .clock = .awake }) } }, Adapter.fetchHttp, .{ endpoint, std.http.Method.POST, &.{}, "test-body", &buffer });
        const result = execution.outcome.completed;
        const send_started = execution.send == .may_have_been_sent;
        thread.join();
        try std.testing.expectEqual(@as(?anyerror, null), server.failure);
        try std.testing.expectEqual(mode != .tls_failure, send_started);
        try std.testing.expectEqual(mode != .tls_failure, server.received_body);
        switch (mode) {
            .tls_failure => try std.testing.expectError(error.NetworkNotSent, Adapter.selectedFetch(.{ .kind = .refresh_token, .principal = null }, result, &buffer, send_started)),
            .lost_response => try std.testing.expectError(error.NetworkFailed, Adapter.selectedFetch(.{ .kind = .refresh_token, .principal = null }, result, &buffer, send_started)),
            .oversized => try std.testing.expectError(error.ResponseTooLarge, Adapter.selectedFetch(.{ .kind = .refresh_token, .principal = null }, result, &buffer, send_started)),
            .complete, .compressed => {
                const response = try Adapter.selectedFetch(.{ .kind = .refresh_token, .principal = null }, result, &buffer, send_started);
                try std.testing.expectEqual(@as(u16, 200), response.status);
                try std.testing.expectEqualStrings("{}", response.body);
            },
        }
    }
}

test "Account retire closes the principal's pooled connection only" {
    const KeepAlive = struct {
        listener: *std.Io.net.Server,
        closed: std.atomic.Value(usize) = .init(0),
        /// One connection per thread, so both stay open side by side.
        fn run(self: *@This()) void {
            {
                var connection = self.listener.accept(std.testing.io) catch return;
                defer {
                    connection.close(std.testing.io);
                    _ = self.closed.fetchAdd(1, .acq_rel);
                }
                var reads: [4096]u8 = undefined;
                var writes: [4096]u8 = undefined;
                var reader = connection.reader(std.testing.io, &reads);
                var writer = connection.writer(std.testing.io, &writes);
                var server: std.http.Server = .init(&reader.interface, &writer.interface);
                var request = server.receiveHead() catch return;
                request.respond("{}", .{ .keep_alive = true }) catch return;
                _ = server.receiveHead() catch {};
            }
        }
    };
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = try address.listen(std.testing.io, .{});
    defer listener.deinit(std.testing.io);
    var server: KeepAlive = .{ .listener = &listener };
    var threads: [2]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, KeepAlive.run, .{&server});
    defer for (threads) |thread| thread.join();
    const endpoint = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/userinfo", .{listener.socket.address.getPort()});
    defer std.testing.allocator.free(endpoint);
    var engine: http.Engine = undefined;
    engine.init(std.testing.allocator, std.testing.io);
    defer engine.deinit();
    var adapter: Adapter = .{ .http = &engine };
    var buffer: [8]u8 = undefined;
    for ([_][]const u8{ "account-1", "account-2" }) |principal| {
        const execution = engine.run(.{ .consumer = .metask, .isolation = Adapter.isolation(principal), .budget = .{ .deadline = .fromNow(engine.io, .{ .raw = .fromSeconds(5), .clock = .awake }) } }, Adapter.fetchHttp, .{ endpoint, std.http.Method.GET, &.{}, "", &buffer });
        try std.testing.expectEqual(@as(u16, 200), (try execution.outcome.completed).status);
    }
    adapter.accountTransport().retire("account-1");
    for (0..400) |_| {
        if (server.closed.load(.acquire) == 1) break;
        std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake) catch {};
    }
    try std.testing.expectEqual(@as(usize, 1), server.closed.load(.acquire));
    var pooled: usize = 0;
    for (&engine.slots) |*slot| {
        if (slot.client.connection_pool.free_len == 0) continue;
        try std.testing.expect(slot.isolation.eql(Adapter.isolation("account-2")));
        pooled += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), pooled);
}
