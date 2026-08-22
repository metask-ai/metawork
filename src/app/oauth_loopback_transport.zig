const std = @import("std");
const policy = @import("account_loopback");
const oauth = @import("account_oauth");

const request_head_bytes: usize = 16 * 1024;
const response_bytes: usize = 4096;

/// Application-owned OAuth loopback server. Listener and connection handles,
/// cancellation/deadline races and HTTP byte mechanics never cross into the
/// Account policy sink.
pub const Server = struct {
    io: std.Io,
    listener: std.Io.net.Server,
    port_value: u16,
    stop_requested: std.atomic.Value(u32) = .init(0),
    listener_closed: std.atomic.Value(bool) = .init(false),

    pub fn init(io: std.Io) policy.ServerError!Server {
        const address: std.Io.net.IpAddress = .{
            .ip4 = .loopback(0),
        };
        const listener = address.listen(io, .{
            .kernel_backlog = 4,
            .reuse_address = false,
        }) catch return error.BindFailed;
        errdefer {
            var cleanup = listener;
            cleanup.deinit(io);
        }
        const assigned_port = listener.socket.address.getPort();
        if (assigned_port == 0) return error.PortUnavailable;
        return .{
            .io = io,
            .listener = listener,
            .port_value = assigned_port,
        };
    }

    pub fn port(self: *const Server) u16 {
        return self.port_value;
    }

    pub fn wait(
        self: *Server,
        sink: policy.RequestSink,
        deadline: std.Io.Clock.Timestamp,
    ) policy.ServerError!void {
        errdefer self.finish();
        while (true) {
            if (self.isStopRequested()) return error.Cancelled;
            var connection = try self.acceptUntil(deadline);
            defer connection.close(self.io);
            var read_buffer: [request_head_bytes]u8 = undefined;
            var write_buffer: [response_bytes]u8 = undefined;
            var reader = connection.reader(self.io, &read_buffer);
            var writer = connection.writer(self.io, &write_buffer);
            var http_server: std.http.Server = .init(
                &reader.interface,
                &writer.interface,
            );
            var request = self.receiveHeadUntil(
                &http_server,
                deadline,
            ) catch |err| switch (err) {
                error.RequestInvalid => {
                    try sink.invalid();
                    continue;
                },
                else => return err,
            };
            const response = try sink.handle(.{
                .method = if (request.head.method == .GET) .get else .other,
                .target = request.head.target,
                .has_content_length = request.head.content_length != null,
                .has_transfer_encoding = request.head.transfer_encoding != .none,
            });
            respond(&request, response) catch return error.IoFailed;
            if (response.complete) {
                self.finish();
                return;
            }
        }
    }

    pub fn cancel(self: *Server) void {
        self.requestStop();
    }

    pub fn deinit(self: *Server) void {
        self.finish();
        self.* = undefined;
    }

    fn requestStop(self: *Server) void {
        if (self.stop_requested.swap(1, .acq_rel) == 0) {
            self.io.futexWake(
                u32,
                &self.stop_requested.raw,
                std.math.maxInt(u32),
            );
        }
    }

    fn closeListener(self: *Server) void {
        if (!self.listener_closed.swap(true, .acq_rel))
            self.listener.socket.close(self.io);
    }

    fn finish(self: *Server) void {
        self.requestStop();
        self.closeListener();
    }

    fn isStopRequested(self: *const Server) bool {
        return self.stop_requested.load(.acquire) != 0;
    }

    const AcceptResult = union(enum) {
        stream: std.Io.net.Stream,
        cancelled,
        failed,
    };

    const AcceptOutcome = union(enum) {
        accepted: AcceptResult,
        deadline,
        cancelled,
    };

    fn acceptUntil(
        self: *Server,
        deadline: std.Io.Clock.Timestamp,
    ) policy.ServerError!std.Io.net.Stream {
        var outcome_storage: [3]AcceptOutcome = undefined;
        var selection = std.Io.Select(AcceptOutcome).init(
            self.io,
            &outcome_storage,
        );
        selection.async(.accepted, acceptOne, .{self});
        selection.async(.deadline, waitDeadline, .{ self.io, deadline });
        selection.async(.cancelled, waitStop, .{self});
        const outcome = selection.await() catch {
            while (selection.cancel()) |remaining| closeAccepted(self.io, remaining);
            if (self.isStopRequested()) {
                self.closeListener();
                return error.Cancelled;
            }
            return error.IoFailed;
        };
        return switch (outcome) {
            .accepted => |accepted| blk: {
                selection.cancelDiscard();
                if (self.isStopRequested()) {
                    closeAcceptResult(self.io, accepted);
                    self.closeListener();
                    return error.Cancelled;
                }
                break :blk switch (accepted) {
                    .stream => |stream| stream,
                    .cancelled => error.Cancelled,
                    .failed => error.IoFailed,
                };
            },
            .deadline => {
                while (selection.cancel()) |remaining| closeAccepted(self.io, remaining);
                self.finish();
                return error.DeadlineExceeded;
            },
            .cancelled => {
                while (selection.cancel()) |remaining| closeAccepted(self.io, remaining);
                self.closeListener();
                return error.Cancelled;
            },
        };
    }

    fn acceptOne(self: *Server) AcceptResult {
        const stream = self.listener.accept(self.io) catch |err| switch (err) {
            error.SocketNotListening => return .cancelled,
            else => return .failed,
        };
        return .{ .stream = stream };
    }

    fn closeAcceptResult(io: std.Io, result: AcceptResult) void {
        switch (result) {
            .stream => |stream| stream.close(io),
            .cancelled, .failed => {},
        }
    }

    fn closeAccepted(io: std.Io, outcome: AcceptOutcome) void {
        switch (outcome) {
            .accepted => |accepted| closeAcceptResult(io, accepted),
            .deadline, .cancelled => {},
        }
    }

    fn waitDeadline(io: std.Io, deadline: std.Io.Clock.Timestamp) void {
        deadline.wait(io) catch {};
    }

    const ReceiveResult = union(enum) {
        request: std.http.Server.Request,
        invalid,
    };

    const ReceiveOutcome = union(enum) {
        received: ReceiveResult,
        deadline,
        cancelled,
    };

    fn receiveHeadUntil(
        self: *Server,
        http_server: *std.http.Server,
        deadline: std.Io.Clock.Timestamp,
    ) policy.ServerError!std.http.Server.Request {
        var outcome_storage: [3]ReceiveOutcome = undefined;
        var selection = std.Io.Select(ReceiveOutcome).init(
            self.io,
            &outcome_storage,
        );
        selection.async(.received, receiveHead, .{http_server});
        selection.async(.deadline, waitDeadline, .{ self.io, deadline });
        selection.async(.cancelled, waitStop, .{self});
        const outcome = selection.await() catch {
            selection.cancelDiscard();
            return error.IoFailed;
        };
        return switch (outcome) {
            .received => |received| blk: {
                selection.cancelDiscard();
                if (self.isStopRequested()) return error.Cancelled;
                break :blk switch (received) {
                    .request => |request| request,
                    .invalid => error.RequestInvalid,
                };
            },
            .deadline => {
                selection.cancelDiscard();
                self.finish();
                return error.DeadlineExceeded;
            },
            .cancelled => {
                selection.cancelDiscard();
                self.closeListener();
                return error.Cancelled;
            },
        };
    }

    fn receiveHead(http_server: *std.http.Server) ReceiveResult {
        return .{ .request = http_server.receiveHead() catch return .invalid };
    }

    fn waitStop(self: *const Server) void {
        while (!self.isStopRequested()) {
            self.io.futexWait(
                u32,
                &self.stop_requested.raw,
                0,
            ) catch return;
        }
    }
};

