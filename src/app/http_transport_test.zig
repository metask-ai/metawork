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
    const result = engine.run(.{ .consumer = .update, .budget = .{ .deadline = .fromNow(engine.io, .{ .raw = .fromSeconds(3), .clock = .awake }) } }, fetch, .{ url, null, &output });
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
        const result = engine.run(.{ .consumer = .metask, .budget = .{ .deadline = .fromNow(io, .{ .raw = .fromSeconds(5), .clock = .boot }) } }, fetch, .{ url, "body", &output });
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
    const result = engine.run(.{ .consumer = .metask, .budget = .{ .deadline = .fromNow(io, .{ .raw = .fromMilliseconds(50), .clock = .boot }) } }, fetch, .{ url, "body", &output });
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
        const result = engine.run(.{ .consumer = .metask, .budget = budget }, fetch, .{ url, "body", &output });
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
    const result = engine.run(.{ .consumer = .metask, .budget = .{ .deadline = .fromNow(engine.io, .{ .raw = .fromSeconds(6), .clock = .awake }) } }, fetch, .{ url, "body", &output });
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
    const result = engine.run(.{ .consumer = .metask, .budget = .{ .deadline = .fromNow(io, .{ .raw = .fromSeconds(6), .clock = .awake }) } }, fetch, .{ url, "body", &output });
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
    const result = engine.run(.{ .consumer = .metask, .budget = .{ .deadline = .fromNow(io, .{ .raw = .fromSeconds(6), .clock = .awake }) } }, fetch, .{ url, "body", &output });
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
        const result = engine.run(.{ .consumer = .completion, .budget = .{ .connect = .fromMilliseconds(200) } }, fetch, .{ "http://fixture.test/post", "body", &output });
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
    const result = engine.run(.{ .consumer = .metask, .budget = .{ .deadline = .fromNow(io, .{ .raw = .fromMilliseconds(20), .clock = .awake }) } }, fetch, .{ "http://fixture.test/post", "body", &output });
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
    const result = engine.run(.{ .consumer = .metask, .budget = .{ .deadline = .fromNow(engine.io, .{ .raw = .fromSeconds(3), .clock = .boot }) } }, fetch, .{ url, "body", &output });
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
        const control: http.Control = .{ .consumer = .completion, .cancellation = .atomic(&state), .budget = .{ .deadline = .fromNow(engine.io, .{ .raw = .fromSeconds(3), .clock = .boot }) } };
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
    const result = engine.run(.{ .consumer = .metask, .budget = .{ .deadline = .fromNow(engine.io, .{ .raw = .fromSeconds(30), .clock = .awake }) }, .cancellation = .{ .context = &fixture, .requested_fn = Fixture.requested, .wait_fn = Fixture.wait } }, Fixture.complete, .{&fixture});
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

test "HTTP reuses only clean same-scope connections and retires stale idle sockets" {
    const KeepAlive = struct {
        listener: *Io.net.Server,
        close_first: bool,
        closed: Io.Event = .unset,
        connections: usize = 0,
        requests: usize = 0,
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            self.serve() catch |err| {
                self.failure = err;
            };
        }
        fn serve(self: *@This()) !void {
            while (self.requests < 3) {
                var connection = try self.listener.accept(std.testing.io);
                self.connections += 1;
                var closed = false;
                defer if (!closed) connection.close(std.testing.io);
                var reads: [4096]u8 = undefined;
                var writes: [4096]u8 = undefined;
                var reader = connection.reader(std.testing.io, &reads);
                var writer = connection.writer(std.testing.io, &writes);
                var server: std.http.Server = .init(&reader.interface, &writer.interface);
                while (self.requests < 3) {
                    var request = server.receiveHead() catch |err| {
                        if (err == error.HttpConnectionClosing) break;
                        return err;
                    };
                    var headers = request.iterateHeaders();
                    var token: []const u8 = "";
                    while (headers.next()) |header| if (std.ascii.eqlIgnoreCase(header.name, "Authorization")) {
                        token = header.value;
                    };
                    try std.testing.expectEqualStrings(if (self.requests == 2) "Bearer second" else "Bearer first", token);
                    self.requests += 1;
                    try request.respond("{}", .{ .keep_alive = self.requests != 3 });
                    if (self.close_first and self.requests == 1) break;
                }
                // The deferred close runs before the next iteration; use an
                // explicit shutdown to make the stale-idle probe deterministic.
                if (self.close_first and self.requests == 1) {
                    connection.close(std.testing.io);
                    closed = true;
                    self.closed.set(std.testing.io);
                }
            }
        }
    };
    for ([_]bool{ false, true }) |close_first| {
        var engine: http.Engine = undefined;
        engine.init(std.testing.allocator, std.testing.io);
        defer engine.deinit();
        const address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        var listener = try address.listen(std.testing.io, .{});
        defer listener.deinit(std.testing.io);
        var server: KeepAlive = .{ .listener = &listener, .close_first = close_first };
        const thread = try std.Thread.spawn(.{}, KeepAlive.run, .{&server});
        const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/fixture", .{listener.socket.address.getPort()});
        defer std.testing.allocator.free(url);
        for (0..3) |index| {
            if (close_first and index == 1) server.closed.waitUncancelable(std.testing.io);
            var output: [8]u8 = undefined;
            const result = engine.run(.{ .consumer = .completion, .budget = .{ .deadline = .fromNow(engine.io, .{ .raw = .fromSeconds(3), .clock = .boot }) } }, authorizedFetch, .{ url, if (index == 2) "Bearer second" else "Bearer first", &output });
            try std.testing.expect(result.outcome == .completed);
            try std.testing.expectEqual(@as(u16, 200), (try result.outcome.completed).status);
        }
        thread.join();
        try std.testing.expectEqual(@as(?anyerror, null), server.failure);
        try std.testing.expectEqual(@as(usize, if (close_first) 3 else 2), server.connections);
        try std.testing.expectEqual(@as(usize, 3), server.requests);
    }
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
            return self.engine.run(.{ .consumer = .mcp, .budget = .{ .deadline = .fromNow(self.engine.io, .{ .raw = .fromSeconds(30), .clock = .awake }) } }, wait, .{self});
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
    const refused = engine.run(.{ .consumer = .mcp, .budget = .{ .deadline = .fromNow(engine.io, .{ .raw = .fromSeconds(30), .clock = .awake }) } }, Held.complete, .{});
    try std.testing.expectEqual(error.ResourceLimit, refused.outcome.failed);
    try std.testing.expectEqual(http.Send.not_sent, refused.send);
    const continuation = engine.run(.{ .consumer = .mcp, .budget = .{ .deadline = .fromNow(engine.io, .{ .raw = .fromSeconds(30), .clock = .awake }) }, .continuation = true }, Held.complete, .{});
    try std.testing.expectEqual(@as(u8, 42), continuation.outcome.completed);
}
