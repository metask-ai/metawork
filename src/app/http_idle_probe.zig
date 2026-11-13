//! Non-blocking liveness check for an idle pooled HTTP connection. Any result
//! other than `idle` means the connection must not carry another request; an
//! undeterminable state is never reported as healthy.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Client = std.http.Client;

pub const Outcome = enum {
    /// No pending bytes, no FIN, no RST.
    idle,
    /// The peer sent FIN.
    fin,
    /// The peer reset the connection.
    rst,
    /// Bytes are pending or already buffered beyond the last response.
    extra_data,
    /// The platform could not give a definite answer.
    unknown,
};

pub fn probe(io: Io, connection: *Client.Connection) Outcome {
    // Plaintext read-ahead, or TLS records (such as close_notify) already
    // pulled into the ciphertext buffer, are not a clean idle connection.
    if (connection.reader().bufferedLen() != 0) return .extra_data;
    if (connection.stream_reader.interface.bufferedLen() != 0) return .extra_data;
    return probeSocket(io, connection.stream_reader.stream.socket.handle);
}

pub fn probeSocket(io: Io, handle: Io.net.Socket.Handle) Outcome {
    return if (builtin.os.tag == .windows) probeAfd(io, handle) else probePeek(io, handle);
}

/// std sockets on Windows are `\Device\Afd` handles, so ws2_32 calls fail with
/// WSAENOTSOCK and std's zero-timeout receive is unavailable. IOCTL_AFD_POLL
/// with a zero timeout completes synchronously. `Io.operate` (never
/// `operateTimeout`) keeps the IRP's stack buffers alive until completion even
/// when the operation is canceled.
const afd = struct {
    const windows = std.os.windows;

    /// Values from wepoll and ReactOS (afd/shared.h).
    const poll_receive: u32 = 0x0001;
    const poll_send: u32 = 0x0004;
    const poll_disconnect: u32 = 0x0008;
    const poll_abort: u32 = 0x0010;
    const poll_local_close: u32 = 0x0020;
    const poll_connect_fail: u32 = 0x0100;
    /// SEND is excluded: an idle writable socket would always report it.
    const idle_events = poll_receive | poll_disconnect | poll_abort | poll_local_close | poll_connect_fail;

    const HandleInfo = extern struct {
        handle: windows.HANDLE,
        events: u32,
        status: windows.NTSTATUS,
    };

    const PollInfo = extern struct {
        timeout: i64,
        number_of_handles: u32,
        exclusive: u32,
        handles: [1]HandleInfo,
    };

    fn classify(info: *const PollInfo) Outcome {
        if (info.number_of_handles == 0) return .idle;
        if (info.number_of_handles != 1 or info.handles[0].status != .SUCCESS) return .unknown;
        const events = info.handles[0].events;
        if (events & poll_receive != 0) return .extra_data;
        if (events & poll_abort != 0) return .rst;
        if (events & poll_disconnect != 0) return .fin;
        return .unknown;
    }
};

fn probeAfd(io: Io, handle: Io.net.Socket.Handle) Outcome {
    var info: afd.PollInfo = .{
        .timeout = 0,
        .number_of_handles = 1,
        .exclusive = 0,
        .handles = .{.{ .handle = handle, .events = afd.idle_events, .status = .SUCCESS }},
    };
    const bytes = std.mem.asBytes(&info);
    const result = io.operate(.{ .device_io_control = .{
        .file = .{ .handle = handle, .flags = .{ .nonblocking = true } },
        .code = std.os.windows.IOCTL.AFD.POLL,
        .in = bytes,
        .out = bytes,
    } }) catch return .unknown;
    if (result.device_io_control.u.Status != .SUCCESS) return .unknown;
    return afd.classify(&info);
}

fn probePeek(io: Io, handle: Io.net.Socket.Handle) Outcome {
    const socket: Io.net.Socket = .{ .handle = handle, .address = undefined };
    var messages: [1]Io.net.IncomingMessage = .{.init};
    var byte: [1]u8 = undefined;
    const err, const count = socket.receiveManyTimeout(io, &messages, &byte, .{ .peek = true }, .{ .duration = .{ .raw = .zero, .clock = .awake } });
    if (err) |failure| return switch (failure) {
        error.Timeout => .idle,
        error.ConnectionResetByPeer => .rst,
        else => .unknown,
    };
    if (count != 1) return .unknown;
    return if (messages[0].data.len == 0) .fin else .extra_data;
}

