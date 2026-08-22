//! Bounded MCP stdio protocol transport over an injected process effect.
//! This module owns newline framing, response bounds, serialization, and
//! connector failure policy. The injected endpoint owns child processes,
//! pipes, stderr draining, timeout, and cancellation.

const std = @import("std");
const connector = @import("agent_mcp_connector");

pub const PortFailure = enum { timeout, child_exit, cancelled, indeterminate, fatal };
pub const SinkFlow = enum { continue_reading, stop };
pub const FeedOutcome = struct { consumed: usize, flow: SinkFlow };

/// Callback-scoped raw stdout consumer. The effect must retain any suffix
/// beyond `consumed`; it may stop pumping as soon as `flow` is `.stop`.
pub const ResponseSink = struct {
    context: *anyopaque,
    feed_fn: *const fn (*anyopaque, []const u8) FeedOutcome,
    finish_fn: *const fn (*anyopaque) SinkFlow,
};

pub const Write = struct {
    fragments: []const []const u8,
    timeout_ms: u32,
    cancellation: connector.Cancellation,
};
pub const OpenOutcome = union(enum) { connection: *anyopaque, failure: PortFailure };
pub const PerformOutcome = union(enum) { completed, failure: PortFailure };

/// Narrow process/pipe capability. Launch configuration and every returned
/// connection remain effect-owned. Arguments, fragments, cancellation, and
/// sink callbacks are borrowed only for the duration of their callback.
pub const ProcessEndpoint = struct {
    context: *anyopaque,
    validate_fn: *const fn (*anyopaque) bool,
    open_fn: *const fn (*anyopaque, u32) OpenOutcome,
    exchange_fn: *const fn (*anyopaque, *anyopaque, Write, *const ResponseSink) PerformOutcome,
    notify_fn: *const fn (*anyopaque, *anyopaque, Write) ?PortFailure,
    close_fn: *const fn (*anyopaque, *anyopaque) void,
};

pub const Config = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    endpoint: ProcessEndpoint,
    max_frame_bytes: usize = (connector.Limits{}).max_response_bytes,
    max_connections: usize = 8,
};

pub const Error = error{InvalidConfig};

