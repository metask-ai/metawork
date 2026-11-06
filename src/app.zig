const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");
const bridge_api = @import("metawork_bridge");
const agent = @import("metawork_agent");
const output_file = @import("app_output_file");
const product_task = @import("metawork_product_task");
const product_workspace = @import("metawork_product_workspace");
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
const office_skills = @import("app/office_skills.zig");
const app_platform = @import("app/platform.zig");
const attachment_images = @import("app/attachment_images.zig");
const app_single_instance = @import("app/single_instance_coordinator.zig");
const app_stores = @import("app/stores.zig");
const app_window = @import("app/window.zig");
const product_update = @import("metawork_product_update");
const update_coordinator = @import("app/update_coordinator.zig");
const update_http = @import("app/update_http_transport.zig");

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
// 16 concurrent executions: workers spend their lives blocked on network
// or on an indefinite UI wait, so the bound is about parallel model
// conversations, not CPU. Sized so approval-blocked runs cannot easily
// exhaust the pool.
const host_worker_count = 16;
const product_snapshot_capacity = bridge_api.snapshot_max_bytes;

const FrozenFileDelivery = struct {
    io: std.Io,
    main_thread_id: std.Thread.Id,
    root: []u8,

    fn prepare(io: std.Io, main_thread_id: std.Thread.Id, root: []const u8) ?product_task.OwnedFileDelivery {
        if (std.Thread.getCurrentId() != main_thread_id) return null;
        const allocator = std.heap.c_allocator;
        const owned = allocator.dupe(u8, root) catch return null;
        const self = allocator.create(FrozenFileDelivery) catch {
            allocator.free(owned);
            return null;
        };
        self.* = .{ .io = io, .main_thread_id = main_thread_id, .root = owned };
        return .{ .input = .{ .context = self, .inspect_fn = inspect }, .release_fn = release };
    }

    fn inspect(context: *anyopaque, path: []const u8, cancelled: *const std.atomic.Value(bool)) agent.FileDeliveryInspection {
        const self: *FrozenFileDelivery = @ptrCast(@alignCast(context));
        const value = output_file.inspect(self.io, .{
            .workspace_root = self.root,
            .relative_path = path,
            .main_thread_id = self.main_thread_id,
        }, cancelled) catch |err| return .{ .failed = switch (err) {
            error.Cancelled, error.Canceled => .cancelled,
            error.FileNotFound => .missing,
            error.OutputTooLarge => .too_large,
            error.OutputChanged => .changed,
            error.InvalidOutputPath, error.InvalidWorkspaceRoot, error.NotRegularOutput, error.AccessDenied, error.SymLinkLoop, error.MainThreadFileEffect => .restricted,
            else => .read_failed,
        } };
        return .{ .verified = .{ .size_bytes = value.size_bytes, .sha256 = value.sha256 } };
    }

    fn release(context: *anyopaque) void {
        const self: *FrozenFileDelivery = @ptrCast(@alignCast(context));
        std.debug.assert(std.Thread.getCurrentId() == self.main_thread_id);
        std.heap.c_allocator.free(self.root);
        std.heap.c_allocator.destroy(self);
    }
};

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
    mcp_budget: ?*mcp_platform.CatalogBudget = null,
    mcp_oauth_refresh: ?mcp_oauth_coordinator.Coordinator = null,
    mcp_candidate_turn: bool = false,
    single_instance: ?*app_single_instance.Coordinator = null,
    update_transport: ?update_http.Adapter = null,
    updates: ?update_coordinator.Coordinator = null,
    history_restore_owner: ?*app_stores.Stores = null,

    fn prepareFileDelivery(context: *anyopaque, authority: product_workspace.TaskAuthority) ?product_task.OwnedFileDelivery {
        const self: *App = @ptrCast(@alignCast(context));
        return FrozenFileDelivery.prepare(self.io, self.main_thread_id, authority.canonical_root);
    }

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
            if (coordinator.bindWakeAndDrain(.{
                .context = &self.platform,
                .notify_fn = app_platform.Adapter.notifyMainLoop,
            })) self.platform.activateMainWindow();
        self.mcp_credential_store = .{
            .io = self.io,
            .runtime = native_runtime,
            .main_thread_id = self.main_thread_id,
        };
        const mcp_management_host = mcp_management_coordinator.platformHost(&self.platform);
        var mcp_host_environment = mcp_platform.HostEnvironment.fromProcess(self.env_map);
        const startup_preparation = try mcp_startup.prepare(
            self.mcp_configuration_store,
            if (self.mcp_credential_store) |*store| store else null,
        );
        var preparation = startup_preparation.preparation;
        if (preparation.recovery_diagnostic != .none)
            std.log.warn("MCP startup recovery: {s}", .{@tagName(preparation.recovery_diagnostic)});
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
        self.mcp_budget = try mcp_platform.CatalogBudget.init(std.heap.c_allocator, self.io, agent_runtime);
        mcp_host_environment.catalog_budget = self.mcp_budget;
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
        configuration.mcp_catalog = self.mcp_budget.?.catalog();
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
                .max_history_bytes = 256 * 1024 * 1024,
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
        self.control_configuration.task_persistence.restore_fn = null;
        if (self.history_restore_owner) |stores| stores.releaseTaskRestore();
        self.history_restore_owner = null;

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
        _ = self.mcp_management.?.applyConfiguration(.automatic) catch {};
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
        // run() only reserves Product storage; Runtime.init above must finish
        // before installing capabilities that initialization would overwrite.
        control_storage.setAccountProjectionCredentials(account.runtime.accessTokenProjection());
        control_storage.setImageRunPreparation(models_management.imageRunPreparation());
        control_storage.setMetaskAuthorizationCheck(models_management.metaskAuthorizationCheck());
        models_management.setCredentialRenewal(control_storage.metaskCredentialRenewal());
        control_storage.setFileDeliveryPreparation(.{ .context = self, .prepare_fn = prepareFileDelivery });
        control_storage.setOutputFileReveal(self.platform.outputFileReveal());
        control_storage.setOutputFileSave(self.platform.outputFileSave());
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
        } else if (self.platform.services() != null) {
            self.models_platform_binding = models_platform_binding.Adapter.init(
                native_runtime,
                self.io,
                self.main_thread_id,
            );
            self.account_platform_binding = account_platform_binding.Adapter.init(
                native_runtime,
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

        if (product_identity.artifact_kind != .automation) {
            const host = self.platform.dispatcherPlatform();
            self.update_transport = .{ .allocator = std.heap.c_allocator, .io = self.io };
            self.updates = .{
                .allocator = std.heap.c_allocator,
                .io = self.io,
                .management = control_storage.updateManagement(),
                .transport = self.update_transport.?.transport(),
                .host = .{ .context = host.context, .now_ns_fn = host.now_fn, .wake_fn = host.wake_fn, .start_timer_fn = host.start_timer_fn, .cancel_timer_fn = host.cancel_timer_fn, .open_fn = host.open_external_url_fn, .on_main_thread_fn = host.on_main_thread_fn },
            };
            self.updates.?.start(product_identity.automatic_update_checks);
            self.dispatcher.?.setUpdatesHost(.{ .context = self, .check_fn = requestUpdateCheck, .download_fn = requestUpdateDownload, .website_fn = openUpdateWebsite, .cancel_fn = cancelUpdateDownload });
        }
        (self.dispatcher orelse @panic("Bridge Dispatcher is not composed")).startIngress();
    }

    fn requestUpdateCheck(context: *anyopaque) product_update.CommandOutcome {
        const self: *App = @ptrCast(@alignCast(context));
        return if (self.updates) |*coordinator| coordinator.requestCheck() else .unavailable;
    }
    fn requestUpdateDownload(context: *anyopaque, expected_version: []const u8) product_update.CommandOutcome {
        const self: *App = @ptrCast(@alignCast(context));
        return if (self.updates) |*coordinator| coordinator.requestDownload(expected_version) else .unavailable;
    }
    fn openUpdateWebsite(context: *anyopaque) bool {
        const self: *App = @ptrCast(@alignCast(context));
        return if (self.updates) |*coordinator| coordinator.openWebsite() else false;
    }
    fn cancelUpdateDownload(context: *anyopaque) void {
        const self: *App = @ptrCast(@alignCast(context));
        if (self.updates) |*coordinator| coordinator.cancelDownload();
    }

    fn stop(context: *anyopaque, native_runtime: *native_sdk.Runtime) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (self.control) |control| control.beginShutdown();
        if (self.updates) |*coordinator| coordinator.shutdown();
        if (self.single_instance) |coordinator| coordinator.stopIngress();
        if (self.dispatcher) |dispatcher| dispatcher.stopIngress();
        if (self.account_started) if (self.account_coordinator) |coordinator|
            coordinator.beginShutdown();
        if (self.control) |control| {
            control.shutdownAttachmentStagingExecutor();
            control.stopFilePreviewAdmission();
            control.shutdownFilePreviewExecutor();
            control.shutdownOutputChecks();
            control.shutdownFileChangeExecutor();
            if (self.dispatcher) |dispatcher| {
                control.drainFilePreviewCompletions(dispatcher.filePreviewSink());
                control.drainOutputChecks(dispatcher.outputCheckSink());
                control.drainFileChangeCompletions(dispatcher.fileChangeDiffSink());
                dispatcher.settleAttachmentStagingForShutdown();
                dispatcher.settleFilePreviewsForShutdown();
                dispatcher.settleOutputActionsForShutdown();
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
            dispatcher.setUpdatesHost(null);
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
        // Required-wake producers are joined above. Release the relay and
        // platform references even if Agent shutdown reports an error.
        defer self.platform.stop(native_runtime);
        if (self.agent_runtime) |agent_runtime| {
            try agent_runtime.shutdown();
            self.agent_shutdown = true;
        }
        self.drainAgentEvents();
        if (self.control) |control| {
            control.syncLifecycle();
            control.relinquishAgentSessionsAfterRuntimeShutdown();
        }
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
                if (self.updates) |*coordinator| coordinator.drain();
                if (self.single_instance) |coordinator|
                    if (coordinator.drain()) self.platform.activateMainWindow();
                if (self.account_coordinator) |coordinator|
                    coordinator.drain();
                if (self.models_coordinator) |coordinator|
                    coordinator.drain();
                // Product consumes catalog completion before management can
                // observe the shared boundary and decide whether to advance.
                self.drainAgentEvents();
                if (self.mcp_oauth_refresh) |*coordinator| _ = coordinator.drain();
                self.advanceMcp();
                if (self.control) |control|
                    if (self.dispatcher) |dispatcher| {
                        control.drainFilePreviewCompletions(
                            dispatcher.filePreviewSink(),
                        );
                        control.drainOutputChecks(dispatcher.outputCheckSink());
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
                if (timer.id == update_coordinator.timer_id) {
                    if (self.updates) |*coordinator| coordinator.onTimer();
                    if (self.dispatcher) |dispatcher| try dispatcher.emitProductChanged();
                    return;
                }
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
            .command => |command| {
                if (command.source == .tray) {
                    const result = self.platform.handleTrayCommand(command.tray_item_id);
                    if (result == .quit_requested) {
                        if (self.single_instance) |coordinator| coordinator.stopIngress();
                        try self.platform.requestExplicitQuit();
                    }
                } else if (command.source == .notification and command.window_id == app_window.main_window_id) {
                    if (app_window.notificationTaskId(command.name)) |task_id| {
                        self.platform.activateMainWindow();
                        if (self.dispatcher) |dispatcher| try dispatcher.openTaskFromNotification(task_id);
                    }
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

    fn advanceMcp(self: *App) void {
        const due = if (self.mcp_oauth_refresh) |*oauth| oauth.dueMaintenance() else null;
        const maintenance_first = if (due) |value| value.runtime_loaded or !self.mcp_candidate_turn else false;
        var maintained = false;
        if (maintenance_first) if (self.mcp_oauth_refresh) |*oauth| {
            maintained = oauth.runDueMaintenance();
            if (maintained) self.mcp_candidate_turn = true;
        };
        if (self.mcp_management) |*management| {
            const had_apply = management.configuration_apply_job != null;
            _ = management.drain();
            if (!had_apply and management.configuration_apply_job != null) self.mcp_candidate_turn = false;
        }
        const applying = if (self.mcp_management) |*management| management.configuration_apply_job != null else false;
        if (!maintained and !applying) if (self.mcp_oauth_refresh) |*oauth| {
            if (oauth.runDueMaintenance()) self.mcp_candidate_turn = true;
        };
        if (self.mcp_oauth_refresh) |*oauth| oauth.reconcileTimer();
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
        .notify_fn = app_platform.Adapter.notifyAgentEvents,
    });
    defer app.automation.deinit();
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

    const builtin_skill_root: ?[:0]u8 = if (@import("builtin").os.tag == .windows or @import("builtin").os.tag == .macos)
        office_skills.prepare(std.heap.c_allocator, init.io, paths_state.dataDir()) catch |failure| failed: {
            std.log.warn("Office Skill publication unavailable: {s}", .{@errorName(failure)});
            break :failed null;
        }
    else
        null;
    defer if (builtin_skill_root) |root| std.heap.c_allocator.free(root);

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
    app.history_restore_owner = &stores_state;
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
            .context = &stores_state,
            .enabled = stores_state.task != null,
            .restore_fn = app_stores.takeTaskRestore,
            .restore_failed = stores_state.task_restore_failed,
            .restore_degraded = if (stores_state.task) |store| store.import_degraded else false,
            .restore_incompatible = if (stores_state.task) |store| store.incompatible else false,
            .credentials_fn = app_stores.taskStoreCredentials,
            .generation_commit_fn = app_stores.commitTaskStoreGeneration,
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
        if (app.mcp_budget) |budget| {
            budget.release();
            app.mcp_budget = null;
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
    account_coordinator_state.setCommitObserver(.{
        .context = &models_coordinator_state,
        .notify_fn = notifyModelsAuthorizationChanged,
    });
    app.account_coordinator = &account_coordinator_state;
    app.models_coordinator = &models_coordinator_state;
    defer {
        app.models_coordinator = null;
        app.account_coordinator = null;
        if (app.control_initialized) control.clearAccountProjectionCredentials();
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

test "Application canonical paths test roots" {
    std.testing.refAllDecls(app_paths);
}

test "Windows window chrome Application test roots" {
    _ = app_window;
    _ = app_platform;
}

test "main-loop wake Application test roots" {
    std.testing.refAllDecls(app_platform);
    std.testing.refAllDecls(app_single_instance);
}

test "main-loop wake joins the required relay after Agent shutdown failure" {
    const fixture = @import("lifecycle_fixture");
    const Wake = struct {
        var calls: std.atomic.Value(usize) = .init(0);
        fn notify(_: ?*anyopaque) anyerror!void {
            _ = calls.fetchAdd(1, .monotonic);
        }
    };
    Wake.calls.store(0, .monotonic);
    fixture.fake_core.reset();
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.runtime.options.platform.services.wake_fn = Wake.notify;
    const agent_runtime = try agent.Runtime.initWithApi(std.testing.io, std.testing.allocator, &fixture.fake_api, .{ .max_sessions = 1 });
    defer {
        agent_runtime.shutdown() catch unreachable;
        agent_runtime.deinit();
    }
    var composition: App = .{
        .env_map = undefined,
        .io = std.testing.io,
        .frontend_asset_root = "",
        .main_thread_id = std.Thread.getCurrentId(),
        .automation = undefined,
        .platform = app_platform.Adapter.init(std.testing.io, std.Thread.getCurrentId()),
        .completion_transport = undefined,
        .agent_runtime = agent_runtime,
    };
    try composition.platform.start(&harness.runtime);
    defer composition.platform.stop(&harness.runtime);
    app_platform.Adapter.notifyRequired(&composition.platform);
    fixture.fake_core.failNextRuntimeDestroy();

    try std.testing.expectError(error.RuntimeDestroyFailed, App.stop(&composition, &harness.runtime));

    try std.testing.expect(composition.platform.services() == null);
    try std.testing.expect(composition.platform.native_runtime == null);
    try std.testing.expect(composition.platform.required_wake == null);
    try std.testing.expectEqual(@as(usize, 1), Wake.calls.load(.monotonic));
    try std.testing.expect(!composition.agent_shutdown);
}

test "SDK consumption Application test roots" {
    std.testing.refAllDecls(app_platform);
    std.testing.refAllDecls(app_window);
    std.testing.refAllDecls(account_platform_binding);
    std.testing.refAllDecls(models_platform_binding);
}

test "SDK consumption dialog connection replacement settles Save As and reuses response slots" {
    const Responses = struct {
        var count: usize = 0;
        var valid_outcomes: bool = true;
        var forward: *const fn (?*anyopaque, u64, []const u8, []const u8) anyerror!void = undefined;
        fn complete(context: ?*anyopaque, window: u64, label: []const u8, bytes: []const u8) !void {
            count += 1;
            if (std.mem.startsWith(u8, bytes, "{\"id\":\"save\","))
                valid_outcomes = valid_outcomes and std.mem.indexOf(u8, bytes, "\"state\":\"cancelled\"") != null;
            if (std.mem.startsWith(u8, bytes, "{\"id\":\"workspace\","))
                valid_outcomes = valid_outcomes and std.mem.indexOf(u8, bytes, "DialogCancelled") != null;
            try forward(context, window, label, bytes);
        }
    };
    Responses.count = 0;
    Responses.valid_outcomes = true;
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    _ = try harness.runtime.createWindow(.{ .id = 1, .label = "main", .source = .html("") });
    harness.null_platform.useAsyncDialogs(&harness.runtime.options.platform.services);
    Responses.forward = harness.runtime.options.platform.services.complete_webview_bridge_fn.?;
    harness.runtime.options.platform.services.complete_webview_bridge_fn = Responses.complete;
    var platform = app_platform.Adapter.init(std.testing.io, std.Thread.getCurrentId());
    try platform.start(&harness.runtime);
    defer platform.stop(&harness.runtime);
    const control = try std.testing.allocator.create(product_control.Runtime);
    defer std.testing.allocator.destroy(control);
    try product_control.TestSupport.filePreviewFixture(control, "/tmp/metawork-dialog-test");
    defer control.deinit();
    try product_control.TestSupport.recordDeliveredOutputFixture(control);
    control.setOutputFileSave(platform.outputFileSave());
    var dispatcher = try bridge_api.Dispatcher.init(std.testing.allocator, control, undefined, undefined, platform.dispatcherPlatform(), .{}, 1);
    defer dispatcher.deinit();
    defer dispatcher.breakConnection();
    harness.runtime.options.bridge = dispatcher.register(bridge_api.policy.product(.release));
    const app: native_sdk.App = .{ .context = &platform, .name = "dialog-response-reuse", .source = .html("") };
    const connect = "{\"id\":\"connect\",\"command\":\"metawork.events.connect\",\"payload\":{\"contractId\":\"metawork.renderer-bridge\",\"contractRevision\":1}}";
    try harness.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{ .bytes = connect, .origin = "zero://app", .window_id = 1 } });
    try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"accepted\":true") != null);

    // These requests enter through Runtime, which allocates and releases the
    // real SDK response slots. Eighty cycles exceed its 64-slot capacity.
    for (0..80) |iteration| {
        const before = Responses.count;
        var storage: [512]u8 = undefined;
        const save = try std.fmt.bufPrint(&storage, "{{\"id\":\"save\",\"command\":\"metawork.outputs.action\",\"payload\":{{\"generation\":\"{d}\",\"operationId\":\"1\",\"taskId\":\"3\",\"runId\":\"7\",\"outputId\":\"03030303030303030303030303030303\",\"action\":\"save\"}}}}", .{dispatcher.productDelivery().connectedGeneration().?});
        try harness.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{ .bytes = save, .origin = "zero://app", .window_id = 1 } });
        try harness.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{ .bytes = "{\"id\":\"workspace\",\"command\":\"metawork.workspaces.choose\",\"payload\":{}}", .origin = "zero://app", .window_id = 1 } });
        try std.testing.expectEqual(before, Responses.count);
        try std.testing.expectEqual(@as(usize, 2), harness.runtime.pendingDialogCount());
        try std.testing.expectEqual(@as(usize, 1), harness.null_platform.presentedDialogCount());

        // No disconnect: replacing the connection must immediately settle both
        // commands and release the frozen Save target, before SDK completion.
        try harness.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{ .bytes = connect, .origin = "zero://app", .window_id = 1 } });
        try std.testing.expectEqual(before + 3, Responses.count);
        try std.testing.expect(Responses.valid_outcomes);
        try std.testing.expect(std.mem.indexOf(u8, harness.null_platform.lastBridgeResponse(), "\"accepted\":true") != null);
        for (control.pending_output_saves) |pending| try std.testing.expect(pending == null);
        for (dispatcher.output_in_flight) |pending| try std.testing.expect(pending == null);
        for (dispatcher.dialogs) |pending| try std.testing.expect(!pending.active);
        try std.testing.expectEqual(iteration + 1, harness.null_platform.dialog_cancel_count);
        try std.testing.expectEqual(@as(usize, 0), harness.null_platform.presentedDialogCount());

        // Reuse the freed response slot while the old native results are still
        // pending. Their callbacks must leave the new command unanswered.
        try harness.runtime.dispatchPlatformEvent(app, .{ .bridge_message = .{ .bytes = "{\"id\":\"fresh\",\"command\":\"metawork.workspaces.choose\",\"payload\":{}}", .origin = "zero://app", .window_id = 1 } });
        const fresh = for (dispatcher.dialogs) |pending| {
            if (pending.active) break pending.handle;
        } else return error.MissingDialog;
        while (harness.null_platform.takeWake()) |event| try harness.runtime.dispatchPlatformEvent(app, event);
        try std.testing.expectEqual(before + 3, Responses.count);
        try std.testing.expectEqual(@as(usize, 1), harness.runtime.pendingDialogCount());
        try std.testing.expectEqual(@as(usize, 1), harness.null_platform.presentedDialogCount());
        try harness.null_platform.finishDialog(fresh, .cancelled, "", .primary);
        while (harness.null_platform.takeWake()) |event| try harness.runtime.dispatchPlatformEvent(app, event);
        try std.testing.expectEqual(before + 4, Responses.count);
        try std.testing.expectEqualStrings("{\"id\":\"fresh\",\"ok\":true,\"result\":{\"selected\":false}}", harness.null_platform.lastBridgeResponse());
        try std.testing.expectEqual(@as(usize, 0), harness.runtime.pendingDialogCount());
        try std.testing.expectEqual(@as(usize, 0), harness.null_platform.presentedDialogCount());
    }
    try std.testing.expectEqual(@as(usize, 160), harness.null_platform.dialog_request_count);
}

