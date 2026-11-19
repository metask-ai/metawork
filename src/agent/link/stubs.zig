//! The four port vtables the caller's half installs, and the one body behind
//! all fifty-four of them.
//!
//! Product keeps calling the ports it already calls. What changes is what is
//! behind them: a stub that encodes the arguments (`outbound.zig`), sends the
//! call and reads the answer back (`inbound.zig`), and turns a link that is
//! gone into what its own return type can say (`unreachability.zig`).
//!
//! ## Why the signatures are written out
//!
//! Zig 0.16 removed `@Type` for functions, so a function whose signature is
//! computed cannot be synthesised. Each stub therefore declares its vtable
//! signature by hand -- and that is cheap, because the compiler checks every
//! one against the vtable field it is assigned to, so a signature that drifts
//! from the contract does not build. What is *not* written out is anything
//! that decides something: the payload, the conversion in either direction,
//! the receiver and the answer for a gone link all come from the registries.
//! Fifty-four signatures the compiler checks are not a risk; fifty-four hand
//! written encoders would have been.
//!
//! ## Two entry points, and the compiler picks
//!
//! `forward` is for a method whose answer for a gone link follows from its
//! return type: an error union answers `DependencyUnreachable`, an optional
//! answers null, a type that declares its own answer as a whole value answers
//! that. `forwardAnswering` is for the rest -- the nine methods
//! `unreachability.exemptions` covers, plus the unions that name an arm
//! without naming what fills it.
//!
//! Neither can be used where the other belongs: `forward` refuses at compile
//! time when the answer is not derivable, and `forwardAnswering` refuses when
//! it is. So a stub cannot quietly invent an answer for a method whose type
//! already states one, and cannot quietly inherit a derived answer for a
//! method whose exemption rests on a specific value.

const std = @import("std");
const contract = @import("agent_contract");
const adapters = @import("adapters.zig");
const call_frame = @import("call_frame.zig");
const channel = @import("channel.zig");
const client = @import("client.zig");
const dispatch = @import("dispatch.zig");
const frame = @import("frame.zig");
const pending = @import("pending.zig");
const run_tools = @import("run_tools.zig");
const error_code = @import("error_code.zig");
const handle_table = @import("handle_table.zig");
const inbound = @import("inbound.zig");
const method = @import("method.zig");
const outbound = @import("outbound.zig");
const payload = @import("payload.zig");
const unreachability = @import("unreachability.zig");
const wire_types = @import("wire_types.zig");

const port = contract.port;
const surface = contract.surface;
const control = contract.control;
const checkpoint = @import("agent_checkpoint");
const catalog = @import("agent_catalog");
const mcp_catalog = @import("agent_mcp_catalog");

// ---------------------------------------------------------------------------
// The one body
// ---------------------------------------------------------------------------

fn Returns(comptime owner: method.Owner, comptime name: []const u8) type {
    return unreachability.ReturnType(owner, name);
}

/// The port's own parameters, after the context pointer.
fn Parameters(comptime owner: method.Owner, comptime name: []const u8) type {
    comptime var types: []const type = &.{};
    const Fn = @typeInfo(@FieldType(owner.VTable(), name)).pointer.child;
    inline for (@typeInfo(Fn).@"fn".params, 0..) |param, position| {
        if (position == 0) continue;
        types = types ++ [_]type{param.type.?};
    }
    return std.meta.Tuple(types);
}

/// The answer a gone link gets, when the return type alone decides it.
///
/// `null` means it does not, which is the compile-time signal that this stub
/// belongs to `forwardAnswering`. A union that declares *which arm* without
/// declaring what fills it is in that group: naming the arm is not naming the
/// value, and what fills it is a decision about what to tell Product.
fn derivedAnswer(comptime owner: method.Owner, comptime name: []const u8) ?Returns(owner, name) {
    @setEvalBranchQuota(1_000_000);
    const R = Returns(owner, name);
    return switch (comptime unreachability.expressibility(R) orelse return null) {
        .error_union => blk: {
            const Set = @typeInfo(R).error_union.error_set;
            // A set with no member for it is a type that has to change, not a
            // member to borrow: `port.CompactCancellation` is the one that
            // did, and the reason is written there.
            if (comptime !hasMember(Set, "DependencyUnreachable")) break :blk null;
            break :blk error.DependencyUnreachable;
        },
        .optional => null_answer: {
            const value: R = null;
            break :null_answer value;
        },
        .declared_answer => blk: {
            const declared = @field(R, unreachability.answer_decl);
            if (@TypeOf(declared) == R) break :blk declared;
            // A tag rather than a whole value. If the arm it names carries
            // nothing, naming the arm *is* naming the value and the stub has
            // no room to choose; `control.InputSubmission.link_unreachable`
            // is one, and `port.zig` builds it exactly this way.
            inline for (@typeInfo(R).@"union".fields) |field| {
                if (field.name.len == @tagName(declared).len and
                    std.mem.eql(u8, field.name, @tagName(declared)) and
                    field.type == void)
                {
                    break :blk @unionInit(R, field.name, {});
                }
            }
            // The arm carries something, so what fills it is a decision
            // about what to tell Product: that is `forwardAnswering`'s.
            break :blk null;
        },
    };
}

fn hasMember(comptime Set: type, comptime wanted: []const u8) bool {
    @setEvalBranchQuota(100_000);
    inline for (@typeInfo(Set).error_set.?) |member| {
        if (std.mem.eql(u8, member.name, wanted)) return true;
    }
    return false;
}

/// Sends one call, for a method whose return type says what a gone link is.
fn forward(
    comptime owner: method.Owner,
    comptime name: []const u8,
    context: ?*anyopaque,
    parameters: Parameters(owner, name),
) Returns(owner, name) {
    const gone = comptime derivedAnswer(owner, name) orelse @compileError(
        @tagName(owner) ++ "." ++ name ++ " does not say what a gone link is from its " ++
            "return type alone, so its answer is a decision: use `forwardAnswering` and " ++
            "pass the value, which is what `unreachability.exemptions` is about",
    );
    return body(owner, name, gone, context, parameters);
}

/// Sends one call, for a method whose answer is a value someone chose.
fn forwardAnswering(
    comptime owner: method.Owner,
    comptime name: []const u8,
    gone: Returns(owner, name),
    context: ?*anyopaque,
    parameters: Parameters(owner, name),
) Returns(owner, name) {
    if (comptime derivedAnswer(owner, name) != null) @compileError(
        @tagName(owner) ++ "." ++ name ++ "'s return type already says what a gone link " ++
            "is; use `forward` rather than choosing a second answer beside it",
    );
    return body(owner, name, gone, context, parameters);
}

// ---------------------------------------------------------------------------
// The four this build does not forward
// ---------------------------------------------------------------------------
//
// The mirror of the dispatcher's `NotDispatchable`, and recorded the same
// way: a method whose argument has no wire form or whose result has nothing
// to read it back cannot be forwarded, and saying so where it happens is the
// alternative to a stub that answers something.
//
// It is a panic rather than the gone answer. The gone answer is a statement
// about the link, and the link is fine: what is missing is a piece of this
// build. Answering "the peer is unreachable" would send Product down a path
// that handles a real condition, and the state it put the Task in would look
// like a link problem to everyone who read it afterwards.

const NotForwarded = struct {
    owner: method.Owner,
    name: []const u8,
    /// What is missing, and where the rest of it is recorded.
    why: []const u8,
};

