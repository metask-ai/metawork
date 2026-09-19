//! Native SDK 0.10.1 System WebView titlebar compatibility for Windows.
//!
//! The SDK's public drag-region mirror only applies to GPU surfaces. The
//! startup System WebView remains windowed, so this seam reauthorizes each
//! browser gesture against live OS state. The browser selects drag/toggle;
//! this seam never retains or reconstructs a previous press.

const std = @import("std");
const native_sdk = @import("native_sdk");
const startup_window = @import("../system_webview_startup_window.zig");
const types = @import("types.zig");

pub const gesture_mode: types.GestureMode = .browser_mouse;
pub const chrome_top_override: ?f64 = 40;

const HWND = ?*anyopaque;
const BOOL = i32;
const UINT = u32;
const WPARAM = usize;
const LPARAM = isize;

const ga_root: u32 = 2;
const sm_swapbutton: i32 = 23;
const vk_lbutton: i32 = 0x01;
const vk_rbutton: i32 = 0x02;
const wm_nchittest: UINT = 0x0084;
const wm_nclbuttondown: UINT = 0x00a1;
const htclient: isize = 1;
const htcaption: WPARAM = 2;

const Point = extern struct { x: i32, y: i32 };

extern "user32" fn IsWindow(window: HWND) callconv(.winapi) BOOL;
extern "user32" fn GetSystemMetrics(index: i32) callconv(.winapi) i32;
extern "user32" fn GetAsyncKeyState(key: i32) callconv(.winapi) i16;
extern "user32" fn GetCursorPos(point: *Point) callconv(.winapi) BOOL;
extern "user32" fn WindowFromPoint(point: Point) callconv(.winapi) HWND;
extern "user32" fn GetAncestor(window: HWND, flags: u32) callconv(.winapi) HWND;
extern "user32" fn ScreenToClient(window: HWND, point: *Point) callconv(.winapi) BOOL;
extern "user32" fn GetDpiForWindow(window: HWND) callconv(.winapi) u32;
extern "user32" fn SendMessageW(window: HWND, message: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) isize;
extern "user32" fn ReleaseCapture() callconv(.winapi) BOOL;
extern "user32" fn PostMessageW(window: HWND, message: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) BOOL;

pub const State = struct {
    root: HWND = null,
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

pub fn handleGesture(
    state: *State,
    _: native_sdk.platform.PlatformServices,
    _: native_sdk.platform.WindowId,
    action: types.GestureAction,
    _: f64,
    _: f64,
) !types.GestureOutcome {
    const root = state.root orelse return error.WindowUnavailable;
    if (IsWindow(root) == 0) return error.WindowUnavailable;
    const point = authorizePress(root) orelse return .ignored;
    if (action == .toggle_maximize) return .toggle_maximize;
    _ = ReleaseCapture();
    if (PostMessageW(
        root,
        wm_nclbuttondown,
        htcaption,
        packScreenPoint(point),
    ) == 0) {
        return error.SystemWebViewDragStartFailed;
    }
    return .drag_started;
}

pub fn deinit(state: *State) void {
    state.* = .{};
}

fn authorizePress(root: HWND) ?Point {
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

    return screen_point;
}

fn packScreenPoint(point: Point) LPARAM {
    const x: u16 = @bitCast(@as(i16, @truncate(point.x)));
    const y: u16 = @bitCast(@as(i16, @truncate(point.y)));
    return @bitCast(@as(usize, x) | (@as(usize, y) << 16));
}

test "both gestures require a live bound root before selecting an action" {
    var state: State = .{};
    for ([_]types.GestureAction{ .start_drag, .toggle_maximize }) |action| {
        try std.testing.expectError(error.WindowUnavailable, handleGesture(&state, .{}, 1, action, 20, 20));
        state.root = @ptrFromInt(1);
        try std.testing.expectError(error.WindowUnavailable, handleGesture(&state, .{}, 1, action, 20, 20));
        state.root = null;
    }
}
