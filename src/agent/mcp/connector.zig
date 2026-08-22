//! Agent-private adapter from MetaWork Host transport capabilities to the
//! canonical AgentCore MCP connector ABI. This module maps ownership and
//! status only; MCP protocol parsing and negotiation remain inside AgentCore.

const std = @import("std");
const sdk = @import("metask_agentcore");
const wire = sdk.types;

pub const Purpose = enum {
    disposable_probe,
    actual,
};

pub const Era = enum {
    modern_2026_07_28,
    compat_2025_11_25,
    compat_2025_06_18,
};

pub const Failure = enum {
    timeout,
    network,
    auth,
    server,
    child_exit,
    cancelled,
    indeterminate,
    fatal,
};

pub const Cancellation = struct {
    context: ?*const anyopaque = null,
    is_cancelled_fn: *const fn (?*const anyopaque) bool = neverCancelled,

    pub fn isCancelled(self: Cancellation) bool {
        return self.is_cancelled_fn(self.context);
    }

    fn neverCancelled(_: ?*const anyopaque) bool {
        return false;
    }
};

pub const OpenOutcome = union(enum) {
    connection: *anyopaque,
    failure: Failure,
};

pub const ExchangeResponse = struct {
    /// Stdio uses zero. Streamable HTTP reports the complete final response
    /// status so AgentCore can own protocol negotiation and classification.
    http_status: u32,
    /// Non-empty bytes must be allocated with the allocator passed to the
    /// transport callback. HTTP responses may use the canonical empty slice.
    body: []u8,
};

/// A successful response transfers any non-empty body allocation to Adapter
/// and then to AgentCore.
pub const ExchangeOutcome = union(enum) {
    response: ExchangeResponse,
    failure: Failure,
};

/// The concrete stdio and HTTP implementations satisfy this capability. The
/// context and every returned connection remain valid until their matching
/// close callback. Request bytes and Cancellation are callback-scoped borrows
/// and must not be retained after request_fn or notify_fn returns. Adapter does
/// not own or destroy `context`.
pub const Transport = struct {
    context: *anyopaque,
    open_fn: *const fn (*anyopaque, Purpose, Era, u32) OpenOutcome,
    request_fn: *const fn (
        *anyopaque,
        std.mem.Allocator,
        []const u8,
        u32,
        Cancellation,
    ) ExchangeOutcome,
    notify_fn: *const fn (
        *anyopaque,
        []const u8,
        u32,
        Cancellation,
    ) ?Failure,
    close_fn: *const fn (*anyopaque) void,
};

/// Linear owner for one concrete transport context. The transport callbacks
/// borrow `context`; Agent Runtime takes this owner before publishing the
/// connector descriptor and releases it only after every adapter connection
/// has quiesced.
pub const TransportOwner = struct {
    transport: Transport,
    deinit_fn: *const fn (*anyopaque) void,

    pub fn init(
        transport: Transport,
        deinit_fn: *const fn (*anyopaque) void,
    ) TransportOwner {
        return .{ .transport = transport, .deinit_fn = deinit_fn };
    }

    pub fn take(self: *TransportOwner) TransportOwner {
        const moved = self.*;
        self.* = undefined;
        return moved;
    }

    pub fn deinit(self: *TransportOwner) void {
        self.deinit_fn(self.transport.context);
        self.* = undefined;
    }
};

pub const Limits = struct {
    max_secrets: usize = 128,
    max_secret_bytes: usize = 16 * 1024,
    max_response_bytes: usize = @intCast(wire.MAX_MCP_FRAME_BYTES_V1),
};

pub const Config = struct {
    transport: Transport,
    secrets: []const []const u8 = &.{},
    limits: Limits = .{},
};

pub const Error = error{
    InvalidConfig,
};

