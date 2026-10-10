const std = @import("std");
const oauth = @import("account_oauth");
const account_metask = @import("metask_client");
const metask_transport = @import("metask_transport");
const models_metask = @import("product_models_metask");

/// Application-owned HTTP execution shared by Account's narrow transport port
/// and the Models Metask provider transport leaf. Account owns OAuth and
/// identity request policy; Models owns catalog request policy. This adapter
/// only maps their request kinds to network effects.
pub const Adapter = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    const default_request_timeout: std.Io.Clock.Duration = .{
        .raw = .fromSeconds(30),
        .clock = .boot,
    };

    const FetchResult = union(enum) {
        completed: struct {
            status: u16,
            body_len: usize,
        },
        network_failed,
        response_too_large,
        protocol_failed,
    };

    const Outcome = union(enum) {
        fetch: FetchResult,
        deadline,
        cancelled,
    };

    pub fn accountTransport(self: *Adapter) account_metask.Transport {
        return .{
            .context = self,
            .perform_fn = performAccount,
        };
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
        const deadline = if (request.control) |control|
            control.deadline
        else
            std.Io.Clock.Timestamp.fromNow(
                self.io,
                default_request_timeout,
            );
        // Only fetch writes this flag. Read it after cancelDiscard has joined
        // every worker, including on deadline/cancellation paths.
        var send_started = false;
        var outcome_storage: [3]Outcome = undefined;
        var selection = std.Io.Select(Outcome).init(
            self.io,
            &outcome_storage,
        );
        selection.async(
            .fetch,
            fetch,
            .{ self, request, response_buffer, &send_started },
        );
        selection.async(
            .deadline,
            waitDeadline,
            .{ self.io, deadline },
        );
        if (request.control) |control| {
            selection.async(
                .cancelled,
                waitCancellation,
                .{control.cancellation},
            );
        }
        const outcome = selection.await() catch {
            selection.cancelDiscard();
            return if (send_started) error.NetworkFailed else error.NetworkNotSent;
        };
        switch (outcome) {
            .fetch => |result| {
                selection.cancelDiscard();
                return selectedFetch(request, result, response_buffer, send_started);
            },
            .deadline => {
                selection.cancelDiscard();
                return if (send_started) error.DeadlineExceeded else error.DeadlineExceededNotSent;
            },
            .cancelled => {
                selection.cancelDiscard();
                return if (send_started) error.Cancelled else error.CancelledNotSent;
            },
        }
    }

    fn selectedFetch(request: metask_transport.Request, result: FetchResult, response_buffer: []u8, send_started: bool) metask_transport.TransportError!metask_transport.Response {
        // The selector already chose fetch. A complete refresh response is
        // authoritative even when cancellation arrives during loser cleanup.
        const complete_refresh = request.kind == .refresh_token and result == .completed;
        if (!complete_refresh) if (request.control) |control| {
            if (control.cancellation.isCancelled()) return if (send_started) error.Cancelled else error.CancelledNotSent;
        };
        return switch (result) {
            .completed => |completed| .{ .status = completed.status, .body = response_buffer[0..completed.body_len] },
            .network_failed => if (send_started) error.NetworkFailed else error.NetworkNotSent,
            .response_too_large => error.ResponseTooLarge,
            .protocol_failed => error.ProtocolFailed,
        };
    }

    fn fetch(
        self: *Adapter,
        request: metask_transport.Request,
        response_buffer: []u8,
        send_started: *bool,
    ) FetchResult {
        var client: std.http.Client = .{
            .allocator = self.allocator,
            .io = self.io,
        };
        defer client.deinit();

        var authorization_storage: [oauth.Limits.secret_bytes + "Bearer ".len]u8 =
            undefined;
        defer std.crypto.secureZero(u8, &authorization_storage);
        var authorization: []const u8 = "";
        if (request.bearer) |bearer| {
            if (bearer.len == 0 or
                bearer.len > oauth.Limits.secret_bytes or
                std.mem.indexOfAny(u8, bearer, "\r\n") != null)
                return .protocol_failed;
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
                    return .protocol_failed;
                const endpoint = std.fmt.bufPrint(
                    &endpoint_storage,
                    "{s}?scope=user&granularity=day&since={s}&before={s}",
                    .{
                        account_metask.usage_stats_url,
                        range.since,
                        range.before,
                    },
                ) catch return .protocol_failed;
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
            if (authorization.len == 0) return .protocol_failed;
            headers[header_count] = .{
                .name = "Authorization",
                .value = authorization,
            };
            header_count += 1;
        } else if (request.bearer != null) {
            return .protocol_failed;
        }
        return fetchHttp(&client, endpoint, method, headers[0..header_count], request.body, response_buffer, send_started);
    }

    fn fetchHttp(
        client: *std.http.Client,
        endpoint: []const u8,
        method: std.http.Method,
        headers: []const std.http.Header,
        body_bytes: []const u8,
        response_buffer: []u8,
        send_started: *bool,
    ) FetchResult {
        const uri = std.Uri.parse(endpoint) catch return .protocol_failed;
        // request completes DNS, TCP and TLS without sending HTTP bytes.
        var req = client.request(method, uri, .{
            .redirect_behavior = .unhandled,
            .extra_headers = headers,
        }) catch return .network_failed;
        defer req.deinit();

        // Mark before the first operation that may write any HTTP bytes.
        // A failure from this point onward cannot prove nonconsumption.
        send_started.* = true;
        if (method == .POST) {
            req.transfer_encoding = .{ .content_length = body_bytes.len };
            var body = req.sendBodyUnflushed(&.{}) catch return .network_failed;
            body.writer.writeAll(body_bytes) catch return .network_failed;
            body.end() catch return .network_failed;
            req.connection.?.flush() catch return .network_failed;
        } else {
            req.sendBodiless() catch return .network_failed;
        }
        var response = req.receiveHead(&.{}) catch return .network_failed;
        const decompress_buffer: []u8 = switch (response.head.content_encoding) {
            .identity => &.{},
            .zstd => client.allocator.alloc(u8, std.compress.zstd.default_window_len) catch return .network_failed,
            .deflate, .gzip => client.allocator.alloc(u8, std.compress.flate.max_window_len) catch return .network_failed,
            .compress => return .network_failed,
        };
        defer if (decompress_buffer.len != 0) client.allocator.free(decompress_buffer);
        var transfer_buffer: [64]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
        var response_writer = std.Io.Writer.fixed(response_buffer);
        _ = reader.streamRemaining(&response_writer) catch |err| switch (err) {
            error.WriteFailed => return .response_too_large,
            error.ReadFailed => return .network_failed,
        };
        return .{ .completed = .{
            .status = @intFromEnum(response.head.status),
            .body_len = response_writer.buffered().len,
        } };
    }

    fn waitDeadline(
        io: std.Io,
        deadline: std.Io.Clock.Timestamp,
    ) void {
        deadline.wait(io) catch {};
    }

    fn waitCancellation(cancellation: *const metask_transport.Cancellation) void {
        cancellation.wait();
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
    const response = try Adapter.selectedFetch(.{ .kind = .refresh_token, .control = control }, .{ .completed = .{ .status = 200, .body_len = 2 } }, &buffer, true);
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqualStrings("{}", response.body);
    try std.testing.expectError(error.Cancelled, Adapter.selectedFetch(.{ .kind = .models, .control = control }, .{ .completed = .{ .status = 200, .body_len = 2 } }, &buffer, true));
    try std.testing.expectError(error.Cancelled, Adapter.selectedFetch(.{ .kind = .refresh_token, .control = control }, .network_failed, &buffer, true));
}

