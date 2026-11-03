//! Agent-private Streamable HTTP connector over an opaque, preauthorized
//! endpoint capability. This module owns MCP request/response headers,
//! Streamable HTTP status rules, JSON body bounds, SSE framing, session state,
//! and connector failure policy. The injected endpoint owns authorization,
//! network resources, raw byte pumping, timeout, and cancellation.

const std = @import("std");
const connector = @import("agent_mcp_connector");
const protocol = @import("agent_mcp_http_protocol");

pub const HeaderName = protocol.HeaderName;
pub const reserved_request_header_names = protocol.reserved_request_header_names;

pub const PortFailure = enum {
    timeout,
    network,
    auth,
    server,
    cancelled,
    indeterminate,
    fatal,
};

pub const Method = enum { post, delete };

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const SinkFlow = enum { continue_reading, stop };

pub const FeedOutcome = struct {
    consumed: usize,
    flow: SinkFlow,
};

/// Callback-scoped response consumer owned by Backend. Endpoint
/// implementations may invoke it only during `perform_fn`. Header and byte
/// slices are borrowed for the duration of each callback. `feed_fn` reports
/// the exact consumed prefix so reusable effects can retain trailing bytes.
pub const ResponseSink = struct {
    context: *anyopaque,
    begin_fn: *const fn (*anyopaque, u16) SinkFlow,
    header_fn: *const fn (*anyopaque, []const u8, []const u8) SinkFlow,
    end_headers_fn: *const fn (*anyopaque) SinkFlow,
    feed_fn: *const fn (*anyopaque, []const u8) FeedOutcome,
    finish_fn: *const fn (*anyopaque) SinkFlow,
};

pub const Request = struct {
    method: Method,
    headers: []const Header,
    body: []const u8,
    timeout_ms: u32,
    cancellation: connector.Cancellation,
};

pub const PerformOutcome = union(enum) {
    completed,
    failure: PortFailure,
};

/// Opaque capability for one already-authorized endpoint/header set. Its
/// context owns credentials and HTTP implementation details and must outlive
/// Backend. Request fields and ResponseSink are callback-scoped borrows. The
/// effect must quiesce every sink callback before returning.
pub const AuthorizedEndpoint = struct {
    context: *anyopaque,
    validate_fn: *const fn (*anyopaque) bool,
    perform_fn: *const fn (
        *anyopaque,
        Request,
        *const ResponseSink,
    ) PerformOutcome,
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
            closeSession(self);
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
        return performRequest(
            connection,
            allocator,
            bytes,
            timeout_ms,
            cancellation,
        );
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
        return performNotification(
            connection,
            bytes,
            timeout_ms,
            cancellation,
        );
    }

    fn close(raw_connection: *anyopaque) void {
        const connection: *Connection = @ptrCast(@alignCast(raw_connection));
        connection.mutex.lockUncancelable(connection.backend.config.io);
        connection.poisoned = true;
        connection.mutex.unlock(connection.backend.config.io);
        connection.deinit();
    }
};

const ExchangeKind = enum { request, notification, close };

fn performRequest(
    connection: *Backend.Connection,
    allocator: std.mem.Allocator,
    bytes: []const u8,
    timeout_ms: u32,
    cancellation: connector.Cancellation,
) connector.ExchangeOutcome {
    var collector = ResponseCollector.init(
        allocator,
        .request,
        connection.backend.config.max_response_bytes,
        connection.backend.config.max_session_token_bytes,
    ) catch return poisonExchange(connection, .fatal);
    defer collector.deinit();
    const port = performEffect(
        connection,
        bytes,
        timeout_ms,
        cancellation,
        &collector,
    );
    switch (port) {
        .failure => |failure| return poisonExchange(connection, failure),
        .completed => {},
    }
    if (collector.failure) |failure|
        return poisonExchange(connection, failure);
    if (!collector.complete or
        (!collector.error_status and
            !acceptSessionToken(connection, collector.sessionToken())))
        return poisonExchange(connection, .fatal);
    const body = if (collector.output_len == 0)
        @constCast(&[_]u8{})
    else
        allocator.dupe(
            u8,
            collector.output[0..collector.output_len],
        ) catch return poisonExchange(connection, .fatal);
    return .{ .response = .{
        .http_status = collector.status,
        .body = body,
    } };
}