const not_forwarded = [_]NotForwarded{
    .{
        .owner = .runtime,
        .name = "activate_mcp",
        .why = "its `*McpActivation` needs a stand-in object on this side holding the " ++
            "projected reads, not a box; see `inbound.owedInbound` and the MCP step",
    },
    .{
        .owner = .runtime,
        .name = "restore_session_route",
        .why = "its options carry a byte callback for the checkpoint source, whose wire " ++
            "form is a descriptor the caller has to state: a restore names a blob that " ++
            "already exists, by facts only the caller has. `export_checkpoint` was here " ++
            "for what looked like the same reason and is not, because an export names a " ++
            "blob that does not exist yet",
    },
    .{
        .owner = .session,
        .name = "prepare_run_with_tools",
        .why = "the MCP installation input is a reverse call; see " ++
            "`shapes.McpInstallationTarget` and the MCP step",
    },

    // The entries below are the execution half's side, and they are here
    // because `forwardable` spans both halves. Each one's result puts a
    // handle *into* a table over there, which `adapters.resultAdapter`
    // leaves to the path that carries a reservation into the result encoding
    // -- `adapters.named_handles` classifies every one of them. The caller's
    // half can send the call and read the answer; nothing yet writes the
    // answer.
    //
    // How many there are is not written here. The previous version said
    // "the ten below" above nine entries, in the commit that was about a
    // hand-counted number claiming something the build did not do, which is
    // the same mistake one line further down. `execSideGaps` counts the list
    // instead, and a test reads it.
    .{
        .owner = .runtime,
        .name = "create_session_route",
        .why = "`adapters.owedResults` owes `port.SessionRoute`: the Session has to be put " ++
            "into the execution half's table, which needs the reservation path",
    },
    .{
        .owner = .runtime,
        .name = "query_skill_catalog",
        .why = "`adapters.owedResults` owes `catalog.Acquisition`, whose lease is put into " ++
            "a table; `named_handles` classifies it irreversible",
    },
    .{
        .owner = .runtime,
        .name = "borrow_skill_restore_inputs",
        .why = "`adapters.owedResults` owes `port.SkillRestoreBorrow`, which names a lease " ++
            "the execution half holds",
    },
    .{
        .owner = .runtime,
        .name = "clone_skill_restore_inputs",
        .why = "`adapters.owedResults` owes a new `*SkillRestoreInputs`, which is a handle " ++
            "put into a table",
    },
    .{
        .owner = .runtime,
        .name = "narrow_skill_restore_inputs",
        .why = "the same, and narrowing allocates another handle on that side",
    },
    .{
        .owner = .runtime,
        .name = "create_mcp_admission_selection",
        .why = "both directions are MCP's: the activation argument and the selection result",
    },
    .{
        .owner = .runtime,
        .name = "prepare_mcp_restore_selection",
        .why = "the same, and it takes two MCP handles",
    },
    .{
        .owner = .session,
        .name = "capture_restore_inputs",
        .why = "`adapters.owedResults` owes `port.SessionRestoreInputs`, which names two " ++
            "captured capabilities",
    },
    .{
        .owner = .session,
        .name = "begin_run_outcome",
        .why = "`adapters.owedResults` owes `port.BeginRunOutcome`: a begun Run is an entry " ++
            "in the execution half's `runs` table, taken before the call that begins it",
    },
};

/// Whether this build answers one method **end to end**.
///
/// All four directions, not the two this half owns. The first version asked
/// only `outbound.sendable and inbound.readable`, and that let me report "46
/// methods forward end to end" when what I had measured was 46 the caller's
/// half can send and read -- the execution half's own two registries were
/// untouched, so a method in that 46 could still meet `NotDispatchable` at
/// the far end. A count that can say something the build does not do is worse
/// than no count, so the predicate now spans both halves and the number it
/// produces cannot mean anything else.
///
/// It also means `not_forwarded` is the honest list: a method whose exec-side
/// adapter is missing is named there with its reason, rather than looking
/// forwardable from here.
fn forwardable(comptime owner: method.Owner, comptime name: []const u8) bool {
    return outbound.sendable(owner, name) and
        inbound.readable(owner, name) and
        dispatch.dispatchable(owner, name);
}

/// How many entries on the list are the execution half's, read off the list.
///
/// Counted rather than written in the comment above it. The first version of
/// that comment said "the ten below" over nine entries, inside the commit
/// about a hand-counted number claiming something the build did not do.
fn execSideGaps() usize {
    comptime {
        var count: usize = 0;
        for (not_forwarded) |entry| {
            const blocked_there = switch (entry.owner) {
                inline else => |owner| !dispatch.dispatchable(owner, entry.name),
            };
            const fine_here = switch (entry.owner) {
                inline else => |owner| outbound.sendable(owner, entry.name) and
                    inbound.readable(owner, entry.name),
            };
            if (blocked_there and fine_here) count += 1;
        }
        return count;
    }
}

fn listedNotForwarded(comptime owner: method.Owner, comptime name: []const u8) bool {
    for (not_forwarded) |entry| {
        if (entry.owner == owner and std.mem.eql(u8, entry.name, name)) return true;
    }
    return false;
}

// Closed both ways, so the list cannot drift from what the build can do: a
// method that becomes forwardable is named here by the compiler rather than
// keeping a panic nobody noticed, and a method that stops being forwardable
// cannot be left out.
comptime {
    @setEvalBranchQuota(10_000_000);
    for (method.entries) |entry| {
        if (entry.transport == .stream) continue;
        const can = switch (entry.owner) {
            inline else => |owner| forwardable(owner, entry.name),
        };
        const listed = switch (entry.owner) {
            inline else => |owner| listedNotForwarded(owner, entry.name),
        };
        if (can and listed) @compileError(
            "src/agent/link/stubs.zig lists " ++ entry.name ++ " as not forwarded, but " ++
                "both its arguments and its result are answered now; delete the entry and " ++
                "give it a real stub",
        );
        if (!can and !listed) @compileError(
            entry.name ++ " cannot be forwarded from the caller's half and is not in " ++
                "`not_forwarded`; add it with what is missing, so a method nobody can " ++
                "call is a recorded gap rather than a stub that answers something",
        );
    }
}

fn notForwarded(comptime owner: method.Owner, comptime name: []const u8) noreturn {
    // The comptime check above guarantees that an unforwardable method is
    // listed, so reaching the `else` means this was called for a method that
    // *is* forwardable -- a caller bypassing `forward`.
    const entry = comptime for (not_forwarded) |listed| {
        if (listed.owner == owner and std.mem.eql(u8, listed.name, name)) break listed;
    } else @compileError(
        name ++ " is answered end to end by this build, so it has no `not_forwarded` entry; " ++
            "`forward`/`forwardAnswering` reach this only through `body`, which checks " ++
            "`forwardable` first",
    );
    @panic("agent link: " ++ @tagName(owner) ++ "." ++ name ++
        " is not forwarded by this build -- " ++ entry.why);
}

/// What a stub answers when the call did not reach an answer, by which fact
/// stopped it.
///
/// One `catch return gone` used to cover all of these, and that merged facts
/// that call for opposite behaviour. A refusal for capacity says "ask again";
/// the gone answer says "stop asking". `runtime.zig` turns a compact
/// cancellation's `DependencyUnreachable` into `.session_closing` and stops
/// following that compact -- so a cancellation refused because the outbound
/// queue was full, reported as unreachable, would abandon a compact that is
/// still running. `client.Failure`'s own comment says "nobody is there" and
/// "not right now" are two facts; this is where that stops being a comment.
///
/// The split is by whether the condition is permanent, because that is what
/// decides whether the gone answer leads the caller to the same action as
/// the truth would:
///
///   * Gone, unreadable, and a handle this half no longer names are all
///     permanent. The gone answer is the restricting one and no retry would
///     help, so it is the right answer for each -- the *diagnostic*
///     difference between them is real and belongs in a log this layer does
///     not yet have, which is worth saying out loud rather than leaving to
///     whoever next reads the merge.
///   * Capacity -- the send queue, this half's box table, an allocation --
///     is transient, and the correct behaviour is to ask again. No return
///     type in the surface can say it (`unreachability.pressureCounts`),
///     so there is nothing to answer with and this refuses loudly.
/// Every way a call can stop before it has an answer, as one set.
///
/// Written as a union of the two paths' own sets rather than listed, so the
/// switch below is exhaustive by construction: a new member on either path
/// fails the build instead of landing in an `else` that would quietly give
/// it the gone answer -- which is how the merge this function removes got
/// there in the first place.
const Stopped = outbound.Error || inbound.InvokeError;

