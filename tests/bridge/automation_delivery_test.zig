const fixture = @import("lifecycle_fixture");
const std = fixture.std;
const automation_delivery = fixture.automation_delivery;
const deliveryInput = fixture.deliveryInput;
test "Gate 5 delivery rejects zero sentinel identities" {
    var delivery = try automation_delivery.Delivery.init(std.testing.allocator, .{
        .inline_event_bytes = 64,
        .batch_count = 1,
        .batch_bytes = 256,
        .batch_sessions = 1,
        .batch_per_session = 1,
        .retention_count = 1,
        .retention_bytes = 128,
        .retention_ns = 100,
        .object_count = 1,
        .object_bytes = 64,
        .per_session_object_count = 1,
        .per_session_object_bytes = 64,
        .max_object_bytes = 64,
        .route_slots = 1,
    });
    defer delivery.deinit();
    var invalid_delivery = try deliveryInput(std.testing.allocator, 1, 0, "{}");
    try std.testing.expectError(error.InvalidIdentity, delivery.ingest(invalid_delivery));
    invalid_delivery.deinit();
}

test "Gate 5 delivery rejects configurations that cannot fit an inline envelope" {
    try std.testing.expectError(
        error.InvalidLimits,
        automation_delivery.Delivery.init(std.testing.allocator, .{
            .inline_event_bytes = 97,
            .batch_count = 1,
            .batch_bytes = 256,
            .batch_sessions = 1,
            .batch_per_session = 1,
            .retention_count = 1,
            .retention_bytes = 256,
            .retention_ns = 100,
            .object_count = 1,
            .object_bytes = 128,
            .per_session_object_count = 1,
            .per_session_object_bytes = 128,
            .max_object_bytes = 128,
            .route_slots = 1,
        }),
    );
}

test "Gate 5 delivery enforces retention and object budgets and releases on acknowledgement" {
    var delivery = try automation_delivery.Delivery.init(std.testing.allocator, .{
        .inline_event_bytes = 16,
        .batch_count = 2,
        .batch_bytes = 256,
        .batch_sessions = 1,
        .batch_per_session = 2,
        .retention_count = 2,
        .retention_bytes = 256,
        .retention_ns = 100,
        .object_count = 1,
        .object_bytes = 128,
        .per_session_object_count = 1,
        .per_session_object_bytes = 128,
        .max_object_bytes = 128,
        .route_slots = 1,
    });
    defer delivery.deinit();

    const object_json = "{\"payload\":\"xxxxxxxxxxxxxxxx\"}";
    try delivery.ingest(try deliveryInput(std.testing.allocator, 1, 1, object_json));
    var rejected_object = try deliveryInput(std.testing.allocator, 1, 1, object_json);
    try std.testing.expectError(error.ObjectCapacity, delivery.ingest(rejected_object));
    rejected_object.deinit();
    try delivery.ingest(try deliveryInput(std.testing.allocator, 1, 1, "{}"));
    var rejected_retention = try deliveryInput(std.testing.allocator, 1, 1, "{}");
    try std.testing.expectError(error.RetentionCapacity, delivery.ingest(rejected_retention));
    rejected_retention.deinit();

    const generation = try delivery.connect();
    var batch = (try delivery.buildBatch(generation)).?;
    defer batch.deinit();
    try delivery.commitBatch(&batch);
    try delivery.acknowledge(generation, 1, 1, 1);
    const after_object_ack = delivery.stats();
    try std.testing.expectEqual(@as(usize, 1), after_object_ack.retained_count);
    try std.testing.expectEqual(@as(usize, 0), after_object_ack.object_count);
    try std.testing.expectEqual(@as(usize, 0), after_object_ack.object_bytes);
    try delivery.acknowledge(generation, 1, 1, 2);
    try std.testing.expectEqual(@as(usize, 0), delivery.stats().retained_count);
}