pub const Backend = struct {
    config: Config,
    active_connections: std.atomic.Value(usize) = .init(0),

    pub fn init(config: Config) Error!Backend {
        if (config.max_frame_bytes == 0 or
            config.max_frame_bytes > (connector.Limits{}).max_response_bytes or
            config.max_connections == 0 or
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
        effect_connection: *anyopaque,
        mutex: std.Io.Mutex = .init,
        poisoned: bool = false,

        fn deinit(self: *Connection) void {
            const backend = self.backend;
            const endpoint = backend.config.endpoint;
            endpoint.close_fn(endpoint.context, self.effect_connection);
            backend.config.allocator.destroy(self);
            releaseCounter(&backend.active_connections);
        }
    };

    fn open(
        raw: *anyopaque,
        _: connector.Purpose,
        _: connector.Era,
        timeout_ms: u32,
    ) connector.OpenOutcome {
        const self: *Backend = @ptrCast(@alignCast(raw));
        if (timeout_ms == 0 or !incrementBounded(
            &self.active_connections,
            self.config.max_connections,
        )) return .{ .failure = .fatal };
        const endpoint = self.config.endpoint;
        const effect_connection = switch (endpoint.open_fn(endpoint.context, timeout_ms)) {
            .connection => |value| value,
            .failure => |failure| {
                releaseCounter(&self.active_connections);
                return .{ .failure = mapFailure(failure) };
            },
        };
        const connection = self.config.allocator.create(Connection) catch {
            endpoint.close_fn(endpoint.context, effect_connection);
            releaseCounter(&self.active_connections);
            return .{ .failure = .fatal };
        };
        connection.* = .{ .backend = self, .effect_connection = effect_connection };
        return .{ .connection = connection };
    }

    fn request(
        raw: *anyopaque,
        allocator: std.mem.Allocator,
        bytes: []const u8,
        timeout_ms: u32,
        cancellation: connector.Cancellation,
    ) connector.ExchangeOutcome {
        const connection: *Connection = @ptrCast(@alignCast(raw));
        const config = connection.backend.config;
        connection.mutex.lockUncancelable(config.io);
        defer connection.mutex.unlock(config.io);
        if (connection.poisoned or timeout_ms == 0) return .{ .failure = .fatal };
        if (cancellation.isCancelled()) return .{ .failure = .cancelled };
        var collector = ResponseCollector.init(allocator, config.max_frame_bytes) catch
            return poisonExchange(connection, .fatal);
        defer collector.deinit();
        const sink = collector.sink();
        const fragments = [_][]const u8{ bytes, "\n" };
        const endpoint = config.endpoint;
        switch (endpoint.exchange_fn(
            endpoint.context,
            connection.effect_connection,
            .{ .fragments = &fragments, .timeout_ms = timeout_ms, .cancellation = cancellation },
            &sink,
        )) {
            .failure => |failure| return poisonExchange(connection, failure),
            .completed => {},
        }
        if (collector.failure) |failure| return poisonExchange(connection, failure);
        if (!collector.complete or collector.output_len == 0)
            return poisonExchange(connection, .fatal);
        const response = allocator.dupe(u8, collector.output[0..collector.output_len]) catch
            return poisonExchange(connection, .fatal);
        return .{ .response = response };
    }

    fn notify(
        raw: *anyopaque,
        bytes: []const u8,
        timeout_ms: u32,
        cancellation: connector.Cancellation,
    ) ?connector.Failure {
        const connection: *Connection = @ptrCast(@alignCast(raw));
        const config = connection.backend.config;
        connection.mutex.lockUncancelable(config.io);
        defer connection.mutex.unlock(config.io);
        if (connection.poisoned or timeout_ms == 0) return .fatal;
        if (cancellation.isCancelled()) return .cancelled;
        const fragments = [_][]const u8{ bytes, "\n" };
        const endpoint = config.endpoint;
        if (endpoint.notify_fn(
            endpoint.context,
            connection.effect_connection,
            .{ .fragments = &fragments, .timeout_ms = timeout_ms, .cancellation = cancellation },
        )) |failure| return poisonNotification(connection, failure);
        return null;
    }

    fn close(raw: *anyopaque) void {
        const connection: *Connection = @ptrCast(@alignCast(raw));
        const io = connection.backend.config.io;
        connection.mutex.lockUncancelable(io);
        connection.poisoned = true;
        connection.mutex.unlock(io);
        connection.deinit();
    }
};

const ResponseCollector = struct {
    allocator: std.mem.Allocator,
    output: []u8,
    output_len: usize = 0,
    complete: bool = false,
    failure: ?PortFailure = null,

    fn init(allocator: std.mem.Allocator, max_frame_bytes: usize) std.mem.Allocator.Error!ResponseCollector {
        return .{ .allocator = allocator, .output = try allocator.alloc(u8, max_frame_bytes) };
    }

    fn deinit(self: *ResponseCollector) void {
        std.crypto.secureZero(u8, self.output);
        self.allocator.free(self.output);
        self.* = undefined;
    }

    fn sink(self: *ResponseCollector) ResponseSink {
        return .{ .context = self, .feed_fn = feed, .finish_fn = finish };
    }

    fn feed(raw: *anyopaque, bytes: []const u8) FeedOutcome {
        const self: *ResponseCollector = @ptrCast(@alignCast(raw));
        if (self.failure != null or self.complete)
            return .{ .consumed = 0, .flow = .stop };
        const delimiter = std.mem.indexOfScalar(u8, bytes, '\n');
        const payload_len = delimiter orelse bytes.len;
        const remaining = self.output.len - self.output_len;
        if (payload_len > remaining) {
            if (remaining != 0)
                @memcpy(self.output[self.output_len..], bytes[0..remaining]);
            self.output_len = self.output.len;
            self.failure = .fatal;
            return .{ .consumed = remaining, .flow = .stop };
        }
        if (payload_len != 0)
            @memcpy(self.output[self.output_len..][0..payload_len], bytes[0..payload_len]);
        self.output_len += payload_len;
        if (delimiter) |index| {
            if (self.output_len == 0) self.failure = .fatal else self.complete = true;
            return .{ .consumed = index + 1, .flow = .stop };
        }
        return .{ .consumed = bytes.len, .flow = .continue_reading };
    }

    fn finish(raw: *anyopaque) SinkFlow {
        const self: *ResponseCollector = @ptrCast(@alignCast(raw));
        if (!self.complete and self.failure == null) self.failure = .fatal;
        return .stop;
    }
};

fn poisonExchange(connection: *Backend.Connection, failure: PortFailure) connector.ExchangeOutcome {
    connection.poisoned = true;
    return .{ .failure = mapFailure(failure) };
}

fn poisonNotification(connection: *Backend.Connection, failure: PortFailure) connector.Failure {
    connection.poisoned = true;
    return mapFailure(failure);
}

fn mapFailure(failure: PortFailure) connector.Failure {
    return switch (failure) {
        .timeout => .timeout,
        .child_exit => .child_exit,
        .cancelled => .cancelled,
        .indeterminate => .indeterminate,
        .fatal => .fatal,
    };
}

fn incrementBounded(counter: *std.atomic.Value(usize), limit: usize) bool {
    var current = counter.load(.acquire);
    while (current < limit) {
        if (counter.cmpxchgWeak(current, current + 1, .acq_rel, .acquire)) |observed| {
            current = observed;
        } else return true;
    }
    return false;
}

fn releaseCounter(counter: *std.atomic.Value(usize)) void {
    const previous = counter.fetchSub(1, .acq_rel);
    if (previous == 0) @panic("MCP stdio connection reference underflow");
}

const FakeEndpoint = struct {
    valid: bool = true,
    perform_failure: ?PortFailure = null,
    response: []const u8 = "opaque-response\ntrailing",
    closes: usize = 0,
    notifications: usize = 0,
    framing_valid: bool = true,

    fn capability(self: *FakeEndpoint) ProcessEndpoint {
        return .{
            .context = self,
            .validate_fn = validate,
            .open_fn = open,
            .exchange_fn = exchange,
            .notify_fn = notify,
            .close_fn = close,
        };
    }

    fn validate(raw: *anyopaque) bool {
        const self: *FakeEndpoint = @ptrCast(@alignCast(raw));
        return self.valid;
    }

    fn open(raw: *anyopaque, _: u32) OpenOutcome {
        return .{ .connection = raw };
    }

    fn exchange(
        raw: *anyopaque,
        _: *anyopaque,
        write: Write,
        sink: *const ResponseSink,
    ) PerformOutcome {
        const self: *FakeEndpoint = @ptrCast(@alignCast(raw));
        self.checkFraming(write);
        if (self.perform_failure) |failure| return .{ .failure = failure };
        const fed = sink.feed_fn(sink.context, self.response);
        if (fed.flow == .continue_reading) _ = sink.finish_fn(sink.context);
        return .completed;
    }

    fn notify(raw: *anyopaque, _: *anyopaque, write: Write) ?PortFailure {
        const self: *FakeEndpoint = @ptrCast(@alignCast(raw));
        self.checkFraming(write);
        self.notifications += 1;
        return self.perform_failure;
    }

    fn close(raw: *anyopaque, _: *anyopaque) void {
        const self: *FakeEndpoint = @ptrCast(@alignCast(raw));
        self.closes += 1;
    }

    fn checkFraming(self: *FakeEndpoint, write: Write) void {
        self.framing_valid = self.framing_valid and
            write.fragments.len == 2 and
            std.mem.eql(u8, write.fragments[1], "\n");
    }
};

fn openTestConnection(transport: connector.Transport) !*anyopaque {
    return switch (transport.open_fn(
        transport.context,
        .actual,
        .modern_2026_07_28,
        1000,
    )) {
        .connection => |value| value,
        .failure => error.TestUnexpectedResult,
    };
}

test "stdio endpoint capability and connection count are bounded" {
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
    const connection = try openTestConnection(transport);
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

test "stdio owns newline framing and consumes exactly one response" {
    var endpoint: FakeEndpoint = .{};
    var backend = try Backend.init(.{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .endpoint = endpoint.capability(),
    });
    defer backend.deinit() catch unreachable;
    const transport = backend.transport();
    const connection = try openTestConnection(transport);
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
    try std.testing.expectEqualStrings("opaque-response", response);
    try std.testing.expectEqual(
        @as(?connector.Failure, null),
        transport.notify_fn(connection, "opaque-notify", 1000, .{}),
    );
    try std.testing.expect(endpoint.framing_valid);
    try std.testing.expectEqual(@as(usize, 1), endpoint.notifications);
}

test "stdio protocol failure poisons the connection" {
    var endpoint: FakeEndpoint = .{ .response = "toolong\n" };
    var backend = try Backend.init(.{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .endpoint = endpoint.capability(),
        .max_frame_bytes = 4,
    });
    defer backend.deinit() catch unreachable;
    const transport = backend.transport();
    const connection = try openTestConnection(transport);
    defer transport.close_fn(connection);
    switch (transport.request_fn(
        connection,
        std.testing.allocator,
        "request",
        1000,
        .{},
    )) {
        .failure => |failure| try std.testing.expectEqual(
            connector.Failure.fatal,
            failure,
        ),
        .response => |response| {
            std.testing.allocator.free(response);
            return error.TestUnexpectedResult;
        },
    }
    try std.testing.expectEqual(
        @as(?connector.Failure, .fatal),
        transport.notify_fn(connection, "notify", 1000, .{}),
    );
}
