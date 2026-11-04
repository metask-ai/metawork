const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const bridge_api = @import("metawork_bridge");
const control_ports = @import("metawork_product_control_ports");
const automation_api = @import("metawork_automation");
const app_window = @import("window.zig");

pub const TrayCommandResult = enum {
    handled,
    quit_requested,
};

pub const scheduled_task_timer_id: u64 = 0x4d57_5343_4844_544b;
pub const mcp_oauth_timer_id: u64 = 0x4d57_4d43_504f_4155;
pub const mcp_catalog_timer_id: u64 = 0x4d57_4d43_5043_4154;

// The Windows host takes its lifetime lock in wake(), and WebView2 handlers
// hold that lock across synchronous Bridge callbacks. A worker that wakes
// directly cannot exit while a Bridge command joins it. Required wakes are
// handed to this thread, so the worker never blocks on the host.
const RequiredWake = struct {
    const pending: u32 = 1;
    const closed: u32 = 2;

    io: std.Io,
    services: native_sdk.platform.PlatformServices,
    state: std.atomic.Value(u32) = .init(0),
    thread: ?std.Thread = null,

    fn start(self: *RequiredWake) std.Thread.SpawnError!void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    /// Any thread. Never blocks; false once closed.
    fn request(self: *RequiredWake) bool {
        const previous = self.state.fetchOr(pending, .release);
        if (previous & closed != 0) return false;
        if (previous & pending == 0) self.io.futexWake(u32, &self.state.raw, 1);
        return true;
    }

    fn run(self: *RequiredWake) void {
        while (true) {
            if (self.state.load(.acquire) == 0) {
                self.io.futexWaitUncancelable(u32, &self.state.raw, 0);
                continue;
            }
            const taken = self.state.fetchAnd(~pending, .acq_rel);
            if (taken & pending != 0) self.services.wake() catch
                @panic("Application completion lost its required main-loop wake");
            if (taken & closed != 0) return;
        }
    }

    /// Main thread, outside host callbacks. An accepted request is delivered
    /// before the thread exits.
    fn close(self: *RequiredWake) void {
        _ = self.state.fetchOr(closed, .release);
        self.io.futexWake(u32, &self.state.raw, 1);
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }
};