pub const Adapter = struct {
    allocator: std.mem.Allocator,
    transport: Transport,
    secrets: [][]u8,
    max_response_bytes: usize,
    active_connections: std.atomic.Value(usize) = .init(0),
    connector_references: std.atomic.Value(usize) = .init(1),

    pub fn init(
        allocator: std.mem.Allocator,
        config: Config,
    ) (Error || std.mem.Allocator.Error)!Adapter {
        try validateConfig(config);
        const secrets = try allocator.alloc([]u8, config.secrets.len);
        var initialized: usize = 0;
        errdefer {
            for (secrets[0..initialized]) |secret| {
                std.crypto.secureZero(u8, secret);
                allocator.free(secret);
            }
            allocator.free(secrets);
        }
        for (config.secrets, secrets) |source, *target| {
            target.* = try allocator.dupe(u8, source);
            initialized += 1;
        }
        return .{
            .allocator = allocator,
            .transport = config.transport,
            .secrets = secrets,
            .max_response_bytes = config.limits.max_response_bytes,
        };
    }

    pub fn deinit(self: *Adapter) error{ ConnectionsActive, ConnectorRetained }!void {
        if (self.active_connections.load(.acquire) != 0)
            return error.ConnectionsActive;
        if (self.connector_references.load(.acquire) != 1)
            return error.ConnectorRetained;
        for (self.secrets) |secret| {
            std.crypto.secureZero(u8, secret);
            self.allocator.free(secret);
        }
        self.allocator.free(self.secrets);
        self.* = undefined;
    }

    pub fn isQuiescent(self: *const Adapter) bool {
        return self.active_connections.load(.acquire) == 0 and
            self.connector_references.load(.acquire) == 1;
    }

    pub fn descriptor(self: *Adapter) wire.McpConnectorV1 {
        return .{
            .struct_size = @sizeOf(wire.McpConnectorV1),
            .reserved0 = 0,
            .ctx = self,
            .open = open,
            .request = request,
            .notify = notify,
            .close = close,
            .release_response = releaseResponse,
            .retain_connector = retainConnector,
            .release_connector = releaseConnector,
            .reserved = [_]u64{0},
        };
    }

    fn retainConnector(context: ?*anyopaque) callconv(.c) void {
        const self: *Adapter = @ptrCast(@alignCast(
            context orelse @panic("AgentCore retained a null MCP connector"),
        ));
        const previous = self.connector_references.fetchAdd(1, .acq_rel);
        if (previous == 0 or previous == std.math.maxInt(usize))
            @panic("AgentCore MCP connector retain overflow");
    }

    fn releaseConnector(context: ?*anyopaque) callconv(.c) void {
        const self: *Adapter = @ptrCast(@alignCast(
            context orelse @panic("AgentCore released a null MCP connector"),
        ));
        const previous = self.connector_references.fetchSub(1, .acq_rel);
        if (previous <= 1)
            @panic("AgentCore released an unretained MCP connector");
    }

    fn containsSecret(self: *const Adapter, bytes: []const u8) bool {
        for (self.secrets) |secret| {
            if (std.mem.indexOf(u8, bytes, secret) != null) return true;
        }
        return false;
    }

    fn discardResponse(self: *Adapter, response: []u8) void {
        std.crypto.secureZero(u8, response);
        self.allocator.free(response);
    }

    const Connection = struct {
        adapter: *Adapter,
        backend: *anyopaque,
    };

    fn open(
        context: ?*anyopaque,
        purpose_code: u32,
        era_code: u32,
        timeout_ms: u32,
        out_connection: ?*?*anyopaque,
    ) callconv(.c) u32 {
        const output = out_connection orelse return wire.MCP_OPEN_FATAL;
        output.* = null;
        const self: *Adapter = @ptrCast(@alignCast(
            context orelse return wire.MCP_OPEN_FATAL,
        ));
        if (timeout_ms == 0) return wire.MCP_OPEN_FATAL;
        const purpose: Purpose = switch (purpose_code) {
            wire.MCP_CONNECTION_DISPOSABLE_PROBE => .disposable_probe,
            wire.MCP_CONNECTION_ACTUAL => .actual,
            else => return wire.MCP_OPEN_FATAL,
        };
        const era: Era = switch (era_code) {
            wire.MCP_ERA_2026_07_28 => .modern_2026_07_28,
            wire.MCP_ERA_2025_11_25 => .compat_2025_11_25,
            wire.MCP_ERA_2025_06_18 => .compat_2025_06_18,
            else => return wire.MCP_OPEN_FATAL,
        };
        return switch (self.transport.open_fn(
            self.transport.context,
            purpose,
            era,
            timeout_ms,
        )) {
            .failure => |failure| mapOpenFailure(failure),
            .connection => |backend| result: {
                const connection = self.allocator.create(Connection) catch {
                    self.transport.close_fn(backend);
                    break :result wire.MCP_OPEN_FATAL;
                };
                if (!retainConnection(&self.active_connections)) {
                    self.allocator.destroy(connection);
                    self.transport.close_fn(backend);
                    break :result wire.MCP_OPEN_FATAL;
                }
                connection.* = .{ .adapter = self, .backend = backend };
                output.* = connection;
                break :result wire.MCP_OPEN_OK;
            },
        };
    }

    fn request(
        context: ?*anyopaque,
        connection_context: ?*anyopaque,
        request_json: wire.BytesViewV1,
        timeout_ms: u32,
        raw_cancellation: ?*const wire.McpCancellationV1,
        out_response: ?*wire.McpResponseV1,
    ) callconv(.c) u32 {
        const output = out_response orelse return wire.MCP_EXCHANGE_FATAL;
        output.* = emptyMcpResponse();
        const self: *Adapter = @ptrCast(@alignCast(
            context orelse return wire.MCP_EXCHANGE_FATAL,
        ));
        const connection: *Connection = @ptrCast(@alignCast(
            connection_context orelse return wire.MCP_EXCHANGE_FATAL,
        ));
        if (connection.adapter != self or timeout_ms == 0)
            return wire.MCP_EXCHANGE_FATAL;
        const encoded = borrowedBytes(request_json) orelse
            return wire.MCP_EXCHANGE_FATAL;
        if (self.containsSecret(encoded)) return wire.MCP_EXCHANGE_FATAL;
        var bridge: CancellationBridge = undefined;
        const cancellation = makeCancellation(raw_cancellation, &bridge) catch
            return wire.MCP_EXCHANGE_FATAL;
        if (cancellation.isCancelled()) return wire.MCP_EXCHANGE_CANCELLED;
        return switch (self.transport.request_fn(
            connection.backend,
            self.allocator,
            encoded,
            timeout_ms,
            cancellation,
        )) {
            .failure => |failure| mapExchangeFailure(failure),
            .response => |response| result: {
                const body = response.body;
                const valid_status = response.http_status == 0 or
                    (response.http_status >= 100 and response.http_status <= 599);
                const valid_body = body.len <= self.max_response_bytes and
                    (response.http_status != 0 or body.len != 0);
                if (!valid_status or !valid_body or self.containsSecret(body)) {
                    if (body.len != 0) self.discardResponse(body);
                    break :result wire.MCP_EXCHANGE_FATAL;
                }
                output.http_status = response.http_status;
                if (body.len != 0)
                    output.body = .{ .ptr = body.ptr, .len = body.len };
                break :result wire.MCP_EXCHANGE_RESPONSE;
            },
        };
    }

    fn notify(
        context: ?*anyopaque,
        connection_context: ?*anyopaque,
        notification_json: wire.BytesViewV1,
        timeout_ms: u32,
        raw_cancellation: ?*const wire.McpCancellationV1,
    ) callconv(.c) u32 {
        const self: *Adapter = @ptrCast(@alignCast(
            context orelse return wire.MCP_NOTIFY_FAILED,
        ));
        const connection: *Connection = @ptrCast(@alignCast(
            connection_context orelse return wire.MCP_NOTIFY_FAILED,
        ));
        if (connection.adapter != self or timeout_ms == 0)
            return wire.MCP_NOTIFY_FAILED;
        const encoded = borrowedBytes(notification_json) orelse
            return wire.MCP_NOTIFY_FAILED;
        if (self.containsSecret(encoded)) return wire.MCP_NOTIFY_FAILED;
        var bridge: CancellationBridge = undefined;
        const cancellation = makeCancellation(raw_cancellation, &bridge) catch
            return wire.MCP_NOTIFY_FAILED;
        if (cancellation.isCancelled()) return wire.MCP_NOTIFY_FAILED;
        if (self.transport.notify_fn(
            connection.backend,
            encoded,
            timeout_ms,
            cancellation,
        )) |failure| return mapNotifyFailure(failure);
        return wire.MCP_NOTIFY_OK;
    }

    fn close(
        context: ?*anyopaque,
        connection_context: ?*anyopaque,
    ) callconv(.c) void {
        const self: *Adapter = @ptrCast(@alignCast(context orelse return));
        const connection: *Connection = @ptrCast(@alignCast(
            connection_context orelse return,
        ));
        if (connection.adapter != self) return;
        self.transport.close_fn(connection.backend);
        self.allocator.destroy(connection);
        releaseConnection(&self.active_connections);
    }

    fn releaseResponse(
        context: ?*anyopaque,
        _: ?*anyopaque,
        response: ?*wire.OwnedBytesV1,
    ) callconv(.c) void {
        const self: *Adapter = @ptrCast(@alignCast(context orelse return));
        const value = response orelse return;
        const len = std.math.cast(usize, value.len) orelse {
            value.* = emptyOwnedBytes();
            return;
        };
        const pointer = value.ptr orelse {
            value.* = emptyOwnedBytes();
            return;
        };
        const storage = pointer[0..len];
        self.discardResponse(storage);
        value.* = emptyOwnedBytes();
    }
};

