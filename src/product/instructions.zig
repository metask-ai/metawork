//! The user's own instruction files, global and per working directory: where
//! they live, how a turn reads them, what each Run reports it carried, and
//! how the Settings editor loads and saves the global one.
pub const source = @import("instructions/source.zig");
pub const global_file = @import("instructions/global_file.zig");

test {
    _ = source;
    _ = global_file;
}
