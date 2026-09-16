//! Native SDK 0.10.1 System WebView drag-region support for macOS.

const native_sdk = @import("native_sdk");
const startup_window = @import("../system_webview_startup_window.zig");
const types = @import("types.zig");

pub const live_pointer_drag = true;
pub const chrome_top_override: ?f64 = null;
pub const State = struct {};

pub fn captureStartupWindow(_: *State, _: startup_window.Binding) !void {}

pub fn requirePlatform(services: native_sdk.platform.PlatformServices) !void {
    if (services.start_window_drag_fn == null)
        return error.SystemWebViewChromeUnavailable;
}

pub fn bindRoot(_: *State) !void {}

pub fn handlePointerDown(
    _: *State,
    services: native_sdk.platform.PlatformServices,
    window_id: native_sdk.platform.WindowId,
    x: f64,
    y: f64,
) !types.PointerOutcome {
    if (!types.pointInTopBand(x, y, services.windowChrome(window_id).insets.top)) return .ignored;
    try services.startWindowDrag(window_id);
    return .drag_started;
}

pub fn resetPointerSequence(_: *State) void {}

pub fn deinit(state: *State) void {
    state.* = .{};
}
