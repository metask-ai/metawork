//! Reading an answer back into the port's own types.
//!
//! The fourth direction, and the one with the least in common with the other
//! three. The execution half resolves an argument by *reading* a table and
//! encodes a result by *writing* one; this half does neither. It allocates
//! what the port type says the caller owns, and it names what the far side
//! kept -- and naming something it does not hold is where the work is.
//!
//! ## A name is capacity, and capacity is spent before the call
//!
//! A method whose result names a handle has already done something
//! irreversible by the time its answer arrives: the Session exists, the lease
//! is held, the Run is begun. If this half discovered only then that it had
//! no box left, the object would be live over there with nothing here able to
//! name it or release it -- the leak the execution half's reservations exist
//! to prevent, in the other direction.
//!
//! So the boxes are taken before the request is sent and filled from the
//! answer, and a call that produced fewer handles than its type could carry
//! gives the rest back. `boxesNeeded` is read off the wire form, so a shape
//! that gains a handle reserves for it without anyone editing a number.
//!
//! ## What is owed is counted, not assumed
//!
//! `owedInbound` is this direction's own list, on the same terms as
//! `adapters.owedParameters` and `adapters.owedResults`: a return type with
//! nothing to read it back is named by the compiler, never left as "nobody
//! got to it yet".

const std = @import("std");
const contract = @import("agent_contract");
const client = @import("client.zig");
const handle_repr = @import("handle_repr.zig");
const handle_table = @import("handle_table.zig");
const method = @import("method.zig");
const shapes = @import("shapes.zig");
const error_code = @import("error_code.zig");
const wire_types = @import("wire_types.zig");

const port = contract.port;
const surface = contract.surface;
const control = contract.control;
const catalog = @import("agent_catalog");
const mcp_catalog = @import("agent_mcp_catalog");
const checkpoint = @import("agent_checkpoint");

pub const Error = error{
    /// The peer sent something this build does not encode -- an error number
    /// outside the registry, a handle id of zero. A protocol violation, never
    /// one of the port's own failures.
    Unreadable,
} || std.mem.Allocator.Error || client.Boxes.Error;

// ---------------------------------------------------------------------------
// Boxes taken before the call
// ---------------------------------------------------------------------------

/// How many handles a value of this wire form could name.
///
/// The maximum over a union's arms, because only one arm arrives and
/// reserving for the widest is what makes the arrival unable to fail. An
/// optional id counts as one: absent spends nothing and gives the box back.
pub fn boxesNeeded(comptime Wired: type) usize {
    if (Wired == handle_table.Id) return 1;
    return switch (@typeInfo(Wired)) {
        .optional => |info| boxesNeeded(info.child),
        .@"struct" => |info| blk: {
            var total: usize = 0;
            inline for (info.fields) |field| total += boxesNeeded(field.type);
            break :blk total;
        },
        .@"union" => |info| blk: {
            var widest: usize = 0;
            inline for (info.fields) |field| {
                const needed = boxesNeeded(field.type);
                if (needed > widest) widest = needed;
            }
            break :blk widest;
        },
        else => 0,
    };
}

/// The boxes a call took before sending, handed to the conversion in order.
pub const Reservations = struct {
    taken: []const *client.Box,
    used: usize = 0,
    /// The id each claimed box is to hold, written into it only once the
    /// whole conversion has succeeded.
    wanted: []handle_table.Id = &.{},

    /// The next box, for a handle the answer actually carried, with the id it
    /// is to name.
    ///
    /// The id is recorded rather than written, and that is the whole point.
    /// A conversion that filled a box and then failed -- `catalog.Acquisition`
    /// fills the lease and then allocates the projection, which can fail --
    /// left an object live on the far side with nothing on this side able to
    /// name it or release it, which is exactly what the boxes exist to stop,
    /// one line later than the header describes. Ordering the work inside
    /// every adapter would fix the ones we looked at and leave the rule to be
    /// remembered by the next one; deferring the fill to `invoke` means no
    /// adapter *can* fill a box, so none can abandon a filled one.
    ///
    /// Asserts rather than returning an error: running out means
    /// `boxesNeeded` under-counted the shape, which is a build-time fact
    /// about types rather than anything the peer can cause.
    pub fn claim(self: *Reservations, id: handle_table.Id) *client.Box {
        std.debug.assert(self.used < self.taken.len);
        std.debug.assert(self.used < self.wanted.len);
        const box = self.taken[self.used];
        self.wanted[self.used] = id;
        self.used += 1;
        return box;
    }

    /// Writes the recorded ids in. Called once, after the conversion has
    /// succeeded, so every box either names something or was never claimed.
    pub fn settle(self: *Reservations, half: *client.Client) void {
        for (self.taken[0..self.used], self.wanted[0..self.used]) |box, id| {
            half.boxes.fill(box, id);
        }
    }
};

