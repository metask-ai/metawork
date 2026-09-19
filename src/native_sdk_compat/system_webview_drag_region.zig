//! Application-owned compatibility seam for System WebView drag regions.
//!
//! Native SDK 0.10.1 owns the window, chrome geometry, and platform drag loop.
//! Its Windows drag-region public API only covers GPU surfaces, not the startup
//! System WebView, so
//! MetaWork keeps this bounded seam until that Runtime API is available.
//! Renderer classifies DOM targets; Host restricts gestures to the native top
//! band. Renderer input never carries native window identity.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const startup_window = @import("system_webview_startup_window.zig");
const types = @import("system_webview_drag_region/types.zig");
pub const GestureOutcome = types.GestureOutcome;
pub const GestureAction = types.GestureAction;
// Only the isolated build entry may instantiate this unproven input primitive.
pub const InputPrototype = if (builtin.os.tag == .windows) Platform.InputPrototype else void;

const Platform = switch (builtin.os.tag) {
    .windows => @import("system_webview_drag_region/windows.zig"),
    .macos => @import("system_webview_drag_region/macos.zig"),
    else => struct {
        pub const gesture_mode: types.GestureMode = .disabled;
        pub const chrome_top_override: ?f64 = null;
        pub const State = struct {};

        pub fn captureStartupWindow(_: *State, _: startup_window.Binding) !void {
            return error.SystemWebViewChromeUnavailable;
        }

        pub fn requirePlatform(_: native_sdk.platform.PlatformServices) !void {
            return error.SystemWebViewChromeUnavailable;
        }

        pub fn bindRoot(_: *State) !void {
            return error.SystemWebViewChromeUnavailable;
        }

        pub fn handleGesture(_: *State, _: native_sdk.platform.PlatformServices, _: native_sdk.platform.WindowId, _: GestureAction, _: f64, _: f64) !GestureOutcome {
            return .ignored;
        }

        pub fn deinit(_: *State) void {}
    },
};

pub const Environment = struct {
    top: f64,
    left: f64,
    bottom: f64,
    right: f64,
    buttons_x: f64,
    buttons_y: f64,
    buttons_width: f64,
    buttons_height: f64,
    gesture_mode: types.GestureMode,
};

pub const Capability = struct {
    window_id: native_sdk.platform.WindowId,
    platform_ready: bool = false,
    document_attached: bool = false,
    platform: Platform.State = .{},

    pub fn init(window_id: native_sdk.platform.WindowId) Capability {
        std.debug.assert(window_id != 0);
        return .{ .window_id = window_id };
    }

    pub fn captureStartupWindow(
        self: *Capability,
        binding: startup_window.Binding,
    ) !void {
        try Platform.captureStartupWindow(&self.platform, binding);
    }

    pub fn requirePlatform(
        _: *Capability,
        services: native_sdk.platform.PlatformServices,
    ) !void {
        if (services.window_chrome_fn == null)
            return error.SystemWebViewChromeUnavailable;
        try Platform.requirePlatform(services);
    }

    pub fn bindRoot(self: *Capability) void {
        Platform.bindRoot(&self.platform) catch {
            self.platform_ready = false;
            return;
        };
        self.platform_ready = true;
    }

    pub fn connect(
        self: *Capability,
        services: native_sdk.platform.PlatformServices,
    ) !Environment {
        try self.requirePlatform(services);
        self.document_attached = self.platform_ready;
        return self.environment(services);
    }

    pub fn handleGesture(
        self: *Capability,
        services: native_sdk.platform.PlatformServices,
        action: GestureAction,
        x: f64,
        y: f64,
    ) !GestureOutcome {
        if (!self.document_attached or !types.validCoordinate(x) or !types.validCoordinate(y)) {
            return error.InvalidWindowChromeGesture;
        }
        return Platform.handleGesture(
            &self.platform,
            services,
            self.window_id,
            action,
            x,
            y,
        );
    }

    pub fn current(
        self: *const Capability,
        services: native_sdk.platform.PlatformServices,
    ) Environment {
        return self.environment(services);
    }

    pub fn disconnect(self: *Capability) void {
        self.document_attached = false;
    }

    pub fn deinit(self: *Capability) void {
        self.disconnect();
        self.platform_ready = false;
        Platform.deinit(&self.platform);
    }

    fn environment(
        self: *const Capability,
        services: native_sdk.platform.PlatformServices,
    ) Environment {
        return self.environmentFromChrome(services.windowChrome(self.window_id));
    }

    fn environmentFromChrome(
        self: *const Capability,
        chrome: native_sdk.platform.WindowChrome,
    ) Environment {
        return .{
            .top = self.chromeTop(chrome),
            .left = chrome.insets.left,
            .bottom = chrome.insets.bottom,
            .right = chrome.insets.right,
            .buttons_x = chrome.buttons.x,
            .buttons_y = chrome.buttons.y,
            .buttons_width = chrome.buttons.width,
            .buttons_height = chrome.buttons.height,
            .gesture_mode = if (self.document_attached) Platform.gesture_mode else .disabled,
        };
    }

    fn chromeTop(
        _: *const Capability,
        chrome: native_sdk.platform.WindowChrome,
    ) f64 {
        return Platform.chrome_top_override orelse chrome.insets.top;
    }
};

