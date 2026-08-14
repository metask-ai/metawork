const std = @import("std");
const builtin = @import("builtin");
const agentcore = @import("metask_agentcore");
const wire = agentcore.types;

const checkpoint_capacity = 1024 * 1024;

const Description = struct {
    session_id: []u8,
    model: []u8,

    fn deinit(self: *Description, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        allocator.free(self.model);
        self.* = undefined;
    }
};

const Sink = struct {
    bytes: [checkpoint_capacity]u8 = undefined,
    len: usize = 0,

    fn write(context: ?*anyopaque, chunk: wire.BytesViewV1) callconv(.c) u32 {
        const self: *Sink = @ptrCast(@alignCast(context orelse return wire.CHECKPOINT_IO_FATAL));
        const bytes = agentcore.borrowedBytes(chunk) catch return wire.CHECKPOINT_IO_FATAL;
        if (bytes.len > self.bytes.len - self.len) return wire.CHECKPOINT_IO_FAILED;
        @memcpy(self.bytes[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
        return wire.CHECKPOINT_IO_OK;
    }
};

const Source = struct {
    bytes: []const u8,
    offset: usize = 0,

    fn read(
        context: ?*anyopaque,
        destination: ?[*]u8,
        capacity: u64,
        out_len: ?*u64,
    ) callconv(.c) u32 {
        const self: *Source = @ptrCast(@alignCast(context orelse return wire.CHECKPOINT_IO_FATAL));
        const output = out_len orelse return wire.CHECKPOINT_IO_FATAL;
        output.* = 0;
        if (self.offset == self.bytes.len) return wire.CHECKPOINT_IO_OK;
        const destination_capacity = std.math.cast(usize, capacity) orelse return wire.CHECKPOINT_IO_FATAL;
        const output_pointer = destination orelse return wire.CHECKPOINT_IO_FATAL;
        if (destination_capacity == 0) return wire.CHECKPOINT_IO_FATAL;
        const count = @min(self.bytes.len - self.offset, @min(destination_capacity, 17));
        @memcpy(output_pointer[0..count], self.bytes[self.offset..][0..count]);
        self.offset += count;
        output.* = count;
        return wire.CHECKPOINT_IO_OK;
    }
};

const Probe = struct {
    api: agentcore.Api,
    session: ?*wire.SessionHandle = null,
    active_mutation_attempted: bool = false,
    active_mutation_status: ?agentcore.Status = null,

    fn onEvent(
        context: ?*anyopaque,
        _: ?*const wire.RunContextV1,
        _: wire.BytesViewV1,
    ) callconv(.c) u32 {
        const self: *Probe = @ptrCast(@alignCast(context orelse return wire.EVENT_FATAL));
        if (!self.active_mutation_attempted) {
            self.active_mutation_attempted = true;
            const raw_status = self.api.sessionSetModel()(
                self.session,
                agentcore.bytesView("model-a"),
                null,
            );
            self.active_mutation_status = agentcore.Status.fromCode(raw_status) catch null;
        }
        return wire.EVENT_CONTINUE;
    }
};

fn emptyOwned() wire.OwnedBytesV1 {
    return .{ .ptr = null, .len = 0 };
}

fn releaseOwned(api: agentcore.Api, bytes: *wire.OwnedBytesV1) void {
    if (bytes.ptr != null or bytes.len != 0) api.bufferRelease()(bytes);
    bytes.* = emptyOwned();
}

fn expectOk(_: agentcore.Api, operation: []const u8, raw: u32) !void {
    const status = agentcore.Status.fromCode(raw) catch {
        std.debug.print("{s}: unknown status {d}\n", .{ operation, raw });
        return error.UnknownStatus;
    };
    std.debug.print("{s}: {s}\n", .{ operation, @tagName(status) });
    if (status != .ok) return error.AgentCoreCallFailed;
}

fn statusName(raw: u32) []const u8 {
    const status = agentcore.Status.fromCode(raw) catch return "unknown";
    return @tagName(status);
}

fn makeRuntime(api: agentcore.Api) !*wire.RuntimeHandle {
    const names = [_][]const u8{
        "Read", "Write", "Edit", "Glob", "Grep", "Bash", "BashOutput",
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

fn makeCallbacks(probe: *Probe) wire.SessionCallbacksV1 {
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.ctx = probe;
    callbacks.on_event = Probe.onEvent;
    callbacks.on_ui_request = onUiRequest;
    callbacks.release_response = releaseResponse;
    return callbacks;
}

fn onUiRequest(
    _: ?*anyopaque,
    _: ?*const wire.RunContextV1,
    _: wire.BytesViewV1,
    output: ?*wire.OwnedBytesV1,
) callconv(.c) u32 {
    if (output) |value| value.* = emptyOwned();
    return wire.UI_UNAVAILABLE;
}

fn releaseResponse(_: ?*anyopaque, response: ?*wire.OwnedBytesV1) callconv(.c) void {
    if (response) |value| value.* = emptyOwned();
}

fn makeHost() wire.SessionHostConfigV1 {
    const workspace = if (builtin.os.tag == .windows) "C:\\" else "/";
    var host = std.mem.zeroes(wire.SessionHostConfigV1);
    host.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host.permission_mode_code = wire.PERMISSION_DEFAULT;
    host.shell_policy_code = wire.SHELL_DISABLED;
    host.api_key = agentcore.bytesView("model-mutation-probe-key");
    host.base_url = agentcore.bytesView("__BASE_URL__");
    host.workspace_root = agentcore.bytesView(workspace);
    host.workspace_home = agentcore.bytesView(workspace);
    return host;
}

fn describe(allocator: std.mem.Allocator, api: agentcore.Api, session: *wire.SessionHandle) !Description {
    var encoded = emptyOwned();
    defer releaseOwned(api, &encoded);
    try expectOk(api, "session_describe", api.sessionDescribe()(session, &encoded, null));
    const bytes = try agentcore.borrowedBytes(.{ .ptr = encoded.ptr, .len = encoded.len });
    var parsed = try agentcore.decodeSessionDescription(allocator, bytes);
    defer parsed.deinit();
    return .{
        .session_id = try allocator.dupe(u8, parsed.value.session_id),
        .model = try allocator.dupe(u8, parsed.value.model),
    };
}

fn makeLimits() wire.CheckpointLimitsV1 {
    var limits = std.mem.zeroes(wire.CheckpointLimitsV1);
    limits.struct_size = @sizeOf(wire.CheckpointLimitsV1);
    limits.hard_bytes = checkpoint_capacity;
    limits.max_section_bytes = checkpoint_capacity / 2;
    limits.max_string_bytes = 64 * 1024;
    limits.max_messages = 128;
    limits.max_blocks_per_message = 128;
    limits.chunk_bytes = 31;
    return limits;
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    const api = try agentcore.Api.discover();
    var probe = Probe{ .api = api };
    const callbacks = makeCallbacks(&probe);
    const host = makeHost();
    const runtime = try makeRuntime(api);
    defer _ = api.runtimeDestroy()(runtime, null);

    var create_config = std.mem.zeroes(wire.SessionCreateConfigV1);
    create_config.struct_size = @sizeOf(wire.SessionCreateConfigV1);
    create_config.host = &host;
    create_config.model = agentcore.bytesView("model-a");
    var session: ?*wire.SessionHandle = null;
    try expectOk(api, "session_create", api.sessionCreate()(runtime, &create_config, &callbacks, &session, null));
    const raw_session = session orelse return error.MissingSession;
    defer _ = api.sessionDestroy()(raw_session, null);
    probe.session = raw_session;

    var before = try describe(allocator, api, raw_session);
    defer before.deinit(allocator);
    if (!std.mem.eql(u8, before.model, "model-a")) return error.InitialModelMismatch;

    try expectOk(api, "session_set_model_idle", api.sessionSetModel()(raw_session, agentcore.bytesView("model-b"), null));
    var after_idle = try describe(allocator, api, raw_session);
    defer after_idle.deinit(allocator);
    if (!std.mem.eql(u8, after_idle.model, "model-b")) return error.IdleMutationNotApplied;

    var options = std.mem.zeroes(wire.RunOptionsV1);
    options.struct_size = @sizeOf(wire.RunOptionsV1);
    options.max_turns = 1;
    var run_result = std.mem.zeroes(wire.RunResultV1);
    var run_diagnostic = emptyOwned();
    defer releaseOwned(api, &run_diagnostic);
    try expectOk(api, "active_run", api.sessionRunText(
        raw_session,
        2,
        agentcore.bytesView("probe active run"),
        &options,
        &run_result,
        &run_diagnostic,
    ));
    const busy_status = probe.active_mutation_status orelse return error.ActiveMutationNotObserved;
    std.debug.print("session_set_model_active: {s}\n", .{@tagName(busy_status)});
    if (busy_status == .ok) return error.ActiveMutationAccepted;
    try expectOk(api, "session_set_model_after_run", api.sessionSetModel()(raw_session, agentcore.bytesView("model-a"), null));

    var sink_context = Sink{};
    var sink = std.mem.zeroes(wire.CheckpointSinkV1);
    sink.struct_size = @sizeOf(wire.CheckpointSinkV1);
    sink.ctx = &sink_context;
    sink.write = Sink.write;
    var export_config = std.mem.zeroes(wire.CheckpointExportConfigV1);
    export_config.struct_size = @sizeOf(wire.CheckpointExportConfigV1);
    var limits = makeLimits();
    export_config.limits = &limits;
    export_config.sink = &sink;
    var export_result = std.mem.zeroes(wire.CheckpointExportResultV1);
    try expectOk(api, "session_export_checkpoint", api.sessionExportCheckpoint()(raw_session, &export_config, &export_result, null));
    if (sink_context.len == 0) return error.EmptyCheckpoint;

    var expected = try describe(allocator, api, raw_session);
    defer expected.deinit(allocator);
    const restored_runtime = try makeRuntime(api);
    defer _ = api.runtimeDestroy()(restored_runtime, null);
    var source_context = Source{ .bytes = sink_context.bytes[0..sink_context.len] };
    var source = std.mem.zeroes(wire.CheckpointSourceV1);
    source.struct_size = @sizeOf(wire.CheckpointSourceV1);
    source.ctx = &source_context;
    source.read = Source.read;
    var restore_config = std.mem.zeroes(wire.SessionRestoreConfigV1);
    restore_config.struct_size = @sizeOf(wire.SessionRestoreConfigV1);
    restore_config.host = &host;
    restore_config.source = &source;
    restore_config.limits = &limits;
    var restored_session: ?*wire.SessionHandle = null;
    var restore_report = emptyOwned();
    defer releaseOwned(api, &restore_report);
    try expectOk(api, "session_restore", api.sessionRestore()(restored_runtime, &restore_config, &callbacks, &restored_session, &restore_report, null));
    const candidate = restored_session orelse return error.MissingRestoredSession;
    defer _ = api.sessionDestroy()(candidate, null);
    try expectOk(api, "session_set_model_restore_candidate", api.sessionSetModel()(candidate, agentcore.bytesView("model-b"), null));
    var restored = try describe(allocator, api, candidate);
    defer restored.deinit(allocator);
    if (!std.mem.eql(u8, restored.session_id, expected.session_id) or
        !std.mem.eql(u8, restored.model, "model-b")) return error.RestoreCandidateMutationFailed;

    std.debug.print(
        "AgentCore model mutation probe passed: idle=model-b active_status={s} post_run=model-a restore_candidate=model-b checkpoint_bytes={d}\n",
        .{ @tagName(busy_status), sink_context.len },
    );
}
