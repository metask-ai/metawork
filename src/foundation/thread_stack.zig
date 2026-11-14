//! Stack size for a thread the host spawns itself.
//!
//! `std.Thread.SpawnConfig` defaults to 16 MiB, and on Windows that value is
//! passed to `NtCreateThreadEx` as `StackCommit` while `StackReserve` stays at
//! the executable header's value. A full commit is charged to the system-wide
//! commit limit the moment the thread is created, whether or not the stack is
//! ever touched, and exhausting that limit fails allocations in unrelated
//! processes. The host keeps a fixed set of long-lived threads, so the default
//! charges hundreds of megabytes for stacks that stay almost entirely unused.
//!
//! What the two platforms do with this number differs, and both are safe here:
//!
//! - Windows commits this much up front and still reserves the header's size
//!   (16 MiB), growing the stack on demand through its guard page. Lowering it
//!   lowers the pre-charge without lowering the depth a thread can reach.
//! - POSIX maps exactly this much, so it is a hard ceiling.
//!
//! The value is therefore sized against the POSIX ceiling, the stricter of the
//! two: 1 MiB is twice the 512 KiB that platform gives a secondary thread by
//! default. These threads run single-purpose work -- HTTP exchanges, file and
//! image I/O, SQL calls, watchdog timers, job workers -- and every recursive
//! decode they reach is depth bounded by its own owner well under a hundred
//! levels, so no thread here has an input-driven depth. Across the Native test
//! graph and the desktop verticals, no thread carrying this size grew past it.
//!
//! A thread class that needs a deeper stack states its own size at its spawn
//! site with the reason; it does not raise this one.

const std = @import("std");

pub const bytes: usize = 1024 * 1024;

/// Spawn configuration for host-owned threads. Product spawn sites pass this
/// instead of `.{}` so the size stays one decision.
pub const config: std.Thread.SpawnConfig = .{ .stack_size = bytes };

test "the host stack stays under the default and above the Windows floor" {
    // `std.Thread.spawn` raises anything under 64 KiB to that floor on Windows,
    // so a value below it would silently stop being this module's decision.
    try std.testing.expect(bytes >= 64 * 1024);
    try std.testing.expect(bytes < std.Thread.SpawnConfig.default_stack_size);
    try std.testing.expectEqual(bytes, config.stack_size);
}
