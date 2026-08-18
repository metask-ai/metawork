//! Native SDK 0.9.2 secure-input compatibility for macOS.

const std = @import("std");
const secure_input = @import("../secure_input.zig");
const startup_window = @import("../system_webview_startup_window.zig");

pub const Result = union(enum) { submitted: usize, cancelled };

const Id = ?*anyopaque;
const Class = ?*anyopaque;
const Sel = ?*anyopaque;
const NSModalResponse = isize;
const NSPoint = extern struct { x: f64, y: f64 };
const NSSize = extern struct { width: f64, height: f64 };
const NSRect = extern struct { origin: NSPoint, size: NSSize };
const ns_utf8_string_encoding: usize = 4;
const ns_alert_first_button_return: NSModalResponse = 1000;

extern "objc" fn objc_getClass(name: [*:0]const u8) Class;
extern "objc" fn sel_registerName(name: [*:0]const u8) Sel;
extern "objc" fn objc_msgSend() callconv(.c) void;

// These wrappers intentionally return only pointers and scalar values. A
// future aggregate return must select the ABI-specific objc_msgSend_stret on
// x86_64 instead of extending these ordinary objc_msgSend casts blindly.

pub const State = struct { ready: bool = false };

pub fn bind(state: *State, _: startup_window.Binding) !void {
    state.ready = true;
}

pub fn capture(state: *State, options: secure_input.Options, output: []u8) !Result {
    if (!state.ready) return error.WindowUnavailable;
    const pool = send0(Id, class("NSAutoreleasePool"), selector("new"));
    defer send0(void, pool, selector("drain"));

    const alert = send0(Id, class("NSAlert"), selector("new"));
    if (alert == null) return error.PlatformFailure;
    defer send0(void, alert, selector("release"));
    const field = sendRect(
        Id,
        send0(Id, class("NSSecureTextField"), selector("alloc")),
        selector("initWithFrame:"),
        .{
            .origin = .{ .x = 0, .y = 0 },
            .size = .{ .width = 360, .height = 24 },
        },
    );
    if (field == null) return error.PlatformFailure;
    defer send0(void, field, selector("release"));

    const title = try nsString(options.title);
    defer send0(void, title, selector("release"));
    const message = try nsString(options.message);
    defer send0(void, message, selector("release"));
    const accept_label = try nsString(options.accept_label);
    defer send0(void, accept_label, selector("release"));
    const cancel_label = try nsString(options.cancel_label);
    defer send0(void, cancel_label, selector("release"));
    const empty = try nsString("");
    defer send0(void, empty, selector("release"));
    const too_large = try nsString("The value is too long. Shorten it and try again.");
    defer send0(void, too_large, selector("release"));

    send1(void, alert, selector("setMessageText:"), title);
    send1(void, alert, selector("setInformativeText:"), message);
    send1(void, alert, selector("setAccessoryView:"), field);
    _ = send1(Id, alert, selector("addButtonWithTitle:"), accept_label);
    _ = send1(Id, alert, selector("addButtonWithTitle:"), cancel_label);

    defer send1(void, field, selector("setStringValue:"), empty);
    while (true) {
        const response = send0(NSModalResponse, alert, selector("runModal"));
        if (response != ns_alert_first_button_return) {
            std.crypto.secureZero(u8, output);
            return .cancelled;
        }
        const value = send0(Id, field, selector("stringValue"));
        if (value == null) return error.PlatformFailure;
        const byte_length = sendUsize(
            value,
            selector("lengthOfBytesUsingEncoding:"),
            ns_utf8_string_encoding,
        );
        if (byte_length > output.len) {
            send1(void, alert, selector("setInformativeText:"), too_large);
            continue;
        }
        std.crypto.secureZero(u8, output);
        if (byte_length != 0) {
            const bytes = send0(?[*]const u8, value, selector("UTF8String")) orelse
                return error.PlatformFailure;
            @memcpy(output[0..byte_length], bytes[0..byte_length]);
        }
        return .{ .submitted = byte_length };
    }
}

pub fn deinit(state: *State) void {
    state.ready = false;
}

fn nsString(value: []const u8) !Id {
    const allocated = send0(Id, class("NSString"), selector("alloc"));
    if (allocated == null) return error.PlatformFailure;
    return sendBytes(
        Id,
        allocated,
        selector("initWithBytes:length:encoding:"),
        value.ptr,
        value.len,
        ns_utf8_string_encoding,
    ) orelse error.PlatformFailure;
}

fn class(name: [*:0]const u8) Class {
    return objc_getClass(name) orelse @panic("required AppKit class unavailable");
}

fn selector(name: [*:0]const u8) Sel {
    return sel_registerName(name) orelse @panic("Objective-C selector unavailable");
}

fn send0(comptime Return: type, object: Id, sel: Sel) Return {
    const Function = *const fn (Id, Sel) callconv(.c) Return;
    return @as(Function, @ptrCast(&objc_msgSend))(object, sel);
}

fn send1(comptime Return: type, object: Id, sel: Sel, argument: Id) Return {
    const Function = *const fn (Id, Sel, Id) callconv(.c) Return;
    return @as(Function, @ptrCast(&objc_msgSend))(object, sel, argument);
}

fn sendRect(
    comptime Return: type,
    object: Id,
    sel: Sel,
    rect: NSRect,
) Return {
    const Function = *const fn (Id, Sel, NSRect) callconv(.c) Return;
    return @as(Function, @ptrCast(&objc_msgSend))(object, sel, rect);
}

fn sendUsize(object: Id, sel: Sel, argument: usize) usize {
    const Function = *const fn (Id, Sel, usize) callconv(.c) usize;
    return @as(Function, @ptrCast(&objc_msgSend))(object, sel, argument);
}

fn sendBytes(
    comptime Return: type,
    object: Id,
    sel: Sel,
    bytes: [*]const u8,
    length: usize,
    encoding: usize,
) Return {
    const Function = *const fn (Id, Sel, [*]const u8, usize, usize) callconv(.c) Return;
    return @as(Function, @ptrCast(&objc_msgSend))(
        object,
        sel,
        bytes,
        length,
        encoding,
    );
}
