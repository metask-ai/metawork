//! Snapshot identity and bounded chunk transport state.
//! Workbench remains the only owner of snapshot serialization.

const std = @import("std");

pub const WindowId = u64;

pub const max_bytes: usize = @import("snapshot_contract.zig").max_snapshot_bytes;
pub const chunk_bytes: usize = @import("snapshot_contract.zig").chunk_bytes;

pub const Error = error{ StaleSnapshot, InvalidOffset, InvalidStorage };

pub const State = struct {
    storage: []u8 = @constCast(&.{}),
    allocator: ?std.mem.Allocator = null,
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

    pub fn initOwned(allocator: std.mem.Allocator) std.mem.Allocator.Error!State {
        return .{
            .storage = try allocator.alloc(u8, max_bytes),
            .allocator = allocator,
        };
    }

    pub fn deinitOwnedBuffers(self: *State) void {
        self.invalidate();
        if (self.allocator) |allocator| allocator.free(self.storage);
        self.* = .{};
    }

    pub fn invalidate(self: *State) void {
        std.crypto.secureZero(u8, self.storage[0..@max(self.len, self.dirty_len)]);
        self.len = 0;
        self.dirty_len = 0;
        self.generation = 0;
        self.window_id = 0;
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

test "owned snapshot storage has one explicit lifetime" {
    var state = try State.initOwned(std.testing.allocator);
    try std.testing.expectEqual(max_bytes, state.storage.len);
    state.deinitOwnedBuffers();
    try std.testing.expectEqual(@as(usize, 0), state.storage.len);
}