/// What a stopped call is, for answering purposes.
const Reason = enum {
    /// Permanent: no retry would reach a different outcome, so the gone
    /// answer leads the caller to the same action the truth would.
    gone,
    /// Transient: the far side was reached, or would have been, and the
    /// correct behaviour is to ask again.
    no_room,
};

/// Split out from `linkAnswer` so it can be tested over every member of the
/// set. The answer itself is a value of the method's own return type and a
/// panic on the other branch, neither of which a test can compare.
fn stoppedBy(err: Stopped) Reason {
    return switch (err) {
        // Nothing is there, or nothing will be.
        error.Unreachable => .gone,
        // An answer this build cannot decode means the peer is not this
        // build, so nothing usable will come from it either.
        error.Unreadable => .gone,
        // A handle already released, or one this half never issued. The
        // object is not there, permanently; asking again names the same
        // missing thing.
        error.UnknownHandle, error.UnknownBox => .gone,
        // Room, not reachability.
        error.Busy, error.BoxCapacity, error.OutOfMemory => .no_room,
    };
}

fn linkAnswer(
    comptime owner: method.Owner,
    comptime name: []const u8,
    gone: Returns(owner, name),
    err: Stopped,
) Returns(owner, name) {
    return switch (stoppedBy(err)) {
        .gone => gone,
        .no_room => noRoom(owner, name, err),
    };
}

/// Reached, and no room. This build has nothing to answer with.
///
/// A panic rather than the gone answer, for the same reason `notForwarded`
/// is one: the gone answer is a statement about the link, and the link is
/// fine. What is missing is a piece of this build -- here, a return type
/// that can say "not now", which is a change to the Agent contract rather
/// than something a stub can decide. Until it lands, the condition is loud
/// where it happens instead of silently becoming a different fact somewhere
/// Product can act on it.
///
/// `unreachability.pressureCounts().owed` is how many methods are in this
/// state, and the plan's §4.2 row -- a saturated queue returns typed busy
/// and never a user timeout, a user refusal or an Agent terminal cause -- is
/// what closes it.
fn noRoom(
    comptime owner: method.Owner,
    comptime name: []const u8,
    err: Stopped,
) noreturn {
    if (comptime unreachability.saysPressure(Returns(owner, name))) @compileError(
        @tagName(owner) ++ "." ++ name ++ "'s return type can say it was refused for " ++
            "capacity, so it must say so rather than panic: answer with its " ++
            "`" ++ unreachability.pressure_decl ++ "` or `" ++
            unreachability.pressure_error ++ "`",
    );
    std.debug.panic(
        "agent link: {s}.{s} was refused for capacity ({s}) and its return type cannot " ++
            "say so; see `unreachability.pressureCounts`",
        .{ @tagName(owner), name, @errorName(err) },
    );
}

fn body(
    comptime owner: method.Owner,
    comptime name: []const u8,
    gone: Returns(owner, name),
    context: ?*anyopaque,
    parameters: Parameters(owner, name),
) Returns(owner, name) {
    if (comptime !forwardable(owner, name)) notForwarded(owner, name);
    // A Runtime method names no receiver, because there is nothing to choose
    // between: across the link the Runtime *is* the link, so the port's own
    // context is this half.
    const half = if (comptime owner == .runtime)
        @as(*client.Client, @ptrCast(@alignCast(context.?)))
    else
        client.Client.linkFrom(context);
    const receiver = if (comptime owner == .runtime)
        handle_table.Id.none
    else
        client.Client.receiverFrom(context) catch |err|
            return linkAnswer(owner, name, gone, err);

    const arguments = send(owner, name, half, parameters) catch |err|
        return linkAnswer(owner, name, gone, err);
    const outcome = inbound.invoke(owner, name, half, receiver, arguments) catch |err|
        return linkAnswer(owner, name, gone, err);
    return switch (outcome) {
        .returned => |value| value,
        .failed => |err| answered(owner, name, gone, err),
    };
}

/// The port's arguments as the wire's, position by position.
///
/// Written once rather than per stub, which is the point: a parameter whose
/// wire form changes changes here, and the fifty-four signatures above do not
/// contain a single encoder between them.
fn send(
    comptime owner: method.Owner,
    comptime name: []const u8,
    half: *client.Client,
    parameters: Parameters(owner, name),
) outbound.Error!client.Arguments(owner, name) {
    var arguments: client.Arguments(owner, name) = undefined;
    comptime var field: usize = 0;
    inline for (parameters, 0..) |parameter, position| {
        _ = position;
        const Parameter = @TypeOf(parameter);
        // A parameter that does not travel contributes no field, which is
        // `wire_types.Request` leaving it out rather than a rule repeated
        // here.
        if (comptime wire_types.Wire(Parameter) == void) continue;
        const adapter = comptime outbound.adapter(Parameter) orelse @compileError(
            @tagName(owner) ++ "." ++ name ++ " takes a " ++ @typeName(Parameter) ++
                " and nothing puts one on the wire; it is in `outbound.owedArguments`",
        );
        arguments[field] = try adapter.apply(half, parameter);
        field += 1;
    }
    comptime std.debug.assert(field == @typeInfo(client.Arguments(owner, name)).@"struct".fields.len);
    return arguments;
}

/// The far side was reached and said no, so the answer is its error -- if
/// this method's own set contains it.
///
/// A `LinkError` outside the method's set is the peer answering with
/// something this signature cannot express, which is a protocol violation and
/// not one of the port's failures. It lands on the gone answer, which is the
/// restricting side for every method here by construction.
fn answered(
    comptime owner: method.Owner,
    comptime name: []const u8,
    gone: Returns(owner, name),
    err: error_code.LinkError,
) Returns(owner, name) {
    @setEvalBranchQuota(1_000_000);
    const R = Returns(owner, name);
    if (comptime @typeInfo(R) != .error_union) return gone;
    const Set = @typeInfo(R).error_union.error_set;
    inline for (@typeInfo(Set).error_set.?) |member| {
        if (err == @field(anyerror, member.name)) return @field(anyerror, member.name);
    }
    return gone;
}

// The signatures below are the vtable's own, so they are written with the
// contract's own names: `port.zig` declares the vtable in terms of these, and
// a stub whose signature is spelled differently would still have to mean the
// same type. Aliasing rather than respelling keeps that a fact rather than a
// habit -- and the compiler checks each stub against the field it is assigned
// to, so a signature that drifts from the contract does not build.
const session_control = control;
const Error = surface.Error;
const Allocating = Error || std.mem.Allocator.Error;
const SessionPort = port.SessionPort;
const SessionRoute = port.SessionRoute;
const SessionRestoreRoute = port.SessionRestoreRoute;
const SessionRestoreInputs = port.SessionRestoreInputs;
const SkillRestoreInputs = port.SkillRestoreInputs;
const SkillRestoreBorrow = port.SkillRestoreBorrow;
const BeginRunOutcome = port.BeginRunOutcome;
const RestoreAdmission = port.RuntimePort.RestoreAdmission;
const PendingUiObservation = port.SessionPort.PendingUiObservation;

// The contract re-exports what the link module itself does not depend on,
// which is also the honest dependency: these names reach the stubs the same
// way they reach `port.zig`, through the contract rather than past it.
const event_pump = struct {
    const OwnedCoreEvent = contract.OwnedCoreEvent;
};
const delivery = struct {
    const Input = contract.FileDeliveryInput;
};
const generate_video = struct {
    const Input = contract.VideoGenerationRunInput;
};
const mcp_install = struct {
    const Input = contract.McpInstallationInput;
};
const sdk = struct {
    const protocol = struct {
        const PermissionChoice = contract.PermissionChoice;
    };
};

// ---------------------------------------------------------------------------
// The answers someone had to choose
// ---------------------------------------------------------------------------
//
// Each one is the value `unreachability.exemptions` argues for, and the
// exemption's `reason` is where the argument lives. They are here, beside the
// stubs that pass them, so that reading either leads to the other.