// ---------------------------------------------------------------------------
// The conversion
// ---------------------------------------------------------------------------

pub fn Adapter(comptime T: type) type {
    return struct {
        apply: *const fn (*client.Client, *Reservations, wire_types.Wire(T)) Error!T,
    };
}

/// How one wire value becomes the port's own type, or `null` when nothing
/// does it yet.
pub fn adapter(comptime T: type) ?Adapter(T) {
    // Plain data, which is most of them: a Run id, a count, a bool, `void`.
    // Nothing to own and nothing to name.
    if (wire_types.Wire(T) == T) return .{ .apply = struct {
        fn apply(_: *client.Client, _: *Reservations, value: T) Error!T {
            return value;
        }
    }.apply };

    // A handle the far side kept. Which representation it gets is
    // `handle_repr`'s answer, not a decision repeated here.
    if (wire_types.Wire(T) == handle_table.Id) return handleAdapter(T);

    // An optional handle. Absent is absent: no box is spent, and the one
    // reserved for it goes back with the rest.
    if (wire_types.Wire(T) == ?handle_table.Id) {
        const inner = comptime handleAdapter(@typeInfo(T).optional.child) orelse return null;
        return .{ .apply = struct {
            fn apply(
                half: *client.Client,
                taken: *Reservations,
                value: ?handle_table.Id,
            ) Error!T {
                return if (value) |id| try inner.apply(half, taken, id) else null;
            }
        }.apply };
    }

    // Mirrors that carry their own inverse, because turning a number back
    // into an error is not a field copy and a number outside the registry is
    // a protocol violation rather than a generic failure.
    if (T == surface.CloseOutcome) return .{ .apply = struct {
        fn apply(_: *client.Client, _: *Reservations, value: shapes.CloseOutcome) Error!T {
            return value.into() orelse error.Unreadable;
        }
    }.apply };
    if (T == surface.BeginRunFailure) return .{ .apply = struct {
        fn apply(_: *client.Client, _: *Reservations, value: shapes.BeginRunFailure) Error!T {
            return value.into() orelse error.Unreadable;
        }
    }.apply };

    // Mirrors whose original owns bytes through an allocator. Each one's
    // `into` allocates from this half and leaves the original's own `deinit`
    // to free it, which is the ownership rule in `client.zig` applied by the
    // type that states it rather than restated here.
    if (T == control.TerminalResult) return allocating(T, shapes.TerminalResult);
    if (T == control.CompactTerminalResult) return allocating(T, shapes.CompactTerminalResult);
    if (T == surface.PendingUiRequest) return allocating(T, shapes.PendingUiRequest);
    if (T == checkpoint.Outcome) return allocating(T, shapes.CheckpointOutcome);

    // Values that name a handle *and* carry data beside it. Written out
    // rather than read generically, because each one decides something a
    // field copy cannot: which vtable a port value gets, whether an absent
    // id is a null or a violation, and that a Run's two halves come from one
    // entry over there and so from one box here.
    if (T == port.SessionRoute) return .{ .apply = struct {
        fn apply(
            half: *client.Client,
            taken: *Reservations,
            value: shapes.SessionRoute,
        ) Error!port.SessionRoute {
            return .{
                .id = value.route_id,
                .session = try (comptime adapter(port.SessionPort).?)
                    .apply(half, taken, value.session),
            };
        }
    }.apply };
    if (T == port.SessionRestoreRoute) return .{
        .apply = struct {
            fn apply(
                half: *client.Client,
                taken: *Reservations,
                value: shapes.SessionRestoreRoute,
            ) Error!port.SessionRestoreRoute {
                return .{
                    .id = value.route_id,
                    .session = try (comptime adapter(port.SessionPort).?)
                        .apply(half, taken, value.session),
                    // Scalars throughout, so the report is itself.
                    .report = value.report,
                };
            }
        }.apply,
    };
    if (T == port.SkillRestoreBorrow) return .{ .apply = struct {
        fn apply(
            half: *client.Client,
            taken: *Reservations,
            value: shapes.SkillRestoreBorrow,
        ) Error!port.SkillRestoreBorrow {
            return .{
                .catalog = try (comptime adapter(*catalog.Lease).?)
                    .apply(half, taken, value.catalog),
                .policy = value.policy,
            };
        }
    }.apply };
    if (T == port.SessionRestoreInputs) return .{
        .apply = struct {
            fn apply(
                half: *client.Client,
                taken: *Reservations,
                value: shapes.SessionRestoreInputs,
            ) Error!port.SessionRestoreInputs {
                return .{
                    // The Runtime does not travel, because across the link the
                    // Runtime *is* the link: the value names the half it came
                    // from so its parts can be released there, and over here
                    // that half is this one.
                    .agent = .{ .context = null, .vtable = half.vtables.runtime },
                    // Absent as `Id.none` rather than as an optional, so an
                    // absent capability is the zero that is already invalid by
                    // construction and not a second way of saying the same
                    // thing.
                    .skill = if (value.skill.valid())
                        try (comptime adapter(*port.SkillRestoreInputs).?)
                            .apply(half, taken, value.skill)
                    else
                        null,
                    .mcp = if (value.mcp.valid())
                        try (comptime adapter(*mcp_catalog.RestoreSelection).?)
                            .apply(half, taken, value.mcp)
                    else
                        null,
                    .permission_mode = value.permission_mode,
                    .shell_policy = value.shell_policy,
                    .permission_interaction = value.permission_interaction,
                };
            }
        }.apply,
    };
    if (T == catalog.Acquisition) return .{
        .apply = struct {
            fn apply(
                half: *client.Client,
                taken: *Reservations,
                value: shapes.CatalogAcquisition,
            ) Error!catalog.Acquisition {
                const lease = try (comptime adapter(*catalog.Lease).?)
                    .apply(half, taken, value.lease);
                // The projection owns its contents in an arena of its own,
                // through `catalog.Projection.own`: what arrived borrows the
                // response bytes and this call's arena, and both are gone by
                // the time Product reads any of it.
                return .{
                    .lease = lease,
                    .projection = try catalog.Projection.own(
                        half.allocator,
                        value.projection.revision,
                        value.projection.health,
                        value.projection.skills,
                        value.projection.issues,
                    ),
                };
            }
        }.apply,
    };
    if (T == port.BeginRunOutcome) return .{
        .apply = struct {
            fn apply(
                half: *client.Client,
                taken: *Reservations,
                value: shapes.BeginRunOutcome,
            ) Error!port.BeginRunOutcome {
                return switch (value) {
                    .failure => |failure| .{
                        .failure = try (comptime adapter(surface.BeginRunFailure).?)
                            .apply(half, taken, failure),
                    },
                    .run => |route| blk: {
                        if (!route.run.valid()) return error.Unreadable;
                        // One box, because over there one entry holds both the
                        // Run's vtable and the control every retain goes
                        // through: `adapters.BegunRun` is that entry, and a
                        // second id for the same thing would be a second
                        // lifetime to keep in step with it.
                        const box = taken.claim(route.run);
                        const control_handle: port.RunControl = .{
                            .context = box,
                            .vtable = half.vtables.run_control,
                            .run_id = route.run_id,
                            .generation = route.generation,
                        };
                        break :blk .{
                            .run = .{
                                .context = box,
                                .vtable = half.vtables.run,
                                .run_id = route.run_id,
                                .generation = route.generation,
                                // The retain already happened over there, when the
                                // Run was begun: this is that reference, named here,
                                // and the lease's `deinit` releases it across the
                                // link exactly as it would in process.
                                .base_lease = .{ .control = control_handle },
                            },
                        };
                    },
                };
            }
        }.apply,
    };

    // An optional of anything already answered. Last, so a type that wants
    // its own answer for the absent case gets it above rather than having
    // this one chosen for it.
    if (@typeInfo(T) == .optional) {
        const Child = @typeInfo(T).optional.child;
        const inner = comptime adapter(Child) orelse return null;
        if (wire_types.Wire(T) != ?wire_types.Wire(Child)) return null;
        return .{ .apply = struct {
            fn apply(
                half: *client.Client,
                taken: *Reservations,
                value: ?wire_types.Wire(Child),
            ) Error!T {
                return if (value) |inner_value| try inner.apply(half, taken, inner_value) else null;
            }
        }.apply };
    }

    return null;
}

