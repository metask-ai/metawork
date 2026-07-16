const std = @import("std");
const sdk = @import("metacodes_agentcore");
const wire = sdk.types;

test "discovers the pinned ABI through the bundle SDK" {
    const api = try sdk.Api.discover();
    try std.testing.expectEqual(wire.ABI_VERSION_V1, api.raw.abi_version);
    try std.testing.expectEqual(
        wire.REQUIRED_CAPABILITIES_V1,
        api.raw.capabilities & wire.REQUIRED_CAPABILITIES_V1,
    );

    var missing_capability = api.raw.*;
    missing_capability.capabilities &= ~wire.CAP_ABORT;
    try std.testing.expectError(error.UnsupportedAbi, sdk.Api.validate(&missing_capability));

    var missing_function = api.raw.*;
    missing_function.session_run = null;
    try std.testing.expectError(error.UnsupportedAbi, sdk.Api.validate(&missing_function));
}

test "validates every SDK status and stop reason without accepting unknown codes" {
    inline for (std.meta.fields(sdk.Status)) |field| {
        const expected: sdk.Status = @enumFromInt(field.value);
        try std.testing.expectEqual(expected, try sdk.Status.fromCode(field.value));
    }
    inline for (std.meta.fields(sdk.StopReason)) |field| {
        const expected: sdk.StopReason = @enumFromInt(field.value);
        const actual = try sdk.StopReason.fromCode(field.value);
        try std.testing.expectEqual(expected, actual);
        consumeStopReason(actual);
    }
    try std.testing.expectError(error.UnknownStatus, sdk.Status.fromCode(10));
    try std.testing.expectError(error.UnknownStatus, sdk.Status.fromCode(std.math.maxInt(u32)));
    try std.testing.expectError(error.UnknownStopReason, sdk.StopReason.fromCode(10));
    try std.testing.expectError(error.UnknownStopReason, sdk.StopReason.fromCode(std.math.maxInt(u32)));
}

fn consumeStopReason(reason: sdk.StopReason) void {
    switch (reason) {
        .invalid,
        .end_turn,
        .max_turns,
        .aborted,
        .tool_error,
        .api_error,
        .tool_loop,
        .suspended,
        .backgrounded,
        .budget,
        => {},
    }
}

test "validates borrowed byte views at the SDK boundary" {
    const empty = try sdk.borrowedBytes(.{ .ptr = null, .len = 0 });
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    try std.testing.expectError(
        error.InvalidBytesView,
        sdk.borrowedBytes(.{ .ptr = null, .len = 1 }),
    );
    try std.testing.expectError(
        error.InvalidBytesView,
        sdk.borrowedBytes(.{ .ptr = null, .len = std.math.maxInt(u64) }),
    );

    const bytes = "owned by caller";
    try std.testing.expectEqualStrings(bytes, try sdk.borrowedBytes(sdk.bytesView(bytes)));
}

test "decodes every CoreEvent variant from SDK-owned typed values" {
    const trace = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
    const events = [_]sdk.CoreEvent{
        .{ .text_chunk = "hello" },
        .stream_begin,
        .{ .tool_start = .{ .id = "t1", .name = "Read", .input = "{}" } },
        .{ .set_current_tool = .{ .name = "Read" } },
        .{ .tool_progress = .{ .id = "t1", .text = "working" } },
        .{ .progress = .{ .turn = 1, .tool_name = "Read", .tool_input = "{}", .tool_calls = 2 } },
        .clear_current_tool,
        .{ .tool_result = .{ .id = "t1", .name = "Read", .input = "{}", .content = "ok", .is_error = false } },
        .{ .usage = .{ .input_tokens = 1, .output_tokens = 2 } },
        .{ .phase_change = .generating },
        .{ .context_warning = .{ .current_tokens = 1, .warning_threshold = 2, .auto_compact_threshold = 3, .blocking_limit = 4, .level = "medium" } },
        .{ .auto_compact = .{ .dropped = 1, .kept = 2 } },
        .{ .retry_notice = .{ .attempt = 1, .max = 2, .delay_ms = 3 } },
        .stream_done,
        .{ .ui_request_pending = .{ .tool_use_id = "t1", .request_json = "{}" } },
        .{ .diag_turn_begin = .{ .trace_id = trace, .depth = 0, .turn = 1 } },
        .{ .diag_turn_end = .{ .trace_id = trace, .depth = 0, .turn = 1, .tool_calls = 2 } },
        .{ .diag_breaker_tripped = .{ .trace_id = trace, .depth = 0, .same_err_count = 3 } },
        .{ .diag_cache_break = .{ .trace_id = trace, .depth = 0, .cache_read = 4, .cache_creation = 5 } },
        .{ .diag_continuation = .{ .trace_id = trace, .depth = 0, .n = 1, .max = 2 } },
        .{ .diag_run_end = .{ .trace_id = trace, .depth = 0, .turns = 1, .tool_calls = 2, .stop_reason_name = "end_turn" } },
    };

    for (events) |event| {
        const encoded = try std.json.Stringify.valueAlloc(std.testing.allocator, event, .{});
        defer std.testing.allocator.free(encoded);
        var decoded = try sdk.decodeCoreEvent(std.testing.allocator, encoded);
        defer decoded.deinit();
        try std.testing.expectEqual(std.meta.activeTag(event), std.meta.activeTag(decoded.value));
    }
}

