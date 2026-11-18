//! The execution half's handle table: the objects a caller names but does not
//! hold.
//!
//! A port method that returns a live lease, selection or activation cannot send
//! the pointer, so it sends an id and keeps the object here.
//!
//! This half needs a table for every handle but one. The catalog query's
//! source lifetime pointed the other way and turned out to be forbidden from
//! crossing by its own contract. The MCP installation tool, though, really
//! does call back: it hands an install request to the caller and reads the
//! answer, because it has to tell the model whether the request was accepted.
//! That path is recorded as owed in `shapes.McpInstallationTarget` and belongs
//! to the MCP step; until it is designed, do not read this file as proof that
//! calls only go one way.
//!
//! The id carries a generation, and that is the whole design. A table that
//! handed out bare slot indices would resolve a stale id to whatever object
//! later took that slot -- a wrong answer indistinguishable from a right one,
//! which is the failure this change has been refusing everywhere else. With a
//! generation, a stale id resolves to nothing, and nothing is a protocol
//! violation the caller can be told about.
//!
//! The table is bounded and never grows. Capacity exhaustion is a typed
//! failure the caller maps onto the admission result it already has, not an
//! allocation at the moment a Run needs one.

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

    pub fn bits(self: Id) u64 {
        return @bitCast(self);
    }

    pub fn fromBits(value: u64) Id {
        return @bitCast(value);
    }
};

pub const InsertError = error{
    /// Every slot is live. A bounded table says so instead of growing.
    HandleCapacity,
    /// This slot has issued every generation it can. Astronomically unlikely
    /// and still not silently wrapped: a wrapped generation would bring back
    /// exactly the stale-id confusion the generation exists to prevent.
    GenerationExhausted,
};

/// A table of `*T`. The table never frees what it holds; `take` hands the
/// pointer back so whoever owns it can.
pub fn Table(comptime T: type) type {
    return struct {
        const Self = @This();

        /// The type states its own kind, so "which of these fields is a
        /// handle table" is a question about the type rather than about a
        /// name someone chose. The reclamation inventory in `adapters.zig`
        /// closes over this.
        pub const is_handle_table = true;
        pub const Held = T;

        const Slot = struct {
            /// The generation this slot is currently at. Odd means live, even
            /// means free, so a slot's history cannot be confused with its
            /// state.
            generation: u32 = 0,
            value: ?*T = null,
        };

        allocator: std.mem.Allocator,
        slots: []Slot,
        live: usize = 0,

        pub fn init(allocator: std.mem.Allocator, slot_count: usize) std.mem.Allocator.Error!Self {
            std.debug.assert(slot_count > 0);
            const slots = try allocator.alloc(Slot, slot_count);
            @memset(slots, .{});
            return .{ .allocator = allocator, .slots = slots };
        }

        /// Releases the table itself. Every handle must already be taken: a
        /// table that dropped live objects would leak them silently, so the
        /// caller is required to have drained it.
        pub fn deinit(self: *Self) void {
            std.debug.assert(self.live == 0);
            self.allocator.free(self.slots);
            self.* = undefined;
        }

        pub fn insert(self: *Self, value: *T) InsertError!Id {
            for (self.slots, 0..) |*slot, index| {
                if (slot.value != null) continue;
                if (slot.generation == std.math.maxInt(u32)) return error.GenerationExhausted;
                slot.generation += 1;
                slot.value = value;
                self.live += 1;
                return .{ .slot = @intCast(index + 1), .generation = slot.generation };
            }
            return error.HandleCapacity;
        }

        /// The object, or `null` for an id this table never issued, already
        /// took back, or issued for an earlier occupant of the slot.
        pub fn resolve(self: *const Self, id: Id) ?*T {
            const slot = self.slotOf(id) orelse return null;
            return slot.value;
        }

        /// Hands the object back and retires the id. A second take of the same
        /// id returns `null` rather than the object twice, so a duplicate
        /// release from the caller cannot become a double free here.
        pub fn take(self: *Self, id: Id) ?*T {
            const index = self.indexOf(id) orelse return null;
            const slot = &self.slots[index];
            const value = slot.value orelse return null;
            slot.value = null;
            // Step again, so the retired id cannot match this slot's next
            // occupant either.
            if (slot.generation != std.math.maxInt(u32)) slot.generation += 1;
            self.live -= 1;
            return value;
        }

        pub fn liveCount(self: *const Self) usize {
            return self.live;
        }

        pub fn capacity(self: *const Self) usize {
            return self.slots.len;
        }

        /// Every live object, for the closure that has to release what the
        /// other half can no longer ask about.
        pub fn drain(self: *Self, output: []*T) []*T {
            var count: usize = 0;
            for (self.slots) |*slot| {
                if (count == output.len) break;
                const value = slot.value orelse continue;
                slot.value = null;
                if (slot.generation != std.math.maxInt(u32)) slot.generation += 1;
                self.live -= 1;
                output[count] = value;
                count += 1;
            }
            return output[0..count];
        }

        fn indexOf(self: *const Self, id: Id) ?usize {
            if (!id.valid()) return null;
            const index = @as(usize, id.slot) - 1;
            if (index >= self.slots.len) return null;
            if (self.slots[index].generation != id.generation) return null;
            return index;
        }

        fn slotOf(self: *const Self, id: Id) ?*const Slot {
            const index = self.indexOf(id) orelse return null;
            return &self.slots[index];
        }
    };
}

