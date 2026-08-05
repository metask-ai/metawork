//! Agent-private Streamable HTTP connector over an opaque, preauthorized
//! endpoint capability. Credential acquisition, refresh, headers, HTTP/SSE
//! mechanics, and MCP protocol parsing do not belong to this module.

const std = @import("std");
const connector = @import("agent_mcp_connector");

pub const PortFailure = enum {
    timeout,
    network,
    auth,
    server,
    cancelled,
    indeterminate,
    fatal,
};

pub const Request = struct {
    purpose: connector.Purpose,
    era: connector.Era,
    session_token: []const u8,
    body: []const u8,
    timeout_ms: u32,
    max_response_bytes: usize,
    cancellation: connector.Cancellation,
    notification: bool,
};

pub const Response = struct {
    /// Allocated with the allocator passed to `perform_fn`. Ownership transfers
    /// to Backend even when the status is rejected.
    body: []u8,
    status: u16,
    session_token: []const u8 = &.{},
};

pub const PerformOutcome = union(enum) {
    response: Response,
    failure: PortFailure,
};

/// Opaque capability for one already-authorized endpoint/header set. Its
/// context owns credentials and HTTP implementation details and must outlive
/// Backend. Request and close fields are callback-scoped borrows. Returned
/// session_token is callback-scoped; Backend copies it.
pub const AuthorizedEndpoint = struct {
    context: *anyopaque,
    validate_fn: *const fn (*anyopaque) bool,
    perform_fn: *const fn (
        *anyopaque,
        std.mem.Allocator,
        Request,
    ) PerformOutcome,
    close_fn: *const fn (*anyopaque, connector.Era, []const u8) void,
};

pub const Config = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    endpoint: AuthorizedEndpoint,
    max_connections: usize = 16,
    max_response_bytes: usize = (connector.Limits{}).max_response_bytes,
    max_session_token_bytes: usize = 1024,
};

pub const Error = error{InvalidConfig};

pub const Backend = struct {
    config: Config,
    active_connections: std.atomic.Value(usize) = .init(0),

    pub fn init(config: Config) Error!Backend {
        if (config.max_connections == 0 or config.max_response_bytes == 0 or
            config.max_response_bytes > (connector.Limits{}).max_response_bytes or
            config.max_session_token_bytes == 0 or
            config.max_session_token_bytes > max_session_token_bytes or
            !config.endpoint.validate_fn(config.endpoint.context))
            return error.InvalidConfig;
        return .{ .config = config };
    }

    pub fn transport(self: *Backend) connector.Transport {
        return .{
            .context = self,
            .open_fn = open,
            .request_fn = request,
            .notify_fn = notify,
            .close_fn = close,
        };
    }

    pub fn deinit(self: *Backend) error{ConnectionsActive}!void {
        if (self.active_connections.load(.acquire) != 0)
            return error.ConnectionsActive;
        self.* = undefined;
    }

    const Connection = struct {
        backend: *Backend,
        purpose: connector.Purpose,
        era: connector.Era,
        session_token: []u8,
        mutex: std.Io.Mutex = .init,
        poisoned: bool = false,

        fn deinit(self: *Connection) void {
            const backend = self.backend;
            const endpoint = backend.config.endpoint;
            endpoint.close_fn(endpoint.context, self.era, self.session_token);
            secureFree(backend.config.allocator, self.session_token);
            backend.config.allocator.destroy(self);
            releaseCounter(&backend.active_connections);
        }
    };

    fn open(
        context: *anyopaque,
        purpose: connector.Purpose,
        era: connector.Era,
        timeout_ms: u32,
    ) connector.OpenOutcome {
        const self: *Backend = @ptrCast(@alignCast(context));
        if (timeout_ms == 0 or !incrementBounded(
            &self.active_connections,
            self.config.max_connections,
        )) return .{ .failure = .fatal };
        const connection = self.config.allocator.create(Connection) catch {
            releaseCounter(&self.active_connections);
            return .{ .failure = .fatal };
        };
        connection.* = .{
            .backend = self,
            .purpose = purpose,
            .era = era,
            .session_token = &.{},
        };
        return .{ .connection = connection };
    }

    fn request(
        raw_connection: *anyopaque,
        allocator: std.mem.Allocator,
        bytes: []const u8,
        timeout_ms: u32,
        cancellation: connector.Cancellation,
    ) connector.ExchangeOutcome {
        const connection: *Connection = @ptrCast(@alignCast(raw_connection));
        connection.mutex.lockUncancelable(connection.backend.config.io);
        defer connection.mutex.unlock(connection.backend.config.io);
        if (connection.poisoned or timeout_ms == 0)
            return .{ .failure = .fatal };
        if (cancellation.isCancelled())
            return .{ .failure = .cancelled };
        return switch (perform(
            connection,
            allocator,
            bytes,
            timeout_ms,
            cancellation,
            false,
        )) {
            .failure => |failure| poisonExchange(connection, failure),
            .response => |response| acceptRequest(
                connection,
                allocator,
                response,
            ),
        };
    }

    fn notify(
        raw_connection: *anyopaque,
        bytes: []const u8,
        timeout_ms: u32,
        cancellation: connector.Cancellation,
    ) ?connector.Failure {
        const connection: *Connection = @ptrCast(@alignCast(raw_connection));
        connection.mutex.lockUncancelable(connection.backend.config.io);
        defer connection.mutex.unlock(connection.backend.config.io);
        if (connection.poisoned or timeout_ms == 0) return .fatal;
        if (cancellation.isCancelled()) return .cancelled;
        return switch (perform(
            connection,
            connection.backend.config.allocator,
            bytes,
            timeout_ms,
            cancellation,
            true,
        )) {
            .failure => |failure| poisonNotification(connection, failure),
            .response => |response| acceptNotification(
                connection,
                connection.backend.config.allocator,
                response,
            ),
        };
    }

    fn close(raw_connection: *anyopaque) void {
        const connection: *Connection = @ptrCast(@alignCast(raw_connection));
        connection.mutex.lockUncancelable(connection.backend.config.io);
        connection.poisoned = true;
        connection.mutex.unlock(connection.backend.config.io);
        connection.deinit();
    }
};