test "Gate 5 delivery batch is byte bounded and fair across Sessions" {
    var delivery = try automation_delivery.Delivery.init(std.testing.allocator, .{
        .inline_event_bytes = 64,
        .batch_count = 4,
        .batch_bytes = 512,
        .batch_sessions = 2,
        .batch_per_session = 2,
        .retention_count = 8,
        .retention_bytes = 4096,
        .retention_ns = 100,
        .object_count = 2,
        .object_bytes = 512,
        .per_session_object_count = 1,
        .per_session_object_bytes = 256,
        .max_object_bytes = 256,
        .route_slots = 3,
    });
    defer delivery.deinit();
    for (0..3) |_| try delivery.ingest(try deliveryInput(std.testing.allocator, 1, 1, "{}"));
    for (0..2) |_| try delivery.ingest(try deliveryInput(std.testing.allocator, 2, 1, "{}"));
    try delivery.ingest(try deliveryInput(std.testing.allocator, 3, 1, "{}"));

    const generation = try delivery.connect();
    var first = (try delivery.buildBatch(generation)).?;
    defer first.deinit();
    try std.testing.expectEqual(@as(usize, 4), first.item_count);
    try std.testing.expect(first.json.len <= 512);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, first.json, "\"sessionId\":\"1\""));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, first.json, "\"sessionId\":\"2\""));
    try delivery.commitBatch(&first);
    var second = (try delivery.buildBatch(generation)).?;
    defer second.deinit();
    try std.testing.expectEqual(@as(usize, 2), second.item_count);
    try std.testing.expect(std.mem.indexOf(u8, second.json, "\"sessionId\":\"3\"") != null);
    try delivery.commitBatch(&second);
}

test "Gate 5 delivery OOM does not mark an event sent" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var delivery = try automation_delivery.Delivery.init(failing.allocator(), .{
        .inline_event_bytes = 64,
        .batch_count = 1,
        .batch_bytes = 256,
        .batch_sessions = 1,
        .batch_per_session = 1,
        .retention_count = 1,
        .retention_bytes = 128,
        .retention_ns = 100,
        .object_count = 1,
        .object_bytes = 64,
        .per_session_object_count = 1,
        .per_session_object_bytes = 64,
        .max_object_bytes = 64,
        .route_slots = 1,
    });
    defer delivery.deinit();
    try delivery.ingest(try deliveryInput(std.testing.allocator, 1, 1, "{}"));
    const generation = try delivery.connect();
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, delivery.buildBatch(generation));
    try std.testing.expect(failing.has_induced_failure);
    failing.fail_index = std.math.maxInt(usize);
    var retry = (try delivery.buildBatch(generation)).?;
    defer retry.deinit();
    try std.testing.expectEqual(@as(usize, 1), retry.item_count);
}

test "Gate 5 delivery rejects a batch built by another owner" {
    const limits = automation_delivery.Limits{
        .inline_event_bytes = 64,
        .batch_count = 1,
        .batch_bytes = 256,
        .batch_sessions = 1,
        .batch_per_session = 1,
        .retention_count = 1,
        .retention_bytes = 128,
        .retention_ns = 100,
        .object_count = 1,
        .object_bytes = 64,
        .per_session_object_count = 1,
        .per_session_object_bytes = 64,
        .max_object_bytes = 64,
        .route_slots = 1,
    };
    var first = try automation_delivery.Delivery.init(std.testing.allocator, limits);
    defer first.deinit();
    var second = try automation_delivery.Delivery.init(std.testing.allocator, limits);
    defer second.deinit();
    try first.ingest(try deliveryInput(std.testing.allocator, 1, 1, "{}"));
    const generation = try first.connect();
    _ = try second.connect();
    var batch = (try first.buildBatch(generation)).?;
    defer batch.deinit();
    try std.testing.expectError(error.ForeignBatch, second.commitBatch(&batch));
    try first.commitBatch(&batch);
}
