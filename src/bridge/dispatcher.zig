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
pub const max_extra_handlers: usize = 32;
const workspace_path_capacity = workspace_grant.max_path_bytes;
const event_name = "metawork:host-signal";

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
    now_fn: *const fn (?*anyopaque) u64,
    on_main_thread_fn: *const fn (?*anyopaque) bool,
};

pub const AutomationHooks = struct {
    context: ?*anyopaque = null,
    active_fn: *const fn (?*anyopaque) bool = inactive,
    before_connect_fn: *const fn (?*anyopaque, u64) anyerror!void = noAutomationAction,
    connect_fn: *const fn (?*anyopaque, u64) anyerror!void = noAutomationAction,
    detach_fn: *const fn (?*anyopaque, u64, u64) anyerror!void = noAutomationDetach,

    fn active(self: AutomationHooks) bool {
        return self.active_fn(self.context);
    }
};

pub const Dispatcher = struct {
    workbench: ?*workbench_api.Workbench,
    account_commands: account_contract.AccountCommandSink,
    platform: Platform,
    automation: AutomationHooks,
    delivery: product_delivery.Delivery,
    callbacks: callback_gate.State = .{},
    grants: workspace_grant.State = .{},
    sequence: u64 = 0,
    acknowledged_sequence: u64 = 0,
    handler_count: usize = 0,
    registered_handlers: [product_handler_count + max_extra_handlers]native_sdk.bridge.Handler = undefined,

    pub fn init(
        allocator: std.mem.Allocator,
        workbench: *workbench_api.Workbench,
        account_commands: account_contract.AccountCommandSink,
        platform: Platform,
        automation: AutomationHooks,
    ) std.mem.Allocator.Error!Dispatcher {
        return .{
            .workbench = workbench,
            .account_commands = account_commands,
            .platform = platform,
            .automation = automation,
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

    /// Registers the complete product table and appends compile-time-selected
    /// automation handlers into Bridge-owned registry storage.
    pub fn register(
        self: *Dispatcher,
        policy: native_sdk.BridgePolicy,
        extra_handlers: []const native_sdk.bridge.Handler,
    ) !native_sdk.BridgeDispatcher {
        if (extra_handlers.len > max_extra_handlers) return error.HandlerCapacity;
        const product_specs = [_]struct {
            name: []const u8,
            function: native_sdk.bridge.HandlerFn,
        }{
            .{ .name = commands.ping, .function = ping },
            .{ .name = commands.ping_ack, .function = acknowledgeEvent },
            .{ .name = commands.connect, .function = connectEvents },
            .{ .name = commands.disconnect, .function = disconnectEvents },
            .{ .name = commands.choose_workspace, .function = chooseWorkspace },
            .{ .name = commands.snapshot, .function = beginSnapshot },
            .{ .name = commands.snapshot_chunk, .function = fetchSnapshotChunk },
            .{ .name = commands.account_begin_login, .function = accountBeginLogin },
            .{ .name = commands.account_reauthenticate, .function = accountReauthenticate },
            .{ .name = commands.account_cancel_operation, .function = accountCancelOperation },
            .{ .name = commands.account_refresh_catalog, .function = accountRefreshCatalog },
            .{ .name = commands.account_select_api_key, .function = accountSelectApiKey },
            .{ .name = commands.account_select_model, .function = accountSelectModel },
            .{ .name = commands.account_logout, .function = accountLogout },
            .{ .name = commands.create_task, .function = createTask },
            .{ .name = commands.run, .function = runTask },
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
        @memcpy(
            self.registered_handlers[product_handler_count..][0..extra_handlers.len],
            extra_handlers,
        );
        self.handler_count = product_handler_count + extra_handlers.len;
        return .{
            .policy = policy,
            .registry = .{ .handlers = self.registered_handlers[0..self.handler_count] },
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
        if (self.delivery.connectedGeneration()) |generation|
            self.automation.detach_fn(self.automation.context, generation, self.now()) catch {};
        self.delivery.breakConnection(self.transport());
        self.grants.invalidate();
    }

    pub fn connectedWindow(self: *const Dispatcher) ?native_sdk.platform.WindowId {
        return self.delivery.connectedWindow();
    }

    pub fn callbackGate(self: *Dispatcher) *callback_gate.State {
        return &self.callbacks;
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
        if (self.delivery.connectedWindow()) |window_id|
            if (window_id != invocation.source.window_id) return error.EventWindowMismatch;
        const now_ns = self.now();
        try self.automation.before_connect_fn(self.automation.context, now_ns);
        const generation = try self.delivery.connect(invocation.source.window_id, self.transport());
        errdefer self.delivery.breakConnection(self.transport());
        try self.automation.connect_fn(self.automation.context, generation);
        errdefer self.automation.detach_fn(self.automation.context, generation, now_ns) catch {};
        try self.platform.wake_fn(self.platform.context);
        return std.fmt.bufPrint(output, "{{\"generation\":\"{d}\"}}", .{generation});
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
        try self.automation.detach_fn(self.automation.context, generation, self.now());
        return std.fmt.bufPrint(output, "{{\"generation\":\"{d}\",\"detached\":true}}", .{generation});
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
            handlers.AccountSelectApiKey,
            invocation.request.payload,
        );
        defer parsed.deinit();
        if (parsed.value.apiKeyId.len == 0 or
            parsed.value.apiKeyId.len >
                account_contract.Limits.api_key_id_bytes)
            return error.InvalidBridgePayload;
        return encodeAccountResult(
            output,
            self.account_commands.submit(.{
                .select_api_key = parsed.value.apiKeyId,
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
            handlers.AccountSelectModel,
            invocation.request.payload,
        );
        defer parsed.deinit();
        if (parsed.value.modelId.len == 0 or
            parsed.value.modelId.len >
                account_contract.Limits.model_id_bytes)
            return error.InvalidBridgePayload;
        return encodeAccountResult(
            output,
            self.account_commands.submit(.{
                .select_model = parsed.value.modelId,
            }),
        );
    }

    fn chooseWorkspace(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        if (self.automation.active()) return error.AutomationOnly;
        const generation = self.delivery.connectedGeneration() orelse return error.NoConnection;
        self.grants.invalidate();
        var dialog_storage: [native_sdk.platform.max_dialog_paths_bytes]u8 = undefined;
        const selected = try self.platform.show_open_dialog_fn(
            self.platform.context,
            .{
                .title = "Choose a workspace for this Agent session",
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
                .message = "AgentCore tools will be allowed to work in this directory.",
                .informative_text = visible_path,
                .primary_button = "Trust workspace",
                .secondary_button = "Cancel",
            },
        );
        if (decision != .primary) return "{\"selected\":false}";
        const token = try self.grants.issue(
            generation,
            invocation.source.window_id,
            selected.paths,
        );
        var writer = std.Io.Writer.fixed(output);
        writer.writeAll("{\"selected\":true,\"workspaceRoot\":") catch return error.NoSpaceLeft;
        std.json.Stringify.value(selected.paths, .{}, &writer) catch return error.NoSpaceLeft;
        writer.print(",\"grant\":\"{d}\"}}", .{token}) catch return error.NoSpaceLeft;
        return writer.buffered();
    }

    fn createTask(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *Dispatcher = @ptrCast(@alignCast(context));
        var callback = try self.callbacks.enter();
        defer callback.deinit();
        try self.requireWindow(invocation.source.window_id);
        var parsed = try handlers.parsePayload(handlers.TaskCreate, invocation.request.payload);
        defer parsed.deinit();
        var path_storage: [workspace_path_capacity]u8 = undefined;
        const input: workbench_api.TaskCreateInput = if (self.automation.active()) automation: {
            if (parsed.value.workspaceRoot == null or parsed.value.workspaceGrant != null)
                return error.InvalidBridgePayload;
            break :automation .{
                .workspace_root = parsed.value.workspaceRoot.?,
                .trust = .{ .temporary = "/tmp" },
            };
        } else trusted: {
            if (parsed.value.workspaceRoot != null or parsed.value.workspaceGrant == null)
                return error.InvalidBridgePayload;
            const token = try handlers.parseWireId(parsed.value.workspaceGrant.?);
            break :trusted .{
                .workspace_root = try self.grants.consume(
                    token,
                    invocation.source.window_id,
                    self.delivery.connectedGeneration() orelse return error.NoConnection,
                    &path_storage,
                ),
                .trust = .explicitly_trusted,
            };
        };
        const task_id = try (try self.requireWorkbench()).createTask(input);
        self.notifyCommitted();
        return std.fmt.bufPrint(output, "{{\"taskId\":\"{d}\"}}", .{task_id});
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
        const task_id = try handlers.parseWireId(parsed.value.taskId);
        if (parsed.value.prompt.len == 0) return error.EmptyPrompt;
        const run_id = try (try self.requireWorkbench()).runTask(task_id, parsed.value.prompt);
        self.notifyCommitted();
        return std.fmt.bufPrint(
            output,
            "{{\"taskId\":\"{d}\",\"runId\":\"{d}\"}}",
            .{ task_id, run_id },
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

    fn requireAccountAuthority(
        self: *const Dispatcher,
        window_id: native_sdk.platform.WindowId,
    ) !void {
        try self.requireWindow(window_id);
        if (!self.platform.on_main_thread_fn(self.platform.context))
            return error.InvalidBridgeThread;
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

fn inactive(_: ?*anyopaque) bool {
    return false;
}

fn noAutomationAction(_: ?*anyopaque, _: u64) anyerror!void {}

fn noAutomationDetach(_: ?*anyopaque, _: u64, _: u64) anyerror!void {}

test "Dispatcher validates authority before domain calls and preserves committed state on response loss" {
    const fixture = @import("lifecycle_fixture");
    const Harness = struct {
        wake_calls: usize = 0,
        detach_calls: usize = 0,
        account_calls: usize = 0,
        fail_detach: bool = false,
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

        fn detach(context: ?*anyopaque, _: u64, _: u64) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.detach_calls += 1;
            if (self.fail_detach) return error.InjectedDetachFailure;
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
            .now_fn = Harness.now,
            .on_main_thread_fn = Harness.onMainThread,
        },
        .{
            .context = &harness,
            .detach_fn = Harness.detach,
        },
    );
    defer {
        dispatcher.deinit();
        workbench.shutdownExecutor();
        runtime.shutdown() catch unreachable;
        workbench.deinit();
        runtime.deinit();
    }
    const native_dispatcher = try dispatcher.register(
        @import("policy.zig").product(.release),
        &.{},
    );
    const source = native_sdk.bridge.Source{ .origin = "zero://app", .window_id = 3 };
    var response: [4096]u8 = undefined;

    const invalid = native_dispatcher.dispatch(
        "{\"id\":\"bad\",\"command\":\"metawork.tasks.create\",\"payload\":{\"workspaceGrant\":\"1\",\"extra\":true}}",
        source,
        &response,
    );
    try std.testing.expect(std.mem.indexOf(u8, invalid, "\"handler_failed\"") != null);
    try std.testing.expectEqual(initial_revision, workbench.currentRevision());

    _ = native_dispatcher.dispatch(
        "{\"id\":\"connect\",\"command\":\"metawork.events.connect\",\"payload\":{}}",
        source,
        &response,
    );
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
        "{\"id\":\"empty-model\",\"command\":\"metawork.account.selectModel\",\"payload\":{\"modelId\":\"\"}}",
        source,
        &response,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, empty_model, "\"handler_failed\"") != null,
    );
    try std.testing.expectEqual(@as(usize, 1), harness.account_calls);
    harness.on_main_thread = false;
    _ = native_dispatcher.dispatch(
        "{\"id\":\"wrong-thread\",\"command\":\"metawork.account.logout\",\"payload\":{}}",
        source,
        &response,
    );
    try std.testing.expectEqual(@as(usize, 1), harness.account_calls);
    harness.on_main_thread = true;
    harness.account_result = .rejected(.invalid_state);
    const rejected = native_dispatcher.dispatch(
        "{\"id\":\"state-rejected\",\"command\":\"metawork.account.refreshCatalog\",\"payload\":{}}",
        source,
        &response,
    );
    try std.testing.expectEqual(@as(usize, 2), harness.account_calls);
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            rejected,
            "\"accepted\":false,\"errorCode\":\"invalid_state\",\"attemptId\":null",
        ) != null,
    );
    const chosen = native_dispatcher.dispatch(
        "{\"id\":\"choose\",\"command\":\"metawork.workspace.choose\",\"payload\":{}}",
        source,
        &response,
    );
    const grant_start = std.mem.indexOf(u8, chosen, "\"grant\":\"") orelse
        return error.TestUnexpectedResult;
    const digits_start = grant_start + "\"grant\":\"".len;
    const digits_end = std.mem.indexOfPos(u8, chosen, digits_start, "\"") orelse
        return error.TestUnexpectedResult;
    const grant = chosen[digits_start..digits_end];

    var request_storage: [256]u8 = undefined;
    const request = try std.fmt.bufPrint(
        &request_storage,
        "{{\"id\":\"create\",\"command\":\"metawork.tasks.create\",\"payload\":{{\"workspaceGrant\":\"{s}\"}}}}",
        .{grant},
    );
    var lost_response: [32]u8 = undefined;
    _ = native_dispatcher.dispatch(request, source, &lost_response);
    try std.testing.expect(workbench.currentRevision() > 0);
    try std.testing.expect(harness.wake_calls >= 2);

    var snapshot_storage: [128 * 1024]u8 = undefined;
    const snapshot = try workbench.writeSnapshot(&snapshot_storage);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"workspaceRoot\":\"/private/tmp\"") != null or
        std.mem.indexOf(u8, snapshot, "\"workspaceRoot\":\"/tmp\"") != null);

    const generation = dispatcher.productDelivery().connectedGeneration().?;
    const unused_grant = try dispatcher.grants.issue(generation, source.window_id, "/tmp");
    harness.fail_detach = true;
    var disconnect_storage: [256]u8 = undefined;
    const disconnect = try std.fmt.bufPrint(
        &disconnect_storage,
        "{{\"id\":\"disconnect\",\"command\":\"metawork.events.disconnect\",\"payload\":{{\"generation\":\"{d}\"}}}}",
        .{generation},
    );
    const failed_disconnect = native_dispatcher.dispatch(disconnect, source, &response);
    try std.testing.expect(std.mem.indexOf(u8, failed_disconnect, "\"handler_failed\"") != null);
    try std.testing.expectEqual(@as(usize, 1), harness.detach_calls);
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
