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
            /// Promised to a caller that has not filled it yet. `insert`
            /// skips one, because the whole point of a reservation is that
            /// its id already exists and cannot be handed to anyone else.
            reserved: bool = false,
        };

        /// A slot promised before the thing that will fill it exists.
        ///
        /// Taken as a parameter by the calls whose success cannot be undone,
        /// so that beginning something this half cannot name back is not an
        /// order anyone has to remember avoiding -- it is an order that
        /// cannot be written. A forged one is refused: `fill` and `release`
        /// check that the slot is still reserved at this exact generation,
        /// and nothing but `reserve` produces that pairing.
        pub const Reservation = struct {
            id: Id,
        };

        allocator: std.mem.Allocator,
        /// Held across every operation below, because this half answers
        /// requests on several threads: a pool thread, a thread of its own
        /// per blocking method, and the thread that drains events. Two of
        /// those scanning for a free slot at once would hand one slot to
        /// both callers -- the stale-id confusion the generation exists to
        /// prevent, arriving by another door.
        ///
        /// Every critical section here is a scan of the slots and a few
        /// field writes. None of them calls out, waits, or allocates, so the
        /// lock is never held across anything that could block. That is the
        /// property which makes locking the whole table, rather than asking
        /// every caller to do it, safe to do.
        mutex: std.Io.Mutex = .init,
        /// Stored rather than taken per call: `Io.Mutex` needs one to park a
        /// contended waiter, and a table whose callers each passed their own
        /// would have no single answer to "which Io is this".
        io: std.Io,
        slots: []Slot,
        live: usize = 0,

        pub fn init(
            io: std.Io,
            allocator: std.mem.Allocator,
            slot_count: usize,
        ) std.mem.Allocator.Error!Self {
            std.debug.assert(slot_count > 0);
            const slots = try allocator.alloc(Slot, slot_count);
            @memset(slots, .{});
            return .{ .allocator = allocator, .io = io, .slots = slots };
        }

        /// The table's own lock, for the caller that has to decide something
        /// about a value and act on the decision before another resolve of
        /// the same id can begin.
        ///
        /// Everything else locks internally. This exists because "nothing
        /// names this any more" stops being true the moment the lock is
        /// dropped: a release that read zero and then took the entry under a
        /// second lock would be racing whatever resolved it in between. Pair
        /// it with the `Locked` operations and nothing else.
        pub fn lock(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
        }

        pub fn unlock(self: *Self) void {
            self.mutex.unlock(self.io);
        }

        /// Releases the table itself. Every handle must already be taken: a
        /// table that dropped live objects would leak them silently, so the
        /// caller is required to have drained it.
        ///
        /// Takes no lock, and could not usefully: it frees the memory the
        /// lock lives in. A table torn down while another thread is still
        /// inside it is a composition error no lock here can answer.
        pub fn deinit(self: *Self) void {
            std.debug.assert(self.live == 0);
            self.allocator.free(self.slots);
            self.* = undefined;
        }

        /// For a value that already exists, from a call that could be undone
        /// if naming it failed. A value from a call that could not be undone
        /// goes through `reserve` first.
        pub fn insert(self: *Self, value: *T) InsertError!Id {
            self.lock();
            defer self.unlock();
            const index = try self.freeSlot();
            const slot = &self.slots[index];
            slot.generation += 1;
            slot.value = value;
            self.live += 1;
            return .{ .slot = @intCast(index + 1), .generation = slot.generation };
        }

        /// Promises a slot before the thing that will fill it exists.
        ///
        /// The id is final from here: the generation has already moved, so
        /// what fills the slot gets the name the caller was promised, and no
        /// other caller can be given it meanwhile.
        pub fn reserve(self: *Self) InsertError!Reservation {
            self.lock();
            defer self.unlock();
            const index = try self.freeSlot();
            const slot = &self.slots[index];
            slot.generation += 1;
            slot.reserved = true;
            self.live += 1;
            return .{ .id = .{ .slot = @intCast(index + 1), .generation = slot.generation } };
        }

        /// Puts the value in the slot it was promised. Refuses a reservation
        /// this table did not make, or one already filled or released.
        pub fn fill(self: *Self, reservation: Reservation, value: *T) ?Id {
            self.lock();
            defer self.unlock();
            const slot = self.reservedSlot(reservation) orelse return null;
            slot.reserved = false;
            slot.value = value;
            return reservation.id;
        }

        /// Gives the slot back because the thing that would have filled it
        /// does not exist after all. The generation moves again, so the
        /// promised id can never be filled later.
        pub fn releaseReservation(self: *Self, reservation: Reservation) bool {
            self.lock();
            defer self.unlock();
            const slot = self.reservedSlot(reservation) orelse return false;
            slot.reserved = false;
            if (slot.generation != std.math.maxInt(u32)) slot.generation += 1;
            self.live -= 1;
            return true;
        }

        /// Whether this promise is still outstanding: made by this table, at
        /// this generation, and neither filled nor given back. The table is
        /// asked rather than a flag kept beside it, so there is one answer.
        pub fn stillReserved(self: *Self, reservation: Reservation) bool {
            self.lock();
            defer self.unlock();
            return self.reservedSlot(reservation) != null;
        }

        fn reservedSlot(self: *Self, reservation: Reservation) ?*Slot {
            const index = self.indexOf(reservation.id) orelse return null;
            const slot = &self.slots[index];
            if (!slot.reserved) return null;
            return slot;
        }

        fn freeSlot(self: *Self) InsertError!usize {
            for (self.slots, 0..) |*slot, index| {
                if (slot.value != null or slot.reserved) continue;
                if (slot.generation == std.math.maxInt(u32)) return error.GenerationExhausted;
                return index;
            }
            return error.HandleCapacity;
        }

        /// The object, or `null` for an id this table never issued, already
        /// took back, or issued for an earlier occupant of the slot.
        pub fn resolve(self: *Self, id: Id) ?*T {
            self.lock();
            defer self.unlock();
            return self.resolveLocked(id);
        }

        /// `resolve` for a caller already holding the lock.
        pub fn resolveLocked(self: *const Self, id: Id) ?*T {
            const slot = self.slotOf(id) orelse return null;
            return slot.value;
        }

        /// Hands the object back and retires the id. A second take of the same
        /// id returns `null` rather than the object twice, so a duplicate
        /// release from the caller cannot become a double free here.
        pub fn take(self: *Self, id: Id) ?*T {
            self.lock();
            defer self.unlock();
            return self.takeLocked(id);
        }

        /// `take` for a caller already holding the lock.
        pub fn takeLocked(self: *Self, id: Id) ?*T {
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

        pub fn liveCount(self: *Self) usize {
            self.lock();
            defer self.unlock();
            return self.live;
        }

        /// Takes no lock: the slot count is decided at `init` and never
        /// moves, so there is nothing here another thread could change.
        pub fn capacity(self: *const Self) usize {
            return self.slots.len;
        }

        /// Every live object, for the closure that has to release what the
        /// other half can no longer ask about.
        pub fn drain(self: *Self, output: []*T) []*T {
            self.lock();
            defer self.unlock();
            var count: usize = 0;
            for (self.slots) |*slot| {
                // A reservation nobody filled has no object to hand back, and
                // leaving it would keep the slot live for a caller that can
                // no longer fill it -- including past `deinit`, which asserts
                // the table is empty.
                if (slot.reserved) {
                    slot.reserved = false;
                    if (slot.generation != std.math.maxInt(u32)) slot.generation += 1;
                    self.live -= 1;
                    continue;
                }
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
    var table = try Table(Thing).init(testing.io, testing.allocator, 4);
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
    var table = try Table(Thing).init(testing.io, testing.allocator, 1);
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
    var table = try Table(Thing).init(testing.io, testing.allocator, 2);
    defer table.deinit();
    const id = try table.insert(&thing);
    try testing.expectEqual(&thing, table.take(id).?);
    try testing.expect(table.take(id) == null);
    try testing.expectEqual(@as(usize, 0), table.liveCount());
}

test "the bound is a typed failure, not a growth" {
    var things: [3]Thing = .{ .{ .tag = 0 }, .{ .tag = 1 }, .{ .tag = 2 } };
    var table = try Table(Thing).init(testing.io, testing.allocator, 2);
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
    var table = try Table(Thing).init(testing.io, testing.allocator, 4);
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

test "a reserved slot is promised to one caller and to nobody else" {
    var first: Thing = .{ .tag = 1 };
    var second: Thing = .{ .tag = 2 };
    var table = try Table(Thing).init(testing.io, testing.allocator, 1);
    defer table.deinit();

    const promised = try table.reserve();
    try testing.expect(promised.id.valid());
    // The one slot is taken even though nothing fills it yet, which is the
    // point: capacity was spent before the irreversible call, not after.
    try testing.expectEqual(@as(usize, 1), table.liveCount());
    try testing.expectError(error.HandleCapacity, table.insert(&first));
    try testing.expectError(error.HandleCapacity, table.reserve());
    // And it resolves to nothing until it is filled.
    try testing.expect(table.resolve(promised.id) == null);

    const id = table.fill(promised, &second).?;
    try testing.expectEqual(promised.id.bits(), id.bits());
    try testing.expectEqual(@as(u32, 2), table.resolve(id).?.tag);
    _ = table.take(id);
}

test "a reservation given back can never be filled later" {
    var thing: Thing = .{ .tag = 7 };
    var table = try Table(Thing).init(testing.io, testing.allocator, 1);
    defer table.deinit();

    const promised = try table.reserve();
    try testing.expect(table.releaseReservation(promised));
    try testing.expectEqual(@as(usize, 0), table.liveCount());

    // The generation moved, so the promised name is dead even though its slot
    // is free again -- the same reason a retired id never answers.
    try testing.expect(table.fill(promised, &thing) == null);
    try testing.expect(!table.releaseReservation(promised));

    // The slot itself is reusable, under a new name.
    const reused = try table.insert(&thing);
    try testing.expect(reused.bits() != promised.id.bits());
    _ = table.take(reused);
}

test "a forged reservation is refused, because only reserve makes a live one" {
    var thing: Thing = .{ .tag = 3 };
    var table = try Table(Thing).init(testing.io, testing.allocator, 2);
    defer table.deinit();

    // Shaped like a reservation and never made by this table.
    try testing.expect(table.fill(.{ .id = .{ .slot = 1, .generation = 1 } }, &thing) == null);
    try testing.expect(table.fill(.{ .id = .none }, &thing) == null);
    try testing.expect(!table.releaseReservation(.{ .id = .{ .slot = 2, .generation = 9 } }));

    // A filled slot is no longer a reservation either, so a second fill of
    // the same promise cannot overwrite what is there.
    const promised = try table.reserve();
    _ = table.fill(promised, &thing).?;
    var other: Thing = .{ .tag = 4 };
    try testing.expect(table.fill(promised, &other) == null);
    try testing.expectEqual(@as(u32, 3), table.resolve(promised.id).?.tag);
    _ = table.take(promised.id);
}

/// One thread's share of a table every thread is in at once.
///
/// Holds at most one handle at a time, so a table with a slot per thread
/// always has a free one and a refusal means the table's own count drifted.
const Hammer = struct {
    table: *Table(Thing),
    rounds: usize,
    mine: Thing,
    /// Ids this thread was issued, in order, for the uniqueness check the
    /// whole run is judged on.
    issued: []Id,
    /// An answer that belonged to another thread, or a promise this table
    /// would not honour. Either one is the table handing one slot out twice.
    wrong: usize = 0,
    refused: usize = 0,

    fn run(self: *Hammer) void {
        var round: usize = 0;
        while (round < self.rounds) : (round += 1) {
            const reservation = self.table.reserve() catch {
                self.refused += 1;
                self.issued[round] = .none;
                continue;
            };
            const id = self.table.fill(reservation, &self.mine) orelse {
                self.wrong += 1;
                self.issued[round] = .none;
                continue;
            };
            self.issued[round] = id;
            // The object an id names must be the object this thread put
            // there. Anything else is another thread's, reached through a
            // name this one was promised.
            if (self.table.resolve(id) != &self.mine) self.wrong += 1;
            if (self.table.take(id) != &self.mine) self.wrong += 1;
        }
    }
};

fn lessThanId(_: void, left: Id, right: Id) bool {
    return left.bits() < right.bits();
}

test "threads sharing one table are never handed one slot twice" {
    // This half answers requests on a pool thread, on a thread of its own per
    // blocking method, and on the thread that drains events, so every
    // operation above can be running on several at once. What a lost scan
    // produces is two ids naming one slot -- and then this half resolves one
    // caller's id to another caller's object, which is exactly the confusion
    // the generation exists to make impossible, arriving by another door.
    //
    // Few slots and many threads on purpose. The window a missing lock opens
    // is a handful of instructions wide, and the way to land in it is to have
    // every thread scanning the same small array at the same moment rather
    // than to sleep inside one of them. One slot per thread, so a refusal is
    // never legitimate: each thread holds at most one handle at a time.
    const thread_count = 8;
    const rounds = 4000;

    var table = try Table(Thing).init(testing.io, testing.allocator, thread_count);
    defer table.deinit();

    const issued = try testing.allocator.alloc(Id, thread_count * rounds);
    defer testing.allocator.free(issued);

    var hammers: [thread_count]Hammer = undefined;
    for (&hammers, 0..) |*hammer, index| {
        hammer.* = .{
            .table = &table,
            .rounds = rounds,
            .mine = .{ .tag = @intCast(index) },
            .issued = issued[index * rounds ..][0..rounds],
        };
    }

    var threads: [thread_count]std.Thread = undefined;
    for (&threads, &hammers) |*thread, *hammer| {
        thread.* = try std.Thread.spawn(.{}, Hammer.run, .{hammer});
    }
    for (&threads) |thread| thread.join();

    for (&hammers) |*hammer| {
        try testing.expectEqual(@as(usize, 0), hammer.wrong);
        try testing.expectEqual(@as(usize, 0), hammer.refused);
    }

    // No id was issued twice, across every thread and every round. A table
    // that let two scans pick one slot steps that slot's generation once for
    // both, so the duplicate shows up here even when both callers happened to
    // read their own object back.
    std.mem.sort(Id, issued, {}, lessThanId);
    for (issued[1..], issued[0 .. issued.len - 1]) |current, previous| {
        try testing.expect(current.bits() != previous.bits());
    }

    // And the table's own count came back. A non-atomic increment and
    // decrement under this much contention does not.
    try testing.expectEqual(@as(usize, 0), table.liveCount());
}

test "closure clears a reservation nobody filled" {
    var thing: Thing = .{ .tag = 5 };
    var table = try Table(Thing).init(testing.io, testing.allocator, 2);
    defer table.deinit();

    const filled = try table.insert(&thing);
    _ = try table.reserve();
    try testing.expectEqual(@as(usize, 2), table.liveCount());

    var storage: [2]*Thing = undefined;
    const drained = table.drain(&storage);
    // One object came back; the reservation had none to give, and is gone
    // rather than left holding a slot for a caller that cannot fill it.
    try testing.expectEqual(@as(usize, 1), drained.len);
    try testing.expectEqual(@as(usize, 0), table.liveCount());
    try testing.expect(table.resolve(filled) == null);
}
