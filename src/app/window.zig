const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const bridge_api = @import("metawork_bridge");
const control_ports = @import("metawork_product_control_ports");
const notification_text = bridge_api.notification_text;
const app_manifest = @import("app_manifest_zon");

pub const main_window_id: native_sdk.platform.WindowId = 1;

pub const tray_open_id: native_sdk.platform.TrayItemId = 1;
pub const tray_quit_id: native_sdk.platform.TrayItemId = 2;

const tray_items = [_]native_sdk.platform.TrayMenuItem{
    .{ .id = tray_open_id, .label = "Open MetaWork", .command = "metawork.tray.open" },
    .{ .separator = true },
    .{ .id = tray_quit_id, .label = "Quit MetaWork", .command = "metawork.tray.quit" },
};

/// The one notification command that opens a Task. The wire name dates from
/// scheduled tasks, which introduced it; every Task-opening notification now
/// carries it, bound to both the action button and the banner itself, and
/// `src/app.zig` routes it through `notificationTaskId` below.
const open_task_prefix = "metawork.schedule.open.";

pub fn notificationTaskId(name: []const u8) ?u64 {
    if (!std.mem.startsWith(u8, name, open_task_prefix)) return null;
    const value = name[open_task_prefix.len..];
    if (value.len == 0 or value[0] == '0') return null;
    for (value) |byte| if (byte < '0' or byte > '9') return null;
    return std.fmt.parseInt(u64, value, 10) catch null;
}

const tray_icon_path = switch (builtin.os.tag) {
    .windows => "assets/icons/tray-icon.ico",
    else => "assets/icons/tray-icon.png",
};

const window_icon_path = switch (builtin.os.tag) {
    .windows => "assets/icons/app-icon.ico",
    else => "assets/icons/app-icon.png",
};

/// What a Task notification says and what a click on it opens. Everything the
/// Host decides about one banner, so `showTaskNotification` is the single
/// place that talks to the SDK.
const TaskNotification = struct {
    /// Replacement identity. Reissuing it replaces the earlier banner instead
    /// of stacking another one; empty means no replacement.
    id: []const u8,
    /// Which catalog string the body takes.
    slot: notification_text.Slot,
    /// The Task title, already localized by Product, shown as the subtitle.
    title: []const u8,
    /// Zero when this notification cannot open a Task.
    task_id: u64,
};

