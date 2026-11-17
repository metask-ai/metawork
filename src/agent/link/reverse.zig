//! Calls that run from the execution half into the caller.
//!
//! There is exactly one, and it is registered here rather than left as a shape
//! each future case grows for itself. While there is one, the rules are cheap;
//! with five they would be five local decisions, each with a reason that
//! sounded fine at the time.
//!
//! The one is the MCP installation tool: it hands an install request to the
//! caller and reads the answer, because it has to tell the model whether the
//! request was accepted. Everything else either composes locally or was ruled
//! out from crossing.
//!
//! Two rules, and the second is the one that looked free in process.
//!
//! **A reverse call is answered by a caller-side thread that never blocks on a
//! forward call.** Otherwise a reachable deadlock: a driver blocked in
//! `execute` waits for a terminal, the execution half asks the caller to admit
//! an install, and the answer has to come from a caller thread -- if the only
//! thread that could produce it is itself blocked in a forward call, nothing
//! moves. A correlation-keyed response table fixes who may *receive* an
//! answer; it does not conjure a thread to *produce* one.
//!
//! **The execution half holds no lock across a reverse call.** In process the
//! installation tool takes the Session lock, re-validates the Run, submits and
//! releases -- holding the lock over a local call is nearly free, and makes the
//! check and the submit atomic. Across a process that becomes a lock held over
//! a round trip: the Session's lock duration becomes the caller's response
//! time, and every other operation needing that Session queues behind it.
//!
//! So the atomicity is reshaped rather than carried. The check travels with
//! the request -- the Run id and generation the execution half validated
//! against go in the payload, and the caller admits or refuses against its own
//! record, which is the side that owns the Run anyway. `requestCarriesGuard`
//! below is what keeps that from being dropped later.
//!
//! The answer vocabulary needs nothing new: the tool's result already has
//! `unavailable`, which is the fail-closed answer when the caller is not
//! there, and `busy`, which is "try later". That is the same split as the
//! pending table's two exhaustion failures.

const std = @import("std");
const contract = @import("agent_contract");
const payload = @import("payload.zig");
const wire_types = @import("wire_types.zig");
const channel = @import("channel.zig");
const pending = @import("pending.zig");

pub const Call = enum {
    /// Hand an install request to the caller and read whether it was admitted.
    mcp_installation,
};

/// What crosses from the execution half to the caller for one reverse call.
///
/// The guard fields are not decoration: they are the atomicity that used to be
/// a held lock. The caller admits against its own Run record using them, so
/// the execution half can validate, release its lock, and then call.
pub const McpInstallationRequest = struct {
    task_id: u64,
    /// The Run the execution half validated against before releasing its
    /// lock. The caller refuses a request whose Run has moved on.
    run_id: u64,
    /// Its generation, so a reused Run id cannot admit a stale request.
    generation: u64,
    /// The install request's own bytes. The original owns them through an
    /// allocator; only the bytes travel.
    request_json: []const u8,
};

pub const McpInstallationResponse = contract.McpInstallationResult;

pub fn Request(comptime call: Call) type {
    return switch (call) {
        .mcp_installation => McpInstallationRequest,
    };
}

pub fn Response(comptime call: Call) type {
    return switch (call) {
        .mcp_installation => McpInstallationResponse,
    };
}

/// Whether a reverse call's request carries the guard that replaces the held
/// lock. A reverse call without one would have to be answered while something
/// stays locked, which is the shape this file exists to prevent.
pub fn requestCarriesGuard(comptime call: Call) bool {
    const T = Request(call);
    return @hasField(T, "run_id") and @hasField(T, "generation");
}

comptime {
    @setEvalBranchQuota(100_000);
    for (std.enums.values(Call)) |call| switch (call) {
        inline else => |tag| {
            // Both directions must be carriable by the same codec as a forward
            // call: a reverse call is not a second protocol.
            payload.requireStructural(Request(tag));
            payload.requireStructural(wire_types.Wire(Response(tag)));
            if (!requestCarriesGuard(tag)) @compileError(
                "the reverse call " ++ @tagName(tag) ++ " does not carry the Run id and " ++
                    "generation its answer must be admitted against. Without them the " ++
                    "execution half would have to keep a lock held across the round trip; " ++
                    "see src/agent/link/reverse.zig",
            );
        },
    };
}