fn performNotification(
    connection: *Backend.Connection,
    bytes: []const u8,
    timeout_ms: u32,
    cancellation: connector.Cancellation,
) ?connector.Failure {
    var collector = ResponseCollector.init(
        connection.backend.config.allocator,
        .notification,
        connection.backend.config.max_response_bytes,
        connection.backend.config.max_session_token_bytes,
    ) catch return poisonNotification(connection, .fatal);
    defer collector.deinit();
    const port = performEffect(
        connection,
        bytes,
        timeout_ms,
        cancellation,
        &collector,
    );
    switch (port) {
        .failure => |failure| return poisonNotification(connection, failure),
        .completed => {},
    }
    if (collector.failure) |failure|
        return poisonNotification(connection, failure);
    if (!collector.complete or
        !acceptSessionToken(connection, collector.sessionToken()))
        return poisonNotification(connection, .fatal);
    return null;
}

fn closeSession(connection: *Backend.Connection) void {
    if (connection.session_token.len == 0) return;
    var collector = ResponseCollector.init(
        connection.backend.config.allocator,
        .close,
        connection.backend.config.max_response_bytes,
        connection.backend.config.max_session_token_bytes,
    ) catch return;
    defer collector.deinit();
    _ = performEffect(connection, "", 1000, .{}, &collector);
}

fn performEffect(
    connection: *Backend.Connection,
    body: []const u8,
    timeout_ms: u32,
    cancellation: connector.Cancellation,
    collector: *ResponseCollector,
) PerformOutcome {
    var headers: [4]Header = undefined;
    var count: usize = 0;
    headers[count] = .{
        .name = HeaderName.accept,
        .value = "application/json, text/event-stream",
    };
    count += 1;
    headers[count] = .{
        .name = HeaderName.protocol_version,
        .value = protocolVersion(connection.era),
    };
    count += 1;
    if (collector.kind != .close) {
        headers[count] = .{ .name = HeaderName.content_type, .value = "application/json" };
        count += 1;
    }
    if (connection.session_token.len != 0) {
        headers[count] = .{
            .name = HeaderName.session_id,
            .value = connection.session_token,
        };
        count += 1;
    }
    const sink = collector.sink();
    const endpoint = connection.backend.config.endpoint;
    return endpoint.perform_fn(endpoint.context, .{
        .method = if (collector.kind == .close) .delete else .post,
        .headers = headers[0..count],
        .body = body,
        .timeout_ms = timeout_ms,
        .cancellation = cancellation,
    }, &sink);
}

const ResponseMediaType = enum { json, event_stream };

fn responseMediaType(value: []const u8) ?ResponseMediaType {
    const separator = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
    const essence = std.mem.trim(u8, value[0..separator], " \t");
    if (std.ascii.eqlIgnoreCase(essence, "application/json")) return .json;
    if (std.ascii.eqlIgnoreCase(essence, "text/event-stream")) return .event_stream;
    return null;
}

