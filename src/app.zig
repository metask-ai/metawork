const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");
const bridge_api = @import("metawork_bridge");
const agent = @import("metawork_agent");
const product_control = @import("metawork_product_control");
const models_contract = @import("metawork_product_models_contract");
const models_ports = @import("product_models_ports");
const mcp_configuration = @import("metawork_product_mcp").contract;
const account_api = @import("metawork_account");
const product_identity = @import("metawork_product_identity");
const mcp_platform = @import("metawork_mcp_platform");
const mcp_oauth = @import("metawork_mcp_oauth");
const account_coordinator = @import("app/account_coordinator.zig");
const account_platform_binding = @import("app/account_platform_binding.zig");
const models_coordinator = @import("models_coordinator");
const models_automation_vault = @import("app/models_automation_vault.zig");
const models_platform_binding = @import("app/models_platform_binding.zig");
const metask_http_transport = @import("app/metask_http_transport.zig");
const completion_http_transport = @import("app/completion_http_transport.zig");
const oauth_loopback_transport = @import("oauth_loopback_transport");
const agent_event_coordinator = @import("app/agent_event_coordinator.zig");
const app_automation = @import("app/automation.zig");
const frontend = @import("app/frontend.zig");
const mcp_startup = @import("app/mcp_startup.zig");
const mcp_bridge_adapter = @import("app/mcp_bridge_adapter.zig");
const mcp_oauth_coordinator = @import("app/mcp_oauth_coordinator.zig");
const mcp_management_coordinator = @import("app/mcp_management_coordinator.zig");
const app_paths = @import("app/paths.zig");
const app_platform = @import("app/platform.zig");
const attachment_images = @import("app/attachment_images.zig");
const app_single_instance = @import("app/single_instance_coordinator.zig");
const app_stores = @import("app/stores.zig");
const app_window = @import("app/window.zig");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

