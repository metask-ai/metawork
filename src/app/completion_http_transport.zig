//! Application-owned Completion and streamed download HTTP adapter.
const std = @import("std");
const http = @import("app_http_transport");
const agent = @import("metawork_agent");

pub const Backend = struct {
    http: *http.Engine,

    pub fn transport(self: *Backend) agent.CompletionTransport {
        return .{ .context = self, .perform_fn = perform, .signal_cancellation_fn = signalCancellation };
    }

    pub fn createCompletion(context: ?*anyopaque, allocator: std.mem.Allocator, binding: agent.ModelBinding) anyerror!*agent.Completion {
        const self: *Backend = @ptrCast(@alignCast(context.?));
        return agent.Completion.init(allocator, self.transport(), binding);
    }

    fn perform(context: ?*anyopaque, request: agent.CompletionHttpRequest, cancellation: *const agent.CompletionCancellation, response_buffer: []u8) agent.CompletionTransportError!agent.CompletionTransportResponse {
        const self: *Backend = @ptrCast(@alignCast(context.?));
        const result = self.http.run(.{ .consumer = .completion, .cancellation = .atomic(&cancellation.state) }, fetch, .{ request, response_buffer });
        return switch (result.outcome) {
            .completed => |response| response catch |err| mapError(err),
            .failed => |err| mapError(err),
        };
    }

    fn signalCancellation(context: ?*anyopaque, cancellation: *agent.CompletionCancellation) void {
        const self: *Backend = @ptrCast(@alignCast(context.?));
        self.http.io.futexWake(u32, &cancellation.state.raw, std.math.maxInt(u32));
    }

    fn fetch(operation: *http.Operation, input: agent.CompletionHttpRequest, output: []u8) http.Error!agent.CompletionTransportResponse {
        if (input.url.len == 0 or input.headers.len > 16 or
            (input.method == .post and (input.body.len == 0 or input.stream != null)) or
            (input.method == .get and input.body.len != 0)) return operation.fail(error.InvalidRequest);
        var headers: [16]std.http.Header = undefined;
        for (input.headers, 0..) |header, index| headers[index] = .{ .name = header.name, .value = header.value };
        const uri = std.Uri.parse(input.url) catch return operation.fail(error.InvalidRequest);
        var request = try operation.open(if (input.method == .post) .POST else .GET, uri, .{ .headers = headers[0..input.headers.len] });
        defer request.deinit();
        try request.send(if (input.method == .post) input.body else null);
        var response = try request.receiveHead();
        const status: u16 = @intFromEnum(response.head.status);
        if (input.stream) |stream| {
            if (status == 200) {
                if (response.head.content_encoding != .identity) return operation.fail(error.InvalidResponse);
                var transfer_buffer: [1024]u8 = undefined;
                stream.receive_fn(stream.context, response.head.content_type, response.head.content_length, response.reader(&transfer_buffer));
            }
            return .{ .status = status, .body = &.{} };
        }
        return .{ .status = status, .body = try request.readAll(&response, output) };
    }
};

fn mapError(err: http.Error) agent.CompletionTransportError {
    return switch (err) {
        error.Cancelled => error.Cancelled,
        error.DnsFailed => error.DnsFailed,
        error.ConnectFailed => error.ConnectFailed,
        error.TlsFailed => error.TlsFailed,
        error.WriteFailed => error.WriteFailed,
        error.ReadFailed => error.ReadFailed,
        error.InvalidRequest, error.InvalidResponse => error.InvalidHttp,
        error.ResponseTooLarge => error.ResponseTooLarge,
        error.ResourceLimit => error.ResourceLimit,
        error.OutOfMemory => error.OutOfMemory,
        error.DeadlineExceeded => error.Unexpected,
    };
}

test "Completion HTTP adapter public surface is analyzed" {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Backend);
}

test "Completion HTTP registration failure settles an already started request" {
    const Dns = struct {
        fn lookup(_: ?*anyopaque, _: std.Io.net.HostName, resolved: *std.Io.Queue(std.Io.net.HostName.LookupResult), _: std.Io.net.HostName.LookupOptions) std.Io.net.HostName.LookupError!void {
            defer resolved.close(std.testing.io);
            try std.Io.sleep(std.testing.io, .fromSeconds(60), .awake);
            return error.UnknownHostName;
        }
    };
    for (0..2) |capacity| {
        var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .async_limit = .nothing, .concurrent_limit = .limited(capacity) });
        defer threaded.deinit();
        var vtable = threaded.io().vtable.*;
        vtable.netLookup = Dns.lookup;
        var engine: http.Engine = undefined;
        engine.init(std.testing.allocator, .{ .userdata = threaded.io().userdata, .vtable = &vtable });
        defer engine.deinit();
        var backend: Backend = .{ .http = &engine };
        var cancellation = agent.CompletionCancellation.init(backend.transport());
        var buffer: [32]u8 = undefined;
        try std.testing.expectError(error.ResourceLimit, backend.transport().perform(.{ .url = "https://completion.invalid/messages", .headers = &.{}, .body = "fixture" }, &cancellation, &buffer));
    }
}

