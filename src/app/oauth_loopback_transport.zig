const std = @import("std");
const loopback = @import("oauth_loopback");
const select_start = @import("app_select_start");

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

    pub fn init(io: std.Io) loopback.ServerError!Server {
        return initOnPort(io, 0);
    }

    pub fn initOnPort(
        io: std.Io,
        bind_port: u16,
    ) loopback.ServerError!Server {
        const address: std.Io.net.IpAddress = .{
            .ip4 = .loopback(bind_port),
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
        sink: loopback.RequestSink,
        deadline: std.Io.Clock.Timestamp,
    ) loopback.ServerError!void {
        errdefer self.finish();
        while (true) {
            if (self.isStopRequested()) return error.Cancelled;
            var connection = try self.acceptUntil(deadline);
            defer connection.close(self.io);
            var read_buffer: [request_head_bytes]u8 = undefined;
            defer std.crypto.secureZero(u8, &read_buffer);
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
    ) loopback.ServerError!std.Io.net.Stream {
        var outcome_storage: [3]AcceptOutcome = undefined;
        var selection = std.Io.Select(AcceptOutcome).init(
            self.io,
            &outcome_storage,
        );
        select_start.startWithCleanup(&selection, .{
            .{ .accepted, acceptOne, .{self} },
            .{ .deadline, waitDeadline, .{ self.io, deadline } },
            .{ .cancelled, waitStop, .{self} },
        }, cancelAccept, .{ self.io, &selection }) catch return error.IoFailed;
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

    fn cancelAccept(io: std.Io, selection: *std.Io.Select(AcceptOutcome)) void {
        while (selection.cancel()) |remaining| closeAccepted(io, remaining);
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
    ) loopback.ServerError!std.http.Server.Request {
        var outcome_storage: [3]ReceiveOutcome = undefined;
        var selection = std.Io.Select(ReceiveOutcome).init(
            self.io,
            &outcome_storage,
        );
        select_start.start(&selection, .{
            .{ .received, receiveHead, .{http_server} },
            .{ .deadline, waitDeadline, .{ self.io, deadline } },
            .{ .cancelled, waitStop, .{self} },
        }) catch return error.IoFailed;
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

    pub fn endpoint(self: *Adapter) loopback.Endpoint {
        return .{
            .context = self,
            .open_fn = open,
            .wait_fn = waitForCallback,
            .cancel_fn = cancel,
            .close_fn = close,
        };
    }

    fn open(context: *anyopaque) loopback.ServerError!u16 {
        const self: *Adapter = @ptrCast(@alignCast(context));
        if (self.server != null) return error.BindFailed;
        self.server = try Server.init(self.io);
        return self.server.?.port();
    }

    fn waitForCallback(
        context: *anyopaque,
        sink: loopback.RequestSink,
        deadline: std.Io.Clock.Timestamp,
    ) loopback.ServerError!void {
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
    response: loopback.Response,
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
    sink: loopback.RequestSink,
    deadline: std.Io.Clock.Timestamp,
    failure: ?loopback.ServerError = null,

    fn run(self: *WaitContext) void {
        self.server.wait(self.sink, self.deadline) catch |err| {
            self.failure = err;
        };
    }
};

const TestPolicy = struct {
    completed: bool = false,
    invalid_count: usize = 0,

    fn sink(self: *TestPolicy) loopback.RequestSink {
        return .{
            .context = self,
            .invalid_fn = invalid,
            .handle_fn = handle,
        };
    }

    fn invalid(context: *anyopaque) loopback.ServerError!void {
        const self: *TestPolicy = @ptrCast(@alignCast(context));
        try self.recordInvalid();
    }

    fn recordInvalid(self: *TestPolicy) loopback.ServerError!void {
        self.invalid_count += 1;
        if (self.invalid_count >= 4) return error.TooManyInvalidRequests;
    }

    fn handle(
        context: *anyopaque,
        request: loopback.Request,
    ) loopback.ServerError!loopback.Response {
        const self: *TestPolicy = @ptrCast(@alignCast(context));
        if (request.method != .get or request.has_content_length or
            request.has_transfer_encoding or
            !std.mem.eql(u8, request.target, "/callback?accepted=1"))
        {
            try self.recordInvalid();
            return .{
                .status = .bad_request,
                .body = "invalid",
                .complete = false,
            };
        }
        self.completed = true;
        return .{ .status = .ok, .body = "complete", .complete = true };
    }
};

test "Application loopback pump composes with a caller-owned callback policy" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .async_limit = .nothing });
    defer threaded.deinit();
    var server = try Server.init(threaded.io());
    defer server.deinit();
    var callback_policy: TestPolicy = .{};
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
        "GET /callback?accepted=1 HTTP/1.1\r\n" ++
            "Host: 127.0.0.1:{d}\r\nConnection: close\r\n\r\n",
        .{server.port()},
    );
    try writer.interface.flush();
    thread.join();
    try std.testing.expectEqual(@as(?loopback.ServerError, null), context.failure);
    try std.testing.expect(callback_policy.completed);
}

test "Account loopback adapters bind distinct OS-assigned ports" {
    var first = Adapter.init(std.testing.io);
    defer first.deinit();
    const first_endpoint = first.endpoint();
    const first_port = try first_endpoint.open();
    defer first_endpoint.close();

    var second = Adapter.init(std.testing.io);
    defer second.deinit();
    const second_endpoint = second.endpoint();
    const second_port = try second_endpoint.open();
    defer second_endpoint.close();

    try std.testing.expect(first_port != 0);
    try std.testing.expect(second_port != 0);
    try std.testing.expect(first_port != second_port);
}