// ---------------------------------------------------------------------------
// Direction
// ---------------------------------------------------------------------------

/// Everything a forward call needs: a correlation to open, somewhere to send
/// under it, and somewhere the answer lands. Named as one type so that "can
/// this code make a forward call" becomes a question about types.
pub const Caller = struct {
    outbound: *channel.Outbound,
    pending: *pending.Table,
};

/// Whether a type can reach a `Caller`, directly or through its fields.
///
/// An opaque pointer counts as reaching one, because it might be one and
/// nothing can prove otherwise. That is deliberate: it is what stops a handler
/// from smuggling the forward capability through a type-erased context, which
/// is exactly how a rule like this normally gets around.
/// Type-erased capabilities that are not the link and cannot become it.
///
/// An opaque pointer otherwise counts as reaching a caller, because it might
/// be one and nothing can prove otherwise -- that is what stops a handler
/// smuggling the forward capability through a type-erased context. But the
/// platform's own erased capabilities would then poison every context that
/// holds one, and a handler legitimately needs them. They are exempt because
/// reaching the link requires the link's own types, which neither of these
/// can produce. Adding to this list is a decision, not a convenience.
const erased_exemptions = [_]type{ std.Io, std.mem.Allocator };

fn exempt(comptime T: type) bool {
    inline for (erased_exemptions) |Allowed| {
        if (T == Allowed) return true;
    }
    return false;
}

pub fn reachesForwardCaller(comptime T: type) bool {
    if (T == Caller) return true;
    if (exempt(T)) return false;
    return switch (@typeInfo(T)) {
        .optional => |info| reachesForwardCaller(info.child),
        .array => |info| reachesForwardCaller(info.child),
        .vector => |info| reachesForwardCaller(info.child),
        .pointer => |info| info.child == anyopaque or reachesForwardCaller(info.child),
        .@"struct" => |info| blk: {
            inline for (info.fields) |field| {
                if (reachesForwardCaller(field.type)) break :blk true;
            }
            break :blk false;
        },
        .@"union" => |info| blk: {
            inline for (info.fields) |field| {
                if (reachesForwardCaller(field.type)) break :blk true;
            }
            break :blk false;
        },
        // An opaque type's contents are unknown, so it could hold one.
        .@"opaque" => true,
        else => false,
    };
}

/// The handler for one reverse call, over a context the link can inspect.
///
/// The third rule, and the one that closes the loop. A forward call's handler
/// may nest a reverse call and wait: the installation tool does exactly that,
/// and it is safe because of the first rule -- the caller answers on a thread
/// that never blocks on a forward call. The reverse of that is not safe. If a
/// reverse handler started a forward call and waited, the chain would close:
/// the execution half waiting for an answer to its reverse call, the caller
/// waiting for an answer to its forward call, and both sides' exhaustion codes
/// saying the peer owes answers, with nothing naming the cycle.
///
/// So a reverse handler cannot be given the means. Its context must be a type
/// this module can look inside, and it must not reach a `Caller`. Stating it
/// now costs nothing, because no reverse handler exists yet; once some do,
/// enforcing it would mean auditing what each one calls.
pub fn Handler(comptime call: Call, comptime Context: type) type {
    comptime {
        if (reachesForwardCaller(Context)) @compileError(
            "a reverse call's handler cannot reach a forward caller: " ++ @typeName(Context) ++
                ". A handler that could call forward and wait closes a cross-process cycle " ++
                "that neither side's capacity failure would name. An opaque context counts, " ++
                "because it could hold one -- give the handler a type the link can inspect.",
        );
        return *const fn (*Context, Request(call)) Response(call);
    }
}

