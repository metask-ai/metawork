const std = @import("std");
const http = @import("http_transport.zig");
const Io = std.Io;

const Reply = struct { status: u16, length: usize };

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
    try std.testing.expectEqual(http.Send.may_have_been_sent, result.send);
}

const Faults = struct {
    const Mode = enum { first_v4, first_v6, two_stalled, late_connect, slow_dns, refused, slow_single, tls_then_refused, stalled_single };
    var original: Io = undefined;
    var mode: Mode = .first_v4;
    var active: std.atomic.Value(usize) = .init(0);
    var attempts: std.atomic.Value(usize) = .init(0);
    var late: std.atomic.Value(usize) = .init(0);
    var dns_active: std.atomic.Value(usize) = .init(0);
    /// Start time of each connection attempt, in attempt order.
    var starts: [8]Io.Clock.Timestamp = undefined;

    fn reset(io: Io, selected: Mode) void {
        original = io;
        mode = selected;
        active.store(0, .monotonic);
        attempts.store(0, .monotonic);
        late.store(0, .monotonic);
        dns_active.store(0, .monotonic);
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
    try std.testing.expectEqual(http.Send.not_sent, result.send);
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
    try std.testing.expectEqual(http.Send.not_sent, result.send);
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
        try std.testing.expectEqual(http.Send.not_sent, result.send);
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
    try std.testing.expectEqual(http.Send.not_sent, result.send);
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
    try std.testing.expectEqual(http.Send.may_have_been_sent, result.send);
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
        try std.testing.expectEqual(http.Send.not_sent, result.send);
        state.store(1, .release);
        const cancelled = engine.run(control, fetch, .{ "http://127.0.0.1:1/post", "body", &output });
        try std.testing.expectEqual(error.Cancelled, cancelled.outcome.failed);
        try std.testing.expectEqual(http.Send.not_sent, cancelled.send);
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

    const Options = struct {
        /// Exactly how many connections the peer accepts before it stops.
        connections: usize,
        /// The first connection closes right after its first response.
        close_first: bool = false,
    };

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
        while (true) {
            var request = server.receiveHead() catch return;
            const number = self.requests.fetchAdd(1, .acq_rel);
            if (number < self.served_by.len) self.served_by[number] = index;
            request.respond("{}", .{ .keep_alive = true }) catch return;
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
    try std.testing.expectEqual(http.Send.not_sent, refused.send);
    const continuation = engine.run(.{ .consumer = .mcp, .isolation = .public, .budget = .{ .deadline = .fromNow(engine.io, .{ .raw = .fromSeconds(30), .clock = .awake }) }, .continuation = true }, Held.complete, .{});
    try std.testing.expectEqual(@as(u8, 42), continuation.outcome.completed);
}
