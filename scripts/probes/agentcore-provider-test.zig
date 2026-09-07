const std = @import("std");
const builtin = @import("builtin");
const agentcore = @import("metask_agentcore");
const wire = agentcore.types;

const Checkpoint = struct {
    bytes: []u8,
    len: usize = 0,
    offset: usize = 0,

    fn write(ctx: ?*anyopaque, chunk: wire.BytesViewV1) callconv(.c) u32 {
        const self: *Checkpoint = @ptrCast(@alignCast(ctx.?));
        const bytes = agentcore.borrowedBytes(chunk) catch return wire.CHECKPOINT_IO_FATAL;
        if (bytes.len > self.bytes.len - self.len) return wire.CHECKPOINT_IO_FAILED;
        @memcpy(self.bytes[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
        return wire.CHECKPOINT_IO_OK;
    }

    fn read(ctx: ?*anyopaque, dst: ?[*]u8, capacity: u64, out_len: ?*u64) callconv(.c) u32 {
        const self: *Checkpoint = @ptrCast(@alignCast(ctx.?));
        const count = @min(self.len - self.offset, capacity);
        if (count != 0) @memcpy(dst.?[0..count], self.bytes[self.offset..][0..count]);
        self.offset += count;
        out_len.?.* = count;
        return wire.CHECKPOINT_IO_OK;
    }
};

fn validateResult(result: wire.RunResultV1) !void {
    if (result.struct_size != @sizeOf(wire.RunResultV1) or
        result.stop_reason_code != wire.STOP_END_TURN or result.turns != 1 or result.tool_calls != 0)
        return error.ProviderRunFailed;
}

fn expectInputLimit(api: agentcore.Api, session: *wire.SessionHandle, parts: []const wire.RunInputPartV1, options: *const wire.RunOptionsV1, name: []const u8) !void {
    var result: wire.RunResultV1 = undefined;
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer releaseOwned(api, &diagnostic);
    const status = api.session().runMultimodal(session, 2, parts, options, &result, &diagnostic);
    std.debug.print("{s}: status={d}\n", .{ name, status });
    if (status != wire.STATUS_RESOURCE_LIMIT) return error.UnexpectedInputLimitStatus;
}

const ProviderTest = struct {
    event_count: usize = 0,
    max_event_bytes: usize = 0,
    callback_decode_failed: bool = false,

    fn onEvent(
        context: ?*anyopaque,
        _: ?*const wire.RunContextV1,
        event_json: wire.BytesViewV1,
    ) callconv(.c) u32 {
        const self: *ProviderTest = @ptrCast(@alignCast(context orelse return wire.EVENT_FATAL));
        const bytes = agentcore.borrowedBytes(event_json) catch {
            self.callback_decode_failed = true;
            return wire.EVENT_CONTINUE;
        };
        self.max_event_bytes = @max(self.max_event_bytes, bytes.len);
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
    try expectOk(api, "runtime_create", api.runtime().create()(&config, null, &runtime, null));
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
    host.protocol_kind_code = __PROTOCOL_CODE__;
    host.permission_mode_code = wire.PERMISSION_DEFAULT;
    host.shell_policy_code = wire.SHELL_DISABLED;
    host.api_key = agentcore.bytesView("__API_KEY__");
    host.base_url = agentcore.bytesView("__BASE_URL__");
    const workspace = if (builtin.os.tag == .windows) "C:\\" else "/";
    host.workspace_root = agentcore.bytesView(workspace);
    host.workspace_home = agentcore.bytesView(workspace);

    const runtime = try makeRuntime(api);
    defer _ = api.runtime().destroy()(runtime, null);

    var config = std.mem.zeroes(wire.SessionCreateConfigV1);
    config.struct_size = @sizeOf(wire.SessionCreateConfigV1);
    config.host = &host;
    config.model = agentcore.bytesView("__MODEL__");
    var session: ?*wire.SessionHandle = null;
    try expectOk(
        api,
        "session_create",
        api.session().create()(runtime, &config, &callbacks, &session, null),
    );
    const raw_session = session orelse return error.MissingSession;
    var session_live = true;
    defer if (session_live) {
        _ = api.session().destroy()(raw_session, null);
    };

    var options = std.mem.zeroes(wire.RunOptionsV1);
    options.struct_size = @sizeOf(wire.RunOptionsV1);
    options.max_turns = 1;
    var result = std.mem.zeroes(wire.RunResultV1);
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer releaseOwned(api, &diagnostic);
    try expectOk(
        api,
        "session_run_provider_test",
        api.session().runText(
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

    const parts = [_]wire.RunInputPartV1{
        agentcore.textPart("First image."),
        agentcore.imagePart("image/png", "__PNG__"),
        agentcore.textPart("Second image."),
        agentcore.imagePart("image/gif", "__GIF__"),
    };
    const too_many = [_]wire.RunInputPartV1{agentcore.textPart("x")} ** (wire.MAX_RUN_INPUT_PARTS_V1 + 1);
    try expectInputLimit(api, raw_session, &too_many, &options, "too_many_parts");
    const oversized = try std.heap.page_allocator.alloc(u8, wire.MAX_RUN_INPUT_IMAGE_DATA_BYTES_V1 + 4);
    defer std.heap.page_allocator.free(oversized);
    @memset(oversized, 'A');
    const oversized_parts = [_]wire.RunInputPartV1{agentcore.imagePart("image/png", oversized)};
    try expectInputLimit(api, raw_session, &oversized_parts, &options, "oversized_image");
    const total_parts = [_]wire.RunInputPartV1{agentcore.imagePart("image/png", oversized[0..wire.MAX_RUN_INPUT_IMAGE_DATA_BYTES_V1])} ** 4;
    try expectInputLimit(api, raw_session, &total_parts, &options, "oversized_aggregate");
    releaseOwned(api, &diagnostic);
    const image_status = api.session().runMultimodal(raw_session, 2, &parts, &options, &result, &diagnostic);
    if (diagnostic.len != 0) std.debug.print("image diagnostic: {s}\n", .{try agentcore.borrowedBytes(.{ .ptr = diagnostic.ptr, .len = diagnostic.len })});
    try expectOk(api, "multimodal", image_status);
    try validateResult(result);
    releaseOwned(api, &diagnostic);
    const history_run_id: u64 = 3;
    try expectOk(api, "multimodal_history", api.session().runText(raw_session, history_run_id, agentcore.bytesView("Continue with the images."), &options, &result, &diagnostic));
    try validateResult(result);
    releaseOwned(api, &diagnostic);
    const large_parts = [_]wire.RunInputPartV1{agentcore.imagePart("image/png", @embedFile("image.b64"))};
    const large_run_id = history_run_id + 1;
    try expectOk(api, "large_image_only", api.session().runMultimodal(raw_session, large_run_id, &large_parts, &options, &result, &diagnostic));
    try validateResult(result);

    const allocator = std.heap.page_allocator;
    var checkpoint = Checkpoint{ .bytes = try allocator.alloc(u8, 16 * 1024 * 1024) };
    defer allocator.free(checkpoint.bytes);
    var sink = std.mem.zeroes(wire.CheckpointSinkV1);
    sink.struct_size = @sizeOf(wire.CheckpointSinkV1);
    sink.ctx = &checkpoint;
    sink.write = Checkpoint.write;
    var limits = std.mem.zeroes(wire.CheckpointLimitsV1);
    limits.struct_size = @sizeOf(wire.CheckpointLimitsV1);
    limits.hard_bytes = checkpoint.bytes.len;
    limits.max_section_bytes = checkpoint.bytes.len;
    limits.max_string_bytes = 1024 * 1024;
    limits.max_messages = 4096;
    limits.max_blocks_per_message = 256;
    limits.chunk_bytes = 256 * 1024;
    var export_config = std.mem.zeroes(wire.CheckpointExportConfigV1);
    export_config.struct_size = @sizeOf(wire.CheckpointExportConfigV1);
    export_config.limits = &limits;
    export_config.sink = &sink;
    var exported = std.mem.zeroes(wire.CheckpointExportResultV1);
    releaseOwned(api, &diagnostic);
    const restricted = api.sessionControl().exportCheckpoint()(raw_session, &export_config, &exported, &diagnostic);
    std.debug.print("restricted checkpoint status={d} bytes={d}\n", .{ restricted, checkpoint.len });
    if (restricted != wire.STATUS_RESOURCE_LIMIT) return error.UnexpectedCheckpointLimitStatus;
    limits.max_string_bytes = 2 * 1024 * 1024;
    checkpoint.len = 0;
    releaseOwned(api, &diagnostic);
    try expectOk(api, "image_export", api.sessionControl().exportCheckpoint()(raw_session, &export_config, &exported, &diagnostic));
    if (exported.total_bytes != checkpoint.len or checkpoint.len == 0) return error.InvalidCheckpoint;
    try expectOk(api, "destroy_before_restore", api.session().destroy()(raw_session, null));
    session_live = false;
    var source = std.mem.zeroes(wire.CheckpointSourceV1);
    source.struct_size = @sizeOf(wire.CheckpointSourceV1);
    source.ctx = &checkpoint;
    source.read = Checkpoint.read;
    var restore_config = std.mem.zeroes(wire.SessionRestoreConfigV1);
    restore_config.struct_size = @sizeOf(wire.SessionRestoreConfigV1);
    restore_config.host = &host;
    restore_config.source = &source;
    restore_config.limits = &limits;
    var restored: ?*wire.SessionHandle = null;
    var report = std.mem.zeroes(wire.OwnedBytesV1);
    defer releaseOwned(api, &report);
    releaseOwned(api, &diagnostic);
    try expectOk(api, "image_restore", api.sessionControl().restore()(runtime, &restore_config, &callbacks, &restored, &report, &diagnostic));
    defer _ = api.session().destroy()(restored, null);
    var decoded = try agentcore.decodeRestoreReport(allocator, try agentcore.borrowedBytes(.{ .ptr = report.ptr, .len = report.len }));
    defer decoded.deinit();
    if (decoded.value.health != .complete) return error.DegradedRestore;
    releaseOwned(api, &diagnostic);
    const restored_run_id = large_run_id + 1;
    try expectOk(api, "restored_multimodal_history", api.session().runText(restored, restored_run_id, agentcore.bytesView("Continue after restore."), &options, &result, &diagnostic));
    try validateResult(result);

    if (__EXPECT_UNKNOWN_IMAGE_REJECTION__) {
        try expectOk(api, "set_unknown_model", api.sessionControl().setModel()(restored, agentcore.bytesView("unknown-provider-test-model"), null));
        const events_before = provider_test.event_count;
        releaseOwned(api, &diagnostic);
        const rejected_run_id = restored_run_id + 1;
        const rejected = api.session().runMultimodal(restored, rejected_run_id, &parts, &options, &result, &diagnostic);
        if (rejected != wire.STATUS_IMAGE_INPUT_UNSUPPORTED or provider_test.event_count != events_before)
            return error.UnexpectedImageRejection;
        releaseOwned(api, &diagnostic);
        try expectOk(api, "restore_multimodal_model", api.sessionControl().setModel()(restored, agentcore.bytesView("__MODEL__"), null));
    } else {
        // Gemini's unknown-model defaults accept images; use a malformed input
        // to verify admission atomicity without asserting a nonexistent gate.
        const empty_parts = [_]wire.RunInputPartV1{agentcore.textPart("")};
        releaseOwned(api, &diagnostic);
        if (api.session().runMultimodal(restored, restored_run_id + 1, &empty_parts, &options, &result, &diagnostic) != wire.STATUS_INVALID_ARGUMENT)
            return error.UnexpectedInvalidInputStatus;
    }
    releaseOwned(api, &diagnostic);
    const rejection_history_run_id = restored_run_id + 1;
    try expectOk(api, "rejection_history", api.session().runText(restored, rejection_history_run_id, agentcore.bytesView("Continue after rejection."), &options, &result, &diagnostic));
    try validateResult(result);
    if (__EXPECT_UNKNOWN_IMAGE_REJECTION__) {
        try expectOk(api, "set_text_only_model_after_images", api.sessionControl().setModel()(restored, agentcore.bytesView("unknown-provider-test-model"), null));
        releaseOwned(api, &diagnostic);
        try expectOk(api, "unsupported_history_status", api.session().runText(restored, rejection_history_run_id + 1, agentcore.bytesView("History cannot be sent to this model."), &options, &result, &diagnostic));
        if (try agentcore.StopReason.fromCode(result.stop_reason_code) != .api_error)
            return error.UnexpectedHistoryFailure;
    }
    if (provider_test.max_event_bytes > 512 * 1024) return error.EventTooLarge;
    std.debug.print("multimodal events maximum bytes={d}\n", .{provider_test.max_event_bytes});
}