pub const State = struct {
    tray_installed: bool = false,
    /// The Renderer's localized notification strings, absent until it
    /// registers them. `showTaskNotification` states what absence means.
    notification_text: ?notification_text.Table = null,

    /// Main thread, from the Renderer Bridge. Replaces the whole table, so a
    /// language change takes effect on the next notification.
    pub fn setNotificationText(self: *State, table: notification_text.Table) void {
        self.notification_text = table;
    }

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
            .icon_path = resolvePackagedIconPath(io, tray_icon_path, &icon_path_buffer),
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
        self: *const State,
        runtime: *native_sdk.Runtime,
        notification: control_ports.ScheduleNotification,
    ) bool {
        var id_buffer: [native_sdk.platform.max_notification_id_bytes]u8 = undefined;
        const id = if (notification.task_id != 0)
            std.fmt.bufPrint(&id_buffer, "schedule-{d}-{d}-{s}", .{ notification.scheduled_task_id, notification.task_id, @tagName(notification.kind) }) catch return false
        else
            "";
        return self.showTaskNotification(runtime, .{
            .id = id,
            // Exhaustive, so a new scheduled-task notification kind cannot
            // reach the banner without a catalog slot of its own.
            .slot = switch (notification.kind) {
                .completed => .schedule_completed,
                .failed => .schedule_failed,
                .skipped => .schedule_skipped,
                .needs_attention => .schedule_needs_attention,
            },
            .title = notification.title,
            .task_id = notification.task_id,
        });
    }

    /// A Run reached a point the user asked to be told about. Only raised when
    /// the application is not the active one: a banner over the window the
    /// user is already reading says nothing the Task list does not.
    pub fn notifyRunAttention(
        self: *const State,
        runtime: *native_sdk.Runtime,
        notification: control_ports.RunNotification,
    ) bool {
        // The SDK keeps this register for us, stamped in its dispatch loop
        // from the platform's `.app_activated`/`.app_deactivated` events, so
        // it replays deterministically and there is no second copy of the
        // fact to drift. It is APPLICATION activation, not window focus:
        // close enough for a single-window application, and it is what the
        // Windows and macOS hosts actually report.
        if (runtime.app_active) return false;
        var id_buffer: [native_sdk.platform.max_notification_id_bytes]u8 = undefined;
        const id = std.fmt.bufPrint(&id_buffer, "run-{d}-{d}-{s}", .{
            notification.task_id,
            notification.run_id,
            @tagName(notification.kind),
        }) catch return false;
        return self.showTaskNotification(runtime, .{
            .id = id,
            .slot = switch (notification.kind) {
                .completed => .run_completed,
                .failed => .run_failed,
                .needs_approval => .run_needs_approval,
            },
            .title = notification.title,
            .task_id = notification.task_id,
        });
    }

    /// The only place the Host hands a notification to the SDK.
    ///
    /// The window title and the Task title are the only strings the Host owns
    /// that are already in the user's language: `display_name` is the product
    /// name and Product localized the Task title. Body and action label exist
    /// only in the Renderer's catalog, so with no registered table this sends
    /// the banner WITHOUT them rather than falling back to English. That is a
    /// deliberate trade: a half-English banner beside a Chinese Task title is
    /// the defect this layer exists to remove, and an English fallback would
    /// keep that defect alive on the one path nobody looks at.
    fn showTaskNotification(
        self: *const State,
        runtime: *native_sdk.Runtime,
        notification: TaskNotification,
    ) bool {
        if (!std.unicode.utf8ValidateSlice(notification.title)) return false;
        var end = @min(notification.title.len, native_sdk.platform.max_notification_subtitle_bytes);
        while (!std.unicode.utf8ValidateSlice(notification.title[0..end])) end -= 1;
        const body = if (self.notification_text) |*table| table.get(notification.slot) else "";
        const label = if (self.notification_text) |*table| table.get(.open_task_action) else "";
        var command_buffer: [native_sdk.platform.max_notification_action_command_bytes]u8 = undefined;
        // The SDK pairs label and command: an unlabelled button cannot be
        // presented, so without a catalog there is no action to route either.
        const command = if (notification.task_id != 0 and label.len != 0)
            std.fmt.bufPrint(&command_buffer, open_task_prefix ++ "{d}", .{notification.task_id}) catch return false
        else
            "";
        runtime.showNotification(.{
            .id = notification.id,
            .title = app_manifest.display_name,
            .subtitle = notification.title[0..end],
            .body = body,
            .action_label = if (command.len != 0) label else "",
            .action_command = command,
            // Clicking the banner itself opens the Task too, not just the
            // button. The SDK dispatches at most one of the two.
            .activation_command = command,
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

/// The main window's icon: the Windows taskbar button, Alt+Tab, the window
/// thumbnail and the caption, and the macOS dev-run Dock icon.
pub fn resolveWindowIconPath(io: std.Io, output: []u8) []const u8 {
    return resolvePackagedIconPath(io, window_icon_path, output);
}

/// A Windows packaged run resolves a relative icon path against the packaged
/// `resources` directory and then the working directory, and the icons live in
/// neither, so only an absolute path reaches them whatever directory the run
/// starts from. The packaged icon tree sits next to the executable's own `bin`
/// directory; a development run keeps the relative path.
fn resolvePackagedIconPath(io: std.Io, relative_path: []const u8, output: []u8) []const u8 {
    if (comptime builtin.os.tag != .windows) return relative_path;

    var executable_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const executable_len = std.process.executablePath(io, &executable_buffer) catch
        return relative_path;
    const candidate = windowsPackagedIconPath(
        executable_buffer[0..executable_len],
        relative_path,
        output,
    ) orelse return relative_path;
    const stat = std.Io.Dir.cwd().statFile(io, candidate, .{}) catch
        return relative_path;
    return if (stat.kind == .file) candidate else relative_path;
}

fn windowsPackagedIconPath(
    executable_path: []const u8,
    relative_path: []const u8,
    output: []u8,
) ?[]const u8 {
    const executable_dir = std.fs.path.dirnameWindows(executable_path) orelse return null;
    const package_root = std.fs.path.dirnameWindows(executable_dir) orelse return null;
    const packaged_path = std.fmt.bufPrint(
        output,
        "{s}\\{s}",
        .{ package_root, relative_path },
    ) catch return null;
    std.mem.replaceScalar(u8, packaged_path[package_root.len..], '/', '\\');
    return packaged_path;
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

test "Windows packaged icons resolve from the executable's package root" {
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "C:\\Users\\demo\\AppData\\Local\\Programs\\MetaWork\\assets\\icons\\tray-icon.ico",
        windowsPackagedIconPath(
            "C:\\Users\\demo\\AppData\\Local\\Programs\\MetaWork\\bin\\metawork.exe",
            "assets/icons/tray-icon.ico",
            &buffer,
        ).?,
    );
    try std.testing.expectEqualStrings(
        "C:\\Users\\demo\\AppData\\Local\\Programs\\MetaWork\\assets\\icons\\app-icon.ico",
        windowsPackagedIconPath(
            "C:\\Users\\demo\\AppData\\Local\\Programs\\MetaWork\\bin\\metawork.exe",
            "assets/icons/app-icon.ico",
            &buffer,
        ).?,
    );
    if (builtin.os.tag == .windows) {
        try std.testing.expectEqualStrings("assets/icons/app-icon.ico", window_icon_path);
        try std.testing.expectEqualStrings("assets/icons/tray-icon.ico", tray_icon_path);
    }
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
    window.setNotificationText(testNotificationText());
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

/// A stand-in for a Renderer registration, in a language the Host has no copy
/// of, so a test that sees these words can only have read the table.
fn testNotificationText() notification_text.Table {
    return notification_text.decode(.{
        .scheduleCompleted = "定时任务已完成",
        .scheduleFailed = "定时任务失败",
        .scheduleSkipped = "本次运行已跳过",
        .scheduleNeedsAttention = "定时任务需要处理",
        .runCompleted = "任务已完成",
        .runFailed = "任务失败",
        .runNeedsApproval = "任务正在等待你的确认",
        .openTaskAction = "查看任务",
    }).?;
}

/// Records one notification whole, so a test can read the exact banner.
const NotificationSpy = struct {
    var calls: usize = 0;
    var title: [native_sdk.platform.max_notification_title_bytes]u8 = undefined;
    var title_len: usize = 0;
    var subtitle: [native_sdk.platform.max_notification_subtitle_bytes]u8 = undefined;
    var subtitle_len: usize = 0;
    var body: [notification_text.max_slot_bytes]u8 = undefined;
    var body_len: usize = 0;
    var label: [native_sdk.platform.max_notification_action_label_bytes]u8 = undefined;
    var label_len: usize = 0;
    var id: [native_sdk.platform.max_notification_id_bytes]u8 = undefined;
    var id_len: usize = 0;
    var action_command: [native_sdk.platform.max_notification_action_command_bytes]u8 = undefined;
    var action_command_len: usize = 0;
    var activation_command: [native_sdk.platform.max_notification_activation_command_bytes]u8 = undefined;
    var activation_command_len: usize = 0;

    fn reset() void {
        calls = 0;
        title_len = 0;
        subtitle_len = 0;
        body_len = 0;
        label_len = 0;
        id_len = 0;
        action_command_len = 0;
        activation_command_len = 0;
    }

    fn notify(_: ?*anyopaque, options: native_sdk.platform.NotificationOptions) anyerror!void {
        calls += 1;
        title_len = copy(&title, options.title);
        subtitle_len = copy(&subtitle, options.subtitle);
        body_len = copy(&body, options.body);
        label_len = copy(&label, options.action_label);
        id_len = copy(&id, options.id);
        action_command_len = copy(&action_command, options.action_command);
        activation_command_len = copy(&activation_command, options.activation_command);
    }

    fn copy(destination: []u8, source: []const u8) usize {
        @memcpy(destination[0..source.len], source);
        return source.len;
    }

    fn install(harness: anytype) void {
        reset();
        harness.runtime.options.platform.services.show_notification_fn = notify;
    }

    fn seenTitle() []const u8 {
        return title[0..title_len];
    }
    fn seenSubtitle() []const u8 {
        return subtitle[0..subtitle_len];
    }
    fn seenBody() []const u8 {
        return body[0..body_len];
    }
    fn seenLabel() []const u8 {
        return label[0..label_len];
    }
    fn seenId() []const u8 {
        return id[0..id_len];
    }
    fn seenActionTaskId() ?u64 {
        return notificationTaskId(action_command[0..action_command_len]);
    }
    fn seenActivationTaskId() ?u64 {
        return notificationTaskId(activation_command[0..activation_command_len]);
    }
};

test "a registered table writes the whole banner in the Renderer's language" {
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    NotificationSpy.install(harness);
    var window: State = .{};
    window.setNotificationText(testNotificationText());

    try std.testing.expect(window.notifyScheduledTask(&harness.runtime, .{
        .scheduled_task_id = 7,
        .task_id = 42,
        .title = "每日简报",
        .kind = .completed,
    }));
    // The window title is the manifest's display name, not a literal repeated
    // at the call site.
    try std.testing.expectEqualStrings(app_manifest.display_name, NotificationSpy.seenTitle());
    // Body, button and Task title are all in one language.
    try std.testing.expectEqualStrings("每日简报", NotificationSpy.seenSubtitle());
    try std.testing.expectEqualStrings("定时任务已完成", NotificationSpy.seenBody());
    try std.testing.expectEqualStrings("查看任务", NotificationSpy.seenLabel());
    try std.testing.expectEqualStrings("schedule-7-42-completed", NotificationSpy.seenId());
    // The button and the banner itself both open the same Task.
    try std.testing.expectEqual(@as(?u64, 42), NotificationSpy.seenActionTaskId());
    try std.testing.expectEqual(@as(?u64, 42), NotificationSpy.seenActivationTaskId());

    // Every scheduled-task kind takes a slot of its own; no two share a string.
    var seen: [4][]const u8 = undefined;
    var filled: usize = 0;
    defer for (seen[0..filled]) |value| std.testing.allocator.free(value);
    for ([_]control_ports.ScheduleNotificationKind{ .completed, .failed, .skipped, .needs_attention }) |kind| {
        try std.testing.expect(window.notifyScheduledTask(
            &harness.runtime,
            .{ .scheduled_task_id = 1, .task_id = 2, .title = "t", .kind = kind },
        ));
        seen[filled] = try std.testing.allocator.dupe(u8, NotificationSpy.seenBody());
        filled += 1;
    }
    for (seen[0..filled], 0..) |left, index| for (seen[index + 1 .. filled]) |right|
        try std.testing.expect(!std.mem.eql(u8, left, right));
}

test "re-registering the table changes the next banner's language" {
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    NotificationSpy.install(harness);
    var window: State = .{};
    window.setNotificationText(testNotificationText());
    const failed: control_ports.ScheduleNotification = .{
        .scheduled_task_id = 1,
        .task_id = 2,
        .title = "Daily digest",
        .kind = .failed,
    };
    try std.testing.expect(window.notifyScheduledTask(&harness.runtime, failed));
    try std.testing.expectEqualStrings("定时任务失败", NotificationSpy.seenBody());

    window.setNotificationText(notification_text.decode(.{
        .scheduleCompleted = "Scheduled task completed",
        .scheduleFailed = "Scheduled task failed",
        .scheduleSkipped = "A run was skipped",
        .scheduleNeedsAttention = "Scheduled task needs attention",
        .runCompleted = "Task finished",
        .runFailed = "Task failed",
        .runNeedsApproval = "Task is waiting for your approval",
        .openTaskAction = "View task",
    }).?);
    try std.testing.expect(window.notifyScheduledTask(&harness.runtime, failed));
    try std.testing.expectEqualStrings("Scheduled task failed", NotificationSpy.seenBody());
    try std.testing.expectEqualStrings("View task", NotificationSpy.seenLabel());
}

test "an unregistered table drops the banner's words instead of falling back to English" {
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    NotificationSpy.install(harness);
    // No setNotificationText: either the Renderer has not registered yet, or
    // its registration was refused.
    var window: State = .{};
    try std.testing.expect(window.notifyScheduledTask(&harness.runtime, .{
        .scheduled_task_id = 7,
        .task_id = 42,
        .title = "每日简报",
        .kind = .completed,
    }));
    // The two strings that are already in the user's language still go out.
    try std.testing.expectEqualStrings(app_manifest.display_name, NotificationSpy.seenTitle());
    try std.testing.expectEqualStrings("每日简报", NotificationSpy.seenSubtitle());
    // Everything that would have had to be English does not.
    try std.testing.expectEqual(@as(usize, 0), NotificationSpy.body_len);
    try std.testing.expectEqual(@as(usize, 0), NotificationSpy.label_len);
    try std.testing.expectEqual(@as(usize, 0), NotificationSpy.action_command_len);
    try std.testing.expectEqual(@as(usize, 0), NotificationSpy.activation_command_len);
    // It is still a real notification the user sees, with its own identity.
    try std.testing.expectEqual(@as(usize, 1), NotificationSpy.calls);
    try std.testing.expectEqualStrings("schedule-7-42-completed", NotificationSpy.seenId());
}

test "a Run notification waits for the application to lose the foreground" {
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    NotificationSpy.install(harness);
    var window: State = .{};
    window.setNotificationText(testNotificationText());
    var context: u8 = 0;
    const app: native_sdk.App = .{ .context = &context, .name = "notification-test" };
    const completed: control_ports.RunNotification = .{
        .task_id = 42,
        .run_id = 3,
        .title = "整理周报",
        .kind = .completed,
    };

    // A launching application counts as active, and a banner over the window
    // the user is already reading says nothing the Task list does not.
    try std.testing.expect(harness.runtime.app_active);
    try std.testing.expect(!window.notifyRunAttention(&harness.runtime, completed));
    try std.testing.expectEqual(@as(usize, 0), NotificationSpy.calls);

    try harness.runtime.dispatchPlatformEvent(app, .app_deactivated);
    try std.testing.expect(!harness.runtime.app_active);
    try std.testing.expect(window.notifyRunAttention(&harness.runtime, completed));
    try std.testing.expectEqual(@as(usize, 1), NotificationSpy.calls);
    try std.testing.expectEqualStrings(app_manifest.display_name, NotificationSpy.seenTitle());
    try std.testing.expectEqualStrings("整理周报", NotificationSpy.seenSubtitle());
    try std.testing.expectEqualStrings("任务已完成", NotificationSpy.seenBody());
    try std.testing.expectEqualStrings("查看任务", NotificationSpy.seenLabel());
    try std.testing.expectEqualStrings("run-42-3-completed", NotificationSpy.seenId());
    try std.testing.expectEqual(@as(?u64, 42), NotificationSpy.seenActionTaskId());
    try std.testing.expectEqual(@as(?u64, 42), NotificationSpy.seenActivationTaskId());

    // Each reason takes its own slot and its own replacement identity, so a
    // later failure cannot overwrite a pending approval.
    try std.testing.expect(window.notifyRunAttention(&harness.runtime, .{ .task_id = 42, .run_id = 3, .title = "整理周报", .kind = .needs_approval }));
    try std.testing.expectEqualStrings("任务正在等待你的确认", NotificationSpy.seenBody());
    try std.testing.expectEqualStrings("run-42-3-needs_approval", NotificationSpy.seenId());
    try std.testing.expect(window.notifyRunAttention(&harness.runtime, .{ .task_id = 42, .run_id = 3, .title = "整理周报", .kind = .failed }));
    try std.testing.expectEqualStrings("任务失败", NotificationSpy.seenBody());
    try std.testing.expectEqualStrings("run-42-3-failed", NotificationSpy.seenId());

    // Coming back to the front silences them again.
    try harness.runtime.dispatchPlatformEvent(app, .app_activated);
    NotificationSpy.reset();
    try std.testing.expect(!window.notifyRunAttention(&harness.runtime, completed));
    try std.testing.expectEqual(@as(usize, 0), NotificationSpy.calls);
}

test "a Run notification in an unregistered language keeps the Task title and drops the rest" {
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    NotificationSpy.install(harness);
    var window: State = .{};
    var context: u8 = 0;
    const app: native_sdk.App = .{ .context = &context, .name = "notification-test" };
    try harness.runtime.dispatchPlatformEvent(app, .app_deactivated);
    try std.testing.expect(window.notifyRunAttention(&harness.runtime, .{
        .task_id = 9,
        .run_id = 1,
        .title = "整理周报",
        .kind = .failed,
    }));
    try std.testing.expectEqualStrings("整理周报", NotificationSpy.seenSubtitle());
    try std.testing.expectEqual(@as(usize, 0), NotificationSpy.body_len);
    try std.testing.expectEqual(@as(usize, 0), NotificationSpy.label_len);
    try std.testing.expectEqualStrings("run-9-1-failed", NotificationSpy.seenId());
}
