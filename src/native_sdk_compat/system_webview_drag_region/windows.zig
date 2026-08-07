//! Native SDK 0.8.0 System WebView drag-region support for Windows.
//!
//! Startup HWND identity is acquired once by the private shared startup-window
//! binding. This seam consumes that binding; it does not discover windows or
//! own a second creation interval.

const native_sdk = @import("native_sdk");
const startup_window = @import("../system_webview_startup_window.zig");

pub const live_pointer_drag = true;
pub const chrome_top_override: ?f64 = 40;
pub const PointIsDraggableFn = *const fn (*const anyopaque, f64, f64) bool;

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
    drag_context: ?*const anyopaque = null,
    point_is_draggable: ?PointIsDraggableFn = null,
};

pub fn prepareStartup(
    state: *State,
    context: *const anyopaque,
    point_is_draggable: PointIsDraggableFn,
) !void {
    state.drag_context = context;
    state.point_is_draggable = point_is_draggable;
}

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

pub fn beginLivePointerDrag(
    state: *State,
    _: native_sdk.platform.PlatformServices,
    _: native_sdk.platform.WindowId,
) !void {
    const root = state.root orelse return error.WindowUnavailable;
    if (IsWindow(root) == 0) return error.WindowUnavailable;

    const primary_button = if (GetSystemMetrics(sm_swapbutton) != 0)
        vk_rbutton
    else
        vk_lbutton;
    if ((@as(u16, @bitCast(GetAsyncKeyState(primary_button))) & 0x8000) == 0)
        return error.InvalidWindowChromeGesture;

    var screen_point: Point = undefined;
    if (GetCursorPos(&screen_point) == 0)
        return error.InvalidWindowChromeGesture;
    const pointer_window = WindowFromPoint(screen_point) orelse
        return error.InvalidWindowChromeGesture;
    if (GetAncestor(pointer_window, ga_root) != root)
        return error.InvalidWindowChromeGesture;

    const packed_screen_point = packScreenPoint(screen_point);
    if (SendMessageW(root, wm_nchittest, 0, packed_screen_point) != htclient)
        return error.InvalidWindowChromeGesture;

    var client_point = screen_point;
    if (ScreenToClient(root, &client_point) == 0)
        return error.InvalidWindowChromeGesture;
    const dpi = @max(GetDpiForWindow(root), 96);
    const scale = @as(f64, @floatFromInt(dpi)) / 96.0;
    const context = state.drag_context orelse
        return error.InvalidWindowChromeGesture;
    const point_is_draggable = state.point_is_draggable orelse
        return error.InvalidWindowChromeGesture;
    if (!point_is_draggable(
        context,
        @as(f64, @floatFromInt(client_point.x)) / scale,
        @as(f64, @floatFromInt(client_point.y)) / scale,
    )) return error.InvalidWindowChromeGesture;

    _ = ReleaseCapture();
    if (PostMessageW(
        root,
        wm_nclbuttondown,
        htcaption,
        packed_screen_point,
    ) == 0) return error.SystemWebViewDragStartFailed;
}

pub fn deinit(state: *State) void {
    state.root = null;
    state.drag_context = null;
    state.point_is_draggable = null;
}

fn packScreenPoint(point: Point) LPARAM {
    const x: u16 = @bitCast(@as(i16, @truncate(point.x)));
    const y: u16 = @bitCast(@as(i16, @truncate(point.y)));
    return @bitCast(@as(usize, x) | (@as(usize, y) << 16));
}
