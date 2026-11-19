//! Turning the arguments a stub was called with into the ones that travel.
//!
//! The fifth direction, and the only one with a simplification rather than a
//! complication: every handle resolves the same way. The execution half needs
//! a case per table -- a Session in `sessions`, a lease in `leases`, a
//! captured capability in `skill_restore` -- because the object lives in one
//! of six places. This half has one place. A handle is a box, boxed or
//! in-context, so `Boxes.borrow` answers all of them and there is nothing per
//! type to keep in step.
//!
//! What this direction *cannot* do is compose a capability. A parameter that
//! is a function pointer into this process means nothing over there, and the
//! answer is never "send the pointer": either the far side builds its own
//! from what it already has -- `checkpoint.Sink` sends nothing at all, because
//! every fact a destination needs is on the Session the call was made on or in
//! the call's own limits -- or the call is a reverse call and the pointer
//! stays here. Both are decisions recorded
//! elsewhere -- `adapters.Disposition` on the execution side,
//! `reverse.zig` for the calls that come back -- so a parameter with neither
//! is owed, and `owedArguments` is the list.

const std = @import("std");
const contract = @import("agent_contract");
const adapters = @import("adapters.zig");
const client = @import("client.zig");
const handle_table = @import("handle_table.zig");
const method = @import("method.zig");
const shapes = @import("shapes.zig");
const wire_types = @import("wire_types.zig");

const port = contract.port;
const surface = contract.surface;
const control = contract.control;
const catalog = @import("agent_catalog");
const mcp_catalog = @import("agent_mcp_catalog");

pub const Error = error{
    /// A handle this half did not issue, or one already released. The caller
    /// asked a question about an object it no longer names.
    UnknownHandle,
} || client.Boxes.Error;

pub fn Adapter(comptime T: type) type {
    return struct {
        apply: *const fn (*client.Client, T) Error!wire_types.Wire(T),
    };
}

/// How one argument becomes its wire form, or `null` when nothing does it
/// yet.
pub fn adapter(comptime T: type) ?Adapter(T) {
    // Plain data is itself: `Wire(T) == T` is the statement that the value
    // crosses unchanged.
    if (wire_types.Wire(T) == T) return .{ .apply = struct {
        fn apply(_: *client.Client, value: T) Error!T {
            return value;
        }
    }.apply };

    // Values that do not travel at all. The allocator is the caller's and the
    // far side uses its own; the Runtime is the link, so naming it carries
    // nothing. Both map to `void`, which is the wire saying "no field here"
    // rather than a field holding nothing.
    if (wire_types.Wire(T) == void) return .{ .apply = struct {
        fn apply(_: *client.Client, _: T) Error!void {}
    }.apply };

    // Every handle, by the one rule. Which representation it has decided
    // where the box's address was carried, and `borrow` does not care: the
    // address is the address either way, and a box that is not this half's
    // or is no longer live fails the same arithmetic.
    if (wire_types.Wire(T) == handle_table.Id) return handleAdapter(T);

    // Mirrors with their own `from`, because what each does -- numbering an
    // error, naming a handle, dropping a capability -- is not a field copy.
    if (T == control.TerminalResult) return .{ .apply = struct {
        fn apply(_: *client.Client, value: T) Error!shapes.TerminalResult {
            return shapes.TerminalResult.from(&value);
        }
    }.apply };
    if (T == surface.CloseOutcome) return .{ .apply = struct {
        fn apply(_: *client.Client, value: T) Error!shapes.CloseOutcome {
            return shapes.CloseOutcome.from(value);
        }
    }.apply };
    if (T == catalog.Query) return mirrorFrom(T, shapes.CatalogQuery);
    // Handles inside, which the generic reader sends through this same chain
    // -- so an id in an options struct is resolved by the one rule above
    // rather than by a case written out here.
    if (T == surface.SessionOpenOptions) return mirrorFrom(T, shapes.SessionOpenOptions);

    // A capability whose whole wire form is the three fields the far side
    // needs to build its own. The credential and the two function pointers
    // do not cross, and `shapes.mirrors` is where that is recorded with its
    // reason -- the mirror being a strict subset is the decision, not an
    // omission this reader has to work around.
    //
    // The image input is one level deeper than the video one: it wraps the
    // binding beside a transport, and the transport is the third capability
    // composed over there. So the mirror is the binding's, and the wrapper
    // contributes nothing but the unwrap.
    if (T == surface.ImageGenerationRunInput) return .{ .apply = struct {
        fn apply(half: *client.Client, value: T) Error!shapes.ImageGenerationBinding {
            return copyFields(shapes.ImageGenerationBinding, half, value.binding);
        }
    }.apply };
    if (T == contract.VideoGenerationRunInput) return mirrorFrom(T, shapes.VideoGenerationBinding);

    // A capability whose whole content is its presence. The inspection is a
    // reverse call answered by the half that holds the delivery root, so
    // nothing about the root travels and there is nothing here to carry.
    if (T == contract.FileDeliveryInput) return .{ .apply = struct {
        fn apply(_: *client.Client, _: T) Error!shapes.FileDeliveryEnabled {
            return .{};
        }
    }.apply };

    // An optional of anything already answered. Last, so a type with its own
    // answer for the absent case gets it above.
    if (@typeInfo(T) == .optional) {
        const Child = @typeInfo(T).optional.child;
        const inner = comptime adapter(Child) orelse return null;
        if (wire_types.Wire(T) != ?wire_types.Wire(Child)) return null;
        return .{ .apply = struct {
            fn apply(half: *client.Client, value: T) Error!wire_types.Wire(T) {
                return if (value) |inner_value| try inner.apply(half, inner_value) else null;
            }
        }.apply };
    }

    return null;
}

