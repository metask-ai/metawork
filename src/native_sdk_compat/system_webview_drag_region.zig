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
pub const PointerOutcome = types.PointerOutcome;
// Only the isolated build entry may instantiate this unproven input primitive.
pub const InputPrototype = if (builtin.os.tag == .windows) Platform.InputPrototype else void;

const Platform = switch (builtin.os.tag) {
    .windows => @import("system_webview_drag_region/windows.zig"),
    .macos => @import("system_webview_drag_region/macos.zig"),
    else => struct {
        pub const live_pointer_drag = false;
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

        pub fn handlePointerDown(_: *State, _: native_sdk.platform.PlatformServices, _: native_sdk.platform.WindowId, _: f64, _: f64) !PointerOutcome {
            return .ignored;
        }

        pub fn resetPointerSequence(_: *State) void {}

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
    live_pointer_drag: bool,
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
        self.resetPointerSequence();
        self.document_attached = self.platform_ready;
        return self.environment(services);
    }

    pub fn handlePointerDown(
        self: *Capability,
        services: native_sdk.platform.PlatformServices,
        x: f64,
        y: f64,
    ) !PointerOutcome {
        if (!self.document_attached or !types.validCoordinate(x) or !types.validCoordinate(y)) {
            self.resetPointerSequence();
            return error.InvalidWindowChromeGesture;
        }
        return Platform.handlePointerDown(
            &self.platform,
            services,
            self.window_id,
            x,
            y,
        );
    }

    pub fn resetPointerSequence(self: *Capability) void {
        Platform.resetPointerSequence(&self.platform);
    }

    pub fn current(
        self: *const Capability,
        services: native_sdk.platform.PlatformServices,
    ) Environment {
        return self.environment(services);
    }

    pub fn disconnect(self: *Capability) void {
        self.resetPointerSequence();
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
            .live_pointer_drag = Platform.live_pointer_drag and self.document_attached,
        };
    }

    fn chromeTop(
        _: *const Capability,
        chrome: native_sdk.platform.WindowChrome,
    ) f64 {
        return Platform.chrome_top_override orelse chrome.insets.top;
    }
};

test "disconnect revokes gestures and clears the Windows press" {
    var capability = Capability.init(1);
    capability.document_attached = true;
    capability.disconnect();
    try std.testing.expect(!capability.document_attached);
    try std.testing.expectError(error.InvalidWindowChromeGesture, capability.handlePointerDown(.{}, 20, 20));
}

test "refresh does not interrupt the Windows double-click sequence" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var capability = Capability.init(1);
    capability.document_attached = true;
    capability.platform.first_press = .{
        .tick_ms = 100,
        .screen_point = .{ .x = 400, .y = 20 },
        .window_rect = .{ .left = 100, .top = 100, .right = 900, .bottom = 700 },
    };
    const first = capability.platform.first_press.?;
    _ = capability.current(.{});
    try std.testing.expect(std.meta.eql(first, capability.platform.first_press.?));
    try std.testing.expectError(error.InvalidWindowChromeGesture, capability.handlePointerDown(.{}, -1, 20));
    try std.testing.expect(capability.platform.first_press == null);
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
        try std.testing.expectEqual(PointerOutcome.ignored, try macos.handlePointerDown(&state, services, 1, 20, y));
    }
    try std.testing.expectEqual(@as(usize, 0), Harness.calls);
    try std.testing.expectEqual(PointerOutcome.drag_started, try macos.handlePointerDown(&state, services, 1, 20, 20));
    try std.testing.expectEqual(@as(usize, 1), Harness.calls);
    try std.testing.expectEqual(PointerOutcome.ignored, try macos.handlePointerDown(&state, .{}, 1, 20, 20));
}
