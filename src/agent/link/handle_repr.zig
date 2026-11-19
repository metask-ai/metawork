//! How the caller's half names a handle the execution half holds.
//!
//! The execution half keeps the object and sends an id. The caller has to
//! hand Product back something of the port's own type.
//!
//! An earlier version of this comment said that `handles.zig` asserts the
//! opaque handle types declare nothing, so nothing is ever called on them
//! over here. That is wrong, and it was the premise under "a box is enough":
//! `handles.zig` exists *because* an opaque type can carry methods, and it
//! classifies eleven of them on `mcp_catalog.Activation` alone. What it
//! actually says is narrower, and it says it in as many words -- `catalog.Lease`
//! and `port.SkillRestoreInputs` carry no methods at all, which is why they
//! need nothing there beyond an assertion.
//!
//! Those two are also the only `boxed` handles outside MCP, so the box is
//! sufficient for exactly the types it is used for, and `boxed_carry_nothing`
//! below is the check rather than the claim. A handle that *does* carry
//! methods needs a third representation -- an object on this side that
//! answers the `projected` reads from what rode across and forwards the
//! `call` and `release` ones -- and all four such types are MCP's, which is
//! why `activate_mcp` is the one result the inbound chain still owes.
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
const handles = @import("handles.zig");
const method = @import("method.zig");
const wire_types = @import("wire_types.zig");

const mcp_catalog = @import("agent_mcp_catalog");
const port = contract.port;
const surface = contract.surface;

pub const Representation = enum {
    /// The id rides in the port value's own context, which is this side's.
    in_context,
    /// The id lives in a slot of ours, named by a real pointer to it.
    boxed,
};

/// A handle whose type carries methods, which a box cannot serve.
///
/// A box names the far object and nothing more. Product calling
/// `activation.state()` on a box does not reach the far side at all -- it
/// reads a slot as if it were an `ActivationStorage`, which is the silent
/// wrong answer this file exists to refuse, arrived at from the other
/// direction. What such a handle needs is an object of ours that answers the
/// `projected` reads from the facts that rode across and forwards the rest,
/// and building one means the module that owns the opaque type has to be able
/// to make one -- the same gap `catalog.Projection.own` closed for the skill
/// catalog.
///
/// All four are MCP's, so this whole shape belongs to the MCP step.
pub const needs_stand_in = [_][]const u8{
    @typeName(mcp_catalog.Activation),
    @typeName(mcp_catalog.Selection),
    @typeName(mcp_catalog.RestoreSelection),
    @typeName(mcp_catalog.Projection),
};

/// Whether `handles.zig` records this type as carrying methods.
fn carriesMethods(comptime T: type) bool {
    inline for (handles.handles) |handle| {
        if (comptime std.mem.eql(u8, handle.name, @typeName(T))) return handle.methods.len > 0;
    }
    return false;
}

fn listedNeedsStandIn(comptime T: type) bool {
    inline for (needs_stand_in) |name| {
        if (comptime std.mem.eql(u8, name, @typeName(T))) return true;
    }
    return false;
}

/// A `boxed` handle must carry no methods, or be one of the four already
/// recorded as needing more than a box.
///
/// This is the check that replaces the claim the header used to make. Closed
/// both ways: a type that gains a method and is not recorded fails the build
/// rather than getting a box that answers its reads out of a slot, and a type
/// recorded here that no longer carries methods is named so the entry goes.
fn boxedCarriesNothing(comptime T: type, comptime named: []const u8) void {
    comptime {
        if (representationOf(T) != .boxed) return;
        const Target = switch (@typeInfo(T)) {
            .optional => |info| switch (@typeInfo(info.child)) {
                .pointer => |inner| inner.child,
                else => info.child,
            },
            .pointer => |info| info.child,
            else => T,
        };
        if (carriesMethods(Target) and !listedNeedsStandIn(Target)) @compileError(
            @typeName(Target) ++ " is named by " ++ named ++ ", crosses as a boxed handle, " ++
                "and carries methods that src/agent/link/handles.zig classifies. A box " ++
                "cannot answer them: Product would read a slot of ours as if it were that " ++
                "type's own storage. Give it the stand-in representation, or record it in " ++
                "`needs_stand_in` with the step that will",
        );
        if (!carriesMethods(Target) and listedNeedsStandIn(Target)) @compileError(
            @typeName(Target) ++ " is in `needs_stand_in` but carries no methods any more; " ++
                "a box is enough for it, so remove the entry",
        );
    }
}

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
            boxedCarriesNothing(T, named);
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
            boxedCarriesNothing(Origin, named);
            if (representationOf(Origin) == null) @compileError(
                "the wire carries " ++ @typeName(T) ++ "." ++ field.name ++ " as a handle id " ++
                    "and nothing says how the caller's half names " ++ @typeName(Origin) ++
                    "; see src/agent/link/handle_repr.zig",
            );
        }
    }
}

