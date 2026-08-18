const std = @import("std");
const builtin = @import("builtin");
const agentcore = @import("metask_agentcore");
const wire = agentcore.types;

const ProviderTest = struct {
    event_count: usize = 0,
    callback_decode_failed: bool = false,

    fn onEvent(
        context: ?*anyopaque,
        _: ?*const wire.RunContextV1,
        event_json: wire.BytesViewV1,
    ) callconv(.c) u32 {
        const self: *ProviderTest = @ptrCast(@alignCast(context orelse return wire.EVENT_FATAL));
        _ = agentcore.borrowedBytes(event_json) catch {
            self.callback_decode_failed = true;
            return wire.EVENT_CONTINUE;
        };
        self.event_count += 1;
        return wire.EVENT_CONTINUE;
    }

    fn onUiRequest(
        _: ?*anyopaque,
        _: ?*const wire.RunContextV1,
        _: wire.BytesViewV1,
        out_response: ?*wire.OwnedBytesV1,
    ) callconv(.c) u32 {
        if (out_response) |output| output.* = .{ .ptr = null, .len = 0 };
        return wire.UI_UNAVAILABLE;
    }

    fn releaseResponse(_: ?*anyopaque, response: ?*wire.OwnedBytesV1) callconv(.c) void {
        if (response) |output| output.* = .{ .ptr = null, .len = 0 };
    }
};

fn releaseOwned(api: agentcore.Api, bytes: *wire.OwnedBytesV1) void {
    if (bytes.ptr != null or bytes.len != 0) api.bufferRelease()(bytes);
    bytes.* = .{ .ptr = null, .len = 0 };
}

fn expectOk(_: agentcore.Api, operation: []const u8, raw: u32) !void {
    const status = agentcore.Status.fromCode(raw) catch {
        std.debug.print("{s}: unknown status {d}\n", .{ operation, raw });
        return error.UnknownStatus;
    };
    std.debug.print("{s}: {s}\n", .{ operation, @tagName(status) });
    if (status != .ok) return error.AgentCoreCallFailed;
}

fn makeRuntime(api: agentcore.Api) !*wire.RuntimeHandle {
    const names = [_][]const u8{
        "Read",      "Write",           "Edit",      "Glob",     "Grep", "Bash", "BashOutput",
        "KillShell", "AskUserQuestion", "WebSearch", "WebFetch",
    };
    var views: [names.len]wire.BytesViewV1 = undefined;
    for (names, 0..) |name, index| views[index] = agentcore.bytesView(name);

    var config = std.mem.zeroes(wire.RuntimeConfigV1);
    config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    config.builtin_tools = &views;
    config.builtin_tool_count = views.len;
    var runtime: ?*wire.RuntimeHandle = null;
    try expectOk(api, "runtime_create", api.runtimeCreate()(&config, &runtime, null));
    return runtime orelse error.MissingRuntime;
}

pub fn main() !void {
    const api = try agentcore.Api.discover();
    var provider_test = ProviderTest{};

    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.ctx = &provider_test;
    callbacks.on_event = ProviderTest.onEvent;
    callbacks.on_ui_request = ProviderTest.onUiRequest;
    callbacks.release_response = ProviderTest.releaseResponse;

    var host = std.mem.zeroes(wire.SessionHostConfigV1);
    host.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host.provider_kind_code = __PROVIDER_CODE__;
    host.permission_mode_code = wire.PERMISSION_DEFAULT;
    host.shell_policy_code = wire.SHELL_DISABLED;
    host.api_key = agentcore.bytesView("__API_KEY__");
    host.base_url = agentcore.bytesView("__BASE_URL__");
    const workspace = if (builtin.os.tag == .windows) "C:\\" else "/";
    host.workspace_root = agentcore.bytesView(workspace);
    host.workspace_home = agentcore.bytesView(workspace);

    const runtime = try makeRuntime(api);
    defer _ = api.runtimeDestroy()(runtime, null);

    var config = std.mem.zeroes(wire.SessionCreateConfigV1);
    config.struct_size = @sizeOf(wire.SessionCreateConfigV1);
    config.host = &host;
    config.model = agentcore.bytesView("__MODEL__");
    var session: ?*wire.SessionHandle = null;
    try expectOk(
        api,
        "session_create",
        api.sessionCreate()(runtime, &config, &callbacks, &session, null),
    );
    const raw_session = session orelse return error.MissingSession;
    defer _ = api.sessionDestroy()(raw_session, null);

    var options = std.mem.zeroes(wire.RunOptionsV1);
    options.struct_size = @sizeOf(wire.RunOptionsV1);
    options.max_turns = 1;
    var result = std.mem.zeroes(wire.RunResultV1);
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer releaseOwned(api, &diagnostic);
    try expectOk(
        api,
        "session_run_provider_test",
        api.sessionRunText(
            raw_session,
            1,
            agentcore.bytesView("Reply with one short sentence."),
            &options,
            &result,
            &diagnostic,
        ),
    );
    if (result.struct_size != @sizeOf(wire.RunResultV1)) return error.InvalidRunResult;
    if (provider_test.callback_decode_failed or provider_test.event_count == 0)
        return error.InvalidEventObservation;
    const stop_reason = agentcore.StopReason.fromCode(result.stop_reason_code) catch
        return error.InvalidRunResult;
    if (stop_reason != .end_turn or result.turns != 1 or result.tool_calls != 0)
        return error.ProviderRunFailed;
    std.debug.print(
        "provider_test events={d} stop_reason={d} turns={d} tool_calls={d}\n",
        .{ provider_test.event_count, result.stop_reason_code, result.turns, result.tool_calls },
    );
}