const ResponseCollector = struct {
    allocator: std.mem.Allocator,
    kind: ExchangeKind,
    max_session_token_bytes: usize,
    output: []u8,
    output_len: usize = 0,
    media_type: ?ResponseMediaType = null,
    content_type_count: usize = 0,
    session_token: ?[]u8 = null,
    session_token_count: usize = 0,
    sse: ?SseDecoder = null,
    failure: ?PortFailure = null,
    complete: bool = false,
    status: u16 = 0,
    error_status: bool = false,

    fn init(
        allocator: std.mem.Allocator,
        kind: ExchangeKind,
        max_response_bytes: usize,
        max_session_token_bytes_value: usize,
    ) std.mem.Allocator.Error!ResponseCollector {
        return .{
            .allocator = allocator,
            .kind = kind,
            .max_session_token_bytes = max_session_token_bytes_value,
            .output = try allocator.alloc(u8, max_response_bytes),
        };
    }

    fn deinit(self: *ResponseCollector) void {
        if (self.session_token) |token| secureFree(self.allocator, token);
        secureFree(self.allocator, self.output);
        self.* = undefined;
    }

    fn sessionToken(self: *const ResponseCollector) []const u8 {
        return self.session_token orelse &.{};
    }

    fn sink(self: *ResponseCollector) ResponseSink {
        return .{
            .context = self,
            .begin_fn = begin,
            .header_fn = header,
            .end_headers_fn = endHeaders,
            .feed_fn = feed,
            .finish_fn = finish,
        };
    }

    fn begin(raw: *anyopaque, status: u16) SinkFlow {
        const self: *ResponseCollector = @ptrCast(@alignCast(raw));
        self.status = status;
        switch (self.kind) {
            .request => self.error_status = status < 200 or status >= 300,
            .close => if (status < 200 or status >= 300)
                return self.fail(.server),
            .notification => if (status != 202)
                return self.fail(.server),
        }
        return .continue_reading;
    }

    fn header(
        raw: *anyopaque,
        name: []const u8,
        value: []const u8,
    ) SinkFlow {
        const self: *ResponseCollector = @ptrCast(@alignCast(raw));
        if (self.failure != null or self.complete) return .stop;
        if (std.ascii.eqlIgnoreCase(name, HeaderName.content_type)) {
            if (self.kind != .request or self.error_status) return .continue_reading;
            self.content_type_count += 1;
            if (self.content_type_count != 1)
                return self.fail(.fatal);
            self.media_type = responseMediaType(value) orelse
                return self.fail(.fatal);
            return .continue_reading;
        }
        if (std.ascii.eqlIgnoreCase(name, HeaderName.session_id)) {
            if (self.kind == .close or self.error_status)
                return .continue_reading;
            self.session_token_count += 1;
            if (self.session_token_count != 1 or value.len == 0 or
                value.len > self.max_session_token_bytes or
                !visibleAscii(value)) return self.fail(.fatal);
            self.session_token = self.allocator.dupe(u8, value) catch
                return self.fail(.fatal);
        }
        return .continue_reading;
    }

    fn endHeaders(raw: *anyopaque) SinkFlow {
        const self: *ResponseCollector = @ptrCast(@alignCast(raw));
        if (self.failure != null or self.complete) return .stop;
        if (self.kind != .request or self.error_status) return .continue_reading;
        const media_type = self.media_type orelse return .continue_reading;
        if (media_type == .event_stream) {
            const max_wire_bytes = std.math.add(
                usize,
                self.output.len,
                max_sse_framing_bytes,
            ) catch return self.fail(.fatal);
            self.sse = SseDecoder.init(self.output, max_wire_bytes);
        }
        return .continue_reading;
    }

    fn feed(raw: *anyopaque, bytes: []const u8) FeedOutcome {
        const self: *ResponseCollector = @ptrCast(@alignCast(raw));
        if (self.failure != null or self.complete)
            return .{ .consumed = 0, .flow = .stop };
        switch (self.kind) {
            .notification => {
                if (bytes.len == 0)
                    return .{ .consumed = 0, .flow = .continue_reading };
                _ = self.fail(.fatal);
                return .{ .consumed = bytes.len, .flow = .stop };
            },
            .close => {
                const remaining = self.output.len - self.output_len;
                if (bytes.len > remaining) {
                    self.output_len = self.output.len;
                    _ = self.fail(.fatal);
                    return .{ .consumed = remaining, .flow = .stop };
                }
                self.output_len += bytes.len;
                return .{ .consumed = bytes.len, .flow = .continue_reading };
            },
            .request => {},
        }
        if (self.error_status) {
            const remaining = self.output.len - self.output_len;
            if (bytes.len > remaining) {
                if (remaining != 0)
                    @memcpy(self.output[self.output_len..], bytes[0..remaining]);
                self.output_len = self.output.len;
                _ = self.fail(.fatal);
                return .{ .consumed = remaining, .flow = .stop };
            }
            @memcpy(self.output[self.output_len..][0..bytes.len], bytes);
            self.output_len += bytes.len;
            return .{ .consumed = bytes.len, .flow = .continue_reading };
        }
        switch (self.media_type orelse {
            _ = self.fail(.fatal);
            return .{ .consumed = 0, .flow = .stop };
        }) {
            .json => {
                const remaining = self.output.len - self.output_len;
                if (bytes.len > remaining) {
                    if (remaining != 0)
                        @memcpy(self.output[self.output_len..], bytes[0..remaining]);
                    self.output_len = self.output.len;
                    _ = self.fail(.fatal);
                    return .{ .consumed = remaining, .flow = .stop };
                }
                @memcpy(self.output[self.output_len..][0..bytes.len], bytes);
                self.output_len += bytes.len;
                return .{ .consumed = bytes.len, .flow = .continue_reading };
            },
            .event_stream => {
                const decoder = &(self.sse orelse {
                    _ = self.fail(.fatal);
                    return .{ .consumed = 0, .flow = .stop };
                });
                for (bytes, 0..) |byte, index| {
                    const outcome = decoder.feedByte(byte) catch {
                        _ = self.fail(.fatal);
                        return .{ .consumed = index + 1, .flow = .stop };
                    };
                    if (outcome == .complete) {
                        self.output_len = decoder.output_len;
                        self.complete = true;
                        return .{ .consumed = index + 1, .flow = .stop };
                    }
                }
                return .{ .consumed = bytes.len, .flow = .continue_reading };
            },
        }
    }

    fn finish(raw: *anyopaque) SinkFlow {
        const self: *ResponseCollector = @ptrCast(@alignCast(raw));
        if (self.failure != null or self.complete) return .stop;
        switch (self.kind) {
            .request => if (!self.error_status) {
                if (self.media_type) |media_type| switch (media_type) {
                    .json => {},
                    .event_stream => if ((self.sse orelse
                        return self.fail(.fatal)).wire_bytes != 0)
                        return self.fail(.fatal),
                } else if (self.output_len != 0) return self.fail(.fatal);
            },
            .notification, .close => {},
        }
        self.complete = true;
        return .stop;
    }

    fn fail(self: *ResponseCollector, failure: PortFailure) SinkFlow {
        if (self.failure == null) self.failure = failure;
        return .stop;
    }
};

