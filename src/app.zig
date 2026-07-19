const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");
const bridge_api = @import("metawork_bridge");
const automation_api = @import("metawork_automation");
const agent = @import("metawork_agent");
const workbench_api = @import("metawork_workbench");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const frontend_url_env = "NATIVE_SDK_FRONTEND_URL";
const pending_ui_json_capacity = 256 * 1024;
const terminal_diagnostic_capacity = 512;
const agent_event_retry_interval: std.Io.Duration = .fromMilliseconds(5);
const agent_event_notification_timeout: std.Io.Duration = .fromMilliseconds(50);
const host_worker_count = 4;
const workbench_snapshot_capacity = bridge_api.snapshot_max_bytes;
const FrontendMode = bridge_api.policy.Mode;

const App = struct {
    env_map: *std.process.Environ.Map,
    main_thread_id: std.Thread.Id,
    automation: automation_api.Runtime = .{},
    dispatcher: ?*bridge_api.Dispatcher = null,
    agent_runtime: ?*agent.Runtime = null,
    workbench: ?*workbench_api.Workbench = null,
    agent_shutdown: bool = false,
    agent_event_wake_pending: std.atomic.Value(bool) = .init(false),
    native_runtime: ?*native_sdk.Runtime = null,
    platform_services: ?native_sdk.platform.PlatformServices = null,

    fn app(self: *@This()) native_sdk.App {
        return .{
            .context = self,
            .name = "metawork",
            .source = native_sdk.frontend.productionSource(.{ .dist = "frontend/dist" }),
            .source_fn = source,
            .start_fn = start,
            .event_fn = event,
            .stop_fn = stop,
        };
    }

    fn source(context: *anyopaque) anyerror!native_sdk.WebViewSource {
        const self: *@This() = @ptrCast(@alignCast(context));
        return native_sdk.frontend.sourceFromEnv(self.env_map, .{
            .dist = "frontend/dist",
            .entry = "index.html",
        });
    }

    fn start(context: *anyopaque, native_runtime: *native_sdk.Runtime) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.native_runtime = native_runtime;
        self.platform_services = native_runtime.options.platform.services;
        self.automation.start(native_runtime);
    }

    fn stop(context: *anyopaque, native_runtime: *native_sdk.Runtime) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (self.dispatcher) |dispatcher| dispatcher.stopIngress();
        self.automation.stop();
        if (self.workbench) |workbench| workbench.shutdownExecutor();
        if (self.agent_runtime) |agent_runtime| {
            try agent_runtime.shutdown();
            self.agent_shutdown = true;
        }
        self.drainAgentEvents();
        if (self.workbench) |workbench| workbench.syncLifecycle();
        if (self.dispatcher) |dispatcher| {
            dispatcher.breakConnection();
            dispatcher.assertQuiescent();
            dispatcher.detachWorkbench();
        }
        self.workbench = null;
        self.platform_services = null;
        if (self.native_runtime == native_runtime) self.native_runtime = null;
    }

    fn event(
        context: *anyopaque,
        native_runtime: *native_sdk.Runtime,
        value: native_sdk.Event,
    ) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        _ = native_runtime;
        switch (value) {
            .effects_wake => {
                self.drainAgentEvents();
                if (self.dispatcher) |dispatcher| if (dispatcher.connectedWindow()) |window_id| {
                    try self.automation.onEffectsWake(window_id);
                    try dispatcher.emitWorkbenchChanged();
                };
            },
            .timer => |timer| if (self.automation.onTimer(
                timer.id,
                native_sdk.monotonicNanoseconds(),
            )) {
                return;
            } else if (self.dispatcher != null and self.dispatcher.?.onTimer(timer.id)) {
                try self.dispatcher.?.emitWorkbenchChanged();
            },
            else => {},
        }
    }

    fn bridge(self: *@This(), mode: FrontendMode) native_sdk.BridgeDispatcher {
        var automation_handlers: [automation_api.handler_count]native_sdk.bridge.Handler = undefined;
        self.automation.fillHandlers(&automation_handlers);
        return (self.dispatcher orelse @panic("Bridge Dispatcher is not composed")).register(
            self.automation.productPolicy(bridge_api.policy.product(mode)),
            &automation_handlers,
        ) catch @panic("Bridge handler registry capacity is invalid");
    }

    fn drainAgentEvents(self: *@This()) void {
        const agent_runtime = self.agent_runtime orelse return;
        self.agent_event_wake_pending.store(false, .release);
        self.drainAgentEventPass(agent_runtime);
        const workbench = self.workbench orelse return;
        // Terminal publication happens after the synchronous AgentCore Run
        // returns, so its acquire observes all callback event enqueues. Drain
        // once more after that observation before exposing product terminal
        // state and the final assistant suffix; otherwise a queued callback
        // could lose the race to lifecycle publication or a snapshot.
        workbench.markTerminalRunsBeforeEventDrain();
        self.drainAgentEventPass(agent_runtime);
        workbench.finalizeMarkedTerminalRunsAfterEventDrain();
    }

    fn drainAgentEventPass(
        self: *@This(),
        agent_runtime: *agent.Runtime,
    ) void {
        while (agent_runtime.takeEvent()) |value| {
            var envelope = value;
            defer envelope.deinit();
            if (self.workbench) |workbench| workbench.applyEvent(&envelope) catch {
                agent_runtime.requestRunTermination(
                    envelope.session_id,
                    envelope.run_id,
                    .{ .event_pump_failure = .consumer_rejected },
                ) catch {};
            };
        }
    }

    fn notifyMainLoop(context: ?*anyopaque) bool {
        const self: *@This() = @ptrCast(@alignCast(context orelse return false));
        const services = self.platform_services orelse return false;
        services.wake() catch return false;
        return true;
    }

    fn notifyAgentEventConsumer(context: ?*anyopaque) agent.EventReadyNotification {
        const self: *@This() = @ptrCast(@alignCast(context orelse return .unavailable));
        if (self.agent_event_wake_pending.swap(true, .acq_rel)) return .already_pending;
        if (notifyMainLoop(context)) return .scheduled;
        self.agent_event_wake_pending.store(false, .release);
        return .unavailable;
    }

    fn dispatcherPlatform(self: *@This()) bridge_api.DispatcherPlatform {
        return .{
            .context = self,
            .wake_fn = platformWake,
            .emit_fn = platformEmit,
            .start_timer_fn = platformStartTimer,
            .cancel_timer_fn = platformCancelTimer,
            .show_open_dialog_fn = platformShowOpenDialog,
            .show_message_dialog_fn = platformShowMessageDialog,
            .now_fn = platformNow,
            .on_main_thread_fn = platformOnMainThread,
        };
    }

    fn dispatcherAutomation(self: *@This()) bridge_api.DispatcherAutomationHooks {
        return .{
            .context = self,
            .active_fn = automationActive,
            .before_connect_fn = automationBeforeConnect,
            .connect_fn = automationConnect,
            .detach_fn = automationDetach,
        };
    }

    fn platformWake(context: ?*anyopaque) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        try (self.platform_services orelse return error.RuntimeUnavailable).wake();
    }

    fn platformEmit(
        context: ?*anyopaque,
        window_id: native_sdk.platform.WindowId,
        name: []const u8,
        detail: []const u8,
    ) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        try (self.native_runtime orelse return error.RuntimeUnavailable).emitWindowEvent(
            window_id,
            name,
            detail,
        );
    }

    fn platformStartTimer(
        context: ?*anyopaque,
        timer_id: u64,
        interval_ns: u64,
        repeats: bool,
    ) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        try (self.platform_services orelse return error.RuntimeUnavailable).startTimer(
            timer_id,
            interval_ns,
            repeats,
        );
    }

    fn platformCancelTimer(context: ?*anyopaque, timer_id: u64) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        try (self.platform_services orelse return error.RuntimeUnavailable).cancelTimer(timer_id);
    }

    fn platformShowOpenDialog(
        context: ?*anyopaque,
        options: native_sdk.platform.OpenDialogOptions,
        output: []u8,
    ) anyerror!native_sdk.platform.OpenDialogResult {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        return (self.platform_services orelse return error.RuntimeUnavailable).showOpenDialog(
            options,
            output,
        );
    }

    fn platformShowMessageDialog(
        context: ?*anyopaque,
        options: native_sdk.platform.MessageDialogOptions,
    ) anyerror!native_sdk.platform.MessageDialogResult {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        return (self.platform_services orelse return error.RuntimeUnavailable).showMessageDialog(
            options,
        );
    }

    fn platformNow(_: ?*anyopaque) u64 {
        return native_sdk.monotonicNanoseconds();
    }

    fn platformOnMainThread(context: ?*anyopaque) bool {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        return std.Thread.getCurrentId() == self.main_thread_id;
    }

    fn automationActive(context: ?*anyopaque) bool {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        return self.automation.active();
    }

    fn automationBeforeConnect(context: ?*anyopaque, now_ns: u64) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        try self.automation.beforeConnect(now_ns);
    }

    fn automationConnect(context: ?*anyopaque, generation: u64) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        try self.automation.connectAt(generation);
    }

    fn automationDetach(context: ?*anyopaque, generation: u64, now_ns: u64) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        try self.automation.detach(generation, now_ns);
    }

    fn breakProductConnectionForAutomation(context: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(context orelse return));
        if (self.dispatcher) |dispatcher| dispatcher.breakConnection();
    }
};