const testing = std.testing;

const Thing = struct { tag: u32 };

test "an id round-trips to its object and nothing else does" {
    var first: Thing = .{ .tag = 1 };
    var second: Thing = .{ .tag = 2 };
    var table = try Table(Thing).init(testing.allocator, 4);
    defer table.deinit();

    const a = try table.insert(&first);
    const b = try table.insert(&second);
    try testing.expect(a.valid() and b.valid());
    try testing.expect(a.bits() != b.bits());
    try testing.expectEqual(@as(u32, 1), table.resolve(a).?.tag);
    try testing.expectEqual(@as(u32, 2), table.resolve(b).?.tag);
    try testing.expectEqual(@as(usize, 2), table.liveCount());

    // An id this table never issued.
    try testing.expect(table.resolve(.none) == null);
    try testing.expect(table.resolve(.{ .slot = 99, .generation = 1 }) == null);
    try testing.expect(table.resolve(.{ .slot = a.slot, .generation = a.generation + 7 }) == null);

    _ = table.take(a);
    _ = table.take(b);
}

test "a retired id never resolves to the slot's next occupant" {
    // The reason the id carries a generation. Without it a stale id would
    // answer with a different object, which is a wrong answer that looks
    // exactly like a right one.
    var first: Thing = .{ .tag = 1 };
    var second: Thing = .{ .tag = 2 };
    var table = try Table(Thing).init(testing.allocator, 1);
    defer table.deinit();

    const stale = try table.insert(&first);
    try testing.expectEqual(&first, table.take(stale).?);
    try testing.expect(table.resolve(stale) == null);

    const fresh = try table.insert(&second);
    try testing.expect(fresh.bits() != stale.bits());
    try testing.expectEqual(@as(u32, 2), table.resolve(fresh).?.tag);
    // The point: the old id still answers nothing, even though its slot is
    // live again.
    try testing.expect(table.resolve(stale) == null);
    try testing.expect(table.take(stale) == null);
    _ = table.take(fresh);
}

test "taking twice returns the object once" {
    var thing: Thing = .{ .tag = 7 };
    var table = try Table(Thing).init(testing.allocator, 2);
    defer table.deinit();
    const id = try table.insert(&thing);
    try testing.expectEqual(&thing, table.take(id).?);
    try testing.expect(table.take(id) == null);
    try testing.expectEqual(@as(usize, 0), table.liveCount());
}

test "the bound is a typed failure, not a growth" {
    var things: [3]Thing = .{ .{ .tag = 0 }, .{ .tag = 1 }, .{ .tag = 2 } };
    var table = try Table(Thing).init(testing.allocator, 2);
    defer table.deinit();
    const a = try table.insert(&things[0]);
    const b = try table.insert(&things[1]);
    try testing.expectError(error.HandleCapacity, table.insert(&things[2]));
    try testing.expectEqual(@as(usize, 2), table.capacity());
    _ = table.take(a);
    // A freed slot is reusable, so the bound is on live handles, not on
    // handles ever issued.
    const c = try table.insert(&things[2]);
    try testing.expectEqual(@as(u32, 2), table.resolve(c).?.tag);
    _ = table.take(b);
    _ = table.take(c);
}

test "drain hands back everything live, for the closure that has to release it" {
    var things: [3]Thing = .{ .{ .tag = 0 }, .{ .tag = 1 }, .{ .tag = 2 } };
    var table = try Table(Thing).init(testing.allocator, 4);
    defer table.deinit();
    const ids = [_]Id{
        try table.insert(&things[0]),
        try table.insert(&things[1]),
        try table.insert(&things[2]),
    };
    var storage: [4]*Thing = undefined;
    const drained = table.drain(&storage);
    try testing.expectEqual(@as(usize, 3), drained.len);
    try testing.expectEqual(@as(usize, 0), table.liveCount());
    // Every id is retired by the drain, so a caller that did not hear about
    // the closure cannot resolve one afterwards.
    for (ids) |id| try testing.expect(table.resolve(id) == null);
}

test "a zero id is invalid by construction, not by convention" {
    try testing.expect(!Id.none.valid());
    try testing.expectEqual(@as(u64, 0), Id.none.bits());
    // A field left at its zero value cannot name a handle.
    const zeroed: Id = @bitCast(@as(u64, 0));
    try testing.expect(!zeroed.valid());
    try testing.expect((Id{ .slot = 1, .generation = 0 }).valid());
    try testing.expectEqual(Id.fromBits((Id{ .slot = 3, .generation = 9 }).bits()).slot, 3);
}