fn perform(
    connection: *Backend.Connection,
    allocator: std.mem.Allocator,
    bytes: []const u8,
    timeout_ms: u32,
    cancellation: connector.Cancellation,
    notification: bool,
) PerformOutcome {
    const endpoint = connection.backend.config.endpoint;
    return endpoint.perform_fn(endpoint.context, allocator, .{
        .purpose = connection.purpose,
        .era = connection.era,
        .session_token = connection.session_token,
        .body = bytes,
        .timeout_ms = timeout_ms,
        .max_response_bytes = connection.backend.config.max_response_bytes,
        .cancellation = cancellation,
        .notification = notification,
    });
}

fn acceptRequest(
    connection: *Backend.Connection,
    allocator: std.mem.Allocator,
    response: Response,
) connector.ExchangeOutcome {
    if (response.body.len > connection.backend.config.max_response_bytes) {
        secureFree(allocator, response.body);
        return poisonExchange(connection, .fatal);
    }
    if (response.status == 401 or response.status == 403) {
        secureFree(allocator, response.body);
        return poisonExchange(connection, .auth);
    }
    if (response.status < 200 or response.status >= 300) {
        secureFree(allocator, response.body);
        return poisonExchange(connection, .server);
    }
    if (response.body.len == 0 or
        !acceptSessionToken(connection, response.session_token))
    {
        secureFree(allocator, response.body);
        return poisonExchange(connection, .fatal);
    }
    return .{ .response = response.body };
}

fn acceptNotification(
    connection: *Backend.Connection,
    allocator: std.mem.Allocator,
    response: Response,
) ?connector.Failure {
    defer secureFree(allocator, response.body);
    if (response.body.len > connection.backend.config.max_response_bytes)
        return poisonNotification(connection, .fatal);
    if (response.status == 401 or response.status == 403)
        return poisonNotification(connection, .auth);
    if (response.status != 202 or response.body.len != 0)
        return poisonNotification(connection, .server);
    if (!acceptSessionToken(connection, response.session_token))
        return poisonNotification(connection, .fatal);
    return null;
}

