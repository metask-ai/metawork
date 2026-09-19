const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const bridge_api = @import("metawork_bridge");
const control_ports = @import("metawork_product_control_ports");
const automation_api = @import("metawork_automation");
const app_window = @import("window.zig");

test "Windows Adapter rejects both gestures before effects and allows detached cleanup" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    var adapter = Adapter.init(std.testing.io, std.Thread.getCurrentId());
    defer adapter.deinit();
    const port = adapter.dispatcherPlatform();
    const gestures = [_]bridge_api.WindowChromeGesture{
        .{ .action = .start_drag, .x = 300, .y = 20 },
        .{ .action = .toggle_maximize, .x = 300, .y = 20 },
    };
    for (gestures) |gesture| {
        try std.testing.expectError(error.WindowIdentityMismatch, port.window_chrome_gesture_fn(port.context, 2, gesture));
        try std.testing.expectError(error.RuntimeUnavailable, port.window_chrome_gesture_fn(port.context, 1, gesture));
    }
    try std.testing.expectError(error.RuntimeUnavailable, port.window_chrome_connect_fn(port.context, 1));
    try std.testing.expectError(error.RuntimeUnavailable, port.window_chrome_refresh_fn(port.context, 1));

    adapter.native_runtime = &harness.runtime;
    adapter.platform_services = harness.runtime.options.platform.services;
    _ = try harness.runtime.createWindow(.{ .id = 1, .label = "main", .source = .html("") });
    for (gestures) |gesture|
        try std.testing.expectError(error.WindowUnavailable, port.window_chrome_gesture_fn(port.context, 1, gesture));
    try harness.runtime.hideWindow(1);
    for (gestures) |gesture|
        try std.testing.expectError(error.WindowHidden, port.window_chrome_gesture_fn(port.context, 1, gesture));
    for ([_]bridge_api.WindowChromeControlAction{ .minimize, .toggle_maximize, .close }) |action|
        try std.testing.expectError(error.WindowHidden, port.window_chrome_control_fn(port.context, 1, action));

    adapter.native_runtime = null;
    adapter.platform_services = null;
    adapter.window.drag_region_capability.document_attached = true;
    try port.window_chrome_disconnect_fn(port.context, 1);
    try std.testing.expect(!adapter.window.drag_region_capability.document_attached);
}

pub const TrayCommandResult = enum {
    handled,
    quit_confirmed,
};

pub const scheduled_task_timer_id: u64 = 0x4d57_5343_4844_544b;
pub const mcp_oauth_timer_id: u64 = 0x4d57_4d43_504f_4155;
pub const mcp_catalog_timer_id: u64 = 0x4d57_4d43_5043_4154;

