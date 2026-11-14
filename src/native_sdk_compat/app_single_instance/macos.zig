//! macOS app-instance transport: current-user Unix Domain Socket and fixed prompt.

const std = @import("std");
const thread_stack = @import("metawork_thread_stack");
const contract = @import("../app_single_instance.zig");

const fd_t = c_int;
const uid_t = u32;
const socklen_t = u32;
const af_unix: c_int = 1;
const sock_stream: c_int = 1;
const shut_rdwr: c_int = 2;
const response_timeout_ms: c_int = 3000;
const cs_darwin_user_temp_dir: c_int = 65537;
const endpoint_digest_bytes = 16;

const SockAddrUn = extern struct {
    len: u8 = @sizeOf(SockAddrUn),
    family: u8 = af_unix,
    path: [104]u8 = [_]u8{0} ** 104,
};

const TimeVal = extern struct {
    seconds: isize,
    microseconds: i32,
};

extern "c" fn socket(c_int, c_int, c_int) fd_t;
extern "c" fn bind(fd_t, *const anyopaque, socklen_t) c_int;
extern "c" fn listen(fd_t, c_int) c_int;
extern "c" fn accept(fd_t, ?*anyopaque, ?*socklen_t) fd_t;
extern "c" fn connect(fd_t, *const anyopaque, socklen_t) c_int;
extern "c" fn shutdown(fd_t, c_int) c_int;
extern "c" fn close(fd_t) c_int;
extern "c" fn unlink([*:0]const u8) c_int;
extern "c" fn chmod([*:0]const u8, u16) c_int;
extern "c" fn read(fd_t, [*]u8, usize) isize;
extern "c" fn write(fd_t, [*]const u8, usize) isize;
extern "c" fn setsockopt(fd_t, c_int, c_int, *const anyopaque, socklen_t) c_int;
extern "c" fn getuid() uid_t;
extern "c" fn getpeereid(fd_t, *uid_t, *u32) c_int;
extern "c" fn confstr(c_int, ?[*]u8, usize) usize;

const sol_socket: c_int = 0xffff;
const so_sndtimeo: c_int = 0x1005;
const so_rcvtimeo: c_int = 0x1006;

const CFStringRef = ?*const anyopaque;
extern "CoreFoundation" fn CFStringCreateWithCString(?*const anyopaque, [*:0]const u8, u32) CFStringRef;
extern "CoreFoundation" fn CFRelease(?*const anyopaque) void;
extern "CoreFoundation" fn CFUserNotificationDisplayNotice(
    f64,
    usize,
    ?*const anyopaque,
    ?*const anyopaque,
    ?*const anyopaque,
    CFStringRef,
    CFStringRef,
    CFStringRef,
) i32;

const utf8_encoding: u32 = 0x0800_0100;
const stop_alert_level: usize = 0;