test "Completion lost response is a read failure after one POST" {
    const Server = struct {
        listener: *std.Io.net.Server,
        received: bool = false,
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
            var request = try server.receiveHead();
            try std.testing.expectEqual(std.http.Method.POST, request.head.method);
            var bytes: [2]u8 = undefined;
            try request.readerExpectNone(&.{}).readSliceAll(&bytes);
            try std.testing.expectEqualStrings("{}", &bytes);
            self.received = true;
        }
    };
    var engine: http.Engine = undefined;
    engine.init(std.testing.allocator, std.testing.io);
    defer engine.deinit();
    var backend: Backend = .{ .http = &engine };
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = try address.listen(std.testing.io, .{});
    defer listener.deinit(std.testing.io);
    var server: Server = .{ .listener = &listener };
    const thread = try std.Thread.spawn(.{}, Server.run, .{&server});
    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/complete", .{listener.socket.address.getPort()});
    defer std.testing.allocator.free(url);
    var cancellation = agent.CompletionCancellation.init(backend.transport());
    var output: [8]u8 = undefined;
    const result = backend.transport().perform(.{ .url = url, .headers = &.{}, .body = "{}" }, &cancellation, &output);
    thread.join();
    try std.testing.expectEqual(@as(?anyerror, null), server.failure);
    try std.testing.expect(server.received);
    try std.testing.expectError(error.ReadFailed, result);
}

test "Completion blocked streamed GET neither blocks another request nor outlives cancel" {
    const Stream = struct {
        entered: std.Io.Event = .unset,
        returned: std.atomic.Value(bool) = .init(false),
        fn receive(context: *anyopaque, _: ?[]const u8, _: ?u64, reader: *std.Io.Reader) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.entered.set(std.testing.io);
            defer self.returned.store(true, .release);
            _ = reader.takeByte() catch return;
        }
    };
    const Server = struct {
        listener: *std.Io.net.Server,
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            self.serve() catch |err| {
                self.failure = err;
            };
        }
        fn serve(self: *@This()) !void {
            var held = try self.listener.accept(std.testing.io);
            defer held.close(std.testing.io);
            var held_reads: [4096]u8 = undefined;
            var held_writes: [256]u8 = undefined;
            var held_reader = held.reader(std.testing.io, &held_reads);
            var held_writer = held.writer(std.testing.io, &held_writes);
            var first: std.http.Server = .init(&held_reader.interface, &held_writer.interface);
            _ = try first.receiveHead();
            try held_writer.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\n");
            try held_writer.interface.flush();
            var other = try self.listener.accept(std.testing.io);
            defer other.close(std.testing.io);
            var reads: [4096]u8 = undefined;
            var writes: [256]u8 = undefined;
            var reader = other.reader(std.testing.io, &reads);
            var writer = other.writer(std.testing.io, &writes);
            var second: std.http.Server = .init(&reader.interface, &writer.interface);
            var request = try second.receiveHead();
            try request.respond("{}", .{ .keep_alive = false });
            try std.testing.expectError(error.EndOfStream, held_reader.interface.takeByte());
        }
    };
    var engine: http.Engine = undefined;
    engine.init(std.testing.allocator, std.testing.io);
    defer engine.deinit();
    var backend: Backend = .{ .http = &engine };
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = try address.listen(std.testing.io, .{});
    defer listener.deinit(std.testing.io);
    var server: Server = .{ .listener = &listener };
    const thread = try std.Thread.spawn(.{}, Server.run, .{&server});
    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/stream", .{listener.socket.address.getPort()});
    defer std.testing.allocator.free(url);
    var stream: Stream = .{};
    var cancellation = agent.CompletionCancellation.init(backend.transport());
    var held_output: [8]u8 = undefined;
    var held = try std.testing.io.concurrent(Backend.perform, .{
        @as(?*anyopaque, &backend),
        @as(agent.CompletionHttpRequest, .{ .method = .get, .url = url, .headers = &.{}, .body = "", .stream = .{ .context = &stream, .receive_fn = Stream.receive } }),
        &cancellation,
        &held_output,
    });
    defer {
        cancellation.request();
        _ = held.cancel(std.testing.io) catch {};
    }
    stream.entered.waitUncancelable(std.testing.io);
    var other_cancellation = agent.CompletionCancellation.init(backend.transport());
    var output: [8]u8 = undefined;
    const other = try backend.transport().perform(.{ .method = .get, .url = url, .headers = &.{}, .body = "" }, &other_cancellation, &output);
    try std.testing.expectEqualStrings("{}", other.body);
    try std.testing.expect(!stream.returned.load(.acquire));
    cancellation.request();
    try std.testing.expectError(error.Cancelled, held.await(std.testing.io));
    thread.join();
    try std.testing.expectEqual(@as(?anyerror, null), server.failure);
    try std.testing.expect(stream.returned.load(.acquire));
}
