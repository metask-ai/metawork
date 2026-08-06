//! Desktop Host compatibility seam for System WebView window controls.
//!
//! Native SDK 0.8.0 owns the startup window and provides minimize through its
//! Runtime API. It does not expose maximize/restore, user-close, or maximized
//! state for that window. This seam supplies only those missing capabilities.

const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const std = @import("std");

const Platform = switch (builtin.os.tag) {
    .windows => @import("system_webview_window_controls/windows.zig"),
    else => struct {
        pub const renderer_controls = false;
        pub const State = struct {};

        pub fn prepareStartup(_: *@This().State) !void {}

        pub fn captureStartupWindow(
            _: *@This().State,
            _: native_sdk.platform.WindowId,
        ) !void {}

        pub fn control(_: *@This().State, _: Action) !void {
            return error.UnsupportedSystemWebViewWindowControl;
        }

        pub fn maximized(_: *const @This().State) bool {
            return false;
        }

        pub fn deinit(_: *@This().State) void {}
    },
};

pub const Action = enum {
    toggle_maximize,
    user_close,
};

pub const State = struct {
    renderer_controls: bool,
    maximized: bool,
};

pub const Capability = struct {
    window_id: native_sdk.platform.WindowId,
    platform: Platform.State = .{},

    pub fn init(window_id: native_sdk.platform.WindowId) Capability {
        std.debug.assert(window_id != 0);
        return .{ .window_id = window_id };
    }

    pub fn prepareStartup(self: *Capability) !void {
        try Platform.prepareStartup(&self.platform);
    }

    pub fn captureStartupWindow(self: *Capability) !void {
        try Platform.captureStartupWindow(&self.platform, self.window_id);
    }

    pub fn control(self: *Capability, action: Action) !State {
        try Platform.control(&self.platform, action);
        return self.state();
    }

    pub fn state(self: *const Capability) State {
        return .{
            .renderer_controls = Platform.renderer_controls,
            .maximized = Platform.maximized(&self.platform),
        };
    }

    pub fn deinit(self: *Capability) void {
        Platform.deinit(&self.platform);
    }
};

test "unsupported platforms do not advertise Renderer controls" {
    if (builtin.os.tag == .windows) return;
    var capability = Capability.init(1);
    defer capability.deinit();
    try capability.prepareStartup();
    try capability.captureStartupWindow();
    const state = capability.state();
    try std.testing.expect(!state.renderer_controls);
    try std.testing.expect(!state.maximized);
}
