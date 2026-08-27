//! Application-owned buffered HTTP/TLS effect for Agent Completion.

const std = @import("std");
const agent = @import("metawork_agent");

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
        config: agent.CompletionConfig,
    ) anyerror!*agent.Completion {
        const self: *Backend = @ptrCast(@alignCast(context.?));
        return agent.Completion.init(allocator, self.transport(), config);
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
        selection.async(.operation, fetch, .{ self, request, response_buffer });
        selection.async(.cancelled, CancelWait.run, .{&wait});
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
        if (request.url.len == 0 or request.body.len == 0 or request.headers.len > 16)
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
        var client: std.http.Client = .{
            .allocator = self.allocator,
            .io = self.io,
        };
        defer client.deinit();
        const result = client.fetch(.{
            .location = .{ .url = request.url },
            .method = .POST,
            .payload = request.body,
            .redirect_behavior = .unhandled,
            .response_writer = &response_writer,
            .extra_headers = headers[0..request.headers.len],
        }) catch |failure| return mapFetchError(failure);
        return .{
            .status = @intFromEnum(result.status),
            .body = response_writer.buffered(),
        };
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