/// Stable Application storage exposed to Account only through its endpoint
/// vtable. Exactly one Account login may own the adapter at a time.
pub const Adapter = struct {
    io: std.Io,
    server: ?Server = null,

    pub fn init(io: std.Io) Adapter {
        return .{ .io = io };
    }

    pub fn deinit(self: *Adapter) void {
        std.debug.assert(self.server == null);
        self.* = undefined;
    }

    pub fn endpoint(self: *Adapter) policy.Endpoint {
        return .{
            .context = self,
            .open_fn = open,
            .wait_fn = waitForCallback,
            .cancel_fn = cancel,
            .close_fn = close,
        };
    }

    fn open(context: *anyopaque) policy.ServerError!u16 {
        const self: *Adapter = @ptrCast(@alignCast(context));
        if (self.server != null) return error.BindFailed;
        self.server = try Server.init(self.io);
        return self.server.?.port();
    }

    fn waitForCallback(
        context: *anyopaque,
        sink: policy.RequestSink,
        deadline: std.Io.Clock.Timestamp,
    ) policy.ServerError!void {
        const self: *Adapter = @ptrCast(@alignCast(context));
        const server = if (self.server) |*value| value else return error.BindFailed;
        return server.wait(sink, deadline);
    }

    fn cancel(context: *anyopaque) void {
        const self: *Adapter = @ptrCast(@alignCast(context));
        if (self.server) |*server| server.cancel();
    }

    fn close(context: *anyopaque) void {
        const self: *Adapter = @ptrCast(@alignCast(context));
        if (self.server) |*server| server.deinit();
        self.server = null;
    }
};