const State = struct {
    allocator: std.mem.Allocator,
    endpoint: [:0]u8,
    listener: fd_t,
    owner_uid: uid_t,
    handler: contract.Handler,
    stopping: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    request: [contract.max_transport_request_bytes]u8 = undefined,
    response: [contract.max_transport_response_bytes]u8 = undefined,

    fn run(self: *State) void {
        defer {
            _ = close(self.listener);
            _ = unlink(self.endpoint.ptr);
        }
        while (!self.stopping.load(.acquire)) {
            const client = accept(self.listener, null, null);
            if (client < 0) {
                if (self.stopping.load(.acquire)) break;
                continue;
            }
            if (self.stopping.load(.acquire)) {
                _ = close(client);
                break;
            }
            self.serveClient(client);
        }
    }

    fn serveClient(self: *State, client: fd_t) void {
        defer _ = close(client);
        var peer_uid: uid_t = 0;
        var peer_gid: u32 = 0;
        if (getpeereid(client, &peer_uid, &peer_gid) != 0 or
            peer_uid != self.owner_uid)
            return;

        const request_len = readFrame(client, &self.request) catch return;
        const response_len = self.handler.handle(
            self.request[0..request_len],
            &self.response,
        );
        if (response_len == 0 or response_len > self.response.len) return;
        writeFrame(client, self.response[0..response_len]) catch return;
    }
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    state: *State,

    pub fn init(
        allocator: std.mem.Allocator,
        canonical_data_root: []const u8,
        handler: contract.Handler,
    ) !Server {
        const endpoint = try endpointPath(allocator, canonical_data_root);
        errdefer allocator.free(endpoint);
        var address = try socketAddress(endpoint);
        _ = unlink(endpoint.ptr);
        const listener = socket(af_unix, sock_stream, 0);
        if (listener < 0) return error.EndpointUnavailable;
        errdefer _ = close(listener);
        if (bind(listener, &address, @sizeOf(SockAddrUn)) != 0)
            return error.EndpointUnavailable;
        errdefer _ = unlink(endpoint.ptr);
        if (chmod(endpoint.ptr, 0o600) != 0 or listen(listener, 4) != 0)
            return error.EndpointUnavailable;

        const state = try allocator.create(State);
        errdefer allocator.destroy(state);
        state.* = .{
            .allocator = allocator,
            .endpoint = endpoint,
            .listener = listener,
            .owner_uid = getuid(),
            .handler = handler,
        };
        state.thread = try std.Thread.spawn(thread_stack.config, State.run, .{state});
        return .{ .allocator = allocator, .state = state };
    }

    pub fn stop(self: *Server) void {
        const state = self.state;
        if (state.stopping.swap(true, .acq_rel)) return;
        // A local wake connection unblocks accept without closing a descriptor
        // that the listener thread still owns.
        const wake_socket = socket(af_unix, sock_stream, 0);
        if (wake_socket >= 0) {
            var address = socketAddress(state.endpoint) catch null;
            if (address) |*value| _ = connect(wake_socket, value, @sizeOf(SockAddrUn));
            _ = close(wake_socket);
        } else {
            _ = shutdown(state.listener, shut_rdwr);
        }
        if (state.thread) |thread| {
            thread.join();
            state.thread = null;
        }
    }

    pub fn deinit(self: *Server) void {
        self.stop();
        const state = self.state;
        self.allocator.free(state.endpoint);
        self.allocator.destroy(state);
        self.* = undefined;
    }
};

pub fn forward(
    allocator: std.mem.Allocator,
    canonical_data_root: []const u8,
    request: []const u8,
    response: []u8,
) !usize {
    const endpoint = try endpointPath(allocator, canonical_data_root);
    defer allocator.free(endpoint);
    var address = try socketAddress(endpoint);
    const client = socket(af_unix, sock_stream, 0);
    if (client < 0) return error.EndpointUnavailable;
    defer _ = close(client);
    try setTimeout(client);
    if (connect(client, &address, @sizeOf(SockAddrUn)) != 0)
        return error.EndpointUnavailable;
    writeFrame(client, request) catch return error.TransferFailed;
    return readFrame(client, response) catch return error.ResponseTimeout;
}

pub fn reportFailure(failure: contract.Failure) void {
    const message = contract.failureMessage(failure);
    const title = CFStringCreateWithCString(null, "MetaWork", utf8_encoding) orelse return;
    defer CFRelease(title);
    const body = CFStringCreateWithCString(null, message.ptr, utf8_encoding) orelse return;
    defer CFRelease(body);
    const button = CFStringCreateWithCString(null, "OK", utf8_encoding) orelse return;
    defer CFRelease(button);
    _ = CFUserNotificationDisplayNotice(
        0,
        stop_alert_level,
        null,
        null,
        null,
        title,
        body,
        button,
    );
}

fn endpointPath(
    allocator: std.mem.Allocator,
    canonical_data_root: []const u8,
) ![:0]u8 {
    const temporary_root = try userTemporaryDirectory(allocator);
    defer allocator.free(temporary_root);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var uid_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &uid_bytes, getuid(), .little);
    hash.update(&uid_bytes);
    hash.update(canonical_data_root);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    const hex = std.fmt.bytesToHex(digest[0..endpoint_digest_bytes].*, .lower);
    const separator = if (std.mem.endsWith(u8, temporary_root, "/")) "" else "/";
    const endpoint = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}{s}metawork-{s}.sock",
        .{ temporary_root, separator, hex },
        0,
    );
    return endpoint;
}

