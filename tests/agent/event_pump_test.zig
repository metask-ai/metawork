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

test "event pump waits for a slow consumer and fails at the hard deadline" {
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
        .timeout = .fromSeconds(1),
    };
    const thread = try std.Thread.spawn(.{}, enqueuePumpOnThread, .{&context});
    try std.testing.io.sleep(.fromMilliseconds(20), .awake);
    var first = pump.takeFair().?;
    first.deinit();
    thread.join();
    try std.testing.expect(context.succeeded);
    try std.testing.expect(context.failure == null);
    var second = pump.takeFair().?;
    second.deinit();

    try pump.enqueue(try pumpEnvelope(1, 1, "{\"text_chunk\":\"third\"}"));
    var timed_out = try pumpEnvelope(1, 1, "{\"text_chunk\":\"fourth\"}");
    try std.testing.expectError(
        error.DeadlineExceeded,
        pump.enqueueWithDeadline(timed_out, .fromMilliseconds(5)),
    );
    timed_out.deinit();
    var third = pump.takeFair().?;
    third.deinit();
}