const SseDecoder = struct {
    const FeedResult = enum { pending, complete };
    const LineKind = enum { pending, data, event, other, comment };

    output: []u8,
    output_len: usize = 0,
    max_wire_bytes: usize,
    wire_bytes: usize = 0,
    stream_start: bool = true,
    bom_len: u2 = 0,
    saw_data: bool = false,
    saw_data_bytes: bool = false,
    event_is_message: bool = true,
    ignore_lf_after_cr: bool = false,
    line_kind: LineKind = .pending,
    line_has_bytes: bool = false,
    in_value: bool = false,
    skip_value_space: bool = false,
    field_storage: [16]u8 = undefined,
    field_len: usize = 0,
    field_overflow: bool = false,
    event_value_len: usize = 0,
    event_value_matches: bool = true,

    fn init(output: []u8, max_wire_bytes: usize) SseDecoder {
        return .{ .output = output, .max_wire_bytes = max_wire_bytes };
    }

    fn feedByte(self: *SseDecoder, byte: u8) error{InvalidResponse}!FeedResult {
        if (self.wire_bytes == self.max_wire_bytes) return error.InvalidResponse;
        self.wire_bytes += 1;
        if (self.stream_start) {
            const bom = "\xef\xbb\xbf";
            if (self.bom_len != 0) {
                if (byte != bom[self.bom_len]) return error.InvalidResponse;
                self.bom_len += 1;
                if (self.bom_len == bom.len) self.stream_start = false;
                return .pending;
            }
            if (byte == bom[0]) {
                self.bom_len = 1;
                return .pending;
            }
            self.stream_start = false;
        }
        if (byte == '\n' and self.ignore_lf_after_cr) {
            self.ignore_lf_after_cr = false;
            return .pending;
        }
        self.ignore_lf_after_cr = false;
        if (byte == '\r') {
            self.ignore_lf_after_cr = true;
            return self.finishLine();
        }
        if (byte == '\n') return self.finishLine();
        self.line_has_bytes = true;
        if (self.line_kind == .comment) return .pending;
        if (!self.in_value) {
            if (self.field_len == 0 and byte == ':') {
                self.line_kind = .comment;
                self.in_value = true;
                return .pending;
            }
            if (byte == ':') {
                self.in_value = true;
                self.classifyField();
                try self.beginValue();
                self.skip_value_space = true;
                return .pending;
            }
            if (self.field_len < self.field_storage.len) {
                self.field_storage[self.field_len] = byte;
                self.field_len += 1;
            } else self.field_overflow = true;
            return .pending;
        }
        if (self.skip_value_space) {
            self.skip_value_space = false;
            if (byte == ' ') return .pending;
        }
        switch (self.line_kind) {
            .data => {
                try self.appendDataByte(byte);
                self.saw_data_bytes = true;
            },
            .event => {
                const expected = "message";
                if (self.event_value_len >= expected.len or
                    byte != expected[self.event_value_len])
                    self.event_value_matches = false;
                self.event_value_len += 1;
            },
            else => {},
        }
        return .pending;
    }

    fn finishLine(self: *SseDecoder) error{InvalidResponse}!FeedResult {
        if (!self.line_has_bytes) {
            const complete = self.saw_data and self.saw_data_bytes and self.event_is_message;
            if (!complete) {
                self.output_len = 0;
                self.saw_data = false;
                self.saw_data_bytes = false;
                self.event_is_message = true;
            }
            self.resetLine();
            return if (complete) .complete else .pending;
        }
        if (!self.in_value) {
            self.classifyField();
            try self.beginValue();
        }
        if (self.line_kind == .event) {
            self.event_is_message = self.event_value_len == 0 or
                (self.event_value_matches and self.event_value_len == "message".len);
        }
        self.resetLine();
        return .pending;
    }

    fn classifyField(self: *SseDecoder) void {
        if (self.field_overflow) {
            self.line_kind = .other;
        } else if (std.mem.eql(u8, self.field_storage[0..self.field_len], "data")) {
            self.line_kind = .data;
        } else if (std.mem.eql(u8, self.field_storage[0..self.field_len], "event")) {
            self.line_kind = .event;
        } else {
            self.line_kind = .other;
        }
    }

    fn beginValue(self: *SseDecoder) error{InvalidResponse}!void {
        switch (self.line_kind) {
            .data => {
                if (self.saw_data) try self.appendDataByte('\n');
                self.saw_data = true;
            },
            .event => {
                self.event_value_len = 0;
                self.event_value_matches = true;
            },
            else => {},
        }
    }

    fn appendDataByte(self: *SseDecoder, byte: u8) error{InvalidResponse}!void {
        if (self.output_len == self.output.len) return error.InvalidResponse;
        self.output[self.output_len] = byte;
        self.output_len += 1;
    }

    fn resetLine(self: *SseDecoder) void {
        self.line_kind = .pending;
        self.line_has_bytes = false;
        self.in_value = false;
        self.skip_value_space = false;
        self.field_len = 0;
        self.field_overflow = false;
        self.event_value_len = 0;
        self.event_value_matches = true;
    }
};

