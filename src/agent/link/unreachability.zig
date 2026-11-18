//! Every port method's answer must be able to say that the link is gone.
//!
//! The rule, and it is the whole file:
//!
//! **A port method that can fail must have a return type that can express
//! "the link is unreachable", and absence must land on the restricting side.
//! Where the existing type's default lands on the permitting side, the type
//! changes, so the compiler makes every call site say which side it chose.**
//!
//! The precedent is this repository's own. `control.InputSubmission` has
//! `unknown`, with the comment *"A dependency contract failure cannot be
//! reported as a refusal."* In process that case is nearly unreachable, so
//! only the one method that could hit it carries the answer. Across a process
//! it is reachable from every method, and this file is that one comment
//! generalised to the whole surface.
//!
//! ## What the guard can check, and what it cannot
//!
//! It checks the half that is a property of the type: can the answer be said
//! at all, and is the call site forced to receive it.
//!
//! - An error union forces every call site to handle a failure.
//! - An optional forces every call site to say what absence means.
//! - An enum or union qualifies only when the type itself declares which of
//!   its variants is the answer, as `link_unreachable`. That is a property
//!   the type states, not a spelling this file pattern-matches, and a stub
//!   has one place to read it from.
//!
//! It cannot check *which side* a call site then chose: that is a judgement
//! per call site, and the only thing forcing it is the compiler having
//! demanded an answer at all. Two consequences worth stating rather than
//! discovering later:
//!
//! - An error union counts as expressible even though its error set may not
//!   yet have a member that names a gone link. Which error names it belongs
//!   to `error_code.zig`, not here.
//! - A comparison is not a switch. `if (result == .stale_run)` keeps
//!   compiling when a variant is added, so a new answer can land nowhere.
//!   Two sites in the surface this change touches compare that way, both of
//!   them panics, and neither is left to a comment: they ask
//!   `policy.publishedControlStale` and `policy.dispatchedControlStale`,
//!   which are exhaustive switches. A predicate that does one thing can
//!   afford the switch where the long function around the call site cannot,
//!   so the risk is not merely gathered in one place but checked there.
//!
//! ## The three exemption categories, and why each is load-bearing
//!
//! A method whose type cannot say it must be listed, with a reason, under one
//! of three categories. The category is the claim being made, so it is
//! checked: `already_total` and `restrictive_default` must name the call site
//! the claim is about, and `void_release` must not, because its claim is
//! about the return type alone.
//!
//! - `void_release` -- it returns nothing and its purpose is release. A
//!   failure to reach the far side is not a failure of the call: what was to
//!   be released is unreachable, which is what release wanted.
//! - `already_total` -- the consuming function is total and its answer for
//!   every other doubtful path is already the restricting one. Naming that
//!   function is the fact the exemption rests on.
//! - `restrictive_default` -- the existing default value is itself on the
//!   restricting side, so absence needs no new vocabulary.
//!
//! ## `pending` is the list of methods this rule still owes a change
//!
//! An entry here is not an exemption: it is a method whose default lands on
//! the permitting side and whose type therefore has to change. The table is
//! what the rule produces rather than what it assumes, and the end state of
//! this file is `pending.len == 0`.

const std = @import("std");
const contract = @import("agent_contract");
const method = @import("method.zig");

const port = contract.port;

/// The declaration an enum or union uses to name its own unreachable answer.
pub const answer_decl = "link_unreachable";

pub const Expressibility = enum {
    /// `error{...}!T`: a call site cannot ignore the failure.
    error_union,
    /// `?T`: a call site must say what absence means.
    optional,
    /// An enum or union that declares which variant is the answer.
    declared_answer,
};

fn canHaveDecls(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => true,
        else => false,
    };
}

/// Whether a type names its own unreachable answer, as a value of itself or
/// as one of its union tags.
pub fn declaresAnswer(comptime T: type) bool {
    // Both conditions are forced comptime: `@hasDecl` is only legal on a
    // container, so the guard has to be resolved before this branch is
    // analysed at all.
    if (comptime !canHaveDecls(T)) return false;
    if (comptime !@hasDecl(T, answer_decl)) return false;
    const Declared = @TypeOf(@field(T, answer_decl));
    if (Declared == T) return true;
    return switch (@typeInfo(T)) {
        .@"union" => |info| if (info.tag_type) |Tag| Declared == Tag else false,
        else => false,
    };
}

