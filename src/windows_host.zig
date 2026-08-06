//! Narrow Windows startup-window identity seam for Native SDK 0.8.0.
//!
//! The SDK still owns every window and the application lifecycle. This file
//! only resolves MetaWork's single startup HWND for the drag-region seam.

const builtin = @import("builtin");
const native_sdk = @import("native_sdk");

const Windows = if (builtin.os.tag == .windows) struct {
    pub const HWND = ?*anyopaque;
    const BOOL = i32;
    const LPARAM = isize;
    const gwlp_userdata: i32 = -21;
    const EnumProc = *const fn (HWND, LPARAM) callconv(.winapi) BOOL;

    extern "user32" fn EnumThreadWindows(thread_id: u32, callback: EnumProc, data: LPARAM) callconv(.winapi) BOOL;
    extern "user32" fn GetWindowLongPtrW(window: HWND, index: i32) callconv(.winapi) isize;
    extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) u32;

    const WindowLookup = struct {
        expected_host: isize,
        window: HWND = null,
    };

    fn exactStartupWindow(
        services: native_sdk.platform.PlatformServices,
        expected_window_id: native_sdk.platform.WindowId,
    ) !HWND {
        const context = services.context orelse return error.RuntimeUnavailable;
        const platform: *native_sdk.platform.windows.WindowsPlatform = @ptrCast(@alignCast(context));
        if (platform.app_info.startupWindowCount() != 1 or
            platform.app_info.resolvedMainWindow().id != expected_window_id)
            return error.WindowIdentityMismatch;
        var lookup = WindowLookup{ .expected_host = @bitCast(@intFromPtr(platform.host)) };
        _ = EnumThreadWindows(GetCurrentThreadId(), findWindow, @intCast(@intFromPtr(&lookup)));
        return lookup.window orelse error.WindowUnavailable;
    }

    fn findWindow(window: HWND, data: LPARAM) callconv(.winapi) BOOL {
        const lookup: *WindowLookup = @ptrFromInt(@as(usize, @bitCast(data)));
        if (GetWindowLongPtrW(window, gwlp_userdata) == lookup.expected_host) {
            if (lookup.window != null) {
                lookup.window = null;
                return 0;
            }
            lookup.window = window;
        }
        return 1;
    }
} else struct {
    pub const HWND = usize;
};

pub fn exactStartupWindow(
    services: native_sdk.platform.PlatformServices,
    expected_window_id: native_sdk.platform.WindowId,
) !Windows.HWND {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
    return Windows.exactStartupWindow(services, expected_window_id);
}
