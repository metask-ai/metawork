const std = @import("std");
const http = @import("http_transport.zig");
const contract = @import("metawork_http_contract");
const Io = std.Io;

const Reply = struct { status: u16, length: usize };

/// A successful call carries no diagnostic, and every failure carries one
/// naming the same cause, including a failure the called function returned.
fn expectDiagnosedOutcome(result: anytype) !void {
    const failure: ?http.Error = switch (result.outcome) {
        .completed => |value| if (value) |_| null else |err| err,
        .failed => |err| err,
    };
    if (failure) |err| try std.testing.expectEqual(http.causeOf(err), result.diagnostic.?.cause) else try std.testing.expect(result.diagnostic == null);
}

fn fetch(operation: *http.Operation, url: []const u8, body: ?[]const u8, output: []u8) http.Error!Reply {
    const uri = std.Uri.parse(url) catch return error.InvalidRequest;
    var request = try operation.open(if (body != null) .POST else .GET, uri, .{});
    defer request.deinit();
    try request.send(body);
    var response = try request.receiveHead();
    const bytes = try request.readAll(&response, output);
    return .{ .status = @intFromEnum(response.head.status), .length = bytes.len };
}

test "HTTP fixed execution closes controls and consumes a real response" {
    const GetServer = struct {
        listener: *Io.net.Server,
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            self.serve() catch |err| {
                self.failure = err;
            };
        }
        fn serve(self: *@This()) !void {
            var connection = try self.listener.accept(std.testing.io);
            defer connection.close(std.testing.io);
            var reads: [4096]u8 = undefined;
            var writes: [4096]u8 = undefined;
            var reader = connection.reader(std.testing.io, &reads);
            var writer = connection.writer(std.testing.io, &writes);
            var server: std.http.Server = .init(&reader.interface, &writer.interface);
            var request = try server.receiveHead();
            try std.testing.expectEqualStrings("/fixture", request.head.target);
            try request.respond("{}", .{ .keep_alive = false });
        }
    };
    var threaded: Io.Threaded = .init(std.testing.allocator, .{ .async_limit = .nothing });
    defer threaded.deinit();
    var engine: http.Engine = undefined;
    engine.init(std.testing.allocator, threaded.io());
    defer engine.deinit();
    const address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = try address.listen(std.testing.io, .{});
    defer listener.deinit(std.testing.io);
    var server: GetServer = .{ .listener = &listener };
    const thread = try std.Thread.spawn(.{}, GetServer.run, .{&server});
    defer thread.join();
    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/fixture", .{listener.socket.address.getPort()});
    defer std.testing.allocator.free(url);
    var output: [8]u8 = undefined;
    const result = engine.run(.{ .consumer = .update, .isolation = .public, .budget = .{ .deadline = .fromNow(engine.io, .{ .raw = .fromSeconds(3), .clock = .awake }) } }, fetch, .{ url, null, &output });
    try std.testing.expect(result.outcome == .completed);
    const reply = try result.outcome.completed;
    try std.testing.expectEqual(@as(u16, 200), reply.status);
    try std.testing.expectEqualStrings("{}", output[0..reply.length]);
    try std.testing.expectEqual(contract.Send.may_have_been_sent, result.send);
    try expectDiagnosedOutcome(result);
}

const Faults = struct {
    const Mode = enum { first_v4, first_v6, two_stalled, late_connect, slow_dns, refused, slow_single, tls_then_refused, stalled_single };
    var original: Io = undefined;
    var mode: Mode = .first_v4;
    var active: std.atomic.Value(usize) = .init(0);
    var attempts: std.atomic.Value(usize) = .init(0);
    var late: std.atomic.Value(usize) = .init(0);
    var dns_active: std.atomic.Value(usize) = .init(0);
    /// The next this many socket writes fail before any byte is accepted.
    var failing_writes: std.atomic.Value(usize) = .init(0);
    /// Start time of each connection attempt, in attempt order.
    var starts: [8]Io.Clock.Timestamp = undefined;

    fn reset(io: Io, selected: Mode) void {
        original = io;
        mode = selected;
        active.store(0, .monotonic);
        attempts.store(0, .monotonic);
        late.store(0, .monotonic);
        dns_active.store(0, .monotonic);
        failing_writes.store(0, .monotonic);
    }

    fn write(userdata: ?*anyopaque, handle: Io.net.Socket.Handle, header: []const u8, data: []const []const u8, splat: usize) Io.net.Stream.Writer.Error!usize {
        while (true) {
            const pending = failing_writes.load(.acquire);
            if (pending == 0) break;
            if (failing_writes.cmpxchgWeak(pending, pending - 1, .acq_rel, .acquire) == null) return error.ConnectionResetByPeer;
        }
        return original.vtable.netWrite(userdata, handle, header, data, splat);
    }

    fn startedAfter(first: usize, second: usize) i64 {
        return starts[first].durationTo(starts[second]).raw.toMilliseconds();
    }

    fn lookup(userdata: ?*anyopaque, host: Io.net.HostName, queue: *Io.Queue(Io.net.HostName.LookupResult), options: Io.net.HostName.LookupOptions) Io.net.HostName.LookupError!void {
        if (!std.mem.eql(u8, host.bytes, "fixture.test")) return original.vtable.netLookup(userdata, host, queue, options);
        defer queue.close(original);
        _ = dns_active.fetchAdd(1, .monotonic);
        defer _ = dns_active.fetchSub(1, .monotonic);
        if (mode == .slow_dns) {
            Io.sleep(original, .fromSeconds(30), .awake) catch {
                _ = late.fetchAdd(1, .monotonic);
                Io.sleep(original, .fromMilliseconds(30), .awake) catch {};
            };
        }
        if (mode == .slow_single or mode == .stalled_single) {
            var only: Io.net.IpAddress = .{ .ip4 = .loopback(options.port) };
            if (mode == .stalled_single) only.ip4.bytes[3] = 2;
            queue.putOne(original, .{ .address = only }) catch return error.Canceled;
            return;
        }
        if (mode == .tls_then_refused) {
            // The TLS peer first, then an address that refuses TCP.
            queue.putOne(original, .{ .address = .{ .ip4 = .loopback(options.port) } }) catch return error.Canceled;
            var refusing: Io.net.IpAddress = .{ .ip4 = .loopback(options.port) };
            refusing.ip4.bytes[3] = 4;
            queue.putOne(original, .{ .address = refusing }) catch return error.Canceled;
            return;
        }
        var slow: Io.net.IpAddress = .{ .ip4 = .loopback(options.port) };
        if (mode == .first_v6) slow = .{ .ip6 = .loopback(options.port) } else slow.ip4.bytes[3] = 2;
        if (mode != .slow_dns) queue.putOne(original, .{ .address = slow }) catch return error.Canceled;
        if (mode == .two_stalled) {
            slow.ip4.bytes[3] = 3;
            queue.putOne(original, .{ .address = slow }) catch return error.Canceled;
        }
        queue.putOne(original, .{ .address = .{ .ip4 = .loopback(options.port) } }) catch return error.Canceled;
    }

    fn connect(userdata: ?*anyopaque, address: *const Io.net.IpAddress, options: Io.net.IpAddress.ConnectOptions) Io.net.IpAddress.ConnectError!Io.net.Socket {
        _ = active.fetchAdd(1, .monotonic);
        defer _ = active.fetchSub(1, .monotonic);
        const index = attempts.fetchAdd(1, .monotonic);
        if (index < starts.len) starts[index] = .now(original, .awake);
        if (mode == .refused) return error.ConnectionRefused;
        if (address.* == .ip4 and address.ip4.bytes[3] == 4) return error.ConnectionRefused;
        // A slow but healthy only address: TCP alone exceeds three seconds.
        if (mode == .slow_single) try Io.sleep(original, .fromMilliseconds(3500), .awake);
        if (address.* == .ip6 or address.ip4.bytes[3] != 1) {
            try Io.sleep(original, .fromSeconds(30), .awake);
            return error.NetworkUnreachable;
        }
        if (mode == .late_connect) Io.sleep(original, .fromSeconds(30), .awake) catch {
            // Models a nested async task acknowledging cancellation and then
            // returning a connection anyway: it must not authorize an HTTP write.
            _ = late.fetchAdd(1, .monotonic);
        };
        return original.vtable.netConnectIp(userdata, address, options);
    }
};

