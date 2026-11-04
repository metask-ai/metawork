const fixture = @import("lifecycle_fixture");
const std = fixture.std;
const event_pump = fixture.event_pump;
const pumpEnvelope = fixture.pumpEnvelope;
const textChunk = fixture.textChunk;
const PumpEnqueueContext = fixture.PumpEnqueueContext;
const enqueuePumpOnThread = fixture.enqueuePumpOnThread;

test "event pump preserves per-Session order with round-robin fairness" {
    var pump = try event_pump.EventPump.init(std.testing.io, std.testing.allocator, .{
        .global_count = 8,
        .global_bytes = 4096,
        .global_control_reserved_count = 2,
        .global_control_reserved_bytes = 512,
        .per_session_count = 4,
        .per_session_bytes = 2048,
        .per_session_control_reserved_count = 1,
        .per_session_control_reserved_bytes = 256,
        .session_slots = 2,
    });
    defer pump.deinit();

    try pump.enqueue(try pumpEnvelope(1, 1, "{\"text_chunk\":\"one\"}"));
    try pump.enqueue(try pumpEnvelope(1, 1, "{\"text_chunk\":\"two\"}"));
    try pump.enqueue(try pumpEnvelope(2, 1, "{\"text_chunk\":\"other\"}"));
    try std.testing.expectEqual(@as(usize, 2), pump.pendingForSession(1));
    try std.testing.expectEqual(@as(usize, 1), pump.pendingForSession(2));
    try std.testing.expectEqual(@as(usize, 0), pump.pendingForSession(3));

    var first = pump.takeFair().?;
    defer first.deinit();
    var second = pump.takeFair().?;
    defer second.deinit();
    var third = pump.takeFair().?;
    defer third.deinit();
    try std.testing.expectEqual(@as(u64, 1), first.session_id);
    try std.testing.expectEqualStrings("one", try textChunk(first.event.value));
    try std.testing.expectEqual(@as(u64, 2), second.session_id);
    try std.testing.expectEqualStrings("other", try textChunk(second.event.value));
    try std.testing.expectEqual(@as(u64, 1), third.session_id);
    try std.testing.expectEqualStrings("two", try textChunk(third.event.value));
    try std.testing.expectEqual(@as(usize, 0), pump.stats().count);
    try std.testing.expectEqual(@as(usize, 0), pump.pendingForSession(1));
    try std.testing.expectEqual(@as(usize, 0), pump.pendingForSession(2));
}

test "event pump data cannot consume reserved control capacity" {
    var pump = try event_pump.EventPump.init(std.testing.io, std.testing.allocator, .{
        .global_count = 5,
        .global_bytes = 1024,
        .global_control_reserved_count = 2,
        .global_control_reserved_bytes = 128,
        .per_session_count = 5,
        .per_session_bytes = 1024,
        .per_session_control_reserved_count = 2,
        .per_session_control_reserved_bytes = 128,
        .session_slots = 1,
    });
    defer pump.deinit();

    try pump.enqueue(try pumpEnvelope(1, 1, "{\"text_chunk\":\"a\"}"));
    try pump.enqueue(try pumpEnvelope(1, 1, "{\"text_chunk\":\"b\"}"));
    try pump.enqueue(try pumpEnvelope(1, 1, "{\"text_chunk\":\"c\"}"));
    var rejected = try pumpEnvelope(1, 1, "{\"text_chunk\":\"d\"}");
    try std.testing.expectError(error.GlobalCapacity, pump.enqueue(rejected));
    rejected.deinit();
    try pump.enqueue(try pumpEnvelope(
        1,
        1,
        "{\"output_segment_begin\":{\"index\":0,\"turn\":1,\"group\":0}}",
    ));
    try pump.enqueue(try pumpEnvelope(
        1,
        1,
        "{\"output_segment_end\":{\"index\":0,\"turn\":1,\"group\":0,\"disposition\":\"final\",\"bytes\":0}}",
    ));
    const stats = pump.stats();
    try std.testing.expectEqual(@as(usize, 5), stats.count);
    try std.testing.expectEqual(@as(usize, 3), stats.data_count);
}

test "event pump rejects zero sentinel identities" {
    var pump = try event_pump.EventPump.init(std.testing.io, std.testing.allocator, .{
        .global_count = 2,
        .global_bytes = 512,
        .global_control_reserved_count = 0,
        .global_control_reserved_bytes = 0,
        .per_session_count = 2,
        .per_session_bytes = 512,
        .per_session_control_reserved_count = 0,
        .per_session_control_reserved_bytes = 0,
        .session_slots = 1,
    });
    defer pump.deinit();
    var invalid = try pumpEnvelope(0, 1, "{\"text_chunk\":\"invalid\"}");
    try std.testing.expectError(error.InvalidIdentity, pump.enqueue(invalid));
    invalid.deinit();
}

test "text chunks remain byte lossless through the event pump" {
    var pump = try event_pump.EventPump.init(std.testing.io, std.testing.allocator, .{
        .global_count = 4,
        .global_bytes = 1024,
        .global_control_reserved_count = 1,
        .global_control_reserved_bytes = 128,
        .per_session_count = 4,
        .per_session_bytes = 1024,
        .per_session_control_reserved_count = 1,
        .per_session_control_reserved_bytes = 128,
        .session_slots = 1,
    });
    defer pump.deinit();
    try pump.enqueue(try pumpEnvelope(1, 1, "{\"text_chunk\":\"hello \"}"));
    try pump.enqueue(try pumpEnvelope(1, 1, "{\"text_chunk\":\"世界\"}"));
    try pump.enqueue(try pumpEnvelope(1, 1, "{\"text_chunk\":\"!\"}"));
    var storage: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    while (pump.takeFair()) |value| {
        var event = value;
        try writer.writeAll(try textChunk(event.event.value));
        event.deinit();
    }
    try std.testing.expectEqualStrings("hello 世界!", writer.buffered());
}