// This is the single DispatcherPlatform vtable implementation. It owns the
// Native SDK runtime/services references required by that vtable and delegates
// window-system behavior to window.State; it is not a general platform module.
pub const Adapter = struct {
    io: std.Io,
    main_thread_id: std.Thread.Id,
    trace_product_delivery: bool = false,
    native_runtime: ?*native_sdk.Runtime = null,
    platform_services: ?native_sdk.platform.PlatformServices = null,
    required_wake: ?RequiredWake = null,
    window: app_window.State = .{},

    pub fn init(io: std.Io, main_thread_id: std.Thread.Id) Adapter {
        return .{ .io = io, .main_thread_id = main_thread_id };
    }

    pub fn setProductDeliveryTrace(self: *Adapter, enabled: bool) void {
        self.trace_product_delivery = enabled;
    }

    pub fn start(self: *Adapter, runtime: *native_sdk.Runtime) !void {
        const services_value = runtime.options.platform.services;
        if (services_value.wake_fn == null) return error.MainLoopWakeUnavailable;
        self.required_wake = .{ .io = self.io, .services = services_value };
        const required_wake = &self.required_wake.?;
        required_wake.start() catch {
            self.required_wake = null;
            return error.MainLoopWakeUnavailable;
        };
        errdefer self.closeRequiredWake();
        try self.window.bind(services_value);
        self.native_runtime = runtime;
        self.platform_services = services_value;
    }

    pub fn stop(self: *Adapter, runtime: *native_sdk.Runtime) void {
        self.window.removeTray(runtime);
        // App stop runs after the host message loop has exited, so the relay
        // cannot be parked on the host lock while this joins it.
        self.closeRequiredWake();
        self.platform_services = null;
        if (self.native_runtime == runtime) self.native_runtime = null;
    }

    fn closeRequiredWake(self: *Adapter) void {
        if (self.required_wake) |*required_wake| required_wake.close();
        self.required_wake = null;
    }

    fn requestRequiredWake(self: *Adapter) bool {
        const required_wake = if (self.required_wake) |*value| value else return false;
        return required_wake.request();
    }

    pub fn outputFileSave(self: *Adapter) control_ports.OutputFileSave {
        return .{ .context = self, .begin_fn = prepareOutputSave, .cancel_fn = cancelOutputSave };
    }

    const OwnedSave = struct {
        main_thread_id: std.Thread.Id,
        value: @import("app_output_file").Save,
        fn stage(context: *anyopaque, cancelled: *const std.atomic.Value(bool)) !void {
            const self: *OwnedSave = @ptrCast(@alignCast(context));
            try self.value.stage(cancelled);
        }
        fn publish(context: *anyopaque) !void {
            const self: *OwnedSave = @ptrCast(@alignCast(context));
            try self.value.publish();
        }
        fn discard(context: *anyopaque) !void {
            const self: *OwnedSave = @ptrCast(@alignCast(context));
            try self.value.discard();
        }
        fn release(context: *anyopaque) void {
            const self: *OwnedSave = @ptrCast(@alignCast(context));
            std.debug.assert(std.Thread.getCurrentId() == self.main_thread_id);
            self.value.deinit();
            std.heap.c_allocator.destroy(self);
        }
    };

    fn prepareOutputSave(context: *anyopaque, operation: u64, parent: u64, default_name: []const u8, completion: *const control_ports.OutputFileSave.Completion) !u64 {
        const self: *Adapter = @ptrCast(@alignCast(context));
        if (std.Thread.getCurrentId() != self.main_thread_id) return error.InvalidThread;
        const runtime = self.native_runtime orelse return error.RuntimeUnavailable;
        if (!self.supportsAsyncDialogs()) return error.UnsupportedService;
        var tag: [8]u8 = undefined;
        std.mem.writeInt(u64, &tag, operation, .little);
        return runtime.requestSaveDialog(.{ .default_name = default_name }, parent, .{ .context = @constCast(completion), .tag = &tag, .on_result = outputSaveResult });
    }
    fn cancelOutputSave(context: *anyopaque, handle: u64) void {
        cancelDialog(context, handle);
    }
    fn outputSaveResult(context: *anyopaque, _: *native_sdk.Runtime, tag: []const u8, result: native_sdk.platform.DialogResult) !void {
        const completion: *const control_ports.OutputFileSave.Completion = @ptrCast(@alignCast(context));
        const operation = std.mem.readInt(u64, tag[0..8], .little);
        switch (result.outcome) {
            .cancelled => completion.complete_fn(completion.context, operation, .cancelled),
            .failed => completion.complete_fn(completion.context, operation, .{ .failed = error.DialogFailed }),
            .selected => {
                const source = completion.borrow_source_fn(completion.context, operation) catch |err| {
                    completion.complete_fn(completion.context, operation, .{ .failed = err });
                    return;
                };
                if (result.count != 1 or result.paths.len == 0) {
                    completion.complete_fn(completion.context, operation, .{ .failed = error.InvalidDialogResult });
                    return;
                }
                const owned = std.heap.c_allocator.create(OwnedSave) catch |err| {
                    completion.complete_fn(completion.context, operation, .{ .failed = err });
                    return;
                };
                owned.* = .{ .main_thread_id = std.Thread.getCurrentId(), .value = @import("app_output_file").Save.init(std.heap.c_allocator, source.io, .{ .workspace_root = source.workspace_root, .relative_path = source.relative_path, .main_thread_id = std.Thread.getCurrentId() }, result.paths, .{ .size_bytes = source.size_bytes, .sha256 = source.sha256 }) catch |err| {
                    std.heap.c_allocator.destroy(owned);
                    completion.complete_fn(completion.context, operation, .{ .failed = err });
                    return;
                } };
                completion.complete_fn(completion.context, operation, .{ .selected = .{ .context = owned, .stage_fn = OwnedSave.stage, .publish_fn = OwnedSave.publish, .discard_fn = OwnedSave.discard, .release_fn = OwnedSave.release } });
            },
        }
    }

    pub fn outputFileReveal(self: *Adapter) control_ports.OutputFileReveal {
        return .{ .context = self, .reveal_fn = revealOutputFile };
    }

    fn revealOutputFile(context: *anyopaque, root: []const u8, relative: []const u8) !void {
        const self: *Adapter = @ptrCast(@alignCast(context));
        if (std.Thread.getCurrentId() != self.main_thread_id) return error.InvalidThread;
        if (!std.fs.path.isAbsolute(root)) return error.InvalidPath;
        const path = try @import("app_output_file").absolutePath(std.heap.c_allocator, root, relative);
        defer std.heap.c_allocator.free(path);
        try (self.native_runtime orelse return error.RuntimeUnavailable).revealPath(path);
    }

    pub fn services(self: *const Adapter) ?native_sdk.platform.PlatformServices {
        return self.platform_services;
    }

    pub fn supportsMcpConnectionApproval(self: *const Adapter) bool {
        return self.supportsAsyncDialogs();
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
    ) TrayCommandResult {
        const runtime_value = self.native_runtime orelse return .handled;
        return switch (tray_item_id) {
            app_window.tray_open_id => result: {
                self.window.showMainWindow(runtime_value);
                break :result .handled;
            },
            app_window.tray_quit_id => .quit_requested,
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
            .request_dialog_fn = requestDialog,
            .cancel_dialog_fn = cancelDialog,
            .canonicalize_directory_fn = canonicalizeDirectory,
            .random_fn = random,
            .window_chrome_connect_fn = windowChromeConnect,
            .window_chrome_refresh_fn = windowChromeRefresh,
            .window_chrome_control_fn = windowChromeControl,
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

    /// Agent notifications use the same required relay without making a
    /// closed consumer fatal to the executing callback.
    pub fn notifyAgentEvents(context: ?*anyopaque) bool {
        const self: *Adapter = @ptrCast(@alignCast(context orelse return false));
        return self.requestRequiredWake();
    }

    pub fn notifyRequired(context: *anyopaque) void {
        const self: *Adapter = @ptrCast(@alignCast(context));
        if (!self.requestRequiredWake())
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
        (self.native_runtime orelse return false).startTimer(
            mcp_oauth_timer_id,
            delay_ns,
            false,
        ) catch return false;
        return true;
    }

    pub fn cancelMcpOauthTimer(self: *Adapter) void {
        if (self.native_runtime) |runtime|
            runtime.cancelTimer(mcp_oauth_timer_id) catch {};
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
        (self.native_runtime orelse return false).startTimer(
            mcp_catalog_timer_id,
            delay_ns,
            false,
        ) catch return false;
        return true;
    }

    pub fn cancelMcpCatalogTimer(context: ?*anyopaque) void {
        const self: *Adapter = @ptrCast(@alignCast(context orelse return));
        if (self.native_runtime) |runtime|
            runtime.cancelTimer(mcp_catalog_timer_id) catch {};
    }

    pub fn openMcpAuthorizationUrl(self: *Adapter, url: []const u8) bool {
        if (std.Thread.getCurrentId() != self.main_thread_id or self.native_runtime == null)
            return false;
        // The MCP owner binds this URL to the current consent/attempt. Keep
        // Host handoff independent of the WebView's deny-navigation policy.
        if (url.len == 0 or url.len > native_sdk.platform.max_external_url_bytes or
            !std.unicode.utf8ValidateSlice(url)) return false;
        for (url) |byte| if (byte <= 0x20 or byte == 0x7f or byte == '\\') return false;
        const uri = std.Uri.parse(url) catch return false;
        if (!std.ascii.eqlIgnoreCase(uri.scheme, "https") or uri.host == null or
            uri.host.?.isEmpty() or uri.user != null or uri.password != null or
            uri.fragment != null) return false;
        const services_value = self.platform_services orelse return false;
        services_value.openExternalUrl(url) catch return false;
        return true;
    }

    fn openExternalUrl(context: ?*anyopaque, url: []const u8) !void {
        const self: *Adapter = @ptrCast(@alignCast(context orelse
            return error.RuntimeUnavailable));
        if (std.Thread.getCurrentId() != self.main_thread_id) return error.WrongThread;
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
        (self.native_runtime orelse return false).startTimer(
            scheduled_task_timer_id,
            delay_ns,
            false,
        ) catch return false;
        return true;
    }

    pub fn cancelScheduledTaskTimer(context: ?*anyopaque) void {
        const self: *Adapter = @ptrCast(@alignCast(context.?));
        if (self.native_runtime) |runtime|
            runtime.cancelTimer(scheduled_task_timer_id) catch {};
    }

    pub fn notifyScheduledTask(
        context: ?*anyopaque,
        notification: control_ports.ScheduleNotification,
    ) bool {
        const self: *Adapter = @ptrCast(@alignCast(context orelse return false));
        const runtime = self.native_runtime orelse return false;
        return self.window.notifyScheduledTask(runtime, notification);
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
        try (self.native_runtime orelse return error.RuntimeUnavailable).startTimer(
            timer_id,
            interval_ns,
            repeats,
        );
    }

    fn cancelTimer(context: ?*anyopaque, timer_id: u64) anyerror!void {
        const self: *Adapter = @ptrCast(@alignCast(context.?));
        try (self.native_runtime orelse return error.RuntimeUnavailable).cancelTimer(timer_id);
    }

    pub fn supportsAsyncDialogs(self: *const Adapter) bool {
        const runtime = self.native_runtime orelse return false;
        const services_value = runtime.options.platform.services;
        return services_value.supportsAsyncDialogs() and services_value.cancel_dialog_fn != null and services_value.wake_fn != null;
    }

    pub fn requestDialog(context: ?*anyopaque, operation: u64, parent: u64, options: control_ports.NativeDialog.Options, completion: *const control_ports.NativeDialog.Completion) anyerror!u64 {
        const self: *Adapter = @ptrCast(@alignCast(context.?));
        if (std.Thread.getCurrentId() != self.main_thread_id) return error.InvalidThread;
        const runtime = self.native_runtime orelse return error.RuntimeUnavailable;
        if (!self.supportsAsyncDialogs()) return error.UnsupportedService;
        var tag: [8]u8 = undefined;
        std.mem.writeInt(u64, &tag, operation, .little);
        const parent_id: ?u64 = if (parent == 0) null else parent;
        const result: native_sdk.DialogCompletion = .{ .context = @constCast(completion), .tag = &tag, .on_result = dialogResult };
        switch (options) {
            .open => |open| {
                const filters = try std.heap.c_allocator.alloc(native_sdk.platform.FileFilter, open.filters.len);
                defer std.heap.c_allocator.free(filters);
                for (open.filters, filters) |input, *output| output.* = .{ .name = input.name, .extensions = input.extensions };
                return runtime.requestOpenDialog(.{ .title = open.title, .default_path = open.default_path, .filters = filters, .allow_directories = open.allow_directories, .allow_multiple = open.allow_multiple }, parent_id, result);
            },
            .save => |save| return runtime.requestSaveDialog(.{ .title = save.title, .default_path = save.default_path, .default_name = save.default_name }, parent_id, result),
            .message => |message| return runtime.requestMessageDialog(.{
                .title = message.title,
                .message = message.message,
                .informative_text = message.informative_text,
                .style = switch (message.style) {
                    .info => .info,
                    .warning => .warning,
                    .critical => .critical,
                },
                .primary_button = message.primary_button,
                .secondary_button = message.secondary_button,
                .tertiary_button = message.tertiary_button,
            }, parent_id, result),
        }
    }

    fn dialogResult(context: *anyopaque, _: *native_sdk.Runtime, tag: []const u8, result: native_sdk.platform.DialogResult) !void {
        const completion: *const control_ports.NativeDialog.Completion = @ptrCast(@alignCast(context));
        const operation = std.mem.readInt(u64, tag[0..8], .little);
        const converted: control_ports.NativeDialog.Result = switch (result.outcome) {
            .cancelled => .cancelled,
            .failed => .failed,
            .selected => if (result.count != 0) .{ .files = .{ .paths = result.paths, .count = result.count } } else .{ .button = switch (result.button) {
                .primary => .primary,
                .secondary => .secondary,
                .tertiary => .tertiary,
            } },
        };
        completion.result_fn(completion.context, operation, converted);
    }

    pub fn cancelDialog(context: ?*anyopaque, handle: u64) void {
        const self: *Adapter = @ptrCast(@alignCast(context.?));
        if (self.native_runtime) |runtime| runtime.cancelDialog(handle);
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

    fn windowChromeConnect(
        context: ?*anyopaque,
        window_id: native_sdk.platform.WindowId,
    ) anyerror!bridge_api.WindowChromePlatformEnvironment {
        const self: *Adapter = @ptrCast(@alignCast(context.?));
        if (comptime builtin.os.tag == .windows) return self.window.connectWindows(
            self.native_runtime orelse return error.RuntimeUnavailable,
            window_id,
        );
        return self.window.connect(
            self.native_runtime orelse return error.RuntimeUnavailable,
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
            window_id,
        );
        return self.window.refresh(
            self.native_runtime orelse return error.RuntimeUnavailable,
            window_id,
        );
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

test "main-loop wake startup rejects a missing service before publication" {
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.runtime.options.platform.services.wake_fn = null;
    var adapter = Adapter.init(std.testing.io, std.Thread.getCurrentId());
    try std.testing.expectError(error.MainLoopWakeUnavailable, adapter.start(&harness.runtime));
    try std.testing.expect(adapter.services() == null);
    try std.testing.expect(adapter.native_runtime == null);
    try std.testing.expect(!Adapter.notifyMainLoop(&adapter));
    try std.testing.expect(!adapter.requestRequiredWake());
}

const RequiredWakeTest = struct {
    // Stands in for the Windows host lifetime lock taken by wake().
    var host_lock: std.Io.Mutex = .init;
    var calls: std.atomic.Value(usize) = .init(0);

    fn wake(_: ?*anyopaque) anyerror!void {
        host_lock.lockUncancelable(std.testing.io);
        defer host_lock.unlock(std.testing.io);
        _ = calls.fetchAdd(1, .monotonic);
    }

    const Worker = struct {
        adapter: *Adapter,
        exited: std.Io.Event = .unset,
        accepted: bool = false,

        fn run(self: *@This()) void {
            self.accepted = Adapter.notifyAgentEvents(self.adapter);
            self.exited.set(std.testing.io);
        }
    };
};

test "required wake lets a worker exit while a Bridge callback holds the host lock" {
    const T = RequiredWakeTest;
    T.calls.store(0, .monotonic);
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.runtime.options.platform.services.wake_fn = T.wake;
    var adapter = Adapter.init(std.testing.io, std.Thread.getCurrentId());
    try std.testing.expect(!Adapter.notifyAgentEvents(&adapter));
    try adapter.start(&harness.runtime);
    defer adapter.stop(&harness.runtime);

    // The UI thread owns the host lock for the whole callback and joins.
    T.host_lock.lockUncancelable(std.testing.io);
    var worker: T.Worker = .{ .adapter = &adapter };
    const thread = try std.Thread.spawn(.{}, T.Worker.run, .{&worker});
    const exited = worker.exited.waitTimeout(std.testing.io, .{
        .duration = .{ .raw = .fromSeconds(5), .clock = .boot },
    });
    T.host_lock.unlock(std.testing.io);
    thread.join();
    try exited;
    try std.testing.expect(worker.accepted);

    adapter.stop(&harness.runtime);
    try std.testing.expectEqual(@as(usize, 1), T.calls.load(.monotonic));
    try std.testing.expect(!adapter.requestRequiredWake());
    try std.testing.expect(!Adapter.notifyAgentEvents(&adapter));
}

test "required wake coalesces requests while the host is busy" {
    const T = RequiredWakeTest;
    T.calls.store(0, .monotonic);
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.runtime.options.platform.services.wake_fn = T.wake;
    var adapter = Adapter.init(std.testing.io, std.Thread.getCurrentId());
    try adapter.start(&harness.runtime);
    defer adapter.stop(&harness.runtime);

    T.host_lock.lockUncancelable(std.testing.io);
    for (0..32) |_| try std.testing.expect(Adapter.notifyAgentEvents(&adapter));
    T.host_lock.unlock(std.testing.io);

    adapter.stop(&harness.runtime);
    const calls = T.calls.load(.monotonic);
    try std.testing.expect(calls >= 1 and calls <= 2);
}

const WakePublicationTest = struct {
    const activation = @import("single_instance.zig");
    var calls: std.atomic.Value(usize) = .init(0);

    fn wake(_: ?*anyopaque) anyerror!void {
        _ = calls.fetchAdd(1, .monotonic);
    }

    const Worker = struct {
        queue: *activation.ActivationQueue,
        frame: []const u8,
        entered: std.atomic.Value(bool) = .init(false),
        failed: bool = false,

        fn run(self: *@This()) void {
            if (self.queue.accept(self.frame) != .accepted) self.failed = true;
            self.entered.store(true, .release);
            for (0..100_000) |_| {
                if (self.queue.accept(self.frame) != .accepted) self.failed = true;
            }
        }
    };
};

test "main-loop wake publishes Native startup to the live activation listener" {
    const T = WakePublicationTest;
    T.calls.store(0, .monotonic);
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.runtime.options.platform.services.wake_fn = T.wake;
    var adapter = Adapter.init(std.testing.io, std.Thread.getCurrentId());
    const identity = T.activation.Identity.init("wake-test", "/isolated");
    var queue = T.activation.ActivationQueue.init(std.testing.io, identity);
    var storage: [T.activation.max_frame_bytes]u8 = undefined;
    const frame = try T.activation.encodeRequest(&storage, identity, "/", &.{"metawork"});
    var worker: T.Worker = .{ .queue = &queue, .frame = frame };
    var started = false;
    defer {
        queue.stop();
        if (started) adapter.stop(&harness.runtime);
    }
    {
        const thread = try std.Thread.spawn(.{}, T.Worker.run, .{&worker});
        defer thread.join();
        while (!worker.entered.load(.acquire)) std.Thread.yield() catch {};
        try std.testing.expectEqual(@as(usize, 0), T.calls.load(.monotonic));
        try adapter.start(&harness.runtime);
        started = true;
        try std.testing.expect(queue.bindWakeAndDrain(.{ .context = &adapter, .notify_fn = Adapter.notifyMainLoop }));
    }
    try std.testing.expect(!worker.failed);
    // Guaranteed post-bind request in addition to the concurrent stress.
    try std.testing.expectEqual(T.activation.Status.accepted, queue.accept(frame));
    try std.testing.expect(T.calls.load(.monotonic) > 0);
}

const ExternalUrlTest = struct {
    var calls: usize = 0;
    var fail = false;
    var exact = false;
    const url = "https://oauth.example.invalid/authorize?state=synthetic&code_challenge=synthetic";
    fn open(_: ?*anyopaque, value: []const u8) anyerror!void {
        calls += 1;
        exact = std.mem.eql(u8, value, url);
        if (fail) return error.InjectedHandlerFailure;
    }
};

test "SDK consumption MCP Host handoff preserves deny policy and exact target" {
    const T = ExternalUrlTest;
    T.calls = 0;
    T.fail = false;
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.runtime.options.platform.services.open_external_url_fn = T.open;
    var adapter = Adapter.init(std.testing.io, std.Thread.getCurrentId());
    try adapter.start(&harness.runtime);
    defer adapter.stop(&harness.runtime);
    try std.testing.expectError(error.NavigationDenied, harness.runtime.openExternalUrl(T.url));
    try std.testing.expectEqual(@as(usize, 0), T.calls);
    try std.testing.expect(adapter.supportsMcpExternalAuthorization());
    try std.testing.expect(adapter.openMcpAuthorizationUrl(T.url));
    try std.testing.expectEqual(@as(usize, 1), T.calls);
    try std.testing.expect(T.exact);
    try std.testing.expectEqual(native_sdk.security.ExternalLinkAction.deny, harness.runtime.options.security.navigation.external_links.action);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.options.security.navigation.external_links.allowed_urls.len);
    for ([_][]const u8{ "", "http://oauth.example.invalid/", "mailto:a@example.invalid", "https://user:pass@oauth.example.invalid/", "https://oauth.example.invalid/#fragment", "https://oauth.example.invalid/\n" }) |invalid| {
        try std.testing.expect(!adapter.openMcpAuthorizationUrl(invalid));
    }
    try std.testing.expectEqual(@as(usize, 1), T.calls);
    T.fail = true;
    try std.testing.expect(!adapter.openMcpAuthorizationUrl(T.url));
    try std.testing.expectEqual(@as(usize, 2), T.calls);
    adapter.main_thread_id +%= 1;
    try std.testing.expect(!adapter.openMcpAuthorizationUrl(T.url));
    try std.testing.expectEqual(@as(usize, 2), T.calls);
}

test "SDK consumption timers preserve producer IDs and explicit failures" {
    const Spy = struct {
        var id: u64 = 0;
        var interval: u64 = 0;
        var repeats = false;
        var fail = false;
        fn start(_: ?*anyopaque, timer_id: u64, ns: u64, repeated: bool) anyerror!void {
            id = timer_id;
            interval = ns;
            repeats = repeated;
            if (fail) return error.InjectedTimerFailure;
        }
        fn cancel(_: ?*anyopaque, timer_id: u64) anyerror!void {
            id = timer_id;
            if (fail) return error.InjectedTimerFailure;
        }
    };
    Spy.fail = false;
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.runtime.options.platform.services.start_timer_fn = Spy.start;
    harness.runtime.options.platform.services.cancel_timer_fn = Spy.cancel;
    var adapter = Adapter.init(std.testing.io, std.Thread.getCurrentId());
    try adapter.start(&harness.runtime);
    defer adapter.stop(&harness.runtime);
    const port = adapter.dispatcherPlatform();
    try port.start_timer_fn(port.context, 99, 123, true);
    try std.testing.expectEqual(@as(u64, 99), Spy.id);
    try std.testing.expectEqual(@as(u64, 123), Spy.interval);
    try std.testing.expect(Spy.repeats);
    try port.cancel_timer_fn(port.context, 99);
    try std.testing.expectEqual(@as(u64, 99), Spy.id);
    try std.testing.expect(adapter.armMcpOauthTimer(0));
    try std.testing.expectEqual(mcp_oauth_timer_id, Spy.id);
    try std.testing.expectEqual(std.time.ns_per_ms, Spy.interval);
    adapter.cancelMcpOauthTimer();
    try std.testing.expectEqual(mcp_oauth_timer_id, Spy.id);
    try std.testing.expect(Adapter.armMcpCatalogTimer(&adapter, 0));
    try std.testing.expectEqual(mcp_catalog_timer_id, Spy.id);
    Adapter.cancelMcpCatalogTimer(&adapter);
    try std.testing.expectEqual(mcp_catalog_timer_id, Spy.id);
    try std.testing.expect(Adapter.armScheduledTaskTimer(&adapter, 0));
    try std.testing.expectEqual(scheduled_task_timer_id, Spy.id);
    try std.testing.expectEqual(std.time.ns_per_s, Spy.interval);
    try std.testing.expect(!Spy.repeats);
    Adapter.cancelScheduledTaskTimer(&adapter);
    try std.testing.expectEqual(scheduled_task_timer_id, Spy.id);
    Spy.fail = true;
    try std.testing.expectError(error.InjectedTimerFailure, port.start_timer_fn(port.context, 99, 1, false));
    try std.testing.expectError(error.InjectedTimerFailure, port.cancel_timer_fn(port.context, 99));
    try std.testing.expect(!adapter.armMcpOauthTimer(0));
    try std.testing.expect(!Adapter.armMcpCatalogTimer(&adapter, 0));
    try std.testing.expect(!Adapter.armScheduledTaskTimer(&adapter, 0));
    adapter.stop(&harness.runtime);
    try std.testing.expectError(error.RuntimeUnavailable, port.start_timer_fn(port.context, 99, 1, false));
}

test "Output location uses the SDK Runtime reveal boundary and rejects invalid input before the platform" {
    const Spy = struct {
        var calls: usize = 0;
        var fail: bool = false;
        fn reveal(_: ?*anyopaque, path: []const u8) !void {
            calls += 1;
            try std.testing.expect(std.mem.endsWith(u8, path, "report.docx"));
            if (fail) return error.InjectedRevealFailure;
        }
    };
    Spy.calls = 0;
    Spy.fail = false;
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.runtime.options.platform.services.reveal_path_fn = Spy.reveal;
    var adapter = Adapter.init(std.testing.io, std.Thread.getCurrentId());
    adapter.native_runtime = &harness.runtime;
    const port = adapter.outputFileReveal();
    const root = if (builtin.os.tag == .windows) "C:\\workspace" else "/tmp/workspace";
    try port.reveal_fn(port.context, root, "report.docx");
    try std.testing.expectEqual(@as(usize, 1), Spy.calls);
    try std.testing.expectError(error.InvalidOutputPath, port.reveal_fn(port.context, root, "../report.docx"));
    try std.testing.expectError(error.InvalidPath, port.reveal_fn(port.context, "relative", "report.docx"));
    try std.testing.expectEqual(@as(usize, 1), Spy.calls);
    Spy.fail = true;
    try std.testing.expectError(error.InjectedRevealFailure, port.reveal_fn(port.context, root, "report.docx"));
    adapter.native_runtime = null;
    try std.testing.expectError(error.RuntimeUnavailable, port.reveal_fn(port.context, root, "report.docx"));
    try std.testing.expectEqual(@as(usize, 2), Spy.calls);
}

test "SDK consumption Output Save picker freezes selected path for worker publication" {
    const Probe = struct {
        source: control_ports.OutputFileSaveInput,
        effect: ?control_ports.OwnedOutputSave = null,
        cancelled: bool = false,
        fn borrow(raw: *anyopaque, _: u64) !control_ports.OutputFileSaveInput {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return self.source;
        }
        fn complete(raw: *anyopaque, _: u64, result: control_ports.OutputFileSave.Result) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            switch (result) {
                .selected => |effect| self.effect = effect,
                .cancelled => self.cancelled = true,
                .failed => @panic("unexpected Save As failure"),
            }
        }
    };
    const Worker = struct {
        effect: *control_ports.OwnedOutputSave,
        operation: enum { stage, publish },
        cancelled: std.atomic.Value(bool) = .init(false),
        result: anyerror!void = error.NotStarted,
        fn run(self: *@This()) void {
            self.result = switch (self.operation) {
                .stage => self.effect.stage_fn(self.effect.context, &self.cancelled),
                .publish => self.effect.publish_fn(self.effect.context),
            };
        }
        fn execute(self: *@This()) !void {
            const thread = try std.Thread.spawn(.{}, run, .{self});
            thread.join();
            return self.result;
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "source.txt", .data = "abc" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "selected.txt", .data = "keep" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const selected = try std.fs.path.join(std.testing.allocator, &.{ root, "selected.txt" });
    defer std.testing.allocator.free(selected);
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    const app: native_sdk.App = .{ .context = harness, .name = "save-publication", .source = native_sdk.WebViewSource.html("<p>Save</p>") };
    try harness.runtime.dispatchPlatformEvent(app, .app_start);
    harness.null_platform.useAsyncDialogs(&harness.runtime.options.platform.services);
    var adapter = Adapter.init(std.testing.io, std.Thread.getCurrentId());
    adapter.native_runtime = &harness.runtime;
    const port = adapter.outputFileSave();
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("abc", &hash, .{});
    var probe: Probe = .{ .source = .{ .io = std.testing.io, .workspace_root = root, .relative_path = "source.txt", .size_bytes = 3, .sha256 = hash } };
    const completion: control_ports.OutputFileSave.Completion = .{ .context = &probe, .borrow_source_fn = Probe.borrow, .complete_fn = Probe.complete };
    const cancelled = try port.begin_fn(port.context, 1, 1, "source.txt", &completion);
    try harness.null_platform.finishDialog(cancelled, .cancelled, "", .primary);
    while (harness.null_platform.takeWake()) |event| try harness.runtime.dispatchPlatformEvent(app, event);
    try std.testing.expect(probe.cancelled);
    try std.testing.expect(probe.effect == null);
    const chosen = try port.begin_fn(port.context, 2, 1, "source.txt", &completion);
    try harness.null_platform.finishDialog(chosen, .selected, selected, .primary);
    while (harness.null_platform.takeWake()) |event| try harness.runtime.dispatchPlatformEvent(app, event);
    var effect = probe.effect.?;
    defer effect.deinit();
    // SDK completion storage has been released before worker publication.
    var worker: Worker = .{ .effect = &effect, .operation = .stage };
    try worker.execute();
    const before = try tmp.dir.readFileAlloc(std.testing.io, "selected.txt", std.testing.allocator, .limited(32));
    defer std.testing.allocator.free(before);
    try std.testing.expectEqualStrings("keep", before);
    worker.operation = .publish;
    try worker.execute();
    const after = try tmp.dir.readFileAlloc(std.testing.io, "selected.txt", std.testing.allocator, .limited(32));
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings("abc", after);
}

test "SDK consumption async dialogs check capability before request and deliver typed outcomes later" {
    const Probe = struct {
        calls: usize = 0,
        operation: u64 = 0,
        result: enum { none, files, primary, cancelled, failed } = .none,
        fn receive(context: *anyopaque, operation: u64, result: control_ports.NativeDialog.Result) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            self.operation = operation;
            self.result = switch (result) {
                .files => .files,
                .button => .primary,
                .cancelled => .cancelled,
                .failed => .failed,
            };
        }
    };
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    const app: native_sdk.App = .{ .context = harness, .name = "async-dialog-test", .source = native_sdk.WebViewSource.html("<p>Dialog</p>") };
    try harness.runtime.dispatchPlatformEvent(app, .app_start);
    var adapter = Adapter.init(std.testing.io, std.Thread.getCurrentId());
    adapter.native_runtime = &harness.runtime;
    defer adapter.native_runtime = null;
    var probe: Probe = .{};
    const completion: control_ports.NativeDialog.Completion = .{ .context = &probe, .result_fn = Probe.receive };
    try std.testing.expect(!adapter.supportsAsyncDialogs());
    try std.testing.expectError(error.UnsupportedService, Adapter.requestDialog(&adapter, 1, 1, .{ .open = .{} }, &completion));
    harness.null_platform.useAsyncDialogs(&harness.runtime.options.platform.services);
    try std.testing.expect(adapter.supportsAsyncDialogs());
    const port = adapter.dispatcherPlatform();
    try std.testing.expectError(error.InvalidDialogOptions, port.request_dialog_fn(port.context, 41, 1, .{ .open = .{ .title = "bad\x00title" } }, &completion));
    const id = try port.request_dialog_fn(port.context, 42, 1, .{ .open = .{ .allow_multiple = true, .filters = &.{.{ .name = "Images", .extensions = &.{"png"} }} } }, &completion);
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
    try harness.null_platform.finishDialog(id, .selected, "/a.txt\n/b.txt", .primary);
    while (harness.null_platform.takeWake()) |event| try harness.runtime.dispatchPlatformEvent(app, event);
    try std.testing.expectEqual(@as(u64, 42), probe.operation);
    try std.testing.expectEqual(.files, probe.result);
    const message = try port.request_dialog_fn(port.context, 43, 1, .{ .message = .{ .message = "Approve?" } }, &completion);
    try harness.null_platform.finishDialog(message, .cancelled, "", .primary);
    while (harness.null_platform.takeWake()) |event| try harness.runtime.dispatchPlatformEvent(app, event);
    try std.testing.expectEqual(.cancelled, probe.result);
    const cancelled = try port.request_dialog_fn(port.context, 44, 1, .{ .open = .{} }, &completion);
    port.cancel_dialog_fn(port.context, cancelled);
    while (harness.null_platform.takeWake()) |event| try harness.runtime.dispatchPlatformEvent(app, event);
    try std.testing.expectEqual(@as(u64, 44), probe.operation);
    try std.testing.expectEqual(.cancelled, probe.result);
    const failed = try port.request_dialog_fn(port.context, 45, 1, .{ .message = .{} }, &completion);
    try harness.null_platform.finishDialog(failed, .failed, "", .primary);
    while (harness.null_platform.takeWake()) |event| try harness.runtime.dispatchPlatformEvent(app, event);
    try std.testing.expectEqual(.failed, probe.result);
    try std.testing.expectEqual(@as(usize, 4), probe.calls);
    harness.runtime.options.platform.services.cancel_dialog_fn = null;
    try std.testing.expectError(error.UnsupportedService, port.request_dialog_fn(port.context, 46, 1, .{ .open = .{} }, &completion));
}

test "SDK consumption Save As borrows the frozen source only during selected completion" {
    const Probe = struct {
        borrows: usize = 0,
        completions: usize = 0,
        outcome: enum { none, selected, cancelled, failed } = .none,
        reject_source: bool = false,
        fn borrow(context: *anyopaque, _: u64) !control_ports.OutputFileSaveInput {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.borrows += 1;
            if (self.reject_source) return error.UnknownOutput;
            return .{ .io = std.testing.io, .workspace_root = if (builtin.os.tag == .windows) "C:\\workspace" else "/tmp/workspace", .relative_path = "report.txt", .size_bytes = 42, .sha256 = @splat(2) };
        }
        fn complete(context: *anyopaque, _: u64, result: control_ports.OutputFileSave.Result) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.completions += 1;
            self.outcome = switch (result) {
                .selected => .selected,
                .cancelled => .cancelled,
                .failed => .failed,
            };
            if (result == .selected) {
                var effect = result.selected;
                effect.deinit();
            }
        }
    };
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    const app: native_sdk.App = .{ .context = harness, .name = "save-dialog-test", .source = native_sdk.WebViewSource.html("<p>Save</p>") };
    try harness.runtime.dispatchPlatformEvent(app, .app_start);
    harness.null_platform.useAsyncDialogs(&harness.runtime.options.platform.services);
    var adapter = Adapter.init(std.testing.io, std.Thread.getCurrentId());
    adapter.native_runtime = &harness.runtime;
    defer adapter.native_runtime = null;
    const port = adapter.outputFileSave();
    var probe: Probe = .{};
    const completion: control_ports.OutputFileSave.Completion = .{ .context = &probe, .borrow_source_fn = Probe.borrow, .complete_fn = Probe.complete };
    const cancelled = try port.begin_fn(port.context, 1, 1, "report.txt", &completion);
    try std.testing.expectEqual(@as(usize, 0), probe.borrows);
    try harness.null_platform.finishDialog(cancelled, .cancelled, "", .primary);
    while (harness.null_platform.takeWake()) |event| try harness.runtime.dispatchPlatformEvent(app, event);
    try std.testing.expectEqual(.cancelled, probe.outcome);
    try std.testing.expectEqual(@as(usize, 0), probe.borrows);
    const selected = try port.begin_fn(port.context, 2, 1, "report.txt", &completion);
    try harness.null_platform.finishDialog(selected, .selected, if (builtin.os.tag == .windows) "C:\\export\\report.txt" else "/tmp/export/report.txt", .primary);
    while (harness.null_platform.takeWake()) |event| try harness.runtime.dispatchPlatformEvent(app, event);
    try std.testing.expectEqual(.selected, probe.outcome);
    try std.testing.expectEqual(@as(usize, 1), probe.borrows);
    probe.reject_source = true;
    const stale = try port.begin_fn(port.context, 3, 1, "report.txt", &completion);
    try harness.null_platform.finishDialog(stale, .selected, "/tmp/export/report.txt", .primary);
    while (harness.null_platform.takeWake()) |event| try harness.runtime.dispatchPlatformEvent(app, event);
    try std.testing.expectEqual(.failed, probe.outcome);
    try std.testing.expectEqual(@as(usize, 3), probe.completions);
}
