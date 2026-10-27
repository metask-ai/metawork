//! Concrete Renderer command boundary. This module owns command registration,
//! authority checks, connection/grant state, payload decoding, response
//! encoding, and the only Bridge -> Product Control calls.

const std = @import("std");
const native_sdk = @import("native_sdk");
const account_contract = @import("metawork_account_contract");
const models_contract = @import("metawork_product_models_contract");
const product_control = @import("metawork_product_control");
const mcp_configuration = @import("metawork_product_mcp").contract;
const skill_management = @import("metawork_product_skill").management;
const skill_runtime = @import("metawork_product_skill").runtime;
const commands = @import("commands.zig");
const handlers = @import("handlers.zig");
const callback_gate = @import("callback_gate.zig");
const product_delivery = @import("product_delivery.zig");
const workspace_grant = @import("workspace_grant.zig");
const skill_grant = @import("skill_grant.zig");
const attachment_grant = @import("attachment_grant.zig");

const product_handler_count = commands.product.len;
const async_product_handler_count = 10;
const output_timer_id: u64 = 0x4d574f55;
const preview_timer_id: u64 = 0x4d574950;
const sync_product_handler_count = product_handler_count - async_product_handler_count;
const max_preview_in_flight: usize = 8;
const max_diff_in_flight: usize = 8;
const max_attachment_in_flight: usize = 4;
pub const attachment_chunk_bytes = 128 * 1024;
const workspace_path_capacity = workspace_grant.max_path_bytes;
const event_name = "metawork:host-signal";
const max_external_link_url_bytes: usize = 4096;

pub const WindowChromePlatformEnvironment = struct {
    top: f64,
    left: f64,
    bottom: f64,
    right: f64,
    buttons_x: f64,
    buttons_y: f64,
    buttons_width: f64,
    buttons_height: f64,
    renderer_controls: bool,
    maximized: bool,
};

pub const WindowChromeControlAction = enum {
    minimize,
    toggle_maximize,
    close,
};

pub const Platform = struct {
    attachment_input: enum { native_paths, file_bytes } = .native_paths,
    context: ?*anyopaque,
    wake_fn: *const fn (?*anyopaque) anyerror!void,
    emit_fn: *const fn (
        ?*anyopaque,
        native_sdk.platform.WindowId,
        []const u8,
        []const u8,
    ) anyerror!void,
    start_timer_fn: *const fn (?*anyopaque, u64, u64, bool) anyerror!void,
    cancel_timer_fn: *const fn (?*anyopaque, u64) anyerror!void,
    show_open_dialog_fn: *const fn (
        ?*anyopaque,
        native_sdk.platform.OpenDialogOptions,
        []u8,
    ) anyerror!native_sdk.platform.OpenDialogResult,
    canonicalize_directory_fn: *const fn (
        ?*anyopaque,
        []const u8,
        []u8,
    ) anyerror![]const u8,
    random_fn: *const fn (?*anyopaque, []u8) bool = unavailableRandom,
    window_chrome_connect_fn: *const fn (
        ?*anyopaque,
        native_sdk.platform.WindowId,
    ) anyerror!WindowChromePlatformEnvironment,
    window_chrome_refresh_fn: *const fn (
        ?*anyopaque,
        native_sdk.platform.WindowId,
    ) anyerror!WindowChromePlatformEnvironment,
    window_chrome_control_fn: *const fn (
        ?*anyopaque,
        native_sdk.platform.WindowId,
        WindowChromeControlAction,
    ) anyerror!void,
    open_external_url_fn: *const fn (
        ?*anyopaque,
        []const u8,
    ) anyerror!void = unavailableExternalUrl,
    now_fn: *const fn (?*anyopaque) u64,
    on_main_thread_fn: *const fn (?*anyopaque) bool,
};

pub const AutomationAuthority = struct {
    context: ?*anyopaque = null,
    active_fn: *const fn (?*anyopaque) bool = inactive,
    workspace_root_fn: *const fn (?*anyopaque) ?[]const u8 = noAutomationWorkspace,
    attachment_paths_fn: *const fn (?*anyopaque) ?[]const u8 = noAutomationAttachments,

    fn active(self: AutomationAuthority) bool {
        return self.active_fn(self.context);
    }

    fn workspaceRoot(self: AutomationAuthority) ?[]const u8 {
        return self.workspace_root_fn(self.context);
    }

    fn attachmentPaths(self: AutomationAuthority) ?[]const u8 {
        return self.attachment_paths_fn(self.context);
    }
};

pub const McpHostOutcome = enum {
    saved,
    saved_recovery_required,
    stale_generation,
    rejected,
    indeterminate,
    cancelled,
    capability_unavailable,
};

pub const McpAuthorizationStartOutcome = union(enum) {
    started: []const u8,
    rejected,
    stale_generation,
    capability_unavailable,
};

pub const McpConnectionTestStartOutcome = enum {
    started,
    busy,
    stale_generation,
    needs_authentication,
    rejected,
    unavailable,
};

pub const McpConfigurationApplyStartOutcome = enum {
    started,
    busy,
    rejected,
    unavailable,
};

pub const McpSecretSlot = union(enum) {
    stdio_environment: []const u8,
    http_header: []const u8,
    oauth_client_secret,
};

/// Application-owned Models effects that cannot run inside Product Control.
pub const ModelsHost = struct {
    context: *anyopaque,
    refresh_catalog_fn: *const fn (*anyopaque) models_contract.CommandResult,
    reset_store_fn: *const fn (*anyopaque, u64) models_contract.CommandResult,

    fn refreshCatalog(self: ModelsHost) models_contract.CommandResult {
        return self.refresh_catalog_fn(self.context);
    }

    fn resetStore(self: ModelsHost, expected_revision: u64) models_contract.CommandResult {
        return self.reset_store_fn(self.context, expected_revision);
    }
};

/// Narrow Application effect port. It grants only the MCP management
/// sequences owned by the Application coordinator, never platform authority.
pub const McpManagementHost = struct {
    context: *anyopaque,
    test_fn: *const fn (*anyopaque, u64, []const u8) anyerror!McpConnectionTestStartOutcome,
    approve_fn: *const fn (*anyopaque, u64, []const u8) anyerror!McpHostOutcome,
    capture_fn: *const fn (*anyopaque, u64, []const u8, McpSecretSlot, []const u8) anyerror!McpHostOutcome,
    authorize_fn: *const fn (*anyopaque, u64, []const u8) anyerror!McpAuthorizationStartOutcome,
    cancel_fn: *const fn (*anyopaque, []const u8) McpHostOutcome,
    apply_fn: *const fn (*anyopaque) anyerror!McpConfigurationApplyStartOutcome,
};

pub const Dispatcher = struct {
    const PreviewRelease = struct {
        responder: native_sdk.bridge.AsyncResponder,
        request_id: [native_sdk.bridge.max_id_bytes]u8 = undefined,
        request_len: usize,
    };
    const PreviewGrant = struct {
        token: [48]u8,
        image: product_control.FilePreviewImage,
        generation: u64,
        window_id: native_sdk.platform.WindowId,
        preview_id: u64,
    };
    const PreviewImage = struct { token: []const u8, image: product_control.FilePreviewImage };
    const PreviewInFlight = struct {
        active: bool = false,
        generation: u64 = 0,
        window_id: native_sdk.platform.WindowId = 0,
        preview_id: u64 = 0,
        cancelled: bool = false,
        release_waiter: ?PreviewRelease = null,
        completion_id: u64 = 0,
        responder: native_sdk.bridge.AsyncResponder = undefined,
        request_id_storage: [native_sdk.bridge.max_id_bytes]u8 = undefined,
        request_id_len: usize = 0,
    };
    const OutputInFlight = struct {
        completion_id: u64,
        generation: u64,
        operation_id: u64,
        window_id: native_sdk.platform.WindowId,
        cancelled: bool = false,
        responder: native_sdk.bridge.AsyncResponder,
        request_id: [native_sdk.bridge.max_id_bytes]u8,
        request_len: usize,
    };
    const DiffInFlight = struct {
        active: bool = false,
        completion_id: u64 = 0,
        responder: native_sdk.bridge.AsyncResponder = undefined,
        request_id_storage: [native_sdk.bridge.max_id_bytes]u8 = undefined,
        request_id_len: usize = 0,
    };
    const AttachmentInFlight = struct {
        batch_id: ?u64 = null,
        active: bool = false,
        completion_id: u64 = 0,
        generation: u64 = 0,
        window_id: native_sdk.platform.WindowId = 0,
        responder: native_sdk.bridge.AsyncResponder = undefined,
        request_id_storage: [native_sdk.bridge.max_id_bytes]u8 = undefined,
        request_id_len: usize = 0,
    };
    const AddCancel = struct {
        generation: u64,
        window_id: native_sdk.platform.WindowId,
        batch_id: u64,
        responder: native_sdk.bridge.AsyncResponder,
        request_id: [native_sdk.bridge.max_id_bytes]u8,
        request_len: usize,
    };
    const AddDebt = struct { generation: u64, window_id: native_sdk.platform.WindowId, batch_id: u64, product_id: ?u64 = null, attachment_id: ?u64 = null };
    const AttachmentGrantAcceptance = struct {
        dispatcher: *Dispatcher,
        tokens: []const []const u8,
        generation: u64,
        window_id: native_sdk.platform.WindowId,
    };

    control: ?*product_control.Runtime,
    account_commands: account_contract.AccountCommandSink,
    custom_provider_commands: models_contract.CommandSink,
    platform: Platform,
    automation: AutomationAuthority,
    mcp_management_host: ?McpManagementHost = null,
    models_host: ?ModelsHost = null,
    bootstrap_window_id: native_sdk.platform.WindowId,
    delivery: product_delivery.Delivery,
    callbacks: callback_gate.State = .{},
    grants: workspace_grant.State = .{},
    skill_grants: skill_grant.State = .{},
    attachment_grants: attachment_grant.State = .{},
    receive_high_water: u64 = 0,
    receive_active: ?struct { batch_id: u64, product_id: u64, unified: bool = false, bytes: bool = true } = null,
    add_cancel: ?AddCancel = null,
    add_debt: [attachment_grant.max_grants]?AddDebt = @splat(null),
    window_chrome_generation: u64 = 0,
    window_chrome_connected: bool = false,
    sequence: u64 = 0,
    acknowledged_sequence: u64 = 0,
    registered_handlers: [sync_product_handler_count]native_sdk.bridge.Handler = undefined,
    registered_async_handlers: [async_product_handler_count]native_sdk.bridge.AsyncHandler = undefined,
    preview_in_flight: [max_preview_in_flight]PreviewInFlight = @splat(.{}),
    next_preview_completion_id: u64 = 1,
    preview_high_water: u64 = 0,
    preview_grants: [2]?PreviewGrant = @splat(null),
    preview_timer_armed: bool = false,
    output_timer_armed: bool = false,
    output_in_flight: [2]?OutputInFlight = @splat(null),
    output_high_water: u64 = 0,
    next_output_completion_id: u64 = 1,
    diff_in_flight: [max_diff_in_flight]DiffInFlight = @splat(.{}),
    next_diff_completion_id: u64 = 1,
    attachment_in_flight: [max_attachment_in_flight]AttachmentInFlight = @splat(.{}),
    next_attachment_completion_id: u64 = 1,

    pub fn init(
        allocator: std.mem.Allocator,
        control: *product_control.Runtime,
        account_commands: account_contract.AccountCommandSink,
        custom_provider_commands: models_contract.CommandSink,
        platform: Platform,
        automation: AutomationAuthority,
        bootstrap_window_id: native_sdk.platform.WindowId,
    ) std.mem.Allocator.Error!Dispatcher {
        std.debug.assert(bootstrap_window_id != 0);
        return .{
            .control = control,
            .account_commands = account_commands,
            .custom_provider_commands = custom_provider_commands,
            .platform = platform,
            .automation = automation,
            .bootstrap_window_id = bootstrap_window_id,
            .delivery = try product_delivery.Delivery.init(allocator),
        };
    }

    pub fn deinit(self: *Dispatcher) void {
        self.callbacks.stopIngress();
        self.callbacks.assertQuiescent();
        self.cancelPreviewConnection();
        self.delivery.breakConnection(self.transport());
        self.grants.invalidate();
        self.skill_grants.invalidate();
        self.releaseAllAttachmentGrants();
        self.window_chrome_connected = false;
        self.control = null;
        self.delivery.deinitOwnedBuffers();
        self.* = undefined;
    }

    pub fn setModelsHost(self: *Dispatcher, host: ?ModelsHost) void {
        self.models_host = host;
    }

    /// Registers the complete product command table. Automation may change
    /// authority in controlled builds, but it does not add a parallel protocol.
    pub fn register(
        self: *Dispatcher,
        policy: native_sdk.BridgePolicy,
    ) native_sdk.BridgeDispatcher {
        const product_specs = [_]struct {
            name: []const u8,
            function: native_sdk.bridge.HandlerFn,
        }{
            .{ .name = commands.ping, .function = ping },
            .{ .name = commands.ping_ack, .function = acknowledgeEvent },
            .{ .name = commands.connect, .function = connectEvents },
            .{ .name = commands.disconnect, .function = disconnectEvents },
            .{ .name = commands.window_chrome_connect, .function = connectWindowChrome },
            .{ .name = commands.window_chrome_refresh, .function = refreshWindowChrome },
            .{ .name = commands.window_chrome_control, .function = controlWindowChrome },
            .{ .name = commands.window_chrome_disconnect, .function = disconnectWindowChrome },
            .{ .name = commands.read_preview_image, .function = readPreviewImage },
            .{ .name = commands.open_external_link, .function = openExternalLink },
            .{ .name = commands.output_action_cancel, .function = cancelOutputAction },
            .{ .name = commands.choose_workspace, .function = chooseWorkspace },
            .{ .name = commands.choose_automatic_workspace_root, .function = chooseAutomaticWorkspaceRoot },
            .{ .name = commands.reset_automatic_workspace_root, .function = resetAutomaticWorkspaceRoot },
            .{ .name = commands.retry_automatic_workspace_root, .function = retryAutomaticWorkspaceRoot },
            .{ .name = commands.refresh_workspace_skill_catalog, .function = refreshWorkspaceSkillCatalog },
            .{ .name = commands.refresh_skill_catalog, .function = refreshSkillCatalog },
            .{ .name = commands.set_skill_enabled, .function = setSkillEnabled },
            .{ .name = commands.set_skill_source_enabled, .function = setSkillSourceEnabled },
            .{ .name = commands.recover_skill_source_settings, .function = recoverSkillSourceSettings },
            .{ .name = commands.choose_skill_import, .function = chooseSkillImport },
            .{ .name = commands.install_skill, .function = installSkill },
            .{ .name = commands.reimport_skill, .function = reimportSkill },
            .{ .name = commands.uninstall_skill, .function = uninstallSkill },
            .{ .name = commands.retry_skill, .function = retrySkill },
            .{ .name = commands.export_skill, .function = exportSkill },
            .{ .name = commands.skill_detail, .function = skillDetail },
            .{ .name = commands.mcp_create_stdio_server, .function = createMcpStdioServer },
            .{ .name = commands.mcp_create_http_server, .function = createMcpHttpServer },
            .{ .name = commands.mcp_update_stdio_connection, .function = updateMcpStdioConnection },
            .{ .name = commands.mcp_update_http_connection, .function = updateMcpHttpConnection },
            .{ .name = commands.mcp_rename_server, .function = renameMcpServer },
            .{ .name = commands.mcp_approve_connection, .function = approveMcpConnection },
            .{ .name = commands.mcp_capture_secret, .function = captureMcpSecret },
            .{ .name = commands.mcp_authorize_oauth, .function = authorizeMcpOauth },
            .{ .name = commands.mcp_cancel_authorization, .function = cancelMcpAuthorization },
            .{ .name = commands.mcp_set_server_enabled, .function = setMcpServerEnabled },
            .{ .name = commands.mcp_set_allowed_tools, .function = setMcpAllowedTools },
            .{ .name = commands.mcp_remove_server, .function = removeMcpServer },
            .{ .name = commands.mcp_test_connection, .function = testMcpConnection },
            .{ .name = commands.mcp_apply_configuration, .function = applyMcpConfiguration },
            .{ .name = commands.mcp_refresh_catalog, .function = refreshMcpCatalog },
            .{ .name = commands.snapshot, .function = beginSnapshot },
            .{ .name = commands.snapshot_chunk, .function = fetchSnapshotChunk },
            .{ .name = commands.account_begin_login, .function = accountBeginLogin },
            .{ .name = commands.account_cancel_operation, .function = accountCancelOperation },
            .{ .name = commands.account_retry_refresh, .function = accountRetryRefresh },
            .{ .name = commands.account_refresh_summary, .function = accountRefreshSummary },
            .{ .name = commands.account_open_recharge, .function = accountOpenRecharge },
            .{ .name = commands.models_refresh_catalog, .function = modelsRefreshCatalog },
            .{ .name = commands.models_reset_store, .function = modelsResetStore },
            .{ .name = commands.models_configure_metask_selection, .function = configureMetaskSelection },
            .{ .name = commands.models_select_default, .function = selectModelsDefault },
            .{ .name = commands.custom_provider_create, .function = customProviderCreate },
            .{ .name = commands.builtin_provider_create, .function = builtinProviderCreate },
            .{ .name = commands.builtin_provider_update_base_url, .function = builtinProviderUpdateBaseUrl },
            .{ .name = commands.custom_provider_update, .function = customProviderUpdate },
            .{ .name = commands.custom_provider_replace_credential, .function = customProviderReplaceCredential },
            .{ .name = commands.custom_provider_remove, .function = customProviderRemove },
            .{ .name = commands.custom_model_test, .function = customModelTest },
            .{ .name = commands.custom_model_add, .function = customModelAdd },
            .{ .name = commands.custom_model_replace, .function = customModelReplace },
            .{ .name = commands.custom_model_remove, .function = customModelRemove },
            .{ .name = commands.account_logout, .function = accountLogout },
            .{ .name = commands.create_task, .function = createTask },
            .{ .name = commands.run, .function = runTask },
            .{ .name = commands.send_input, .function = sendInput },
            .{ .name = commands.stop, .function = stopTask },
            .{ .name = commands.release_attachment, .function = releaseAttachment },
            .{ .name = commands.begin_attachment_receive, .function = beginAttachmentReceive },
            .{ .name = commands.append_attachment_receive, .function = appendAttachmentReceive },
            .{ .name = commands.finish_attachment_receive, .function = finishAttachmentReceive },
            .{ .name = commands.cancel_attachment_receive, .function = cancelAttachmentReceive },
            .{ .name = commands.set_approval_mode, .function = setApprovalMode },
            .{ .name = commands.select_task_model, .function = selectTaskModel },
            .{ .name = commands.restore_task, .function = restoreTask },
            .{ .name = commands.compact, .function = compactTask },
            .{ .name = commands.cancel_compact, .function = cancelCompact },
            .{ .name = commands.refresh_task_skill_catalog, .function = refreshTaskSkillCatalog },
            .{ .name = commands.cancel, .function = cancelTask },
            .{ .name = commands.respond_ui, .function = respondUi },
            .{ .name = commands.rename_task, .function = renameTask },
            .{ .name = commands.archive_task, .function = archiveTask },
            .{ .name = commands.mark_task_completion_seen, .function = markTaskCompletionSeen },
            .{ .name = commands.delete_task, .function = deleteTask },
            .{ .name = commands.recover_task_history, .function = recoverTaskHistory },
            .{ .name = commands.create_scheduled_task, .function = createScheduledTask },
            .{ .name = commands.update_scheduled_task, .function = updateScheduledTask },
            .{ .name = commands.set_scheduled_task_enabled, .function = setScheduledTaskEnabled },
            .{ .name = commands.run_scheduled_task_now, .function = runScheduledTaskNow },
            .{ .name = commands.delete_scheduled_task, .function = deleteScheduledTask },
            .{ .name = commands.recover_scheduled_task_store, .function = recoverScheduledTaskStore },
        };
        comptime std.debug.assert(product_specs.len == sync_product_handler_count);
        inline for (product_specs, 0..) |spec, index| self.registered_handlers[index] = .{
            .name = spec.name,
            .context = self,
            .invoke_fn = spec.function,
        };
        self.registered_async_handlers[0] = .{
            .name = commands.preview_file,
            .context = self,
            .invoke_fn = previewFile,
        };
        self.registered_async_handlers[1] = .{
            .name = commands.diff_file,
            .context = self,
            .invoke_fn = diffFile,
        };
        self.registered_async_handlers[2] = .{
            .name = commands.choose_attachments,
            .context = self,
            .invoke_fn = chooseAttachments,
        };
        self.registered_async_handlers[3] = .{
            .name = commands.add_dropped_attachments,
            .context = self,
            .invoke_fn = addDroppedAttachments,
        };
        self.registered_async_handlers[4] = .{ .name = commands.begin_attachment_add, .context = self, .invoke_fn = beginAttachmentAdd };
        self.registered_async_handlers[5] = .{ .name = commands.append_attachment_add, .context = self, .invoke_fn = appendAttachmentAdd };
        self.registered_async_handlers[6] = .{ .name = commands.finish_attachment_add, .context = self, .invoke_fn = finishAttachmentAdd };
        self.registered_async_handlers[7] = .{ .name = commands.cancel_attachment_add, .context = self, .invoke_fn = cancelAttachmentAdd };
        self.registered_async_handlers[8] = .{ .name = commands.release_preview, .context = self, .invoke_fn = releasePreview };
        self.registered_async_handlers[9] = .{ .name = commands.output_action, .context = self, .invoke_fn = outputAction };
        return .{
            .policy = policy,
            .registry = .{ .handlers = &self.registered_handlers },
            .async_registry = .{ .handlers = &self.registered_async_handlers },
        };
    }

    pub fn stopIngress(self: *Dispatcher) void {
        self.callbacks.stopIngress();
    }

    /// App closes the freshly constructed dispatcher until all startup product
    /// state has been committed, then opens it exactly once before the Native
    /// Runtime loads the first Renderer window.
    pub fn startIngress(self: *Dispatcher) void {
        self.callbacks.startIngress();
    }

    pub fn assertQuiescent(self: *Dispatcher) void {
        self.callbacks.assertQuiescent();
    }

    pub fn detachProductControl(self: *Dispatcher) void {
        if (self.control) |control| control.cancelSnapshot();
        self.mcp_management_host = null;
        self.control = null;
    }

    pub fn attachMcpManagementHost(
        self: *Dispatcher,
        host: McpManagementHost,
    ) void {
        std.debug.assert(self.control != null);
        std.debug.assert(self.mcp_management_host == null);
        self.mcp_management_host = host;
    }

    pub fn breakConnection(self: *Dispatcher) void {
        self.cancelOutputConnection();
        self.cancelPreviewConnection();
        if (self.control) |control| control.cancelSnapshot();
        self.delivery.breakConnection(self.transport());
        self.grants.invalidate();
        self.skill_grants.invalidate();
        self.releaseAllAttachmentGrants();
    }

    fn releaseAllAttachmentGrants(self: *Dispatcher) void {
        if (self.control) |workbench| for (self.attachment_in_flight) |slot| {
            if (slot.active) _ = workbench.cancelAttachmentStaging(slot.completion_id);
        };
        if (self.receive_active) |receive| {
            if (self.control) |workbench| {
                if (!workbench.attachmentWriterActive()) {
                    _ = workbench.cancelAttachmentPreparation(receive.product_id);
                    _ = workbench.cancelAttachmentReceive(receive.product_id);
                }
            }
        }
        self.receive_active = null;
        self.receive_high_water = 0;
        var ids: [attachment_grant.max_grants]u64 = undefined;
        const taken = self.attachment_grants.takeAll(&ids);
        const workbench = self.control orelse return;
        for (taken) |id| _ = workbench.releaseAttachment(id);
    }

    fn releaseAttachmentDescriptors(
        self: *Dispatcher,
        descriptors: []const product_control.AttachmentDescriptor,
    ) void {
        const workbench = self.control orelse return;
        for (descriptors) |descriptor| _ = workbench.releaseAttachment(descriptor.id);
    }

    pub fn connectedWindow(self: *const Dispatcher) ?native_sdk.platform.WindowId {
        return self.delivery.connectedWindow();
    }

    pub fn productDelivery(self: *Dispatcher) *product_delivery.Delivery {
        return &self.delivery;
    }

    pub fn onTimer(self: *Dispatcher, timer_id: u64) bool {
        if (timer_id == output_timer_id) {
            if (self.control) |control| control.drainOutputChecks(self.outputCheckSink());
            self.updateOutputTimer();
            return true;
        }
        if (timer_id == preview_timer_id) {
            if (self.control) |control| {
                control.drainFilePreviewCompletions(self.filePreviewSink());
                for (&self.preview_grants) |*entry| if (entry.*) |grant| {
                    if (!control.hasFilePreviewImage(grant.image.id)) entry.* = null;
                };
            }
            self.updatePreviewTimer();
            return true;
        }
        return self.delivery.onTimer(timer_id);
    }

    pub fn emitProductChanged(self: *Dispatcher) !void {
        const workbench = self.control orelse return;
        const revision = workbench.currentRevision();
        _ = self.delivery.deliverRevision(
            revision,
            workbench.projectionSecurityEpoch(),
            self.now(),
            self.transport(),
        ) catch |err| switch (err) {
            error.RevisionRetryExhausted, error.RevisionRetryUnavailable => {
                const revision_decision = product_control.decideTransportFailure(.{
                    .stage = .revision_delivery,
                });
                const connection_decision = product_control.decideTransportFailure(.{
                    .stage = .connection_generation,
                });
                std.debug.assert(revision_decision == .retry);
                std.debug.assert(connection_decision == .detach_renderer);
                self.breakConnection();
                return error.RuntimeRevisionDeliveryUnavailable;
            },
            else => return err,
        };
    }

    fn ping(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        self.sequence += 1;
        const on_main_thread = self.platform.on_main_thread_fn(self.platform.context);
        var detail_buffer: [512]u8 = undefined;
        const detail = try std.fmt.bufPrint(
            &detail_buffer,
            "{{\"sequence\":{d},\"transport\":\"Runtime.emitWindowEvent\",\"origin\":\"{s}\",\"onMainThread\":{},\"requestBytes\":{d}}}",
            .{ self.sequence, invocation.source.origin, on_main_thread, invocation.request.payload.len },
        );
        try self.platform.emit_fn(
            self.platform.context,
            invocation.source.window_id,
            event_name,
            detail,
        );
        return std.fmt.bufPrint(
            output,
            "{{\"sequence\":{d},\"transport\":\"BridgeDispatcher.response\",\"origin\":\"{s}\",\"onMainThread\":{}}}",
            .{ self.sequence, invocation.source.origin, on_main_thread },
        );
    }

    fn acknowledgeEvent(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        const acknowledged = try handlers.acknowledgementSequence(invocation.request.payload);
        if (acknowledged == 0 or acknowledged > self.sequence) return error.SequenceMismatch;
        self.acknowledged_sequence = @max(self.acknowledged_sequence, acknowledged);
        const on_main_thread = self.platform.on_main_thread_fn(self.platform.context);
        std.debug.print("metawork.smoke.event_ack sequence={d} origin={s} main_thread={}\n", .{
            acknowledged,
            invocation.source.origin,
            on_main_thread,
        });
        return std.fmt.bufPrint(
            output,
            "{{\"sequence\":{d},\"transport\":\"React.eventAck\",\"origin\":\"{s}\",\"onMainThread\":{}}}",
            .{
                acknowledged,
                invocation.source.origin,
                on_main_thread,
            },
        );
    }

    fn connectEvents(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireBootstrapWindow(invocation.source.window_id);
        if (self.delivery.connectedWindow()) |window_id|
            if (window_id != invocation.source.window_id) return error.EventWindowMismatch;
        errdefer self.breakConnection();
        var parsed = try handlers.parsePayload(
            handlers.RendererBridgeConnect,
            invocation.request.payload,
        );
        defer parsed.deinit();
        if (!std.mem.eql(u8, parsed.value.contractId, commands.contract_id)) {
            self.breakConnection();
            return std.fmt.bufPrint(
                output,
                "{{\"accepted\":false,\"contractId\":\"{s}\",\"contractRevision\":{d},\"generation\":null,\"error\":\"identity_mismatch\"}}",
                .{ commands.contract_id, commands.contract_revision },
            );
        }
        if (parsed.value.contractRevision != commands.contract_revision) {
            self.breakConnection();
            return std.fmt.bufPrint(
                output,
                "{{\"accepted\":false,\"contractId\":\"{s}\",\"contractRevision\":{d},\"generation\":null,\"error\":\"revision_mismatch\"}}",
                .{ commands.contract_id, commands.contract_revision },
            );
        }
        if (self.control) |control| control.cancelSnapshot();
        self.cancelPreviewConnection();
        const generation = try self.delivery.connect(invocation.source.window_id, self.transport());
        self.preview_high_water = 0;
        self.output_high_water = 0;
        self.grants.invalidate();
        self.skill_grants.invalidate();
        self.releaseAllAttachmentGrants();
        try self.platform.wake_fn(self.platform.context);
        return std.fmt.bufPrint(
            output,
            "{{\"accepted\":true,\"contractId\":\"{s}\",\"contractRevision\":{d},\"generation\":\"{d}\",\"error\":null,\"attachmentInput\":{{\"mode\":\"{s}\",\"maxChunkBytes\":\"{d}\"}}}}",
            .{ commands.contract_id, commands.contract_revision, generation, @tagName(self.platform.attachment_input), attachment_chunk_bytes },
        );
    }

    fn disconnectEvents(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        var parsed = try handlers.parsePayload(handlers.EventDisconnect, invocation.request.payload);
        defer parsed.deinit();
        const generation = try handlers.parseWireId(parsed.value.generation);
        try self.delivery.validateConnection(generation, invocation.source.window_id);
        defer self.grants.invalidate();
        defer self.skill_grants.invalidate();
        defer self.breakConnection();
        return std.fmt.bufPrint(output, "{{\"generation\":\"{d}\",\"detached\":true}}", .{generation});
    }

    fn connectWindowChrome(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireBootstrapWindow(invocation.source.window_id);
        if (!self.platform.on_main_thread_fn(self.platform.context))
            return error.InvalidBridgeThread;
        var parsed = try handlers.parsePayload(handlers.Empty, invocation.request.payload);
        defer parsed.deinit();
        self.window_chrome_connected = false;
        self.window_chrome_generation +%= 1;
        if (self.window_chrome_generation == 0) self.window_chrome_generation = 1;
        const environment = try self.platform.window_chrome_connect_fn(
            self.platform.context,
            invocation.source.window_id,
        );
        self.window_chrome_connected = true;
        return encodeWindowChromeEnvironment(
            output,
            self.window_chrome_generation,
            environment,
        );
    }

    fn refreshWindowChrome(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireBootstrapWindow(invocation.source.window_id);
        if (!self.platform.on_main_thread_fn(self.platform.context))
            return error.InvalidBridgeThread;
        var parsed = try handlers.parsePayload(handlers.WindowChromeRefresh, invocation.request.payload);
        defer parsed.deinit();
        const generation = try handlers.parseWireId(parsed.value.generation);
        try self.validateWindowChromeSession(invocation.source.window_id, generation);
        const environment = try self.platform.window_chrome_refresh_fn(
            self.platform.context,
            invocation.source.window_id,
        );
        return encodeWindowChromeEnvironment(output, generation, environment);
    }

    fn disconnectWindowChrome(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireBootstrapWindow(invocation.source.window_id);
        if (!self.platform.on_main_thread_fn(self.platform.context))
            return error.InvalidBridgeThread;
        var parsed = try handlers.parsePayload(handlers.WindowChromeDisconnect, invocation.request.payload);
        defer parsed.deinit();
        const generation = try handlers.parseWireId(parsed.value.generation);
        try self.validateWindowChromeSession(invocation.source.window_id, generation);
        self.window_chrome_connected = false;
        return std.fmt.bufPrint(output, "{{\"generation\":\"{d}\",\"detached\":true}}", .{generation});
    }

    fn controlWindowChrome(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireBootstrapWindow(invocation.source.window_id);
        if (!self.platform.on_main_thread_fn(self.platform.context))
            return error.InvalidBridgeThread;
        var parsed = try handlers.parsePayload(handlers.WindowChromeControl, invocation.request.payload);
        defer parsed.deinit();
        const action: WindowChromeControlAction = if (std.mem.eql(u8, parsed.value.action, "minimize"))
            .minimize
        else if (std.mem.eql(u8, parsed.value.action, "toggle_maximize"))
            .toggle_maximize
        else if (std.mem.eql(u8, parsed.value.action, "close"))
            .close
        else
            return error.InvalidBridgePayload;
        const generation = try handlers.parseWireId(parsed.value.generation);
        try self.validateWindowChromeSession(invocation.source.window_id, generation);
        try self.platform.window_chrome_control_fn(
            self.platform.context,
            invocation.source.window_id,
            action,
        );
        return encodeWindowChromeHandled(output, generation);
    }

    fn validateWindowChromeSession(
        self: *const Dispatcher,
        window_id: native_sdk.platform.WindowId,
        generation: u64,
    ) !void {
        if (!self.window_chrome_connected or
            window_id != self.bootstrap_window_id or
            generation == 0 or
            generation != self.window_chrome_generation)
            return error.StaleWindowChromeDocument;
    }

    fn openExternalLink(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireManagementAuthority(invocation.source.window_id);
        var parsed = try handlers.parsePayloadWithLimit(
            handlers.ExternalLinkOpen,
            invocation.request.payload,
            32 * 1024,
        );
        defer parsed.deinit();
        if (!validExternalLink(parsed.value.url))
            return encodeExternalLinkOutcome(output, "rejected");
        self.platform.open_external_url_fn(
            self.platform.context,
            parsed.value.url,
        ) catch return encodeExternalLinkOutcome(output, "unavailable");
        return encodeExternalLinkOutcome(output, "opened");
    }

    fn encodeExternalLinkOutcome(output: []u8, outcome: []const u8) ![]const u8 {
        return std.fmt.bufPrint(output, "{{\"outcome\":\"{s}\"}}", .{outcome});
    }

    fn encodeWindowChromeHandled(output: []u8, generation: u64) ![]const u8 {
        return std.fmt.bufPrint(output, "{{\"generation\":\"{d}\",\"handled\":true}}", .{generation});
    }

    fn encodeWindowChromeEnvironment(
        output: []u8,
        generation: u64,
        value: WindowChromePlatformEnvironment,
    ) ![]const u8 {
        return std.fmt.bufPrint(
            output,
            "{{\"generation\":\"{d}\",\"insets\":{{\"top\":{d},\"left\":{d},\"bottom\":{d},\"right\":{d}}},\"buttons\":{{\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d}}},\"rendererControls\":{},\"maximized\":{}}}",
            .{
                generation,
                value.top,
                value.left,
                value.bottom,
                value.right,
                value.buttons_x,
                value.buttons_y,
                value.buttons_width,
                value.buttons_height,
                value.renderer_controls,
                value.maximized,
            },
        );
    }

    fn beginSnapshot(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        if (invocation.request.payload.len > 16 * 1024) return error.InvalidPayload;
        var envelope = try std.json.parseFromSlice(std.json.Value, std.heap.c_allocator, invocation.request.payload, .{});
        defer envelope.deinit();
        if (envelope.value == .object and envelope.value.object.contains("preparingSnapshotId")) {
            var continuation = try handlers.parsePayload(handlers.ProductSnapshotContinue, invocation.request.payload);
            defer continuation.deinit();
            const control = try self.requireProductControl();
            const descriptor = try self.delivery.prepareSnapshot(invocation.source.window_id, control.projectionSecurityEpoch(), continuation.value.preparingSnapshotId.value, .{ .context = control, .prepare_fn = continueSnapshot });
            return encodeSnapshotDescriptor(output, descriptor);
        }
        var parsed = try handlers.parsePayloadWithLimit(handlers.ProductViewRequest, invocation.request.payload, 16 * 1024);
        defer parsed.deinit();
        var receipt_queries: [64]product_control.ViewReceiptQuery = undefined;
        var view = ViewWriteContext{ .control = try self.requireProductControl(), .request = try parsed.value.product(&receipt_queries) };
        const descriptor = self.delivery.publishSnapshot(
            invocation.source.window_id,
            view.control.projectionSecurityEpoch(),
            .{ .context = &view, .write_fn = writeSnapshot, .cancellation = .{ .context = view.control, .cancel_fn = cancelSnapshotRead } },
        ) catch |err| {
            std.debug.assert(product_control.decideTransportFailure(.{
                .stage = .snapshot_transport,
            }) == .retry);
            return err;
        };
        return encodeSnapshotDescriptor(output, descriptor);
    }

    fn cancelSnapshotRead(context: *anyopaque, read_id: u64) void {
        const control: *product_control.Runtime = @ptrCast(@alignCast(context));
        control.cancelSnapshotRead(read_id);
    }

    fn encodeSnapshotDescriptor(output: []u8, descriptor: product_delivery.SnapshotDescriptor) ![]const u8 {
        var writer = std.Io.Writer.fixed(output);
        if (descriptor.bytes == 0) {
            try std.json.Stringify.value(@import("snapshot_contract.zig").SnapshotPreparing{ .snapshotId = .{ .value = descriptor.id } }, .{}, &writer);
        } else {
            try std.json.Stringify.value(@import("snapshot_contract.zig").SnapshotDescriptor{
                .snapshotId = .{ .value = descriptor.id },
                .bytes = .{ .value = descriptor.bytes },
                .chunkBytes = .{ .value = product_delivery.snapshot_chunk_bytes },
            }, .{}, &writer);
        }
        return writer.buffered();
    }

    fn fetchSnapshotChunk(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        comptime {
            if (product_delivery.snapshot_chunk_bytes > product_control.projection_step_bytes) @compileError("Snapshot transport chunk exceeds the Product encoding step budget");
        }
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        var parsed = try handlers.parsePayload(
            handlers.ProductSnapshotChunk,
            invocation.request.payload,
        );
        defer parsed.deinit();
        const snapshot_id = parsed.value.snapshotId.value;
        const offset = std.math.cast(usize, parsed.value.offset.value) orelse return error.InvalidBridgePayload;
        const chunk = self.delivery.snapshotChunk(
            invocation.source.window_id,
            (try self.requireProductControl()).projectionSecurityEpoch(),
            snapshot_id,
            offset,
            .{ .context = try self.requireProductControl(), .write_fn = materializeSnapshot },
        ) catch |err| switch (err) {
            error.InvalidOffset => return error.InvalidBridgePayload,
            else => return err,
        };
        var writer = std.Io.Writer.fixed(output);
        writer.print(
            "{{\"snapshotId\":\"{d}\",\"offset\":{d},\"bytes\":{d},\"data\":\"",
            .{ snapshot_id, offset, chunk.len },
        ) catch return error.NoSpaceLeft;
        std.base64.standard.Encoder.encodeWriter(&writer, chunk) catch return error.NoSpaceLeft;
        writer.writeAll("\"}") catch return error.NoSpaceLeft;
        return writer.buffered();
    }

    fn outputAction(context: *anyopaque, invocation: native_sdk.bridge.Invocation, responder: native_sdk.bridge.AsyncResponder) anyerror!void {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        self.beginOutputAction(invocation, responder) catch {
            responder.fail(invocation.request.id, .handler_failed, "Output action rejected") catch {};
        };
    }

    fn requireOutputConnection(self: *Dispatcher, invocation: native_sdk.bridge.Invocation, generation: u64, operation: u64) !void {
        try self.requireWindow(invocation.source.window_id);
        if (!self.platform.on_main_thread_fn(self.platform.context)) return error.InvalidBridgeThread;
        if (generation == 0 or operation == 0) return error.InvalidBridgeId;
        try self.delivery.validateConnection(generation, invocation.source.window_id);
    }

    fn beginOutputAction(self: *Dispatcher, invocation: native_sdk.bridge.Invocation, responder: native_sdk.bridge.AsyncResponder) !void {
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        var parsed = try handlers.parsePayload(handlers.OutputAction, invocation.request.payload);
        defer parsed.deinit();
        const request = parsed.value;
        const generation = request.generation.value;
        const operation = request.operationId.value;
        try self.requireOutputConnection(invocation, generation, operation);
        if (operation <= self.output_high_water or request.taskId.value == 0 or request.runId.value == 0) return error.InvalidBridgeId;
        const id = try handlers.parseOutputId(request.outputId.value);
        self.output_high_water = operation;
        const control = try self.requireProductControl();
        const vacant = for (&self.output_in_flight) |*slot| {
            if (slot.* == null) break slot;
        } else {
            respondOutputAction(responder, invocation.request.id, generation, operation, .busy);
            return;
        };
        if (self.next_output_completion_id == std.math.maxInt(u64)) return error.Capacity;
        const completion = self.next_output_completion_id;
        self.next_output_completion_id += 1;
        vacant.* = .{ .completion_id = completion, .generation = generation, .operation_id = operation, .window_id = invocation.source.window_id, .responder = responder, .request_len = invocation.request.id.len, .request_id = undefined };
        @memcpy(vacant.*.?.request_id[0..invocation.request.id.len], invocation.request.id);
        switch (control.beginOutputCheck(completion, request.taskId.value, request.runId.value, id, request.action.value)) {
            .queued => {
                if (vacant.* == null or vacant.*.?.cancelled) _ = control.cancelOutputCheck(completion);
                self.updateOutputTimer();
            },
            .immediate => |state| self.completeOutputAction(.{ .completion_id = completion, .state = state }),
        }
    }

    pub fn outputCheckSink(self: *Dispatcher) product_control.OutputCheckSink {
        return .{ .context = self, .request_active_fn = outputRequestActive, .complete_fn = completeOutputFromSink };
    }

    fn outputRequestActive(context: *anyopaque, completion_id: u64) bool {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        for (self.output_in_flight) |entry| if (entry) |slot| {
            if (slot.completion_id != completion_id) continue;
            if (slot.cancelled) return false;
            self.delivery.validateConnection(slot.generation, slot.window_id) catch return false;
            return true;
        };
        return false;
    }

    fn completeOutputFromSink(context: *anyopaque, result: product_control.OutputCheckResult) void {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        self.completeOutputAction(result);
    }

    fn completeOutputAction(self: *Dispatcher, result: product_control.OutputCheckResult) void {
        for (&self.output_in_flight) |*entry| if (entry.*) |slot| {
            if (slot.completion_id != result.completion_id) continue;
            const active = outputRequestActive(self, result.completion_id);
            entry.* = null;
            respondOutputAction(slot.responder, slot.request_id[0..slot.request_len], slot.generation, slot.operation_id, if (active or result.committed or result.state == .cleanup_failed) result.state else .cancelled);
            self.updateOutputTimer();
            return;
        };
    }

    fn respondOutputAction(responder: native_sdk.bridge.AsyncResponder, request_id: []const u8, generation: u64, operation: u64, state: product_control.OutputCheckState) void {
        var buffer: [256]u8 = undefined;
        const result = std.fmt.bufPrint(&buffer, "{{\"generation\":\"{d}\",\"operationId\":\"{d}\",\"state\":\"{s}\"}}", .{ generation, operation, @tagName(state) }) catch unreachable;
        responder.success(request_id, result) catch {};
    }

    fn cancelOutputAction(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        var parsed = try handlers.parsePayload(handlers.OutputActionCancel, invocation.request.payload);
        defer parsed.deinit();
        const generation = parsed.value.generation.value;
        const operation = parsed.value.operationId.value;
        try self.requireOutputConnection(invocation, generation, operation);
        var cancelled = false;
        for (&self.output_in_flight) |*entry| if (entry.*) |*slot| {
            if (slot.generation != generation or slot.operation_id != operation or slot.window_id != invocation.source.window_id) continue;
            if (self.control) |control| {
                if (control.outputPublicationCommitted(slot.completion_id)) break;
                _ = control.cancelOutputCheck(slot.completion_id);
            }
            slot.cancelled = true;
            cancelled = true;
            break;
        };
        return std.fmt.bufPrint(output, "{{\"generation\":\"{d}\",\"operationId\":\"{d}\",\"cancelled\":{}}}", .{ generation, operation, cancelled });
    }

    fn updateOutputTimer(self: *Dispatcher) void {
        const active = if (self.control) |control| control.hasOutputChecks() else false;
        if (active and !self.output_timer_armed) {
            self.platform.start_timer_fn(self.platform.context, output_timer_id, 250 * std.time.ns_per_ms, true) catch {
                self.cancelOutputConnection();
                return;
            };
            self.output_timer_armed = true;
        } else if (!active and self.output_timer_armed) {
            self.platform.cancel_timer_fn(self.platform.context, output_timer_id) catch {};
            self.output_timer_armed = false;
        }
    }

    fn cancelOutputConnection(self: *Dispatcher) void {
        for (&self.output_in_flight) |*entry| if (entry.*) |*slot| {
            slot.cancelled = true;
            if (self.control) |control| _ = control.cancelOutputCheck(slot.completion_id);
        };
    }

    pub fn settleOutputActionsForShutdown(self: *Dispatcher) void {
        if (self.output_timer_armed) self.platform.cancel_timer_fn(self.platform.context, output_timer_id) catch {};
        self.output_timer_armed = false;
        for (&self.output_in_flight) |*entry| if (entry.*) |slot| {
            entry.* = null;
            respondOutputAction(slot.responder, slot.request_id[0..slot.request_len], slot.generation, slot.operation_id, .cancelled);
        };
    }

    fn requirePreviewKey(self: *Dispatcher, invocation: native_sdk.bridge.Invocation, generation_text: []const u8, preview_text: []const u8) !struct { generation: u64, preview_id: u64 } {
        try self.requireWindow(invocation.source.window_id);
        if (!self.platform.on_main_thread_fn(self.platform.context)) return error.InvalidBridgeThread;
        const generation = try handlers.parseWireId(generation_text);
        const preview_id = try handlers.parseWireId(preview_text);
        if (preview_id == 0) return error.InvalidBridgeId;
        try self.delivery.validateConnection(generation, invocation.source.window_id);
        return .{ .generation = generation, .preview_id = preview_id };
    }

    fn previewFile(context: *anyopaque, invocation: native_sdk.bridge.Invocation, responder: native_sdk.bridge.AsyncResponder) anyerror!void {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        self.beginPreview(invocation, responder) catch {
            respondFilePreview(responder, invocation.request.id, .failed, "", false, false, null);
        };
    }
    fn beginPreview(self: *Dispatcher, invocation: native_sdk.bridge.Invocation, responder: native_sdk.bridge.AsyncResponder) !void {
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        var parsed = try handlers.parsePayload(handlers.FilePreviewRequest, invocation.request.payload);
        defer parsed.deinit();
        const key = try self.requirePreviewKey(invocation, parsed.value.generation, parsed.value.previewId);
        if (key.preview_id <= self.preview_high_water or parsed.value.fileReferenceId.len == 0 or parsed.value.fileReferenceId.len > 128) return error.InvalidBridgePayload;
        self.preview_high_water = key.preview_id;
        const task_id = try handlers.parseWireId(parsed.value.taskId);
        const run_id = try handlers.parseWireId(parsed.value.runId);
        const control = try self.requireProductControl();
        const id = self.reserveFilePreview(responder, invocation.request.id) orelse {
            respondFilePreview(responder, invocation.request.id, .busy, "", false, false, null);
            return;
        };
        for (&self.preview_in_flight) |*slot| if (slot.active and slot.completion_id == id) {
            slot.generation = key.generation;
            slot.preview_id = key.preview_id;
            slot.window_id = invocation.source.window_id;
            break;
        };
        switch (control.beginFilePreview(id, task_id, run_id, parsed.value.fileReferenceId)) {
            .queued => self.updatePreviewTimer(),
            .immediate => |state| self.completeFilePreview(.{ .completion_id = id, .state = state, .content = "", .truncated = false, .redacted = false }),
        }
    }
    fn reserveFilePreview(self: *Dispatcher, responder: native_sdk.bridge.AsyncResponder, request_id: []const u8) ?u64 {
        if (self.next_preview_completion_id == std.math.maxInt(u64)) return null;
        for (&self.preview_in_flight) |*slot| {
            if (slot.active) continue;
            const id = self.next_preview_completion_id;
            self.next_preview_completion_id += 1;
            slot.* = .{ .active = true, .completion_id = id, .responder = responder, .request_id_len = request_id.len };
            @memcpy(slot.request_id_storage[0..request_id.len], request_id);
            return id;
        }
        return null;
    }
    pub fn filePreviewSink(self: *Dispatcher) product_control.FilePreviewSink {
        return .{ .context = self, .complete_fn = completeFilePreviewFromSink };
    }
    fn completeFilePreviewFromSink(context: *anyopaque, result: product_control.FilePreviewResult) void {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        self.completeFilePreview(result);
    }
    fn completeFilePreview(self: *Dispatcher, result: product_control.FilePreviewResult) void {
        for (&self.preview_in_flight) |*slot| {
            if (!slot.active or slot.completion_id != result.completion_id) continue;
            const pending = slot.*;
            slot.* = .{};
            var state = result.state;
            const connected = if (self.delivery.validateConnection(pending.generation, pending.window_id)) |_| true else |_| false;
            if (pending.cancelled or !connected) state = .failed;
            var descriptor: ?PreviewImage = null;
            if (result.image) |image| {
                if (state == .ready) {
                    const vacant = for (&self.preview_grants) |*entry| {
                        if (entry.* == null) break entry;
                    } else null;
                    var random: [24]u8 = undefined;
                    if (vacant != null and self.platform.random_fn(self.platform.context, &random)) {
                        vacant.?.* = .{ .token = std.fmt.bytesToHex(random, .lower), .image = image, .generation = pending.generation, .window_id = pending.window_id, .preview_id = pending.preview_id };
                        descriptor = .{ .token = &vacant.?.*.?.token, .image = image };
                    } else state = .failed;
                }
                if (descriptor == null) if (self.control) |control| {
                    _ = control.releaseFilePreview(image.id);
                };
            }
            respondFilePreview(pending.responder, pending.request_id_storage[0..pending.request_id_len], state, result.content, result.truncated, result.redacted, descriptor);
            if (pending.release_waiter) |waiter| respondPreviewRelease(waiter.responder, waiter.request_id[0..waiter.request_len], pending.generation, pending.preview_id);
            self.updatePreviewTimer();
            return;
        }
        if (result.image) |image| if (self.control) |control| {
            _ = control.releaseFilePreview(image.id);
        };
    }
    fn respondPreviewRelease(responder: native_sdk.bridge.AsyncResponder, id: []const u8, generation: u64, preview_id: u64) void {
        var buffer: [180]u8 = undefined;
        const response = std.fmt.bufPrint(&buffer, "{{\"generation\":\"{d}\",\"previewId\":\"{d}\",\"released\":true}}", .{ generation, preview_id }) catch unreachable;
        responder.success(id, response) catch {};
    }
    fn releasePreview(context: *anyopaque, invocation: native_sdk.bridge.Invocation, responder: native_sdk.bridge.AsyncResponder) anyerror!void {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        self.releasePreviewChecked(invocation, responder) catch {
            responder.fail(invocation.request.id, .handler_failed, "Invalid preview release") catch {};
        };
    }
    fn releasePreviewChecked(self: *Dispatcher, invocation: native_sdk.bridge.Invocation, responder: native_sdk.bridge.AsyncResponder) !void {
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        var parsed = try handlers.parsePayload(handlers.FilePreviewKey, invocation.request.payload);
        defer parsed.deinit();
        const key = try self.requirePreviewKey(invocation, parsed.value.generation, parsed.value.previewId);
        self.preview_high_water = @max(self.preview_high_water, key.preview_id);
        for (&self.preview_in_flight) |*slot| {
            if (!slot.active or slot.generation != key.generation or slot.preview_id != key.preview_id) continue;
            if (slot.release_waiter != null) return error.InvalidBridgePayload;
            slot.cancelled = true;
            var waiter: PreviewRelease = .{ .responder = responder, .request_len = invocation.request.id.len };
            @memcpy(waiter.request_id[0..waiter.request_len], invocation.request.id);
            slot.release_waiter = waiter;
            _ = (try self.requireProductControl()).releaseFilePreview(slot.completion_id);
            return;
        }
        for (&self.preview_grants) |*entry| if (entry.*) |grant| {
            if (grant.generation != key.generation or grant.preview_id != key.preview_id) continue;
            _ = (try self.requireProductControl()).releaseFilePreview(grant.image.id);
            entry.* = null;
            break;
        };
        respondPreviewRelease(responder, invocation.request.id, key.generation, key.preview_id);
        self.updatePreviewTimer();
    }
    fn readPreviewImage(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        var parsed = try handlers.parsePayload(handlers.FilePreviewChunkRequest, invocation.request.payload);
        defer parsed.deinit();
        const key = try self.requirePreviewKey(invocation, parsed.value.generation, parsed.value.previewId);
        const offset = std.math.cast(usize, try handlers.parseWireId(parsed.value.offset)) orelse return error.InvalidBridgePayload;
        const control = try self.requireProductControl();
        if (try handlers.parseWireId(parsed.value.securityEpoch) != control.projectionSecurityEpoch())
            return std.fmt.bufPrint(output, "{{\"state\":\"stale_security\"}}", .{});
        for (&self.preview_grants) |*entry| if (entry.*) |*grant| {
            if (grant.generation != key.generation or grant.preview_id != key.preview_id or grant.window_id != invocation.source.window_id or !std.mem.eql(u8, &grant.token, parsed.value.token)) continue;
            if (grant.image.security_epoch != control.projectionSecurityEpoch()) {
                _ = control.releaseFilePreview(grant.image.id);
                entry.* = null;
                return std.fmt.bufPrint(output, "{{\"state\":\"stale_security\"}}", .{});
            }
            const bytes = control.readFilePreviewImage(grant.image.id, offset) catch |err| {
                _ = control.releaseFilePreview(grant.image.id);
                entry.* = null;
                return std.fmt.bufPrint(output, "{{\"state\":\"{s}\"}}", .{switch (err) {
                    error.StaleSecurityEpoch => "stale_security",
                    error.RestrictedPreview => "restricted",
                    error.MissingPreview => "expired",
                    else => "error",
                }});
            };
            var writer = std.Io.Writer.fixed(output);
            try writer.print("{{\"state\":\"ready\",\"token\":\"{s}\",\"offset\":\"{d}\",\"bytes\":\"{d}\",\"dataBase64\":\"", .{ grant.token, offset, bytes.len });
            const encoded = try writer.writableSlice(std.base64.standard.Encoder.calcSize(bytes.len));
            _ = std.base64.standard.Encoder.encode(encoded, bytes);
            try writer.writeAll("\"}");
            return writer.buffered();
        };
        return std.fmt.bufPrint(output, "{{\"state\":\"expired\"}}", .{});
    }
    fn updatePreviewTimer(self: *Dispatcher) void {
        const active = if (self.control) |control| control.hasFilePreviews() else false;
        if (active and !self.preview_timer_armed) {
            self.platform.start_timer_fn(self.platform.context, preview_timer_id, 250 * std.time.ns_per_ms, true) catch {
                self.cancelPreviewConnection();
                return;
            };
            self.preview_timer_armed = true;
        } else if (!active and self.preview_timer_armed) {
            self.platform.cancel_timer_fn(self.platform.context, preview_timer_id) catch {};
            self.preview_timer_armed = false;
        }
    }
    fn cancelPreviewConnection(self: *Dispatcher) void {
        if (self.control) |control| {
            for (&self.preview_in_flight) |*slot| if (slot.active) {
                slot.cancelled = true;
                _ = control.releaseFilePreview(slot.completion_id);
            };
            for (&self.preview_grants) |*entry| if (entry.*) |grant| {
                _ = control.releaseFilePreview(grant.image.id);
                entry.* = null;
            };
        }
        if (self.preview_timer_armed) self.platform.cancel_timer_fn(self.platform.context, preview_timer_id) catch {};
        self.preview_timer_armed = false;
    }
    pub fn settleFilePreviewsForShutdown(self: *Dispatcher) void {
        self.cancelPreviewConnection();
        for (&self.preview_in_flight) |*slot| {
            if (!slot.active) continue;
            const pending = slot.*;
            slot.* = .{};
            respondFilePreview(pending.responder, pending.request_id_storage[0..pending.request_id_len], .failed, "", false, false, null);
            if (pending.release_waiter) |waiter| respondPreviewRelease(waiter.responder, waiter.request_id[0..waiter.request_len], pending.generation, pending.preview_id);
        }
    }
    fn respondFilePreview(responder: native_sdk.bridge.AsyncResponder, request_id: []const u8, state: product_control.FilePreviewState, content: []const u8, truncated: bool, redacted: bool, image: ?PreviewImage) void {
        var buffer: [native_sdk.bridge.max_result_bytes]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        writer.print("{{\"state\":\"{s}\",\"content\":", .{switch (state) {
            .ready => "ready",
            .busy => "busy",
            .stale_security => "stale_security",
            .missing => "missing",
            .restricted => "restricted",
            .unsupported, .image_limit, .animated_image => "unsupported",
            .changing => "changing",
            .failed => "error",
        }}) catch {
            responder.fail(request_id, .internal_error, "Preview encoding failed") catch {};
            return;
        };
        std.json.Stringify.value(if (state == .ready) content else "", .{}, &writer) catch {
            responder.fail(request_id, .internal_error, "Preview encoding failed") catch {};
            return;
        };
        if (state == .image_limit or state == .animated_image) {
            writer.print(",\"reason\":\"{s}\"", .{if (state == .image_limit) "image_limit" else "animated_image"}) catch {
                responder.fail(request_id, .internal_error, "Preview encoding failed") catch {};
                return;
            };
        }
        if (state == .ready) if (image) |descriptor| {
            const info = descriptor.image;
            writer.print(",\"image\":{{\"token\":\"{s}\",\"mediaType\":\"{s}\",\"sizeBytes\":\"{d}\",\"width\":{d},\"height\":{d},\"chunkBytes\":\"{d}\",\"securityEpoch\":\"{d}\"}}", .{ descriptor.token, info.media_type, info.size_bytes, info.width, info.height, product_control.file_preview_chunk_bytes, info.security_epoch }) catch {
                responder.fail(request_id, .internal_error, "Preview encoding failed") catch {};
                return;
            };
        };
        writer.print(",\"truncated\":{},\"redacted\":{}}}", .{ state == .ready and truncated, state == .ready and redacted }) catch {
            responder.fail(request_id, .internal_error, "Preview encoding failed") catch {};
            return;
        };
        responder.success(request_id, writer.buffered()) catch {};
    }

    fn requireReceiveKey(self: *Dispatcher, invocation: native_sdk.bridge.Invocation, generation_text: []const u8, batch_text: []const u8) !struct { generation: u64, batch_id: u64 } {
        try self.requireBootstrapWindow(invocation.source.window_id);
        if (!self.platform.on_main_thread_fn(self.platform.context)) return error.InvalidBridgeThread;
        if (self.platform.attachment_input != .file_bytes) return error.InvalidBridgePayload;
        const generation = try handlers.parseWireId(generation_text);
        const batch_id = try handlers.parseWireId(batch_text);
        if (batch_id == 0) return error.InvalidBridgeId;
        try self.delivery.validateConnection(generation, invocation.source.window_id);
        return .{ .generation = generation, .batch_id = batch_id };
    }

    fn receiveRejected(output: []u8, err: anyerror) ![]const u8 {
        const reason: []const u8 = switch (err) {
            error.FileTooLarge => "file_too_large",
            error.TextFileTooLarge => "text_file_too_large",
            error.TooManyFiles => "too_many_files",
            error.StagingCapacity, error.InputBusy, error.OutOfMemory, error.IdentityExhausted => "staging_capacity",
            error.ExecutorShuttingDown => "shutting_down",
            error.StaleTransfer => "stale_transfer",
            error.EmptyFile, error.InvalidDisplayName, error.ReadFailed, error.WriteFailed => "read_failed",
            error.FileChanged => "file_changed",
            error.UnsupportedType => "unsupported_type",
            else => "invalid_transfer",
        };
        return std.fmt.bufPrint(output, "{{\"status\":\"rejected\",\"reason\":\"{s}\"}}", .{reason});
    }

    fn beginAttachmentReceive(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        var parsed = try handlers.parsePayloadWithLimit(handlers.AttachmentReceiveBegin, invocation.request.payload, 32 * 1024);
        defer parsed.deinit();
        const key = try self.requireReceiveKey(invocation, parsed.value.generation, parsed.value.batchId);
        if (key.batch_id <= self.receive_high_water) return receiveRejected(output, error.StaleTransfer);
        self.receive_high_water = key.batch_id;
        if (self.receive_active != null) return receiveRejected(output, error.StagingCapacity);
        var files: [attachment_grant.max_grants]product_control.AttachmentReceiveFile = undefined;
        if (parsed.value.files.len == 0 or parsed.value.files.len > files.len) return receiveRejected(output, error.TooManyFiles);
        for (parsed.value.files, 0..) |file, index| {
            const size = handlers.parseWireId(file.sizeBytes) catch return receiveRejected(output, error.InvalidTransfer);
            files[index] = .{ .display_name = file.name, .size_bytes = std.math.cast(usize, size) orelse return receiveRejected(output, error.FileTooLarge) };
        }
        const workbench = try self.requireProductControl();
        const id = workbench.beginAttachmentReceive(files[0..parsed.value.files.len]) catch |err| return receiveRejected(output, err);
        self.receive_active = .{ .batch_id = key.batch_id, .product_id = id };
        return "{\"status\":\"accepted\"}";
    }

    fn appendAttachmentReceive(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        var parsed = try handlers.parsePayloadWithLimit(handlers.AttachmentReceiveAppend, invocation.request.payload, 192 * 1024);
        defer parsed.deinit();
        const key = try self.requireReceiveKey(invocation, parsed.value.generation, parsed.value.batchId);
        const active = self.receive_active orelse return receiveRejected(output, error.StaleTransfer);
        if (active.unified) return receiveRejected(output, error.InvalidTransfer);
        if (active.batch_id != key.batch_id) return receiveRejected(output, error.StaleTransfer);
        const offset = handlers.parseWireId(parsed.value.offset) catch return receiveRejected(output, error.InvalidTransfer);
        var bytes: [attachment_chunk_bytes]u8 = undefined;
        defer std.crypto.secureZero(u8, &bytes);
        const decoder = std.base64.standard.Decoder;
        const size = decoder.calcSizeForSlice(parsed.value.dataBase64) catch return receiveRejected(output, error.InvalidTransfer);
        if (size == 0 or size > bytes.len) return receiveRejected(output, error.InvalidTransfer);
        decoder.decode(bytes[0..size], parsed.value.dataBase64) catch return receiveRejected(output, error.InvalidTransfer);
        const workbench = try self.requireProductControl();
        workbench.appendAttachmentReceive(active.product_id, parsed.value.fileIndex, std.math.cast(usize, offset) orelse return receiveRejected(output, error.InvalidTransfer), bytes[0..size]) catch |err| return receiveRejected(output, err);
        return "{\"status\":\"accepted\"}";
    }

    fn finishAttachmentReceive(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        var parsed = try handlers.parsePayload(handlers.AttachmentReceiveKey, invocation.request.payload);
        defer parsed.deinit();
        const key = try self.requireReceiveKey(invocation, parsed.value.generation, parsed.value.batchId);
        const active = self.receive_active orelse return receiveRejected(output, error.StaleTransfer);
        if (active.unified) return receiveRejected(output, error.InvalidTransfer);
        if (active.batch_id != key.batch_id) return receiveRejected(output, error.StaleTransfer);
        const workbench = try self.requireProductControl();
        var descriptors: [attachment_grant.max_grants]product_control.AttachmentDescriptor = undefined;
        const ready = workbench.finishAttachmentReceive(active.product_id, &descriptors) catch |err| {
            _ = workbench.cancelAttachmentReceive(active.product_id);
            self.receive_active = null;
            return receiveRejected(output, err);
        };
        self.receive_active = null;
        var ids: [attachment_grant.max_grants]u64 = undefined;
        for (ready, 0..) |descriptor, index| ids[index] = descriptor.id;
        var issued_storage: [attachment_grant.max_grants]attachment_grant.Issued = undefined;
        const issued = self.attachment_grants.issueBatch(key.generation, invocation.source.window_id, ids[0..ready.len], &issued_storage, self.platform.context, self.platform.random_fn) catch {
            self.releaseAttachmentDescriptors(ready);
            if (workbench.attachmentCleanupPending(active.product_id, null)) {
                self.rememberAddDebt(.{ .generation = key.generation, .window_id = invocation.source.window_id, .batch_id = key.batch_id, .product_id = active.product_id });
                return error.CleanupFailed;
            }
            return receiveRejected(output, error.StagingCapacity);
        };
        self.attachment_grants.tagReceiveBatch(ids[0..ready.len], key.batch_id);
        errdefer _ = self.cancelReceiveBatch(key.generation, invocation.source.window_id, key.batch_id) catch {};
        return encodeAttachmentsReady(output, ready, issued);
    }

    fn cancelReceiveBatch(self: *Dispatcher, generation: u64, window_id: native_sdk.platform.WindowId, batch_id: u64) !bool {
        const workbench = self.control orelse return false;
        var released = false;
        var failed = false;
        if (self.receive_active) |active| if (active.batch_id == batch_id) {
            if (active.unified) return error.InvalidTransfer;
            released = workbench.cancelAttachmentReceiveChecked(active.product_id) catch cleanup: {
                failed = true;
                self.rememberAddDebt(.{ .generation = generation, .window_id = window_id, .batch_id = batch_id, .product_id = active.product_id });
                break :cleanup false;
            };
            self.receive_active = null;
        };
        var ids: [attachment_grant.max_grants]u64 = undefined;
        for (self.attachment_grants.takeReceiveBatch(generation, window_id, batch_id, &ids)) |id| {
            released = (workbench.releaseAttachmentChecked(id) catch cleanup: {
                failed = true;
                self.rememberAddDebt(.{ .generation = generation, .window_id = window_id, .batch_id = batch_id, .attachment_id = id });
                break :cleanup false;
            }) or released;
        }
        self.receive_high_water = @max(self.receive_high_water, batch_id);
        if (failed or self.hasAddDebt(generation, window_id, batch_id)) return error.CleanupFailed;
        return released;
    }

    fn cancelAttachmentReceive(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        var parsed = try handlers.parsePayload(handlers.AttachmentReceiveKey, invocation.request.payload);
        defer parsed.deinit();
        const key = try self.requireReceiveKey(invocation, parsed.value.generation, parsed.value.batchId);
        return std.fmt.bufPrint(output, "{{\"released\":{}}}", .{try self.cancelReceiveBatch(key.generation, invocation.source.window_id, key.batch_id)});
    }

    fn requireAddKey(self: *Dispatcher, invocation: native_sdk.bridge.Invocation, generation_text: []const u8, batch_text: []const u8) !struct { generation: u64, batch_id: u64 } {
        try self.requireBootstrapWindow(invocation.source.window_id);
        if (!self.platform.on_main_thread_fn(self.platform.context)) return error.InvalidBridgeThread;
        const generation = try handlers.parseWireId(generation_text);
        const batch_id = try handlers.parseWireId(batch_text);
        if (generation == 0 or batch_id == 0) return error.InvalidBridgeId;
        try self.delivery.validateConnection(generation, invocation.source.window_id);
        return .{ .generation = generation, .batch_id = batch_id };
    }
    fn respondAddError(responder: native_sdk.bridge.AsyncResponder, request_id: []const u8, err: anyerror) void {
        var buffer: [256]u8 = undefined;
        const reason: []const u8 = switch (err) {
            error.InputBusy => "input_busy",
            error.CleanupFailed, error.DeleteFailed => "cleanup_failed",
            error.StaleTransfer => "stale_transfer",
            error.InvalidTransfer => "invalid_transfer",
            error.UnsupportedType, error.EmptyFile, error.InvalidDisplayName => "unsupported_type",
            error.FileTooLarge => "file_too_large",
            error.FileChanged => "file_changed",
            error.TooManyFiles, error.EmptyBatch => "too_many_files",
            error.StagingCapacity, error.Capacity, error.OutOfMemory, error.IdentityExhausted => "staging_capacity",
            error.ShuttingDown, error.ExecutorShuttingDown => "shutting_down",
            else => "read_failed",
        };
        const value = std.fmt.bufPrint(&buffer, "{{\"status\":\"rejected\",\"reason\":\"{s}\"}}", .{reason}) catch unreachable;
        responder.success(request_id, value) catch {};
    }
    fn addSlot(self: *Dispatcher, responder: native_sdk.bridge.AsyncResponder, request_id: []const u8, generation: u64, window: native_sdk.platform.WindowId, batch: u64) ?u64 {
        const id = self.reserveAttachmentStaging(responder, request_id, generation, window) orelse return null;
        for (&self.attachment_in_flight) |*slot| if (slot.active and slot.completion_id == id) {
            slot.batch_id = batch;
            break;
        };
        return id;
    }
    fn addPaths(paths: []const []const u8, output: []u8) ![]const u8 {
        if (paths.len == 0 or paths.len > attachment_grant.max_grants) return error.TooManyFiles;
        var used: usize = 0;
        for (paths, 0..) |path, index| {
            if (path.len == 0 or !std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, '\n') != null) return error.InvalidBridgePayload;
            if (index != 0) {
                if (used == output.len) return error.InvalidBridgePayload;
                output[used] = '\n';
                used += 1;
            }
            if (path.len > output.len - used) return error.InvalidBridgePayload;
            @memcpy(output[used..][0..path.len], path);
            used += path.len;
        }
        return output[0..used];
    }
    fn beginAttachmentAdd(context: *anyopaque, invocation: native_sdk.bridge.Invocation, responder: native_sdk.bridge.AsyncResponder) anyerror!void {
        beginAttachmentAddChecked(context, invocation, responder) catch |err| {
            // Async admission rejection is a command failure, not an SDK event
            // callback failure that stops the background host.
            responder.fail(invocation.request.id, .handler_failed, @errorName(err)) catch {};
        };
    }
    fn beginAttachmentAddChecked(context: *anyopaque, invocation: native_sdk.bridge.Invocation, responder: native_sdk.bridge.AsyncResponder) anyerror!void {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        var parsed = try handlers.parsePayloadWithLimit(handlers.AttachmentAddBegin, invocation.request.payload, native_sdk.platform.max_drop_paths_bytes * 2);
        defer parsed.deinit();
        const value = parsed.value;
        const key = try self.requireAddKey(invocation, value.generation, value.batchId);
        const source = value.source;
        var shape = try handlers.parsePayloadWithLimit(std.json.Value, invocation.request.payload, native_sdk.platform.max_drop_paths_bytes * 2);
        defer shape.deinit();
        const source_shape = shape.value.object.get("source").?.object;
        if (source_shape.count() != (if (source.kind == .picker) @as(usize, 1) else @as(usize, 2))) return error.InvalidBridgePayload;
        switch (source.kind) {
            .picker => if (source.paths != null or source.files != null) return error.InvalidBridgePayload,
            .native_paths => if (self.platform.attachment_input != .native_paths or source.paths == null or source.files != null) return error.InvalidBridgePayload,
            .file_bytes => if (source.files == null or source.paths != null) return error.InvalidBridgePayload,
        }
        if (key.batch_id <= self.receive_high_water) {
            respondAddError(responder, invocation.request.id, error.StaleTransfer);
            return;
        }
        self.receive_high_water = key.batch_id;
        if (self.receive_active != null or self.add_cancel != null) {
            respondAddError(responder, invocation.request.id, error.InputBusy);
            return;
        }
        const workbench = try self.requireProductControl();
        if (source.kind == .file_bytes) {
            const files = source.files.?;
            if (files.len == 0 or files.len > attachment_grant.max_grants) {
                respondAddError(responder, invocation.request.id, error.TooManyFiles);
                return;
            }
            var metadata: [attachment_grant.max_grants]product_control.AttachmentReceiveFile = undefined;
            for (files, 0..) |file, index| {
                const size = try handlers.parseWireId(file.sizeBytes);
                metadata[index] = .{ .display_name = file.name, .size_bytes = std.math.cast(usize, size) orelse {
                    respondAddError(responder, invocation.request.id, error.FileTooLarge);
                    return;
                } };
            }
            const product_id = workbench.prepareAttachmentAdd() catch |err| {
                respondAddError(responder, invocation.request.id, err);
                return;
            };
            const completion = self.addSlot(responder, invocation.request.id, key.generation, invocation.source.window_id, key.batch_id) orelse {
                _ = workbench.cancelAttachmentPreparation(product_id);
                respondAddError(responder, invocation.request.id, error.InputBusy);
                return;
            };
            self.receive_active = .{ .batch_id = key.batch_id, .product_id = product_id, .unified = true, .bytes = true };
            workbench.beginPreparedAttachmentBytes(completion, product_id, metadata[0..files.len]) catch |err| {
                self.completeAttachmentStaging(completion, .{ .rejected = addRejection(err) });
                return;
            };
            return;
        }
        var path_storage: [native_sdk.platform.max_drop_paths_bytes]u8 = undefined;
        const paths = if (source.kind == .native_paths) addPaths(source.paths.?, &path_storage) catch |err| {
            if (err != error.TooManyFiles) return err;
            respondAddError(responder, invocation.request.id, err);
            return;
        } else &.{};
        const product_id = workbench.prepareAttachmentAdd() catch |err| {
            respondAddError(responder, invocation.request.id, err);
            return;
        };
        const completion = self.addSlot(responder, invocation.request.id, key.generation, invocation.source.window_id, key.batch_id) orelse {
            _ = workbench.cancelAttachmentPreparation(product_id);
            respondAddError(responder, invocation.request.id, error.InputBusy);
            return;
        };
        self.receive_active = .{ .batch_id = key.batch_id, .product_id = product_id, .unified = true, .bytes = false };
        var dialog_storage: [native_sdk.platform.max_dialog_paths_bytes]u8 = undefined;
        const selected = if (source.kind == .native_paths) native_sdk.platform.OpenDialogResult{ .paths = paths, .count = source.paths.?.len } else if (self.automation.active()) automation: {
            const selected_paths = self.automation.attachmentPaths() orelse {
                _ = workbench.cancelAttachmentPreparation(product_id);
                self.completeAttachmentStaging(completion, .{ .rejected = .read_failed });
                return;
            };
            const count = countAutomationAttachmentPaths(selected_paths) orelse {
                _ = workbench.cancelAttachmentPreparation(product_id);
                self.completeAttachmentStaging(completion, .{ .rejected = .read_failed });
                return;
            };
            break :automation native_sdk.platform.OpenDialogResult{ .paths = selected_paths, .count = count };
        } else self.platform.show_open_dialog_fn(self.platform.context, .{ .title = "Choose files", .allow_directories = false, .allow_multiple = true }, &dialog_storage) catch {
            _ = workbench.cancelAttachmentPreparation(product_id);
            self.completeAttachmentStaging(completion, .{ .rejected = .read_failed });
            return;
        };
        const active = self.receive_active;
        if (active == null or active.?.product_id != product_id or self.delivery.connectedGeneration() != key.generation or self.delivery.connectedWindow() != invocation.source.window_id) {
            _ = workbench.cancelAttachmentPreparation(product_id);
            self.completeAttachmentStaging(completion, .cancelled);
            return;
        }
        if (selected.count == 0) {
            _ = workbench.cancelAttachmentPreparation(product_id);
            self.completeAttachmentStaging(completion, .cancelled);
            return;
        }
        workbench.beginPreparedAttachmentStaging(completion, product_id, selected.count, selected.paths) catch |err| {
            _ = workbench.cancelAttachmentPreparation(product_id);
            self.completeAttachmentStaging(completion, .{ .rejected = addRejection(err) });
        };
    }
    fn addRejection(err: anyerror) product_control.AttachmentStagingRejection {
        return switch (err) {
            error.InvalidTransfer => .invalid_transfer,
            error.StaleTransfer => .stale_transfer,
            error.InputBusy => .input_busy,
            error.CleanupFailed, error.DeleteFailed => .cleanup_failed,
            error.UnsupportedType, error.EmptyFile, error.InvalidDisplayName => .unsupported_type,
            error.TooManyFiles, error.EmptyBatch => .too_many_files,
            error.FileTooLarge => .file_too_large,
            error.FileChanged => .file_changed,
            error.StagingCapacity, error.OutOfMemory, error.Capacity, error.IdentityExhausted => .staging_capacity,
            error.ShuttingDown, error.ExecutorShuttingDown => .shutting_down,
            else => .read_failed,
        };
    }
    fn appendAttachmentAdd(context: *anyopaque, invocation: native_sdk.bridge.Invocation, responder: native_sdk.bridge.AsyncResponder) anyerror!void {
        appendAttachmentAddChecked(context, invocation, responder) catch |err| {
            // Async admission rejection is a command failure, not an SDK event
            // callback failure that stops the background host.
            responder.fail(invocation.request.id, .handler_failed, @errorName(err)) catch {};
        };
    }
    fn appendAttachmentAddChecked(context: *anyopaque, invocation: native_sdk.bridge.Invocation, responder: native_sdk.bridge.AsyncResponder) anyerror!void {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        var parsed = try handlers.parsePayloadWithLimit(handlers.AttachmentReceiveAppend, invocation.request.payload, 192 * 1024);
        defer parsed.deinit();
        const value = parsed.value;
        const key = try self.requireAddKey(invocation, value.generation, value.batchId);
        const active = self.receive_active orelse {
            respondAddError(responder, invocation.request.id, error.StaleTransfer);
            return;
        };
        if (!active.unified or !active.bytes or active.batch_id != key.batch_id) {
            respondAddError(responder, invocation.request.id, error.InvalidTransfer);
            return;
        }
        if (self.add_cancel != null) {
            respondAttachmentCancelled(responder, invocation.request.id);
            return;
        }
        var bytes: [attachment_chunk_bytes]u8 = undefined;
        defer std.crypto.secureZero(u8, &bytes);
        const decoder = std.base64.standard.Decoder;
        const size = decoder.calcSizeForSlice(value.dataBase64) catch {
            respondAddError(responder, invocation.request.id, error.InvalidTransfer);
            return;
        };
        if (size == 0 or size > bytes.len) {
            respondAddError(responder, invocation.request.id, error.InvalidTransfer);
            return;
        }
        decoder.decode(bytes[0..size], value.dataBase64) catch {
            respondAddError(responder, invocation.request.id, error.InvalidTransfer);
            return;
        };
        const offset = std.math.cast(usize, try handlers.parseWireId(value.offset)) orelse {
            respondAddError(responder, invocation.request.id, error.InvalidTransfer);
            return;
        };
        const completion = self.addSlot(responder, invocation.request.id, key.generation, invocation.source.window_id, key.batch_id) orelse {
            respondAddError(responder, invocation.request.id, error.InputBusy);
            return;
        };
        (try self.requireProductControl()).appendAttachmentBytes(completion, active.product_id, value.fileIndex, offset, bytes[0..size]) catch |err| {
            self.completeAttachmentStaging(completion, .{ .rejected = addRejection(err) });
        };
    }
    fn finishAttachmentAdd(context: *anyopaque, invocation: native_sdk.bridge.Invocation, responder: native_sdk.bridge.AsyncResponder) anyerror!void {
        finishAttachmentAddChecked(context, invocation, responder) catch |err| {
            // Async admission rejection is a command failure, not an SDK event
            // callback failure that stops the background host.
            responder.fail(invocation.request.id, .handler_failed, @errorName(err)) catch {};
        };
    }
    fn finishAttachmentAddChecked(context: *anyopaque, invocation: native_sdk.bridge.Invocation, responder: native_sdk.bridge.AsyncResponder) anyerror!void {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        var parsed = try handlers.parsePayload(handlers.AttachmentReceiveKey, invocation.request.payload);
        defer parsed.deinit();
        const key = try self.requireAddKey(invocation, parsed.value.generation, parsed.value.batchId);
        const active = self.receive_active orelse {
            respondAddError(responder, invocation.request.id, error.StaleTransfer);
            return;
        };
        if (!active.unified or !active.bytes or active.batch_id != key.batch_id) {
            respondAddError(responder, invocation.request.id, error.InvalidTransfer);
            return;
        }
        if (self.add_cancel != null) {
            respondAttachmentCancelled(responder, invocation.request.id);
            return;
        }
        const completion = self.addSlot(responder, invocation.request.id, key.generation, invocation.source.window_id, key.batch_id) orelse {
            respondAddError(responder, invocation.request.id, error.InputBusy);
            return;
        };
        (try self.requireProductControl()).finishAttachmentBytes(completion, active.product_id) catch |err| {
            self.completeAttachmentStaging(completion, .{ .rejected = addRejection(err) });
        };
    }
    fn rememberAddDebt(self: *Dispatcher, debt: AddDebt) void {
        for (self.add_debt) |slot| if (slot) |existing| {
            if (std.meta.eql(existing, debt)) return;
        };
        if (self.control) |workbench| for (&self.add_debt) |*slot| if (slot.*) |existing| {
            if (!workbench.attachmentCleanupPending(existing.product_id, existing.attachment_id)) slot.* = null;
        };
        for (&self.add_debt) |*slot| if (slot.* == null) {
            slot.* = debt;
            return;
        };
        // Each debt owns at least one Product slot; exceeding this is an invariant failure.
        unreachable;
    }
    fn cleanAdd(self: *Dispatcher, generation: u64, window: native_sdk.platform.WindowId, batch: u64) !bool {
        const workbench = try self.requireProductControl();
        var released = false;
        var failed = false;
        if (self.receive_active) |active| if (active.unified and active.batch_id == batch) {
            released = workbench.cancelAttachmentPreparation(active.product_id);
            released = (workbench.cancelAttachmentReceiveChecked(active.product_id) catch debt_failed: {
                self.rememberAddDebt(.{ .generation = generation, .window_id = window, .batch_id = batch, .product_id = active.product_id });
                failed = true;
                break :debt_failed false;
            }) or released;
            self.receive_active = null;
        };
        var ids: [attachment_grant.max_grants]u64 = undefined;
        for (self.attachment_grants.takeReceiveBatch(generation, window, batch, &ids)) |id| {
            released = (workbench.releaseAttachmentChecked(id) catch debt_failed: {
                self.rememberAddDebt(.{ .generation = generation, .window_id = window, .batch_id = batch, .attachment_id = id });
                failed = true;
                break :debt_failed false;
            }) or released;
        }
        for (&self.add_debt) |*slot| if (slot.*) |debt| {
            if (!workbench.attachmentCleanupPending(debt.product_id, debt.attachment_id)) {
                slot.* = null;
                continue;
            }
            if (debt.generation == generation and debt.window_id == window and debt.batch_id == batch) failed = true;
        };
        if (failed) return error.CleanupFailed;
        return released;
    }
    fn respondAddCancel(responder: native_sdk.bridge.AsyncResponder, id: []const u8, cleaned: bool, released: bool) void {
        if (!cleaned) {
            responder.success(id, "{\"status\":\"cleanup_failed\"}") catch {};
            return;
        }
        var buffer: [64]u8 = undefined;
        const value = std.fmt.bufPrint(&buffer, "{{\"status\":\"cleaned\",\"released\":{}}}", .{released}) catch unreachable;
        responder.success(id, value) catch {};
    }
    fn cancelAttachmentAdd(context: *anyopaque, invocation: native_sdk.bridge.Invocation, responder: native_sdk.bridge.AsyncResponder) anyerror!void {
        cancelAttachmentAddChecked(context, invocation, responder) catch |err| {
            // Async admission rejection is a command failure, not an SDK event
            // callback failure that stops the background host.
            responder.fail(invocation.request.id, .handler_failed, @errorName(err)) catch {};
        };
    }
    fn cancelAttachmentAddChecked(context: *anyopaque, invocation: native_sdk.bridge.Invocation, responder: native_sdk.bridge.AsyncResponder) anyerror!void {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        var parsed = try handlers.parsePayload(handlers.AttachmentReceiveKey, invocation.request.payload);
        defer parsed.deinit();
        const key = try self.requireAddKey(invocation, parsed.value.generation, parsed.value.batchId);
        self.receive_high_water = @max(self.receive_high_water, key.batch_id);
        if (self.add_cancel) |pending| {
            if (pending.generation == key.generation and pending.window_id == invocation.source.window_id and pending.batch_id == key.batch_id) return error.AttachmentCancelBusy;
        }
        for (self.attachment_in_flight) |slot| if (slot.active and slot.batch_id == key.batch_id and slot.generation == key.generation and slot.window_id == invocation.source.window_id) {
            if ((try self.requireProductControl()).cancelAttachmentStaging(slot.completion_id)) {
                var cancel: AddCancel = .{ .generation = key.generation, .window_id = invocation.source.window_id, .batch_id = key.batch_id, .responder = responder, .request_id = undefined, .request_len = invocation.request.id.len };
                @memcpy(cancel.request_id[0..cancel.request_len], invocation.request.id);
                self.add_cancel = cancel;
                return;
            }
            // Native picker may still be open; abandon its authority now, and
            // ignore the modal result when its handler resumes.
            self.completeAttachmentStaging(slot.completion_id, .cancelled);
        };
        const released = self.cleanAdd(key.generation, invocation.source.window_id, key.batch_id) catch {
            respondAddCancel(responder, invocation.request.id, false, false);
            return;
        };
        respondAddCancel(responder, invocation.request.id, true, released);
    }

    fn chooseAttachments(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        responder: native_sdk.bridge.AsyncResponder,
    ) anyerror!void {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = self.callbacks.enter() catch {
            respondAttachmentRejected(responder, invocation.request.id, .shutting_down);
            return;
        };
        defer callback.deinit();
        self.requireWindow(invocation.source.window_id) catch {
            respondAttachmentRejected(responder, invocation.request.id, .shutting_down);
            return;
        };
        var parsed = handlers.parsePayload(handlers.Empty, invocation.request.payload) catch {
            respondAttachmentRejected(responder, invocation.request.id, .read_failed);
            return;
        };
        defer parsed.deinit();
        const generation = self.delivery.connectedGeneration() orelse {
            respondAttachmentRejected(responder, invocation.request.id, .shutting_down);
            return;
        };
        var dialog_storage: [native_sdk.platform.max_dialog_paths_bytes]u8 = undefined;
        const selected = if (self.automation.active()) automation: {
            const paths = self.automation.attachmentPaths() orelse {
                respondAttachmentRejected(responder, invocation.request.id, .read_failed);
                return;
            };
            const count = countAutomationAttachmentPaths(paths) orelse {
                respondAttachmentRejected(responder, invocation.request.id, .read_failed);
                return;
            };
            break :automation native_sdk.platform.OpenDialogResult{
                .paths = paths,
                .count = count,
            };
        } else user: {
            break :user self.platform.show_open_dialog_fn(
                self.platform.context,
                .{
                    .title = "Choose files",
                    .allow_directories = false,
                    .allow_multiple = true,
                },
                &dialog_storage,
            ) catch {
                respondAttachmentRejected(responder, invocation.request.id, .read_failed);
                return;
            };
        };
        if (selected.count == 0) {
            respondAttachmentCancelled(responder, invocation.request.id);
            return;
        }
        if (selected.count > attachment_grant.max_grants or selected.paths.len == 0) {
            respondAttachmentRejected(responder, invocation.request.id, .too_many_files);
            return;
        }
        self.beginAttachmentStaging(
            responder,
            invocation.request.id,
            generation,
            invocation.source.window_id,
            selected.count,
            selected.paths,
        );
    }

    fn addDroppedAttachments(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        responder: native_sdk.bridge.AsyncResponder,
    ) anyerror!void {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = self.callbacks.enter() catch {
            respondAttachmentRejected(responder, invocation.request.id, .shutting_down);
            return;
        };
        defer callback.deinit();
        self.requireWindow(invocation.source.window_id) catch {
            respondAttachmentRejected(responder, invocation.request.id, .shutting_down);
            return;
        };
        var parsed = handlers.parsePayloadWithLimit(
            handlers.AttachmentPaths,
            invocation.request.payload,
            native_sdk.platform.max_drop_paths_bytes * 2,
        ) catch {
            respondAttachmentRejected(responder, invocation.request.id, .read_failed);
            return;
        };
        defer parsed.deinit();
        if (parsed.value.paths.len == 0 or parsed.value.paths.len > attachment_grant.max_grants) {
            respondAttachmentRejected(responder, invocation.request.id, .too_many_files);
            return;
        }
        var path_storage: [native_sdk.platform.max_drop_paths_bytes]u8 = undefined;
        var used: usize = 0;
        for (parsed.value.paths, 0..) |path, index| {
            if (path.len == 0 or !std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, '\n') != null) {
                respondAttachmentRejected(responder, invocation.request.id, .read_failed);
                return;
            }
            if (index != 0) {
                if (used == path_storage.len) {
                    respondAttachmentRejected(responder, invocation.request.id, .read_failed);
                    return;
                }
                path_storage[used] = '\n';
                used += 1;
            }
            if (path.len > path_storage.len - used) {
                respondAttachmentRejected(responder, invocation.request.id, .read_failed);
                return;
            }
            @memcpy(path_storage[used..][0..path.len], path);
            used += path.len;
        }
        const generation = self.delivery.connectedGeneration() orelse {
            respondAttachmentRejected(responder, invocation.request.id, .shutting_down);
            return;
        };
        self.beginAttachmentStaging(
            responder,
            invocation.request.id,
            generation,
            invocation.source.window_id,
            parsed.value.paths.len,
            path_storage[0..used],
        );
    }

    fn beginAttachmentStaging(
        self: *Dispatcher,
        responder: native_sdk.bridge.AsyncResponder,
        request_id: []const u8,
        generation: u64,
        window_id: native_sdk.platform.WindowId,
        path_count: usize,
        paths: []const u8,
    ) void {
        const completion_id = self.reserveAttachmentStaging(
            responder,
            request_id,
            generation,
            window_id,
        ) orelse {
            respondAttachmentRejected(responder, request_id, .staging_capacity);
            return;
        };
        (self.requireProductControl() catch {
            self.completeAttachmentRejected(completion_id, .shutting_down);
            return;
        }).beginAttachmentStaging(completion_id, path_count, paths) catch |err| {
            self.completeAttachmentRejected(completion_id, switch (err) {
                error.ShuttingDown => .shutting_down,
                error.Capacity, error.OutOfMemory => .staging_capacity,
                error.InputBusy => .input_busy,
                error.CleanupFailed => .cleanup_failed,
                else => .read_failed,
            });
        };
    }

    fn reserveAttachmentStaging(
        self: *Dispatcher,
        responder: native_sdk.bridge.AsyncResponder,
        request_id: []const u8,
        generation: u64,
        window_id: native_sdk.platform.WindowId,
    ) ?u64 {
        if (self.next_attachment_completion_id == std.math.maxInt(u64)) return null;
        for (&self.attachment_in_flight) |*slot| {
            if (slot.active) continue;
            const completion_id = self.next_attachment_completion_id;
            self.next_attachment_completion_id += 1;
            @memcpy(slot.request_id_storage[0..request_id.len], request_id);
            slot.* = .{
                .active = true,
                .completion_id = completion_id,
                .generation = generation,
                .window_id = window_id,
                .responder = responder,
                .request_id_storage = slot.request_id_storage,
                .request_id_len = request_id.len,
            };
            return completion_id;
        }
        return null;
    }

    pub fn attachmentStagingSink(self: *Dispatcher) product_control.AttachmentStagingSink {
        return .{ .context = self, .complete_fn = completeAttachmentStagingFromSink };
    }

    fn completeAttachmentStagingFromSink(
        context: *anyopaque,
        completion_id: u64,
        result: product_control.AttachmentStagingResult,
    ) void {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        self.completeAttachmentStaging(completion_id, result);
    }

    fn completeAttachmentStaging(self: *Dispatcher, completion_id: u64, result: product_control.AttachmentStagingResult) void {
        for (&self.attachment_in_flight) |*slot| {
            if (!slot.active or slot.completion_id != completion_id) continue;
            const responder = slot.responder;
            const generation = slot.generation;
            const window_id = slot.window_id;
            const batch_id = slot.batch_id;
            var request_id_storage: [native_sdk.bridge.max_id_bytes]u8 = undefined;
            @memcpy(request_id_storage[0..slot.request_id_len], slot.request_id_storage[0..slot.request_id_len]);
            const request_id = request_id_storage[0..slot.request_id_len];
            slot.* = .{};
            const cancel = if (self.add_cancel) |value| if (value.batch_id == batch_id and value.generation == generation and value.window_id == window_id) value else null else null;
            if (cancel) |pending| {
                self.add_cancel = null;
                const cleaned = (result != .rejected or result.rejected != .cleanup_failed);
                const released = self.cleanAdd(generation, window_id, batch_id.?) catch false;
                respondAttachmentCancelled(responder, request_id);
                respondAddCancel(pending.responder, pending.request_id[0..pending.request_len], cleaned and !self.hasAddDebt(generation, window_id, batch_id.?), released or cleaned);
                return;
            }
            switch (result) {
                .accepted => responder.success(request_id, "{\"status\":\"accepted\"}") catch {},
                .cancelled => {
                    if (batch_id) |batch| {
                        _ = self.cleanAdd(generation, window_id, batch) catch {
                            respondAddError(responder, request_id, error.CleanupFailed);
                            return;
                        };
                    }
                    respondAttachmentCancelled(responder, request_id);
                },
                .rejected => |reason| {
                    if (batch_id != null) {
                        var buffer: [256]u8 = undefined;
                        const encoded = std.fmt.bufPrint(&buffer, "{{\"status\":\"rejected\",\"reason\":\"{s}\"}}", .{@tagName(reason)}) catch unreachable;
                        responder.success(request_id, encoded) catch {};
                    } else respondAttachmentRejected(responder, request_id, reason);
                },
                .ready => |descriptors| {
                    if (self.delivery.connectedGeneration() != generation or self.delivery.connectedWindow() != window_id) {
                        self.releaseAttachmentDescriptors(descriptors);
                        respondAttachmentCancelled(responder, request_id);
                        return;
                    }
                    var ids: [attachment_grant.max_grants]u64 = undefined;
                    for (descriptors, 0..) |descriptor, index| ids[index] = descriptor.id;
                    var issued_storage: [attachment_grant.max_grants]attachment_grant.Issued = undefined;
                    const issued = self.attachment_grants.issueBatch(generation, window_id, ids[0..descriptors.len], &issued_storage, self.platform.context, self.platform.random_fn) catch {
                        self.releaseAttachmentDescriptors(descriptors);
                        if (batch_id) |batch| {
                            _ = self.cleanAdd(generation, window_id, batch) catch {};
                        }
                        respondAttachmentRejected(responder, request_id, .staging_capacity);
                        return;
                    };
                    if (batch_id) |batch| self.attachment_grants.tagReceiveBatch(ids[0..descriptors.len], batch);
                    var buffer: [native_sdk.bridge.max_result_bytes]u8 = undefined;
                    const encoded = encodeAttachmentsReady(&buffer, descriptors, issued) catch {
                        if (batch_id) |batch| {
                            _ = self.cleanAdd(generation, window_id, batch) catch {};
                        } else {
                            for (issued) |grant| _ = self.attachment_grants.release(grant.token, generation, window_id);
                            self.releaseAttachmentDescriptors(descriptors);
                        }
                        responderEncodingFailure(responder, request_id);
                        return;
                    };
                    if (batch_id != null) self.receive_active = null;
                    responder.success(request_id, encoded) catch {
                        if (batch_id) |batch| {
                            _ = self.cleanAdd(generation, window_id, batch) catch {};
                        } else {
                            for (issued) |grant| _ = self.attachment_grants.release(grant.token, generation, window_id);
                            self.releaseAttachmentDescriptors(descriptors);
                        }
                    };
                },
            }
            return;
        }
        if (result == .ready) self.releaseAttachmentDescriptors(result.ready);
    }
    fn hasAddDebt(self: *Dispatcher, generation: u64, window: native_sdk.platform.WindowId, batch: u64) bool {
        const workbench = self.control orelse return false;
        for (self.add_debt) |slot| if (slot) |debt| {
            if (debt.generation == generation and debt.window_id == window and debt.batch_id == batch and workbench.attachmentCleanupPending(debt.product_id, debt.attachment_id)) return true;
        };
        return false;
    }

    fn completeAttachmentRejected(
        self: *Dispatcher,
        completion_id: u64,
        reason: product_control.AttachmentStagingRejection,
    ) void {
        self.completeAttachmentStaging(completion_id, .{ .rejected = reason });
    }

    pub fn settleAttachmentStagingForShutdown(self: *Dispatcher) void {
        for (&self.attachment_in_flight) |*slot| {
            if (!slot.active) continue;
            const responder = slot.responder;
            var request_id_storage: [native_sdk.bridge.max_id_bytes]u8 = undefined;
            @memcpy(request_id_storage[0..slot.request_id_len], slot.request_id_storage[0..slot.request_id_len]);
            const request_id = request_id_storage[0..slot.request_id_len];
            slot.* = .{};
            respondAttachmentRejected(responder, request_id, .shutting_down);
        }
    }

    fn respondAttachmentCancelled(
        responder: native_sdk.bridge.AsyncResponder,
        request_id: []const u8,
    ) void {
        responder.success(request_id, "{\"status\":\"cancelled\"}") catch {};
    }

    fn respondAttachmentRejected(
        responder: native_sdk.bridge.AsyncResponder,
        request_id: []const u8,
        reason: product_control.AttachmentStagingRejection,
    ) void {
        if (reason == .cleanup_failed) {
            responder.fail(request_id, .internal_error, "Attachment cleanup failed") catch {};
            return;
        }
        const name = if (reason == .input_busy) "staging_capacity" else @tagName(reason);
        var buffer: [256]u8 = undefined;
        const value = std.fmt.bufPrint(&buffer, "{{\"status\":\"rejected\",\"reason\":\"{s}\"}}", .{name}) catch {
            responder.fail(request_id, .internal_error, "Attachment result encoding failed") catch {};
            return;
        };
        responder.success(request_id, value) catch {};
    }

    fn respondAttachmentsReady(
        responder: native_sdk.bridge.AsyncResponder,
        request_id: []const u8,
        descriptors: []const product_control.AttachmentDescriptor,
        issued: []const attachment_grant.Issued,
    ) void {
        var buffer: [native_sdk.bridge.max_result_bytes]u8 = undefined;
        const encoded = encodeAttachmentsReady(&buffer, descriptors, issued) catch return responderEncodingFailure(responder, request_id);
        responder.success(request_id, encoded) catch {};
    }

    fn encodeAttachmentsReady(output: []u8, descriptors: []const product_control.AttachmentDescriptor, issued: []const attachment_grant.Issued) ![]const u8 {
        var writer = std.Io.Writer.fixed(output);
        try writer.writeAll("{\"status\":\"ready\",\"attachments\":[");
        for (descriptors, issued, 0..) |descriptor, grant, index| {
            if (index != 0) try writer.writeByte(',');
            try writer.print("{{\"token\":\"{s}\",\"kind\":\"{s}\"", .{
                grant.token,
                @tagName(descriptor.kind),
            });
            if (descriptor.format) |format|
                try writer.print(",\"format\":\"{s}\"", .{@tagName(format)});
            try writer.writeAll(",\"displayName\":");
            try std.json.Stringify.value(descriptor.display_name, .{}, &writer);
            try writer.print(",\"sizeBytes\":\"{d}\"}}", .{descriptor.size_bytes});
        }
        try writer.writeAll("]}");
        return writer.buffered();
    }

    fn responderEncodingFailure(
        responder: native_sdk.bridge.AsyncResponder,
        request_id: []const u8,
    ) void {
        responder.fail(request_id, .internal_error, "Attachment result encoding failed") catch {};
    }

    fn diffFile(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        responder: native_sdk.bridge.AsyncResponder,
    ) anyerror!void {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = self.callbacks.enter() catch {
            respondFileChangeDiffUnavailable(responder, invocation.request.id, .capacity);
            return;
        };
        defer callback.deinit();
        self.requireWindow(invocation.source.window_id) catch {
            respondFileChangeDiffUnavailable(responder, invocation.request.id, .not_recorded);
            return;
        };
        var parsed = handlers.parsePayload(
            handlers.FileChangeDiffRequest,
            invocation.request.payload,
        ) catch {
            respondFileChangeDiffUnavailable(responder, invocation.request.id, .not_recorded);
            return;
        };
        defer parsed.deinit();
        if (parsed.value.fileChangeId.len == 0 or parsed.value.fileChangeId.len > 128) {
            respondFileChangeDiffUnavailable(responder, invocation.request.id, .not_recorded);
            return;
        }
        const task_id = handlers.parseWireId(parsed.value.taskId) catch {
            respondFileChangeDiffUnavailable(responder, invocation.request.id, .not_recorded);
            return;
        };
        const run_id = handlers.parseWireId(parsed.value.runId) catch {
            respondFileChangeDiffUnavailable(responder, invocation.request.id, .not_recorded);
            return;
        };
        const workbench = self.requireProductControl() catch {
            respondFileChangeDiffUnavailable(responder, invocation.request.id, .capacity);
            return;
        };
        const completion_id = self.reserveFileChangeDiff(
            responder,
            invocation.request.id,
        ) orelse {
            respondFileChangeDiffUnavailable(responder, invocation.request.id, .capacity);
            return;
        };
        switch (workbench.beginFileChangeDiff(
            completion_id,
            task_id,
            run_id,
            parsed.value.fileChangeId,
        )) {
            .queued => {},
            .immediate => |reason| self.completeFileChangeDiff(.{ .unavailable = .{
                .completion_id = completion_id,
                .reason = reason,
            } }),
        }
    }

    fn reserveFileChangeDiff(
        self: *Dispatcher,
        responder: native_sdk.bridge.AsyncResponder,
        request_id: []const u8,
    ) ?u64 {
        if (self.next_diff_completion_id == std.math.maxInt(u64)) return null;
        for (&self.diff_in_flight) |*slot| {
            if (slot.active) continue;
            const completion_id = self.next_diff_completion_id;
            self.next_diff_completion_id += 1;
            @memcpy(slot.request_id_storage[0..request_id.len], request_id);
            slot.active = true;
            slot.completion_id = completion_id;
            slot.responder = responder;
            slot.request_id_len = request_id.len;
            return completion_id;
        }
        return null;
    }

    pub fn fileChangeDiffSink(self: *Dispatcher) product_control.FileChangeDiffSink {
        return .{ .context = self, .complete_fn = completeFileChangeDiffFromSink };
    }

    fn completeFileChangeDiffFromSink(
        context: *anyopaque,
        result: product_control.FileChangeDiffResult,
    ) void {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        self.completeFileChangeDiff(result);
    }

    fn completeFileChangeDiff(
        self: *Dispatcher,
        result: product_control.FileChangeDiffResult,
    ) void {
        const completion_id = switch (result) {
            .ready => |ready| ready.completion_id,
            .unavailable => |unavailable| unavailable.completion_id,
        };
        for (&self.diff_in_flight) |*slot| {
            if (!slot.active or slot.completion_id != completion_id) continue;
            const responder = slot.responder;
            var request_id_storage: [native_sdk.bridge.max_id_bytes]u8 = undefined;
            @memcpy(
                request_id_storage[0..slot.request_id_len],
                slot.request_id_storage[0..slot.request_id_len],
            );
            const request_id = request_id_storage[0..slot.request_id_len];
            slot.* = .{};
            respondFileChangeDiff(responder, request_id, result);
            return;
        }
    }

    pub fn settleFileChangeDiffsForShutdown(self: *Dispatcher) void {
        for (&self.diff_in_flight) |*slot| {
            if (!slot.active) continue;
            const responder = slot.responder;
            var request_id_storage: [native_sdk.bridge.max_id_bytes]u8 = undefined;
            @memcpy(
                request_id_storage[0..slot.request_id_len],
                slot.request_id_storage[0..slot.request_id_len],
            );
            const request_id = request_id_storage[0..slot.request_id_len];
            slot.* = .{};
            respondFileChangeDiffUnavailable(responder, request_id, .capacity);
        }
    }

    fn respondFileChangeDiff(
        responder: native_sdk.bridge.AsyncResponder,
        request_id: []const u8,
        result: product_control.FileChangeDiffResult,
    ) void {
        var result_buffer: [native_sdk.bridge.max_result_bytes]u8 = undefined;
        var writer = std.Io.Writer.fixed(&result_buffer);
        switch (result) {
            .ready => |ready| {
                writer.writeAll("{\"status\":\"ready\",\"content\":") catch
                    return respondFileChangeDiffEncodingFailure(responder, request_id);
                std.json.Stringify.value(ready.content, .{}, &writer) catch
                    return respondFileChangeDiffEncodingFailure(responder, request_id);
                writer.print(",\"complete\":{},\"redacted\":{}}}", .{
                    ready.complete,
                    ready.redacted,
                }) catch return respondFileChangeDiffEncodingFailure(responder, request_id);
            },
            .unavailable => |unavailable| {
                writer.print(
                    "{{\"status\":\"unavailable\",\"reason\":\"{s}\",\"content\":\"\"}}",
                    .{@tagName(unavailable.reason)},
                ) catch return respondFileChangeDiffEncodingFailure(responder, request_id);
            },
        }
        responder.success(request_id, writer.buffered()) catch {};
    }

    fn respondFileChangeDiffUnavailable(
        responder: native_sdk.bridge.AsyncResponder,
        request_id: []const u8,
        reason: product_control.FileChangeDiffReason,
    ) void {
        respondFileChangeDiff(responder, request_id, .{ .unavailable = .{
            .completion_id = 0,
            .reason = reason,
        } });
    }

    fn respondFileChangeDiffEncodingFailure(
        responder: native_sdk.bridge.AsyncResponder,
        request_id: []const u8,
    ) void {
        responder.fail(request_id, .internal_error, "File change diff encoding failed") catch {};
    }

    fn accountBeginLogin(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        return submitEmptyAccountCommand(
            context,
            invocation,
            output,
            .begin_login,
        );
    }

    fn accountCancelOperation(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        return submitEmptyAccountCommand(
            context,
            invocation,
            output,
            .cancel_operation,
        );
    }

    fn accountRetryRefresh(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        return submitEmptyAccountCommand(
            context,
            invocation,
            output,
            .retry_refresh,
        );
    }

    fn accountRefreshSummary(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        return submitEmptyAccountCommand(
            context,
            invocation,
            output,
            .refresh_summary,
        );
    }

    fn accountOpenRecharge(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        return submitEmptyAccountCommand(
            context,
            invocation,
            output,
            .open_recharge,
        );
    }

    fn accountLogout(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        return submitEmptyAccountCommand(
            context,
            invocation,
            output,
            .logout,
        );
    }

    fn submitEmptyAccountCommand(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
        command: account_contract.AccountCommand,
    ) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireManagementAuthority(invocation.source.window_id);
        var parsed = try handlers.parsePayload(
            handlers.Empty,
            invocation.request.payload,
        );
        defer parsed.deinit();
        return encodeAccountResult(
            output,
            self.account_commands.submit(command),
        );
    }

    fn modelsRefreshCatalog(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireManagementAuthority(invocation.source.window_id);
        var parsed = try handlers.parsePayload(handlers.Empty, invocation.request.payload);
        defer parsed.deinit();
        const host = self.models_host orelse
            return encodeExecutionResult(output, .rejected(.catalog_unavailable));
        return encodeExecutionResult(output, host.refreshCatalog());
    }

    fn modelsResetStore(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireManagementAuthority(invocation.source.window_id);
        var parsed = try handlers.parsePayload(
            handlers.ModelsResetStore,
            invocation.request.payload,
        );
        defer parsed.deinit();
        const host = self.models_host orelse
            return encodeExecutionResult(output, .rejected(.persistence_unavailable));
        return encodeExecutionResult(
            output,
            host.resetStore(try handlers.parseWireId(parsed.value.expectedRevision)),
        );
    }

    fn configureMetaskSelection(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireManagementAuthority(invocation.source.window_id);
        var parsed = try handlers.parsePayload(
            handlers.ConfigureMetaskSelection,
            invocation.request.payload,
        );
        defer parsed.deinit();
        if (parsed.value.sourceId.len == 0 or
            parsed.value.sourceId.len > models_contract.Limits.provider_id_bytes or
            parsed.value.modelId.len == 0 or
            parsed.value.modelId.len > models_contract.Limits.model_id_bytes)
            return error.InvalidBridgePayload;
        const control = self.control orelse return error.DispatcherUnavailable;
        return encodeExecutionResult(output, control.configureMetaskSelection(.{
            .selection = .{
                .source_id = parsed.value.sourceId,
                .model_id = parsed.value.modelId,
            },
            .expected_metask_selection_revision = try handlers.parseWireId(
                parsed.value.expectedMetaskSelectionRevision,
            ),
            .expected_catalog_generation = try handlers.parseWireId(
                parsed.value.expectedCatalogGeneration,
            ),
        }));
    }

    fn selectModelsDefault(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireManagementAuthority(invocation.source.window_id);
        var parsed = try handlers.parsePayload(
            handlers.ModelDefaultSelection,
            invocation.request.payload,
        );
        defer parsed.deinit();
        if (parsed.value.sourceId.len == 0 or
            parsed.value.sourceId.len > models_contract.Limits.provider_id_bytes or
            parsed.value.modelId.len == 0 or
            parsed.value.modelId.len > models_contract.Limits.model_id_bytes)
            return error.InvalidBridgePayload;
        const control = self.control orelse return error.DispatcherUnavailable;
        return encodeExecutionResult(
            output,
            control.selectModelsDefault(.{
                .selection = .{
                    .source_id = parsed.value.sourceId,
                    .model_id = parsed.value.modelId,
                },
                .expected_selection_revision = try handlers.parseWireId(
                    parsed.value.expectedSelectionRevision,
                ),
                .expected_source_generation = try handlers.parseWireId(
                    parsed.value.expectedSourceGeneration,
                ),
                .expected_catalog_generation = try handlers.parseWireId(
                    parsed.value.expectedCatalogGeneration,
                ),
            }),
        );
    }

    fn customProviderCreate(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireManagementAuthority(invocation.source.window_id);
        var parsed = try handlers.parsePayload(handlers.CustomProviderCreate, invocation.request.payload);
        defer parsed.deinit();
        const protocol = parseProtocol(parsed.value.protocol) orelse
            return error.InvalidBridgePayload;
        const normalized_base_url = models_contract.normalizeCustomProviderEndpointAlloc(
            std.heap.c_allocator,
            protocol,
            parsed.value.normalizedBaseUrl,
        ) catch return error.InvalidBridgePayload;
        defer std.heap.c_allocator.free(normalized_base_url);
        if (parsed.value.displayName.len == 0 or
            parsed.value.displayName.len > models_contract.Limits.display_name_bytes or
            parsed.value.normalizedBaseUrl.len == 0 or
            parsed.value.normalizedBaseUrl.len > models_contract.Limits.base_url_bytes or
            parsed.value.apiKey.len == 0 or
            parsed.value.apiKey.len > models_contract.Limits.credential_bytes)
            return error.InvalidBridgePayload;
        const spec: models_contract.CustomProviderSpec = .{
            .display_name = parsed.value.displayName,
            .protocol = protocol,
            .normalized_base_url = normalized_base_url,
        };
        models_contract.validateCustomProviderSpec(spec) catch
            return error.InvalidBridgePayload;
        const control = try self.requireProductControl();
        return encodeExecutionResult(
            output,
            control.createCustomProviderWithCredential(parsed.value.apiKey, spec),
        );
    }

    fn builtinProviderCreate(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireManagementAuthority(invocation.source.window_id);
        var parsed = try handlers.parsePayload(
            handlers.BuiltinProviderCreate,
            invocation.request.payload,
        );
        defer parsed.deinit();
        const provider_id = std.meta.stringToEnum(
            models_contract.BuiltinProviderId,
            parsed.value.providerId,
        ) orelse return error.InvalidBridgePayload;
        if (parsed.value.apiKey.len == 0 or
            parsed.value.apiKey.len > models_contract.Limits.credential_bytes or
            !models_contract.validProviderBaseUrl(parsed.value.baseUrl))
            return error.InvalidBridgePayload;
        const control = try self.requireProductControl();
        return encodeExecutionResult(
            output,
            control.createBuiltinProviderWithCredential(
                parsed.value.apiKey,
                provider_id,
                parsed.value.baseUrl,
            ),
        );
    }

    fn builtinProviderUpdateBaseUrl(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireManagementAuthority(invocation.source.window_id);
        var parsed = try handlers.parsePayload(
            handlers.BuiltinProviderBaseUrlUpdate,
            invocation.request.payload,
        );
        defer parsed.deinit();
        if (parsed.value.providerId.len == 0 or
            parsed.value.providerId.len > models_contract.Limits.instance_id_bytes or
            !models_contract.validProviderBaseUrl(parsed.value.baseUrl))
            return error.InvalidBridgePayload;
        const control = try self.requireProductControl();
        return encodeExecutionResult(
            output,
            control.updateBuiltinProviderBaseUrl(.{
                .source_id = parsed.value.providerId,
                .expected_provider_revision = try handlers.parseWireId(
                    parsed.value.expectedProviderRevision,
                ),
            }, parsed.value.baseUrl),
        );
    }

    fn customProviderUpdate(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireManagementAuthority(invocation.source.window_id);
        var parsed = try handlers.parsePayload(handlers.CustomProviderUpdate, invocation.request.payload);
        defer parsed.deinit();
        const protocol = parseProtocol(parsed.value.protocol) orelse
            return error.InvalidBridgePayload;
        const normalized_base_url = models_contract.normalizeCustomProviderEndpointAlloc(
            std.heap.c_allocator,
            protocol,
            parsed.value.normalizedBaseUrl,
        ) catch return error.InvalidBridgePayload;
        defer std.heap.c_allocator.free(normalized_base_url);
        const spec: models_contract.CustomProviderSpec = .{
            .display_name = parsed.value.displayName,
            .protocol = protocol,
            .normalized_base_url = normalized_base_url,
        };
        models_contract.validateCustomProviderSpec(spec) catch
            return error.InvalidBridgePayload;
        return encodeExecutionResult(output, self.custom_provider_commands.submit(.{
            .update = .{
                .selection = .{
                    .source_id = parsed.value.providerId,
                    .expected_provider_revision = try handlers.parseWireId(
                        parsed.value.expectedProviderRevision,
                    ),
                },
                .spec = spec,
            },
        }));
    }

    fn customProviderReplaceCredential(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireManagementAuthority(invocation.source.window_id);
        var parsed = try handlers.parsePayload(
            handlers.CustomProviderCredentialReplace,
            invocation.request.payload,
        );
        defer parsed.deinit();
        if (parsed.value.providerId.len == 0 or
            parsed.value.providerId.len > models_contract.Limits.instance_id_bytes or
            parsed.value.apiKey.len == 0 or
            parsed.value.apiKey.len > models_contract.Limits.credential_bytes)
            return error.InvalidBridgePayload;
        const control = try self.requireProductControl();
        return encodeExecutionResult(
            output,
            control.replaceCustomProviderCredential(parsed.value.apiKey, .{
                .source_id = parsed.value.providerId,
                .expected_provider_revision = try handlers.parseWireId(
                    parsed.value.expectedProviderRevision,
                ),
            }),
        );
    }

    fn customProviderRemove(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireManagementAuthority(invocation.source.window_id);
        var parsed = try handlers.parsePayload(handlers.CustomProviderSelection, invocation.request.payload);
        defer parsed.deinit();
        return encodeExecutionResult(output, self.custom_provider_commands.submit(.{
            .remove = .{
                .source_id = parsed.value.providerId,
                .expected_provider_revision = try handlers.parseWireId(parsed.value.expectedProviderRevision),
            },
        }));
    }

    fn customModelTest(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireManagementAuthority(invocation.source.window_id);
        var parsed = try handlers.parsePayload(handlers.CustomModelTest, invocation.request.payload);
        defer parsed.deinit();
        return encodeExecutionResult(output, self.custom_provider_commands.submit(.{
            .test_model = .{
                .model = .{
                    .source_id = parsed.value.model.sourceId,
                    .model_id = parsed.value.model.modelId,
                },
                .expected_provider_revision = try handlers.parseWireId(
                    parsed.value.expectedProviderRevision,
                ),
                .expected_source_generation = try handlers.parseWireId(
                    parsed.value.expectedSourceGeneration,
                ),
                .expected_catalog_generation = try handlers.parseWireId(
                    parsed.value.expectedCatalogGeneration,
                ),
            },
        }));
    }

    fn customModelAdd(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireManagementAuthority(invocation.source.window_id);
        var parsed = try handlers.parsePayload(handlers.CustomModelAdd, invocation.request.payload);
        defer parsed.deinit();
        return encodeExecutionResult(output, self.custom_provider_commands.submit(.{
            .add_custom_model = .{
                .source_id = parsed.value.providerId,
                .expected_provider_revision = try handlers.parseWireId(
                    parsed.value.expectedProviderRevision,
                ),
                .expected_catalog_generation = try handlers.parseWireId(
                    parsed.value.expectedCatalogGeneration,
                ),
                .model = try parseCustomModel(parsed.value.model),
            },
        }));
    }

    fn customModelReplace(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireManagementAuthority(invocation.source.window_id);
        var parsed = try handlers.parsePayload(handlers.CustomModelReplace, invocation.request.payload);
        defer parsed.deinit();
        return encodeExecutionResult(output, self.custom_provider_commands.submit(.{
            .replace_custom_model = .{
                .selection = .{
                    .source_id = parsed.value.selection.sourceId,
                    .model_id = parsed.value.selection.modelId,
                },
                .expected_provider_revision = try handlers.parseWireId(
                    parsed.value.expectedProviderRevision,
                ),
                .expected_catalog_generation = try handlers.parseWireId(
                    parsed.value.expectedCatalogGeneration,
                ),
                .replacement = try parseCustomModel(parsed.value.replacement),
            },
        }));
    }

    fn customModelRemove(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireManagementAuthority(invocation.source.window_id);
        var parsed = try handlers.parsePayload(handlers.CustomModelRemove, invocation.request.payload);
        defer parsed.deinit();
        return encodeExecutionResult(output, self.custom_provider_commands.submit(.{
            .remove_custom_model = .{
                .selection = .{
                    .source_id = parsed.value.selection.sourceId,
                    .model_id = parsed.value.selection.modelId,
                },
                .expected_provider_revision = try handlers.parseWireId(
                    parsed.value.expectedProviderRevision,
                ),
                .expected_catalog_generation = try handlers.parseWireId(
                    parsed.value.expectedCatalogGeneration,
                ),
            },
        }));
    }

    fn parseCustomModel(value: handlers.CustomModel) !models_contract.CustomModelInput {
        const model: models_contract.CustomModelInput = .{
            .id = value.id,
            .display_name = value.displayName,
            .metadata = .{
                .max_input_tokens = if (value.metadata.maxInputTokens) |token_count|
                    try handlers.parseWireId(token_count)
                else
                    null,
                .max_output_tokens = if (value.metadata.maxOutputTokens) |token_count|
                    try handlers.parseWireId(token_count)
                else
                    null,
                .capabilities = .{
                    .text_input = value.metadata.capabilities.textInput,
                    .audio_input = value.metadata.capabilities.audioInput,
                    .video_input = value.metadata.capabilities.videoInput,
                    .output = value.metadata.capabilities.output,
                    .image_input = value.metadata.capabilities.imageInput,
                    .pdf_input = value.metadata.capabilities.pdfInput,
                    .batch = value.metadata.capabilities.batch,
                    .citations = value.metadata.capabilities.citations,
                    .code_execution = value.metadata.capabilities.codeExecution,
                    .structured_outputs = value.metadata.capabilities.structuredOutputs,
                    .thinking = .{
                        .supported = value.metadata.capabilities.thinking.supported,
                        .adaptive = value.metadata.capabilities.thinking.adaptive,
                        .enabled = value.metadata.capabilities.thinking.enabled,
                    },
                    .effort = .{
                        .supported = value.metadata.capabilities.effort.supported,
                        .low = value.metadata.capabilities.effort.low,
                        .medium = value.metadata.capabilities.effort.medium,
                        .high = value.metadata.capabilities.effort.high,
                        .max = value.metadata.capabilities.effort.max,
                    },
                    .context_management = .{
                        .supported = value.metadata.capabilities.contextManagement.supported,
                        .clear_thinking_20251015 = value.metadata.capabilities.contextManagement.clearThinking20251015,
                        .clear_tool_uses_20250919 = value.metadata.capabilities.contextManagement.clearToolUses20250919,
                        .compact_20260112 = value.metadata.capabilities.contextManagement.compact20260112,
                    },
                },
            },
        };
        models_contract.validateCustomModelInput(model) catch
            return error.InvalidBridgePayload;
        return model;
    }

    fn parseProtocol(value: []const u8) ?models_contract.Protocol {
        return std.meta.stringToEnum(models_contract.Protocol, value);
    }

    fn chooseWorkspace(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        const generation = self.delivery.connectedGeneration() orelse return error.NoConnection;
        self.grants.invalidate();
        var dialog_storage: [native_sdk.platform.max_dialog_paths_bytes]u8 = undefined;
        const selected_path: []const u8 = if (self.automation.active()) automation: {
            break :automation self.automation.workspaceRoot() orelse
                return error.AutomationWorkspaceUnavailable;
        } else user: {
            const selected = try self.platform.show_open_dialog_fn(
                self.platform.context,
                .{
                    .title = "Choose a workspace",
                    .allow_directories = true,
                    .allow_multiple = false,
                },
                &dialog_storage,
            );
            if (selected.count == 0) return "{\"selected\":false}";
            if (selected.count != 1 or selected.paths.len == 0 or
                selected.paths.len > workspace_path_capacity)
                return error.InvalidWorkspace;
            break :user selected.paths;
        };
        if (selected_path.len == 0 or selected_path.len > workspace_path_capacity)
            return error.InvalidWorkspace;
        const token = try self.grants.issue(
            generation,
            invocation.source.window_id,
            selected_path,
        );
        var path_storage: [workspace_path_capacity]u8 = undefined;
        const consumed_path = try self.grants.consume(
            token,
            invocation.source.window_id,
            self.delivery.connectedGeneration() orelse return error.NoConnection,
            &path_storage,
        );
        const workspace_id = try (try self.requireProductControl()).openWorkspace(.{
            .workspace_root = consumed_path,
            .trust = if (self.automation.active())
                .{ .temporary = consumed_path }
            else
                .explicitly_trusted,
        });
        self.notifyCommitted();
        return std.fmt.bufPrint(
            output,
            "{{\"selected\":true,\"workspaceId\":\"{d}\"}}",
            .{workspace_id},
        );
    }

    fn chooseAutomaticWorkspaceRoot(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        _: []u8,
    ) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        const expected_generation = try parseAutomaticWorkspaceRootMutation(
            invocation.request.payload,
        );
        const product_control_runtime = try self.requireProductControl();
        const current_root = product_control_runtime.automaticWorkspaceRootConfiguration();
        var dialog_storage: [native_sdk.platform.max_dialog_paths_bytes]u8 = undefined;
        const selected = try self.platform.show_open_dialog_fn(
            self.platform.context,
            .{
                .title = "Choose the Automatic Workspace location",
                .default_path = current_root.canonical_root orelse "",
                .allow_directories = true,
                .allow_multiple = false,
            },
            &dialog_storage,
        );
        if (selected.count == 0) return "{\"outcome\":\"cancelled\"}";
        if (selected.count != 1 or selected.paths.len == 0 or
            selected.paths.len > workspace_path_capacity)
            return error.InvalidWorkspace;
        var canonical_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const canonical = try self.platform.canonicalize_directory_fn(
            self.platform.context,
            selected.paths,
            &canonical_storage,
        );
        try product_control_runtime.chooseAutomaticWorkspaceRoot(
            expected_generation,
            canonical,
        );
        self.notifyCommitted();
        return "{\"outcome\":\"applied\"}";
    }

    fn resetAutomaticWorkspaceRoot(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        _: []u8,
    ) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        const expected_generation = try parseAutomaticWorkspaceRootMutation(
            invocation.request.payload,
        );
        try (try self.requireProductControl()).resetAutomaticWorkspaceRoot(
            expected_generation,
        );
        self.notifyCommitted();
        return "{\"outcome\":\"applied\"}";
    }

    fn retryAutomaticWorkspaceRoot(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        _: []u8,
    ) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        const expected_generation = try parseAutomaticWorkspaceRootMutation(
            invocation.request.payload,
        );
        try (try self.requireProductControl()).retryAutomaticWorkspaceRoot(
            expected_generation,
        );
        self.notifyCommitted();
        return "{\"outcome\":\"applied\"}";
    }

    fn parseAutomaticWorkspaceRootMutation(payload: []const u8) !u64 {
        var parsed = try handlers.parsePayload(
            handlers.AutomaticWorkspaceRootMutation,
            payload,
        );
        defer parsed.deinit();
        const generation = try handlers.parseWireId(parsed.value.expectedGeneration);
        if (generation == 0) return error.InvalidBridgeId;
        return generation;
    }

    fn createTask(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        var parsed = try handlers.parsePayload(handlers.TaskCreate, invocation.request.payload);
        defer parsed.deinit();
        const workspace_request: product_control.TaskWorkspaceRequest = if (std.mem.eql(
            u8,
            parsed.value.workspace.kind,
            "automatic",
        )) automatic: {
            if (parsed.value.workspace.workspaceId != null or
                parsed.value.workspace.expectedWorkspaceEpoch != null)
                return error.InvalidBridgePayload;
            break :automatic .automatic;
        } else if (std.mem.eql(u8, parsed.value.workspace.kind, "manual")) manual: {
            const workspace_id = try handlers.parseWireId(
                parsed.value.workspace.workspaceId orelse return error.InvalidBridgePayload,
            );
            const workspace_epoch = try handlers.parseWireId(
                parsed.value.workspace.expectedWorkspaceEpoch orelse return error.InvalidBridgePayload,
            );
            break :manual .{ .manual = .{
                .workspace_id = workspace_id,
                .expected_epoch = workspace_epoch,
            } };
        } else return error.InvalidBridgePayload;
        const execution_generation = try handlers.parseWireId(
            parsed.value.expectedExecutionGeneration,
        );
        const selection_revision = try handlers.parseWireId(
            parsed.value.expectedSelectionRevision,
        );
        const model_selection: ?product_control.NewTaskModelSelectionInput =
            if (parsed.value.modelSelection) |selection|
                .{
                    .target = .{
                        .source_id = selection.targetModelRef.sourceId,
                        .model_id = selection.targetModelRef.modelId,
                    },
                    .expected_source_generation = try handlers.parseWireId(
                        selection.expectedSourceGeneration,
                    ),
                    .expected_catalog_generation = try handlers.parseWireId(
                        selection.expectedCatalogGeneration,
                    ),
                }
            else
                null;
        if (parsed.value.expectedSkillCatalogRevision) |revision|
            if (revision.len == 0) return error.InvalidBridgePayload;
        if ((parsed.value.expectedSkillCatalogRevision == null) !=
            (parsed.value.expectedSkillSelectionRevision == null))
            return error.InvalidBridgePayload;
        const skill_selection_revision = if (parsed.value.expectedSkillSelectionRevision) |revision|
            try handlers.parseWireId(revision)
        else
            null;
        const workbench = try self.requireProductControl();
        const approval_mode = handlers.approvalMode(
            parsed.value.approvalMode,
        ) orelse return error.InvalidBridgePayload;
        const task_id = workbench.createTaskForWorkspace(
            workspace_request,
            execution_generation,
            selection_revision,
            model_selection,
            parsed.value.expectedSkillCatalogRevision,
            skill_selection_revision,
            .{ .interactive = approval_mode },
        ) catch |err| {
            if (taskCreateRejection(err)) |reason|
                return encodeTaskCreateResult(output, false, null, null, null, reason, if (err == error.SessionReleaseFailed) workbench.sessionReleaseFailureTaskId() else null);
            return err;
        };
        const binding_epoch = try workbench.taskBindingEpoch(task_id);
        const mcp_authority = try workbench.taskMcpAuthority(task_id);
        self.notifyCommitted();
        return encodeTaskCreateResult(
            output,
            true,
            task_id,
            binding_epoch,
            mcp_authority,
            null,
            null,
        );
    }

    fn runTask(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        var parsed = try handlers.parsePayloadWithLimit(
            handlers.TaskRun,
            invocation.request.payload,
            native_sdk.bridge.max_message_bytes,
        );
        defer parsed.deinit();
        var input = try handlers.parseTaskRunInput(parsed.value.input);
        defer input.deinit();
        const task_id = try handlers.parseWireId(parsed.value.taskId);
        const binding_epoch = try handlers.parseWireId(parsed.value.expectedBindingEpoch);
        const generation = self.delivery.connectedGeneration() orelse return error.NoConnection;
        var attachment_ids: [attachment_grant.max_grants]u64 = undefined;
        var attachment_acceptance: AttachmentGrantAcceptance = undefined;
        const workbench_input: product_control.TaskRunInput = switch (input.value) {
            .text => |text| text_input: {
                if (text.len == 0) return error.EmptyPrompt;
                break :text_input .{ .text = text };
            },
            .skill => |skill| skill_input: {
                if (skill.skill_id.len == 0 or skill.catalog_revision.len == 0)
                    return error.InvalidBridgePayload;
                break :skill_input .{ .skill = .{
                    .skill_id = skill.skill_id,
                    .catalog_revision = skill.catalog_revision,
                    .selection_revision = skill.selection_revision,
                    .argument_values = skill.argument_values,
                } };
            },
            .multimodal => |multimodal| multimodal_input: {
                if (multimodal.text.len > (product_control.Limits{}).max_user_message_bytes)
                    return error.InvalidBridgePayload;
                const ids = self.attachment_grants.resolve(
                    multimodal.attachment_tokens,
                    generation,
                    invocation.source.window_id,
                    &attachment_ids,
                ) catch return error.InvalidBridgePayload;
                attachment_acceptance = .{
                    .dispatcher = self,
                    .tokens = multimodal.attachment_tokens,
                    .generation = generation,
                    .window_id = invocation.source.window_id,
                };
                break :multimodal_input .{ .multimodal = .{
                    .text = multimodal.text,
                    .attachment_ids = ids,
                    .acceptance = .{
                        .context = &attachment_acceptance,
                        .accept_fn = acceptAttachmentGrants,
                    },
                } };
            },
        };
        const run_id = (try self.requireProductControl()).runTaskAtBinding(
            task_id,
            binding_epoch,
            workbench_input,
        ) catch |err| {
            if (taskRunRejection(err)) |reason|
                return encodeTaskRunResult(output, false, task_id, null, reason);
            return err;
        };
        self.notifyCommitted();
        return encodeTaskRunResult(
            output,
            true,
            task_id,
            run_id,
            null,
        );
    }

    fn sendInput(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        var parsed = try handlers.parsePayloadWithLimit(
            handlers.TaskSendInput,
            invocation.request.payload,
            native_sdk.bridge.max_message_bytes,
        );
        defer parsed.deinit();
        try handlers.validateInputOperationId(parsed.value.operationId);
        var input = try handlers.parseTaskRunInput(parsed.value.input);
        defer input.deinit();
        const task_id = try handlers.parseWireId(parsed.value.taskId);
        if (task_id == 0) return error.InvalidBridgePayload;
        const generation = self.delivery.connectedGeneration() orelse return error.NoConnection;
        var attachment_ids: [attachment_grant.max_grants]u64 = undefined;
        var attachment_acceptance: AttachmentGrantAcceptance = undefined;
        const workbench_input: product_control.TaskRunInput = switch (input.value) {
            .text => |text| text_input: {
                if (text.len == 0) return error.EmptyPrompt;
                break :text_input .{ .text = text };
            },
            .skill => |skill| skill_input: {
                if (skill.skill_id.len == 0 or skill.catalog_revision.len == 0)
                    return error.InvalidBridgePayload;
                break :skill_input .{ .skill = .{
                    .skill_id = skill.skill_id,
                    .catalog_revision = skill.catalog_revision,
                    .selection_revision = skill.selection_revision,
                    .argument_values = skill.argument_values,
                } };
            },
            .multimodal => |multimodal| multimodal_input: {
                if (multimodal.text.len > (product_control.Limits{}).max_user_message_bytes)
                    return error.InvalidBridgePayload;
                const ids = self.attachment_grants.resolve(
                    multimodal.attachment_tokens,
                    generation,
                    invocation.source.window_id,
                    &attachment_ids,
                ) catch return error.InvalidBridgePayload;
                attachment_acceptance = .{
                    .dispatcher = self,
                    .tokens = multimodal.attachment_tokens,
                    .generation = generation,
                    .window_id = invocation.source.window_id,
                };
                break :multimodal_input .{ .multimodal = .{
                    .text = multimodal.text,
                    .attachment_ids = ids,
                    .acceptance = .{
                        .context = &attachment_acceptance,
                        .accept_fn = acceptAttachmentGrants,
                    },
                } };
            },
        };
        const control = try self.requireProductControl();
        const result = control.sendInput(parsed.value.operationId, task_id, workbench_input) catch |err| {
            if (err == error.InvalidInput) return error.InvalidBridgePayload;
            if (err == error.UnknownTask) {
                var rejected: product_control.SendInputResult = .{ .task_id = task_id, .operation_id_len = @intCast(parsed.value.operationId.len), .reason = .task_unavailable };
                @memcpy(rejected.operation_id[0..rejected.operation_id_len], parsed.value.operationId);
                return encodeSendInputResult(output, control, rejected);
            }
            return err;
        };
        self.notifyCommitted();
        return encodeSendInputResult(output, control, result);
    }

    fn acceptAttachmentGrants(context: ?*anyopaque) void {
        const acceptance: *AttachmentGrantAcceptance = @ptrCast(@alignCast(context.?));
        acceptance.dispatcher.attachment_grants.consume(
            acceptance.tokens,
            acceptance.generation,
            acceptance.window_id,
        );
    }

    fn releaseAttachment(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        var parsed = try handlers.parsePayload(
            handlers.AttachmentRelease,
            invocation.request.payload,
        );
        defer parsed.deinit();
        if (!handlers.validAttachmentToken(parsed.value.token))
            return error.InvalidBridgePayload;
        const generation = self.delivery.connectedGeneration() orelse return error.NoConnection;
        const id = self.attachment_grants.release(
            parsed.value.token,
            generation,
            invocation.source.window_id,
        );
        const released = if (id) |attachment_id|
            try (try self.requireProductControl()).releaseAttachmentChecked(attachment_id)
        else
            false;
        return std.fmt.bufPrint(output, "{{\"released\":{}}}", .{released});
    }

    fn setApprovalMode(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        var parsed = try handlers.parsePayload(handlers.TaskApprovalMode, invocation.request.payload);
        defer parsed.deinit();
        const task_id = try handlers.parseWireId(parsed.value.taskId);
        const epoch = try handlers.parseWireId(parsed.value.expectedBindingEpoch);
        const expected_revision = try handlers.parseWireId(parsed.value.expectedApprovalRevision);
        if (task_id == 0 or epoch == 0 or expected_revision == 0) return error.InvalidBridgeId;
        const revision = (try self.requireProductControl()).setApprovalMode(task_id, parsed.value.targetMode, epoch, expected_revision) catch |err| {
            if (taskApprovalModeRejection(err)) |reason|
                return encodeTaskApprovalModeResult(output, task_id, null, reason);
            return err;
        };
        self.notifyCommitted();
        return encodeTaskApprovalModeResult(output, task_id, revision, null);
    }

    fn selectTaskModel(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        var parsed = try handlers.parsePayload(
            handlers.TaskModelSelection,
            invocation.request.payload,
        );
        defer parsed.deinit();
        if (parsed.value.targetModelRef.sourceId.len == 0 or
            parsed.value.targetModelRef.sourceId.len > models_contract.Limits.provider_id_bytes or
            !std.unicode.utf8ValidateSlice(parsed.value.targetModelRef.sourceId) or
            parsed.value.targetModelRef.modelId.len == 0 or
            parsed.value.targetModelRef.modelId.len > models_contract.Limits.model_id_bytes or
            !std.unicode.utf8ValidateSlice(parsed.value.targetModelRef.modelId))
            return error.InvalidBridgePayload;
        const task_id = try handlers.parseWireId(parsed.value.taskId);
        const selection_revision = try handlers.parseWireId(
            parsed.value.expectedSelectionRevision,
        );
        const source_generation = try handlers.parseWireId(
            parsed.value.expectedSourceGeneration,
        );
        const catalog_generation = try handlers.parseWireId(
            parsed.value.expectedCatalogGeneration,
        );
        if (task_id == 0 or source_generation == 0 or
            catalog_generation == 0)
            return error.InvalidBridgePayload;
        const revision = (try self.requireProductControl()).selectTaskModel(
            task_id,
            .{
                .expected_selection_revision = selection_revision,
                .target = .{
                    .source_id = parsed.value.targetModelRef.sourceId,
                    .model_id = parsed.value.targetModelRef.modelId,
                },
                .expected_source_generation = source_generation,
                .expected_catalog_generation = catalog_generation,
            },
        ) catch |err| {
            if (taskModelSelectionRejection(err)) |reason| {
                self.notifyCommitted();
                return encodeTaskModelSelectionResult(
                    output,
                    false,
                    task_id,
                    null,
                    reason,
                );
            }
            return err;
        };
        self.notifyCommitted();
        return encodeTaskModelSelectionResult(
            output,
            true,
            task_id,
            revision,
            null,
        );
    }

    fn compactTask(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        var parsed = try handlers.parsePayload(
            handlers.TaskCompact,
            invocation.request.payload,
        );
        defer parsed.deinit();
        const task_id = try handlers.parseWireId(parsed.value.taskId);
        const binding_epoch = try handlers.parseWireId(
            parsed.value.expectedBindingEpoch,
        );
        const operation_id = (try self.requireProductControl()).compactTaskAtBinding(
            task_id,
            binding_epoch,
        ) catch |err| {
            if (taskCompactRejection(err)) |reason|
                return encodeTaskCompactResult(
                    output,
                    false,
                    task_id,
                    null,
                    reason,
                );
            return err;
        };
        self.notifyCommitted();
        return encodeTaskCompactResult(
            output,
            true,
            task_id,
            operation_id,
            null,
        );
    }

    fn restoreTask(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        var parsed = try handlers.parsePayload(
            handlers.TaskRestore,
            invocation.request.payload,
        );
        defer parsed.deinit();
        const task_id = try handlers.parseWireId(parsed.value.taskId);
        const binding_epoch = try handlers.parseWireId(
            parsed.value.expectedBindingEpoch,
        );
        const workbench = try self.requireProductControl();
        const attempt_id = workbench.restoreTaskConversation(
            task_id,
            binding_epoch,
        ) catch |err| {
            if (taskRestoreRejection(err)) |reason|
                return encodeTaskRestoreResult(
                    output,
                    false,
                    task_id,
                    null,
                    reason,
                    if (err == error.SessionReleaseFailed) workbench.sessionReleaseFailureTaskId() else null,
                );
            return err;
        };
        self.notifyCommitted();
        return encodeTaskRestoreResult(
            output,
            true,
            task_id,
            attempt_id,
            null,
            null,
        );
    }

    fn cancelCompact(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        var parsed = try handlers.parsePayload(
            handlers.TaskCompactIdentity,
            invocation.request.payload,
        );
        defer parsed.deinit();
        const task_id = try handlers.parseWireId(parsed.value.taskId);
        const operation_id = try handlers.parseWireId(parsed.value.operationId);
        try (try self.requireProductControl()).cancelCompact(task_id, operation_id);
        self.notifyCommitted();
        return std.fmt.bufPrint(
            output,
            "{{\"taskId\":\"{d}\",\"operationId\":\"{d}\",\"cancelRequested\":true}}",
            .{ task_id, operation_id },
        );
    }

    fn refreshWorkspaceSkillCatalog(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        var parsed = try handlers.parsePayload(
            handlers.WorkspaceIdentity,
            invocation.request.payload,
        );
        defer parsed.deinit();
        const workspace_id = try handlers.parseWireId(parsed.value.workspaceId);
        const expected_epoch = try handlers.parseWireId(
            parsed.value.expectedWorkspaceEpoch,
        );
        const workbench = try self.requireProductControl();
        workbench.refreshWorkspaceCatalog(
            workspace_id,
            expected_epoch,
        ) catch |err| {
            if (catalogRefreshRejection(err)) |reason|
                return encodeCatalogRefreshResult(
                    output,
                    false,
                    "workspaceId",
                    workspace_id,
                    reason,
                );
            return err;
        };
        self.notifyCommitted();
        return encodeCatalogRefreshResult(
            output,
            true,
            "workspaceId",
            workspace_id,
            null,
        );
    }

    fn refreshSkillCatalog(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        var parsed = try handlers.parsePayload(
            handlers.Empty,
            invocation.request.payload,
        );
        defer parsed.deinit();
        (try self.requireProductControl()).refreshSkillCatalog() catch |err| {
            if (catalogRefreshRejection(err)) |reason|
                return encodeSkillCatalogRefreshResult(output, false, reason);
            return err;
        };
        self.notifyCommitted();
        return encodeSkillCatalogRefreshResult(output, true, null);
    }

    fn setSkillEnabled(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        var parsed = try handlers.parsePayload(
            handlers.SkillSetEnabled,
            invocation.request.payload,
        );
        defer parsed.deinit();
        if (parsed.value.skillPolicyKey.len == 0 or
            parsed.value.expectedCatalogRevision.len == 0)
            return error.InvalidBridgePayload;
        const state: product_control.SkillEnablementState =
            if (std.mem.eql(u8, parsed.value.state, "enabled"))
                .enabled
            else if (std.mem.eql(u8, parsed.value.state, "disabled"))
                .disabled
            else if (std.mem.eql(u8, parsed.value.state, "inherit"))
                .inherit
            else
                return error.InvalidBridgePayload;
        const scope: product_control.SkillEnablementScope =
            if (std.mem.eql(u8, parsed.value.scope, "personal")) personal: {
                if (parsed.value.workspaceId != null or
                    parsed.value.expectedWorkspaceEpoch != null or
                    state == .inherit)
                    return error.InvalidBridgePayload;
                break :personal .personal;
            } else if (std.mem.eql(u8, parsed.value.scope, "project")) project: {
                const workspace_id = parsed.value.workspaceId orelse
                    return error.InvalidBridgePayload;
                const workspace_epoch = parsed.value.expectedWorkspaceEpoch orelse
                    return error.InvalidBridgePayload;
                break :project .{ .project = .{
                    .workspace_id = try handlers.parseWireId(workspace_id),
                    .expected_workspace_epoch = try handlers.parseWireId(workspace_epoch),
                } };
            } else return error.InvalidBridgePayload;
        const next_revision = (try self.requireProductControl()).setSkillEnabled(.{
            .scope = scope,
            .skill_policy_key = parsed.value.skillPolicyKey,
            .state = state,
            .expected_catalog_revision = parsed.value.expectedCatalogRevision,
            .expected_selection_revision = try handlers.parseWireId(
                parsed.value.expectedSelectionRevision,
            ),
        }) catch |err| {
            const reason = skillMutationRejection(err) orelse return err;
            return std.fmt.bufPrint(
                output,
                "{{\"applied\":false,\"selectionRevision\":null,\"reason\":\"{s}\"}}",
                .{reason},
            );
        };
        self.notifyCommitted();
        return std.fmt.bufPrint(
            output,
            "{{\"applied\":true,\"selectionRevision\":\"{d}\",\"reason\":null}}",
            .{next_revision},
        );
    }

    fn setSkillSourceEnabled(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        var parsed = try handlers.parsePayload(handlers.SkillSourceSetEnabled, invocation.request.payload);
        defer parsed.deinit();
        const brand = try handlers.parseSkillSourceBrand(parsed.value.sourceId);
        const revision = try handlers.parseWireId(parsed.value.expectedRevision);
        if (revision == 0) return error.InvalidBridgeId;
        const result = (try self.requireProductControl()).setSkillSourceEnabled(brand, parsed.value.enabled, revision);
        if (result.changed) self.notifyCommitted();
        return encodeSourceSettingsResult(output, result);
    }

    fn recoverSkillSourceSettings(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        var parsed = try handlers.parsePayload(handlers.SkillSourceRecover, invocation.request.payload);
        defer parsed.deinit();
        const action = std.meta.stringToEnum(skill_runtime.SourceRecoveryAction, parsed.value.action) orelse return error.InvalidBridgePayload;
        const token = try handlers.parseWireId(parsed.value.expectedRecoveryToken);
        if (token == 0) return error.InvalidBridgeId;
        const result = (try self.requireProductControl()).recoverSkillSourceSettings(action, token);
        if (result.changed) self.notifyCommitted();
        return encodeSourceSettingsResult(output, result);
    }

    fn encodeSourceSettingsResult(output: []u8, result: skill_runtime.SourceSettingsResult) ![]const u8 {
        if (result.applied) return std.fmt.bufPrint(output, "{{\"applied\":true,\"revision\":\"{d}\",\"reason\":null}}", .{result.revision.?});
        return std.fmt.bufPrint(output, "{{\"applied\":false,\"revision\":null,\"reason\":\"{s}\"}}", .{@tagName(result.reason.?)});
    }

    fn chooseSkillImport(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        const generation = self.delivery.connectedGeneration() orelse
            return error.NoConnection;
        var parsed = try handlers.parsePayload(
            handlers.SkillImportChoice,
            invocation.request.payload,
        );
        defer parsed.deinit();
        const source_kind: skill_grant.SourceKind =
            if (std.mem.eql(u8, parsed.value.kind, "package"))
                .local_package
            else if (std.mem.eql(u8, parsed.value.kind, "directory"))
                .local_directory
            else
                return error.InvalidBridgePayload;
        self.skill_grants.invalidate();
        var dialog_storage: [native_sdk.platform.max_dialog_paths_bytes]u8 = undefined;
        const package_filters = [_]native_sdk.platform.FileFilter{.{
            .name = "Skill packages",
            .extensions = &.{ "skill", "zip" },
        }};
        const selected = try self.platform.show_open_dialog_fn(
            self.platform.context,
            .{
                .title = if (source_kind == .local_package)
                    "Choose a Skill package"
                else
                    "Choose a Skill folder",
                .filters = if (source_kind == .local_package)
                    &package_filters
                else
                    &.{},
                .allow_directories = source_kind == .local_directory,
                .allow_multiple = false,
            },
            &dialog_storage,
        );
        if (selected.count == 0) return "{\"selected\":false}";
        if (selected.count != 1 or selected.paths.len == 0 or
            selected.paths.len > skill_grant.max_path_bytes)
            return error.InvalidBridgePayload;
        var preview = switch (source_kind) {
            .local_package => try (try self.requireProductControl()).previewSkillArchive(
                selected.paths,
            ),
            .local_directory => try (try self.requireProductControl()).previewSkillDirectory(
                selected.paths,
            ),
        };
        defer preview.deinit();
        const issued = try self.skill_grants.issue(
            generation,
            invocation.source.window_id,
            self.now(),
            .{
                .source_kind = source_kind,
                .selected_path = selected.paths,
                .invocation_name = preview.invocation_name,
                .description = preview.description,
                .file_count = preview.file_count,
                .total_bytes = preview.total_bytes,
                .content_hash = preview.content_hash,
            },
        );
        var writer = std.Io.Writer.fixed(output);
        writer.print(
            "{{\"selected\":true,\"previewId\":\"{d}\",\"sourceKind\":\"{s}\",\"invocationName\":",
            .{ issued.token, @tagName(source_kind) },
        ) catch return error.NoSpaceLeft;
        std.json.Stringify.value(issued.invocation_name, .{}, &writer) catch
            return error.NoSpaceLeft;
        writer.writeAll(",\"displayName\":") catch return error.NoSpaceLeft;
        std.json.Stringify.value(issued.invocation_name, .{}, &writer) catch
            return error.NoSpaceLeft;
        writer.writeAll(",\"description\":") catch return error.NoSpaceLeft;
        std.json.Stringify.value(issued.description, .{}, &writer) catch
            return error.NoSpaceLeft;
        writer.print(",\"fileCount\":{d},\"totalBytes\":{d}}}", .{
            issued.file_count,
            issued.total_bytes,
        }) catch return error.NoSpaceLeft;
        return writer.buffered();
    }

    fn installSkill(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        var parsed = try handlers.parsePayload(
            handlers.SkillInstall,
            invocation.request.payload,
        );
        defer parsed.deinit();
        const preview_id = try handlers.parseWireId(parsed.value.previewId);
        const scope = parseSkillScope(
            parsed.value.scope,
            parsed.value.workspaceId,
            parsed.value.expectedWorkspaceEpoch,
        ) catch return encodeSkillMutationResult(
            output,
            false,
            null,
            false,
            "invalid_scope",
        );
        const consumed = self.skill_grants.consume(
            preview_id,
            invocation.source.window_id,
            self.delivery.connectedGeneration() orelse return error.NoConnection,
            self.now(),
        ) catch return encodeSkillMutationResult(
            output,
            false,
            null,
            false,
            "invalid_preview",
        );
        const source_kind: skill_management.SourceKind = switch (consumed.source_kind) {
            .local_package => .local_package,
            .local_directory => .local_directory,
        };
        const input: product_control.SkillInstallInput = .{
            .source_kind = source_kind,
            .scope = scope,
            .expected_invocation_name = consumed.invocationName(),
            .expected_content_hash = consumed.content_hash,
            .allow_replace = parsed.value.allowReplace,
        };
        const result = switch (consumed.source_kind) {
            .local_package => (try self.requireProductControl()).installSkillArchive(
                consumed.path(),
                input,
            ),
            .local_directory => (try self.requireProductControl()).installSkillDirectory(
                consumed.path(),
                input,
            ),
        } catch |err| {
            if (skillMutationRejection(err)) |reason| {
                if (skillMutationMayHaveCommitted(err)) self.notifyCommitted();
                return encodeSkillMutationResult(
                    output,
                    false,
                    null,
                    false,
                    reason,
                );
            }
            return err;
        };
        self.notifyCommitted();
        return encodeSkillMutationResult(
            output,
            true,
            result.install_id,
            result.verification_pending,
            null,
        );
    }

    fn reimportSkill(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        var parsed = try handlers.parsePayload(
            handlers.SkillReimport,
            invocation.request.payload,
        );
        defer parsed.deinit();
        const install_id = parseSkillInstallId(parsed.value.installId) catch
            return encodeSkillMutationResult(
                output,
                false,
                null,
                false,
                "asset_unavailable",
            );
        const preview_id = try handlers.parseWireId(parsed.value.previewId);
        const consumed = self.skill_grants.consume(
            preview_id,
            invocation.source.window_id,
            self.delivery.connectedGeneration() orelse return error.NoConnection,
            self.now(),
        ) catch return encodeSkillMutationResult(
            output,
            false,
            null,
            false,
            "invalid_preview",
        );
        const result = switch (consumed.source_kind) {
            .local_package => (try self.requireProductControl()).reimportSkillArchive(
                install_id,
                consumed.path(),
                consumed.invocationName(),
                consumed.content_hash,
            ),
            .local_directory => (try self.requireProductControl()).reimportSkillDirectory(
                install_id,
                consumed.path(),
                consumed.invocationName(),
                consumed.content_hash,
            ),
        } catch |err| {
            if (skillMutationRejection(err)) |reason| {
                if (skillMutationMayHaveCommitted(err)) self.notifyCommitted();
                return encodeSkillMutationResult(
                    output,
                    false,
                    null,
                    false,
                    reason,
                );
            }
            return err;
        };
        self.notifyCommitted();
        return encodeSkillMutationResult(
            output,
            true,
            result.install_id,
            result.verification_pending,
            null,
        );
    }

    fn uninstallSkill(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        return mutateExistingSkill(context, invocation, output, .uninstall);
    }

    fn retrySkill(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        return mutateExistingSkill(context, invocation, output, .retry);
    }

    const ExistingSkillMutation = enum { uninstall, retry };

    fn mutateExistingSkill(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
        operation: ExistingSkillMutation,
    ) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        var parsed = try handlers.parsePayload(
            handlers.SkillIdentity,
            invocation.request.payload,
        );
        defer parsed.deinit();
        const install_id = parseSkillInstallId(parsed.value.installId) catch
            return encodeSkillMutationResult(
                output,
                false,
                null,
                false,
                "asset_unavailable",
            );
        const workbench = try self.requireProductControl();
        const result = switch (operation) {
            .uninstall => workbench.uninstallSkill(install_id),
            .retry => workbench.retrySkillVerification(install_id),
        } catch |err| {
            if (skillMutationRejection(err)) |reason| {
                if (skillMutationMayHaveCommitted(err)) self.notifyCommitted();
                return encodeSkillMutationResult(
                    output,
                    false,
                    null,
                    false,
                    reason,
                );
            }
            return err;
        };
        self.notifyCommitted();
        return encodeSkillMutationResult(
            output,
            true,
            result.install_id,
            result.verification_pending,
            null,
        );
    }

    fn exportSkill(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        var parsed = try handlers.parsePayload(
            handlers.SkillIdentity,
            invocation.request.payload,
        );
        defer parsed.deinit();
        const install_id = parseSkillInstallId(parsed.value.installId) catch
            return encodeSkillExportResult(output, false, null, "asset_unavailable");
        var dialog_storage: [native_sdk.platform.max_dialog_paths_bytes]u8 = undefined;
        const selected = try self.platform.show_open_dialog_fn(
            self.platform.context,
            .{
                .title = "Export Skill package",
                .allow_directories = true,
                .allow_multiple = false,
            },
            &dialog_storage,
        );
        if (selected.count == 0) return "{\"exported\":false,\"fileName\":null,\"reason\":\"cancelled\"}";
        if (selected.count != 1 or selected.paths.len == 0 or
            selected.paths.len > skill_grant.max_path_bytes)
            return error.InvalidBridgePayload;
        const result = (try self.requireProductControl()).exportSkill(
            install_id,
            selected.paths,
        ) catch |err| return encodeSkillExportResult(
            output,
            false,
            null,
            skillMutationRejection(err) orelse "export_failed",
        );
        return encodeSkillExportResult(output, true, result.fileName(), null);
    }

    fn skillDetail(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        var parsed = try handlers.parsePayload(
            handlers.SkillIdentity,
            invocation.request.payload,
        );
        defer parsed.deinit();
        const install_id = parseSkillInstallId(parsed.value.installId) catch
            return encodeSkillDetailUnavailable(output, "asset_unavailable");
        var detail = (try self.requireProductControl()).readSkillDefinition(
            install_id,
        ) catch |err| return encodeSkillDetailUnavailable(
            output,
            skillMutationRejection(err) orelse "detail_unavailable",
        );
        defer detail.deinit();
        var writer = std.Io.Writer.fixed(output);
        writer.writeAll("{\"available\":true,\"definition\":") catch
            return error.NoSpaceLeft;
        std.json.Stringify.value(detail.definition, .{}, &writer) catch
            return error.NoSpaceLeft;
        writer.print(",\"fileCount\":{d},\"totalBytes\":{d},\"reason\":null}}", .{
            detail.file_count,
            detail.total_bytes,
        }) catch return error.NoSpaceLeft;
        return writer.buffered();
    }

    fn createMcpStdioServer(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        var parsed = try handlers.parsePayloadWithLimit(
            handlers.McpCreateStdioServer,
            invocation.request.payload,
            256 * 1024,
        );
        defer parsed.deinit();
        try validateMcpConnectionFields(
            parsed.value.negotiation,
            parsed.value.timeoutMs,
            parsed.value.arguments,
            parsed.value.environmentNames,
        );
        const expected = try handlers.parseWireId(parsed.value.expectedDesiredGeneration);
        const workbench = try self.requireProductControl();
        const outcome = try workbench.createMcpStdioServer(expected, .{
            .display_name = parsed.value.displayName,
            .negotiation = parsed.value.negotiation,
            .timeout_ms = parsed.value.timeoutMs,
            .command = parsed.value.command,
            .arguments = parsed.value.arguments,
            .cwd = parsed.value.cwd,
            .auth_mode = if (parsed.value.environmentNames.len == 0) .none else .static,
            .environment_names = parsed.value.environmentNames,
        });
        return self.finishMcpMutation(workbench, output, outcome);
    }

    fn createMcpHttpServer(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        var parsed = try handlers.parsePayloadWithLimit(
            handlers.McpCreateHttpServer,
            invocation.request.payload,
            8 * 1024,
        );
        defer parsed.deinit();
        try validateMcpConnectionFields(
            parsed.value.negotiation,
            parsed.value.timeoutMs,
            &.{},
            parsed.value.headerNames,
        );
        const expected = try handlers.parseWireId(parsed.value.expectedDesiredGeneration);
        const workbench = try self.requireProductControl();
        const outcome = if (std.mem.eql(u8, parsed.value.authMode, "oauth")) oauth: {
            if (parsed.value.headerNames.len != 0) return error.InvalidBridgePayload;
            break :oauth try workbench.createMcpOauthHttpServer(expected, .{
                .display_name = parsed.value.displayName,
                .negotiation = parsed.value.negotiation,
                .timeout_ms = parsed.value.timeoutMs,
                .url = parsed.value.endpoint,
                .client = try mcpOauthClientPlan(parsed.value.registration),
            });
        } else try workbench.createMcpHttpServer(expected, .{
            .display_name = parsed.value.displayName,
            .negotiation = parsed.value.negotiation,
            .timeout_ms = parsed.value.timeoutMs,
            .url = parsed.value.endpoint,
            .auth_mode = try mcpStaticAuthMode(
                parsed.value.authMode,
                parsed.value.registration,
                parsed.value.headerNames,
            ),
            .header_names = parsed.value.headerNames,
        });
        return self.finishMcpMutation(workbench, output, outcome);
    }

    fn updateMcpStdioConnection(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        var parsed = try handlers.parsePayloadWithLimit(
            handlers.McpUpdateStdioConnection,
            invocation.request.payload,
            256 * 1024,
        );
        defer parsed.deinit();
        try validateMcpConnectionFields(
            parsed.value.negotiation,
            parsed.value.timeoutMs,
            parsed.value.arguments,
            parsed.value.environmentNames,
        );
        const expected = try handlers.parseWireId(parsed.value.expectedDesiredGeneration);
        const workbench = try self.requireProductControl();
        if (workbench.mcpServerOperationBusy(parsed.value.serverId))
            return encodeMcpTypedOutcome(output, "busy", null);
        const outcome = try workbench.updateMcpStdioConnection(expected, .{
            .server_id = parsed.value.serverId,
            .display_name = parsed.value.displayName,
            .negotiation = parsed.value.negotiation,
            .timeout_ms = parsed.value.timeoutMs,
            .command = parsed.value.command,
            .arguments = parsed.value.arguments,
            .cwd = parsed.value.cwd,
            .auth_mode = if (parsed.value.environmentNames.len == 0) .none else .static,
            .environment_names = parsed.value.environmentNames,
        });
        return self.finishMcpMutation(workbench, output, outcome);
    }

    fn updateMcpHttpConnection(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        var parsed = try handlers.parsePayloadWithLimit(
            handlers.McpUpdateHttpConnection,
            invocation.request.payload,
            256 * 1024,
        );
        defer parsed.deinit();
        try validateMcpConnectionFields(
            parsed.value.negotiation,
            parsed.value.timeoutMs,
            &.{},
            parsed.value.headerNames,
        );
        const expected = try handlers.parseWireId(parsed.value.expectedDesiredGeneration);
        const workbench = try self.requireProductControl();
        if (workbench.mcpServerOperationBusy(parsed.value.serverId))
            return encodeMcpTypedOutcome(output, "busy", null);
        const outcome = if (std.mem.eql(u8, parsed.value.authMode, "oauth")) oauth: {
            if (parsed.value.headerNames.len != 0) return error.InvalidBridgePayload;
            break :oauth try workbench.updateMcpOauthHttpConnection(expected, .{
                .server_id = parsed.value.serverId,
                .display_name = parsed.value.displayName,
                .negotiation = parsed.value.negotiation,
                .timeout_ms = parsed.value.timeoutMs,
                .url = parsed.value.endpoint,
                .client = try mcpOauthClientPlan(parsed.value.registration),
            });
        } else try workbench.updateMcpHttpConnection(expected, .{
            .server_id = parsed.value.serverId,
            .display_name = parsed.value.displayName,
            .negotiation = parsed.value.negotiation,
            .timeout_ms = parsed.value.timeoutMs,
            .url = parsed.value.endpoint,
            .auth_mode = try mcpStaticAuthMode(
                parsed.value.authMode,
                parsed.value.registration,
                parsed.value.headerNames,
            ),
            .header_names = parsed.value.headerNames,
        });
        return self.finishMcpMutation(workbench, output, outcome);
    }

    fn renameMcpServer(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        var parsed = try handlers.parsePayload(
            handlers.McpServerRename,
            invocation.request.payload,
        );
        defer parsed.deinit();
        const expected = try handlers.parseWireId(parsed.value.expectedDesiredGeneration);
        const workbench = try self.requireProductControl();
        if (workbench.mcpServerOperationBusy(parsed.value.serverId))
            return encodeMcpTypedOutcome(output, "busy", null);
        const outcome = try workbench.renameMcpServer(expected, .{
            .server_id = parsed.value.serverId,
            .display_name = parsed.value.displayName,
        });
        return self.finishMcpMutation(workbench, output, outcome);
    }

    fn approveMcpConnection(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        var parsed = try handlers.parsePayload(handlers.McpServerIdentity, invocation.request.payload);
        defer parsed.deinit();
        const expected = try handlers.parseWireId(parsed.value.expectedDesiredGeneration);
        const workbench = try self.requireProductControl();
        if (workbench.mcpServerOperationBusy(parsed.value.serverId))
            return encodeMcpTypedOutcome(output, "busy", null);
        const host = self.mcp_management_host orelse
            return self.finishMcpHostMutation(workbench, output, .capability_unavailable);
        const outcome = try host.approve_fn(host.context, expected, parsed.value.serverId);
        return self.finishMcpHostMutation(workbench, output, outcome);
    }

    fn captureMcpSecret(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        var parsed = try handlers.parsePayloadWithLimit(
            handlers.McpCaptureSecret,
            invocation.request.payload,
            native_sdk.platform.max_credential_secret_bytes * 6 + 8 * 1024,
        );
        defer parsed.deinit();
        const expected = try handlers.parseWireId(parsed.value.expectedDesiredGeneration);
        const workbench = try self.requireProductControl();
        if (workbench.mcpServerOperationBusy(parsed.value.serverId))
            return encodeMcpTypedOutcome(output, "busy", null);
        const slot: McpSecretSlot = if (std.mem.eql(u8, parsed.value.slot.kind, "stdio_environment"))
            .{ .stdio_environment = parsed.value.slot.name orelse return error.InvalidBridgePayload }
        else if (std.mem.eql(u8, parsed.value.slot.kind, "http_header"))
            .{ .http_header = parsed.value.slot.name orelse return error.InvalidBridgePayload }
        else if (std.mem.eql(u8, parsed.value.slot.kind, "oauth_client_secret") and
            parsed.value.slot.name == null)
            .oauth_client_secret
        else
            return error.InvalidBridgePayload;
        const host = self.mcp_management_host orelse
            return self.finishMcpHostMutation(workbench, output, .capability_unavailable);
        if (parsed.value.secret.len == 0 or
            parsed.value.secret.len > native_sdk.platform.max_credential_secret_bytes)
            return error.InvalidBridgePayload;
        const outcome = try host.capture_fn(
            host.context,
            expected,
            parsed.value.serverId,
            slot,
            parsed.value.secret,
        );
        return self.finishMcpHostMutation(workbench, output, outcome);
    }

    fn authorizeMcpOauth(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        var parsed = try handlers.parsePayload(handlers.McpServerIdentity, invocation.request.payload);
        defer parsed.deinit();
        const expected = try handlers.parseWireId(parsed.value.expectedDesiredGeneration);
        const workbench = try self.requireProductControl();
        if (workbench.mcpServerOperationBusy(parsed.value.serverId)) return std.fmt.bufPrint(
            output,
            "{{\"outcome\":\"busy\",\"operationId\":null}}",
            .{},
        );
        const host = self.mcp_management_host orelse return std.fmt.bufPrint(
            output,
            "{{\"outcome\":\"capability_unavailable\",\"operationId\":null}}",
            .{},
        );
        return switch (try host.authorize_fn(host.context, expected, parsed.value.serverId)) {
            .started => |operation_id| started: {
                self.notifyCommitted();
                break :started std.fmt.bufPrint(
                    output,
                    "{{\"outcome\":\"started\",\"operationId\":{f}}}",
                    .{std.json.fmt(operation_id, .{})},
                );
            },
            .rejected => std.fmt.bufPrint(output, "{{\"outcome\":\"rejected\",\"operationId\":null}}", .{}),
            .stale_generation => std.fmt.bufPrint(output, "{{\"outcome\":\"stale_generation\",\"operationId\":null}}", .{}),
            .capability_unavailable => std.fmt.bufPrint(output, "{{\"outcome\":\"capability_unavailable\",\"operationId\":null}}", .{}),
        };
    }

    fn cancelMcpAuthorization(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        var parsed = try handlers.parsePayload(
            handlers.McpCancelAuthorization,
            invocation.request.payload,
        );
        defer parsed.deinit();
        const host = self.mcp_management_host orelse return std.fmt.bufPrint(
            output,
            "{{\"outcome\":\"capability_unavailable\"}}",
            .{},
        );
        const outcome = host.cancel_fn(host.context, parsed.value.operationId);
        if (outcome == .cancelled or outcome == .saved or
            outcome == .saved_recovery_required or outcome == .indeterminate)
            self.notifyCommitted();
        return std.fmt.bufPrint(output, "{{\"outcome\":\"{s}\"}}", .{@tagName(outcome)});
    }

    fn setMcpServerEnabled(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        var parsed = try handlers.parsePayload(
            handlers.McpServerEnable,
            invocation.request.payload,
        );
        defer parsed.deinit();
        const expected = try handlers.parseWireId(parsed.value.expectedDesiredGeneration);
        const workbench = try self.requireProductControl();
        if (workbench.mcpServerOperationBusy(parsed.value.serverId))
            return encodeMcpTypedOutcome(output, "busy", null);
        const outcome = try workbench.setMcpServerEnabled(expected, .{
            .server_id = parsed.value.serverId,
            .enabled = parsed.value.enabled,
        });
        return self.finishMcpMutation(workbench, output, outcome);
    }

    fn setMcpAllowedTools(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        var parsed = try handlers.parsePayloadWithLimit(
            handlers.McpAllowedTools,
            invocation.request.payload,
            256 * 1024,
        );
        defer parsed.deinit();
        try validateMcpToolNames(parsed.value.toolNames);
        const expected = try handlers.parseWireId(parsed.value.expectedDesiredGeneration);
        const workbench = try self.requireProductControl();
        if (workbench.mcpServerOperationBusy(parsed.value.serverId))
            return encodeMcpTypedOutcome(output, "busy", null);
        const outcome = try workbench.setMcpAllowedTools(expected, .{
            .server_id = parsed.value.serverId,
            .tools = parsed.value.toolNames,
        });
        return self.finishMcpMutation(workbench, output, outcome);
    }

    fn removeMcpServer(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        var parsed = try handlers.parsePayload(
            handlers.McpServerIdentity,
            invocation.request.payload,
        );
        defer parsed.deinit();
        const expected = try handlers.parseWireId(parsed.value.expectedDesiredGeneration);
        const workbench = try self.requireProductControl();
        if (workbench.mcpServerOperationBusy(parsed.value.serverId))
            return encodeMcpTypedOutcome(output, "busy", null);
        const outcome = try workbench.removeMcpServer(expected, parsed.value.serverId);
        return self.finishMcpMutation(workbench, output, outcome);
    }

    fn refreshMcpCatalog(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        var parsed = try handlers.parsePayload(handlers.Empty, invocation.request.payload);
        defer parsed.deinit();
        const workbench = try self.requireProductControl();
        workbench.refreshMcpCatalog() catch |err| {
            const outcome: ?[]const u8 = if (err == error.CatalogLoading)
                "busy"
            else if (err == error.CatalogUnavailable)
                "unavailable"
            else if (err == error.ExecutorShuttingDown)
                "shutting_down"
            else if (err == error.CatalogRequestGenerationExhausted)
                "rejected"
            else if (err == error.McpManagementUnavailable)
                "rejected"
            else
                null;
            if (outcome) |value|
                return std.fmt.bufPrint(output, "{{\"outcome\":\"{s}\"}}", .{value});
            return err;
        };
        self.notifyCommitted();
        return std.fmt.bufPrint(output, "{{\"outcome\":\"started\"}}", .{});
    }

    fn testMcpConnection(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        var parsed = try handlers.parsePayload(
            handlers.McpServerIdentity,
            invocation.request.payload,
        );
        defer parsed.deinit();
        const expected = try handlers.parseWireId(parsed.value.expectedDesiredGeneration);
        const host = self.mcp_management_host orelse
            return std.fmt.bufPrint(output, "{{\"outcome\":\"unavailable\"}}", .{});
        const outcome = try host.test_fn(host.context, expected, parsed.value.serverId);
        if (outcome == .started) self.notifyCommitted();
        return std.fmt.bufPrint(output, "{{\"outcome\":\"{s}\"}}", .{@tagName(outcome)});
    }

    fn applyMcpConfiguration(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        var parsed = try handlers.parsePayload(handlers.Empty, invocation.request.payload);
        defer parsed.deinit();
        const host = self.mcp_management_host orelse
            return std.fmt.bufPrint(output, "{{\"outcome\":\"unavailable\"}}", .{});
        const outcome = try host.apply_fn(host.context);
        if (outcome == .started) self.notifyCommitted();
        return std.fmt.bufPrint(output, "{{\"outcome\":\"{s}\"}}", .{@tagName(outcome)});
    }

    fn finishMcpMutation(
        self: *Dispatcher,
        workbench: *product_control.Runtime,
        output: []u8,
        outcome: mcp_configuration.ManagementOutcome,
    ) ![]const u8 {
        if (outcome == .saved or outcome == .saved_recovery_required)
            self.startMcpConfigurationApplyIfNeeded(workbench);
        if (outcome != .unchanged and outcome != .stale_generation)
            self.notifyCommitted();
        const inspection = workbench.inspectMcpDesiredConfiguration();
        const generation: ?u64 = if (outcome == .indeterminate)
            null
        else if (inspection) |value|
            if (value.health == .outcome_unknown)
                null
            else if (value.desired_generation) |current|
                current
            else if (value.health == .ready)
                0
            else
                null
        else
            null;
        if (generation) |current| return std.fmt.bufPrint(
            output,
            "{{\"outcome\":\"{s}\",\"desiredGeneration\":\"{d}\"}}",
            .{ @tagName(outcome), current },
        );
        return std.fmt.bufPrint(
            output,
            "{{\"outcome\":\"{s}\",\"desiredGeneration\":null}}",
            .{@tagName(outcome)},
        );
    }

    fn finishMcpHostMutation(
        self: *Dispatcher,
        workbench: *product_control.Runtime,
        output: []u8,
        outcome: McpHostOutcome,
    ) ![]const u8 {
        if (outcome == .saved or outcome == .saved_recovery_required)
            self.startMcpConfigurationApplyIfNeeded(workbench);
        if (outcome == .saved or outcome == .saved_recovery_required or
            outcome == .indeterminate)
            self.notifyCommitted();
        const inspection = workbench.inspectMcpDesiredConfiguration();
        const generation: ?u64 = if (outcome == .indeterminate)
            null
        else if (inspection) |value|
            if (value.health == .outcome_unknown)
                null
            else
                value.desired_generation orelse if (value.health == .ready) 0 else null
        else
            null;
        return encodeMcpTypedOutcome(output, @tagName(outcome), generation);
    }

    fn startMcpConfigurationApplyIfNeeded(
        self: *Dispatcher,
        workbench: *product_control.Runtime,
    ) void {
        const inspection = workbench.inspectMcpDesiredConfiguration() orelse return;
        if (inspection.health != .ready or
            inspection.runtime_alignment != .restart_required)
            return;
        const host = self.mcp_management_host orelse return;
        _ = host.apply_fn(host.context) catch return;
    }

    fn encodeMcpTypedOutcome(
        output: []u8,
        outcome: []const u8,
        generation: ?u64,
    ) ![]const u8 {
        if (generation) |value| return std.fmt.bufPrint(
            output,
            "{{\"outcome\":\"{s}\",\"desiredGeneration\":\"{d}\"}}",
            .{ outcome, value },
        );
        return std.fmt.bufPrint(
            output,
            "{{\"outcome\":\"{s}\",\"desiredGeneration\":null}}",
            .{outcome},
        );
    }

    fn mcpStaticAuthMode(
        value: []const u8,
        registration: ?handlers.McpOauthRegistration,
        slot_names: []const []const u8,
    ) !mcp_configuration.StaticAuthMode {
        if (registration != null) return error.InvalidBridgePayload;
        if (std.mem.eql(u8, value, "none")) {
            if (slot_names.len != 0) return error.InvalidBridgePayload;
            return .none;
        }
        if (std.mem.eql(u8, value, "static")) {
            if (slot_names.len == 0) return error.InvalidBridgePayload;
            return .static;
        }
        return error.InvalidBridgePayload;
    }

    fn mcpOauthClientPlan(
        registration: ?handlers.McpOauthRegistration,
    ) !mcp_configuration.OauthClientPlan {
        const value = registration orelse return error.InvalidBridgePayload;
        if (std.mem.eql(u8, value.kind, "automatic")) {
            if (value.clientId != null or value.tokenEndpointAuthMethod != null)
                return error.InvalidBridgePayload;
            return .dynamic_registration;
        }
        if (!std.mem.eql(u8, value.kind, "pre_registered"))
            return error.InvalidBridgePayload;
        const client_id = value.clientId orelse return error.InvalidBridgePayload;
        if (client_id.len == 0) return error.InvalidBridgePayload;
        const method = value.tokenEndpointAuthMethod orelse
            return error.InvalidBridgePayload;
        if (!std.mem.eql(u8, method, "none") and
            !std.mem.eql(u8, method, "client_secret_basic") and
            !std.mem.eql(u8, method, "client_secret_post"))
            return error.InvalidBridgePayload;
        return .{ .pre_registered = .{
            .client_id = client_id,
            .token_endpoint_auth_method = method,
        } };
    }

    fn validateMcpConnectionFields(
        negotiation: []const u8,
        timeout_ms: u32,
        arguments: []const []const u8,
        slot_names: []const []const u8,
    ) !void {
        if ((!std.mem.eql(u8, negotiation, "automatic") and
            !std.mem.eql(u8, negotiation, "modern_only") and
            !std.mem.eql(u8, negotiation, "compat_only")) or timeout_ms == 0 or
            arguments.len > 256 or slot_names.len > 256)
            return error.InvalidBridgePayload;
        for (arguments) |argument| if (argument.len > 4096 or
            !std.unicode.utf8ValidateSlice(argument)) return error.InvalidBridgePayload;
        for (slot_names, 0..) |name, index| {
            if (name.len == 0 or name.len > 256 or !std.unicode.utf8ValidateSlice(name))
                return error.InvalidBridgePayload;
            for (slot_names[0..index]) |previous|
                if (std.ascii.eqlIgnoreCase(previous, name)) return error.InvalidBridgePayload;
        }
    }

    fn validateMcpToolNames(names: []const []const u8) !void {
        if (names.len > 1024) return error.InvalidBridgePayload;
        for (names, 0..) |name, index| {
            if (name.len == 0 or name.len > 256 or !std.unicode.utf8ValidateSlice(name))
                return error.InvalidBridgePayload;
            for (name) |byte| if (byte < 0x20 or byte == 0x7f)
                return error.InvalidBridgePayload;
            for (names[0..index]) |previous|
                if (std.mem.eql(u8, previous, name)) return error.InvalidBridgePayload;
        }
    }

    fn refreshTaskSkillCatalog(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        var parsed = try handlers.parsePayload(
            handlers.TaskCatalogRefresh,
            invocation.request.payload,
        );
        defer parsed.deinit();
        const task_id = try handlers.parseWireId(parsed.value.taskId);
        const expected_binding_epoch = try handlers.parseWireId(
            parsed.value.expectedBindingEpoch,
        );
        (try self.requireProductControl()).refreshTaskCatalog(
            task_id,
            expected_binding_epoch,
        ) catch |err| {
            if (catalogRefreshRejection(err)) |reason|
                return encodeCatalogRefreshResult(
                    output,
                    false,
                    "taskId",
                    task_id,
                    reason,
                );
            return err;
        };
        self.notifyCommitted();
        return encodeCatalogRefreshResult(
            output,
            true,
            "taskId",
            task_id,
            null,
        );
    }

    fn stopTask(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        _ = self.delivery.connectedGeneration() orelse return error.NoConnection;
        var parsed = try handlers.parsePayload(handlers.TaskStop, invocation.request.payload);
        defer parsed.deinit();
        const task_id = try handlers.parseWireId(parsed.value.taskId);
        if (task_id == 0) return error.InvalidBridgePayload;
        try (try self.requireProductControl()).stopTask(task_id);
        self.notifyCommitted();
        return std.fmt.bufPrint(output, "{{\"taskId\":\"{d}\",\"stopRequested\":true}}", .{task_id});
    }

    fn cancelTask(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        var parsed = try handlers.parsePayload(handlers.TaskIdentity, invocation.request.payload);
        defer parsed.deinit();
        const task_id = try handlers.parseWireId(parsed.value.taskId);
        const run_id = try handlers.parseWireId(parsed.value.runId);
        try (try self.requireProductControl()).cancel(task_id, run_id);
        self.notifyCommitted();
        return std.fmt.bufPrint(
            output,
            "{{\"taskId\":\"{d}\",\"runId\":\"{d}\",\"cancelRequested\":true}}",
            .{ task_id, run_id },
        );
    }

    fn respondUi(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        var parsed = try handlers.parsePayloadWithLimit(
            handlers.UiResponseRequest,
            invocation.request.payload,
            256 * 1024,
        );
        defer parsed.deinit();
        const request = parsed.value;
        const task_id = try handlers.parseWireId(request.taskId);
        const run_id = try handlers.parseWireId(request.runId);
        const request_id = try handlers.parseWireId(request.requestId);
        const response = try decodeUiResponse(request);
        try (try self.requireProductControl()).respondUi(task_id, run_id, request_id, response);
        self.notifyCommitted();
        return std.fmt.bufPrint(
            output,
            "{{\"taskId\":\"{d}\",\"runId\":\"{d}\",\"requestId\":\"{d}\",\"answered\":true}}",
            .{ task_id, run_id, request_id },
        );
    }

    fn renameTask(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        var parsed = try handlers.parsePayload(handlers.TaskRename, invocation.request.payload);
        defer parsed.deinit();
        const task_id = try handlers.parseWireId(parsed.value.taskId);
        try (try self.requireProductControl()).renameTask(task_id, parsed.value.title);
        self.notifyCommitted();
        return std.fmt.bufPrint(output, "{{\"taskId\":\"{d}\",\"renamed\":true}}", .{task_id});
    }

    fn archiveTask(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        var parsed = try handlers.parsePayload(handlers.TaskArchive, invocation.request.payload);
        defer parsed.deinit();
        const task_id = try handlers.parseWireId(parsed.value.taskId);
        try (try self.requireProductControl()).setTaskArchived(task_id, parsed.value.archived);
        self.notifyCommitted();
        return std.fmt.bufPrint(
            output,
            "{{\"taskId\":\"{d}\",\"archived\":{}}}",
            .{ task_id, parsed.value.archived },
        );
    }

    fn markTaskCompletionSeen(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        var parsed = try handlers.parsePayload(handlers.TaskIdentity, invocation.request.payload);
        defer parsed.deinit();
        const task_id = try handlers.parseWireId(parsed.value.taskId);
        const run_id = try handlers.parseWireId(parsed.value.runId);
        if (task_id == 0 or run_id == 0) return error.InvalidBridgeId;
        const marked = (try self.requireProductControl()).markTaskCompletionSeen(task_id, run_id);
        if (marked) self.notifyCommitted();
        return std.fmt.bufPrint(
            output,
            "{{\"taskId\":\"{d}\",\"runId\":\"{d}\",\"marked\":{}}}",
            .{ task_id, run_id, marked },
        );
    }

    fn deleteTask(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        var parsed = try handlers.parsePayload(handlers.TaskDelete, invocation.request.payload);
        defer parsed.deinit();
        const task_id = try handlers.parseWireId(parsed.value.taskId);
        try (try self.requireProductControl()).deleteTask(task_id);
        self.notifyCommitted();
        return std.fmt.bufPrint(output, "{{\"taskId\":\"{d}\",\"deleting\":true}}", .{task_id});
    }

    fn recoverTaskHistory(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        var parsed = try handlers.parsePayload(
            handlers.PersistenceRecovery,
            invocation.request.payload,
        );
        defer parsed.deinit();
        const expected_revision = try handlers.parseWireId(
            parsed.value.expectedRevision,
        );
        const outcome = (try self.requireProductControl()).recoverTaskHistory(
            expected_revision,
        );
        self.notifyCommitted();
        return encodePersistenceRecoveryOutcome(output, outcome);
    }

    fn createScheduledTask(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        var parsed = try handlers.parsePayloadWithLimit(
            handlers.ScheduledTaskMutation,
            invocation.request.payload,
            128 * 1024,
        );
        defer parsed.deinit();
        const instruction = try handlers.parseScheduledTaskInstruction(
            parsed.value.input,
        );
        const definition = try scheduledTaskDefinition(
            parsed.value.title,
            parsed.value.binding,
            parsed.value.permissionProfile,
            instruction,
            parsed.value.recurrence,
        );
        const workbench = try self.requireProductControl();
        const scheduled_task_id = try workbench.createScheduledTask(definition);
        const epoch = try workbench.scheduledTaskEpoch(scheduled_task_id);
        self.notifyCommitted();
        return std.fmt.bufPrint(
            output,
            "{{\"scheduledTaskId\":\"{d}\",\"epoch\":\"{d}\",\"accepted\":true}}",
            .{ scheduled_task_id, epoch },
        );
    }

    fn updateScheduledTask(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        var parsed = try handlers.parsePayloadWithLimit(
            handlers.ScheduledTaskUpdate,
            invocation.request.payload,
            128 * 1024,
        );
        defer parsed.deinit();
        const instruction = try handlers.parseScheduledTaskInstruction(
            parsed.value.input,
        );
        const scheduled_task_id =
            try handlers.parseWireId(parsed.value.scheduledTaskId);
        const expected_epoch = try handlers.parseWireId(parsed.value.expectedEpoch);
        const definition = try scheduledTaskDefinition(
            parsed.value.title,
            parsed.value.binding,
            parsed.value.permissionProfile,
            instruction,
            parsed.value.recurrence,
        );
        const workbench = try self.requireProductControl();
        try workbench.updateScheduledTask(
            scheduled_task_id,
            expected_epoch,
            definition,
        );
        const epoch = try workbench.scheduledTaskEpoch(scheduled_task_id);
        self.notifyCommitted();
        return std.fmt.bufPrint(
            output,
            "{{\"scheduledTaskId\":\"{d}\",\"epoch\":\"{d}\",\"accepted\":true}}",
            .{ scheduled_task_id, epoch },
        );
    }

    fn setScheduledTaskEnabled(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        var parsed = try handlers.parsePayload(
            handlers.ScheduledTaskEnable,
            invocation.request.payload,
        );
        defer parsed.deinit();
        const id = try handlers.parseWireId(parsed.value.scheduledTaskId);
        const epoch = try handlers.parseWireId(parsed.value.expectedEpoch);
        const workbench = try self.requireProductControl();
        try workbench.setScheduledTaskEnabled(id, epoch, parsed.value.enabled);
        const next_epoch = try workbench.scheduledTaskEpoch(id);
        self.notifyCommitted();
        return std.fmt.bufPrint(
            output,
            "{{\"scheduledTaskId\":\"{d}\",\"epoch\":\"{d}\",\"enabled\":{}}}",
            .{ id, next_epoch, parsed.value.enabled },
        );
    }

    fn runScheduledTaskNow(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        var parsed = try handlers.parsePayload(
            handlers.ScheduledTaskIdentity,
            invocation.request.payload,
        );
        defer parsed.deinit();
        const id = try handlers.parseWireId(parsed.value.scheduledTaskId);
        const epoch = try handlers.parseWireId(parsed.value.expectedEpoch);
        const task_id = try (try self.requireProductControl()).runScheduledTaskNow(
            id,
            epoch,
        );
        self.notifyCommitted();
        return std.fmt.bufPrint(
            output,
            "{{\"scheduledTaskId\":\"{d}\",\"taskId\":\"{d}\",\"accepted\":true}}",
            .{ id, task_id },
        );
    }

    fn deleteScheduledTask(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        var parsed = try handlers.parsePayload(
            handlers.ScheduledTaskIdentity,
            invocation.request.payload,
        );
        defer parsed.deinit();
        const id = try handlers.parseWireId(parsed.value.scheduledTaskId);
        const epoch = try handlers.parseWireId(parsed.value.expectedEpoch);
        try (try self.requireProductControl()).deleteScheduledTask(id, epoch);
        self.notifyCommitted();
        return std.fmt.bufPrint(
            output,
            "{{\"scheduledTaskId\":\"{d}\",\"deleted\":true}}",
            .{id},
        );
    }

    fn recoverScheduledTaskStore(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        var parsed = try handlers.parsePayload(
            handlers.PersistenceRecovery,
            invocation.request.payload,
        );
        defer parsed.deinit();
        const expected_revision = try handlers.parseWireId(
            parsed.value.expectedRevision,
        );
        const outcome = (try self.requireProductControl()).recoverScheduledTaskStore(
            expected_revision,
        );
        self.notifyCommitted();
        return encodePersistenceRecoveryOutcome(output, outcome);
    }

    fn encodePersistenceRecoveryOutcome(
        output: []u8,
        outcome: product_control.PersistenceRecoveryOutcome,
    ) ![]const u8 {
        return std.fmt.bufPrint(
            output,
            "{{\"outcome\":\"{s}\"}}",
            .{@tagName(outcome)},
        );
    }

    fn requireWindow(self: *const Dispatcher, window_id: native_sdk.platform.WindowId) !void {
        _ = try self.delivery.requireWindow(window_id);
    }

    fn requireBootstrapWindow(
        self: *const Dispatcher,
        window_id: native_sdk.platform.WindowId,
    ) !void {
        if (window_id == 0 or window_id != self.bootstrap_window_id)
            return error.EventWindowMismatch;
    }

    fn requireManagementAuthority(
        self: *const Dispatcher,
        window_id: native_sdk.platform.WindowId,
    ) !void {
        try self.requireWindow(window_id);
        if (!self.platform.on_main_thread_fn(self.platform.context))
            return error.InvalidBridgeThread;
    }

    fn requireProductControl(self: *Dispatcher) !*product_control.Runtime {
        return self.control orelse error.RuntimeUnavailable;
    }

    fn notifyCommitted(self: *Dispatcher) void {
        self.platform.wake_fn(self.platform.context) catch |err|
            std.log.warn("committed Workbench mutation could not schedule a UI wake: {s}", .{
                @errorName(err),
            });
    }

    fn now(self: *const Dispatcher) u64 {
        return self.platform.now_fn(self.platform.context);
    }

    fn transport(self: *Dispatcher) product_delivery.Transport {
        return .{
            .context = self,
            .emit_fn = emitProductEvent,
            .start_timer_fn = startProductTimer,
            .cancel_timer_fn = cancelProductTimer,
        };
    }

    fn emitProductEvent(
        context: ?*anyopaque,
        window_id: native_sdk.platform.WindowId,
        name: []const u8,
        detail: []const u8,
    ) anyerror!void {
        const self: *Dispatcher = @ptrCast(@alignCast(context.?));
        return self.platform.emit_fn(self.platform.context, window_id, name, detail);
    }

    fn startProductTimer(
        context: ?*anyopaque,
        timer_id: u64,
        interval_ns: u64,
        repeats: bool,
    ) anyerror!void {
        const self: *Dispatcher = @ptrCast(@alignCast(context.?));
        return self.platform.start_timer_fn(
            self.platform.context,
            timer_id,
            interval_ns,
            repeats,
        );
    }

    fn cancelProductTimer(context: ?*anyopaque, timer_id: u64) anyerror!void {
        const self: *Dispatcher = @ptrCast(@alignCast(context.?));
        return self.platform.cancel_timer_fn(self.platform.context, timer_id);
    }

    const ViewWriteContext = struct {
        control: *product_control.Runtime,
        request: product_control.ViewRequest,
    };

    fn writeSnapshot(context: ?*anyopaque, output: []u8) anyerror!product_delivery.SnapshotStart {
        const view: *const ViewWriteContext = @ptrCast(@alignCast(context.?));
        const read = try view.control.writeSnapshot(output, view.request);
        return .{ .read_id = read.id, .bytes = read.bytes, .scratch_bytes = read.scratch_bytes };
    }
    fn continueSnapshot(context: ?*anyopaque, read_id: u64, output: []u8) anyerror!product_delivery.SnapshotStart {
        const control: *product_control.Runtime = @ptrCast(@alignCast(context.?));
        const read = try control.continueSnapshot(read_id, output);
        return .{ .read_id = read.id, .bytes = read.bytes, .scratch_bytes = read.scratch_bytes };
    }
    fn materializeSnapshot(context: ?*anyopaque, read_id: u64, output: []u8, offset: usize, length: usize) anyerror!void {
        const control: *product_control.Runtime = @ptrCast(@alignCast(context.?));
        try control.writeSnapshotRange(read_id, output, offset, length);
    }
};

fn encodeAccountResult(
    output: []u8,
    result: account_contract.AccountCommandResult,
) ![]const u8 {
    if (result.accepted != (result.error_code == .none) or
        (!result.accepted and result.attempt_id != null) or
        result.attempt_id == 0)
        return error.InvalidAccountCommandResult;
    var writer = std.Io.Writer.fixed(output);
    writer.print(
        "{{\"accepted\":{},\"errorCode\":\"{s}\",\"attemptId\":",
        .{ result.accepted, @tagName(result.error_code) },
    ) catch return error.NoSpaceLeft;
    if (result.attempt_id) |attempt_id|
        writer.print("\"{d}\"", .{attempt_id}) catch
            return error.NoSpaceLeft
    else
        writer.writeAll("null") catch return error.NoSpaceLeft;
    writer.writeByte('}') catch return error.NoSpaceLeft;
    return writer.buffered();
}

fn encodeExecutionResult(
    output: []u8,
    result: models_contract.CommandResult,
) ![]const u8 {
    const error_code: []const u8 = if (result.accepted)
        "none"
    else switch (result.error_code.?) {
        .authorization_unavailable => "authorization_unavailable",
        .catalog_unavailable => "catalog_unavailable",
        .invalid_provider => "custom_provider_invalid",
        .provider_not_found => "custom_provider_not_found",
        .generation_mismatch => "generation_mismatch",
        .model_not_found => "no_models",
        .capacity, .local_resource_exhausted => "local_resource_exhausted",
        .persistence_unavailable => "custom_provider_persistence_unavailable",
        .capture_unavailable => "custom_provider_capture_unavailable",
        .test_unavailable => "custom_model_test_unavailable",
        .credential_write_failed => "credential_store_write_failed",
        .operation_in_progress => "operation_in_progress",
        .user_cancelled => "user_cancelled",
    };
    var writer = std.Io.Writer.fixed(output);
    writer.print(
        "{{\"accepted\":{},\"errorCode\":\"{s}\",\"attemptId\":null}}",
        .{ result.accepted, error_code },
    ) catch return error.NoSpaceLeft;
    return writer.buffered();
}

fn taskCreateRejection(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.SessionReleasing => "session_releasing",
        error.SessionReleaseFailed => "session_close_failed",
        error.SessionCapacity => "session_capacity",
        error.ExecutionGenerationMismatch => "execution_changed",
        error.ExecutionUnavailable, error.ExecutionInUse => "execution_unavailable",
        error.WorkspaceEpochMismatch => "workspace_changed",
        error.UnknownWorkspace, error.WorkspaceUnavailable, error.WorkspaceIdentityUntrusted => "workspace_unavailable",
        error.WorkspaceRemovalInProgress => "workspace_removing",
        error.CatalogLoading => "catalog_loading",
        error.CatalogUnavailable => "catalog_unavailable",
        error.ModelSelectionChanged => "model_selection_changed",
        error.StaleCatalog => "stale_catalog",
        error.TaskCapacity, error.ProjectionCapacity => "capacity_reached",
        error.TaskBusy => "execution_unavailable",
        error.ExecutorShuttingDown => "shutting_down",
        else => null,
    };
}

fn taskRunRejection(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.BindingEpochMismatch => "binding_changed",
        error.ExecutionUnavailable, error.ExecutionGenerationMismatch => "binding_unavailable",
        error.UnknownTask, error.TaskClosing => "task_unavailable",
        error.TaskBusy => "task_busy",
        error.UnknownWorkspace, error.WorkspaceUnavailable, error.WorkspaceIdentityUntrusted => "workspace_unavailable",
        error.WorkspaceEpochMismatch => "workspace_changed",
        error.WorkspaceRemovalInProgress => "workspace_removing",
        error.CatalogLoading => "catalog_loading",
        error.CatalogUnavailable => "catalog_unavailable",
        error.StaleCatalog => "stale_catalog",
        error.SkillNotFound => "skill_not_found",
        error.SkillUnavailable => "skill_unavailable",
        error.InvalidSkillArguments => "invalid_skill_arguments",
        error.MissingInstruction => "missing_instruction",
        error.UnsupportedType => "unsupported_attachment",
        error.RunCapacity, error.QueueFull, error.ProjectionCapacity => "capacity_reached",
        error.ExecutorShuttingDown => "shutting_down",
        else => null,
    };
}

fn taskApprovalModeRejection(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.UnknownTask => "task_not_found",
        error.BindingEpochMismatch => "stale_binding",
        error.ApprovalRevisionMismatch => "stale_revision",
        error.TaskBusy => "busy",
        error.TaskClosing => "task_closed",
        error.UnsupportedPermissionProfile => "unsupported_interaction",
        error.ApprovalUnavailable => "unavailable",
        error.ApprovalRevisionExhausted => "revision_exhausted",
        error.ReviewGenerationExhausted => "review_exhausted",
        error.ExecutorShuttingDown => "shutting_down",
        else => null,
    };
}

fn taskModelSelectionRejection(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.TaskPersistenceUnavailable => "persistence_unavailable",
        error.TaskPersistenceFailed => "persistence_failed",
        error.TaskPersistenceOutcomeUnknown => "persistence_outcome_unknown",
        error.InvalidTaskModel => "stale_catalog",
        error.TaskModelMismatch => "model_changed",
        error.StaleCatalog => "stale_catalog",
        error.UnknownTask, error.TaskClosing => "task_unavailable",
        error.TaskBusy, error.SessionNotIdle => "task_busy",
        error.ExecutorShuttingDown => "shutting_down",
        error.ProjectionCapacity, error.OutOfMemory => "capacity_reached",
        else => null,
    };
}

fn taskCompactRejection(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.BindingEpochMismatch => "binding_changed",
        error.ExecutionUnavailable, error.ExecutionGenerationMismatch => "binding_unavailable",
        error.UnknownTask, error.TaskClosing => "task_unavailable",
        error.TaskBusy => "task_busy",
        error.NoSuchRun => "no_history",
        error.CompactCapacity,
        error.CompactIdExhausted,
        error.QueueFull,
        error.ProjectionCapacity,
        => "capacity_reached",
        error.ExecutorShuttingDown => "shutting_down",
        else => null,
    };
}

fn taskRestoreRejection(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.SessionReleasing => "session_releasing",
        error.SessionReleaseFailed => "session_close_failed",
        error.SessionCapacity => "session_capacity",
        error.BindingEpochMismatch => "binding_changed",
        error.UnknownTask => "task_unavailable",
        error.RecoveryUnavailable, error.TaskBusy => "recovery_unavailable",
        error.RestoreAttemptExhausted,
        error.QueueFull,
        error.ProjectionCapacity,
        error.OutOfMemory,
        => "capacity_reached",
        error.ExecutorShuttingDown => "shutting_down",
        else => null,
    };
}

fn catalogRefreshRejection(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.WorkspaceEpochMismatch => "workspace_changed",
        error.BindingEpochMismatch => "binding_changed",
        error.UnknownWorkspace, error.WorkspaceUnavailable, error.WorkspaceIdentityUntrusted => "workspace_unavailable",
        error.UnknownTask, error.TaskClosing => "task_unavailable",
        error.WorkspaceRemovalInProgress => "workspace_removing",
        error.TaskBusy => "task_busy",
        error.CatalogLoading => "catalog_loading",
        error.CatalogUnavailable => "catalog_unavailable",
        error.CatalogRequestGenerationExhausted,
        error.ProjectionCapacity,
        error.QueueFull,
        => "capacity_reached",
        error.ExecutorShuttingDown => "shutting_down",
        else => null,
    };
}

fn parseSkillScope(
    kind: []const u8,
    workspace_id: ?[]const u8,
    workspace_epoch: ?[]const u8,
) !skill_management.Scope {
    if (std.mem.eql(u8, kind, "personal")) {
        if (workspace_id != null or workspace_epoch != null)
            return error.InvalidBridgePayload;
        return .personal;
    }
    if (!std.mem.eql(u8, kind, "project") or
        workspace_id == null or workspace_epoch == null)
        return error.InvalidBridgePayload;
    return .{ .project = .{
        .workspace_id = try handlers.parseWireId(workspace_id.?),
        .workspace_epoch = try handlers.parseWireId(workspace_epoch.?),
    } };
}

fn parseSkillInstallId(value: []const u8) !skill_management.InstallId {
    if (value.len != @sizeOf(skill_management.InstallId) * 2)
        return error.InvalidBridgePayload;
    var result: skill_management.InstallId = undefined;
    _ = std.fmt.hexToBytes(&result, value) catch
        return error.InvalidBridgePayload;
    return result;
}

fn skillMutationRejection(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.InvalidAsset,
        error.InvalidDefinition,
        error.SkillDefinitionMissing,
        error.SourceUnavailable,
        error.ArchiveCorrupt,
        error.InvalidSkillId,
        => "source_changed",
        error.AssetNotFound, error.SkillNotFound => "asset_unavailable",
        error.TransactionAlreadyActive,
        error.TransactionMissing,
        error.InvalidTransaction,
        error.RevisionMismatch,
        error.StaleCatalog,
        => "state_changed",
        error.TargetAlreadyExists, error.DuplicateTarget => "target_exists",
        error.TaskBusy => "busy",
        error.CatalogLoading => "catalog_loading",
        error.WorkspaceEpochMismatch => "workspace_changed",
        error.UnknownWorkspace, error.WorkspaceUnavailable, error.WorkspaceIdentityUntrusted => "workspace_unavailable",
        error.ProjectionCapacity,
        error.QueueFull,
        error.WorkspaceCapacity,
        error.SkillCapacity,
        error.RevisionExhausted,
        error.StoreTooLarge,
        error.StoreEncodeFailed,
        => "capacity_reached",
        error.ExecutorShuttingDown => "shutting_down",
        error.PersistenceFailed,
        error.PersistenceOutcomeUnknown,
        error.WriteFailed,
        error.FileTransactionFailed,
        error.CandidateUnavailable,
        error.TargetUnavailable,
        error.RootUnavailable,
        error.RecoveryUnavailable,
        => "local_storage_failed",
        else => null,
    };
}

fn skillMutationMayHaveCommitted(err: anyerror) bool {
    return switch (err) {
        error.PersistenceFailed,
        error.PersistenceOutcomeUnknown,
        error.FileTransactionFailed,
        error.CandidateUnavailable,
        error.TargetUnavailable,
        => true,
        else => false,
    };
}

fn validSessionBlocker(accepted: bool, reason: ?[]const u8, task_id: ?u64) bool {
    const failed = if (reason) |value| std.mem.eql(u8, value, "session_close_failed") else false;
    return if (failed) !accepted and task_id != null and task_id.? != 0 else task_id == null;
}

fn encodeTaskCreateResult(
    output: []u8,
    accepted: bool,
    task_id: ?u64,
    binding_epoch: ?u64,
    mcp_authority: ?product_control.TaskMcpAuthorityAtCreation,
    reason: ?[]const u8,
    blocking_task_id: ?u64,
) ![]const u8 {
    const valid = if (accepted)
        task_id != null and task_id.? != 0 and
            binding_epoch != null and binding_epoch.? != 0 and
            mcp_authority != null and reason == null
    else
        task_id == null and binding_epoch == null and
            mcp_authority == null and reason != null;
    if (!valid)
        return error.InvalidTaskCreateResult;
    if (!validSessionBlocker(accepted, reason, blocking_task_id)) return error.InvalidSessionPressureResult;
    var writer = std.Io.Writer.fixed(output);
    writer.print("{{\"accepted\":{},\"taskId\":", .{accepted}) catch
        return error.NoSpaceLeft;
    if (task_id) |value|
        writer.print("\"{d}\"", .{value}) catch return error.NoSpaceLeft
    else
        writer.writeAll("null") catch return error.NoSpaceLeft;
    writer.writeAll(",\"bindingEpoch\":") catch return error.NoSpaceLeft;
    if (binding_epoch) |value|
        writer.print("\"{d}\"", .{value}) catch return error.NoSpaceLeft
    else
        writer.writeAll("null") catch return error.NoSpaceLeft;
    writer.writeAll(",\"mcpAuthority\":") catch return error.NoSpaceLeft;
    if (mcp_authority) |authority| switch (authority) {
        .ready_with_selection => writer.writeAll(
            "{\"kind\":\"ready\",\"selection\":\"selected\"}",
        ) catch return error.NoSpaceLeft,
        .ready_without_selection => writer.writeAll(
            "{\"kind\":\"ready\",\"selection\":\"none\"}",
        ) catch return error.NoSpaceLeft,
        .unavailable => writer.writeAll(
            "{\"kind\":\"unavailable\",\"selection\":null}",
        ) catch return error.NoSpaceLeft,
    } else writer.writeAll("null") catch return error.NoSpaceLeft;
    writer.writeAll(",\"reason\":") catch return error.NoSpaceLeft;
    if (reason) |value|
        std.json.Stringify.value(value, .{}, &writer) catch return error.NoSpaceLeft
    else
        writer.writeAll("null") catch return error.NoSpaceLeft;
    if (blocking_task_id) |id| writer.print(",\"blockingTaskId\":\"{d}\"", .{id}) catch return error.NoSpaceLeft;
    writer.writeByte('}') catch return error.NoSpaceLeft;
    return writer.buffered();
}

fn scheduledTaskDefinition(
    title: []const u8,
    binding: handlers.ScheduledTaskBinding,
    permission_profile_wire: []const u8,
    instruction: []const u8,
    recurrence_value: std.json.Value,
) !product_control.ScheduledTaskDefinitionInput {
    return .{
        .title = title,
        .binding = .{
            .model_ref = .{
                .source_id = binding.modelRef.sourceId,
                .model_id = binding.modelRef.modelId,
            },
            .source_generation = try handlers.parseWireId(binding.sourceGeneration),
            .selection_revision = try handlers.parseWireId(binding.selectionRevision),
            .protocol = std.meta.stringToEnum(
                models_contract.Protocol,
                binding.protocol,
            ) orelse
                return error.InvalidBridgePayload,
        },
        .permission_profile = handlers.permissionProfile(permission_profile_wire) orelse
            return error.InvalidBridgePayload,
        .input = instruction,
        .recurrence = try handlers.parseScheduledTaskRecurrence(recurrence_value),
    };
}

fn encodeSendInputResult(output: []u8, control: *const product_control.Runtime, result: product_control.SendInputResult) ![]const u8 {
    var writer = std.Io.Writer.fixed(output);
    try control.writeSendInputResult(&writer, result);
    return writer.buffered();
}

fn encodeTaskRunResult(
    output: []u8,
    accepted: bool,
    task_id: u64,
    run_id: ?u64,
    reason: ?[]const u8,
) ![]const u8 {
    const valid = task_id != 0 and if (accepted)
        run_id != null and run_id.? != 0 and reason == null
    else
        run_id == null and reason != null;
    if (!valid)
        return error.InvalidTaskRunResult;
    var writer = std.Io.Writer.fixed(output);
    writer.print("{{\"accepted\":{},\"taskId\":\"{d}\",\"runId\":", .{
        accepted,
        task_id,
    }) catch return error.NoSpaceLeft;
    if (run_id) |value|
        writer.print("\"{d}\"", .{value}) catch return error.NoSpaceLeft
    else
        writer.writeAll("null") catch return error.NoSpaceLeft;
    writer.writeAll(",\"reason\":") catch return error.NoSpaceLeft;
    if (reason) |value|
        std.json.Stringify.value(value, .{}, &writer) catch return error.NoSpaceLeft
    else
        writer.writeAll("null") catch return error.NoSpaceLeft;
    writer.writeByte('}') catch return error.NoSpaceLeft;
    return writer.buffered();
}

fn encodeTaskApprovalModeResult(output: []u8, task_id: u64, revision: ?u64, reason: ?[]const u8) ![]const u8 {
    if (task_id == 0 or (revision != null) == (reason != null) or (revision != null and revision.? == 0))
        return error.InvalidTaskApprovalModeResult;
    var writer = std.Io.Writer.fixed(output);
    writer.print("{{\"accepted\":{},\"taskId\":\"{d}\",\"approvalRevision\":", .{ revision != null, task_id }) catch return error.NoSpaceLeft;
    if (revision) |value| writer.print("\"{d}\"", .{value}) catch return error.NoSpaceLeft else writer.writeAll("null") catch return error.NoSpaceLeft;
    writer.writeAll(",\"reason\":") catch return error.NoSpaceLeft;
    if (reason) |value| std.json.Stringify.value(value, .{}, &writer) catch return error.NoSpaceLeft else writer.writeAll("null") catch return error.NoSpaceLeft;
    writer.writeByte('}') catch return error.NoSpaceLeft;
    return writer.buffered();
}

fn encodeTaskModelSelectionResult(
    output: []u8,
    accepted: bool,
    task_id: u64,
    revision: ?u64,
    reason: ?[]const u8,
) ![]const u8 {
    const valid = task_id != 0 and if (accepted)
        revision != null and revision.? != 0 and reason == null
    else
        revision == null and reason != null;
    if (!valid) return error.InvalidTaskModelSelectionResult;
    var writer = std.Io.Writer.fixed(output);
    writer.print("{{\"accepted\":{},\"taskId\":\"{d}\",\"selectionRevision\":", .{
        accepted,
        task_id,
    }) catch return error.NoSpaceLeft;
    if (revision) |value|
        writer.print("\"{d}\"", .{value}) catch return error.NoSpaceLeft
    else
        writer.writeAll("null") catch return error.NoSpaceLeft;
    writer.writeAll(",\"reason\":") catch return error.NoSpaceLeft;
    if (reason) |value|
        std.json.Stringify.value(value, .{}, &writer) catch return error.NoSpaceLeft
    else
        writer.writeAll("null") catch return error.NoSpaceLeft;
    writer.writeByte('}') catch return error.NoSpaceLeft;
    return writer.buffered();
}

fn encodeTaskCompactResult(
    output: []u8,
    accepted: bool,
    task_id: u64,
    operation_id: ?u64,
    reason: ?[]const u8,
) ![]const u8 {
    const valid = task_id != 0 and if (accepted)
        operation_id != null and operation_id.? != 0 and reason == null
    else
        operation_id == null and reason != null;
    if (!valid) return error.InvalidTaskCompactResult;
    var writer = std.Io.Writer.fixed(output);
    writer.print("{{\"accepted\":{},\"taskId\":\"{d}\",\"operationId\":", .{
        accepted,
        task_id,
    }) catch return error.NoSpaceLeft;
    if (operation_id) |value|
        writer.print("\"{d}\"", .{value}) catch return error.NoSpaceLeft
    else
        writer.writeAll("null") catch return error.NoSpaceLeft;
    writer.writeAll(",\"reason\":") catch return error.NoSpaceLeft;
    if (reason) |value|
        std.json.Stringify.value(value, .{}, &writer) catch return error.NoSpaceLeft
    else
        writer.writeAll("null") catch return error.NoSpaceLeft;
    writer.writeByte('}') catch return error.NoSpaceLeft;
    return writer.buffered();
}

fn encodeTaskRestoreResult(
    output: []u8,
    accepted: bool,
    task_id: u64,
    attempt_id: ?u64,
    reason: ?[]const u8,
    blocking_task_id: ?u64,
) ![]const u8 {
    const valid = task_id != 0 and if (accepted)
        attempt_id != null and attempt_id.? != 0 and reason == null
    else
        attempt_id == null and reason != null;
    if (!valid) return error.InvalidTaskRestoreResult;
    if (!validSessionBlocker(accepted, reason, blocking_task_id)) return error.InvalidSessionPressureResult;
    var writer = std.Io.Writer.fixed(output);
    writer.print("{{\"accepted\":{},\"taskId\":\"{d}\",\"attemptId\":", .{
        accepted,
        task_id,
    }) catch return error.NoSpaceLeft;
    if (attempt_id) |value|
        writer.print("\"{d}\"", .{value}) catch return error.NoSpaceLeft
    else
        writer.writeAll("null") catch return error.NoSpaceLeft;
    writer.writeAll(",\"reason\":") catch return error.NoSpaceLeft;
    if (reason) |value|
        std.json.Stringify.value(value, .{}, &writer) catch return error.NoSpaceLeft
    else
        writer.writeAll("null") catch return error.NoSpaceLeft;
    if (blocking_task_id) |id| writer.print(",\"blockingTaskId\":\"{d}\"", .{id}) catch return error.NoSpaceLeft;
    writer.writeByte('}') catch return error.NoSpaceLeft;
    return writer.buffered();
}

fn encodeCatalogRefreshResult(
    output: []u8,
    accepted: bool,
    identity_name: []const u8,
    identity: u64,
    reason: ?[]const u8,
) ![]const u8 {
    if (identity == 0 or accepted != (reason == null))
        return error.InvalidCatalogRefreshResult;
    var writer = std.Io.Writer.fixed(output);
    writer.print("{{\"accepted\":{},\"{s}\":\"{d}\",\"reason\":", .{
        accepted,
        identity_name,
        identity,
    }) catch return error.NoSpaceLeft;
    if (reason) |value|
        std.json.Stringify.value(value, .{}, &writer) catch
            return error.NoSpaceLeft
    else
        writer.writeAll("null") catch return error.NoSpaceLeft;
    writer.writeByte('}') catch return error.NoSpaceLeft;
    return writer.buffered();
}

fn encodeSkillCatalogRefreshResult(
    output: []u8,
    accepted: bool,
    reason: ?[]const u8,
) ![]const u8 {
    if (accepted != (reason == null))
        return error.InvalidCatalogRefreshResult;
    var writer = std.Io.Writer.fixed(output);
    writer.print("{{\"accepted\":{},\"reason\":", .{accepted}) catch
        return error.NoSpaceLeft;
    if (reason) |value|
        std.json.Stringify.value(value, .{}, &writer) catch
            return error.NoSpaceLeft
    else
        writer.writeAll("null") catch return error.NoSpaceLeft;
    writer.writeByte('}') catch return error.NoSpaceLeft;
    return writer.buffered();
}

fn encodeSkillMutationResult(
    output: []u8,
    accepted: bool,
    install_id: ?skill_management.InstallId,
    verification_pending: bool,
    reason: ?[]const u8,
) ![]const u8 {
    const valid = if (accepted)
        install_id != null and reason == null
    else
        install_id == null and !verification_pending and reason != null;
    if (!valid) return error.InvalidSkillMutationResult;
    var writer = std.Io.Writer.fixed(output);
    writer.print("{{\"accepted\":{},\"installId\":", .{accepted}) catch
        return error.NoSpaceLeft;
    if (install_id) |value| {
        const hex = std.fmt.bytesToHex(value, .lower);
        writer.print("\"{s}\"", .{&hex}) catch return error.NoSpaceLeft;
    } else writer.writeAll("null") catch return error.NoSpaceLeft;
    writer.print(",\"verificationPending\":{},\"reason\":", .{verification_pending}) catch
        return error.NoSpaceLeft;
    if (reason) |value|
        std.json.Stringify.value(value, .{}, &writer) catch return error.NoSpaceLeft
    else
        writer.writeAll("null") catch return error.NoSpaceLeft;
    writer.writeByte('}') catch return error.NoSpaceLeft;
    return writer.buffered();
}

fn encodeSkillExportResult(
    output: []u8,
    exported: bool,
    file_name: ?[]const u8,
    reason: ?[]const u8,
) ![]const u8 {
    if (exported != (file_name != null and reason == null))
        return error.InvalidSkillExportResult;
    var writer = std.Io.Writer.fixed(output);
    writer.print("{{\"exported\":{},\"fileName\":", .{exported}) catch
        return error.NoSpaceLeft;
    if (file_name) |value|
        std.json.Stringify.value(value, .{}, &writer) catch return error.NoSpaceLeft
    else
        writer.writeAll("null") catch return error.NoSpaceLeft;
    writer.writeAll(",\"reason\":") catch return error.NoSpaceLeft;
    if (reason) |value|
        std.json.Stringify.value(value, .{}, &writer) catch return error.NoSpaceLeft
    else
        writer.writeAll("null") catch return error.NoSpaceLeft;
    writer.writeByte('}') catch return error.NoSpaceLeft;
    return writer.buffered();
}

fn encodeSkillDetailUnavailable(output: []u8, reason: []const u8) ![]const u8 {
    if (reason.len == 0) return error.InvalidSkillDetailResult;
    var writer = std.Io.Writer.fixed(output);
    writer.writeAll("{\"available\":false,\"definition\":null,\"fileCount\":0,\"totalBytes\":0,\"reason\":") catch
        return error.NoSpaceLeft;
    std.json.Stringify.value(reason, .{}, &writer) catch return error.NoSpaceLeft;
    writer.writeByte('}') catch return error.NoSpaceLeft;
    return writer.buffered();
}

fn decodeUiResponse(request: handlers.UiResponseRequest) !product_control.UiResponse {
    if (std.mem.eql(u8, request.kind, "permission")) {
        if (request.permission == null) return error.InvalidUiResponse;
        const choice = handlers.permissionChoice(request.permission.?) orelse
            return error.InvalidUiResponse;
        return .{ .permission = switch (choice) {
            .allow_once => .allow_once,
            .allow_session => .allow_session,
            .deny_once => .deny_once,
            .deny_session => .deny_session,
        } };
    }
    return error.InvalidUiResponse;
}

test "MCP Bridge keeps OAuth client authentication explicit and bounded" {
    try std.testing.expectError(
        error.InvalidBridgePayload,
        Dispatcher.mcpOauthClientPlan(.{
            .kind = "automatic",
            .clientId = "renderer-must-not-supply-this",
        }),
    );
    try std.testing.expectError(
        error.InvalidBridgePayload,
        Dispatcher.mcpOauthClientPlan(.{
            .kind = "pre_registered",
            .clientId = "client-1",
        }),
    );
    try std.testing.expectError(
        error.InvalidBridgePayload,
        Dispatcher.mcpOauthClientPlan(.{
            .kind = "pre_registered",
            .clientId = "client-1",
            .tokenEndpointAuthMethod = "guess",
        }),
    );
    const basic = try Dispatcher.mcpOauthClientPlan(.{
        .kind = "pre_registered",
        .clientId = "client-1",
        .tokenEndpointAuthMethod = "client_secret_basic",
    });
    switch (basic) {
        .pre_registered => |client| {
            try std.testing.expectEqualStrings("client-1", client.client_id);
            try std.testing.expectEqualStrings(
                "client_secret_basic",
                client.token_endpoint_auth_method,
            );
        },
        .dynamic_registration => return error.TestUnexpectedResult,
    }
    try std.testing.expectError(
        error.InvalidBridgePayload,
        Dispatcher.validateMcpConnectionFields(
            "automatic",
            30_000,
            &.{},
            &.{ "Authorization", "authorization" },
        ),
    );
}

test "permission command ingress accepts AgentCore Session choices" {
    const allow_once = try decodeUiResponse(.{
        .taskId = "1",
        .runId = "2",
        .requestId = "3",
        .kind = "permission",
        .permission = "allow_once",
    });
    try std.testing.expectEqual(
        product_control.PermissionChoice.allow_once,
        allow_once.permission,
    );

    const allow_session = try decodeUiResponse(.{
        .taskId = "1",
        .runId = "2",
        .requestId = "3",
        .kind = "permission",
        .permission = "allow_session",
    });
    try std.testing.expectEqual(
        product_control.PermissionChoice.allow_session,
        allow_session.permission,
    );

    const deny_once = try decodeUiResponse(.{
        .taskId = "1",
        .runId = "2",
        .requestId = "3",
        .kind = "permission",
        .permission = "deny_once",
    });
    try std.testing.expectEqual(
        product_control.PermissionChoice.deny_once,
        deny_once.permission,
    );

    const deny_session = try decodeUiResponse(.{
        .taskId = "1",
        .runId = "2",
        .requestId = "3",
        .kind = "permission",
        .permission = "deny_session",
    });
    try std.testing.expectEqual(
        product_control.PermissionChoice.deny_session,
        deny_session.permission,
    );

    for ([_][]const u8{
        "full_access",
    }) |permission| {
        try std.testing.expectError(error.InvalidUiResponse, decodeUiResponse(.{
            .taskId = "1",
            .runId = "2",
            .requestId = "3",
            .kind = "permission",
            .permission = permission,
        }));
    }
}

test "file preview native grants bind authority and cancellation and expire without trapping capacity" {
    const Host = struct {
        fn wake(_: ?*anyopaque) !void {}
        fn emit(_: ?*anyopaque, _: u64, _: []const u8, _: []const u8) !void {}
        fn timer(_: ?*anyopaque, _: u64, _: u64, _: bool) !void {}
        fn cancel(_: ?*anyopaque, _: u64) !void {}
        fn main(_: ?*anyopaque) bool {
            return true;
        }
        fn now(_: ?*anyopaque) u64 {
            return 1;
        }
        fn random(_: ?*anyopaque, bytes: []u8) bool {
            @memset(bytes, 7);
            return true;
        }
    };
    const Capture = struct {
        response: ?[]u8 = null,
        calls: usize = 0,
        control: *product_control.Runtime,
        released_check: bool = false,
        fn receive(context: *anyopaque, _: native_sdk.bridge.Source, bytes: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.released_check and std.mem.indexOf(u8, bytes, "\"released\":true") != null)
                try std.testing.expect(!self.control.hasFilePreviews());
            if (self.response) |old| std.testing.allocator.free(old);
            self.response = try std.testing.allocator.dupe(u8, bytes);
            self.calls += 1;
        }
        fn deinit(self: *@This()) void {
            if (self.response) |bytes| std.testing.allocator.free(bytes);
        }
        fn invoke(self: *@This(), native: native_sdk.bridge.Dispatcher, command: []const u8, payload: []const u8) !void {
            const handler = native.async_registry.find(command).?;
            const source: native_sdk.bridge.Source = .{ .origin = "zero://app", .window_id = 3 };
            try handler.invoke_fn(handler.context, .{ .request = .{ .id = "preview-test", .command = command, .payload = payload }, .source = source }, .{ .context = self, .source = source, .respond_fn = receive });
        }
        fn wait(self: *@This(), boundary: *Dispatcher, count: usize) !void {
            for (0..5000) |_| {
                self.control.drainFilePreviewCompletions(boundary.filePreviewSink());
                if (self.calls >= count) return;
                try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
            }
            return error.PreviewDidNotComplete;
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const bytes = try std.testing.allocator.alloc(u8, product_control.file_preview_chunk_bytes + 17);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 'a');
    const jpeg = "\xff\xd8\xff\xc0\x00\x0b\x08\x00\x02\x00\x03\x01\x01\x11\x00" ++ "\xff\xda\x00\x08\x01\x01\x00\x00\x3f\x00\x01\xff\xd9";
    @memcpy(bytes[0..jpeg.len], jpeg);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "image.jpg", .data = bytes });
    var control = try product_control.TestSupport.filePreviewFixture(root);
    defer control.deinit();
    var boundary = try Dispatcher.init(std.testing.allocator, &control, undefined, undefined, .{
        .context = null,
        .wake_fn = Host.wake,
        .emit_fn = Host.emit,
        .start_timer_fn = Host.timer,
        .cancel_timer_fn = Host.cancel,
        .random_fn = Host.random,
        .now_fn = Host.now,
        .on_main_thread_fn = Host.main,
        .show_open_dialog_fn = undefined,
        .canonicalize_directory_fn = undefined,
        .window_chrome_connect_fn = undefined,
        .window_chrome_refresh_fn = undefined,
        .window_chrome_control_fn = undefined,
    }, .{}, 3);
    defer boundary.deinit();
    _ = try boundary.delivery.connect(3, boundary.transport());
    const native = boundary.register(@import("policy.zig").product(.release));
    var opened: Capture = .{ .control = &control };
    defer opened.deinit();
    var released: Capture = .{ .control = &control, .released_check = true };
    defer released.deinit();
    try released.invoke(native, commands.release_preview, "{\"generation\":\"1\",\"previewId\":\"1\"}");
    try opened.invoke(native, commands.preview_file, "{\"generation\":\"1\",\"previewId\":\"1\",\"taskId\":\"3\",\"runId\":\"7\",\"fileReferenceId\":\"file-3-1-1-1\"}");
    try std.testing.expect(std.mem.indexOf(u8, opened.response.?, "\"state\":\"error\"") != null);
    try std.testing.expect(!control.hasFilePreviews());
    try opened.invoke(native, commands.preview_file, "{\"generation\":\"1\",\"previewId\":\"2\",\"taskId\":\"3\",\"runId\":\"7\",\"fileReferenceId\":\"file-3-1-1-1\"}");
    try opened.wait(&boundary, 2);
    var descriptor = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, opened.response.?, .{});
    defer descriptor.deinit();
    const image = descriptor.value.object.get("result").?.object.get("image").?.object;
    const payload = try std.fmt.allocPrint(std.testing.allocator, "{{\"generation\":\"1\",\"previewId\":\"2\",\"token\":\"{s}\",\"offset\":\"0\",\"securityEpoch\":\"{s}\"}}", .{ image.get("token").?.string, image.get("securityEpoch").?.string });
    defer std.testing.allocator.free(payload);
    const output = try std.testing.allocator.alloc(u8, native_sdk.bridge.max_result_bytes);
    defer std.testing.allocator.free(output);
    const reader = native.registry.find(commands.read_preview_image).?;
    if (reader.invoke_fn(reader.context, .{ .request = .{ .id = "read", .command = commands.read_preview_image, .payload = payload }, .source = .{ .origin = "zero://app", .window_id = 4 } }, output)) |_| return error.ForeignWindowReadAllowed else |_| {}
    const result = try reader.invoke_fn(reader.context, .{ .request = .{ .id = "read", .command = commands.read_preview_image, .payload = payload }, .source = .{ .origin = "zero://app", .window_id = 3 } }, output);
    var chunk = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer chunk.deinit();
    const encoded = chunk.value.object.get("dataBase64").?.string;
    const decoded = try std.testing.allocator.alloc(u8, product_control.file_preview_chunk_bytes);
    defer std.testing.allocator.free(decoded);
    try std.base64.standard.Decoder.decode(decoded, encoded);
    try std.testing.expectEqualSlices(u8, bytes[0..decoded.len], decoded);
    try std.testing.expect(result.len < native_sdk.bridge.max_result_bytes);
    product_control.TestSupport.invalidatePreviewSecurity(&control);
    const stale = try reader.invoke_fn(reader.context, .{ .request = .{ .id = "read", .command = commands.read_preview_image, .payload = payload }, .source = .{ .origin = "zero://app", .window_id = 3 } }, output);
    try std.testing.expectEqualStrings("{\"state\":\"stale_security\"}", stale);
    try released.invoke(native, commands.release_preview, "{\"generation\":\"1\",\"previewId\":\"2\"}");
    try std.testing.expect(!control.hasFilePreviews());
    try opened.invoke(native, commands.preview_file, "{\"generation\":\"1\",\"previewId\":\"3\",\"taskId\":\"3\",\"runId\":\"7\",\"fileReferenceId\":\"file-3-1-1-1\"}");
    try released.invoke(native, commands.release_preview, "{\"generation\":\"1\",\"previewId\":\"3\"}");
    try opened.wait(&boundary, 3);
    try std.testing.expectEqual(@as(usize, 3), released.calls);
    try std.testing.expect(!control.hasFilePreviews());
    try opened.invoke(native, commands.preview_file, "{\"generation\":\"1\",\"previewId\":\"4\",\"taskId\":\"3\",\"runId\":\"7\",\"fileReferenceId\":\"file-3-1-1-1\"}");
    try opened.wait(&boundary, 4);
    product_control.TestSupport.expirePreview(&control, boundary.preview_grants[0].?.image.id);
    try std.testing.expect(boundary.onTimer(preview_timer_id));
    try std.testing.expect(!control.hasFilePreviews());
    for (boundary.preview_grants) |entry| try std.testing.expect(entry == null);
    try opened.invoke(native, commands.preview_file, "{\"generation\":\"1\",\"previewId\":\"5\",\"taskId\":\"3\",\"runId\":\"7\",\"fileReferenceId\":\"file-3-1-1-1\"}");
    try opened.wait(&boundary, 5);
    try std.testing.expect(std.mem.indexOf(u8, opened.response.?, "\"image\"") != null);
    boundary.breakConnection();
    try std.testing.expect(!control.hasFilePreviews());
    _ = try boundary.delivery.connect(3, boundary.transport());
    try opened.invoke(native, commands.preview_file, "{\"generation\":\"2\",\"previewId\":\"6\",\"taskId\":\"3\",\"runId\":\"7\",\"fileReferenceId\":\"file-3-1-1-1\"}");
    try opened.wait(&boundary, 6);
    try opened.invoke(native, commands.preview_file, "{\"generation\":\"2\",\"previewId\":\"7\",\"taskId\":\"3\",\"runId\":\"7\",\"fileReferenceId\":\"file-3-1-1-1\"}");
    control.beginShutdown();
    boundary.stopIngress();
    control.shutdownFilePreviewExecutor();
    control.drainFilePreviewCompletions(boundary.filePreviewSink());
    boundary.settleFilePreviewsForShutdown();
    try std.testing.expectEqual(@as(usize, 7), opened.calls);
    try std.testing.expect(!control.hasFilePreviews());
    boundary.assertQuiescent();
}

test "file preview async response preserves the exact bounded wire shape" {
    const Capture = struct {
        allocator: std.mem.Allocator,
        response: ?[]u8 = null,
        calls: usize = 0,

        fn receive(
            context: *anyopaque,
            _: native_sdk.bridge.Source,
            response: []const u8,
        ) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.response) |previous| self.allocator.free(previous);
            self.response = try self.allocator.dupe(u8, response);
            self.calls += 1;
        }

        fn reset(self: *@This()) void {
            if (self.response) |response| self.allocator.free(response);
            self.response = null;
            self.calls = 0;
        }
    };
    var capture = Capture{ .allocator = std.testing.allocator };
    defer capture.reset();
    const responder: native_sdk.bridge.AsyncResponder = .{
        .context = &capture,
        .source = .{ .origin = "zero://app", .window_id = 3 },
        .respond_fn = Capture.receive,
    };

    Dispatcher.respondFilePreview(
        responder,
        "preview-1",
        .ready,
        "line 1\nline 2",
        true,
        true,
        null,
    );
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    var ready = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        capture.response.?,
        .{},
    );
    defer ready.deinit();
    const ready_result = ready.value.object.get("result").?.object;
    try std.testing.expectEqualStrings(
        "ready",
        ready_result.get("state").?.string,
    );
    try std.testing.expectEqualStrings(
        "line 1\nline 2",
        ready_result.get("content").?.string,
    );
    try std.testing.expect(ready_result.get("truncated").?.bool);
    try std.testing.expect(ready_result.get("redacted").?.bool);

    capture.reset();
    Dispatcher.respondFilePreview(
        responder,
        "preview-2",
        .restricted,
        "must not cross the Bridge",
        true,
        true,
        null,
    );
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    var restricted = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        capture.response.?,
        .{},
    );
    defer restricted.deinit();
    const restricted_result = restricted.value.object.get("result").?.object;
    try std.testing.expectEqualStrings(
        "restricted",
        restricted_result.get("state").?.string,
    );
    try std.testing.expectEqualStrings(
        "",
        restricted_result.get("content").?.string,
    );
    try std.testing.expect(!restricted_result.get("truncated").?.bool);
    try std.testing.expect(!restricted_result.get("redacted").?.bool);
    const descriptor: Dispatcher.PreviewImage = .{ .token = "000000000000000000000000000000000000000000000000", .image = .{ .id = 1, .size_bytes = 10 * 1024 * 1024, .width = 1600, .height = 1600, .media_type = "image/png", .security_epoch = 1 } };
    capture.reset();
    Dispatcher.respondFilePreview(responder, "preview-image", .ready, "", false, false, descriptor);
    var image = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, capture.response.?, .{});
    defer image.deinit();
    const result = image.value.object.get("result").?.object;
    try std.testing.expectEqualStrings("10485760", result.get("image").?.object.get("sizeBytes").?.string);
    try std.testing.expectEqualStrings("image/png", result.get("image").?.object.get("mediaType").?.string);
    try std.testing.expectEqualStrings("", result.get("content").?.string);
    try std.testing.expect(result.get("image").?.object.get("dataBase64") == null);
    const fixture = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, @embedFile("file_preview_image.fixture"), .{});
    defer fixture.deinit();
    try std.testing.expectEqualStrings(fixture.value.object.get("image").?.object.get("token").?.string, result.get("image").?.object.get("token").?.string);
    try std.testing.expect(capture.response.?.len < native_sdk.bridge.max_result_bytes);
    capture.reset();
    Dispatcher.respondFilePreview(responder, "preview-busy", .busy, "must not appear", true, true, descriptor);
    var busy = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, capture.response.?, .{});
    defer busy.deinit();
    const busy_result = busy.value.object.get("result").?.object;
    try std.testing.expectEqualStrings("busy", busy_result.get("state").?.string);
    try std.testing.expect(busy_result.get("image") == null);
    try std.testing.expectEqualStrings("", busy_result.get("content").?.string);
}

test "file change diff async response preserves the strict wire variants" {
    const Capture = struct {
        allocator: std.mem.Allocator,
        response: ?[]u8 = null,

        fn receive(
            context: *anyopaque,
            _: native_sdk.bridge.Source,
            response: []const u8,
        ) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.response) |previous| self.allocator.free(previous);
            self.response = try self.allocator.dupe(u8, response);
        }

        fn reset(self: *@This()) void {
            if (self.response) |response| self.allocator.free(response);
            self.response = null;
        }
    };
    var capture = Capture{ .allocator = std.testing.allocator };
    defer capture.reset();
    const responder: native_sdk.bridge.AsyncResponder = .{
        .context = &capture,
        .source = .{ .origin = "zero://app", .window_id = 3 },
        .respond_fn = Capture.receive,
    };

    Dispatcher.respondFileChangeDiff(responder, "diff-1", .{ .ready = .{
        .completion_id = 1,
        .content = "@@ -1 +1 @@\n-old\n+new\n",
        .complete = false,
        .redacted = true,
    } });
    var ready = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        capture.response.?,
        .{},
    );
    defer ready.deinit();
    const ready_result = ready.value.object.get("result").?.object;
    try std.testing.expectEqual(@as(usize, 4), ready_result.count());
    try std.testing.expectEqualStrings("ready", ready_result.get("status").?.string);
    try std.testing.expectEqualStrings(
        "@@ -1 +1 @@\n-old\n+new\n",
        ready_result.get("content").?.string,
    );
    try std.testing.expect(!ready_result.get("complete").?.bool);
    try std.testing.expect(ready_result.get("redacted").?.bool);

    capture.reset();
    Dispatcher.respondFileChangeDiff(responder, "diff-2", .{ .unavailable = .{
        .completion_id = 2,
        .reason = .missing,
    } });
    var unavailable = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        capture.response.?,
        .{},
    );
    defer unavailable.deinit();
    const unavailable_result = unavailable.value.object.get("result").?.object;
    try std.testing.expectEqual(@as(usize, 3), unavailable_result.count());
    try std.testing.expectEqualStrings(
        "unavailable",
        unavailable_result.get("status").?.string,
    );
    try std.testing.expectEqualStrings("missing", unavailable_result.get("reason").?.string);
    try std.testing.expectEqualStrings("", unavailable_result.get("content").?.string);
}

test "Account command response encoding rejects inconsistent attempt metadata" {
    var output: [256]u8 = undefined;
    try std.testing.expectError(
        error.InvalidAccountCommandResult,
        encodeAccountResult(&output, .{
            .accepted = true,
            .error_code = .invalid_state,
        }),
    );
    try std.testing.expectError(
        error.InvalidAccountCommandResult,
        encodeAccountResult(&output, .{
            .accepted = false,
            .error_code = .invalid_state,
            .attempt_id = 7,
        }),
    );
    try std.testing.expectError(
        error.InvalidAccountCommandResult,
        encodeAccountResult(&output, .{
            .accepted = true,
            .error_code = .none,
            .attempt_id = 0,
        }),
    );
}

test "Execution command responses preserve the existing Bridge error vocabulary" {
    var output: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "{\"accepted\":true,\"errorCode\":\"none\",\"attemptId\":null}",
        try encodeExecutionResult(&output, .acceptedResult()),
    );
    inline for (.{
        .{ models_contract.ManagementError.invalid_provider, "custom_provider_invalid" },
        .{ models_contract.ManagementError.provider_not_found, "custom_provider_not_found" },
        .{ models_contract.ManagementError.generation_mismatch, "generation_mismatch" },
        .{ models_contract.ManagementError.model_not_found, "no_models" },
        .{ models_contract.ManagementError.capacity, "local_resource_exhausted" },
        .{ models_contract.ManagementError.persistence_unavailable, "custom_provider_persistence_unavailable" },
        .{ models_contract.ManagementError.capture_unavailable, "custom_provider_capture_unavailable" },
        .{ models_contract.ManagementError.credential_write_failed, "credential_store_write_failed" },
        .{ models_contract.ManagementError.operation_in_progress, "operation_in_progress" },
        .{ models_contract.ManagementError.test_unavailable, "custom_model_test_unavailable" },
        .{ models_contract.ManagementError.user_cancelled, "user_cancelled" },
        .{ models_contract.ManagementError.local_resource_exhausted, "local_resource_exhausted" },
    }) |case| {
        const encoded = try encodeExecutionResult(&output, .rejected(case[0]));
        var parsed = try std.json.parseFromSlice(
            std.json.Value,
            std.testing.allocator,
            encoded,
            .{},
        );
        defer parsed.deinit();
        try std.testing.expect(!parsed.value.object.get("accepted").?.bool);
        try std.testing.expectEqualStrings(
            case[1],
            parsed.value.object.get("errorCode").?.string,
        );
        try std.testing.expect(parsed.value.object.get("attemptId").? == .null);
    }
}

test "Task model selection result acknowledges intent revision and preserves typed save failures" {
    var output: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "{\"accepted\":true,\"taskId\":\"3\",\"selectionRevision\":\"7\",\"reason\":null}",
        try encodeTaskModelSelectionResult(&output, true, 3, 7, null),
    );
    try std.testing.expectEqualStrings(
        "{\"accepted\":false,\"taskId\":\"3\",\"selectionRevision\":null,\"reason\":\"persistence_outcome_unknown\"}",
        try encodeTaskModelSelectionResult(&output, false, 3, null, taskModelSelectionRejection(error.TaskPersistenceOutcomeUnknown)),
    );
    try std.testing.expectError(error.InvalidTaskModelSelectionResult, encodeTaskModelSelectionResult(&output, true, 0, 7, null));
    try std.testing.expectError(error.InvalidTaskModelSelectionResult, encodeTaskModelSelectionResult(&output, true, 3, 0, null));
    try std.testing.expectError(error.InvalidTaskModelSelectionResult, encodeTaskModelSelectionResult(&output, false, 3, 7, "persistence_failed"));
}

test "mutation response encoders reject every inconsistent success and rejection shape" {
    var output: [256]u8 = undefined;
    try std.testing.expectError(
        error.InvalidTaskCreateResult,
        encodeTaskCreateResult(&output, false, 1, null, null, "task_unavailable", null),
    );
    try std.testing.expectError(
        error.InvalidTaskCreateResult,
        encodeTaskCreateResult(&output, false, null, null, null, null, null),
    );
    try std.testing.expectError(
        error.InvalidTaskCreateResult,
        encodeTaskCreateResult(&output, true, 1, 1, .ready_without_selection, "unexpected", null),
    );
    try std.testing.expectError(
        error.InvalidTaskCreateResult,
        encodeTaskCreateResult(&output, true, 0, 1, .ready_without_selection, null, null),
    );
    try std.testing.expectError(
        error.InvalidTaskCreateResult,
        encodeTaskCreateResult(&output, true, 1, 0, .ready_without_selection, null, null),
    );
    try std.testing.expectError(
        error.InvalidTaskCreateResult,
        encodeTaskCreateResult(&output, true, 1, 1, null, null, null),
    );
    const task_create = try encodeTaskCreateResult(
        &output,
        true,
        1,
        1,
        .unavailable,
        null,
        null,
    );
    try std.testing.expectEqualStrings(
        "{\"accepted\":true,\"taskId\":\"1\",\"bindingEpoch\":\"1\",\"mcpAuthority\":{\"kind\":\"unavailable\",\"selection\":null},\"reason\":null}",
        task_create,
    );
    try std.testing.expectError(
        error.InvalidTaskRunResult,
        encodeTaskRunResult(&output, false, 1, 9, "task_busy"),
    );
    try std.testing.expectError(
        error.InvalidTaskRunResult,
        encodeTaskRunResult(&output, false, 1, null, null),
    );
    try std.testing.expectError(
        error.InvalidTaskRunResult,
        encodeTaskRunResult(&output, true, 0, 9, null),
    );
    try std.testing.expectError(
        error.InvalidTaskRunResult,
        encodeTaskRunResult(&output, true, 1, 0, null),
    );
    try std.testing.expectError(
        error.InvalidTaskCompactResult,
        encodeTaskCompactResult(&output, false, 1, 9, "task_busy"),
    );
    try std.testing.expectError(
        error.InvalidTaskCompactResult,
        encodeTaskCompactResult(&output, false, 1, null, null),
    );
    try std.testing.expectError(
        error.InvalidTaskCompactResult,
        encodeTaskCompactResult(&output, true, 0, 9, null),
    );
    try std.testing.expectError(
        error.InvalidTaskCompactResult,
        encodeTaskCompactResult(&output, true, 1, 0, null),
    );
    try std.testing.expectError(
        error.InvalidTaskRestoreResult,
        encodeTaskRestoreResult(&output, false, 1, 9, "recovery_unavailable", null),
    );
    try std.testing.expectError(
        error.InvalidTaskRestoreResult,
        encodeTaskRestoreResult(&output, false, 1, null, null, null),
    );
    try std.testing.expectError(
        error.InvalidTaskRestoreResult,
        encodeTaskRestoreResult(&output, true, 0, 9, null, null),
    );
    try std.testing.expectError(
        error.InvalidTaskRestoreResult,
        encodeTaskRestoreResult(&output, true, 1, 0, null, null),
    );
}

fn inactive(_: ?*anyopaque) bool {
    return false;
}

fn unavailableExternalUrl(_: ?*anyopaque, _: []const u8) anyerror!void {
    return error.ExternalLinkUnavailable;
}

fn validExternalLink(value: []const u8) bool {
    if (value.len == 0 or value.len > max_external_link_url_bytes or
        !std.unicode.utf8ValidateSlice(value)) return false;
    for (value) |byte| if (byte <= 0x20 or byte == 0x7f or byte == '\\')
        return false;
    const uri = std.Uri.parse(value) catch return false;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "http") or
        std.ascii.eqlIgnoreCase(uri.scheme, "https"))
    {
        return uri.host != null and !uri.host.?.isEmpty() and
            uri.user == null and uri.password == null;
    }
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "mailto")) return false;
    if (uri.host != null or uri.user != null or uri.password != null or
        uri.port != null or uri.path.isEmpty() or uri.fragment != null)
        return false;
    return std.ascii.indexOfIgnoreCase(value, "%0d") == null and
        std.ascii.indexOfIgnoreCase(value, "%0a") == null;
}

test "external link validation accepts only bounded credential-free web and mail targets" {
    for ([_][]const u8{
        "https://example.com/path?q=1#result",
        "HTTP://localhost:3000/",
        "mailto:test@example.com?subject=MetaWork",
    }) |value| try std.testing.expect(validExternalLink(value));

    for ([_][]const u8{
        "",
        "docs/help",
        "//example.com",
        "https:example.com",
        "https://user:secret@example.com",
        "https://example.com\\redirect",
        "file:///tmp/report.txt",
        "metawork://settings",
        "mailto:",
        "mailto:test@example.com?subject=a%0d%0abcc:x",
    }) |value| try std.testing.expect(!validExternalLink(value));

    var oversized: [max_external_link_url_bytes + 1]u8 = undefined;
    @memset(&oversized, 'a');
    try std.testing.expect(!validExternalLink(&oversized));
}

fn unavailableRandom(_: ?*anyopaque, _: []u8) bool {
    return false;
}

fn noAutomationWorkspace(_: ?*anyopaque) ?[]const u8 {
    return null;
}

fn noAutomationAttachments(_: ?*anyopaque) ?[]const u8 {
    return null;
}

fn countAutomationAttachmentPaths(paths: []const u8) ?usize {
    if (paths.len == 0) return null;
    var count: usize = 0;
    var split = std.mem.splitScalar(u8, paths, '\n');
    while (split.next()) |path| {
        if (path.len == 0) return null;
        count += 1;
    }
    return count;
}

test "automation attachment path batches preserve platform selection cardinality" {
    try std.testing.expectEqual(
        @as(?usize, 2),
        countAutomationAttachmentPaths("/tmp/one.png\n/tmp/two.jpg"),
    );
    try std.testing.expectEqual(@as(?usize, 1), countAutomationAttachmentPaths("/tmp/one.png"));
    try std.testing.expectEqual(@as(?usize, null), countAutomationAttachmentPaths(""));
    try std.testing.expectEqual(@as(?usize, null), countAutomationAttachmentPaths("/tmp/one.png\n"));
    try std.testing.expectEqual(@as(?usize, null), countAutomationAttachmentPaths("\n/tmp/two.jpg"));
}

test "file receive dispatch scopes cancellation, response loss and generation cleanup" {
    const fixture = @import("lifecycle_fixture");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buffer);
    var store = try product_control.AttachmentFileStore.init(std.testing.io, std.testing.allocator, path_buffer[0..path_len]);
    defer store.deinit();
    var wire = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, @embedFile("attachment_receive.fixture"), .{});
    defer wire.deinit();
    var fixture_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer fixture_arena.deinit();
    const Host = struct {
        fn wake(_: ?*anyopaque) anyerror!void {}
        fn emit(_: ?*anyopaque, _: u64, _: []const u8, _: []const u8) anyerror!void {}
        fn timer(_: ?*anyopaque, _: u64, _: u64, _: bool) anyerror!void {}
        fn cancel(_: ?*anyopaque, _: u64) anyerror!void {}
        fn main(_: ?*anyopaque) bool {
            return true;
        }
        fn now(_: ?*anyopaque) u64 {
            return 1;
        }
        fn random(_: ?*anyopaque, out: []u8) bool {
            @memset(out, 7);
            return true;
        }
    };
    fixture.fake_core.reset();
    const runtime = try fixture.createTestRuntime(.{ .max_sessions = 1 });
    var configuration = fixture.productControlConfiguration();
    configuration.attachment_store = &store;
    var workbench = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, .{ .max_tasks = 1, .max_runs_per_task = 1, .max_tools_per_run = 1 }, configuration);
    var dispatcher = try Dispatcher.init(std.testing.allocator, &workbench, undefined, undefined, .{
        .attachment_input = .file_bytes,
        .context = null,
        .wake_fn = Host.wake,
        .emit_fn = Host.emit,
        .start_timer_fn = Host.timer,
        .cancel_timer_fn = Host.cancel,
        .random_fn = Host.random,
        .now_fn = Host.now,
        .on_main_thread_fn = Host.main,
        // This test dispatches only the byte-input commands, never OS effects.
        .show_open_dialog_fn = undefined,
        .canonicalize_directory_fn = undefined,
        .window_chrome_connect_fn = undefined,
        .window_chrome_refresh_fn = undefined,
        .window_chrome_control_fn = undefined,
    }, .{}, 3);
    defer {
        dispatcher.deinit();
        workbench.shutdownExecutor();
        runtime.shutdown() catch unreachable;
        workbench.deinit();
        runtime.deinit();
    }
    const native = dispatcher.register(@import("policy.zig").product(.release));
    const source: native_sdk.bridge.Source = .{ .origin = "zero://app", .window_id = 3 };
    var output: [16 * 1024]u8 = undefined;
    const connect_request = "{\"id\":\"c\",\"command\":\"metawork.events.connect\",\"payload\":{\"contractId\":\"metawork.renderer-bridge\",\"contractRevision\":1}}";
    const connected = native.dispatch(connect_request, source, &output);
    const expected_connect = try std.json.Stringify.valueAlloc(fixture_arena.allocator(), wire.value.object.get("connect").?, .{});
    try std.testing.expect(std.mem.indexOf(u8, connected, expected_connect) != null);
    const Driver = struct {
        fn run(n: native_sdk.bridge.Dispatcher, s: native_sdk.bridge.Source, out: []u8, command: []const u8, payload: []const u8, expected: []const u8) !void {
            var request_buffer: [2048]u8 = undefined;
            const request = try std.fmt.bufPrint(&request_buffer, "{{\"id\":\"r\",\"command\":\"metawork.attachments.{s}\",\"payload\":{s}}}", .{ command, payload });
            const result = n.dispatch(request, s, out);
            try std.testing.expect(std.mem.indexOf(u8, result, expected) != null);
        }
    };
    const key = "{\"generation\":\"1\",\"batchId\":\"1\"}";
    const begin = "{\"generation\":\"1\",\"batchId\":\"1\",\"files\":[{\"name\":\"a.txt\",\"sizeBytes\":\"3\"}]}";
    try Driver.run(native, source, &output, "cancelReceive", key, "\"released\":false");
    try Driver.run(native, source, &output, "beginReceive", begin, "stale_transfer");
    const begin2 = try std.json.Stringify.valueAlloc(fixture_arena.allocator(), wire.value.object.get("begin").?, .{});
    try Driver.run(native, source, &output, "beginReceive", begin2, "accepted");
    try std.testing.expectEqual(@as(usize, 3), workbench.attachments.used_bytes);
    try Driver.run(native, .{ .origin = "zero://app", .window_id = 4 }, &output, "cancelReceive", "{\"generation\":\"1\",\"batchId\":\"2\"}", "handler_failed");
    try Driver.run(native, source, &output, "appendReceive", "{\"generation\":\"1\",\"batchId\":\"2\",\"fileIndex\":0,\"offset\":\"1\",\"dataBase64\":\"YWJj\"}", "invalid_transfer");
    try Driver.run(native, source, &output, "appendReceive", "{\"generation\":\"1\",\"batchId\":\"2\",\"fileIndex\":0,\"offset\":\"0\",\"dataBase64\":\"?\"}", "invalid_transfer");
    const append = try std.json.Stringify.valueAlloc(fixture_arena.allocator(), wire.value.object.get("append").?, .{});
    try Driver.run(native, source, &output, "appendReceive", append, "accepted");
    const key2 = try std.json.Stringify.valueAlloc(fixture_arena.allocator(), wire.value.object.get("key").?, .{});
    // Ignore the finish response, as if transport delivery was lost.
    const expected_ready = try std.json.Stringify.valueAlloc(fixture_arena.allocator(), wire.value.object.get("ready").?, .{});
    try Driver.run(native, source, &output, "finishReceive", key2, expected_ready);
    try Driver.run(native, source, &output, "finishReceive", key2, "stale_transfer");
    try Driver.run(native, source, &output, "cancelReceive", key2, "\"released\":true");
    try std.testing.expectEqual(@as(usize, 0), workbench.attachments.used_bytes);
    try Driver.run(native, source, &output, "beginReceive", "{\"generation\":\"1\",\"batchId\":\"3\",\"files\":[{\"name\":\"a\",\"sizeBytes\":\"3\"}]}", "accepted");
    _ = native.dispatch(connect_request, source, &output);
    try std.testing.expectEqual(@as(usize, 0), workbench.attachments.used_bytes);
    try Driver.run(native, source, &output, "beginReceive", "{\"generation\":\"2\",\"batchId\":\"1\",\"files\":[{\"name\":\"a\",\"sizeBytes\":\"3\"}]}", "accepted");
    try Driver.run(native, source, &output, "cancelReceive", key, "handler_failed");
    try std.testing.expectEqual(@as(usize, 3), workbench.attachments.used_bytes);
    dispatcher.breakConnection();
    try std.testing.expectEqual(@as(usize, 0), workbench.attachments.used_bytes);
}

test "Automatic Workspace root Bridge keeps paths Host-only and mutates by generation" {
    const fixture = @import("lifecycle_fixture");
    const Harness = struct {
        selected_path: []const u8,
        expected_default_path: []const u8,
        cancel_next: bool = false,

        fn wake(_: ?*anyopaque) anyerror!void {}
        fn emit(_: ?*anyopaque, _: u64, _: []const u8, _: []const u8) anyerror!void {}
        fn startTimer(_: ?*anyopaque, _: u64, _: u64, _: bool) anyerror!void {}
        fn cancelTimer(_: ?*anyopaque, _: u64) anyerror!void {}
        fn open(
            context: ?*anyopaque,
            options: native_sdk.platform.OpenDialogOptions,
            output: []u8,
        ) anyerror!native_sdk.platform.OpenDialogResult {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            try std.testing.expect(options.allow_directories);
            try std.testing.expect(!options.allow_multiple);
            try std.testing.expectEqualStrings(
                self.expected_default_path,
                options.default_path,
            );
            if (self.cancel_next) {
                self.cancel_next = false;
                return .{ .paths = "", .count = 0 };
            }
            @memcpy(output[0..self.selected_path.len], self.selected_path);
            return .{ .paths = output[0..self.selected_path.len], .count = 1 };
        }
        fn canonicalizeDirectory(
            _: ?*anyopaque,
            path: []const u8,
            output: []u8,
        ) anyerror![]const u8 {
            @memcpy(output[0..path.len], path);
            return output[0..path.len];
        }
        fn now(_: ?*anyopaque) u64 {
            return 1;
        }
        fn onMainThread(_: ?*anyopaque) bool {
            return true;
        }
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "default", .default_dir);
    try tmp.dir.createDir(std.testing.io, "custom", .default_dir);
    var default_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var custom_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const default_len = try tmp.dir.realPathFile(std.testing.io, "default", &default_storage);
    const custom_len = try tmp.dir.realPathFile(std.testing.io, "custom", &custom_storage);
    const default_root = default_storage[0..default_len];
    const custom_root = custom_storage[0..custom_len];
    var store: product_control.AutomaticWorkspaceRootConfigurationFileStore = .{
        .io = std.testing.io,
        .dir = tmp.dir,
    };

    fixture.fake_core.reset();
    const runtime = try fixture.createTestRuntime(.{ .max_sessions = 1 });
    var configuration = fixture.productControlConfiguration();
    configuration.directories = .{
        .automatic_workspace_system_root = default_root,
        .automatic_workspace_configuration_store = &store,
    };
    var workbench = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{ .max_tasks = 1, .max_runs_per_task = 1, .max_tools_per_run = 1 },
        configuration,
    );
    var harness: Harness = .{
        .selected_path = custom_root,
        .expected_default_path = default_root,
    };
    var dispatcher = try Dispatcher.init(
        std.testing.allocator,
        &workbench,
        undefined,
        undefined,
        .{
            .context = &harness,
            .wake_fn = Harness.wake,
            .emit_fn = Harness.emit,
            .start_timer_fn = Harness.startTimer,
            .cancel_timer_fn = Harness.cancelTimer,
            .show_open_dialog_fn = Harness.open,
            .canonicalize_directory_fn = Harness.canonicalizeDirectory,
            .window_chrome_connect_fn = undefined,
            .window_chrome_refresh_fn = undefined,
            .window_chrome_control_fn = undefined,
            .now_fn = Harness.now,
            .on_main_thread_fn = Harness.onMainThread,
        },
        .{},
        3,
    );
    defer {
        dispatcher.deinit();
        workbench.shutdownExecutor();
        runtime.shutdown() catch unreachable;
        workbench.deinit();
        runtime.deinit();
    }
    const native = dispatcher.register(@import("policy.zig").product(.release));
    const source: native_sdk.bridge.Source = .{ .origin = "zero://app", .window_id = 3 };
    var output: [4096]u8 = undefined;
    const connected = native.dispatch(
        "{\"id\":\"connect\",\"command\":\"metawork.events.connect\",\"payload\":{\"contractId\":\"metawork.renderer-bridge\",\"contractRevision\":1}}",
        source,
        &output,
    );
    try std.testing.expect(std.mem.indexOf(u8, connected, "\"generation\":\"1\"") != null);

    for ([_][]const u8{
        "{\"id\":\"bad-choose\",\"command\":\"metawork.workspaces.chooseAutomaticRoot\",\"payload\":{\"expectedGeneration\":\"1\",\"path\":\"/tmp/leak\"}}",
        "{\"id\":\"bad-reset\",\"command\":\"metawork.workspaces.resetAutomaticRoot\",\"payload\":{\"expectedGeneration\":\"0\"}}",
        "{\"id\":\"bad-retry\",\"command\":\"metawork.workspaces.retryAutomaticRoot\",\"payload\":{\"expectedGeneration\":\"1\",\"extra\":true}}",
    }) |request| {
        const response = native.dispatch(request, source, &output);
        try std.testing.expect(std.mem.indexOf(u8, response, "handler_failed") != null);
    }
    try std.testing.expectEqual(@as(u64, 1), workbench.automaticWorkspaceRootConfiguration().generation);

    harness.cancel_next = true;
    const cancelled = native.dispatch(
        "{\"id\":\"cancel\",\"command\":\"metawork.workspaces.chooseAutomaticRoot\",\"payload\":{\"expectedGeneration\":\"1\"}}",
        source,
        &output,
    );
    try std.testing.expect(std.mem.indexOf(u8, cancelled, "\"outcome\":\"cancelled\"") != null);
    try std.testing.expectEqual(@as(u64, 1), workbench.automaticWorkspaceRootConfiguration().generation);

    const chosen = native.dispatch(
        "{\"id\":\"choose\",\"command\":\"metawork.workspaces.chooseAutomaticRoot\",\"payload\":{\"expectedGeneration\":\"1\"}}",
        source,
        &output,
    );
    try std.testing.expect(std.mem.indexOf(u8, chosen, "\"outcome\":\"applied\"") != null);
    const custom_view = workbench.automaticWorkspaceRootConfiguration();
    try std.testing.expectEqualStrings(custom_root, custom_view.canonical_root.?);
    try std.testing.expectEqual(product_control.AutomaticWorkspaceRootConfigurationMode.custom, custom_view.mode.?);

    harness.expected_default_path = custom_root;
    harness.cancel_next = true;
    var cancel_custom_request_storage: [256]u8 = undefined;
    const cancel_custom_request = try std.fmt.bufPrint(
        &cancel_custom_request_storage,
        "{{\"id\":\"cancel-custom\",\"command\":\"metawork.workspaces.chooseAutomaticRoot\",\"payload\":{{\"expectedGeneration\":\"{d}\"}}}}",
        .{custom_view.generation},
    );
    const cancelled_custom = native.dispatch(cancel_custom_request, source, &output);
    try std.testing.expect(std.mem.indexOf(u8, cancelled_custom, "\"outcome\":\"cancelled\"") != null);
    try std.testing.expectEqual(
        custom_view.generation,
        workbench.automaticWorkspaceRootConfiguration().generation,
    );

    var reset_request_storage: [256]u8 = undefined;
    const reset_request = try std.fmt.bufPrint(
        &reset_request_storage,
        "{{\"id\":\"reset\",\"command\":\"metawork.workspaces.resetAutomaticRoot\",\"payload\":{{\"expectedGeneration\":\"{d}\"}}}}",
        .{custom_view.generation},
    );
    const reset = native.dispatch(reset_request, source, &output);
    try std.testing.expect(std.mem.indexOf(u8, reset, "\"outcome\":\"applied\"") != null);
    const reset_view = workbench.automaticWorkspaceRootConfiguration();
    try std.testing.expectEqualStrings(default_root, reset_view.canonical_root.?);
    try std.testing.expectEqual(product_control.AutomaticWorkspaceRootConfigurationMode.system_default, reset_view.mode.?);
}

test "Dispatcher validates authority before domain calls and preserves committed state on response loss" {
    const fixture = @import("lifecycle_fixture");
    const Harness = struct {
        wake_calls: usize = 0,
        account_calls: usize = 0,
        models_calls: usize = 0,
        chrome_connect_calls: usize = 0,
        chrome_refresh_calls: usize = 0,
        chrome_control_calls: usize = 0,
        external_link_calls: usize = 0,
        external_link_error: ?anyerror = null,
        chrome_error: ?anyerror = null,
        on_main_thread: bool = true,
        account_result: account_contract.AccountCommandResult =
            .acceptedAttempt(41),
        models_result: models_contract.CommandResult = .acceptedResult(),

        fn wake(context: ?*anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.wake_calls += 1;
        }

        fn emit(_: ?*anyopaque, _: u64, _: []const u8, _: []const u8) anyerror!void {}
        fn startTimer(_: ?*anyopaque, _: u64, _: u64, _: bool) anyerror!void {}
        fn cancelTimer(_: ?*anyopaque, _: u64) anyerror!void {}

        fn open(
            _: ?*anyopaque,
            _: native_sdk.platform.OpenDialogOptions,
            output: []u8,
        ) anyerror!native_sdk.platform.OpenDialogResult {
            const path = "/tmp";
            @memcpy(output[0..path.len], path);
            return .{ .paths = output[0..path.len], .count = 1 };
        }

        fn canonicalizeDirectory(
            _: ?*anyopaque,
            path: []const u8,
            output: []u8,
        ) anyerror![]const u8 {
            @memcpy(output[0..path.len], path);
            return output[0..path.len];
        }

        fn chromeEnvironment() WindowChromePlatformEnvironment {
            return .{
                .top = 52,
                .left = 0,
                .bottom = 0,
                .right = 138,
                .buttons_x = 662,
                .buttons_y = 0,
                .buttons_width = 138,
                .buttons_height = 52,
                .renderer_controls = true,
                .maximized = false,
            };
        }

        fn connectWindowChrome(
            context: ?*anyopaque,
            window_id: native_sdk.platform.WindowId,
        ) anyerror!WindowChromePlatformEnvironment {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            try std.testing.expectEqual(@as(native_sdk.platform.WindowId, 3), window_id);
            if (self.chrome_error) |err| return err;
            self.chrome_connect_calls += 1;
            return chromeEnvironment();
        }

        fn refreshWindowChrome(
            context: ?*anyopaque,
            window_id: native_sdk.platform.WindowId,
        ) anyerror!WindowChromePlatformEnvironment {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            try std.testing.expectEqual(@as(native_sdk.platform.WindowId, 3), window_id);
            if (self.chrome_error) |err| return err;
            self.chrome_refresh_calls += 1;
            return chromeEnvironment();
        }

        fn controlWindowChrome(
            context: ?*anyopaque,
            window_id: native_sdk.platform.WindowId,
            action: WindowChromeControlAction,
        ) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            try std.testing.expectEqual(@as(native_sdk.platform.WindowId, 3), window_id);
            try std.testing.expectEqual(WindowChromeControlAction.toggle_maximize, action);
            self.chrome_control_calls += 1;
        }

        fn openExternalUrl(context: ?*anyopaque, url: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            try std.testing.expect(validExternalLink(url));
            self.external_link_calls += 1;
            if (self.external_link_error) |err| return err;
        }

        fn now(_: ?*anyopaque) u64 {
            return 7;
        }

        fn onMainThread(context: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            return self.on_main_thread;
        }

        fn submitAccount(
            context: *anyopaque,
            command: account_contract.AccountCommand,
        ) account_contract.AccountCommandResult {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.account_calls += 1;
            switch (command) {
                .begin_login,
                .cancel_operation,
                .retry_refresh,
                .refresh_summary,
                .open_recharge,
                .logout,
                => {},
            }
            return self.account_result;
        }

        fn submitCustomProvider(
            context: *anyopaque,
            _: models_contract.CustomProviderCommand,
        ) models_contract.CommandResult {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.account_calls += 1;
            return if (self.account_result.accepted)
                .acceptedResult()
            else
                .rejected(.invalid_provider);
        }

        fn refreshModels(context: *anyopaque) models_contract.CommandResult {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.models_calls += 1;
            return self.models_result;
        }

        fn resetModels(
            context: *anyopaque,
            _: u64,
        ) models_contract.CommandResult {
            return refreshModels(context);
        }
    };

    fixture.fake_core.reset();
    const runtime = try fixture.createTestRuntime(.{ .max_sessions = 1 });
    var workbench = try product_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        runtime,
        .{ .max_tasks = 1, .max_runs_per_task = 1, .max_tools_per_run = 1 },
        fixture.productControlConfiguration(),
    );
    try fixture.installProductControlExecution(&workbench);
    const initial_revision = workbench.currentRevision();
    var harness = Harness{};
    var dispatcher = try Dispatcher.init(
        std.testing.allocator,
        &workbench,
        .{
            .context = &harness,
            .submit_fn = Harness.submitAccount,
        },
        .{
            .context = &harness,
            .submit_fn = Harness.submitCustomProvider,
        },
        .{
            .context = &harness,
            .wake_fn = Harness.wake,
            .emit_fn = Harness.emit,
            .start_timer_fn = Harness.startTimer,
            .cancel_timer_fn = Harness.cancelTimer,
            .show_open_dialog_fn = Harness.open,
            .canonicalize_directory_fn = Harness.canonicalizeDirectory,
            .window_chrome_connect_fn = Harness.connectWindowChrome,
            .window_chrome_refresh_fn = Harness.refreshWindowChrome,
            .window_chrome_control_fn = Harness.controlWindowChrome,
            .open_external_url_fn = Harness.openExternalUrl,
            .now_fn = Harness.now,
            .on_main_thread_fn = Harness.onMainThread,
        },
        .{},
        3,
    );
    defer {
        dispatcher.deinit();
        workbench.shutdownExecutor();
        runtime.shutdown() catch unreachable;
        workbench.deinit();
        runtime.deinit();
    }
    dispatcher.setModelsHost(.{
        .context = &harness,
        .refresh_catalog_fn = Harness.refreshModels,
        .reset_store_fn = Harness.resetModels,
    });
    const native_dispatcher = dispatcher.register(
        @import("policy.zig").product(.release),
    );
    // Every published command must resolve exactly once, including async-only
    // commands whose sync lookup must safely traverse the entire table.
    for (commands.product) |command| {
        const sync_handler = native_dispatcher.registry.find(command);
        const async_handler = native_dispatcher.async_registry.find(command);
        try std.testing.expect((sync_handler != null) != (async_handler != null));
    }
    try std.testing.expect(native_dispatcher.registry.find(commands.preview_file) == null);
    try std.testing.expect(native_dispatcher.async_registry.find(commands.preview_file) != null);
    try std.testing.expect(native_dispatcher.registry.find(commands.diff_file) == null);
    try std.testing.expect(native_dispatcher.async_registry.find(commands.diff_file) != null);
    const source = native_sdk.bridge.Source{ .origin = "zero://app", .window_id = 3 };
    var response: [4096]u8 = undefined;

    for ([_][]const u8{
        "{\"id\":\"snapshot-before-contract\",\"command\":\"metawork.workbench.snapshot\",\"payload\":{}}",
        "{\"id\":\"account-before-contract\",\"command\":\"metawork.account.beginLogin\",\"payload\":{}}",
        "{\"id\":\"task-before-contract\",\"command\":\"metawork.tasks.create\",\"payload\":{\"workspaceGrant\":\"1\"}}",
        "{\"id\":\"link-before-contract\",\"command\":\"metawork.host.links.openExternal\",\"payload\":{\"url\":\"https://example.com\"}}",
    }) |request| {
        const before_contract = native_dispatcher.dispatch(request, source, &response);
        try std.testing.expect(std.mem.indexOf(u8, before_contract, "\"handler_failed\"") != null);
    }
    try std.testing.expectEqual(@as(usize, 0), harness.account_calls);
    try std.testing.expectEqual(@as(usize, 0), harness.external_link_calls);
    try std.testing.expectEqual(initial_revision, workbench.currentRevision());

    const chrome_connect = native_dispatcher.dispatch(
        "{\"id\":\"chrome-connect\",\"command\":\"metawork.host.windowChrome.connect\",\"payload\":{}}",
        source,
        &response,
    );
    try std.testing.expect(std.mem.indexOf(u8, chrome_connect, "\"generation\":\"1\"") != null);
    try std.testing.expectEqual(@as(usize, 1), harness.chrome_connect_calls);
    const chrome_refresh = native_dispatcher.dispatch(
        "{\"id\":\"chrome-refresh\",\"command\":\"metawork.host.windowChrome.refresh\",\"payload\":{\"generation\":\"1\"}}",
        source,
        &response,
    );
    try std.testing.expect(std.mem.indexOf(u8, chrome_refresh, "\"right\":138") != null);
    try std.testing.expectEqual(@as(usize, 1), harness.chrome_refresh_calls);
    const retired_gesture = native_dispatcher.dispatch(
        "{\"id\":\"retired-gesture\",\"command\":\"metawork.host.windowChrome.gesture\",\"payload\":{\"generation\":\"1\",\"action\":\"start_drag\",\"x\":200,\"y\":20}}",
        source,
        &response,
    );
    try std.testing.expect(std.mem.indexOf(u8, retired_gesture, "\"handled\":true") == null);
    const chrome_control = native_dispatcher.dispatch(
        "{\"id\":\"chrome-control\",\"command\":\"metawork.host.windowChrome.control\",\"payload\":{\"generation\":\"1\",\"action\":\"toggle_maximize\"}}",
        source,
        &response,
    );
    try std.testing.expect(std.mem.indexOf(u8, chrome_control, "\"handled\":true") != null);
    try std.testing.expectEqual(@as(usize, 1), harness.chrome_control_calls);
    const foreign_bootstrap_window = native_sdk.bridge.Source{
        .origin = source.origin,
        .window_id = source.window_id + 1,
    };
    const denied_bootstrap_connect = native_dispatcher.dispatch(
        "{\"id\":\"wrong-bootstrap-window\",\"command\":\"metawork.host.windowChrome.connect\",\"payload\":{}}",
        foreign_bootstrap_window,
        &response,
    );
    try std.testing.expect(std.mem.indexOf(u8, denied_bootstrap_connect, "\"handler_failed\"") != null);
    try std.testing.expectEqual(@as(usize, 1), harness.chrome_connect_calls);
    harness.on_main_thread = false;
    const off_thread_refresh = native_dispatcher.dispatch(
        "{\"id\":\"off-thread-sync\",\"command\":\"metawork.host.windowChrome.refresh\",\"payload\":{\"generation\":\"1\"}}",
        source,
        &response,
    );
    try std.testing.expect(std.mem.indexOf(u8, off_thread_refresh, "\"handler_failed\"") != null);
    try std.testing.expectEqual(@as(usize, 1), harness.chrome_refresh_calls);
    harness.on_main_thread = true;
    const invalid_refresh = native_dispatcher.dispatch(
        "{\"id\":\"invalid-window-chrome\",\"command\":\"metawork.host.windowChrome.refresh\",\"payload\":{\"generation\":\"1\",\"regions\":[]}}",
        source,
        &response,
    );
    try std.testing.expect(std.mem.indexOf(u8, invalid_refresh, "\"handler_failed\"") != null);
    try std.testing.expectEqual(@as(usize, 1), harness.chrome_refresh_calls);
    const chrome_disconnect = native_dispatcher.dispatch(
        "{\"id\":\"chrome-disconnect\",\"command\":\"metawork.host.windowChrome.disconnect\",\"payload\":{\"generation\":\"1\"}}",
        source,
        &response,
    );
    try std.testing.expect(std.mem.indexOf(u8, chrome_disconnect, "\"detached\":true") != null);
    const stale_after_disconnect = native_dispatcher.dispatch(
        "{\"id\":\"stale-after-disconnect\",\"command\":\"metawork.host.windowChrome.refresh\",\"payload\":{\"generation\":\"1\"}}",
        source,
        &response,
    );
    try std.testing.expect(std.mem.indexOf(u8, stale_after_disconnect, "\"handler_failed\"") != null);
    try std.testing.expectEqual(@as(usize, 1), harness.chrome_refresh_calls);
    const replacement_connect = native_dispatcher.dispatch(
        "{\"id\":\"replacement-connect\",\"command\":\"metawork.host.windowChrome.connect\",\"payload\":{}}",
        source,
        &response,
    );
    try std.testing.expect(std.mem.indexOf(u8, replacement_connect, "\"generation\":\"2\"") != null);
    const stale_replacement_refresh = native_dispatcher.dispatch(
        "{\"id\":\"stale-replacement-sync\",\"command\":\"metawork.host.windowChrome.refresh\",\"payload\":{\"generation\":\"1\"}}",
        source,
        &response,
    );
    try std.testing.expect(std.mem.indexOf(u8, stale_replacement_refresh, "\"handler_failed\"") != null);
    try std.testing.expectEqual(@as(usize, 1), harness.chrome_refresh_calls);

    const current_refresh = "{\"id\":\"current-refresh\",\"command\":\"metawork.host.windowChrome.refresh\",\"payload\":{\"generation\":\"2\"}}";
    harness.chrome_error = error.WindowUnavailable;
    const failed_refresh = native_dispatcher.dispatch(current_refresh, source, &response);
    try std.testing.expect(std.mem.indexOf(u8, failed_refresh, "WindowUnavailable") != null);
    try std.testing.expect(dispatcher.window_chrome_connected);
    try std.testing.expectEqual(@as(u64, 2), dispatcher.window_chrome_generation);
    harness.chrome_error = null;
    const recovered_refresh = native_dispatcher.dispatch(current_refresh, source, &response);
    try std.testing.expect(std.mem.indexOf(u8, recovered_refresh, "\"generation\":\"2\"") != null);

    harness.chrome_error = error.WindowUnavailable;
    const failed_connect = native_dispatcher.dispatch(
        "{\"id\":\"failed-connect\",\"command\":\"metawork.host.windowChrome.connect\",\"payload\":{}}",
        source,
        &response,
    );
    try std.testing.expect(std.mem.indexOf(u8, failed_connect, "WindowUnavailable") != null);
    try std.testing.expect(!dispatcher.window_chrome_connected);
    try std.testing.expectEqual(@as(u64, 3), dispatcher.window_chrome_generation);
    harness.chrome_error = null;

    const mismatch = native_dispatcher.dispatch(
        "{\"id\":\"mismatch\",\"command\":\"metawork.events.connect\",\"payload\":{\"contractId\":\"metawork.renderer-bridge\",\"contractRevision\":2}}",
        source,
        &response,
    );
    try std.testing.expect(std.mem.indexOf(u8, mismatch, "\"accepted\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, mismatch, "\"revision_mismatch\"") != null);
    try std.testing.expect(dispatcher.connectedWindow() == null);
    const identity_mismatch = native_dispatcher.dispatch(
        "{\"id\":\"identity-mismatch\",\"command\":\"metawork.events.connect\",\"payload\":{\"contractId\":\"other.renderer-bridge\",\"contractRevision\":1}}",
        source,
        &response,
    );
    try std.testing.expect(std.mem.indexOf(u8, identity_mismatch, "\"identity_mismatch\"") != null);
    try std.testing.expect(dispatcher.connectedWindow() == null);

    const invalid = native_dispatcher.dispatch(
        "{\"id\":\"bad\",\"command\":\"metawork.tasks.create\",\"payload\":{\"workspaceGrant\":\"1\",\"extra\":true}}",
        source,
        &response,
    );
    try std.testing.expect(std.mem.indexOf(u8, invalid, "\"handler_failed\"") != null);
    try std.testing.expectEqual(initial_revision, workbench.currentRevision());

    _ = native_dispatcher.dispatch(
        "{\"id\":\"connect\",\"command\":\"metawork.events.connect\",\"payload\":{\"contractId\":\"metawork.renderer-bridge\",\"contractRevision\":1}}",
        source,
        &response,
    );
    try std.testing.expect(dispatcher.connectedWindow() == source.window_id);
    _ = native_dispatcher.dispatch(
        "{\"id\":\"reload-mismatch\",\"command\":\"metawork.events.connect\",\"payload\":{\"contractId\":\"metawork.renderer-bridge\",\"contractRevision\":2}}",
        source,
        &response,
    );
    try std.testing.expect(dispatcher.connectedWindow() == null);
    const gated_after_mismatch = native_dispatcher.dispatch(
        "{\"id\":\"account-after-mismatch\",\"command\":\"metawork.account.beginLogin\",\"payload\":{}}",
        source,
        &response,
    );
    try std.testing.expect(std.mem.indexOf(u8, gated_after_mismatch, "\"handler_failed\"") != null);
    try std.testing.expectEqual(@as(usize, 0), harness.account_calls);
    _ = native_dispatcher.dispatch(
        "{\"id\":\"reconnect\",\"command\":\"metawork.events.connect\",\"payload\":{\"contractId\":\"metawork.renderer-bridge\",\"contractRevision\":1}}",
        source,
        &response,
    );
    for ([_][]const u8{
        "{\"id\":\"open-https\",\"command\":\"metawork.host.links.openExternal\",\"payload\":{\"url\":\"https://example.com/a?q=1#result\"}}",
        "{\"id\":\"open-http\",\"command\":\"metawork.host.links.openExternal\",\"payload\":{\"url\":\"http://localhost:3000/\"}}",
        "{\"id\":\"open-mail\",\"command\":\"metawork.host.links.openExternal\",\"payload\":{\"url\":\"mailto:test@example.com?subject=MetaWork\"}}",
    }) |request| {
        const opened = native_dispatcher.dispatch(request, source, &response);
        try std.testing.expect(std.mem.indexOf(u8, opened, "\"outcome\":\"opened\"") != null);
    }
    try std.testing.expectEqual(@as(usize, 3), harness.external_link_calls);
    for ([_][]const u8{
        "{\"id\":\"relative-link\",\"command\":\"metawork.host.links.openExternal\",\"payload\":{\"url\":\"docs/help\"}}",
        "{\"id\":\"credential-link\",\"command\":\"metawork.host.links.openExternal\",\"payload\":{\"url\":\"https://user:secret@example.com\"}}",
        "{\"id\":\"custom-link\",\"command\":\"metawork.host.links.openExternal\",\"payload\":{\"url\":\"metawork://settings\"}}",
        "{\"id\":\"newline-mail\",\"command\":\"metawork.host.links.openExternal\",\"payload\":{\"url\":\"mailto:test@example.com?subject=a%0Abcc:x\"}}",
    }) |request| {
        const rejected = native_dispatcher.dispatch(request, source, &response);
        try std.testing.expect(std.mem.indexOf(u8, rejected, "\"outcome\":\"rejected\"") != null);
    }
    try std.testing.expectEqual(@as(usize, 3), harness.external_link_calls);
    harness.external_link_error = error.SystemHandlerUnavailable;
    const unavailable_link = native_dispatcher.dispatch(
        "{\"id\":\"unavailable-link\",\"command\":\"metawork.host.links.openExternal\",\"payload\":{\"url\":\"https://example.com\"}}",
        source,
        &response,
    );
    try std.testing.expect(std.mem.indexOf(u8, unavailable_link, "\"outcome\":\"unavailable\"") != null);
    try std.testing.expectEqual(@as(usize, 4), harness.external_link_calls);
    harness.external_link_error = null;
    var recovery_request_storage: [256]u8 = undefined;
    const task_recovery_request = try std.fmt.bufPrint(
        &recovery_request_storage,
        "{{\"id\":\"recover-task-history\",\"command\":\"metawork.tasks.recoverHistory\",\"payload\":{{\"expectedRevision\":\"{d}\"}}}}",
        .{initial_revision},
    );
    const task_recovery = native_dispatcher.dispatch(
        task_recovery_request,
        source,
        &response,
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        task_recovery,
        "\"outcome\":\"unavailable\"",
    ) != null);
    const schedule_recovery_request = try std.fmt.bufPrint(
        &recovery_request_storage,
        "{{\"id\":\"recover-schedule-store\",\"command\":\"metawork.scheduledTasks.recoverStore\",\"payload\":{{\"expectedRevision\":\"{d}\"}}}}",
        .{initial_revision},
    );
    const schedule_recovery = native_dispatcher.dispatch(
        schedule_recovery_request,
        source,
        &response,
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        schedule_recovery,
        "\"outcome\":\"unavailable\"",
    ) != null);
    const login = native_dispatcher.dispatch(
        "{\"id\":\"login\",\"command\":\"metawork.account.beginLogin\",\"payload\":{}}",
        source,
        &response,
    );
    try std.testing.expectEqual(@as(usize, 1), harness.account_calls);
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            login,
            "\"accepted\":true,\"errorCode\":\"none\",\"attemptId\":\"41\"",
        ) != null,
    );
    const foreign_origin = native_sdk.bridge.Source{
        .origin = "https://attacker.invalid",
        .window_id = source.window_id,
    };
    const denied_origin = native_dispatcher.dispatch(
        "{\"id\":\"foreign\",\"command\":\"metawork.account.logout\",\"payload\":{}}",
        foreign_origin,
        &response,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, denied_origin, "\"result\"") == null,
    );
    try std.testing.expectEqual(@as(usize, 1), harness.account_calls);
    const wrong_window = native_sdk.bridge.Source{
        .origin = source.origin,
        .window_id = source.window_id + 1,
    };
    const denied_window = native_dispatcher.dispatch(
        "{\"id\":\"wrong-window\",\"command\":\"metawork.account.logout\",\"payload\":{}}",
        wrong_window,
        &response,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, denied_window, "\"handler_failed\"") != null,
    );
    try std.testing.expectEqual(@as(usize, 1), harness.account_calls);
    const invalid_account_payload = native_dispatcher.dispatch(
        "{\"id\":\"bad-login\",\"command\":\"metawork.account.beginLogin\",\"payload\":{\"extra\":true}}",
        source,
        &response,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, invalid_account_payload, "\"handler_failed\"") !=
            null,
    );
    try std.testing.expectEqual(@as(usize, 1), harness.account_calls);
    const refreshed_summary = native_dispatcher.dispatch(
        "{\"id\":\"refresh-summary\",\"command\":\"metawork.account.refreshSummary\",\"payload\":{}}",
        source,
        &response,
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        refreshed_summary,
        "\"accepted\":true,\"errorCode\":\"none\",\"attemptId\":\"41\"",
    ) != null);
    try std.testing.expectEqual(@as(usize, 2), harness.account_calls);
    const invalid_summary_payload = native_dispatcher.dispatch(
        "{\"id\":\"bad-refresh-summary\",\"command\":\"metawork.account.refreshSummary\",\"payload\":{\"extra\":true}}",
        source,
        &response,
    );
    try std.testing.expect(std.mem.indexOf(u8, invalid_summary_payload, "\"handler_failed\"") != null);
    try std.testing.expectEqual(@as(usize, 2), harness.account_calls);
    const empty_model = native_dispatcher.dispatch(
        "{\"id\":\"empty-model\",\"command\":\"metawork.models.configureMetaskSelection\",\"payload\":{\"sourceId\":\"\",\"modelId\":\"\",\"expectedMetaskSelectionRevision\":\"0\",\"expectedSourceGeneration\":\"0\",\"expectedCatalogGeneration\":\"0\"}}",
        source,
        &response,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, empty_model, "\"handler_failed\"") != null,
    );
    try std.testing.expectEqual(@as(usize, 2), harness.account_calls);
    const image_revision = workbench.currentRevision();
    const retired_image_setting = native_dispatcher.dispatch(
        "{\"id\":\"image-setting\",\"command\":\"metawork.models.configureMetaskImageSelection\",\"payload\":{\"modelId\":\"other-image\",\"expectedSelectionRevision\":\"0\",\"expectedCatalogGeneration\":\"0\"}}",
        source,
        &response,
    );
    try std.testing.expect(std.mem.indexOf(u8, retired_image_setting, "\"permission_denied\"") != null);
    try std.testing.expectEqual(image_revision, workbench.currentRevision());
    try std.testing.expectEqual(@as(usize, 2), harness.account_calls);
    const forwarded_selection = native_dispatcher.dispatch(
        "{\"id\":\"refresh-models\",\"command\":\"metawork.models.refreshCatalog\",\"payload\":{}}",
        source,
        &response,
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        forwarded_selection,
        "\"accepted\":true",
    ) != null);
    try std.testing.expectEqual(@as(usize, 2), harness.account_calls);
    try std.testing.expectEqual(@as(usize, 1), harness.models_calls);
    var reset_request_storage: [256]u8 = undefined;
    const reset_request = try std.fmt.bufPrint(
        &reset_request_storage,
        "{{\"id\":\"reset-models\",\"command\":\"metawork.models.resetStore\",\"payload\":{{\"expectedRevision\":\"{d}\"}}}}",
        .{workbench.currentRevision()},
    );
    const reset_response = native_dispatcher.dispatch(
        reset_request,
        source,
        &response,
    );
    try std.testing.expect(std.mem.indexOf(u8, reset_response, "\"accepted\":true") != null);
    try std.testing.expectEqual(@as(usize, 2), harness.models_calls);
    const malformed_reset = native_dispatcher.dispatch(
        "{\"id\":\"bad-reset\",\"command\":\"metawork.models.resetStore\",\"payload\":{\"expectedRevision\":\"1\",\"extra\":true}}",
        source,
        &response,
    );
    try std.testing.expect(std.mem.indexOf(u8, malformed_reset, "\"handler_failed\"") != null);
    harness.on_main_thread = false;
    _ = native_dispatcher.dispatch(
        "{\"id\":\"wrong-thread\",\"command\":\"metawork.account.logout\",\"payload\":{}}",
        source,
        &response,
    );
    try std.testing.expectEqual(@as(usize, 2), harness.account_calls);
    harness.on_main_thread = true;
    harness.account_result = .rejected(.invalid_state);
    const rejected = native_dispatcher.dispatch(
        "{\"id\":\"state-rejected\",\"command\":\"metawork.account.logout\",\"payload\":{}}",
        source,
        &response,
    );
    try std.testing.expectEqual(@as(usize, 3), harness.account_calls);
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            rejected,
            "\"accepted\":false,\"errorCode\":\"invalid_state\",\"attemptId\":null",
        ) != null,
    );
    harness.account_result = .acceptedAttempt(null);
    const retried_refresh = native_dispatcher.dispatch(
        "{\"id\":\"retry-refresh\",\"command\":\"metawork.account.retryRefresh\",\"payload\":{}}",
        source,
        &response,
    );
    try std.testing.expectEqual(@as(usize, 4), harness.account_calls);
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            retried_refresh,
            "\"accepted\":true,\"errorCode\":\"none\",\"attemptId\":null",
        ) != null,
    );
    const chosen = native_dispatcher.dispatch(
        "{\"id\":\"choose\",\"command\":\"metawork.workspaces.choose\",\"payload\":{}}",
        source,
        &response,
    );
    const workspace_start = std.mem.indexOf(u8, chosen, "\"workspaceId\":\"") orelse
        return error.TestUnexpectedResult;
    const digits_start = workspace_start + "\"workspaceId\":\"".len;
    const digits_end = std.mem.indexOfPos(u8, chosen, digits_start, "\"") orelse
        return error.TestUnexpectedResult;
    const workspace_id = try handlers.parseWireId(chosen[digits_start..digits_end]);

    var workspace_request_storage: [512]u8 = undefined;
    const refresh_workspace_request = try std.fmt.bufPrint(
        &workspace_request_storage,
        "{{\"id\":\"refresh-skills\",\"command\":\"metawork.workspaces.refreshSkillCatalog\",\"payload\":{{\"workspaceId\":\"{d}\",\"expectedWorkspaceEpoch\":\"1\"}}}}",
        .{workspace_id},
    );
    const refresh_workspace = native_dispatcher.dispatch(
        refresh_workspace_request,
        source,
        &response,
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        refresh_workspace,
        "\"reason\":\"catalog_unavailable\"",
    ) != null);

    const stale_create = try std.fmt.bufPrint(
        &workspace_request_storage,
        "{{\"id\":\"stale-create\",\"command\":\"metawork.tasks.create\",\"payload\":{{\"workspace\":{{\"kind\":\"manual\",\"workspaceId\":\"{d}\",\"expectedWorkspaceEpoch\":\"1\"}},\"expectedExecutionGeneration\":\"99\",\"expectedSelectionRevision\":\"3\",\"modelSelection\":null,\"expectedSkillCatalogRevision\":null,\"expectedSkillSelectionRevision\":null,\"approvalMode\":\"manual\"}}}}",
        .{workspace_id},
    );
    const rejected_create = native_dispatcher.dispatch(
        stale_create,
        source,
        &response,
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        rejected_create,
        "\"reason\":\"execution_changed\"",
    ) != null);

    const automatic_create = native_dispatcher.dispatch(
        "{\"id\":\"automatic-create\",\"command\":\"metawork.tasks.create\",\"payload\":{\"workspace\":{\"kind\":\"automatic\"},\"expectedExecutionGeneration\":\"1\",\"expectedSelectionRevision\":\"3\",\"modelSelection\":null,\"expectedSkillCatalogRevision\":null,\"expectedSkillSelectionRevision\":null,\"approvalMode\":\"manual\"}}",
        source,
        &response,
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        automatic_create,
        "\"reason\":\"workspace_unavailable\"",
    ) != null);

    var request_storage: [512]u8 = undefined;
    const request = try std.fmt.bufPrint(
        &request_storage,
        "{{\"id\":\"create\",\"command\":\"metawork.tasks.create\",\"payload\":{{\"workspace\":{{\"kind\":\"manual\",\"workspaceId\":\"{d}\",\"expectedWorkspaceEpoch\":\"1\"}},\"expectedExecutionGeneration\":\"1\",\"expectedSelectionRevision\":\"3\",\"modelSelection\":null,\"expectedSkillCatalogRevision\":null,\"expectedSkillSelectionRevision\":null,\"approvalMode\":\"manual\"}}}}",
        .{workspace_id},
    );
    var lost_response: [32]u8 = undefined;
    _ = native_dispatcher.dispatch(request, source, &lost_response);
    try std.testing.expect(workbench.currentRevision() > 0);
    try std.testing.expect(harness.wake_calls >= 2);

    const approval_requests = [_]struct { payload: []const u8, expected: []const u8 }{
        .{ .payload = "{\"id\":\"mode-noop\",\"command\":\"metawork.tasks.setApprovalMode\",\"payload\":{\"taskId\":\"1\",\"targetMode\":\"manual\",\"expectedBindingEpoch\":\"1\",\"expectedApprovalRevision\":\"1\"}}", .expected = "\"accepted\":true,\"taskId\":\"1\",\"approvalRevision\":\"1\",\"reason\":null" },
        .{ .payload = "{\"id\":\"mode-stale-binding\",\"command\":\"metawork.tasks.setApprovalMode\",\"payload\":{\"taskId\":\"1\",\"targetMode\":\"auto_review\",\"expectedBindingEpoch\":\"99\",\"expectedApprovalRevision\":\"1\"}}", .expected = "\"approvalRevision\":null,\"reason\":\"stale_binding\"" },
        .{ .payload = "{\"id\":\"mode-stale-revision\",\"command\":\"metawork.tasks.setApprovalMode\",\"payload\":{\"taskId\":\"1\",\"targetMode\":\"auto_review\",\"expectedBindingEpoch\":\"1\",\"expectedApprovalRevision\":\"99\"}}", .expected = "\"reason\":\"stale_revision\"" },
        .{ .payload = "{\"id\":\"mode-missing\",\"command\":\"metawork.tasks.setApprovalMode\",\"payload\":{\"taskId\":\"99\",\"targetMode\":\"full_access\",\"expectedBindingEpoch\":\"1\",\"expectedApprovalRevision\":\"1\"}}", .expected = "\"reason\":\"task_not_found\"" },
    };
    for (approval_requests) |approval_request| {
        const result = native_dispatcher.dispatch(approval_request.payload, source, &response);
        try std.testing.expect(std.mem.indexOf(u8, result, approval_request.expected) != null);
    }

    var snapshot_storage: [128 * 1024]u8 = undefined;
    const snapshot = try workbench.writeAggregateFixture(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"workspaceRoot\":\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"workspaces\":[{") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        snapshot,
        "\"permissionProfile\":\"approval_required\"",
    ) != null);

    const wake_calls_before_receipt = harness.wake_calls;
    const unseen_completion = native_dispatcher.dispatch(
        "{\"id\":\"completion-seen\",\"command\":\"metawork.tasks.markCompletionSeen\",\"payload\":{\"taskId\":\"1\",\"runId\":\"7\"}}",
        source,
        &response,
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        unseen_completion,
        "\"taskId\":\"1\",\"runId\":\"7\",\"marked\":false",
    ) != null);
    try std.testing.expectEqual(wake_calls_before_receipt, harness.wake_calls);
    const invalid_completion = native_dispatcher.dispatch(
        "{\"id\":\"completion-invalid\",\"command\":\"metawork.tasks.markCompletionSeen\",\"payload\":{\"taskId\":\"1\",\"runId\":\"0\"}}",
        source,
        &response,
    );
    try std.testing.expect(std.mem.indexOf(u8, invalid_completion, "\"handler_failed\"") != null);

    harness.account_result = .acceptedAttempt(57);
    const metask_default = native_dispatcher.dispatch(
        "{\"id\":\"models-refresh\",\"command\":\"metawork.models.refreshCatalog\",\"payload\":{}}",
        source,
        &response,
    );
    // Models commands are routed through the Models host and never manufacture
    // an Account attempt identity.
    try std.testing.expectEqual(@as(usize, 4), harness.account_calls);
    try std.testing.expectEqual(@as(usize, 3), harness.models_calls);
    try std.testing.expect(std.mem.indexOf(
        u8,
        metask_default,
        "\"accepted\":true,\"errorCode\":\"none\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, metask_default, "\"57\"") == null);

    const generation = dispatcher.productDelivery().connectedGeneration().?;
    const unused_grant = try dispatcher.grants.issue(generation, source.window_id, "/tmp");
    var disconnect_storage: [256]u8 = undefined;
    const disconnect = try std.fmt.bufPrint(
        &disconnect_storage,
        "{{\"id\":\"disconnect\",\"command\":\"metawork.events.disconnect\",\"payload\":{{\"generation\":\"{d}\"}}}}",
        .{generation},
    );
    const disconnected = native_dispatcher.dispatch(disconnect, source, &response);
    try std.testing.expect(std.mem.indexOf(u8, disconnected, "\"detached\":true") != null);
    try std.testing.expect(dispatcher.connectedWindow() == null);
    var grant_output: [workspace_path_capacity]u8 = undefined;
    try std.testing.expectError(
        error.WorkspaceNotTrusted,
        dispatcher.grants.consume(
            unused_grant,
            source.window_id,
            generation,
            &grant_output,
        ),
    );
}

test "window chrome environment and action ack match the shared Renderer wire fixture" {
    var fixture = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, @embedFile("window_chrome.fixture"), .{});
    defer fixture.deinit();
    var output: [1024]u8 = undefined;
    const environment = try Dispatcher.encodeWindowChromeEnvironment(&output, 7, .{
        .top = 52,
        .left = 72,
        .bottom = 0,
        .right = 138,
        .buttons_x = 0,
        .buttons_y = 0,
        .buttons_width = 138,
        .buttons_height = 52,
        .renderer_controls = true,
        .maximized = false,
    });
    const expected = try std.json.Stringify.valueAlloc(std.testing.allocator, fixture.value.object.get("environment").?, .{});
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, environment);
    const expected_ack = try std.json.Stringify.valueAlloc(std.testing.allocator, fixture.value.object.get("handled").?, .{});
    defer std.testing.allocator.free(expected_ack);
    try std.testing.expectEqualStrings(expected_ack, try Dispatcher.encodeWindowChromeHandled(&output, 7));
}

test "unified add async jobs join cancellation and freeze their protocol producer" {
    const fixture = @import("lifecycle_fixture");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buffer);
    var store = try product_control.AttachmentFileStore.init(std.testing.io, std.testing.allocator, path_buffer[0..path_len]);
    defer store.deinit();
    var wire = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, @embedFile("attachment_add.fixture"), .{});
    defer wire.deinit();
    var fixture_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer fixture_arena.deinit();
    const Host = struct {
        fn wake(_: ?*anyopaque) anyerror!void {}
        fn emit(_: ?*anyopaque, _: u64, _: []const u8, _: []const u8) anyerror!void {}
        fn timer(_: ?*anyopaque, _: u64, _: u64, _: bool) anyerror!void {}
        fn cancel(_: ?*anyopaque, _: u64) anyerror!void {}
        fn main(_: ?*anyopaque) bool {
            return true;
        }
        fn now(_: ?*anyopaque) u64 {
            return 1;
        }
        fn random(_: ?*anyopaque, out: []u8) bool {
            @memset(out, 7);
            return true;
        }
        fn uniqueRandom(_: ?*anyopaque, out: []u8) bool {
            std.Io.randomSecure(std.testing.io, out) catch return false;
            return true;
        }
        fn picker(_: ?*anyopaque, _: native_sdk.platform.OpenDialogOptions, _: []u8) anyerror!native_sdk.platform.OpenDialogResult {
            return .{ .count = attachment_grant.max_grants + 1, .paths = "/ignored" };
        }
    };
    fixture.fake_core.reset();
    const runtime = try fixture.createTestRuntime(.{ .max_sessions = 1 });
    var configuration = fixture.productControlConfiguration();
    configuration.attachment_store = &store;
    var workbench = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, .{ .max_tasks = 1, .max_runs_per_task = 1, .max_tools_per_run = 1 }, configuration);
    var dispatcher = try Dispatcher.init(std.testing.allocator, &workbench, undefined, undefined, .{
        .attachment_input = .native_paths,
        .context = null,
        .wake_fn = Host.wake,
        .emit_fn = Host.emit,
        .start_timer_fn = Host.timer,
        .cancel_timer_fn = Host.cancel,
        .random_fn = Host.random,
        .now_fn = Host.now,
        .on_main_thread_fn = Host.main,
        .show_open_dialog_fn = Host.picker,
        .canonicalize_directory_fn = undefined,
        .window_chrome_connect_fn = undefined,
        .window_chrome_refresh_fn = undefined,
        .window_chrome_control_fn = undefined,
    }, .{}, 3);
    defer {
        dispatcher.deinit();
        workbench.shutdownExecutor();
        runtime.shutdown() catch unreachable;
        workbench.deinit();
        runtime.deinit();
    }
    const native = dispatcher.register(@import("policy.zig").product(.release));
    const source: native_sdk.bridge.Source = .{ .origin = "zero://app", .window_id = 3 };
    var output: [16 * 1024]u8 = undefined;
    const connect_request = "{\"id\":\"c\",\"command\":\"metawork.events.connect\",\"payload\":{\"contractId\":\"metawork.renderer-bridge\",\"contractRevision\":1}}";
    const connected = native.dispatch(connect_request, source, &output);
    const expected_connect = try std.json.Stringify.valueAlloc(fixture_arena.allocator(), wire.value.object.get("nativePathsConnect").?, .{});
    try std.testing.expect(std.mem.indexOf(u8, connected, expected_connect) != null);
    const Capture = struct {
        response: ?[]u8 = null,
        calls: usize = 0,
        control: *product_control.Runtime,
        allow_other_jobs: bool = false,
        fn receive(context: *anyopaque, _: native_sdk.bridge.Source, response: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (!self.allow_other_jobs) try std.testing.expectEqual(@as(usize, 0), self.control.attachment_lane.active_count);
            if (self.response) |previous| std.testing.allocator.free(previous);
            self.response = try std.testing.allocator.dupe(u8, response);
            self.calls += 1;
        }
        fn deinit(self: *@This()) void {
            if (self.response) |value| std.testing.allocator.free(value);
        }
        fn invoke(self: *@This(), n: native_sdk.bridge.Dispatcher, source_value: native_sdk.bridge.Source, command: []const u8, payload: []const u8) !void {
            const handler = n.async_registry.find(command).?;
            try handler.invoke_fn(handler.context, .{ .request = .{ .id = "add-test", .command = command, .payload = payload }, .source = source_value }, .{ .context = self, .source = source_value, .respond_fn = receive });
        }
        fn wait(self: *@This(), control: *product_control.Runtime, boundary: *Dispatcher, count: usize) !void {
            var attempts: usize = 0;
            while (self.calls < count and attempts < 2000) : (attempts += 1) {
                control.drainAttachmentStagingCompletions(boundary.attachmentStagingSink());
                std.testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
            }
            try std.testing.expectEqual(count, self.calls);
        }
        fn expect(self: *@This(), text: []const u8) !void {
            try std.testing.expect(std.mem.indexOf(u8, self.response.?, text) != null);
        }
    };
    var capture = Capture{ .control = &workbench };
    defer capture.deinit();
    const key1 = "{\"generation\":\"1\",\"batchId\":\"1\"}";
    try capture.invoke(native, source, commands.cancel_attachment_add, key1);
    try capture.expect("\"status\":\"cleaned\"");
    try capture.invoke(native, source, commands.begin_attachment_add, "{\"generation\":\"1\",\"batchId\":\"1\",\"source\":{\"kind\":\"file_bytes\",\"files\":[{\"name\":\"a.txt\",\"sizeBytes\":\"3\"}]}}");
    try capture.expect("stale_transfer");
    const key2 = "{\"generation\":\"1\",\"batchId\":\"2\"}";
    try capture.invoke(native, source, commands.begin_attachment_add, "{\"generation\":\"1\",\"batchId\":\"2\",\"source\":{\"kind\":\"file_bytes\",\"files\":[{\"name\":\"a.txt\",\"sizeBytes\":\"3\"}]}}");
    try std.testing.expectEqual(@as(usize, 2), capture.calls);
    try capture.invoke(native, source, commands.cancel_attachment_add, key2);
    try std.testing.expectEqual(@as(usize, 2), capture.calls);
    try capture.wait(&workbench, &dispatcher, 4);
    try capture.expect("\"status\":\"cleaned\"");
    try std.testing.expectEqual(@as(usize, 0), workbench.attachments.used_bytes);
    var add_wire = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, @embedFile("attachment_add.fixture"), .{});
    defer add_wire.deinit();
    const add_begin = try std.json.Stringify.valueAlloc(fixture_arena.allocator(), add_wire.value.object.get("begin").?, .{});
    const key3 = "{\"generation\":\"1\",\"batchId\":\"3\"}";
    try capture.invoke(native, source, commands.begin_attachment_add, add_begin);
    try capture.wait(&workbench, &dispatcher, 5);
    try capture.expect("accepted");
    dispatcher.platform.attachment_input = .file_bytes;
    const legacy = native.dispatch("{\"id\":\"r\",\"command\":\"metawork.attachments.finishReceive\",\"payload\":{\"generation\":\"1\",\"batchId\":\"3\"}}", source, &output);
    try std.testing.expect(std.mem.indexOf(u8, legacy, "invalid_transfer") != null);
    dispatcher.platform.attachment_input = .native_paths;
    try capture.invoke(native, source, commands.append_attachment_add, "{\"generation\":\"1\",\"batchId\":\"3\",\"fileIndex\":0,\"offset\":\"0\",\"dataBase64\":\"/wBi\"}");
    try capture.wait(&workbench, &dispatcher, 6);
    try capture.expect("accepted");
    try capture.invoke(native, source, commands.finish_attachment_add, key3);
    try capture.wait(&workbench, &dispatcher, 7);
    const expected_ready = try std.json.Stringify.valueAlloc(fixture_arena.allocator(), add_wire.value.object.get("ready").?, .{});
    try capture.expect(expected_ready);
    try capture.invoke(native, source, commands.cancel_attachment_add, key3);
    try capture.expect("\"released\":true");
    try std.testing.expectEqual(@as(usize, 0), workbench.attachments.used_bytes);
    dispatcher.platform.attachment_input = .file_bytes;
    try capture.invoke(native, .{ .origin = "zero://app", .window_id = 4 }, commands.cancel_attachment_add, key3);
    try capture.expect("EventWindowMismatch");
    try capture.invoke(native, source, commands.begin_attachment_add, "{\"generation\":\"1\",\"batchId\":\"4\",\"source\":{\"kind\":\"native_paths\",\"paths\":[\"C:/tmp/a.txt\"]}}");
    try capture.expect("InvalidBridgePayload");
    try std.testing.expectEqual(@as(u64, 3), dispatcher.receive_high_water);
    try std.testing.expectEqual(@as(usize, 0), workbench.attachments.used_bytes);
    // All three source adapters reject an oversized batch before any I/O.
    const too_many_paths = [_][]const u8{"/ignored"} ** (attachment_grant.max_grants + 1);
    const TooManyFile = struct { name: []const u8 = "a.txt", sizeBytes: []const u8 = "3" };
    const too_many_files = [_]TooManyFile{.{}} ** (attachment_grant.max_grants + 1);
    const inputs = [_][]const u8{
        try std.json.Stringify.valueAlloc(fixture_arena.allocator(), .{ .generation = "1", .batchId = "5", .source = .{ .kind = "picker" } }, .{}),
        try std.json.Stringify.valueAlloc(fixture_arena.allocator(), .{ .generation = "1", .batchId = "6", .source = .{ .kind = "native_paths", .paths = too_many_paths } }, .{}),
        try std.json.Stringify.valueAlloc(fixture_arena.allocator(), .{ .generation = "1", .batchId = "7", .source = .{ .kind = "file_bytes", .files = too_many_files } }, .{}),
    };
    for (inputs, 0..) |input, index| {
        dispatcher.platform.attachment_input = if (index == 1) .native_paths else .file_bytes;
        try capture.invoke(native, source, commands.begin_attachment_add, input);
        try capture.expect("\"reason\":\"too_many_files\"");
        try std.testing.expect(workbench.attachments.preparing == null);
        try std.testing.expect(workbench.attachment_io == null);
        try std.testing.expectEqual(@as(usize, 0), workbench.attachments.used_bytes);
        var key_buffer: [80]u8 = undefined;
        const cancel_key = try std.fmt.bufPrint(&key_buffer, "{{\"generation\":\"1\",\"batchId\":\"{d}\"}}", .{index + 5});
        try capture.invoke(native, source, commands.cancel_attachment_add, cancel_key);
        try capture.expect("\"status\":\"cleaned\"");
        try capture.expect("\"released\":false");
        try std.testing.expect(dispatcher.receive_active == null);
    }
    // Retain three ready batches, then cancel a fourth without draining its job.
    dispatcher.platform.attachment_input = .file_bytes;
    dispatcher.platform.random_fn = Host.uniqueRandom;
    for (8..11) |batch| {
        var begin_buffer: [220]u8 = undefined;
        const begin = try std.fmt.bufPrint(&begin_buffer, "{{\"generation\":\"1\",\"batchId\":\"{d}\",\"source\":{{\"kind\":\"file_bytes\",\"files\":[{{\"name\":\"file{d}.txt\",\"sizeBytes\":\"3\"}}]}}}}", .{ batch, batch });
        var expected_calls = capture.calls + 1;
        try capture.invoke(native, source, commands.begin_attachment_add, begin);
        try capture.wait(&workbench, &dispatcher, expected_calls);
        try capture.expect("\"status\":\"accepted\"");
        var append_buffer: [180]u8 = undefined;
        const append = try std.fmt.bufPrint(&append_buffer, "{{\"generation\":\"1\",\"batchId\":\"{d}\",\"fileIndex\":0,\"offset\":\"0\",\"dataBase64\":\"YWJj\"}}", .{batch});
        expected_calls = capture.calls + 1;
        try capture.invoke(native, source, commands.append_attachment_add, append);
        try capture.wait(&workbench, &dispatcher, expected_calls);
        var key_buffer: [80]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buffer, "{{\"generation\":\"1\",\"batchId\":\"{d}\"}}", .{batch});
        expected_calls = capture.calls + 1;
        try capture.invoke(native, source, commands.finish_attachment_add, key);
        try capture.wait(&workbench, &dispatcher, expected_calls);
        try capture.expect("\"status\":\"ready\"");
    }
    var debt_path_buffer: [80]u8 = undefined;
    var debt_path: ?[]const u8 = null;
    var untouched_id: u64 = 0;
    for (workbench.attachments.slots) |slot| if (slot) |entry| {
        if (std.mem.eql(u8, entry.display_name, "file9.txt")) {
            // A directory at the original path deterministically denies deletion.
            debt_path = try std.fmt.bufPrint(&debt_path_buffer, "0/{s}.txt", .{entry.file.name});
            try store.deleteChecked(entry.file);
            try store.root.createDir(std.testing.io, debt_path.?, .default_dir);
        }
        if (std.mem.eql(u8, entry.display_name, "file10.txt")) untouched_id = entry.id;
    };
    try std.testing.expect(untouched_id != 0);
    try std.testing.expect(debt_path != null);
    const calls_before_cancel = capture.calls;
    try capture.invoke(native, source, commands.begin_attachment_add, "{\"generation\":\"1\",\"batchId\":\"11\",\"source\":{\"kind\":\"file_bytes\",\"files\":[{\"name\":\"pending.txt\",\"sizeBytes\":\"3\"}]}}");
    const pending_key = "{\"generation\":\"1\",\"batchId\":\"11\"}";
    try capture.invoke(native, source, commands.cancel_attachment_add, pending_key);
    try std.testing.expect(dispatcher.add_cancel != null);
    try std.testing.expectEqual(calls_before_cancel, capture.calls);
    var other = Capture{ .control = &workbench, .allow_other_jobs = true };
    defer other.deinit();
    try other.invoke(native, source, commands.cancel_attachment_add, pending_key);
    try other.expect("AttachmentCancelBusy");
    try std.testing.expect(dispatcher.add_cancel != null);
    try other.invoke(native, source, commands.begin_attachment_add, "{\"generation\":\"1\",\"batchId\":\"12\",\"source\":{\"kind\":\"file_bytes\",\"files\":[{\"name\":\"busy.txt\",\"sizeBytes\":\"3\"}]}}");
    try other.expect("input_busy");
    try other.invoke(native, source, commands.cancel_attachment_add, "{\"generation\":\"1\",\"batchId\":\"12\"}");
    try other.expect("\"status\":\"cleaned\"");
    try other.expect("\"released\":false");
    try other.invoke(native, source, commands.cancel_attachment_add, "{\"generation\":\"1\",\"batchId\":\"8\"}");
    try other.expect("\"released\":true");
    try other.invoke(native, source, commands.cancel_attachment_add, "{\"generation\":\"1\",\"batchId\":\"9\"}");
    try other.expect("\"status\":\"cleanup_failed\"");
    try other.invoke(native, source, commands.cancel_attachment_add, "{\"generation\":\"1\",\"batchId\":\"9\"}");
    try other.expect("\"status\":\"cleanup_failed\"");
    try std.testing.expectEqual(@as(usize, 9), workbench.attachments.used_bytes);
    try std.testing.expectEqual(@as(usize, 1), workbench.attachments.cleanupDebt().count);
    try std.testing.expect(workbench.attachments.descriptorFor(untouched_id) != null);
    try std.testing.expectEqual(@as(usize, 1), workbench.attachment_lane.active_count);
    try std.testing.expectEqual(calls_before_cancel, capture.calls);

    // Replacement resets batch allocation; an equal number is a distinct key.
    const reconnected = native.dispatch(connect_request, source, &output);
    try std.testing.expect(std.mem.indexOf(u8, reconnected, "\"generation\":\"2\"") != null);
    try other.invoke(native, source, commands.begin_attachment_add, "{\"generation\":\"2\",\"batchId\":\"11\",\"source\":{\"kind\":\"file_bytes\",\"files\":[{\"name\":\"busy.txt\",\"sizeBytes\":\"3\"}]}}");
    try other.expect("input_busy");
    try other.invoke(native, source, commands.cancel_attachment_add, "{\"generation\":\"2\",\"batchId\":\"11\"}");
    try other.expect("\"status\":\"cleaned\"");
    try other.expect("\"released\":false");
    try other.invoke(native, source, commands.cancel_attachment_add, "{\"generation\":\"2\",\"batchId\":\"1\"}");
    try other.expect("\"released\":false");
    try std.testing.expectEqual(@as(u64, 1), dispatcher.add_cancel.?.generation);
    try std.testing.expectEqual(@as(u64, 11), dispatcher.add_cancel.?.batch_id);
    try std.testing.expectEqual(@as(usize, 6), workbench.attachments.used_bytes);
    try capture.wait(&workbench, &dispatcher, calls_before_cancel + 2);
    try capture.expect("\"status\":\"cleaned\"");
    try std.testing.expect(dispatcher.add_cancel == null);
    try std.testing.expect(workbench.attachment_io == null);
    try std.testing.expectEqual(@as(usize, 3), workbench.attachments.used_bytes);
    try other.invoke(native, source, commands.cancel_attachment_add, "{\"generation\":\"2\",\"batchId\":\"9\"}");
    try other.expect("\"released\":false");
    try std.testing.expectEqual(@as(usize, 1), workbench.attachments.cleanupDebt().count);
    try store.root.deleteDir(std.testing.io, debt_path.?);
    try std.testing.expect(workbench.attachments.retryCleanup());
    try std.testing.expectEqual(@as(usize, 0), workbench.attachments.used_bytes);
    // Once the old job settles, a new batch can start and join its own cancel.
    const before_new = capture.calls;
    try capture.invoke(native, source, commands.begin_attachment_add, "{\"generation\":\"2\",\"batchId\":\"12\",\"source\":{\"kind\":\"file_bytes\",\"files\":[{\"name\":\"new.txt\",\"sizeBytes\":\"3\"}]}}");
    try capture.invoke(native, source, commands.cancel_attachment_add, "{\"generation\":\"2\",\"batchId\":\"12\"}");
    try capture.wait(&workbench, &dispatcher, before_new + 2);
    try capture.expect("\"status\":\"cleaned\"");
    try std.testing.expectEqual(@as(usize, 0), workbench.attachments.used_bytes);
    workbench.attachment_lane.stopAdmission();
    try capture.invoke(native, source, commands.begin_attachment_add, "{\"generation\":\"2\",\"batchId\":\"99\",\"source\":{\"kind\":\"file_bytes\",\"files\":[{\"name\":\"a.txt\",\"sizeBytes\":\"3\"}]}}");
    try capture.expect("shutting_down");
    try std.testing.expectEqual(@as(u64, 99), dispatcher.receive_active.?.batch_id);
    try std.testing.expectEqual(@as(usize, 0), workbench.attachments.used_bytes);
    try capture.invoke(native, source, commands.cancel_attachment_add, "{\"generation\":\"2\",\"batchId\":\"99\"}");
    try capture.expect("\"status\":\"cleaned\"");
    try std.testing.expect(dispatcher.receive_active == null);
}

test "active input dispatch accepts FIFO without waiting for responses and scopes identity" {
    const fixture = @import("lifecycle_fixture");
    const Host = struct {
        fn wake(_: ?*anyopaque) anyerror!void {}
        fn emit(_: ?*anyopaque, _: u64, _: []const u8, _: []const u8) anyerror!void {}
        fn timer(_: ?*anyopaque, _: u64, _: u64, _: bool) anyerror!void {}
        fn cancel(_: ?*anyopaque, _: u64) anyerror!void {}
        fn main(_: ?*anyopaque) bool {
            return true;
        }
        fn now(_: ?*anyopaque) u64 {
            return 1;
        }
        fn random(_: ?*anyopaque, out: []u8) bool {
            @memset(out, 7);
            return true;
        }
        fn dispatch(n: native_sdk.bridge.Dispatcher, source: native_sdk.bridge.Source, output: []u8, command: []const u8, payload: []const u8) []const u8 {
            var bytes: [2048]u8 = undefined;
            const request = std.fmt.bufPrint(&bytes, "{{\"id\":\"q\",\"command\":\"{s}\",\"payload\":{s}}}", .{ command, payload }) catch unreachable;
            return n.dispatch(request, source, output);
        }
    };
    fixture.fake_core.reset();
    fixture.fake_core.input_enabled = true;
    fixture.fake_core.setNextPlan(.ui_wait);
    const runtime = try fixture.createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        fixture.shutdownTestComposition(runtime) catch unreachable;
        fixture.deinitTestComposition(runtime);
    }
    var control = try product_control.Runtime.init(std.testing.allocator, std.testing.io, runtime, .{ .worker_count = 1, .queue_capacity = 1, .max_tasks = 1, .max_runs_per_task = 2, .max_tools_per_run = 1 }, fixture.productControlConfiguration());
    defer control.deinit();
    try fixture.installProductControlExecution(&control);
    var input = fixture.productControlTaskInput();
    input.approval_mode = .manual;
    const task_id = try control.createTask(input);
    _ = try control.runTask(task_id, .{ .text = "initial" });
    try fixture.waitProductControlSnapshot(&control, "\"currentRunPhase\":\"waiting_ui\"");
    var dispatcher = try Dispatcher.init(std.testing.allocator, &control, undefined, undefined, .{
        .context = null,
        .wake_fn = Host.wake,
        .emit_fn = Host.emit,
        .start_timer_fn = Host.timer,
        .cancel_timer_fn = Host.cancel,
        .random_fn = Host.random,
        .now_fn = Host.now,
        .on_main_thread_fn = Host.main,
        .show_open_dialog_fn = undefined,
        .canonicalize_directory_fn = undefined,
        .window_chrome_connect_fn = undefined,
        .window_chrome_refresh_fn = undefined,
        .window_chrome_control_fn = undefined,
    }, .{}, 3);
    defer dispatcher.deinit();
    const native = dispatcher.register(@import("policy.zig").product(.release));
    const source: native_sdk.bridge.Source = .{ .origin = "zero://app", .window_id = 3 };
    var output: [16 * 1024]u8 = undefined;
    var wire = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, @embedFile("active_input.fixture"), .{});
    defer wire.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const payload = try std.json.Stringify.valueAlloc(arena.allocator(), wire.value.object.get("send").?, .{});
    const task = control.task_runtime.find(task_id).?;
    _ = Host.dispatch(native, source, &output, commands.send_input, payload);
    try std.testing.expect(task.durable.runs[0].?.additional_inputs[0] == null);
    _ = Host.dispatch(native, source, &output, commands.connect, "{\"contractId\":\"metawork.renderer-bridge\",\"contractRevision\":1}");
    _ = Host.dispatch(native, .{ .origin = "zero://app", .window_id = 4 }, &output, commands.send_input, payload);
    try std.testing.expect(task.durable.runs[0].?.additional_inputs[0] == null);
    var small: [32]u8 = undefined;
    _ = Host.dispatch(native, source, &small, commands.send_input, payload);
    try std.testing.expectEqual(.submitted, task.send_input_result.?.outcome);
    try std.testing.expectEqualStrings("input-1", task.send_input_result.?.operationId());
    try std.testing.expectEqual(@as(?u32, 1), task.send_input_result.?.sequence);
    var snapshot_buffer: [64 * 1024]u8 = undefined;
    const snapshot = try control.writeAggregateFixture(&snapshot_buffer);
    var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), snapshot, .{});
    defer parsed.deinit();
    const projected_task = parsed.value.object.get("tasks").?.array.items[0].object;
    try std.testing.expect(projected_task.get("sendInputResult") == null);
    const projected_input = projected_task.get("runs").?.array.items[0].object.get("additionalInputs").?.array.items[0].object;
    const submission = projected_input.get("submission").?.object;
    try std.testing.expectEqualStrings("input-1", submission.get("operationId").?.string);
    try std.testing.expectEqual(wire.value.object.get("history").?.object.get("afterOutputCount").?.integer, projected_input.get("afterOutputCount").?.integer);
    // Dispatch through the registered Native Bridge, without observing A's
    // lost response or B's response before delivering C. Response observation
    // does not gate or reorder the main-thread acceptance transactions.
    var response_b: [4096]u8 = undefined;
    const b = Host.dispatch(native, source, &response_b, commands.send_input, "{\"operationId\":\"input-2\",\"taskId\":\"1\",\"input\":{\"kind\":\"text\",\"text\":\"B\"}}");
    const c = Host.dispatch(native, source, &output, commands.send_input, "{\"operationId\":\"input-3\",\"taskId\":\"1\",\"input\":{\"kind\":\"text\",\"text\":\"C\"}}");
    try std.testing.expect(std.mem.indexOf(u8, c, "\"outcome\":\"accepted\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, b, "\"outcome\":\"accepted\"") != null);
    const run = task.durable.runs[0].?;
    for ([_][]const u8{ "input-1", "input-2", "input-3" }, 0..) |op, index| {
        try std.testing.expectEqualStrings(op, run.additional_inputs[index].?.submission.?.operationId());
        try std.testing.expectEqual(@as(?u32, @intCast(index + 1)), run.additional_inputs[index].?.sequence);
    }
    try std.testing.expect(task.durable.runs[1] == null);
}

test "Product view Dispatcher freezes and transports a complete multi-chunk snapshot through the native registry" {
    const Host = struct {
        fn wake(_: ?*anyopaque) !void {}
        fn emit(_: ?*anyopaque, _: u64, _: []const u8, _: []const u8) !void {}
        fn timer(_: ?*anyopaque, _: u64, _: u64, _: bool) !void {}
        fn cancel(_: ?*anyopaque, _: u64) !void {}
        fn main(_: ?*anyopaque) bool {
            return true;
        }
        fn now(_: ?*anyopaque) u64 {
            return 1;
        }
        fn random(_: ?*anyopaque, out: []u8) bool {
            @memset(out, 7);
            return true;
        }
    };
    const control = try std.testing.allocator.create(product_control.Runtime);
    defer std.testing.allocator.destroy(control);
    control.* = try product_control.TestSupport.maximumFixture();
    defer control.deinit();
    var dispatcher = try Dispatcher.init(std.testing.allocator, control, undefined, undefined, .{
        .context = null,
        .wake_fn = Host.wake,
        .emit_fn = Host.emit,
        .start_timer_fn = Host.timer,
        .cancel_timer_fn = Host.cancel,
        .random_fn = Host.random,
        .now_fn = Host.now,
        .on_main_thread_fn = Host.main,
        .show_open_dialog_fn = undefined,
        .canonicalize_directory_fn = undefined,
        .window_chrome_connect_fn = undefined,
        .window_chrome_refresh_fn = undefined,
        .window_chrome_control_fn = undefined,
    }, .{}, 3);
    defer dispatcher.deinit();
    const native = dispatcher.register(@import("policy.zig").product(.release));
    const source: native_sdk.bridge.Source = .{ .origin = "zero://app", .window_id = 3 };
    const response = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(response);
    const connected = native.dispatch("{\"id\":\"c\",\"command\":\"metawork.events.connect\",\"payload\":{\"contractId\":\"metawork.renderer-bridge\",\"contractRevision\":1}}", source, response);
    try std.testing.expect(std.mem.indexOf(u8, connected, "\"accepted\":true") != null);
    const begin = "{\"id\":\"s\",\"command\":\"metawork.workbench.snapshot\",\"payload\":{\"taskId\":\"1\",\"beforeRunId\":\"5\",\"runLimit\":4,\"management\":\"none\",\"search\":false,\"searchQuery\":\"\",\"searchCursor\":null,\"receipts\":[],\"known\":{\"securityEpoch\":\"0\",\"versions\":{\"context\":\"0\",\"workspaces\":\"0\",\"taskIndex\":\"0\",\"taskPage\":\"0\",\"historyPage\":\"0\",\"management\":\"0\",\"searchIndex\":\"0\"}}}}";
    var descriptor = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, native.dispatch(begin, source, response), .{});
    defer descriptor.deinit();
    var result = descriptor.value.object.get("result").?.object;
    const id = try std.fmt.parseInt(u64, result.get("snapshotId").?.string, 10);
    var preparation_request: [256]u8 = undefined;
    var preparation_steps: usize = 0;
    while (result.contains("phase")) {
        try std.testing.expect(preparation_steps < @import("snapshot_contract.zig").max_preparation_steps);
        preparation_steps += 1;
        const request = try std.fmt.bufPrint(&preparation_request, "{{\"id\":\"prepare\",\"command\":\"metawork.workbench.snapshot\",\"payload\":{{\"preparingSnapshotId\":\"{d}\"}}}}", .{id});
        descriptor.deinit();
        descriptor = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, native.dispatch(request, source, response), .{});
        result = descriptor.value.object.get("result").?.object;
        try std.testing.expectEqual(id, try std.fmt.parseInt(u64, result.get("snapshotId").?.string, 10));
    }
    const bytes: usize = @intCast(result.get("bytes").?.integer);
    try std.testing.expect(bytes > product_delivery.snapshot_chunk_bytes);
    try std.testing.expectEqual(@as(usize, 0), control.view_read.produced);
    const assembled = try std.testing.allocator.alloc(u8, bytes);
    defer std.testing.allocator.free(assembled);
    var request_storage: [256]u8 = undefined;
    var offset: usize = 0;
    while (offset < bytes) : (offset += product_delivery.snapshot_chunk_bytes) {
        const request = try std.fmt.bufPrint(&request_storage, "{{\"id\":\"chunk\",\"command\":\"metawork.workbench.snapshot.chunk\",\"payload\":{{\"snapshotId\":\"{d}\",\"offset\":\"{d}\"}}}}", .{ id, offset });
        if (offset == 0) {
            const rejected = native.dispatch(request, .{ .origin = source.origin, .window_id = 99 }, response);
            try std.testing.expect(std.mem.indexOf(u8, rejected, "\"handler_failed\"") != null);
            try std.testing.expectEqual(@as(usize, 0), control.view_read.produced);
        }
        var chunk = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, native.dispatch(request, source, response), .{});
        defer chunk.deinit();
        const fields = chunk.value.object.get("result").?.object;
        const data = fields.get("data").?.string;
        const length = @min(product_delivery.snapshot_chunk_bytes, bytes - offset);
        try std.testing.expectEqual(length, try std.base64.standard.Decoder.calcSizeForSlice(data));
        try std.base64.standard.Decoder.decode(assembled[offset..][0..length], data);
    }
    try std.testing.expect(std.unicode.utf8ValidateSlice(assembled));
    var decoded = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, assembled, .{});
    defer decoded.deinit();
    try std.testing.expectEqual(@as(usize, 4), decoded.value.object.get("historyPage").?.object.get("runs").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 50), decoded.value.object.get("taskIndex").?.array.items.len);
    try std.testing.expectEqual(bytes, control.view_read.produced);
    dispatcher.breakConnection();
    try std.testing.expectEqual(@as(u64, 0), control.view_read.id);
}

test "Output action Bridge binds fixture identities and refuses replay cancellation and disconnected reveal" {
    const Host = struct {
        fn wake(_: ?*anyopaque) !void {}
        fn emit(_: ?*anyopaque, _: native_sdk.platform.WindowId, _: []const u8, _: []const u8) !void {}
        fn timer(_: ?*anyopaque, _: u64, _: u64, _: bool) !void {}
        fn cancel(_: ?*anyopaque, _: u64) !void {}
        fn now(_: ?*anyopaque) u64 {
            return 1;
        }
        fn main(_: ?*anyopaque) bool {
            return true;
        }
    };
    const Capture = struct {
        response: ?[]u8 = null,
        count: usize = 0,
        fn receive(context: *anyopaque, _: native_sdk.bridge.Source, bytes: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.response) |old| std.testing.allocator.free(old);
            self.response = try std.testing.allocator.dupe(u8, bytes);
            self.count += 1;
        }
        fn invoke(self: *@This(), native: native_sdk.bridge.Dispatcher, payload: []const u8, window: u64) !void {
            const handler = native.async_registry.find(commands.output_action).?;
            const source: native_sdk.bridge.Source = .{ .origin = "zero://app", .window_id = window };
            try handler.invoke_fn(handler.context, .{ .request = .{ .id = "output-test", .command = commands.output_action, .payload = payload }, .source = source }, .{ .context = self, .source = source, .respond_fn = receive });
        }
        fn wait(self: *@This(), control: *product_control.Runtime, boundary: *Dispatcher, count: usize) !void {
            for (0..5000) |_| {
                _ = boundary.onTimer(output_timer_id);
                if (self.count >= count) return;
                try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
            }
            _ = control;
            return error.TestTimeout;
        }
    };
    var effect: product_control.TestSupport.OutputFileEffect = .{ .main_thread_id = std.Thread.getCurrentId(), .workspace_id = 2 };
    var capture: Capture = .{};
    defer if (capture.response) |bytes| std.testing.allocator.free(bytes);
    var control = try product_control.TestSupport.filePreviewFixture("/tmp/metawork-test");
    try product_control.TestSupport.recordDeliveredOutputFixture(&control);
    defer control.deinit();
    product_control.TestSupport.bindOutputFileEffect(&control, &effect);
    var boundary = try Dispatcher.init(std.testing.allocator, &control, undefined, undefined, .{ .context = null, .wake_fn = Host.wake, .emit_fn = Host.emit, .start_timer_fn = Host.timer, .cancel_timer_fn = Host.cancel, .now_fn = Host.now, .on_main_thread_fn = Host.main, .show_open_dialog_fn = undefined, .canonicalize_directory_fn = undefined, .window_chrome_connect_fn = undefined, .window_chrome_refresh_fn = undefined, .window_chrome_control_fn = undefined }, .{}, 3);
    defer boundary.deinit();
    defer {
        control.shutdownOutputChecks();
        control.drainOutputChecks(boundary.outputCheckSink());
        boundary.settleOutputActionsForShutdown();
    }
    _ = try boundary.delivery.connect(3, boundary.transport());
    const native = boundary.register(@import("policy.zig").product(.release));
    var fixture = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, @import("contract_fixture").output_action, .{});
    defer fixture.deinit();
    const request = try std.json.Stringify.valueAlloc(std.testing.allocator, fixture.value.object.get("request").?, .{});
    defer std.testing.allocator.free(request);
    try capture.invoke(native, request, 4);
    try std.testing.expect(std.mem.indexOf(u8, capture.response.?, "\"error\"") != null);
    try std.testing.expectEqual(@as(usize, 0), effect.prepares);
    try capture.invoke(native, request, 3);
    try capture.wait(&control, &boundary, 2);
    var response = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, capture.response.?, .{});
    defer response.deinit();
    const result = try std.json.Stringify.valueAlloc(std.testing.allocator, response.value.object.get("result").?, .{});
    defer std.testing.allocator.free(result);
    const expected = try std.json.Stringify.valueAlloc(std.testing.allocator, fixture.value.object.get("result").?, .{});
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, result);
    try capture.invoke(native, request, 3);
    try std.testing.expect(std.mem.indexOf(u8, capture.response.?, "\"error\"") != null);
    try std.testing.expectEqual(@as(usize, 1), effect.prepares);
    const reveal = "{\"generation\":\"1\",\"operationId\":\"2\",\"taskId\":\"3\",\"runId\":\"7\",\"outputId\":\"03030303030303030303030303030303\",\"action\":\"reveal\"}";
    effect.blocked.store(true, .release);
    try capture.invoke(native, reveal, 3);
    var output: [256]u8 = undefined;
    const cancel = native.registry.find(commands.output_action_cancel).?;
    const ack = try cancel.invoke_fn(cancel.context, .{ .request = .{ .id = "cancel-output", .command = commands.output_action_cancel, .payload = "{\"generation\":\"1\",\"operationId\":\"2\"}" }, .source = .{ .origin = "zero://app", .window_id = 3 } }, &output);
    try std.testing.expect(std.mem.indexOf(u8, ack, "\"cancelled\":true") != null);
    try capture.wait(&control, &boundary, 4);
    try std.testing.expect(std.mem.indexOf(u8, capture.response.?, "\"state\":\"cancelled\"") != null);
    try std.testing.expectEqual(@as(usize, 0), effect.reveals);
    const third = "{\"generation\":\"1\",\"operationId\":\"3\",\"taskId\":\"3\",\"runId\":\"7\",\"outputId\":\"03030303030303030303030303030303\",\"action\":\"reveal\"}";
    effect.blocked.store(false, .release);
    try capture.invoke(native, third, 3);
    try capture.wait(&control, &boundary, 5);
    try std.testing.expect(std.mem.indexOf(u8, capture.response.?, "\"state\":\"revealed\"") != null);
    try std.testing.expectEqual(@as(usize, 1), effect.reveals);
    var save_effect: product_control.TestSupport.OutputSaveEffect = .{ .main_thread_id = std.Thread.getCurrentId() };
    save_effect.publishing_blocked.store(true, .release);
    defer save_effect.publishing_blocked.store(false, .release);
    product_control.TestSupport.bindOutputSaveEffect(&control, &save_effect);
    var save_wire = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, @import("contract_fixture").output_save, .{});
    defer save_wire.deinit();
    const save_request = try std.json.Stringify.valueAlloc(std.testing.allocator, save_wire.value.object.get("request").?, .{});
    defer std.testing.allocator.free(save_request);
    try capture.invoke(native, save_request, 3);
    for (0..5000) |_| {
        _ = boundary.onTimer(output_timer_id);
        if (save_effect.publish_entered.load(.acquire)) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    } else return error.TestTimeout;
    const late_cancel = try cancel.invoke_fn(cancel.context, .{ .request = .{ .id = "cancel-save", .command = commands.output_action_cancel, .payload = "{\"generation\":\"1\",\"operationId\":\"4\"}" }, .source = .{ .origin = "zero://app", .window_id = 3 } }, &output);
    const expected_cancel = try std.json.Stringify.valueAlloc(std.testing.allocator, save_wire.value.object.get("cancelTooLate").?, .{});
    defer std.testing.allocator.free(expected_cancel);
    try std.testing.expectEqualStrings(expected_cancel, late_cancel);
    save_effect.publishing_blocked.store(false, .release);
    try capture.wait(&control, &boundary, 6);
    var saved = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, capture.response.?, .{});
    defer saved.deinit();
    const actual_save = try std.json.Stringify.valueAlloc(std.testing.allocator, saved.value.object.get("result").?, .{});
    defer std.testing.allocator.free(actual_save);
    const expected_save = try std.json.Stringify.valueAlloc(std.testing.allocator, save_wire.value.object.get("result").?, .{});
    defer std.testing.allocator.free(expected_save);
    try std.testing.expectEqualStrings(expected_save, actual_save);
    try std.testing.expectEqual(@as(usize, 1), save_effect.published.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), save_effect.releases);
    const fourth = "{\"generation\":\"1\",\"operationId\":\"5\",\"taskId\":\"3\",\"runId\":\"7\",\"outputId\":\"03030303030303030303030303030303\",\"action\":\"reveal\"}";
    effect.blocked.store(true, .release);
    try capture.invoke(native, fourth, 3);
    boundary.breakConnection();
    try capture.wait(&control, &boundary, 7);
    try std.testing.expect(std.mem.indexOf(u8, capture.response.?, "\"state\":\"cancelled\"") != null);
    try std.testing.expectEqual(@as(usize, 1), effect.reveals);
    try std.testing.expect(!control.hasOutputChecks());
}

test "Product view Session pressure rejection fixture preserves exact reason and blocking Task" {
    const allocator = std.testing.allocator;
    const fixture = try std.json.parseFromSlice(std.json.Value, allocator, @import("contract_fixture").session_pressure, .{});
    defer fixture.deinit();
    var output: [1024]u8 = undefined;
    const create = try std.json.Stringify.valueAlloc(allocator, fixture.value.object.get("create").?, .{});
    defer allocator.free(create);
    try std.testing.expectEqualStrings(create, try encodeTaskCreateResult(&output, false, null, null, null, "session_close_failed", 7));
    const restore = try std.json.Stringify.valueAlloc(allocator, fixture.value.object.get("restore").?, .{});
    defer allocator.free(restore);
    try std.testing.expectEqualStrings(restore, try encodeTaskRestoreResult(&output, false, 3, null, "session_close_failed", 7));
    try std.testing.expectError(error.InvalidSessionPressureResult, encodeTaskCreateResult(&output, false, null, null, null, "session_close_failed", null));
    try std.testing.expectError(error.InvalidSessionPressureResult, encodeTaskRestoreResult(&output, false, 3, null, "session_releasing", 7));
    try std.testing.expectEqualStrings("session_releasing", taskCreateRejection(error.SessionReleasing).?);
    try std.testing.expectEqualStrings("session_close_failed", taskRestoreRejection(error.SessionReleaseFailed).?);
    try std.testing.expectEqualStrings("session_capacity", taskCreateRejection(error.SessionCapacity).?);
}
