//! Application-owned HTTP execution. Business owners retain retry, response and
//! shutdown policy. A returned result always means all borrowed inputs are idle.
const std = @import("std");
const memory = @import("app_http_memory");
const Io = std.Io;
const Client = std.http.Client;

pub const Error = error{
    InvalidRequest,
    DnsFailed,
    ConnectFailed,
    TlsFailed,
    WriteFailed,
    ReadFailed,
    InvalidResponse,
    ResponseTooLarge,
    OutOfMemory,
    ResourceLimit,
    Cancelled,
    DeadlineExceeded,
};
pub const Consumer = enum { update, completion, metask, mcp_oauth, mcp };
pub const Phase = enum { admission, resolve, connect, send, head, body, complete };
pub const Send = enum { not_sent, may_have_been_sent };

pub const Cancellation = struct {
    context: *const anyopaque,
    requested_fn: *const fn (*const anyopaque) bool,
    wait_fn: *const fn (Io, *const anyopaque) Io.Cancelable!void,

    pub fn atomic(state: *const std.atomic.Value(u32)) Cancellation {
        return .{ .context = state, .requested_fn = requestedAtomic, .wait_fn = waitAtomic };
    }

    fn requestedAtomic(context: *const anyopaque) bool {
        const state: *const std.atomic.Value(u32) = @ptrCast(@alignCast(context));
        return state.load(.acquire) != 0;
    }

    fn waitAtomic(io: Io, context: *const anyopaque) Io.Cancelable!void {
        const state: *const std.atomic.Value(u32) = @ptrCast(@alignCast(context));
        while (state.load(.acquire) == 0) try io.futexWait(u32, &state.raw, 0);
    }
};

pub const Control = struct {
    consumer: Consumer,
    cancellation: ?Cancellation = null,
    deadline: ?Io.Clock.Timestamp = null,
    /// Only an HTTP response to a server request on an already-held MCP stream.
    continuation: bool = false,
};

pub fn Result(comptime T: type) type {
    return struct {
        outcome: union(enum) { completed: T, failed: Error },
        send: Send,
    };
}

