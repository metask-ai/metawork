//! Backend-independent, business-agnostic storage capabilities.

pub const sql = @import("storage/sql.zig");

test {
    _ = sql;
    _ = @import("storage/conformance.zig");
}