/// `session.close_outcome`: the declared arm is `.failure`, and a close that
/// could not reach the Session is a failure rather than a close -- `closed`
/// would tell the caller its Session is gone when it may still be running.
/// The disposition is the restricting one: nothing established that the
/// Session is reusable.
const gone_close: surface.CloseOutcome = .{ .failure = .{
    .err = error.DependencyUnreachable,
    .session_disposition = .poisoned,
} };

/// `session.begin_run_outcome`: the declared arm is `.failure` for the same
/// reason in the other direction -- a `run` arm would hand back a Run that
/// nothing is executing.
const gone_begin_run: port.BeginRunOutcome = .{ .failure = .{
    .err = error.DependencyUnreachable,
    .session_disposition = .poisoned,
} };

/// `session.snapshot`: `.poisoned` is the value the exemption rests on, and
/// it says so in as many words -- all four of its consumer's downstreams put
/// `.poisoned` on the restricting side, and a stub answering anything else
/// would break the exemption. The rest is zero because none of it is known
/// and that consumer reads only `.state`.
const gone_snapshot: surface.SessionSnapshot = .{
    .session_id = 0,
    .state = .poisoned,
    .workspace_root = "",
    .active_run_id = 0,
    .active_compact_id = 0,
    .pending_ui_request_id = null,
};

/// `run.execute`: a terminal whose failure is `dependency_contract`, which
/// `control.terminationEffect` already reads as "the termination effect is
/// unknown" before looking at anything else, and which the consuming
/// classifier's catch-all already handles. Built rather than declared
/// because the type owns its diagnostic through an allocator; the storage is
/// empty, and `std.mem.Allocator.free` returns immediately on a zero-length
/// slice, so Product's own `deinit` is correct either way.
fn goneTerminal(context: ?*anyopaque) control.TerminalResult {
    return .{
        .allocator = client.Client.linkFrom(context).allocator,
        .diagnostic_storage = &.{},
        .diagnostic_len = 0,
        .diagnostic_truncated = false,
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
        .failure = .dependency_contract,
        .session_disposition_at_completion = .poisoned,
        .durable_budget = null,
        .input_counts = null,
        .first_callback_rejection = null,
        .first_host_failure = null,
        .controlled_callback_close = null,
        .model_error = null,
    };
}

// ---------------------------------------------------------------------------
// The four that are not calls
// ---------------------------------------------------------------------------
//
// `wire_types.zig` records why: an event owns its JSON through an allocator
// and holds parsed pointers into it, so it could never have been a response.
// The bytes travel as `event` frames and this half's pump builds the value
// locally -- which means these four are answered from frames already in
// hand, by a pump that is its own piece of work.
//
// They panic rather than answering, because an answer would be a lie with a
// shape: a null event reads as "nothing to deliver", a zero count reads as
// "fully drained", and `unreachability.zig`'s pending entry is about exactly
// that -- Product commits a truncated conversation as a complete one. A
// vtable installed without a pump is a wiring mistake in MetaWork, not a
// runtime condition, so it says so where it happens.

fn pumpOwns(comptime name: []const u8) noreturn {
    @panic("agent link: " ++ name ++ " is answered by the caller-side event pump, " ++
        "which this build has not installed");
}

fn runtimeTakeEvent(_: ?*anyopaque) ?event_pump.OwnedCoreEvent {
    pumpOwns("take_event");
}

fn runtimeHasPendingEvents(_: ?*anyopaque) bool {
    pumpOwns("has_pending_events");
}

fn runtimePendingEventCount(_: ?*anyopaque, _: u64) usize {
    pumpOwns("pending_event_count");
}

fn runtimeNotifyEventConsumer(_: ?*anyopaque) session_control.EventReadyNotification {
    pumpOwns("notify_event_consumer");
}

// -------------------------------------------------------------------------
// RunPort
// -------------------------------------------------------------------------

fn runExecute(
    context: ?*anyopaque,
    run_id: u64,
    generation: u64,
) session_control.TerminalResult {
    return forwardAnswering(.run, "execute", goneTerminal(context), context, .{ run_id, generation });
}

// -------------------------------------------------------------------------
// RunControl
// -------------------------------------------------------------------------

fn runControlTryRetain(
    context: ?*anyopaque,
) bool {
    return forwardAnswering(.run_control, "try_retain", false, context, .{});
}

fn runControlRelease(
    context: ?*anyopaque,
) void {
    return forwardAnswering(.run_control, "release", {}, context, .{});
}

fn runControlSubmitInput(
    context: ?*anyopaque,
    run_id: u64,
    generation: u64,
    input_id: u64,
    text: []const u8,
) session_control.InputSubmission {
    return forward(.run_control, "submit_input", context, .{ run_id, generation, input_id, text });
}

fn runControlInputObservation(
    context: ?*anyopaque,
    run_id: u64,
    generation: u64,
) ?session_control.InputObservation {
    return forward(.run_control, "input_observation", context, .{ run_id, generation });
}

fn runControlRequestTermination(
    context: ?*anyopaque,
    run_id: u64,
    generation: u64,
    signal: session_control.TerminationSignal,
) session_control.TerminationRequestResult {
    return forward(.run_control, "request_termination", context, .{ run_id, generation, signal });
}

// -------------------------------------------------------------------------
// SessionPort
// -------------------------------------------------------------------------

fn sessionRetainReference(
    context: ?*anyopaque,
) bool {
    return forwardAnswering(.session, "retain_reference", false, context, .{});
}

fn sessionReleaseReference(
    context: ?*anyopaque,
) void {
    return forwardAnswering(.session, "release_reference", {}, context, .{});
}

fn sessionStopEventDelivery(
    context: ?*anyopaque,
) void {
    return forwardAnswering(.session, "stop_event_delivery", {}, context, .{});
}

fn sessionCloseOutcome(
    context: ?*anyopaque,
    interruption: session_control.ExternalInterruption,
) surface.CloseOutcome {
    return forwardAnswering(.session, "close_outcome", gone_close, context, .{interruption});
}

fn sessionRefreshSkillCatalog(
    context: ?*anyopaque,
    lease: *catalog.Lease,
    policy: surface.SkillPolicyInput,
) Allocating!void {
    return forward(.session, "refresh_skill_catalog", context, .{ lease, policy });
}

fn sessionSetModel(
    context: ?*anyopaque,
    model: []const u8,
) Error!void {
    return forward(.session, "set_model", context, .{model});
}

fn sessionClearSkillPolicy(
    context: ?*anyopaque,
) Allocating!void {
    return forward(.session, "clear_skill_policy", context, .{});
}

fn sessionSkillPolicyMatches(
    context: ?*anyopaque,
    lease: *catalog.Lease,
    policy: surface.SkillPolicyInput,
) bool {
    return forwardAnswering(.session, "skill_policy_matches", false, context, .{ lease, policy });
}

fn sessionCaptureRestoreInputs(
    context: ?*anyopaque,
) Allocating!SessionRestoreInputs {
    return forward(.session, "capture_restore_inputs", context, .{});
}

fn sessionSnapshot(
    context: ?*anyopaque,
) surface.SessionSnapshot {
    return forwardAnswering(.session, "snapshot", gone_snapshot, context, .{});
}

fn sessionUpdatePermissionMode(
    context: ?*anyopaque,
    expected: session_control.PermissionMode,
    target: session_control.PermissionMode,
) Error!surface.PermissionModeUpdate {
    return forward(.session, "update_permission_mode", context, .{ expected, target });
}

fn sessionConversationBounds(
    context: ?*anyopaque,
) Error!surface.ConversationBounds {
    return forward(.session, "conversation_bounds", context, .{});
}

fn sessionRewindToUserMessage(
    context: ?*anyopaque,
    position: u64,
) Error!surface.RewindOutcome {
    return forward(.session, "rewind_to_user_message", context, .{position});
}

fn sessionUpdateCredential(
    context: ?*anyopaque,
    credential: []const u8,
) Error!void {
    return forward(.session, "update_credential", context, .{credential});
}

fn sessionRequestTermination(
    context: ?*anyopaque,
    run_id: u64,
    signal: session_control.TerminationSignal,
) Error!void {
    return forward(.session, "request_termination", context, .{ run_id, signal });
}