// This is the single DispatcherPlatform vtable implementation. It owns the
// Native SDK runtime/services references required by that vtable and delegates
// window-system behavior to window.State; it is not a general platform module.
pub const Adapter = struct {
    io: std.Io,
    main_thread_id: std.Thread.Id,
    trace_product_delivery: bool = false,
    native_runtime: ?*native_sdk.Runtime = null,
    platform_services: ?native_sdk.platform.PlatformServices = null,
    window: app_window.State = .{},

    pub fn init(io: std.Io, main_thread_id: std.Thread.Id) Adapter {
        return .{ .io = io, .main_thread_id = main_thread_id };
    }

    pub fn setProductDeliveryTrace(self: *Adapter, enabled: bool) void {
        self.trace_product_delivery = enabled;
    }

    pub fn prepareStartup(self: *Adapter) !void {
        try self.window.prepareStartup();
    }

    pub fn start(self: *Adapter, runtime: *native_sdk.Runtime) !void {
        try self.window.captureStartupWindow();
        self.native_runtime = runtime;
        self.platform_services = runtime.options.platform.services;
        const services_value = self.platform_services orelse
            return error.SystemWebViewChromeUnavailable;
        try self.window.bind(services_value);
    }

    pub fn stop(self: *Adapter, runtime: *native_sdk.Runtime) void {
        self.window.removeTray(runtime);
        self.window.deinit();
        self.platform_services = null;
        if (self.native_runtime == runtime) self.native_runtime = null;
    }

    pub fn deinit(self: *Adapter) void {
        self.window.deinit();
    }

    pub fn services(self: *const Adapter) ?native_sdk.platform.PlatformServices {
        return self.platform_services;
    }

    pub fn supportsMcpConnectionApproval(self: *const Adapter) bool {
        if (self.native_runtime == null) return false;
        const services_value = self.platform_services orelse return false;
        return services_value.show_message_dialog_fn != null;
    }

    pub fn supportsMcpExternalAuthorization(self: *const Adapter) bool {
        if (self.native_runtime == null) return false;
        const services_value = self.platform_services orelse return false;
        return services_value.open_external_url_fn != null;
    }

    pub fn installScheduleHost(
        self: *Adapter,
        schedule: control_ports.ScheduleHost,
    ) !void {
        try self.window.installTray(
            self.io,
            self.native_runtime orelse return error.RuntimeUnavailable,
            schedule,
        );
    }

    pub fn handleTrayCommand(
        self: *Adapter,
        tray_item_id: native_sdk.platform.TrayItemId,
        schedule: control_ports.ScheduleHost,
    ) TrayCommandResult {
        const runtime_value = self.native_runtime orelse return .handled;
        return switch (tray_item_id) {
            app_window.tray_open_id => result: {
                self.window.showMainWindow(runtime_value);
                break :result .handled;
            },
            app_window.tray_quit_id => if (self.window.confirmExplicitQuit(runtime_value, schedule))
                .quit_confirmed
            else
                .handled,
            else => .handled,
        };
    }

    pub fn requestExplicitQuit(self: *Adapter) !void {
        try self.window.requestExplicitQuit(
            self.native_runtime orelse return error.RuntimeUnavailable,
        );
    }

    pub fn activateMainWindow(self: *Adapter) void {
        const runtime_value = self.native_runtime orelse return;
        self.window.showMainWindow(runtime_value);
    }

    pub fn dispatcherPlatform(self: *Adapter) bridge_api.DispatcherPlatform {
        return .{
            .attachment_input = if (@import("builtin").os.tag == .windows) .file_bytes else .native_paths,
            .context = self,
            .wake_fn = wake,
            .emit_fn = emit,
            .start_timer_fn = startTimer,
            .cancel_timer_fn = cancelTimer,
            .show_open_dialog_fn = showOpenDialog,
            .canonicalize_directory_fn = canonicalizeDirectory,
            .random_fn = random,
            .window_chrome_connect_fn = windowChromeConnect,
            .window_chrome_refresh_fn = windowChromeRefresh,
            .window_chrome_gesture_fn = windowChromeGesture,
            .window_chrome_control_fn = windowChromeControl,
            .window_chrome_disconnect_fn = windowChromeDisconnect,
            .open_external_url_fn = openExternalUrl,
            .now_fn = now,
            .on_main_thread_fn = onMainThread,
        };
    }

    pub fn notifyMainLoop(context: ?*anyopaque) bool {
        const self: *Adapter = @ptrCast(@alignCast(context orelse return false));
        const services_value = self.platform_services orelse return false;
        services_value.wake() catch return false;
        return true;
    }

    pub fn notifyRequired(context: *anyopaque) void {
        if (!notifyMainLoop(context))
            @panic("Application completion lost its required main-loop wake");
    }

    pub fn scheduledTaskNow(context: ?*anyopaque) ?u64 {
        const self: *Adapter = @ptrCast(@alignCast(context.?));
        const nanoseconds = std.Io.Timestamp.now(self.io, .real).nanoseconds;
        if (nanoseconds < 0) return null;
        const seconds = @divFloor(nanoseconds, std.time.ns_per_s);
        if (seconds > std.math.maxInt(i64)) return null;
        return @intCast(seconds);
    }

    pub fn runNowMonotonicMs(context: ?*anyopaque) ?u64 {
        const self: *Adapter = @ptrCast(@alignCast(context.?));
        const nanoseconds = std.Io.Timestamp.now(self.io, .boot).nanoseconds;
        return std.math.cast(u64, @divFloor(nanoseconds, std.time.ns_per_ms));
    }

    pub fn runNowUnixMs(context: ?*anyopaque) ?u64 {
        const self: *Adapter = @ptrCast(@alignCast(context.?));
        return self.nowUnixMilliseconds();
    }

    pub fn nowUnixMilliseconds(self: *const Adapter) ?u64 {
        const nanoseconds = std.Io.Timestamp.now(self.io, .real).nanoseconds;
        if (nanoseconds < 0) return null;
        return @intCast(@divFloor(nanoseconds, std.time.ns_per_ms));
    }

    pub fn armMcpOauthTimer(
        self: *Adapter,
        due_unix_ms: u64,
    ) bool {
        const current = self.nowUnixMilliseconds() orelse return false;
        const delay_ms = if (due_unix_ms > current) due_unix_ms - current else 1;
        const delay_ns = std.math.mul(u64, delay_ms, std.time.ns_per_ms) catch
            std.math.maxInt(u64);
        (self.platform_services orelse return false).startTimer(
            mcp_oauth_timer_id,
            delay_ns,
            false,
        ) catch return false;
        return true;
    }

    pub fn cancelMcpOauthTimer(self: *Adapter) void {
        if (self.platform_services) |services_value|
            services_value.cancelTimer(mcp_oauth_timer_id) catch {};
    }

    pub fn mcpCatalogNowMonotonicMs(_: ?*anyopaque) ?u64 {
        return native_sdk.monotonicNanoseconds() / std.time.ns_per_ms;
    }

    pub fn armMcpCatalogTimer(context: ?*anyopaque, deadline_ms: u64) bool {
        const self: *Adapter = @ptrCast(@alignCast(context orelse return false));
        const current = mcpCatalogNowMonotonicMs(context) orelse return false;
        const delay_ms = if (deadline_ms > current) deadline_ms - current else 1;
        const delay_ns = std.math.mul(u64, delay_ms, std.time.ns_per_ms) catch
            return false;
        (self.platform_services orelse return false).startTimer(
            mcp_catalog_timer_id,
            delay_ns,
            false,
        ) catch return false;
        return true;
    }

    pub fn cancelMcpCatalogTimer(context: ?*anyopaque) void {
        const self: *Adapter = @ptrCast(@alignCast(context orelse return));
        if (self.platform_services) |services_value|
            services_value.cancelTimer(mcp_catalog_timer_id) catch {};
    }

    /// Shows every byte of a Host-only MCP trust or OAuth consent document in
    /// bounded native-dialog pages. Only the final page can approve; closing
    /// or cancelling any page rejects the operation.
    pub fn confirmMcpDetails(
        self: *Adapter,
        title: []const u8,
        details: []const u8,
        approval_label: []const u8,
    ) ?bool {
        const runtime = self.native_runtime orelse return null;
        if (details.len == 0 or !std.unicode.utf8ValidateSlice(details) or
            title.len == 0 or title.len > native_sdk.platform.max_dialog_title_bytes or
            approval_label.len == 0 or
            approval_label.len > native_sdk.platform.max_dialog_button_bytes)
            return null;
        var offset: usize = 0;
        while (offset < details.len) {
            var end = @min(
                details.len,
                offset + native_sdk.platform.max_dialog_message_bytes,
            );
            while (end > offset and !std.unicode.utf8ValidateSlice(details[offset..end]))
                end -= 1;
            if (end == offset) return null;
            const final_page = end == details.len;
            const result = runtime.showMessageDialog(.{
                .style = .warning,
                .title = title,
                .message = details[offset..end],
                .primary_button = if (final_page) approval_label else "Next",
                .secondary_button = "Cancel",
            }) catch return null;
            if (result != .primary) return false;
            offset = end;
        }
        return true;
    }

    pub fn openMcpAuthorizationUrl(self: *Adapter, url: []const u8) bool {
        const runtime = self.native_runtime orelse return false;
        runtime.openExternalUrl(url) catch return false;
        return true;
    }

    fn openExternalUrl(context: ?*anyopaque, url: []const u8) !void {
        const self: *Adapter = @ptrCast(@alignCast(context orelse
            return error.RuntimeUnavailable));
        const services_value = self.platform_services orelse
            return error.RuntimeUnavailable;
        try services_value.openExternalUrl(url);
    }

    pub fn armScheduledTaskTimer(
        context: ?*anyopaque,
        due_unix_seconds: u64,
    ) bool {
        const self: *Adapter = @ptrCast(@alignCast(context.?));
        const current = scheduledTaskNow(context) orelse return false;
        const delay_seconds = if (due_unix_seconds > current)
            due_unix_seconds - current
        else
            1;
        const delay_ns = std.math.mul(
            u64,
            delay_seconds,
            std.time.ns_per_s,
        ) catch return false;
        (self.platform_services orelse return false).startTimer(
            scheduled_task_timer_id,
            delay_ns,
            false,
        ) catch return false;
        return true;
    }

    pub fn cancelScheduledTaskTimer(context: ?*anyopaque) void {
        const self: *Adapter = @ptrCast(@alignCast(context.?));
        if (self.platform_services) |services_value|
            services_value.cancelTimer(scheduled_task_timer_id) catch {};
    }

    pub fn notifyScheduledTask(
        context: ?*anyopaque,
        notification: control_ports.ScheduleNotification,
    ) bool {
        const self: *Adapter = @ptrCast(@alignCast(context orelse return false));
        const services_value = self.platform_services orelse return false;
        return self.window.notifyScheduledTask(services_value, notification);
    }

    fn wake(context: ?*anyopaque) anyerror!void {
        const self: *Adapter = @ptrCast(@alignCast(context.?));
        try (self.platform_services orelse return error.RuntimeUnavailable).wake();
    }

    fn emit(
        context: ?*anyopaque,
        window_id: native_sdk.platform.WindowId,
        name: []const u8,
        detail: []const u8,
    ) anyerror!void {
        const self: *Adapter = @ptrCast(@alignCast(context.?));
        if (comptime automation_api.enabled) {
            if (self.trace_product_delivery and
                std.mem.eql(u8, name, bridge_api.product_event_name))
            {
                std.debug.print("metawork.product_delivery.emit event={s} main_thread={}\n", .{
                    name,
                    std.Thread.getCurrentId() == self.main_thread_id,
                });
            }
        }
        try (self.native_runtime orelse return error.RuntimeUnavailable).emitWindowEvent(
            window_id,
            name,
            detail,
        );
    }

    fn startTimer(
        context: ?*anyopaque,
        timer_id: u64,
        interval_ns: u64,
        repeats: bool,
    ) anyerror!void {
        const self: *Adapter = @ptrCast(@alignCast(context.?));
        try (self.platform_services orelse return error.RuntimeUnavailable).startTimer(
            timer_id,
            interval_ns,
            repeats,
        );
    }

    fn cancelTimer(context: ?*anyopaque, timer_id: u64) anyerror!void {
        const self: *Adapter = @ptrCast(@alignCast(context.?));
        try (self.platform_services orelse return error.RuntimeUnavailable).cancelTimer(timer_id);
    }

    fn showOpenDialog(
        context: ?*anyopaque,
        options: native_sdk.platform.OpenDialogOptions,
        output: []u8,
    ) anyerror!native_sdk.platform.OpenDialogResult {
        const self: *Adapter = @ptrCast(@alignCast(context.?));
        return self.window.showOpenDialog(
            self.platform_services orelse return error.RuntimeUnavailable,
            options,
            output,
        );
    }

    fn canonicalizeDirectory(
        context: ?*anyopaque,
        absolute_path: []const u8,
        output: []u8,
    ) anyerror![]const u8 {
        const self: *Adapter = @ptrCast(@alignCast(context.?));
        if (!std.fs.path.isAbsolute(absolute_path)) return error.InvalidPath;
        const length = try std.Io.Dir.realPathFileAbsolute(
            self.io,
            absolute_path,
            output,
        );
        const canonical = output[0..length];
        const stat = try std.Io.Dir.cwd().statFile(self.io, canonical, .{});
        if (stat.kind != .directory) return error.NotDir;
        return canonical;
    }

    fn random(context: ?*anyopaque, output: []u8) bool {
        const self: *Adapter = @ptrCast(@alignCast(context.?));
        self.io.random(output);
        return true;
    }

    fn showMessageDialog(
        context: ?*anyopaque,
        options: native_sdk.platform.MessageDialogOptions,
    ) anyerror!native_sdk.platform.MessageDialogResult {
        const self: *Adapter = @ptrCast(@alignCast(context.?));
        return self.window.showMessageDialog(
            self.platform_services orelse return error.RuntimeUnavailable,
            options,
        );
    }

    fn windowChromeConnect(
        context: ?*anyopaque,
        window_id: native_sdk.platform.WindowId,
    ) anyerror!bridge_api.WindowChromePlatformEnvironment {
        const self: *Adapter = @ptrCast(@alignCast(context.?));
        if (comptime builtin.os.tag == .windows) return self.window.connectWindows(
            self.native_runtime orelse return error.RuntimeUnavailable,
            self.platform_services orelse return error.RuntimeUnavailable,
            window_id,
        );
        return self.window.connect(
            self.platform_services orelse return error.RuntimeUnavailable,
            window_id,
        );
    }

    fn windowChromeRefresh(
        context: ?*anyopaque,
        window_id: native_sdk.platform.WindowId,
    ) anyerror!bridge_api.WindowChromePlatformEnvironment {
        const self: *Adapter = @ptrCast(@alignCast(context.?));
        if (comptime builtin.os.tag == .windows) return self.window.refreshWindows(
            self.native_runtime orelse return error.RuntimeUnavailable,
            self.platform_services orelse return error.RuntimeUnavailable,
            window_id,
        );
        return self.window.refresh(
            self.platform_services orelse return error.RuntimeUnavailable,
            window_id,
        );
    }

    fn windowChromeGesture(
        context: ?*anyopaque,
        window_id: native_sdk.platform.WindowId,
        gesture: bridge_api.WindowChromeGesture,
    ) anyerror!void {
        const self: *Adapter = @ptrCast(@alignCast(context.?));
        if (comptime builtin.os.tag == .windows) return self.window.handleWindowsGesture(
            self.native_runtime,
            self.platform_services,
            window_id,
            gesture,
        );
        return self.window.handleGesture(
            self.platform_services orelse return error.RuntimeUnavailable,
            window_id,
            gesture,
        );
    }

    fn windowChromeDisconnect(
        context: ?*anyopaque,
        window_id: native_sdk.platform.WindowId,
    ) anyerror!void {
        const self: *Adapter = @ptrCast(@alignCast(context.?));
        try self.window.disconnect(window_id);
    }

    fn windowChromeControl(
        context: ?*anyopaque,
        window_id: native_sdk.platform.WindowId,
        action: bridge_api.WindowChromeControlAction,
    ) anyerror!void {
        const self: *Adapter = @ptrCast(@alignCast(context.?));
        return self.window.control(
            self.native_runtime orelse return error.RuntimeUnavailable,
            window_id,
            action,
        );
    }

    fn now(_: ?*anyopaque) u64 {
        return native_sdk.monotonicNanoseconds();
    }

    fn onMainThread(context: ?*anyopaque) bool {
        const self: *Adapter = @ptrCast(@alignCast(context.?));
        return std.Thread.getCurrentId() == self.main_thread_id;
    }
};
