//! The id a handle crosses the link as: the objects a caller names but does
//! not hold.
//!
//! A port method that returns a live lease, selection or activation cannot send
//! the pointer, so it sends an id.
//!
//! The id carries a generation, and that is the whole design. A table that
//! handed out bare slot indices would resolve a stale id to whatever object
//! later took that slot -- a wrong answer indistinguishable from a right one,
//! which is the failure this change has been refusing everywhere else. With a
//! generation, a stale id resolves to nothing, and nothing is a protocol
//! violation the caller can be told about.

const std = @import("std");

/// Slot and generation packed into the id the wire carries. Zero is never
/// issued, so a zero-initialised field cannot be mistaken for a live handle.
pub const Id = packed struct(u64) {
    /// 1-based, so an all-zero id is invalid by construction.
    slot: u32,
    generation: u32,

    pub const none: Id = .{ .slot = 0, .generation = 0 };

    pub fn valid(self: Id) bool {
        return self.slot != 0;
    }
};

const testing = std.testing;

test "a zero id is invalid by construction, not by convention" {
    try testing.expect(!Id.none.valid());
    // A field left at its zero value cannot name a handle.
    const zeroed: Id = @bitCast(@as(u64, 0));
    try testing.expect(!zeroed.valid());
    try testing.expect((Id{ .slot = 1, .generation = 0 }).valid());
}