/// How a return type can carry "the link is gone", or `null` when it cannot.
pub fn expressibility(comptime T: type) ?Expressibility {
    return switch (@typeInfo(T)) {
        .error_union => .error_union,
        .optional => .optional,
        else => if (declaresAnswer(T)) .declared_answer else null,
    };
}

pub fn ReturnType(comptime owner: method.Owner, comptime name: []const u8) type {
    const Fn = @typeInfo(@FieldType(owner.VTable(), name)).pointer.child;
    return @typeInfo(Fn).@"fn".return_type.?;
}

pub const Category = enum {
    /// Returns nothing, and releases. An unreachable peer has nothing held.
    void_release,
    /// The consuming function is total and already answers restrictively.
    already_total,
    /// The existing default value is on the restricting side.
    restrictive_default,
};

pub const Exemption = struct {
    owner: method.Owner,
    name: []const u8,
    category: Category,
    /// The call site the category's claim is about. Required for
    /// `already_total` and `restrictive_default`; empty for `void_release`,
    /// whose claim is about the return type alone.
    consumer: []const u8 = "",
    reason: []const u8,
};

pub const exemptions = [_]Exemption{
    .{
        .owner = .run,
        .name = "execute",
        .category = .already_total,
        .consumer = "src/product/task/policy.zig classifyAgentTerminal",
        .reason = "A TerminalResult whose failure is dependency_contract already means the " ++
            "termination effect is unknown -- control.zig's terminationEffect returns " ++
            ".unknown on that branch before reading anything else. The consuming " ++
            "classifier is total and its catch-all is dependency_contract_failure, and " ++
            "every field a gone link makes unknowable is already optional, so the answer " ++
            "is a truthful one rather than an invented one.",
    },
    .{
        .owner = .run_control,
        .name = "try_retain",
        .category = .restrictive_default,
        .consumer = "src/agent/session/binding.zig tryRetain caller",
        .reason = "false is turned into `return null` by its caller. A link that cannot be " ++
            "reached has not retained anything, so false is the fact rather than a default.",
    },
    .{
        .owner = .run_control,
        .name = "release",
        .category = .void_release,
        .reason = "Releases a retained Run control block. With the peer gone there is no " ++
            "block to release, which is the state release was asking for.",
    },
    .{
        .owner = .session,
        .name = "retain_reference",
        .category = .restrictive_default,
        .consumer = "src/product/task/agent_session.zig Binding.attach",
        .reason = "false becomes error.SessionClosing at the one Product call site. A " ++
            "reference to a Session across a dead link is exactly what must not be handed " ++
            "out.",
    },
    .{
        .owner = .session,
        .name = "release_reference",
        .category = .void_release,
        .reason = "Drops a reference the execution half holds. If the half is gone the " ++
            "reference is gone with it.",
    },
    .{
        .owner = .session,
        .name = "stop_event_delivery",
        .category = .void_release,
        .reason = "Asks the execution half to stop delivering events. The link is what " ++
            "carried them, so a gone link has already stopped delivery.",
    },
    .{
        .owner = .session,
        .name = "skill_policy_matches",
        .category = .already_total,
        .consumer = "src/product/task/runtime.zig catalogBindingMatches",
        .reason = "Every other doubtful path in that function already returns false: Task " ++
            "not found, skills unavailable, no pinned catalog, revision mismatch, and a " ++
            "failed access acquisition. A false answer costs a catalog refresh; a true one " ++
            "would pin a policy nobody confirmed.",
    },
    .{
        .owner = .session,
        .name = "snapshot",
        .category = .already_total,
        .consumer = "src/product/task/agent_session.zig Access.sessionState",
        .reason = "The only Product consumer reads one field, .state, and all four of its " ++
            "downstreams put .poisoned on the restricting side: two approval-job " ++
            "dispositions, a checkpoint session_disposition, and credential renewal's " ++
            "error.SessionPoisoned. .poisoned is a value SessionState already has and is " ++
            "true of a Session whose link is gone, so the stub answers it and adds no " ++
            "vocabulary. A forwarding stub that answered anything else would break this " ++
            "exemption.",
    },
    .{
        .owner = .runtime,
        .name = "has_pending_events",
        .category = .restrictive_default,
        .consumer = "src/product/control/runtime.zig shutdownExecutor's barrier and " ++
            "drainAgentEvents' re-arm",
        .reason = "The fact this rests on is what the caller does next, and it is the line " ++
            "after the barrier: shutdownExecutor follows the loop with " ++
            "excludePendingConversationTailAfterShutdown, which marks a Run's pending " ++
            "coverage excluded. The shutdown path answers \"nothing pending\" by throwing " ++
            "the tail away, not by sealing it, so a false that is wrong costs nothing it " ++
            "was not already giving up. That is the whole difference from " ++
            "pending_event_count, where the same words make Product commit the tail as " ++
            "complete -- one sentence, opposite consequences, which is why one of them can " ++
            "be exempt and the other cannot. The other consumer only declines to re-arm " ++
            "the notifier, which is harmless. Liveness agrees but is not the reason: true " ++
            "would hang shutdown on an event that cannot arrive.",
    },
};

