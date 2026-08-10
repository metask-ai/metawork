const std = @import("std");
const contract = @import("metawork_account_contract");
const state = @import("account_state");
const oauth = @import("account_oauth");
const loopback = @import("account_loopback");
const metask = @import("metask_client");

pub const WorkerResult = union(enum) {
    authorized: oauth.TokenSet,
    failed: state.WorkerFailure,
    consumed,

    pub fn take(self: *WorkerResult) WorkerResult {
        const result: WorkerResult = switch (self.*) {
            .authorized => |*tokens| .{
                .authorized = tokens.take(),
            },
            .failed => |failure| .{ .failed = failure },
            .consumed => .consumed,
        };
        self.* = .consumed;
        return result;
    }

    pub fn deinit(self: *WorkerResult) void {
        switch (self.*) {
            .authorized => |*tokens| tokens.deinit(),
            .failed, .consumed => {},
        }
        self.* = .consumed;
    }
};

pub const ResultSink = struct {
    context: *anyopaque,
    publish_fn: *const fn (
        context: *anyopaque,
        attempt_id: u64,
        result: *WorkerResult,
    ) bool,

    /// The callback must call `WorkerResult.take` before returning `true`.
    /// This method consumes `result` on every path.
    pub fn publish(
        self: ResultSink,
        attempt_id: u64,
        result: *WorkerResult,
    ) void {
        if (!self.publish_fn(self.context, attempt_id, result)) {
            result.deinit();
            return;
        }
        std.debug.assert(result.* == .consumed);
    }
};

pub const StartError = error{
    AlreadyStarted,
    InvalidAttempt,
    RandomFailed,
    BindFailed,
    ThreadSpawnFailed,
    AuthorizationUrlFailed,
};

pub const LoginAttempt = struct {
    const attempt_timeout: std.Io.Clock.Duration = .{
        .raw = .fromSeconds(5 * 60),
        .clock = .boot,
    };

    allocator: std.mem.Allocator = undefined,
    io: std.Io = undefined,
    attempt_id: u64 = 0,
    now_unix_seconds: i64 = 0,
    transport: metask.Transport = undefined,
    sink: ResultSink = undefined,
    cancellation: metask.Cancellation = undefined,
    deadline: std.Io.Clock.Timestamp = undefined,
    server: loopback.Server = undefined,
    material: oauth.AttemptMaterial = undefined,
    authorization_url_storage: [oauth.Limits.authorization_url_bytes]u8 =
        undefined,
    authorization_url_len: usize = 0,
    thread: ?std.Thread = null,
    started: bool = false,
    joined: bool = false,

    /// Initializes and starts a single bounded login worker in caller-owned,
    /// stable memory. The caller opens `authorizationUrl()` on the main thread,
    /// then must call `cancel`+`join` before `deinit`.
    pub fn start(
        self: *LoginAttempt,
        allocator: std.mem.Allocator,
        io: std.Io,
        attempt_id: u64,
        transport: metask.Transport,
        sink: ResultSink,
        now_unix_seconds: i64,
    ) StartError!void {
        if (self.started) return error.AlreadyStarted;
        if (attempt_id == 0 or now_unix_seconds < 0)
            return error.InvalidAttempt;
        self.* = .{
            .allocator = allocator,
            .io = io,
            .attempt_id = attempt_id,
            .now_unix_seconds = now_unix_seconds,
            .transport = transport,
            .sink = sink,
            .cancellation = .init(io),
            .deadline = std.Io.Clock.Timestamp.fromNow(
                io,
                attempt_timeout,
            ),
        };
        errdefer std.crypto.secureZero(
            u8,
            &self.authorization_url_storage,
        );
        oauth.AttemptMaterial.generate(
            io,
            &self.material,
        ) catch return error.RandomFailed;
        errdefer self.material.deinit();
        self.server = loopback.Server.init(io) catch
            return error.BindFailed;
        errdefer self.server.deinit();
        const url = oauth.buildAuthorizeUrl(
            &self.authorization_url_storage,
            self.server.port(),
            &self.material,
        ) catch return error.AuthorizationUrlFailed;
        self.authorization_url_len = url.len;
        self.started = true;
        errdefer self.started = false;
        self.thread = std.Thread.spawn(.{}, workerMain, .{self}) catch
            return error.ThreadSpawnFailed;
    }

    pub fn authorizationUrl(self: *const LoginAttempt) []const u8 {
        std.debug.assert(self.started and !self.joined);
        return self.authorization_url_storage[0..self.authorization_url_len];
    }

    pub fn matches(self: *const LoginAttempt, attempt_id: u64) bool {
        return self.started and !self.joined and
            self.attempt_id == attempt_id;
    }

    pub fn callbackPort(self: *const LoginAttempt) u16 {
        std.debug.assert(self.started);
        return self.server.port();
    }

    pub fn cancel(self: *LoginAttempt) void {
        if (!self.started or self.joined) return;
        self.cancellation.cancel();
        self.server.cancel();
    }

    pub fn join(self: *LoginAttempt) void {
        if (!self.started or self.joined) return;
        const thread = self.thread orelse @panic("started login has no thread");
        thread.join();
        self.thread = null;
        self.joined = true;
    }

    pub fn deinit(self: *LoginAttempt) void {
        if (!self.started) {
            self.* = .{};
            return;
        }
        std.debug.assert(self.joined);
        self.server.deinit();
        self.material.deinit();
        std.crypto.secureZero(u8, &self.authorization_url_storage);
        self.* = .{};
    }

    fn workerMain(self: *LoginAttempt) void {
        var callback = self.server.wait(
            self.allocator,
            &self.material.state,
            self.deadline,
        ) catch |err| {
            var failure: WorkerResult = .{
                .failed = .fromCode(loopbackFailure(err)),
            };
            self.sink.publish(
                self.attempt_id,
                &failure,
            );
            return;
        };
        defer callback.deinit();
        switch (callback) {
            .rejected => {
                var failure: WorkerResult = .{
                    .failed = .fromCode(.user_cancelled),
                };
                self.sink.publish(self.attempt_id, &failure);
            },
            .code => |*code| {
                var tokens = metask.exchangeAuthorizationCode(
                    self.allocator,
                    self.transport,
                    code,
                    &self.material.verifier,
                    self.server.port(),
                    self.now_unix_seconds,
                    .{
                        .cancellation = &self.cancellation,
                        .deadline = self.deadline,
                    },
                ) catch |err| {
                    var failure: WorkerResult = .{
                        .failed = metask.workerFailure(err),
                    };
                    self.sink.publish(
                        self.attempt_id,
                        &failure,
                    );
                    return;
                };
                defer tokens.deinit();
                var worker_result: WorkerResult = .{
                    .authorized = tokens.take(),
                };
                self.sink.publish(
                    self.attempt_id,
                    &worker_result,
                );
            },
        }
    }
};

