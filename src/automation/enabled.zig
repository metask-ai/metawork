//! Automation-only Native composition. This file is injected by build.zig
//! only for `-Dautomation=true` and is absent from the release module graph.

const std = @import("std");
const native_sdk = @import("native_sdk");
const renderer_bridge = @import("metawork_bridge");
const delivery_api = @import("automation_delivery");
const account_contract = @import("metawork_account_contract");

pub const enabled = true;
pub const handler_count: usize = 3;

const activation_env = "METAWORK_GATE0_AUTOMATION";
const retention_timer_id: u64 = 0x4d57_4445_4c49_5652;
const event_name = "metawork:agent-events";
const inline_origin = "zero://inline";
const allowed_origins = [_][]const u8{ "zero://app", inline_origin };
const acknowledge_command = "metawork.events.ack";
const fetch_command = "metawork.events.fetch";
const emit_command = "metawork.gate5.emitFixture";
const gate6_provider_base_url_env =
    "METAWORK_GATE6_PROVIDER_BASE_URL";
const gate6_credential = "metawork-gate6-fixture-key";
const gate6_model = "metawork-gate6-fixture-model";

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

pub const Hooks = struct {
    context: ?*anyopaque = null,
    break_product_connection_fn: *const fn (?*anyopaque) void,

    fn breakProductConnection(self: Hooks) void {
        self.break_product_connection_fn(self.context);
    }
};

pub const ExecutionFixture = struct {
    provider: account_contract.ProviderKind,
    credential: []const u8,
    model: []const u8,
    base_url: []const u8,
};