test "disconnect revokes both gestures and disables input mode" {
    var capability = Capability.init(1);
    capability.document_attached = true;
    capability.disconnect();
    try std.testing.expect(!capability.document_attached);
    for ([_]GestureAction{ .start_drag, .toggle_maximize }) |action|
        try std.testing.expectError(error.InvalidWindowChromeGesture, capability.handleGesture(.{}, action, 20, 20));
    try std.testing.expectEqual(types.GestureMode.disabled, capability.current(.{}).gesture_mode);
}

test "refresh preserves attachment and both gestures reject invalid coordinates" {
    var capability = Capability.init(1);
    capability.document_attached = true;
    _ = capability.current(.{});
    try std.testing.expect(capability.document_attached);
    for ([_]GestureAction{ .start_drag, .toggle_maximize }) |action| {
        try std.testing.expectError(error.InvalidWindowChromeGesture, capability.handleGesture(.{}, action, -1, 20));
        try std.testing.expectError(error.InvalidWindowChromeGesture, capability.handleGesture(.{}, action, 20, std.math.nan(f64)));
    }
}

test "macOS authorizes event coordinates against SDK top band before dragging" {
    const macos = @import("system_webview_drag_region/macos.zig");
    const Harness = struct {
        var calls: usize = 0;
        fn chrome(_: ?*anyopaque, _: native_sdk.platform.WindowId) native_sdk.platform.WindowChrome {
            return .{ .insets = .{ .top = 52 } };
        }
        fn drag(_: ?*anyopaque, _: native_sdk.platform.WindowId) anyerror!void {
            calls += 1;
        }
    };
    Harness.calls = 0;
    const services: native_sdk.platform.PlatformServices = .{ .window_chrome_fn = Harness.chrome, .start_window_drag_fn = Harness.drag };
    var state: macos.State = .{};
    for ([_]f64{ -1, 52, 100, std.math.nan(f64) }) |y| {
        try std.testing.expectEqual(GestureOutcome.ignored, try macos.handleGesture(&state, services, 1, .start_drag, 20, y));
    }
    try std.testing.expectEqual(@as(usize, 0), Harness.calls);
    try std.testing.expectError(error.InvalidWindowChromeGesture, macos.handleGesture(&state, services, 1, .toggle_maximize, 20, 20));
    try std.testing.expectEqual(GestureOutcome.drag_started, try macos.handleGesture(&state, services, 1, .start_drag, 20, 20));
    try std.testing.expectEqual(@as(usize, 1), Harness.calls);
    try std.testing.expectEqual(GestureOutcome.ignored, try macos.handleGesture(&state, .{}, 1, .start_drag, 20, 20));
}
