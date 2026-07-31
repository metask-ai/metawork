//! Concrete Renderer command boundary. This module owns command registration,
//! authority checks, connection/grant state, payload decoding, response
//! encoding, and the only Bridge -> Workbench product calls.

const std = @import("std");
const native_sdk = @import("native_sdk");
const account_contract = @import("metawork_account_contract");
const workbench_api = @import("metawork_workbench");
const commands = @import("commands.zig");
const handlers = @import("handlers.zig");
const callback_gate = @import("callback_gate.zig");
const product_delivery = @import("product_delivery.zig");
const workspace_grant = @import("workspace_grant.zig");

const product_handler_count = commands.product.len;
const workspace_path_capacity = workspace_grant.max_path_bytes;
const event_name = "metawork:host-signal";

const AccountSelectionKind = enum { api_key, model };
pub const WindowControl = enum { minimize, toggle_maximize, close };

pub const Platform = struct {
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
    show_message_dialog_fn: *const fn (
        ?*anyopaque,
        native_sdk.platform.MessageDialogOptions,
    ) anyerror!native_sdk.platform.MessageDialogResult,
    begin_window_drag_fn: *const fn (
        ?*anyopaque,
        native_sdk.platform.WindowId,
        u8,
    ) anyerror!void,
    window_control_fn: *const fn (
        ?*anyopaque,
        native_sdk.platform.WindowId,
        WindowControl,
    ) anyerror!void,
    now_fn: *const fn (?*anyopaque) u64,
    on_main_thread_fn: *const fn (?*anyopaque) bool,
};

pub const AutomationAuthority = struct {
    context: ?*anyopaque = null,
    active_fn: *const fn (?*anyopaque) bool = inactive,
    workspace_root_fn: *const fn (?*anyopaque) ?[]const u8 = noAutomationWorkspace,

    fn active(self: AutomationAuthority) bool {
        return self.active_fn(self.context);
    }

    fn workspaceRoot(self: AutomationAuthority) ?[]const u8 {
        return self.workspace_root_fn(self.context);
    }
};