/// The answer when the caller cannot be reached at all. A reverse call must
/// have one, or the execution half would have to wait for a peer that is gone.
pub fn unreachableAnswer(comptime call: Call) Response(call) {
    return switch (call) {
        .mcp_installation => .unavailable,
    };
}

const testing = std.testing;

test "there is one reverse call, and adding another is a decision not a drift" {
    // The count is asserted so a second reverse call cannot appear without
    // this file changing, which is where the two rules live.
    try testing.expectEqual(@as(usize, 1), std.enums.values(Call).len);
}

test "every reverse call can answer that the caller is unreachable" {
    // The fail-closed answer has to exist in the vocabulary the tool already
    // has, or the execution half is left waiting on a peer that is gone. It
    // does, which is why this path needs no new result type.
    inline for (comptime std.enums.values(Call)) |call| {
        const answer = unreachableAnswer(call);
        switch (call) {
            .mcp_installation => try testing.expectEqual(
                contract.McpInstallationResult.unavailable,
                answer,
            ),
        }
    }
}

test "every reverse call carries the guard that replaces the held lock" {
    inline for (comptime std.enums.values(Call)) |call| {
        try testing.expect(requestCarriesGuard(call));
    }
}

test "the request carries the bytes but not their ownership" {
    // The original owns its JSON through an allocator; the wire carries the
    // bytes and the receiving side owns its own copy, as everywhere else.
    try testing.expectEqual([]const u8, @FieldType(McpInstallationRequest, "request_json"));
    try testing.expect(!@hasField(McpInstallationRequest, "allocator"));
}

test "a reverse handler cannot be handed the forward caller, however it is wrapped" {
    // The predicate the rule is built on, checked in both directions so the
    // rule is a property rather than a promise.
    const Plain = struct { task_id: u64, name: []const u8 };
    try testing.expect(!reachesForwardCaller(Plain));
    try testing.expect(!reachesForwardCaller(u64));
    try testing.expect(!reachesForwardCaller(McpInstallationRequest));

    // Directly.
    try testing.expect(reachesForwardCaller(Caller));
    try testing.expect(reachesForwardCaller(*Caller));
    try testing.expect(reachesForwardCaller(?*Caller));

    // One field down, and two.
    const Nested = struct { link: *Caller };
    const Deeper = struct { inner: Nested, count: u32 };
    try testing.expect(reachesForwardCaller(Nested));
    try testing.expect(reachesForwardCaller(Deeper));

    // Through a union, which is where a hand-audit would most likely miss it.
    const Either = union(enum) { nothing, link: Caller };
    try testing.expect(reachesForwardCaller(Either));

    // And type-erased, which is how a rule like this normally gets around.
    const Erased = struct { context: ?*anyopaque };
    try testing.expect(reachesForwardCaller(Erased));
}

test "the one registered reverse call has an inspectable handler" {
    // Compiles only because the context is a type the link can look inside
    // and it reaches no caller; a context that did would fail the build with
    // the reason, which is the point of putting the check in `Handler`.
    const Context = struct { task_id: u64 };
    const Expected = *const fn (*Context, McpInstallationRequest) McpInstallationResponse;
    try testing.expectEqual(Expected, Handler(.mcp_installation, Context));
}

test "the platform's own erased capabilities do not poison a handler context" {
    // Without the exemption, any context holding an `std.Io` would be refused,
    // because `Io` carries an opaque userdata pointer. A handler needs one, and
    // neither it nor an allocator can reach the link: doing that takes the
    // link's own types.
    const WithIo = struct { io: std.Io, task_id: u64 };
    const WithAllocator = struct { allocator: std.mem.Allocator };
    try testing.expect(!reachesForwardCaller(WithIo));
    try testing.expect(!reachesForwardCaller(WithAllocator));
    // The exemption is narrow: an arbitrary erased pointer is still refused.
    const WithErased = struct { io: std.Io, smuggled: *anyopaque };
    try testing.expect(reachesForwardCaller(WithErased));
}