/// Fixed capacity, with no waiting request queue. Each held MCP parent can admit
/// one continuation even when ordinary capacity is full. Slots also bound TLS
/// buffers, CA bundles and idle connections; only one connection is retained per
/// slot. An exclusively leased Client gives every handshake a fresh TLS clock.
pub const Engine = struct {
    pub const request_limit = 8;
    pub const continuation_limit = request_limit;
    pub const resolver_limit = request_limit;
    const slot_count = request_limit + continuation_limit;
    const idle_seconds = 30;
    const lifetime_seconds = 300;

    io: Io,
    memory: memory.ZeroingAllocator,
    mutex: Io.Mutex = .init,
    active: [2]usize = .{ 0, 0 },
    resolving: usize = 0,
    next_id: u64 = 1,
    slots: [slot_count]Slot = undefined,

    const Slot = struct {
        client: Client,
        busy: bool = false,
        scope: [32]u8 = @splat(0),
        created: Io.Clock.Timestamp = undefined,
        idle: Io.Clock.Timestamp = undefined,
    };

    /// The engine must stay at this address until deinit, after its callers join.
    pub fn init(self: *Engine, allocator: std.mem.Allocator, io: Io) void {
        self.* = .{ .io = io, .memory = .{ .backing = allocator } };
        for (&self.slots) |*slot| slot.* = .{ .client = .{
            .io = io,
            .allocator = self.memory.allocator(),
            .connection_pool = .{ .free_size = 1 },
        } };
    }

    pub fn deinit(self: *Engine) void {
        std.debug.assert(self.active[0] == 0 and self.active[1] == 0 and self.resolving == 0);
        for (&self.slots) |*slot| {
            std.debug.assert(!slot.busy);
            slot.client.deinit();
        }
        self.* = undefined;
    }

    pub fn run(self: *Engine, control: Control, comptime function: anytype, args: anytype) Result(@typeInfo(@TypeOf(function)).@"fn".return_type.?) {
        const T = @typeInfo(@TypeOf(function)).@"fn".return_type.?;
        const Outcome = union(enum) { completed: T, cancelled: void, deadline: void };
        var operation: Operation = .{ .engine = self, .control = control };
        const started: Io.Clock.Timestamp = .now(self.io, .awake);
        self.mutex.lockUncancelable(self.io);
        const id = self.next_id;
        self.next_id +%= 1;
        self.mutex.unlock(self.io);
        defer if (operation.failure) |err| if (err != error.Cancelled) {
            // Only typed facts. No endpoint, headers, payload or backend message.
            std.log.warn("http id={d} consumer={s} phase={s} cause={s} send={s} reused={} elapsed_ms={d}", .{
                id, @tagName(control.consumer), @tagName(operation.phase), @errorName(err), @tagName(operation.sendFact()), operation.reused, started.untilNow(self.io).raw.toMilliseconds(),
            });
        };
        operation.check() catch |err| return .{ .outcome = .{ .failed = err }, .send = .not_sent };
        const lane: usize = @intFromBool(control.continuation);
        self.mutex.lockUncancelable(self.io);
        if (self.active[lane] == request_limit) {
            self.mutex.unlock(self.io);
            return .{ .outcome = .{ .failed = operation.fail(error.ResourceLimit) }, .send = .not_sent };
        }
        self.active[lane] += 1;
        self.mutex.unlock(self.io);
        defer {
            self.mutex.lockUncancelable(self.io);
            self.active[lane] -= 1;
            if (operation.slot) |slot| {
                std.debug.assert(slot.client.connection_pool.used.first == null);
                slot.idle = .now(self.io, .awake);
                slot.busy = false;
            }
            self.mutex.unlock(self.io);
        }
        var storage: [3]Outcome = undefined;
        var selection: Io.Select(Outcome) = .init(self.io, &storage);
        const selected: union(enum) { value: Outcome, failed: Error } = selected: {
            // Register controls first: a registration failure must close the send
            // gate before canceling any worker, even if a dependency eats cancel.
            if (control.deadline != null) selection.concurrent(.deadline, Operation.waitDeadline, .{&operation}) catch break :selected .{ .failed = error.ResourceLimit };
            if (control.cancellation != null) selection.concurrent(.cancelled, Operation.waitCancellation, .{&operation}) catch break :selected .{ .failed = error.ResourceLimit };
            selection.concurrent(.completed, function, .{&operation} ++ args) catch break :selected .{ .failed = error.ResourceLimit };
            break :selected .{ .value = selection.await() catch break :selected .{ .failed = error.Cancelled } };
        };
        // Terminal selection precedes resource cleanup. A complete response that
        // won selection is never replaced by cancellation during this join.
        operation.stop();
        selection.cancelDiscard();
        const result: Result(T) = .{
            .send = operation.sendFact(),
            .outcome = switch (selected) {
                .failed => |err| .{ .failed = err },
                .value => |value| switch (value) {
                    .completed => |completed| .{ .completed = completed },
                    .cancelled => .{ .failed = error.Cancelled },
                    .deadline => .{ .failed = error.DeadlineExceeded },
                },
            },
        };
        if (result.outcome == .failed) operation.failure = result.outcome.failed;
        return result;
    }

    fn lease(self: *Engine, criteria: Client.ConnectionPool.Criteria, scope: [32]u8) *Slot {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var available: ?*Slot = null;
        for (&self.slots) |*slot| {
            if (slot.busy) continue;
            if (available == null) available = slot;
            if (!std.mem.eql(u8, &scope, &slot.scope)) continue;
            const node = slot.client.connection_pool.free.first orelse continue;
            const connection: *Client.Connection = @alignCast(@fieldParentPtr("pool_node", node));
            if (connection.protocol == criteria.protocol and connection.port == criteria.port and connection.host().eql(criteria.host)) {
                available = slot;
                break;
            }
        }
        const slot = available.?; // admission reserves at most one slot per call
        slot.busy = true;
        return slot;
    }

    fn discardIdle(slot: *Slot) void {
        while (slot.client.connection_pool.free.first) |node| {
            const connection: *Client.Connection = @alignCast(@fieldParentPtr("pool_node", node));
            slot.client.connection_pool.acquire(slot.client.io, connection);
            dispose(connection);
        }
    }
};

