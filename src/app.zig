const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");
const bridge_api = @import("metawork_bridge");
const agent = @import("metawork_agent");
const workbench_api = @import("metawork_workbench");
const account_api = @import("metawork_account");
const product_identity = @import("metawork_product_identity");
const mcp_platform = @import("metawork_mcp_platform");
const mcp_oauth = @import("metawork_mcp_oauth");
const account_coordinator = @import("app/account_coordinator.zig");
const agent_event_coordinator = @import("app/agent_event_coordinator.zig");
const app_automation = @import("app/automation.zig");
const frontend = @import("app/frontend.zig");
const mcp_startup = @import("app/mcp_startup.zig");
const app_paths = @import("app/paths.zig");
const app_platform = @import("app/platform.zig");
const app_stores = @import("app/stores.zig");
const app_window = @import("app/window.zig");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const pending_ui_json_capacity = 256 * 1024;
const terminal_diagnostic_capacity = 512;
const agent_event_retry_interval: std.Io.Duration = .fromMilliseconds(5);
const agent_event_notification_timeout: std.Io.Duration = .fromMilliseconds(50);
const host_worker_count = 4;
const workbench_snapshot_capacity = bridge_api.snapshot_max_bytes;
const App = struct {
    env_map: *std.process.Environ.Map,
    io: std.Io,
    frontend_asset_root: []const u8,
    main_thread_id: std.Thread.Id,
    automation: app_automation.Adapter,
    platform: app_platform.Adapter,
    dispatcher: ?*bridge_api.Dispatcher = null,
    agent_runtime: ?*agent.Runtime = null,
    workbench: ?*workbench_api.Workbench = null,
    agent_shutdown: bool = false,
    agent_events: agent_event_coordinator.Coordinator = .{},
    account_coordinator: ?*account_coordinator.Coordinator = null,
    account_started: bool = false,
    workbench_storage: ?*workbench_api.Workbench = null,
    workbench_configuration: workbench_api.Configuration = .{},
    workbench_initialized: bool = false,
    mcp_configuration_store: ?*workbench_api.McpConfigurationFileStore = null,
    mcp_credential_store: ?mcp_platform.CredentialStore = null,

    fn app(self: *@This()) native_sdk.App {
        return .{
            .context = self,
            .name = "metawork",
            .source = native_sdk.frontend.productionSource(.{
                .dist = self.frontend_asset_root,
                .entry = frontend.entry,
            }),
            .source_fn = source,
            .start_fn = start,
            .event_fn = event,
            .stop_fn = stop,
        };
    }

    fn source(context: *anyopaque) anyerror!native_sdk.WebViewSource {
        const self: *@This() = @ptrCast(@alignCast(context));
        return frontend.source(self.env_map, self.frontend_asset_root);
    }

    fn start(context: *anyopaque, native_runtime: *native_sdk.Runtime) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        try self.platform.start(native_runtime);
        self.mcp_credential_store = .{
            .io = self.io,
            .services = self.platform.services().?,
            .main_thread_id = self.main_thread_id,
        };
        const startup_preparation = try mcp_startup.prepare(
            self.mcp_configuration_store,
            if (self.mcp_credential_store) |*store| store else null,
        );
        var preparation = startup_preparation.preparation;
        var preparation_owned = true;
        defer if (preparation_owned) preparation.deinit();
        var mcp_input: ?agent.McpRuntimeInput = null;
        defer if (mcp_input) |*input| input.deinit();
        var runtime_manifest: ?workbench_api.McpRuntimeManifest = null;
        var runtime_manifest_owned = false;
        defer if (runtime_manifest_owned) runtime_manifest.?.deinit();
        var activation_failed = false;
        var input_construction_succeeded = true;
        mcp_input = mcp_platform.buildRuntimeInput(
            self.io,
            std.heap.c_allocator,
            &preparation,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidConfig => failed: {
                activation_failed = true;
                input_construction_succeeded = false;
                break :failed null;
            },
        };
        if (input_construction_succeeded) {
            runtime_manifest = try workbench_api.McpRuntimeManifest.candidate(
                std.heap.c_allocator,
                &preparation,
            );
            runtime_manifest_owned = runtime_manifest != null;
        }
        const agent_runtime = try createAgentRuntime(
            self.io,
            self.agent_events.notifier(),
            if (mcp_input) |*input| input else null,
        );
        self.agent_runtime = agent_runtime;
        var activation: ?*agent.McpActivation = null;
        defer if (activation) |value| value.deinit();
        switch (try agent_runtime.activateMcp()) {
            .empty => {},
            .activated => |value| activation = value,
            .unavailable => activation_failed = true,
        }
        preparation.releaseCredentials();
        const workbench_storage = self.workbench_storage orelse
            @panic("Workbench storage is not composed");
        var configuration = self.workbench_configuration;
        configuration.mcp = .{
            .preparation = &preparation,
            .activation = activation,
            .activation_failed = activation_failed,
            .management = if (self.mcp_configuration_store) |store| .{
                .persistence = store.mutationPersistence(),
                .credentials = self.mcp_credential_store.?.effects(),
                .locator_generator = self.mcp_credential_store.?.locatorGenerator(),
                .identity_generator = self.mcp_credential_store.?.serverIdentityGenerator(),
                .limits = mcp_startup.configuration_limits,
                .initial_health = startup_preparation.management_health,
                .runtime_manifest = if (runtime_manifest) |*manifest| manifest else null,
            } else null,
        };
        workbench_storage.* = try workbench_api.Workbench.init(
            std.heap.c_allocator,
            self.io,
            agent_runtime,
            .{
                .worker_count = host_worker_count,
                .queue_capacity = 8,
                .max_pending_ui_json_bytes = pending_ui_json_capacity,
                .max_pending_ui_requests = host_worker_count,
                .max_terminal_diagnostic_bytes = terminal_diagnostic_capacity,
                .max_snapshot_bytes = workbench_snapshot_capacity,
            },
            configuration,
        );
        preparation_owned = false;
        activation = null;
        if (configuration.mcp.management != null) runtime_manifest_owned = false;
        self.workbench = workbench_storage;
        self.workbench_initialized = true;
        try self.platform.installScheduleHost(workbench_storage);
        const coordinator = self.account_coordinator orelse
            @panic("Account coordinator is not composed");
        if (self.automation.active()) {
            coordinator.startAutomation();
            if (self.automation.executionFixture()) |execution| {
                const workbench = self.workbench orelse
                    @panic("Workbench is not composed");
                workbench.installAutomationExecution(.{
                    .provider = execution.provider,
                    .credential = execution.credential,
                    .model = execution.model,
                    .base_url = execution.base_url,
                }) catch @panic(
                    "automation execution fixture is invalid",
                );
            }
        } else if (self.platform.services()) |services| {
            coordinator.start(services);
        } else {
            coordinator.startUnavailable();
        }
        self.account_started = true;
        (self.dispatcher orelse @panic("Bridge Dispatcher is not composed")).startIngress();
    }

    fn stop(context: *anyopaque, native_runtime: *native_sdk.Runtime) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (self.dispatcher) |dispatcher| {
            dispatcher.stopIngress();
            // Native Bridge callbacks are synchronous on this same platform
            // loop. Prove the product ingress boundary is quiescent before
            // Workbench workers or Agent-owned transports begin shutdown.
            dispatcher.assertQuiescent();
            dispatcher.breakConnection();
            dispatcher.detachWorkbench();
        }
        if (self.account_started) if (self.account_coordinator) |coordinator| {
            coordinator.shutdown();
            coordinator.drain();
        };
        if (self.workbench) |workbench| workbench.shutdownExecutor();
        if (self.agent_runtime) |agent_runtime| {
            try agent_runtime.shutdown();
            self.agent_shutdown = true;
        }
        self.drainAgentEvents();
        if (self.workbench) |workbench| workbench.syncLifecycle();
        self.platform.stop(native_runtime);
        self.workbench = null;
        self.account_started = false;
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
                if (self.account_coordinator) |coordinator|
                    coordinator.drain();
                self.drainAgentEvents();
                if (self.dispatcher) |dispatcher| if (dispatcher.connectedWindow() != null) {
                    try dispatcher.emitWorkbenchChanged();
                };
            },
            .timer => |timer| {
                if (self.account_coordinator) |coordinator|
                    if (coordinator.onTimer(timer.id))
                        return;
                if (timer.id == app_platform.scheduled_task_timer_id) {
                    if (self.workbench) |workbench| {
                        workbench.onScheduledTaskTimer();
                        if (self.dispatcher) |dispatcher|
                            try dispatcher.emitWorkbenchChanged();
                    }
                    return;
                }
                if (self.dispatcher != null and
                    self.dispatcher.?.onTimer(timer.id))
                {
                    try self.dispatcher.?.emitWorkbenchChanged();
                }
            },
            .command => |command| if (command.source == .tray) if (self.workbench) |workbench|
                self.platform.handleTrayCommand(command.tray_item_id, workbench),
            else => {},
        }
    }

    fn bridge(self: *@This(), mode: frontend.Mode) native_sdk.BridgeDispatcher {
        return (self.dispatcher orelse @panic("Bridge Dispatcher is not composed")).register(
            self.automation.productPolicy(bridge_api.policy.product(mode)),
        );
    }

    fn drainAgentEvents(self: *@This()) void {
        const workbench = self.workbench orelse return;
        self.agent_events.drain(workbench);
    }
};

