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
