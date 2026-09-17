//! Native SDK 0.10.1 System WebView titlebar compatibility for Windows.
//!
//! The SDK's public drag-region mirror only applies to GPU surfaces. The
//! startup System WebView remains windowed, so this seam reauthorizes each
//! browser pointer press against live OS state, delegates the first press to
//! the system caption loop, and classifies a second press with OS thresholds.

const std = @import("std");
const native_sdk = @import("native_sdk");
const startup_window = @import("../system_webview_startup_window.zig");
const types = @import("types.zig");

pub const live_pointer_drag = true;
pub const chrome_top_override: ?f64 = 40;

const HWND = ?*anyopaque;
const BOOL = i32;
const UINT = u32;
const WPARAM = usize;
const LPARAM = isize;

const ga_root: u32 = 2;
const sm_swapbutton: i32 = 23;
const sm_cxdoubleclk: i32 = 36;
const sm_cydoubleclk: i32 = 37;
const vk_lbutton: i32 = 0x01;
const vk_rbutton: i32 = 0x02;
const wm_nchittest: UINT = 0x0084;
const wm_nclbuttondown: UINT = 0x00a1;
const htclient: isize = 1;
const htcaption: WPARAM = 2;

const Point = extern struct { x: i32, y: i32 };
const Rect = extern struct { left: i32, top: i32, right: i32, bottom: i32 };

extern "user32" fn IsWindow(window: HWND) callconv(.winapi) BOOL;
extern "user32" fn GetSystemMetrics(index: i32) callconv(.winapi) i32;
extern "user32" fn GetAsyncKeyState(key: i32) callconv(.winapi) i16;
extern "user32" fn GetCursorPos(point: *Point) callconv(.winapi) BOOL;
extern "user32" fn WindowFromPoint(point: Point) callconv(.winapi) HWND;
extern "user32" fn GetAncestor(window: HWND, flags: u32) callconv(.winapi) HWND;
extern "user32" fn ScreenToClient(window: HWND, point: *Point) callconv(.winapi) BOOL;
extern "user32" fn GetDpiForWindow(window: HWND) callconv(.winapi) u32;
extern "user32" fn GetWindowRect(window: HWND, rect: *Rect) callconv(.winapi) BOOL;
extern "user32" fn GetDoubleClickTime() callconv(.winapi) UINT;
extern "user32" fn SendMessageW(window: HWND, message: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) isize;
extern "user32" fn ReleaseCapture() callconv(.winapi) BOOL;
extern "user32" fn PostMessageW(window: HWND, message: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) BOOL;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

const Press = struct {
    tick_ms: u64,
    screen_point: Point,
    window_rect: Rect,
};

const DoubleClickLimits = struct {
    time_ms: u64,
    width: i32,
    height: i32,
};

pub const State = struct {
    root: HWND = null,
    first_press: ?Press = null,
};

pub fn captureStartupWindow(
    state: *State,
    binding: startup_window.Binding,
) !void {
    state.root = binding.root orelse return error.WindowUnavailable;
}

pub fn requirePlatform(_: native_sdk.platform.PlatformServices) !void {}

pub fn bindRoot(state: *State) !void {
    _ = state.root orelse return error.WindowUnavailable;
}

pub fn handlePointerDown(
    state: *State,
    _: native_sdk.platform.PlatformServices,
    _: native_sdk.platform.WindowId,
    _: f64,
    _: f64,
) !types.PointerOutcome {
    const root = state.root orelse return error.WindowUnavailable;
    if (IsWindow(root) == 0) {
        resetPointerSequence(state);
        return error.WindowUnavailable;
    }

    const press = authorizePress(root) orelse {
        resetPointerSequence(state);
        return .ignored;
    };
    if (state.first_press) |first| {
        if (isDoubleClick(first, press, systemDoubleClickLimits())) {
            resetPointerSequence(state);
            return .toggle_maximize;
        }
    }

    state.first_press = press;
    _ = ReleaseCapture();
    if (PostMessageW(
        root,
        wm_nclbuttondown,
        htcaption,
        packScreenPoint(press.screen_point),
    ) == 0) {
        resetPointerSequence(state);
        return error.SystemWebViewDragStartFailed;
    }
    return .drag_started;
}

