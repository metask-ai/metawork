const std = @import("std");
const builtin = @import("builtin");
const runner = @import("runner");
const native_sdk = @import("native_sdk");
const bridge_api = @import("metawork_bridge");
const automation_api = @import("metawork_automation");
const agent = @import("metawork_agent");
const workbench_api = @import("metawork_workbench");
const account_contract = @import("metawork_account_contract");
const account_api = @import("metawork_account");
const product_identity = @import("metawork_product_identity");
const mcp_platform = @import("metawork_mcp_platform");
const window_chrome = @import("native_sdk_compat/system_webview_drag_region.zig");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const frontend_url_env = "NATIVE_SDK_FRONTEND_URL";
const frontend_dist = "frontend/dist";
const frontend_entry = "index.html";
const pending_ui_json_capacity = 256 * 1024;
const terminal_diagnostic_capacity = 512;
const agent_event_retry_interval: std.Io.Duration = .fromMilliseconds(5);
const agent_event_notification_timeout: std.Io.Duration = .fromMilliseconds(50);
const host_worker_count = 4;
const workbench_snapshot_capacity = bridge_api.snapshot_max_bytes;
const scheduled_task_timer_id: u64 = 0x4d57_5343_4844_544b;
const FrontendMode = bridge_api.policy.Mode;
const main_window_id: native_sdk.platform.WindowId = 1;
const tray_open_id: native_sdk.platform.TrayItemId = 1;
const tray_quit_id: native_sdk.platform.TrayItemId = 2;
const tray_items = [_]native_sdk.platform.TrayMenuItem{
    .{ .id = tray_open_id, .label = "Open MetaWork", .command = "metawork.tray.open" },
    .{ .separator = true },
    .{ .id = tray_quit_id, .label = "Quit MetaWork", .command = "metawork.tray.quit" },
};
const windows_data_directory_name = "MetaWork";
const mcp_runtime_limits: agent.McpRuntimeLimits = .{};

const mcp_configuration_limits: workbench_api.McpConfigurationLimits = .{
    .max_servers = 64,
    .max_tools_per_server = 1024,
    .max_namespace_bytes = 24,
    .max_credential_locators = 4096,
    .max_credential_secret_bytes = native_sdk.platform.max_credential_secret_bytes,
    .max_runtime_secrets_per_server = mcp_runtime_limits.max_secrets,
    .max_runtime_secret_bytes_per_server = mcp_runtime_limits.max_secret_bytes,
};

const McpStartupPreparation = struct {
    preparation: workbench_api.McpPreparedConfiguration,
    management_health: workbench_api.McpStoreHealth,
};

fn mcpManagementHealthAfterPreparation(
    state: workbench_api.McpPreparationState,
    recovery_health: workbench_api.McpStoreHealth,
) workbench_api.McpStoreHealth {
    return switch (state) {
        .empty, .available => recovery_health,
        .unavailable => if (recovery_health == .outcome_unknown)
            .outcome_unknown
        else
            .recovery_required,
    };
}

fn bridgeWindowChromeEnvironment(value: window_chrome.Environment) bridge_api.WindowChromeEnvironment {
    return .{
        .generation = value.generation,
        .top = value.top,
        .left = value.left,
        .bottom = value.bottom,
        .right = value.right,
        .buttons_x = value.buttons_x,
        .buttons_y = value.buttons_y,
        .buttons_width = value.buttons_width,
        .buttons_height = value.buttons_height,
        .live_pointer_drag = value.live_pointer_drag,
    };
}

fn platformDataDirectoryName(os_tag: @TypeOf(builtin.os.tag)) []const u8 {
    return if (os_tag == .macos)
        product_identity.macos_data_directory_name
    else
        windows_data_directory_name;
}

const ExecutionReplacement = enum { none, default, identity };