test "Account DNS failure and connection refusal prove refresh was not sent" {
    const Failures = struct {
        fn lookup(_: ?*anyopaque, _: std.Io.net.HostName, resolved: *std.Io.Queue(std.Io.net.HostName.LookupResult), _: std.Io.net.HostName.LookupOptions) std.Io.net.HostName.LookupError!void {
            defer resolved.close(std.testing.io);
            return error.UnknownHostName;
        }
        fn connect(_: ?*anyopaque, _: *const std.Io.net.IpAddress, _: std.Io.net.IpAddress.ConnectOptions) std.Io.net.IpAddress.ConnectError!std.Io.net.Socket {
            return error.ConnectionRefused;
        }
    };
    var vtable = std.testing.io.vtable.*;
    vtable.netLookup = Failures.lookup;
    var adapter: Adapter = .{ .allocator = std.testing.allocator, .io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable } };
    var buffer: [64]u8 = undefined;
    try std.testing.expectError(error.NetworkNotSent, adapter.accountTransport().perform(.{ .kind = .refresh_token }, &buffer));

    vtable.netConnectIp = Failures.connect;
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = adapter.io };
    defer client.deinit();
    var send_started = false;
    const result = Adapter.fetchHttp(&client, "http://127.0.0.1:80/token", .POST, &.{}, "test-body", &buffer, &send_started);
    try std.testing.expect(result == .network_failed);
    try std.testing.expect(!send_started);
    try std.testing.expectError(error.NetworkNotSent, Adapter.selectedFetch(.{ .kind = .refresh_token }, result, &buffer, send_started));
}