fn protocolVersion(era: connector.Era) []const u8 {
    return switch (era) {
        .modern_2026_07_28 => "2026-07-28",
        .compat_2025_11_25 => "2025-11-25",
        .compat_2025_06_18 => "2025-06-18",
    };
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
const max_sse_framing_bytes: usize = 64 * 1024;

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

test "HTTP protocol versions remain Agent transport facts" {
    try std.testing.expectEqualStrings("2026-07-28", protocolVersion(.modern_2026_07_28));
    try std.testing.expectEqualStrings("2025-11-25", protocolVersion(.compat_2025_11_25));
    try std.testing.expectEqualStrings("2025-06-18", protocolVersion(.compat_2025_06_18));
}

test "HTTP protocol reserves only Agent-owned request headers" {
    try std.testing.expectEqual(@as(usize, 4), reserved_request_header_names.len);
    inline for (.{
        "accept",
        "CONTENT-TYPE",
        "mcp-protocol-version",
        "MCP-SESSION-ID",
    }) |name| try std.testing.expect(protocol.isReservedRequestHeader(name));
    try std.testing.expect(!protocol.isReservedRequestHeader("Accept-Encoding"));
    try std.testing.expect(!protocol.isReservedRequestHeader("Host"));
}

test "HTTP classifies JSON and event-stream response media types" {
    try std.testing.expectEqual(
        ResponseMediaType.json,
        responseMediaType(" Application/JSON ; charset=utf-8").?,
    );
    try std.testing.expectEqual(
        ResponseMediaType.event_stream,
        responseMediaType("text/event-stream; charset=utf-8").?,
    );
    try std.testing.expectEqual(
        @as(?ResponseMediaType, null),
        responseMediaType("text/plain"),
    );
}

fn expectSseMessage(
    input: []const u8,
    expected: []const u8,
    expect_early_stop: bool,
) !void {
    var collector = try ResponseCollector.init(
        std.testing.allocator,
        .request,
        128,
        1024,
    );
    defer collector.deinit();
    const sink = collector.sink();
    try std.testing.expectEqual(SinkFlow.continue_reading, sink.begin_fn(sink.context, 200));
    try std.testing.expectEqual(
        SinkFlow.continue_reading,
        sink.header_fn(sink.context, "Content-Type", "text/event-stream"),
    );
    try std.testing.expectEqual(
        SinkFlow.continue_reading,
        sink.end_headers_fn(sink.context),
    );
    const fed = sink.feed_fn(sink.context, input);
    try std.testing.expectEqual(SinkFlow.stop, fed.flow);
    if (expect_early_stop)
        try std.testing.expect(fed.consumed < input.len)
    else
        try std.testing.expectEqual(input.len, fed.consumed);
    try std.testing.expectEqual(@as(?PortFailure, null), collector.failure);
    try std.testing.expect(collector.complete);
    try std.testing.expectEqualStrings(expected, collector.output[0..collector.output_len]);
}

test "HTTP normalizes one bounded SSE message without waiting for EOF" {
    try expectSseMessage(
        "\xef\xbb\xbf: heartbeat\r\n" ++
            "event: ping\r\n" ++
            "data: ignored\r\n\r\n" ++
            "event: message\r\n" ++
            "data: {\"jsonrpc\":\"2.0\",\r\n" ++
            "data: \"id\":1}\r\n\r\n" ++
            "data: trailing-must-not-be-read\r\n\r\n",
        "{\"jsonrpc\":\"2.0\",\n\"id\":1}",
        true,
    );
}

test "HTTP skips empty SSE events before one bounded message" {
    try expectSseMessage(
        "id: empty-event\n" ++
            "data:\n\n" ++
            "event: message\n" ++
            "id: response-event\n" ++
            "data: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n\n",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}",
        false,
    );
}