pub const Operation = struct {
    engine: *Engine,
    control: Control,
    // bit 0: first HTTP write admitted; bit 1: execution stopped.
    gate: std.atomic.Value(u8) = .init(0),
    slot: ?*Engine.Slot = null,
    phase: Phase = .admission,
    failure: ?Error = null,
    reused: bool = false,

    pub fn io(self: *Operation) Io {
        return self.engine.io;
    }

    pub fn allocator(self: *Operation) std.mem.Allocator {
        return self.engine.memory.allocator();
    }

    pub fn fail(self: *Operation, err: Error) Error {
        self.failure = err;
        return err;
    }

    fn stop(self: *Operation) void {
        _ = self.gate.fetchOr(2, .acq_rel);
    }

    pub fn sendFact(self: *const Operation) Send {
        return if (self.gate.load(.acquire) & 1 != 0) .may_have_been_sent else .not_sent;
    }

    pub fn check(self: *Operation) Error!void {
        if (self.control.deadline) |deadline| if (deadline.raw.nanoseconds <= deadline.clock.now(self.io()).nanoseconds) return self.fail(error.DeadlineExceeded);
        if (self.control.cancellation) |cancellation| if (cancellation.requested_fn(cancellation.context)) return self.fail(error.Cancelled);
        if (self.gate.load(.acquire) & 2 != 0) return self.fail(error.Cancelled);
    }

    fn admitSend(self: *Operation) Error!void {
        try self.check();
        if (self.gate.cmpxchgStrong(0, 1, .acq_rel, .acquire) != null) return self.fail(error.Cancelled);
        // Conservative evidence if the source changed just after the CAS.
        try self.check();
        self.phase = .send;
    }

    fn waitDeadline(self: *Operation) void {
        self.control.deadline.?.wait(self.io()) catch return;
        self.stop();
    }

    fn waitCancellation(self: *Operation) void {
        const cancellation = self.control.cancellation.?;
        cancellation.wait_fn(self.io(), cancellation.context) catch return;
        self.stop();
    }

    pub const Options = struct {
        headers: []const std.http.Header = &.{},
        standard_headers: Client.Request.Headers = .{},
        /// Credentials in an OAuth body also partition reuse. Never retained.
        credential_scope: []const u8 = "",
    };

    pub fn open(self: *Operation, method: std.http.Method, uri: std.Uri, options: Options) Error!Request {
        try self.check();
        if (self.slot != null) return self.fail(error.InvalidRequest);
        const protocol = Client.Protocol.fromUri(uri) orelse return self.fail(error.InvalidRequest);
        if (uri.user != null or uri.password != null) return self.fail(error.InvalidRequest);
        var host_storage: [Io.net.HostName.max_len]u8 = undefined;
        const host = uri.getHost(&host_storage) catch return self.fail(error.InvalidRequest);
        var scope_hash = std.crypto.hash.sha2.Sha256.init(.{});
        defer std.crypto.secureZero(u8, std.mem.asBytes(&scope_hash));
        // Some integrations put credentials in the path or query. Partition by
        // the request target as well as headers without retaining those bytes.
        switch (uri.path) {
            inline else => |bytes| hashField(&scope_hash, bytes),
        }
        if (uri.query) |query| switch (query) {
            inline else => |bytes| hashField(&scope_hash, bytes),
        };
        for (options.headers) |header| {
            if (header.name.len == 0 or std.mem.indexOfAny(u8, header.name, "\r\n:") != null or std.mem.indexOfAny(u8, header.value, "\r\n") != null) return self.fail(error.InvalidRequest);
            hashField(&scope_hash, header.name);
            hashField(&scope_hash, header.value);
        }
        inline for (@typeInfo(Client.Request.Headers).@"struct".fields) |field| {
            const value = @field(options.standard_headers, field.name);
            hashField(&scope_hash, field.name);
            switch (value) {
                .default => hashField(&scope_hash, "default"),
                .omit => hashField(&scope_hash, "omit"),
                .override => |bytes| {
                    if (std.mem.indexOfAny(u8, bytes, "\r\n") != null) return self.fail(error.InvalidRequest);
                    hashField(&scope_hash, "override");
                    hashField(&scope_hash, bytes);
                },
            }
        }
        hashField(&scope_hash, options.credential_scope);
        const scope = scope_hash.finalResult();
        const criteria: Client.ConnectionPool.Criteria = .{ .host = host, .port = uri.port orelse @as(u16, if (protocol == .tls) 443 else 80), .protocol = protocol };
        const slot = self.engine.lease(criteria, scope);
        self.slot = slot;
        const client = &slot.client;
        if (!std.mem.eql(u8, &scope, &slot.scope) or (client.connection_pool.free_len != 0 and
            (slot.idle.untilNow(self.io()).raw.toSeconds() >= Engine.idle_seconds or slot.created.untilNow(self.io()).raw.toSeconds() >= Engine.lifetime_seconds))) Engine.discardIdle(slot);
        slot.scope = scope;
        var connection: ?*Client.Connection = client.connection_pool.findConnection(self.io(), criteria);
        if (connection) |candidate| {
            if (idleHealthy(candidate)) self.reused = true else {
                dispose(candidate);
                connection = null;
            }
        }
        if (connection == null) {
            Engine.discardIdle(slot);
            if (protocol == .tls) {
                const now = Io.Clock.real.now(self.io());
                if (client.now == null) client.ca_bundle.rescan(client.allocator, self.io(), now) catch |err| return self.fail(if (err == error.Canceled) error.Cancelled else error.TlsFailed);
                client.now = now;
            }
            connection = try self.connect(client, criteria);
            slot.created = .now(self.io(), .awake);
        }
        errdefer dispose(connection.?);
        try self.check();
        const raw = client.request(method, uri, .{ .connection = connection, .redirect_behavior = .unhandled, .extra_headers = options.headers, .headers = options.standard_headers }) catch |err| return self.fail(if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidRequest);
        return .{ .operation = self, .raw = raw };
    }

    fn resolve(self: *Operation, host: Io.net.HostName, port: u16, addresses: *[16]Io.net.IpAddress) Error!usize {
        if (Io.net.IpAddress.parse(host.bytes, port)) |address| {
            addresses[0] = address;
            return 1;
        } else |_| {}
        self.phase = .resolve;
        self.engine.mutex.lockUncancelable(self.io());
        if (self.engine.resolving == Engine.resolver_limit) {
            self.engine.mutex.unlock(self.io());
            return self.fail(error.ResourceLimit);
        }
        self.engine.resolving += 1;
        self.engine.mutex.unlock(self.io());
        defer {
            self.engine.mutex.lockUncancelable(self.io());
            self.engine.resolving -= 1;
            self.engine.mutex.unlock(self.io());
        }
        var storage: [16]Io.net.HostName.LookupResult = undefined;
        var queue: Io.Queue(Io.net.HostName.LookupResult) = .init(&storage);
        var lookup = self.io().concurrent(Io.net.HostName.lookup, .{ host, self.io(), &queue, @as(Io.net.HostName.LookupOptions, .{ .port = port }) }) catch return self.fail(error.ResourceLimit);
        // DNS may acknowledge cancel late. Keep inputs and capacity until joined.
        defer lookup.cancel(self.io()) catch {};
        var count: usize = 0;
        while (queue.getOne(self.io())) |item| {
            if (item != .address or count == addresses.len) continue;
            var duplicate = false;
            for (addresses[0..count]) |address| if (address.eql(&item.address)) {
                duplicate = true;
                break;
            };
            if (!duplicate) {
                addresses[count] = item.address;
                count += 1;
            }
        } else |err| if (err == error.Canceled) return self.fail(error.Cancelled);
        lookup.await(self.io()) catch |err| return self.fail(if (err == error.Canceled) error.Cancelled else error.DnsFailed);
        try self.check();
        if (count == 0) return self.fail(error.DnsFailed);
        // Preserve order within each family, alternating families when possible.
        var family = addresses[0] == .ip4;
        for (1..count) |index| {
            family = !family;
            for (index..count) |candidate| if ((addresses[candidate] == .ip4) == family) {
                const address = addresses[candidate];
                std.mem.copyBackwards(Io.net.IpAddress, addresses[index + 1 .. candidate + 1], addresses[index..candidate]);
                addresses[index] = address;
                break;
            };
        }
        return count;
    }

    fn connect(self: *Operation, client: *Client, criteria: Client.ConnectionPool.Criteria) Error!*Client.Connection {
        var addresses: [16]Io.net.IpAddress = undefined;
        const count = try self.resolve(criteria.host, criteria.port, &addresses);
        self.phase = .connect;
        var race: ConnectRace = .{ .operation = self, .client = client, .criteria = criteria, .addresses = addresses[0..count] };
        var storage: [2]ConnectRace.Outcome = undefined;
        var selection: Io.Select(ConnectRace.Outcome) = .init(self.io(), &storage);
        defer {
            race.stopped.store(true, .release);
            while (selection.cancel()) |outcome| {
                const result = switch (outcome) {
                    inline else => |value| value,
                };
                if (result) |connection| dispose(connection) else |_| {}
            }
        }
        selection.concurrent(.first, ConnectRace.run, .{ &race, false }) catch return self.fail(error.ResourceLimit);
        if (count > 1) selection.concurrent(.second, ConnectRace.run, .{ &race, true }) catch return self.fail(error.ResourceLimit);
        var last_error: Error = error.ConnectFailed;
        for (0..@as(usize, if (count > 1) 2 else 1)) |_| {
            const outcome = selection.await() catch return self.fail(error.Cancelled);
            const result = switch (outcome) {
                inline else => |value| value,
            };
            if (result) |connection| return connection else |err| last_error = err;
        }
        return self.fail(last_error);
    }
};