/// A mirror whose original owns bytes, converted by that mirror's own `into`.
fn allocating(comptime T: type, comptime Mirror: type) Adapter(T) {
    if (wire_types.Wire(T) != Mirror) @compileError(
        "the mirror for " ++ @typeName(T) ++ " is not its wire form",
    );
    return .{ .apply = struct {
        fn apply(half: *client.Client, _: *Reservations, value: Mirror) Error!T {
            return value.into(half.allocator);
        }
    }.apply };
}

/// A handle, named the way `handle_repr` says this half names it.
fn handleAdapter(comptime T: type) ?Adapter(T) {
    const representation = handle_repr.representationOf(T) orelse return null;
    return switch (representation) {
        // The pointer is the value, so the box's address *is* the handle.
        .boxed => .{ .apply = struct {
            fn apply(_: *client.Client, taken: *Reservations, id: handle_table.Id) Error!T {
                if (!id.valid()) return error.Unreadable;
                return @ptrCast(taken.claim(id));
            }
        }.apply },
        // A port value has a context to carry the box in. Which port value
        // it is decides the vtable, and the only one that crosses as a bare
        // id is the Session: a Run arrives inside `BeginRunOutcome`, which
        // builds both halves of it at once.
        .in_context => if (T == port.SessionPort) .{ .apply = struct {
            fn apply(
                half: *client.Client,
                taken: *Reservations,
                id: handle_table.Id,
            ) Error!port.SessionPort {
                if (!id.valid()) return error.Unreadable;
                return .{ .context = taken.claim(id), .vtable = half.vtables.session };
            }
        }.apply } else null,
    };
}