test "HTTP skips SSE events containing only empty data lines" {
    try expectSseMessage(
        "data:\n" ++
            "data:\n\n" ++
            "data: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n\n",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}",
        false,
    );
}

test "HTTP rejects an SSE payload beyond the response bound" {
    var collector = try ResponseCollector.init(
        std.testing.allocator,
        .request,
        4,
        1024,
    );
    defer collector.deinit();
    const sink = collector.sink();
    _ = sink.begin_fn(sink.context, 200);
    _ = sink.header_fn(sink.context, "Content-Type", "text/event-stream");
    _ = sink.end_headers_fn(sink.context);
    const fed = sink.feed_fn(sink.context, "data: 12345\n\n");
    try std.testing.expectEqual(SinkFlow.stop, fed.flow);
    try std.testing.expectEqual(@as(?PortFailure, .fatal), collector.failure);
}

test "HTTP bounds ignored SSE framing bytes" {
    var collector = try ResponseCollector.init(
        std.testing.allocator,
        .request,
        4,
        1024,
    );
    defer collector.deinit();
    const sink = collector.sink();
    _ = sink.begin_fn(sink.context, 200);
    _ = sink.header_fn(sink.context, "Content-Type", "text/event-stream");
    _ = sink.end_headers_fn(sink.context);
    const input = try std.testing.allocator.alloc(
        u8,
        collector.output.len + max_sse_framing_bytes + 1,
    );
    defer std.testing.allocator.free(input);
    @memset(input, 'x');
    input[0] = ':';
    const fed = sink.feed_fn(sink.context, input);
    try std.testing.expectEqual(SinkFlow.stop, fed.flow);
    try std.testing.expectEqual(@as(?PortFailure, .fatal), collector.failure);
}