fn loopbackFailure(failure: loopback.ServerError) contract.ErrorCode {
    return switch (failure) {
        error.BindFailed, error.PortUnavailable => .oauth_bind_failed,
        error.Cancelled => .user_cancelled,
        error.DeadlineExceeded => .deadline_exceeded,
        error.TooManyInvalidRequests,
        error.RequestInvalid,
        error.IoFailed,
        => .oauth_callback_rejected,
    };
}

const CaptureSink = struct {
    attempt_id: u64 = 0,
    result: ?WorkerResult = null,

    fn sink(self: *CaptureSink) ResultSink {
        return .{ .context = self, .publish_fn = publish };
    }

    fn publish(
        context: *anyopaque,
        attempt_id: u64,
        result: *WorkerResult,
    ) bool {
        const self: *CaptureSink = @ptrCast(@alignCast(context));
        if (self.result != null) return false;
        self.attempt_id = attempt_id;
        self.result = result.take();
        return true;
    }
};

const FakeTransport = struct {
    step: usize = 0,

    fn transport(self: *FakeTransport) metask.Transport {
        return .{ .context = self, .perform_fn = perform };
    }

    fn perform(
        context: *anyopaque,
        request: metask.Request,
        output: []u8,
    ) metask.TransportError!metask.Response {
        const self: *FakeTransport = @ptrCast(@alignCast(context));
        const body = switch (self.step) {
            0 => blk: {
                if (request.kind != .exchange_code)
                    return error.ProtocolFailed;
                break :blk
                \\{"access_token":"access","refresh_token":"refresh","token_type":"Bearer","expires_in":3600,"scope":"metawork:use","account_id":"acct-1"}
                ;
            },
            1 => blk: {
                if (request.kind != .current_user)
                    return error.ProtocolFailed;
                break :blk
                \\{"code":0,"message":"success","data":{"id":1,"username":"Metask User"}}
                ;
            },
            else => return error.ProtocolFailed,
        };
        @memcpy(output[0..body.len], body);
        self.step += 1;
        return .{ .status = 200, .body = output[0..body.len] };
    }
};

