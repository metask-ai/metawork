//! Native SDK 0.8.0 System WebView drag-region support for macOS.

const native_sdk = @import("native_sdk");

pub const live_pointer_drag = true;
pub const chrome_top_override: ?f64 = null;
pub const PointIsDraggableFn = *const fn (*const anyopaque, f64, f64) bool;
pub const State = struct {};

pub fn prepareStartup(_: *State, _: *const anyopaque, _: PointIsDraggableFn) !void {}

pub fn captureStartupWindow(_: *State, _: native_sdk.platform.WindowId) !void {}

pub fn requirePlatform(services: native_sdk.platform.PlatformServices) !void {
    if (services.start_window_drag_fn == null)
        return error.SystemWebViewChromeUnavailable;
}

pub fn install(
    _: *State,
    _: native_sdk.platform.PlatformServices,
    _: native_sdk.platform.WindowId,
) !void {}

pub fn beginLivePointerDrag(
    _: *State,
    services: native_sdk.platform.PlatformServices,
    window_id: native_sdk.platform.WindowId,
) !void {
    try services.startWindowDrag(window_id);
}

pub fn deinit(_: *State) void {}