const Server = struct {
    listener: *Io.net.Server,
    mode: enum { complete, lost, no_http },
    requests: usize = 0,
    failure: ?anyerror = null,

    fn run(self: *@This()) void {
        self.serve() catch |err| {
            self.failure = err;
        };
    }
    fn serve(self: *@This()) !void {
        var connection = try self.listener.accept(std.testing.io);
        defer connection.close(std.testing.io);
        var reads: [4096]u8 = undefined;
        var writes: [4096]u8 = undefined;
        var reader = connection.reader(std.testing.io, &reads);
        var writer = connection.writer(std.testing.io, &writes);
        if (self.mode == .no_http) {
            try std.testing.expectError(error.EndOfStream, reader.interface.takeByte());
            return;
        }
        var server: std.http.Server = .init(&reader.interface, &writer.interface);
        var request = try server.receiveHead();
        self.requests += 1;
        var body: [4]u8 = undefined;
        try request.readerExpectNone(&.{}).readSliceAll(&body);
        try std.testing.expectEqualStrings("body", &body);
        if (self.mode == .complete) try request.respond("{}", .{ .keep_alive = false });
    }
};

test "HTTP races both same-family and dual-stack addresses with async quota zero" {
    for ([_]Faults.Mode{ .first_v4, .first_v6, .two_stalled }) |mode| {
        var threaded: Io.Threaded = .init(std.testing.allocator, .{ .async_limit = .nothing });
        defer threaded.deinit();
        Faults.reset(threaded.io(), mode);
        var vtable = threaded.io().vtable.*;
        vtable.netLookup = Faults.lookup;
        vtable.netConnectIp = Faults.connect;
        const io: Io = .{ .userdata = threaded.io().userdata, .vtable = &vtable };
        var engine: http.Engine = undefined;
        engine.init(std.testing.allocator, io);
        defer engine.deinit();
        const address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        var listener = try address.listen(std.testing.io, .{});
        defer listener.deinit(std.testing.io);
        var server: Server = .{ .listener = &listener, .mode = .complete };
        const thread = try std.Thread.spawn(.{}, Server.run, .{&server});
        const url = try std.fmt.allocPrint(std.testing.allocator, "http://fixture.test:{d}/post", .{listener.socket.address.getPort()});
        defer std.testing.allocator.free(url);
        var output: [8]u8 = undefined;
        const result = engine.run(.{ .consumer = .metask, .isolation = .public, .budget = .{ .deadline = .fromNow(io, .{ .raw = .fromSeconds(5), .clock = .boot }) } }, fetch, .{ url, "body", &output });
        thread.join();
        try std.testing.expectEqual(@as(?anyerror, null), server.failure);
        try std.testing.expect(result.outcome == .completed);
        try std.testing.expectEqual(@as(u16, 200), (try result.outcome.completed).status);
        try std.testing.expectEqual(@as(usize, 1), server.requests);
        try std.testing.expectEqual(@as(usize, if (mode == .two_stalled) 3 else 2), Faults.attempts.load(.acquire));
        try std.testing.expectEqual(@as(usize, 0), Faults.active.load(.acquire));
        try std.testing.expectEqual(@as(usize, 0), Faults.dns_active.load(.acquire));
    }
}

test "HTTP cancellation closes send admission before a late connection returns" {
    var threaded: Io.Threaded = .init(std.testing.allocator, .{ .async_limit = .nothing });
    defer threaded.deinit();
    Faults.reset(threaded.io(), .late_connect);
    var vtable = threaded.io().vtable.*;
    vtable.netConnectIp = Faults.connect;
    const io: Io = .{ .userdata = threaded.io().userdata, .vtable = &vtable };
    var engine: http.Engine = undefined;
    engine.init(std.testing.allocator, io);
    defer engine.deinit();
    const address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = try address.listen(std.testing.io, .{});
    defer listener.deinit(std.testing.io);
    var server: Server = .{ .listener = &listener, .mode = .no_http };
    const thread = try std.Thread.spawn(.{}, Server.run, .{&server});
    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/post", .{listener.socket.address.getPort()});
    defer std.testing.allocator.free(url);
    var output: [8]u8 = undefined;
    const result = engine.run(.{ .consumer = .metask, .isolation = .public, .budget = .{ .deadline = .fromNow(io, .{ .raw = .fromMilliseconds(50), .clock = .boot }) } }, fetch, .{ url, "body", &output });
    thread.join();
    try std.testing.expectEqual(@as(?anyerror, null), server.failure);
    try std.testing.expectEqual(error.DeadlineExceeded, result.outcome.failed);
    try std.testing.expectEqual(contract.Send.not_sent, result.send);
    try expectDiagnosedOutcome(result);
    // The deadline fell while a connection was being established.
    try std.testing.expectEqual(contract.Phase.connect, result.diagnostic.?.phase);
    try std.testing.expectEqual(@as(usize, 1), Faults.late.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), Faults.active.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), server.requests);
}

/// Rejects the TLS handshake with a fatal alert after reading ClientHello.
const TlsReject = struct {
    listener: *Io.net.Server,
    delay: Io.Duration,
    failure: ?anyerror = null,

    fn run(self: *@This()) void {
        self.serve() catch |err| {
            self.failure = err;
        };
    }
    fn serve(self: *@This()) !void {
        var connection = try self.listener.accept(std.testing.io);
        defer connection.close(std.testing.io);
        var reads: [4096]u8 = undefined;
        var writes: [64]u8 = undefined;
        var reader = connection.reader(std.testing.io, &reads);
        var writer = connection.writer(std.testing.io, &writes);
        var record_header: [5]u8 = undefined;
        try reader.interface.readSliceAll(&record_header);
        try reader.interface.discardAll(std.mem.readInt(u16, record_header[3..5], .big));
        try Io.sleep(std.testing.io, self.delay, .awake);
        try writer.interface.writeAll(&.{ 21, 3, 3, 0, 2, 2, 40 });
        try writer.interface.flush();
    }
};

fn faultIo(threaded: *Io.Threaded, vtable: *Io.VTable, mode: Faults.Mode) Io {
    Faults.reset(threaded.io(), mode);
    vtable.* = threaded.io().vtable.*;
    vtable.netLookup = Faults.lookup;
    vtable.netConnectIp = Faults.connect;
    vtable.netWrite = Faults.write;
    return .{ .userdata = threaded.io().userdata, .vtable = vtable };
}

test "HTTP only address keeps the whole remaining budget beyond three seconds" {
    for ([_]bool{ false, true }) |connect_budget| {
        var threaded: Io.Threaded = .init(std.testing.allocator, .{ .async_limit = .nothing });
        defer threaded.deinit();
        var vtable: Io.VTable = undefined;
        const io = faultIo(&threaded, &vtable, .slow_single);
        var engine: http.Engine = undefined;
        engine.init(std.testing.allocator, io);
        defer engine.deinit();
        const address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        var listener = try address.listen(std.testing.io, .{});
        defer listener.deinit(std.testing.io);
        var server: Server = .{ .listener = &listener, .mode = .complete };
        const thread = try std.Thread.spawn(.{}, Server.run, .{&server});
        const url = try std.fmt.allocPrint(std.testing.allocator, "http://fixture.test:{d}/post", .{listener.socket.address.getPort()});
        defer std.testing.allocator.free(url);
        var output: [8]u8 = undefined;
        const budget: http.Budget = if (connect_budget) .{ .connect = .fromSeconds(6) } else .{ .deadline = .fromNow(io, .{ .raw = .fromSeconds(6), .clock = .awake }) };
        const started: Io.Clock.Timestamp = .now(io, .awake);
        const result = engine.run(.{ .consumer = .metask, .isolation = .public, .budget = budget }, fetch, .{ url, "body", &output });
        const elapsed = started.untilNow(io).raw.toMilliseconds();
        thread.join();
        try std.testing.expectEqual(@as(?anyerror, null), server.failure);
        try std.testing.expectEqual(@as(u16, 200), (try result.outcome.completed).status);
        try std.testing.expectEqual(@as(usize, 1), Faults.attempts.load(.acquire));
        try std.testing.expect(elapsed >= 3500);
    }
}