fn validateConfig(config: Config) Error!void {
    if (config.limits.max_secrets == 0 or
        config.limits.max_secret_bytes == 0 or
        config.limits.max_response_bytes == 0 or
        config.limits.max_response_bytes > wire.MAX_MCP_FRAME_BYTES_V1 or
        config.secrets.len > config.limits.max_secrets)
        return error.InvalidConfig;
    var total: usize = 0;
    for (config.secrets, 0..) |secret, index| {
        if (secret.len == 0) return error.InvalidConfig;
        total = std.math.add(usize, total, secret.len) catch
            return error.InvalidConfig;
        if (total > config.limits.max_secret_bytes) return error.InvalidConfig;
        for (config.secrets[0..index]) |previous| {
            if (std.mem.eql(u8, previous, secret)) return error.InvalidConfig;
        }
    }
}

const CancellationBridge = struct {
    raw: *const wire.McpCancellationV1,

    fn isCancelled(context: ?*const anyopaque) bool {
        const self: *const CancellationBridge = @ptrCast(@alignCast(
            context orelse return true,
        ));
        return self.raw.is_cancelled.?(self.raw.ctx) != 0;
    }
};

fn makeCancellation(
    raw: ?*const wire.McpCancellationV1,
    bridge: *CancellationBridge,
) error{InvalidCancellation}!Cancellation {
    const value = raw orelse return .{};
    if (value.struct_size != @sizeOf(wire.McpCancellationV1) or
        value.reserved0 != 0 or value.is_cancelled == null or
        !allZero(&value.reserved))
        return error.InvalidCancellation;
    bridge.* = .{ .raw = value };
    return .{ .context = bridge, .is_cancelled_fn = CancellationBridge.isCancelled };
}