fn sessionPrepareRun(
    context: ?*anyopaque,
    input: surface.RunInput,
) Allocating!u64 {
    return forward(.session, "prepare_run", context, .{input});
}

fn sessionPrepareRunWithTools(
    context: ?*anyopaque,
    input: surface.RunInput,
    image: ?surface.ImageGenerationRunInput,
    delivery_input: ?delivery.Input,
    mcp: ?mcp_install.Input,
    video: ?generate_video.Input,
) Allocating!u64 {
    return forward(.session, "prepare_run_with_tools", context, .{ input, image, delivery_input, mcp, video });
}

fn sessionBeginRunOutcome(
    context: ?*anyopaque,
    run_id: u64,
) BeginRunOutcome {
    return forwardAnswering(.session, "begin_run_outcome", gone_begin_run, context, .{run_id});
}

fn sessionCancelPreparedRun(
    context: ?*anyopaque,
    run_id: u64,
) Error!void {
    return forward(.session, "cancel_prepared_run", context, .{run_id});
}

fn sessionPrepareCompact(
    context: ?*anyopaque,
) Allocating!u64 {
    return forward(.session, "prepare_compact", context, .{});
}

fn sessionCancelPreparedCompact(
    context: ?*anyopaque,
    compact_id: u64,
) Error!void {
    return forward(.session, "cancel_prepared_compact", context, .{compact_id});
}

fn sessionExecutePreparedCompact(
    context: ?*anyopaque,
    compact_id: u64,
) Error!session_control.CompactTerminalResult {
    return forward(.session, "execute_prepared_compact", context, .{compact_id});
}

fn sessionRequestCompactCancellation(
    context: ?*anyopaque,
    compact_id: u64,
    interruption: session_control.ExternalInterruption,
) port.CompactCancellation!void {
    return forward(.session, "request_compact_cancellation", context, .{ compact_id, interruption });
}

fn sessionRespondPermission(
    context: ?*anyopaque,
    run_id: u64,
    request_id: u64,
    choice: sdk.protocol.PermissionChoice,
) Allocating!void {
    return forward(.session, "respond_permission", context, .{ run_id, request_id, choice });
}

fn sessionFailUiRequestIdentityContract(
    context: ?*anyopaque,
    request_id: u64,
) Error!void {
    return forward(.session, "fail_ui_request_identity_contract", context, .{request_id});
}

fn sessionPendingUiObservation(
    context: ?*anyopaque,
) ?PendingUiObservation {
    return forward(.session, "pending_ui_observation", context, .{});
}

fn sessionPermissionStopRequest(
    context: ?*anyopaque,
) ?u64 {
    return forward(.session, "permission_stop_request", context, .{});
}

fn sessionCopyPendingUiRequest(
    context: ?*anyopaque,
    allocator: std.mem.Allocator,
) Allocating!surface.PendingUiRequest {
    return forward(.session, "copy_pending_ui_request", context, .{allocator});
}

fn sessionExportCheckpoint(
    context: ?*anyopaque,
    limits: checkpoint.Limits,
    sink: checkpoint.Sink,
    last_run_id: u64,
    last_compact_id: u64,
    model: []const u8,
) Error!checkpoint.Outcome {
    return forward(.session, "export_checkpoint", context, .{ limits, sink, last_run_id, last_compact_id, model });
}

// -------------------------------------------------------------------------
// RuntimePort
// -------------------------------------------------------------------------

fn runtimeCreateSessionRoute(
    context: ?*anyopaque,
    options: surface.SessionOpenOptions,
) Allocating!SessionRoute {
    return forward(.runtime, "create_session_route", context, .{options});
}

fn runtimeRestoreSessionRoute(
    context: ?*anyopaque,
    options: surface.SessionRestoreOptions,
) Allocating!SessionRestoreRoute {
    return forward(.runtime, "restore_session_route", context, .{options});
}

fn runtimeReleaseClosedSession(
    context: ?*anyopaque,
    session: SessionPort,
) Error!void {
    return forward(.runtime, "release_closed_session", context, .{session});
}

fn runtimeRequestRunTermination(
    context: ?*anyopaque,
    run_id: u64,
    generation: u64,
    signal: session_control.TerminationSignal,
) Error!void {
    return forward(.runtime, "request_run_termination", context, .{ run_id, generation, signal });
}

fn runtimeRestoreAdmission(
    context: ?*anyopaque,
    releasing_route_id: ?u64,
) RestoreAdmission {
    return forward(.runtime, "restore_admission", context, .{releasing_route_id});
}

fn runtimeActivateMcp(
    context: ?*anyopaque,
) Allocating!surface.McpActivationOutcome {
    return forward(.runtime, "activate_mcp", context, .{});
}

fn runtimeCreateMcpAdmissionSelection(
    context: ?*anyopaque,
    activation: *const mcp_catalog.Activation,
    allowlists: []const mcp_catalog.ServerAllowlist,
) Allocating!?*mcp_catalog.Selection {
    return forward(.runtime, "create_mcp_admission_selection", context, .{ activation, allowlists });
}

fn runtimePrepareMcpRestoreSelection(
    context: ?*anyopaque,
    restore: *const mcp_catalog.RestoreSelection,
    activation: *const mcp_catalog.Activation,
    tools: []const mcp_catalog.ActivationTool,
) Allocating!*mcp_catalog.Selection {
    return forward(.runtime, "prepare_mcp_restore_selection", context, .{ restore, activation, tools });
}

fn runtimeQuerySkillCatalog(
    context: ?*anyopaque,
    query: catalog.Query,
) Allocating!catalog.Acquisition {
    return forward(.runtime, "query_skill_catalog", context, .{query});
}

fn runtimeReleaseSkillCatalog(
    context: ?*anyopaque,
    lease: *catalog.Lease,
) Error!void {
    return forward(.runtime, "release_skill_catalog", context, .{lease});
}

fn runtimeNarrowSkillRestoreInputs(
    context: ?*anyopaque,
    inputs: *SkillRestoreInputs,
    policy: surface.SkillPolicyInput,
) Allocating!*SkillRestoreInputs {
    return forward(.runtime, "narrow_skill_restore_inputs", context, .{ inputs, policy });
}

fn runtimeCloneSkillRestoreInputs(
    context: ?*anyopaque,
    inputs: *SkillRestoreInputs,
) Allocating!*SkillRestoreInputs {
    return forward(.runtime, "clone_skill_restore_inputs", context, .{inputs});
}

fn runtimeBorrowSkillRestoreInputs(
    context: ?*anyopaque,
    inputs: *const SkillRestoreInputs,
) ?SkillRestoreBorrow {
    return forward(.runtime, "borrow_skill_restore_inputs", context, .{inputs});
}

fn runtimeReleaseSkillRestoreInputs(
    context: ?*anyopaque,
    inputs: *SkillRestoreInputs,
) Error!void {
    return forward(.runtime, "release_skill_restore_inputs", context, .{inputs});
}

fn runtimeReleaseRestoreInputs(
    context: ?*anyopaque,
    inputs: *SessionRestoreInputs,
) Error!void {
    return forward(.runtime, "release_restore_inputs", context, .{inputs});
}

/// The RunPort this half installs.
pub const runPort: port.RunPort.VTable = .{
    .execute = runExecute,
};

/// The RunControl this half installs.
pub const runControl: port.RunControl.VTable = .{
    .try_retain = runControlTryRetain,
    .release = runControlRelease,
    .submit_input = runControlSubmitInput,
    .input_observation = runControlInputObservation,
    .request_termination = runControlRequestTermination,
};

