//! Product-neutral OAuth loopback byte-pump contract.
//!
//! Business callback policy, paths, invalid-request budgets and response copy
//! remain with each caller.
const std = @import("std");

pub const ServerError = error{
    BindFailed,
    PortUnavailable,
    Cancelled,
    DeadlineExceeded,
    RequestInvalid,
    TooManyInvalidRequests,
    IoFailed,
};

pub const Method = enum { get, other };

pub const Request = struct {
    method: Method,
    target: []const u8,
    has_content_length: bool,
    has_transfer_encoding: bool,
};

pub const Response = struct {
    status: enum { ok, bad_request },
    body: []const u8,
    complete: bool,
};

pub const RequestSink = struct {
    context: *anyopaque,
    invalid_fn: *const fn (*anyopaque) ServerError!void,
    handle_fn: *const fn (*anyopaque, Request) ServerError!Response,

    pub fn invalid(self: RequestSink) ServerError!void {
        return self.invalid_fn(self.context);
    }

    pub fn handle(self: RequestSink, request: Request) ServerError!Response {
        return self.handle_fn(self.context, request);
    }
};

pub const Endpoint = struct {
    context: *anyopaque,
    open_fn: *const fn (*anyopaque) ServerError!u16,
    wait_fn: *const fn (
        *anyopaque,
        RequestSink,
        std.Io.Clock.Timestamp,
    ) ServerError!void,
    cancel_fn: *const fn (*anyopaque) void,
    close_fn: *const fn (*anyopaque) void,

    pub fn open(self: Endpoint) ServerError!u16 {
        return self.open_fn(self.context);
    }

    pub fn wait(
        self: Endpoint,
        sink: RequestSink,
        deadline: std.Io.Clock.Timestamp,
    ) ServerError!void {
        return self.wait_fn(self.context, sink, deadline);
    }

    pub fn cancel(self: Endpoint) void {
        self.cancel_fn(self.context);
    }

    pub fn close(self: Endpoint) void {
        self.close_fn(self.context);
    }
};
