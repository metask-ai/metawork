const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");
const renderer_bridge = @import("metawork_bridge");
const automation_api = @import("metawork_automation");
const agent = @import("metawork_agent");
const workbench_api = @import("metawork_workbench");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const frontend_url_env = "NATIVE_SDK_FRONTEND_URL";
const event_name = "metawork:host-signal";
const workspace_path_capacity = renderer_bridge.workspace_grant.max_path_bytes;
const pending_ui_json_capacity = 256 * 1024;
const terminal_diagnostic_capacity = 512;
const agent_event_retry_interval: std.Io.Duration = .fromMilliseconds(5);
const agent_event_notification_timeout: std.Io.Duration = .fromMilliseconds(50);
const host_worker_count = 4;
const product_handler_count = 15;
const workbench_snapshot_capacity = renderer_bridge.snapshot_max_bytes;
const workbench_snapshot_chunk_bytes = renderer_bridge.snapshot_chunk_bytes;

const FrontendMode = renderer_bridge.policy.Mode;
const EventDisconnect = renderer_bridge.handlers.EventDisconnect;
const WorkbenchSnapshotChunk = renderer_bridge.handlers.WorkbenchSnapshotChunk;
const TaskCreate = renderer_bridge.handlers.TaskCreate;
const TaskRun = renderer_bridge.handlers.TaskRun;
const TaskIdentity = renderer_bridge.handlers.TaskIdentity;
const TaskClose = renderer_bridge.handlers.TaskClose;
const TaskRename = renderer_bridge.handlers.TaskRename;
const TaskArchive = renderer_bridge.handlers.TaskArchive;
const TaskDelete = renderer_bridge.handlers.TaskDelete;
const UiResponseRequest = renderer_bridge.handlers.UiResponseRequest;
const parsePayload = renderer_bridge.handlers.parsePayload;
const parsePayloadWithLimit = renderer_bridge.handlers.parsePayloadWithLimit;
const parseWireId = renderer_bridge.handlers.parseWireId;
const permissionChoice = renderer_bridge.handlers.permissionChoice;
const acknowledgementSequence = renderer_bridge.handlers.acknowledgementSequence;

