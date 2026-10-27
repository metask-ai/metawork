//! Product Control's ordered history migrations. No runtime or I/O ownership.
const std = @import("std");
pub const sql = @import("metawork_storage_sql");

pub const migrations: []const sql.Migration = &.{.{
    .version = 1,
    .name = "product_history",
    .sql = @embedFile("migrations/0001_task_history.sql"),
}};

pub const codec = @import("codec.zig");
pub const repository = @import("repository.zig");

comptime {
    @setEvalBranchQuota(4_000_000);
    if (!sql.validMigrations(migrations)) @compileError("Invalid Product history migration list");
    for (migrations) |migration| {
        if (std.mem.indexOfScalar(u8, migration.sql, '\r') != null or
            std.mem.startsWith(u8, migration.sql, "\xef\xbb\xbf") or
            !std.unicode.utf8ValidateSlice(migration.sql))
            @compileError("History migrations must be UTF-8 without BOM, with LF line endings");
    }
}
