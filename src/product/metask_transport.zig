//! Shared Metask HTTP transport values.
//!
//! This leaf describes only Application-owned request execution. It carries no
//! Account or Models state and contains no provider policy.

const std = @import("std");

pub const RequestKind = enum {
    exchange_code,
    refresh_token,
    current_user,
    usage_dashboard,
    keys,
    models,
};

pub const Request = struct {
    kind: RequestKind,
    body: []const u8 = "",
    bearer: ?[]const u8 = null,
    control: ?RequestControl = null,
};

pub const Response = struct {
    status: u16,
    body: []const u8,
};

pub const TransportError = error{
    NetworkFailed,
    ResponseTooLarge,
    ProtocolFailed,
    Cancelled,
    DeadlineExceeded,
};

pub const Cancellation = struct {
    io: std.Io,
    state: std.atomic.Value(u32) = .init(0),

    pub fn init(io: std.Io) Cancellation {
        return .{ .io = io };
    }

    pub fn cancel(self: *Cancellation) void {
        self.state.store(1, .release);
        self.io.futexWake(u32, &self.state.raw, std.math.maxInt(u32));
    }

    pub fn isCancelled(self: *const Cancellation) bool {
        return self.state.load(.acquire) != 0;
    }

    pub fn wait(self: *const Cancellation) void {
        while (!self.isCancelled()) {
            self.io.futexWait(u32, &self.state.raw, 0) catch return;
        }
    }
};

pub const RequestControl = struct {
    cancellation: *const Cancellation,
    deadline: std.Io.Clock.Timestamp,
};

pub const Transport = struct {
    context: *anyopaque,
    perform_fn: *const fn (
        context: *anyopaque,
        request: Request,
        response_buffer: []u8,
    ) TransportError!Response,

    pub fn perform(
        self: Transport,
        request: Request,
        response_buffer: []u8,
    ) TransportError!Response {
        return self.perform_fn(self.context, request, response_buffer);
    }
};
