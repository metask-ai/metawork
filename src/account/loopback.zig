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
    stop_requested: std.atomic.Value(u32) = .init(0),
    listener_closed: std.atomic.Value(bool) = .init(false),

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
        allocator: std.mem.Allocator,
        expected_state: []const u8,
        deadline: std.Io.Clock.Timestamp,
    ) ServerError!oauth.Callback {
        return self.waitValidated(
            allocator,
            expected_state,
            .{},
            deadline,
        );
    }

    /// Shares the same single-use loopback listener with MCP while allowing
    /// RFC 9207 issuer validation derived from validated AS metadata.
    pub fn waitValidated(
        self: *Server,
        allocator: std.mem.Allocator,
        expected_state: []const u8,
        validation: oauth.CallbackValidation,
        deadline: std.Io.Clock.Timestamp,
    ) ServerError!oauth.Callback {
        var invalid_count: usize = 0;
        while (invalid_count < Limits.invalid_requests) {
            if (self.isStopRequested()) return error.Cancelled;
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
            var request = self.receiveHeadUntil(
                &http_server,
                deadline,
            ) catch |err| switch (err) {
                error.RequestInvalid => {
                    invalid_count += 1;
                    continue;
                },
                else => return err,
            };
            if (request.head.method != .GET or
                request.head.content_length != null or
                request.head.transfer_encoding != .none)
            {
                respond(&request, .bad_request, "Invalid OAuth callback.") catch {};
                invalid_count += 1;
                continue;
            }
            var callback = (if (validation.expected_issuer == null and
                !validation.issuer_required)
                oauth.parseCallbackTarget(
                    allocator,
                    request.head.target,
                    expected_state,
                )
            else
                oauth.parseCallbackTargetValidated(
                    allocator,
                    request.head.target,
                    expected_state,
                    validation,
                )) catch {
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
            self.finish();
            return callback;
        }
        self.finish();
        return error.TooManyInvalidRequests;
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
    ) ServerError!std.Io.net.Stream {
        var outcome_storage: [3]AcceptOutcome = undefined;
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
        selection.async(
            .cancelled,
            waitStop,
            .{self},
        );
        const outcome = selection.await() catch {
            while (selection.cancel()) |remaining| {
                switch (remaining) {
                    .accepted => |accepted| switch (accepted) {
                        .stream => |stream| stream.close(self.io),
                        .cancelled, .failed => {},
                    },
                    .deadline, .cancelled => {},
                }
            }
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
                    switch (accepted) {
                        .stream => |stream| stream.close(self.io),
                        .cancelled, .failed => {},
                    }
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
                while (selection.cancel()) |remaining| {
                    switch (remaining) {
                        .accepted => |accepted| switch (accepted) {
                            .stream => |stream| stream.close(self.io),
                            .cancelled, .failed => {},
                        },
                        .deadline, .cancelled => {},
                    }
                }
                self.finish();
                return error.DeadlineExceeded;
            },
            .cancelled => {
                while (selection.cancel()) |remaining| {
                    switch (remaining) {
                        .accepted => |accepted| switch (accepted) {
                            .stream => |stream| stream.close(self.io),
                            .cancelled, .failed => {},
                        },
                        .deadline, .cancelled => {},
                    }
                }
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

    fn waitDeadline(
        io: std.Io,
        deadline: std.Io.Clock.Timestamp,
    ) void {
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
    ) ServerError!std.http.Server.Request {
        var outcome_storage: [3]ReceiveOutcome = undefined;
        var selection = std.Io.Select(ReceiveOutcome).init(
            self.io,
            &outcome_storage,
        );
        selection.async(
            .received,
            receiveHead,
            .{http_server},
        );
        selection.async(
            .deadline,
            waitDeadline,
            .{ self.io, deadline },
        );
        selection.async(
            .cancelled,
            waitStop,
            .{self},
        );
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

const ReceiveContext = struct {
    server: *Server,
    connection: std.Io.net.Stream,
    deadline: std.Io.Clock.Timestamp,
    started: std.atomic.Value(u32) = .init(0),
    failure: ?ServerError = null,
    unexpected_success: bool = false,

    fn run(self: *ReceiveContext) void {
        defer self.connection.close(self.server.io);
        var read_buffer: [Limits.request_head_bytes]u8 = undefined;
        var write_buffer: [Limits.response_bytes]u8 = undefined;
        var reader = self.connection.reader(self.server.io, &read_buffer);
        var writer = self.connection.writer(self.server.io, &write_buffer);
        var http_server: std.http.Server = .init(
            &reader.interface,
            &writer.interface,
        );
        self.started.store(1, .release);
        self.server.io.futexWake(
            u32,
            &self.started.raw,
            std.math.maxInt(u32),
        );
        _ = self.server.receiveHeadUntil(
            &http_server,
            self.deadline,
        ) catch |err| {
            self.failure = err;
            return;
        };
        self.unexpected_success = true;
    }

    fn waitStarted(self: *ReceiveContext) void {
        while (self.started.load(.acquire) == 0) {
            self.server.io.futexWait(
                u32,
                &self.started.raw,
                0,
            ) catch {};
        }
    }
};

test "loopback listener binds dynamic IPv4 and accepts one exact callback" {
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

test "cancel interrupts receiveHeadUntil on an accepted partial request" {
    var server = try Server.init(std.testing.io);
    defer server.deinit();
    const address: std.Io.net.IpAddress = .{
        .ip4 = .loopback(server.port()),
    };
    var stream = try address.connect(std.testing.io, .{
        .mode = .stream,
        .protocol = .tcp,
    });
    defer stream.close(std.testing.io);
    var write_buffer: [128]u8 = undefined;
    var writer = stream.writer(std.testing.io, &write_buffer);
    try writer.interface.writeAll("GET /auth/callback HTTP/1.1\r\n");
    try writer.interface.flush();

    var context: ReceiveContext = .{
        .server = &server,
        .connection = try server.listener.accept(std.testing.io),
        .deadline = std.Io.Clock.Timestamp.fromNow(
            std.testing.io,
            .{ .raw = .fromSeconds(30), .clock = .boot },
        ),
    };
    const thread = try std.Thread.spawn(.{}, ReceiveContext.run, .{&context});
    context.waitStarted();
    server.cancel();
    thread.join();
    try std.testing.expect(!context.unexpected_success);
    try std.testing.expectEqual(error.Cancelled, context.failure.?);
}

test "deadline interrupts receiveHeadUntil on an accepted partial request" {
    var server = try Server.init(std.testing.io);
    defer server.deinit();
    const address: std.Io.net.IpAddress = .{
        .ip4 = .loopback(server.port()),
    };
    var stream = try address.connect(std.testing.io, .{
        .mode = .stream,
        .protocol = .tcp,
    });
    defer stream.close(std.testing.io);
    var write_buffer: [128]u8 = undefined;
    var writer = stream.writer(std.testing.io, &write_buffer);
    try writer.interface.writeAll("GET /auth/callback HTTP/1.1\r\n");
    try writer.interface.flush();

    var context: ReceiveContext = .{
        .server = &server,
        .connection = try server.listener.accept(std.testing.io),
        .deadline = std.Io.Clock.Timestamp.fromNow(
            std.testing.io,
            .{ .raw = .fromMilliseconds(100), .clock = .boot },
        ),
    };
    const thread = try std.Thread.spawn(.{}, ReceiveContext.run, .{&context});
    context.waitStarted();
    thread.join();
    try std.testing.expect(!context.unexpected_success);
    try std.testing.expectEqual(error.DeadlineExceeded, context.failure.?);
}
