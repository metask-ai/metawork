//! Platform seam for the WebView-owned hidden-inset titlebar.
//!
//! Native SDK's ordinary drag channel starts from a canvas pointer press.
//! MetaWork's header lives in the system WebView, so Win32 resolves the one
//! declared startup window through the exact SDK window id before posting the
//! caption message. A future multi-window product needs an SDK-owned exact-id
//! chrome seam; it must not fall back to whichever HWND happens to be active.

const builtin = @import("builtin");
const native_sdk = @import("native_sdk");

pub const State = struct { maximized: bool = false };

pub fn beginDrag(
    services: native_sdk.platform.PlatformServices,
    window_id: native_sdk.platform.WindowId,
    clicks: u8,
) !State {
    if (clicks != 1 and clicks != 2) return error.InvalidClickCount;
    if (builtin.os.tag == .windows) {
        if (clicks == 2) return Windows.toggleMaximize(services, window_id);
        try Windows.beginDrag(services, window_id);
        return Windows.state(services, window_id);
    }
    try services.startWindowDrag(window_id);
    return .{};
}

pub const Control = enum { minimize, toggle_maximize, show_system_menu, close };

pub fn control(
    services: native_sdk.platform.PlatformServices,
    window_id: native_sdk.platform.WindowId,
    action: Control,
) !State {
    switch (action) {
        .minimize => {
            const current = try state(services, window_id);
            try services.minimizeWindow(window_id);
            return current;
        },
        .close => {
            const current = try state(services, window_id);
            try services.closeWindow(window_id);
            return current;
        },
        .toggle_maximize => if (builtin.os.tag == .windows)
            return Windows.toggleMaximize(services, window_id)
        else
            return error.UnsupportedPlatform,
        .show_system_menu => if (builtin.os.tag == .windows) {
            try Windows.showSystemMenu(services, window_id);
            return Windows.state(services, window_id);
        } else return error.UnsupportedPlatform,
    }
}

pub fn state(
    services: native_sdk.platform.PlatformServices,
    window_id: native_sdk.platform.WindowId,
) !State {
    if (builtin.os.tag == .windows) return Windows.state(services, window_id);
    return .{};
}

fn packScreenPoint(x: i32, y: i32) isize {
    const x_word: u16 = @bitCast(@as(i16, @truncate(x)));
    const y_word: u16 = @bitCast(@as(i16, @truncate(y)));
    return @intCast(@as(u32, x_word) | (@as(u32, y_word) << 16));
}

const Windows = if (builtin.os.tag == .windows) struct {
    const HWND = ?*anyopaque;
    const wm_nclbuttondown: u32 = 0x00a1;
    const wm_syscommand: u32 = 0x0112;
    const htcaption: usize = 2;
    const sw_maximize: i32 = 3;
    const sw_restore: i32 = 9;
    const gwlp_userdata: i32 = -21;
    const tpm_rightbutton: u32 = 0x0002;
    const tpm_returncmd: u32 = 0x0100;

    const Point = extern struct { x: i32, y: i32 };
    const HMENU = ?*anyopaque;

    extern "user32" fn GetActiveWindow() callconv(.winapi) HWND;
    extern "user32" fn GetWindowLongPtrW(window: HWND, index: i32) callconv(.winapi) isize;
    extern "user32" fn GetCursorPos(point: *Point) callconv(.winapi) i32;
    extern "user32" fn GetSystemMenu(window: HWND, revert: i32) callconv(.winapi) HMENU;
    extern "user32" fn ReleaseCapture() callconv(.winapi) i32;
    extern "user32" fn IsZoomed(window: HWND) callconv(.winapi) i32;
    extern "user32" fn ShowWindow(window: HWND, command: i32) callconv(.winapi) i32;
    extern "user32" fn PostMessageW(
        window: HWND,
        message: u32,
        wparam: usize,
        lparam: isize,
    ) callconv(.winapi) i32;
    extern "user32" fn TrackPopupMenu(
        menu: HMENU,
        flags: u32,
        x: i32,
        y: i32,
        reserved: i32,
        window: HWND,
        rect: ?*const anyopaque,
    ) callconv(.winapi) u32;

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
        var point: Point = undefined;
        if (GetCursorPos(&point) == 0) return error.CursorUnavailable;
        _ = ReleaseCapture();
        if (PostMessageW(
            window,
            wm_nclbuttondown,
            htcaption,
            packScreenPoint(point.x, point.y),
        ) == 0)
            return error.WindowDragFailed;
    }

    fn toggleMaximize(
        services: native_sdk.platform.PlatformServices,
        window_id: native_sdk.platform.WindowId,
    ) !State {
        const window = try exactStartupWindow(services, window_id);
        _ = ShowWindow(window, if (IsZoomed(window) != 0) sw_restore else sw_maximize);
        return .{ .maximized = IsZoomed(window) != 0 };
    }

    fn showSystemMenu(
        services: native_sdk.platform.PlatformServices,
        window_id: native_sdk.platform.WindowId,
    ) !void {
        const window = try exactStartupWindow(services, window_id);
        var point: Point = undefined;
        if (GetCursorPos(&point) == 0) return error.CursorUnavailable;
        const menu = GetSystemMenu(window, 0) orelse return error.WindowMenuUnavailable;
        const command = TrackPopupMenu(
            menu,
            tpm_rightbutton | tpm_returncmd,
            point.x,
            point.y,
            0,
            window,
            null,
        );
        if (command != 0 and PostMessageW(window, wm_syscommand, command, 0) == 0)
            return error.WindowMenuFailed;
    }

    fn state(
        services: native_sdk.platform.PlatformServices,
        window_id: native_sdk.platform.WindowId,
    ) !State {
        const window = try exactStartupWindow(services, window_id);
        return .{ .maximized = IsZoomed(window) != 0 };
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
    ) !State {
        return error.UnsupportedPlatform;
    }

    fn showSystemMenu(
        _: native_sdk.platform.PlatformServices,
        _: native_sdk.platform.WindowId,
    ) !void {
        return error.UnsupportedPlatform;
    }

    fn state(
        _: native_sdk.platform.PlatformServices,
        _: native_sdk.platform.WindowId,
    ) !State {
        return .{};
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
        beginDrag(services, 1, 3),
    );
}

test "screen point packing preserves signed Win32 coordinates" {
    try @import("std").testing.expectEqual(
        @as(isize, 0xffc9fff4),
        packScreenPoint(-12, -55),
    );
}
