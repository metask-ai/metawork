//! Product Account OAuth callback policy and loopback endpoint contract.
const std = @import("std");
const oauth = @import("account_oauth");

pub const Limits = struct {
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

pub const Method = enum { get, other };

/// Callback-scoped request metadata. The target is borrowed only for the
/// duration of `RequestSink.handle`; Product policy must copy any retained
/// value before returning.
pub const Request = struct {
    method: Method,
    target: []const u8,
    has_content_length: bool,
    has_transfer_encoding: bool,
};

pub const Response = struct {
    status: enum { ok, bad_request },
    body: []const u8,
    complete: bool,
};

pub const RequestSink = struct {
    context: *anyopaque,
    invalid_fn: *const fn (*anyopaque) ServerError!void,
    handle_fn: *const fn (*anyopaque, Request) ServerError!Response,

    pub fn invalid(self: RequestSink) ServerError!void {
        return self.invalid_fn(self.context);
    }

    pub fn handle(self: RequestSink, request: Request) ServerError!Response {
        return self.handle_fn(self.context, request);
    }
};

/// Account-owned capability port. The concrete listener, connections,
/// cancellation race, deadlines and byte pump remain behind Application.
pub const Endpoint = struct {
    context: *anyopaque,
    open_fn: *const fn (*anyopaque) ServerError!u16,
    wait_fn: *const fn (
        *anyopaque,
        RequestSink,
        std.Io.Clock.Timestamp,
    ) ServerError!void,
    cancel_fn: *const fn (*anyopaque) void,
    close_fn: *const fn (*anyopaque) void,

    pub fn open(self: Endpoint) ServerError!u16 {
        return self.open_fn(self.context);
    }

    pub fn wait(
        self: Endpoint,
        sink: RequestSink,
        deadline: std.Io.Clock.Timestamp,
    ) ServerError!void {
        return self.wait_fn(self.context, sink, deadline);
    }

    pub fn cancel(self: Endpoint) void {
        self.cancel_fn(self.context);
    }

    pub fn close(self: Endpoint) void {
        self.close_fn(self.context);
    }
};

/// OAuth callback policy and owned result collector. It knows state, issuer,
/// code/error semantics and the invalid-request budget, but no socket or HTTP
/// server implementation details.
pub const CallbackPolicy = struct {
    allocator: std.mem.Allocator,
    expected_state: []const u8,
    validation: oauth.CallbackValidation,
    invalid_count: usize = 0,
    callback: ?oauth.Callback = null,

    pub fn init(
        allocator: std.mem.Allocator,
        expected_state: []const u8,
        validation: oauth.CallbackValidation,
    ) CallbackPolicy {
        return .{
            .allocator = allocator,
            .expected_state = expected_state,
            .validation = validation,
        };
    }

    pub fn deinit(self: *CallbackPolicy) void {
        if (self.callback) |*callback| callback.deinit();
        self.callback = null;
    }

    pub fn sink(self: *CallbackPolicy) RequestSink {
        return .{
            .context = self,
            .invalid_fn = invalidRequest,
            .handle_fn = handleRequest,
        };
    }

    pub fn take(self: *CallbackPolicy) ?oauth.Callback {
        const callback = self.callback;
        self.callback = null;
        return callback;
    }

    fn invalidRequest(context: *anyopaque) ServerError!void {
        const self: *CallbackPolicy = @ptrCast(@alignCast(context));
        try self.recordInvalid();
    }

    fn handleRequest(
        context: *anyopaque,
        request: Request,
    ) ServerError!Response {
        const self: *CallbackPolicy = @ptrCast(@alignCast(context));
        if (request.method != .get or
            request.has_content_length or
            request.has_transfer_encoding)
        {
            try self.recordInvalid();
            return invalidResponse();
        }
        const callback = (if (self.validation.expected_issuer == null and
            !self.validation.issuer_required)
            oauth.parseCallbackTarget(
                self.allocator,
                request.target,
                self.expected_state,
            )
        else
            oauth.parseCallbackTargetValidated(
                self.allocator,
                request.target,
                self.expected_state,
                self.validation,
            )) catch {
            try self.recordInvalid();
            return invalidResponse();
        };
        std.debug.assert(self.callback == null);
        const response: Response = switch (callback) {
            .code => .{
                .status = .ok,
                .body = "Authorization returned to MetaWork. You may close this window and wait for MetaWork to finish signing in.",
                .complete = true,
            },
            .rejected => .{
                .status = .bad_request,
                .body = "Authentication was not completed. You may close this window and return to MetaWork.",
                .complete = true,
            },
        };
        self.callback = callback;
        return response;
    }

    fn recordInvalid(self: *CallbackPolicy) ServerError!void {
        self.invalid_count += 1;
        if (self.invalid_count >= Limits.invalid_requests)
            return error.TooManyInvalidRequests;
    }
};

fn invalidResponse() Response {
    return .{
        .status = .bad_request,
        .body = "Invalid OAuth callback.",
        .complete = false,
    };
}

test "callback policy accepts one exact code without socket knowledge" {
    const expected_state = "0123456789012345678901234567890123456789012";
    var policy = CallbackPolicy.init(
        std.testing.allocator,
        expected_state,
        .{},
    );
    defer policy.deinit();
    const response = try policy.sink().handle(.{
        .method = .get,
        .target = oauth.callback_path ++
            "?code=authorization-code&state=" ++ expected_state,
        .has_content_length = false,
        .has_transfer_encoding = false,
    });
    try std.testing.expectEqual(.ok, response.status);
    try std.testing.expect(response.complete);
    var callback = policy.take() orelse return error.TestUnexpectedResult;
    defer callback.deinit();
    try std.testing.expectEqualStrings(
        "authorization-code",
        callback.code.view(),
    );
}

test "callback policy owns invalid request budget" {
    var policy = CallbackPolicy.init(
        std.testing.allocator,
        "0123456789012345678901234567890123456789012",
        .{},
    );
    defer policy.deinit();
    const request_sink = policy.sink();
    try request_sink.invalid();
    try request_sink.invalid();
    try request_sink.invalid();
    try std.testing.expectError(
        error.TooManyInvalidRequests,
        request_sink.invalid(),
    );
}