fn userTemporaryDirectory(allocator: std.mem.Allocator) ![:0]u8 {
    const required = confstr(cs_darwin_user_temp_dir, null, 0);
    if (required <= 1 or required > 4096) return error.EndpointUnavailable;
    const result = try allocator.allocSentinel(u8, required - 1, 0);
    errdefer allocator.free(result);
    if (confstr(cs_darwin_user_temp_dir, result.ptr, required) != required or
        result[result.len] != 0 or result[0] != '/')
        return error.EndpointUnavailable;
    const without_trailing_separator = std.mem.trimEnd(u8, result, "/");
    if (std.mem.eql(u8, without_trailing_separator, "/tmp") or
        std.mem.eql(u8, without_trailing_separator, "/private/tmp"))
        return error.EndpointUnavailable;
    return result;
}

test "macOS endpoint stays in the private user temporary directory and fits sun_path" {
    const temporary_root = try userTemporaryDirectory(std.testing.allocator);
    defer std.testing.allocator.free(temporary_root);
    const first = try endpointPath(std.testing.allocator, "/Users/test/MetaWork Dev");
    defer std.testing.allocator.free(first);
    const second = try endpointPath(std.testing.allocator, "/Users/test/MetaWork Dev");
    defer std.testing.allocator.free(second);
    try std.testing.expect(std.mem.startsWith(u8, first, temporary_root));
    try std.testing.expect(first.len < @sizeOf(@FieldType(SockAddrUn, "path")));
    try std.testing.expectEqualStrings(first, second);
}

fn socketAddress(endpoint: []const u8) !SockAddrUn {
    var address = SockAddrUn{};
    if (endpoint.len >= address.path.len) return error.EndpointNameTooLong;
    @memcpy(address.path[0..endpoint.len], endpoint);
    address.path[endpoint.len] = 0;
    return address;
}

fn setTimeout(socket_fd: fd_t) !void {
    const timeout = TimeVal{
        .seconds = @divFloor(response_timeout_ms, 1000),
        .microseconds = @mod(response_timeout_ms, 1000) * 1000,
    };
    if (setsockopt(socket_fd, sol_socket, so_sndtimeo, &timeout, @sizeOf(TimeVal)) != 0 or
        setsockopt(socket_fd, sol_socket, so_rcvtimeo, &timeout, @sizeOf(TimeVal)) != 0)
        return error.EndpointUnavailable;
}

fn readFrame(socket_fd: fd_t, output: []u8) !usize {
    var header: [4]u8 = undefined;
    try readAll(socket_fd, &header);
    const length = std.mem.readInt(u32, &header, .little);
    if (length == 0 or length > output.len) return error.InvalidFrame;
    try readAll(socket_fd, output[0..length]);
    return length;
}

fn writeFrame(socket_fd: fd_t, bytes: []const u8) !void {
    if (bytes.len == 0 or bytes.len > contract.max_transport_request_bytes)
        return error.InvalidFrame;
    var header: [4]u8 = undefined;
    std.mem.writeInt(u32, &header, @intCast(bytes.len), .little);
    try writeAll(socket_fd, &header);
    try writeAll(socket_fd, bytes);
}

fn readAll(socket_fd: fd_t, output: []u8) !void {
    var cursor: usize = 0;
    while (cursor < output.len) {
        const count = read(socket_fd, output[cursor..].ptr, output.len - cursor);
        if (count <= 0) return error.TransferFailed;
        cursor += @intCast(count);
    }
}

fn writeAll(socket_fd: fd_t, bytes: []const u8) !void {
    var cursor: usize = 0;
    while (cursor < bytes.len) {
        const count = write(socket_fd, bytes[cursor..].ptr, bytes.len - cursor);
        if (count <= 0) return error.TransferFailed;
        cursor += @intCast(count);
    }
}
