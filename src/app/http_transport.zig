//! Application-owned HTTP execution. Business owners retain retry, response and
//! shutdown policy. A returned result always means all borrowed inputs are idle.
const std = @import("std");
const memory = @import("app_http_memory");
const idle_probe = @import("http_idle_probe.zig");
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

/// The business owner's identity for connection reuse. Reuse is keyed by
/// origin, TLS configuration and this identity, never by token, path, query,
/// headers or body, so credential rotation keeps reuse. Only the digest of the
/// identity is retained.
pub const Isolation = struct {
    namespace: Namespace,
    digest: [32]u8,

    /// Distinct owners never share a connection even for equal identities.
    pub const Namespace = enum(u8) { public, metask_account, mcp_server, mcp_draft, completion_source };

    /// Credential-free endpoints owned by Application, such as updates.
    pub const public: Isolation = .{ .namespace = .public, .digest = @splat(0) };

    pub fn of(namespace: Namespace, identity: []const u8) Isolation {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        var length: [8]u8 = undefined;
        std.mem.writeInt(u64, &length, @intCast(identity.len), .little);
        hash.update(&.{@intFromEnum(namespace)});
        hash.update(&length);
        hash.update(identity);
        return .{ .namespace = namespace, .digest = hash.finalResult() };
    }

    pub fn eql(a: Isolation, b: Isolation) bool {
        return a.namespace == b.namespace and std.mem.eql(u8, &a.digest, &b.digest);
    }
};

/// Every caller bounds connection establishment explicitly.
pub const Budget = union(enum) {
    /// Absolute end of the whole call, including DNS, TCP and TLS.
    deadline: Io.Clock.Timestamp,
    /// The caller bounds the whole call by cancellation. This bounds only DNS,
    /// TCP and TLS, measured from admission.
    connect: Io.Duration,
};

pub const Control = struct {
    consumer: Consumer,
    isolation: Isolation,
    budget: Budget,
    cancellation: ?Cancellation = null,
    /// Only an HTTP response to a server request on an already-held MCP stream.
    continuation: bool = false,
};

