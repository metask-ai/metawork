const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const bridge_api = @import("metawork_bridge");
const control_ports = @import("metawork_product_control_ports");
const drag_region = @import("../native_sdk_compat/system_webview_drag_region.zig");
const startup_window = @import("../native_sdk_compat/system_webview_startup_window.zig");
const window_controls = @import("../native_sdk_compat/system_webview_window_controls.zig");
const resize = @import("../native_sdk_compat/system_webview_resize.zig");

pub const main_window_id: native_sdk.platform.WindowId = 1;
pub const tray_open_id: native_sdk.platform.TrayItemId = 1;
pub const tray_quit_id: native_sdk.platform.TrayItemId = 2;

const tray_items = [_]native_sdk.platform.TrayMenuItem{
    .{ .id = tray_open_id, .label = "Open MetaWork", .command = "metawork.tray.open" },
    .{ .separator = true },
    .{ .id = tray_quit_id, .label = "Quit MetaWork", .command = "metawork.tray.quit" },
};

const tray_icon_path = switch (builtin.os.tag) {
    .windows => "assets/icons/tray-icon.ico",
    else => "assets/icons/tray-icon.png",
};

pub const State = struct {
    startup_window_capture: startup_window.Capture = .{},
    drag_region_capability: drag_region.Capability = drag_region.Capability.init(main_window_id),
    window_controls_capability: window_controls.Capability = window_controls.Capability.init(main_window_id),
    resize_capability: resize.Capability = .{},
    tray_installed: bool = false,

    pub fn prepareStartup(self: *State) !void {
        try self.drag_region_capability.prepareStartup();
        try self.window_controls_capability.prepareStartup();
        try self.startup_window_capture.prepare();
    }

    pub fn captureStartupWindow(self: *State) !void {
        const startup_binding = try self.startup_window_capture.take(main_window_id);
        try self.drag_region_capability.captureStartupWindow(startup_binding);
        try self.window_controls_capability.captureStartupWindow(startup_binding);
        try self.resize_capability.attach(startup_binding, self, resetTitlebarSequence);
    }

    pub fn bind(self: *State, services: native_sdk.platform.PlatformServices) !void {
        try self.drag_region_capability.requirePlatform(services);
        self.drag_region_capability.bindRoot();
    }

    pub fn deinit(self: *State) void {
        self.resize_capability.deinit();
        self.startup_window_capture.deinit();
        self.window_controls_capability.deinit();
        self.drag_region_capability.deinit();
    }

    fn resetTitlebarSequence(data: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(data));
        self.drag_region_capability.resetPointerSequence();
    }

    pub fn installTray(
        self: *State,
        io: std.Io,
        runtime: *native_sdk.Runtime,
        schedule: control_ports.ScheduleHost,
    ) !void {
        var icon_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        try runtime.createTray(.{
            .icon_path = resolveTrayIconPath(io, &icon_path_buffer),
            .tooltip = "MetaWork",
            .items = &tray_items,
        });
        self.tray_installed = true;
        schedule.setScheduleBackgroundAvailableNoFail(true);
    }

    pub fn removeTray(self: *State, runtime: *native_sdk.Runtime) void {
        if (!self.tray_installed) return;
        runtime.removeTray() catch {};
        self.tray_installed = false;
    }

    pub fn showMainWindow(_: *State, runtime: *native_sdk.Runtime) void {
        runtime.showWindow(main_window_id) catch return;
        runtime.focusWindow(main_window_id) catch {};
    }

    pub fn confirmExplicitQuit(
        _: *State,
        runtime: *native_sdk.Runtime,
        schedule: control_ports.ScheduleHost,
    ) bool {
        if (schedule.hasEnabledScheduledTasks()) {
            const result = runtime.showMessageDialog(.{
                .style = .warning,
                .title = "Quit MetaWork?",
                .message = "Scheduled tasks will pause while MetaWork is not running.",
                .informative_text = "Closing the main window keeps them running. Use Quit only when you want to stop the background host.",
                .primary_button = "Keep Running",
                .secondary_button = "Quit MetaWork",
            }) catch return false;
            if (result != .secondary) return false;
        }
        return true;
    }

    pub fn requestExplicitQuit(_: *State, runtime: *native_sdk.Runtime) !void {
        try runtime.closeWindow(main_window_id);
    }

    pub fn notifyScheduledTask(
        _: *State,
        services: native_sdk.platform.PlatformServices,
        notification: control_ports.ScheduleNotification,
    ) bool {
        const body = switch (notification.kind) {
            .completed => "Scheduled task completed",
            .failed => "Scheduled task failed",
            .skipped => "A run was skipped because the previous run is still active",
            .needs_attention => "Scheduled task needs attention",
        };
        services.showNotification(.{
            .title = "MetaWork",
            .subtitle = notification.title,
            .body = body,
        }) catch return false;
        return true;
    }

    pub fn showOpenDialog(
        _: *State,
        services: native_sdk.platform.PlatformServices,
        options: native_sdk.platform.OpenDialogOptions,
        output: []u8,
    ) !native_sdk.platform.OpenDialogResult {
        return services.showOpenDialog(options, output);
    }

    pub fn showMessageDialog(
        _: *State,
        services: native_sdk.platform.PlatformServices,
        options: native_sdk.platform.MessageDialogOptions,
    ) !native_sdk.platform.MessageDialogResult {
        return services.showMessageDialog(options);
    }

    pub fn connect(
        self: *State,
        services: native_sdk.platform.PlatformServices,
        window_id: native_sdk.platform.WindowId,
    ) !bridge_api.WindowChromePlatformEnvironment {
        try requireMainWindow(window_id);
        return environment(
            try self.drag_region_capability.connect(services),
            self.window_controls_capability.state(),
        );
    }

    pub fn sync(
        self: *State,
        services: native_sdk.platform.PlatformServices,
        window_id: native_sdk.platform.WindowId,
        viewport_width: f64,
        viewport_height: f64,
        regions: []const bridge_api.WindowChromeRegion,
    ) !bridge_api.WindowChromePlatformEnvironment {
        if (window_id != main_window_id or regions.len > drag_region.max_regions)
            return error.WindowIdentityMismatch;
        var chrome_regions: [drag_region.max_regions]drag_region.Region = undefined;
        for (regions, 0..) |region, index| chrome_regions[index] = .{
            .x = region.x,
            .y = region.y,
            .width = region.width,
            .height = region.height,
            .exclusion = region.exclusion,
        };
        return environment(
            try self.drag_region_capability.sync(
                services,
                viewport_width,
                viewport_height,
                chrome_regions[0..regions.len],
            ),
            self.window_controls_capability.state(),
        );
    }

    pub fn handlePointer(
        self: *State,
        services: native_sdk.platform.PlatformServices,
        window_id: native_sdk.platform.WindowId,
        pointer: bridge_api.WindowChromePointer,
    ) !bridge_api.WindowChromePlatformEnvironment {
        try requireMainWindow(window_id);
        const outcome = switch (pointer) {
            .down => |down| try self.drag_region_capability.handlePointerDown(
                services,
                down.x,
                down.y,
            ),
            .reset => reset: {
                self.drag_region_capability.resetPointerSequence();
                break :reset drag_region.PointerOutcome.ignored;
            },
        };
        if (outcome == .toggle_maximize)
            try self.window_controls_capability.toggleMaximize();
        return environment(
            self.drag_region_capability.current(services),
            self.window_controls_capability.state(),
        );
    }

    pub fn disconnect(self: *State, window_id: native_sdk.platform.WindowId) !void {
        try requireMainWindow(window_id);
        self.drag_region_capability.disconnect();
    }

    pub fn control(
        self: *State,
        runtime: *native_sdk.Runtime,
        services: native_sdk.platform.PlatformServices,
        window_id: native_sdk.platform.WindowId,
        action: bridge_api.WindowChromeControlAction,
    ) !bridge_api.WindowChromePlatformEnvironment {
        try requireMainWindow(window_id);
        switch (action) {
            .minimize => try runtime.minimizeWindow(main_window_id),
            .toggle_maximize => try self.window_controls_capability.toggleMaximize(),
            .close => try self.window_controls_capability.userClose(),
        }
        return environment(
            self.drag_region_capability.current(services),
            self.window_controls_capability.state(),
        );
    }
};

