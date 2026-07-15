const std = @import("std");

pub const MockServer = struct {
    listen_fd: std.c.fd_t,
    port: u16,
    responses: []const []const u8,
    thread: std.Thread,

    pub fn start(responses: []const []const u8) !*MockServer {
        const fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
        if (fd < 0) return error.SocketFailed;
        errdefer _ = std.c.close(fd);
        const yes: c_int = 1;
        if (std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.REUSEADDR, &yes, @sizeOf(c_int)) < 0)
            return error.SocketOptionFailed;
        var address = std.c.sockaddr.in{
            .family = std.c.AF.INET,
            .port = 0,
            .addr = 0x0100007f,
            .zero = [_]u8{0} ** 8,
        };
        if (std.c.bind(fd, @ptrCast(&address), @sizeOf(@TypeOf(address))) < 0)
            return error.BindFailed;
        if (std.c.listen(fd, 8) < 0) return error.ListenFailed;
        var bound: std.c.sockaddr.in = undefined;
        var length: std.c.socklen_t = @sizeOf(@TypeOf(bound));
        if (std.c.getsockname(fd, @ptrCast(&bound), &length) < 0)
            return error.GetSocknameFailed;

        const self = try std.heap.page_allocator.create(MockServer);
        self.* = .{
            .listen_fd = fd,
            .port = std.mem.bigToNative(u16, bound.port),
            .responses = responses,
            .thread = undefined,
        };
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
        return self;
    }

    pub fn url(self: *const MockServer, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/v1/messages", .{self.port});
    }

    pub fn stop(self: *MockServer) void {
        _ = std.c.close(self.listen_fd);
        self.thread.join();
        std.heap.page_allocator.destroy(self);
    }

    fn serve(self: *MockServer) void {
        for (self.responses) |response| {
            var client_address: std.c.sockaddr = undefined;
            var address_length: std.c.socklen_t = @sizeOf(@TypeOf(client_address));
            const connection = std.c.accept(self.listen_fd, &client_address, &address_length);
            if (connection < 0) return;
            const timeout = std.c.timeval{ .sec = 10, .usec = 0 };
            if (std.c.setsockopt(connection, std.c.SOL.SOCKET, std.c.SO.RCVTIMEO, &timeout, @sizeOf(@TypeOf(timeout))) < 0 or
                std.c.setsockopt(connection, std.c.SOL.SOCKET, std.c.SO.SNDTIMEO, &timeout, @sizeOf(@TypeOf(timeout))) < 0)
            {
                _ = std.c.close(connection);
                return;
            }
            readRequest(connection);
            writeResponse(connection, response);
            _ = std.c.close(connection);
        }
    }
};

fn readRequest(connection: std.c.fd_t) void {
    var request: [64 * 1024]u8 = undefined;
    var total: usize = 0;
    var body_start: ?usize = null;
    var content_length: usize = 0;
    while (total < request.len and body_start == null) {
        const count = std.c.read(connection, request[total..].ptr, request.len - total);
        if (count <= 0) return;
        total += @intCast(count);
        if (std.mem.indexOf(u8, request[0..total], "\r\n\r\n")) |index| {
            body_start = index + 4;
            content_length = parseContentLength(request[0..index]);
        }
    }
    if (body_start) |start| while (total - start < content_length and total < request.len) {
        const count = std.c.read(connection, request[total..].ptr, request.len - total);
        if (count <= 0) return;
        total += @intCast(count);
    };
}

fn parseContentLength(headers: []const u8) usize {
    const marker = "content-length:";
    var lower: [4096]u8 = undefined;
    const length = @min(headers.len, lower.len);
    for (headers[0..length], 0..) |byte, index| lower[index] = std.ascii.toLower(byte);
    const start = std.mem.indexOf(u8, lower[0..length], marker) orelse return 0;
    var cursor = start + marker.len;
    while (cursor < length and (lower[cursor] == ' ' or lower[cursor] == '\t')) : (cursor += 1) {}
    var end = cursor;
    while (end < length and std.ascii.isDigit(lower[end])) : (end += 1) {}
    return std.fmt.parseInt(usize, lower[cursor..end], 10) catch 0;
}

fn writeResponse(connection: std.c.fd_t, body: []const u8) void {
    writeAll(connection, "HTTP/1.1 200 OK\r\n" ++
        "content-type: text/event-stream\r\n" ++
        "transfer-encoding: chunked\r\n" ++
        "connection: close\r\n\r\n");
    var header: [32]u8 = undefined;
    const encoded = std.fmt.bufPrint(&header, "{x}\r\n", .{body.len}) catch return;
    writeAll(connection, encoded);
    writeAll(connection, body);
    writeAll(connection, "\r\n0\r\n\r\n");
}

fn writeAll(file: std.c.fd_t, bytes: []const u8) void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = std.c.write(file, bytes[offset..].ptr, bytes.len - offset);
        if (count <= 0) return;
        offset += @intCast(count);
    }
}