/// A handle, resolved to the id the far side knows it by.
///
/// An absent optional crosses as `Id.none`, not as `?Id`: a zero id is
/// already invalid by construction, and a second way to say absent is a
/// second thing for a decoder to be told.
fn handleAdapter(comptime T: type) ?Adapter(T) {
    return switch (@typeInfo(T)) {
        .optional => .{ .apply = struct {
            fn apply(half: *client.Client, value: T) Error!handle_table.Id {
                const handle = value orelse return .none;
                return idOf(half, handle);
            }
        }.apply },
        else => .{ .apply = struct {
            fn apply(half: *client.Client, value: T) Error!handle_table.Id {
                return idOf(half, value);
            }
        }.apply },
    };
}

/// The id behind one handle, whichever way its box was carried.
fn idOf(half: *client.Client, handle: anytype) Error!handle_table.Id {
    // A port value carries the box in its own context; a bare pointer is the
    // box. Both end at the same table.
    const address: *const anyopaque = switch (@typeInfo(@TypeOf(handle))) {
        .@"struct" => handle.context orelse return error.UnknownHandle,
        else => handle,
    };
    return half.boxes.borrow(address) catch error.UnknownHandle;
}

/// A mirror whose fields all correspond, copied by a generic reader.
///
/// The counterpart of `adapters.mirrorAdapter`, which reads the same mirrors
/// the other way. Generic for the same reason: a hand-written copy is a
/// second place for a shape to drift, and `shapes.mirrors` only checks that
/// each field still names something.
fn mirrorFrom(comptime T: type, comptime Mirror: type) Adapter(T) {
    if (wire_types.Wire(T) != Mirror) @compileError(
        "the mirror for " ++ @typeName(T) ++ " is not its wire form",
    );
    return .{ .apply = struct {
        fn apply(half: *client.Client, value: T) Error!Mirror {
            return copyFields(Mirror, half, value);
        }
    }.apply };
}

/// The copy itself, without asking whether the original has a wire form of
/// its own.
///
/// `image_generation.BindingInput` is why that question is separate: it has a
/// mirror but is never a parameter, so `Wire` has no entry for it and asking
/// would fail on a type nothing is wrong with. The protection against a
/// forgotten field is this reader plus `shapes.mirrors`, which checks the
/// pair in both directions -- not the wire-form assertion, which is only a
/// sanity check on the caller above.
fn copyFields(
    comptime Mirror: type,
    half: *client.Client,
    value: anytype,
) Error!Mirror {
    const Origin = @TypeOf(value);
    var out: Mirror = undefined;
    inline for (@typeInfo(Mirror).@"struct".fields) |field| {
        if (!@hasField(Origin, field.name)) @compileError(
            @typeName(Mirror) ++ "." ++ field.name ++ " does not name a field of " ++
                @typeName(Origin) ++ ", so this is a reshaping rather than a copy and " ++
                "belongs in that mirror's own `from`",
        );
        const Field = @FieldType(Origin, field.name);
        if (Field == field.type) {
            @field(out, field.name) = @field(value, field.name);
            continue;
        }
        const nested = comptime adapter(Field) orelse @compileError(
            @typeName(Origin) ++ "." ++ field.name ++ " crosses as " ++
                @typeName(field.type) ++ " and nothing turns " ++
                @typeName(Field) ++ " into it",
        );
        @field(out, field.name) = try nested.apply(half, @field(value, field.name));
    }
    return out;
}

