//! Product Account network-attempt lifecycle.
const std = @import("std");
const contract = @import("metawork_account_contract");
const state = @import("account_state");
const oauth = @import("account_oauth");
const metask = @import("metask_client");
const credentials = @import("account_credentials_runtime");
const login_attempt = @import("account_login_attempt");

/// What one request is sent with and answered into, never the session's own
/// credential. The attempt owns it from `start` on, whether or not the thread
/// starts; only an answered grant leaves it.
pub const Work = union(enum) {
    login_exchange: struct { input: login_attempt.CallbackExchangeInput, grant: ?*credentials.Grant },
    refresh: struct { token: oauth.Secret, principal: Principal, grant: ?*credentials.Grant },
    load_identity: oauth.Secret,
    none,

    pub fn deinit(self: *Work) void {
        switch (self.*) {
            .login_exchange => |*exchange| {
                exchange.input.deinit();
                if (exchange.grant) |grant| grant.destroy();
            },
            .refresh => |*refresh| {
                refresh.token.deinit();
                if (refresh.grant) |grant| grant.destroy();
            },
            .load_identity => |*token| token.deinit(),
            .none => {},
        }
        self.* = .none;
    }
};

/// The account a request acts for; empty while a stored login is unconfirmed.
pub const Principal = struct {
    bytes: [contract.Limits.account_id_bytes]u8 = undefined,
    len: usize = 0,

    pub fn init(account_id: []const u8) Principal {
        var result: Principal = .{ .len = account_id.len };
        @memcpy(result.bytes[0..account_id.len], account_id);
        return result;
    }

    fn view(self: *const Principal) ?[]const u8 {
        return if (self.len == 0) null else self.bytes[0..self.len];
    }
};

pub const Result = union(enum) {
    login: *credentials.Grant,
    refresh: *credentials.Grant,
    completion: state.WorkerCompletion,
    consumed,

    pub fn take(self: *Result) Result {
        const result: Result = switch (self.*) {
            .login => |grant| .{ .login = grant },
            .refresh => |grant| .{ .refresh = grant },
            .completion => |*completion| result: {
                const value = completion.*;
                completion.payload = .{ .failed = .fromCode(
                    .account_operation_failed,
                ) };
                break :result .{ .completion = value };
            },
            .consumed => .consumed,
        };
        self.* = .consumed;
        return result;
    }

    pub fn deinit(self: *Result) void {
        switch (self.*) {
            .login, .refresh => |grant| grant.destroy(),
            .completion => |*completion| completion.deinit(),
            .consumed => {},
        }
        self.* = .consumed;
    }
};

pub const ResultSink = struct {
    context: *anyopaque,
    publish_fn: *const fn (
        context: *anyopaque,
        attempt_id: u64,
        result: *Result,
    ) bool,

    pub fn publish(
        self: ResultSink,
        attempt_id: u64,
        result: *Result,
    ) void {
        if (!self.publish_fn(self.context, attempt_id, result)) {
            result.deinit();
            return;
        }
        std.debug.assert(result.* == .consumed);
    }
};