fn resolveTrayIconPath(io: std.Io, output: []u8) []const u8 {
    if (comptime builtin.os.tag != .windows) return tray_icon_path;

    var executable_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const executable_len = std.process.executablePath(io, &executable_buffer) catch
        return tray_icon_path;
    const candidate = windowsPackagedTrayIconPath(
        executable_buffer[0..executable_len],
        output,
    ) orelse return tray_icon_path;
    const stat = std.Io.Dir.cwd().statFile(io, candidate, .{}) catch
        return tray_icon_path;
    return if (stat.kind == .file) candidate else tray_icon_path;
}

fn windowsPackagedTrayIconPath(executable_path: []const u8, output: []u8) ?[]const u8 {
    const executable_dir = std.fs.path.dirnameWindows(executable_path) orelse return null;
    const package_root = std.fs.path.dirnameWindows(executable_dir) orelse return null;
    return std.fmt.bufPrint(
        output,
        "{s}\\assets\\icons\\tray-icon.ico",
        .{package_root},
    ) catch null;
}

fn requireMainWindow(window_id: native_sdk.platform.WindowId) !void {
    if (window_id != main_window_id) return error.WindowIdentityMismatch;
}

fn environment(
    value: drag_region.Environment,
    controls: window_controls.State,
) bridge_api.WindowChromePlatformEnvironment {
    return .{
        .top = value.top,
        .left = value.left,
        .bottom = value.bottom,
        .right = value.right,
        .buttons_x = value.buttons_x,
        .buttons_y = value.buttons_y,
        .buttons_width = value.buttons_width,
        .buttons_height = value.buttons_height,
        .live_pointer_drag = value.live_pointer_drag,
        .renderer_controls = controls.renderer_controls,
        .maximized = controls.maximized,
    };
}

test {
    _ = drag_region;
    _ = startup_window;
    _ = window_controls;
}

test "Windows packaged tray icon resolves from the executable's package root" {
    var buffer: [256]u8 = undefined;
    const resolved = windowsPackagedTrayIconPath(
        "C:\\Users\\demo\\AppData\\Local\\Programs\\MetaWork\\bin\\metawork.exe",
        &buffer,
    ).?;
    try std.testing.expectEqualStrings(
        "C:\\Users\\demo\\AppData\\Local\\Programs\\MetaWork\\assets\\icons\\tray-icon.ico",
        resolved,
    );
}
