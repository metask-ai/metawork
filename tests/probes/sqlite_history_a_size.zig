//! Same tiny executable with/without the canonical backend: linkage estimate only.
const std = @import("std");
const options = @import("stage_a_size_options");
pub fn main(init: std.process.Init) !void {
    if (options.engine) {
        const storage = @import("storage");
        const db = try storage.sqlite.Database.create(init.io, init.gpa, .memory, &.{});
        try db.destroy();
    }
    std.debug.print("stage A link sample\n", .{});
}