// ---------------------------------------------------------------------------
// One whole call, from this side
// ---------------------------------------------------------------------------

/// What one call means to the method's own caller: its return payload, or the
/// failure the far side answered with.
///
/// The transport's own three failures are not here. A stub turns one of those
/// into what its return type can say, which is `unreachability.zig`'s rule
/// and belongs at the stub rather than in a fourth arm nobody can act on.
pub fn Outcome(comptime owner: method.Owner, comptime name: []const u8) type {
    const Returned = wire_types.Payload(
        @typeInfo(client.Signature(owner, name)).@"fn".return_type.?,
    );
    return union(enum) {
        returned: Returned,
        failed: error_code.LinkError,
    };
}

/// Whether one method's result can be read back from here.
pub fn readable(comptime owner: method.Owner, comptime name: []const u8) bool {
    return adapter(@FieldType(Outcome(owner, name), "returned")) != null;
}

pub const InvokeError = client.CallError || Error;

/// Sends one call and reads its answer back into the port's own types.
///
/// The three steps are in one place on purpose. Each is wrong without the
/// others: the boxes must be taken before the request (the answer cannot
/// fail), the arena must outlive the decode (the value borrows it), and the
/// boxes not used must go back (a call that failed, or an absent optional,
/// must not spend a name). A stub that composed them itself would be fifty
/// chances to get the order wrong.
pub fn invoke(
    comptime owner: method.Owner,
    comptime name: []const u8,
    half: *client.Client,
    receiver: handle_table.Id,
    arguments: client.Arguments(owner, name),
) InvokeError!Outcome(owner, name) {
    const Returned = comptime @FieldType(Outcome(owner, name), "returned");
    const read = comptime adapter(Returned) orelse @compileError(
        "nothing reads " ++ @typeName(Returned) ++ " back, so " ++ name ++
            " cannot be forwarded yet; it is in `owedInbound`",
    );
    const needed = comptime boxesNeeded(wire_types.Wire(Returned));

    var reserved: [needed]*client.Box = undefined;
    var opened: usize = 0;
    // Everything not filled goes back, whether the call failed, an optional
    // arrived absent, or a union took the narrower arm.
    defer for (reserved[0..opened]) |box| {
        if (!box.id.valid()) half.boxes.releaseReservation(box);
    };
    while (opened < needed) : (opened += 1) reserved[opened] = try half.boxes.reserve();

    var arena_state = std.heap.ArenaAllocator.init(half.allocator);
    defer arena_state.deinit();

    const answer = try client.call(
        owner,
        name,
        half,
        arena_state.allocator(),
        receiver,
        arguments,
    );
    return switch (answer) {
        .failed => |err| .{ .failed = err },
        .returned => |wired| blk: {
            var wanted: [needed]handle_table.Id = undefined;
            var taken: Reservations = .{
                .taken = reserved[0..opened],
                .wanted = wanted[0..],
            };
            // The conversion claims boxes but fills none, so a failure here
            // leaves every box unfilled and the defer above gives all of them
            // back. Settling after it has succeeded is what makes "a filled
            // box is a box Product owns" true without each adapter having to
            // order its own work.
            const value = try read.apply(half, &taken, wired);
            taken.settle(half);
            break :blk .{ .returned = value };
        },
    };
}