pub fn Result(comptime T: type) type {
    return struct {
        outcome: union(enum) { completed: T, failed: Error },
        send: Send,
        /// The request was attempted on a pooled idle connection.
        reused: bool = false,
        /// That attempt failed safely and the request ran once more on a new
        /// connection. Implies `reused`.
        retried: bool = false,
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
    /// Idle limit without a server hint, and the cap on any hint.
    const idle_seconds = 30;
    const lifetime_seconds = 300;
    /// Subtracted from a server's Keep-Alive timeout: our idle clock starts
    /// after reading the response, later than the server's, and a request
    /// needs about half a round trip to arrive. Covers RTT up to about 1 s.
    const keep_alive_margin_seconds = 1;
    /// Idle connections kept per origin across isolations. Two covers the usual
    /// concurrency per origin (for example Account with Models on Metask, or a
    /// title with a permission review) without one origin filling every slot.
    const origin_idle_limit = 2;
    /// A rescan costs about 2-4 ms (46 roots, 50 KB measured on Windows 10), so
    /// root store changes reach every slot within one connection lifetime.
    const ca_rescan_seconds = lifetime_seconds;

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
        isolation: Isolation = .public,
        /// The owner retired this isolation while the slot was busy.
        retire_on_release: bool = false,
        /// A socket write of the current request returned success.
        wrote: bool = false,
        socket_writes: *const Io.Writer.VTable = undefined,
        watched_writes: Io.Writer.VTable = undefined,
        created: Io.Clock.Timestamp = undefined,
        idle: Io.Clock.Timestamp = undefined,
        /// From the last response's Keep-Alive timeout, else the default.
        idle_limit: Io.Duration = .fromSeconds(idle_seconds),
        ca_scanned: ?Io.Clock.Timestamp = null,

        fn idleConnection(slot: *Slot) ?*Client.Connection {
            const node = slot.client.connection_pool.free.first orelse return null;
            return @alignCast(@fieldParentPtr("pool_node", node));
        }

        fn expired(slot: *const Slot, now: Io.Clock.Timestamp) bool {
            return slot.idle.durationTo(now).raw.nanoseconds >= slot.idle_limit.nanoseconds or
                slot.created.durationTo(now).raw.toSeconds() >= lifetime_seconds;
        }

        fn sameOrigin(connection: *Client.Connection, protocol: Client.Protocol, port: u16, host: Io.net.HostName) bool {
            return connection.protocol == protocol and connection.port == port and connection.host().eql(host);
        }
    };

    const Lease = struct {
        slot: *Slot,
        reuse: bool,
        /// This owner's expired idle connections, reserved for closing.
        expired: [slot_count]*Slot = undefined,
        expired_count: usize = 0,
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
        const Outcome = union(enum) { completed: T, cancelled: void, deadline: void, connect_budget: void };
        const started: Io.Clock.Timestamp = .now(self.io, .awake);
        var operation: Operation = .{ .engine = self, .control = control, .connect_end = switch (control.budget) {
            .deadline => |deadline| deadline,
            .connect => |duration| started.addDuration(.{ .raw = duration, .clock = .awake }),
        } };
        self.mutex.lockUncancelable(self.io);
        const id = self.next_id;
        self.next_id +%= 1;
        self.mutex.unlock(self.io);
        defer if (operation.failure) |err| if (err != error.Cancelled) {
            // Only typed facts. No endpoint, headers, payload or backend message.
            // Connection attempts are counts only: never addresses or hosts.
            const attempts = &operation.attempts;
            std.log.warn("http id={d} consumer={s} phase={s} cause={s} send={s} reused={} retried={} elapsed_ms={d} addresses={d} attempted={d} tls={d} connect={d} capped={d}", .{
                id,                            @tagName(control.consumer),        @tagName(operation.phase),                      @errorName(err),    @tagName(operation.sendFact()),
                operation.reused,              operation.retried,                 started.untilNow(self.io).raw.toMilliseconds(), attempts.addresses, attempts.attempted.load(.monotonic),
                attempts.tls.load(.monotonic), attempts.connect.load(.monotonic), attempts.capped.load(.monotonic),
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
            var surplus: ?*Slot = null;
            var retired: ?*Slot = null;
            if (operation.slot) |slot| {
                std.debug.assert(slot.client.connection_pool.used.first == null);
                slot.idle = .now(self.io, .awake);
                slot.idle_limit = operation.idle_limit;
                if (slot.retire_on_release) {
                    slot.retire_on_release = false;
                    if (slot.idleConnection() != null) retired = slot;
                } else if (slot.idleConnection() != null) surplus = self.originSurplus(slot);
                // A retired slot stays busy until evict closes its connection.
                if (retired == null) slot.busy = false;
            }
            self.mutex.unlock(self.io);
            if (retired) |slot| self.evict(slot);
            if (surplus) |victim| self.evict(victim);
        }
        var storage: [3]Outcome = undefined;
        var selection: Io.Select(Outcome) = .init(self.io, &storage);
        const selected: union(enum) { value: Outcome, failed: Error } = selected: {
            // Register controls first: a registration failure must close the send
            // gate before canceling any worker, even if a dependency eats cancel.
            switch (control.budget) {
                .deadline => selection.concurrent(.deadline, Operation.waitDeadline, .{&operation}) catch break :selected .{ .failed = error.ResourceLimit },
                .connect => selection.concurrent(.connect_budget, Operation.waitConnectBudget, .{&operation}) catch break :selected .{ .failed = error.ResourceLimit },
            }
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
            .reused = operation.reused,
            .retried = operation.retried,
            .outcome = switch (selected) {
                .failed => |err| .{ .failed = err },
                .value => |value| switch (value) {
                    .completed => |completed| .{ .completed = completed },
                    .cancelled => .{ .failed = error.Cancelled },
                    .deadline => .{ .failed = error.DeadlineExceeded },
                    // Read after the join: the worker no longer writes phase.
                    .connect_budget => .{ .failed = operation.connectExpiry() },
                },
            },
        };
        if (result.outcome == .failed) operation.failure = result.outcome.failed;
        return result;
    }

    /// An exact idle match (most recently used first), else a slot without an
    /// idle connection, else the least recently used idle slot, expired first.
    fn lease(self: *Engine, criteria: Client.ConnectionPool.Criteria, isolation: Isolation) Lease {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const now: Io.Clock.Timestamp = .now(self.io, .awake);
        var exact: ?*Slot = null;
        var empty: ?*Slot = null;
        var oldest: ?*Slot = null;
        for (&self.slots) |*slot| {
            if (slot.busy) continue;
            const connection = slot.idleConnection() orelse {
                if (empty == null) empty = slot;
                continue;
            };
            const stale = slot.expired(now);
            if (!stale and isolation.eql(slot.isolation) and Slot.sameOrigin(connection, criteria.protocol, criteria.port, criteria.host)) {
                if (exact == null or slot.idle.raw.nanoseconds > exact.?.idle.raw.nanoseconds) exact = slot;
            }
            if (oldest) |current| {
                const current_stale = current.expired(now);
                if (stale and !current_stale) oldest = slot else if (stale == current_stale and slot.idle.raw.nanoseconds < current.idle.raw.nanoseconds) oldest = slot;
            } else oldest = slot;
        }
        var chosen: Lease = if (exact) |slot| .{ .slot = slot, .reuse = true } else .{ .slot = empty orelse oldest.?, .reuse = false }; // admission reserves a slot per call
        chosen.slot.busy = true;
        // An expired connection of this owner can never serve it again.
        for (&self.slots) |*slot| {
            if (slot.busy) continue;
            const connection = slot.idleConnection() orelse continue;
            if (!slot.expired(now) or !isolation.eql(slot.isolation) or !Slot.sameOrigin(connection, criteria.protocol, criteria.port, criteria.host)) continue;
            slot.busy = true;
            chosen.expired[chosen.expired_count] = slot;
            chosen.expired_count += 1;
        }
        // Under the mutex, so a concurrent retire sees the new owner.
        chosen.slot.isolation = isolation;
        return chosen;
    }

    /// Closes idle connections of this isolation now; one in use closes when
    /// its request ends. Owners call this when the identity stops being valid.
    pub fn retire(self: *Engine, isolation: Isolation) void {
        var idle: [slot_count]*Slot = undefined;
        var count: usize = 0;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            for (&self.slots) |*slot| {
                if (!slot.isolation.eql(isolation)) continue;
                if (slot.busy) {
                    slot.retire_on_release = true;
                } else if (slot.idleConnection() != null) {
                    slot.busy = true;
                    idle[count] = slot;
                    count += 1;
                }
            }
        }
        for (idle[0..count]) |slot| self.evict(slot);
    }

    /// Caller holds the mutex. Returns the oldest other idle connection of the
    /// same origin when the origin is over its idle limit, reserved for evict.
    fn originSurplus(self: *Engine, released: *Slot) ?*Slot {
        const connection = released.idleConnection().?;
        var count: usize = 1;
        var oldest: ?*Slot = null;
        for (&self.slots) |*slot| {
            if (slot == released or slot.busy) continue;
            const other = slot.idleConnection() orelse continue;
            if (!Slot.sameOrigin(other, connection.protocol, connection.port, connection.host())) continue;
            count += 1;
            if (oldest == null or slot.idle.raw.nanoseconds < oldest.?.idle.raw.nanoseconds) oldest = slot;
        }
        if (count <= origin_idle_limit) return null;
        oldest.?.busy = true;
        return oldest;
    }

    fn evict(self: *Engine, slot: *Slot) void {
        discardIdle(slot);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        slot.busy = false;
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
    retried: bool = false,
    /// Idle limit for the connection after this response.
    idle_limit: Io.Duration = .fromSeconds(Engine.idle_seconds),
    /// End of DNS, TCP and TLS: the deadline, or admission plus the connect budget.
    connect_end: Io.Clock.Timestamp,
    /// 0 establishing, 1 established in time, 2 connect budget expired first.
    connect_state: std.atomic.Value(u8) = .init(0),
    attempts: Attempts = .{},

    /// Written by connection lanes, read after they join.
    const Attempts = struct {
        addresses: usize = 0,
        attempted: std.atomic.Value(usize) = .init(0),
        tls: std.atomic.Value(usize) = .init(0),
        connect: std.atomic.Value(usize) = .init(0),
        capped: std.atomic.Value(usize) = .init(0),
    };

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
        if (self.control.budget == .deadline) {
            const deadline = self.control.budget.deadline;
            if (deadline.raw.nanoseconds <= deadline.clock.now(self.io()).nanoseconds) return self.fail(error.DeadlineExceeded);
        }
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
        self.control.budget.deadline.wait(self.io()) catch return;
        self.stop();
    }

    /// Ends the call only if DNS, TCP and TLS are still running at the end of
    /// the connect budget. Once a connection is in hand the waiter parks until
    /// the call's own selection cancels it.
    fn waitConnectBudget(self: *Operation) void {
        self.connect_end.wait(self.io()) catch return;
        if (self.connect_state.cmpxchgStrong(0, 2, .acq_rel, .acquire) == null) {
            self.stop();
            return;
        }
        var parked: Io.Event = .unset;
        parked.wait(self.io()) catch {};
    }

    /// The most specific connection failure: TLS over TCP over DNS.
    fn connectExpiry(self: *const Operation) Error {
        return switch (self.phase) {
            .resolve => error.DnsFailed,
            else => if (self.attempts.tls.load(.monotonic) != 0) error.TlsFailed else error.ConnectFailed,
        };
    }

    /// Claims the connection for this call unless the connect budget already
    /// ended it; a late connection never authorizes an HTTP write.
    fn established(self: *Operation) bool {
        return self.connect_state.cmpxchgStrong(0, 1, .acq_rel, .acquire) == null;
    }

    fn waitCancellation(self: *Operation) void {
        const cancellation = self.control.cancellation.?;
        cancellation.wait_fn(self.io(), cancellation.context) catch return;
        self.stop();
    }

    pub const Options = struct {
        headers: []const std.http.Header = &.{},
        standard_headers: Client.Request.Headers = .{},
        /// Whether a reused connection that failed before any response byte
        /// may resend this request; null means GET and HEAD only. POST is
        /// never replayable.
        replayable: ?bool = null,
    };

    pub fn open(self: *Operation, method: std.http.Method, uri: std.Uri, options: Options) Error!Request {
        try self.check();
        if (self.slot != null) return self.fail(error.InvalidRequest);
        const protocol = Client.Protocol.fromUri(uri) orelse return self.fail(error.InvalidRequest);
        if (uri.user != null or uri.password != null) return self.fail(error.InvalidRequest);
        var host_storage: [Io.net.HostName.max_len]u8 = undefined;
        const host = uri.getHost(&host_storage) catch return self.fail(error.InvalidRequest);
        for (options.headers) |header| {
            if (header.name.len == 0 or std.mem.indexOfAny(u8, header.name, "\r\n:") != null or std.mem.indexOfAny(u8, header.value, "\r\n") != null) return self.fail(error.InvalidRequest);
        }
        const replayable = options.replayable orelse (method == .GET or method == .HEAD);
        if (method == .POST and replayable) return self.fail(error.InvalidRequest);
        inline for (@typeInfo(Client.Request.Headers).@"struct".fields) |field| switch (@field(options.standard_headers, field.name)) {
            .default, .omit => {},
            .override => |bytes| if (std.mem.indexOfAny(u8, bytes, "\r\n") != null) return self.fail(error.InvalidRequest),
        };
        const criteria: Client.ConnectionPool.Criteria = .{ .host = host, .port = uri.port orelse @as(u16, if (protocol == .tls) 443 else 80), .protocol = protocol };
        const lease = self.engine.lease(criteria, self.control.isolation);
        for (lease.expired[0..lease.expired_count]) |stale| self.engine.evict(stale);
        const slot = lease.slot;
        self.slot = slot;
        const client = &slot.client;
        var connection: ?*Client.Connection = null;
        if (lease.reuse) {
            const candidate = slot.idleConnection().?;
            client.connection_pool.acquire(self.io(), candidate);
            if (idle_probe.probe(self.io(), candidate) == .idle) {
                connection = candidate;
                self.reused = true;
            } else dispose(candidate);
        } else Engine.discardIdle(slot);
        if (connection == null) {
            if (protocol == .tls) try self.refreshTls(slot);
            connection = try self.connect(client, criteria);
            slot.created = .now(self.io(), .awake);
        }
        errdefer dispose(connection.?);
        if (!self.established()) return self.fail(error.Cancelled);
        watchWrites(slot, connection.?);
        try self.check();
        return .{
            .operation = self,
            .raw = try self.request(client, connection.?, method, uri, options),
            .method = method,
            .uri = uri,
            .options = options,
            .replayable = replayable,
        };
    }

    fn request(self: *Operation, client: *Client, connection: *Client.Connection, method: std.http.Method, uri: std.Uri, options: Options) Error!Client.Request {
        return client.request(method, uri, .{ .connection = connection, .redirect_behavior = .unhandled, .extra_headers = options.headers, .headers = options.standard_headers }) catch |err| return self.fail(if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidRequest);
    }

    /// Every new TLS connection validates certificates against the current
    /// time. The root store is rescanned into a fresh bundle when due; a failed
    /// rescan keeps the previous bundle and fails only when there is none.
    fn refreshTls(self: *Operation, slot: *Engine.Slot) Error!void {
        const client = &slot.client;
        const now = Io.Clock.real.now(self.io());
        const due = if (slot.ca_scanned) |scanned| scanned.untilNow(self.io()).raw.toSeconds() >= Engine.ca_rescan_seconds else true;
        if (due) {
            var bundle: std.crypto.Certificate.Bundle = .empty;
            defer bundle.deinit(client.allocator);
            if (bundle.rescan(client.allocator, self.io(), now)) {
                client.ca_bundle_lock.lockUncancelable(self.io());
                defer client.ca_bundle_lock.unlock(self.io());
                std.mem.swap(std.crypto.Certificate.Bundle, &client.ca_bundle, &bundle);
                slot.ca_scanned = .now(self.io(), .awake);
            } else |err| {
                if (err == error.Canceled) return self.fail(error.Cancelled);
                if (slot.ca_scanned == null) return self.fail(error.TlsFailed);
                std.log.warn("http consumer={s} root certificate rescan failed; keeping the previous bundle", .{@tagName(self.control.consumer)});
            }
        }
        client.now = now;
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

    /// A retry has its own establishment window. Under a connect budget the
    /// budget waiter has already let go, so every attempt is capped instead.
    fn connect(self: *Operation, client: *Client, criteria: Client.ConnectionPool.Criteria) Error!*Client.Connection {
        var addresses: [16]Io.net.IpAddress = undefined;
        const count = try self.resolve(criteria.host, criteria.port, &addresses);
        self.phase = .connect;
        self.attempts.addresses = count;
        var race: ConnectRace = .{ .operation = self, .client = client, .criteria = criteria, .addresses = addresses[0..count], .end = self.connect_end, .cap_last = self.retried and self.control.budget == .connect };
        var storage: [ConnectRace.lanes]ConnectRace.Outcome = undefined;
        var selection: Io.Select(ConnectRace.Outcome) = .init(self.io(), &storage);
        defer {
            race.stopped.store(true, .release);
            while (selection.cancel()) |outcome| switch (outcome) {
                inline else => |lane| if (lane == .connected) dispose(lane.connected),
            };
        }
        const lanes: usize = @min(count, ConnectRace.lanes);
        selection.concurrent(.first, ConnectRace.run, .{&race}) catch return self.fail(error.ResourceLimit);
        if (lanes > 1) selection.concurrent(.second, ConnectRace.run, .{&race}) catch return self.fail(error.ResourceLimit);
        for (0..lanes) |_| {
            const outcome = selection.await() catch return self.fail(error.Cancelled);
            switch (switch (outcome) {
                inline else => |lane| lane,
            }) {
                .connected => |connection| return connection,
                .exhausted => {},
                .failed => |err| return self.fail(err),
            }
        }
        // Unattempted addresses are not failures; TLS outranks TCP.
        return self.fail(if (self.attempts.tls.load(.monotonic) != 0) error.TlsFailed else error.ConnectFailed);
    }
};

/// RFC 8305 style establishment with at most two attempts in flight. The next
/// address starts once the previous start is at least 250 ms old and a lane is
/// free. Only an attempt with later addresses behind it is capped, so the last
/// or only address keeps the whole remaining budget.
const ConnectRace = struct {
    const lanes = 2;
    const attempt_delay: Io.Duration = .fromMilliseconds(250);
    const minimum_attempt: Io.Duration = .fromSeconds(2);
    const Lane = union(enum) { connected: *Client.Connection, exhausted: void, failed: Error };
    const Outcome = union(enum) { first: Lane, second: Lane };
    const Attempt = union(enum) { connected: *Client.Connection, tls: void, connect: void, capped: void, failed: Error };

    operation: *Operation,
    client: *Client,
    criteria: Client.ConnectionPool.Criteria,
    addresses: []const Io.net.IpAddress,
    end: Io.Clock.Timestamp,
    /// Without a waiter on the budget, the last attempt is capped as well.
    cap_last: bool,
    mutex: Io.Mutex = .init,
    next: usize = 0,
    last_start: ?Io.Clock.Timestamp = null,
    stopped: std.atomic.Value(bool) = .init(false),

    const Reservation = struct { index: usize, start: Io.Clock.Timestamp };

    fn reserve(self: *ConnectRace, io: Io) ?Reservation {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.next == self.addresses.len) return null;
        var start: Io.Clock.Timestamp = .now(io, .awake);
        if (self.last_start) |previous| {
            const paced = previous.addDuration(.{ .raw = attempt_delay, .clock = .awake });
            if (paced.raw.nanoseconds > start.raw.nanoseconds) start = paced;
        }
        self.last_start = start;
        defer self.next += 1;
        return .{ .index = self.next, .start = start };
    }

    /// Shares the remaining budget among the addresses not yet started, with a
    /// two-second floor; never more than what remains.
    fn cap(self: *const ConnectRace, io: Io, index: usize) ?Io.Duration {
        const last = index + 1 == self.addresses.len;
        if (last and !self.cap_last) return null;
        const remaining = self.end.durationFromNow(io).raw.nanoseconds;
        if (remaining <= 0) return .fromNanoseconds(0);
        if (last) return .fromNanoseconds(remaining);
        const share = @divTrunc(remaining, @as(i96, @intCast(self.addresses.len - index)));
        return .fromNanoseconds(@min(remaining, @max(share, minimum_attempt.nanoseconds)));
    }

    fn stopping(self: *const ConnectRace) bool {
        return self.stopped.load(.acquire) or self.operation.gate.load(.acquire) & 2 != 0;
    }

    fn run(self: *ConnectRace) Lane {
        const io = self.operation.io();
        while (true) {
            // Workers only read control state; phase/failure belong to the caller.
            if (self.stopping()) return .{ .failed = error.Cancelled };
            const reservation = self.reserve(io) orelse return .exhausted;
            const wait = reservation.start.durationFromNow(io).raw;
            if (wait.nanoseconds > 0) Io.sleep(io, wait, .awake) catch return .{ .failed = error.Cancelled };
            if (self.stopping()) return .{ .failed = error.Cancelled };
            const attempts = &self.operation.attempts;
            _ = attempts.attempted.fetchAdd(1, .monotonic);
            switch (self.attempt(io, reservation.index)) {
                .connected => |connection| {
                    if (self.stopping()) {
                        dispose(connection);
                        return .{ .failed = error.Cancelled };
                    }
                    return .{ .connected = connection };
                },
                .tls => _ = attempts.tls.fetchAdd(1, .monotonic),
                .connect => _ = attempts.connect.fetchAdd(1, .monotonic),
                .capped => _ = attempts.capped.fetchAdd(1, .monotonic),
                .failed => |err| return .{ .failed = err },
            }
        }
    }

    fn attempt(self: *ConnectRace, io: Io, index: usize) Attempt {
        var buffer: [128]u8 = undefined;
        var writer: Io.Writer = .fixed(&buffer);
        self.addresses[index].formatResolved(io, &writer) catch return .connect;
        const formatted = writer.buffered();
        const options: Client.ConnectTcpOptions = .{
            .host = .{ .bytes = switch (self.addresses[index]) {
                .ip4 => formatted[0..std.mem.lastIndexOfScalar(u8, formatted, ':').?],
                .ip6 => formatted[1..std.mem.lastIndexOfScalar(u8, formatted, ']').?],
            } },
            .port = self.criteria.port,
            .protocol = self.criteria.protocol,
            // Public seam: numeric routing, original SNI/certificate identity.
            .proxied_host = self.criteria.host,
            .proxied_port = self.criteria.port,
        };
        const limit = self.cap(io, index) orelse return classify(Client.connectTcpOptions(self.client, options));
        const Capped = union(enum) { connected: Client.ConnectTcpError!*Client.Connection, timeout: void };
        var storage: [2]Capped = undefined;
        var selection: Io.Select(Capped) = .init(io, &storage);
        defer while (selection.cancel()) |outcome| switch (outcome) {
            .connected => |result| if (result) |connection| dispose(connection) else |_| {},
            .timeout => {},
        };
        selection.concurrent(.timeout, sleepFor, .{ io, limit }) catch return .{ .failed = error.ResourceLimit };
        selection.concurrent(.connected, Client.connectTcpOptions, .{ self.client, options }) catch return .{ .failed = error.ResourceLimit };
        return switch (selection.await() catch return .{ .failed = error.Cancelled }) {
            .timeout => .capped,
            .connected => |result| classify(result),
        };
    }

    fn sleepFor(io: Io, duration: Io.Duration) void {
        Io.sleep(io, duration, .awake) catch {};
    }

    fn classify(result: Client.ConnectTcpError!*Client.Connection) Attempt {
        const connection = result catch |err| return switch (err) {
            error.Canceled => .{ .failed = error.Cancelled },
            error.OutOfMemory => .{ .failed = error.OutOfMemory },
            error.TlsInitializationFailed => .tls,
            else => .connect,
        };
        return .{ .connected = connection };
    }
};

pub const Request = struct {
    operation: *Operation,
    raw: Client.Request,
    received: bool = false,
    method: std.http.Method,
    uri: std.Uri,
    options: Operation.Options,
    replayable: bool,
    /// Borrowed from the caller and kept only for a single retry.
    body: ?[]const u8 = null,

    pub fn deinit(self: *Request) void {
        const connection = self.raw.connection.?;
        const slot = self.operation.slot.?;
        const reusable = self.received and (self.raw.reader.state == .ready or !self.raw.method.responseHasBody()) and
            self.operation.idle_limit.nanoseconds > 0 and
            slot.created.untilNow(self.operation.io()).raw.toSeconds() < Engine.lifetime_seconds;
        connection.closing = connection.closing or !reusable or self.operation.gate.load(.acquire) & 2 != 0;
        // Do not let std Request.deinit drain an abandoned GET while canceling.
        self.raw.connection = null;
        self.raw.deinit();
        connection.client.connection_pool.release(connection, self.operation.io());
        self.* = undefined;
    }

    pub fn send(self: *Request, body: ?[]const u8) Error!void {
        try self.operation.admitSend();
        self.body = body;
        self.write() catch {
            if (!self.retryAllowed(.send, error.WriteFailed)) return self.operation.fail(error.WriteFailed);
            try self.retry();
            self.write() catch return self.operation.fail(error.WriteFailed);
        };
    }

    fn write(self: *Request) error{WriteFailed}!void {
        self.operation.slot.?.wrote = false;
        if (self.body) |bytes| {
            self.raw.transfer_encoding = .{ .content_length = bytes.len };
            var writer = try self.raw.sendBodyUnflushed(&.{});
            try writer.writer.writeAll(bytes);
            try writer.end();
            try self.raw.connection.?.flush();
        } else try self.raw.sendBodiless();
    }

    /// Only a pooled connection's failure may be retried, once, on a new
    /// connection, and never for POST: (a) the request wrote nothing to the
    /// socket, or (b) it is replayable and not one response byte arrived.
    fn retryAllowed(self: *Request, stage: enum { send, head }, cause: anyerror) bool {
        const operation = self.operation;
        if (!operation.reused or operation.retried or self.method == .POST) return false;
        const connection = self.raw.connection.?;
        switch (stage) {
            .send => if (!operation.slot.?.wrote) return true,
            .head => switch (cause) {
                // EOF before the first head byte.
                error.HttpConnectionClosing => {},
                // A transport reset, not a TLS protocol failure. Windows
                // reports a reset read as Unexpected.
                error.ReadFailed => switch (connection.getReadError() orelse return false) {
                    error.ConnectionResetByPeer, error.Unexpected => {},
                    else => return false,
                },
                else => return false,
            },
        }
        return self.replayable and connection.reader().bufferedLen() == 0;
    }

    fn retry(self: *Request) Error!void {
        const operation = self.operation;
        try operation.check();
        operation.retried = true;
        const slot = operation.slot.?;
        const failed = self.raw.connection.?;
        self.raw.connection = null;
        self.raw.deinit();
        dispose(failed);
        var host_storage: [Io.net.HostName.max_len]u8 = undefined;
        const host = self.uri.getHost(&host_storage) catch return operation.fail(error.InvalidRequest);
        const protocol = Client.Protocol.fromUri(self.uri).?;
        const criteria: Client.ConnectionPool.Criteria = .{ .host = host, .port = self.uri.port orelse @as(u16, if (protocol == .tls) 443 else 80), .protocol = protocol };
        if (operation.control.budget == .connect) operation.connect_end = Io.Clock.Timestamp.now(operation.io(), .awake).addDuration(.{ .raw = operation.control.budget.connect, .clock = .awake });
        if (protocol == .tls) try operation.refreshTls(slot);
        const connection = try operation.connect(&slot.client, criteria);
        slot.created = .now(operation.io(), .awake);
        watchWrites(slot, connection);
        self.raw = operation.request(&slot.client, connection, self.method, self.uri, self.options) catch |err| {
            dispose(connection);
            return err;
        };
        self.received = false;
        operation.phase = .send;
    }

    pub fn receiveHead(self: *Request) Error!Client.Response {
        self.operation.phase = .head;
        const response = self.raw.receiveHead(&.{}) catch |err| response: {
            if (!self.retryAllowed(.head, err)) return self.operation.fail(headError(err));
            try self.retry();
            self.write() catch return self.operation.fail(error.WriteFailed);
            self.operation.phase = .head;
            break :response self.raw.receiveHead(&.{}) catch |again| return self.operation.fail(headError(again));
        };
        self.received = true;
        self.operation.idle_limit = idleLimit(&response.head);
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

/// min(Keep-Alive timeout - margin, default). A timeout at or below the margin
/// means the connection is not kept; no or an unparsable hint keeps the default.
fn idleLimit(head: *const Client.Response.Head) Io.Duration {
    const default: Io.Duration = .fromSeconds(Engine.idle_seconds);
    var headers = head.iterateHeaders();
    while (headers.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "keep-alive")) continue;
        var parameters = std.mem.tokenizeScalar(u8, header.value, ',');
        while (parameters.next()) |parameter| {
            const trimmed = std.mem.trim(u8, parameter, " \t");
            const separator = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
            if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, trimmed[0..separator], " \t"), "timeout")) continue;
            const seconds = std.fmt.parseInt(u32, std.mem.trim(u8, trimmed[separator + 1 ..], " \t"), 10) catch return default;
            if (seconds <= Engine.keep_alive_margin_seconds) return .fromNanoseconds(0);
            return .fromSeconds(@min(seconds - Engine.keep_alive_margin_seconds, Engine.idle_seconds));
        }
    }
    return default;
}

