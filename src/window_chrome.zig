//! Platform seam for the WebView-owned hidden-inset titlebar.
//!
//! Native SDK's ordinary drag channel starts from a canvas pointer press.
//! MetaWork's header lives in the system WebView, so Win32 resolves the one
//! declared startup window through the exact SDK window id before posting the
//! caption message. A future multi-window product needs an SDK-owned exact-id
//! chrome seam; it must not fall back to whichever HWND happens to be active.

const builtin = @import("builtin");
const native_sdk = @import("native_sdk");

pub fn beginDrag(
    services: native_sdk.platform.PlatformServices,
    window_id: native_sdk.platform.WindowId,
    clicks: u8,
) !void {
    if (clicks != 1) return error.InvalidClickCount;
    if (builtin.os.tag == .windows) return Windows.beginDrag(services, window_id);
    return services.startWindowDrag(window_id);
}

pub const Control = enum { minimize, toggle_maximize, close };

pub fn control(
    services: native_sdk.platform.PlatformServices,
    window_id: native_sdk.platform.WindowId,
    action: Control,
) !void {
    switch (action) {
        .minimize => try services.minimizeWindow(window_id),
        .close => try services.closeWindow(window_id),
        .toggle_maximize => if (builtin.os.tag == .windows)
            try Windows.toggleMaximize(services, window_id)
        else
            return error.UnsupportedPlatform,
    }
}

const Windows = if (builtin.os.tag == .windows) struct {
    const HWND = ?*anyopaque;
    const wm_nclbuttondown: u32 = 0x00a1;
    const htcaption: usize = 2;
    const sw_maximize: i32 = 3;
    const sw_restore: i32 = 9;
    const gwlp_userdata: i32 = -21;

    extern "user32" fn GetActiveWindow() callconv(.winapi) HWND;
    extern "user32" fn GetWindowLongPtrW(window: HWND, index: i32) callconv(.winapi) isize;
    extern "user32" fn ReleaseCapture() callconv(.winapi) i32;
    extern "user32" fn IsZoomed(window: HWND) callconv(.winapi) i32;
    extern "user32" fn ShowWindow(window: HWND, command: i32) callconv(.winapi) i32;
    extern "user32" fn PostMessageW(
        window: HWND,
        message: u32,
        wparam: usize,
        lparam: isize,
    ) callconv(.winapi) i32;

    fn exactStartupWindow(
        services: native_sdk.platform.PlatformServices,
        window_id: native_sdk.platform.WindowId,
    ) !HWND {
        const context = services.context orelse return error.RuntimeUnavailable;
        const platform: *native_sdk.platform.windows.WindowsPlatform = @ptrCast(@alignCast(context));
        if (platform.app_info.startupWindowCount() != 1 or
            platform.app_info.resolvedMainWindow().id != window_id)
            return error.WindowIdentityMismatch;
        try services.focusWindow(window_id);
        const window = GetActiveWindow() orelse return error.WindowUnavailable;
        const expected_host: isize = @bitCast(@intFromPtr(platform.host));
        if (GetWindowLongPtrW(window, gwlp_userdata) != expected_host)
            return error.WindowIdentityMismatch;
        return window;
    }

    fn beginDrag(
        services: native_sdk.platform.PlatformServices,
        window_id: native_sdk.platform.WindowId,
    ) !void {
        const window = try exactStartupWindow(services, window_id);
        _ = ReleaseCapture();
        if (PostMessageW(window, wm_nclbuttondown, htcaption, 0) == 0)
            return error.WindowDragFailed;
    }

    fn toggleMaximize(
        services: native_sdk.platform.PlatformServices,
        window_id: native_sdk.platform.WindowId,
    ) !void {
        const window = try exactStartupWindow(services, window_id);
        _ = ShowWindow(window, if (IsZoomed(window) != 0) sw_restore else sw_maximize);
    }
} else struct {
    fn beginDrag(
        _: native_sdk.platform.PlatformServices,
        _: native_sdk.platform.WindowId,
    ) !void {
        return error.UnsupportedPlatform;
    }

    fn toggleMaximize(
        _: native_sdk.platform.PlatformServices,
        _: native_sdk.platform.WindowId,
    ) !void {
        return error.UnsupportedPlatform;
    }
};

test "window drag rejects impossible click counts before platform work" {
    const services: native_sdk.platform.PlatformServices = .{};
    try @import("std").testing.expectError(
        error.InvalidClickCount,
        beginDrag(services, 1, 0),
    );
    try @import("std").testing.expectError(
        error.InvalidClickCount,
        beginDrag(services, 1, 2),
    );
}
