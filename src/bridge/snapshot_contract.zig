//! The Bridge-owned descriptor and transport limits, consumed by both endpoints.
const encoding = @import("product_view_encoding");

pub const max_snapshot_bytes = 64 * 1024 * 1024;
// At most 8 Runs x 32 Tools x 7 formatter stages, plus block preparation.
pub const max_preparation_steps = 2048;
pub const chunk_bytes = 256 * 1024;

pub const SnapshotPreparing = struct {
    snapshotId: encoding.PositiveId,
    phase: enum { preparing } = .preparing,
};

pub const SnapshotDescriptor = struct {
    snapshotId: encoding.PositiveId,
    bytes: encoding.PositiveNumber,
    chunkBytes: encoding.PositiveNumber,
};

test "snapshot descriptor wire preserves integer representation and exact public fields" {
    const std = @import("std");
    var storage: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try std.json.Stringify.value(SnapshotDescriptor{
        .snapshotId = .{ .value = std.math.maxInt(u64) },
        .bytes = .{ .value = max_snapshot_bytes },
        .chunkBytes = .{ .value = chunk_bytes },
    }, .{}, &writer);
    try std.testing.expectEqualStrings("{\"snapshotId\":\"18446744073709551615\",\"bytes\":67108864,\"chunkBytes\":262144}", writer.buffered());
}