/// A method whose return type still cannot say it. Each entry says which side
/// absence lands on today, why no change of default fixes it, and which step
/// owes the change.
pub const Pending = struct {
    owner: method.Owner,
    name: []const u8,
    lands: []const u8,
    step: []const u8,
};

pub const pending = [_]Pending{
    .{
        .owner = .runtime,
        .name = "pending_event_count",
        .lands = "Zero reads as fully drained by both consumers of EventDrainStatus -- " ++
            "settleTerminalOutputAfterEventDrain and " ++
            "finalizeMarkedTerminalRunsAfterEventDrain in src/product/task/runtime.zig " ++
            "both skip a route whose pending count is non-zero and otherwise go on to " ++
            "seal the Run's final output. A truncated conversation is therefore committed " ++
            "as a complete one. That this method does not cross makes it worse rather " ++
            "than better: a call that crosses can fail, and its failure is visible, while " ++
            "a count computed from frames already in hand always succeeds and so cannot " ++
            "be told apart from a real drain by construction. Its fix is not this rule's " ++
            "usual one either. The pump knows how many frames it holds, so \"I cannot " ++
            "tell\" is never its honest answer and an optional would add a branch nobody " ++
            "takes while leaving zero-is-not-end-of-stream exactly where it is. What is " ++
            "missing is a second proposition -- the stream has ended -- stated by the side " ++
            "that can know it, with those two call sites gated on that instead of on a " ++
            "count reaching zero.",
        .step = "disconnect closure",
    },
};

/// Whether the registry still carries this method, so a table entry cannot
/// outlive the method it describes.
fn isRegistered(comptime owner: method.Owner, comptime name: []const u8) bool {
    inline for (method.entries) |entry| {
        if (entry.owner == owner and comptime std.mem.eql(u8, entry.name, name)) return true;
    }
    return false;
}