const AccountCoordinator = struct {
    runtime: *account_api.Runtime,
    workbench: *workbench_api.Workbench,
    main_thread_id: std.Thread.Id,

    fn init(
        runtime: *account_api.Runtime,
        workbench: *workbench_api.Workbench,
        main_thread_id: std.Thread.Id,
    ) AccountCoordinator {
        return .{
            .runtime = runtime,
            .workbench = workbench,
            .main_thread_id = main_thread_id,
        };
    }

    fn commandSink(self: *AccountCoordinator) account_contract.AccountCommandSink {
        return .{ .context = self, .submit_fn = submitCommand };
    }

    fn submitCommand(
        context: *anyopaque,
        command: account_contract.AccountCommand,
    ) account_contract.AccountCommandResult {
        const self: *AccountCoordinator = @ptrCast(@alignCast(context));
        self.assertMainThread();
        const replacement: ExecutionReplacement = switch (command) {
            .select_model => .default,
            .reauthenticate, .logout => .identity,
            else => .none,
        };
        return switch (self.runtime.prepareCommand(command)) {
            .prepared => |prepared| self.commitPrepared(
                prepared,
                replacement,
            ),
            .rejected => |error_code| .rejected(error_code),
            .ignored_stale => unreachable,
        };
    }

    fn start(
        self: *AccountCoordinator,
        services: account_api.PlatformServices,
    ) void {
        self.assertMainThread();
        const result = self.commitPrepared(
            self.runtime.prepareStart(services),
            .identity,
        );
        std.debug.assert(result.accepted);
    }

    fn startAutomation(self: *AccountCoordinator) void {
        self.assertMainThread();
        const result = self.commitPrepared(
            self.runtime.prepareAutomationStart(),
            .identity,
        );
        std.debug.assert(result.accepted);
    }

    fn startUnavailable(self: *AccountCoordinator) void {
        self.assertMainThread();
        const result = self.commitPrepared(
            self.runtime.prepareStartUnavailable(),
            .identity,
        );
        std.debug.assert(result.accepted);
    }

    fn onTimer(self: *AccountCoordinator, timer_id: u64) bool {
        self.assertMainThread();
        const prepared_result = self.runtime.prepareTimer(timer_id) orelse
            return false;
        switch (prepared_result) {
            .prepared => |prepared| {
                const result = self.commitPrepared(prepared, .none);
                std.debug.assert(result.accepted);
            },
            .rejected, .ignored_stale => {},
        }
        return true;
    }

    fn drain(self: *AccountCoordinator) void {
        self.assertMainThread();
        while (self.runtime.prepareNextCompletion()) |result| {
            switch (result) {
                .prepared => |prepared| {
                    const committed = self.commitPrepared(prepared, .none);
                    std.debug.assert(committed.accepted);
                },
                .rejected, .ignored_stale => {},
            }
        }
    }

    fn commitPrepared(
        self: *AccountCoordinator,
        prepared_value: account_api.Prepared,
        replacement: ExecutionReplacement,
    ) account_contract.AccountCommandResult {
        var prepared = prepared_value;
        defer prepared.deinit();

        switch (replacement) {
            .none => {},
            .default => self.workbench.beginDefaultExecutionReplacement() catch
                return .rejected(.execution_in_use),
            .identity => self.workbench.beginExecutionReplacement() catch
                return .rejected(.execution_in_use),
        }
        if (!self.runtime.admitEffect(&prepared)) {
            if (self.workbench.executionReplacementPending())
                self.workbench.endExecutionReplacementNoFail();
            return .rejected(.local_resource_exhausted);
        }

        const fact = self.runtime.preparedFact(&prepared);
        self.workbench.commitAccountFactNoFail(fact);
        if (prepared.takeExecution()) |execution_value| {
            var execution = execution_value;
            self.workbench.installExecutionNoFail(&execution);
        } else if (self.workbench.executionReplacementPending() and
            fact.view.operation == .none and
            fact.view.execution_state == .none)
        {
            self.workbench.clearExecutionNoFail();
        }
        self.runtime.commit(&prepared);
        if (self.workbench.executionReplacementPending() and
            fact.view.operation == .none)
            self.workbench.endExecutionReplacementNoFail();
        self.workbench.finishAccountCommitNoFail();

        const refresh_after_commit =
            self.runtime.takeRefreshAfterCommit(&prepared);
        const follow_up = self.runtime.takeFollowUpCommand(&prepared);
        self.runtime.dispatchCommitted(&prepared);

        if (refresh_after_commit) {
            const refreshed = self.commitPrepared(
                self.runtime.prepareRestoredRefresh(),
                .none,
            );
            std.debug.assert(refreshed.accepted);
        }
        if (follow_up) |command| self.submitFollowUp(command);
        return .acceptedAttempt(prepared.attemptId());
    }

    fn submitFollowUp(
        self: *AccountCoordinator,
        command: account_contract.AccountCommand,
    ) void {
        const result = submitCommand(self, command);
        if (result.accepted) return;
        switch (command) {
            .refresh_catalog => {
                const recovered = self.commitPrepared(
                    self.runtime.prepareContinuationFailure(
                        result.error_code,
                    ),
                    .none,
                );
                std.debug.assert(recovered.accepted);
            },
            else => {},
        }
    }

    fn shutdown(self: *AccountCoordinator) void {
        self.assertMainThread();
        const result = self.commitPrepared(
            self.runtime.prepareShutdown(),
            .none,
        );
        std.debug.assert(result.accepted);
    }

    fn assertMainThread(self: *const AccountCoordinator) void {
        std.debug.assert(std.Thread.getCurrentId() == self.main_thread_id);
    }
};
const App = struct {
    env_map: *std.process.Environ.Map,
    io: std.Io,
    frontend_asset_root: []const u8,
    main_thread_id: std.Thread.Id,
    automation: automation_api.Runtime = .{},
    dispatcher: ?*bridge_api.Dispatcher = null,
    agent_runtime: ?*agent.Runtime = null,
    workbench: ?*workbench_api.Workbench = null,
    agent_shutdown: bool = false,
    agent_event_wake_pending: std.atomic.Value(bool) = .init(false),
    native_runtime: ?*native_sdk.Runtime = null,
    platform_services: ?native_sdk.platform.PlatformServices = null,
    window_chrome_capability: window_chrome.Capability = window_chrome.Capability.init(main_window_id),
    tray_installed: bool = false,
    account_coordinator: ?*AccountCoordinator = null,
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
                .entry = frontend_entry,
            }),
            .source_fn = source,
            .start_fn = start,
            .event_fn = event,
            .stop_fn = stop,
        };
    }

    fn source(context: *anyopaque) anyerror!native_sdk.WebViewSource {
        const self: *@This() = @ptrCast(@alignCast(context));
        return native_sdk.frontend.sourceFromEnv(self.env_map, .{
            .dist = self.frontend_asset_root,
            .entry = frontend_entry,
        });
    }

    fn start(context: *anyopaque, native_runtime: *native_sdk.Runtime) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        try self.window_chrome_capability.captureStartupWindow();
        self.native_runtime = native_runtime;
        self.platform_services = native_runtime.options.platform.services;
        if (self.platform_services) |services|
            try self.window_chrome_capability.requirePlatform(services)
        else
            return error.SystemWebViewChromeUnavailable;
        self.mcp_credential_store = .{
            .io = self.io,
            .services = self.platform_services.?,
            .main_thread_id = self.main_thread_id,
        };
        const startup_preparation = try self.prepareMcpConfiguration();
        var preparation = startup_preparation.preparation;
        var preparation_owned = true;
        defer if (preparation_owned) preparation.deinit();
        var mcp_input: ?agent.McpRuntimeInput = null;
        defer if (mcp_input) |*input| input.deinit();
        var activation_failed = false;
        mcp_input = mcp_platform.buildRuntimeInput(
            self.io,
            std.heap.c_allocator,
            &preparation,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidConfig => failed: {
                activation_failed = true;
                break :failed null;
            },
        };
        const agent_runtime = try createAgentRuntime(
            self.io,
            .{
                .context = self,
                .notify_fn = App.notifyAgentEventConsumer,
            },
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
                .limits = mcp_configuration_limits,
                .initial_health = startup_preparation.management_health,
            } else null,
        };
        workbench_storage.* = try workbench_api.Workbench.init(
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
            configuration,
        );
        preparation_owned = false;
        activation = null;
        self.workbench = workbench_storage;
        self.workbench_initialized = true;
        try self.installScheduleHost();
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
        } else if (self.platform_services) |services| {
            coordinator.start(services);
        } else {
            coordinator.startUnavailable();
        }
        self.account_started = true;
        (self.dispatcher orelse @panic("Bridge Dispatcher is not composed")).startIngress();
    }

    fn prepareMcpConfiguration(self: *@This()) !McpStartupPreparation {
        const store = self.mcp_configuration_store orelse
            return .{
                .preparation = try workbench_api.prepareMcpConfiguration(
                    std.heap.c_allocator,
                    null,
                    false,
                    false,
                    .{},
                    mcp_configuration_limits,
                ),
                .management_health = .recovery_required,
            };
        const restored_bytes = store.loadAlloc(std.heap.c_allocator) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{
                .preparation = try workbench_api.prepareMcpConfiguration(
                    std.heap.c_allocator,
                    null,
                    true,
                    true,
                    .{},
                    mcp_configuration_limits,
                ),
                .management_health = .recovery_required,
            },
        };
        defer if (restored_bytes) |bytes| std.heap.c_allocator.free(bytes);
        var registry_corrupt = false;
        const generation: u64 = if (restored_bytes) |bytes| generation: {
            var decoded = workbench_api.decodeMcpRegistry(
                std.heap.c_allocator,
                bytes,
                mcp_configuration_limits,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    registry_corrupt = true;
                    break :generation 0;
                },
            };
            defer decoded.deinit();
            break :generation decoded.value.generation;
        } else 0;
        const credential_store = if (self.mcp_credential_store) |*value| value else return error.RuntimeUnavailable;
        var recovery_failed = registry_corrupt;
        var management_health: workbench_api.McpStoreHealth =
            if (registry_corrupt) .recovery_required else .ready;
        if (!registry_corrupt) {
            _ = store.recoverPendingCredentialTransaction(
                std.heap.c_allocator,
                generation,
                credential_store.cleanup(),
                mcp_configuration_limits,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.PersistenceOutcomeUnknown => {
                    recovery_failed = true;
                    management_health = .outcome_unknown;
                },
                else => {
                    recovery_failed = true;
                    management_health = .recovery_required;
                },
            };
        }
        const preparation = try workbench_api.prepareMcpConfiguration(
            std.heap.c_allocator,
            restored_bytes,
            true,
            recovery_failed,
            credential_store.resolver(),
            mcp_configuration_limits,
        );
        return .{
            .preparation = preparation,
            .management_health = mcpManagementHealthAfterPreparation(
                preparation.state,
                management_health,
            ),
        };
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
        if (self.tray_installed) {
            native_runtime.removeTray() catch {};
            self.tray_installed = false;
        }
        self.window_chrome_capability.deinit();
        self.workbench = null;
        self.account_started = false;
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
                if (timer.id == scheduled_task_timer_id) {
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
            .command => |command| if (command.source == .tray) switch (command.tray_item_id) {
                tray_open_id => self.showMainWindow(),
                tray_quit_id => self.requestExplicitQuit(),
                else => {},
            },
            else => {},
        }
    }

    fn installScheduleHost(self: *@This()) anyerror!void {
        const native_runtime = self.native_runtime orelse
            return error.RuntimeUnavailable;
        try native_runtime.createTray(.{
            .tooltip = "MetaWork",
            .items = &tray_items,
        });
        self.tray_installed = true;
        if (self.workbench) |workbench|
            workbench.setScheduleBackgroundAvailableNoFail(true);
    }

    fn showMainWindow(self: *@This()) void {
        const native_runtime = self.native_runtime orelse return;
        native_runtime.showWindow(main_window_id) catch return;
        native_runtime.focusWindow(main_window_id) catch {};
    }

    fn requestExplicitQuit(self: *@This()) void {
        const native_runtime = self.native_runtime orelse return;
        if (self.workbench) |workbench| if (workbench.hasEnabledScheduledTasks()) {
            const result = native_runtime.showMessageDialog(.{
                .style = .warning,
                .title = "Quit MetaWork?",
                .message = "Scheduled tasks will pause while MetaWork is not running.",
                .informative_text = "Closing the main window keeps them running. Use Quit only when you want to stop the background host.",
                .primary_button = "Keep Running",
                .secondary_button = "Quit MetaWork",
            }) catch return;
            if (result != .secondary) return;
        };
        native_runtime.closeWindow(main_window_id) catch {};
    }

    fn notifyScheduledTask(
        context: ?*anyopaque,
        notification: workbench_api.ScheduleNotification,
    ) bool {
        const self: *@This() = @ptrCast(@alignCast(context orelse return false));
        const services = self.platform_services orelse return false;
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

    fn bridge(self: *@This(), mode: FrontendMode) native_sdk.BridgeDispatcher {
        return (self.dispatcher orelse @panic("Bridge Dispatcher is not composed")).register(
            self.automation.productPolicy(bridge_api.policy.product(mode)),
        );
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
                workbench.recordEventProjectionFailure(
                    envelope.session_id,
                    envelope.run_id,
                );
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

    fn notifyAccountEffects(context: *anyopaque) void {
        if (!notifyMainLoop(context))
            @panic("Account completion lost its required main-loop wake");
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
            .window_chrome_connect_fn = platformWindowChromeConnect,
            .window_chrome_sync_fn = platformWindowChromeSync,
            .window_chrome_begin_drag_fn = platformWindowChromeBeginDrag,
            .window_chrome_disconnect_fn = platformWindowChromeDisconnect,
            .now_fn = platformNow,
            .on_main_thread_fn = platformOnMainThread,
        };
    }

    fn dispatcherAutomationAuthority(self: *@This()) bridge_api.DispatcherAutomationAuthority {
        return .{
            .context = self,
            .active_fn = automationActive,
            .workspace_root_fn = automationWorkspaceRoot,
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
        if (self.automation.active() and std.mem.eql(u8, name, bridge_api.product_event_name)) {
            std.debug.print("metawork.product_delivery.emit event={s} main_thread={}\n", .{
                name,
                std.Thread.getCurrentId() == self.main_thread_id,
            });
        }
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

    fn scheduledTaskNow(context: ?*anyopaque) ?u64 {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        const now = wallUnixSeconds(self.io) orelse return null;
        return @intCast(now);
    }

    fn armScheduledTaskTimer(
        context: ?*anyopaque,
        due_unix_seconds: u64,
    ) bool {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        const now = scheduledTaskNow(context) orelse return false;
        const delay_seconds = if (due_unix_seconds > now)
            due_unix_seconds - now
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

    fn cancelScheduledTaskTimer(context: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        if (self.platform_services) |services|
            services.cancelTimer(scheduled_task_timer_id) catch {};
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

    fn platformWindowChromeConnect(
        context: ?*anyopaque,
        window_id: native_sdk.platform.WindowId,
    ) anyerror!bridge_api.WindowChromeEnvironment {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        if (window_id != main_window_id) return error.WindowIdentityMismatch;
        return bridgeWindowChromeEnvironment(try self.window_chrome_capability.connect(
            self.platform_services orelse return error.RuntimeUnavailable,
        ));
    }

    fn platformWindowChromeSync(
        context: ?*anyopaque,
        window_id: native_sdk.platform.WindowId,
        generation: u64,
        viewport_width: f64,
        viewport_height: f64,
        regions: []const bridge_api.WindowChromeRegion,
    ) anyerror!bridge_api.WindowChromeEnvironment {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        if (window_id != main_window_id or regions.len > window_chrome.max_regions)
            return error.WindowIdentityMismatch;
        var chrome_regions: [window_chrome.max_regions]window_chrome.Region = undefined;
        for (regions, 0..) |region, index| chrome_regions[index] = .{
            .x = region.x,
            .y = region.y,
            .width = region.width,
            .height = region.height,
            .exclusion = region.exclusion,
        };
        return bridgeWindowChromeEnvironment(try self.window_chrome_capability.sync(
            self.platform_services orelse return error.RuntimeUnavailable,
            generation,
            viewport_width,
            viewport_height,
            chrome_regions[0..regions.len],
        ));
    }

    fn platformWindowChromeBeginDrag(
        context: ?*anyopaque,
        window_id: native_sdk.platform.WindowId,
        generation: u64,
        x: f64,
        y: f64,
    ) anyerror!bridge_api.WindowChromeEnvironment {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        if (window_id != main_window_id) return error.WindowIdentityMismatch;
        return bridgeWindowChromeEnvironment(try self.window_chrome_capability.beginLivePointerDrag(
            self.platform_services orelse return error.RuntimeUnavailable,
            generation,
            x,
            y,
        ));
    }

    fn platformWindowChromeDisconnect(
        context: ?*anyopaque,
        window_id: native_sdk.platform.WindowId,
        generation: u64,
    ) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        if (window_id != main_window_id) return error.WindowIdentityMismatch;
        try self.window_chrome_capability.disconnect(generation);
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

    fn automationWorkspaceRoot(context: ?*anyopaque) ?[]const u8 {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        return self.automation.workspaceRoot();
    }
};

fn wallUnixSeconds(io: std.Io) ?i64 {
    const nanoseconds = std.Io.Timestamp.now(io, .real).nanoseconds;
    if (nanoseconds < 0) return null;
    const seconds = @divFloor(nanoseconds, std.time.ns_per_s);
    if (seconds > std.math.maxInt(i64)) return null;
    return @intCast(seconds);
}

fn commitScheduledTaskStore(
    context: ?*anyopaque,
    bytes: []const u8,
) workbench_api.SchedulePersistenceCommit {
    const store: *workbench_api.ScheduledTaskFileStore = @ptrCast(
        @alignCast(context orelse return .failed),
    );
    store.commit(bytes) catch |err| return switch (err) {
        error.PersistenceOutcomeUnknown => .outcome_unknown,
        else => .failed,
    };
    return .committed;
}

fn commitTaskStore(
    context: ?*anyopaque,
    bytes: []const u8,
) workbench_api.TaskPersistenceCommit {
    const store: *workbench_api.TaskFileStore = @ptrCast(
        @alignCast(context orelse return .failed),
    );
    store.commit(bytes) catch |err| return switch (err) {
        error.PersistenceOutcomeUnknown => .outcome_unknown,
        else => .failed,
    };
    return .committed;
}

fn frontendMode(env_map: *std.process.Environ.Map) FrontendMode {
    return if (env_map.get(frontend_url_env) != null) .development else .release;
}

fn resolveFrontendAssetRoot(io: std.Io, allocator: std.mem.Allocator) ![]u8 {
    const executable_dir = try std.process.executableDirPathAlloc(io, allocator);
    defer allocator.free(executable_dir);

    const candidates = [_][]const []const u8{
        &.{ executable_dir, "frontend", "dist" },
        &.{ executable_dir, "..", "resources", "frontend", "dist" },
        &.{ executable_dir, "..", "Resources", "frontend", "dist" },
        &.{ executable_dir, "..", "..", "frontend", "dist" },
    };
    for (candidates) |segments| {
        const candidate = try std.fs.path.resolve(allocator, segments);
        if (frontendEntryExists(io, allocator, candidate)) return candidate;
        allocator.free(candidate);
    }
    return error.FrontendAssetsNotFound;
}

fn frontendEntryExists(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
) bool {
    const entry_path = std.fs.path.join(allocator, &.{ root, frontend_entry }) catch return false;
    defer allocator.free(entry_path);
    var file = std.Io.Dir.cwd().openFile(io, entry_path, .{}) catch return false;
    file.close(io);
    return true;
}

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

fn resolveCanonicalUserHome(
    io: std.Io,
    allocator: std.mem.Allocator,
    env_map: *std.process.Environ.Map,
) ?[]u8 {
    const configured = switch (builtin.os.tag) {
        .windows => env_map.get("USERPROFILE"),
        else => env_map.get("HOME"),
    } orelse return null;
    return resolveCanonicalDirectory(io, allocator, configured);
}

fn resolveCanonicalDirectory(
    io: std.Io,
    allocator: std.mem.Allocator,
    configured: []const u8,
) ?[]u8 {
    if (configured.len == 0 or !std.fs.path.isAbsolute(configured) or
        !std.unicode.utf8ValidateSlice(configured))
        return null;
    const canonical = std.Io.Dir.realPathFileAbsoluteAlloc(
        io,
        configured,
        allocator,
    ) catch return null;
    const stat = std.Io.Dir.cwd().statFile(io, canonical, .{}) catch {
        allocator.free(canonical);
        return null;
    };
    if (stat.kind != .directory) {
        allocator.free(canonical);
        return null;
    }
    return canonical;
}

pub fn run(init: std.process.Init) !void {
    const frontend_asset_root = if (init.environ_map.get(frontend_url_env) == null)
        try resolveFrontendAssetRoot(init.io, std.heap.c_allocator)
    else
        try std.heap.c_allocator.dupe(u8, frontend_dist);
    defer std.heap.c_allocator.free(frontend_asset_root);

    var app = App{
        .env_map = init.environ_map,
        .io = init.io,
        .frontend_asset_root = frontend_asset_root,
        .main_thread_id = std.Thread.getCurrentId(),
        .automation = automation_api.Runtime.init(init.environ_map),
    };
    defer app.window_chrome_capability.deinit();
    defer app.automation.deinit();
    var data_dir_storage: [4096]u8 = undefined;
    const data_dir = try native_sdk.app_dirs.resolveOne(
        .{ .name = platformDataDirectoryName(builtin.os.tag) },
        native_sdk.app_dirs.currentPlatform(),
        native_sdk.debug.envFromMap(init.environ_map),
        .data,
        &data_dir_storage,
    );
    var automatic_workspace_dir_storage: [4096]u8 = undefined;
    const automatic_workspace_dir = native_sdk.app_dirs.join(
        native_sdk.app_dirs.currentPlatform(),
        &automatic_workspace_dir_storage,
        &.{ data_dir, "workspaces" },
    ) catch null;
    var automatic_workspace_root: ?workbench_api.AutomaticWorkspaceRoot =
        if (automatic_workspace_dir) |directory|
            workbench_api.AutomaticWorkspaceRoot.open(
                init.io,
                std.heap.c_allocator,
                directory,
            ) catch null
        else
            null;
    defer if (automatic_workspace_root) |*root| root.deinit();
    var account_dir_storage: [4096]u8 = undefined;
    const account_dir = try native_sdk.app_dirs.join(
        native_sdk.app_dirs.currentPlatform(),
        &account_dir_storage,
        &.{ data_dir, "account" },
    );
    var scheduled_task_dir_storage: [4096]u8 = undefined;
    const scheduled_task_dir = try native_sdk.app_dirs.join(
        native_sdk.app_dirs.currentPlatform(),
        &scheduled_task_dir_storage,
        &.{ data_dir, "workbench" },
    );
    var skill_staging_dir_storage: [4096]u8 = undefined;
    const skill_staging_dir = try native_sdk.app_dirs.join(
        native_sdk.app_dirs.currentPlatform(),
        &skill_staging_dir_storage,
        &.{ scheduled_task_dir, "skill-staging" },
    );
    var mcp_dir_storage: [4096]u8 = undefined;
    const mcp_dir = try native_sdk.app_dirs.join(
        native_sdk.app_dirs.currentPlatform(),
        &mcp_dir_storage,
        &.{ data_dir, "mcp" },
    );
    var mcp_configuration_store: ?workbench_api.McpConfigurationFileStore =
        workbench_api.McpConfigurationFileStore.init(init.io, mcp_dir) catch null;
    defer if (mcp_configuration_store) |*store| store.deinit();
    app.mcp_configuration_store = if (mcp_configuration_store) |*store| store else null;
    var task_file_store: ?workbench_api.TaskFileStore =
        workbench_api.TaskFileStore.init(
            init.io,
            scheduled_task_dir,
        ) catch null;
    defer if (task_file_store) |*store| store.deinit();
    var task_restore_failed = task_file_store == null;
    const task_restored_bytes = if (task_file_store) |*store|
        store.loadAlloc(std.heap.c_allocator) catch restore: {
            task_restore_failed = true;
            break :restore null;
        }
    else
        null;
    defer if (task_restored_bytes) |bytes|
        std.heap.c_allocator.free(bytes);
    var scheduled_task_file_store: ?workbench_api.ScheduledTaskFileStore =
        workbench_api.ScheduledTaskFileStore.init(
            init.io,
            scheduled_task_dir,
        ) catch null;
    defer if (scheduled_task_file_store) |*store| store.deinit();
    var scheduled_task_restore_failed = scheduled_task_file_store == null;
    const scheduled_task_restored_bytes = if (scheduled_task_file_store) |*store|
        store.loadAlloc(std.heap.c_allocator) catch restore: {
            scheduled_task_restore_failed = true;
            break :restore null;
        }
    else
        null;
    defer if (scheduled_task_restored_bytes) |bytes|
        std.heap.c_allocator.free(bytes);
    var skill_management_file_store: ?workbench_api.SkillManagementFileStore =
        workbench_api.SkillManagementFileStore.init(
            init.io,
            scheduled_task_dir,
        ) catch null;
    defer if (skill_management_file_store) |*store| store.deinit();
    var skill_management_restore_failed = skill_management_file_store == null;
    const skill_management_restored_bytes = if (skill_management_file_store) |*store|
        store.loadAlloc(std.heap.c_allocator) catch restore: {
            skill_management_restore_failed = true;
            break :restore null;
        }
    else
        null;
    defer if (skill_management_restored_bytes) |bytes|
        std.heap.c_allocator.free(bytes);
    const canonical_user_home = if (app.automation.canonicalUserHome()) |home|
        resolveCanonicalDirectory(init.io, std.heap.c_allocator, home)
    else
        resolveCanonicalUserHome(
            init.io,
            std.heap.c_allocator,
            init.environ_map,
        );
    defer if (canonical_user_home) |home|
        std.heap.c_allocator.free(home);

    // AccountCoordinator and Dispatcher need stable Workbench addresses before
    // Native startup, but neither may dereference this storage while Bridge
    // ingress is closed. App.start initializes Workbench completely and only
    // then opens ingress, before the first Renderer window is loaded.
    var workbench: workbench_api.Workbench = undefined;
    app.workbench_storage = &workbench;
    app.workbench_configuration = .{
        .change_notifier = .{
            .context = &app,
            .wake = App.notifyMainLoop,
        },
        .directories = .{
            .canonical_user_home = canonical_user_home,
            .automatic_workspace_root = if (automatic_workspace_root) |*root|
                root
            else
                null,
        },
        .schedule_timer = .{
            .context = &app,
            .enabled = true,
            .now_unix_seconds = App.scheduledTaskNow,
            .arm = App.armScheduledTaskTimer,
            .cancel = App.cancelScheduledTaskTimer,
        },
        .schedule_persistence = .{
            .context = if (scheduled_task_file_store) |*store| store else null,
            .enabled = scheduled_task_file_store != null and
                !scheduled_task_restore_failed,
            .restored_bytes = scheduled_task_restored_bytes,
            .restore_failed = scheduled_task_restore_failed,
            .commit_fn = commitScheduledTaskStore,
        },
        .task_persistence = .{
            .context = if (task_file_store) |*store| store else null,
            .enabled = task_file_store != null and !task_restore_failed,
            .restored_bytes = task_restored_bytes,
            .restore_failed = task_restore_failed,
            .commit_fn = commitTaskStore,
        },
        .schedule_notifier = .{
            .context = &app,
            .enabled = true,
            .notify_fn = App.notifyScheduledTask,
        },
        .skill_management = .{
            .file_store = if (skill_management_file_store) |*store| store else null,
            .staging_root = skill_staging_dir,
            .restored_bytes = skill_management_restored_bytes,
            .restore_failed = skill_management_restore_failed,
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
        account_dir,
        .{
            .context = &app,
            .notify_fn = App.notifyAccountEffects,
        },
    );
    var account_coordinator = AccountCoordinator.init(
        &account_runtime,
        &workbench,
        app.main_thread_id,
    );
    app.account_coordinator = &account_coordinator;
    defer {
        app.account_coordinator = null;
        account_runtime.deinit();
    }

    var dispatcher = try bridge_api.Dispatcher.init(
        std.heap.c_allocator,
        &workbench,
        account_coordinator.commandSink(),
        app.dispatcherPlatform(),
        app.dispatcherAutomationAuthority(),
        main_window_id,
    );
    dispatcher.stopIngress();
    defer dispatcher.deinit();
    app.dispatcher = &dispatcher;
    const mode = frontendMode(init.environ_map);

    try app.window_chrome_capability.prepareStartup();
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

test "App remains a composition root with explicit platform limits" {
    try std.testing.expectEqual(@as(usize, 1024 * 1024), native_sdk.bridge.max_message_bytes);
    try std.testing.expectEqual(@as(usize, 8192), native_sdk.platform.max_window_event_detail_bytes);
    try std.testing.expectEqual(@as(usize, 1), bridge_api.policy.origins(.release).len);
}

test {
    _ = window_chrome;
}

test "MCP App composition keeps registry limits within AgentCore authority bounds" {
    std.testing.refAllDecls(App);
    comptime _ = run;
    try std.testing.expectEqual(@as(usize, 64), mcp_configuration_limits.max_servers);
    try std.testing.expectEqual(@as(usize, 1024), mcp_configuration_limits.max_tools_per_server);
    try std.testing.expectEqual(@as(usize, 24), mcp_configuration_limits.max_namespace_bytes);
    try std.testing.expectEqual(
        workbench_api.McpStoreHealth.recovery_required,
        mcpManagementHealthAfterPreparation(
            .{ .unavailable = .credential_store_unavailable },
            .ready,
        ),
    );
    try std.testing.expectEqual(
        workbench_api.McpStoreHealth.outcome_unknown,
        mcpManagementHealthAfterPreparation(
            .{ .unavailable = .read_failed },
            .outcome_unknown,
        ),
    );
}

test "product identity does not unify macOS and Windows Account storage" {
    try std.testing.expectEqualStrings(
        "com.metask.metawork.dev",
        product_identity.bundle_id,
    );
    try std.testing.expectEqualStrings(
        product_identity.macos_data_directory_name,
        platformDataDirectoryName(.macos),
    );
    try std.testing.expectEqualStrings(
        windows_data_directory_name,
        platformDataDirectoryName(.windows),
    );
}

test "App coordinator commits Account Runtime facts into Workbench" {
    const TestWake = struct {
        fn notify(_: *anyopaque) void {}
    };
    var wake_context: u8 = 0;
    var account_runtime = try account_api.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        std.Thread.getCurrentId(),
        if (builtin.os.tag == .windows)
            "C:\\metawork-account-coordinator-test"
        else
            "/tmp/metawork-account-coordinator-test",
        .{ .context = &wake_context, .notify_fn = TestWake.notify },
    );
    defer account_runtime.deinit();

    var agent_runtime: agent.Runtime = undefined;
    agent_runtime.io = std.testing.io;
    var workbench = try workbench_api.Workbench.init(
        std.testing.allocator,
        &agent_runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 1,
            .max_tasks = 1,
            .max_runs_per_task = 1,
            .max_tools_per_run = 1,
        },
        .{},
    );
    defer workbench.deinit();
    var coordinator = AccountCoordinator.init(
        &account_runtime,
        &workbench,
        std.Thread.getCurrentId(),
    );

    var execution = try account_contract.OwnedExecutionConfig.initOwned(
        std.testing.allocator,
        .anthropic,
        try std.testing.allocator.dupe(u8, "model-1"),
        try std.testing.allocator.dupe(
            u8,
            account_contract.metask_anthropic_messages_url,
        ),
        1,
        try std.testing.allocator.dupe(u8, "secret-key"),
    );
    defer execution.deinit();
    const restored = coordinator.commitPrepared(
        try account_api.TestSupport.prepareReadyRestore(
            &account_runtime,
            &execution,
        ),
        .identity,
    );
    try std.testing.expect(restored.accepted);
    try std.testing.expectEqual(
        account_contract.AccountSessionState.authenticated,
        account_runtime.view().session_state,
    );
    try std.testing.expectEqual(
        account_contract.ExecutionState.ready,
        account_runtime.view().execution_state,
    );
    try std.testing.expectEqual(
        account_contract.AccountSessionState.authenticated,
        workbench.accountView().session_state,
    );
    try std.testing.expect(workbench.accountView().can_create_task);

    coordinator.shutdown();
    try std.testing.expectEqual(
        account_contract.AccountSessionState.shutting_down,
        account_runtime.view().session_state,
    );
    try std.testing.expectEqual(
        account_contract.AccountSessionState.shutting_down,
        workbench.accountView().session_state,
    );
    try std.testing.expectEqual(
        account_contract.ExecutionState.none,
        workbench.accountView().execution_state,
    );
    try std.testing.expectEqual(@as(usize, 0), workbench.accountView().api_keys.len);
    try std.testing.expectEqual(@as(usize, 0), workbench.accountView().models.len);
    try std.testing.expect(!workbench.accountView().can_create_task);
}

test "App coordinator balances Workbench gate when Account effect admission fails" {
    const TestWake = struct {
        fn notify(_: *anyopaque) void {}
    };
    var wake_context: u8 = 0;
    var account_runtime = try account_api.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        std.Thread.getCurrentId(),
        if (builtin.os.tag == .windows)
            "C:\\metawork-account-admission-test"
        else
            "/tmp/metawork-account-admission-test",
        .{ .context = &wake_context, .notify_fn = TestWake.notify },
    );
    defer account_runtime.deinit();

    var agent_runtime: agent.Runtime = undefined;
    agent_runtime.io = std.testing.io;
    var workbench = try workbench_api.Workbench.init(
        std.testing.allocator,
        &agent_runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 1,
            .max_tasks = 1,
            .max_runs_per_task = 1,
            .max_tools_per_run = 1,
        },
        .{},
    );
    defer workbench.deinit();
    var coordinator = AccountCoordinator.init(
        &account_runtime,
        &workbench,
        std.Thread.getCurrentId(),
    );

    var execution = try account_contract.OwnedExecutionConfig.initOwned(
        std.testing.allocator,
        .anthropic,
        try std.testing.allocator.dupe(u8, "model-1"),
        try std.testing.allocator.dupe(
            u8,
            account_contract.metask_anthropic_messages_url,
        ),
        1,
        try std.testing.allocator.dupe(u8, "secret-key"),
    );
    defer execution.deinit();
    const restored = coordinator.commitPrepared(
        try account_api.TestSupport.prepareReadyRestore(
            &account_runtime,
            &execution,
        ),
        .identity,
    );
    try std.testing.expect(restored.accepted);
    const revision = workbench.currentRevision();

    account_api.TestSupport.occupyEffectQueue(&account_runtime);
    const rejected = coordinator.commandSink().submit(.logout);
    try std.testing.expect(!rejected.accepted);
    try std.testing.expectEqual(
        account_contract.ErrorCode.local_resource_exhausted,
        rejected.error_code,
    );
    try std.testing.expectEqual(
        account_contract.AccountSessionState.authenticated,
        account_runtime.view().session_state,
    );
    try std.testing.expect(workbench.accountView().can_create_task);
    try std.testing.expectEqual(revision, workbench.currentRevision());
    try std.testing.expect(!workbench.executionReplacementPending());

    account_api.TestSupport.clearEffectQueue(&account_runtime);
    coordinator.shutdown();
}