// ---------------------------------------------------------------------------
// What is still owed
// ---------------------------------------------------------------------------

pub const Owed = struct {
    owner: method.Owner,
    name: []const u8,
    result: []const u8,
};

pub fn owedInbound() []const Owed {
    comptime {
        @setEvalBranchQuota(1_000_000);
        var list: []const Owed = &.{};
        for (method.entries) |entry| {
            if (entry.transport == .stream) continue;
            const blocked = switch (entry.owner) {
                inline else => |owner| blockingResult(owner, entry.name),
            };
            if (blocked) |name| list = list ++ [_]Owed{.{
                .owner = entry.owner,
                .name = entry.name,
                .result = name,
            }};
        }
        return list;
    }
}

fn blockingResult(comptime owner: method.Owner, comptime name: []const u8) ?[]const u8 {
    comptime {
        const Fn = @typeInfo(@FieldType(owner.VTable(), name)).pointer.child;
        const Returned = wire_types.Payload(@typeInfo(Fn).@"fn".return_type.?);
        if (Returned == void) return null;
        if (adapter(Returned) != null) return null;
        return @typeName(Returned);
    }
}

const testing = std.testing;

test "how many boxes a result needs is read off its shape" {
    // Nothing to name.
    try testing.expectEqual(@as(usize, 0), boxesNeeded(void));
    try testing.expectEqual(@as(usize, 0), boxesNeeded(shapes.TerminalResult));

    // One handle, named directly or inside a struct.
    try testing.expectEqual(@as(usize, 1), boxesNeeded(handle_table.Id));
    try testing.expectEqual(@as(usize, 1), boxesNeeded(?handle_table.Id));
    try testing.expectEqual(@as(usize, 1), boxesNeeded(shapes.SessionRoute));
    try testing.expectEqual(@as(usize, 1), boxesNeeded(shapes.CatalogAcquisition));

    // Two, because the value can carry both.
    try testing.expectEqual(@as(usize, 2), boxesNeeded(shapes.SessionRestoreInputs));

    // A union reserves for its widest arm, because one arm arrives and the
    // arrival must not be able to fail.
    try testing.expectEqual(@as(usize, 1), boxesNeeded(shapes.BeginRunOutcome));
}

test "a handle arrives into a box that was already taken" {
    const half = try testClient(2);
    defer releaseTestClient(half);

    const box = try half.boxes.reserve();
    var wanted: [1]handle_table.Id = undefined;
    var taken: Reservations = .{ .taken = &.{box}, .wanted = &wanted };

    const session = try (comptime adapter(port.SessionPort).?)
        .apply(half, &taken, .{ .slot = 6, .generation = 2 });
    // The conversion claimed the box; `invoke` is what writes the id in once
    // nothing further can fail, so a test driving one adapter does that step
    // too rather than reading a box the real sequence has not filled yet.
    taken.settle(half);

    // Named, and the name is this half's own record rather than the id in a
    // pointer-shaped integer.
    try testing.expectEqual(@as(usize, 1), taken.used);
    try testing.expectEqual(@as(u32, 6), (try client.Client.receiverFrom(session.context)).slot);
    try testing.expectEqual(half, client.Client.linkFrom(session.context));
}

test "a zero id is a protocol violation, and the box it would have used is untouched" {
    const half = try testClient(1);
    defer releaseTestClient(half);

    const box = try half.boxes.reserve();
    var taken: Reservations = .{ .taken = &.{box} };

    // Zero is never a live handle, so it is read as the peer not speaking
    // this protocol rather than as an absent object.
    try testing.expectError(
        error.Unreadable,
        (comptime adapter(port.SessionPort).?).apply(half, &taken, .none),
    );
    try testing.expectEqual(@as(usize, 0), taken.used);
    // The reservation is still a reservation: it names nothing, and the
    // caller gives it back.
    try testing.expectError(error.UnknownBox, half.boxes.borrow(box));
    half.boxes.releaseReservation(box);
    try testing.expectEqual(@as(usize, 0), half.boxes.liveCount());
}