test "cancel closes the Application listener and wakes blocked accept" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .async_limit = .nothing });
    defer threaded.deinit();
    const Probe = struct {
        var entered: std.Io.Event = .unset;
        var io: std.Io = undefined;

        fn accept(userdata: ?*anyopaque, handle: std.Io.net.Socket.Handle, options: std.Io.net.Server.AcceptOptions) std.Io.net.Server.AcceptError!std.Io.net.Socket {
            entered.set(std.testing.io);
            return io.vtable.netAccept(userdata, handle, options);
        }
    };
    Probe.entered = .unset;
    Probe.io = threaded.io();
    var vtable = Probe.io.vtable.*;
    vtable.netAccept = Probe.accept;
    var server = try Server.init(.{ .userdata = Probe.io.userdata, .vtable = &vtable });
    defer server.deinit();
    var callback_policy: TestPolicy = .{};
    var context: WaitContext = .{
        .server = &server,
        .sink = callback_policy.sink(),
        .deadline = std.Io.Clock.Timestamp.fromNow(
            std.testing.io,
            .{ .raw = .fromSeconds(30), .clock = .boot },
        ),
    };
    const thread = try std.Thread.spawn(.{}, WaitContext.run, .{&context});
    try Probe.entered.wait(std.testing.io);
    server.cancel();
    thread.join();
    try std.testing.expectEqual(error.Cancelled, context.failure.?);
}

test "deadline closes the Application listener" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .async_limit = .nothing });
    defer threaded.deinit();
    var server = try Server.init(threaded.io());
    defer server.deinit();
    var callback_policy: TestPolicy = .{};
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
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .async_limit = .nothing });
    defer threaded.deinit();
    const Probe = struct {
        var entered: std.Io.Event = .unset;
        var io: std.Io = undefined;

        fn read(userdata: ?*anyopaque, handle: std.Io.net.Socket.Handle, buffers: [][]u8) std.Io.net.Stream.Reader.Error!usize {
            entered.set(std.testing.io);
            return io.vtable.netRead(userdata, handle, buffers);
        }
    };
    Probe.entered = .unset;
    Probe.io = threaded.io();
    var vtable = Probe.io.vtable.*;
    vtable.netRead = Probe.read;
    var server = try Server.init(.{ .userdata = Probe.io.userdata, .vtable = &vtable });
    defer server.deinit();
    var callback_policy: TestPolicy = .{};
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
    try Probe.entered.wait(std.testing.io);
    server.cancel();
    thread.join();
    try std.testing.expectEqual(error.Cancelled, context.failure.?);
}

test "deadline interrupts an accepted partial callback request" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .async_limit = .nothing });
    defer threaded.deinit();
    var server = try Server.init(threaded.io());
    defer server.deinit();
    var callback_policy: TestPolicy = .{};
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

test "loopback registration failures close listener and accepted streams" {
    const Probe = struct {
        var io: std.Io = undefined;
        var registered: usize = 0;
        var fail_at: usize = 0;
        var accepted: std.Io.Event = .unset;
        var closed: std.atomic.Value(usize) = .init(0);

        fn concurrent(userdata: ?*anyopaque, group: *std.Io.Group, context: []const u8, alignment: std.mem.Alignment, run: *const fn (*const anyopaque) void) std.Io.ConcurrentError!void {
            const index = registered;
            registered += 1;
            if (index == fail_at) {
                if (index == 1 or index == 2) accepted.waitUncancelable(std.testing.io);
                return error.ConcurrencyUnavailable;
            }
            return io.vtable.groupConcurrent(userdata, group, context, alignment, run);
        }

        fn accept(userdata: ?*anyopaque, handle: std.Io.net.Socket.Handle, options: std.Io.net.Server.AcceptOptions) std.Io.net.Server.AcceptError!std.Io.net.Socket {
            const socket = try io.vtable.netAccept(userdata, handle, options);
            accepted.set(std.testing.io);
            return socket;
        }

        fn close(userdata: ?*anyopaque, handles: []const std.Io.net.Socket.Handle) void {
            _ = closed.fetchAdd(handles.len, .monotonic);
            io.vtable.netClose(userdata, handles);
        }
    };
    for (0..6) |fail_at| {
        var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .async_limit = .nothing });
        defer threaded.deinit();
        Probe.io = threaded.io();
        Probe.registered = 0;
        Probe.fail_at = fail_at;
        Probe.accepted = .unset;
        Probe.closed.store(0, .monotonic);
        var vtable = Probe.io.vtable.*;
        vtable.groupConcurrent = Probe.concurrent;
        vtable.netAccept = Probe.accept;
        vtable.netClose = Probe.close;
        var server = try Server.init(.{ .userdata = Probe.io.userdata, .vtable = &vtable });
        defer server.deinit();
        const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(server.port()) };
        const client = try address.connect(std.testing.io, .{ .mode = .stream, .protocol = .tcp });
        defer client.close(std.testing.io);
        var policy: TestPolicy = .{};
        try std.testing.expectError(error.IoFailed, server.wait(policy.sink(), std.Io.Clock.Timestamp.fromNow(std.testing.io, .{ .raw = .fromSeconds(30), .clock = .boot })));
        try std.testing.expectEqual(fail_at + 1, Probe.registered);
        try std.testing.expectEqual(@as(usize, if (fail_at > 0) 2 else 1), Probe.closed.load(.monotonic));
        try std.testing.expect(!policy.completed);
    }
}