test "HTTP slow TLS rejection on the only address stays a TLS failure" {
    var engine: http.Engine = undefined;
    engine.init(std.testing.allocator, std.testing.io);
    defer engine.deinit();
    const address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = try address.listen(std.testing.io, .{});
    defer listener.deinit(std.testing.io);
    var server: TlsReject = .{ .listener = &listener, .delay = .fromMilliseconds(3500) };
    const thread = try std.Thread.spawn(.{}, TlsReject.run, .{&server});
    const url = try std.fmt.allocPrint(std.testing.allocator, "https://127.0.0.1:{d}/post", .{listener.socket.address.getPort()});
    defer std.testing.allocator.free(url);
    var output: [8]u8 = undefined;
    const started: Io.Clock.Timestamp = .now(engine.io, .awake);
    const result = engine.run(.{ .consumer = .metask, .isolation = .public, .budget = .{ .deadline = .fromNow(engine.io, .{ .raw = .fromSeconds(6), .clock = .awake }) } }, fetch, .{ url, "body", &output });
    const elapsed = started.untilNow(engine.io).raw.toMilliseconds();
    thread.join();
    try std.testing.expectEqual(@as(?anyerror, null), server.failure);
    try std.testing.expectError(error.TlsFailed, result.outcome.completed);
    try std.testing.expectEqual(contract.Send.not_sent, result.send);
    try std.testing.expect(elapsed >= 3500);
}

test "HTTP TLS failure is not replaced by later connection failures or idle lanes" {
    var threaded: Io.Threaded = .init(std.testing.allocator, .{ .async_limit = .nothing });
    defer threaded.deinit();
    var vtable: Io.VTable = undefined;
    const io = faultIo(&threaded, &vtable, .tls_then_refused);
    var engine: http.Engine = undefined;
    engine.init(std.testing.allocator, io);
    defer engine.deinit();
    const address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = try address.listen(std.testing.io, .{});
    defer listener.deinit(std.testing.io);
    var server: TlsReject = .{ .listener = &listener, .delay = .fromNanoseconds(0) };
    const thread = try std.Thread.spawn(.{}, TlsReject.run, .{&server});
    const url = try std.fmt.allocPrint(std.testing.allocator, "https://fixture.test:{d}/post", .{listener.socket.address.getPort()});
    defer std.testing.allocator.free(url);
    var output: [8]u8 = undefined;
    const result = engine.run(.{ .consumer = .metask, .isolation = .public, .budget = .{ .deadline = .fromNow(io, .{ .raw = .fromSeconds(6), .clock = .awake }) } }, fetch, .{ url, "body", &output });
    thread.join();
    try std.testing.expectEqual(@as(?anyerror, null), server.failure);
    try std.testing.expectError(error.TlsFailed, result.outcome.completed);
    try std.testing.expectEqual(@as(usize, 2), Faults.attempts.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), Faults.active.load(.acquire));
}

test "HTTP starts later addresses 250 ms apart and caps only attempts with addresses behind them" {
    var threaded: Io.Threaded = .init(std.testing.allocator, .{ .async_limit = .nothing });
    defer threaded.deinit();
    var vtable: Io.VTable = undefined;
    // Two stalled addresses, then a reachable one.
    const io = faultIo(&threaded, &vtable, .two_stalled);
    var engine: http.Engine = undefined;
    engine.init(std.testing.allocator, io);
    defer engine.deinit();
    const address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = try address.listen(std.testing.io, .{});
    defer listener.deinit(std.testing.io);
    var server: Server = .{ .listener = &listener, .mode = .complete };
    const thread = try std.Thread.spawn(.{}, Server.run, .{&server});
    const url = try std.fmt.allocPrint(std.testing.allocator, "http://fixture.test:{d}/post", .{listener.socket.address.getPort()});
    defer std.testing.allocator.free(url);
    var output: [8]u8 = undefined;
    // 6 s over three addresses: the first attempt is capped at max(2 s, 6 s / 3).
    const result = engine.run(.{ .consumer = .metask, .isolation = .public, .budget = .{ .deadline = .fromNow(io, .{ .raw = .fromSeconds(6), .clock = .awake }) } }, fetch, .{ url, "body", &output });
    thread.join();
    try std.testing.expectEqual(@as(?anyerror, null), server.failure);
    try std.testing.expectEqual(@as(u16, 200), (try result.outcome.completed).status);
    try std.testing.expectEqual(@as(usize, 3), Faults.attempts.load(.acquire));
    const second = Faults.startedAfter(0, 1);
    try std.testing.expect(second >= 240 and second < 600);
    const third = Faults.startedAfter(0, 2);
    try std.testing.expect(third >= 1900 and third < 2700);
    try std.testing.expectEqual(@as(usize, 0), Faults.active.load(.acquire));
}

test "HTTP connect budget ends DNS and TCP with their typed failures before any send" {
    for ([_]Faults.Mode{ .slow_dns, .stalled_single }) |mode| {
        var threaded: Io.Threaded = .init(std.testing.allocator, .{ .async_limit = .nothing });
        defer threaded.deinit();
        var vtable: Io.VTable = undefined;
        const io = faultIo(&threaded, &vtable, mode);
        var engine: http.Engine = undefined;
        engine.init(std.testing.allocator, io);
        defer engine.deinit();
        var output: [8]u8 = undefined;
        const result = engine.run(.{ .consumer = .completion, .isolation = .public, .budget = .{ .connect = .fromMilliseconds(200) } }, fetch, .{ "http://fixture.test/post", "body", &output });
        try std.testing.expectEqual(@as(http.Error, if (mode == .slow_dns) error.DnsFailed else error.ConnectFailed), result.outcome.failed);
        try std.testing.expectEqual(contract.Send.not_sent, result.send);
        try expectDiagnosedOutcome(result);
        try std.testing.expectEqual(@as(contract.Phase, if (mode == .slow_dns) .resolve else .connect), result.diagnostic.?.phase);
        try std.testing.expectEqual(@as(usize, 0), Faults.dns_active.load(.acquire));
        try std.testing.expectEqual(@as(usize, 0), Faults.active.load(.acquire));
        try std.testing.expectEqual(@as(usize, if (mode == .slow_dns) 0 else 1), Faults.attempts.load(.acquire));
        try std.testing.expectEqual(@as(usize, 0), engine.resolving);
    }
}

test "HTTP retains resolver capacity and borrowed inputs until canceled DNS joins" {
    var threaded: Io.Threaded = .init(std.testing.allocator, .{ .async_limit = .nothing });
    defer threaded.deinit();
    Faults.reset(threaded.io(), .slow_dns);
    var vtable = threaded.io().vtable.*;
    vtable.netLookup = Faults.lookup;
    vtable.netConnectIp = Faults.connect;
    const io: Io = .{ .userdata = threaded.io().userdata, .vtable = &vtable };
    var engine: http.Engine = undefined;
    engine.init(std.testing.allocator, io);
    defer engine.deinit();
    var output: [8]u8 = undefined;
    const result = engine.run(.{ .consumer = .metask, .isolation = .public, .budget = .{ .deadline = .fromNow(io, .{ .raw = .fromMilliseconds(20), .clock = .awake }) } }, fetch, .{ "http://fixture.test/post", "body", &output });
    try std.testing.expectEqual(error.DeadlineExceeded, result.outcome.failed);
    try std.testing.expectEqual(contract.Send.not_sent, result.send);
    try expectDiagnosedOutcome(result);
    try std.testing.expectEqual(contract.Phase.resolve, result.diagnostic.?.phase);
    try std.testing.expectEqual(@as(usize, 1), Faults.late.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), Faults.dns_active.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), Faults.attempts.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), engine.resolving);
}