test "CoreEvent decoder owns retained data and fails closed" {
    const allocator = std.testing.allocator;
    const encoded = try allocator.dupe(u8, "{\"text_chunk\":\"retained\"}");
    var decoded = try sdk.decodeCoreEvent(allocator, encoded);
    @memset(encoded, 'x');
    allocator.free(encoded);
    defer decoded.deinit();
    try std.testing.expectEqualStrings("retained", decoded.value.text_chunk);

    try std.testing.expectError(error.MalformedJson, sdk.decodeCoreEvent(allocator, "{"));
    try std.testing.expectError(error.UnknownTag, sdk.decodeCoreEvent(allocator, "{\"future_event\":{}}"));
    try std.testing.expectError(error.InvalidPayload, sdk.decodeCoreEvent(allocator, "{\"retry_notice\":{\"attempt\":1}}"));
    try std.testing.expectError(error.InvalidPayload, sdk.decodeCoreEvent(allocator, "{\"stream_begin\":{},\"stream_done\":{}}"));
}

test "decodes every UiRequest and encodes only its matching UiResponse" {
    const allocator = std.testing.allocator;
    const questions = [_]sdk.protocol.AskQuestion{.{
        .question = "Continue?",
        .header = "Choice",
        .multi = false,
        .options = &.{.{ .label = "Yes", .description = "Proceed" }},
    }};
    const requests = [_]sdk.UiRequest{
        .{ .ask_question = &questions },
        .{ .permission = .{ .tool = "Bash", .args = "{}" } },
        .{ .plan_approval = .{ .plan_md = "Do it", .kg_step_count = 2 } },
        .{ .custom = .{ .kind = "fixture", .payload_json = "{}" } },
    };
    for (requests) |request| {
        const encoded = try std.json.Stringify.valueAlloc(allocator, request, .{});
        defer allocator.free(encoded);
        var decoded = try sdk.decodeUiRequest(allocator, encoded);
        defer decoded.deinit();
        try std.testing.expectEqual(std.meta.activeTag(request), std.meta.activeTag(decoded.value));
    }

    const answers = [_][]const u8{"Yes"};
    const answer_json = try sdk.encodeUiResponse(allocator, requests[0], .{ .answers = &answers });
    defer allocator.free(answer_json);
    try std.testing.expectEqualStrings("{\"answers\":[\"Yes\"]}", answer_json);

    const permission_json = try sdk.encodeUiResponse(allocator, requests[1], .{ .permission = .allow_once });
    defer allocator.free(permission_json);
    try std.testing.expectEqualStrings("{\"permission\":\"allow_once\"}", permission_json);

    const plan_json = try sdk.encodeUiResponse(allocator, requests[2], .{ .plan_approval = .approve_default });
    defer allocator.free(plan_json);
    try std.testing.expectEqualStrings("{\"plan_approval\":\"approve_default\"}", plan_json);

    const custom_json = try sdk.encodeUiResponse(allocator, requests[3], .{ .custom = "{\"ok\":true}" });
    defer allocator.free(custom_json);
    try std.testing.expectEqualStrings("{\"custom\":\"{\\\"ok\\\":true}\"}", custom_json);

    try std.testing.expectError(
        error.MismatchedResponse,
        sdk.encodeUiResponse(allocator, requests[1], .{ .answers = &answers }),
    );
    try std.testing.expectError(
        error.InvalidResponse,
        sdk.encodeUiResponse(allocator, requests[0], .{ .answers = &.{} }),
    );
    try std.testing.expectError(error.MalformedJson, sdk.decodeUiRequest(allocator, "{"));
    try std.testing.expectError(error.UnknownTag, sdk.decodeUiRequest(allocator, "{\"future_request\":{}}"));
    try std.testing.expectError(error.InvalidPayload, sdk.decodeUiRequest(allocator, "{\"permission\":{\"tool\":\"Bash\"}}"));
}

test "normalizes decoder and encoder allocation failures" {
    var decode_failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        sdk.decodeCoreEvent(decode_failing.allocator(), "{\"text_chunk\":\"x\"}"),
    );

    var encode_failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const request = sdk.UiRequest{ .custom = .{ .kind = "fixture", .payload_json = "{}" } };
    try std.testing.expectError(
        error.OutOfMemory,
        sdk.encodeUiResponse(encode_failing.allocator(), request, .{ .custom = "{}" }),
    );
}