const ConnectRace = struct {
    const Outcome = union(enum) { first: Error!*Client.Connection, second: Error!*Client.Connection };
    operation: *Operation,
    client: *Client,
    criteria: Client.ConnectionPool.Criteria,
    addresses: []const Io.net.IpAddress,
    next: std.atomic.Value(usize) = .init(0),
    stopped: std.atomic.Value(bool) = .init(false),

    fn attemptTimeout(io: Io) void {
        // Later addresses must progress even when both lanes stall. The caller's
        // absolute deadline remains in force throughout every connection attempt.
        Io.sleep(io, .fromSeconds(3), .awake) catch {};
    }

    fn connectOne(self: *ConnectRace, address: []const u8) Error!*Client.Connection {
        const OutcomeOne = union(enum) { connected: Client.ConnectTcpError!*Client.Connection, timeout: void };
        var storage: [2]OutcomeOne = undefined;
        var selection: Io.Select(OutcomeOne) = .init(self.operation.io(), &storage);
        defer while (selection.cancel()) |outcome| switch (outcome) {
            .connected => |result| if (result) |connection| {
                dispose(connection);
            } else |_| {},
            .timeout => {},
        };
        selection.concurrent(.timeout, attemptTimeout, .{self.operation.io()}) catch return error.ResourceLimit;
        selection.concurrent(.connected, Client.connectTcpOptions, .{
            self.client,
            @as(Client.ConnectTcpOptions, .{
                .host = .{ .bytes = address },
                .port = self.criteria.port,
                .protocol = self.criteria.protocol,
                // Public seam: numeric routing, original SNI/certificate identity.
                .proxied_host = self.criteria.host,
                .proxied_port = self.criteria.port,
            }),
        }) catch return error.ResourceLimit;
        return switch (selection.await() catch return error.Cancelled) {
            .timeout => error.ConnectFailed,
            .connected => |result| result catch |err| switch (err) {
                error.Canceled => error.Cancelled,
                error.OutOfMemory => error.OutOfMemory,
                error.TlsInitializationFailed => error.TlsFailed,
                else => error.ConnectFailed,
            },
        };
    }

    fn run(self: *ConnectRace, delayed: bool) Error!*Client.Connection {
        const io = self.operation.io();
        if (delayed) Io.sleep(io, .fromMilliseconds(250), .awake) catch return error.Cancelled;
        var last_error: Error = error.ConnectFailed;
        while (!self.stopped.load(.acquire)) {
            // Workers only read control state; phase/failure belong to the caller.
            if (self.operation.gate.load(.acquire) & 2 != 0) return error.Cancelled;
            const index = self.next.fetchAdd(1, .monotonic);
            if (index >= self.addresses.len) break;
            var buffer: [128]u8 = undefined;
            var writer: Io.Writer = .fixed(&buffer);
            self.addresses[index].formatResolved(io, &writer) catch return error.ConnectFailed;
            const formatted = writer.buffered();
            const address = switch (self.addresses[index]) {
                .ip4 => formatted[0..std.mem.lastIndexOfScalar(u8, formatted, ':').?],
                .ip6 => formatted[1..std.mem.lastIndexOfScalar(u8, formatted, ']').?],
            };
            const connection = self.connectOne(address) catch |err| {
                if (err == error.Cancelled or err == error.OutOfMemory or err == error.ResourceLimit) return err;
                last_error = err;
                continue;
            };
            if (self.stopped.load(.acquire) or self.operation.gate.load(.acquire) & 2 != 0) {
                dispose(connection);
                return error.Cancelled;
            }
            return connection;
        }
        return last_error;
    }
};

