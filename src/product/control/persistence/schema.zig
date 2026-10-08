//! Product Control's ordered history migrations. No runtime or I/O ownership.
const std = @import("std");
const sql = @import("metawork_storage_sql");

pub const migrations: []const sql.Migration = &.{ .{
    .version = 1,
    .name = "task_history",
    .sql = @embedFile("migrations/0001_task_history.sql"),
}, .{
    .version = 2,
    .name = "permission_review_delegation",
    .sql = @embedFile("migrations/0002_permission_review_delegation.sql"),
}, .{
    .version = 3,
    .name = "approval_mode",
    .sql = @embedFile("migrations/0003_approval_mode.sql"),
} };

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