test "HTTP lost POST response is never replayed and retains may-sent evidence" {
    var engine: http.Engine = undefined;
    engine.init(std.testing.allocator, std.testing.io);
    defer engine.deinit();
    const address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = try address.listen(std.testing.io, .{});
    defer listener.deinit(std.testing.io);
    var server: Server = .{ .listener = &listener, .mode = .lost };
    const thread = try std.Thread.spawn(.{}, Server.run, .{&server});
    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/post", .{listener.socket.address.getPort()});
    defer std.testing.allocator.free(url);
    var output: [8]u8 = undefined;
    const result = engine.run(.{ .consumer = .metask, .isolation = .public, .budget = .{ .deadline = .fromNow(engine.io, .{ .raw = .fromSeconds(3), .clock = .boot }) } }, fetch, .{ url, "body", &output });
    thread.join();
    try std.testing.expectEqual(@as(?anyerror, null), server.failure);
    try std.testing.expectEqual(@as(usize, 1), server.requests);
    try std.testing.expectError(error.ReadFailed, result.outcome.completed);
    try std.testing.expectEqual(contract.Send.may_have_been_sent, result.send);
    // A failure the called function returned is diagnosed like a selected one.
    try expectDiagnosedOutcome(result);
    try std.testing.expectEqual(contract.Phase.head, result.diagnostic.?.phase);
}

test "HTTP no capacity and preexisting controls refuse work without sending" {
    for (0..4) |capacity| {
        var threaded: Io.Threaded = .init(std.testing.allocator, .{ .async_limit = .nothing, .concurrent_limit = .limited(capacity) });
        defer threaded.deinit();
        var engine: http.Engine = undefined;
        engine.init(std.testing.allocator, threaded.io());
        defer engine.deinit();
        var state: std.atomic.Value(u32) = .init(0);
        var output: [8]u8 = undefined;
        const control: http.Control = .{ .consumer = .completion, .isolation = .public, .cancellation = .atomic(&state), .budget = .{ .deadline = .fromNow(engine.io, .{ .raw = .fromSeconds(3), .clock = .boot }) } };
        const result = engine.run(control, fetch, .{ "http://127.0.0.1:1/post", "body", &output });
        if (result.outcome == .completed) try std.testing.expectError(error.ResourceLimit, result.outcome.completed) else try std.testing.expectEqual(error.ResourceLimit, result.outcome.failed);
        try std.testing.expectEqual(contract.Send.not_sent, result.send);
        state.store(1, .release);
        const cancelled = engine.run(control, fetch, .{ "http://127.0.0.1:1/post", "body", &output });
        try std.testing.expectEqual(error.Cancelled, cancelled.outcome.failed);
        try std.testing.expectEqual(contract.Send.not_sent, cancelled.send);
    }
}

test "HTTP selected complete result survives cancellation in loser cleanup" {
    const Fixture = struct {
        state: std.atomic.Value(u32) = .init(0),
        waiting: Io.Event = .unset,
        fn requested(context: *const anyopaque) bool {
            const self: *const @This() = @ptrCast(@alignCast(context));
            return self.state.load(.acquire) != 0;
        }
        fn wait(io: Io, context: *const anyopaque) Io.Cancelable!void {
            const self: *@This() = @ptrCast(@alignCast(@constCast(context)));
            self.waiting.set(io);
            Io.sleep(io, .fromSeconds(30), .awake) catch {
                self.state.store(1, .release);
                return error.Canceled;
            };
        }
        fn complete(op: *http.Operation, self: *@This()) u8 {
            self.waiting.waitUncancelable(op.io());
            return 42;
        }
    };
    var engine: http.Engine = undefined;
    engine.init(std.testing.allocator, std.testing.io);
    defer engine.deinit();
    var fixture: Fixture = .{};
    const result = engine.run(.{ .consumer = .metask, .isolation = .public, .budget = .{ .deadline = .fromNow(engine.io, .{ .raw = .fromSeconds(30), .clock = .awake }) }, .cancellation = .{ .context = &fixture, .requested_fn = Fixture.requested, .wait_fn = Fixture.wait } }, Fixture.complete, .{&fixture});
    try std.testing.expectEqual(@as(u8, 42), result.outcome.completed);
    try std.testing.expectEqual(@as(u32, 1), fixture.state.load(.acquire));
}

fn authorizedFetch(operation: *http.Operation, url: []const u8, token: []const u8, output: []u8) http.Error!Reply {
    var headers = [_]std.http.Header{.{ .name = "Authorization", .value = token }};
    var request = try operation.open(.GET, std.Uri.parse(url) catch return error.InvalidRequest, .{ .headers = &headers });
    defer request.deinit();
    try request.send(null);
    var response = try request.receiveHead();
    const bytes = try request.readAll(&response, output);
    return .{ .status = @intFromEnum(response.head.status), .length = bytes.len };
}

test "HTTP reuses an owner's connection across token rotation and retires stale idle sockets" {
    for ([_]bool{ false, true }) |close_first| {
        const pool = try Pool.create(.{ .connections = if (close_first) 2 else 1, .close_first = close_first });
        defer pool.destroy();
        var engine: http.Engine = undefined;
        engine.init(std.testing.allocator, std.testing.io);
        defer engine.deinit();
        var url_buffer: [64]u8 = undefined;
        const url = pool.url(&url_buffer);
        var reused: [3]bool = undefined;
        for (&reused, 0..) |*value, index| {
            // The stale idle socket must be visible before the probe runs.
            if (close_first and index == 1) try pool.waitClosed(0);
            var output: [8]u8 = undefined;
            const result = engine.run(.{ .consumer = .completion, .isolation = .public, .budget = .{ .deadline = .fromNow(engine.io, .{ .raw = .fromSeconds(3), .clock = .boot }) } }, authorizedFetch, .{ url, if (index == 2) "Bearer second" else "Bearer first", &output });
            try std.testing.expectEqual(@as(u16, 200), (try result.outcome.completed).status);
            value.* = result.reused;
        }
        // A rotated token keeps the owner's isolation and its connection.
        try std.testing.expectEqualSlices(bool, if (close_first) &.{ false, false, true } else &.{ false, true, true }, &reused);
        try std.testing.expectEqual(@as(usize, if (close_first) 2 else 1), pool.accepted.load(.acquire));
        try std.testing.expectEqual(@as(?anyerror, null), pool.failure);
    }
}

// Keep-alive peer serving each accepted connection on its own thread until the
/// client closes it. Counts connections and requests, and records which
/// connection served each request.
const Pool = struct {
    listener: Io.net.Server,
    options: Options,
    accepted: std.atomic.Value(usize) = .init(0),
    requests: std.atomic.Value(usize) = .init(0),
    served_by: [64]usize = @splat(0),
    closed: [16]std.atomic.Value(bool) = @splat(.init(false)),
    failure: ?anyerror = null,
    acceptor: ?std.Thread = null,

    const Action = enum {
        respond,
        /// Read the request head, then close without any response byte.
        drop,
        /// Send part of a response head, then close.
        truncate,
        /// Send the head and part of the body, cancel the client through
        /// `cancel_on_drop`, then wait for the client to close.
        stall,
    };

    const Options = struct {
        /// Exactly how many connections the peer accepts before it stops.
        connections: usize,
        /// The first connection closes right after its first response.
        close_first: bool = false,
        /// What the peer does with the nth request on the nth connection.
        action: *const fn (connection: usize, request: usize) Action = respondAlways,
        /// Sent as the Keep-Alive header of every response.
        keep_alive: ?[]const u8 = null,
        /// Every response body.
        body: []const u8 = "{}",
    };

    fn respondAlways(_: usize, _: usize) Action {
        return .respond;
    }

    /// Set by a test so the peer cancels the client as it drops a request.
    var cancel_on_drop: ?*std.atomic.Value(u32) = null;

    fn create(options: Options) !*Pool {
        const self = try std.testing.allocator.create(Pool);
        errdefer std.testing.allocator.destroy(self);
        const address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        self.* = .{ .listener = try address.listen(std.testing.io, .{}), .options = options };
        self.acceptor = try std.Thread.spawn(.{}, acceptAll, .{self});
        return self;
    }

    /// The engine must have closed every pooled connection (deinit) first.
    fn destroy(self: *Pool) void {
        if (self.acceptor) |thread| thread.join();
        self.listener.deinit(std.testing.io);
        std.testing.allocator.destroy(self);
    }

    fn url(self: *Pool, buffer: []u8) []const u8 {
        return std.fmt.bufPrint(buffer, "http://127.0.0.1:{d}/fixture", .{self.listener.socket.address.getPort()}) catch unreachable;
    }

    fn acceptAll(self: *Pool) void {
        var threads: [16]?std.Thread = @splat(null);
        defer for (threads) |thread| if (thread) |value| value.join();
        for (0..self.options.connections) |index| {
            const stream = self.listener.accept(std.testing.io) catch |err| {
                self.failure = err;
                return;
            };
            _ = self.accepted.fetchAdd(1, .acq_rel);
            threads[index] = std.Thread.spawn(.{}, serve, .{ self, stream, index }) catch |err| {
                stream.close(std.testing.io);
                self.failure = err;
                return;
            };
        }
    }

    fn serve(self: *Pool, stream: Io.net.Stream, index: usize) void {
        defer {
            stream.close(std.testing.io);
            self.closed[index].store(true, .release);
        }
        var reads: [4096]u8 = undefined;
        var writes: [4096]u8 = undefined;
        var reader = stream.reader(std.testing.io, &reads);
        var writer = stream.writer(std.testing.io, &writes);
        var server: std.http.Server = .init(&reader.interface, &writer.interface);
        var served: usize = 0;
        while (true) : (served += 1) {
            var request = server.receiveHead() catch return;
            const number = self.requests.fetchAdd(1, .acq_rel);
            if (number < self.served_by.len) self.served_by[number] = index;
            switch (self.options.action(index, served)) {
                .respond => {},
                .drop => {
                    if (cancel_on_drop) |state| state.store(1, .release);
                    return;
                },
                .truncate => {
                    writer.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Le") catch {};
                    writer.interface.flush() catch {};
                    return;
                },
                .stall => {
                    writer.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 64\r\n\r\npartial") catch return;
                    writer.interface.flush() catch return;
                    if (cancel_on_drop) |state| {
                        state.store(1, .release);
                        std.testing.io.futexWake(u32, &state.raw, std.math.maxInt(u32));
                    }
                    _ = reader.interface.discardRemaining() catch {};
                    return;
                },
            }
            const keep_alive: []const std.http.Header = if (self.options.keep_alive) |value| &.{.{ .name = "Keep-Alive", .value = value }} else &.{};
            request.respond(self.options.body, .{ .keep_alive = true, .extra_headers = keep_alive }) catch return;
            if (index == 0 and self.options.close_first) return;
        }
    }

    fn waitClosed(self: *Pool, index: usize) !void {
        for (0..400) |_| {
            if (self.closed[index].load(.acquire)) return;
            Io.sleep(std.testing.io, .fromMilliseconds(5), .awake) catch {};
        }
        return error.TestUnexpectedResult;
    }
};

