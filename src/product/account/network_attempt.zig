//! Product Account network-attempt lifecycle.
const std = @import("std");
const contract = @import("metawork_account_contract");
const state = @import("account_state");
const oauth = @import("account_oauth");
const metask = @import("metask_client");
const catalog = @import("account_catalog");
const credentials = @import("account_credentials_runtime");

pub const Result = union(enum) {
    refresh: credentials.CredentialRotation,
    completion: state.WorkerCompletion,
    consumed,

    pub fn take(self: *Result) Result {
        const result: Result = switch (self.*) {
            .refresh => |*rotation| .{ .refresh = rotation.take() },
            .completion => |*completion| result: {
                const value = completion.*;
                completion.payload = .{ .failed = .fromCode(
                    .dependency_contract_invalid,
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
        refresh,
        load_identity,
        load_api_keys,
        load_models,
    };

    allocator: std.mem.Allocator = undefined,
    io: std.Io = undefined,
    attempt_id: u64 = 0,
    kind: Kind = undefined,
    transport: metask.Transport = undefined,
    credential_owner: ?*const credentials.CredentialOwner = null,
    identity: ?state.AccountIdentity = null,
    catalog_session: ?*catalog.CatalogSession = null,
    api_key_storage: [contract.Limits.api_key_id_bytes]u8 = undefined,
    api_key_len: usize = 0,
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
            null,
            null,
            "",
            sink,
            now_unix_seconds,
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
            null,
            null,
            "",
            sink,
            0,
        );
    }

    pub fn startLoadApiKeys(
        self: *NetworkAttempt,
        allocator: std.mem.Allocator,
        io: std.Io,
        attempt_id: u64,
        transport: metask.Transport,
        credential_owner: *const credentials.CredentialOwner,
        identity: state.AccountIdentity,
        catalog_session: *catalog.CatalogSession,
        sink: ResultSink,
    ) !void {
        try self.start(
            allocator,
            io,
            attempt_id,
            .load_api_keys,
            transport,
            credential_owner,
            identity,
            catalog_session,
            "",
            sink,
            0,
        );
    }

    pub fn startLoadModels(
        self: *NetworkAttempt,
        allocator: std.mem.Allocator,
        io: std.Io,
        attempt_id: u64,
        transport: metask.Transport,
        catalog_session: *catalog.CatalogSession,
        api_key_id: []const u8,
        sink: ResultSink,
    ) !void {
        if (api_key_id.len == 0 or
            api_key_id.len > self.api_key_storage.len)
            return error.InvalidArgument;
        try self.start(
            allocator,
            io,
            attempt_id,
            .load_models,
            transport,
            null,
            null,
            catalog_session,
            api_key_id,
            sink,
            0,
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
        std.crypto.secureZero(u8, &self.api_key_storage);
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
        identity: ?state.AccountIdentity,
        catalog_session: ?*catalog.CatalogSession,
        api_key_id: []const u8,
        sink: ResultSink,
        now_unix_seconds: i64,
    ) !void {
        if (self.started) return error.AlreadyStarted;
        if (attempt_id == 0 or now_unix_seconds < 0)
            return error.InvalidArgument;
        self.* = .{
            .allocator = allocator,
            .io = io,
            .attempt_id = attempt_id,
            .kind = kind,
            .transport = transport,
            .credential_owner = credential_owner,
            .identity = identity,
            .catalog_session = catalog_session,
            .now_unix_seconds = now_unix_seconds,
            .sink = sink,
            .cancellation = .init(io),
            .deadline = std.Io.Clock.Timestamp.fromNow(io, timeout),
            .started = true,
        };
        @memcpy(self.api_key_storage[0..api_key_id.len], api_key_id);
        self.api_key_len = api_key_id.len;
        errdefer self.started = false;
        self.thread = std.Thread.spawn(.{}, workerMain, .{self}) catch
            return error.ThreadSpawnFailed;
    }

    fn workerMain(self: *NetworkAttempt) void {
        const control: metask.RequestControl = .{
            .cancellation = &self.cancellation,
            .deadline = self.deadline,
        };
        switch (self.kind) {
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
            .load_api_keys => {
                self.credential_owner.?.loadApiKeys(
                    self.catalog_session.?,
                    self.transport,
                    self.identity.?,
                    control,
                ) catch |err| {
                    self.publishCatalogFailure(
                        "keys",
                        catalog.errorCode(err),
                    );
                    return;
                };
                self.publishCompletion(.api_keys_loaded);
            },
            .load_models => {
                const session = self.catalog_session.?;
                session.loadModelsForApiKey(
                    self.api_key_storage[0..self.api_key_len],
                    self.transport,
                    control,
                ) catch |err| {
                    self.publishCatalogFailure(
                        "models",
                        catalog.errorCode(err),
                    );
                    return;
                };
                self.publishCompletion(.models_loaded);
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

    /// Catalog failures carry the request name and HTTP status so a refused
    /// key or endpoint is diagnosable from the banner instead of a guess.
    fn publishCatalogFailure(
        self: *NetworkAttempt,
        request_name: []const u8,
        error_code: contract.ErrorCode,
    ) void {
        const status = self.catalog_session.?.last_http_status;
        if (status == 0) return self.publishFailure(error_code);
        var buffer: [64]u8 = undefined;
        const text = std.fmt.bufPrint(
            &buffer,
            "{s} HTTP {d}",
            .{ request_name, status },
        ) catch return self.publishFailure(error_code);
        const failure = state.WorkerFailure.init(error_code, text) catch
            return self.publishFailure(error_code);
        self.publishCompletion(.{ .failed = failure });
    }
};

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
                \\{"code":0,"message":"success","data":{"id":1,"username":"Stored User"}}
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
