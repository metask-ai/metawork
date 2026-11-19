//! Snapshot identity and bounded chunk transport state.
//! Workbench remains the only owner of snapshot serialization.

const std = @import("std");

pub const WindowId = u64;

pub const max_bytes: usize = @import("snapshot_contract.zig").max_snapshot_bytes;
pub const chunk_bytes: usize = @import("snapshot_contract.zig").chunk_bytes;
/// The written extent an owned mapping may keep. A revoked snapshot that wrote
/// no more is cleared in place, so the thread that presents snapshots does not
/// map and fault its storage anew for each one; a snapshot that wrote more, or
/// a write that reported no extent, gives its pages back with the mapping.
pub const retain_bytes: usize = 8 * 1024 * 1024;

pub const Error = error{ StaleSnapshot, InvalidOffset, InvalidStorage };

pub const State = struct {
    storage: []u8 = @constCast(&.{}),
    owned: bool = false,
    len: usize = 0,
    dirty_len: usize = 0,
    id: u64 = 0,
    generation: u64 = 0,
    window_id: WindowId = 0,
    step_bytes: usize = chunk_bytes,

    pub fn init(storage: []u8) Error!State {
        if (storage.len != max_bytes) return error.InvalidStorage;
        return .{ .storage = storage };
    }

    /// Owned storage is a page mapping, taken when a snapshot is first written
    /// and not before. It is a mapping rather than a heap block because
    /// revoking a snapshot then needs no byte written: the pages leave the
    /// process, whatever part of them the snapshot reached.
    pub fn initOwned() State {
        return .{ .owned = true };
    }

    pub fn deinitOwnedBuffers(self: *State) void {
        self.invalidate();
        self.unmap();
        self.* = .{};
    }

    /// Maps owned storage for the snapshot about to be written. The pages are
    /// zero and become resident only where a snapshot writes them, so the full
    /// transport capacity is never filled to be available.
    pub fn acquire(self: *State) std.mem.Allocator.Error!void {
        if (!self.owned or self.storage.len != 0) return;
        const mapped = std.heap.PageAllocator.map(max_bytes, .of(u8)) orelse return error.OutOfMemory;
        self.storage = mapped[0..max_bytes];
    }

    pub fn invalidate(self: *State) void {
        self.revoke(@max(self.len, self.dirty_len));
    }

    /// A failed write reported no extent, so all of the storage counts as
    /// written.
    pub fn invalidateUnreported(self: *State) void {
        self.revoke(self.storage.len);
    }

    fn revoke(self: *State, written: usize) void {
        if (self.owned and written > retain_bytes) self.unmap() else std.crypto.secureZero(u8, self.storage[0..written]);
        self.len = 0;
        self.dirty_len = 0;
        self.generation = 0;
        self.window_id = 0;
    }

    fn unmap(self: *State) void {
        if (!self.owned or self.storage.len == 0) return;
        std.heap.PageAllocator.unmap(@alignCast(self.storage));
        self.storage = @constCast(&.{});
    }

    pub fn publish(
        self: *State,
        len: usize,
        generation: u64,
        window_id: WindowId,
        step_bytes: usize,
    ) Error!void {
        if (len > self.storage.len or step_bytes == 0 or step_bytes > chunk_bytes) return error.InvalidStorage;
        self.id +%= 1;
        if (self.id == 0) self.id = 1;
        self.len = len;
        self.generation = generation;
        self.window_id = window_id;
        self.step_bytes = step_bytes;
    }

    pub fn chunk(
        self: *const State,
        snapshot_id: u64,
        generation: u64,
        window_id: WindowId,
        offset: usize,
    ) Error![]const u8 {
        if (snapshot_id != self.id or generation != self.generation or window_id != self.window_id)
            return error.StaleSnapshot;
        if (self.len == 0) return error.StaleSnapshot;
        if (offset >= self.len) return error.InvalidOffset;
        return self.storage[offset..@min(self.len, offset + self.step_bytes)];
    }
};

test "snapshot transport binds chunks to identity generation and window" {
    var bytes = [_]u8{ 1, 2, 3 };
    var state = State{ .storage = &bytes };
    try state.publish(bytes.len, 4, 7, chunk_bytes);
    try @import("std").testing.expectEqualSlices(u8, &bytes, try state.chunk(1, 4, 7, 0));
    try @import("std").testing.expectError(error.StaleSnapshot, state.chunk(1, 5, 7, 0));
    state.invalidate();
    try @import("std").testing.expectEqual(@as(usize, 0), state.len);
}

test "Product view owned transport storage is mapped on demand and gives a large snapshot's pages back" {
    var state = State.initOwned();
    defer state.deinitOwnedBuffers();
    try std.testing.expectEqual(@as(usize, 0), state.storage.len);

    try state.acquire();
    try std.testing.expectEqual(max_bytes, state.storage.len);
    // Mapped, not filled: a fill would make every page resident.
    try std.testing.expectEqual(@as(u8, 0), state.storage[0]);
    try std.testing.expectEqual(@as(u8, 0), state.storage[max_bytes - 1]);

    // A snapshot within the retained extent is cleared where it is.
    const held = state.storage.ptr;
    @memcpy(state.storage[0..3], "abc");
    try state.publish(3, 4, 7, chunk_bytes);
    state.invalidate();
    try std.testing.expectEqual(held, state.storage.ptr);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0 }, state.storage[0..3]);
    try state.acquire();
    try std.testing.expectEqual(held, state.storage.ptr);

    // A larger one leaves with its mapping,
    state.storage[retain_bytes] = 1;
    try state.publish(retain_bytes + 1, 4, 7, chunk_bytes);
    state.invalidate();
    try std.testing.expectEqual(@as(usize, 0), state.storage.len);
    try std.testing.expectError(error.StaleSnapshot, state.chunk(state.id, 4, 7, 0));

    // and so does a write that failed somewhere in the capacity.
    try state.acquire();
    try std.testing.expectEqual(@as(u8, 0), state.storage[retain_bytes]);
    state.storage[max_bytes - 1] = 1;
    state.invalidateUnreported();
    try std.testing.expectEqual(@as(usize, 0), state.storage.len);
}

test "Product view borrowed transport storage is cleared in place, in full when a write reported no extent" {
    var bytes = [_]u8{ 1, 2, 3, 4 };
    var state = State{ .storage = &bytes };
    try state.acquire();
    try std.testing.expectEqual(@as([*]u8, &bytes), state.storage.ptr);
    try state.publish(2, 4, 7, chunk_bytes);
    state.invalidate();
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 3, 4 }, &bytes);
    state.invalidateUnreported();
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, &bytes);
}