/// The SessionPort this half installs.
pub const sessionPort: port.SessionPort.VTable = .{
    .retain_reference = sessionRetainReference,
    .release_reference = sessionReleaseReference,
    .stop_event_delivery = sessionStopEventDelivery,
    .close_outcome = sessionCloseOutcome,
    .refresh_skill_catalog = sessionRefreshSkillCatalog,
    .set_model = sessionSetModel,
    .clear_skill_policy = sessionClearSkillPolicy,
    .skill_policy_matches = sessionSkillPolicyMatches,
    .capture_restore_inputs = sessionCaptureRestoreInputs,
    .snapshot = sessionSnapshot,
    .update_permission_mode = sessionUpdatePermissionMode,
    .conversation_bounds = sessionConversationBounds,
    .rewind_to_user_message = sessionRewindToUserMessage,
    .update_credential = sessionUpdateCredential,
    .request_termination = sessionRequestTermination,
    .prepare_run = sessionPrepareRun,
    .prepare_run_with_tools = sessionPrepareRunWithTools,
    .begin_run_outcome = sessionBeginRunOutcome,
    .cancel_prepared_run = sessionCancelPreparedRun,
    .prepare_compact = sessionPrepareCompact,
    .cancel_prepared_compact = sessionCancelPreparedCompact,
    .execute_prepared_compact = sessionExecutePreparedCompact,
    .request_compact_cancellation = sessionRequestCompactCancellation,
    .respond_permission = sessionRespondPermission,
    .fail_ui_request_identity_contract = sessionFailUiRequestIdentityContract,
    .pending_ui_observation = sessionPendingUiObservation,
    .permission_stop_request = sessionPermissionStopRequest,
    .copy_pending_ui_request = sessionCopyPendingUiRequest,
    .export_checkpoint = sessionExportCheckpoint,
};

/// The RuntimePort this half installs.
pub const runtimePort: port.RuntimePort.VTable = .{
    .create_session_route = runtimeCreateSessionRoute,
    .restore_session_route = runtimeRestoreSessionRoute,
    .release_closed_session = runtimeReleaseClosedSession,
    .take_event = runtimeTakeEvent,
    .has_pending_events = runtimeHasPendingEvents,
    .pending_event_count = runtimePendingEventCount,
    .notify_event_consumer = runtimeNotifyEventConsumer,
    .request_run_termination = runtimeRequestRunTermination,
    .restore_admission = runtimeRestoreAdmission,
    .activate_mcp = runtimeActivateMcp,
    .create_mcp_admission_selection = runtimeCreateMcpAdmissionSelection,
    .prepare_mcp_restore_selection = runtimePrepareMcpRestoreSelection,
    .query_skill_catalog = runtimeQuerySkillCatalog,
    .release_skill_catalog = runtimeReleaseSkillCatalog,
    .narrow_skill_restore_inputs = runtimeNarrowSkillRestoreInputs,
    .clone_skill_restore_inputs = runtimeCloneSkillRestoreInputs,
    .borrow_skill_restore_inputs = runtimeBorrowSkillRestoreInputs,
    .release_skill_restore_inputs = runtimeReleaseSkillRestoreInputs,
    .release_restore_inputs = runtimeReleaseRestoreInputs,
};

/// The four vtables, as the one value a `client.Client` is built with.
pub const vtables: client.Vtables = .{
    .session = &sessionPort,
    .run = &runPort,
    .run_control = &runControl,
    .runtime = &runtimePort,
};

const testing = std.testing;

// ---------------------------------------------------------------------------
// One call, both halves, nothing faked in between
// ---------------------------------------------------------------------------
//
// Everything above is checked by the compiler or by counting. This is the
// test that runs a stub: Product's own `SessionPort.setModel` on one side, a
// real `Outbound` and a real frame on the wire, a real `Inbound` reassembling
// it, the real dispatcher resolving a real handle table, and the answer read
// back through the real inbound chain.
//
// The one thing it does not do is send the response over a second channel --
// it deposits it in the correlation table the way this half's own pump will.
// The reverse-path tests already cover that hop, and the response travelling
// as frames is the one piece this test would duplicate rather than add.

/// A Session that records what it was told, on the execution side.
const Recorder = struct {
    model: [64]u8 = undefined,
    model_len: usize = 0,
    calls: usize = 0,
    stopped_run: ?u64 = null,
    stopped_with: ?session_control.TerminationSignal = null,

    fn setModel(context: ?*anyopaque, model: []const u8) surface.Error!void {
        const self: *Recorder = @ptrCast(@alignCast(context.?));
        if (model.len > self.model.len) return error.CoreCallFailed;
        @memcpy(self.model[0..model.len], model);
        self.model_len = model.len;
        self.calls += 1;
    }

    fn told(self: *const Recorder) []const u8 {
        return self.model[0..self.model_len];
    }

    fn requestTermination(
        context: ?*anyopaque,
        run_id: u64,
        signal: session_control.TerminationSignal,
    ) surface.Error!void {
        const self: *Recorder = @ptrCast(@alignCast(context.?));
        self.stopped_run = run_id;
        self.stopped_with = signal;
        self.calls += 1;
    }

    fn sessionPortFor(self: *Recorder, vtable: *port.SessionPort.VTable) port.SessionPort {
        vtable.set_model = setModel;
        vtable.request_termination = requestTermination;
        return .{ .context = self, .vtable = vtable };
    }
};

/// The execution half, as far as one call needs it.
const Peer = struct {
    io: std.Io,
    dir: std.Io.Dir,
    slots: *pending.Table,
    sessions: *handle_table.Table(run_tools.HeldSession),
    answered: usize = 0,
    /// The frame kind the request arrived on. Recorded rather than assumed:
    /// the transport column is only a design claim until something reads
    /// which kind actually carried the call.
    arrived_on: ?frame.Kind = null,

    const limits: channel.MessageLimits = .{
        .event = 1 << 20,
        .request = 1 << 20,
        .response = 1 << 20,
        .ui_request = 1 << 16,
        .ui_response = 1 << 16,
    };

    fn run(self: *Peer) void {
        // Polls rather than assuming an order. The stub opens its
        // correlation before it submits, so a peer that acted on the first
        // live slot could close the channel under a request that had not
        // been written yet -- and the test would then be exercising the
        // closed-link path while claiming to exercise this one.
        var attempts: usize = 0;
        while (attempts < 10_000) : (attempts += 1) {
            if (self.tryOnce()) return;
        }
    }

    fn tryOnce(self: *Peer) bool {
        const file = self.dir.openFile(self.io, "link", .{}) catch return false;
        defer file.close(self.io);
        var buffer: [8192]u8 = undefined;
        var reader = file.readerStreaming(self.io, &buffer);

        var header_bytes: [frame.header_bytes]u8 = undefined;
        reader.interface.readSliceAll(&header_bytes) catch return false;
        const header = frame.decode(&header_bytes) catch return false;
        // Either kind can carry a call: `control` is the one that may
        // overtake fragments, and a dispatcher that only read `request`
        // frames would leave every Stop unanswered on a link that was
        // working.
        if (header.kind != .request and header.kind != .control) return false;
        if (!header.final) return false;

        const request_bytes = testing.allocator.alloc(u8, header.payload_len) catch return false;
        defer testing.allocator.free(request_bytes);
        reader.interface.readSliceAll(request_bytes) catch return false;

        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const request = dispatch.classify(request_bytes) catch return false;
        const response = dispatch.invoke(arena, self.bindings(), request) catch return false;

        // Owned by the table's allocator, because `claim` frees it there.
        const owned = self.slots.allocator.alloc(u8, response.len) catch return false;
        @memcpy(owned, response);
        self.slots.deposit(header.correlation, owned);
        self.answered += 1;
        self.arrived_on = header.kind;
        return true;
    }

    fn bindings(self: *Peer) adapters.Bindings {
        return .{
            .allocator = testing.allocator,
            .runtime = port.RuntimePort.quiet,
            .store = call_frame.BlobStore.empty,
            .sessions = self.sessions,
            .runs = undefined,
            .leases = undefined,
            .skill_restore = undefined,
            .session_restore = undefined,
            .selections = undefined,
        };
    }
};

