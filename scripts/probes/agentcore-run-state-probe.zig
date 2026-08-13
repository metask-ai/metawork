const std = @import("std");
const agentcore = @import("metask_agentcore");
const wire = agentcore.types;

const Probe = struct {
    allocator: std.mem.Allocator,
    host_run_id: u64 = 0,
    state_count: usize = 0,
    last_sequence: ?u64 = null,
    first_sequence: ?u64 = null,
    duplicate_or_regression: bool = false,
    cross_run: bool = false,
    decode_failure: bool = false,

    fn onEvent(
        context: ?*anyopaque,
        raw_run: ?*const wire.RunContextV1,
        event_json: wire.BytesViewV1,
    ) callconv(.c) u32 {
        const self: *Probe = @ptrCast(@alignCast(context orelse return wire.EVENT_FATAL));
        const run = agentcore.validateRunContext(raw_run) catch {
            self.decode_failure = true;
            return wire.EVENT_CONTINUE;
        };
        if (self.host_run_id == 0) self.host_run_id = run.run_id;
        const bytes = agentcore.borrowedBytes(event_json) catch {
            self.decode_failure = true;
            return wire.EVENT_CONTINUE;
        };
        var parsed = agentcore.decodeCoreEvent(self.allocator, bytes) catch {
            self.decode_failure = true;
            return wire.EVENT_CONTINUE;
        };
        defer parsed.deinit();
        switch (parsed.value) {
            .known => |known| switch (known) {
                .run_state => |state| {
                    if (self.state_count == 0) self.first_sequence = state.transition_seq;
                    if (state.run_id != run.run_id or state.run_id != self.host_run_id)
                        self.cross_run = true;
                    if (self.last_sequence) |last| {
                        if (state.transition_seq <= last) self.duplicate_or_regression = true;
                    }
                    self.last_sequence = state.transition_seq;
                    self.state_count += 1;
                    std.debug.print(
                        "run_state run_id={d} callback_run_id={d} seq={d} phase={s} turn={d} tool_calls={d} in_flight={d}\n",
                        .{
                            state.run_id,
                            run.run_id,
                            state.transition_seq,
                            @tagName(state.phase),
                            state.turn,
                            state.tool_calls,
                            state.in_flight_tools.len,
                        },
                    );
                },
                else => {},
            },
            .unknown => {},
        }
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

fn expectStatus(_: agentcore.Api, operation: []const u8, raw: u32) !agentcore.Status {
    const status = agentcore.Status.fromCode(raw) catch {
        std.debug.print("{s} returned unknown status {d}\n", .{ operation, raw });
        return error.UnknownStatus;
    };
    std.debug.print("{s} status={s}\n", .{ operation, @tagName(status) });
    return status;
}

fn releaseOwned(api: agentcore.Api, bytes: *wire.OwnedBytesV1) void {
    if (bytes.ptr != null or bytes.len != 0) api.bufferRelease()(bytes);
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    const api = try agentcore.Api.discover();
    var probe = Probe{ .allocator = allocator };
    const workspace_path = if (@import("builtin").os.tag == .windows) "C:\\" else "/";

    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.ctx = &probe;
    callbacks.on_event = Probe.onEvent;
    callbacks.on_ui_request = Probe.onUiRequest;
    callbacks.release_response = Probe.releaseResponse;

    var builtin_views: [11]wire.BytesViewV1 = undefined;
    const builtin_names = [_][]const u8{
        "Read",      "Write",           "Edit",      "Glob",     "Grep", "Bash", "BashOutput",
        "KillShell", "AskUserQuestion", "WebSearch", "WebFetch",
    };
    for (builtin_names, 0..) |name, index| builtin_views[index] = agentcore.bytesView(name);

    var host = std.mem.zeroes(wire.SessionHostConfigV1);
    host.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host.permission_mode_code = wire.PERMISSION_DEFAULT;
    host.shell_policy_code = wire.SHELL_DISABLED;
    host.api_key = agentcore.bytesView("run-state-probe-key");
    host.base_url = agentcore.bytesView("__BASE_URL__");
    host.workspace_root = agentcore.bytesView(workspace_path);
    host.workspace_home = agentcore.bytesView(workspace_path);

    var config = std.mem.zeroes(wire.SessionCreateConfigV1);
    config.struct_size = @sizeOf(wire.SessionCreateConfigV1);
    config.host = &host;
    config.model = agentcore.bytesView("run-state-probe-model");

    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    runtime_config.builtin_tools = &builtin_views;
    runtime_config.builtin_tool_count = builtin_views.len;
    var runtime: ?*wire.RuntimeHandle = null;
    _ = try expectStatus(api, "runtime_create", api.runtimeCreate()(&runtime_config, &runtime, null));
    const raw_runtime = runtime orelse return error.MissingRuntime;
    defer _ = api.runtimeDestroy()(raw_runtime, null);

    var session: ?*wire.SessionHandle = null;
    const create_status = try expectStatus(
        api,
        "session_create",
        api.sessionCreate()(raw_runtime, &config, &callbacks, &session, null),
    );
    if (create_status != .ok) return error.SessionCreateFailed;
    const raw_session = session orelse return error.MissingSession;
    defer _ = api.sessionDestroy()(raw_session, null);

    var options = std.mem.zeroes(wire.RunOptionsV1);
    options.struct_size = @sizeOf(wire.RunOptionsV1);
    options.max_turns = 1;
    var result = std.mem.zeroes(wire.RunResultV1);
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    const run_status = try expectStatus(
        api,
        "session_run_input",
        api.sessionRunText(
            raw_session,
            7,
            agentcore.bytesView("Reply with one short sentence."),
            &options,
            &result,
            &diagnostic,
        ),
    );
    defer releaseOwned(api, &diagnostic);
    if (run_status != .ok) return error.RunFailed;
    if (result.struct_size != @sizeOf(wire.RunResultV1)) return error.InvalidRunResult;

    std.debug.print(
        "run_state_summary host_run_id={d} state_count={d} first_sequence={any} last_sequence={any} duplicate_or_regression={} cross_run={} decode_failure={} stop_reason={d} turns={d} tool_calls={d}\n",
        .{
            probe.host_run_id,
            probe.state_count,
            probe.first_sequence,
            probe.last_sequence,
            probe.duplicate_or_regression,
            probe.cross_run,
            probe.decode_failure,
            result.stop_reason_code,
            result.turns,
            result.tool_calls,
        },
    );
    if (probe.host_run_id != 7 or probe.cross_run or probe.duplicate_or_regression or probe.decode_failure)
        return error.InvalidRunStateObservation;
    if (probe.state_count == 0) return error.RunStateUnavailable;
}