fn borrowedBytes(view: wire.BytesViewV1) ?[]const u8 {
    const len = std.math.cast(usize, view.len) orelse return null;
    if (len == 0) return &.{};
    const pointer = view.ptr orelse return null;
    return pointer[0..len];
}

fn emptyOwnedBytes() wire.OwnedBytesV1 {
    return .{ .ptr = null, .len = 0 };
}

fn emptyMcpResponse() wire.McpResponseV1 {
    return .{
        .struct_size = @sizeOf(wire.McpResponseV1),
        .http_status = 0,
        .body = emptyOwnedBytes(),
        .reserved = [_]u64{0} ** 2,
    };
}

fn mapOpenFailure(failure: Failure) u32 {
    return switch (failure) {
        .timeout => wire.MCP_OPEN_TIMEOUT,
        .network => wire.MCP_OPEN_NETWORK_ERROR,
        .auth => wire.MCP_OPEN_AUTH_ERROR,
        .server => wire.MCP_OPEN_SERVER_ERROR,
        .child_exit => wire.MCP_OPEN_CHILD_EXIT,
        .cancelled, .indeterminate, .fatal => wire.MCP_OPEN_FATAL,
    };
}

fn mapExchangeFailure(failure: Failure) u32 {
    return switch (failure) {
        .timeout => wire.MCP_EXCHANGE_TIMEOUT,
        .network => wire.MCP_EXCHANGE_NETWORK_ERROR,
        .auth => wire.MCP_EXCHANGE_AUTH_ERROR,
        .server => wire.MCP_EXCHANGE_SERVER_ERROR,
        .child_exit => wire.MCP_EXCHANGE_CHILD_EXIT,
        .cancelled => wire.MCP_EXCHANGE_CANCELLED,
        .indeterminate => wire.MCP_EXCHANGE_INDETERMINATE,
        .fatal => wire.MCP_EXCHANGE_FATAL,
    };
}

