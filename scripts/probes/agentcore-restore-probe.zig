const std = @import("std");
const builtin = @import("builtin");
const agentcore = @import("metask_agentcore");
const wire = agentcore.types;

const checkpoint_capacity = 1024 * 1024;
const short_read_limit = 13;

const Sink = struct {
    bytes: [checkpoint_capacity]u8 = undefined,
    len: usize = 0,
    calls: u64 = 0,

    fn write(context: ?*anyopaque, chunk: wire.BytesViewV1) callconv(.c) u32 {
        const self: *Sink = @ptrCast(@alignCast(context orelse return wire.CHECKPOINT_IO_FATAL));
        const bytes = agentcore.borrowedBytes(chunk) catch return wire.CHECKPOINT_IO_FATAL;
        if (bytes.len > self.bytes.len - self.len) return wire.CHECKPOINT_IO_FAILED;
        @memcpy(self.bytes[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
        self.calls += 1;
        return wire.CHECKPOINT_IO_OK;
    }
};

const Source = struct {
    bytes: []const u8,
    offset: usize = 0,
    calls: u64 = 0,
    eof_calls: u64 = 0,

    fn read(
        context: ?*anyopaque,
        destination: ?[*]u8,
        capacity: u64,
        out_len: ?*u64,
    ) callconv(.c) u32 {
        const self: *Source = @ptrCast(@alignCast(context orelse return wire.CHECKPOINT_IO_FATAL));
        const output = out_len orelse return wire.CHECKPOINT_IO_FATAL;
        output.* = 0;
        self.calls += 1;
        if (self.offset == self.bytes.len) {
            self.eof_calls += 1;
            return wire.CHECKPOINT_IO_OK;
        }
        const destination_capacity = std.math.cast(usize, capacity) orelse
            return wire.CHECKPOINT_IO_FATAL;
        if (destination_capacity == 0) return wire.CHECKPOINT_IO_FATAL;
        const output_pointer = destination orelse return wire.CHECKPOINT_IO_FATAL;
        const count = @min(
            @min(self.bytes.len - self.offset, destination_capacity),
            short_read_limit,
        );
        @memcpy(output_pointer[0..count], self.bytes[self.offset..][0..count]);
        self.offset += count;
        output.* = count;
        return wire.CHECKPOINT_IO_OK;
    }
};

const Description = struct {
    session_id: []u8,
    model: []u8,
    last_run_id: u64,
    last_compact_id: u64,
    checkpoint_generation: u64,

    fn deinit(self: Description, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        allocator.free(self.model);
    }
};

fn onEvent(
    _: ?*anyopaque,
    _: ?*const wire.RunContextV1,
    _: wire.BytesViewV1,
) callconv(.c) u32 {
    return wire.EVENT_CONTINUE;
}

fn onUiRequest(
    _: ?*anyopaque,
    _: ?*const wire.RunContextV1,
    _: wire.BytesViewV1,
    out_response: ?*wire.OwnedBytesV1,
) callconv(.c) u32 {
    if (out_response) |output| output.* = emptyOwnedBytes();
    return wire.UI_UNAVAILABLE;
}

fn releaseResponse(_: ?*anyopaque, response: ?*wire.OwnedBytesV1) callconv(.c) void {
    if (response) |output| output.* = emptyOwnedBytes();
}

fn makeRuntime(api: agentcore.Api) !*wire.RuntimeHandle {
    const builtin_names = [_][]const u8{ "Read", "Bash", "Edit", "AskUserQuestion" };
    var builtin_views: [builtin_names.len]wire.BytesViewV1 = undefined;
    for (builtin_names, 0..) |name, index| builtin_views[index] = agentcore.bytesView(name);
    var config = std.mem.zeroes(wire.RuntimeConfigV1);
    config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    config.builtin_tools = &builtin_views;
    config.builtin_tool_count = builtin_views.len;
    var runtime: ?*wire.RuntimeHandle = null;
    try expectStatus(api, "runtime_create", api.runtimeCreate()(&config, &runtime, null));
    return runtime orelse error.MissingRuntime;
}

fn makeHostConfig() wire.SessionHostConfigV1 {
    const workspace = if (builtin.os.tag == .windows) "C:\\" else "/";
    var host = std.mem.zeroes(wire.SessionHostConfigV1);
    host.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host.provider_kind_code = wire.PROVIDER_OPENAI;
    host.permission_mode_code = wire.PERMISSION_DEFAULT;
    host.shell_policy_code = wire.SHELL_DISABLED;
    host.api_key = agentcore.bytesView("probe-not-used");
    host.base_url = agentcore.bytesView("https://api.openai.com/v1");
    host.workspace_root = agentcore.bytesView(workspace);
    host.workspace_home = agentcore.bytesView(workspace);
    return host;
}

fn makeCallbacks() wire.SessionCallbacksV1 {
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.on_event = onEvent;
    callbacks.on_ui_request = onUiRequest;
    callbacks.release_response = releaseResponse;
    return callbacks;
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

fn describe(
    allocator: std.mem.Allocator,
    api: agentcore.Api,
    session: *wire.SessionHandle,
) !Description {
    var encoded = emptyOwnedBytes();
    defer releaseOwned(api, &encoded);
    try expectStatus(api, "session_describe", api.sessionDescribe()(session, &encoded, null));
    const bytes = try agentcore.borrowedBytes(.{ .ptr = encoded.ptr, .len = encoded.len });
    var parsed = try agentcore.decodeSessionDescription(allocator, bytes);
    defer parsed.deinit();
    return .{
        .session_id = try allocator.dupe(u8, parsed.value.session_id),
        .model = try allocator.dupe(u8, parsed.value.model),
        .last_run_id = parsed.value.last_run_id,
        .last_compact_id = parsed.value.last_compact_id,
        .checkpoint_generation = parsed.value.checkpoint_generation,
    };
}

fn destroySession(api: agentcore.Api, session: *wire.SessionHandle) !void {
    try expectStatus(api, "session_destroy", api.sessionDestroy()(session, null));
}

fn destroyRuntime(api: agentcore.Api, runtime: *wire.RuntimeHandle) !void {
    try expectStatus(api, "runtime_destroy", api.runtimeDestroy()(runtime, null));
}

fn expectStatus(api: agentcore.Api, operation: []const u8, status_code: u32) !void {
    _ = api;
    const status = agentcore.Status.fromCode(status_code) catch {
        std.debug.print("{s} returned unknown status {d}\n", .{ operation, status_code });
        return error.UnknownStatus;
    };
    if (status != .ok) {
        std.debug.print("{s} returned {s}\n", .{ operation, @tagName(status) });
        return error.AgentCoreCallFailed;
    }
}

fn emptyOwnedBytes() wire.OwnedBytesV1 {
    return .{ .ptr = null, .len = 0 };
}

fn releaseOwned(api: agentcore.Api, bytes: *wire.OwnedBytesV1) void {
    if (bytes.ptr != null or bytes.len != 0) api.bufferRelease()(bytes);
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    const api = try agentcore.Api.discover();
    const callbacks = makeCallbacks();
    const host = makeHostConfig();
    const limits = makeLimits();

    const first_runtime = try makeRuntime(api);
    var first_runtime_live = true;
    defer if (first_runtime_live) destroyRuntime(api, first_runtime) catch {};

    var create_config = std.mem.zeroes(wire.SessionCreateConfigV1);
    create_config.struct_size = @sizeOf(wire.SessionCreateConfigV1);
    create_config.host = &host;
    create_config.model = agentcore.bytesView("gpt-5-mini");
    var first_session: ?*wire.SessionHandle = null;
    try expectStatus(api, "session_create", api.sessionCreate()(
        first_runtime,
        &create_config,
        &callbacks,
        &first_session,
        null,
    ));
    const session = first_session orelse return error.MissingSession;
    var first_session_live = true;
    defer if (first_session_live) destroySession(api, session) catch {};

    var sink_context = Sink{};
    var sink = std.mem.zeroes(wire.CheckpointSinkV1);
    sink.struct_size = @sizeOf(wire.CheckpointSinkV1);
    sink.ctx = &sink_context;
    sink.write = Sink.write;
    var export_config = std.mem.zeroes(wire.CheckpointExportConfigV1);
    export_config.struct_size = @sizeOf(wire.CheckpointExportConfigV1);
    export_config.limits = &limits;
    export_config.sink = &sink;
    var export_result = std.mem.zeroes(wire.CheckpointExportResultV1);
    try expectStatus(api, "session_export_checkpoint", api.sessionExportCheckpoint()(
        session,
        &export_config,
        &export_result,
        null,
    ));
    if (sink_context.len == 0 or
        export_result.total_bytes != sink_context.len or
        export_result.chunk_count != sink_context.calls)
        return error.InvalidCheckpointExport;

    const expected = try describe(allocator, api, session);
    defer expected.deinit(allocator);
    if (expected.checkpoint_generation != export_result.checkpoint_generation)
        return error.InvalidCheckpointGeneration;

    try destroySession(api, session);
    first_session_live = false;
    try destroyRuntime(api, first_runtime);
    first_runtime_live = false;

    const restored_runtime = try makeRuntime(api);
    var restored_runtime_live = true;
    defer if (restored_runtime_live) destroyRuntime(api, restored_runtime) catch {};

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
    var restore_report = emptyOwnedBytes();
    defer releaseOwned(api, &restore_report);
    try expectStatus(api, "session_restore", api.sessionRestore()(
        restored_runtime,
        &restore_config,
        &callbacks,
        &restored_session,
        &restore_report,
        null,
    ));
    const restored = restored_session orelse return error.MissingRestoredSession;
    var restored_session_live = true;
    defer if (restored_session_live) destroySession(api, restored) catch {};

    if (source_context.offset != source_context.bytes.len or source_context.eof_calls == 0)
        return error.IncompleteCheckpointRead;
    const report_bytes = try agentcore.borrowedBytes(.{
        .ptr = restore_report.ptr,
        .len = restore_report.len,
    });
    var parsed_report = try agentcore.decodeRestoreReport(allocator, report_bytes);
    defer parsed_report.deinit();
    if (parsed_report.value.health != .complete or
        parsed_report.value.checkpoint_generation != export_result.checkpoint_generation or
        !std.mem.eql(u8, parsed_report.value.session_id, expected.session_id))
        return error.InvalidRestoreReport;

    const actual = try describe(allocator, api, restored);
    defer actual.deinit(allocator);
    if (!std.mem.eql(u8, actual.session_id, expected.session_id) or
        !std.mem.eql(u8, actual.model, expected.model) or
        actual.last_run_id != expected.last_run_id or
        actual.last_compact_id != expected.last_compact_id or
        actual.checkpoint_generation != expected.checkpoint_generation)
        return error.InvalidRestoredDescription;

    try destroySession(api, restored);
    restored_session_live = false;
    try destroyRuntime(api, restored_runtime);
    restored_runtime_live = false;

    // Failure-path observation. `agent/checkpoint_restore.zig` classifies a
    // non-OK restore by its typed status, but only when the call left the
    // session handle and the restore report empty. The ABI defines neither
    // output on a failure status, so pin the canonical behavior here: if the
    // bundle populates the report alongside a failure, every typed checkpoint
    // failure would collapse into an untyped dependency contract failure.
    const corrupt_runtime = try makeRuntime(api);
    var corrupt_runtime_live = true;
    defer if (corrupt_runtime_live) destroyRuntime(api, corrupt_runtime) catch {};

    // Truncation rather than a flipped byte: a premature EOF is invalid for
    // any checkpoint encoding, so this stays deterministic without depending
    // on where the format keeps integrity-relevant bytes.
    var corrupt_source_context = Source{ .bytes = sink_context.bytes[0 .. sink_context.len / 2] };
    var corrupt_source = std.mem.zeroes(wire.CheckpointSourceV1);
    corrupt_source.struct_size = @sizeOf(wire.CheckpointSourceV1);
    corrupt_source.ctx = &corrupt_source_context;
    corrupt_source.read = Source.read;
    var corrupt_config = std.mem.zeroes(wire.SessionRestoreConfigV1);
    corrupt_config.struct_size = @sizeOf(wire.SessionRestoreConfigV1);
    corrupt_config.host = &host;
    corrupt_config.source = &corrupt_source;
    corrupt_config.limits = &limits;
    var corrupt_session: ?*wire.SessionHandle = null;
    var corrupt_report = emptyOwnedBytes();
    defer releaseOwned(api, &corrupt_report);
    var corrupt_diagnostic = emptyOwnedBytes();
    defer releaseOwned(api, &corrupt_diagnostic);
    const corrupt_status_code = api.sessionRestore()(
        corrupt_runtime,
        &corrupt_config,
        &callbacks,
        &corrupt_session,
        &corrupt_report,
        &corrupt_diagnostic,
    );
    defer if (corrupt_session) |value| destroySession(api, value) catch {};
    const corrupt_status = agentcore.Status.fromCode(corrupt_status_code) catch
        return error.UnknownTruncatedRestoreStatus;
    const corrupt_report_empty = corrupt_report.ptr == null and corrupt_report.len == 0;
    std.debug.print(
        "AgentCore truncated restore observed: status={s} session_returned={} report_empty={} diagnostic_empty={}\n",
        .{
            @tagName(corrupt_status),
            corrupt_session != null,
            corrupt_report_empty,
            corrupt_diagnostic.ptr == null and corrupt_diagnostic.len == 0,
        },
    );
    if (corrupt_status == .ok) return error.TruncatedCheckpointAccepted;
    if (corrupt_session != null) return error.FailedRestoreRetainedSession;
    if (!corrupt_report_empty) return error.FailedRestoreEmittedReport;

    try destroyRuntime(api, corrupt_runtime);
    corrupt_runtime_live = false;

    std.debug.print(
        "AgentCore restore probe passed: bytes={d} export_chunks={d} source_calls={d} eof_calls={d} short_read_limit={d}\n",
        .{
            sink_context.len,
            sink_context.calls,
            source_context.calls,
            source_context.eof_calls,
            short_read_limit,
        },
    );
}
