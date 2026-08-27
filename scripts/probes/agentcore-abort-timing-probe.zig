const std = @import("std");
const agentcore = @import("metask_agentcore");
const wire = agentcore.types;

// Evidence probe for the Stop barrier: does AgentCore deliver on_event
// callbacks after session_abort has returned? The answer decides whether the
// Workbench double drain barrier needs an AgentCore contract amendment.
const Probe = struct {
    allocator: std.mem.Allocator,
    api: agentcore.Api = undefined,
    session: ?*wire.SessionHandle = null,
    first_event_seen: std.atomic.Value(bool) = .init(false),
    abort_returned: std.atomic.Value(bool) = .init(false),
    abort_status: std.atomic.Value(u32) = .init(std.math.maxInt(u32)),
    events_total: std.atomic.Value(u64) = .init(0),
    events_after_abort_returned: std.atomic.Value(u64) = .init(0),
    decode_failure: std.atomic.Value(bool) = .init(false),

    fn onEvent(
        context: ?*anyopaque,
        raw_run: ?*const wire.RunContextV1,
        event_json: wire.BytesViewV1,
    ) callconv(.c) u32 {
        const self: *Probe = @ptrCast(@alignCast(context orelse return wire.EVENT_FATAL));
        _ = agentcore.validateRunContext(raw_run) catch {
            self.decode_failure.store(true, .release);
            return wire.EVENT_CONTINUE;
        };
        const bytes = agentcore.borrowedBytes(event_json) catch {
            self.decode_failure.store(true, .release);
            return wire.EVENT_CONTINUE;
        };
        var parsed = agentcore.decodeCoreEvent(self.allocator, bytes) catch {
            self.decode_failure.store(true, .release);
            return wire.EVENT_CONTINUE;
        };
        parsed.deinit();
        _ = self.events_total.fetchAdd(1, .acq_rel);
        if (self.abort_returned.load(.acquire)) {
            const after = self.events_after_abort_returned.fetchAdd(1, .acq_rel) + 1;
            std.debug.print("event_after_abort_return index={d}\n", .{after});
        }
        self.first_event_seen.store(true, .release);
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

    fn abortThread(self: *Probe) void {
        while (!self.first_event_seen.load(.acquire))
            std.Thread.sleep(2 * std.time.ns_per_ms);
        std.Thread.sleep(50 * std.time.ns_per_ms);
        const status = self.api.session().abort()(self.session, 7, null);
        self.abort_status.store(status, .release);
        self.abort_returned.store(true, .release);
        std.debug.print("session_abort returned status={d}\n", .{status});
    }
};

fn expectStatus(operation: []const u8, raw: u32) !agentcore.Status {
    const status = agentcore.Status.fromCode(raw) catch {
        std.debug.print("{s} returned unknown status {d}\n", .{ operation, raw });
        return error.UnknownStatus;
    };
    std.debug.print("{s} status={s}\n", .{ operation, @tagName(status) });
    return status;
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    const api = try agentcore.Api.discover();
    var probe = Probe{ .allocator = allocator, .api = api };

    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.ctx = &probe;
    callbacks.on_event = Probe.onEvent;
    callbacks.on_ui_request = Probe.onUiRequest;
    callbacks.release_response = Probe.releaseResponse;

    var builtin_views: [1]wire.BytesViewV1 = .{agentcore.bytesView("Read")};
    var host = std.mem.zeroes(wire.SessionHostConfigV1);
    host.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host.permission_mode_code = wire.PERMISSION_DEFAULT;
    host.shell_policy_code = wire.SHELL_DISABLED;
    host.api_key = agentcore.bytesView("abort-probe-key");
    host.base_url = agentcore.bytesView("__BASE_URL__");
    host.workspace_root = agentcore.bytesView("C:\\");
    host.workspace_home = agentcore.bytesView("C:\\");

    var config = std.mem.zeroes(wire.SessionCreateConfigV1);
    config.struct_size = @sizeOf(wire.SessionCreateConfigV1);
    config.host = &host;
    config.model = agentcore.bytesView("abort-probe-model");

    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    runtime_config.builtin_tools = &builtin_views;
    runtime_config.builtin_tool_count = builtin_views.len;
    var runtime: ?*wire.RuntimeHandle = null;
    _ = try expectStatus("runtime_create", api.runtime().create()(&runtime_config, null, &runtime, null));
    const raw_runtime = runtime orelse return error.MissingRuntime;
    defer _ = api.runtime().destroy()(raw_runtime, null);

    var session: ?*wire.SessionHandle = null;
    const create_status = try expectStatus(
        "session_create",
        api.session().create()(raw_runtime, &config, &callbacks, &session, null),
    );
    if (create_status != .ok) return error.SessionCreateFailed;
    probe.session = session orelse return error.MissingSession;
    defer _ = api.session().destroy()(probe.session, null);

    const worker = try std.Thread.spawn(.{}, Probe.abortThread, .{&probe});

    var options = std.mem.zeroes(wire.RunOptionsV1);
    options.struct_size = @sizeOf(wire.RunOptionsV1);
    options.max_turns = 1;
    var result = std.mem.zeroes(wire.RunResultV1);
    const run_status_code = api.session().runText(
        probe.session,
        7,
        agentcore.bytesView("Stream slowly so the abort lands mid-run."),
        &options,
        &result,
        null,
    );
    const run_returned_at_total = probe.events_total.load(.acquire);
    worker.join();
    _ = try expectStatus("session_run_input", run_status_code);

    // Post-run settle window: any callback arriving here is definitive
    // evidence of delivery after both abort and run returned.
    std.Thread.sleep(300 * std.time.ns_per_ms);
    const total = probe.events_total.load(.acquire);
    std.debug.print(
        "abort_timing_summary events_total={d} events_at_run_return={d} events_after_abort_returned={d} events_after_run_returned={d} abort_status={d} stop_reason={d} decode_failure={}\n",
        .{
            total,
            run_returned_at_total,
            probe.events_after_abort_returned.load(.acquire),
            total - run_returned_at_total,
            probe.abort_status.load(.acquire),
            result.stop_reason_code,
            probe.decode_failure.load(.acquire),
        },
    );
    if (probe.decode_failure.load(.acquire)) return error.DecodeFailure;
    if (total == 0) return error.NoEventsObserved;
    if (!probe.abort_returned.load(.acquire)) return error.AbortNotIssued;
}
