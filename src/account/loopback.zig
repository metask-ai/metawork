const std = @import("std");
const oauth = @import("account_oauth");

pub const Limits = struct {
    pub const request_head_bytes: usize = 16 * 1024;
    pub const response_bytes: usize = 4096;
    pub const invalid_requests: usize = 4;
};

pub const ServerError = error{
    BindFailed,
    PortUnavailable,
    Cancelled,
    DeadlineExceeded,
    RequestInvalid,
    TooManyInvalidRequests,
    IoFailed,
};

/// One OAuth attempt owns one loopback listener. `cancel` may be called from
/// another thread; the owner must join the thread running `wait` before
/// destroying this value.
pub const Server = struct {
    io: std.Io,
    listener: std.Io.net.Server,
    port_value: u16,
    closed: std.atomic.Value(bool) = .init(false),

    pub fn init(io: std.Io) ServerError!Server {
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
        const assigned_port = assignedPort(listener.socket.handle) orelse
            return error.PortUnavailable;
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
        allocator: std.mem.Allocator,
        expected_state: []const u8,
        deadline: std.Io.Clock.Timestamp,
    ) ServerError!oauth.Callback {
        var invalid_count: usize = 0;
        while (invalid_count < Limits.invalid_requests) {
            if (self.closed.load(.acquire)) return error.Cancelled;
            const stream = try self.acceptUntil(deadline);
            var connection = stream;
            defer connection.close(self.io);
            var read_buffer: [Limits.request_head_bytes]u8 = undefined;
            var write_buffer: [Limits.response_bytes]u8 = undefined;
            var reader = connection.reader(self.io, &read_buffer);
            var writer = connection.writer(self.io, &write_buffer);
            var http_server: std.http.Server = .init(
                &reader.interface,
                &writer.interface,
            );
            var request = http_server.receiveHead() catch {
                invalid_count += 1;
                continue;
            };
            if (request.head.method != .GET or
                request.head.content_length != null or
                request.head.transfer_encoding != .none)
            {
                respond(&request, .bad_request, "Invalid OAuth callback.") catch {};
                invalid_count += 1;
                continue;
            }
            var callback = oauth.parseCallbackTarget(
                allocator,
                request.head.target,
                expected_state,
            ) catch {
                respond(&request, .bad_request, "Invalid OAuth callback.") catch {};
                invalid_count += 1;
                continue;
            };
            switch (callback) {
                .code => respond(
                    &request,
                    .ok,
                    "Authentication complete. You may close this window and return to MetaWork.",
                ) catch {
                    callback.deinit();
                    return error.IoFailed;
                },
                .rejected => respond(
                    &request,
                    .bad_request,
                    "Authentication was not completed. You may close this window and return to MetaWork.",
                ) catch {
                    callback.deinit();
                    return error.IoFailed;
                },
            }
            self.closeListener();
            return callback;
        }
        self.closeListener();
        return error.TooManyInvalidRequests;
    }

    pub fn cancel(self: *Server) void {
        self.closeListener();
    }

    pub fn deinit(self: *Server) void {
        self.closeListener();
        self.* = undefined;
    }

    fn closeListener(self: *Server) void {
        if (!self.closed.swap(true, .acq_rel))
            self.listener.socket.close(self.io);
    }

    const AcceptResult = union(enum) {
        stream: std.Io.net.Stream,
        cancelled,
        failed,
    };

    const AcceptOutcome = union(enum) {
        accepted: AcceptResult,
        deadline,
    };

    fn acceptUntil(
        self: *Server,
        deadline: std.Io.Clock.Timestamp,
    ) ServerError!std.Io.net.Stream {
        var outcome_storage: [2]AcceptOutcome = undefined;
        var selection = std.Io.Select(AcceptOutcome).init(
            self.io,
            &outcome_storage,
        );
        selection.async(.accepted, acceptOne, .{self});
        selection.async(
            .deadline,
            waitDeadline,
            .{ self.io, deadline },
        );
        const outcome = selection.await() catch {
            selection.cancelDiscard();
            return error.IoFailed;
        };
        return switch (outcome) {
            .accepted => |accepted| blk: {
                selection.cancelDiscard();
                break :blk switch (accepted) {
                    .stream => |stream| stream,
                    .cancelled => error.Cancelled,
                    .failed => error.IoFailed,
                };
            },
            .deadline => {
                while (selection.cancel()) |remaining| {
                    switch (remaining) {
                        .accepted => |accepted| switch (accepted) {
                            .stream => |stream| stream.close(self.io),
                            .cancelled, .failed => {},
                        },
                        .deadline => {},
                    }
                }
                self.closeListener();
                return error.DeadlineExceeded;
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

    fn waitDeadline(
        io: std.Io,
        deadline: std.Io.Clock.Timestamp,
    ) void {
        deadline.wait(io) catch {};
    }
};

fn respond(
    request: *std.http.Server.Request,
    status: std.http.Status,
    body: []const u8,
) !void {
    try request.respond(body, .{
        .status = status,
        .keep_alive = false,
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = "text/plain; charset=utf-8" },
            .{ .name = "Cache-Control", .value = "no-store" },
            .{ .name = "Pragma", .value = "no-cache" },
            .{ .name = "X-Content-Type-Options", .value = "nosniff" },
        },
    });
}

fn assignedPort(socket: std.Io.net.Socket.Handle) ?u16 {
    var address: std.posix.sockaddr.in = undefined;
    var length: std.c.socklen_t = @sizeOf(@TypeOf(address));
    if (std.c.getsockname(
        socket,
        @ptrCast(&address),
        &length,
    ) != 0) return null;
    if (length < @sizeOf(@TypeOf(address))) return null;
    return std.mem.bigToNative(u16, address.port);
}

const WaitContext = struct {
    server: *Server,
    allocator: std.mem.Allocator,
    state: []const u8,
    deadline: std.Io.Clock.Timestamp,
    callback: ?oauth.Callback = null,
    failure: ?ServerError = null,

    fn run(self: *WaitContext) void {
        self.callback = self.server.wait(
            self.allocator,
            self.state,
            self.deadline,
        ) catch |err| {
            self.failure = err;
            return;
        };
    }
};

test "loopback listener binds dynamic IPv4 and accepts one exact callback" {
    var server = try Server.init(std.testing.io);
    defer if (!server.closed.load(.acquire)) server.deinit();
    const expected_state = "0123456789012345678901234567890123456789012";
    var context: WaitContext = .{
        .server = &server,
        .allocator = std.testing.allocator,
        .state = expected_state,
        .deadline = std.Io.Clock.Timestamp.fromNow(
            std.testing.io,
            .{ .raw = .fromSeconds(30), .clock = .boot },
        ),
    };
    const thread = try std.Thread.spawn(.{}, WaitContext.run, .{&context});

    const address: std.Io.net.IpAddress = .{
        .ip4 = .loopback(server.port()),
    };
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
            "Host: 127.0.0.1:{d}\r\n" ++
            "Connection: close\r\n\r\n",
        .{ expected_state, server.port() },
    );
    try writer.interface.flush();
    thread.join();
    try std.testing.expectEqual(@as(?ServerError, null), context.failure);
    var callback = context.callback orelse return error.TestUnexpectedResult;
    defer callback.deinit();
    try std.testing.expectEqualStrings(
        "authorization-code",
        callback.code.view(),
    );
}

test "cancel closes the listener and wakes a blocked accept" {
    var server = try Server.init(std.testing.io);
    defer server.deinit();
    const expected_state = "0123456789012345678901234567890123456789012";
    var context: WaitContext = .{
        .server = &server,
        .allocator = std.testing.allocator,
        .state = expected_state,
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

test "attempt deadline closes the listener and wakes a blocked accept" {
    var server = try Server.init(std.testing.io);
    defer server.deinit();
    const expected_state = "0123456789012345678901234567890123456789012";
    try std.testing.expectError(
        error.DeadlineExceeded,
        server.wait(
            std.testing.allocator,
            expected_state,
            std.Io.Clock.Timestamp.fromNow(
                std.testing.io,
                .{ .raw = .zero, .clock = .boot },
            ),
        ),
    );
}