const App = struct {
    env_map: *std.process.Environ.Map,
    io: std.Io,
    automation: automation_api.Runtime = .{},
    product_delivery: renderer_bridge.ProductDelivery = .{},
    bridge_callbacks: renderer_bridge.CallbackGate = .{},
    agent_runtime: ?*agent.Runtime = null,
    workbench: ?*workbench_api.Workbench = null,
    agent_shutdown: bool = false,
    agent_event_wake_pending: std.atomic.Value(bool) = .init(false),
    main_thread_id: std.Thread.Id,
    native_runtime: ?*native_sdk.Runtime = null,
    platform_services: ?native_sdk.platform.PlatformServices = null,
    sequence: u64 = 0,
    acknowledged_sequence: u64 = 0,
    workspace_grants: renderer_bridge.workspace_grant.State = .{},
    emit_window_event_context: ?*anyopaque = null,
    emit_window_event_override: ?*const fn (
        context: ?*anyopaque,
        window_id: native_sdk.platform.WindowId,
        name: []const u8,
        detail: []const u8,
    ) anyerror!void = null,
    snapshot_write_context: ?*anyopaque = null,
    snapshot_write_override: ?*const fn (
        context: ?*anyopaque,
        workbench: *workbench_api.Workbench,
        output: []u8,
    ) anyerror![]const u8 = null,
    handlers: [product_handler_count + automation_api.handler_count]native_sdk.bridge.Handler = undefined,

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
        self.stopBridgeIngress();
        self.automation.stop();
        if (self.workbench) |workbench| workbench.shutdownExecutor();
        if (self.agent_runtime) |agent_runtime| {
            try agent_runtime.shutdown();
            self.agent_shutdown = true;
        }
        self.drainAgentEvents();
        if (self.workbench) |workbench| workbench.syncLifecycle();
        self.product_delivery.breakConnection(self.productTransport());
        self.quiesceBridgeCallbacks();
        self.detachWorkbench();
        self.platform_services = null;
        self.workspace_grants.invalidate();
        if (self.native_runtime == native_runtime) self.native_runtime = null;
    }

    fn event(context: *anyopaque, native_runtime: *native_sdk.Runtime, value: native_sdk.Event) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        _ = native_runtime;
        switch (value) {
            .effects_wake => {
                self.drainAgentEvents();
                if (self.product_delivery.connectedWindow()) |window_id| {
                    try self.automation.onEffectsWake(window_id);
                    try self.emitWorkbenchChanged();
                }
            },
            .timer => |timer| if (self.automation.onTimer(timer.id, native_sdk.monotonicNanoseconds())) {
                return;
            } else if (self.product_delivery.onTimer(timer.id)) {
                try self.emitWorkbenchChanged();
            },
            else => {},
        }
    }

    fn bridge(self: *@This(), mode: FrontendMode) native_sdk.BridgeDispatcher {
        self.handlers[0] = .{
            .name = renderer_bridge.commands.ping,
            .context = self,
            .invoke_fn = ping,
        };
        self.handlers[1] = .{
            .name = renderer_bridge.commands.ping_ack,
            .context = self,
            .invoke_fn = acknowledgeEvent,
        };
        self.handlers[2] = .{
            .name = renderer_bridge.commands.connect,
            .context = self,
            .invoke_fn = connectEvents,
        };
        self.handlers[3] = .{
            .name = renderer_bridge.commands.disconnect,
            .context = self,
            .invoke_fn = disconnectEvents,
        };
        self.handlers[4] = .{
            .name = renderer_bridge.commands.choose_workspace,
            .context = self,
            .invoke_fn = chooseWorkspace,
        };
        self.handlers[5] = .{
            .name = renderer_bridge.commands.snapshot,
            .context = self,
            .invoke_fn = beginWorkbenchSnapshot,
        };
        self.handlers[6] = .{
            .name = renderer_bridge.commands.snapshot_chunk,
            .context = self,
            .invoke_fn = fetchWorkbenchSnapshotChunk,
        };
        self.handlers[7] = .{
            .name = renderer_bridge.commands.create_task,
            .context = self,
            .invoke_fn = createTask,
        };
        self.handlers[8] = .{
            .name = renderer_bridge.commands.run,
            .context = self,
            .invoke_fn = runTask,
        };
        self.handlers[9] = .{
            .name = renderer_bridge.commands.cancel,
            .context = self,
            .invoke_fn = cancelTask,
        };
        self.handlers[10] = .{
            .name = renderer_bridge.commands.respond_ui,
            .context = self,
            .invoke_fn = respondUi,
        };
        self.handlers[11] = .{
            .name = renderer_bridge.commands.close_task,
            .context = self,
            .invoke_fn = closeTask,
        };
        self.handlers[12] = .{
            .name = renderer_bridge.commands.rename_task,
            .context = self,
            .invoke_fn = renameTask,
        };
        self.handlers[13] = .{
            .name = renderer_bridge.commands.archive_task,
            .context = self,
            .invoke_fn = archiveTask,
        };
        self.handlers[14] = .{
            .name = renderer_bridge.commands.delete_task,
            .context = self,
            .invoke_fn = deleteTask,
        };
        self.automation.fillHandlers(self.handlers[product_handler_count..]);
        return .{
            .policy = self.automation.productPolicy(renderer_bridge.policy.product(mode)),
            .registry = .{ .handlers = &self.handlers },
        };
    }

    fn ping(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        var callback = try self.enterBridgeCallback();
        defer callback.deinit();
        const native_runtime = self.native_runtime orelse return error.RuntimeUnavailable;
        self.sequence += 1;

        const on_main_thread = std.Thread.getCurrentId() == self.main_thread_id;
        var detail_buffer: [512]u8 = undefined;
        const detail = try std.fmt.bufPrint(
            &detail_buffer,
            "{{\"sequence\":{d},\"transport\":\"Runtime.emitWindowEvent\",\"origin\":\"{s}\",\"onMainThread\":{},\"requestBytes\":{d}}}",
            .{
                self.sequence,
                invocation.source.origin,
                on_main_thread,
                invocation.request.payload.len,
            },
        );
        try native_runtime.emitWindowEvent(invocation.source.window_id, event_name, detail);

        return std.fmt.bufPrint(
            output,
            "{{\"sequence\":{d},\"transport\":\"BridgeDispatcher.response\",\"origin\":\"{s}\",\"onMainThread\":{}}}",
            .{
                self.sequence,
                invocation.source.origin,
                on_main_thread,
            },
        );
    }

    fn acknowledgeEvent(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        var callback = try self.enterBridgeCallback();
        defer callback.deinit();
        _ = self.native_runtime orelse return error.RuntimeUnavailable;
        const acknowledged_sequence = try acknowledgementSequence(invocation.request.payload);
        if (acknowledged_sequence == 0 or acknowledged_sequence > self.sequence) return error.SequenceMismatch;
        self.acknowledged_sequence = @max(self.acknowledged_sequence, acknowledged_sequence);
        const on_main_thread = std.Thread.getCurrentId() == self.main_thread_id;
        std.debug.print("metawork.smoke.event_ack sequence={d} origin={s} main_thread={}\n", .{
            acknowledged_sequence,
            invocation.source.origin,
            on_main_thread,
        });
        return std.fmt.bufPrint(
            output,
            "{{\"sequence\":{d},\"transport\":\"React.eventAck\",\"origin\":\"{s}\",\"onMainThread\":{}}}",
            .{ acknowledged_sequence, invocation.source.origin, on_main_thread },
        );
    }

    fn connectEvents(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        var callback = try self.enterBridgeCallback();
        defer callback.deinit();
        _ = self.native_runtime orelse return error.RuntimeUnavailable;
        const services = self.platform_services orelse return error.RuntimeUnavailable;
        if (self.product_delivery.connectedWindow()) |window_id|
            if (window_id != invocation.source.window_id) return error.EventWindowMismatch;
        const now_ns = native_sdk.monotonicNanoseconds();
        try self.automation.beforeConnect(now_ns);
        const generation = try self.product_delivery.connect(
            invocation.source.window_id,
            self.productTransport(),
        );
        errdefer {
            self.product_delivery.breakConnection(self.productTransport());
        }
        try self.automation.connectAt(generation);
        errdefer self.automation.detach(generation, now_ns) catch {};
        try services.wake();
        return std.fmt.bufPrint(output, "{{\"generation\":\"{d}\"}}", .{generation});
    }

    fn disconnectEvents(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        var callback = try self.enterBridgeCallback();
        defer callback.deinit();
        var parsed = try parsePayload(EventDisconnect, invocation.request.payload);
        defer parsed.deinit();
        const request = parsed.value;
        const generation = try parseWireId(request.generation);
        try self.product_delivery.validateConnection(generation, invocation.source.window_id);
        defer self.workspace_grants.invalidate();
        defer self.product_delivery.breakConnection(self.productTransport());
        try self.automation.detach(generation, native_sdk.monotonicNanoseconds());
        return std.fmt.bufPrint(output, "{{\"generation\":\"{d}\",\"detached\":true}}", .{generation});
    }

    fn beginWorkbenchSnapshot(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        var callback = try self.enterBridgeCallback();
        defer callback.deinit();
        try self.requireEventWindow(invocation.source.window_id);
        const snapshot = self.product_delivery.publishSnapshot(
            invocation.source.window_id,
            .{ .context = self, .write_fn = App.writeProductSnapshot },
        ) catch |err| {
            const decision = workbench_api.decideTransportFailure(.{ .stage = .snapshot_transport });
            std.debug.assert(decision == .retry);
            return err;
        };
        return std.fmt.bufPrint(
            output,
            "{{\"snapshotId\":\"{d}\",\"bytes\":{d},\"chunkBytes\":{d}}}",
            .{ snapshot.id, snapshot.bytes, workbench_snapshot_chunk_bytes },
        );
    }

    fn fetchWorkbenchSnapshotChunk(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        var callback = try self.enterBridgeCallback();
        defer callback.deinit();
        try self.requireEventWindow(invocation.source.window_id);
        var parsed = try parsePayload(WorkbenchSnapshotChunk, invocation.request.payload);
        defer parsed.deinit();
        const snapshot_id = try parseWireId(parsed.value.snapshotId);
        const offset = std.fmt.parseInt(usize, parsed.value.offset, 10) catch return error.InvalidBridgePayload;
        const chunk = self.product_delivery.snapshotChunk(
            invocation.source.window_id,
            snapshot_id,
            offset,
        ) catch |err| switch (err) {
            error.StaleSnapshot => return error.StaleSnapshot,
            error.InvalidOffset => return error.InvalidBridgePayload,
            error.InvalidStorage => unreachable,
            error.NoConnection, error.StaleConnection, error.EventWindowMismatch => return err,
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

    fn chooseWorkspace(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        var callback = try self.enterBridgeCallback();
        defer callback.deinit();
        try self.requireEventWindow(invocation.source.window_id);
        if (self.automation.active()) return error.AutomationOnly;
        const generation = self.product_delivery.connectedGeneration() orelse return error.NoConnection;
        const services = self.platform_services orelse return error.RuntimeUnavailable;
        self.workspace_grants.invalidate();
        var dialog_storage: [native_sdk.platform.max_dialog_paths_bytes]u8 = undefined;
        const selected = try services.showOpenDialog(.{
            .title = "Choose a workspace for this Agent session",
            .allow_directories = true,
            .allow_multiple = false,
        }, &dialog_storage);
        if (selected.count == 0) return "{\"selected\":false}";
        if (selected.count != 1 or selected.paths.len == 0) return error.InvalidWorkspace;

        const canonical = try std.Io.Dir.realPathFileAbsoluteAlloc(
            self.io,
            selected.paths,
            std.heap.c_allocator,
        );
        defer std.heap.c_allocator.free(canonical);
        if (canonical.len > workspace_path_capacity) return error.InvalidWorkspace;
        const workspace_stat = try std.Io.Dir.cwd().statFile(self.io, canonical, .{});
        if (workspace_stat.kind != .directory) return error.InvalidWorkspace;

        const visible_path = canonical[0..@min(canonical.len, native_sdk.platform.max_dialog_message_bytes)];
        const decision = try services.showMessageDialog(.{
            .style = .warning,
            .title = "Trust this workspace?",
            .message = "AgentCore tools will be allowed to work in this directory.",
            .informative_text = visible_path,
            .primary_button = "Trust workspace",
            .secondary_button = "Cancel",
        });
        if (decision != .primary) {
            self.workspace_grants.invalidate();
            return "{\"selected\":false}";
        }

        const token = self.workspace_grants.issue(generation, invocation.source.window_id, canonical) catch
            return error.InvalidWorkspace;
        var writer = std.Io.Writer.fixed(output);
        writer.print("{{\"selected\":true,\"workspaceRoot\":", .{}) catch return error.NoSpaceLeft;
        std.json.Stringify.value(canonical, .{}, &writer) catch return error.NoSpaceLeft;
        writer.print(",\"grant\":\"{d}\"}}", .{token}) catch return error.NoSpaceLeft;
        return writer.buffered();
    }

    fn createTask(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        var callback = try self.enterBridgeCallback();
        defer callback.deinit();
        try self.requireEventWindow(invocation.source.window_id);
        var parsed = try parsePayload(TaskCreate, invocation.request.payload);
        defer parsed.deinit();
        const request = parsed.value;
        var granted_path_storage: [workspace_path_capacity]u8 = undefined;
        const canonical_input = if (self.automation.active()) automation: {
            if (request.workspaceRoot == null or request.workspaceGrant != null) return error.InvalidBridgePayload;
            break :automation request.workspaceRoot.?;
        } else trusted: {
            if (request.workspaceRoot != null or request.workspaceGrant == null) return error.InvalidBridgePayload;
            const token = try parseWireId(request.workspaceGrant.?);
            const granted = try self.workspace_grants.consume(
                token,
                invocation.source.window_id,
                self.product_delivery.connectedGeneration() orelse return error.NoConnection,
                &granted_path_storage,
            );
            break :trusted granted;
        };
        const canonical = try std.Io.Dir.realPathFileAbsoluteAlloc(self.io, canonical_input, std.heap.c_allocator);
        defer std.heap.c_allocator.free(canonical);
        const workspace_stat = try std.Io.Dir.cwd().statFile(self.io, canonical, .{});
        if (workspace_stat.kind != .directory) return error.InvalidWorkspace;
        const temp_root = try std.Io.Dir.realPathFileAbsoluteAlloc(self.io, "/tmp", std.heap.c_allocator);
        defer std.heap.c_allocator.free(temp_root);
        const workspace_trust: agent.WorkspaceTrust = if (self.automation.active())
            .{ .temporary = temp_root }
        else
            .explicitly_trusted;
        const credential = self.env_map.get("METAWORK_PROVIDER_API_KEY") orelse return error.ProviderCredentialMissing;
        const model = self.env_map.get("METAWORK_PROVIDER_MODEL") orelse return error.ProviderModelMissing;
        const provider = providerKind(self.env_map.get("METAWORK_PROVIDER_KIND") orelse "anthropic") orelse
            return error.UnsupportedProvider;
        const base_url = self.env_map.get("METAWORK_PROVIDER_BASE_URL") orelse "";
        const workbench = self.workbench orelse return error.RuntimeUnavailable;
        const task_id = try workbench.createTask(.{
            .provider = provider,
            .permission_mode = .default,
            .shell_policy = .unrestricted,
            .credential = credential,
            .model = model,
            .base_url = base_url,
            .workspace = .{
                .canonical_root = canonical,
                .trust = workspace_trust,
            },
        });
        self.notifyCommitted();
        return std.fmt.bufPrint(output, "{{\"taskId\":\"{d}\"}}", .{task_id});
    }

    fn runTask(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        var callback = try self.enterBridgeCallback();
        defer callback.deinit();
        try self.requireEventWindow(invocation.source.window_id);
        var parsed = try parsePayloadWithLimit(TaskRun, invocation.request.payload, 128 * 1024);
        defer parsed.deinit();
        const task_id = try parseWireId(parsed.value.taskId);
        if (parsed.value.prompt.len == 0) return error.EmptyPrompt;
        const run_id = try (self.workbench orelse return error.RuntimeUnavailable).runTask(task_id, parsed.value.prompt);
        self.notifyCommitted();
        return std.fmt.bufPrint(output, "{{\"taskId\":\"{d}\",\"runId\":\"{d}\"}}", .{ task_id, run_id });
    }

    fn cancelTask(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        var callback = try self.enterBridgeCallback();
        defer callback.deinit();
        try self.requireEventWindow(invocation.source.window_id);
        var parsed = try parsePayload(TaskIdentity, invocation.request.payload);
        defer parsed.deinit();
        const task_id = try parseWireId(parsed.value.taskId);
        const run_id = try parseWireId(parsed.value.runId);
        try (self.workbench orelse return error.RuntimeUnavailable).cancel(task_id, run_id);
        self.notifyCommitted();
        return std.fmt.bufPrint(output, "{{\"taskId\":\"{d}\",\"runId\":\"{d}\",\"cancelRequested\":true}}", .{ task_id, run_id });
    }

    fn respondUi(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        var callback = try self.enterBridgeCallback();
        defer callback.deinit();
        try self.requireEventWindow(invocation.source.window_id);
        var parsed = try parsePayloadWithLimit(UiResponseRequest, invocation.request.payload, 256 * 1024);
        defer parsed.deinit();
        const request = parsed.value;
        const task_id = try parseWireId(request.taskId);
        const run_id = try parseWireId(request.runId);
        const request_id = try parseWireId(request.requestId);
        const response: agent.UiResponse = if (std.mem.eql(u8, request.kind, "answers")) answer: {
            if (request.answers == null or request.permission != null)
                return error.InvalidUiResponse;
            break :answer .{ .answers = request.answers.? };
        } else if (std.mem.eql(u8, request.kind, "permission")) permission: {
            if (request.answers != null or request.permission == null)
                return error.InvalidUiResponse;
            const choice = permissionChoice(request.permission.?) orelse return error.InvalidUiResponse;
            break :permission .{ .permission = switch (choice) {
                .allow_once => .allow_once,
                .allow_always => .allow_always,
                .deny_once => .deny_once,
                .deny_tool_session => .deny_tool_session,
            } };
        } else return error.InvalidUiResponse;
        try (self.workbench orelse return error.RuntimeUnavailable).respondUi(task_id, run_id, request_id, response);
        self.notifyCommitted();
        return std.fmt.bufPrint(output, "{{\"taskId\":\"{d}\",\"runId\":\"{d}\",\"requestId\":\"{d}\",\"answered\":true}}", .{ task_id, run_id, request_id });
    }

    fn closeTask(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        var callback = try self.enterBridgeCallback();
        defer callback.deinit();
        try self.requireEventWindow(invocation.source.window_id);
        var parsed = try parsePayload(TaskClose, invocation.request.payload);
        defer parsed.deinit();
        const task_id = try parseWireId(parsed.value.taskId);
        try (self.workbench orelse return error.RuntimeUnavailable).closeTask(task_id);
        self.notifyCommitted();
        return std.fmt.bufPrint(output, "{{\"taskId\":\"{d}\",\"closing\":true}}", .{task_id});
    }

    fn renameTask(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        var callback = try self.enterBridgeCallback();
        defer callback.deinit();
        try self.requireEventWindow(invocation.source.window_id);
        var parsed = try parsePayload(TaskRename, invocation.request.payload);
        defer parsed.deinit();
        const task_id = try parseWireId(parsed.value.taskId);
        try (self.workbench orelse return error.RuntimeUnavailable).renameTask(task_id, parsed.value.title);
        self.notifyCommitted();
        return std.fmt.bufPrint(output, "{{\"taskId\":\"{d}\",\"renamed\":true}}", .{task_id});
    }

    fn archiveTask(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        var callback = try self.enterBridgeCallback();
        defer callback.deinit();
        try self.requireEventWindow(invocation.source.window_id);
        var parsed = try parsePayload(TaskArchive, invocation.request.payload);
        defer parsed.deinit();
        const task_id = try parseWireId(parsed.value.taskId);
        try (self.workbench orelse return error.RuntimeUnavailable).setTaskArchived(task_id, parsed.value.archived);
        self.notifyCommitted();
        return std.fmt.bufPrint(output, "{{\"taskId\":\"{d}\",\"archived\":{}}}", .{ task_id, parsed.value.archived });
    }

    fn deleteTask(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        var callback = try self.enterBridgeCallback();
        defer callback.deinit();
        try self.requireEventWindow(invocation.source.window_id);
        var parsed = try parsePayload(TaskDelete, invocation.request.payload);
        defer parsed.deinit();
        const task_id = try parseWireId(parsed.value.taskId);
        try (self.workbench orelse return error.RuntimeUnavailable).deleteTask(task_id);
        self.notifyCommitted();
        return std.fmt.bufPrint(output, "{{\"taskId\":\"{d}\",\"deleted\":true}}", .{task_id});
    }

    fn emitWorkbenchChanged(self: *@This()) !void {
        const workbench = self.workbench orelse return;
        const revision = workbench.currentRevision();
        _ = self.product_delivery.deliverRevision(
            revision,
            native_sdk.monotonicNanoseconds(),
            self.productTransport(),
        ) catch |err| switch (err) {
            error.RevisionRetryExhausted, error.RevisionRetryUnavailable => {
                const revision_decision = workbench_api.decideTransportFailure(.{ .stage = .revision_delivery });
                const connection_decision = workbench_api.decideTransportFailure(.{ .stage = .connection_generation });
                std.debug.assert(revision_decision == .retry);
                std.debug.assert(connection_decision == .detach_renderer);
                std.log.warn("Workbench revision {d} delivery became unavailable: {s}", .{
                    revision,
                    @errorName(err),
                });
                self.breakEventConnection();
                return error.WorkbenchRevisionDeliveryUnavailable;
            },
            else => return err,
        };
    }

    fn breakEventConnection(self: *@This()) void {
        if (self.product_delivery.connectedGeneration()) |generation|
            self.automation.detach(generation, native_sdk.monotonicNanoseconds()) catch {};
        self.product_delivery.breakConnection(self.productTransport());
        self.workspace_grants.invalidate();
    }

    fn breakProductConnectionForAutomation(context: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(context orelse return));
        self.product_delivery.breakConnection(self.productTransport());
        self.workspace_grants.invalidate();
    }

    fn drainAgentEvents(self: *@This()) void {
        const agent_runtime = self.agent_runtime orelse return;
        // Clear before draining: an event published concurrently after this
        // point schedules another wake instead of disappearing behind a stale
        // coalescing bit. A redundant wake is harmless; a lost wake is not.
        self.agent_event_wake_pending.store(false, .release);
        while (agent_runtime.takeEvent()) |value| {
            var envelope = value;
            defer envelope.deinit();
            if (self.workbench) |workbench| workbench.applyEvent(&envelope) catch {
                const session_id = envelope.session_id;
                const run_id = envelope.run_id;
                agent_runtime.requestRunTermination(
                    session_id,
                    run_id,
                    .{ .event_pump_failure = .consumer_rejected },
                ) catch {};
                continue;
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

    fn notifyNativeMainLoop(self: *@This()) !void {
        const services = self.platform_services orelse return error.RuntimeUnavailable;
        try services.wake();
    }

    fn notifyCommitted(self: *@This()) void {
        self.notifyNativeMainLoop() catch |err| {
            std.log.warn("committed Workbench mutation could not schedule a UI wake: {s}", .{@errorName(err)});
        };
    }

    fn enterBridgeCallback(self: *@This()) !renderer_bridge.CallbackGate.Lease {
        return self.bridge_callbacks.enter();
    }

    fn stopBridgeIngress(self: *@This()) void {
        self.bridge_callbacks.stopIngress();
    }

    fn detachWorkbench(self: *@This()) void {
        self.workbench = null;
    }

    fn quiesceBridgeCallbacks(self: *@This()) void {
        self.bridge_callbacks.assertQuiescent();
    }

    fn requireEventWindow(self: *@This(), window_id: native_sdk.platform.WindowId) !void {
        _ = try self.product_delivery.requireWindow(window_id);
    }

    fn emitWindowEvent(
        self: *@This(),
        native_runtime: ?*native_sdk.Runtime,
        window_id: native_sdk.platform.WindowId,
        name: []const u8,
        detail: []const u8,
    ) !void {
        if (self.emit_window_event_override) |emit|
            return emit(self.emit_window_event_context, window_id, name, detail);
        try (native_runtime orelse return error.RuntimeUnavailable).emitWindowEvent(window_id, name, detail);
    }

    fn productTransport(self: *@This()) renderer_bridge.ProductDeliveryTransport {
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
        const self: *@This() = @ptrCast(@alignCast(context.?));
        return self.emitWindowEvent(self.native_runtime, window_id, name, detail);
    }

    fn startProductTimer(
        context: ?*anyopaque,
        timer_id: u64,
        interval_ns: u64,
        repeats: bool,
    ) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        const services = self.platform_services orelse return error.RuntimeUnavailable;
        return services.startTimer(timer_id, interval_ns, repeats);
    }

    fn cancelProductTimer(context: ?*anyopaque, timer_id: u64) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        const services = self.platform_services orelse return error.RuntimeUnavailable;
        return services.cancelTimer(timer_id);
    }

    fn writeProductSnapshot(context: ?*anyopaque, output: []u8) anyerror![]const u8 {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        const workbench_state = self.workbench orelse return error.RuntimeUnavailable;
        if (self.snapshot_write_override) |write|
            return write(self.snapshot_write_context, workbench_state, output);
        return workbench_state.writeSnapshot(output);
    }
};

fn providerKind(value: []const u8) ?agent.ProviderKind {
    if (std.mem.eql(u8, value, "anthropic")) return .anthropic;
    if (std.mem.eql(u8, value, "openai")) return .openai;
    if (std.mem.eql(u8, value, "gemini")) return .gemini;
    return null;
}

fn frontendMode(env_map: *std.process.Environ.Map) FrontendMode {
    if (env_map.get(frontend_url_env) != null) return .development;
    return .release;
}

fn createAgentRuntime(
    io: std.Io,
    notifier: agent.EventReadyNotifier,
) !*agent.Runtime {
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
    var app = initialized: {
        var automation = try automation_api.Runtime.init(
            std.heap.c_allocator,
            init.environ_map,
            std.Thread.getCurrentId(),
        );
        errdefer automation.deinit();
        const product_delivery = try renderer_bridge.ProductDelivery.init(std.heap.c_allocator);
        break :initialized App{
            .env_map = init.environ_map,
            .io = init.io,
            .automation = automation,
            .product_delivery = product_delivery,
            .main_thread_id = std.Thread.getCurrentId(),
        };
    };
    defer {
        app.product_delivery.breakConnection(app.productTransport());
        app.product_delivery.deinitOwnedBuffers();
    }
    defer app.automation.deinit();
    app.automation.bind(&app.bridge_callbacks, &app.product_delivery, .{
        .context = &app,
        .break_product_connection_fn = App.breakProductConnectionForAutomation,
    });
    const agent_runtime = try createAgentRuntime(init.io, .{
        .context = &app,
        .notify_fn = App.notifyAgentEventConsumer,
    });
    app.agent_runtime = agent_runtime;
    var workbench_state: workbench_api.Workbench = undefined;
    var workbench_initialized = false;
    defer {
        if (workbench_initialized) workbench_state.shutdownExecutor();
        if (!app.agent_shutdown) agent_runtime.shutdown() catch {};
        if (workbench_initialized) workbench_state.deinit();
        agent_runtime.deinit();
    }
    workbench_state = try workbench_api.Workbench.initWithNotifier(
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
        .{ .context = &app, .wake = App.notifyMainLoop },
    );
    workbench_initialized = true;
    if (init.environ_map.get("METAWORK_PROVIDER_API_KEY")) |credential|
        try workbench_state.setKnownSecret(credential);
    app.workbench = &workbench_state;
    const mode = frontendMode(init.environ_map);

    try runner.runWithOptions(app.app(), .{
        .app_name = "MetaWork",
        .window_title = "MetaWork",
        .bundle_id = "dev.metawork.desktop",
        .bridge = app.bridge(mode),
        .builtin_bridge = app.automation.builtinPolicy(renderer_bridge.policy.builtin(mode)),
        .js_window_api = true,
        .security = .{
            .permissions = &renderer_bridge.policy.window_permissions,
            .navigation = .{
                .allowed_origins = app.automation.allowedOrigins(renderer_bridge.policy.origins(mode)),
            },
        },
    }, init);
}

test "transport limits and origin sets are explicit" {
    try std.testing.expectEqual(@as(usize, 1024 * 1024), native_sdk.bridge.max_message_bytes);
    try std.testing.expectEqual(@as(usize, 1024 * 1024), native_sdk.bridge.max_result_bytes);
    try std.testing.expectEqual(@as(usize, 1024 * 1024), native_sdk.bridge.max_response_bytes);
    try std.testing.expectEqual(@as(usize, 8192), native_sdk.platform.max_window_event_detail_bytes);
    try std.testing.expectEqual(@as(usize, 1), renderer_bridge.policy.origins(.release).len);
    try std.testing.expectEqual(@as(usize, 2), renderer_bridge.policy.origins(.development).len);
}

test "bridge rejects an untrusted origin before handler dispatch" {
    var app = App{
        .env_map = undefined,
        .io = std.testing.io,
        .main_thread_id = std.Thread.getCurrentId(),
    };
    var response_buffer: [512]u8 = undefined;
    const response = app.bridge(.release).dispatch(
        "{\"id\":\"origin-test\",\"command\":\"metawork.smoke.ping\",\"payload\":null}",
        .{ .origin = "https://untrusted.invalid" },
        &response_buffer,
    );

    try std.testing.expect(std.mem.indexOf(u8, response, "\"permission_denied\"") != null);
    try std.testing.expectEqual(@as(u64, 0), app.sequence);
}

test "Bridge shutdown closes ingress before Workbench detaches" {
    var app = App{
        .env_map = undefined,
        .io = std.testing.io,
        .main_thread_id = std.Thread.getCurrentId(),
    };
    app.stopBridgeIngress();
    app.quiesceBridgeCallbacks();
    app.detachWorkbench();

    var response_buffer: [1024]u8 = undefined;
    const response = app.bridge(.release).dispatch(
        "{\"id\":\"after-stop\",\"command\":\"metawork.smoke.ping\",\"payload\":{}}",
        .{ .origin = "zero://app", .window_id = 1 },
        &response_buffer,
    );
    try std.testing.expect(std.mem.indexOf(u8, response, "\"handler_failed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "BridgeStopping") != null);
    try std.testing.expectEqual(@as(usize, 0), app.bridge_callbacks.active);
}

test "event acknowledgement payload is exact and bounded" {
    try std.testing.expectEqual(@as(u64, 42), try acknowledgementSequence("{\"sequence\":42}"));
    try std.testing.expectError(error.InvalidAcknowledgement, acknowledgementSequence("{\"sequence\":42,\"extra\":true}"));
    try std.testing.expectError(error.InvalidAcknowledgement, acknowledgementSequence("{\"sequence\":-1}"));
    try std.testing.expectError(error.InvalidAcknowledgement, acknowledgementSequence("{\"sequence\":01}"));
}

test "Workspace trust grants are bound to window and generation and consumed once" {
    var app = App{
        .env_map = undefined,
        .io = std.testing.io,
        .main_thread_id = std.Thread.getCurrentId(),
    };
    var token = try app.workspace_grants.issue(9, 3, "/tmp/metawork-granted");
    var path_storage: [workspace_path_capacity]u8 = undefined;
    try std.testing.expectError(
        error.WorkspaceNotTrusted,
        app.workspace_grants.consume(token, 4, 9, &path_storage),
    );
    token = try app.workspace_grants.issue(9, 3, "/tmp/metawork-granted");
    try std.testing.expectError(
        error.WorkspaceNotTrusted,
        app.workspace_grants.consume(token, 3, 10, &path_storage),
    );
    token = try app.workspace_grants.issue(9, 3, "/tmp/metawork-granted");
    const granted = try app.workspace_grants.consume(token, 3, 9, &path_storage);
    try std.testing.expectEqualStrings("/tmp/metawork-granted", granted);
    try std.testing.expectError(
        error.WorkspaceNotTrusted,
        app.workspace_grants.consume(token, 3, 9, &path_storage),
    );
}

test "release Workspace selection uses native confirmation before issuing a one-time grant" {
    const Harness = struct {
        open_calls: usize = 0,
        confirm_calls: usize = 0,

        fn open(context: ?*anyopaque, options: native_sdk.platform.OpenDialogOptions, buffer: []u8) anyerror!native_sdk.platform.OpenDialogResult {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.open_calls += 1;
            try std.testing.expect(options.allow_directories);
            const path = "/tmp";
            @memcpy(buffer[0..path.len], path);
            return .{ .count = 1, .paths = buffer[0..path.len] };
        }

        fn confirm(context: ?*anyopaque, options: native_sdk.platform.MessageDialogOptions) anyerror!native_sdk.platform.MessageDialogResult {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.confirm_calls += 1;
            try std.testing.expectEqual(native_sdk.platform.MessageDialogStyle.warning, options.style);
            try std.testing.expect(options.informative_text.len != 0);
            return .primary;
        }
    };
    var harness = Harness{};
    var app = App{
        .env_map = undefined,
        .io = std.testing.io,
        .main_thread_id = std.Thread.getCurrentId(),
        .platform_services = .{
            .context = &harness,
            .show_open_dialog_fn = Harness.open,
            .show_message_dialog_fn = Harness.confirm,
        },
    };
    const generation = try app.product_delivery.connect(3, app.productTransport());
    var output: [4096]u8 = undefined;
    const response = app.bridge(.release).dispatch(
        "{\"id\":\"workspace\",\"command\":\"metawork.workspace.choose\",\"payload\":{}}",
        .{ .origin = "zero://app", .window_id = 3 },
        &output,
    );
    const Result = struct { selected: bool, workspaceRoot: []const u8, grant: []const u8 };
    const Envelope = struct { id: []const u8, ok: bool, result: Result };
    var parsed = try std.json.parseFromSlice(Envelope, std.testing.allocator, response, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.ok);
    try std.testing.expect(parsed.value.result.selected);
    try std.testing.expectEqual(@as(usize, 1), harness.open_calls);
    try std.testing.expectEqual(@as(usize, 1), harness.confirm_calls);

    var granted_path: [workspace_path_capacity]u8 = undefined;
    const consumed = try app.workspace_grants.consume(
        try parseWireId(parsed.value.result.grant),
        3,
        generation,
        &granted_path,
    );
    try std.testing.expectEqualStrings(parsed.value.result.workspaceRoot, consumed);
    try std.testing.expectError(
        error.WorkspaceNotTrusted,
        app.workspace_grants.consume(try parseWireId(parsed.value.result.grant), 3, generation, &granted_path),
    );
}

test "post-commit wake failure is not returned as a mutation failure" {
    const Harness = struct {
        wake_calls: usize = 0,

        fn wake(context: ?*anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.wake_calls += 1;
            return error.InjectedWakeFailure;
        }
    };
    var harness = Harness{};
    var app = App{
        .env_map = undefined,
        .io = std.testing.io,
        .main_thread_id = std.Thread.getCurrentId(),
        .platform_services = .{ .context = &harness, .wake_fn = Harness.wake },
    };
    app.notifyCommitted();
    try std.testing.expectEqual(@as(usize, 1), harness.wake_calls);
    try std.testing.expectEqual(
        agent.EventReadyNotification.unavailable,
        App.notifyAgentEventConsumer(&app),
    );
    try std.testing.expectEqual(@as(usize, 2), harness.wake_calls);
}

test "Workbench revision delivery retries and coalesces to the newest revision" {
    const Harness = struct {
        emit_calls: usize = 0,
        timer_starts: usize = 0,
        timer_cancels: usize = 0,
        last_detail: [96]u8 = undefined,
        last_detail_len: usize = 0,

        fn emit(context: ?*anyopaque, window_id: native_sdk.platform.WindowId, name: []const u8, detail: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.emit_calls += 1;
            try std.testing.expectEqual(@as(native_sdk.platform.WindowId, 4), window_id);
            try std.testing.expectEqualStrings(renderer_bridge.product_event_name, name);
            if (self.emit_calls == 1) return error.InjectedEmitFailure;
            @memcpy(self.last_detail[0..detail.len], detail);
            self.last_detail_len = detail.len;
        }

        fn startTimer(context: ?*anyopaque, id: u64, interval_ns: u64, repeats: bool) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.timer_starts += 1;
            try std.testing.expectEqual(renderer_bridge.product_retry_timer_id, id);
            try std.testing.expect(interval_ns > 0);
            try std.testing.expect(!repeats);
        }

        fn cancelTimer(context: ?*anyopaque, id: u64) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.timer_cancels += 1;
            try std.testing.expectEqual(renderer_bridge.product_retry_timer_id, id);
        }
    };
    var harness = Harness{};
    var workbench = try workbench_api.Workbench.init(std.testing.allocator, undefined, .{});
    defer workbench.deinit();
    workbench.revision = 7;
    var app = App{
        .env_map = undefined,
        .io = std.testing.io,
        .workbench = &workbench,
        .main_thread_id = std.Thread.getCurrentId(),
        .platform_services = .{
            .context = &harness,
            .start_timer_fn = Harness.startTimer,
            .cancel_timer_fn = Harness.cancelTimer,
        },
        .emit_window_event_context = &harness,
        .emit_window_event_override = Harness.emit,
    };
    _ = try app.product_delivery.connect(4, app.productTransport());

    try app.emitWorkbenchChanged();
    try std.testing.expect(app.product_delivery.revision.pending);
    try std.testing.expectEqual(@as(u64, 0), app.product_delivery.revision.last_emitted);
    workbench.revision = 9;
    try app.emitWorkbenchChanged();
    try std.testing.expect(!app.product_delivery.revision.pending);
    try std.testing.expectEqual(@as(u64, 9), app.product_delivery.revision.last_emitted);
    try std.testing.expectEqual(@as(usize, 2), harness.emit_calls);
    try std.testing.expectEqual(@as(usize, 1), harness.timer_starts);
    try std.testing.expectEqual(@as(usize, 1), harness.timer_cancels);
    try std.testing.expect(std.mem.indexOf(u8, harness.last_detail[0..harness.last_detail_len], "\"9\"") != null);
}

test "Workbench revision delivery fails closed when retry scheduling is unavailable" {
    const Harness = struct {
        fn emit(context: ?*anyopaque, window_id: native_sdk.platform.WindowId, name: []const u8, detail: []const u8) anyerror!void {
            _ = context;
            _ = window_id;
            _ = name;
            _ = detail;
            return error.InjectedEmitFailure;
        }

        fn startTimer(context: ?*anyopaque, id: u64, interval_ns: u64, repeats: bool) anyerror!void {
            _ = context;
            _ = interval_ns;
            _ = repeats;
            if (id == renderer_bridge.product_retry_timer_id) return error.InjectedTimerFailure;
        }

        fn cancelTimer(context: ?*anyopaque, id: u64) anyerror!void {
            _ = context;
            _ = id;
        }
    };
    var workbench = try workbench_api.Workbench.init(std.testing.allocator, undefined, .{});
    defer workbench.deinit();
    workbench.revision = 1;
    var app = App{
        .env_map = undefined,
        .io = std.testing.io,
        .workbench = &workbench,
        .main_thread_id = std.Thread.getCurrentId(),
        .platform_services = .{
            .start_timer_fn = Harness.startTimer,
            .cancel_timer_fn = Harness.cancelTimer,
        },
        .emit_window_event_override = Harness.emit,
    };
    _ = try app.product_delivery.connect(4, app.productTransport());

    try std.testing.expectError(
        error.WorkbenchRevisionDeliveryUnavailable,
        app.emitWorkbenchChanged(),
    );
    try std.testing.expectEqual(@as(?native_sdk.platform.WindowId, null), app.product_delivery.connectedWindow());
    try std.testing.expectEqual(@as(usize, 0), app.product_delivery.snapshot.len);
}

test "Workbench snapshot chunk handler binds identity generation and offset" {
    const generation: u64 = 1;
    var snapshot_storage = [_]u8{ 0, 1, 2, 3, 254, 255 };
    var app = App{
        .env_map = undefined,
        .io = std.testing.io,
        .main_thread_id = std.Thread.getCurrentId(),
        .product_delivery = .{
            .generation = generation,
            .window_id = 2,
            .snapshot = .{
                .storage = &snapshot_storage,
                .len = snapshot_storage.len,
                .id = 5,
                .generation = generation,
                .window_id = 2,
            },
        },
    };
    var output: [512]u8 = undefined;
    const response = try App.fetchWorkbenchSnapshotChunk(&app, .{
        .request = .{
            .id = "chunk",
            .command = "metawork.workbench.snapshot.chunk",
            .payload = "{\"snapshotId\":\"5\",\"offset\":\"0\"}",
        },
        .source = .{ .origin = "zero://app", .window_id = 2 },
    }, &output);
    const Result = struct { snapshotId: []const u8, offset: usize, bytes: usize, data: []const u8 };
    var parsed = try std.json.parseFromSlice(Result, std.testing.allocator, response, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("5", parsed.value.snapshotId);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.offset);
    try std.testing.expectEqual(snapshot_storage.len, parsed.value.bytes);
    var decoded: [snapshot_storage.len]u8 = undefined;
    try std.base64.standard.Decoder.decode(&decoded, parsed.value.data);
    try std.testing.expectEqualSlices(u8, &snapshot_storage, &decoded);

    try std.testing.expectError(
        error.StaleSnapshot,
        App.fetchWorkbenchSnapshotChunk(&app, .{
            .request = .{
                .id = "stale",
                .command = "metawork.workbench.snapshot.chunk",
                .payload = "{\"snapshotId\":\"4\",\"offset\":\"0\"}",
            },
            .source = .{ .origin = "zero://app", .window_id = 2 },
        }, &output),
    );
    try std.testing.expect(
        std.base64.standard.Encoder.calcSize(workbench_snapshot_chunk_bytes) + 256 <
            native_sdk.bridge.max_result_bytes,
    );
}

test "a failed snapshot write invalidates the previously published descriptor" {
    const Harness = struct {
        fn write(
            context: ?*anyopaque,
            workbench: *workbench_api.Workbench,
            output: []u8,
        ) anyerror![]const u8 {
            _ = context;
            _ = workbench;
            @memset(output[0..64], 0xaa);
            return error.InjectedSnapshotFailure;
        }
    };
    const generation: u64 = 1;
    var workbench = try workbench_api.Workbench.init(std.testing.allocator, undefined, .{});
    defer workbench.deinit();
    const snapshot_storage = try std.testing.allocator.alloc(u8, workbench_snapshot_capacity);
    defer std.testing.allocator.free(snapshot_storage);
    var app = App{
        .env_map = undefined,
        .io = std.testing.io,
        .workbench = &workbench,
        .main_thread_id = std.Thread.getCurrentId(),
        .product_delivery = .{
            .generation = generation,
            .window_id = 2,
            .snapshot = .{ .storage = snapshot_storage },
        },
        .snapshot_write_override = Harness.write,
    };
    app.product_delivery.snapshot.len = 128;
    app.product_delivery.snapshot.id = 9;
    app.product_delivery.snapshot.generation = generation;
    app.product_delivery.snapshot.window_id = 2;
    var output: [512]u8 = undefined;
    try std.testing.expectError(
        error.InjectedSnapshotFailure,
        App.beginWorkbenchSnapshot(&app, .{
            .request = .{ .id = "begin", .command = "metawork.workbench.snapshot", .payload = "{}" },
            .source = .{ .origin = "zero://app", .window_id = 2 },
        }, &output),
    );
    try std.testing.expectEqual(@as(usize, 0), app.product_delivery.snapshot.len);
    try std.testing.expectEqual(@as(u64, 0), app.product_delivery.snapshot.generation);
    try std.testing.expectError(
        error.StaleSnapshot,
        App.fetchWorkbenchSnapshotChunk(&app, .{
            .request = .{
                .id = "old",
                .command = "metawork.workbench.snapshot.chunk",
                .payload = "{\"snapshotId\":\"9\",\"offset\":\"0\"}",
            },
            .source = .{ .origin = "zero://app", .window_id = 2 },
        }, &output),
    );
}

test "Agent transport ids preserve the complete u64 domain" {
    try std.testing.expectEqual(@as(u64, 1), try parseWireId("1"));
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        try parseWireId("18446744073709551615"),
    );
    try std.testing.expectError(error.InvalidBridgeId, parseWireId(""));
    try std.testing.expectError(error.InvalidBridgeId, parseWireId("01"));
    try std.testing.expectError(error.InvalidBridgeId, parseWireId("+1"));
    try std.testing.expectError(error.InvalidBridgeId, parseWireId("1_0"));
    try std.testing.expectError(error.InvalidBridgeId, parseWireId("-1"));
    try std.testing.expectError(
        error.InvalidBridgeId,
        parseWireId("18446744073709551616"),
    );
}