fn respond(
    request: *std.http.Server.Request,
    response: policy.Response,
) !void {
    try request.respond(response.body, .{
        .status = switch (response.status) {
            .ok => .ok,
            .bad_request => .bad_request,
        },
        .keep_alive = false,
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = "text/plain; charset=utf-8" },
            .{ .name = "Cache-Control", .value = "no-store" },
            .{ .name = "Pragma", .value = "no-cache" },
            .{ .name = "X-Content-Type-Options", .value = "nosniff" },
        },
    });
}

const WaitContext = struct {
    server: *Server,
    sink: policy.RequestSink,
    deadline: std.Io.Clock.Timestamp,
    failure: ?policy.ServerError = null,

    fn run(self: *WaitContext) void {
        self.server.wait(self.sink, self.deadline) catch |err| {
            self.failure = err;
        };
    }
};

test "Application loopback pump and Account callback policy compose" {
    var server = try Server.init(std.testing.io);
    defer server.deinit();
    const expected_state = "0123456789012345678901234567890123456789012";
    var callback_policy = policy.CallbackPolicy.init(
        std.testing.allocator,
        expected_state,
        .{},
    );
    defer callback_policy.deinit();
    var context: WaitContext = .{
        .server = &server,
        .sink = callback_policy.sink(),
        .deadline = std.Io.Clock.Timestamp.fromNow(
            std.testing.io,
            .{ .raw = .fromSeconds(30), .clock = .boot },
        ),
    };
    const thread = try std.Thread.spawn(.{}, WaitContext.run, .{&context});

    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(server.port()) };
    var stream = try address.connect(std.testing.io, .{
        .mode = .stream,
        .protocol = .tcp,
    });
    defer stream.close(std.testing.io);
    var write_buffer: [2048]u8 = undefined;
    var writer = stream.writer(std.testing.io, &write_buffer);
    try writer.interface.print(
        "GET " ++ oauth.callback_path ++
            "?code=authorization-code&state={s} HTTP/1.1\r\n" ++
            "Host: 127.0.0.1:{d}\r\nConnection: close\r\n\r\n",
        .{ expected_state, server.port() },
    );
    try writer.interface.flush();
    thread.join();
    try std.testing.expectEqual(@as(?policy.ServerError, null), context.failure);
    var callback = callback_policy.take() orelse return error.TestUnexpectedResult;
    defer callback.deinit();
    try std.testing.expectEqualStrings("authorization-code", callback.code.view());
}

