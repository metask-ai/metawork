//! Backend-independent, business-agnostic storage capabilities.

pub const sql = @import("storage/sql.zig");
pub const sqlite = @import("storage/sqlite.zig");

test {
    _ = sql;
    _ = sqlite;
    _ = @import("storage/conformance.zig");
}