fn canonicalArchiveFile(io: std.Io, path: []const u8) ![]u8 {
    if (path.len == 0 or path.len > product_control.AttachmentArchiveTool.max_path_bytes or
        !std.fs.path.isAbsolute(path) or !std.unicode.utf8ValidateSlice(path) or
        std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidArchiveConfiguration;
    const canonical = try std.Io.Dir.realPathFileAbsoluteAlloc(io, path, std.heap.c_allocator);
    errdefer std.heap.c_allocator.free(canonical);
    const file = try std.Io.Dir.openFileAbsolute(io, canonical, .{});
    defer file.close(io);
    if ((try file.stat(io)).kind != .file) return error.InvalidArchiveConfiguration;
    return canonical;
}

const pending_ui_json_capacity = 256 * 1024;
const terminal_diagnostic_capacity = 512;
const agent_event_retry_interval: std.Io.Duration = .fromMilliseconds(5);
const agent_event_notification_timeout: std.Io.Duration = .fromMilliseconds(50);
// 16 concurrent executions: workers spend their lives blocked on network
// or on an indefinite UI wait, so the bound is about parallel model
// conversations, not CPU. Sized so approval-blocked runs cannot easily
// exhaust the pool.
const host_worker_count = 16;
const product_snapshot_capacity = bridge_api.snapshot_max_bytes;
const App = struct {
    env_map: *std.process.Environ.Map,
    io: std.Io,
    frontend_asset_root: []const u8,
    main_thread_id: std.Thread.Id,
    automation: app_automation.Adapter,
    platform: app_platform.Adapter,
    completion_transport: completion_http_transport.Backend,
    account_path: []const u8 = "",
    account_platform_binding: ?account_platform_binding.Adapter = null,
    models_platform_binding: ?models_platform_binding.Adapter = null,
    dispatcher: ?*bridge_api.Dispatcher = null,
    agent_runtime: ?*agent.Runtime = null,
    control: ?*product_control.Runtime = null,
    agent_shutdown: bool = false,
    agent_events: agent_event_coordinator.Coordinator = .{},
    account_coordinator: ?*account_coordinator.Coordinator = null,
    models_coordinator: ?*models_coordinator.Coordinator = null,
    automation_models_vault: ?*models_automation_vault.Vault = null,
    account_started: bool = false,
    models_started: bool = false,
    control_storage: ?*product_control.Runtime = null,
    control_configuration: product_control.Configuration = .{},
    control_initialized: bool = false,
    mcp_configuration_store: ?*mcp_configuration.FileStore = null,
    mcp_credential_store: ?mcp_platform.CredentialStore = null,
    mcp_authorizations: ?mcp_platform.HttpAuthorizations = null,
    mcp_management: ?mcp_management_coordinator.Coordinator = null,
    mcp_oauth_refresh: ?mcp_oauth_coordinator.Coordinator = null,
    single_instance: ?*app_single_instance.Coordinator = null,

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
        if (self.single_instance) |coordinator|
            if (coordinator.drain()) self.platform.activateMainWindow();
        self.mcp_credential_store = .{
            .io = self.io,
            .services = self.platform.services().?,
            .main_thread_id = self.main_thread_id,
        };
        const mcp_management_host = mcp_management_coordinator.platformHost(&self.platform);
        const mcp_host_environment = mcp_platform.HostEnvironment.fromProcess(self.env_map);
        const startup_preparation = try mcp_startup.prepare(
            self.mcp_configuration_store,
            if (self.mcp_credential_store) |*store| store else null,
        );
        var preparation = startup_preparation.preparation;
        var preparation_owned = true;
        defer if (preparation_owned) preparation.deinit();
        var runtime_manifest = try mcp_startup.emptyRuntimeManifest(std.heap.c_allocator);
        var runtime_manifest_owned = true;
        defer if (runtime_manifest_owned) runtime_manifest.deinit();
        const agent_runtime = try createAgentRuntime(
            self.io,
            self.agent_events.notifier(),
            null,
        );
        self.agent_runtime = agent_runtime;
        self.mcp_authorizations = .{ .allocator = std.heap.c_allocator };
        // Startup preparation may transiently own resolved credential bytes.
        // The empty Runtime cannot consume them, and Product Control must never
        // retain them; the normal apply coordinator resolves them again.
        preparation.releaseCredentials();
        const control_storage = self.control_storage orelse
            @panic("Product Control storage is not composed");
        var configuration = self.control_configuration;
        const custom_provider_capability_available =
            !self.automation.active() and
            self.platform.services() != null;
        configuration.custom_providers = .{
            .management = custom_provider_capability_available,
            .secret_capture = custom_provider_capability_available,
            .model_test = custom_provider_capability_available,
        };
        configuration.mcp = .{
            .preparation = &preparation,
            .activation = null,
            .activation_failed = false,
            .management = if (self.mcp_configuration_store) |store| .{
                .persistence = store.mutationPersistence(),
                .credentials = self.mcp_credential_store.?.effects(),
                .locator_generator = self.mcp_credential_store.?.locatorGenerator(),
                .identity_generator = self.mcp_credential_store.?.serverIdentityGenerator(),
                .limits = mcp_startup.configuration_limits,
                .initial_health = startup_preparation.management_health,
                .runtime_manifest = &runtime_manifest,
            } else null,
            .host_capabilities = .{
                .connection_approval = mcp_management_host.confirmation_available,
                .secret_capture = mcp_management_host.capture_available,
                .oauth = mcp_management_host.oauth_available and
                    mcp_management_host.confirmation_available,
            },
        };
        control_storage.* = try product_control.Runtime.init(
            std.heap.c_allocator,
            self.io,
            agent_runtime,
            .{
                .worker_count = host_worker_count,
                .queue_capacity = 8,
                .max_tasks = 50,
                .max_pending_ui_json_bytes = pending_ui_json_capacity,
                .max_pending_ui_requests = host_worker_count,
                .max_terminal_diagnostic_bytes = terminal_diagnostic_capacity,
                .max_snapshot_bytes = product_snapshot_capacity,
            },
            configuration,
        );
        preparation_owned = false;
        if (configuration.mcp.management != null) runtime_manifest_owned = false;
        self.control = control_storage;
        self.control_initialized = true;
        try self.platform.installScheduleHost(control_storage.scheduleHost());
        self.mcp_management = mcp_management_coordinator.Coordinator.init(
            std.heap.c_allocator,
            self.io,
            control_storage.mcpManagementPort(),
            agent_runtime,
            &self.mcp_credential_store.?,
            &self.mcp_authorizations.?,
            mcp_management_host,
            mcp_host_environment,
        );
        (self.dispatcher orelse @panic("Bridge Dispatcher is not composed")).attachMcpManagementHost(
            mcp_bridge_adapter.host(&self.mcp_management.?),
        );
        // Initial MCP connection and catalog discovery use the same complete
        // declarative apply transaction as later Desired mutations. No
        // external MCP effect remains on the Application readiness path.
        _ = self.mcp_management.?.applyConfiguration() catch {};
        self.mcp_oauth_refresh = mcp_oauth_coordinator.Coordinator.init(
            std.heap.c_allocator,
            self.io,
            control_storage.mcpOauthPort(),
            &self.mcp_credential_store.?,
            &self.mcp_authorizations.?,
            mcp_oauth_coordinator.platformHost(&self.platform),
        );
        self.mcp_oauth_refresh.?.start();
        const account = self.account_coordinator orelse
            @panic("Account coordinator is not composed");
        const models_management = self.models_coordinator orelse
            @panic("Models coordinator is not composed");
        models_management.setProbeNotifier(.{
            .context = &self.platform,
            .notify_fn = app_platform.Adapter.notifyRequired,
        });
        if (self.automation.active()) {
            const vault = self.automation_models_vault orelse
                @panic("automation Models vault is not composed");
            models_management.start(self.account_path, vault.port());
            self.models_started = true;
            account.startAutomation();
            if (self.automation.executionFixture()) |execution| {
                const control = self.control orelse
                    @panic("Product Control is not composed");
                control.installAutomationExecution(.{
                    .protocol = execution.protocol,
                    .credential = execution.credential,
                    .model = execution.model,
                    .base_url = execution.base_url,
                }) catch @panic(
                    "automation execution fixture is invalid",
                );
            }
        } else if (self.platform.services()) |services| {
            self.models_platform_binding = models_platform_binding.Adapter.init(
                services,
                self.io,
                self.main_thread_id,
            );
            self.account_platform_binding = account_platform_binding.Adapter.init(
                services,
                self.io,
                self.main_thread_id,
            ) catch null;
            models_management.start(
                self.account_path,
                self.models_platform_binding.?.ports(),
            );
            self.models_started = true;
            if (self.account_platform_binding) |*binding| {
                account.start(binding.ports());
            } else {
                account.startUnavailable();
            }
        } else {
            models_management.startUnavailable();
            self.models_started = true;
            account.startUnavailable();
        }
        self.account_started = true;
        (self.dispatcher orelse @panic("Bridge Dispatcher is not composed")).setModelsHost(.{
            .context = models_management,
            .refresh_catalog_fn = refreshModelsCatalog,
            .reset_store_fn = resetModelsStore,
        });
        (self.dispatcher orelse @panic("Bridge Dispatcher is not composed")).startIngress();
    }

    fn stop(context: *anyopaque, native_runtime: *native_sdk.Runtime) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (self.control) |control| control.beginShutdown();
        if (self.single_instance) |coordinator| coordinator.stopIngress();
        if (self.dispatcher) |dispatcher| dispatcher.stopIngress();
        if (self.account_started) if (self.account_coordinator) |coordinator|
            coordinator.beginShutdown();
        if (self.control) |control| {
            control.shutdownAttachmentStagingExecutor();
            control.stopFilePreviewAdmission();
            control.shutdownFilePreviewExecutor();
            control.shutdownFileChangeExecutor();
            if (self.dispatcher) |dispatcher| {
                control.drainFilePreviewCompletions(dispatcher.filePreviewSink());
                control.drainFileChangeCompletions(dispatcher.fileChangeDiffSink());
                dispatcher.settleAttachmentStagingForShutdown();
                dispatcher.settleFilePreviewsForShutdown();
                dispatcher.settleFileChangeDiffsForShutdown();
            }
        }
        if (self.dispatcher) |dispatcher| {
            // Synchronous ingress has returned and every asynchronous preview
            // responder has been settled above. Prove the Bridge boundary is
            // quiescent before the remaining owners begin shutdown.
            dispatcher.assertQuiescent();
            dispatcher.breakConnection();
            dispatcher.detachProductControl();
            dispatcher.setModelsHost(null);
        }
        if (self.mcp_management) |*coordinator| coordinator.shutdown();
        if (self.mcp_oauth_refresh) |*coordinator| coordinator.shutdown();
        if (self.models_started) if (self.models_coordinator) |coordinator| {
            coordinator.shutdown();
            coordinator.drain();
        };
        if (self.account_started) if (self.account_coordinator) |coordinator| {
            coordinator.shutdown();
            coordinator.drain();
        };
        if (self.account_platform_binding) |*binding| binding.deinit();
        self.account_platform_binding = null;
        self.models_platform_binding = null;
        if (self.control) |control| control.shutdownExecutor();
        if (self.agent_runtime) |agent_runtime| {
            try agent_runtime.shutdown();
            self.agent_shutdown = true;
        }
        self.drainAgentEvents();
        if (self.control) |control| {
            control.syncLifecycle();
            control.relinquishAgentSessionsAfterRuntimeShutdown();
        }
        self.platform.stop(native_runtime);
        self.control = null;
        self.account_started = false;
        self.models_started = false;
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
                if (self.single_instance) |coordinator|
                    if (coordinator.drain()) self.platform.activateMainWindow();
                if (self.account_coordinator) |coordinator|
                    coordinator.drain();
                if (self.models_coordinator) |coordinator|
                    coordinator.drain();
                if (self.mcp_oauth_refresh) |*coordinator|
                    if (!coordinator.drain()) coordinator.reconcileTimer();
                if (self.mcp_management) |*coordinator|
                    if (coordinator.drain())
                        if (self.mcp_oauth_refresh) |*refresh|
                            refresh.reconcileTimer();
                self.drainAgentEvents();
                if (self.control) |control|
                    if (self.dispatcher) |dispatcher| {
                        control.drainFilePreviewCompletions(
                            dispatcher.filePreviewSink(),
                        );
                        control.drainAttachmentStagingCompletions(
                            dispatcher.attachmentStagingSink(),
                        );
                        control.drainFileChangeCompletions(
                            dispatcher.fileChangeDiffSink(),
                        );
                    };
                if (self.dispatcher) |dispatcher| if (dispatcher.connectedWindow() != null) {
                    try dispatcher.emitProductChanged();
                };
            },
            .timer => |timer| {
                if (self.account_coordinator) |coordinator|
                    if (coordinator.onTimer(timer.id))
                        return;
                if (timer.id == app_platform.scheduled_task_timer_id) {
                    if (self.control) |control| {
                        control.onScheduledTaskTimer();
                        if (self.dispatcher) |dispatcher|
                            try dispatcher.emitProductChanged();
                    }
                    return;
                }
                if (timer.id == app_platform.mcp_catalog_timer_id) {
                    if (self.control) |control| {
                        control.onMcpRefreshTimer();
                        if (self.dispatcher) |dispatcher|
                            try dispatcher.emitProductChanged();
                    }
                    return;
                }
                if (timer.id == app_platform.mcp_oauth_timer_id) {
                    if (self.mcp_oauth_refresh) |*coordinator|
                        _ = coordinator.onTimer();
                    return;
                }
                if (self.dispatcher != null and
                    self.dispatcher.?.onTimer(timer.id))
                {
                    try self.dispatcher.?.emitProductChanged();
                }
            },
            .command => |command| if (command.source == .tray) {
                const result = self.platform.handleTrayCommand(command.tray_item_id);
                if (result == .quit_requested) {
                    if (self.single_instance) |coordinator| coordinator.stopIngress();
                    try self.platform.requestExplicitQuit();
                }
            },
            else => {},
        }
    }

    fn bridge(self: *@This(), mode: frontend.Mode) native_sdk.BridgeDispatcher {
        return (self.dispatcher orelse @panic("Bridge Dispatcher is not composed")).register(
            self.automation.productPolicy(bridge_api.policy.product(mode)),
        );
    }

    fn drainAgentEvents(self: *@This()) void {
        const control = self.control orelse return;
        self.agent_events.drain(control.agentEventConsumer());
    }
};

