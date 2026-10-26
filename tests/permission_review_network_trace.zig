//! Counts-only, single-evaluation diagnostic over the original Io callbacks.
//! Does not replace HTTP/TLS, inspect bytes, or modify the underlying Io table.
const std = @import("std");
const agent = @import("metawork_agent");
const net = std.Io.net;
const Counter = std.atomic.Value(u64);
const Stage = enum { dns, connect, read, write };

const Counts = struct {
    calls: Counter = .init(0),
    pending: Counter = .init(0),
    bytes: Counter = .init(0),
    errors: Counter = .init(0),
    total_ms: Counter = .init(0),
    max_ms: Counter = .init(0),
    last_started_ms: Counter = .init(0),
    last_completed_ms: Counter = .init(0),
};

pub const StageView = struct {
    calls: u64,
    pending: u64,
    bytes: u64,
    errors: u64,
    total_ms: u64,
    max_ms: u64,
    last_started_ms: ?u64,
    last_completed_ms: ?u64,
};

pub const Snapshot = struct {
    elapsed_ms: u64,
    dns: StageView,
    connect: StageView,
    read: StageView,
    write: StageView,
};

/// Exactly one traced Io in this opt-in process. Create it before starting
/// requests and deinit only after review has joined its watchdog and all I/O.
pub const Trace = struct {
    original: std.Io,
    table: std.Io.VTable,
    network: agent.CompletionTransport = undefined,
    started: ?std.Io.Clock.Timestamp = null,
    counts: [4]Counts = @splat(.{}),
    running: bool = false,
    has_started: std.atomic.Value(bool) = .init(false),
    prepared: bool = false,
    finished: ?Snapshot = null,
    at_cancel: ?Snapshot = null,
    cancelled_before_transport: bool = false,

    var active: ?*Trace = null;

    pub fn init(self: *Trace, original: std.Io) !void {
        if (active != null) return error.DiagnosticTraceAlreadyActive;
        self.* = .{ .original = original, .table = original.vtable.* };
        self.table.netLookup = lookup;
        self.table.netConnectIp = connect;
        self.table.netRead = read;
        self.table.netWrite = write;
        active = self;
    }

    pub fn deinit(self: *Trace) void {
        std.debug.assert(active == self and !self.running);
        active = null;
    }

    pub fn io(self: *Trace) std.Io {
        // Unchanged callbacks still receive their real implementation context.
        return .{ .userdata = self.original.userdata, .vtable = &self.table };
    }

    pub fn wrap(self: *Trace, network: agent.CompletionTransport) agent.CompletionTransport {
        self.network = network;
        return .{ .context = self, .perform_fn = perform, .signal_cancellation_fn = cancel };
    }

    /// Reset before creating each fresh Cancellation, including early failure
    /// paths that never enter the transport.
    pub fn prepare(self: *Trace) void {
        std.debug.assert(!self.running);
        self.counts = @splat(.{});
        self.started = null;
        self.has_started.store(false, .release);
        self.finished = null;
        self.at_cancel = null;
        self.cancelled_before_transport = false;
        self.prepared = true;
    }

    pub fn report(self: *const Trace) struct { finished: ?Snapshot, at_cancel: ?Snapshot, cancelled_before_transport: bool } {
        std.debug.assert(!self.running);
        return .{ .finished = self.finished, .at_cancel = self.at_cancel, .cancelled_before_transport = self.cancelled_before_transport };
    }

    fn perform(context: ?*anyopaque, request: agent.CompletionHttpRequest, cancellation: *const agent.CompletionCancellation, output: []u8) agent.CompletionTransportError!agent.CompletionTransportResponse {
        const self: *Trace = @ptrCast(@alignCast(context.?));
        std.debug.assert(!self.running and self.prepared);
        self.prepared = false;
        self.started = std.Io.Clock.Timestamp.now(self.original, .awake);
        self.has_started.store(true, .release);
        self.running = true;
        defer {
            self.finished = self.snapshot();
            self.running = false;
        }
        return self.network.perform(request, cancellation, output);
    }

    fn cancel(context: ?*anyopaque, cancellation: *agent.CompletionCancellation) void {
        const self: *Trace = @ptrCast(@alignCast(context.?));
        // Cancellation signals exactly once. The caller joins this callback's
        // watchdog before report/reset/deinit, so this owned snapshot is stable.
        const started = self.has_started.load(.acquire);
        self.cancelled_before_transport = !started;
        self.at_cancel = if (started) self.snapshot() else null;
        if (self.network.signal_cancellation_fn) |signal| signal(self.network.context, cancellation);
    }

    fn current(context: ?*anyopaque) *Trace {
        const self = active.?;
        std.debug.assert(context == self.original.userdata);
        return self;
    }

    fn elapsed(self: *const Trace) u64 {
        const started = self.started orelse return 0;
        return @intCast(@max(0, started.durationTo(std.Io.Clock.Timestamp.now(self.original, .awake)).raw.toMilliseconds()));
    }

    fn begin(self: *Trace, stage: Stage) u64 {
        const counts = &self.counts[@intFromEnum(stage)];
        const start = self.elapsed();
        _ = counts.calls.fetchAdd(1, .monotonic);
        _ = counts.pending.fetchAdd(1, .monotonic);
        counts.last_started_ms.store(start, .monotonic);
        return start;
    }

    fn end(self: *Trace, stage: Stage, start: u64) void {
        const counts = &self.counts[@intFromEnum(stage)];
        const now = self.elapsed();
        _ = counts.total_ms.fetchAdd(now -| start, .monotonic);
        _ = counts.max_ms.fetchMax(now -| start, .monotonic);
        counts.last_completed_ms.store(now, .monotonic);
        _ = counts.pending.fetchSub(1, .release);
    }

    fn view(self: *const Trace, stage: Stage) StageView {
        const c = &self.counts[@intFromEnum(stage)];
        const calls = c.calls.load(.acquire);
        const pending = c.pending.load(.acquire);
        return .{
            .calls = calls,
            .pending = pending,
            .bytes = c.bytes.load(.acquire),
            .errors = c.errors.load(.acquire),
            .total_ms = c.total_ms.load(.acquire),
            .max_ms = c.max_ms.load(.acquire),
            .last_started_ms = if (calls != 0) c.last_started_ms.load(.acquire) else null,
            .last_completed_ms = if (calls > pending) c.last_completed_ms.load(.acquire) else null,
        };
    }

    fn snapshot(self: *const Trace) Snapshot {
        return .{ .elapsed_ms = self.elapsed(), .dns = self.view(.dns), .connect = self.view(.connect), .read = self.view(.read), .write = self.view(.write) };
    }

    fn lookup(context: ?*anyopaque, host: net.HostName, results: *std.Io.Queue(net.HostName.LookupResult), options: net.HostName.LookupOptions) net.HostName.LookupError!void {
        const self = current(context);
        const start = self.begin(.dns);
        defer self.end(.dns, start);
        self.original.vtable.netLookup(context, host, results, options) catch |err| {
            _ = self.counts[@intFromEnum(Stage.dns)].errors.fetchAdd(1, .monotonic);
            return err;
        };
    }

    fn connect(context: ?*anyopaque, address: *const net.IpAddress, options: net.IpAddress.ConnectOptions) net.IpAddress.ConnectError!net.Socket {
        const self = current(context);
        const start = self.begin(.connect);
        defer self.end(.connect, start);
        return self.original.vtable.netConnectIp(context, address, options) catch |err| {
            _ = self.counts[@intFromEnum(Stage.connect)].errors.fetchAdd(1, .monotonic);
            return err;
        };
    }

    fn read(context: ?*anyopaque, socket: net.Socket.Handle, data: [][]u8) net.Stream.Reader.Error!usize {
        const self = current(context);
        const start = self.begin(.read);
        defer self.end(.read, start);
        const size = self.original.vtable.netRead(context, socket, data) catch |err| {
            _ = self.counts[@intFromEnum(Stage.read)].errors.fetchAdd(1, .monotonic);
            return err;
        };
        _ = self.counts[@intFromEnum(Stage.read)].bytes.fetchAdd(size, .monotonic);
        return size;
    }

    fn write(context: ?*anyopaque, socket: net.Socket.Handle, header: []const u8, data: []const []const u8, splat: usize) net.Stream.Writer.Error!usize {
        const self = current(context);
        const start = self.begin(.write);
        defer self.end(.write, start);
        const size = self.original.vtable.netWrite(context, socket, header, data, splat) catch |err| {
            _ = self.counts[@intFromEnum(Stage.write)].errors.fetchAdd(1, .monotonic);
            return err;
        };
        _ = self.counts[@intFromEnum(Stage.write)].bytes.fetchAdd(size, .monotonic);
        return size;
    }
};