test "a call through the port Product already uses reaches a real Session" {
    const io = testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "link", .{ .read = true, .truncate = true });
    defer file.close(io);

    // The caller's half.
    var queue: channel.Outbound = undefined;
    try queue.start(io, testing.allocator, file, .{});
    defer queue.stop();
    var slots: pending.Table = undefined;
    try slots.init(io, testing.allocator, 4);
    defer slots.deinit();
    const half = try testing.allocator.create(client.Client);
    defer testing.allocator.destroy(half);
    try half.init(testing.allocator, &queue, &slots, vtables, 4);
    defer half.deinit();

    // The execution half: a Session in a real table.
    var sessions = try handle_table.Table(run_tools.HeldSession).init(testing.allocator, 2);
    defer sessions.deinit();
    var recorder: Recorder = .{};
    var session_vtable: port.SessionPort.VTable = undefined;
    var held = run_tools.HeldSession.init(recorder.sessionPortFor(&session_vtable));
    const id = try sessions.insert(&held);

    // The handle, named over here.
    const box = try half.boxes.open(id);
    const session: port.SessionPort = .{ .context = box, .vtable = half.vtables.session };

    var peer: Peer = .{ .io = io, .dir = tmp.dir, .slots = &slots, .sessions = &sessions };
    var thread = try std.Thread.spawn(.{}, Peer.run, .{&peer});

    // Product's own call, unchanged: this is the whole point of the boundary.
    try session.setModel("a-model");
    thread.join();

    try testing.expectEqual(@as(usize, 1), peer.answered);
    try testing.expectEqual(@as(usize, 1), recorder.calls);
    try testing.expectEqualStrings("a-model", recorder.told());

    // Nothing is owed afterwards: the correlation settled and the box is
    // still the box, because `set_model` names no new handle.
    try testing.expectEqual(@as(usize, 0), slots.liveCount());
    try testing.expectEqual(@as(usize, 1), half.boxes.liveCount());
    try testing.expectEqual(frame.Kind.request, peer.arrived_on.?);
    _ = sessions.take(id);
}

test "capacity is never answered as a gone link" {
    // The one `catch return gone` this replaces gave all seven of these the
    // same answer. Named one by one, because the harm is specific: a compact
    // cancellation refused for queue capacity, reported as unreachable,
    // makes `runtime.zig` call the compact closing and stop following a
    // compact that is still running.
    try testing.expectEqual(Reason.no_room, stoppedBy(error.Busy));
    try testing.expectEqual(Reason.no_room, stoppedBy(error.BoxCapacity));
    try testing.expectEqual(Reason.no_room, stoppedBy(error.OutOfMemory));

    try testing.expectEqual(Reason.gone, stoppedBy(error.Unreachable));
    try testing.expectEqual(Reason.gone, stoppedBy(error.Unreadable));
    try testing.expectEqual(Reason.gone, stoppedBy(error.UnknownHandle));
    try testing.expectEqual(Reason.gone, stoppedBy(error.UnknownBox));

    // Every member is accounted for above. The switch in `stoppedBy` is
    // exhaustive, so this is about the *list here* staying complete: a new
    // way for a call to stop would otherwise be classified in code and
    // unexamined in the suite.
    try testing.expectEqual(@as(usize, 7), @typeInfo(Stopped).error_set.?.len);
}

test "a Stop travels on the transport it is registered with" {
    // The transport column exists so a Stop can overtake queued fragments.
    // Until this test, every call went out as a `request` whatever the
    // registry said -- so what is under test is not that the Session was
    // reached but *which frame kind* reached it.
    const io = testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "link", .{ .read = true, .truncate = true });
    defer file.close(io);

    var queue: channel.Outbound = undefined;
    try queue.start(io, testing.allocator, file, .{});
    defer queue.stop();
    var slots: pending.Table = undefined;
    try slots.init(io, testing.allocator, 4);
    defer slots.deinit();
    const half = try testing.allocator.create(client.Client);
    defer testing.allocator.destroy(half);
    try half.init(testing.allocator, &queue, &slots, vtables, 4);
    defer half.deinit();

    var sessions = try handle_table.Table(run_tools.HeldSession).init(testing.allocator, 2);
    defer sessions.deinit();
    var recorder: Recorder = .{};
    var session_vtable: port.SessionPort.VTable = undefined;
    var held = run_tools.HeldSession.init(recorder.sessionPortFor(&session_vtable));
    const id = try sessions.insert(&held);

    const box = try half.boxes.open(id);
    const session: port.SessionPort = .{ .context = box, .vtable = half.vtables.session };

    var peer: Peer = .{ .io = io, .dir = tmp.dir, .slots = &slots, .sessions = &sessions };
    var thread = try std.Thread.spawn(.{}, Peer.run, .{&peer});

    try session.requestTermination(7, .{ .interrupted = .user_cancel });
    thread.join();

    try testing.expectEqual(frame.Kind.control, peer.arrived_on.?);
    try testing.expectEqual(@as(u64, 7), recorder.stopped_run.?);
    try testing.expectEqual(
        session_control.ExternalInterruption.user_cancel,
        recorder.stopped_with.?.interrupted,
    );
    try testing.expectEqual(@as(usize, 0), slots.liveCount());
    _ = sessions.take(id);
}

test "every control-transport request fits the one frame it is allowed" {
    // The comptime block in `wire_types.zig` already failed the build if not.
    // This records that the set is not empty, because a check over an empty
    // set passes for the wrong reason.
    comptime var controls: usize = 0;
    inline for (method.entries) |entry| {
        if (entry.transport != .control) continue;
        controls += 1;
        switch (entry.owner) {
            inline else => |tag| {
                const Fn = @typeInfo(@FieldType(tag.VTable(), entry.name)).pointer.child;
                const bound = comptime payload.maxEncodedSize(wire_types.Request(Fn)).?;
                try testing.expect(bound <= frame.max_fragment_payload_bytes);
            },
        }
    }
    try testing.expectEqual(@as(usize, 4), controls);
}

test "a method the far side refuses comes back as that method's own error" {
    const io = testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "link", .{ .read = true, .truncate = true });
    defer file.close(io);

    var queue: channel.Outbound = undefined;
    try queue.start(io, testing.allocator, file, .{});
    defer queue.stop();
    var slots: pending.Table = undefined;
    try slots.init(io, testing.allocator, 4);
    defer slots.deinit();
    const half = try testing.allocator.create(client.Client);
    defer testing.allocator.destroy(half);
    try half.init(testing.allocator, &queue, &slots, vtables, 4);
    defer half.deinit();

    var sessions = try handle_table.Table(run_tools.HeldSession).init(testing.allocator, 2);
    defer sessions.deinit();
    var recorder: Recorder = .{};
    var session_vtable: port.SessionPort.VTable = undefined;
    var held = run_tools.HeldSession.init(recorder.sessionPortFor(&session_vtable));
    const id = try sessions.insert(&held);
    const box = try half.boxes.open(id);
    const session: port.SessionPort = .{ .context = box, .vtable = half.vtables.session };

    var peer: Peer = .{ .io = io, .dir = tmp.dir, .slots = &slots, .sessions = &sessions };
    var thread = try std.Thread.spawn(.{}, Peer.run, .{&peer});

    // Longer than the recorder will take, so the Session itself refuses --
    // and what comes back has to be that refusal and not a link failure,
    // which is the split `client.Failure` exists to keep.
    const too_long = "m" ** 100;
    try testing.expectError(error.CoreCallFailed, session.setModel(too_long));
    thread.join();

    // The peer did answer: without that the stub would have returned
    // `DependencyUnreachable`, so the error arriving is also the proof that
    // the far side was reached and said no.
    try testing.expectEqual(@as(usize, 1), peer.answered);
    try testing.expectEqual(@as(usize, 0), recorder.calls);
    try testing.expectEqual(@as(usize, 0), slots.liveCount());
    _ = sessions.take(id);
}

