//! How the caller's half names a handle the execution half holds.
//!
//! The execution half keeps the object and sends an id. The caller has to
//! hand Product back something of the port's own type, and Product only ever
//! passes it along -- `handles.zig` asserts the opaque handle types declare
//! nothing, so nothing is ever called on them over here.
//!
//! The obvious shortcut is to put the id in the pointer: `@ptrFromInt` on the
//! way out, `@intFromPtr` on the way back, no allocation. It is rejected, and
//! the reason is that it inverts every check this change is built on. A small
//! integer in a pointer is a *non-null* pointer to an address like 0x2a, so
//! `orelse` passes, a non-null assertion passes, a debugger and a sanitizer
//! both read it as a real address, and a dereference is silent undefined
//! behaviour. An invalid value that looks exactly like a valid one, measured
//! by the checks the surrounding code relies on, is the failure this work
//! exists to remove -- the same reason a zero handle id is invalid by
//! construction, an id carries a generation, and a frame's marker is a word
//! rather than a bool.
//!
//! So there are two representations, and which one a type gets is derived
//! from the type rather than listed:
//!
//! - A port value carries its own `context`, and on this side that context is
//!   *our* object. The id rides there, the pointer stays a real pointer to a
//!   real thing, and the contract does not change.
//! - A bare pointer to an opaque type has nowhere to put an id, because the
//!   pointer *is* the value. It gets a real pointer to a slot we own that
//!   holds the id.
//!
//! The derivation is closed both ways by `comptime` below: every type the
//! wire carries as an id gets exactly one representation, a type that is not
//! carried as an id gets none, and a handle type nobody classified fails the
//! build naming itself. Two hand-kept lists would let the next handle type
//! land between them, and landing between them does not fail.

const std = @import("std");
const contract = @import("agent_contract");
const handle_table = @import("handle_table.zig");
const method = @import("method.zig");
const wire_types = @import("wire_types.zig");

const port = contract.port;
const surface = contract.surface;

pub const Representation = enum {
    /// The id rides in the port value's own context, which is this side's.
    in_context,
    /// The id lives in a slot of ours, named by a real pointer to it.
    boxed,
};

/// Which representation a type gets, read off the type and nothing else.
///
/// Deliberately does not ask whether the wire carries this type as a handle:
/// `Wire` refuses types that have no wire form at all, and asking it here
/// would make the classifier fail on types it is not being asked about. Which
/// types it is asked about is the closure's business, below.
pub fn representationOf(comptime T: type) ?Representation {
    // Strip the pointer and the optional: naming a handle by pointer or by
    // maybe-pointer is the same question about the same thing.
    const target = switch (@typeInfo(T)) {
        .optional => |info| switch (@typeInfo(info.child)) {
            .pointer => |inner| inner.child,
            else => info.child,
        },
        .pointer => |info| info.child,
        else => T,
    };
    return switch (@typeInfo(target)) {
        // A port value, which carries its own context -- and on this side
        // that context is our object, so the id rides there.
        .@"struct" => if (carriesContext(target)) .in_context else null,
        // Nowhere to put an id: the pointer is the value.
        .@"opaque" => .boxed,
        else => null,
    };
}

/// Whether a struct has a context of its own to carry an id in, directly or
/// through a port value it holds.
///
/// Transitive because `port.SessionRestoreInputs` is one: it is a struct with
/// no context field of its own, but it holds a `RuntimePort`, whose context is
/// this side's object. The closure below found that -- it is a third shape
/// neither of the first two rules covered, and a hand-kept list would have
/// let it through as "not a handle".
fn carriesContext(comptime T: type) bool {
    if (@hasField(T, "context")) return true;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (@typeInfo(field.type) == .@"struct" and carriesContext(field.type)) return true;
    }
    return false;
}

