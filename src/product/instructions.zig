//! The user's own instruction files, global and per working directory: where
//! they live, how a turn reads them, and what each Run reports it carried.
pub const source = @import("instructions/source.zig");

test {
    _ = source;
}