fn headError(err: Client.Request.ReceiveHeadError) Error {
    return switch (err) {
        error.HttpHeadersInvalid, error.HttpHeadersOversize, error.HttpContentEncodingUnsupported => error.InvalidResponse,
        else => error.ReadFailed,
    };
}

/// std exposes no count of bytes written, so a slot interposes on the socket
/// writer's drain. Every plain and TLS write passes through it: the TLS client
/// holds a pointer to this interface and reads its vtable on each call. Tests
/// fail in both directions if a std change bypasses this.
fn watchWrites(slot: *Engine.Slot, connection: *Client.Connection) void {
    const writer = &connection.stream_writer.interface;
    if (writer.vtable == &slot.watched_writes) return;
    slot.socket_writes = writer.vtable;
    slot.watched_writes = writer.vtable.*;
    slot.watched_writes.drain = watchedDrain;
    writer.vtable = &slot.watched_writes;
}

fn watchedDrain(writer: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
    const stream: *Io.net.Stream.Writer = @alignCast(@fieldParentPtr("interface", writer));
    const connection: *Client.Connection = @alignCast(@fieldParentPtr("stream_writer", stream));
    const slot: *Engine.Slot = @alignCast(@fieldParentPtr("client", connection.client));
    const buffered = writer.end;
    const consumed = try slot.socket_writes.drain(writer, data, splat);
    // drain consumes buffered bytes by lowering `end`, then reports the rest.
    if (consumed != 0 or writer.end < buffered) slot.wrote = true;
    return consumed;
}