test "Account deadline and cancellation during connection prove refresh was not sent" {
    const SlowDns = struct {
        fn lookup(_: ?*anyopaque, _: std.Io.net.HostName, resolved: *std.Io.Queue(std.Io.net.HostName.LookupResult), _: std.Io.net.HostName.LookupOptions) std.Io.net.HostName.LookupError!void {
            defer resolved.close(std.testing.io);
            try std.Io.sleep(std.testing.io, .fromSeconds(30), .awake);
            return error.UnknownHostName;
        }
    };
    var vtable = std.testing.io.vtable.*;
    vtable.netLookup = SlowDns.lookup;
    var adapter: Adapter = .{ .allocator = std.testing.allocator, .io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable } };
    var buffer: [64]u8 = undefined;
    var cancellation = metask_transport.Cancellation.init(std.testing.io);
    var control: metask_transport.RequestControl = .{
        .cancellation = &cancellation,
        .deadline = std.Io.Clock.Timestamp.fromNow(std.testing.io, .{ .raw = .fromMilliseconds(20), .clock = .boot }),
    };
    try std.testing.expectError(error.DeadlineExceededNotSent, adapter.accountTransport().perform(.{ .kind = .refresh_token, .control = control }, &buffer));
    cancellation.cancel();
    control.deadline = std.Io.Clock.Timestamp.fromNow(std.testing.io, .{ .raw = .fromSeconds(30), .clock = .boot });
    try std.testing.expectError(error.CancelledNotSent, adapter.accountTransport().perform(.{ .kind = .refresh_token, .control = control }, &buffer));
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
        var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
        defer client.deinit();
        var send_started = false;
        var buffer: [2]u8 = undefined;
        const result = Adapter.fetchHttp(&client, endpoint, .POST, &.{}, "test-body", &buffer, &send_started);
        thread.join();
        try std.testing.expectEqual(@as(?anyerror, null), server.failure);
        try std.testing.expectEqual(mode != .tls_failure, send_started);
        try std.testing.expectEqual(mode != .tls_failure, server.received_body);
        switch (mode) {
            .tls_failure => try std.testing.expectError(error.NetworkNotSent, Adapter.selectedFetch(.{ .kind = .refresh_token }, result, &buffer, send_started)),
            .lost_response => try std.testing.expectError(error.NetworkFailed, Adapter.selectedFetch(.{ .kind = .refresh_token }, result, &buffer, send_started)),
            .oversized => try std.testing.expectError(error.ResponseTooLarge, Adapter.selectedFetch(.{ .kind = .refresh_token }, result, &buffer, send_started)),
            .complete, .compressed => {
                const response = try Adapter.selectedFetch(.{ .kind = .refresh_token }, result, &buffer, send_started);
                try std.testing.expectEqual(@as(u16, 200), response.status);
                try std.testing.expectEqualStrings("{}", response.body);
            },
        }
    }
}
