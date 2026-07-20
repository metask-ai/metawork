const std = @import("std");
const sdk = @import("metask_agentcore");
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
    try std.testing.expectError(error.UnknownStatus, sdk.Status.fromCode(11));
    try std.testing.expectError(error.UnknownStatus, sdk.Status.fromCode(std.math.maxInt(u32)));
    try std.testing.expectError(error.UnknownStopReason, sdk.StopReason.fromCode(10));
    try std.testing.expectError(error.UnknownStopReason, sdk.StopReason.fromCode(std.math.maxInt(u32)));
}

fn consumeStopReason(reason: sdk.StopReason) void {
    switch (reason) {
        .end_turn,
        .max_turns,
        .aborted,
        .tool_error,
        .api_error,
        .tool_loop,
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
    const events = [_]sdk.CoreEvent{
        .{ .text_chunk = "hello" },
        .{ .tool_start = .{ .id = "t1", .name = "Read", .input = "{}" } },
        .{ .tool_progress = .{ .id = "t1", .text = "working" } },
        .{ .progress = .{ .turn = 1, .tool_name = "Read", .tool_input = "{}", .tool_calls = 2 } },
        .{ .tool_result = .{ .id = "t1", .name = "Read", .input = "{}", .content = "ok", .is_error = false, .elapsed_ms = 4 } },
        .{ .usage = .{ .input_tokens = 1, .output_tokens = 2 } },
        .{ .context_warning = .{ .current_tokens = 1, .warning_threshold = 2, .auto_compact_threshold = 3, .blocking_limit = 4, .level = "medium" } },
        .{ .auto_compact = .{ .dropped = 1, .kept = 2, .before_tokens = 3, .after_tokens = 4, .cause = "trigger" } },
        .{ .retry_notice = .{ .attempt = 1, .max = 2, .delay_ms = 3 } },
        .stream_done,
    };

    for (events) |event| {
        const encoded = try std.json.Stringify.valueAlloc(std.testing.allocator, event, .{});
        defer std.testing.allocator.free(encoded);
        var decoded = try sdk.decodeCoreEvent(std.testing.allocator, encoded);
        defer decoded.deinit();
        switch (decoded.value) {
            .known => |known| try std.testing.expectEqual(std.meta.activeTag(event), std.meta.activeTag(known)),
            .unknown => return error.UnexpectedUnknownEvent,
        }
    }
}

test "CoreEvent decoder owns retained data, preserves unknown observations, and fails closed" {
    const allocator = std.testing.allocator;
    const encoded = try allocator.dupe(u8, "{\"text_chunk\":\"retained\"}");
    var decoded = try sdk.decodeCoreEvent(allocator, encoded);
    @memset(encoded, 'x');
    allocator.free(encoded);
    defer decoded.deinit();
    switch (decoded.value) {
        .known => |event| try std.testing.expectEqualStrings("retained", event.text_chunk),
        .unknown => return error.UnexpectedUnknownEvent,
    }

    var unknown = try sdk.decodeCoreEvent(allocator, "{\"future_event\":{\"answer\":42}}");
    defer unknown.deinit();
    switch (unknown.value) {
        .known => return error.UnexpectedKnownEvent,
        .unknown => |event| {
            try std.testing.expectEqualStrings("future_event", event.tag);
            try std.testing.expectEqualStrings("{\"answer\":42}", event.payload_json);
        },
    }

    try std.testing.expectError(error.MalformedJson, sdk.decodeCoreEvent(allocator, "{"));
    try std.testing.expectError(error.InvalidPayload, sdk.decodeCoreEvent(allocator, "{\"retry_notice\":{\"attempt\":1}}"));
    try std.testing.expectError(error.InvalidPayload, sdk.decodeCoreEvent(allocator, "{\"future_event\":{},\"stream_done\":{}}"));
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
    const questions = [_]sdk.protocol.AskQuestion{.{
        .question = "Continue?",
        .header = "Choice",
        .multi = false,
        .options = &.{},
    }};
    const answers = [_][]const u8{"Yes"};
    const request = sdk.UiRequest{ .ask_question = &questions };
    try std.testing.expectError(
        error.OutOfMemory,
        sdk.encodeUiResponse(encode_failing.allocator(), request, .{ .answers = &answers }),
    );
}
