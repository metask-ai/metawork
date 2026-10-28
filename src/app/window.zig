const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const bridge_api = @import("metawork_bridge");
const control_ports = @import("metawork_product_control_ports");

pub const main_window_id: native_sdk.platform.WindowId = 1;

pub const tray_open_id: native_sdk.platform.TrayItemId = 1;
pub const tray_quit_id: native_sdk.platform.TrayItemId = 2;

const tray_items = [_]native_sdk.platform.TrayMenuItem{
    .{ .id = tray_open_id, .label = "Open MetaWork", .command = "metawork.tray.open" },
    .{ .separator = true },
    .{ .id = tray_quit_id, .label = "Quit MetaWork", .command = "metawork.tray.quit" },
};

const schedule_open_prefix = "metawork.schedule.open.";

pub fn notificationTaskId(name: []const u8) ?u64 {
    if (!std.mem.startsWith(u8, name, schedule_open_prefix)) return null;
    const value = name[schedule_open_prefix.len..];
    if (value.len == 0 or value[0] == '0') return null;
    for (value) |byte| if (byte < '0' or byte > '9') return null;
    return std.fmt.parseInt(u64, value, 10) catch null;
}

const tray_icon_path = switch (builtin.os.tag) {
    .windows => "assets/icons/tray-icon.ico",
    else => "assets/icons/tray-icon.png",
};

