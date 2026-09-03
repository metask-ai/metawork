//! Product Account login-attempt lifecycle.
const std = @import("std");
const contract = @import("metawork_account_contract");
const state = @import("account_state");
const oauth = @import("account_oauth");
const loopback = @import("account_loopback");
const metask = @import("metask_client");

pub const WorkerResult = union(enum) {
    exchange: CallbackExchangeInput,
    failed: state.WorkerFailure,
    consumed,

    pub fn take(self: *WorkerResult) WorkerResult {
        const result: WorkerResult = switch (self.*) {
            .exchange => |*input| .{
                .exchange = input.take(),
            },
            .failed => |failure| .{ .failed = failure },
            .consumed => .consumed,
        };
        self.* = .consumed;
        return result;
    }

    pub fn deinit(self: *WorkerResult) void {
        switch (self.*) {
            .exchange => |*input| input.deinit(),
            .failed, .consumed => {},
        }
        self.* = .consumed;
    }
};

pub const CallbackExchangeInput = struct {
    code: oauth.Secret = .{},
    verifier: [oauth.Limits.verifier_bytes]u8 = undefined,
    callback_port: u16 = 0,
    attempt_deadline: std.Io.Clock.Timestamp = undefined,
    owned: bool = false,

    fn init(
        code: *oauth.Secret,
        verifier: *const [oauth.Limits.verifier_bytes]u8,
        callback_port: u16,
        attempt_deadline: std.Io.Clock.Timestamp,
    ) CallbackExchangeInput {
        return .{
            .code = code.take(),
            .verifier = verifier.*,
            .callback_port = callback_port,
            .attempt_deadline = attempt_deadline,
            .owned = true,
        };
    }

    pub fn take(self: *CallbackExchangeInput) CallbackExchangeInput {
        std.debug.assert(self.owned);
        const result = self.*;
        self.code = .{};
        std.crypto.secureZero(u8, &self.verifier);
        self.callback_port = 0;
        self.owned = false;
        return result;
    }

    pub fn deinit(self: *CallbackExchangeInput) void {
        if (!self.owned) return;
        self.code.deinit();
        std.crypto.secureZero(u8, &self.verifier);
        self.callback_port = 0;
        self.owned = false;
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
    sink: ResultSink = undefined,
    cancellation: metask.Cancellation = undefined,
    deadline: std.Io.Clock.Timestamp = undefined,
    loopback_endpoint: loopback.Endpoint = undefined,
    callback_port: u16 = 0,
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
        loopback_endpoint: loopback.Endpoint,
        attempt_id: u64,
        sink: ResultSink,
    ) StartError!void {
        if (self.started) return error.AlreadyStarted;
        if (attempt_id == 0) return error.InvalidAttempt;
        self.* = .{
            .allocator = allocator,
            .io = io,
            .loopback_endpoint = loopback_endpoint,
            .attempt_id = attempt_id,
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
        self.callback_port = self.loopback_endpoint.open() catch
            return error.BindFailed;
        errdefer self.loopback_endpoint.close();
        const url = oauth.buildAuthorizeUrl(
            &self.authorization_url_storage,
            self.callback_port,
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

    pub fn cancel(self: *LoginAttempt) void {
        if (!self.started or self.joined) return;
        self.cancellation.cancel();
        self.loopback_endpoint.cancel();
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
        self.loopback_endpoint.close();
        self.material.deinit();
        std.crypto.secureZero(u8, &self.authorization_url_storage);
        self.* = .{};
    }

    fn workerMain(self: *LoginAttempt) void {
        var callback_policy = loopback.CallbackPolicy.init(
            self.allocator,
            &self.material.state,
            .{},
        );
        defer callback_policy.deinit();
        self.loopback_endpoint.wait(
            callback_policy.sink(),
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
        var callback = callback_policy.take() orelse {
            var failure: WorkerResult = .{
                .failed = .fromCode(.oauth_callback_rejected),
            };
            self.sink.publish(self.attempt_id, &failure);
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
                var exchange = CallbackExchangeInput.init(
                    code,
                    &self.material.verifier,
                    self.callback_port,
                    self.deadline,
                );
                defer exchange.deinit();
                var worker_result: WorkerResult = .{
                    .exchange = exchange.take(),
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

pub const TestSupport = if (@import("builtin").is_test) struct {
    pub fn exchangeInput(
        allocator: std.mem.Allocator,
        io: std.Io,
        code_value: []const u8,
        remaining: std.Io.Clock.Duration,
    ) !CallbackExchangeInput {
        var code = try oauth.Secret.init(allocator, code_value);
        errdefer code.deinit();
        var material = oauth.AttemptMaterial.fromSeeds(
            [_]u8{1} ** 32,
            [_]u8{2} ** 32,
        );
        defer material.deinit();
        return CallbackExchangeInput.init(
            &code,
            &material.verifier,
            49152,
            std.Io.Clock.Timestamp.fromNow(io, remaining),
        );
    }
} else struct {};

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

const FakeLoopback = struct {
    io: std.Io,
    state: std.atomic.Value(u32) = .init(0),
    target: [oauth.Limits.callback_target_bytes]u8 = undefined,
    target_len: usize = 0,

    fn endpoint(self: *FakeLoopback) loopback.Endpoint {
        return .{
            .context = self,
            .open_fn = open,
            .wait_fn = wait,
            .cancel_fn = cancel,
            .close_fn = close,
        };
    }

    fn provideCode(self: *FakeLoopback, expected_state: []const u8) !void {
        var writer = std.Io.Writer.fixed(&self.target);
        try writer.print(
            oauth.callback_path ++ "?code=code&state={s}",
            .{expected_state},
        );
        self.target_len = writer.buffered().len;
        self.state.store(1, .release);
        self.io.futexWake(u32, &self.state.raw, std.math.maxInt(u32));
    }

    fn open(_: *anyopaque) loopback.ServerError!u16 {
        return 49152;
    }

    fn wait(
        context: *anyopaque,
        sink: loopback.RequestSink,
        _: std.Io.Clock.Timestamp,
    ) loopback.ServerError!void {
        const self: *FakeLoopback = @ptrCast(@alignCast(context));
        while (self.state.load(.acquire) == 0) {
            self.io.futexWait(u32, &self.state.raw, 0) catch {};
        }
        if (self.state.load(.acquire) == 2) return error.Cancelled;
        const response = try sink.handle(.{
            .method = .get,
            .target = self.target[0..self.target_len],
            .has_content_length = false,
            .has_transfer_encoding = false,
        });
        if (!response.complete) return error.RequestInvalid;
    }

    fn cancel(context: *anyopaque) void {
        const self: *FakeLoopback = @ptrCast(@alignCast(context));
        self.state.store(2, .release);
        self.io.futexWake(u32, &self.state.raw, std.math.maxInt(u32));
    }

    fn close(_: *anyopaque) void {}
};

test "rejected login result publication releases stale token ownership" {
    var backing: [1024]u8 = undefined;
    @memset(&backing, 0xaa);
    var fixed = std.heap.FixedBufferAllocator.init(&backing);
    var code = try oauth.Secret.init(fixed.allocator(), "stale-code");
    var material = oauth.AttemptMaterial.fromSeeds(
        [_]u8{1} ** 32,
        [_]u8{2} ** 32,
    );
    defer material.deinit();
    var input = CallbackExchangeInput.init(
        &code,
        &material.verifier,
        49152,
        std.Io.Clock.Timestamp.fromNow(std.testing.io, LoginAttempt.attempt_timeout),
    );
    var result: WorkerResult = .{ .exchange = input.take() };
    const code_storage = result.exchange.code.bytes;
    const verifier_storage = &result.exchange.verifier;
    const RejectingSink = struct {
        fn publish(_: *anyopaque, _: u64, _: *WorkerResult) bool {
            return false;
        }
    };
    var context: u8 = 0;
    const sink: ResultSink = .{
        .context = &context,
        .publish_fn = RejectingSink.publish,
    };

    sink.publish(9, &result);

    try std.testing.expect(result == .consumed);
    try std.testing.expect(!std.mem.eql(u8, code_storage, "stale-code"));
    try std.testing.expect(std.mem.allEqual(u8, verifier_storage, 0));
}

test "login attempt publishes owned callback exchange input" {
    var fake_loopback: FakeLoopback = .{ .io = std.testing.io };
    var capture: CaptureSink = .{};
    var attempt: LoginAttempt = .{};
    try attempt.start(
        std.testing.allocator,
        std.testing.io,
        fake_loopback.endpoint(),
        7,
        capture.sink(),
    );
    defer attempt.deinit();
    try std.testing.expect(std.mem.startsWith(
        u8,
        attempt.authorizationUrl(),
        oauth.authorize_url,
    ));
    try fake_loopback.provideCode(&attempt.material.state);
    attempt.join();
    try std.testing.expectEqual(@as(u64, 7), capture.attempt_id);
    var result = capture.result orelse return error.TestUnexpectedResult;
    defer result.deinit();
    try std.testing.expectEqualStrings("code", result.exchange.code.view());
    try std.testing.expectEqual(@as(u16, 49152), result.exchange.callback_port);
    try std.testing.expectEqualSlices(
        u8,
        &attempt.material.verifier,
        &result.exchange.verifier,
    );
}

test "cancel plus join publishes one typed cancellation" {
    var fake_loopback: FakeLoopback = .{ .io = std.testing.io };
    var capture: CaptureSink = .{};
    var attempt: LoginAttempt = .{};
    try attempt.start(
        std.testing.allocator,
        std.testing.io,
        fake_loopback.endpoint(),
        8,
        capture.sink(),
    );
    attempt.cancel();
    attempt.join();
    defer attempt.deinit();
    try std.testing.expectEqual(
        contract.ErrorCode.user_cancelled,
        capture.result.?.failed.error_code,
    );
}

test "callback completion leaves exchange outside the cancellable login worker" {
    var fake_loopback: FakeLoopback = .{ .io = std.testing.io };
    var capture: CaptureSink = .{};
    var attempt: LoginAttempt = .{};
    try attempt.start(
        std.testing.allocator,
        std.testing.io,
        fake_loopback.endpoint(),
        9,
        capture.sink(),
    );
    defer attempt.deinit();
    try fake_loopback.provideCode(&attempt.material.state);
    attempt.join();
    var result = capture.result orelse return error.TestUnexpectedResult;
    defer result.deinit();
    try std.testing.expect(result == .exchange);
    attempt.cancel();
}
