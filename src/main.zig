const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");
const bridge_delivery = @import("host/bridge_delivery.zig");
const agentcore = @import("metacodes_agentcore");
const host_lifecycle = @import("host_lifecycle");
const host_workbench = @import("host_workbench");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const frontend_url_env = "NATIVE_SDK_FRONTEND_URL";
const gate0_automation_env = "METAWORK_GATE0_AUTOMATION";
const gate5_fixture_env = "METAWORK_GATE5_FIXTURE";
const delivery_retention_timer_id: u64 = 0x4d57_4445_4c49_5652;
const event_name = "metawork:host-signal";
const agent_event_name = "metawork:agent-events";
const workbench_event_name = "metawork:workbench-changed";

const FrontendMode = enum {
    release,
    development,
    gate0_automation,
};

const release_origins = [_][]const u8{"zero://app"};
const development_origins = [_][]const u8{ "zero://app", "http://127.0.0.1:5173" };
const gate0_automation_origins = [_][]const u8{ "zero://app", "zero://inline" };
const window_permissions = [_][]const u8{native_sdk.security.permission_window};

const release_bridge_commands = [_]native_sdk.bridge.CommandPolicy{
    .{
        .name = "metawork.smoke.ping",
        .origins = &release_origins,
    },
    .{
        .name = "metawork.smoke.eventAck",
        .origins = &release_origins,
    },
    .{ .name = "metawork.events.connect", .origins = &release_origins },
    .{ .name = "metawork.events.disconnect", .origins = &release_origins },
    .{ .name = "metawork.events.ack", .origins = &release_origins },
    .{ .name = "metawork.events.fetch", .origins = &release_origins },
    .{ .name = "metawork.workbench.snapshot", .origins = &release_origins },
    .{ .name = "metawork.sessions.create", .origins = &release_origins },
    .{ .name = "metawork.sessions.run", .origins = &release_origins },
    .{ .name = "metawork.sessions.cancel", .origins = &release_origins },
    .{ .name = "metawork.sessions.respondUi", .origins = &release_origins },
    .{ .name = "metawork.sessions.close", .origins = &release_origins },
};
const development_bridge_commands = [_]native_sdk.bridge.CommandPolicy{
    .{
        .name = "metawork.smoke.ping",
        .origins = &development_origins,
    },
    .{
        .name = "metawork.smoke.eventAck",
        .origins = &development_origins,
    },
    .{ .name = "metawork.events.connect", .origins = &development_origins },
    .{ .name = "metawork.events.disconnect", .origins = &development_origins },
    .{ .name = "metawork.events.ack", .origins = &development_origins },
    .{ .name = "metawork.events.fetch", .origins = &development_origins },
    .{ .name = "metawork.workbench.snapshot", .origins = &development_origins },
    .{ .name = "metawork.sessions.create", .origins = &development_origins },
    .{ .name = "metawork.sessions.run", .origins = &development_origins },
    .{ .name = "metawork.sessions.cancel", .origins = &development_origins },
    .{ .name = "metawork.sessions.respondUi", .origins = &development_origins },
    .{ .name = "metawork.sessions.close", .origins = &development_origins },
};
const gate0_automation_bridge_commands = [_]native_sdk.bridge.CommandPolicy{
    .{
        .name = "metawork.smoke.ping",
        .origins = &gate0_automation_origins,
    },
    .{
        .name = "metawork.smoke.eventAck",
        .origins = &gate0_automation_origins,
    },
    .{ .name = "metawork.events.connect", .origins = &gate0_automation_origins },
    .{ .name = "metawork.events.disconnect", .origins = &gate0_automation_origins },
    .{ .name = "metawork.events.ack", .origins = &gate0_automation_origins },
    .{ .name = "metawork.events.fetch", .origins = &gate0_automation_origins },
    .{ .name = "metawork.workbench.snapshot", .origins = &gate0_automation_origins },
    .{ .name = "metawork.sessions.create", .origins = &gate0_automation_origins },
    .{ .name = "metawork.sessions.run", .origins = &gate0_automation_origins },
    .{ .name = "metawork.sessions.cancel", .origins = &gate0_automation_origins },
    .{ .name = "metawork.sessions.respondUi", .origins = &gate0_automation_origins },
    .{ .name = "metawork.sessions.close", .origins = &gate0_automation_origins },
    .{ .name = "metawork.gate5.emitFixture", .origins = &gate0_automation_origins },
};