fn acceptSessionToken(
    connection: *Backend.Connection,
    token: []const u8,
) bool {
    if (token.len == 0) return true;
    if (token.len > connection.backend.config.max_session_token_bytes or
        !visibleAscii(token)) return false;
    if (connection.session_token.len != 0)
        return std.mem.eql(u8, connection.session_token, token);
    connection.session_token = connection.backend.config.allocator.dupe(
        u8,
        token,
    ) catch return false;
    return true;
}

fn poisonExchange(
    connection: *Backend.Connection,
    failure: PortFailure,
) connector.ExchangeOutcome {
    connection.poisoned = true;
    return .{ .failure = mapFailure(failure) };
}

fn poisonNotification(
    connection: *Backend.Connection,
    failure: PortFailure,
) connector.Failure {
    connection.poisoned = true;
    return mapFailure(failure);
}

fn mapFailure(failure: PortFailure) connector.Failure {
    return switch (failure) {
        .timeout => .timeout,
        .network => .network,
        .auth => .auth,
        .server => .server,
        .cancelled => .cancelled,
        .indeterminate => .indeterminate,
        .fatal => .fatal,
    };
}

fn visibleAscii(bytes: []const u8) bool {
    for (bytes) |byte| if (byte < 0x21 or byte > 0x7e) return false;
    return true;
}

const max_session_token_bytes: usize = 16 * 1024;

fn secureFree(allocator: std.mem.Allocator, bytes: []u8) void {
    if (bytes.len == 0) return;
    std.crypto.secureZero(u8, bytes);
    allocator.free(bytes);
}

fn incrementBounded(counter: *std.atomic.Value(usize), limit: usize) bool {
    var current = counter.load(.acquire);
    while (current < limit) {
        if (counter.cmpxchgWeak(
            current,
            current + 1,
            .acq_rel,
            .acquire,
        )) |observed| {
            current = observed;
        } else return true;
    }
    return false;
}

fn releaseCounter(counter: *std.atomic.Value(usize)) void {
    const previous = counter.fetchSub(1, .acq_rel);
    if (previous == 0) @panic("MCP HTTP connection reference underflow");
}

const FakeEndpoint = struct {
    valid: bool = true,
    failure: ?PortFailure = null,
    status: u16 = 200,
    session_token: []const u8 = &.{},
    empty_body: bool = false,
    calls: usize = 0,
    saw_notification: bool = false,
    closes: usize = 0,

    fn capability(self: *FakeEndpoint) AuthorizedEndpoint {
        return .{
            .context = self,
            .validate_fn = validate,
            .perform_fn = performRequest,
            .close_fn = close,
        };
    }

    fn validate(context: *anyopaque) bool {
        const self: *FakeEndpoint = @ptrCast(@alignCast(context));
        return self.valid;
    }

    fn performRequest(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        request_value: Request,
    ) PerformOutcome {
        const self: *FakeEndpoint = @ptrCast(@alignCast(context));
        self.calls += 1;
        self.saw_notification = request_value.notification;
        if (self.failure) |failure| return .{ .failure = failure };
        const body = if (request_value.notification or self.empty_body)
            allocator.alloc(u8, 0) catch return .{ .failure = .fatal }
        else
            allocator.dupe(u8, request_value.body) catch
                return .{ .failure = .fatal };
        return .{ .response = .{
            .body = body,
            .status = if (request_value.notification) 202 else self.status,
            .session_token = self.session_token,
        } };
    }

    fn close(
        context: *anyopaque,
        _: connector.Era,
        _: []const u8,
    ) void {
        const self: *FakeEndpoint = @ptrCast(@alignCast(context));
        self.closes += 1;
    }
};