const FakeEndpoint = struct {
    valid: bool = true,
    failure: ?PortFailure = null,
    status: u16 = 200,
    content_type: []const u8 = "application/json",
    session_token: []const u8 = &.{},
    expected_protocol_version: ?[]const u8 = null,
    expected_session_token: []const u8 = &.{},
    empty_body: bool = false,
    calls: usize = 0,
    saw_notification: bool = false,
    deletes: usize = 0,
    headers_valid: bool = true,

    fn capability(self: *FakeEndpoint) AuthorizedEndpoint {
        return .{
            .context = self,
            .validate_fn = validate,
            .perform_fn = performEndpoint,
        };
    }

    fn validate(context: *anyopaque) bool {
        const self: *FakeEndpoint = @ptrCast(@alignCast(context));
        return self.valid;
    }

    fn performEndpoint(
        context: *anyopaque,
        request_value: Request,
        sink: *const ResponseSink,
    ) PerformOutcome {
        const self: *FakeEndpoint = @ptrCast(@alignCast(context));
        self.calls += 1;
        self.checkProtocolHeaders(request_value);
        if (self.failure) |failure| return .{ .failure = failure };
        if (request_value.method == .delete) {
            self.deletes += 1;
            if (sink.begin_fn(sink.context, 200) == .stop) return .completed;
            if (sink.end_headers_fn(sink.context) == .stop) return .completed;
            _ = sink.finish_fn(sink.context);
            return .completed;
        }
        const notification = std.mem.eql(u8, request_value.body, "opaque-notify");
        self.saw_notification = notification;
        if (sink.begin_fn(
            sink.context,
            if (notification) 202 else self.status,
        ) == .stop) return .completed;
        if (!notification and sink.header_fn(
            sink.context,
            "Content-Type",
            self.content_type,
        ) == .stop) return .completed;
        if (self.session_token.len != 0 and sink.header_fn(
            sink.context,
            "Mcp-Session-Id",
            self.session_token,
        ) == .stop) return .completed;
        if (sink.end_headers_fn(sink.context) == .stop) return .completed;
        if (!notification and !self.empty_body) {
            const fed = sink.feed_fn(sink.context, request_value.body);
            if (fed.flow == .stop) return .completed;
        }
        _ = sink.finish_fn(sink.context);
        return .completed;
    }

    fn checkProtocolHeaders(self: *FakeEndpoint, request_value: Request) void {
        const expected_protocol = self.expected_protocol_version orelse return;
        self.headers_valid = self.headers_valid and std.mem.eql(
            u8,
            headerValue(request_value.headers, "Accept") orelse "",
            "application/json, text/event-stream",
        ) and std.mem.eql(
            u8,
            headerValue(request_value.headers, "MCP-Protocol-Version") orelse "",
            expected_protocol,
        ) and ((request_value.method == .post) == std.mem.eql(
            u8,
            headerValue(request_value.headers, "Content-Type") orelse "",
            "application/json",
        ));
        const expected_session = if (self.calls == 1) "" else self.expected_session_token;
        self.headers_valid = self.headers_valid and std.mem.eql(
            u8,
            headerValue(request_value.headers, "Mcp-Session-Id") orelse "",
            expected_session,
        );
    }

    fn headerValue(headers: []const Header, name: []const u8) ?[]const u8 {
        var result: ?[]const u8 = null;
        for (headers) |header| if (std.ascii.eqlIgnoreCase(header.name, name)) {
            if (result != null) return null;
            result = header.value;
        };
        return result;
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
    try std.testing.expectEqual(@as(usize, 0), endpoint.deletes);
}

test "HTTP owns protocol headers, opaque bytes, and session token" {
    var endpoint: FakeEndpoint = .{
        .session_token = "session-1",
        .expected_protocol_version = "2025-11-25",
        .expected_session_token = "session-1",
    };
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
    var connection_open = true;
    defer if (connection_open) transport.close_fn(connection);
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
    defer std.testing.allocator.free(response.body);
    try std.testing.expectEqual(@as(u32, 200), response.http_status);
    try std.testing.expectEqualStrings("opaque-request", response.body);
    try std.testing.expectEqual(
        @as(?connector.Failure, null),
        transport.notify_fn(connection, "opaque-notify", 1000, .{}),
    );
    try std.testing.expect(endpoint.saw_notification);
    transport.close_fn(connection);
    connection_open = false;
    try std.testing.expect(endpoint.headers_valid);
    try std.testing.expectEqual(@as(usize, 1), endpoint.deletes);
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
            if (response.body.len != 0) std.testing.allocator.free(response.body);
            return error.TestUnexpectedResult;
        },
    }
    try std.testing.expectEqual(
        @as(?connector.Failure, .fatal),
        transport.notify_fn(connection, "opaque", 1000, .{}),
    );
    try std.testing.expectEqual(@as(usize, 1), endpoint.calls);
}