test "notification activation follows SDK command routing into the real Task Bridge hint" {
    const Host = struct {
        calls: usize = 0,
        fn emit(context: ?*anyopaque, window_id: u64, name: []const u8, detail: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            try std.testing.expectEqual(@as(u64, 1), window_id);
            try std.testing.expectEqualStrings("metawork:open-task", name);
            try std.testing.expectEqualStrings("{\"generation\":\"1\",\"taskId\":\"1\"}", detail);
            self.calls += 1;
        }
        fn wake(_: ?*anyopaque) !void {}
        fn timer(_: ?*anyopaque, _: u64, _: u64, _: bool) !void {}
        fn cancel(_: ?*anyopaque, _: u64) !void {}
        fn now(_: ?*anyopaque) u64 {
            return 1;
        }
        fn main(_: ?*anyopaque) bool {
            return true;
        }
    };
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    _ = try harness.runtime.createWindow(.{ .id = 1, .label = "main", .source = .html("") });
    var host: Host = .{};
    const control = try std.testing.allocator.create(product_control.Runtime);
    defer std.testing.allocator.destroy(control);
    try product_control.TestSupport.maximumSmallFixture(control);
    defer control.deinit();
    var dispatcher = try bridge_api.Dispatcher.init(std.testing.allocator, control, undefined, undefined, .{
        .context = &host,
        .wake_fn = Host.wake,
        .emit_fn = Host.emit,
        .start_timer_fn = Host.timer,
        .cancel_timer_fn = Host.cancel,
        .now_fn = Host.now,
        .on_main_thread_fn = Host.main,
        .canonicalize_directory_fn = undefined,
        .window_chrome_connect_fn = undefined,
        .window_chrome_refresh_fn = undefined,
        .window_chrome_control_fn = undefined,
    }, .{}, 1);
    defer dispatcher.deinit();
    _ = try dispatcher.productDelivery().connect(1, .{
        .context = &host,
        .emit_fn = Host.emit,
        .start_timer_fn = Host.timer,
        .cancel_timer_fn = Host.cancel,
    });
    var composition: App = .{
        .env_map = undefined,
        .io = std.testing.io,
        .frontend_asset_root = "",
        .main_thread_id = std.Thread.getCurrentId(),
        .automation = undefined,
        .platform = .{ .io = std.testing.io, .main_thread_id = std.Thread.getCurrentId(), .native_runtime = &harness.runtime },
        .completion_transport = undefined,
        .dispatcher = &dispatcher,
    };
    const app: native_sdk.App = .{ .name = "schedule-notification-test", .context = &composition, .event_fn = App.event };
    const before = control.currentRevision();
    try std.testing.expect(composition.platform.window.notifyScheduledTask(&harness.runtime, .{ .scheduled_task_id = 1, .task_id = 1, .title = "Completed", .kind = .completed }));
    try harness.runtime.dispatchCommand(app, .{ .name = "metawork.schedule.open.1", .source = .runtime, .window_id = 1 });
    try std.testing.expectEqual(@as(usize, 0), host.calls);
    const activation = harness.null_platform.activateNotification("schedule-1-1-completed").?;
    try harness.runtime.dispatchPlatformEvent(app, activation);
    try std.testing.expectEqual(@as(usize, 1), host.calls);
    try std.testing.expectEqual(before, control.currentRevision());
}

