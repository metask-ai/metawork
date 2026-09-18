//! Backend-independent, business-agnostic storage capabilities.

pub const sql = @import("metawork_storage_sql");
pub const sqlite = @import("storage/sqlite.zig");

test {
    _ = sql;
    _ = sqlite;
    _ = @import("storage/conformance.zig");
}
