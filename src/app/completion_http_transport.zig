//! Application-owned HTTP/TLS effect for Agent requests.

const std = @import("std");
const http_memory = @import("app_http_memory");
const agent = @import("metawork_agent");
const select_start = @import("app_select_start");

pub const Backend = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    pub fn transport(self: *Backend) agent.CompletionTransport {
        return .{
            .context = self,
            .perform_fn = perform,
            .signal_cancellation_fn = signalCancellation,
        };
    }

    pub fn createCompletion(
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        binding: agent.ModelBinding,
    ) anyerror!*agent.Completion {
        const self: *Backend = @ptrCast(@alignCast(context.?));
        return agent.Completion.init(allocator, self.transport(), binding);
    }

    fn perform(
        context: ?*anyopaque,
        request: agent.CompletionHttpRequest,
        cancellation: *const agent.CompletionCancellation,
        response_buffer: []u8,
    ) agent.CompletionTransportError!agent.CompletionTransportResponse {
        const self: *Backend = @ptrCast(@alignCast(context.?));
        if (cancellation.isRequested()) return error.Cancelled;
        var wait = CancelWait{
            .backend = self,
            .cancellation = cancellation,
        };
        var outcomes: [2]Outcome = undefined;
        var selection = std.Io.Select(Outcome).init(self.io, &outcomes);
        select_start.start(&selection, .{
            .{ .operation, fetch, .{ self, request, response_buffer } },
            .{ .cancelled, CancelWait.run, .{&wait} },
        }) catch return error.Unexpected;
        const outcome = selection.await() catch {
            wait.stop();
            selection.cancelDiscard();
            return error.Unexpected;
        };
        return switch (outcome) {
            .operation => |attempt| result: {
                wait.stop();
                selection.cancelDiscard();
                if (cancellation.isRequested()) break :result error.Cancelled;
                break :result attempt;
            },
            .cancelled => result: {
                selection.cancelDiscard();
                break :result error.Cancelled;
            },
        };
    }

    fn signalCancellation(
        context: ?*anyopaque,
        cancellation: *agent.CompletionCancellation,
    ) void {
        const self: *Backend = @ptrCast(@alignCast(context.?));
        self.io.futexWake(
            u32,
            &cancellation.state.raw,
            std.math.maxInt(u32),
        );
    }

    fn fetch(
        self: *Backend,
        request: agent.CompletionHttpRequest,
        response_buffer: []u8,
    ) agent.CompletionTransportError!agent.CompletionTransportResponse {
        if (request.url.len == 0 or request.headers.len > 16 or
            (request.method == .post and (request.body.len == 0 or request.stream != null)) or
            (request.method == .get and request.body.len != 0))
            return error.InvalidHttp;
        var headers: [16]std.http.Header = undefined;
        for (request.headers, 0..) |header, index| {
            if (header.name.len == 0 or
                std.mem.indexOfAny(u8, header.name, "\r\n:") != null or
                std.mem.indexOfAny(u8, header.value, "\r\n") != null)
                return error.InvalidHttp;
            headers[index] = .{ .name = header.name, .value = header.value };
        }
        var response_writer = std.Io.Writer.fixed(response_buffer);
        var memory: http_memory.ZeroingAllocator = .{ .backing = self.allocator };
        var client: std.http.Client = .{
            .allocator = memory.allocator(),
            .io = self.io,
        };
        defer client.deinit();
        if (request.stream != null) return fetchStream(&client, request, headers[0..request.headers.len]);
        const result = client.fetch(.{
            .location = .{ .url = request.url },
            .method = if (request.method == .post) .POST else .GET,
            .payload = if (request.method == .post) request.body else null,
            .redirect_behavior = .unhandled,
            .response_writer = &response_writer,
            .extra_headers = headers[0..request.headers.len],
        }) catch |failure| return mapFetchError(failure);
        return .{
            .status = @intFromEnum(result.status),
            .body = response_writer.buffered(),
        };
    }

    fn fetchStream(client: *std.http.Client, input: agent.CompletionHttpRequest, headers: []const std.http.Header) agent.CompletionTransportError!agent.CompletionTransportResponse {
        const uri = std.Uri.parse(input.url) catch return error.InvalidHttp;
        var request = client.request(.GET, uri, .{ .redirect_behavior = .unhandled, .keep_alive = false, .extra_headers = headers }) catch |err| return mapFetchError(err);
        defer request.deinit();
        request.sendBodiless() catch |err| return mapFetchError(err);
        var response = request.receiveHead(&.{}) catch |err| return mapFetchError(err);
        const status: u16 = @intFromEnum(response.head.status);
        if (status == 200) {
            if (response.head.content_encoding != .identity) return error.InvalidHttp;
            const content_type = response.head.content_type;
            const content_length = response.head.content_length;
            var transfer_buffer: [1024]u8 = undefined;
            const stream = input.stream.?;
            stream.receive_fn(stream.context, content_type, content_length, response.reader(&transfer_buffer));
        }
        return .{ .status = status, .body = &.{} };
    }
};

const Outcome = union(enum) {
    operation: agent.CompletionTransportError!agent.CompletionTransportResponse,
    cancelled,
};

const CancelWait = struct {
    backend: *Backend,
    cancellation: *const agent.CompletionCancellation,
    stopped: std.atomic.Value(bool) = .init(false),

    fn run(self: *CancelWait) void {
        while (!self.stopped.load(.acquire) and
            !self.cancellation.isRequested())
        {
            self.backend.io.futexWait(
                u32,
                &self.cancellation.state.raw,
                0,
            ) catch return;
        }
    }

    fn stop(self: *CancelWait) void {
        self.stopped.store(true, .release);
        self.backend.io.futexWake(
            u32,
            &self.cancellation.state.raw,
            std.math.maxInt(u32),
        );
    }
};

fn mapFetchError(failure: anyerror) agent.CompletionTransportError {
    return switch (failure) {
        error.StreamTooLong => error.ResponseTooLarge,
        error.UnknownHostName, error.NoAddressReturned => error.DnsFailed,
        error.TlsInitializationFailed => error.TlsFailed,
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Cancelled,
        else => error.ConnectFailed,
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
        var backend: Backend = .{ .allocator = std.testing.allocator, .io = .{ .userdata = threaded.io().userdata, .vtable = &vtable } };
        var cancellation = agent.CompletionCancellation.init(backend.transport());
        var buffer: [32]u8 = undefined;
        try std.testing.expectError(error.Unexpected, backend.transport().perform(.{ .url = "https://completion.invalid/messages", .headers = &.{}, .body = "fixture" }, &cancellation, &buffer));
    }
}