test "MCP Application composition imports the startup owner" {
    std.testing.refAllDecls(App);
    comptime _ = run;
    std.testing.refAllDecls(mcp_startup);
    std.testing.refAllDecls(mcp_oauth);
    std.testing.refAllDecls(mcp_management_coordinator);
}

test {
    std.testing.refAllDecls(office_skills);
    std.testing.refAllDecls(account_coordinator);
    std.testing.refAllDecls(metask_http_transport);
    std.testing.refAllDecls(update_http);
    std.testing.refAllDecls(update_coordinator);
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

test "Application file delivery freezes Workspace root and keeps all file reads off main" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const file = try tmp.dir.createFile(std.testing.io, "result.docx", .{});
    try file.writeStreamingAll(std.testing.io, "abc");
    file.close(std.testing.io);
    var delivery = FrozenFileDelivery.prepare(std.testing.io, std.Thread.getCurrentId(), root).?;
    defer delivery.deinit();
    @memset(root, 'x');
    var cancelled = std.atomic.Value(bool).init(false);
    try std.testing.expectEqual(.restricted, delivery.input.inspect_fn(delivery.input.context, "result.docx", &cancelled).failed);
    const Work = struct {
        input: agent.FileDeliveryInput,
        cancelled: *std.atomic.Value(bool),
        outcome: ?agent.FileDeliveryInspection = null,
        fn run(self: *@This()) void {
            self.outcome = self.input.inspect_fn(self.input.context, "result.docx", self.cancelled);
        }
    };
    var work: Work = .{ .input = delivery.input, .cancelled = &cancelled };
    const thread = try std.Thread.spawn(.{}, Work.run, .{&work});
    thread.join();
    try std.testing.expectEqual(@as(u64, 3), work.outcome.?.verified.size_bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("abc", &digest, .{});
    try std.testing.expectEqualSlices(u8, &digest, &work.outcome.?.verified.sha256);
    cancelled.store(true, .release);
    const stopped = try std.Thread.spawn(.{}, Work.run, .{&work});
    stopped.join();
    try std.testing.expectEqual(.cancelled, work.outcome.?.failed);
}

// Compiled only by the explicit account-evaluation build entry.
pub fn runPermissionReviewEvaluation(init: std.process.Init) !void {
    return @import("app/permission_review_account_eval.zig").run(init);
}

test {
    _ = @import("app/history_store.zig");
}

test "main-loop wake consumes catalog completion and fairly schedules MCP recovery and candidates" {
    const fixture = @import("lifecycle_fixture");
    fixture.fake_core.reset();
    const mcp = @import("metawork_product_mcp");
    const control_ports = @import("metawork_product_control_ports");
    const Effects = struct {
        now_ms: u64 = 0,
        maintenances: usize = 0,
        loaded: bool = false,
        var identity: u8 = 0x51;
        fn commit(_: ?*anyopaque, _: []const u8) mcp_configuration.PersistenceEffect {
            return .committed;
        }
        fn clear(_: ?*anyopaque) mcp_configuration.PersistenceEffect {
            return .committed;
        }
        fn fill(_: ?*anyopaque, output: *[16]u8) bool {
            @memset(output, identity);
            identity += 1;
            return true;
        }
        fn request(_: *anyopaque, _: u64, _: control_ports.NativeDialog.Message, _: *const control_ports.NativeDialog.Completion) !u64 {
            return error.UnexpectedCall;
        }
        fn open(_: *anyopaque, _: []const u8) bool {
            return false;
        }
        fn now(raw: *anyopaque) ?u64 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return self.now_ms;
        }
        fn notify(_: *anyopaque) void {}
        fn arm(_: *anyopaque, _: u64) bool {
            return true;
        }
        fn cancel(_: *anyopaque) void {}
        fn next(raw: *anyopaque) ?mcp.McpOauthExpiry {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return .{ .server_id = "waiting-grant", .expires_at_unix_ms = 0, .runtime_loaded = self.loaded };
        }
        fn begin(raw: *anyopaque, _: []const u8) anyerror!mcp.McpOauthRefreshBeginOutcome {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.maintenances += 1;
            // Reject before any effect. The next due grant still competes
            // with candidates after the ordinary retry floor.
            return .rejected;
        }
        fn complete(_: *anyopaque, _: mcp_configuration.CompleteRefreshInput, _: mcp.McpOauthRuntimeCommit) anyerror!mcp_configuration.ManagementOutcome {
            return error.UnexpectedCall;
        }
        fn reauth(_: *anyopaque, _: mcp.McpRuntimeAuthorizationFailure) anyerror!mcp.McpRuntimeAuthorizationFailureOutcome {
            return error.UnexpectedCall;
        }
        fn oauthClear(_: *anyopaque, _: []const u8) anyerror!mcp_configuration.ManagementOutcome {
            return error.UnexpectedCall;
        }
        fn waitForApply(composition: *App) !void {
            const pending = composition.mcp_management.?.configuration_apply_job.?;
            for (0..5_000) |_| {
                if (pending.finished.load(.acquire)) return;
                std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch unreachable;
            }
            return error.ApplyDidNotFinish;
        }
        fn waiting(_: *anyopaque) ?mcp_configuration.ManagementInspection {
            return .{ .health = .ready, .desired_generation = 3, .runtime_alignment = .current, .server_count = 3, .authorization_recovery_pending = true };
        }
        fn noStep(_: *anyopaque, _: u64, _: mcp_configuration.RuntimeApplyIntent) anyerror!?mcp_configuration.RuntimeApplyStep {
            return null;
        }
    };
    const allocator = std.testing.allocator;
    const limits: mcp_configuration.Limits = .{ .max_servers = 8, .max_tools_per_server = 32, .max_namespace_bytes = 128, .max_credential_locators = 64, .max_runtime_secrets_per_server = 128, .max_runtime_secret_bytes_per_server = 16 * 1024 };
    var preparation = try mcp_configuration.prepare(allocator, null, true, false, .{}, limits);
    var preparation_owned = true;
    defer if (preparation_owned) preparation.deinit();
    var manifest = (try mcp_configuration.RuntimeManifest.candidate(allocator, &preparation)).?;
    var manifest_owned = true;
    defer if (manifest_owned) manifest.deinit();
    const agent_runtime = try fixture.createTestRuntime(.{ .max_sessions = 1 });
    defer {
        agent_runtime.shutdown() catch unreachable;
        agent_runtime.deinit();
    }
    var control = try product_control.Runtime.init(allocator, std.testing.io, agent_runtime, .{ .worker_count = 1, .queue_capacity = 1 }, .{ .mcp = .{
        .preparation = &preparation,
        .management = .{
            .persistence = .{ .available = true, .commit_journal_fn = Effects.commit, .commit_registry_fn = Effects.commit, .clear_journal_fn = Effects.clear },
            .credentials = .{ .available = true },
            .identity_generator = .{ .available = true, .fill_fn = Effects.fill },
            .limits = limits,
            .runtime_manifest = &manifest,
        },
    } });
    preparation_owned = false;
    manifest_owned = false;
    defer control.deinit();
    try std.testing.expectEqual(.saved, (try control.createMcpHttpServer(0, .{ .display_name = "Candidate", .url = "https://candidate.example.test/mcp" })).outcome);
    // The sole completion notification is already being consumed. Product
    // still owns this finished job until the main-loop lifecycle drain.
    const product = &control.mcp.?;
    const job = try allocator.create(mcp.testing.RefreshJob);
    job.* = .{
        .allocator = allocator,
        .catalog = undefined,
        .notifier = undefined,
        .request_generation = mcp.testing.state(product).refresh_request_generation,
        .arena = .init(allocator),
        .allowlists = &.{},
        .build_admission = false,
        .state = .init(.completed),
        .outcome = .empty,
    };
    mcp.testing.installRefreshJob(product, job);
    var authorizations: mcp_platform.HttpAuthorizations = .{ .allocator = allocator };
    defer authorizations.deinit();
    const harness = try native_sdk.TestHarness().create(allocator, .{});
    defer harness.destroy(allocator);
    var credentials: mcp_platform.CredentialStore = .{ .io = std.testing.io, .runtime = &harness.runtime, .main_thread_id = std.Thread.getCurrentId() };
    var host: Effects = .{};
    var composition: App = .{
        .env_map = undefined,
        .io = std.testing.io,
        .frontend_asset_root = "",
        .main_thread_id = std.Thread.getCurrentId(),
        .automation = undefined,
        .platform = undefined,
        .completion_transport = undefined,
        .control = &control,
        .mcp_management = mcp_management_coordinator.Coordinator.init(allocator, std.testing.io, control.mcpManagementPort(), agent_runtime, &credentials, &authorizations, .{
            .context = &host,
            .request_dialog_fn = Effects.request,
            .open_url_fn = Effects.open,
            .now_unix_ms_fn = Effects.now,
            .notify_fn = Effects.notify,
        }, .{}),
        .mcp_oauth_refresh = mcp_oauth_coordinator.Coordinator.init(allocator, std.testing.io, .{
            .context = &host,
            .next_expiry_fn = Effects.next,
            .begin_refresh_fn = Effects.begin,
            .complete_refresh_fn = Effects.complete,
            .require_reauthorization_fn = Effects.reauth,
            .clear_operation_fn = Effects.oauthClear,
            .recover_operation_fn = Effects.oauthClear,
        }, &credentials, &authorizations, .{ .context = &host, .now_unix_ms_fn = Effects.now, .arm_fn = Effects.arm, .cancel_fn = Effects.cancel, .notify_fn = Effects.notify }),
    };
    defer composition.mcp_management.?.deinit();
    defer composition.mcp_oauth_refresh.?.deinit();
    fixture.fake_core.forceNextMcpApplyDisposition(fixture.wire.MCP_APPLY_REJECTED);
    try App.event(&composition, undefined, .effects_wake);
    try std.testing.expect(mcp.testing.refreshJob(product) == null);
    try std.testing.expect(composition.mcp_management.?.configuration_apply_job != null);
    try std.testing.expectEqual(@as(usize, 1), host.maintenances);
    try Effects.waitForApply(&composition);
    host.now_ms = 30_000;
    try App.event(&composition, undefined, .effects_wake);
    try std.testing.expectEqual(@as(usize, 2), host.maintenances);
    try std.testing.expectEqual(.saved, (try control.createMcpHttpServer(1, .{ .display_name = "Second", .url = "https://second.example.test/mcp" })).outcome);
    host.now_ms = 60_000;
    _ = composition.mcp_oauth_refresh.?.onTimer();
    try std.testing.expectEqual(@as(usize, 2), host.maintenances);
    fixture.fake_core.forceNextMcpApplyDisposition(fixture.wire.MCP_APPLY_REJECTED);
    try App.event(&composition, undefined, .effects_wake);
    try std.testing.expect(composition.mcp_management.?.configuration_apply_job != null);
    try std.testing.expectEqual(@as(usize, 2), host.maintenances);
    try Effects.waitForApply(&composition);
    try App.event(&composition, undefined, .effects_wake);
    try std.testing.expectEqual(@as(usize, 3), host.maintenances);
    try std.testing.expectEqual(.saved, (try control.createMcpHttpServer(2, .{ .display_name = "Third", .url = "https://third.example.test/mcp" })).outcome);
    host.loaded = true;
    host.now_ms = 90_000;
    fixture.fake_core.forceNextMcpApplyDisposition(fixture.wire.MCP_APPLY_REJECTED);
    try App.event(&composition, undefined, .effects_wake);
    try std.testing.expectEqual(@as(usize, 4), host.maintenances);
    try std.testing.expect(composition.mcp_management.?.configuration_apply_job != null);
    try Effects.waitForApply(&composition);
    // The rejected mapping shares a live slot whose failure has not been
    // consumed. It must not enter the candidate-only handoff or block apply.
    authorizations.deinit();
    authorizations = try mcp_platform.testing.pendingAuthorizations(allocator, std.testing.io);
    var empty_authorizations: mcp_platform.HttpAuthorizations = .{ .allocator = allocator };
    defer empty_authorizations.deinit();
    const rejected_job = composition.mcp_management.?.configuration_apply_job.?;
    rejected_job.authorizations.deinit();
    rejected_job.authorizations = try authorizations.compose(&empty_authorizations, &.{"server"}, null);
    _ = composition.mcp_management.?.drain();
    try std.testing.expectEqual(@as(usize, 0), authorizations.pending_slots.len);
    var unconsumed = try authorizations.snapshotRuntimeAuthFailures();
    defer unconsumed.deinit();
    try std.testing.expectEqual(@as(usize, 1), unconsumed.values.len);
    composition.mcp_management.?.control.inspect_fn = Effects.waiting;
    composition.mcp_management.?.control.prepare_apply_fn = Effects.noStep;
    try std.testing.expectEqual(.started, try composition.mcp_management.?.applyConfiguration(.retry_all));
}
