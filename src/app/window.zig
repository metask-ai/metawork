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

/// A-stage composition only. The ordinary product State never creates this.
/// The probe keeps this storage alive until process exit even if teardown fails.
pub const InputPrototype = struct {
    capture: startup_window.Capture = .{},
    controls: window_controls.Capability = window_controls.Capability.init(main_window_id),
    top_resize: resize.Capability = .{},
    input: drag_region.InputPrototype = .{},
    runtime: ?*native_sdk.Runtime = null,

    pub fn prepare(self: *InputPrototype) !void {
        if (builtin.os.tag != .windows) return error.WindowsOnlyProbe;
        try self.controls.prepareStartup();
        try self.capture.prepare();
    }

    pub fn start(self: *InputPrototype, runtime: *native_sdk.Runtime) !void {
        self.runtime = runtime;
        const binding = try self.capture.take(main_window_id);
        try self.controls.captureStartupWindow(binding);
        try self.top_resize.attach(binding, self, resizePress);
        try self.input.attach(binding, self, refresh, toggle);
        try refresh(self);
    }

    fn refresh(data: *anyopaque) !void {
        const self: *InputPrototype = @ptrCast(@alignCast(data));
        const band = try self.top_resize.inputBand();
        try self.input.syncFixed(band.anchor, band.width, band.height);
    }

    fn toggle(data: *anyopaque) !void {
        const self: *InputPrototype = @ptrCast(@alignCast(data));
        try requireUnhiddenMainWindow(self.runtime orelse return error.RuntimeUnavailable, main_window_id);
        const maximized = try self.controls.isMaximized();
        try self.controls.setMaximized(!maximized);
        std.debug.print("DRAG_PROBE toggle maximized={}\n", .{!maximized});
    }

    fn resizePress(_: *anyopaque) void {
        std.debug.print("DRAG_PROBE resize-press (no gesture reset)\n", .{});
    }

    pub fn deinit(self: *InputPrototype) !void {
        try self.input.deinit();
        self.top_resize.deinit();
        self.controls.deinit();
        self.capture.deinit();
        self.runtime = null;
    }
};
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

    pub fn connectWindows(
        self: *State,
        runtime: *native_sdk.Runtime,
        services: native_sdk.platform.PlatformServices,
        window_id: native_sdk.platform.WindowId,
    ) !bridge_api.WindowChromePlatformEnvironment {
        _ = try requireLiveMainWindow(runtime, window_id);
        const controls = try self.window_controls_capability.windowsState();
        return environment(try self.drag_region_capability.connect(services), controls);
    }

    pub fn refreshWindows(
        self: *State,
        runtime: *native_sdk.Runtime,
        services: native_sdk.platform.PlatformServices,
        window_id: native_sdk.platform.WindowId,
    ) !bridge_api.WindowChromePlatformEnvironment {
        _ = try requireLiveMainWindow(runtime, window_id);
        return environment(
            self.drag_region_capability.current(services),
            try self.window_controls_capability.windowsState(),
        );
    }

    pub fn handleWindowsPointer(
        self: *State,
        runtime: ?*native_sdk.Runtime,
        services: ?native_sdk.platform.PlatformServices,
        window_id: native_sdk.platform.WindowId,
        pointer: bridge_api.WindowChromePointer,
    ) !void {
        try requireMainWindow(window_id);
        const down = switch (pointer) {
            .reset => {
                self.drag_region_capability.resetPointerSequence();
                return;
            },
            .down => |down| down,
        };
        // Only a valid document's down reaches this point. All newly fallible
        // prerequisites must interrupt its sequence, including a missing Runtime.
        errdefer self.drag_region_capability.resetPointerSequence();
        const runtime_value = runtime orelse return error.RuntimeUnavailable;
        try requireUnhiddenMainWindow(runtime_value, window_id);
        _ = try self.window_controls_capability.isMaximized();
        const outcome = try self.drag_region_capability.handlePointerDown(
            services orelse return error.RuntimeUnavailable,
            down.x,
            down.y,
        );
        if (outcome == .toggle_maximize)
            try self.toggleMainWindowMaximized(runtime_value, window_id);
    }

    fn toggleMainWindowMaximized(
        self: *State,
        runtime: *native_sdk.Runtime,
        window_id: native_sdk.platform.WindowId,
    ) !void {
        try requireUnhiddenMainWindow(runtime, window_id);
        const maximized = try self.window_controls_capability.isMaximized();
        try self.window_controls_capability.setMaximized(!maximized);
    }

    // Existing SDK/disabled-controls path for non-Windows platforms.
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

    pub fn refresh(
        self: *State,
        services: native_sdk.platform.PlatformServices,
        window_id: native_sdk.platform.WindowId,
    ) !bridge_api.WindowChromePlatformEnvironment {
        try requireMainWindow(window_id);
        return environment(self.drag_region_capability.current(services), self.window_controls_capability.state());
    }

    pub fn handlePointer(
        self: *State,
        services: native_sdk.platform.PlatformServices,
        window_id: native_sdk.platform.WindowId,
        pointer: bridge_api.WindowChromePointer,
    ) !void {
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
    }

    pub fn disconnect(self: *State, window_id: native_sdk.platform.WindowId) !void {
        try requireMainWindow(window_id);
        self.drag_region_capability.disconnect();
    }

    pub fn control(
        self: *State,
        runtime: *native_sdk.Runtime,
        window_id: native_sdk.platform.WindowId,
        action: bridge_api.WindowChromeControlAction,
    ) !void {
        try requireMainWindow(window_id);
        if (comptime builtin.os.tag == .windows) {
            switch (action) {
                .minimize => {
                    try requireUnhiddenMainWindow(runtime, window_id);
                    try runtime.minimizeWindow(window_id);
                },
                .toggle_maximize => try self.toggleMainWindowMaximized(runtime, window_id),
                .close => {
                    try requireUnhiddenMainWindow(runtime, window_id);
                    try self.window_controls_capability.requestUserClose();
                },
            }
            return;
        }
        switch (action) {
            .minimize => try runtime.minimizeWindow(main_window_id),
            .toggle_maximize => try self.window_controls_capability.toggleMaximize(),
            .close => try self.window_controls_capability.userClose(),
        }
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

fn requireLiveMainWindow(
    runtime: *const native_sdk.Runtime,
    window_id: native_sdk.platform.WindowId,
) !native_sdk.platform.WindowInfo {
    try requireMainWindow(window_id);
    var windows: [native_sdk.platform.max_windows]native_sdk.platform.WindowInfo = undefined;
    for (runtime.listWindows(&windows)) |window| {
        if (window.id != window_id) continue;
        if (!window.open) return error.WindowUnavailable;
        return window;
    }
    return error.WindowUnavailable;
}

fn requireUnhiddenMainWindow(
    runtime: *const native_sdk.Runtime,
    window_id: native_sdk.platform.WindowId,
) !void {
    if ((try requireLiveMainWindow(runtime, window_id)).hidden)
        return error.WindowHidden;
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
    _ = resize;
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

test "Windows window controls consume current SDK window facts after platform events" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    var context: u8 = 0;
    const app: native_sdk.App = .{ .context = &context, .name = "window-controls-test" };
    _ = try harness.runtime.createWindow(.{
        .id = 2,
        .label = "other",
        .source = .html(""),
    });
    const main = try harness.runtime.createWindow(.{
        .id = main_window_id,
        .label = "main",
        .source = .html(""),
    });
    var windows: [native_sdk.platform.max_windows]native_sdk.platform.WindowInfo = undefined;
    const initial = harness.runtime.listWindows(&windows);
    try std.testing.expectEqual(@as(usize, 2), initial.len);
    try std.testing.expectEqual(main_window_id, initial[1].id);
    try std.testing.expect(initial[1].open and !initial[1].hidden);
    try requireUnhiddenMainWindow(&harness.runtime, main_window_id);
    try std.testing.expectError(error.WindowIdentityMismatch, requireLiveMainWindow(&harness.runtime, 2));

    var state = main.state();
    state.hidden = true;
    try harness.runtime.dispatchPlatformEvent(app, .{ .window_frame_changed = state });
    const hidden = harness.runtime.listWindows(&windows);
    try std.testing.expect(hidden[1].open and hidden[1].hidden);
    try std.testing.expect((try requireLiveMainWindow(&harness.runtime, main_window_id)).hidden);
    try std.testing.expectError(error.WindowHidden, requireUnhiddenMainWindow(&harness.runtime, main_window_id));

    state.hidden = false;
    try harness.runtime.dispatchPlatformEvent(app, .{ .window_frame_changed = state });
    const shown = harness.runtime.listWindows(&windows);
    try std.testing.expect(shown[1].open and !shown[1].hidden);
    try requireUnhiddenMainWindow(&harness.runtime, main_window_id);

    state.open = false;
    try harness.runtime.dispatchPlatformEvent(app, .{ .window_frame_changed = state });
    const closed = harness.runtime.listWindows(&windows);
    try std.testing.expect(!closed[1].open);
    try std.testing.expect(closed[0].open);
    try std.testing.expectError(error.WindowUnavailable, requireLiveMainWindow(&harness.runtime, main_window_id));
}

test "Windows window actions reject missing closed and hidden SDK windows before effects" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    var window: State = .{};
    defer window.deinit();
    const actions = [_]bridge_api.WindowChromeControlAction{ .minimize, .toggle_maximize, .close };
    for (actions) |action|
        try std.testing.expectError(error.WindowUnavailable, window.control(&harness.runtime, 1, action));
    _ = try harness.runtime.createWindow(.{ .id = 1, .label = "main", .source = .html("") });
    try harness.runtime.hideWindow(1);
    for (actions) |action|
        try std.testing.expectError(error.WindowHidden, window.control(&harness.runtime, 1, action));
    try std.testing.expectEqual(@as(u32, 0), harness.null_platform.minimizeCountForWindow(1));

    // Tray reopen remains an SDK operation and removes the admission barrier.
    window.showMainWindow(&harness.runtime);
    try window.control(&harness.runtime, 1, .minimize);
    try std.testing.expectEqual(@as(u32, 1), harness.null_platform.minimizeCountForWindow(1));
    try requireUnhiddenMainWindow(&harness.runtime, 1);
    try std.testing.expectError(error.WindowUnavailable, window.control(&harness.runtime, 1, .toggle_maximize));
    try std.testing.expectError(error.WindowUnavailable, window.control(&harness.runtime, 1, .close));

    try window.requestExplicitQuit(&harness.runtime);
    for (actions) |action|
        try std.testing.expectError(error.WindowUnavailable, window.control(&harness.runtime, 1, action));
}

test "Windows window query failure precedes attachment and preserves refresh session" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    _ = try harness.runtime.createWindow(.{ .id = 1, .label = "main", .source = .html("") });
    var window: State = .{};
    defer window.deinit();
    window.drag_region_capability.platform_ready = true;
    const services = harness.runtime.options.platform.services;
    try std.testing.expectError(error.WindowUnavailable, window.connectWindows(&harness.runtime, services, 1));
    try std.testing.expect(!window.drag_region_capability.document_attached);
    window.drag_region_capability.document_attached = true;
    window.drag_region_capability.platform.first_press = .{
        .tick_ms = 100,
        .screen_point = .{ .x = 400, .y = 20 },
        .window_rect = .{ .left = 100, .top = 100, .right = 900, .bottom = 700 },
    };
    const first = window.drag_region_capability.platform.first_press;
    try harness.runtime.hideWindow(1);
    // Hidden is allowed to query; an absent binding still fails explicitly.
    try std.testing.expectError(error.WindowUnavailable, window.refreshWindows(&harness.runtime, services, 1));
    try std.testing.expect(window.drag_region_capability.document_attached);
    try std.testing.expect(std.meta.eql(first, window.drag_region_capability.platform.first_press));
}
