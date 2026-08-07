//! Native SDK 0.8.0 System WebView window-control compatibility for Windows.
//!
//! The SDK does not expose maximize/restore, user-close, or maximized state.
//! These capabilities consume the one shared startup-window binding but retain
//! explicit entry points and independent removal conditions.

const startup_window = @import("../system_webview_startup_window.zig");

pub const renderer_controls = true;

const HWND = ?*anyopaque;
const BOOL = i32;
const UINT = u32;
const WPARAM = usize;
const LPARAM = isize;

const wm_close: UINT = 0x0010;
const sw_maximize: i32 = 3;
const sw_restore: i32 = 9;

extern "user32" fn PostMessageW(window: HWND, message: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) BOOL;
extern "user32" fn IsZoomed(window: HWND) callconv(.winapi) BOOL;
extern "user32" fn ShowWindow(window: HWND, command: i32) callconv(.winapi) BOOL;

pub const State = struct {
    root: HWND = null,
};

pub fn prepareStartup(_: *State) !void {}

pub fn captureStartupWindow(
    state: *State,
    binding: startup_window.Binding,
) !void {
    state.root = binding.root orelse return error.WindowUnavailable;
}

pub fn toggleMaximize(state: *State) !void {
    const root = state.root orelse return error.WindowUnavailable;
    _ = ShowWindow(
        root,
        if (IsZoomed(root) != 0) sw_restore else sw_maximize,
    );
}

pub fn userClose(state: *State) !void {
    const root = state.root orelse return error.WindowUnavailable;
    if (PostMessageW(root, wm_close, 0, 0) == 0)
        return error.SystemWebViewUserCloseFailed;
}

pub fn maximized(state: *const State) bool {
    return if (state.root) |root| IsZoomed(root) != 0 else false;
}

pub fn deinit(state: *State) void {
    state.root = null;
}
