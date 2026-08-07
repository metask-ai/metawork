const native_sdk = @import("native_sdk");
const bridge_api = @import("metawork_bridge");
const workbench_api = @import("metawork_workbench");
const drag_region = @import("../native_sdk_compat/system_webview_drag_region.zig");
const window_controls = @import("../native_sdk_compat/system_webview_window_controls.zig");

pub const main_window_id: native_sdk.platform.WindowId = 1;
pub const tray_open_id: native_sdk.platform.TrayItemId = 1;
pub const tray_quit_id: native_sdk.platform.TrayItemId = 2;

const tray_items = [_]native_sdk.platform.TrayMenuItem{
    .{ .id = tray_open_id, .label = "Open MetaWork", .command = "metawork.tray.open" },
    .{ .separator = true },
    .{ .id = tray_quit_id, .label = "Quit MetaWork", .command = "metawork.tray.quit" },
};

pub const State = struct {
    drag_region_capability: drag_region.Capability = drag_region.Capability.init(main_window_id),
    window_controls_capability: window_controls.Capability = window_controls.Capability.init(main_window_id),
    tray_installed: bool = false,

    pub fn prepareStartup(self: *State) !void {
        try self.drag_region_capability.prepareStartup();
        try self.window_controls_capability.prepareStartup();
    }

    pub fn captureStartupWindow(self: *State) !void {
        try self.drag_region_capability.captureStartupWindow();
        try self.window_controls_capability.captureStartupWindow();
    }

    pub fn bind(self: *State, services: native_sdk.platform.PlatformServices) !void {
        try self.drag_region_capability.requirePlatform(services);
        self.drag_region_capability.bindRoot();
    }

    pub fn deinit(self: *State) void {
        self.drag_region_capability.deinit();
        self.window_controls_capability.deinit();
    }

    pub fn installTray(
        self: *State,
        runtime: *native_sdk.Runtime,
        workbench: *workbench_api.Workbench,
    ) !void {
        try runtime.createTray(.{
            .tooltip = "MetaWork",
            .items = &tray_items,
        });
        self.tray_installed = true;
        workbench.setScheduleBackgroundAvailableNoFail(true);
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

    pub fn requestExplicitQuit(
        _: *State,
        runtime: *native_sdk.Runtime,
        workbench: *workbench_api.Workbench,
    ) void {
        if (workbench.hasEnabledScheduledTasks()) {
            const result = runtime.showMessageDialog(.{
                .style = .warning,
                .title = "Quit MetaWork?",
                .message = "Scheduled tasks will pause while MetaWork is not running.",
                .informative_text = "Closing the main window keeps them running. Use Quit only when you want to stop the background host.",
                .primary_button = "Keep Running",
                .secondary_button = "Quit MetaWork",
            }) catch return;
            if (result != .secondary) return;
        }
        runtime.closeWindow(main_window_id) catch {};
    }

    pub fn notifyScheduledTask(
        _: *State,
        services: native_sdk.platform.PlatformServices,
        notification: workbench_api.ScheduleNotification,
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

    pub fn beginLivePointerDrag(
        self: *State,
        services: native_sdk.platform.PlatformServices,
        window_id: native_sdk.platform.WindowId,
        x: f64,
        y: f64,
    ) !bridge_api.WindowChromePlatformEnvironment {
        try requireMainWindow(window_id);
        return environment(
            try self.drag_region_capability.beginLivePointerDrag(services, x, y),
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
    _ = window_controls;
}