test "cancel closes the Application listener and wakes blocked accept" {
    var server = try Server.init(std.testing.io);
    defer server.deinit();
    var callback_policy = policy.CallbackPolicy.init(
        std.testing.allocator,
        "0123456789012345678901234567890123456789012",
        .{},
    );
    defer callback_policy.deinit();
    var context: WaitContext = .{
        .server = &server,
        .sink = callback_policy.sink(),
        .deadline = std.Io.Clock.Timestamp.fromNow(
            std.testing.io,
            .{ .raw = .fromSeconds(30), .clock = .boot },
        ),
    };
    const thread = try std.Thread.spawn(.{}, WaitContext.run, .{&context});
    server.cancel();
    thread.join();
    try std.testing.expectEqual(error.Cancelled, context.failure.?);
}

test "deadline closes the Application listener" {
    var server = try Server.init(std.testing.io);
    defer server.deinit();
    var callback_policy = policy.CallbackPolicy.init(
        std.testing.allocator,
        "0123456789012345678901234567890123456789012",
        .{},
    );
    defer callback_policy.deinit();
    try std.testing.expectError(
        error.DeadlineExceeded,
        server.wait(
            callback_policy.sink(),
            std.Io.Clock.Timestamp.fromNow(
                std.testing.io,
                .{ .raw = .zero, .clock = .boot },
            ),
        ),
    );
}

test "cancel interrupts an accepted partial callback request" {
    var server = try Server.init(std.testing.io);
    defer server.deinit();
    var callback_policy = policy.CallbackPolicy.init(
        std.testing.allocator,
        "0123456789012345678901234567890123456789012",
        .{},
    );
    defer callback_policy.deinit();
    var context: WaitContext = .{
        .server = &server,
        .sink = callback_policy.sink(),
        .deadline = std.Io.Clock.Timestamp.fromNow(
            std.testing.io,
            .{ .raw = .fromSeconds(30), .clock = .boot },
        ),
    };
    const thread = try std.Thread.spawn(.{}, WaitContext.run, .{&context});
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(server.port()) };
    var stream = try address.connect(std.testing.io, .{
        .mode = .stream,
        .protocol = .tcp,
    });
    defer stream.close(std.testing.io);
    var write_buffer: [128]u8 = undefined;
    var writer = stream.writer(std.testing.io, &write_buffer);
    try writer.interface.writeAll("GET /auth/callback HTTP/1.1\r\n");
    try writer.interface.flush();
    server.cancel();
    thread.join();
    try std.testing.expectEqual(error.Cancelled, context.failure.?);
}

test "deadline interrupts an accepted partial callback request" {
    var server = try Server.init(std.testing.io);
    defer server.deinit();
    var callback_policy = policy.CallbackPolicy.init(
        std.testing.allocator,
        "0123456789012345678901234567890123456789012",
        .{},
    );
    defer callback_policy.deinit();
    var context: WaitContext = .{
        .server = &server,
        .sink = callback_policy.sink(),
        .deadline = std.Io.Clock.Timestamp.fromNow(
            std.testing.io,
            .{ .raw = .fromMilliseconds(100), .clock = .boot },
        ),
    };
    const thread = try std.Thread.spawn(.{}, WaitContext.run, .{&context});
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(server.port()) };
    var stream = try address.connect(std.testing.io, .{
        .mode = .stream,
        .protocol = .tcp,
    });
    defer stream.close(std.testing.io);
    var write_buffer: [128]u8 = undefined;
    var writer = stream.writer(std.testing.io, &write_buffer);
    try writer.interface.writeAll("GET /auth/callback HTTP/1.1\r\n");
    try writer.interface.flush();
    thread.join();
    try std.testing.expectEqual(error.DeadlineExceeded, context.failure.?);
}