test "Agent transport payload rejects unknown fields and oversized input" {
    var exact = try parsePayload(EventDisconnect, "{\"generation\":\"1\"}");
    defer exact.deinit();
    try std.testing.expectEqualStrings("1", exact.value.generation);
    try std.testing.expectError(
        error.InvalidBridgePayload,
        parsePayload(EventDisconnect, "{\"generation\":\"1\",\"extra\":true}"),
    );
    var oversized: [4097]u8 = undefined;
    @memset(&oversized, 'x');
    try std.testing.expectError(
        error.InvalidBridgePayload,
        parsePayload(EventDisconnect, &oversized),
    );

    var rename = try parsePayload(TaskRename, "{\"taskId\":\"7\",\"title\":\"Release audit\"}");
    defer rename.deinit();
    try std.testing.expectEqualStrings("7", rename.value.taskId);
    try std.testing.expectEqualStrings("Release audit", rename.value.title);
    try std.testing.expectError(
        error.InvalidBridgePayload,
        parsePayload(TaskRename, "{\"taskId\":\"7\",\"title\":\"Release audit\",\"legacy\":true}"),
    );
    var archive = try parsePayload(TaskArchive, "{\"taskId\":\"7\",\"archived\":true}");
    defer archive.deinit();
    try std.testing.expect(archive.value.archived);
}
