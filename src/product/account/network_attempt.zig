//! Product Account network-attempt lifecycle.
const std = @import("std");
const contract = @import("metawork_account_contract");
const state = @import("account_state");
const oauth = @import("account_oauth");
const metask = @import("metask_client");
const credentials = @import("account_credentials_runtime");
const login_attempt = @import("account_login_attempt");

pub const Result = union(enum) {
    login: oauth.TokenSet,
    refresh: credentials.CredentialRotation,
    completion: state.WorkerCompletion,
    consumed,

    pub fn take(self: *Result) Result {
        const result: Result = switch (self.*) {
            .login => |*tokens| .{ .login = tokens.take() },
            .refresh => |*rotation| .{ .refresh = rotation.take() },
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
            .login => |*tokens| tokens.deinit(),
            .refresh => |*rotation| rotation.deinit(),
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

    const Kind = enum {
        login_exchange,
        refresh,
        load_identity,
    };

    allocator: std.mem.Allocator = undefined,
    io: std.Io = undefined,
    attempt_id: u64 = 0,
    kind: Kind = undefined,
    transport: metask.Transport = undefined,
    credential_owner: ?*const credentials.CredentialOwner = null,
    login_exchange: ?login_attempt.CallbackExchangeInput = null,
    now_unix_seconds: i64 = 0,
    sink: ResultSink = undefined,
    cancellation: metask.Cancellation = undefined,
    deadline: std.Io.Clock.Timestamp = undefined,
    thread: ?std.Thread = null,
    started: bool = false,
    joined: bool = false,

    pub fn startRefresh(
        self: *NetworkAttempt,
        allocator: std.mem.Allocator,
        io: std.Io,
        attempt_id: u64,
        transport: metask.Transport,
        credential_owner: *const credentials.CredentialOwner,
        sink: ResultSink,
        now_unix_seconds: i64,
    ) !void {
        try self.start(
            allocator,
            io,
            attempt_id,
            .refresh,
            transport,
            credential_owner,
            sink,
            now_unix_seconds,
            null,
        );
    }

    pub fn startLoginExchange(
        self: *NetworkAttempt,
        allocator: std.mem.Allocator,
        io: std.Io,
        attempt_id: u64,
        transport: metask.Transport,
        input: *login_attempt.CallbackExchangeInput,
        sink: ResultSink,
        now_unix_seconds: i64,
    ) !void {
        try self.start(
            allocator,
            io,
            attempt_id,
            .login_exchange,
            transport,
            null,
            sink,
            now_unix_seconds,
            input,
        );
    }

    pub fn startLoadIdentity(
        self: *NetworkAttempt,
        allocator: std.mem.Allocator,
        io: std.Io,
        attempt_id: u64,
        transport: metask.Transport,
        credential_owner: *const credentials.CredentialOwner,
        sink: ResultSink,
    ) !void {
        try self.start(
            allocator,
            io,
            attempt_id,
            .load_identity,
            transport,
            credential_owner,
            sink,
            0,
            null,
        );
    }

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
        if (self.login_exchange) |*input| input.deinit();
        self.* = .{};
    }

    pub fn matches(self: *const NetworkAttempt, attempt_id: u64) bool {
        return self.started and self.attempt_id == attempt_id;
    }

    fn start(
        self: *NetworkAttempt,
        allocator: std.mem.Allocator,
        io: std.Io,
        attempt_id: u64,
        kind: Kind,
        transport: metask.Transport,
        credential_owner: ?*const credentials.CredentialOwner,
        sink: ResultSink,
        now_unix_seconds: i64,
        login_exchange: ?*login_attempt.CallbackExchangeInput,
    ) !void {
        if (self.started) return error.AlreadyStarted;
        if (attempt_id == 0 or now_unix_seconds < 0)
            return error.InvalidArgument;
        const deadline_cap = std.Io.Clock.Timestamp.fromNow(io, timeout);
        const login_deadline = if (login_exchange) |input|
            input.attempt_deadline
        else
            null;
        self.* = .{
            .allocator = allocator,
            .io = io,
            .attempt_id = attempt_id,
            .kind = kind,
            .transport = transport,
            .credential_owner = credential_owner,
            .login_exchange = if (login_exchange) |input| input.take() else null,
            .now_unix_seconds = now_unix_seconds,
            .sink = sink,
            .cancellation = .init(io),
            .deadline = if (login_deadline) |attempt_deadline|
                earlierDeadline(attempt_deadline, deadline_cap)
            else
                deadline_cap,
            .started = true,
        };
        errdefer {
            if (self.login_exchange) |*input| input.deinit();
            self.* = .{};
        }
        self.thread = std.Thread.spawn(.{}, workerMain, .{self}) catch
            return error.ThreadSpawnFailed;
    }

    fn workerMain(self: *NetworkAttempt) void {
        const control: metask.RequestControl = .{
            .cancellation = &self.cancellation,
            .deadline = self.deadline,
        };
        switch (self.kind) {
            .login_exchange => {
                const input = &self.login_exchange.?;
                var tokens = metask.exchangeAuthorizationCode(
                    self.allocator,
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
                defer tokens.deinit();
                var result: Result = .{ .login = tokens.take() };
                self.sink.publish(self.attempt_id, &result);
            },
            .refresh => {
                var refreshed = self.credential_owner.?.refresh(
                    self.allocator,
                    self.transport,
                    self.now_unix_seconds,
                    control,
                ) catch |err| {
                    self.publishFailure(metask.errorCode(err));
                    return;
                };
                defer refreshed.deinit();
                var result: Result = .{ .refresh = refreshed.take() };
                self.sink.publish(self.attempt_id, &result);
            },
            .load_identity => {
                const identity = self.credential_owner.?.fetchIdentity(
                    self.transport,
                    control,
                ) catch |err| {
                    self.publishFailure(metask.errorCode(err));
                    return;
                };
                self.publishCompletion(.{ .identity_loaded = identity });
            },
        }
    }

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
    started: std.atomic.Value(u32) = .init(0),

    fn transport(self: *RefreshTransport) metask.Transport {
        return .{ .context = self, .perform_fn = perform };
    }

    fn perform(
        context: *anyopaque,
        request: metask.Request,
        output: []u8,
    ) metask.TransportError!metask.Response {
        const self: *RefreshTransport = @ptrCast(@alignCast(context));
        if (request.kind == .current_user) {
            const body =
                \\{"code":0,"message":"success","data":{"id":1,"email":"stored@example.com","username":"Stored User","concurrency":5}}
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
            \\{"access_token":"fresh-access","refresh_token":"fresh-refresh","token_type":"Bearer","expires_in":3600,"scope":"metawork:use","account_id":"1"}
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
        return .{ .context = self, .perform_fn = perform };
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
            \\{"access_token":"access","refresh_token":"refresh","token_type":"Bearer","expires_in":3600,"scope":"metawork:use","account_id":"acct-1"}
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
    try attempt.startLoginExchange(
        std.testing.allocator,
        std.testing.io,
        7,
        transport.transport(),
        &input,
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
    try std.testing.expectEqualStrings("acct-1", result.login.accountId());

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
    try attempt.startLoginExchange(
        std.testing.allocator,
        std.testing.io,
        8,
        blocking.transport(),
        &short_input,
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

test "refresh attempt transfers one opaque generation and cancels cleanly" {
    var credential_owner: credentials.CredentialOwner = .{};
    defer credential_owner.deinit();
    try credential_owner.installStored(
        std.testing.allocator,
        "old-access",
        "old-refresh",
        10,
        "acct-1",
    );
    var transport: RefreshTransport = .{};
    var capture: CaptureSink = .{};
    var attempt: NetworkAttempt = .{};
    try attempt.startRefresh(
        std.testing.allocator,
        std.testing.io,
        9,
        transport.transport(),
        &credential_owner,
        capture.sink(),
        100,
    );
    attempt.join();
    attempt.deinit();
    var refreshed = capture.result orelse
        return error.TestUnexpectedResult;
    defer refreshed.deinit();
    try std.testing.expectEqual(@as(u64, 9), capture.attempt_id);
    try std.testing.expectEqualStrings(
        "1",
        refreshed.refresh.accountId(),
    );
    try std.testing.expectEqual(@as(?i64, 10), credential_owner.expiresAt());

    var blocking: RefreshTransport = .{ .blocking = true };
    var cancelled_capture: CaptureSink = .{};
    try attempt.startRefresh(
        std.testing.allocator,
        std.testing.io,
        10,
        blocking.transport(),
        &credential_owner,
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

test "refresh-only restore commits rotation before loading identity" {
    var refresh = try oauth.Secret.init(
        std.testing.allocator,
        "old-refresh",
    );
    defer refresh.deinit();
    var credential_owner: credentials.CredentialOwner = .{};
    defer credential_owner.deinit();
    credential_owner.installRefreshToken(&refresh);
    var transport: RefreshTransport = .{};
    var capture: CaptureSink = .{};
    var attempt: NetworkAttempt = .{};
    try attempt.startRefresh(
        std.testing.allocator,
        std.testing.io,
        11,
        transport.transport(),
        &credential_owner,
        capture.sink(),
        100,
    );
    attempt.join();
    attempt.deinit();
    var refreshed = capture.result orelse
        return error.TestUnexpectedResult;
    capture.result = null;
    defer refreshed.deinit();
    credential_owner.replaceRotation(&refreshed.refresh);

    try attempt.startLoadIdentity(
        std.testing.allocator,
        std.testing.io,
        12,
        transport.transport(),
        &credential_owner,
        capture.sink(),
    );
    attempt.join();
    attempt.deinit();
    var identified = capture.result orelse return error.TestUnexpectedResult;
    capture.result = null;
    defer identified.deinit();
    const identity = identified.completion.payload.identity_loaded;
    try std.testing.expectEqualStrings("1", identity.accountId());
}