pub const Request = struct {
    operation: *Operation,
    raw: Client.Request,
    received: bool = false,

    pub fn deinit(self: *Request) void {
        const connection = self.raw.connection.?;
        const reusable = self.received and (self.raw.reader.state == .ready or !self.raw.method.responseHasBody());
        connection.closing = connection.closing or !reusable or self.operation.gate.load(.acquire) & 2 != 0;
        // Do not let std Request.deinit drain an abandoned GET while canceling.
        self.raw.connection = null;
        self.raw.deinit();
        connection.client.connection_pool.release(connection, self.operation.io());
        self.* = undefined;
    }

    pub fn send(self: *Request, body: ?[]const u8) Error!void {
        try self.operation.admitSend();
        if (body) |bytes| {
            self.raw.transfer_encoding = .{ .content_length = bytes.len };
            var writer = self.raw.sendBodyUnflushed(&.{}) catch return self.operation.fail(error.WriteFailed);
            writer.writer.writeAll(bytes) catch return self.operation.fail(error.WriteFailed);
            writer.end() catch return self.operation.fail(error.WriteFailed);
            self.raw.connection.?.flush() catch return self.operation.fail(error.WriteFailed);
        } else self.raw.sendBodiless() catch return self.operation.fail(error.WriteFailed);
    }

    pub fn receiveHead(self: *Request) Error!Client.Response {
        self.operation.phase = .head;
        const response = self.raw.receiveHead(&.{}) catch |err| return self.operation.fail(switch (err) {
            error.HttpHeadersInvalid, error.HttpHeadersOversize, error.HttpContentEncodingUnsupported => error.InvalidResponse,
            else => error.ReadFailed,
        });
        self.received = true;
        self.operation.phase = .body;
        return response;
    }

    pub fn readAll(self: *Request, response: *Client.Response, output: []u8) Error![]u8 {
        const allocator = self.operation.allocator();
        const size: usize = switch (response.head.content_encoding) {
            .identity => 0,
            .zstd => std.compress.zstd.default_window_len,
            .deflate, .gzip => std.compress.flate.max_window_len,
            .compress => return self.operation.fail(error.InvalidResponse),
        };
        const buffer = allocator.alloc(u8, size) catch return self.operation.fail(error.OutOfMemory);
        defer allocator.free(buffer);
        var transfer_buffer: [256]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const reader = response.readerDecompressing(&transfer_buffer, &decompress, buffer);
        var writer: Io.Writer = .fixed(output);
        _ = reader.streamRemaining(&writer) catch |err| return self.operation.fail(if (err == error.WriteFailed) error.ResponseTooLarge else error.ReadFailed);
        self.operation.phase = .complete;
        return writer.buffered();
    }
};

fn dispose(connection: *Client.Connection) void {
    connection.closing = true;
    connection.client.connection_pool.release(connection, connection.client.io);
}

fn hashField(hash: *std.crypto.hash.sha2.Sha256, bytes: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, @intCast(bytes.len), .little);
    hash.update(&length);
    hash.update(bytes);
}

fn idleHealthy(connection: *Client.Connection) bool {
    if (connection.reader().bufferedLen() != 0) return false;
    var messages: [1]Io.net.IncomingMessage = .{.init};
    var byte: [1]u8 = undefined;
    const err, _ = connection.stream_reader.stream.socket.receiveManyTimeout(connection.client.io, &messages, &byte, .{ .peek = true }, .{ .duration = .{ .raw = .zero, .clock = .awake } });
    // Pending bytes, EOF or error are not a clean idle HTTP connection. A race
    // after this probe is a normal failure, never an implicit request replay.
    if (err) |failure| return failure == error.Timeout;
    return false;
}

test {
    _ = @import("http_transport_test.zig");
}