const release_builtin_commands = [_]native_sdk.bridge.CommandPolicy{
    .{ .name = "native-sdk.window.list", .permissions = &window_permissions, .origins = &release_origins },
    .{ .name = "native-sdk.window.create", .permissions = &window_permissions, .origins = &release_origins },
    .{ .name = "native-sdk.window.close", .permissions = &window_permissions, .origins = &release_origins },
    .{ .name = "native-sdk.dialog.openFile", .origins = &release_origins },
};
const development_builtin_commands = [_]native_sdk.bridge.CommandPolicy{
    .{ .name = "native-sdk.window.list", .permissions = &window_permissions, .origins = &development_origins },
    .{ .name = "native-sdk.window.create", .permissions = &window_permissions, .origins = &development_origins },
    .{ .name = "native-sdk.window.close", .permissions = &window_permissions, .origins = &development_origins },
    .{ .name = "native-sdk.dialog.openFile", .origins = &development_origins },
};
const gate0_automation_builtin_commands = [_]native_sdk.bridge.CommandPolicy{
    .{ .name = "native-sdk.window.list", .permissions = &window_permissions, .origins = &gate0_automation_origins },
    .{ .name = "native-sdk.window.create", .permissions = &window_permissions, .origins = &gate0_automation_origins },
    .{ .name = "native-sdk.window.close", .permissions = &window_permissions, .origins = &gate0_automation_origins },
    .{ .name = "native-sdk.dialog.openFile", .origins = &gate0_automation_origins },
};