test "HTTP endpoint capability is validated and connection count is bounded" {
    var invalid: FakeEndpoint = .{ .valid = false };
    try std.testing.expectError(error.InvalidConfig, Backend.init(.{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .endpoint = invalid.capability(),
    }));
    var endpoint: FakeEndpoint = .{};
    var backend = try Backend.init(.{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .endpoint = endpoint.capability(),
        .max_connections = 1,
    });
    defer backend.deinit() catch unreachable;
    const transport = backend.transport();
    const connection = switch (transport.open_fn(
        transport.context,
        .actual,
        .modern_2026_07_28,
        1000,
    )) {
        .connection => |value| value,
        .failure => return error.TestUnexpectedResult,
    };
    switch (transport.open_fn(
        transport.context,
        .actual,
        .modern_2026_07_28,
        1000,
    )) {
        .failure => |failure| try std.testing.expectEqual(
            connector.Failure.fatal,
            failure,
        ),
        .connection => |extra| {
            transport.close_fn(extra);
            return error.TestUnexpectedResult;
        },
    }
    transport.close_fn(connection);
    try std.testing.expectEqual(@as(usize, 1), endpoint.closes);
}

test "HTTP request and notification preserve opaque bytes and session token" {
    var endpoint: FakeEndpoint = .{ .session_token = "session-1" };
    var backend = try Backend.init(.{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .endpoint = endpoint.capability(),
    });
    defer backend.deinit() catch unreachable;
    const transport = backend.transport();
    const connection = switch (transport.open_fn(
        transport.context,
        .actual,
        .compat_2025_11_25,
        1000,
    )) {
        .connection => |value| value,
        .failure => return error.TestUnexpectedResult,
    };
    defer transport.close_fn(connection);
    const response = switch (transport.request_fn(
        connection,
        std.testing.allocator,
        "opaque-request",
        1000,
        .{},
    )) {
        .response => |value| value,
        .failure => return error.TestUnexpectedResult,
    };
    defer std.testing.allocator.free(response);
    try std.testing.expectEqualStrings("opaque-request", response);
    try std.testing.expectEqual(
        @as(?connector.Failure, null),
        transport.notify_fn(connection, "opaque-notify", 1000, .{}),
    );
    try std.testing.expect(endpoint.saw_notification);
}

test "HTTP failures map exactly and poison an indeterminate connection" {
    var endpoint: FakeEndpoint = .{ .failure = .indeterminate };
    var backend = try Backend.init(.{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .endpoint = endpoint.capability(),
    });
    defer backend.deinit() catch unreachable;
    const transport = backend.transport();
    const connection = switch (transport.open_fn(
        transport.context,
        .actual,
        .modern_2026_07_28,
        1000,
    )) {
        .connection => |value| value,
        .failure => return error.TestUnexpectedResult,
    };
    defer transport.close_fn(connection);
    switch (transport.request_fn(
        connection,
        std.testing.allocator,
        "opaque",
        1000,
        .{},
    )) {
        .failure => |failure| try std.testing.expectEqual(
            connector.Failure.indeterminate,
            failure,
        ),
        .response => |response| {
            std.testing.allocator.free(response);
            return error.TestUnexpectedResult;
        },
    }
    try std.testing.expectEqual(
        @as(?connector.Failure, .fatal),
        transport.notify_fn(connection, "opaque", 1000, .{}),
    );
    try std.testing.expectEqual(@as(usize, 1), endpoint.calls);
}

test "HTTP empty authorization failure preserves auth status" {
    var endpoint: FakeEndpoint = .{ .status = 401, .empty_body = true };
    var backend = try Backend.init(.{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .endpoint = endpoint.capability(),
    });
    defer backend.deinit() catch unreachable;
    const transport = backend.transport();
    const connection = switch (transport.open_fn(
        transport.context,
        .actual,
        .modern_2026_07_28,
        1000,
    )) {
        .connection => |value| value,
        .failure => return error.TestUnexpectedResult,
    };
    defer transport.close_fn(connection);
    switch (transport.request_fn(
        connection,
        std.testing.allocator,
        "opaque",
        1000,
        .{},
    )) {
        .failure => |failure| try std.testing.expectEqual(
            connector.Failure.auth,
            failure,
        ),
        .response => |response| {
            std.testing.allocator.free(response);
            return error.TestUnexpectedResult;
        },
    }
}
