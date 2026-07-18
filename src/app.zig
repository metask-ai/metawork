const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");
const renderer_bridge = @import("metawork_bridge");
const bridge_delivery = renderer_bridge.delivery;
const agentcore = @import("metacodes_agentcore");
const agent = @import("metawork_agent");
const workbench_api = @import("metawork_workbench");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const frontend_url_env = "NATIVE_SDK_FRONTEND_URL";
const gate0_automation_env = "METAWORK_GATE0_AUTOMATION";
const gate5_fixture_env = "METAWORK_GATE5_FIXTURE";
const delivery_retention_timer_id: u64 = 0x4d57_4445_4c49_5652;
const workbench_revision_retry_timer_id = renderer_bridge.revision_delivery.retry_timer_id;
const event_name = "metawork:host-signal";
const agent_event_name = "metawork:agent-events";
const workbench_event_name = renderer_bridge.revision_delivery.event_name;
const workspace_path_capacity = renderer_bridge.workspace_grant.max_path_bytes;
const pending_ui_json_capacity = 256 * 1024;
const host_worker_count = 4;
const workbench_snapshot_capacity = renderer_bridge.snapshot_delivery.max_bytes;
const workbench_snapshot_chunk_bytes = renderer_bridge.snapshot_delivery.chunk_bytes;