fn providerKind(value: []const u8) ?workbench_api.Provider {
    if (std.mem.eql(u8, value, "anthropic")) return .anthropic;
    if (std.mem.eql(u8, value, "openai")) return .openai;
    if (std.mem.eql(u8, value, "gemini")) return .gemini;
    return null;
}

fn frontendMode(env_map: *std.process.Environ.Map) FrontendMode {
    return if (env_map.get(frontend_url_env) != null) .development else .release;
}

fn createAgentRuntime(io: std.Io, notifier: agent.EventReadyNotifier) !*agent.Runtime {
    return agent.Runtime.init(io, std.heap.c_allocator, .{
        .max_sessions = 8,
        .max_ui_request_bytes = pending_ui_json_capacity,
        .max_terminal_diagnostic_bytes = terminal_diagnostic_capacity,
        .event_ready_notifier = notifier,
        .event_ready_retry_interval = agent_event_retry_interval,
        .event_ready_timeout = agent_event_notification_timeout,
    });
}

pub fn run(init: std.process.Init) !void {
    var app = App{
        .env_map = init.environ_map,
        .main_thread_id = std.Thread.getCurrentId(),
        .automation = try automation_api.Runtime.init(
            std.heap.c_allocator,
            init.environ_map,
            std.Thread.getCurrentId(),
        ),
    };
    defer app.automation.deinit();

    const agent_runtime = try createAgentRuntime(init.io, .{
        .context = &app,
        .notify_fn = App.notifyAgentEventConsumer,
    });
    app.agent_runtime = agent_runtime;
    var workbench_initialized = false;
    var workbench: workbench_api.Workbench = undefined;
    defer {
        if (workbench_initialized) workbench.shutdownExecutor();
        if (!app.agent_shutdown) agent_runtime.shutdown() catch {};
        if (workbench_initialized) workbench.deinit();
        agent_runtime.deinit();
    }

    const credential = init.environ_map.get("METAWORK_PROVIDER_API_KEY") orelse "";
    const model = init.environ_map.get("METAWORK_PROVIDER_MODEL") orelse "";
    const provider = providerKind(
        init.environ_map.get("METAWORK_PROVIDER_KIND") orelse "anthropic",
    ) orelse return error.UnsupportedProvider;
    workbench = try workbench_api.Workbench.init(
        std.heap.c_allocator,
        agent_runtime,
        .{
            .worker_count = host_worker_count,
            .queue_capacity = 8,
            .max_pending_ui_json_bytes = pending_ui_json_capacity,
            .max_pending_ui_requests = host_worker_count,
            .max_terminal_diagnostic_bytes = terminal_diagnostic_capacity,
            .max_snapshot_bytes = workbench_snapshot_capacity,
        },
        .{
            .execution = .{
                .provider = provider,
                .credential = credential,
                .model = model,
                .base_url = init.environ_map.get("METAWORK_PROVIDER_BASE_URL") orelse "",
            },
            .change_notifier = .{ .context = &app, .wake = App.notifyMainLoop },
        },
    );
    workbench_initialized = true;
    app.workbench = &workbench;

    var dispatcher = try bridge_api.Dispatcher.init(
        std.heap.c_allocator,
        &workbench,
        app.dispatcherPlatform(),
        app.dispatcherAutomation(),
    );
    defer dispatcher.deinit();
    app.dispatcher = &dispatcher;
    app.automation.bind(dispatcher.callbackGate(), dispatcher.productDelivery(), .{
        .context = &app,
        .break_product_connection_fn = App.breakProductConnectionForAutomation,
    });
    const mode = frontendMode(init.environ_map);

    try runner.runWithOptions(app.app(), .{
        .app_name = "MetaWork",
        .window_title = "MetaWork",
        .bundle_id = "dev.metawork.desktop",
        .bridge = app.bridge(mode),
        .builtin_bridge = app.automation.builtinPolicy(bridge_api.policy.builtin(mode)),
        .js_window_api = true,
        .security = .{
            .permissions = &bridge_api.policy.window_permissions,
            .navigation = .{
                .allowed_origins = app.automation.allowedOrigins(bridge_api.policy.origins(mode)),
            },
        },
    }, init);
}

test "App remains a composition root with explicit platform limits" {
    try std.testing.expectEqual(@as(usize, 1024 * 1024), native_sdk.bridge.max_message_bytes);
    try std.testing.expectEqual(@as(usize, 8192), native_sdk.platform.max_window_event_detail_bytes);
    try std.testing.expectEqual(@as(usize, 1), bridge_api.policy.origins(.release).len);
    try std.testing.expectEqual(workbench_api.Provider.anthropic, providerKind("anthropic").?);
    try std.testing.expect(providerKind("unsupported") == null);
}