pub const Runtime = struct {
    delivery: delivery_api.Delivery = undefined,
    initialized: bool = false,
    env_map: ?*std.process.Environ.Map = null,
    main_thread_id: std.Thread.Id = undefined,
    callbacks: ?*renderer_bridge.CallbackGate = null,
    product_delivery: ?*renderer_bridge.ProductDelivery = null,
    hooks: ?Hooks = null,
    native_runtime: ?*native_sdk.Runtime = null,
    platform_services: ?native_sdk.platform.PlatformServices = null,
    fixture_thread: ?std.Thread = null,
    policy_commands: [32]native_sdk.bridge.CommandPolicy = undefined,
    builtin_commands: [16]native_sdk.bridge.CommandPolicy = undefined,

    pub fn init(
        allocator: std.mem.Allocator,
        env_map: *std.process.Environ.Map,
        main_thread_id: std.Thread.Id,
    ) !Runtime {
        return .{
            .delivery = try delivery_api.Delivery.init(allocator, .{ .route_slots = 16 }),
            .initialized = true,
            .env_map = env_map,
            .main_thread_id = main_thread_id,
        };
    }

    pub fn deinit(self: *Runtime) void {
        self.stop();
        if (self.initialized) self.delivery.deinitOwnedBuffers();
        self.* = undefined;
    }

    pub fn bind(
        self: *Runtime,
        callbacks: *renderer_bridge.CallbackGate,
        product_delivery: *renderer_bridge.ProductDelivery,
        hooks: Hooks,
    ) void {
        self.callbacks = callbacks;
        self.product_delivery = product_delivery;
        self.hooks = hooks;
    }

    pub fn start(self: *Runtime, native_runtime: *native_sdk.Runtime) void {
        self.native_runtime = native_runtime;
        self.platform_services = native_runtime.options.platform.services;
    }

    pub fn stop(self: *Runtime) void {
        self.joinFixtureWorker();
        if (self.platform_services) |services| services.cancelTimer(retention_timer_id) catch {};
        if (self.initialized and self.delivery.connectedGeneration() != null) {
            const generation = self.delivery.connectedGeneration().?;
            self.delivery.detach(generation, native_sdk.monotonicNanoseconds()) catch {};
        }
        self.native_runtime = null;
        self.platform_services = null;
    }

    pub fn active(self: *const Runtime) bool {
        const env_map = self.env_map orelse return false;
        const value = env_map.get(activation_env) orelse return false;
        return std.mem.eql(u8, value, "1");
    }

    pub fn executionFixture(
        self: *const Runtime,
    ) ?ExecutionFixture {
        if (!self.active()) return null;
        const env_map = self.env_map orelse return null;
        const base_url = env_map.get(
            gate6_provider_base_url_env,
        ) orelse return null;
        return .{
            .provider = .anthropic,
            .credential = gate6_credential,
            .model = gate6_model,
            .base_url = base_url,
        };
    }

    pub fn productPolicy(self: *Runtime, base: native_sdk.BridgePolicy) native_sdk.BridgePolicy {
        if (!self.active()) return base;
        const required = base.commands.len + handler_count;
        std.debug.assert(required <= self.policy_commands.len);
        for (base.commands, 0..) |command, index| {
            self.policy_commands[index] = command;
            self.policy_commands[index].origins = &allowed_origins;
        }
        self.policy_commands[base.commands.len] = .{ .name = acknowledge_command, .origins = &allowed_origins };
        self.policy_commands[base.commands.len + 1] = .{ .name = fetch_command, .origins = &allowed_origins };
        self.policy_commands[base.commands.len + 2] = .{ .name = emit_command, .origins = &allowed_origins };
        return .{
            .enabled = base.enabled,
            .permissions = base.permissions,
            .commands = self.policy_commands[0..required],
        };
    }

    pub fn builtinPolicy(self: *Runtime, base: native_sdk.BridgePolicy) native_sdk.BridgePolicy {
        if (!self.active()) return base;
        std.debug.assert(base.commands.len <= self.builtin_commands.len);
        for (base.commands, 0..) |command, index| {
            self.builtin_commands[index] = command;
            self.builtin_commands[index].origins = &allowed_origins;
        }
        return .{
            .enabled = base.enabled,
            .permissions = base.permissions,
            .commands = self.builtin_commands[0..base.commands.len],
        };
    }

    pub fn allowedOrigins(self: *const Runtime, base: []const []const u8) []const []const u8 {
        return if (self.active()) &allowed_origins else base;
    }

    pub fn fillHandlers(self: *Runtime, output: []native_sdk.bridge.Handler) void {
        std.debug.assert(output.len == handler_count);
        output[0] = .{ .name = acknowledge_command, .context = self, .invoke_fn = acknowledgeEvent };
        output[1] = .{ .name = fetch_command, .context = self, .invoke_fn = fetchEvent };
        output[2] = .{ .name = emit_command, .context = self, .invoke_fn = emitFixture };
    }

    pub fn beforeConnect(self: *Runtime, now_ns: u64) !void {
        if (!self.active()) return;
        self.expireDetachedRoutes(now_ns);
        const services = self.platform_services orelse return error.RuntimeUnavailable;
        try services.cancelTimer(retention_timer_id);
    }

    pub fn connectAt(self: *Runtime, generation: u64) !void {
        if (!self.active()) return;
        try self.delivery.connectAt(generation);
    }

    pub fn detach(self: *Runtime, generation: u64, now_ns: u64) !void {
        if (!self.active()) return;
        try self.delivery.detach(generation, now_ns);
        const services = self.platform_services orelse return error.RuntimeUnavailable;
        services.startTimer(retention_timer_id, self.delivery.retentionNanoseconds(), false) catch |err| {
            self.expireDetachedRoutes(std.math.maxInt(u64));
            return err;
        };
    }

    pub fn onEffectsWake(self: *Runtime, window_id: native_sdk.platform.WindowId) !void {
        if (!self.active()) return;
        const native_runtime = self.native_runtime orelse return error.RuntimeUnavailable;
        const generation = self.delivery.connectedGeneration() orelse return;
        while (try self.delivery.buildBatch(generation)) |value| {
            var batch = value;
            defer batch.deinit();
            native_runtime.emitWindowEvent(window_id, event_name, batch.json) catch |err| {
                self.detach(generation, native_sdk.monotonicNanoseconds()) catch |detach_err| std.log.warn(
                    "automation event delivery failed and detach also failed: emit={s} detach={s}",
                    .{ @errorName(err), @errorName(detach_err) },
                );
                (self.hooks orelse return error.RuntimeUnavailable).breakProductConnection();
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

    pub fn onTimer(self: *Runtime, timer_id: u64, now_ns: u64) bool {
        if (!self.active() or timer_id != retention_timer_id) return false;
        self.expireDetachedRoutes(now_ns);
        return true;
    }

    fn acknowledgeEvent(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *Runtime = @ptrCast(@alignCast(context));
        var callback = try self.enterCallback();
        defer callback.deinit();
        var parsed = try renderer_bridge.handlers.parsePayload(EventAck, invocation.request.payload);
        defer parsed.deinit();
        const request = parsed.value;
        const generation = try renderer_bridge.handlers.parseWireId(request.generation);
        const session_id = try renderer_bridge.handlers.parseWireId(request.sessionId);
        const run_id = try renderer_bridge.handlers.parseWireId(request.runId);
        const sequence = try renderer_bridge.handlers.parseWireId(request.sequence);
        try self.requireWindow(invocation.source.window_id);
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

    fn fetchEvent(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *Runtime = @ptrCast(@alignCast(context));
        var callback = try self.enterCallback();
        defer callback.deinit();
        var parsed = try renderer_bridge.handlers.parsePayload(EventFetch, invocation.request.payload);
        defer parsed.deinit();
        const request = parsed.value;
        const generation = try renderer_bridge.handlers.parseWireId(request.generation);
        const session_id = try renderer_bridge.handlers.parseWireId(request.sessionId);
        const run_id = try renderer_bridge.handlers.parseWireId(request.runId);
        const object_id = try renderer_bridge.handlers.parseWireId(request.objectId);
        try self.requireWindow(invocation.source.window_id);
        const response = try self.delivery.fetchObject(generation, session_id, run_id, object_id, output);
        std.debug.print("metawork.gate5.fetch generation={d} session={d} run={d} object={d} main_thread={}\n", .{
            generation,
            session_id,
            run_id,
            object_id,
            std.Thread.getCurrentId() == self.main_thread_id,
        });
        return response;
    }

    fn emitFixture(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *Runtime = @ptrCast(@alignCast(context));
        var callback = try self.enterCallback();
        defer callback.deinit();
        if (!self.active()) return error.AutomationOnly;
        try self.requireWindow(invocation.source.window_id);
        _ = self.delivery.connectedGeneration() orelse return error.NoConnection;
        errdefer self.delivery.cleanupRun(1, 1);

        const allocator = std.heap.c_allocator;
        const inline_json = try allocator.dupe(u8, "{\"fixture\":\"inline\",\"payload\":\"gate5\"}");
        var inline_event = delivery_api.InputEvent{
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
        var object_event = delivery_api.InputEvent{
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

    fn enterCallback(self: *Runtime) !renderer_bridge.CallbackGate.Lease {
        return (self.callbacks orelse return error.RuntimeUnavailable).enter();
    }

    fn requireWindow(self: *Runtime, window_id: native_sdk.platform.WindowId) !void {
        _ = try (self.product_delivery orelse return error.RuntimeUnavailable).requireWindow(window_id);
    }

    fn expireDetachedRoutes(self: *Runtime, now_ns: u64) void {
        while (self.delivery.firstExpired(now_ns)) |route|
            self.delivery.cleanupRun(route.session_id, route.run_id);
    }

    fn joinFixtureWorker(self: *Runtime) void {
        if (self.fixture_thread) |thread| {
            thread.join();
            self.fixture_thread = null;
        }
    }
};

fn wakeFixtureWorker(services: native_sdk.platform.PlatformServices, main_thread_id: std.Thread.Id) void {
    std.debug.assert(std.Thread.getCurrentId() != main_thread_id);
    services.wake() catch |err| {
        std.debug.print("metawork.gate5.wake_failed error={s}\n", .{@errorName(err)});
        return;
    };
    std.debug.print("metawork.gate5.worker_wake off_main_thread=true\n", .{});
}

test "automation policy adds fixture commands only when explicitly activated" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put(activation_env, "1");
    var runtime = try Runtime.init(std.testing.allocator, &env, std.Thread.getCurrentId());
    defer runtime.deinit();

    try std.testing.expect(runtime.active());
    const base = renderer_bridge.policy.product(.release);
    const policy = runtime.productPolicy(base);
    try std.testing.expectEqual(base.commands.len + handler_count, policy.commands.len);
    try std.testing.expectEqualStrings(acknowledge_command, policy.commands[base.commands.len].name);
    try std.testing.expectEqualStrings(fetch_command, policy.commands[base.commands.len + 1].name);
    try std.testing.expectEqualStrings(emit_command, policy.commands[base.commands.len + 2].name);
    try std.testing.expectEqualStrings(inline_origin, policy.commands[base.commands.len].origins[1]);

    var handlers: [handler_count]native_sdk.bridge.Handler = undefined;
    runtime.fillHandlers(&handlers);
    try std.testing.expectEqualStrings(acknowledge_command, handlers[0].name);
    try std.testing.expectEqualStrings(fetch_command, handlers[1].name);
    try std.testing.expectEqualStrings(emit_command, handlers[2].name);
}