const App = struct {
    env_map: *std.process.Environ.Map,
    io: std.Io,
    delivery: *bridge_delivery.Delivery,
    host: ?*host_lifecycle.Host = null,
    workbench: ?*host_workbench.Workbench = null,
    host_shutdown: bool = false,
    main_thread_id: std.Thread.Id,
    mode: FrontendMode = .release,
    runtime: ?*native_sdk.Runtime = null,
    platform_services: ?native_sdk.platform.PlatformServices = null,
    event_window_id: ?native_sdk.platform.WindowId = null,
    fixture_thread: ?std.Thread = null,
    sequence: u64 = 0,
    acknowledged_sequence: u64 = 0,
    handlers: [13]native_sdk.bridge.Handler = undefined,

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

    fn start(context: *anyopaque, runtime: *native_sdk.Runtime) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.runtime = runtime;
        self.platform_services = runtime.options.platform.services;
    }

    fn stop(context: *anyopaque, runtime: *native_sdk.Runtime) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.joinFixtureWorker();
        if (self.platform_services) |services|
            services.cancelTimer(delivery_retention_timer_id) catch {};
        if (self.host) |host| {
            try host.shutdown();
            self.host_shutdown = true;
        }
        self.platform_services = null;
        self.event_window_id = null;
        if (self.runtime == runtime) self.runtime = null;
    }

    fn event(context: *anyopaque, runtime: *native_sdk.Runtime, value: native_sdk.Event) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        switch (value) {
            .effects_wake => {
                self.drainHostEvents();
                self.expireDetachedRoutes(native_sdk.monotonicNanoseconds());
                if (self.event_window_id) |window_id| {
                    try self.emitAgentBatches(runtime, window_id);
                    try self.emitWorkbenchChanged(runtime, window_id);
                }
            },
            .timer => |timer| if (timer.id == delivery_retention_timer_id) {
                self.expireDetachedRoutes(native_sdk.monotonicNanoseconds());
            },
            else => {},
        }
    }

    fn bridge(self: *@This(), mode: FrontendMode) native_sdk.BridgeDispatcher {
        self.mode = mode;
        self.handlers[0] = .{
            .name = "metawork.smoke.ping",
            .context = self,
            .invoke_fn = ping,
        };
        self.handlers[1] = .{
            .name = "metawork.smoke.eventAck",
            .context = self,
            .invoke_fn = acknowledgeEvent,
        };
        self.handlers[2] = .{
            .name = "metawork.events.connect",
            .context = self,
            .invoke_fn = connectEvents,
        };
        self.handlers[3] = .{
            .name = "metawork.events.disconnect",
            .context = self,
            .invoke_fn = disconnectEvents,
        };
        self.handlers[4] = .{
            .name = "metawork.events.ack",
            .context = self,
            .invoke_fn = acknowledgeAgentEvent,
        };
        self.handlers[5] = .{
            .name = "metawork.events.fetch",
            .context = self,
            .invoke_fn = fetchAgentEvent,
        };
        self.handlers[6] = .{
            .name = "metawork.gate5.emitFixture",
            .context = self,
            .invoke_fn = emitGate5Fixture,
        };
        self.handlers[7] = .{
            .name = "metawork.workbench.snapshot",
            .context = self,
            .invoke_fn = snapshotWorkbench,
        };
        self.handlers[8] = .{
            .name = "metawork.sessions.create",
            .context = self,
            .invoke_fn = createSession,
        };
        self.handlers[9] = .{
            .name = "metawork.sessions.run",
            .context = self,
            .invoke_fn = runSession,
        };
        self.handlers[10] = .{
            .name = "metawork.sessions.cancel",
            .context = self,
            .invoke_fn = cancelSession,
        };
        self.handlers[11] = .{
            .name = "metawork.sessions.respondUi",
            .context = self,
            .invoke_fn = respondUi,
        };
        self.handlers[12] = .{
            .name = "metawork.sessions.close",
            .context = self,
            .invoke_fn = closeSession,
        };
        return .{
            .policy = .{
                .enabled = true,
                .commands = switch (mode) {
                    .release => &release_bridge_commands,
                    .development => &development_bridge_commands,
                    .gate0_automation => &gate0_automation_bridge_commands,
                },
            },
            .registry = .{ .handlers = &self.handlers },
        };
    }

    fn ping(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        const runtime = self.runtime orelse return error.RuntimeUnavailable;
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
        try runtime.emitWindowEvent(invocation.source.window_id, event_name, detail);

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
        _ = self.runtime orelse return error.RuntimeUnavailable;
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
        _ = self.runtime orelse return error.RuntimeUnavailable;
        const services = self.platform_services orelse return error.RuntimeUnavailable;
        if (self.event_window_id) |window_id|
            if (window_id != invocation.source.window_id) return error.EventWindowMismatch;
        self.expireDetachedRoutes(native_sdk.monotonicNanoseconds());
        try services.cancelTimer(delivery_retention_timer_id);
        const generation = try self.delivery.connect();
        self.event_window_id = invocation.source.window_id;
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

    fn snapshotWorkbench(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        try self.requireEventWindow(invocation.source.window_id);
        const workbench = self.workbench orelse return error.RuntimeUnavailable;
        return workbench.writeSnapshot(output);
    }

    fn createSession(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        try self.requireEventWindow(invocation.source.window_id);
        var parsed = try parsePayload(SessionCreate, invocation.request.payload);
        defer parsed.deinit();
        const request = parsed.value;
        if (!request.trusted and self.mode != .gate0_automation) return error.WorkspaceNotTrusted;
        const canonical = try std.Io.Dir.realPathFileAbsoluteAlloc(self.io, request.workspaceRoot, std.heap.c_allocator);
        defer std.heap.c_allocator.free(canonical);
        const workspace_stat = try std.Io.Dir.cwd().statFile(self.io, canonical, .{});
        if (workspace_stat.kind != .directory) return error.InvalidWorkspace;
        const temp_root = try std.Io.Dir.realPathFileAbsoluteAlloc(self.io, "/tmp", std.heap.c_allocator);
        defer std.heap.c_allocator.free(temp_root);
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
                .trust = if (request.trusted) .explicitly_trusted else .{ .temporary = temp_root },
            },
        });
        try self.wakePlatform();
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
        try self.wakePlatform();
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
        try self.wakePlatform();
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
            if (request.answers == null or request.permission != null or request.planApproval != null or request.custom != null)
                return error.InvalidUiResponse;
            break :answer .{ .answers = request.answers.? };
        } else if (std.mem.eql(u8, request.kind, "permission")) permission: {
            if (request.answers != null or request.permission == null or request.planApproval != null or request.custom != null)
                return error.InvalidUiResponse;
            break :permission .{ .permission = permissionChoice(request.permission.?) orelse return error.InvalidUiResponse };
        } else if (std.mem.eql(u8, request.kind, "plan_approval")) plan: {
            if (request.answers != null or request.permission != null or request.planApproval == null or request.custom != null)
                return error.InvalidUiResponse;
            break :plan .{ .plan_approval = planApproval(request.planApproval.?) orelse return error.InvalidUiResponse };
        } else if (std.mem.eql(u8, request.kind, "custom")) custom: {
            if (request.answers != null or request.permission != null or request.planApproval != null or request.custom == null)
                return error.InvalidUiResponse;
            break :custom .{ .custom = request.custom.? };
        } else return error.InvalidUiResponse;
        try (self.workbench orelse return error.RuntimeUnavailable).respondUi(session_id, run_id, request_id, response);
        try self.wakePlatform();
        return std.fmt.bufPrint(output, "{{\"sessionId\":\"{d}\",\"runId\":\"{d}\",\"requestId\":\"{d}\",\"answered\":true}}", .{ session_id, run_id, request_id });
    }

    fn closeSession(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        try self.requireEventWindow(invocation.source.window_id);
        var parsed = try parsePayload(SessionClose, invocation.request.payload);
        defer parsed.deinit();
        const session_id = try parseWireId(parsed.value.sessionId);
        try (self.workbench orelse return error.RuntimeUnavailable).closeSession(session_id);
        try self.wakePlatform();
        return std.fmt.bufPrint(output, "{{\"sessionId\":\"{d}\",\"closing\":true}}", .{session_id});
    }

    fn emitAgentBatches(self: *@This(), runtime: *native_sdk.Runtime, window_id: native_sdk.platform.WindowId) !void {
        const generation = self.delivery.connectedGeneration() orelse return;
        while (try self.delivery.buildBatch(generation)) |value| {
            var batch = value;
            defer batch.deinit();
            runtime.emitWindowEvent(window_id, agent_event_name, batch.json) catch |err| {
                if (self.host) |host| {
                    for (0..batch.item_count) |index| {
                        const route = self.delivery.batchRoute(&batch, index) catch continue;
                        host.failRun(route.session_id, route.run_id, .bridge_pipeline_failure) catch {};
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

    fn emitWorkbenchChanged(self: *@This(), runtime: *native_sdk.Runtime, window_id: native_sdk.platform.WindowId) !void {
        const workbench = self.workbench orelse return;
        var detail_buffer: [96]u8 = undefined;
        const detail = try std.fmt.bufPrint(&detail_buffer, "{{\"revision\":\"{d}\"}}", .{workbench.currentRevision()});
        try runtime.emitWindowEvent(window_id, workbench_event_name, detail);
    }

    fn drainHostEvents(self: *@This()) void {
        const host = self.host orelse return;
        while (host.takeEvent()) |value| {
            var envelope = value;
            if (self.workbench) |workbench| workbench.applyEvent(&envelope) catch {
                const session_id = envelope.session_id;
                const run_id = envelope.run_id;
                envelope.deinit();
                host.failRun(session_id, run_id, .bridge_pipeline_failure) catch {};
                continue;
            };
            const owned = envelope.takeJson();
            var input = bridge_delivery.InputEvent{
                .session_id = owned.session_id,
                .run_id = owned.run_id,
                .json = owned.json,
                .allocator = owned.allocator,
            };
            self.delivery.ingest(input) catch {
                const session_id = input.session_id;
                const run_id = input.run_id;
                input.deinit();
                host.failRun(session_id, run_id, .bridge_pipeline_failure) catch {};
            };
        }
    }

    fn expireDetachedRoutes(self: *@This(), now_ns: u64) void {
        while (self.delivery.firstExpired(now_ns)) |route| {
            if (self.host) |host|
                host.failRun(route.session_id, route.run_id, .bridge_pipeline_failure) catch {};
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

    fn wakeHost(context: ?*anyopaque) bool {
        const self: *@This() = @ptrCast(@alignCast(context orelse return false));
        const services = self.platform_services orelse return false;
        services.wake() catch return false;
        return true;
    }

    fn wakePlatform(self: *@This()) !void {
        const services = self.platform_services orelse return error.RuntimeUnavailable;
        try services.wake();
    }

    fn requireEventWindow(self: *@This(), window_id: native_sdk.platform.WindowId) !void {
        if (self.event_window_id == null or self.event_window_id.? != window_id)
            return error.EventWindowMismatch;
    }

    fn joinFixtureWorker(self: *@This()) void {
        if (self.fixture_thread) |thread| {
            thread.join();
            self.fixture_thread = null;
        }
    }
};

const EventDisconnect = struct { generation: []const u8 };
const EventAck = struct {
    generation: []const u8,
    sessionId: []const u8,
    runId: []const u8,
    sequence: []const u8,
};
const EventFetch = struct {
    generation: []const u8,
    sessionId: []const u8,
    runId: []const u8,
    objectId: []const u8,
};
const SessionCreate = struct { workspaceRoot: []const u8, trusted: bool };
const SessionRun = struct { sessionId: []const u8, prompt: []const u8 };
const SessionIdentity = struct { sessionId: []const u8, runId: []const u8 };
const SessionClose = struct { sessionId: []const u8 };
const UiResponseRequest = struct {
    sessionId: []const u8,
    runId: []const u8,
    requestId: []const u8,
    kind: []const u8,
    answers: ?[]const []const u8 = null,
    permission: ?[]const u8 = null,
    planApproval: ?[]const u8 = null,
    custom: ?[]const u8 = null,
};

fn parsePayload(comptime T: type, payload: []const u8) !std.json.Parsed(T) {
    return parsePayloadWithLimit(T, payload, 4096);
}

fn parsePayloadWithLimit(comptime T: type, payload: []const u8, limit: usize) !std.json.Parsed(T) {
    if (payload.len > limit) return error.InvalidBridgePayload;
    return std.json.parseFromSlice(T, std.heap.c_allocator, payload, .{
        .ignore_unknown_fields = false,
    }) catch error.InvalidBridgePayload;
}

fn providerKind(value: []const u8) ?u32 {
    if (std.mem.eql(u8, value, "anthropic")) return agentcore.types.PROVIDER_ANTHROPIC;
    if (std.mem.eql(u8, value, "openai")) return agentcore.types.PROVIDER_OPENAI;
    if (std.mem.eql(u8, value, "gemini")) return agentcore.types.PROVIDER_GEMINI;
    return null;
}

fn permissionChoice(value: []const u8) ?agentcore.protocol.PermissionChoice {
    if (std.mem.eql(u8, value, "allow_once")) return .allow_once;
    if (std.mem.eql(u8, value, "allow_always")) return .allow_always;
    if (std.mem.eql(u8, value, "deny_once")) return .deny_once;
    if (std.mem.eql(u8, value, "deny_tool_session")) return .deny_tool_session;
    return null;
}

fn planApproval(value: []const u8) ?agentcore.protocol.PlanApproval {
    if (std.mem.eql(u8, value, "approve_default")) return .approve_default;
    if (std.mem.eql(u8, value, "approve_accept_edits")) return .approve_accept_edits;
    if (std.mem.eql(u8, value, "reject")) return .reject;
    return null;
}

fn parseWireId(value: []const u8) !u64 {
    if (value.len == 0 or (value.len > 1 and value[0] == '0')) return error.InvalidBridgeId;
    return std.fmt.parseInt(u64, value, 10) catch error.InvalidBridgeId;
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

fn acknowledgementSequence(payload: []const u8) !u64 {
    const prefix = "{\"sequence\":";
    if (!std.mem.startsWith(u8, payload, prefix) or !std.mem.endsWith(u8, payload, "}")) {
        return error.InvalidAcknowledgement;
    }
    const digits = payload[prefix.len .. payload.len - 1];
    if (digits.len == 0) return error.InvalidAcknowledgement;
    return std.fmt.parseInt(u64, digits, 10) catch error.InvalidAcknowledgement;
}

fn builtinBridgePolicy(mode: FrontendMode) native_sdk.BridgePolicy {
    return .{
        .enabled = true,
        .permissions = &window_permissions,
        .commands = switch (mode) {
            .release => &release_builtin_commands,
            .development => &development_builtin_commands,
            .gate0_automation => &gate0_automation_builtin_commands,
        },
    };
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
    return switch (mode) {
        .release => &release_origins,
        .development => &development_origins,
        .gate0_automation => &gate0_automation_origins,
    };
}

pub fn main(init: std.process.Init) !void {
    var delivery = try bridge_delivery.Delivery.init(std.heap.c_allocator, .{ .route_slots = 16 });
    defer delivery.deinit();
    var app = App{
        .env_map = init.environ_map,
        .io = init.io,
        .delivery = &delivery,
        .main_thread_id = std.Thread.getCurrentId(),
    };
    const api = try agentcore.Api.discover();
    const host = try host_lifecycle.Host.init(init.io, std.heap.c_allocator, api.raw, .{
        .worker_count = 4,
        .queue_capacity = 8,
        .max_sessions = 8,
        .notifier = .{ .context = &app, .wake = App.wakeHost },
    });
    app.host = host;
    var workbench = try host_workbench.Workbench.init(std.heap.c_allocator, host, .{});
    app.workbench = &workbench;
    defer {
        if (!app.host_shutdown) host.shutdown() catch {};
        workbench.deinit();
        host.deinit();
    }
    const mode = frontendMode(init.environ_map);

    try runner.runWithOptions(app.app(), .{
        .app_name = "MetaWork",
        .window_title = "MetaWork · Phase 0",
        .bundle_id = "dev.metawork.desktop",
        .bridge = app.bridge(mode),
        .builtin_bridge = builtinBridgePolicy(mode),
        .js_window_api = true,
        .security = .{
            .permissions = &window_permissions,
            .navigation = .{ .allowed_origins = allowedOrigins(mode) },
        },
    }, init);
}

test "transport limits and origin sets are explicit" {
    try std.testing.expectEqual(@as(usize, 1024 * 1024), native_sdk.bridge.max_message_bytes);
    try std.testing.expectEqual(@as(usize, 1024 * 1024), native_sdk.bridge.max_result_bytes);
    try std.testing.expectEqual(@as(usize, 1024 * 1024), native_sdk.bridge.max_response_bytes);
    try std.testing.expectEqual(@as(usize, 8192), native_sdk.platform.max_window_event_detail_bytes);
    try std.testing.expectEqual(@as(usize, 1), release_origins.len);
    try std.testing.expectEqual(@as(usize, 2), development_origins.len);
    try std.testing.expectEqual(@as(usize, 2), gate0_automation_origins.len);
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
}

test "Agent transport ids preserve the complete u64 domain" {
    try std.testing.expectEqual(@as(u64, 1), try parseWireId("1"));
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        try parseWireId("18446744073709551615"),
    );
    try std.testing.expectError(error.InvalidBridgeId, parseWireId(""));
    try std.testing.expectError(error.InvalidBridgeId, parseWireId("01"));
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
}