comptime {
    // The write watch depends on these std shapes; a change fails the build.
    std.debug.assert(@FieldType(Client.Connection, "stream_writer") == Io.net.Stream.Writer);
    std.debug.assert(@FieldType(Io.net.Stream.Writer, "interface") == Io.Writer);
    std.debug.assert(@FieldType(Io.Writer, "vtable") == *const Io.Writer.VTable);
    std.debug.assert(@FieldType(Client, "connection_pool") == Client.ConnectionPool);
}

fn dispose(connection: *Client.Connection) void {
    connection.closing = true;
    connection.client.connection_pool.release(connection, connection.client.io);
}

test "HTTP Keep-Alive timeout parsing keeps a one second margin under the default" {
    const cases = [_]struct { header: ?[]const u8, seconds: i64 }{
        .{ .header = null, .seconds = 30 },
        .{ .header = "timeout=5, max=100", .seconds = 4 },
        .{ .header = "max=5,timeout=20", .seconds = 19 },
        .{ .header = "Timeout = 75", .seconds = 30 },
        .{ .header = "timeout=2", .seconds = 1 },
        .{ .header = "timeout=1", .seconds = 0 },
        .{ .header = "timeout=0", .seconds = 0 },
        .{ .header = "timeout=soon", .seconds = 30 },
        .{ .header = "max=100", .seconds = 30 },
    };
    for (cases) |case| {
        var buffer: [128]u8 = undefined;
        const bytes = if (case.header) |value|
            try std.fmt.bufPrint(&buffer, "HTTP/1.1 200 OK\r\nKeep-Alive: {s}\r\n\r\n", .{value})
        else
            "HTTP/1.1 200 OK\r\n\r\n";
        const head = try Client.Response.Head.parse(bytes);
        try std.testing.expectEqual(@as(i96, case.seconds * std.time.ns_per_s), idleLimit(&head).nanoseconds);
    }
}

test {
    _ = @import("http_transport_test.zig");
    _ = @import("http_idle_probe.zig");
}