const FrontendMode = renderer_bridge.policy.Mode;
const EventDisconnect = renderer_bridge.handlers.EventDisconnect;
const EventAck = renderer_bridge.handlers.EventAck;
const EventFetch = renderer_bridge.handlers.EventFetch;
const WorkbenchSnapshotChunk = renderer_bridge.handlers.WorkbenchSnapshotChunk;
const SessionCreate = renderer_bridge.handlers.SessionCreate;
const SessionRun = renderer_bridge.handlers.SessionRun;
const SessionIdentity = renderer_bridge.handlers.SessionIdentity;
const SessionClose = renderer_bridge.handlers.SessionClose;
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
    delivery: *bridge_delivery.Delivery,
    agent_runtime: ?*agent.Runtime = null,
    workbench: ?*workbench_api.Workbench = null,
    agent_shutdown: bool = false,
    main_thread_id: std.Thread.Id,
    mode: FrontendMode = .release,
    native_runtime: ?*native_sdk.Runtime = null,
    platform_services: ?native_sdk.platform.PlatformServices = null,
    event_window_id: ?native_sdk.platform.WindowId = null,
    fixture_thread: ?std.Thread = null,
    sequence: u64 = 0,
    acknowledged_sequence: u64 = 0,
    workspace_grants: renderer_bridge.workspace_grant.State = .{},
    revision_delivery: renderer_bridge.revision_delivery.State = .{},
    snapshot_delivery: renderer_bridge.snapshot_delivery.State = .{},
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
    handlers: [18]native_sdk.bridge.Handler = undefined,

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
    }

    fn stop(context: *anyopaque, native_runtime: *native_sdk.Runtime) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.joinFixtureWorker();
        if (self.platform_services) |services| {
            services.cancelTimer(delivery_retention_timer_id) catch {};
            services.cancelTimer(workbench_revision_retry_timer_id) catch {};
        }
        if (self.agent_runtime) |agent_runtime| {
            try agent_runtime.shutdown();
            self.agent_shutdown = true;
        }
        self.platform_services = null;
        self.event_window_id = null;
        self.workspace_grants.invalidate();
        self.invalidateSnapshot();
        if (self.native_runtime == native_runtime) self.native_runtime = null;
    }

    fn event(context: *anyopaque, native_runtime: *native_sdk.Runtime, value: native_sdk.Event) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        switch (value) {
            .effects_wake => {
                self.drainAgentEvents();
                self.expireDetachedRoutes(native_sdk.monotonicNanoseconds());
                if (self.event_window_id) |window_id| {
                    try self.emitAgentBatches(native_runtime, window_id);
                    try self.emitWorkbenchChanged(native_runtime, window_id);
                }
            },
            .timer => |timer| if (timer.id == delivery_retention_timer_id) {
                self.expireDetachedRoutes(native_sdk.monotonicNanoseconds());
            } else if (timer.id == workbench_revision_retry_timer_id) {
                if (self.event_window_id) |window_id| try self.emitWorkbenchChanged(native_runtime, window_id);
            },
            else => {},
        }
    }

    fn bridge(self: *@This(), mode: FrontendMode) native_sdk.BridgeDispatcher {
        self.mode = mode;
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
            .name = renderer_bridge.commands.fixture_ack,
            .context = self,
            .invoke_fn = acknowledgeAgentEvent,
        };
        self.handlers[5] = .{
            .name = renderer_bridge.commands.fixture_fetch,
            .context = self,
            .invoke_fn = fetchAgentEvent,
        };
        self.handlers[6] = .{
            .name = renderer_bridge.commands.fixture_emit,
            .context = self,
            .invoke_fn = emitGate5Fixture,
        };
        self.handlers[7] = .{
            .name = renderer_bridge.commands.choose_workspace,
            .context = self,
            .invoke_fn = chooseWorkspace,
        };
        self.handlers[8] = .{
            .name = renderer_bridge.commands.snapshot,
            .context = self,
            .invoke_fn = beginWorkbenchSnapshot,
        };
        self.handlers[9] = .{
            .name = renderer_bridge.commands.snapshot_chunk,
            .context = self,
            .invoke_fn = fetchWorkbenchSnapshotChunk,
        };
        self.handlers[10] = .{
            .name = renderer_bridge.commands.create_session,
            .context = self,
            .invoke_fn = createSession,
        };
        self.handlers[11] = .{
            .name = renderer_bridge.commands.run,
            .context = self,
            .invoke_fn = runSession,
        };
        self.handlers[12] = .{
            .name = renderer_bridge.commands.cancel,
            .context = self,
            .invoke_fn = cancelSession,
        };
        self.handlers[13] = .{
            .name = renderer_bridge.commands.respond_ui,
            .context = self,
            .invoke_fn = respondUi,
        };
        self.handlers[14] = .{
            .name = renderer_bridge.commands.close_session,
            .context = self,
            .invoke_fn = closeSession,
        };
        self.handlers[15] = .{
            .name = renderer_bridge.commands.rename_task,
            .context = self,
            .invoke_fn = renameTask,
        };
        self.handlers[16] = .{
            .name = renderer_bridge.commands.archive_task,
            .context = self,
            .invoke_fn = archiveTask,
        };
        self.handlers[17] = .{
            .name = renderer_bridge.commands.delete_task,
            .context = self,
            .invoke_fn = deleteTask,
        };
        return .{
            .policy = renderer_bridge.policy.product(mode),
            .registry = .{ .handlers = &self.handlers },
        };
    }

    fn ping(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        const native_runtime = self.native_runtime orelse return error.RuntimeUnavailable;
        self.sequence += 1;

        const on_main_thread = std.Thread.getCurrentId() == self.main_thread_id;
        var detail_buffer: [512]u8 = undefined;
        const detail = try std.fmt.bufPrint(
            &detail_buffer,
            "{{\"sequence\":{d},\"transport\":\"Runtime.emitWindowEvent\",\"origin\":\"{s}\",\"onMainThread\":{},\"requestBytes\":{d},\"automation\":{},\"gate5Fixture\":{}}}",
            .{
                self.sequence,
                invocation.source.origin,
                on_main_thread,
                invocation.request.payload.len,
                self.mode == .gate0_automation,
                envFlag(self.env_map, gate5_fixture_env),
            },
        );
        try native_runtime.emitWindowEvent(invocation.source.window_id, event_name, detail);

        return std.fmt.bufPrint(
            output,
            "{{\"sequence\":{d},\"transport\":\"BridgeDispatcher.response\",\"origin\":\"{s}\",\"onMainThread\":{},\"automation\":{},\"gate5Fixture\":{}}}",
            .{
                self.sequence,
                invocation.source.origin,
                on_main_thread,
                self.mode == .gate0_automation,
                envFlag(self.env_map, gate5_fixture_env),
            },
        );
    }

    fn acknowledgeEvent(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
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
        _ = self.native_runtime orelse return error.RuntimeUnavailable;
        const services = self.platform_services orelse return error.RuntimeUnavailable;
        if (self.event_window_id) |window_id|
            if (window_id != invocation.source.window_id) return error.EventWindowMismatch;
        self.expireDetachedRoutes(native_sdk.monotonicNanoseconds());
        try services.cancelTimer(delivery_retention_timer_id);
        const generation = try self.delivery.connect();
        self.event_window_id = invocation.source.window_id;
        self.invalidateSnapshot();
        errdefer {
            self.detachDelivery(generation) catch {};
            self.event_window_id = null;
        }
        try services.wake();
        return std.fmt.bufPrint(output, "{{\"generation\":\"{d}\"}}", .{generation});
    }

    fn disconnectEvents(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        var parsed = try parsePayload(EventDisconnect, invocation.request.payload);
        defer parsed.deinit();
        const request = parsed.value;
        const generation = try parseWireId(request.generation);
        if (self.event_window_id == null or self.event_window_id.? != invocation.source.window_id)
            return error.EventWindowMismatch;
        defer self.event_window_id = null;
        defer self.workspace_grants.invalidate();
        defer self.invalidateSnapshot();
        try self.detachDelivery(generation);
        return std.fmt.bufPrint(output, "{{\"generation\":\"{d}\",\"detached\":true}}", .{generation});
    }

    fn acknowledgeAgentEvent(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        var parsed = try parsePayload(EventAck, invocation.request.payload);
        defer parsed.deinit();
        const request = parsed.value;
        const generation = try parseWireId(request.generation);
        const session_id = try parseWireId(request.sessionId);
        const run_id = try parseWireId(request.runId);
        const sequence = try parseWireId(request.sequence);
        try self.requireEventWindow(invocation.source.window_id);
        try self.delivery.acknowledge(generation, session_id, run_id, sequence);
        std.debug.print("metawork.gate5.ack generation={d} session={d} run={d} sequence={d} main_thread={}\n", .{
            generation,
            session_id,
            run_id,
            sequence,
            std.Thread.getCurrentId() == self.main_thread_id,
        });
        return std.fmt.bufPrint(output, "{{\"generation\":\"{d}\",\"sequence\":\"{d}\"}}", .{ generation, sequence });
    }

    fn fetchAgentEvent(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        var parsed = try parsePayload(EventFetch, invocation.request.payload);
        defer parsed.deinit();
        const request = parsed.value;
        const generation = try parseWireId(request.generation);
        const session_id = try parseWireId(request.sessionId);
        const run_id = try parseWireId(request.runId);
        const object_id = try parseWireId(request.objectId);
        try self.requireEventWindow(invocation.source.window_id);
        const response = try self.delivery.fetchObject(
            generation,
            session_id,
            run_id,
            object_id,
            output,
        );
        std.debug.print("metawork.gate5.fetch generation={d} session={d} run={d} object={d} main_thread={}\n", .{
            generation,
            session_id,
            run_id,
            object_id,
            std.Thread.getCurrentId() == self.main_thread_id,
        });
        return response;
    }

    fn emitGate5Fixture(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (self.mode != .gate0_automation) return error.AutomationOnly;
        try self.requireEventWindow(invocation.source.window_id);
        _ = self.delivery.connectedGeneration() orelse return error.NoConnection;
        errdefer self.delivery.cleanupRun(1, 1);

        const allocator = std.heap.c_allocator;
        const inline_json = try allocator.dupe(u8, "{\"fixture\":\"inline\",\"payload\":\"gate5\"}");
        var inline_event = bridge_delivery.InputEvent{
            .session_id = 1,
            .run_id = 1,
            .json = inline_json,
            .allocator = allocator,
        };
        self.delivery.ingest(inline_event) catch |err| {
            inline_event.deinit();
            return err;
        };

        const object_len = 12 * 1024;
        const object_json = try allocator.alloc(u8, object_len);
        const prefix = "{\"fixture\":\"object\",\"payload\":\"";
        const suffix = "\"}";
        @memcpy(object_json[0..prefix.len], prefix);
        @memset(object_json[prefix.len .. object_json.len - suffix.len], 'x');
        @memcpy(object_json[object_json.len - suffix.len ..], suffix);
        var object_event = bridge_delivery.InputEvent{
            .session_id = 1,
            .run_id = 1,
            .json = object_json,
            .allocator = allocator,
        };
        self.delivery.ingest(object_event) catch |err| {
            object_event.deinit();
            return err;
        };

        self.joinFixtureWorker();
        const services = self.platform_services orelse return error.RuntimeUnavailable;
        self.fixture_thread = try std.Thread.spawn(.{}, wakeFixtureWorker, .{ services, self.main_thread_id });
        return std.fmt.bufPrint(output, "{{\"queued\":2,\"workerWake\":true}}", .{});
    }

    fn beginWorkbenchSnapshot(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        try self.requireEventWindow(invocation.source.window_id);
        const workbench = self.workbench orelse return error.RuntimeUnavailable;
        if (self.snapshot_delivery.storage.len != workbench_snapshot_capacity) return error.RuntimeUnavailable;
        self.invalidateSnapshot();
        const snapshot = try self.writeWorkbenchSnapshot(workbench);
        try self.snapshot_delivery.publish(
            snapshot.len,
            self.delivery.connectedGeneration() orelse return error.NoConnection,
            invocation.source.window_id,
        );
        return std.fmt.bufPrint(
            output,
            "{{\"snapshotId\":\"{d}\",\"bytes\":{d},\"chunkBytes\":{d}}}",
            .{ self.snapshot_delivery.id, self.snapshot_delivery.len, workbench_snapshot_chunk_bytes },
        );
    }

    fn fetchWorkbenchSnapshotChunk(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        try self.requireEventWindow(invocation.source.window_id);
        var parsed = try parsePayload(WorkbenchSnapshotChunk, invocation.request.payload);
        defer parsed.deinit();
        const snapshot_id = try parseWireId(parsed.value.snapshotId);
        const offset = std.fmt.parseInt(usize, parsed.value.offset, 10) catch return error.InvalidBridgePayload;
        const generation = self.delivery.connectedGeneration() orelse return error.NoConnection;
        const chunk = self.snapshot_delivery.chunk(
            snapshot_id,
            generation,
            invocation.source.window_id,
            offset,
        ) catch |err| switch (err) {
            error.StaleSnapshot => return error.StaleSnapshot,
            error.InvalidOffset => return error.InvalidBridgePayload,
            error.InvalidStorage => unreachable,
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
        try self.requireEventWindow(invocation.source.window_id);
        if (self.mode == .gate0_automation) return error.AutomationOnly;
        const generation = self.delivery.connectedGeneration() orelse return error.NoConnection;
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

    fn createSession(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        try self.requireEventWindow(invocation.source.window_id);
        var parsed = try parsePayload(SessionCreate, invocation.request.payload);
        defer parsed.deinit();
        const request = parsed.value;
        var granted_path_storage: [workspace_path_capacity]u8 = undefined;
        const canonical_input = if (self.mode == .gate0_automation) automation: {
            if (request.workspaceRoot == null or request.workspaceGrant != null) return error.InvalidBridgePayload;
            break :automation request.workspaceRoot.?;
        } else trusted: {
            if (request.workspaceRoot != null or request.workspaceGrant == null) return error.InvalidBridgePayload;
            const token = try parseWireId(request.workspaceGrant.?);
            const granted = try self.workspace_grants.consume(
                token,
                invocation.source.window_id,
                self.delivery.connectedGeneration() orelse return error.NoConnection,
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
        const workspace_trust: agent.WorkspaceTrust = if (self.mode == .gate0_automation)
            .{ .temporary = temp_root }
        else
            .explicitly_trusted;
        const credential = self.env_map.get("METAWORK_PROVIDER_API_KEY") orelse return error.ProviderCredentialMissing;
        const model = self.env_map.get("METAWORK_PROVIDER_MODEL") orelse return error.ProviderModelMissing;
        const provider = providerKind(self.env_map.get("METAWORK_PROVIDER_KIND") orelse "anthropic") orelse
            return error.UnsupportedProvider;
        const base_url = self.env_map.get("METAWORK_PROVIDER_BASE_URL") orelse "";
        const workbench = self.workbench orelse return error.RuntimeUnavailable;
        const session_id = try workbench.createSession(.{
            .provider_kind_code = provider,
            .permission_mode_code = agentcore.types.PERMISSION_DEFAULT,
            .shell_policy_code = agentcore.types.SHELL_UNRESTRICTED,
            .credential = credential,
            .model = model,
            .base_url = base_url,
            .workspace = .{
                .canonical_root = canonical,
                .trust = workspace_trust,
            },
        });
        self.notifyCommitted();
        return std.fmt.bufPrint(output, "{{\"sessionId\":\"{d}\"}}", .{session_id});
    }

    fn runSession(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        try self.requireEventWindow(invocation.source.window_id);
        var parsed = try parsePayloadWithLimit(SessionRun, invocation.request.payload, 128 * 1024);
        defer parsed.deinit();
        const session_id = try parseWireId(parsed.value.sessionId);
        if (parsed.value.prompt.len == 0) return error.EmptyPrompt;
        const run_id = try (self.workbench orelse return error.RuntimeUnavailable).submit(session_id, parsed.value.prompt);
        self.notifyCommitted();
        return std.fmt.bufPrint(output, "{{\"sessionId\":\"{d}\",\"runId\":\"{d}\"}}", .{ session_id, run_id });
    }

    fn cancelSession(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        try self.requireEventWindow(invocation.source.window_id);
        var parsed = try parsePayload(SessionIdentity, invocation.request.payload);
        defer parsed.deinit();
        const session_id = try parseWireId(parsed.value.sessionId);
        const run_id = try parseWireId(parsed.value.runId);
        try (self.workbench orelse return error.RuntimeUnavailable).cancel(session_id, run_id);
        self.notifyCommitted();
        return std.fmt.bufPrint(output, "{{\"sessionId\":\"{d}\",\"runId\":\"{d}\",\"cancelRequested\":true}}", .{ session_id, run_id });
    }

    fn respondUi(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        try self.requireEventWindow(invocation.source.window_id);
        var parsed = try parsePayloadWithLimit(UiResponseRequest, invocation.request.payload, 256 * 1024);
        defer parsed.deinit();
        const request = parsed.value;
        const session_id = try parseWireId(request.sessionId);
        const run_id = try parseWireId(request.runId);
        const request_id = try parseWireId(request.requestId);
        const response: agentcore.UiResponse = if (std.mem.eql(u8, request.kind, "answers")) answer: {
            if (request.answers == null or request.permission != null)
                return error.InvalidUiResponse;
            break :answer .{ .answers = request.answers.? };
        } else if (std.mem.eql(u8, request.kind, "permission")) permission: {
            if (request.answers != null or request.permission == null)
                return error.InvalidUiResponse;
            break :permission .{ .permission = permissionChoice(request.permission.?) orelse return error.InvalidUiResponse };
        } else return error.InvalidUiResponse;
        try (self.workbench orelse return error.RuntimeUnavailable).respondUi(session_id, run_id, request_id, response);
        self.notifyCommitted();
        return std.fmt.bufPrint(output, "{{\"sessionId\":\"{d}\",\"runId\":\"{d}\",\"requestId\":\"{d}\",\"answered\":true}}", .{ session_id, run_id, request_id });
    }

    fn closeSession(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        try self.requireEventWindow(invocation.source.window_id);
        var parsed = try parsePayload(SessionClose, invocation.request.payload);
        defer parsed.deinit();
        const session_id = try parseWireId(parsed.value.sessionId);
        try (self.workbench orelse return error.RuntimeUnavailable).closeSession(session_id);
        self.notifyCommitted();
        return std.fmt.bufPrint(output, "{{\"sessionId\":\"{d}\",\"closing\":true}}", .{session_id});
    }

    fn renameTask(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        try self.requireEventWindow(invocation.source.window_id);
        var parsed = try parsePayload(TaskRename, invocation.request.payload);
        defer parsed.deinit();
        const session_id = try parseWireId(parsed.value.sessionId);
        try (self.workbench orelse return error.RuntimeUnavailable).renameTask(session_id, parsed.value.title);
        self.notifyCommitted();
        return std.fmt.bufPrint(output, "{{\"sessionId\":\"{d}\",\"renamed\":true}}", .{session_id});
    }

    fn archiveTask(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        try self.requireEventWindow(invocation.source.window_id);
        var parsed = try parsePayload(TaskArchive, invocation.request.payload);
        defer parsed.deinit();
        const session_id = try parseWireId(parsed.value.sessionId);
        try (self.workbench orelse return error.RuntimeUnavailable).setTaskArchived(session_id, parsed.value.archived);
        self.notifyCommitted();
        return std.fmt.bufPrint(output, "{{\"sessionId\":\"{d}\",\"archived\":{}}}", .{ session_id, parsed.value.archived });
    }

    fn deleteTask(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        try self.requireEventWindow(invocation.source.window_id);
        var parsed = try parsePayload(TaskDelete, invocation.request.payload);
        defer parsed.deinit();
        const session_id = try parseWireId(parsed.value.sessionId);
        try (self.workbench orelse return error.RuntimeUnavailable).deleteTask(session_id);
        self.notifyCommitted();
        return std.fmt.bufPrint(output, "{{\"sessionId\":\"{d}\",\"deleted\":true}}", .{session_id});
    }

    fn emitAgentBatches(self: *@This(), native_runtime: *native_sdk.Runtime, window_id: native_sdk.platform.WindowId) !void {
        const generation = self.delivery.connectedGeneration() orelse return;
        while (try self.delivery.buildBatch(generation)) |value| {
            var batch = value;
            defer batch.deinit();
            native_runtime.emitWindowEvent(window_id, agent_event_name, batch.json) catch |err| {
                if (self.agent_runtime) |agent_runtime| {
                    for (0..batch.item_count) |index| {
                        const route = self.delivery.batchRoute(&batch, index) catch continue;
                        agent_runtime.failRun(route.session_id, route.run_id, .bridge_pipeline_failure) catch {};
                        self.delivery.cleanupRun(route.session_id, route.run_id);
                    }
                }
                self.detachDelivery(generation) catch {};
                self.event_window_id = null;
                return err;
            };
            try self.delivery.commitBatch(&batch);
            std.debug.print("metawork.gate5.emit generation={d} items={d} bytes={d} main_thread={}\n", .{
                batch.generation,
                batch.item_count,
                batch.json.len,
                std.Thread.getCurrentId() == self.main_thread_id,
            });
        }
    }

    fn emitWorkbenchChanged(self: *@This(), native_runtime: ?*native_sdk.Runtime, window_id: native_sdk.platform.WindowId) !void {
        const workbench = self.workbench orelse return;
        const revision = workbench.currentRevision();
        if (!self.revision_delivery.needsDelivery(revision)) return;
        var detail_buffer: [96]u8 = undefined;
        const detail = try std.fmt.bufPrint(&detail_buffer, "{{\"revision\":\"{d}\"}}", .{revision});
        self.emitWindowEvent(native_runtime, window_id, workbench_event_name, detail) catch |err| {
            self.revision_delivery.fail();
            const services = self.platform_services orelse {
                self.breakEventConnection();
                return error.WorkbenchRevisionDeliveryUnavailable;
            };
            services.startTimer(
                workbench_revision_retry_timer_id,
                renderer_bridge.revision_delivery.retry_interval_ns,
                false,
            ) catch |timer_err| {
                std.log.warn("Workbench revision {d} delivery and retry scheduling failed: emit={s} timer={s}", .{
                    revision,
                    @errorName(err),
                    @errorName(timer_err),
                });
                self.breakEventConnection();
                return error.WorkbenchRevisionDeliveryUnavailable;
            };
            return;
        };
        self.revision_delivery.commit(revision);
        if (self.platform_services) |services|
            services.cancelTimer(workbench_revision_retry_timer_id) catch {};
    }

    fn breakEventConnection(self: *@This()) void {
        if (self.delivery.connectedGeneration()) |generation|
            self.detachDelivery(generation) catch {};
        self.event_window_id = null;
        self.workspace_grants.invalidate();
        self.invalidateSnapshot();
    }

    fn drainAgentEvents(self: *@This()) void {
        const agent_runtime = self.agent_runtime orelse return;
        while (agent_runtime.takeEvent()) |value| {
            var envelope = value;
            defer envelope.deinit();
            if (self.workbench) |workbench| workbench.applyEvent(&envelope) catch {
                const session_id = envelope.session_id;
                const run_id = envelope.run_id;
                agent_runtime.failRun(session_id, run_id, .bridge_pipeline_failure) catch {};
                continue;
            };
        }
    }

    fn expireDetachedRoutes(self: *@This(), now_ns: u64) void {
        while (self.delivery.firstExpired(now_ns)) |route| {
            if (self.agent_runtime) |agent_runtime|
                agent_runtime.failRun(route.session_id, route.run_id, .bridge_pipeline_failure) catch {};
            self.delivery.cleanupRun(route.session_id, route.run_id);
        }
    }

    fn detachDelivery(self: *@This(), generation: u64) !void {
        try self.delivery.detach(generation, native_sdk.monotonicNanoseconds());
        const services = self.platform_services orelse return error.RuntimeUnavailable;
        services.startTimer(
            delivery_retention_timer_id,
            self.delivery.retentionNanoseconds(),
            false,
        ) catch |err| {
            // Without a deadline source, keeping detached events would make
            // the advertised retention TTL a lie. Fail the affected routes now.
            self.expireDetachedRoutes(std.math.maxInt(u64));
            return err;
        };
    }

    fn notifyMainLoop(context: ?*anyopaque) bool {
        const self: *@This() = @ptrCast(@alignCast(context orelse return false));
        const services = self.platform_services orelse return false;
        services.wake() catch return false;
        return true;
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

    fn requireEventWindow(self: *@This(), window_id: native_sdk.platform.WindowId) !void {
        if (self.event_window_id == null or self.event_window_id.? != window_id)
            return error.EventWindowMismatch;
    }

    fn invalidateSnapshot(self: *@This()) void {
        self.snapshot_delivery.invalidate();
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

    fn writeWorkbenchSnapshot(self: *@This(), workbench_state: *workbench_api.Workbench) ![]const u8 {
        if (self.snapshot_write_override) |write|
            return write(self.snapshot_write_context, workbench_state, self.snapshot_delivery.storage);
        return workbench_state.writeSnapshot(self.snapshot_delivery.storage);
    }

    fn joinFixtureWorker(self: *@This()) void {
        if (self.fixture_thread) |thread| {
            thread.join();
            self.fixture_thread = null;
        }
    }
};

fn providerKind(value: []const u8) ?u32 {
    if (std.mem.eql(u8, value, "anthropic")) return agentcore.types.PROVIDER_ANTHROPIC;
    if (std.mem.eql(u8, value, "openai")) return agentcore.types.PROVIDER_OPENAI;
    if (std.mem.eql(u8, value, "gemini")) return agentcore.types.PROVIDER_GEMINI;
    return null;
}

fn wakeFixtureWorker(services: native_sdk.platform.PlatformServices, main_thread_id: std.Thread.Id) void {
    const worker_thread_id = std.Thread.getCurrentId();
    std.debug.assert(worker_thread_id != main_thread_id);
    services.wake() catch |err| {
        std.debug.print("metawork.gate5.wake_failed error={s}\n", .{@errorName(err)});
        return;
    };
    std.debug.print("metawork.gate5.worker_wake off_main_thread=true\n", .{});
}

fn builtinBridgePolicy(mode: FrontendMode) native_sdk.BridgePolicy {
    return renderer_bridge.policy.builtin(mode);
}

fn frontendMode(env_map: *std.process.Environ.Map) FrontendMode {
    if (env_map.get(frontend_url_env) != null) return .development;
    if (env_map.get(gate0_automation_env)) |value| {
        if (std.mem.eql(u8, value, "1")) return .gate0_automation;
    }
    return .release;
}

fn envFlag(env_map: *std.process.Environ.Map, name: []const u8) bool {
    const value = env_map.get(name) orelse return false;
    return std.mem.eql(u8, value, "1");
}

fn allowedOrigins(mode: FrontendMode) []const []const u8 {
    return renderer_bridge.policy.origins(mode);
}

fn createAgentRuntime(
    io: std.Io,
    raw_api: *const agentcore.types.ApiV1,
    notifier: agent.Notifier,
) !*agent.Runtime {
    const executor = try workbench_api.Executor.create(
        io,
        std.heap.c_allocator,
        .{ .worker_count = host_worker_count, .queue_capacity = 8 },
    );
    errdefer executor.destroy();
    return agent.Runtime.init(io, std.heap.c_allocator, raw_api, executor.scheduler(), .{
        .max_sessions = 8,
        .max_ui_request_bytes = pending_ui_json_capacity,
        .notifier = notifier,
    });
}

pub fn run(init: std.process.Init) !void {
    var delivery = try bridge_delivery.Delivery.init(std.heap.c_allocator, .{ .route_slots = 16 });
    defer delivery.deinit();
    const snapshot_storage = try std.heap.c_allocator.alloc(u8, workbench_snapshot_capacity);
    defer std.heap.c_allocator.free(snapshot_storage);
    var app = App{
        .env_map = init.environ_map,
        .io = init.io,
        .delivery = &delivery,
        .main_thread_id = std.Thread.getCurrentId(),
        .snapshot_delivery = try renderer_bridge.snapshot_delivery.State.init(snapshot_storage),
    };
    const api = try agentcore.Api.discover();
    const agent_runtime = try createAgentRuntime(init.io, api.raw, .{ .context = &app, .wake = App.notifyMainLoop });
    app.agent_runtime = agent_runtime;
    var workbench_state: workbench_api.Workbench = undefined;
    var workbench_initialized = false;
    defer {
        if (!app.agent_shutdown) agent_runtime.shutdown() catch {};
        if (workbench_initialized) workbench_state.deinit();
        agent_runtime.deinit();
    }
    workbench_state = try workbench_api.Workbench.initWithNotifier(
        std.heap.c_allocator,
        agent_runtime,
        .{
            .max_pending_ui_json_bytes = pending_ui_json_capacity,
            .max_pending_ui_requests = host_worker_count,
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
        .builtin_bridge = builtinBridgePolicy(mode),
        .js_window_api = true,
        .security = .{
            .permissions = &renderer_bridge.policy.window_permissions,
            .navigation = .{ .allowed_origins = allowedOrigins(mode) },
        },
    }, init);
}

test "transport limits and origin sets are explicit" {
    try std.testing.expectEqual(@as(usize, 1024 * 1024), native_sdk.bridge.max_message_bytes);
    try std.testing.expectEqual(@as(usize, 1024 * 1024), native_sdk.bridge.max_result_bytes);
    try std.testing.expectEqual(@as(usize, 1024 * 1024), native_sdk.bridge.max_response_bytes);
    try std.testing.expectEqual(@as(usize, 8192), native_sdk.platform.max_window_event_detail_bytes);
    try std.testing.expectEqual(@as(usize, 1), allowedOrigins(.release).len);
    try std.testing.expectEqual(@as(usize, 2), allowedOrigins(.development).len);
    try std.testing.expectEqual(@as(usize, 2), allowedOrigins(.gate0_automation).len);
}

test "bridge rejects an untrusted origin before handler dispatch" {
    var delivery = try bridge_delivery.Delivery.init(std.testing.allocator, .{ .route_slots = 4 });
    defer delivery.deinit();
    var app = App{
        .env_map = undefined,
        .io = std.testing.io,
        .delivery = &delivery,
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

test "release policy cannot dispatch the Gate 5 automation fixture" {
    var delivery = try bridge_delivery.Delivery.init(std.testing.allocator, .{ .route_slots = 4 });
    defer delivery.deinit();
    var app = App{
        .env_map = undefined,
        .io = std.testing.io,
        .delivery = &delivery,
        .main_thread_id = std.Thread.getCurrentId(),
    };
    var response_buffer: [512]u8 = undefined;
    const response = app.bridge(.release).dispatch(
        "{\"id\":\"fixture-policy\",\"command\":\"metawork.gate5.emitFixture\",\"payload\":{}}",
        .{ .origin = "zero://app", .window_id = 1 },
        &response_buffer,
    );
    try std.testing.expect(std.mem.indexOf(u8, response, "\"permission_denied\"") != null);
    try std.testing.expectEqual(@as(usize, 0), delivery.stats().retained_count);
}

test "event acknowledgement payload is exact and bounded" {
    try std.testing.expectEqual(@as(u64, 42), try acknowledgementSequence("{\"sequence\":42}"));
    try std.testing.expectError(error.InvalidAcknowledgement, acknowledgementSequence("{\"sequence\":42,\"extra\":true}"));
    try std.testing.expectError(error.InvalidAcknowledgement, acknowledgementSequence("{\"sequence\":-1}"));
    try std.testing.expectError(error.InvalidAcknowledgement, acknowledgementSequence("{\"sequence\":01}"));
}

test "Workspace trust grants are bound to window and generation and consumed once" {
    var delivery = try bridge_delivery.Delivery.init(std.testing.allocator, .{ .route_slots = 4 });
    defer delivery.deinit();
    var app = App{
        .env_map = undefined,
        .io = std.testing.io,
        .delivery = &delivery,
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
    var delivery = try bridge_delivery.Delivery.init(std.testing.allocator, .{ .route_slots = 4 });
    defer delivery.deinit();
    const generation = try delivery.connect();
    var app = App{
        .env_map = undefined,
        .io = std.testing.io,
        .delivery = &delivery,
        .main_thread_id = std.Thread.getCurrentId(),
        .mode = .release,
        .event_window_id = 3,
        .platform_services = .{
            .context = &harness,
            .show_open_dialog_fn = Harness.open,
            .show_message_dialog_fn = Harness.confirm,
        },
    };
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
    var delivery = try bridge_delivery.Delivery.init(std.testing.allocator, .{ .route_slots = 4 });
    defer delivery.deinit();
    var app = App{
        .env_map = undefined,
        .io = std.testing.io,
        .delivery = &delivery,
        .main_thread_id = std.Thread.getCurrentId(),
        .platform_services = .{ .context = &harness, .wake_fn = Harness.wake },
    };
    app.notifyCommitted();
    try std.testing.expectEqual(@as(usize, 1), harness.wake_calls);
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
            try std.testing.expectEqualStrings(workbench_event_name, name);
            if (self.emit_calls == 1) return error.InjectedEmitFailure;
            @memcpy(self.last_detail[0..detail.len], detail);
            self.last_detail_len = detail.len;
        }

        fn startTimer(context: ?*anyopaque, id: u64, interval_ns: u64, repeats: bool) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.timer_starts += 1;
            try std.testing.expectEqual(workbench_revision_retry_timer_id, id);
            try std.testing.expect(interval_ns > 0);
            try std.testing.expect(!repeats);
        }

        fn cancelTimer(context: ?*anyopaque, id: u64) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.timer_cancels += 1;
            try std.testing.expectEqual(workbench_revision_retry_timer_id, id);
        }
    };
    var harness = Harness{};
    var delivery = try bridge_delivery.Delivery.init(std.testing.allocator, .{ .route_slots = 4 });
    defer delivery.deinit();
    var workbench = try workbench_api.Workbench.init(std.testing.allocator, undefined, .{});
    defer workbench.deinit();
    workbench.revision = 7;
    var app = App{
        .env_map = undefined,
        .io = std.testing.io,
        .delivery = &delivery,
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

    try app.emitWorkbenchChanged(null, 4);
    try std.testing.expect(app.revision_delivery.pending);
    try std.testing.expectEqual(@as(u64, 0), app.revision_delivery.last_emitted);
    workbench.revision = 9;
    try app.emitWorkbenchChanged(null, 4);
    try std.testing.expect(!app.revision_delivery.pending);
    try std.testing.expectEqual(@as(u64, 9), app.revision_delivery.last_emitted);
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
            if (id == workbench_revision_retry_timer_id) return error.InjectedTimerFailure;
        }

        fn cancelTimer(context: ?*anyopaque, id: u64) anyerror!void {
            _ = context;
            _ = id;
        }
    };
    var delivery = try bridge_delivery.Delivery.init(std.testing.allocator, .{ .route_slots = 4 });
    defer delivery.deinit();
    _ = try delivery.connect();
    var workbench = try workbench_api.Workbench.init(std.testing.allocator, undefined, .{});
    defer workbench.deinit();
    workbench.revision = 1;
    var app = App{
        .env_map = undefined,
        .io = std.testing.io,
        .delivery = &delivery,
        .workbench = &workbench,
        .main_thread_id = std.Thread.getCurrentId(),
        .event_window_id = 4,
        .platform_services = .{
            .start_timer_fn = Harness.startTimer,
            .cancel_timer_fn = Harness.cancelTimer,
        },
        .emit_window_event_override = Harness.emit,
    };

    try std.testing.expectError(
        error.WorkbenchRevisionDeliveryUnavailable,
        app.emitWorkbenchChanged(null, 4),
    );
    try std.testing.expectEqual(@as(?native_sdk.platform.WindowId, null), app.event_window_id);
    try std.testing.expectEqual(@as(?u64, null), delivery.connectedGeneration());
    try std.testing.expectEqual(@as(usize, 0), app.snapshot_delivery.len);
}

test "Workbench snapshot chunk handler binds identity generation and offset" {
    var delivery = try bridge_delivery.Delivery.init(std.testing.allocator, .{ .route_slots = 4 });
    defer delivery.deinit();
    const generation = try delivery.connect();
    var snapshot_storage = [_]u8{ 0, 1, 2, 3, 254, 255 };
    var app = App{
        .env_map = undefined,
        .io = std.testing.io,
        .delivery = &delivery,
        .main_thread_id = std.Thread.getCurrentId(),
        .event_window_id = 2,
        .snapshot_delivery = .{
            .storage = &snapshot_storage,
            .len = snapshot_storage.len,
            .id = 5,
            .generation = generation,
            .window_id = 2,
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
    var delivery = try bridge_delivery.Delivery.init(std.testing.allocator, .{ .route_slots = 4 });
    defer delivery.deinit();
    const generation = try delivery.connect();
    var workbench = try workbench_api.Workbench.init(std.testing.allocator, undefined, .{});
    defer workbench.deinit();
    const snapshot_storage = try std.testing.allocator.alloc(u8, workbench_snapshot_capacity);
    defer std.testing.allocator.free(snapshot_storage);
    var app = App{
        .env_map = undefined,
        .io = std.testing.io,
        .delivery = &delivery,
        .workbench = &workbench,
        .main_thread_id = std.Thread.getCurrentId(),
        .event_window_id = 2,
        .snapshot_delivery = try renderer_bridge.snapshot_delivery.State.init(snapshot_storage),
        .snapshot_write_override = Harness.write,
    };
    app.snapshot_delivery.len = 128;
    app.snapshot_delivery.id = 9;
    app.snapshot_delivery.generation = generation;
    app.snapshot_delivery.window_id = 2;
    var output: [512]u8 = undefined;
    try std.testing.expectError(
        error.InjectedSnapshotFailure,
        App.beginWorkbenchSnapshot(&app, .{
            .request = .{ .id = "begin", .command = "metawork.workbench.snapshot", .payload = "{}" },
            .source = .{ .origin = "zero://app", .window_id = 2 },
        }, &output),
    );
    try std.testing.expectEqual(@as(usize, 0), app.snapshot_delivery.len);
    try std.testing.expectEqual(@as(u64, 0), app.snapshot_delivery.generation);
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

test "expired detached delivery is cleaned before a Renderer reconnect" {
    var delivery = try bridge_delivery.Delivery.init(std.testing.allocator, .{
        .route_slots = 4,
        .retention_ns = 10,
    });
    defer delivery.deinit();
    const generation = try delivery.connect();
    const json = try std.testing.allocator.dupe(u8, "{\"text_chunk\":\"stale\"}");
    try delivery.ingest(.{
        .session_id = 1,
        .run_id = 2,
        .json = json,
        .allocator = std.testing.allocator,
    });
    try delivery.detach(generation, 100);
    var app = App{
        .env_map = undefined,
        .io = std.testing.io,
        .delivery = &delivery,
        .main_thread_id = std.Thread.getCurrentId(),
    };
    app.expireDetachedRoutes(109);
    try std.testing.expectEqual(@as(usize, 1), delivery.stats().retained_count);
    app.expireDetachedRoutes(110);
    try std.testing.expectEqual(@as(usize, 0), delivery.stats().retained_count);
    try std.testing.expectEqual(@as(?bridge_delivery.ExpiredRoute, null), delivery.firstExpired(111));
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

    var rename = try parsePayload(TaskRename, "{\"sessionId\":\"7\",\"title\":\"Release audit\"}");
    defer rename.deinit();
    try std.testing.expectEqualStrings("7", rename.value.sessionId);
    try std.testing.expectEqualStrings("Release audit", rename.value.title);
    try std.testing.expectError(
        error.InvalidBridgePayload,
        parsePayload(TaskRename, "{\"sessionId\":\"7\",\"title\":\"Release audit\",\"legacy\":true}"),
    );
    var archive = try parsePayload(TaskArchive, "{\"sessionId\":\"7\",\"archived\":true}");
    defer archive.deinit();
    try std.testing.expect(archive.value.archived);
}