fn createAgentRuntime(
    io: std.Io,
    notifier: agent.EventReadyNotifier,
    mcp_input: ?*agent.McpRuntimeInput,
) !*agent.Runtime {
    return agent.Runtime.init(io, std.heap.c_allocator, .{
        .max_sessions = 8,
        .mcp_input = mcp_input,
        .max_ui_request_bytes = pending_ui_json_capacity,
        .max_terminal_diagnostic_bytes = terminal_diagnostic_capacity,
        .event_ready_notifier = notifier,
        .event_ready_retry_interval = agent_event_retry_interval,
        .event_ready_timeout = agent_event_notification_timeout,
    });
}

pub fn run(init: std.process.Init) !void {
    const frontend_asset_root = if (init.environ_map.get(frontend.url_env) == null)
        try frontend.resolveAssetRoot(init.io, std.heap.c_allocator)
    else
        try std.heap.c_allocator.dupe(u8, frontend.dist);
    defer std.heap.c_allocator.free(frontend_asset_root);

    var app = App{
        .env_map = init.environ_map,
        .io = init.io,
        .frontend_asset_root = frontend_asset_root,
        .main_thread_id = std.Thread.getCurrentId(),
        .automation = app_automation.Adapter.init(init.environ_map),
        .platform = app_platform.Adapter.init(init.io, std.Thread.getCurrentId()),
    };
    app.platform.setProductDeliveryTrace(app.automation.productDeliveryTraceEnabled());
    app.agent_events.bindWake(.{
        .context = &app.platform,
        .notify_fn = app_platform.Adapter.notifyMainLoop,
    });
    defer app.platform.deinit();
    defer app.automation.deinit();
    var paths_state: app_paths.Paths = undefined;
    try paths_state.init(
        init.io,
        std.heap.c_allocator,
        init.environ_map,
        app.automation.canonicalUserHome(),
    );
    defer paths_state.deinit();
    var stores_state: app_stores.Stores = undefined;
    stores_state.init(init.io, std.heap.c_allocator, &paths_state);
    defer stores_state.deinit();
    app.mcp_configuration_store = if (stores_state.mcp_configuration) |*store| store else null;

    // The Application Account coordinator and Dispatcher need stable Workbench addresses before
    // Native startup, but neither may dereference this storage while Bridge
    // ingress is closed. App.start initializes Workbench completely and only
    // then opens ingress, before the first Renderer window is loaded.
    var workbench: workbench_api.Workbench = undefined;
    app.workbench_storage = &workbench;
    app.workbench_configuration = .{
        .change_notifier = .{
            .context = &app.platform,
            .wake = app_platform.Adapter.notifyMainLoop,
        },
        .directories = .{
            .canonical_user_home = paths_state.canonical_user_home,
            .automatic_workspace_root = if (stores_state.automatic_workspace_root) |*root|
                root
            else
                null,
        },
        .schedule_timer = .{
            .context = &app.platform,
            .enabled = true,
            .now_unix_seconds = app_platform.Adapter.scheduledTaskNow,
            .arm = app_platform.Adapter.armScheduledTaskTimer,
            .cancel = app_platform.Adapter.cancelScheduledTaskTimer,
        },
        .schedule_persistence = .{
            .context = if (stores_state.scheduled_task) |*store| store else null,
            .enabled = stores_state.scheduled_task != null and
                !stores_state.scheduled_task_restore_failed,
            .restored_bytes = stores_state.scheduled_task_restored_bytes,
            .restore_failed = stores_state.scheduled_task_restore_failed,
            .commit_fn = app_stores.commitScheduledTaskStore,
        },
        .task_persistence = .{
            .context = if (stores_state.task) |*store| store else null,
            .enabled = stores_state.task != null and !stores_state.task_restore_failed,
            .restored_bytes = stores_state.task_restored_bytes,
            .restore_failed = stores_state.task_restore_failed,
            .commit_fn = app_stores.commitTaskStore,
        },
        .schedule_notifier = .{
            .context = &app.platform,
            .enabled = true,
            .notify_fn = app_platform.Adapter.notifyScheduledTask,
        },
        .skill_management = .{
            .file_store = if (stores_state.skill_management) |*store| store else null,
            .staging_root = paths_state.skillStagingDir(),
            .restored_bytes = stores_state.skill_management_restored_bytes,
            .restore_failed = stores_state.skill_management_restore_failed,
        },
    };
    defer {
        if (app.workbench_initialized) workbench.shutdownExecutor();
        if (app.agent_runtime) |runtime| {
            if (!app.agent_shutdown) runtime.shutdown() catch {};
            if (app.workbench_initialized) workbench.deinit();
            runtime.deinit();
        }
    }
    var account_runtime = try account_api.Runtime.init(
        std.heap.c_allocator,
        init.io,
        app.main_thread_id,
        paths_state.accountDir(),
        .{
            .context = &app.platform,
            .notify_fn = app_platform.Adapter.notifyRequired,
        },
    );
    var account_coordinator_state = account_coordinator.Coordinator.init(
        &account_runtime,
        &workbench,
        app.main_thread_id,
    );
    app.account_coordinator = &account_coordinator_state;
    defer {
        app.account_coordinator = null;
        account_runtime.deinit();
    }

    var dispatcher = try bridge_api.Dispatcher.init(
        std.heap.c_allocator,
        &workbench,
        account_coordinator_state.commandSink(),
        app.platform.dispatcherPlatform(),
        app.automation.dispatcherAuthority(),
        app_window.main_window_id,
    );
    dispatcher.stopIngress();
    defer dispatcher.deinit();
    app.dispatcher = &dispatcher;
    const mode = frontend.mode(init.environ_map);

    try app.platform.prepareStartup();
    try runner.runWithOptions(app.app(), .{
        .app_name = "MetaWork",
        .window_title = "MetaWork",
        .bundle_id = product_identity.bundle_id,
        .bridge = app.bridge(mode),
        .builtin_bridge = app.automation.builtinPolicy(bridge_api.policy.builtin(mode)),
        .js_window_api = false,
        .security = .{
            .permissions = &.{},
            .navigation = .{
                .allowed_origins = app.automation.allowedOrigins(bridge_api.policy.origins(mode)),
            },
        },
    }, init);
}

test "Application remains a composition root with explicit platform limits" {
    try std.testing.expectEqual(@as(usize, 1024 * 1024), native_sdk.bridge.max_message_bytes);
    try std.testing.expectEqual(@as(usize, 8192), native_sdk.platform.max_window_event_detail_bytes);
    try std.testing.expectEqual(@as(usize, 1), bridge_api.policy.origins(.release).len);
}

test "MCP Application composition imports the startup owner" {
    std.testing.refAllDecls(App);
    comptime _ = run;
    std.testing.refAllDecls(mcp_startup);
    std.testing.refAllDecls(mcp_oauth);
}
