//! Application-owned input handoff for the Windows System WebView top border.
const builtin = @import("builtin");
const startup_window = @import("system_webview_startup_window.zig");

pub const Capability = if (builtin.os.tag == .windows)
    @import("system_webview_resize/windows.zig").State
else
    struct {
        pub fn attach(_: *@This(), _: startup_window.Binding) !void {}
        pub fn deinit(_: *@This()) void {}
    };

test {
    _ = Capability;
}