comptime {
    @setEvalBranchQuota(1_000_000);
    // Every handle the method surface names, parameters and returns alike,
    // and one level into the mirrors -- which is where a handle inside an
    // options struct lives.
    for (method.entries) |entry| {
        // Streams are skipped for the reason `wire_types` skips them: they
        // are not calls, so they have no wire form to ask about. `take_event`
        // hands back an event that owns its JSON through an allocator, which
        // never crossed in the first place.
        if (entry.transport == .stream) continue;
        switch (entry.owner) {
            inline else => |owner| {
                const Fn = @typeInfo(@FieldType(owner.VTable(), entry.name)).pointer.child;
                for (@typeInfo(Fn).@"fn".params, 0..) |param, position| {
                    if (position == 0) continue;
                    classify(param.type.?, entry.name);
                }
                classify(wire_types.Payload(@typeInfo(Fn).@"fn".return_type.?), entry.name);
            },
        }
    }
}

/// Asks the classifier about exactly the types the wire carries as a handle,
/// and about nothing else.
///
/// The second level matters: a handle inside an options struct is an `Id`
/// field on the *mirror*, so the mirror is what says a handle is there and
/// the original's field of the same name is what has to be classified.
/// Walking the original's fields instead would mean asking `Wire` about
/// fields that have no wire form, which is how the first version of this
/// failed.
fn classify(comptime T: type, comptime named: []const u8) void {
    comptime {
        const Wired = wire_types.Wire(T);
        if (Wired == handle_table.Id) {
            if (representationOf(T) == null) @compileError(
                "the wire carries " ++ @typeName(T) ++ " as a handle id (it reaches " ++ named ++
                    ") and nothing says how the caller's half names it. It is neither a port " ++
                    "value with its own context nor a pointer to an opaque type, so see " ++
                    "src/agent/link/handle_repr.zig: a representation nobody chose is how a " ++
                    "handle ends up in a pointer-shaped integer",
            );
            return;
        }
        if (@typeInfo(Wired) != .@"struct") return;
        for (@typeInfo(Wired).@"struct".fields) |field| {
            if (field.type != handle_table.Id) continue;
            const Origin = @FieldType(T, field.name);
            if (representationOf(Origin) == null) @compileError(
                "the wire carries " ++ @typeName(T) ++ "." ++ field.name ++ " as a handle id " ++
                    "and nothing says how the caller's half names " ++ @typeName(Origin) ++
                    "; see src/agent/link/handle_repr.zig",
            );
        }
    }
}

/// The slots the caller's half names its boxed handles by.
///
/// One bounded allocation rather than one per handle: the pointer handed out
/// is the address of a slot, so it is a real pointer into live memory and a
/// read of it reads what was written. A pointer this table did not issue
/// fails the arithmetic -- out of range, or not on a slot boundary -- so a
/// wrong one is refused instead of being read as whatever lies there.
///
/// A slot keeps no generation of its own. The id it holds has one, so a stale
/// box holds a stale id and the execution half's own table refuses it: the
/// refusal belongs where the object lives. What has to be prevented here is
/// only a freed slot coming back under a different handle, and `releaseThrough`
/// is what prevents that.
pub const Boxes = struct {
    pub const Slot = struct {
        id: handle_table.Id = .none,
        live: bool = false,
    };

    allocator: std.mem.Allocator,
    slots: []Slot,

    pub const Error = error{
        /// Every slot is in use. A bound, not a growth, for the same reason
        /// the execution half's table has one.
        BoxCapacity,
        /// A pointer this table did not issue, or one whose slot is free.
        UnknownBox,
    };

    pub fn init(allocator: std.mem.Allocator, count: usize) std.mem.Allocator.Error!Boxes {
        std.debug.assert(count > 0);
        const slots = try allocator.alloc(Slot, count);
        @memset(slots, .{});
        return .{ .allocator = allocator, .slots = slots };
    }

    pub fn deinit(self: *Boxes) void {
        self.allocator.free(self.slots);
        self.* = undefined;
    }

    /// Names an id, returning the slot the caller will carry as the handle.
    pub fn open(self: *Boxes, id: handle_table.Id) Error!*Slot {
        std.debug.assert(id.valid());
        for (self.slots) |*slot| {
            if (slot.live) continue;
            slot.* = .{ .id = id, .live = true };
            return slot;
        }
        return error.BoxCapacity;
    }

    /// The id a handle names, without giving up the handle.
    pub fn borrow(self: *Boxes, handle: *const anyopaque) Error!handle_table.Id {
        const slot = try self.slotOf(handle);
        return slot.id;
    }

    pub fn liveCount(self: *const Boxes) usize {
        var count: usize = 0;
        for (self.slots) |slot| {
            if (slot.live) count += 1;
        }
        return count;
    }

    pub fn capacity(self: *const Boxes) usize {
        return self.slots.len;
    }

    fn slotOf(self: *Boxes, handle: *const anyopaque) Error!*Slot {
        const base = @intFromPtr(self.slots.ptr);
        const address = @intFromPtr(handle);
        if (address < base) return error.UnknownBox;
        const offset = address - base;
        if (offset % @sizeOf(Slot) != 0) return error.UnknownBox;
        const index = offset / @sizeOf(Slot);
        if (index >= self.slots.len) return error.UnknownBox;
        const slot = &self.slots[index];
        if (!slot.live) return error.UnknownBox;
        return slot;
    }
};