test "an error number outside this build's registry is unreadable, not a failure" {
    const half = try testClient(1);
    defer releaseTestClient(half);
    var taken: Reservations = .{ .taken = &.{} };

    const read = comptime adapter(surface.CloseOutcome).?;
    const closed = try read.apply(half, &taken, .closed);
    try testing.expectEqual(surface.CloseOutcome.closed, closed);

    // A number nothing registers would otherwise have to become *some*
    // error, and whichever one it became would name a cause that did not
    // happen.
    try testing.expectError(error.Unreadable, read.apply(half, &taken, .{ .failure = .{
        .error_code = std.math.maxInt(u16),
        .session_disposition = .reusable,
    } }));
}

test "the inbound direction is counted on its own" {
    const owed = comptime owedInbound();
    for (owed) |entry| {
        try testing.expect(entry.name.len > 0);
        try testing.expect(entry.result.len > 0);
    }
    // One left, and it is the MCP step's: `surface.McpActivationOutcome`
    // hands back a `*McpActivation`, and `handles.zig` records eight of its
    // reads as fixed once the activation is built -- so the caller answers
    // them locally rather than calling across. A box cannot do that: a box
    // names the far object and nothing more, and those reads are methods
    // Product calls on the pointer. What that needs is a stand-in object on
    // this side holding `shapes.McpActivationProjection`, which is a
    // different shape from every other handle here and is why it waits for
    // the step that owns the rest of MCP.
    try testing.expectEqual(@as(usize, 1), owed.len);
    try testing.expectEqual(method.Owner.runtime, owed[0].owner);
    try testing.expectEqualStrings("activate_mcp", owed[0].name);
}

test "what comes back owns itself, so the call's own memory can go" {
    // The rule in `client.zig`, exercised on the type that settles it: the
    // diagnostic arrives borrowing bytes that are freed when the call
    // returns, and what Product is handed must survive that.
    const half = try testClient(1);
    defer releaseTestClient(half);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    const arena = arena_state.allocator();
    const borrowed = try arena.dupe(u8, "core said no");

    var taken: Reservations = .{ .taken = &.{} };
    var result = try (comptime adapter(control.TerminalResult).?).apply(half, &taken, .{
        .diagnostic = borrowed,
        .diagnostic_truncated = true,
        .abi_status = null,
        .raw_status_code = null,
        .stop_reason = null,
        .raw_stop_reason_code = null,
        .abort_status = null,
        .raw_abort_status_code = null,
        .termination_signal = null,
        .file_changes_lost = false,
        .event_delivery_lost = false,
        .receipts = .{},
        .failure = null,
        .session_disposition_at_completion = .reusable,
        .durable_budget = null,
        .input_counts = null,
        .first_callback_rejection = null,
        .first_host_failure = null,
        .controlled_callback_close = null,
        .model_error = null,
    });
    // The call's arena goes, as it does at the end of every call.
    arena_state.deinit();

    // And the value still reads, because it owns its own copy and frees it
    // through the field the port type already had.
    try testing.expectEqualStrings("core said no", result.diagnostic());
    try testing.expect(result.diagnostic_truncated);
    result.deinit();
}

test "an unnamed failure stays unnamed rather than becoming some other error" {
    // The mirror sends "present but unnamed" for an error its registry does
    // not cover. Reading that back as a registered error would name a cause
    // that did not happen, and reading it back as `null` would say no
    // failure was recorded when one was.
    const rejection = shapes.CallbackRejection.from(.{
        .boundary = .event_decode,
        .reason = .decode_failed,
        .event = null,
        .failure = error.SomethingThisBuildNeverRegistered,
        .encoded_bytes = null,
        .host_run_id = 3,
        .observed_run_id = null,
        .session_handle_matches = null,
        .session_identity_matches = null,
        .state = .idle,
        .input_adoption = null,
    });
    try testing.expect(rejection.failure_unnamed);
    try testing.expect(rejection.failure_code == null);

    const back = rejection.into();
    try testing.expectEqual(shapes.CallbackRejection.unnamed_failure, back.failure.?);
    inline for (error_code.entries) |entry| {
        try testing.expect(back.failure.? != @field(anyerror, entry.name));
    }
}