const BlockingTransport = struct {
    started: std.atomic.Value(u32) = .init(0),

    fn transport(self: *BlockingTransport) metask.Transport {
        return .{ .context = self, .perform_fn = perform };
    }

    fn perform(
        context: *anyopaque,
        request: metask.Request,
        _: []u8,
    ) metask.TransportError!metask.Response {
        const self: *BlockingTransport = @ptrCast(@alignCast(context));
        if (request.kind != .exchange_code)
            return error.ProtocolFailed;
        const control = request.control orelse
            return error.ProtocolFailed;
        self.started.store(1, .release);
        control.cancellation.io.futexWake(
            u32,
            &self.started.raw,
            std.math.maxInt(u32),
        );
        control.cancellation.wait();
        return error.Cancelled;
    }

    fn waitUntilStarted(self: *BlockingTransport, io: std.Io) void {
        while (self.started.load(.acquire) == 0) {
            io.futexWait(u32, &self.started.raw, 0) catch return;
        }
    }
};

test "login attempt publishes exchanged tokens before identity lookup" {
    var fake_transport: FakeTransport = .{};
    var capture: CaptureSink = .{};
    var attempt: LoginAttempt = .{};
    try attempt.start(
        std.testing.allocator,
        std.testing.io,
        7,
        fake_transport.transport(),
        capture.sink(),
        100,
    );
    defer attempt.deinit();
    try std.testing.expect(std.mem.startsWith(
        u8,
        attempt.authorizationUrl(),
        oauth.authorize_url,
    ));
    const address: std.Io.net.IpAddress = .{
        .ip4 = .loopback(attempt.callbackPort()),
    };
    var stream = try address.connect(std.testing.io, .{
        .mode = .stream,
        .protocol = .tcp,
    });
    defer stream.close(std.testing.io);
    var buffer: [2048]u8 = undefined;
    var writer = stream.writer(std.testing.io, &buffer);
    try writer.interface.print(
        "GET " ++ oauth.callback_path ++
            "?code=code&state={s} HTTP/1.1\r\n" ++
            "Host: 127.0.0.1:{d}\r\nConnection: close\r\n\r\n",
        .{ attempt.material.state, attempt.callbackPort() },
    );
    try writer.interface.flush();
    attempt.join();
    try std.testing.expectEqual(@as(u64, 7), capture.attempt_id);
    var result = capture.result orelse return error.TestUnexpectedResult;
    defer result.deinit();
    try std.testing.expectEqualStrings(
        "acct-1",
        result.authorized.accountId(),
    );
    try std.testing.expectEqual(@as(usize, 1), fake_transport.step);
}

test "cancel plus join publishes one typed cancellation" {
    var fake_transport: FakeTransport = .{};
    var capture: CaptureSink = .{};
    var attempt: LoginAttempt = .{};
    try attempt.start(
        std.testing.allocator,
        std.testing.io,
        8,
        fake_transport.transport(),
        capture.sink(),
        100,
    );
    attempt.cancel();
    attempt.join();
    defer attempt.deinit();
    try std.testing.expectEqual(
        contract.ErrorCode.user_cancelled,
        capture.result.?.failed.error_code,
    );
}

test "cancel interrupts token exchange and join does not wait for network" {
    var blocking_transport: BlockingTransport = .{};
    var capture: CaptureSink = .{};
    var attempt: LoginAttempt = .{};
    try attempt.start(
        std.testing.allocator,
        std.testing.io,
        9,
        blocking_transport.transport(),
        capture.sink(),
        100,
    );
    defer attempt.deinit();
    const address: std.Io.net.IpAddress = .{
        .ip4 = .loopback(attempt.callbackPort()),
    };
    var stream = try address.connect(std.testing.io, .{
        .mode = .stream,
        .protocol = .tcp,
    });
    defer stream.close(std.testing.io);
    var buffer: [2048]u8 = undefined;
    var writer = stream.writer(std.testing.io, &buffer);
    try writer.interface.print(
        "GET " ++ oauth.callback_path ++
            "?code=code&state={s} HTTP/1.1\r\n" ++
            "Host: 127.0.0.1:{d}\r\nConnection: close\r\n\r\n",
        .{ attempt.material.state, attempt.callbackPort() },
    );
    try writer.interface.flush();
    blocking_transport.waitUntilStarted(std.testing.io);
    attempt.cancel();
    attempt.join();
    try std.testing.expectEqual(
        contract.ErrorCode.user_cancelled,
        capture.result.?.failed.error_code,
    );
}