/// Releases a handle through the call that releases it.
///
/// Both bad states are out of reach by position: the slot is cleared after
/// the call returns without error, so "released but the box is still there"
/// cannot happen (the clear follows the success) and "the box is gone but
/// nothing was released" cannot either (an early return never reaches the
/// clear). A failed release leaves the name working, which it must -- the
/// object is still over there and the caller may ask again.
///
/// Deliberately not "give the slot up first and put it back on failure".
/// That was the first version, and it opens a window: while the call is in
/// flight the slot is free, so another thread's `open` can take it, and the
/// restore would then write this handle's id over that one -- two handles
/// naming one slot. Clearing after success has no window at all.
pub fn releaseThrough(
    boxes: *Boxes,
    handle: *const anyopaque,
    comptime Result: type,
    context: anytype,
    comptime body: fn (@TypeOf(context), handle_table.Id) Result,
) (Boxes.Error || @typeInfo(Result).error_union.error_set)!void {
    const slot = try boxes.slotOf(handle);
    const id = slot.id;
    _ = try body(context, id);
    slot.* = .{};
}

const testing = std.testing;

test "which representation a type gets is read off the type" {
    // A port value carries its own context, so the id rides there.
    try testing.expectEqual(Representation.in_context, representationOf(port.SessionPort).?);

    // A bare pointer to an opaque type has nowhere to put one.
    try testing.expectEqual(
        Representation.boxed,
        representationOf(*@import("agent_catalog").Lease).?,
    );
    try testing.expectEqual(
        Representation.boxed,
        representationOf(?*@import("agent_catalog").Lease).?,
    );
    try testing.expectEqual(
        Representation.boxed,
        representationOf(*port.SkillRestoreInputs).?,
    );

    // The third shape, which the closure found: a struct with no context of
    // its own that holds a port value whose context is ours.
    try testing.expect(!@hasField(port.SessionRestoreInputs, "context"));
    try testing.expectEqual(
        Representation.in_context,
        representationOf(*port.SessionRestoreInputs).?,
    );

    // A plain value gets neither, so a type that reaches the closure without
    // being a handle cannot be mistaken for one that nobody classified.
    try testing.expect(representationOf(u64) == null);
    try testing.expect(representationOf([]const u8) == null);
    try testing.expect(representationOf(surface.SessionOpenOptions) == null);

    // The classifier answers for shapes the wire does not carry as handles
    // too -- `RunPort` has a context and is not sent at all. That is not a
    // gap: which types are asked about is the closure's business, and asking
    // the classifier about the rest is how it stays independent of `Wire`.
    try testing.expectEqual(Representation.in_context, representationOf(port.RunPort).?);
}