fn plainGet(operation: *http.Operation, url: []const u8, output: []u8) http.Error!Reply {
    var request = try operation.open(.GET, std.Uri.parse(url) catch return error.InvalidRequest, .{});
    defer request.deinit();
    try request.send(null);
    var response = try request.receiveHead();
    const bytes = try request.readAll(&response, output);
    return .{ .status = @intFromEnum(response.head.status), .length = bytes.len };
}

fn runScoped(engine: *http.Engine, url: []const u8, scope: []const u8) !bool {
    var output: [8]u8 = undefined;
    const result = engine.run(.{ .consumer = .mcp, .isolation = .of(.mcp_server, scope), .budget = .{ .deadline = .fromNow(engine.io, .{ .raw = .fromSeconds(5), .clock = .awake }) } }, plainGet, .{ url, &output });
    try std.testing.expectEqual(@as(u16, 200), (try result.outcome.completed).status);
    return result.reused;
}

test "HTTP alternating scopes keep their own pooled connections" {
    const pool = try Pool.create(.{ .connections = 2 });
    defer pool.destroy();
    var engine: http.Engine = undefined;
    engine.init(std.testing.allocator, std.testing.io);
    // Runs before the pool joins its connection threads.
    defer engine.deinit();
    var url_buffer: [64]u8 = undefined;
    const url = pool.url(&url_buffer);
    var reused: [6]bool = undefined;
    for (&reused, 0..) |*value, index| value.* = try runScoped(&engine, url, if (index % 2 == 0) "a" else "b");
    try std.testing.expectEqualSlices(bool, &.{ false, false, true, true, true, true }, &reused);
    try std.testing.expectEqual(@as(usize, 2), pool.accepted.load(.acquire));
    try std.testing.expectEqual(@as(?anyerror, null), pool.failure);
    // Scope "a" always lands on the first connection, "b" on the second.
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 0, 1, 0, 1 }, pool.served_by[0..6]);
}

test "HTTP isolation keys separate owners and namespaces without retaining identities" {
    const a = http.Isolation.of(.mcp_server, "server-1");
    try std.testing.expect(a.eql(.of(.mcp_server, "server-1")));
    try std.testing.expect(!a.eql(.of(.mcp_server, "server-2")));
    try std.testing.expect(!a.eql(.of(.completion_source, "server-1")));
    try std.testing.expect(!a.eql(.public));
    try std.testing.expect(std.mem.indexOf(u8, std.mem.asBytes(&a), "server-1") == null);
}

fn retireDuringBody(operation: *http.Operation, url: []const u8, output: []u8) http.Error!Reply {
    var request = try operation.open(.GET, std.Uri.parse(url) catch return error.InvalidRequest, .{});
    defer request.deinit();
    try request.send(null);
    var response = try request.receiveHead();
    // The owner's identity ends while its request is still in flight.
    operation.engine.retire(operation.control.isolation);
    const bytes = try request.readAll(&response, output);
    return .{ .status = @intFromEnum(response.head.status), .length = bytes.len };
}

test "HTTP retire closes idle connections now and in-flight ones on release" {
    const pool = try Pool.create(.{ .connections = 4 });
    defer pool.destroy();
    var engine: http.Engine = undefined;
    engine.init(std.testing.allocator, std.testing.io);
    defer engine.deinit();
    var url_buffer: [64]u8 = undefined;
    const url = pool.url(&url_buffer);
    try std.testing.expect(!try runScoped(&engine, url, "a"));
    try std.testing.expect(!try runScoped(&engine, url, "b"));
    try std.testing.expect(try runScoped(&engine, url, "a"));
    engine.retire(.of(.mcp_server, "a"));
    try pool.waitClosed(0);
    try std.testing.expect(try runScoped(&engine, url, "b"));
    try std.testing.expect(!try runScoped(&engine, url, "a"));
    var output: [8]u8 = undefined;
    const result = engine.run(.{ .consumer = .mcp, .isolation = .of(.mcp_server, "a"), .budget = .{ .deadline = .fromNow(engine.io, .{ .raw = .fromSeconds(5), .clock = .awake }) } }, retireDuringBody, .{ url, &output });
    try std.testing.expectEqual(@as(u16, 200), (try result.outcome.completed).status);
    try std.testing.expect(result.reused);
    try pool.waitClosed(2);
    try std.testing.expect(!try runScoped(&engine, url, "a"));
    try std.testing.expectEqual(@as(usize, 4), pool.accepted.load(.acquire));
    try std.testing.expect(!pool.closed[1].load(.acquire));
}

test "HTTP keeps at most two idle connections per origin and evicts the oldest" {
    const pool = try Pool.create(.{ .connections = 4 });
    defer pool.destroy();
    var engine: http.Engine = undefined;
    engine.init(std.testing.allocator, std.testing.io);
    // Runs before the pool joins its connection threads.
    defer engine.deinit();
    var url_buffer: [64]u8 = undefined;
    const url = pool.url(&url_buffer);
    var reused: [6]bool = undefined;
    for (&reused, [_][]const u8{ "a", "b", "c", "c", "b", "a" }) |*value, scope| value.* = try runScoped(&engine, url, scope);
    // The third idle connection evicted the oldest (scope "a").
    try pool.waitClosed(0);
    try std.testing.expectEqualSlices(bool, &.{ false, false, false, true, true, false }, &reused);
    try std.testing.expectEqual(@as(usize, 4), pool.accepted.load(.acquire));
}

test "HTTP evicts the least recently used slot only when every slot holds a connection" {
    const origins = 17;
    var pools: [origins]*Pool = undefined;
    var created: usize = 0;
    defer for (pools[0..created]) |pool| pool.destroy();
    for (&pools, 0..) |*pool, index| {
        pool.* = try Pool.create(.{ .connections = if (index == 0) 2 else 1 });
        created += 1;
    }
    var engine: http.Engine = undefined;
    engine.init(std.testing.allocator, std.testing.io);
    defer engine.deinit();
    var urls: [origins][64]u8 = undefined;
    for (&pools, 0..) |pool, index| try std.testing.expect(!try runScoped(&engine, pool.url(&urls[index]), "a"));
    // Sixteen slots: the seventeenth origin evicted the first.
    try pools[0].waitClosed(0);
    try std.testing.expect(try runScoped(&engine, pools[1].url(&urls[1]), "a"));
    try std.testing.expect(!try runScoped(&engine, pools[0].url(&urls[0]), "a"));
    try std.testing.expectEqual(@as(usize, 2), pools[0].accepted.load(.acquire));
}