pub const NetworkAttempt = struct {
    const timeout: std.Io.Clock.Duration = .{
        .raw = .fromSeconds(30),
        .clock = .boot,
    };

    io: std.Io = undefined,
    attempt_id: u64 = 0,
    transport: metask.Transport = undefined,
    work: Work = .none,
    now_unix_seconds: i64 = 0,
    sink: ResultSink = undefined,
    cancellation: metask.Cancellation = undefined,
    deadline: std.Io.Clock.Timestamp = undefined,
    thread: ?std.Thread = null,
    started: bool = false,
    joined: bool = false,

    pub fn cancel(self: *NetworkAttempt) void {
        if (!self.started or self.joined) return;
        self.cancellation.cancel();
    }

    pub fn join(self: *NetworkAttempt) void {
        if (!self.started or self.joined) return;
        const thread = self.thread orelse
            @panic("started Account network attempt has no thread");
        thread.join();
        self.thread = null;
        self.joined = true;
    }

    pub fn deinit(self: *NetworkAttempt) void {
        if (!self.started) {
            self.* = .{};
            return;
        }
        std.debug.assert(self.joined);
        self.work.deinit();
        self.* = .{};
    }

    pub fn matches(self: *const NetworkAttempt, attempt_id: u64) bool {
        return self.started and self.attempt_id == attempt_id;
    }

    pub fn start(
        self: *NetworkAttempt,
        io: std.Io,
        attempt_id: u64,
        transport: metask.Transport,
        work_value: Work,
        sink: ResultSink,
        now_unix_seconds: i64,
    ) !void {
        var work = work_value;
        errdefer work.deinit();
        if (self.started) return error.AlreadyStarted;
        if (attempt_id == 0 or now_unix_seconds < 0)
            return error.InvalidArgument;
        const deadline_cap = std.Io.Clock.Timestamp.fromNow(io, timeout);
        self.* = .{
            .io = io,
            .attempt_id = attempt_id,
            .transport = transport,
            .work = work,
            .now_unix_seconds = now_unix_seconds,
            .sink = sink,
            .cancellation = .init(io),
            .deadline = switch (work) {
                .login_exchange => |*exchange| earlierDeadline(exchange.input.attempt_deadline, deadline_cap),
                .refresh, .load_identity, .none => deadline_cap,
            },
            .started = true,
        };
        work = .none;
        errdefer {
            self.work.deinit();
            self.* = .{};
        }
        self.thread = std.Thread.spawn(.{}, workerMain, .{self}) catch
            return error.ThreadSpawnFailed;
    }

    pub fn refreshing(self: *const NetworkAttempt) bool {
        return self.started and self.work == .refresh;
    }

    fn workerMain(self: *NetworkAttempt) void {
        const control: metask.RequestControl = .{
            .cancellation = &self.cancellation,
            .deadline = self.deadline,
        };
        switch (self.work) {
            .login_exchange => |*exchange| {
                const input = &exchange.input;
                const grant = exchange.grant.?;
                var tokens = metask.exchangeAuthorizationCode(
                    grant.secretAllocator(),
                    self.transport,
                    &input.code,
                    &input.verifier,
                    input.callback_port,
                    self.now_unix_seconds,
                    control,
                ) catch |err| {
                    self.publishFailure(metask.errorCode(err));
                    return;
                };
                grant.issue(&tokens);
                var result: Result = .{ .login = credentials.Grant.take(&exchange.grant) };
                self.sink.publish(self.attempt_id, &result);
            },
            .refresh => |*refresh| {
                const grant = refresh.grant.?;
                var tracked: RefreshTransportEvidence = .{ .transport = self.transport };
                var tokens = metask.refreshWithToken(
                    grant.secretAllocator(),
                    .{ .context = &tracked, .perform_fn = RefreshTransportEvidence.perform, .retire_fn = RefreshTransportEvidence.retire },
                    &refresh.token,
                    refresh.principal.view(),
                    self.now_unix_seconds,
                    control,
                ) catch |err| {
                    self.publishCompletion(.{ .failed = .{
                        .error_code = metask.errorCode(err),
                        .refresh_not_consumed = !tracked.may_have_sent or err == error.TokenRefreshFailed,
                    } });
                    return;
                };
                grant.issue(&tokens);
                var result: Result = .{ .refresh = credentials.Grant.take(&refresh.grant) };
                self.sink.publish(self.attempt_id, &result);
            },
            .load_identity => |*token| {
                const identity = metask.fetchIdentity(
                    self.transport,
                    token.view(),
                    control,
                ) catch |err| {
                    self.publishFailure(metask.errorCode(err));
                    return;
                };
                self.publishCompletion(.{ .identity_loaded = identity });
            },
            .none => unreachable,
        }
    }

    const RefreshTransportEvidence = struct {
        transport: metask.Transport,
        may_have_sent: bool = false,

        fn retire(context: *anyopaque, principal: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.transport.retire(principal);
        }

        fn perform(context: *anyopaque, request: metask.Request, output: []u8) metask.TransportError!metask.Response {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.may_have_sent = true;
            return self.transport.perform(request, output) catch |err| {
                switch (err) {
                    error.NetworkNotSent, error.CancelledNotSent, error.DeadlineExceededNotSent => self.may_have_sent = false,
                    else => {},
                }
                return err;
            };
        }
    };

    fn publishCompletion(
        self: *NetworkAttempt,
        payload: state.WorkerCompletion.Payload,
    ) void {
        var result: Result = .{ .completion = .{
            .attempt_id = self.attempt_id,
            .payload = payload,
        } };
        self.sink.publish(self.attempt_id, &result);
    }

    fn publishFailure(
        self: *NetworkAttempt,
        error_code: contract.ErrorCode,
    ) void {
        self.publishCompletion(.{ .failed = .fromCode(error_code) });
    }
};

fn earlierDeadline(
    first: std.Io.Clock.Timestamp,
    second: std.Io.Clock.Timestamp,
) std.Io.Clock.Timestamp {
    std.debug.assert(first.clock == second.clock);
    return if (first.raw.toNanoseconds() <= second.raw.toNanoseconds())
        first
    else
        second;
}

