//! Same tiny executable with/without the canonical backend: linkage estimate only.
const std = @import("std");
const options = @import("stage_a_size_options");
pub fn main(init: std.process.Init) !void {
    if (options.engine) {
        const sqlite = @import("metawork_storage_sqlite");
        const db = try sqlite.Database.create(init.io, init.gpa, .memory, &.{});
        try db.destroy();
    }
    std.debug.print("stage A link sample\n", .{});
}