fn createAgentRuntime(
    io: std.Io,
    notifier: agent.EventReadyNotifier,
    mcp_input: ?*agent.McpRuntimeInput,
) !*agent.Runtime {
    return agent.Runtime.init(io, std.heap.c_allocator, .{
        .max_sessions = 50,
        .mcp_input = mcp_input,
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
        .io = init.io,
        .frontend_asset_root = "",
        .main_thread_id = std.Thread.getCurrentId(),
        .automation = app_automation.Adapter.init(init.environ_map),
        .platform = app_platform.Adapter.init(init.io, std.Thread.getCurrentId()),
        .completion_transport = .{
            .allocator = std.heap.c_allocator,
            .io = init.io,
        },
    };
    app.platform.setProductDeliveryTrace(app.automation.productDeliveryTraceEnabled());
    app.agent_events.bindWake(.{
        .context = &app.platform,
        .notify_fn = app_platform.Adapter.notifyMainLoop,
    });
    defer app.platform.deinit();
    defer app.automation.deinit();
    const builtin_skill_root = if (product_identity.artifact_kind != .release) root: {
        const root = init.environ_map.get("METAWORK_LOCAL_SKILL_ROOT") orelse break :root null;
        break :root try std.Io.Dir.realPathFileAbsoluteAlloc(init.io, root, std.heap.c_allocator);
    } else null;
    defer if (builtin_skill_root) |root| std.heap.c_allocator.free(root);
    const archive_tool: ?product_control.AttachmentArchiveTool = if (product_identity.artifact_kind != .release) configured: {
        const python = init.environ_map.get("METAWORK_LOCAL_ARCHIVE_PYTHON");
        const helper = init.environ_map.get("METAWORK_LOCAL_ARCHIVE_HELPER");
        if (python == null and helper == null) break :configured null;
        if (helper == null) return error.InvalidArchiveConfiguration;
        const python_path = if (python) |path| try canonicalArchiveFile(init.io, path) else null;
        errdefer if (python_path) |path| std.heap.c_allocator.free(path);
        const helper_path = try canonicalArchiveFile(init.io, helper.?);
        break :configured .{ .python = python_path, .helper = helper_path };
    } else null;
    defer if (archive_tool) |tool| {
        if (tool.python) |path| std.heap.c_allocator.free(path);
        std.heap.c_allocator.free(tool.helper);
    };
    var paths_state: app_paths.Paths = undefined;
    try paths_state.init(
        init.io,
        std.heap.c_allocator,
        init.environ_map,
        app.automation.canonicalUserHome(),
    );
    defer paths_state.deinit();
    app.account_path = paths_state.accountDir();
    var single_instance_state: app_single_instance.Coordinator = undefined;
    const disposition = try single_instance_state.init(
        init.io,
        std.heap.c_allocator,
        init.minimal.args,
        paths_state.dataDir(),
        product_identity.runnerBundleId(),
        .{
            .context = &app.platform,
            .notify_fn = app_platform.Adapter.notifyMainLoop,
        },
        product_identity.artifact_kind != .automation,
        product_identity.artifact_kind == .development and
            std.mem.eql(u8, init.environ_map.get("METAWORK_DEV_REQUIRE_PRIMARY") orelse "", "1"),
    );
    if (disposition == .secondary) return;
    app.single_instance = &single_instance_state;
    defer {
        app.single_instance = null;
        single_instance_state.deinit();
    }

    const frontend_asset_root = if (init.environ_map.get(frontend.url_env) == null)
        try frontend.resolveAssetRoot(init.io, std.heap.c_allocator)
    else
        try std.heap.c_allocator.dupe(u8, frontend.dist);
    defer std.heap.c_allocator.free(frontend_asset_root);
    app.frontend_asset_root = frontend_asset_root;

    var stores_state: app_stores.Stores = undefined;
    stores_state.init(init.io, std.heap.c_allocator, &paths_state);
    defer stores_state.deinit();
    app.mcp_configuration_store = if (stores_state.mcp_configuration) |*store| store else null;

    // The Application Account coordinator and Dispatcher need stable Product Control addresses before
    // Native startup, but neither may dereference this storage while Bridge
    // ingress is closed. App.start initializes Product Control completely and only
    // then opens ingress, before the first Renderer window is loaded.
    var control: product_control.Runtime = undefined;
    app.control_storage = &control;
    app.control_configuration = .{
        .change_notifier = .{
            .context = &app.platform,
            .wake = app_platform.Adapter.notifyMainLoop,
        },
        .directories = .{
            .canonical_user_home = paths_state.canonical_user_home,
            .automatic_workspace_system_root = paths_state.automaticWorkspaceSystemRoot(),
            .automatic_workspace_configuration_store = if (stores_state.automatic_workspace_configuration) |*store|
                store
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
        .run_clock = .{
            .context = &app.platform,
            .now_ms_fn = app_platform.Adapter.runNowMonotonicMs,
            .now_unix_ms_fn = app_platform.Adapter.runNowUnixMs,
        },
        .mcp_refresh_timer = .{
            .context = &app.platform,
            .enabled = true,
            .now_monotonic_ms = app_platform.Adapter.mcpCatalogNowMonotonicMs,
            .arm_at = app_platform.Adapter.armMcpCatalogTimer,
            .cancel = app_platform.Adapter.cancelMcpCatalogTimer,
        },
        .schedule_persistence = .{
            .context = if (stores_state.scheduled_task) |*store| store else null,
            .enabled = stores_state.scheduled_task != null,
            .restored_bytes = stores_state.scheduled_task_restored_bytes,
            .restore_failed = stores_state.scheduled_task_restore_failed,
            .commit_fn = app_stores.commitScheduledTaskStore,
            .recover_fn = app_stores.recoverScheduledTaskStore,
        },
        .task_persistence = .{
            .context = if (stores_state.task) |*store| store else null,
            .enabled = stores_state.task != null,
            .restored_bytes = stores_state.task_restored_bytes,
            .restore_failed = stores_state.task_restore_failed,
            .commit_fn = app_stores.commitTaskStore,
            .confirmed_commit_fn = app_stores.commitConfirmedTaskStore,
            .resolve_commit_fn = app_stores.resolveTaskStoreCommit,
            .recover_fn = app_stores.recoverTaskStore,
        },
        .checkpoint_store = .{
            .file_store = if (stores_state.checkpoint) |*store| store else null,
            .open_failed = stores_state.checkpoint_open_failed,
        },
        .attachment_store = if (stores_state.attachments) |*store| store else null,
        .attachment_images = .{ .context = &app.platform, .prepare_fn = attachment_images.prepare },
        .attachment_archive_tool = archive_tool,
        .file_change_store = .{
            .file_store = if (stores_state.file_change) |*store| store else null,
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
        .skill_enablement = .{
            .file_store = if (stores_state.skill_enablement) |*store| store else null,
            .restored_bytes = stores_state.skill_enablement_restored_bytes,
            .restore_failed = stores_state.skill_enablement_restore_failed,
        },
        .skill_sources = .{
            .file_store = if (stores_state.skill_sources) |*store| store else null,
            .restored = stores_state.skill_sources_restored,
        },
        .builtin_skill_root = builtin_skill_root,
        .completion_factory = .{
            .context = &app.completion_transport,
            .create_fn = completion_http_transport.Backend.createCompletion,
        },
    };
    defer {
        if (app.mcp_management) |*coordinator| {
            coordinator.deinit();
            app.mcp_management = null;
        }
        if (app.mcp_oauth_refresh) |*coordinator| {
            coordinator.deinit();
            app.mcp_oauth_refresh = null;
        }
        if (app.control_initialized) control.shutdownExecutor();
        if (app.agent_runtime) |runtime| {
            const shutdown_complete = if (app.agent_shutdown)
                true
            else shutdown: {
                runtime.shutdown() catch break :shutdown false;
                app.agent_shutdown = true;
                break :shutdown true;
            };
            if (app.control_initialized) {
                control.syncLifecycle();
                if (shutdown_complete)
                    control.relinquishAgentSessionsAfterRuntimeShutdown()
                else
                    control.abandonAgentSessionsForRuntimeDeinit();
                control.deinit();
            }
            if (app.mcp_authorizations) |*authorizations| {
                authorizations.deinit();
                app.mcp_authorizations = null;
            }
            runtime.deinit();
        }
    }
    var account_http = metask_http_transport.Adapter{
        .allocator = std.heap.c_allocator,
        .io = init.io,
    };
    var account_loopback = oauth_loopback_transport.Adapter.init(init.io);
    defer account_loopback.deinit();
    var account_runtime = account_api.Runtime.init(
        std.heap.c_allocator,
        init.io,
        app.main_thread_id,
        account_http.accountTransport(),
        account_loopback.endpoint(),
        .{
            .context = &app.platform,
            .notify_fn = app_platform.Adapter.notifyRequired,
        },
    );
    var account_coordinator_state = account_coordinator.Coordinator.init(
        &account_runtime,
        control.accountCommitSink(),
        app.main_thread_id,
    );
    var models_coordinator_state = models_coordinator.Coordinator.init(
        &account_runtime,
        account_http.modelsTransport(),
        control.modelsManagement(),
        app.main_thread_id,
        init.io,
    );
    var automation_models_vault_state: models_automation_vault.Vault = .{};
    app.automation_models_vault = &automation_models_vault_state;
    defer {
        // The vault contains borrowed execution authority. Stop Models before
        // zeroing it, including when Native startup fails before App.stop.
        if (app.models_started) {
            models_coordinator_state.shutdown();
            models_coordinator_state.drain();
            app.models_started = false;
        }
        app.automation_models_vault = null;
        automation_models_vault_state.deinit();
    }
    models_coordinator_state.setCompletionTransport(
        app.completion_transport.transport(),
    );
    control.setImageRunPreparation(models_coordinator_state.imageRunPreparation());
    defer control.setImageRunPreparation(null);
    account_coordinator_state.setCommitObserver(.{
        .context = &models_coordinator_state,
        .notify_fn = notifyModelsAuthorizationChanged,
    });
    app.account_coordinator = &account_coordinator_state;
    app.models_coordinator = &models_coordinator_state;
    defer {
        app.models_coordinator = null;
        app.account_coordinator = null;
        account_runtime.deinit();
    }

    var dispatcher = try bridge_api.Dispatcher.init(
        std.heap.c_allocator,
        &control,
        account_coordinator_state.commandSink(),
        models_coordinator_state.commandSink(),
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
        .bundle_id = product_identity.runnerBundleId(),
        .icon_path = "assets/icons/app-icon.png",
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

fn notifyModelsAuthorizationChanged(context: *anyopaque) void {
    const coordinator: *models_coordinator.Coordinator = @ptrCast(@alignCast(context));
    coordinator.authorizationChanged();
}

fn refreshModelsCatalog(context: *anyopaque) models_contract.CommandResult {
    const coordinator: *models_coordinator.Coordinator = @ptrCast(@alignCast(context));
    return coordinator.refreshCatalog();
}

fn resetModelsStore(context: *anyopaque, expected_revision: u64) models_contract.CommandResult {
    const coordinator: *models_coordinator.Coordinator = @ptrCast(@alignCast(context));
    return coordinator.resetModelsStore(expected_revision);
}

test "Application remains a composition root with explicit platform limits" {
    try std.testing.expectEqual(@as(usize, 1024 * 1024), native_sdk.bridge.max_message_bytes);
    try std.testing.expectEqual(@as(usize, 8192), native_sdk.platform.max_window_event_detail_bytes);
    try std.testing.expectEqual(@as(usize, 1), bridge_api.policy.origins(.release).len);
}

test "Windows window chrome Application test roots" {
    _ = app_window;
    _ = app_platform;
}

test "MCP Application composition imports the startup owner" {
    std.testing.refAllDecls(App);
    comptime _ = run;
    std.testing.refAllDecls(mcp_startup);
    std.testing.refAllDecls(mcp_oauth);
    std.testing.refAllDecls(mcp_management_coordinator);
}

test {
    std.testing.refAllDecls(account_coordinator);
    std.testing.refAllDecls(metask_http_transport);
    std.testing.refAllDecls(models_automation_vault);
    std.testing.refAllDecls(models_coordinator);
    std.testing.refAllDecls(attachment_images);
}

test "automation Models vault is bounded, overwrites securely, and deletes idempotently" {
    var vault: models_automation_vault.Vault = .{};
    defer vault.deinit();
    const port = vault.port();

    var slot_storage: [models_ports.credential_slot_bytes]u8 = undefined;
    const generated = try port.generateSlot(&slot_storage);
    try std.testing.expectEqualStrings(models_automation_vault.Vault.slot, generated);

    try port.store(generated, "fixture-secret-long");
    try port.store(generated, "short");
    try std.testing.expectEqualSlices(
        u8,
        &([_]u8{0} ** ("fixture-secret-long".len - "short".len)),
        vault.secret["short".len.."fixture-secret-long".len],
    );

    var output: [models_contract.Limits.credential_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("short", (try port.get(generated, &output)).?);
    try port.delete(generated);
    try std.testing.expect((try port.get(generated, &output)) == null);
    try std.testing.expectEqualSlices(
        u8,
        &([_]u8{0} ** "short".len),
        vault.secret[0.."short".len],
    );
    try port.delete(generated);
}