fn mapNotifyFailure(failure: Failure) u32 {
    _ = failure;
    return wire.MCP_NOTIFY_FAILED;
}

fn retainConnection(counter: *std.atomic.Value(usize)) bool {
    var current = counter.load(.acquire);
    while (current != std.math.maxInt(usize)) {
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

fn releaseConnection(counter: *std.atomic.Value(usize)) void {
    const previous = counter.fetchSub(1, .acq_rel);
    if (previous == 0) @panic("MCP connector connection reference underflow");
}

fn allZero(values: []const u64) bool {
    for (values) |value| if (value != 0) return false;
    return true;
}

const FakeTransport = struct {
    response: []const u8 = "{\"ok\":true}",
    http_status: u32 = 0,
    open_failure: ?Failure = null,
    request_failure: ?Failure = null,
    notify_failure: ?Failure = null,
    opens: usize = 0,
    requests: usize = 0,
    notifications: usize = 0,
    closes: usize = 0,

    fn capability(self: *FakeTransport) Transport {
        return .{
            .context = self,
            .open_fn = open,
            .request_fn = request,
            .notify_fn = notify,
            .close_fn = close,
        };
    }

    fn open(
        context: *anyopaque,
        _: Purpose,
        _: Era,
        _: u32,
    ) OpenOutcome {
        const self: *FakeTransport = @ptrCast(@alignCast(context));
        self.opens += 1;
        if (self.open_failure) |failure| return .{ .failure = failure };
        return .{ .connection = self };
    }

    fn request(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        _: []const u8,
        _: u32,
        _: Cancellation,
    ) ExchangeOutcome {
        const self: *FakeTransport = @ptrCast(@alignCast(context));
        self.requests += 1;
        if (self.request_failure) |failure| return .{ .failure = failure };
        const response = if (self.response.len == 0)
            @constCast(&[_]u8{})
        else
            allocator.dupe(u8, self.response) catch
                return .{ .failure = .fatal };
        return .{ .response = .{
            .http_status = self.http_status,
            .body = response,
        } };
    }

    fn notify(
        context: *anyopaque,
        _: []const u8,
        _: u32,
        _: Cancellation,
    ) ?Failure {
        const self: *FakeTransport = @ptrCast(@alignCast(context));
        self.notifications += 1;
        return self.notify_failure;
    }

    fn close(context: *anyopaque) void {
        const self: *FakeTransport = @ptrCast(@alignCast(context));
        self.closes += 1;
    }
};

fn openTestConnection(descriptor: wire.McpConnectorV1) !*anyopaque {
    var connection: ?*anyopaque = null;
    try std.testing.expectEqual(
        wire.MCP_OPEN_OK,
        descriptor.open.?(
            descriptor.ctx,
            wire.MCP_CONNECTION_ACTUAL,
            wire.MCP_ERA_2026_07_28,
            1000,
            &connection,
        ),
    );
    return connection.?;
}

test "adapter exports the complete official connector descriptor" {
    var fake = FakeTransport{};
    var adapter = try Adapter.init(std.testing.allocator, .{
        .transport = fake.capability(),
    });
    defer adapter.deinit() catch unreachable;
    const descriptor = adapter.descriptor();
    try std.testing.expectEqual(@as(u32, @sizeOf(wire.McpConnectorV1)), descriptor.struct_size);
    try std.testing.expectEqual(@as(u32, 0), descriptor.reserved0);
    try std.testing.expect(descriptor.ctx != null);
    try std.testing.expect(descriptor.open != null);
    try std.testing.expect(descriptor.request != null);
    try std.testing.expect(descriptor.notify != null);
    try std.testing.expect(descriptor.close != null);
    try std.testing.expect(descriptor.release_response != null);
    try std.testing.expect(descriptor.retain_connector != null);
    try std.testing.expect(descriptor.release_connector != null);
    try std.testing.expectEqual([_]u64{0}, descriptor.reserved);
}

test "response ownership transfers once and release clears the descriptor" {
    var fake = FakeTransport{};
    var adapter = try Adapter.init(std.testing.allocator, .{
        .transport = fake.capability(),
    });
    const descriptor = adapter.descriptor();
    const connection = try openTestConnection(descriptor);
    var response = emptyMcpResponse();
    try std.testing.expectEqual(
        wire.MCP_EXCHANGE_RESPONSE,
        descriptor.request.?(
            descriptor.ctx,
            connection,
            sdk.bytesView("{\"jsonrpc\":\"2.0\"}"),
            1000,
            null,
            &response,
        ),
    );
    const response_len: usize = @intCast(response.body.len);
    try std.testing.expectEqual(@as(u32, 0), response.http_status);
    try std.testing.expectEqual(@as(u32, @sizeOf(wire.McpResponseV1)), response.struct_size);
    try std.testing.expectEqual([_]u64{0} ** 2, response.reserved);
    try std.testing.expectEqualStrings(fake.response, response.body.ptr.?[0..response_len]);
    descriptor.release_response.?(descriptor.ctx, connection, &response.body);
    try std.testing.expect(response.body.ptr == null);
    try std.testing.expectEqual(@as(u64, 0), response.body.len);
    descriptor.release_response.?(descriptor.ctx, connection, &response.body);
    descriptor.close.?(descriptor.ctx, connection);
    try adapter.deinit();
    try std.testing.expectEqual(@as(usize, 1), fake.requests);
    try std.testing.expectEqual(@as(usize, 1), fake.closes);
}

test "complete HTTP response preserves status and permits an empty body" {
    var fake = FakeTransport{ .response = "", .http_status = 400 };
    var adapter = try Adapter.init(std.testing.allocator, .{
        .transport = fake.capability(),
    });
    const descriptor = adapter.descriptor();
    const connection = try openTestConnection(descriptor);
    var response = emptyMcpResponse();
    try std.testing.expectEqual(
        wire.MCP_EXCHANGE_RESPONSE,
        descriptor.request.?(
            descriptor.ctx,
            connection,
            sdk.bytesView("{}"),
            1000,
            null,
            &response,
        ),
    );
    try std.testing.expectEqual(@as(u32, 400), response.http_status);
    try std.testing.expect(response.body.ptr == null);
    try std.testing.expectEqual(@as(u64, 0), response.body.len);
    descriptor.close.?(descriptor.ctx, connection);
    try adapter.deinit();
}

test "secret guard rejects outbound and inbound protocol bytes" {
    var fake = FakeTransport{};
    const secrets = [_][]const u8{"top-secret"};
    var adapter = try Adapter.init(std.testing.allocator, .{
        .transport = fake.capability(),
        .secrets = &secrets,
    });
    const descriptor = adapter.descriptor();
    const connection = try openTestConnection(descriptor);
    var response = emptyMcpResponse();
    try std.testing.expectEqual(
        wire.MCP_EXCHANGE_FATAL,
        descriptor.request.?(
            descriptor.ctx,
            connection,
            sdk.bytesView("{\"value\":\"top-secret\"}"),
            1000,
            null,
            &response,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), fake.requests);
    try std.testing.expectEqual(
        wire.MCP_NOTIFY_FAILED,
        descriptor.notify.?(
            descriptor.ctx,
            connection,
            sdk.bytesView("top-secret"),
            1000,
            null,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), fake.notifications);

    fake.response = "{\"value\":\"top-secret\"}";
    try std.testing.expectEqual(
        wire.MCP_EXCHANGE_FATAL,
        descriptor.request.?(
            descriptor.ctx,
            connection,
            sdk.bytesView("{\"safe\":true}"),
            1000,
            null,
            &response,
        ),
    );
    try std.testing.expect(response.body.ptr == null);
    descriptor.close.?(descriptor.ctx, connection);
    try adapter.deinit();
}

test "empty and oversized responses fail closed without leaking ownership" {
    var fake = FakeTransport{ .response = "" };
    var adapter = try Adapter.init(std.testing.allocator, .{
        .transport = fake.capability(),
        .limits = .{ .max_response_bytes = 4 },
    });
    const descriptor = adapter.descriptor();
    const connection = try openTestConnection(descriptor);
    var response = emptyMcpResponse();
    try std.testing.expectEqual(
        wire.MCP_EXCHANGE_FATAL,
        descriptor.request.?(
            descriptor.ctx,
            connection,
            sdk.bytesView("{}"),
            1000,
            null,
            &response,
        ),
    );
    try std.testing.expect(response.body.ptr == null);
    fake.response = "12345";
    try std.testing.expectEqual(
        wire.MCP_EXCHANGE_FATAL,
        descriptor.request.?(
            descriptor.ctx,
            connection,
            sdk.bytesView("{}"),
            1000,
            null,
            &response,
        ),
    );
    try std.testing.expect(response.body.ptr == null);
    descriptor.close.?(descriptor.ctx, connection);
    try adapter.deinit();
}

test "official failure and cancellation statuses are preserved" {
    var fake = FakeTransport{ .open_failure = .auth };
    var adapter = try Adapter.init(std.testing.allocator, .{
        .transport = fake.capability(),
    });
    const descriptor = adapter.descriptor();
    var raw_connection: ?*anyopaque = null;
    try std.testing.expectEqual(
        wire.MCP_OPEN_AUTH_ERROR,
        descriptor.open.?(
            descriptor.ctx,
            wire.MCP_CONNECTION_ACTUAL,
            wire.MCP_ERA_2025_11_25,
            1000,
            &raw_connection,
        ),
    );
    fake.open_failure = null;
    const connection = try openTestConnection(descriptor);
    fake.request_failure = .indeterminate;
    var response = emptyMcpResponse();
    try std.testing.expectEqual(
        wire.MCP_EXCHANGE_INDETERMINATE,
        descriptor.request.?(
            descriptor.ctx,
            connection,
            sdk.bytesView("{}"),
            1000,
            null,
            &response,
        ),
    );
    fake.notify_failure = .network;
    try std.testing.expectEqual(
        wire.MCP_NOTIFY_FAILED,
        descriptor.notify.?(
            descriptor.ctx,
            connection,
            sdk.bytesView("{}"),
            1000,
            null,
        ),
    );
    descriptor.close.?(descriptor.ctx, connection);
    try adapter.deinit();
}

test "active connection prevents adapter destruction" {
    var fake = FakeTransport{};
    var adapter = try Adapter.init(std.testing.allocator, .{
        .transport = fake.capability(),
    });
    const descriptor = adapter.descriptor();
    const connection = try openTestConnection(descriptor);
    try std.testing.expectError(error.ConnectionsActive, adapter.deinit());
    descriptor.close.?(descriptor.ctx, connection);
    try adapter.deinit();
}

test "AgentCore connector retains block owner destruction until release" {
    var fake = FakeTransport{};
    var adapter = try Adapter.init(std.testing.allocator, .{
        .transport = fake.capability(),
    });
    const descriptor = adapter.descriptor();
    descriptor.retain_connector.?(descriptor.ctx);
    try std.testing.expectError(error.ConnectorRetained, adapter.deinit());
    descriptor.release_connector.?(descriptor.ctx);
    try adapter.deinit();
}

test "cancelled request never reaches the backend" {
    const Cancelled = struct {
        fn yes(_: ?*const anyopaque) callconv(.c) u32 {
            return 1;
        }
    };
    var fake = FakeTransport{};
    var adapter = try Adapter.init(std.testing.allocator, .{
        .transport = fake.capability(),
    });
    const descriptor = adapter.descriptor();
    const connection = try openTestConnection(descriptor);
    var cancellation = std.mem.zeroes(wire.McpCancellationV1);
    cancellation.struct_size = @sizeOf(wire.McpCancellationV1);
    cancellation.is_cancelled = Cancelled.yes;
    var response = emptyMcpResponse();
    try std.testing.expectEqual(
        wire.MCP_EXCHANGE_CANCELLED,
        descriptor.request.?(
            descriptor.ctx,
            connection,
            sdk.bytesView("{}"),
            1000,
            &cancellation,
            &response,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), fake.requests);
    descriptor.close.?(descriptor.ctx, connection);
    try adapter.deinit();
}