pub const State = struct {
    tray_installed: bool = false,

    pub fn bind(_: *State, services: native_sdk.platform.PlatformServices) !void {
        if (services.window_chrome_fn == null) return error.SystemWebViewChromeUnavailable;
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

    pub fn requestExplicitQuit(_: *State, runtime: *native_sdk.Runtime) !void {
        try runtime.closeWindow(main_window_id);
    }

    pub fn notifyScheduledTask(
        _: *State,
        runtime: *native_sdk.Runtime,
        notification: control_ports.ScheduleNotification,
    ) bool {
        const body = switch (notification.kind) {
            .completed => "Scheduled task completed",
            .failed => "Scheduled task failed",
            .skipped => "A run was skipped because the previous run is still active",
            .needs_attention => "Scheduled task needs attention",
        };
        if (!std.unicode.utf8ValidateSlice(notification.title)) return false;
        var end = @min(notification.title.len, native_sdk.platform.max_notification_subtitle_bytes);
        while (!std.unicode.utf8ValidateSlice(notification.title[0..end])) end -= 1;
        var command_buffer: [native_sdk.platform.max_notification_action_command_bytes]u8 = undefined;
        var id_buffer: [native_sdk.platform.max_notification_id_bytes]u8 = undefined;
        const action = if (notification.task_id != 0)
            std.fmt.bufPrint(&command_buffer, schedule_open_prefix ++ "{d}", .{notification.task_id}) catch return false
        else
            "";
        const id = if (notification.task_id != 0)
            std.fmt.bufPrint(&id_buffer, "schedule-{d}-{d}-{s}", .{ notification.scheduled_task_id, notification.task_id, @tagName(notification.kind) }) catch return false
        else
            "";
        runtime.showNotification(.{
            .id = id,
            .title = "MetaWork",
            .subtitle = notification.title[0..end],
            .body = body,
            .action_label = if (action.len != 0) "View task" else "",
            .action_command = action,
        }) catch return false;
        return true;
    }

    pub fn connectWindows(
        _: *State,
        runtime: *native_sdk.Runtime,
        window_id: native_sdk.platform.WindowId,
    ) !bridge_api.WindowChromePlatformEnvironment {
        const window = try requireLiveMainWindow(runtime, window_id);
        return environment(try runtime.windowChrome(window_id), window.maximized);
    }

    pub fn refreshWindows(
        self: *State,
        runtime: *native_sdk.Runtime,
        window_id: native_sdk.platform.WindowId,
    ) !bridge_api.WindowChromePlatformEnvironment {
        return self.connectWindows(runtime, window_id);
    }

    // Existing SDK/disabled-controls path for non-Windows platforms.
    pub fn connect(
        _: *State,
        runtime: *native_sdk.Runtime,
        window_id: native_sdk.platform.WindowId,
    ) !bridge_api.WindowChromePlatformEnvironment {
        try requireMainWindow(window_id);
        return environment(try runtime.windowChrome(window_id), false);
    }

    pub fn refresh(
        self: *State,
        runtime: *native_sdk.Runtime,
        window_id: native_sdk.platform.WindowId,
    ) !bridge_api.WindowChromePlatformEnvironment {
        return self.connect(runtime, window_id);
    }

    pub fn control(
        _: *State,
        runtime: *native_sdk.Runtime,
        window_id: native_sdk.platform.WindowId,
        action: bridge_api.WindowChromeControlAction,
    ) !void {
        try requireMainWindow(window_id);
        if (comptime builtin.os.tag == .windows) {
            try requireUnhiddenMainWindow(runtime, window_id);
            switch (action) {
                .minimize => try runtime.minimizeWindow(window_id),
                .toggle_maximize => if ((try requireLiveMainWindow(runtime, window_id)).maximized)
                    try runtime.unmaximizeWindow(window_id)
                else
                    try runtime.maximizeWindow(window_id),
                .close => try runtime.requestCloseWindow(window_id),
            }
            return;
        }
        switch (action) {
            .minimize => try runtime.minimizeWindow(main_window_id),
            .toggle_maximize => return error.UnsupportedSystemWebViewMaximize,
            .close => return error.UnsupportedSystemWebViewUserClose,
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
    value: native_sdk.platform.WindowChrome,
    maximized: bool,
) bridge_api.WindowChromePlatformEnvironment {
    return .{
        .top = if (builtin.os.tag == .windows) 40 else value.insets.top,
        .left = value.insets.left,
        .bottom = value.insets.bottom,
        .right = value.insets.right,
        .buttons_x = value.buttons.x,
        .buttons_y = value.buttons.y,
        .buttons_width = value.buttons.width,
        .buttons_height = value.buttons.height,
        .renderer_controls = builtin.os.tag == .windows,
        .maximized = maximized,
    };
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
    try window.control(&harness.runtime, 1, .toggle_maximize);
    try std.testing.expect(harness.null_platform.windows[0].maximized);
    try std.testing.expect(harness.null_platform.takeQueuedCloseRequest() == null);

    try window.requestExplicitQuit(&harness.runtime);
    for (actions) |action|
        try std.testing.expectError(error.WindowUnavailable, window.control(&harness.runtime, 1, action));
}

test "Windows window controls follow SDK frame state without a native controls binding" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    _ = try harness.runtime.createWindow(.{ .id = 1, .label = "main", .source = .html("") });
    var window: State = .{};
    const initial = try window.connectWindows(&harness.runtime, 1);
    try std.testing.expect(initial.renderer_controls);
    try std.testing.expect(!initial.maximized);
    var context: u8 = 0;
    const app: native_sdk.App = .{ .context = &context, .name = "window-controls-test" };

    try window.control(&harness.runtime, 1, .toggle_maximize);
    // Only the host frame event commits maximized state to the SDK Runtime.
    try std.testing.expect(!(try window.refreshWindows(&harness.runtime, 1)).maximized);
    try harness.runtime.dispatchPlatformEvent(app, harness.null_platform.windowFrameEvent(1).?);
    try std.testing.expect((try window.refreshWindows(&harness.runtime, 1)).maximized);
    try window.control(&harness.runtime, 1, .toggle_maximize);
    try std.testing.expect(!harness.null_platform.windows[0].maximized);
    try harness.runtime.dispatchPlatformEvent(app, harness.null_platform.windowFrameEvent(1).?);
    try std.testing.expect(!(try window.refreshWindows(&harness.runtime, 1)).maximized);

    // A native double-click or system command uses that same observed state.
    var state = harness.null_platform.windowFrameEvent(1).?.window_frame_changed;
    state.maximized = true;
    try harness.runtime.dispatchPlatformEvent(app, .{ .window_frame_changed = state });
    try std.testing.expect((try window.refreshWindows(&harness.runtime, 1)).maximized);
    try harness.runtime.hideWindow(1);
    _ = try window.refreshWindows(&harness.runtime, 1);
    try std.testing.expectError(error.WindowIdentityMismatch, window.connectWindows(&harness.runtime, 2));
    try window.requestExplicitQuit(&harness.runtime);
    try std.testing.expectError(error.WindowUnavailable, window.refreshWindows(&harness.runtime, 1));
}

test "Windows user close preserves SDK hide policy while explicit quit closes" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    _ = try harness.runtime.createWindow(.{ .id = 1, .label = "main", .source = .html(""), .close_policy = .hide });
    var context: u8 = 0;
    const app: native_sdk.App = .{ .context = &context, .name = "window-controls-test" };
    var window: State = .{};

    try std.testing.expectError(error.WindowIdentityMismatch, window.control(&harness.runtime, 2, .close));
    try std.testing.expect(harness.null_platform.takeQueuedCloseRequest() == null);
    try window.control(&harness.runtime, 1, .close);
    try requireUnhiddenMainWindow(&harness.runtime, 1);
    try harness.runtime.dispatchPlatformEvent(app, harness.null_platform.takeQueuedCloseRequest().?);
    try std.testing.expect((try requireLiveMainWindow(&harness.runtime, 1)).hidden);
    try std.testing.expectError(error.WindowHidden, window.control(&harness.runtime, 1, .close));
    try std.testing.expect(harness.null_platform.takeQueuedCloseRequest() == null);

    window.showMainWindow(&harness.runtime);
    try requireUnhiddenMainWindow(&harness.runtime, 1);
    try window.requestExplicitQuit(&harness.runtime);
    try std.testing.expectError(error.WindowUnavailable, requireLiveMainWindow(&harness.runtime, 1));
}

test "SDK consumption notification bounds presentation without changing Product title" {
    const Spy = struct {
        var calls: usize = 0;
        var seen: [native_sdk.platform.max_notification_subtitle_bytes]u8 = undefined;
        var len: usize = 0;
        var fail = false;
        var task_id: ?u64 = null;
        fn notify(_: ?*anyopaque, options: native_sdk.platform.NotificationOptions) anyerror!void {
            calls += 1;
            try std.testing.expect(std.unicode.utf8ValidateSlice(options.subtitle));
            try std.testing.expect(options.subtitle.len <= seen.len);
            @memcpy(seen[0..options.subtitle.len], options.subtitle);
            len = options.subtitle.len;
            task_id = notificationTaskId(options.action_command);
            try std.testing.expectEqual(options.action_command.len == 0, options.action_label.len == 0);
            if (task_id != null) try std.testing.expect(options.id.len > 0);
            if (fail) return error.InjectedNotificationFailure;
        }
    };
    Spy.calls = 0;
    Spy.fail = false;
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.runtime.options.platform.services.show_notification_fn = Spy.notify;
    var window: State = .{};
    const long = "a" ** 127 ++ "界" ++ "b" ** 50;
    const notification: control_ports.ScheduleNotification = .{ .scheduled_task_id = 1, .title = long, .kind = .completed };
    // Runtime validation would reject the original, unbounded subtitle.
    try std.testing.expectError(error.NotificationFieldTooLarge, harness.runtime.showNotification(.{ .title = "MetaWork", .subtitle = long }));
    try std.testing.expectEqual(@as(usize, 0), Spy.calls);
    try std.testing.expect(window.notifyScheduledTask(&harness.runtime, notification));
    try std.testing.expectEqual(@as(usize, 127), Spy.len);
    try std.testing.expectEqualStrings("a" ** 127, Spy.seen[0..Spy.len]);
    try std.testing.expectEqualStrings(long, notification.title);
    try std.testing.expect(window.notifyScheduledTask(&harness.runtime, .{ .scheduled_task_id = 1, .title = "界", .kind = .failed }));
    try std.testing.expectEqualStrings("界", Spy.seen[0..Spy.len]);
    try std.testing.expectEqual(@as(?u64, null), Spy.task_id);
    try std.testing.expect(window.notifyScheduledTask(&harness.runtime, .{ .scheduled_task_id = 1, .task_id = std.math.maxInt(u64), .title = "Task result", .kind = .completed }));
    try std.testing.expectEqual(@as(?u64, std.math.maxInt(u64)), Spy.task_id);
    Spy.fail = true;
    try std.testing.expect(!window.notifyScheduledTask(&harness.runtime, notification));
    try std.testing.expectEqual(@as(usize, 4), Spy.calls);
}

test "notification command admits only the exact real Task identity syntax" {
    try std.testing.expectEqual(@as(?u64, 42), notificationTaskId("metawork.schedule.open.42"));
    for ([_][]const u8{ "metawork.schedule.open.0", "metawork.schedule.open.01", "metawork.schedule.open.-1", "metawork.schedule.open.1.run", "metawork.schedule.open.18446744073709551616", "metawork.tray.open", "metawork.schedule.open." }) |value|
        try std.testing.expectEqual(@as(?u64, null), notificationTaskId(value));
}

test "SDK consumption chrome queries enter Runtime recording and replay divergence" {
    const Spy = struct {
        var calls: usize = 0;
        fn chrome(_: ?*anyopaque, _: native_sdk.platform.WindowId) native_sdk.platform.WindowChrome {
            calls += 1;
            return .{ .insets = .{ .left = 17 } };
        }
        fn write(_: *anyopaque, _: []const u8) anyerror!void {}
    };
    Spy.calls = 0;
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.runtime.options.platform.services.window_chrome_fn = Spy.chrome;
    _ = try harness.runtime.createWindow(.{ .id = 1, .label = "main", .source = .html("") });
    var window: State = .{};
    const recorder = try std.testing.allocator.create(native_sdk.runtime.SessionRecorder);
    defer std.testing.allocator.destroy(recorder);
    var context: u8 = 0;
    recorder.* = .{ .sink = .{ .context = &context, .write_fn = Spy.write } };
    recorder.begin(native_sdk.runtime.sessionHeaderNow("null", "sdk-chrome-test", 100, 100));
    harness.runtime.options.session_recorder = recorder;
    defer harness.runtime.options.session_recorder = null;
    recorder.stageEvent(.app_start);
    const live = try window.connectWindows(&harness.runtime, 1);
    recorder.commitEvent();
    try std.testing.expectEqual(@as(f32, 17), live.left);
    try std.testing.expectEqual(@as(usize, 1), Spy.calls);
    try std.testing.expectEqual(@as(u64, 1), recorder.window_chrome_count);
    try std.testing.expect(!recorder.failed);
    harness.runtime.options.session_recorder = null;
    harness.runtime.replay_window_chrome_active = true;
    harness.runtime.replay_window_chrome[0] = .{ .window_id = 1, .chrome = .{ .insets = .{ .left = 29 } } };
    harness.runtime.replay_window_chrome_count = 1;
    const replay = try window.refreshWindows(&harness.runtime, 1);
    try std.testing.expectEqual(@as(f32, 29), replay.left);
    try std.testing.expectEqual(@as(usize, 1), Spy.calls);
    try std.testing.expectError(error.ReplayChromeDivergence, window.refreshWindows(&harness.runtime, 1));
    try std.testing.expect(harness.runtime.replay_window_chrome_failed);
    try std.testing.expectError(error.WindowIdentityMismatch, window.connectWindows(&harness.runtime, 2));
    // The non-Windows path must also propagate Runtime errors.
    try std.testing.expectError(error.ReplayChromeDivergence, window.refresh(&harness.runtime, 1));
}