test "HTTP refreshes the TLS clock on every new connection and rescans roots when due" {
    var engine: http.Engine = undefined;
    engine.init(std.testing.allocator, std.testing.io);
    defer engine.deinit();
    const address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = try address.listen(std.testing.io, .{});
    defer listener.deinit(std.testing.io);
    const url = try std.fmt.allocPrint(std.testing.allocator, "https://127.0.0.1:{d}/post", .{listener.socket.address.getPort()});
    defer std.testing.allocator.free(url);
    var scanned: [3]?Io.Clock.Timestamp = undefined;
    var clocks: [3]Io.Timestamp = undefined;
    for (0..3) |round| {
        if (round == 2) for (&engine.slots) |*slot| if (slot.ca_scanned) |value| {
            slot.ca_scanned = value.subDuration(.{ .raw = .fromSeconds(301), .clock = .awake });
        };
        var server: TlsReject = .{ .listener = &listener, .delay = .fromNanoseconds(0) };
        const thread = try std.Thread.spawn(.{}, TlsReject.run, .{&server});
        var output: [8]u8 = undefined;
        const result = engine.run(.{ .consumer = .metask, .isolation = .public, .budget = .{ .deadline = .fromNow(engine.io, .{ .raw = .fromSeconds(5), .clock = .awake }) } }, fetch, .{ url, "body", &output });
        thread.join();
        try std.testing.expectError(error.TlsFailed, result.outcome.completed);
        // A refused handshake leaves no idle connection: slot 0 is chosen again.
        scanned[round] = engine.slots[0].ca_scanned;
        clocks[round] = engine.slots[0].client.now.?;
    }
    try std.testing.expect(scanned[0] != null);
    try std.testing.expectEqual(scanned[0].?.raw.nanoseconds, scanned[1].?.raw.nanoseconds);
    try std.testing.expect(scanned[2].?.raw.nanoseconds > scanned[1].?.raw.nanoseconds);
    try std.testing.expect(clocks[1].nanoseconds > clocks[0].nanoseconds);
    try std.testing.expect(clocks[2].nanoseconds > clocks[1].nanoseconds);
}

fn methodFetch(operation: *http.Operation, url: []const u8, method: std.http.Method, output: []u8) http.Error!Reply {
    var request = try operation.open(method, std.Uri.parse(url) catch return error.InvalidRequest, .{});
    defer request.deinit();
    try request.send(if (method == .POST) "body" else null);
    var response = try request.receiveHead();
    const bytes = try request.readAll(&response, output);
    return .{ .status = @intFromEnum(response.head.status), .length = bytes.len };
}

fn runMethod(engine: *http.Engine, url: []const u8, method: std.http.Method) http.Result(http.Error!Reply) {
    var output: [8]u8 = undefined;
    return engine.run(.{ .consumer = .mcp, .isolation = .public, .budget = .{ .deadline = .fromNow(engine.io, .{ .raw = .fromSeconds(5), .clock = .awake }) } }, methodFetch, .{ url, method, &output });
}

/// The pooled connection fails on its second request; later ones respond.
fn dropSecond(connection: usize, request: usize) Pool.Action {
    return if (connection == 0 and request == 1) .drop else .respond;
}

fn truncateSecond(connection: usize, request: usize) Pool.Action {
    return if (connection == 0 and request == 1) .truncate else .respond;
}

fn dropAfterFirst(connection: usize, request: usize) Pool.Action {
    return if (connection == 0 and request == 0) .respond else .drop;
}

fn dropAlways(_: usize, _: usize) Pool.Action {
    return .drop;
}

test "HTTP retries a replayable request once when a pooled connection closes before any response byte" {
    const pool = try Pool.create(.{ .connections = 2, .action = dropSecond });
    defer pool.destroy();
    var engine: http.Engine = undefined;
    engine.init(std.testing.allocator, std.testing.io);
    defer engine.deinit();
    var url_buffer: [64]u8 = undefined;
    const url = pool.url(&url_buffer);
    _ = try runMethod(&engine, url, .GET).outcome.completed;
    const result = runMethod(&engine, url, .GET);
    try std.testing.expectEqual(@as(u16, 200), (try result.outcome.completed).status);
    try std.testing.expect(result.reused and result.retried);
    try std.testing.expectEqual(@as(usize, 3), pool.requests.load(.acquire));
    try std.testing.expectEqual(@as(usize, 2), pool.accepted.load(.acquire));
}

test "HTTP never retries once response bytes arrived, for POST, or on a new connection" {
    for ([_]enum { truncated, post, fresh }{ .truncated, .post, .fresh }) |case| {
        const pool = try Pool.create(.{ .connections = 1, .action = switch (case) {
            .truncated => truncateSecond,
            .post => dropSecond,
            .fresh => dropAlways,
        } });
        defer pool.destroy();
        var engine: http.Engine = undefined;
        engine.init(std.testing.allocator, std.testing.io);
        defer engine.deinit();
        var url_buffer: [64]u8 = undefined;
        const url = pool.url(&url_buffer);
        if (case != .fresh) _ = try runMethod(&engine, url, .GET).outcome.completed;
        const result = runMethod(&engine, url, if (case == .post) .POST else .GET);
        try std.testing.expectError(error.ReadFailed, result.outcome.completed);
        try std.testing.expect(!result.retried);
        try std.testing.expectEqual(case != .fresh, result.reused);
        try std.testing.expectEqual(contract.Send.may_have_been_sent, result.send);
        try std.testing.expectEqual(@as(usize, if (case == .fresh) 1 else 2), pool.requests.load(.acquire));
    }
}

test "HTTP retries at most once and never after the call was cancelled" {
    for ([_]bool{ false, true }) |cancel| {
        var state: std.atomic.Value(u32) = .init(0);
        Pool.cancel_on_drop = if (cancel) &state else null;
        defer Pool.cancel_on_drop = null;
        const pool = try Pool.create(.{ .connections = if (cancel) 1 else 2, .action = dropAfterFirst });
        defer pool.destroy();
        var engine: http.Engine = undefined;
        engine.init(std.testing.allocator, std.testing.io);
        defer engine.deinit();
        var url_buffer: [64]u8 = undefined;
        const url = pool.url(&url_buffer);
        _ = try runMethod(&engine, url, .GET).outcome.completed;
        var output: [8]u8 = undefined;
        const result = engine.run(.{ .consumer = .mcp, .isolation = .public, .budget = .{ .deadline = .fromNow(engine.io, .{ .raw = .fromSeconds(5), .clock = .awake }) }, .cancellation = .atomic(&state) }, methodFetch, .{ url, std.http.Method.GET, &output });
        try std.testing.expect(result.reused);
        if (cancel) {
            // The peer cancels as it drops the request: no new connection.
            const failure: ?http.Error = switch (result.outcome) {
                .completed => |value| if (value) |_| null else |err| err,
                .failed => |err| err,
            };
            try std.testing.expectEqual(@as(?http.Error, error.Cancelled), failure);
            try std.testing.expect(!result.retried);
            try std.testing.expectEqual(@as(usize, 2), pool.requests.load(.acquire));
        } else {
            // The retry's connection drops it too: no third attempt.
            try std.testing.expectError(error.ReadFailed, result.outcome.completed);
            try std.testing.expect(result.retried);
            try std.testing.expectEqual(@as(usize, 3), pool.requests.load(.acquire));
        }
    }
}