pub const Dispatcher = struct {
    workbench: ?*workbench_api.Workbench,
    account_commands: account_contract.AccountCommandSink,
    platform: Platform,
    automation: AutomationAuthority,
    bootstrap_window_id: native_sdk.platform.WindowId,
    delivery: product_delivery.Delivery,
    callbacks: callback_gate.State = .{},
    grants: workspace_grant.State = .{},
    sequence: u64 = 0,
    acknowledged_sequence: u64 = 0,
    registered_handlers: [product_handler_count]native_sdk.bridge.Handler = undefined,

    pub fn init(
        allocator: std.mem.Allocator,
        workbench: *workbench_api.Workbench,
        account_commands: account_contract.AccountCommandSink,
        platform: Platform,
        automation: AutomationAuthority,
        bootstrap_window_id: native_sdk.platform.WindowId,
    ) std.mem.Allocator.Error!Dispatcher {
        std.debug.assert(bootstrap_window_id != 0);
        return .{
            .workbench = workbench,
            .account_commands = account_commands,
            .platform = platform,
            .automation = automation,
            .bootstrap_window_id = bootstrap_window_id,
            .delivery = try product_delivery.Delivery.init(allocator),
        };
    }

    pub fn deinit(self: *Dispatcher) void {
        self.callbacks.stopIngress();
        self.callbacks.assertQuiescent();
        self.delivery.breakConnection(self.transport());
        self.grants.invalidate();
        self.workbench = null;
        self.delivery.deinitOwnedBuffers();
        self.* = undefined;
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
            .{ .name = commands.window_begin_drag, .function = beginWindowDrag },
            .{ .name = commands.window_control, .function = controlWindow },
            .{ .name = commands.choose_workspace, .function = chooseWorkspace },
            .{ .name = commands.select_workspace, .function = selectWorkspace },
            .{ .name = commands.remove_workspace, .function = removeWorkspace },
            .{ .name = commands.refresh_workspace_skill_catalog, .function = refreshWorkspaceSkillCatalog },
            .{ .name = commands.refresh_skill_catalog, .function = refreshSkillCatalog },
            .{ .name = commands.snapshot, .function = beginSnapshot },
            .{ .name = commands.snapshot_chunk, .function = fetchSnapshotChunk },
            .{ .name = commands.account_begin_login, .function = accountBeginLogin },
            .{ .name = commands.account_reopen_login, .function = accountReopenLogin },
            .{ .name = commands.account_reauthenticate, .function = accountReauthenticate },
            .{ .name = commands.account_cancel_operation, .function = accountCancelOperation },
            .{ .name = commands.account_refresh_catalog, .function = accountRefreshCatalog },
            .{ .name = commands.account_select_api_key, .function = accountSelectApiKey },
            .{ .name = commands.account_select_model, .function = accountSelectModel },
            .{ .name = commands.account_logout, .function = accountLogout },
            .{ .name = commands.create_task, .function = createTask },
            .{ .name = commands.run, .function = runTask },
            .{ .name = commands.refresh_task_skill_catalog, .function = refreshTaskSkillCatalog },
            .{ .name = commands.cancel, .function = cancelTask },
            .{ .name = commands.respond_ui, .function = respondUi },
            .{ .name = commands.close_task, .function = closeTask },
            .{ .name = commands.rename_task, .function = renameTask },
            .{ .name = commands.archive_task, .function = archiveTask },
            .{ .name = commands.delete_task, .function = deleteTask },
        };
        inline for (product_specs, 0..) |spec, index| self.registered_handlers[index] = .{
            .name = spec.name,
            .context = self,
            .invoke_fn = spec.function,
        };
        return .{
            .policy = policy,
            .registry = .{ .handlers = &self.registered_handlers },
        };
    }

    pub fn stopIngress(self: *Dispatcher) void {
        self.callbacks.stopIngress();
    }

    pub fn assertQuiescent(self: *Dispatcher) void {
        self.callbacks.assertQuiescent();
    }

    pub fn detachWorkbench(self: *Dispatcher) void {
        self.workbench = null;
    }

    pub fn breakConnection(self: *Dispatcher) void {
        self.delivery.breakConnection(self.transport());
        self.grants.invalidate();
    }

    pub fn connectedWindow(self: *const Dispatcher) ?native_sdk.platform.WindowId {
        return self.delivery.connectedWindow();
    }

    pub fn productDelivery(self: *Dispatcher) *product_delivery.Delivery {
        return &self.delivery;
    }

    pub fn onTimer(self: *Dispatcher, timer_id: u64) bool {
        return self.delivery.onTimer(timer_id);
    }

    pub fn emitWorkbenchChanged(self: *Dispatcher) !void {
        const workbench = self.workbench orelse return;
        const revision = workbench.currentRevision();
        _ = self.delivery.deliverRevision(
            revision,
            self.now(),
            self.transport(),
        ) catch |err| switch (err) {
            error.RevisionRetryExhausted, error.RevisionRetryUnavailable => {
                const revision_decision = workbench_api.decideTransportFailure(.{
                    .stage = .revision_delivery,
                });
                const connection_decision = workbench_api.decideTransportFailure(.{
                    .stage = .connection_generation,
                });
                std.debug.assert(revision_decision == .retry);
                std.debug.assert(connection_decision == .detach_renderer);
                self.breakConnection();
                return error.WorkbenchRevisionDeliveryUnavailable;
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
        const generation = try self.delivery.connect(invocation.source.window_id, self.transport());
        try self.platform.wake_fn(self.platform.context);
        return std.fmt.bufPrint(
            output,
            "{{\"accepted\":true,\"contractId\":\"{s}\",\"contractRevision\":{d},\"generation\":\"{d}\",\"error\":null}}",
            .{ commands.contract_id, commands.contract_revision, generation },
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
        defer self.delivery.breakConnection(self.transport());
        return std.fmt.bufPrint(output, "{{\"generation\":\"{d}\",\"detached\":true}}", .{generation});
    }

    fn beginWindowDrag(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireBootstrapWindow(invocation.source.window_id);
        var parsed = try handlers.parsePayload(
            handlers.WindowDragStart,
            invocation.request.payload,
        );
        defer parsed.deinit();
        if (parsed.value.clicks != 1)
            return error.InvalidBridgePayload;
        if (!self.platform.on_main_thread_fn(self.platform.context))
            return error.InvalidBridgeThread;
        try self.platform.begin_window_drag_fn(
            self.platform.context,
            invocation.source.window_id,
            parsed.value.clicks,
        );
        return std.fmt.bufPrint(output, "{{\"started\":true}}", .{});
    }

    fn controlWindow(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireBootstrapWindow(invocation.source.window_id);
        if (!self.platform.on_main_thread_fn(self.platform.context))
            return error.InvalidBridgeThread;
        var parsed = try handlers.parsePayload(
            handlers.WindowControl,
            invocation.request.payload,
        );
        defer parsed.deinit();
        const action: WindowControl = if (std.mem.eql(u8, parsed.value.action, "minimize"))
            .minimize
        else if (std.mem.eql(u8, parsed.value.action, "toggle_maximize"))
            .toggle_maximize
        else if (std.mem.eql(u8, parsed.value.action, "close"))
            .close
        else
            return error.InvalidBridgePayload;
        try self.platform.window_control_fn(
            self.platform.context,
            invocation.source.window_id,
            action,
        );
        return std.fmt.bufPrint(output, "{{\"completed\":true}}", .{});
    }

    fn beginSnapshot(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        const descriptor = self.delivery.publishSnapshot(
            invocation.source.window_id,
            .{ .context = self, .write_fn = writeSnapshot },
        ) catch |err| {
            std.debug.assert(workbench_api.decideTransportFailure(.{
                .stage = .snapshot_transport,
            }) == .retry);
            return err;
        };
        return std.fmt.bufPrint(
            output,
            "{{\"snapshotId\":\"{d}\",\"bytes\":{d},\"chunkBytes\":{d}}}",
            .{ descriptor.id, descriptor.bytes, product_delivery.snapshot_chunk_bytes },
        );
    }

    fn fetchSnapshotChunk(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        var parsed = try handlers.parsePayload(
            handlers.WorkbenchSnapshotChunk,
            invocation.request.payload,
        );
        defer parsed.deinit();
        const snapshot_id = try handlers.parseWireId(parsed.value.snapshotId);
        const offset = std.fmt.parseInt(usize, parsed.value.offset, 10) catch
            return error.InvalidBridgePayload;
        const chunk = self.delivery.snapshotChunk(
            invocation.source.window_id,
            snapshot_id,
            offset,
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

    fn accountReauthenticate(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        return submitEmptyAccountCommand(
            context,
            invocation,
            output,
            .reauthenticate,
        );
    }

    fn accountReopenLogin(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        return submitEmptyAccountCommand(
            context,
            invocation,
            output,
            .reopen_login,
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

    fn accountRefreshCatalog(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        return submitEmptyAccountCommand(
            context,
            invocation,
            output,
            .refresh_catalog,
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
        try self.requireAccountAuthority(invocation.source.window_id);
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

    fn accountSelectApiKey(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireAccountAuthority(invocation.source.window_id);
        var parsed = try handlers.parsePayload(
            handlers.AccountSelection,
            invocation.request.payload,
        );
        defer parsed.deinit();
        const admission = try self.validateAccountSelection(
            parsed.value,
            .api_key,
        );
        if (admission != .none)
            return encodeAccountResult(output, .rejected(admission));
        return encodeAccountResult(
            output,
            self.account_commands.submit(.{
                .select_api_key = parsed.value.selectionId,
            }),
        );
    }

    fn accountSelectModel(
        context: *anyopaque,
        invocation: native_sdk.bridge.Invocation,
        output: []u8,
    ) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireAccountAuthority(invocation.source.window_id);
        var parsed = try handlers.parsePayload(
            handlers.AccountSelection,
            invocation.request.payload,
        );
        defer parsed.deinit();
        const admission = try self.validateAccountSelection(
            parsed.value,
            .model,
        );
        if (admission != .none)
            return encodeAccountResult(output, .rejected(admission));
        return encodeAccountResult(
            output,
            self.account_commands.submit(.{
                .select_model = parsed.value.selectionId,
            }),
        );
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
            const visible_path = selected.paths[0..@min(
                selected.paths.len,
                native_sdk.platform.max_dialog_message_bytes,
            )];
            const decision = try self.platform.show_message_dialog_fn(
                self.platform.context,
                .{
                    .style = .warning,
                    .title = "Trust this workspace?",
                    .message = "MetaWork can read and change files in this folder while you use it. Only choose a folder you trust.",
                    .informative_text = visible_path,
                    .primary_button = "Use this folder",
                    .secondary_button = "Cancel",
                },
            );
            if (decision != .primary) return "{\"selected\":false}";
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
        const workspace_id = try (try self.requireWorkbench()).openWorkspace(.{
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

    fn selectWorkspace(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        var parsed = try handlers.parsePayload(handlers.WorkspaceIdentity, invocation.request.payload);
        defer parsed.deinit();
        const workspace_id = try handlers.parseWireId(parsed.value.workspaceId);
        const expected_epoch = try handlers.parseWireId(parsed.value.expectedWorkspaceEpoch);
        const workbench = try self.requireWorkbench();
        workbench.selectWorkspaceAtEpoch(workspace_id, expected_epoch) catch |err| {
            if (workspaceSelectionRejection(err)) |reason|
                return encodeWorkspaceMutationResult(
                    output,
                    false,
                    workspace_id,
                    null,
                    reason,
                );
            return err;
        };
        const workspace_epoch = try workbench.workspaceEpoch(workspace_id);
        self.notifyCommitted();
        return encodeWorkspaceMutationResult(
            output,
            true,
            workspace_id,
            workspace_epoch,
            null,
        );
    }

    fn removeWorkspace(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        var parsed = try handlers.parsePayload(handlers.WorkspaceIdentity, invocation.request.payload);
        defer parsed.deinit();
        const workspace_id = try handlers.parseWireId(parsed.value.workspaceId);
        const expected_epoch = try handlers.parseWireId(parsed.value.expectedWorkspaceEpoch);
        const workbench = try self.requireWorkbench();
        workbench.removeWorkspaceAtEpoch(workspace_id, expected_epoch) catch |err| {
            if (workspaceRemovalRejection(err)) |reason| {
                if (std.mem.eql(u8, reason, "removal_failed"))
                    self.notifyCommitted();
                return encodeWorkspaceMutationResult(
                    output,
                    false,
                    workspace_id,
                    null,
                    reason,
                );
            }
            return err;
        };
        const workspace_epoch = try workbench.workspaceEpoch(workspace_id);
        self.notifyCommitted();
        return encodeWorkspaceMutationResult(
            output,
            true,
            workspace_id,
            workspace_epoch,
            null,
        );
    }

    fn createTask(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        var parsed = try handlers.parsePayload(handlers.TaskCreate, invocation.request.payload);
        defer parsed.deinit();
        const workspace_id = try handlers.parseWireId(parsed.value.workspaceId);
        const workspace_epoch = try handlers.parseWireId(
            parsed.value.expectedWorkspaceEpoch,
        );
        const execution_generation = try handlers.parseWireId(
            parsed.value.expectedExecutionGeneration,
        );
        if (parsed.value.expectedSkillCatalogRevision) |revision|
            if (revision.len == 0) return error.InvalidBridgePayload;
        const workbench = try self.requireWorkbench();
        const task_id = workbench.createTaskInWorkspace(
            workspace_id,
            workspace_epoch,
            execution_generation,
            parsed.value.expectedSkillCatalogRevision,
        ) catch |err| {
            if (taskCreateRejection(err)) |reason|
                return encodeTaskCreateResult(output, false, null, null, reason);
            return err;
        };
        const binding_epoch = try workbench.taskBindingEpoch(task_id);
        self.notifyCommitted();
        return encodeTaskCreateResult(
            output,
            true,
            task_id,
            binding_epoch,
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
            128 * 1024,
        );
        defer parsed.deinit();
        var input = try handlers.parseTaskRunInput(parsed.value.input);
        defer input.deinit();
        const task_id = try handlers.parseWireId(parsed.value.taskId);
        const binding_epoch = try handlers.parseWireId(parsed.value.expectedBindingEpoch);
        const workbench_input: workbench_api.TaskRunInput = switch (input.value) {
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
                    .argument_values = skill.argument_values,
                } };
            },
        };
        const run_id = (try self.requireWorkbench()).runTaskAtBinding(
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
        const workbench = try self.requireWorkbench();
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
        (try self.requireWorkbench()).refreshSkillCatalog() catch |err| {
            if (catalogRefreshRejection(err)) |reason|
                return encodeSkillCatalogRefreshResult(output, false, reason);
            return err;
        };
        self.notifyCommitted();
        return encodeSkillCatalogRefreshResult(output, true, null);
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
        (try self.requireWorkbench()).refreshTaskCatalog(
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

    fn cancelTask(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        var parsed = try handlers.parsePayload(handlers.TaskIdentity, invocation.request.payload);
        defer parsed.deinit();
        const task_id = try handlers.parseWireId(parsed.value.taskId);
        const run_id = try handlers.parseWireId(parsed.value.runId);
        try (try self.requireWorkbench()).cancel(task_id, run_id);
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
        try (try self.requireWorkbench()).respondUi(task_id, run_id, request_id, response);
        self.notifyCommitted();
        return std.fmt.bufPrint(
            output,
            "{{\"taskId\":\"{d}\",\"runId\":\"{d}\",\"requestId\":\"{d}\",\"answered\":true}}",
            .{ task_id, run_id, request_id },
        );
    }

    fn closeTask(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        var parsed = try handlers.parsePayload(handlers.TaskClose, invocation.request.payload);
        defer parsed.deinit();
        const task_id = try handlers.parseWireId(parsed.value.taskId);
        try (try self.requireWorkbench()).closeTask(task_id);
        self.notifyCommitted();
        return std.fmt.bufPrint(output, "{{\"taskId\":\"{d}\",\"closing\":true}}", .{task_id});
    }

    fn renameTask(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        var parsed = try handlers.parsePayload(handlers.TaskRename, invocation.request.payload);
        defer parsed.deinit();
        const task_id = try handlers.parseWireId(parsed.value.taskId);
        try (try self.requireWorkbench()).renameTask(task_id, parsed.value.title);
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
        try (try self.requireWorkbench()).setTaskArchived(task_id, parsed.value.archived);
        self.notifyCommitted();
        return std.fmt.bufPrint(
            output,
            "{{\"taskId\":\"{d}\",\"archived\":{}}}",
            .{ task_id, parsed.value.archived },
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
        try (try self.requireWorkbench()).deleteTask(task_id);
        self.notifyCommitted();
        return std.fmt.bufPrint(output, "{{\"taskId\":\"{d}\",\"deleted\":true}}", .{task_id});
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

    fn requireAccountAuthority(
        self: *const Dispatcher,
        window_id: native_sdk.platform.WindowId,
    ) !void {
        try self.requireWindow(window_id);
        if (!self.platform.on_main_thread_fn(self.platform.context))
            return error.InvalidBridgeThread;
    }

    fn validateAccountSelection(
        self: *Dispatcher,
        selection: handlers.AccountSelection,
        kind: AccountSelectionKind,
    ) !account_contract.ErrorCode {
        const expected_catalog_generation = try handlers.parseWireId(
            selection.expectedCatalogGeneration,
        );
        const expected_execution_generation = try handlers.parseWireId(
            selection.expectedExecutionGeneration,
        );
        if (selection.selectionId.len == 0 or selection.selectionId.len > switch (kind) {
            .api_key => account_contract.Limits.api_key_id_bytes,
            .model => account_contract.Limits.model_id_bytes,
        }) return error.InvalidBridgePayload;
        const view = (try self.requireWorkbench()).accountView();
        if (expected_catalog_generation != view.catalog_generation or
            expected_execution_generation != view.execution_generation)
            return .generation_mismatch;
        const member = switch (kind) {
            .api_key => for (view.api_keys) |candidate| {
                if (std.mem.eql(u8, candidate.id, selection.selectionId)) break true;
            } else false,
            .model => for (view.models) |candidate| {
                if (std.mem.eql(u8, candidate.id, selection.selectionId)) break true;
            } else false,
        };
        return if (member) .none else .invalid_command;
    }

    fn requireWorkbench(self: *Dispatcher) !*workbench_api.Workbench {
        return self.workbench orelse error.RuntimeUnavailable;
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

    fn writeSnapshot(context: ?*anyopaque, output: []u8) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context.?));
        return (try self.requireWorkbench()).writeSnapshot(output);
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

fn taskCreateRejection(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.ExecutionGenerationMismatch => "execution_changed",
        error.ExecutionUnavailable, error.ExecutionInUse => "execution_unavailable",
        error.WorkspaceEpochMismatch => "workspace_changed",
        error.UnknownWorkspace, error.WorkspaceUnavailable => "workspace_unavailable",
        error.WorkspaceRemovalInProgress => "workspace_removing",
        error.CatalogLoading => "catalog_loading",
        error.CatalogUnavailable => "catalog_unavailable",
        error.StaleCatalog => "stale_catalog",
        error.TaskCapacity, error.ProjectionCapacity => "capacity_reached",
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
        error.UnknownWorkspace, error.WorkspaceUnavailable => "workspace_unavailable",
        error.WorkspaceEpochMismatch => "workspace_changed",
        error.WorkspaceRemovalInProgress => "workspace_removing",
        error.CatalogUnavailable => "catalog_unavailable",
        error.StaleCatalog => "stale_catalog",
        error.SkillNotFound => "skill_not_found",
        error.InvalidSkillArguments => "invalid_skill_arguments",
        error.RunCapacity, error.QueueFull, error.ProjectionCapacity => "capacity_reached",
        error.ExecutorShuttingDown => "shutting_down",
        else => null,
    };
}

fn catalogRefreshRejection(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.WorkspaceEpochMismatch => "workspace_changed",
        error.BindingEpochMismatch => "binding_changed",
        error.UnknownWorkspace, error.WorkspaceUnavailable => "workspace_unavailable",
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

fn workspaceSelectionRejection(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.WorkspaceEpochMismatch => "workspace_changed",
        error.UnknownWorkspace => "workspace_unavailable",
        error.WorkspaceRemovalInProgress => "workspace_removing",
        error.WorkspaceOrderExhausted => "capacity_reached",
        else => null,
    };
}

fn workspaceRemovalRejection(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.WorkspaceEpochMismatch => "workspace_changed",
        error.UnknownWorkspace => "workspace_unavailable",
        error.WorkspaceRemovalInProgress => "workspace_removing",
        error.WorkspaceEpochExhausted => "capacity_reached",
        // Every other error here is produced after removal admission while
        // starting Task shutdown. Workbench has already restored the
        // Workspace and published `lastRemovalFailure` for snapshot recovery.
        else => "removal_failed",
    };
}

fn encodeTaskCreateResult(
    output: []u8,
    accepted: bool,
    task_id: ?u64,
    binding_epoch: ?u64,
    reason: ?[]const u8,
) ![]const u8 {
    const valid = if (accepted)
        task_id != null and task_id.? != 0 and
            binding_epoch != null and binding_epoch.? != 0 and reason == null
    else
        task_id == null and binding_epoch == null and reason != null;
    if (!valid)
        return error.InvalidTaskCreateResult;
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
    writer.writeAll(",\"reason\":") catch return error.NoSpaceLeft;
    if (reason) |value|
        std.json.Stringify.value(value, .{}, &writer) catch return error.NoSpaceLeft
    else
        writer.writeAll("null") catch return error.NoSpaceLeft;
    writer.writeByte('}') catch return error.NoSpaceLeft;
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

fn encodeWorkspaceMutationResult(
    output: []u8,
    accepted: bool,
    workspace_id: u64,
    workspace_epoch: ?u64,
    reason: ?[]const u8,
) ![]const u8 {
    const valid = workspace_id != 0 and if (accepted)
        workspace_epoch != null and workspace_epoch.? != 0 and reason == null
    else
        workspace_epoch == null and reason != null;
    if (!valid)
        return error.InvalidWorkspaceMutationResult;
    var writer = std.Io.Writer.fixed(output);
    writer.print("{{\"accepted\":{},\"workspaceId\":\"{d}\",\"workspaceEpoch\":", .{
        accepted,
        workspace_id,
    }) catch return error.NoSpaceLeft;
    if (workspace_epoch) |value|
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

fn decodeUiResponse(request: handlers.UiResponseRequest) !workbench_api.UiResponse {
    if (std.mem.eql(u8, request.kind, "answers")) {
        if (request.answers == null or request.permission != null)
            return error.InvalidUiResponse;
        return .{ .answers = request.answers.? };
    }
    if (std.mem.eql(u8, request.kind, "permission")) {
        if (request.answers != null or request.permission == null)
            return error.InvalidUiResponse;
        const choice = handlers.permissionChoice(request.permission.?) orelse
            return error.InvalidUiResponse;
        return .{ .permission = switch (choice) {
            .allow_once => .allow_once,
            .deny_once => .deny_once,
        } };
    }
    return error.InvalidUiResponse;
}

test "permission command ingress rejects unsupported persistent choices" {
    const allow_once = try decodeUiResponse(.{
        .taskId = "1",
        .runId = "2",
        .requestId = "3",
        .kind = "permission",
        .permission = "allow_once",
    });
    try std.testing.expectEqual(
        workbench_api.PermissionChoice.allow_once,
        allow_once.permission,
    );

    const deny_once = try decodeUiResponse(.{
        .taskId = "1",
        .runId = "2",
        .requestId = "3",
        .kind = "permission",
        .permission = "deny_once",
    });
    try std.testing.expectEqual(
        workbench_api.PermissionChoice.deny_once,
        deny_once.permission,
    );

    for ([_][]const u8{
        "allow_always",
        "deny_tool_session",
        "deny_session",
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

test "mutation response encoders reject every inconsistent success and rejection shape" {
    var output: [256]u8 = undefined;
    try std.testing.expectError(
        error.InvalidTaskCreateResult,
        encodeTaskCreateResult(&output, false, 1, null, "task_unavailable"),
    );
    try std.testing.expectError(
        error.InvalidTaskCreateResult,
        encodeTaskCreateResult(&output, false, null, null, null),
    );
    try std.testing.expectError(
        error.InvalidTaskCreateResult,
        encodeTaskCreateResult(&output, true, 1, 1, "unexpected"),
    );
    try std.testing.expectError(
        error.InvalidTaskCreateResult,
        encodeTaskCreateResult(&output, true, 0, 1, null),
    );
    try std.testing.expectError(
        error.InvalidTaskCreateResult,
        encodeTaskCreateResult(&output, true, 1, 0, null),
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
        error.InvalidWorkspaceMutationResult,
        encodeWorkspaceMutationResult(&output, false, 1, 2, "workspace_changed"),
    );
    try std.testing.expectError(
        error.InvalidWorkspaceMutationResult,
        encodeWorkspaceMutationResult(&output, false, 1, null, null),
    );
    try std.testing.expectError(
        error.InvalidWorkspaceMutationResult,
        encodeWorkspaceMutationResult(&output, true, 0, 2, null),
    );
    try std.testing.expectError(
        error.InvalidWorkspaceMutationResult,
        encodeWorkspaceMutationResult(&output, true, 1, 0, null),
    );
}

fn inactive(_: ?*anyopaque) bool {
    return false;
}

fn noAutomationWorkspace(_: ?*anyopaque) ?[]const u8 {
    return null;
}

test "Dispatcher validates authority before domain calls and preserves committed state on response loss" {
    const fixture = @import("lifecycle_fixture");
    const Harness = struct {
        wake_calls: usize = 0,
        account_calls: usize = 0,
        drag_calls: usize = 0,
        window_control_calls: usize = 0,
        on_main_thread: bool = true,
        account_result: account_contract.AccountCommandResult =
            .acceptedAttempt(41),

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

        fn confirm(
            _: ?*anyopaque,
            _: native_sdk.platform.MessageDialogOptions,
        ) anyerror!native_sdk.platform.MessageDialogResult {
            return .primary;
        }

        fn beginWindowDrag(
            context: ?*anyopaque,
            window_id: native_sdk.platform.WindowId,
            clicks: u8,
        ) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            try std.testing.expectEqual(@as(native_sdk.platform.WindowId, 3), window_id);
            try std.testing.expect(clicks == 1 or clicks == 2);
            self.drag_calls += 1;
        }

        fn controlWindow(
            context: ?*anyopaque,
            window_id: native_sdk.platform.WindowId,
            action: WindowControl,
        ) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            try std.testing.expectEqual(@as(native_sdk.platform.WindowId, 3), window_id);
            try std.testing.expectEqual(WindowControl.minimize, action);
            self.window_control_calls += 1;
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
                .reopen_login,
                .reauthenticate,
                .cancel_operation,
                .refresh_catalog,
                .logout,
                => {},
                .select_api_key => |id| std.debug.assert(id.len != 0),
                .select_model => |id| std.debug.assert(id.len != 0),
            }
            return self.account_result;
        }
    };

    fixture.fake_core.reset();
    const runtime = try fixture.createTestRuntime(.{ .max_sessions = 1 });
    var workbench = try workbench_api.Workbench.init(
        std.testing.allocator,
        runtime,
        .{ .max_tasks = 1, .max_runs_per_task = 1, .max_tools_per_run = 1 },
        fixture.workbenchConfiguration(),
    );
    try fixture.installWorkbenchExecution(&workbench);
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
            .wake_fn = Harness.wake,
            .emit_fn = Harness.emit,
            .start_timer_fn = Harness.startTimer,
            .cancel_timer_fn = Harness.cancelTimer,
            .show_open_dialog_fn = Harness.open,
            .show_message_dialog_fn = Harness.confirm,
            .begin_window_drag_fn = Harness.beginWindowDrag,
            .window_control_fn = Harness.controlWindow,
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
    const native_dispatcher = dispatcher.register(
        @import("policy.zig").product(.release),
    );
    const source = native_sdk.bridge.Source{ .origin = "zero://app", .window_id = 3 };
    var response: [4096]u8 = undefined;

    for ([_][]const u8{
        "{\"id\":\"snapshot-before-contract\",\"command\":\"metawork.workbench.snapshot\",\"payload\":{}}",
        "{\"id\":\"account-before-contract\",\"command\":\"metawork.account.beginLogin\",\"payload\":{}}",
        "{\"id\":\"task-before-contract\",\"command\":\"metawork.tasks.create\",\"payload\":{\"workspaceGrant\":\"1\"}}",
    }) |request| {
        const before_contract = native_dispatcher.dispatch(request, source, &response);
        try std.testing.expect(std.mem.indexOf(u8, before_contract, "\"handler_failed\"") != null);
    }
    try std.testing.expectEqual(@as(usize, 0), harness.account_calls);
    try std.testing.expectEqual(initial_revision, workbench.currentRevision());

    const bootstrap_drag = native_dispatcher.dispatch(
        "{\"id\":\"drag-before-contract\",\"command\":\"metawork.window.beginDrag\",\"payload\":{\"clicks\":1}}",
        source,
        &response,
    );
    try std.testing.expect(std.mem.indexOf(u8, bootstrap_drag, "\"started\":true") != null);
    try std.testing.expectEqual(@as(usize, 1), harness.drag_calls);
    const bootstrap_minimize = native_dispatcher.dispatch(
        "{\"id\":\"minimize-before-contract\",\"command\":\"metawork.window.control\",\"payload\":{\"action\":\"minimize\"}}",
        source,
        &response,
    );
    try std.testing.expect(std.mem.indexOf(u8, bootstrap_minimize, "\"completed\":true") != null);
    try std.testing.expectEqual(@as(usize, 1), harness.window_control_calls);
    const foreign_bootstrap_window = native_sdk.bridge.Source{
        .origin = source.origin,
        .window_id = source.window_id + 1,
    };
    const denied_bootstrap_control = native_dispatcher.dispatch(
        "{\"id\":\"wrong-bootstrap-window\",\"command\":\"metawork.window.control\",\"payload\":{\"action\":\"minimize\"}}",
        foreign_bootstrap_window,
        &response,
    );
    try std.testing.expect(std.mem.indexOf(u8, denied_bootstrap_control, "\"handler_failed\"") != null);
    try std.testing.expectEqual(@as(usize, 1), harness.window_control_calls);
    harness.on_main_thread = false;
    const off_thread_drag = native_dispatcher.dispatch(
        "{\"id\":\"off-thread-drag\",\"command\":\"metawork.window.beginDrag\",\"payload\":{\"clicks\":1}}",
        source,
        &response,
    );
    try std.testing.expect(std.mem.indexOf(u8, off_thread_drag, "\"handler_failed\"") != null);
    try std.testing.expectEqual(@as(usize, 1), harness.drag_calls);
    harness.on_main_thread = true;
    const invalid_control = native_dispatcher.dispatch(
        "{\"id\":\"invalid-window-control\",\"command\":\"metawork.window.control\",\"payload\":{\"action\":\"resize\"}}",
        source,
        &response,
    );
    try std.testing.expect(std.mem.indexOf(u8, invalid_control, "\"handler_failed\"") != null);
    try std.testing.expectEqual(@as(usize, 1), harness.window_control_calls);

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
    const drag = native_dispatcher.dispatch(
        "{\"id\":\"drag\",\"command\":\"metawork.window.beginDrag\",\"payload\":{\"clicks\":1}}",
        source,
        &response,
    );
    try std.testing.expect(std.mem.indexOf(u8, drag, "\"started\":true") != null);
    try std.testing.expectEqual(@as(usize, 2), harness.drag_calls);
    const minimize = native_dispatcher.dispatch(
        "{\"id\":\"minimize\",\"command\":\"metawork.window.control\",\"payload\":{\"action\":\"minimize\"}}",
        source,
        &response,
    );
    try std.testing.expect(std.mem.indexOf(u8, minimize, "\"completed\":true") != null);
    try std.testing.expectEqual(@as(usize, 2), harness.window_control_calls);
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
    const empty_model = native_dispatcher.dispatch(
        "{\"id\":\"empty-model\",\"command\":\"metawork.account.selectModel\",\"payload\":{\"selectionId\":\"\",\"expectedCatalogGeneration\":\"0\",\"expectedExecutionGeneration\":\"1\"}}",
        source,
        &response,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, empty_model, "\"handler_failed\"") != null,
    );
    try std.testing.expectEqual(@as(usize, 1), harness.account_calls);
    const stale_selection = native_dispatcher.dispatch(
        "{\"id\":\"stale-key\",\"command\":\"metawork.account.selectApiKey\",\"payload\":{\"selectionId\":\"key-1\",\"expectedCatalogGeneration\":\"0\",\"expectedExecutionGeneration\":\"1\"}}",
        source,
        &response,
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        stale_selection,
        "\"errorCode\":\"generation_mismatch\"",
    ) != null);
    try std.testing.expectEqual(@as(usize, 1), harness.account_calls);
    const valid_selection = native_dispatcher.dispatch(
        "{\"id\":\"select-key\",\"command\":\"metawork.account.selectApiKey\",\"payload\":{\"selectionId\":\"key-1\",\"expectedCatalogGeneration\":\"1\",\"expectedExecutionGeneration\":\"1\"}}",
        source,
        &response,
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        valid_selection,
        "\"accepted\":true",
    ) != null);
    try std.testing.expectEqual(@as(usize, 2), harness.account_calls);
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
        "{\"id\":\"state-rejected\",\"command\":\"metawork.account.refreshCatalog\",\"payload\":{}}",
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
    const stale_workspace_request = try std.fmt.bufPrint(
        &workspace_request_storage,
        "{{\"id\":\"stale-workspace\",\"command\":\"metawork.workspaces.select\",\"payload\":{{\"workspaceId\":\"{d}\",\"expectedWorkspaceEpoch\":\"99\"}}}}",
        .{workspace_id},
    );
    const stale_workspace = native_dispatcher.dispatch(
        stale_workspace_request,
        source,
        &response,
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        stale_workspace,
        "\"reason\":\"workspace_changed\"",
    ) != null);

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
        "{{\"id\":\"stale-create\",\"command\":\"metawork.tasks.create\",\"payload\":{{\"workspaceId\":\"{d}\",\"expectedWorkspaceEpoch\":\"1\",\"expectedExecutionGeneration\":\"99\",\"expectedSkillCatalogRevision\":null}}}}",
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

    var request_storage: [256]u8 = undefined;
    const request = try std.fmt.bufPrint(
        &request_storage,
        "{{\"id\":\"create\",\"command\":\"metawork.tasks.create\",\"payload\":{{\"workspaceId\":\"{d}\",\"expectedWorkspaceEpoch\":\"1\",\"expectedExecutionGeneration\":\"1\",\"expectedSkillCatalogRevision\":null}}}}",
        .{workspace_id},
    );
    var lost_response: [32]u8 = undefined;
    _ = native_dispatcher.dispatch(request, source, &lost_response);
    try std.testing.expect(workbench.currentRevision() > 0);
    try std.testing.expect(harness.wake_calls >= 2);

    var snapshot_storage: [128 * 1024]u8 = undefined;
    const snapshot = try workbench.writeSnapshot(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"workspaceRoot\":\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"workspaces\":[{") != null);

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