test "a Run's two halves come from one box, because one entry holds both" {
    const half = try testClient(2);
    defer releaseTestClient(half);

    const box = try half.boxes.reserve();
    var wanted: [1]handle_table.Id = undefined;
    var taken: Reservations = .{ .taken = &.{box}, .wanted = &wanted };
    const outcome = try (comptime adapter(port.BeginRunOutcome).?).apply(half, &taken, .{
        .run = .{ .run_id = 11, .generation = 2, .run = .{ .slot = 5, .generation = 1 } },
    });
    taken.settle(half);

    // One box spent, and the Run and its control both name it: a second id
    // for `adapters.BegunRun` would be a second lifetime to keep in step.
    try testing.expectEqual(@as(usize, 1), taken.used);
    try testing.expectEqual(@as(usize, 1), half.boxes.liveCount());
    try testing.expectEqual(outcome.run.context, outcome.run.base_lease.control.context);

    // The identity stays inline, exactly as it does in process.
    try testing.expectEqual(@as(u64, 11), outcome.run.run_id);
    try testing.expectEqual(@as(u64, 11), outcome.run.base_lease.control.run_id);
    try testing.expectEqual(@as(u32, 5), (try client.Client.receiverFrom(outcome.run.context)).slot);
}

test "an absent capability spends no name" {
    const half = try testClient(2);
    defer releaseTestClient(half);

    const first = try half.boxes.reserve();
    const second = try half.boxes.reserve();
    var wanted: [2]handle_table.Id = undefined;
    var taken: Reservations = .{ .taken = &.{ first, second }, .wanted = &wanted };

    const inputs = try (comptime adapter(port.SessionRestoreInputs).?).apply(half, &taken, .{
        .skill = .{ .slot = 2, .generation = 1 },
        // Absent, and absent is the invalid-by-construction zero rather than
        // a second way of saying the same thing.
        .mcp = .none,
        .permission_mode = .default,
        .shell_policy = .sandboxed,
        .permission_interaction = .interactive,
    });

    try testing.expect(inputs.skill != null);
    try testing.expect(inputs.mcp == null);
    try testing.expectEqual(@as(usize, 1), taken.used);

    // The Runtime it names is this half, because across the link the Runtime
    // *is* the link.
    try testing.expectEqual(half.vtables.runtime, inputs.agent.vtable);
    half.boxes.releaseReservation(second);
}

fn testClient(count: usize) !*client.Client {
    const self = try testing.allocator.create(client.Client);
    try self.init(
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

test "a conversion that fails after claiming a box leaves no box named" {
    const half = try testClient(2);
    defer releaseTestClient(half);

    const box = try half.boxes.reserve();
    var wanted: [1]handle_table.Id = undefined;
    var taken: Reservations = .{ .taken = &.{box}, .wanted = &wanted };

    // `catalog.Acquisition` claims the lease's box and then allocates the
    // projection, which can fail. Before the fill was deferred, the box was
    // already filled by then: the lease stayed live on the far side with
    // nothing on this side able to name it or release it, which is the exact
    // failure the boxes exist to prevent.
    const saved = half.allocator;
    half.allocator = std.testing.failing_allocator;
    try testing.expectError(
        error.OutOfMemory,
        (comptime adapter(catalog.Acquisition).?).apply(half, &taken, .{
            .lease = .{ .slot = 3, .generation = 1 },
            .projection = .{
                .revision = "rev",
                .health = .healthy,
                .skills = &.{},
                .issues = &.{},
            },
        }),
    );
    half.allocator = saved;

    // The box was claimed, so `used` moved -- and it holds no id. That is
    // what `invoke`'s defer tests to decide whether to give a box back, so an
    // unnamed box is a box that goes back rather than a name kept for an
    // object this half never received.
    try testing.expectEqual(@as(usize, 1), taken.used);
    try testing.expect(!box.id.valid());

    // And it does go back: the slot is a reservation until then, which is
    // why the count is one here and zero after.
    try testing.expectEqual(@as(usize, 1), half.boxes.liveCount());
    half.boxes.releaseReservation(box);
    try testing.expectEqual(@as(usize, 0), half.boxes.liveCount());
}
