const std = @import("std");
const product = @import("metawork_product_control");

test "Product view preserves a frozen read through updates and revokes stale handles" {
    var control = try product.TestSupport.viewFixture();
    defer control.deinit();
    var expected_storage: [96 * 1024]u8 = undefined;
    const expected = try control.writeViewFixture(&expected_storage, .{ .task_id = 3 });
    var output: [96 * 1024]u8 = undefined;
    var read = try control.writeSnapshot(&output, .{ .task_id = 3 });
    while (read.bytes == 0) read = try control.continueSnapshot(read.id, &output);
    try std.testing.expectError(error.InvalidOffset, control.writeSnapshotRange(read.id, &output, 1, 1));
    try control.writeSnapshotRange(read.id, &output, 0, 64);
    var unrelated_storage: [96 * 1024]u8 = undefined;
    try std.testing.expectError(error.StaleSnapshot, control.writeSnapshotRange(read.id, &unrelated_storage, 64, 64));
    try control.renameTask(3, "new committed title");
    var offset: usize = 0;
    while (offset < read.bytes) : (offset += 64) try control.writeSnapshotRange(read.id, &output, offset, @min(@as(usize, 64), read.bytes - offset));
    try std.testing.expectEqualStrings(expected, output[0..read.bytes]);

    const next = try control.writeSnapshot(&output, .{ .task_id = 3 });
    try std.testing.expect(next.id != read.id);
    try std.testing.expectError(error.StaleSnapshot, control.writeSnapshotRange(read.id, &output, 0, 1));
    product.TestSupport.invalidatePreviewSecurity(&control);
    try std.testing.expectError(error.StaleSnapshot, control.continueSnapshot(next.id, &output));
    const cancelled = try control.writeSnapshot(&output, .{});
    control.cancelSnapshotRead(cancelled.id);
    try std.testing.expectError(error.StaleSnapshot, control.continueSnapshot(cancelled.id, &output));
    const last = try control.writeSnapshot(&output, .{});
    control.beginShutdown();
    try std.testing.expectError(error.StaleSnapshot, control.writeSnapshotRange(last.id, &output, 0, 1));
}