test "HTTP retries a non-POST request whose first socket write accepted nothing" {
    for ([_]std.http.Method{ .DELETE, .POST }) |method| {
        var threaded: Io.Threaded = .init(std.testing.allocator, .{ .async_limit = .nothing });
        defer threaded.deinit();
        var vtable: Io.VTable = undefined;
        const io = faultIo(&threaded, &vtable, .first_v4);
        const pool = try Pool.create(.{ .connections = if (method == .POST) 1 else 2 });
        defer pool.destroy();
        var engine: http.Engine = undefined;
        engine.init(std.testing.allocator, io);
        defer engine.deinit();
        var url_buffer: [64]u8 = undefined;
        const url = pool.url(&url_buffer);
        _ = try runMethod(&engine, url, .GET).outcome.completed;
        Faults.failing_writes.store(1, .release);
        const result = runMethod(&engine, url, method);
        try std.testing.expect(result.reused);
        if (method == .POST) {
            try std.testing.expectError(error.WriteFailed, result.outcome.completed);
            try std.testing.expect(!result.retried);
            try std.testing.expectEqual(@as(usize, 1), pool.requests.load(.acquire));
        } else {
            try std.testing.expectEqual(@as(u16, 200), (try result.outcome.completed).status);
            try std.testing.expect(result.retried);
            try std.testing.expectEqual(@as(usize, 2), pool.requests.load(.acquire));
        }
    }
}

fn observeWrites(operation: *http.Operation, url: []const u8, fail_first: bool, wrote: *bool) http.Error!void {
    var request = try operation.open(.GET, std.Uri.parse(url) catch return error.InvalidRequest, .{});
    defer request.deinit();
    if (fail_first) Faults.failing_writes.store(1, .release);
    request.send(null) catch {};
    wrote.* = operation.slot.?.wrote;
}

test "HTTP write watch sees accepted bytes and only accepted bytes" {
    // Guards the drain interposition against std changes in both directions.
    for ([_]bool{ false, true }) |fail_first| {
        var threaded: Io.Threaded = .init(std.testing.allocator, .{ .async_limit = .nothing });
        defer threaded.deinit();
        var vtable: Io.VTable = undefined;
        const io = faultIo(&threaded, &vtable, .first_v4);
        const pool = try Pool.create(.{ .connections = 1 });
        defer pool.destroy();
        var engine: http.Engine = undefined;
        engine.init(std.testing.allocator, io);
        defer engine.deinit();
        var url_buffer: [64]u8 = undefined;
        const url = pool.url(&url_buffer);
        // Starts at the wrong answer: the watch must actively report.
        var wrote = fail_first;
        const result = engine.run(.{ .consumer = .mcp, .isolation = .public, .budget = .{ .deadline = .fromNow(io, .{ .raw = .fromSeconds(5), .clock = .awake }) } }, observeWrites, .{ url, fail_first, &wrote });
        _ = try result.outcome.completed;
        try std.testing.expectEqual(!fail_first, wrote);
    }
}

/// The slot holding the only pooled connection.
fn pooledSlot(engine: *http.Engine) !*@TypeOf(engine.slots[0]) {
    var found: ?*@TypeOf(engine.slots[0]) = null;
    for (&engine.slots) |*slot| if (slot.client.connection_pool.free_len != 0) {
        if (found != null) return error.TestUnexpectedResult;
        found = slot;
    };
    return found orelse error.TestUnexpectedResult;
}

fn backdate(timestamp: *Io.Clock.Timestamp, milliseconds: i64) void {
    timestamp.* = timestamp.subDuration(.{ .raw = .fromMilliseconds(milliseconds), .clock = .awake });
}

test "HTTP reuse honors a server Keep-Alive timeout of 5 s minus a 1 s margin" {
    // The server announces Keep-Alive: timeout=5 and closes an idle connection
    // after 5 s. Idle time is advanced by backdating instead of waiting.
    const pool = try Pool.create(.{ .connections = 2, .keep_alive = "timeout=5, max=100" });
    defer pool.destroy();
    var engine: http.Engine = undefined;
    engine.init(std.testing.allocator, std.testing.io);
    defer engine.deinit();
    var url_buffer: [64]u8 = undefined;
    const url = pool.url(&url_buffer);
    try std.testing.expect(!try runScoped(&engine, url, "a"));
    const slot = try pooledSlot(&engine);
    try std.testing.expectEqual(@as(i96, 4 * std.time.ns_per_s), slot.idle_limit.nanoseconds);
    backdate(&slot.idle, 3500);
    try std.testing.expect(try runScoped(&engine, url, "a"));
    // Past 4 s: never probed, closed, replaced.
    backdate(&slot.idle, 4500);
    try std.testing.expect(!try runScoped(&engine, url, "a"));
    try pool.waitClosed(0);
    try std.testing.expectEqual(@as(usize, 2), pool.accepted.load(.acquire));
}

test "HTTP probe catches a server that closed within its Keep-Alive timeout" {
    const pool = try Pool.create(.{ .connections = 2, .keep_alive = "timeout=5", .close_first = true });
    defer pool.destroy();
    var engine: http.Engine = undefined;
    engine.init(std.testing.allocator, std.testing.io);
    defer engine.deinit();
    var url_buffer: [64]u8 = undefined;
    const url = pool.url(&url_buffer);
    try std.testing.expect(!try runScoped(&engine, url, "a"));
    try pool.waitClosed(0);
    backdate(&(try pooledSlot(&engine)).idle, 3500);
    // Still within 4 s, so it is probed: FIN, then a new connection.
    try std.testing.expect(!try runScoped(&engine, url, "a"));
    try std.testing.expectEqual(@as(usize, 2), pool.accepted.load(.acquire));
}

test "HTTP keeps no connection for a one second Keep-Alive and none past its lifetime" {
    for ([_]bool{ false, true }) |lifetime| {
        const pool = try Pool.create(.{ .connections = 2, .keep_alive = if (lifetime) null else "timeout=1" });
        defer pool.destroy();
        var engine: http.Engine = undefined;
        engine.init(std.testing.allocator, std.testing.io);
        defer engine.deinit();
        var url_buffer: [64]u8 = undefined;
        const url = pool.url(&url_buffer);
        try std.testing.expect(!try runScoped(&engine, url, "a"));
        if (lifetime) backdate(&(try pooledSlot(&engine)).created, 301 * std.time.ms_per_s);
        try std.testing.expect(!try runScoped(&engine, url, "a"));
        try pool.waitClosed(0);
        try std.testing.expectEqual(@as(usize, 2), pool.accepted.load(.acquire));
    }
}

test "HTTP statistics count reuse per consumer and summaries carry no request data" {
    const pool = try Pool.create(.{ .connections = 3, .action = dropSecond });
    defer pool.destroy();
    var engine: http.Engine = undefined;
    engine.init(std.testing.allocator, std.testing.io);
    defer engine.deinit();
    var url_buffer: [64]u8 = undefined;
    const url = pool.url(&url_buffer);
    // New, then pooled but dropped and retried, then pooled again.
    _ = try runMethod(&engine, url, .GET).outcome.completed;
    _ = try runMethod(&engine, url, .GET).outcome.completed;
    _ = try runMethod(&engine, url, .GET).outcome.completed;
    // Another owner on the same origin, then retire it.
    try std.testing.expect(!try runScoped(&engine, url, "secret-principal"));
    engine.retire(.of(.mcp_server, "secret-principal"));
    const stats = engine.stats();
    const mcp = stats.consumers.get(.mcp);
    try std.testing.expectEqual(@as(u64, 4), mcp.requests);
    try std.testing.expectEqual(@as(u64, 2), mcp.reused);
    try std.testing.expectEqual(@as(u64, 1), mcp.reuse_failed);
    try std.testing.expectEqual(@as(u64, 1), mcp.retried);
    try std.testing.expectEqual(@as(u64, 3), mcp.new_connections);
    try std.testing.expectEqual(@as(u64, 2), mcp.probe.get(.idle));
    try std.testing.expectEqual(@as(u64, 3), mcp.connect_ms.count());
    try std.testing.expectEqual(@as(u64, 1), mcp.head_ms_reused.count());
    try std.testing.expectEqual(@as(u64, 3), mcp.head_ms_new.count());
    try std.testing.expectEqual(@as(u64, 1), stats.retired);
    try std.testing.expectEqual(@as(u64, 0), stats.consumers.get(.metask).requests);

    var buffer: [2048]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    try http.writeSummary(&writer, &stats);
    const summary = writer.buffered();
    try std.testing.expect(std.mem.startsWith(u8, summary, "http stats consumer=mcp requests=4 reused=2 retried=1 reuse_failed=1 new_connections=3 "));
    try std.testing.expect(std.mem.indexOf(u8, summary, "probe_idle=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "\nhttp stats retired=1\n") != null);
    var port: [8]u8 = undefined;
    for ([_][]const u8{ url, "127.0.0.1", "/fixture", "secret-principal", try std.fmt.bufPrint(&port, ":{d}", .{pool.listener.socket.address.getPort()}) }) |forbidden|
        try std.testing.expect(std.mem.indexOf(u8, summary, forbidden) == null);
    // Only the active consumer gets a line.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, summary, "\n"));
}

/// Backing allocator that records every release and whether any released
/// byte was still non-zero. Used from engine worker threads.
const Observed = struct {
    releases: std.atomic.Value(usize) = .init(0),
    dirty: std.atomic.Value(bool) = .init(false),

    fn allocator(self: *Observed) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
    }

    fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        return std.testing.allocator.rawAlloc(len, alignment, ret_addr);
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *Observed = @ptrCast(@alignCast(context));
        for (memory) |byte| if (byte != 0) self.dirty.store(true, .release);
        _ = self.releases.fetchAdd(1, .acq_rel);
        std.testing.allocator.rawFree(memory, alignment, ret_addr);
    }
};