pub fn resetPointerSequence(state: *State) void {
    state.first_press = null;
}

pub fn deinit(state: *State) void {
    state.* = .{};
}

fn authorizePress(root: HWND) ?Press {
    const primary_button = if (GetSystemMetrics(sm_swapbutton) != 0)
        vk_rbutton
    else
        vk_lbutton;
    if ((@as(u16, @bitCast(GetAsyncKeyState(primary_button))) & 0x8000) == 0)
        return null;

    var screen_point: Point = undefined;
    if (GetCursorPos(&screen_point) == 0) return null;
    const pointer_window = WindowFromPoint(screen_point) orelse return null;
    if (GetAncestor(pointer_window, ga_root) != root) return null;
    if (SendMessageW(root, wm_nchittest, 0, packScreenPoint(screen_point)) != htclient)
        return null;

    var client_point = screen_point;
    if (ScreenToClient(root, &client_point) == 0) return null;
    const dpi = @max(GetDpiForWindow(root), 96);
    const scale = @as(f64, @floatFromInt(dpi)) / 96.0;
    if (!types.pointInTopBand(
        @as(f64, @floatFromInt(client_point.x)) / scale,
        @as(f64, @floatFromInt(client_point.y)) / scale,
        chrome_top_override.?,
    )) return null;

    var window_rect: Rect = undefined;
    if (GetWindowRect(root, &window_rect) == 0) return null;
    return .{
        .tick_ms = GetTickCount64(),
        .screen_point = screen_point,
        .window_rect = window_rect,
    };
}

fn systemDoubleClickLimits() DoubleClickLimits {
    return .{
        .time_ms = GetDoubleClickTime(),
        .width = @max(GetSystemMetrics(sm_cxdoubleclk), 1),
        .height = @max(GetSystemMetrics(sm_cydoubleclk), 1),
    };
}

fn isDoubleClick(first: Press, second: Press, limits: DoubleClickLimits) bool {
    if (second.tick_ms < first.tick_ms or
        second.tick_ms - first.tick_ms > limits.time_ms or
        !equalRect(first.window_rect, second.window_rect)) return false;
    const dx = @abs(@as(i64, second.screen_point.x) - first.screen_point.x);
    const dy = @abs(@as(i64, second.screen_point.y) - first.screen_point.y);
    return dx * 2 <= @as(i64, limits.width) and
        dy * 2 <= @as(i64, limits.height);
}

fn equalRect(left: Rect, right: Rect) bool {
    return left.left == right.left and left.top == right.top and
        left.right == right.right and left.bottom == right.bottom;
}

fn packScreenPoint(point: Point) LPARAM {
    const x: u16 = @bitCast(@as(i16, @truncate(point.x)));
    const y: u16 = @bitCast(@as(i16, @truncate(point.y)));
    return @bitCast(@as(usize, x) | (@as(usize, y) << 16));
}

test "double-click classification uses OS time distance and stable window rect" {
    const first = Press{
        .tick_ms = 100,
        .screen_point = .{ .x = 400, .y = 20 },
        .window_rect = .{ .left = 100, .top = 100, .right = 900, .bottom = 700 },
    };
    const limits = DoubleClickLimits{ .time_ms = 500, .width = 4, .height = 4 };
    try std.testing.expect(isDoubleClick(first, .{
        .tick_ms = 600,
        .screen_point = .{ .x = 402, .y = 18 },
        .window_rect = first.window_rect,
    }, limits));
    try std.testing.expect(!isDoubleClick(first, .{
        .tick_ms = 601,
        .screen_point = first.screen_point,
        .window_rect = first.window_rect,
    }, limits));
    try std.testing.expect(!isDoubleClick(first, .{
        .tick_ms = 200,
        .screen_point = .{ .x = 403, .y = 20 },
        .window_rect = first.window_rect,
    }, limits));
    try std.testing.expect(!isDoubleClick(first, .{
        .tick_ms = 200,
        .screen_point = first.screen_point,
        .window_rect = .{ .left = 101, .top = 100, .right = 901, .bottom = 700 },
    }, limits));
}
