const std = @import("std");

pub const Header = struct {
    name: []const u8,
    value: []const u8,
    sensitive: bool = false,
};

pub const HttpRequest = struct {
    url: []const u8,
    headers: []const Header,
    body: []const u8,
};

pub const Cancellation = struct {
    state: std.atomic.Value(u32) = .init(0),
    signal_context: ?*anyopaque = null,
    signal_fn: ?*const fn (?*anyopaque, *Cancellation) void = null,

    pub fn init(transport: Transport) Cancellation {
        return .{
            .signal_context = transport.context,
            .signal_fn = transport.signal_cancellation_fn,
        };
    }

    pub fn request(self: *Cancellation) void {
        if (self.state.swap(1, .acq_rel) != 0) return;
        if (self.signal_fn) |signal| signal(self.signal_context, self);
    }

    pub fn isRequested(self: *const Cancellation) bool {
        return self.state.load(.acquire) != 0;
    }

    pub fn wait(self: *const Cancellation, io: std.Io) void {
        while (!self.isRequested()) {
            io.futexWait(u32, &self.state.raw, 0) catch return;
        }
    }
};

pub const Error = error{
    Cancelled,
    DnsFailed,
    ConnectFailed,
    TlsFailed,
    WriteFailed,
    ReadFailed,
    InvalidHttp,
    ResponseTooLarge,
    OutOfMemory,
    Unexpected,
};

pub const Response = struct {
    status: u16,
    body: []const u8,
};

pub const Transport = struct {
    context: ?*anyopaque = null,
    perform_fn: *const fn (
        ?*anyopaque,
        HttpRequest,
        *const Cancellation,
        []u8,
    ) Error!Response,
    signal_cancellation_fn: ?*const fn (
        ?*anyopaque,
        *Cancellation,
    ) void = null,

    pub fn perform(
        self: Transport,
        request: HttpRequest,
        cancellation: *const Cancellation,
        response_buffer: []u8,
    ) Error!Response {
        return self.perform_fn(
            self.context,
            request,
            cancellation,
            response_buffer,
        );
    }
};

test "Cancellation notification is first-writer idempotent" {
    const Fixture = struct {
        var signals: usize = 0;

        fn perform(
            _: ?*anyopaque,
            _: HttpRequest,
            _: *const Cancellation,
            _: []u8,
        ) Error!Response {
            return error.Unexpected;
        }

        fn signal(_: ?*anyopaque, _: *Cancellation) void {
            signals += 1;
        }
    };
    Fixture.signals = 0;
    var cancellation = Cancellation.init(.{
        .perform_fn = Fixture.perform,
        .signal_cancellation_fn = Fixture.signal,
    });
    cancellation.request();
    cancellation.request();
    try std.testing.expect(cancellation.isRequested());
    try std.testing.expectEqual(@as(usize, 1), Fixture.signals);
}