fn secretFetch(operation: *http.Operation, url: []const u8, output: []u8) http.Error!Reply {
    var headers = [_]std.http.Header{.{ .name = "Authorization", .value = "Bearer request-secret" }};
    var request = try operation.open(.GET, std.Uri.parse(url) catch return error.InvalidRequest, .{ .headers = &headers });
    defer request.deinit();
    try request.send(null);
    var response = try request.receiveHead();
    const bytes = try request.readAll(&response, output);
    return .{ .status = @intFromEnum(response.head.status), .length = bytes.len };
}

fn runSecret(engine: *http.Engine, url: []const u8, isolation: http.Isolation, cancellation: ?http.Cancellation) http.Result(http.Error!Reply) {
    var output: [64]u8 = undefined;
    return engine.run(.{ .consumer = .metask, .isolation = isolation, .budget = .{ .deadline = .fromNow(engine.io, .{ .raw = .fromSeconds(5), .clock = .awake }) }, .cancellation = cancellation }, secretFetch, .{ url, &output });
}

test "HTTP pooled connections keep neither the request head nor the response body" {
    const pool = try Pool.create(.{ .connections = 1, .body = "{\"token\":\"response-secret\"}" });
    defer pool.destroy();
    var engine: http.Engine = undefined;
    engine.init(std.testing.allocator, std.testing.io);
    defer engine.deinit();
    var url_buffer: [64]u8 = undefined;
    const url = pool.url(&url_buffer);
    _ = try runSecret(&engine, url, .public, null).outcome.completed;
    const slot = try pooledSlot(&engine);
    const connection: *std.http.Client.Connection = @alignCast(@fieldParentPtr("pool_node", slot.client.connection_pool.free.first.?));
    const buffers = [_][]const u8{ connection.writer().buffer, connection.stream_writer.interface.buffer, connection.reader().buffer, connection.stream_reader.interface.buffer };
    for (buffers) |buffer| for ([_][]const u8{ "request-secret", "response-secret", "Authorization" }) |secret|
        try std.testing.expect(std.mem.indexOf(u8, buffer, secret) == null);
    // Still a clean, reusable connection.
    try std.testing.expect(runSecret(&engine, url, .public, null).reused);
}

test "HTTP engine frees connections through the wiping allocator on failure, cancellation and eviction" {
    var observed: Observed = .{};
    var state: std.atomic.Value(u32) = .init(0);
    Pool.cancel_on_drop = &state;
    defer Pool.cancel_on_drop = null;
    const Script = struct {
        // Connection 0 fails at once, 1 stalls mid-body, the rest respond.
        fn action(connection: usize, _: usize) Pool.Action {
            return switch (connection) {
                0 => .drop,
                1 => .stall,
                else => .respond,
            };
        }
    };
    const pool = try Pool.create(.{ .connections = 5, .action = Script.action });
    defer pool.destroy();
    var engine: http.Engine = undefined;
    engine.init(observed.allocator(), std.testing.io);
    var engine_live = true;
    defer if (engine_live) engine.deinit();
    var url_buffer: [64]u8 = undefined;
    const url = pool.url(&url_buffer);

    var released = observed.releases.load(.acquire);
    try std.testing.expectError(error.ReadFailed, runSecret(&engine, url, .public, null).outcome.completed);
    try std.testing.expect(observed.releases.load(.acquire) > released);

    // The drop above also tripped the shared cancellation hook.
    state.store(0, .release);
    released = observed.releases.load(.acquire);
    const cancelled = runSecret(&engine, url, .public, .atomic(&state));
    try std.testing.expectEqual(error.Cancelled, cancelled.outcome.failed);
    try pool.waitClosed(1);
    try std.testing.expect(observed.releases.load(.acquire) > released);

    // Retire, then expiry, each close a pooled connection.
    _ = try runSecret(&engine, url, .of(.metask_account, "a"), null).outcome.completed;
    released = observed.releases.load(.acquire);
    engine.retire(.of(.metask_account, "a"));
    try pool.waitClosed(2);
    try std.testing.expect(observed.releases.load(.acquire) > released);
    _ = try runSecret(&engine, url, .of(.metask_account, "b"), null).outcome.completed;
    backdate(&(try pooledSlot(&engine)).idle, 31 * std.time.ms_per_s);
    released = observed.releases.load(.acquire);
    // The owner's next lease closes its expired connection and opens another.
    try std.testing.expect(!runSecret(&engine, url, .of(.metask_account, "b"), null).reused);
    try pool.waitClosed(3);
    try std.testing.expect(observed.releases.load(.acquire) > released);

    engine_live = false;
    engine.deinit();
    try std.testing.expect(!observed.dirty.load(.acquire));
}

test "HTTP saturated ordinary work leaves capacity for a held MCP continuation" {
    const Held = struct {
        engine: *http.Engine,
        entered: Io.Semaphore = .{ .permits = 0 },
        release: Io.Event = .unset,
        fn wait(op: *http.Operation, self: *@This()) u8 {
            self.entered.post(op.io());
            self.release.waitUncancelable(op.io());
            return 1;
        }
        fn run(self: *@This()) http.Result(u8) {
            return self.engine.run(.{ .consumer = .mcp, .isolation = .public, .budget = .{ .deadline = .fromNow(self.engine.io, .{ .raw = .fromSeconds(30), .clock = .awake }) } }, wait, .{self});
        }
        fn complete(_: *http.Operation) u8 {
            return 42;
        }
    };
    var engine: http.Engine = undefined;
    engine.init(std.testing.allocator, std.testing.io);
    defer engine.deinit();
    var held: Held = .{ .engine = &engine };
    var workers: [http.Engine.request_limit]Io.Future(http.Result(u8)) = undefined;
    var started: usize = 0;
    defer {
        held.release.set(engine.io);
        for (workers[0..started]) |*worker| _ = worker.await(engine.io);
    }
    for (&workers) |*worker| {
        worker.* = try engine.io.concurrent(Held.run, .{&held});
        started += 1;
    }
    for (0..workers.len) |_| try held.entered.wait(engine.io);
    const refused = engine.run(.{ .consumer = .mcp, .isolation = .public, .budget = .{ .deadline = .fromNow(engine.io, .{ .raw = .fromSeconds(30), .clock = .awake }) } }, Held.complete, .{});
    try std.testing.expectEqual(error.ResourceLimit, refused.outcome.failed);
    try std.testing.expectEqual(contract.Send.not_sent, refused.send);
    try std.testing.expectEqual(contract.Phase.admission, refused.diagnostic.?.phase);
    try std.testing.expectEqual(contract.Cause.resource_limit, refused.diagnostic.?.cause);
    const continuation = engine.run(.{ .consumer = .mcp, .isolation = .public, .budget = .{ .deadline = .fromNow(engine.io, .{ .raw = .fromSeconds(30), .clock = .awake }) }, .continuation = true }, Held.complete, .{});
    try std.testing.expectEqual(@as(u8, 42), continuation.outcome.completed);
    try std.testing.expect(continuation.diagnostic == null);
}