fn exemptionFor(comptime owner: method.Owner, comptime name: []const u8) ?Exemption {
    inline for (exemptions) |entry| {
        if (entry.owner == owner and comptime std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

fn pendingFor(comptime owner: method.Owner, comptime name: []const u8) ?Pending {
    inline for (pending) |entry| {
        if (entry.owner == owner and comptime std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

// Every method is expressible, exempt, or pending -- exactly one of them.
comptime {
    @setEvalBranchQuota(1_000_000);
    for (method.entries) |entry| {
        const described = "the port method " ++ @tagName(entry.owner) ++ "." ++ entry.name;
        const Return = switch (entry.owner) {
            inline else => |tag| ReturnType(tag, entry.name),
        };
        const expressible = expressibility(Return) != null;
        const listed = exemptionFor(entry.owner, entry.name);
        const owed = pendingFor(entry.owner, entry.name);

        if (listed != null and owed != null) @compileError(
            described ++ " is both exempt and pending; it is one or the other",
        );
        if (expressible) {
            if (listed != null or owed != null) @compileError(
                described ++ " can already express an unreachable link, so remove its " ++
                    "listing from src/agent/link/unreachability.zig: a table entry that " ++
                    "outlives its reason is how the next person learns the wrong rule",
            );
        } else if (listed == null and owed == null) @compileError(
            described ++ " returns " ++ @typeName(Return) ++ ", which cannot say that the " ++
                "link is gone. Either give it a return type that can -- an optional, an " ++
                "error union, or an enum or union declaring `" ++ answer_decl ++ "` -- or " ++
                "list it in src/agent/link/unreachability.zig under one of the three " ++
                "categories with the reason. A method that cannot report its own failure " ++
                "makes every caller guess, and across a process the guess is wrong.",
        );
    }
}

// Every listing names a method that still exists and still needs it.
comptime {
    @setEvalBranchQuota(1_000_000);
    for (exemptions, 0..) |entry, index| {
        if (!isRegistered(entry.owner, entry.name)) @compileError(
            "src/agent/link/unreachability.zig exempts " ++ @tagName(entry.owner) ++ "." ++
                entry.name ++ ", which is not a registered method",
        );
        if (entry.reason.len < 40) @compileError(
            "the exemption for " ++ entry.name ++ " needs a reason, not a label",
        );
        switch (entry.category) {
            .void_release => if (entry.consumer.len != 0) @compileError(
                "the exemption for " ++ entry.name ++ " is void_release, whose claim is " ++
                    "about the return type alone, yet it names a consumer. Either the " ++
                    "category or the claim is wrong",
            ),
            .already_total, .restrictive_default => if (entry.consumer.len == 0) @compileError(
                "the exemption for " ++ entry.name ++ " claims something about a call " ++
                    "site without naming it. That name is the fact the exemption rests " ++
                    "on; without it the entry cannot be rechecked",
            ),
        }
        for (exemptions[index + 1 ..]) |other| {
            if (other.owner == entry.owner and std.mem.eql(u8, other.name, entry.name))
                @compileError("duplicate exemption for " ++ entry.name);
        }
    }
    for (pending, 0..) |entry, index| {
        if (!isRegistered(entry.owner, entry.name)) @compileError(
            "src/agent/link/unreachability.zig lists " ++ @tagName(entry.owner) ++ "." ++
                entry.name ++ " as pending, which is not a registered method",
        );
        if (entry.lands.len < 40 or entry.step.len == 0) @compileError(
            "the pending entry for " ++ entry.name ++ " must say which side absence lands " ++
                "on and which step owes the change",
        );
        for (pending[index + 1 ..]) |other| {
            if (other.owner == entry.owner and std.mem.eql(u8, other.name, entry.name))
                @compileError("duplicate pending entry for " ++ entry.name);
        }
    }
}

/// How many methods fall in each bucket, for a test to pin.
pub const Counts = struct {
    total: usize,
    expressible: usize,
    exempt: usize,
    owed: usize,
};

pub fn counts() Counts {
    @setEvalBranchQuota(1_000_000);
    var tally: Counts = .{ .total = 0, .expressible = 0, .exempt = 0, .owed = 0 };
    inline for (method.entries) |entry| {
        tally.total += 1;
        const Return = switch (entry.owner) {
            inline else => |tag| ReturnType(tag, entry.name),
        };
        if (comptime expressibility(Return) != null) {
            tally.expressible += 1;
        } else if (comptime exemptionFor(entry.owner, entry.name) != null) {
            tally.exempt += 1;
        } else {
            tally.owed += 1;
        }
    }
    return tally;
}

const testing = std.testing;

test "the surface divides into expressible, exempt and pending, with nothing left over" {
    const tally = comptime counts();
    try testing.expectEqual(method.entries.len, tally.total);
    try testing.expectEqual(
        tally.total,
        tally.expressible + tally.exempt + tally.owed,
    );
    try testing.expectEqual(exemptions.len, tally.exempt);
    try testing.expectEqual(pending.len, tally.owed);
    // The numbers themselves, so a method moving between buckets is visible
    // in the suite and not only in a build that happened to succeed.
    try testing.expectEqual(@as(usize, 54), tally.total);
    try testing.expectEqual(@as(usize, 44), tally.expressible);
    try testing.expectEqual(@as(usize, 9), tally.exempt);
    try testing.expectEqual(@as(usize, 1), tally.owed);
}

test "the pending list is the rule's output, named one by one" {
    // Written out rather than counted: this is the list the change works
    // from, and it is down to the one entry this step does not own.
    // `input_observation` and `borrow_skill_restore_inputs` left it as
    // optionals and `request_termination` by naming its own answer, which is
    // what put the choice at each of their call sites.
    const expected = [_][]const u8{
        "pending_event_count",
    };
    try testing.expectEqual(expected.len, pending.len);
    for (pending, expected) |entry, name| try testing.expectEqualStrings(name, entry.name);

    // Nothing is owed by this step any more: the one entry left is deferred
    // to the step that owns the event stream's end, and `pending.len == 0` is
    // reached when that step states it.
    for (pending) |entry| try testing.expect(!std.mem.eql(u8, entry.step, "this change"));
}

test "each way of expressing it is recognised, and nothing else is" {
    // The three admitted forms.
    try testing.expectEqual(
        Expressibility.error_union,
        expressibility(contract.surface.Error!void).?,
    );
    try testing.expectEqual(Expressibility.optional, expressibility(?u64).?);
    try testing.expectEqual(
        Expressibility.declared_answer,
        expressibility(contract.control.InputSubmission).?,
    );
    try testing.expectEqual(
        Expressibility.declared_answer,
        expressibility(contract.control.EventReadyNotification).?,
    );
    try testing.expectEqual(
        Expressibility.declared_answer,
        expressibility(port.RuntimePort.RestoreAdmission).?,
    );
    try testing.expectEqual(
        Expressibility.declared_answer,
        expressibility(port.BeginRunOutcome).?,
    );
    try testing.expectEqual(
        Expressibility.declared_answer,
        expressibility(contract.surface.CloseOutcome).?,
    );

    // And the forms that cannot say it, which is the half that matters.
    try testing.expect(expressibility(void) == null);
    try testing.expect(expressibility(bool) == null);
    try testing.expect(expressibility(usize) == null);
    try testing.expect(expressibility(contract.control.InputObservation) == null);
    // ... and it is now returned as `?InputObservation`, which is why the
    // method no longer appears above.
    try testing.expectEqual(
        Expressibility.optional,
        expressibility(ReturnType(.run_control, "input_observation")).?,
    );
    try testing.expectEqual(
        Expressibility.declared_answer,
        expressibility(contract.control.TerminationRequestResult).?,
    );
    try testing.expect(expressibility(port.SkillRestoreBorrow) == null);
    try testing.expectEqual(
        Expressibility.optional,
        expressibility(ReturnType(.runtime, "borrow_skill_restore_inputs")).?,
    );
}

test "an enum that merely has a plausible variant does not qualify" {
    // The check is the declaration, not the spelling. Without it, a rename or
    // a variant that only looks like the answer would pass.
    const Looks = enum { fine, unavailable, unknown };
    try testing.expect(expressibility(Looks) == null);
    const Says = enum {
        fine,
        gone,
        pub const link_unreachable: @This() = .gone;
    };
    try testing.expectEqual(Expressibility.declared_answer, expressibility(Says).?);

    // A declaration of the wrong type does not qualify either: it has to name
    // a value of the type or one of its tags.
    const Mistyped = enum {
        fine,
        gone,
        pub const link_unreachable: u8 = 1;
    };
    try testing.expect(expressibility(Mistyped) == null);
}

test "a union may name its answer by tag" {
    const Either = union(enum) {
        value: u32,
        failure,
        pub const link_unreachable: std.meta.Tag(@This()) = .failure;
    };
    try testing.expectEqual(Expressibility.declared_answer, expressibility(Either).?);
    try testing.expectEqual(
        std.meta.Tag(contract.surface.CloseOutcome).failure,
        contract.surface.CloseOutcome.link_unreachable,
    );
    try testing.expectEqual(
        std.meta.Tag(contract.control.InputSubmission).unknown,
        contract.control.InputSubmission.link_unreachable,
    );
}

test "every exemption's category matches what it claims" {
    // The comptime block above fails the build otherwise; this records the
    // division so a category change is visible in the suite.
    var by_category: [3]usize = @splat(0);
    for (exemptions) |entry| by_category[@intFromEnum(entry.category)] += 1;
    try testing.expectEqual(@as(usize, 3), by_category[@intFromEnum(Category.void_release)]);
    try testing.expectEqual(@as(usize, 3), by_category[@intFromEnum(Category.already_total)]);
    try testing.expectEqual(
        @as(usize, 3),
        by_category[@intFromEnum(Category.restrictive_default)],
    );
    for (exemptions) |entry| {
        try testing.expect(entry.reason.len >= 40);
        switch (entry.category) {
            .void_release => try testing.expectEqual(@as(usize, 0), entry.consumer.len),
            .already_total, .restrictive_default => try testing.expect(entry.consumer.len > 0),
        }
    }
}
