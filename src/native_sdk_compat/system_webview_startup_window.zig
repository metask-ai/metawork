//! Application-owned startup-window identity acquisition shared by compatibility seams.
//!
//! This is lifecycle plumbing, not a window capability. It owns exactly one
//! current-thread creation interval and hands one verified opaque binding to
//! the independently removable window compatibility seams.

const builtin = @import("builtin");
const native_sdk = @import("native_sdk");

const Platform = switch (builtin.os.tag) {
    .windows => @import("system_webview_startup_window/windows.zig"),
    else => struct {
        const NoopBinding = struct {};
        pub const Binding = NoopBinding;
        pub const Capture = struct {
            pub fn prepare(_: *@This()) !void {}

            pub fn take(
                _: *@This(),
                _: native_sdk.platform.WindowId,
            ) !NoopBinding {
                return .{};
            }

            pub fn deinit(_: *@This()) void {}
        };
    },
};

pub const Binding = Platform.Binding;
pub const Capture = Platform.Capture;

pub const TestSupport = if (builtin.is_test) struct {
    pub const Window = if (builtin.os.tag == .windows) Platform.TestSupport.Window else struct {
        pub fn init() !@This() {
            return .{};
        }
        pub fn deinit(_: @This()) void {}
    };
} else struct {};