/// The boxes the caller's half names far objects by.
///
/// Both representations end up here, and after building the inbound chain
/// that is the honest shape: each one needs *a real pointer to a record of
/// ours that names the far object*, and they differ only in who carries that
/// pointer. A `boxed` handle's pointer **is** the box, because the pointer is
/// the whole value. An `in_context` handle's port value **holds** the box in
/// its own `context`, because it has somewhere to put it. One record, one
/// validity check, one release path; the distinction `Representation` draws
/// is about carriage, not about two kinds of storage.
///
/// One bounded allocation rather than one per handle: the pointer handed out
/// is the address of a slot, so it is a real pointer into live memory and a
/// read of it reads what was written. A pointer this table did not issue
/// fails the arithmetic -- out of range, or not on a slot boundary -- so a
/// wrong one is refused instead of being read as whatever lies there. That is
/// also why a released handle used again is a refusal rather than a
/// use-after-free, which one allocation per handle could not give.
///
/// A slot keeps no generation of its own. The id it holds has one, so a stale
/// box holds a stale id and the execution half's own table refuses it: the
/// refusal belongs where the object lives. What has to be prevented here is
/// only a freed slot coming back under a different handle, and `releaseThrough`
/// is what prevents that.
/// Generic in the link type, so the box's way back cannot hold anything else.
/// `?*anyopaque` would do the same job and would be the shape this file exists
/// to argue against: a pointer whose type nobody checks, cast back on trust.
/// One type parameter buys the check instead.
pub fn Boxes(comptime Link: type) type {
    return struct {
        const Self = @This();

        pub const Slot = struct {
            /// The link this box names something on. A stub reached through
            /// an `in_context` port value has only the context pointer to
            /// start from, so the way back to its own half is in the box.
            ///
            /// Every slot in one table carries the same link, so this is set
            /// once at `init` rather than per `open`: a free slot with a
            /// valid link is a slot whose only unanswered question is what it
            /// names, which is the question `live` answers.
            link: *Link,
            id: handle_table.Id = .none,
            live: bool = false,
        };

        allocator: std.mem.Allocator,
        slots: []Slot,

        pub const Error = error{
            /// Every slot is in use. A bound, not a growth, for the same
            /// reason the execution half's table has one.
            BoxCapacity,
            /// A pointer this table did not issue, or one whose slot is free.
            UnknownBox,
        };

        pub fn init(
            allocator: std.mem.Allocator,
            count: usize,
            link: *Link,
        ) std.mem.Allocator.Error!Self {
            std.debug.assert(count > 0);
            const slots = try allocator.alloc(Slot, count);
            @memset(slots, .{ .link = link });
            return .{ .allocator = allocator, .slots = slots };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.slots);
            self.* = undefined;
        }

        /// Names an id, returning the box the caller will carry.
        pub fn open(self: *Self, id: handle_table.Id) Error!*Slot {
            std.debug.assert(id.valid());
            const slot = try self.freeSlot();
            slot.id = id;
            return slot;
        }

        /// Takes a box before the call that will name it.
        ///
        /// The mirror of `handle_table.reserve`, for the same reason and in
        /// the other direction. A method whose result names a handle has
        /// already done something irreversible on the far side by the time
        /// the answer arrives: if this half then had no box left, the object
        /// would be live over there with nothing here able to name or release
        /// it. Spending the capacity first turns that into a refusal before
        /// the call, which is a refusal that costs nothing.
        pub fn reserve(self: *Self) Error!*Slot {
            return self.freeSlot();
        }

        /// Names the id the answer brought, on a box already taken.
        pub fn fill(self: *Self, slot: *Slot, id: handle_table.Id) void {
            std.debug.assert(id.valid());
            std.debug.assert(slot.live and !slot.id.valid());
            std.debug.assert(self.holds(slot));
            slot.id = id;
        }

        /// Gives back a box whose call did not produce a handle.
        pub fn releaseReservation(self: *Self, slot: *Slot) void {
            std.debug.assert(slot.live and !slot.id.valid());
            std.debug.assert(self.holds(slot));
            slot.live = false;
        }

        /// The id a handle names, without giving up the handle.
        ///
        /// A box that is reserved but not yet filled names nothing, so it is
        /// refused rather than answered with `Id.none`: a zero id is invalid
        /// by construction and handing one out would push the refusal to
        /// whoever read it next.
        pub fn borrow(self: *Self, handle: *const anyopaque) Error!handle_table.Id {
            const slot = try self.slotOf(handle);
            if (!slot.id.valid()) return error.UnknownBox;
            return slot.id;
        }

        fn freeSlot(self: *Self) Error!*Slot {
            for (self.slots) |*slot| {
                if (slot.live) continue;
                slot.* = .{ .link = slot.link, .id = .none, .live = true };
                return slot;
            }
            return error.BoxCapacity;
        }

        fn holds(self: *const Self, slot: *const Slot) bool {
            const base = @intFromPtr(self.slots.ptr);
            const address = @intFromPtr(slot);
            return address >= base and
                (address - base) % @sizeOf(Slot) == 0 and
                (address - base) / @sizeOf(Slot) < self.slots.len;
        }

        /// The link a handle belongs to, which is how a stub entered through
        /// an `in_context` port value finds its own half.
        pub fn linkOf(self: *Self, handle: *const anyopaque) Error!*Link {
            const slot = try self.slotOf(handle);
            return slot.link;
        }

        pub fn liveCount(self: *const Self) usize {
            var count: usize = 0;
            for (self.slots) |slot| {
                if (slot.live) count += 1;
            }
            return count;
        }

        pub fn capacity(self: *const Self) usize {
            return self.slots.len;
        }

        fn slotOf(self: *Self, handle: *const anyopaque) Error!*Slot {
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

        /// Releases a handle through the call that releases it.
        ///
        /// Both bad states are out of reach by position: the slot is cleared
        /// after the call returns without error, so "released but the box is
        /// still there" cannot happen (the clear follows the success) and
        /// "the box is gone but nothing was released" cannot either (an early
        /// return never reaches the clear). A failed release leaves the name
        /// working, which it must -- the object is still over there and the
        /// caller may ask again.
        ///
        /// Deliberately not "give the slot up first and put it back on
        /// failure". That was the first version, and it opens a window: while
        /// the call is in flight the slot is free, so another thread's `open`
        /// can take it, and the restore would then write this handle's id
        /// over that one -- two handles naming one slot. Clearing after
        /// success has no window at all.
        pub fn releaseThrough(
            self: *Self,
            handle: *const anyopaque,
            comptime Result: type,
            context: anytype,
            comptime body: fn (@TypeOf(context), handle_table.Id) Result,
        ) (Error || @typeInfo(Result).error_union.error_set)!void {
            const slot = try self.slotOf(handle);
            // A reserved box names nothing yet, so there is nothing to
            // release through: `releaseReservation` is that case's own call.
            if (!slot.id.valid()) return error.UnknownBox;
            const id = slot.id;
            _ = try body(context, id);
            slot.id = .none;
            slot.live = false;
        }
    };
}

