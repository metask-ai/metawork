//! Direct primitives are exposed only by this disposable probe, never Product.
const std = @import("std");
const sqlite = @import("metawork_storage_sqlite");
extern fn stage_a_primitives() c_int;
test "stage A canonical SQLite primitive feasibility" {
    // Instantiate the existing backend so its canonical engine is linked.
    const database = try sqlite.Database.create(std.testing.io, std.testing.allocator, .memory, &.{});
    try database.destroy();
    try std.testing.expectEqual(@as(c_int, 0), stage_a_primitives());
}