test "a box is a real pointer into live memory, and a forged one is refused" {
    var boxes = try Boxes.init(testing.allocator, 2);
    defer boxes.deinit();

    const first = try boxes.open(.{ .slot = 3, .generation = 1 });
    const second = try boxes.open(.{ .slot = 9, .generation = 4 });
    try testing.expectEqual(@as(usize, 2), boxes.liveCount());

    // The pointer reads back what was written, because it points at a slot.
    try testing.expectEqual(@as(u32, 3), (try boxes.borrow(first)).slot);
    try testing.expectEqual(@as(u32, 9), (try boxes.borrow(second)).slot);

    // The bound is a typed refusal.
    try testing.expectError(error.BoxCapacity, boxes.open(.{ .slot = 1, .generation = 1 }));

    // A pointer this table never issued fails the arithmetic rather than
    // being read as whatever lies at that address.
    var elsewhere: Boxes.Slot = .{ .id = .{ .slot = 7, .generation = 7 }, .live = true };
    try testing.expectError(error.UnknownBox, boxes.borrow(&elsewhere));
    const misaligned: *const anyopaque = @ptrFromInt(@intFromPtr(first) + 1);
    try testing.expectError(error.UnknownBox, boxes.borrow(misaligned));
}

test "a release clears the box only after it succeeded, with no window" {
    var boxes = try Boxes.init(testing.allocator, 1);
    defer boxes.deinit();
    const handle = try boxes.open(.{ .slot = 5, .generation = 2 });

    const Watcher = struct {
        boxes: *Boxes,
        seen: ?handle_table.Id = null,
        live_during_call: usize = 0,

        fn refuses(self: *@This(), id: handle_table.Id) anyerror!void {
            self.seen = id;
            self.live_during_call = self.boxes.liveCount();
            return error.Unexpected;
        }
        fn accepts(self: *@This(), id: handle_table.Id) anyerror!void {
            self.seen = id;
            self.live_during_call = self.boxes.liveCount();
        }
    };
    const Work = Watcher;

    var watcher: Watcher = .{ .boxes = &boxes };
    try testing.expectError(
        error.Unexpected,
        releaseThrough(&boxes, handle, anyerror!void, &watcher, Work.refuses),
    );
    // The call saw the id, and the object is still over there, so the name
    // has to keep working.
    try testing.expectEqual(@as(u32, 5), watcher.seen.?.slot);
    try testing.expectEqual(@as(usize, 1), boxes.liveCount());
    try testing.expectEqual(@as(u32, 5), (try boxes.borrow(handle)).slot);

    // And the slot was never free while the call was in flight. Giving it up
    // first would read zero here, and would let another thread's `open` take
    // the slot this handle still names.
    try testing.expectEqual(@as(usize, 1), watcher.live_during_call);

    watcher.seen = null;
    try releaseThrough(&boxes, handle, anyerror!void, &watcher, Work.accepts);
    // Released, so the box is gone: there is no state where one happened
    // without the other.
    try testing.expectEqual(@as(u32, 5), watcher.seen.?.slot);
    try testing.expectEqual(@as(usize, 0), boxes.liveCount());
    try testing.expectError(error.UnknownBox, boxes.borrow(handle));

    // And the slot is reusable, under whatever id comes next.
    const reused = try boxes.open(.{ .slot = 8, .generation = 1 });
    try testing.expectEqual(@as(u32, 8), (try boxes.borrow(reused)).slot);
}

test "a box keeps no generation, because the id it holds has one" {
    // The stale-handle refusal belongs where the object lives: a box holding
    // a retired id resolves to nothing in the execution half's own table, and
    // duplicating the check here would be a second place for it to drift.
    try testing.expectEqual(@as(usize, @sizeOf(handle_table.Id) + 1), blk: {
        break :blk @sizeOf(Boxes.Slot) - (@sizeOf(Boxes.Slot) - @sizeOf(handle_table.Id) - 1);
    });
    try testing.expect(!@hasField(Boxes.Slot, "generation"));
    const id: handle_table.Id = .{ .slot = 2, .generation = 11 };
    var boxes = try Boxes.init(testing.allocator, 1);
    defer boxes.deinit();
    const handle = try boxes.open(id);
    try testing.expectEqual(id.bits(), (try boxes.borrow(handle)).bits());
}
