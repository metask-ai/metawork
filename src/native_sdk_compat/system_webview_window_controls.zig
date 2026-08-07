//! Desktop Host compatibility seam for System WebView window controls.
//!
//! Native SDK 0.8.0 owns the startup window and provides minimize through its
//! Runtime API. It does not expose maximize/restore, user-close, or maximized
//! state for that window. These independently removable capabilities share one
//! narrow file only because they require the same startup-window binding.

const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const std = @import("std");
const startup_window = @import("system_webview_startup_window.zig");

const Platform = switch (builtin.os.tag) {
    .windows => @import("system_webview_window_controls/windows.zig"),
    else => struct {
        pub const renderer_controls = false;
        pub const State = struct {};

        pub fn prepareStartup(_: *@This().State) !void {}

        pub fn captureStartupWindow(
            _: *@This().State,
            _: startup_window.Binding,
        ) !void {}

        pub fn toggleMaximize(_: *@This().State) !void {
            return error.UnsupportedSystemWebViewMaximize;
        }

        pub fn userClose(_: *@This().State) !void {
            return error.UnsupportedSystemWebViewUserClose;
        }

        pub fn maximized(_: *const @This().State) bool {
            return false;
        }

        pub fn deinit(_: *@This().State) void {}
    },
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

    pub fn captureStartupWindow(
        self: *Capability,
        binding: startup_window.Binding,
    ) !void {
        try Platform.captureStartupWindow(&self.platform, binding);
    }

    pub fn toggleMaximize(self: *Capability) !void {
        try Platform.toggleMaximize(&self.platform);
    }

    pub fn userClose(self: *Capability) !void {
        try Platform.userClose(&self.platform);
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
    try capability.captureStartupWindow(.{});
    const state = capability.state();
    try std.testing.expect(!state.renderer_controls);
    try std.testing.expect(!state.maximized);
}