const testing = std.testing;

/// A stand-in for the caller's half. The table only ever carries the pointer
/// back out, so what it points at does not matter -- that it is typed does.
const TestLink = struct { tag: u32 = 0 };
const TestBoxes = Boxes(TestLink);

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
    var link: TestLink = .{ .tag = 9 };
    var boxes = try TestBoxes.init(testing.allocator, 2, &link);
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
    var elsewhere: TestBoxes.Slot = .{
        .link = &link,
        .id = .{ .slot = 7, .generation = 7 },
        .live = true,
    };
    try testing.expectError(error.UnknownBox, boxes.borrow(&elsewhere));
    const misaligned: *const anyopaque = @ptrFromInt(@intFromPtr(first) + 1);
    try testing.expectError(error.UnknownBox, boxes.borrow(misaligned));
}

test "a release clears the box only after it succeeded, with no window" {
    var link: TestLink = .{};
    var boxes = try TestBoxes.init(testing.allocator, 1, &link);
    defer boxes.deinit();
    const handle = try boxes.open(.{ .slot = 5, .generation = 2 });

    const Watcher = struct {
        boxes: *TestBoxes,
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
        boxes.releaseThrough(handle, anyerror!void, &watcher, Work.refuses),
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
    try boxes.releaseThrough(handle, anyerror!void, &watcher, Work.accepts);
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
    try testing.expect(!@hasField(TestBoxes.Slot, "generation"));

    var link: TestLink = .{ .tag = 4 };
    const id: handle_table.Id = .{ .slot = 2, .generation = 11 };
    var boxes = try TestBoxes.init(testing.allocator, 1, &link);
    defer boxes.deinit();
    const handle = try boxes.open(id);
    try testing.expectEqual(id.bits(), (try boxes.borrow(handle)).bits());

    // And the way back out is the link that was put in, as itself rather than
    // as a pointer something else could have written.
    try testing.expectEqual(&link, try boxes.linkOf(handle));
    try testing.expectEqual(@as(u32, 4), (try boxes.linkOf(handle)).tag);
}

test "both representations are carried by one box, differing only in who holds it" {
    // The point of unifying them: an `in_context` handle's port value holds
    // the box, a `boxed` handle's pointer is the box, and the record and its
    // validity check are the same one. So a stale port value is refused by
    // the same arithmetic that refuses a stale lease pointer, rather than
    // being a freed allocation nobody can check.
    var link: TestLink = .{};
    var boxes = try TestBoxes.init(testing.allocator, 2, &link);
    defer boxes.deinit();

    const boxed = try boxes.open(.{ .slot = 1, .generation = 1 });
    const in_context = try boxes.open(.{ .slot = 2, .generation = 1 });

    // Carried as the handle itself.
    const lease: *@import("agent_catalog").Lease = @ptrCast(boxed);
    try testing.expectEqual(@as(u32, 1), (try boxes.borrow(lease)).slot);

    // Carried in a port value's own context.
    const session: port.SessionPort = .{ .context = in_context, .vtable = undefined };
    try testing.expectEqual(@as(u32, 2), (try boxes.borrow(session.context.?)).slot);

    // One release path, so a released handle of either shape is a refusal.
    const Releasing = struct {
        fn ok(_: void, _: handle_table.Id) anyerror!void {}
    };
    try boxes.releaseThrough(lease, anyerror!void, {}, Releasing.ok);
    try testing.expectError(error.UnknownBox, boxes.borrow(lease));
    try testing.expectEqual(@as(u32, 2), (try boxes.borrow(session.context.?)).slot);
}

test "a box is taken before the call that names it, not after" {
    // The mirror of the reservation on the execution half. The failure this
    // removes: a method whose result names a handle succeeds over there, the
    // answer arrives, and this half has no box left -- so the object is live
    // with nothing here able to name or release it. Taking the box first
    // makes that a refusal before anything irreversible happened.
    var link: TestLink = .{};
    var boxes = try TestBoxes.init(testing.allocator, 1, &link);
    defer boxes.deinit();

    const reserved = try boxes.reserve();
    // Spent, so a second caller is refused now rather than after its call.
    try testing.expectError(error.BoxCapacity, boxes.reserve());
    try testing.expectError(error.BoxCapacity, boxes.open(.{ .slot = 1, .generation = 1 }));

    // It names nothing yet, and says so instead of answering with a zero id
    // that whoever read it would have to refuse.
    try testing.expectError(error.UnknownBox, boxes.borrow(reserved));
    const Releasing = struct {
        fn ok(_: void, _: handle_table.Id) anyerror!void {}
    };
    try testing.expectError(
        error.UnknownBox,
        boxes.releaseThrough(reserved, anyerror!void, {}, Releasing.ok),
    );

    boxes.fill(reserved, .{ .slot = 6, .generation = 2 });
    try testing.expectEqual(@as(u32, 6), (try boxes.borrow(reserved)).slot);

    // And a call that produced no handle gives the box back.
    try boxes.releaseThrough(reserved, anyerror!void, {}, Releasing.ok);
    const again = try boxes.reserve();
    boxes.releaseReservation(again);
    try testing.expectEqual(@as(usize, 0), boxes.liveCount());
}

test "a box is enough for a handle that carries no methods, and for no other" {
    // The header used to justify the box by saying nothing is ever called on
    // an opaque handle over here. `handles.zig` exists because that is not
    // true, so this is the shape of what is actually the case.

    // The two the box is used for carry nothing, which is what makes a slot
    // holding an id a complete answer for them.
    try testing.expect(!carriesMethods(@import("agent_catalog").Lease));
    try testing.expect(!carriesMethods(port.SkillRestoreInputs));
    try testing.expectEqual(
        Representation.boxed,
        representationOf(*@import("agent_catalog").Lease).?,
    );

    // The four that carry methods are all MCP's, and all recorded. A box
    // would let `activation.state()` read one of our slots as if it were
    // that type's own storage -- the same silent wrong answer as an id in a
    // pointer, reached from the other side.
    try testing.expectEqual(@as(usize, 4), needs_stand_in.len);
    var carrying: usize = 0;
    for (handles.handles) |handle| {
        if (handle.methods.len == 0) continue;
        carrying += 1;
        var listed = false;
        for (needs_stand_in) |name| {
            if (std.mem.eql(u8, name, handle.name)) listed = true;
        }
        try testing.expect(listed);
    }
    try testing.expectEqual(needs_stand_in.len, carrying);

    // And `boxedCarriesNothing` is what keeps that true: it runs over the
    // whole method surface in the closure above, so a non-MCP opaque handle
    // gaining a method fails the build rather than quietly getting a box.
    try testing.expect(carriesMethods(mcp_catalog.Activation));
    try testing.expect(listedNeedsStandIn(mcp_catalog.Activation));
}
