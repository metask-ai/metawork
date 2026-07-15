const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const frontend_url_env = "NATIVE_SDK_FRONTEND_URL";
const gate0_automation_env = "METAWORK_GATE0_AUTOMATION";
const event_name = "metawork:host-signal";

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
    main_thread_id: std.Thread.Id,
    runtime: ?*native_sdk.Runtime = null,
    sequence: u64 = 0,
    acknowledged_sequence: u64 = 0,
    handlers: [2]native_sdk.bridge.Handler = undefined,

    fn app(self: *@This()) native_sdk.App {
        return .{
            .context = self,
            .name = "metawork",
            .source = native_sdk.frontend.productionSource(.{ .dist = "frontend/dist" }),
            .source_fn = source,
            .start_fn = start,
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
    }

    fn stop(context: *anyopaque, runtime: *native_sdk.Runtime) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (self.runtime == runtime) self.runtime = null;
    }

    fn bridge(self: *@This(), mode: FrontendMode) native_sdk.BridgeDispatcher {
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
            "{{\"sequence\":{d},\"transport\":\"Runtime.emitWindowEvent\",\"origin\":\"{s}\",\"onMainThread\":{},\"requestBytes\":{d}}}",
            .{ self.sequence, invocation.source.origin, on_main_thread, invocation.request.payload.len },
        );
        try runtime.emitWindowEvent(invocation.source.window_id, event_name, detail);

        return std.fmt.bufPrint(
            output,
            "{{\"sequence\":{d},\"transport\":\"BridgeDispatcher.response\",\"origin\":\"{s}\",\"onMainThread\":{}}}",
            .{ self.sequence, invocation.source.origin, on_main_thread },
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
};

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

fn allowedOrigins(mode: FrontendMode) []const []const u8 {
    return switch (mode) {
        .release => &release_origins,
        .development => &development_origins,
        .gate0_automation => &gate0_automation_origins,
    };
}

pub fn main(init: std.process.Init) !void {
    var app = App{
        .env_map = init.environ_map,
        .main_thread_id = std.Thread.getCurrentId(),
    };
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
    var app = App{
        .env_map = undefined,
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

test "event acknowledgement payload is exact and bounded" {
    try std.testing.expectEqual(@as(u64, 42), try acknowledgementSequence("{\"sequence\":42}"));
    try std.testing.expectError(error.InvalidAcknowledgement, acknowledgementSequence("{\"sequence\":42,\"extra\":true}"));
    try std.testing.expectError(error.InvalidAcknowledgement, acknowledgementSequence("{\"sequence\":-1}"));
}