const CaptureSink = struct {
    attempt_id: u64 = 0,
    result: ?Result = null,

    fn sink(self: *CaptureSink) ResultSink {
        return .{ .context = self, .publish_fn = publish };
    }

    fn publish(
        context: *anyopaque,
        attempt_id: u64,
        result: *Result,
    ) bool {
        const self: *CaptureSink = @ptrCast(@alignCast(context));
        if (self.result != null) return false;
        self.attempt_id = attempt_id;
        self.result = result.take();
        return true;
    }
};

const RefreshTransport = struct {
    blocking: bool = false,
    incomplete_profile: bool = false,
    started: std.atomic.Value(u32) = .init(0),

    fn transport(self: *RefreshTransport) metask.Transport {
        return .{ .context = self, .perform_fn = perform, .retire_fn = metask.retireNothing };
    }

    fn perform(
        context: *anyopaque,
        request: metask.Request,
        output: []u8,
    ) metask.TransportError!metask.Response {
        const self: *RefreshTransport = @ptrCast(@alignCast(context));
        if (request.kind == .userinfo) {
            const body = if (self.incomplete_profile)
                \\{"sub":"1","client_id":"metawork","authorization_id":"auth-1"}
            else
                \\{"sub":"1","email":"stored@example.com","name":"Stored User","client_id":"metawork","authorization_id":"auth-1"}
            ;
            @memcpy(output[0..body.len], body);
            return .{ .status = 200, .body = output[0..body.len] };
        }
        if (request.kind != .refresh_token) return error.ProtocolFailed;
        if (self.blocking) {
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
        const body =
            \\{"access_token":"fresh-access","refresh_token":"fresh-refresh","token_type":"Bearer","expires_in":3600}
        ;
        @memcpy(output[0..body.len], body);
        return .{ .status = 200, .body = output[0..body.len] };
    }

    fn waitUntilStarted(self: *RefreshTransport, io: std.Io) void {
        while (self.started.load(.acquire) == 0) {
            io.futexWait(u32, &self.started.raw, 0) catch return;
        }
    }
};

const LoginTransport = struct {
    blocking: bool = false,
    started: std.atomic.Value(u32) = .init(0),

    fn transport(self: *LoginTransport) metask.Transport {
        return .{ .context = self, .perform_fn = perform, .retire_fn = metask.retireNothing };
    }

    fn perform(
        context: *anyopaque,
        request: metask.Request,
        output: []u8,
    ) metask.TransportError!metask.Response {
        const self: *LoginTransport = @ptrCast(@alignCast(context));
        if (request.kind != .exchange_code) return error.ProtocolFailed;
        if (self.blocking) {
            const control = request.control orelse return error.ProtocolFailed;
            self.started.store(1, .release);
            control.cancellation.io.futexWake(
                u32,
                &self.started.raw,
                std.math.maxInt(u32),
            );
            control.cancellation.wait();
            return error.Cancelled;
        }
        const body =
            \\{"access_token":"access","refresh_token":"refresh","token_type":"Bearer","expires_in":3600,"scope":"read model:invoke"}
        ;
        @memcpy(output[0..body.len], body);
        return .{ .status = 200, .body = output[0..body.len] };
    }

    fn waitUntilStarted(self: *LoginTransport, io: std.Io) void {
        while (self.started.load(.acquire) == 0) {
            io.futexWait(u32, &self.started.raw, 0) catch return;
        }
    }
};

test "login exchange uses the remaining login deadline capped at thirty seconds" {
    var transport: LoginTransport = .{};
    var capture: CaptureSink = .{};
    var input = try login_attempt.TestSupport.exchangeInput(
        std.testing.allocator,
        std.testing.io,
        "authorization-code",
        .{ .raw = .fromSeconds(5 * 60), .clock = .boot },
    );
    defer input.deinit();
    var attempt: NetworkAttempt = .{};
    try attempt.start(
        std.testing.io,
        7,
        transport.transport(),
        try testExchange(&input),
        capture.sink(),
        100,
    );
    const remaining = attempt.deadline.durationFromNow(std.testing.io).raw.toNanoseconds();
    try std.testing.expect(remaining > 0);
    try std.testing.expect(remaining <= 30 * std.time.ns_per_s);
    attempt.join();
    attempt.deinit();
    var result = capture.result orelse return error.TestUnexpectedResult;
    defer result.deinit();
    try std.testing.expect(result.login.accessToken() != null);

    var blocking: LoginTransport = .{ .blocking = true };
    var cancelled_capture: CaptureSink = .{};
    var short_input = try login_attempt.TestSupport.exchangeInput(
        std.testing.allocator,
        std.testing.io,
        "short-lived-code",
        .{ .raw = .fromSeconds(2), .clock = .boot },
    );
    defer short_input.deinit();
    const total_deadline = short_input.attempt_deadline;
    try attempt.start(
        std.testing.io,
        8,
        blocking.transport(),
        try testExchange(&short_input),
        cancelled_capture.sink(),
        100,
    );
    try std.testing.expectEqual(
        total_deadline.raw.toNanoseconds(),
        attempt.deadline.raw.toNanoseconds(),
    );
    blocking.waitUntilStarted(std.testing.io);
    attempt.cancel();
    attempt.join();
    attempt.deinit();
    var cancelled = cancelled_capture.result orelse return error.TestUnexpectedResult;
    defer cancelled.deinit();
    try std.testing.expectEqual(
        contract.ErrorCode.user_cancelled,
        cancelled.completion.payload.failed.error_code,
    );
}

fn testExchange(input: *login_attempt.CallbackExchangeInput) !Work {
    return .{ .login_exchange = .{
        .input = input.take(),
        .grant = try credentials.Grant.create(std.testing.allocator),
    } };
}

fn testRefresh(refresh_token: []const u8) !Work {
    var token = try oauth.Secret.init(std.testing.allocator, refresh_token);
    errdefer token.deinit();
    return .{ .refresh = .{
        .token = token,
        .principal = .init(""),
        .grant = try credentials.Grant.create(std.testing.allocator),
    } };
}

test "a refresh attempt answers into its own grant and cancels cleanly" {
    var transport: RefreshTransport = .{};
    var capture: CaptureSink = .{};
    var attempt: NetworkAttempt = .{};
    try attempt.start(
        std.testing.io,
        9,
        transport.transport(),
        try testRefresh("old-refresh"),
        capture.sink(),
        100,
    );
    attempt.join();
    attempt.deinit();
    var refreshed = capture.result orelse
        return error.TestUnexpectedResult;
    defer refreshed.deinit();
    try std.testing.expectEqual(@as(u64, 9), capture.attempt_id);
    try std.testing.expectEqualStrings("fresh-access", refreshed.refresh.accessToken().?);
    try std.testing.expectEqualStrings("fresh-refresh", refreshed.refresh.refresh_token.view());

    // A refused start keeps nothing of what it was given.
    try std.testing.expectError(error.InvalidArgument, attempt.start(
        std.testing.io,
        0,
        transport.transport(),
        try testRefresh("old-refresh"),
        capture.sink(),
        100,
    ));
    try std.testing.expect(!attempt.started);

    var blocking: RefreshTransport = .{ .blocking = true };
    var cancelled_capture: CaptureSink = .{};
    try attempt.start(
        std.testing.io,
        10,
        blocking.transport(),
        try testRefresh("old-refresh"),
        cancelled_capture.sink(),
        100,
    );
    blocking.waitUntilStarted(std.testing.io);
    attempt.cancel();
    attempt.join();
    attempt.deinit();
    var cancelled = cancelled_capture.result orelse
        return error.TestUnexpectedResult;
    defer cancelled.deinit();
    try std.testing.expectEqual(
        contract.ErrorCode.user_cancelled,
        cancelled.completion.payload.failed.error_code,
    );
}

test "refresh-only restore accepts an identity with incomplete profile data" {
    var transport: RefreshTransport = .{ .incomplete_profile = true };
    var capture: CaptureSink = .{};
    var attempt: NetworkAttempt = .{};
    try attempt.start(
        std.testing.io,
        11,
        transport.transport(),
        try testRefresh("old-refresh"),
        capture.sink(),
        100,
    );
    attempt.join();
    attempt.deinit();
    var refreshed = capture.result orelse
        return error.TestUnexpectedResult;
    capture.result = null;
    defer refreshed.deinit();

    try attempt.start(
        std.testing.io,
        12,
        transport.transport(),
        .{ .load_identity = try oauth.Secret.init(std.testing.allocator, refreshed.refresh.accessToken().?) },
        capture.sink(),
        0,
    );
    attempt.join();
    attempt.deinit();
    var identified = capture.result orelse return error.TestUnexpectedResult;
    capture.result = null;
    defer identified.deinit();
    const identity = identified.completion.payload.identity_loaded;
    try std.testing.expectEqualStrings("1", identity.accountId());
    try std.testing.expectEqualStrings("", identity.displayName());
    try std.testing.expectEqualStrings("", identity.emailHint());
    try std.testing.expectEqual(@as(?u32, null), identity.concurrency_limit);
}