comptime {
    if (builtin.os.tag == .windows and builtin.cpu.arch == .x86_64) {
        // AFD_POLL_HANDLE_INFO and AFD_POLL_INFO layouts on x64.
        std.debug.assert(@sizeOf(afd.HandleInfo) == 16);
        std.debug.assert(@offsetOf(afd.HandleInfo, "events") == 8);
        std.debug.assert(@offsetOf(afd.HandleInfo, "status") == 12);
        std.debug.assert(@sizeOf(afd.PollInfo) == 32);
        std.debug.assert(@offsetOf(afd.PollInfo, "number_of_handles") == 8);
        std.debug.assert(@offsetOf(afd.PollInfo, "exclusive") == 12);
        std.debug.assert(@offsetOf(afd.PollInfo, "handles") == 16);
    }
}

const Pair = struct {
    listener: Io.net.Server,
    client: Io.net.Stream,
    peer: Io.net.Stream,
    peer_open: bool = true,

    fn init(io: Io) !Pair {
        const address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        var listener = try address.listen(io, .{});
        errdefer listener.deinit(io);
        const client = try listener.socket.address.connect(io, .{ .mode = .stream });
        errdefer client.close(io);
        return .{ .listener = listener, .client = client, .peer = try listener.accept(io) };
    }

    fn deinit(self: *Pair, io: Io) void {
        if (self.peer_open) self.peer.close(io);
        self.client.close(io);
        self.listener.deinit(io);
    }

    fn closePeer(self: *Pair, io: Io) void {
        self.peer.close(io);
        self.peer_open = false;
    }

    /// Abortive close: the peer's next segment is RST, not FIN.
    fn resetPeer(self: *Pair, io: Io) !void {
        if (builtin.os.tag == .windows) {
            const windows = std.os.windows;
            // An abortive disconnect completes synchronously; the APC path
            // (`nonblocking = true`) never observes its completion.
            const info: windows.AFD.PARTIAL_DISCONNECT_INFO = .{ .DisconnectMode = .{ .ABORTIVE = true }, .Timeout = -1 };
            const result = try io.operate(.{ .device_io_control = .{
                .file = .{ .handle = self.peer.socket.handle, .flags = .{ .nonblocking = false } },
                .code = windows.IOCTL.AFD.PARTIAL_DISCONNECT,
                .in = std.mem.asBytes(&info),
            } });
            if (result.device_io_control.u.Status != .SUCCESS) return error.TestUnexpectedResult;
        } else {
            const value: std.posix.linger = .{ .onoff = 1, .linger = 0 };
            try std.posix.setsockopt(self.peer.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.LINGER, std.mem.asBytes(&value));
        }
        self.closePeer(io);
    }

    fn settle(io: Io) void {
        // Loopback delivery is asynchronous; the classification itself is
        // non-blocking and stable once the segment has arrived.
        Io.sleep(io, .fromMilliseconds(100), .awake) catch {};
    }
};

test "HTTP idle probe distinguishes idle FIN RST and extra data" {
    const io = std.testing.io;
    for ([_]Outcome{ .idle, .fin, .rst, .extra_data }) |expected| {
        var pair: Pair = try .init(io);
        defer pair.deinit(io);
        switch (expected) {
            .idle => {},
            .fin => pair.closePeer(io),
            .rst => try pair.resetPeer(io),
            .extra_data => {
                var buffer: [8]u8 = undefined;
                var writer = pair.peer.writer(io, &buffer);
                try writer.interface.writeAll("X");
                try writer.interface.flush();
            },
            .unknown => unreachable,
        }
        Pair.settle(io);
        try std.testing.expectEqual(expected, probeSocket(io, pair.client.socket.handle));
        // Probing never consumes or changes the observed state.
        try std.testing.expectEqual(expected, probeSocket(io, pair.client.socket.handle));
    }
}

test "HTTP idle probe AFD poll classification is fail closed" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var info: afd.PollInfo = .{ .timeout = 0, .number_of_handles = 0, .exclusive = 0, .handles = undefined };
    try std.testing.expectEqual(Outcome.idle, afd.classify(&info));
    info.number_of_handles = 1;
    info.handles[0] = .{ .handle = undefined, .events = afd.poll_receive | afd.poll_disconnect, .status = .SUCCESS };
    try std.testing.expectEqual(Outcome.extra_data, afd.classify(&info));
    info.handles[0].events = afd.poll_abort;
    try std.testing.expectEqual(Outcome.rst, afd.classify(&info));
    info.handles[0].events = afd.poll_disconnect;
    try std.testing.expectEqual(Outcome.fin, afd.classify(&info));
    for ([_]u32{ afd.poll_local_close, afd.poll_connect_fail, afd.poll_send, 0 }) |events| {
        info.handles[0].events = events;
        try std.testing.expectEqual(Outcome.unknown, afd.classify(&info));
    }
    info.handles[0] = .{ .handle = undefined, .events = afd.poll_disconnect, .status = .INVALID_HANDLE };
    try std.testing.expectEqual(Outcome.unknown, afd.classify(&info));
    try std.testing.expectEqual(@as(u32, 0), afd.idle_events & afd.poll_send);
}
