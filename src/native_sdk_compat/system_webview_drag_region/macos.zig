//! Native SDK 0.10.1 System WebView drag-region support for macOS.

const native_sdk = @import("native_sdk");
const startup_window = @import("../system_webview_startup_window.zig");
const types = @import("types.zig");

pub const gesture_mode: types.GestureMode = .native_press;
pub const chrome_top_override: ?f64 = null;
pub const State = struct {};

pub fn captureStartupWindow(_: *State, _: startup_window.Binding) !void {}

pub fn requirePlatform(services: native_sdk.platform.PlatformServices) !void {
    if (services.start_window_drag_fn == null)
        return error.SystemWebViewChromeUnavailable;
}

pub fn bindRoot(_: *State) !void {}

pub fn handleGesture(
    _: *State,
    services: native_sdk.platform.PlatformServices,
    window_id: native_sdk.platform.WindowId,
    action: types.GestureAction,
    x: f64,
    y: f64,
) !types.GestureOutcome {
    if (action != .start_drag) return error.InvalidWindowChromeGesture;
    if (!types.pointInTopBand(x, y, services.windowChrome(window_id).insets.top)) return .ignored;
    try services.startWindowDrag(window_id);
    return .drag_started;
}

pub fn deinit(state: *State) void {
    state.* = .{};
}