test "HTTP complete authorization response preserves status for AgentCore" {
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
        .failure => return error.TestUnexpectedResult,
        .response => |response| {
            try std.testing.expectEqual(@as(u32, 401), response.http_status);
            try std.testing.expectEqual(@as(usize, 0), response.body.len);
        },
    }
}

test "HTTP complete protocol rejection preserves raw status and body" {
    var endpoint: FakeEndpoint = .{ .status = 400 };
    var backend = try Backend.init(.{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .endpoint = endpoint.capability(),
    });
    defer backend.deinit() catch unreachable;
    const transport = backend.transport();
    const connection = switch (transport.open_fn(
        transport.context,
        .disposable_probe,
        .modern_2026_07_28,
        1000,
    )) {
        .connection => |value| value,
        .failure => return error.TestUnexpectedResult,
    };
    defer transport.close_fn(connection);
    const response = switch (transport.request_fn(
        connection,
        std.testing.allocator,
        "legacy evidence",
        1000,
        .{},
    )) {
        .failure => return error.TestUnexpectedResult,
        .response => |value| value,
    };
    defer std.testing.allocator.free(response.body);
    try std.testing.expectEqual(@as(u32, 400), response.http_status);
    try std.testing.expectEqualStrings("legacy evidence", response.body);
}

test "HTTP error responses preserve status and body regardless of media type" {
    for ([_]u16{ 400, 401, 403, 502 }) |status| {
        for ([_][]const u8{ "text/html", "text/plain", "application/octet-stream" }) |media_type| {
            var endpoint: FakeEndpoint = .{ .status = status, .content_type = media_type };
            var backend = try Backend.init(.{
                .io = std.testing.io,
                .allocator = std.testing.allocator,
                .endpoint = endpoint.capability(),
            });
            defer backend.deinit() catch unreachable;
            const transport = backend.transport();
            const connection = switch (transport.open_fn(transport.context, .actual, .modern_2026_07_28, 1000)) {
                .connection => |value| value,
                .failure => return error.TestUnexpectedResult,
            };
            defer transport.close_fn(connection);
            const response = switch (transport.request_fn(connection, std.testing.allocator, "error evidence", 1000, .{})) {
                .response => |value| value,
                .failure => return error.TestUnexpectedResult,
            };
            defer std.testing.allocator.free(response.body);
            try std.testing.expectEqual(@as(u32, status), response.http_status);
            try std.testing.expectEqualStrings("error evidence", response.body);
        }
    }
}

test "HTTP successful HTML remains an invalid response" {
    var collector = try ResponseCollector.init(std.testing.allocator, .request, 128, 128);
    defer collector.deinit();
    const sink = collector.sink();
    try std.testing.expectEqual(SinkFlow.continue_reading, sink.begin_fn(sink.context, 200));
    try std.testing.expectEqual(SinkFlow.stop, sink.header_fn(sink.context, "Content-Type", "text/html"));
    try std.testing.expectEqual(@as(?PortFailure, .fatal), collector.failure);
}

test "HTTP complete successful response may have an empty body" {
    var endpoint: FakeEndpoint = .{ .status = 204, .empty_body = true };
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
    const response = switch (transport.request_fn(
        connection,
        std.testing.allocator,
        "opaque",
        1000,
        .{},
    )) {
        .failure => return error.TestUnexpectedResult,
        .response => |value| value,
    };
    try std.testing.expectEqual(@as(u32, 204), response.http_status);
    try std.testing.expectEqual(@as(usize, 0), response.body.len);
}
