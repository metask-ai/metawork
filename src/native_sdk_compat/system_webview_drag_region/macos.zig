//! Native SDK 0.10.1 System WebView drag-region support for macOS.

const native_sdk = @import("native_sdk");
const startup_window = @import("../system_webview_startup_window.zig");
const types = @import("types.zig");

pub const live_pointer_drag = true;
pub const chrome_top_override: ?f64 = null;
pub const PointIsDraggableFn = types.PointIsDraggableFn;
pub const State = struct {
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

pub fn captureStartupWindow(_: *State, _: startup_window.Binding) !void {}

pub fn requirePlatform(services: native_sdk.platform.PlatformServices) !void {
    if (services.start_window_drag_fn == null)
        return error.SystemWebViewChromeUnavailable;
}

pub fn bindRoot(_: *State) !void {}

pub fn handlePointerDown(
    state: *State,
    services: native_sdk.platform.PlatformServices,
    window_id: native_sdk.platform.WindowId,
    x: f64,
    y: f64,
) !types.PointerOutcome {
    const context = state.drag_context orelse return error.InvalidWindowChromeGesture;
    const point_is_draggable = state.point_is_draggable orelse
        return error.InvalidWindowChromeGesture;
    if (!point_is_draggable(context, x, y)) return .ignored;
    try services.startWindowDrag(window_id);
    return .drag_started;
}

pub fn resetPointerSequence(_: *State) void {}

pub fn deinit(state: *State) void {
    state.* = .{};
}