// ---------------------------------------------------------------------------
// What is still owed
// ---------------------------------------------------------------------------

pub const Owed = struct {
    owner: method.Owner,
    name: []const u8,
    /// Which parameter, by position after the context pointer.
    position: usize,
    argument: []const u8,
};

pub fn owedArguments() []const Owed {
    comptime {
        @setEvalBranchQuota(1_000_000);
        var list: []const Owed = &.{};
        for (method.entries) |entry| {
            if (entry.transport == .stream) continue;
            switch (entry.owner) {
                inline else => |owner| {
                    const Fn = @typeInfo(@FieldType(owner.VTable(), entry.name)).pointer.child;
                    for (@typeInfo(Fn).@"fn".params, 0..) |param, position| {
                        if (position == 0) continue;
                        if (adapter(param.type.?) != null) continue;
                        list = list ++ [_]Owed{.{
                            .owner = entry.owner,
                            .name = entry.name,
                            .position = position,
                            .argument = @typeName(param.type.?),
                        }};
                    }
                },
            }
        }
        return list;
    }
}

/// Whether every argument of one method can be put on the wire from here.
pub fn sendable(comptime owner: method.Owner, comptime name: []const u8) bool {
    const Fn = @typeInfo(@FieldType(owner.VTable(), name)).pointer.child;
    inline for (@typeInfo(Fn).@"fn".params, 0..) |param, position| {
        if (position == 0) continue;
        if (comptime adapter(param.type.?) == null) return false;
    }
    return true;
}

const testing = std.testing;

test "every handle resolves by one rule, whichever way its box was carried" {
    const half = try testClient(2);
    defer releaseTestClient(half);

    const in_context = try half.boxes.open(.{ .slot = 3, .generation = 1 });
    const boxed = try half.boxes.open(.{ .slot = 8, .generation = 2 });

    // A port value, whose context holds the box.
    const session: port.SessionPort = .{ .context = in_context, .vtable = half.vtables.session };
    const session_id = try (comptime adapter(port.SessionPort).?).apply(half, session);
    try testing.expectEqual(@as(u32, 3), session_id.slot);

    // A bare pointer, which is the box.
    const lease: *catalog.Lease = @ptrCast(boxed);
    const lease_id = try (comptime adapter(*catalog.Lease).?).apply(half, lease);
    try testing.expectEqual(@as(u32, 8), lease_id.slot);

    // A third kind, through the same table again. The execution half needs a
    // case per kind of object because it resolves against one table per kind
    // -- `adapters.reclamation` enumerates them -- and that is the asymmetry
    // this test is here to record: over here all of them are boxes.
    try testing.expect(adapters.reclamation.len > 1);
    const captured: *port.SkillRestoreInputs = @ptrCast(in_context);
    const captured_id = try (comptime adapter(*port.SkillRestoreInputs).?).apply(half, captured);
    try testing.expectEqual(session_id.bits(), captured_id.bits());
}

test "an absent optional handle crosses as the zero that is already invalid" {
    const half = try testClient(1);
    defer releaseTestClient(half);

    const absent = try (comptime adapter(?*catalog.Lease).?).apply(half, null);
    try testing.expect(!absent.valid());

    const box = try half.boxes.open(.{ .slot = 4, .generation = 1 });
    const present = try (comptime adapter(?*catalog.Lease).?)
        .apply(half, @as(*catalog.Lease, @ptrCast(box)));
    try testing.expectEqual(@as(u32, 4), present.slot);
}

test "a handle this half never issued is refused rather than sent" {
    const half = try testClient(1);
    defer releaseTestClient(half);

    var elsewhere: client.Box = .{
        .link = half,
        .id = .{ .slot = 9, .generation = 9 },
        .live = true,
    };
    const forged: *catalog.Lease = @ptrCast(&elsewhere);
    // It reads back as a plausible id, which is exactly why the table rather
    // than the record is what decides.
    try testing.expectEqual(@as(u32, 9), elsewhere.id.slot);
    try testing.expectError(
        error.UnknownHandle,
        (comptime adapter(*catalog.Lease).?).apply(half, forged),
    );
}