test "all four vtables are filled, with a real function behind every field" {
    // This test is also what makes the stubs above get compiled at all. Zig
    // analyses a referenced file's declarations lazily, so fifty-four `pub
    // const` vtables that nothing reads are fifty-four signatures nobody
    // checked -- the same trap as a test file that is never listed in a test
    // root, where the suite reports green because nothing ran. Taking the
    // address of each field is what forces the analysis.
    inline for (comptime std.enums.values(method.Owner)) |owner| {
        const table = switch (owner) {
            .session => vtables.session,
            .run => vtables.run,
            .run_control => vtables.run_control,
            .runtime => vtables.runtime,
        };
        inline for (@typeInfo(@TypeOf(table.*)).@"struct".fields) |field| {
            try testing.expect(@intFromPtr(@field(table, field.name)) != 0);
        }
    }

    // And every registered method is one of those fields, counted rather
    // than assumed: a method added to a vtable without a stub does not
    // compile, and a stub for a method nobody registered has nowhere to go.
    comptime var fields: usize = 0;
    inline for (comptime std.enums.values(method.Owner)) |owner| {
        fields += @typeInfo(owner.VTable()).@"struct".fields.len;
    }
    try testing.expectEqual(method.entries.len, fields);
    try testing.expectEqual(@as(usize, 54), fields);
}

test "the two entry points partition the surface, and neither can take the other's method" {
    @setEvalBranchQuota(10_000_000);
    // What this is checking is that every callable method has exactly one
    // way to be written: `forward` where the return type decides, and
    // `forwardAnswering` where someone had to. A method in neither group
    // would be a method whose stub cannot be written at all, and a method in
    // both would be a method whose answer could come from either place.
    comptime var derived: usize = 0;
    comptime var chosen: usize = 0;
    inline for (comptime method.entries) |entry| {
        if (entry.transport == .stream) continue;
        switch (entry.owner) {
            inline else => |owner| {
                if (comptime derivedAnswer(owner, entry.name) != null) derived += 1 else chosen += 1;
            },
        }
    }
    try testing.expectEqual(@as(usize, 50), derived + chosen);

    // And every method in the "chosen" group is one something already
    // accounts for: an exemption, the one pending entry, or a union that
    // names an arm without naming what fills it. A method that needed a
    // chosen answer and appeared in none of those would be an answer nobody
    // had argued for, which is the whole thing these registries exist to
    // prevent.
    comptime var accounted: usize = 0;
    inline for (comptime method.entries) |entry| {
        if (entry.transport == .stream) continue;
        switch (entry.owner) {
            inline else => |owner| {
                if (comptime derivedAnswer(owner, entry.name) != null) continue;
                const R = Returns(owner, entry.name);
                const tag_only = comptime unreachability.declaresAnswer(R) and
                    @TypeOf(@field(R, unreachability.answer_decl)) != R;
                if (comptime tag_only or named(owner, entry.name)) {
                    accounted += 1;
                } else {
                    @compileError(@tagName(owner) ++ "." ++ entry.name ++
                        " needs a chosen answer for a gone link and nothing accounts for " ++
                        "it: add an exemption or a pending entry in " ++
                        "src/agent/link/unreachability.zig saying which side absence " ++
                        "lands on and why");
                }
            },
        }
    }
    try testing.expectEqual(chosen, accounted);
}

/// Whether `unreachability.zig` already says something about this method.
fn named(comptime owner: method.Owner, comptime name: []const u8) bool {
    for (unreachability.exemptions) |entry| {
        if (entry.owner == owner and std.mem.eql(u8, entry.name, name)) return true;
    }
    for (unreachability.pending) |entry| {
        if (entry.owner == owner and std.mem.eql(u8, entry.name, name)) return true;
    }
    return false;
}

test "an error set with no member for a gone link is not given one by force" {
    // `port.CompactCancellation` gained a member because its switch is
    // exhaustive on purpose; this is the check that the stub reads the set
    // rather than assuming every error union can carry the error.
    const Cancel = Returns(.session, "request_compact_cancellation");
    try testing.expect(hasMember(@typeInfo(Cancel).error_union.error_set, "DependencyUnreachable"));
    try testing.expect(derivedAnswer(.session, "request_compact_cancellation") != null);

    // And `surface.Error` has it for the same reason, which is why every
    // other error-union method derives its answer.
    try testing.expect(hasMember(surface.Error, "DependencyUnreachable"));
}

test "a declared answer is taken from the type, not written beside it" {
    // `RestoreAdmission` names a whole value, so the stub does not get to
    // choose: a second answer written next to the declaration is exactly the
    // drift the declaration exists to prevent.
    const admission = derivedAnswer(.runtime, "restore_admission").?;
    try testing.expectEqual(port.RuntimePort.RestoreAdmission.link_unreachable, admission);

    // `CloseOutcome` names an arm instead. Naming the arm is not naming the
    // value, so it is the other group's.
    try testing.expect(derivedAnswer(.session, "close_outcome") == null);
    try testing.expectEqual(
        std.meta.Tag(surface.CloseOutcome).failure,
        surface.CloseOutcome.link_unreachable,
    );
}

test "an answer outside the method's own set lands on the restricting side" {
    // The peer answering with an error this signature cannot express is the
    // peer not being this build. Returning the nearest member would name a
    // cause nobody established.
    // `request_compact_cancellation` is the narrow set, so it is where this
    // can be shown at all: `surface.Error` is broad enough to contain almost
    // anything the far side might answer.
    const gone: port.CompactCancellation!void = error.DependencyUnreachable;
    try testing.expectError(
        error.DependencyUnreachable,
        answered(.session, "request_compact_cancellation", gone, error.SessionPoisoned),
    );
    // One the set can express is its own answer, and not this layer's.
    try testing.expectError(
        error.SessionClosing,
        answered(.session, "request_compact_cancellation", gone, error.SessionClosing),
    );
}

test "how much of the surface this build answers end to end, counted across both halves" {
    @setEvalBranchQuota(10_000_000);
    comptime var callable: usize = 0;
    comptime var end_to_end: usize = 0;
    comptime var caller_gap: usize = 0;
    comptime var exec_gap: usize = 0;
    inline for (comptime method.entries) |entry| {
        if (entry.transport == .stream) continue;
        callable += 1;
        switch (entry.owner) {
            inline else => |owner| {
                const sends = comptime outbound.sendable(owner, entry.name);
                const reads = comptime inbound.readable(owner, entry.name);
                const dispatches = comptime dispatch.dispatchable(owner, entry.name);
                if (comptime sends and reads and dispatches) end_to_end += 1;
                if (comptime !(sends and reads)) caller_gap += 1;
                if (comptime !dispatches) exec_gap += 1;
            },
        }
    }

    // The number that matters, and the one I reported wrongly twice: how many
    // of the callable methods are end_to_end by *both* halves. "46" was the
    // caller's half counted on its own, which is a different thing and not a
    // claim about what works; and the sentence that used to stand here said
    // 37 while the assertion below said 38, because a prong fix moved the
    // measurement and not the prose. So the count stays in the assertions and
    // the prose stops repeating it.
    try testing.expectEqual(@as(usize, 50), callable);
    try testing.expectEqual(@as(usize, 38), end_to_end);
    try testing.expectEqual(not_forwarded.len, callable - end_to_end);

    // And the execution half is the binding constraint: every method the
    // caller's half cannot send or read is also one the execution half
    // cannot dispatch, so its own worklist is the longer one. Asserted
    // rather than observed, because if that stops being true the two lists
    // have diverged and the shorter one would start looking like the answer.
    try testing.expectEqual(exec_gap, callable - end_to_end);
    try testing.expect(caller_gap <= exec_gap);
    try testing.expectEqual(@as(usize, 38), comptime dispatch.dispatchableCount());
}

test "the list says how many of its entries belong to which half" {
    @setEvalBranchQuota(10_000_000);
    // Read off the list rather than written above it. The entry this
    // replaces said "the ten below" over nine of them, in the commit about a
    // hand-counted number -- so the number lives here, where it is computed.
    const exec_only = comptime execSideGaps();
    try testing.expect(exec_only > 0);
    try testing.expect(exec_only < not_forwarded.len);

    // The rest are ones this half cannot send or read either, which is the
    // only other way to be on the list.
    try testing.expectEqual(@as(usize, 12), not_forwarded.len);
    try testing.expectEqual(@as(usize, 9), exec_only);
    try testing.expectEqual(@as(usize, 3), not_forwarded.len - exec_only);
}
