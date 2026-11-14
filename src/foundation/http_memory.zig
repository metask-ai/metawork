//! Wipes HTTP-owned allocations before returning them to the backing allocator.
//! Live buffers, caller-owned memory and allocations outside this allocator keep
//! their existing owners. The backing allocator must support concurrent callers.
const std = @import("std");

pub const ZeroingAllocator = struct {
    backing: std.mem.Allocator,

    pub fn allocator(self: *ZeroingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                // A backing remap could release the old block without wiping it.
                // Refusing resize also preserves the entire old block on failed
                // shrink. Allocator.realloc allocates, copies, then calls our free.
                .resize = std.mem.Allocator.noResize,
                .remap = std.mem.Allocator.noRemap,
                .free = free,
            },
        };
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *ZeroingAllocator = @ptrCast(@alignCast(context));
        return self.backing.rawAlloc(len, alignment, ret_addr);
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *ZeroingAllocator = @ptrCast(@alignCast(context));
        std.crypto.secureZero(u8, memory);
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

const ObservedAllocator = struct {
    releases: usize = 0,
    released_bytes: usize = 0,
    dirty_release: bool = false,
    fail_allocations: bool = false,

    fn allocator(self: *ObservedAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = std.mem.Allocator.noResize,
            .remap = std.mem.Allocator.noRemap,
            .free = free,
        } };
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *ObservedAllocator = @ptrCast(@alignCast(context));
        if (self.fail_allocations) return null;
        const result = std.testing.allocator.rawAlloc(len, alignment, ret_addr) orelse return null;
        @memset(result[0..len], 0xa5);
        return result;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *ObservedAllocator = @ptrCast(@alignCast(context));
        self.releases += 1;
        self.released_bytes += memory.len;
        for (memory) |byte| self.dirty_release = self.dirty_release or byte != 0;
        std.testing.allocator.rawFree(memory, alignment, ret_addr);
    }
};

test "HTTP allocator wipes complete aligned allocations before backing free" {
    var observed: ObservedAllocator = .{};
    var wiping: ZeroingAllocator = .{ .backing = observed.allocator() };
    const allocator = wiping.allocator();
    const memory = try allocator.alignedAlloc(u8, .@"64", 193);
    @memcpy(memory[0..13], "Authorization");
    allocator.free(memory);
    try std.testing.expect(!observed.dirty_release);
    try std.testing.expectEqual(@as(usize, 1), observed.releases);
    try std.testing.expectEqual(@as(usize, 193), observed.released_bytes);
}

test "HTTP realloc growth and shrink copy live bytes and wipe every old allocation" {
    var observed: ObservedAllocator = .{};
    var wiping: ZeroingAllocator = .{ .backing = observed.allocator() };
    const allocator = wiping.allocator();
    var memory = try allocator.dupe(u8, "synthetic bearer");
    memory = try allocator.realloc(memory, 96);
    try std.testing.expectEqualStrings("synthetic bearer", memory[0..16]);
    @memset(memory[16..], 0x5a);
    memory = try allocator.realloc(memory, 9);
    try std.testing.expectEqualStrings("synthetic", memory);
    allocator.free(memory);
    try std.testing.expect(!observed.dirty_release);
    try std.testing.expectEqual(@as(usize, 3), observed.releases);
    try std.testing.expectEqual(@as(usize, 16 + 96 + 9), observed.released_bytes);
}

test "HTTP realloc failure leaves the original allocation intact for growth and shrink" {
    for ([_]usize{ 3, 128 }) |new_len| {
        var observed: ObservedAllocator = .{};
        var wiping: ZeroingAllocator = .{ .backing = observed.allocator() };
        const allocator = wiping.allocator();
        const memory = try allocator.dupe(u8, "original token");
        observed.fail_allocations = true;
        try std.testing.expectError(error.OutOfMemory, allocator.realloc(memory, new_len));
        try std.testing.expectEqualStrings("original token", memory);
        try std.testing.expectEqual(@as(usize, 0), observed.releases);
        allocator.free(memory);
        try std.testing.expect(!observed.dirty_release);
        try std.testing.expectEqual(@as(usize, 1), observed.releases);
    }
}

test "HTTP client wipes its allocated buffers after a real authenticated request" {
    const Fixture = struct {
        fn serve(listener: *std.Io.net.Server) !void {
            var stream = try listener.accept(std.testing.io);
            defer stream.close(std.testing.io);
            var read_buffer: [2048]u8 = undefined;
            var write_buffer: [256]u8 = undefined;
            var reader = stream.reader(std.testing.io, &read_buffer);
            var writer = stream.writer(std.testing.io, &write_buffer);
            var server: std.http.Server = .init(&reader.interface, &writer.interface);
            var request = try server.receiveHead();
            var headers = request.iterateHeaders();
            var authenticated = false;
            while (headers.next()) |header| {
                if (std.ascii.eqlIgnoreCase(header.name, "Authorization")) {
                    try std.testing.expectEqualStrings("Bearer synthetic-token", header.value);
                    authenticated = true;
                }
            }
            try std.testing.expect(authenticated);
            try request.respond("test", .{ .keep_alive = false });
        }
    };
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = try address.listen(std.testing.io, .{});
    defer listener.deinit(std.testing.io);
    var server = try std.testing.io.concurrent(Fixture.serve, .{&listener});
    defer server.cancel(std.testing.io) catch {};
    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/", .{listener.socket.address.getPort()});
    defer std.testing.allocator.free(url);
    var observed: ObservedAllocator = .{};
    var wiping: ZeroingAllocator = .{ .backing = observed.allocator() };
    var response_buffer: [4]u8 = undefined;
    var response_writer = std.Io.Writer.fixed(&response_buffer);
    {
        var client: std.http.Client = .{ .allocator = wiping.allocator(), .io = std.testing.io };
        defer client.deinit();
        const response = try client.fetch(.{
            .location = .{ .url = url },
            .redirect_behavior = .unhandled,
            .response_writer = &response_writer,
            .extra_headers = &.{.{ .name = "Authorization", .value = "Bearer synthetic-token" }},
        });
        try std.testing.expectEqual(std.http.Status.ok, response.status);
    }
    try server.await(std.testing.io);
    try std.testing.expectEqualStrings("test", response_writer.buffered());
    try std.testing.expect(observed.releases > 0);
    try std.testing.expect(!observed.dirty_release);
}