test "a released handle is refused while its box is free, and redirects once it is reused" {
    // Both halves of this are deliberate, and the second half is a limit
    // rather than a bug to fix later, so it is pinned here rather than left
    // for someone to discover.
    const half = try testClient(1);
    defer releaseTestClient(half);

    const box = try half.boxes.open(.{ .slot = 2, .generation = 1 });
    const lease: *catalog.Lease = @ptrCast(box);
    const Releasing = struct {
        fn ok(_: void, _: handle_table.Id) anyerror!void {}
    };
    try half.boxes.releaseThrough(box, anyerror!void, {}, Releasing.ok);

    // While the box is free, the refusal is clean. That is what the box buys
    // over one allocation per handle, where this would be a read of freed
    // memory instead.
    try testing.expectError(
        error.UnknownHandle,
        (comptime adapter(*catalog.Lease).?).apply(half, lease),
    );

    // Once the box is reused, the released handle names its new occupant,
    // and nothing here can tell. Detecting it would need a generation in the
    // handle, and the handle is a bare pointer with nowhere to put one --
    // which is the same fact that made the pointer-shaped-integer
    // representation unacceptable, read the other way round.
    //
    // The execution half's table does not have this limit because its handle
    // is an `Id` carrying a generation. The reason the limit is acceptable
    // here is that in process the same mistake is worse: `catalog.Lease` is
    // a refcounted allocation, so a released lease used again is freed
    // memory, and the Agent never consults a table by pointer at all. This
    // half is therefore no worse than the process it replaces, and the one
    // way to be strictly better -- never reusing a box -- would exhaust the
    // table after N releases and break calls that are not bugs.
    const successor = try half.boxes.open(.{ .slot = 7, .generation = 1 });
    try testing.expectEqual(box, successor);
    const redirected = try (comptime adapter(*catalog.Lease).?).apply(half, lease);
    try testing.expectEqual(@as(u32, 7), redirected.slot);
}

test "what does not travel is absent from the wire, not a field holding nothing" {
    const half = try testClient(1);
    defer releaseTestClient(half);

    // The allocator is the caller's: the far side calls with its own.
    try testing.expectEqual(void, wire_types.Wire(std.mem.Allocator));
    try (comptime adapter(std.mem.Allocator).?).apply(half, testing.allocator);

    // And the request tuple has no slot for it either.
    const Copy = @typeInfo(@FieldType(port.SessionPort.VTable, "copy_pending_ui_request"))
        .pointer.child;
    try testing.expectEqual(
        @as(usize, 0),
        @typeInfo(wire_types.Request(Copy)).@"struct".fields.len,
    );
}

test "the argument direction is counted on its own" {
    const owed = comptime owedArguments();
    for (owed) |entry| {
        try testing.expect(entry.name.len > 0);
        try testing.expect(entry.position > 0);
    }
    // Both are the same question rather than two: a parameter that is a byte
    // callback has no wire form derivable from the callback, because what the
    // far side needs to know is in the closure and not in the type.
    //
    //   * `restore_session_route`'s source needs a *descriptor* -- which
    //     generation, which digest, how many bytes -- and those are facts
    //     only the caller has about a blob that already exists, so they have
    //     to be said. `export_checkpoint`'s sink was in this list for the
    //     same reason and is not any more: an export names a blob that does
    //     *not* exist yet, and every fact needed to open one turned out to
    //     be on the Session or in the call's own limits, so its wire form is
    //     nothing at all.
    //   * `prepare_run_with_tools`' MCP install input is a reverse call --
    //     `shapes.McpInstallationTarget` records why -- and belongs to the
    //     MCP step with the rest of it.
    try testing.expectEqual(@as(usize, 2), owed.len);

    // What that leaves: the callable methods that can put every argument
    // they are given on the wire. Counted rather than claimed, same as the
    // execution half's `dispatchableCount` -- and the two owed arguments sit
    // on two methods, so this is the callable count less those two.
    var callable: usize = 0;
    var count: usize = 0;
    inline for (comptime method.entries) |entry| {
        if (entry.transport == .stream) continue;
        callable += 1;
        if (comptime sendable(entry.owner, entry.name)) count += 1;
    }
    try testing.expectEqual(@as(usize, 50), callable);
    try testing.expectEqual(callable - owed.len, count);
}

fn testClient(count: usize) !*client.Client {
    const self = try testing.allocator.create(client.Client);
    try self.init(
        testing.io,
        testing.allocator,
        undefined,
        undefined,
        .{
            .session = undefined,
            .run = undefined,
            .run_control = undefined,
            .runtime = undefined,
        },
        count,
    );
    return self;
}

fn releaseTestClient(self: *client.Client) void {
    self.deinit();
    testing.allocator.destroy(self);
}