test "event pump waits for a slow consumer until space is available" {
    var pump = try event_pump.EventPump.init(std.testing.io, std.testing.allocator, .{
        .global_count = 1,
        .global_bytes = 1024,
        .global_control_reserved_count = 0,
        .global_control_reserved_bytes = 0,
        .per_session_count = 1,
        .per_session_bytes = 1024,
        .per_session_control_reserved_count = 0,
        .per_session_control_reserved_bytes = 0,
        .session_slots = 1,
    });
    defer pump.deinit();
    try pump.enqueue(try pumpEnvelope(1, 1, "{\"text_chunk\":\"first\"}"));
    var context = PumpEnqueueContext{
        .pump = &pump,
        .envelope = try pumpEnvelope(1, 1, "{\"text_chunk\":\"second\"}"),
    };
    const thread = try std.Thread.spawn(.{}, enqueuePumpOnThread, .{&context});
    try std.testing.io.sleep(.fromMilliseconds(20), .awake);
    try std.testing.expect(!context.finished.load(.acquire));
    var first = pump.takeFair().?;
    first.deinit();
    thread.join();
    try std.testing.expect(context.succeeded);
    try std.testing.expect(context.failure == null);
    var second = pump.takeFair().?;
    second.deinit();
}

test "event pump consumer stop wakes waiters and remains sticky" {
    var pump = try event_pump.EventPump.init(std.testing.io, std.testing.allocator, .{
        .global_count = 1,
        .global_bytes = 1024,
        .global_control_reserved_count = 0,
        .global_control_reserved_bytes = 0,
        .per_session_count = 1,
        .per_session_bytes = 1024,
        .per_session_control_reserved_count = 0,
        .per_session_control_reserved_bytes = 0,
        .session_slots = 1,
    });
    defer pump.deinit();
    try pump.enqueue(try pumpEnvelope(1, 1, "{\"text_chunk\":\"first\"}"));
    var context = PumpEnqueueContext{
        .pump = &pump,
        .envelope = try pumpEnvelope(1, 1, "{\"text_chunk\":\"blocked\"}"),
    };
    defer context.envelope.deinit();
    const thread = try std.Thread.spawn(.{}, enqueuePumpOnThread, .{&context});
    try std.testing.io.sleep(.fromMilliseconds(20), .awake);
    pump.stopWaiting(&context.stopped);
    thread.join();
    try std.testing.expectEqual(error.ConsumerStopped, context.failure.?);
    try std.testing.expect(!context.succeeded);
    try std.testing.expectEqual(@as(usize, 1), pump.pendingForSession(1));
    // The producer retains a rejected envelope; a subsequent callback cannot
    // re-enter the wait even if close has already drained the old queue.
    var first = pump.takeFair().?;
    first.deinit();
    try std.testing.expectError(error.ConsumerStopped, pump.enqueueWaiting(context.envelope, &context.stopped));
}

test "event pump does not wait for an envelope that cannot fit an empty queue" {
    var pump = try event_pump.EventPump.init(std.testing.io, std.testing.allocator, .{
        .global_count = 1,
        .global_bytes = 8,
        .global_control_reserved_count = 0,
        .global_control_reserved_bytes = 0,
        .per_session_count = 1,
        .per_session_bytes = 8,
        .per_session_control_reserved_count = 0,
        .per_session_control_reserved_bytes = 0,
        .session_slots = 1,
    });
    defer pump.deinit();
    var envelope = try pumpEnvelope(1, 1, "{\"text_chunk\":\"larger than the queue\"}");
    defer envelope.deinit();
    const stopped: std.atomic.Value(bool) = .init(false);
    try std.testing.expectError(error.EventTooLarge, pump.enqueueWaiting(envelope, &stopped));
}

test "delivery sideband uses event byte admission and transport retains only original Core JSON" {
    const encoded = "{\"tool_result\":{\"id\":\"deliver-1\",\"name\":\"DeliverFile\",\"input\":\"{}\",\"content\":\"ok\",\"is_error\":false,\"elapsed_ms\":1}}";
    var envelope = try pumpEnvelope(1, 1, encoded);
    const Receipt = std.meta.Child(@TypeOf(envelope.delivered_file));
    envelope.delivered_file = try Receipt.init(@splat(1), "result.docx", 42, @splat(2));
    const owned_bytes = encoded.len + @sizeOf(Receipt);
    try std.testing.expectEqual(owned_bytes, envelope.ownedBytes());
    var pump = try event_pump.EventPump.init(std.testing.io, std.testing.allocator, .{
        .max_event_bytes = owned_bytes - 1,
        .global_count = 2,
        .global_bytes = owned_bytes * 2,
        .global_control_reserved_count = 0,
        .global_control_reserved_bytes = 0,
        .per_session_count = 2,
        .per_session_bytes = owned_bytes * 2,
        .per_session_control_reserved_count = 0,
        .per_session_control_reserved_bytes = 0,
        .session_slots = 1,
    });
    defer pump.deinit();
    try std.testing.expectError(error.EventTooLarge, pump.enqueue(envelope));
    var transport = envelope.takeJson();
    defer transport.deinit();
    try std.testing.expectEqualStrings(encoded, transport.json);
}
