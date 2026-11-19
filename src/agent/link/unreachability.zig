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
//! - An error union counts as expressible because the call site is forced to
//!   handle a failure. *Which* error names a gone link was left to
//!   `error_code.zig`, and it now has an answer: `DependencyUnreachable`,
//!   added because no other member means it. Reusing one would assert
//!   something false -- `SessionClosing` that the Session is winding down,
//!   `CoreCallFailed` that Core was reached -- and a caller acting on either
//!   would act on a fact nobody established.
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

// ---------------------------------------------------------------------------
// The second fact: not performed, and worth asking again
// ---------------------------------------------------------------------------
//
// "The link is gone" and "the link is busy" are two facts, and the whole
// point of separating them is that they call for opposite behaviour: gone
// means stop asking, busy means ask again. A caller told the wrong one acts
// correctly on something nobody established -- and this one has a worked
// example. `runtime.zig` maps a compact cancellation's
// `DependencyUnreachable` onto `.session_closing`, so Product stops
// following that compact. If a cancellation refused for queue capacity were
// reported as unreachable, Product would stop following a compact that is
// still running. That is a wrong answer shaped exactly like a right one,
// which is the failure class this whole boundary exists to remove.
//
// So the rule is the sibling of the one above: **a method that can be refused
// for capacity must have a return type that can say so.** The vocabulary is
// the same shape -- an error-set member for an error union, a declared
// variant for an enum or union -- and nothing in the surface has either yet.
// That is why `pressureCounts().owed` is currently every callable method: the
// table is what the rule produces, not what it assumes, and the number falls
// on its own as the contract gains the vocabulary rather than by anyone
// editing a list.
//
// One asymmetry is worth stating rather than discovering. An optional counts
// as expressible for *gone*, because a call site is forced to say what
// absence means. It does not count here: absence already means gone for those
// methods, and one absence cannot carry two facts that call for opposite
// behaviour. A method whose answer is `?T` therefore needs a different return
// type to say "not now", not a second reading of `null`.

/// The declaration an enum or union uses to name its own backpressure answer.
pub const pressure_decl = "link_busy";

/// The error-set member an error union uses for the same.
pub const pressure_error = "LinkBusy";

fn errorSetHas(comptime Set: type, comptime wanted: []const u8) bool {
    @setEvalBranchQuota(100_000);
    const members = @typeInfo(Set).error_set orelse return false; // `anyerror`
    for (members) |member| {
        if (std.mem.eql(u8, member.name, wanted)) return true;
    }
    return false;
}

/// Whether a return type can say "this call was not performed and asking
/// again is worth something", as distinct from saying the far side is gone.
pub fn saysPressure(comptime T: type) bool {
    // Each guard is forced comptime for the same reason `declaresAnswer`
    // does it: `@hasDecl` is only legal on a container, so the branch has to
    // be resolved before this one is analysed at all. A `comptime { ... }`
    // body would not do -- a `return` inside one breaks at runtime call
    // sites.
    if (comptime @typeInfo(T) == .error_union)
        return errorSetHas(@typeInfo(T).error_union.error_set, pressure_error);
    if (comptime !canHaveDecls(T)) return false;
    if (comptime !@hasDecl(T, pressure_decl)) return false;
    const Declared = @TypeOf(@field(T, pressure_decl));
    if (Declared == T) return true;
    return switch (@typeInfo(T)) {
        .@"union" => |info| if (info.tag_type) |Tag| Declared == Tag else false,
        else => false,
    };
}

/// Which claim a pressure exemption is making.
///
/// Two categories, not the three the gone rule has, and the missing one is
/// the point: there is no `void_release` here. That category's claim is that
/// an unreachable peer has already dropped what was to be released -- true
/// of a peer that is gone, false of a send the link itself refused: the peer
/// is still there holding it. A release refused for capacity leaves the
/// nothing on this side able to name it again, so the three `void_release`
/// methods are *pending* below rather than exempt here.
pub const PressureCategory = enum {
    /// The consuming function is total and its answer for every other
    /// doubtful path is already the restricting one.
    already_total,
    /// The value absence or `false` already carries is true of a busy link
    /// too, and the action it leads to is the acceptable one.
    restrictive_default,
};

pub const PressureExemption = struct {
    owner: method.Owner,
    name: []const u8,
    category: PressureCategory,
    /// The call site -- or sites -- the claim is about. Always required here:
    /// both categories make a claim about what the caller does next.
    consumer: []const u8,
    reason: []const u8,
};

/// A method whose type cannot say "no room" and does not need to, because the
/// answer it already gives is true of a busy link as well.
///
/// Every entry claims the same two things and both are checkable: the value
/// is *true* of a call the link refused before sending it, and the consumer's
/// action on it is one a caller would accept for a transient refusal. What no
/// entry claims is that the caller can tell busy from gone -- it cannot, and
/// the cost is diagnostic. The gone side already pays exactly that cost for
/// the same methods, which is why accepting it twice is consistent rather
/// than new.
pub const pressure_exemptions = [_]PressureExemption{
    .{
        .owner = .run_control,
        .name = "try_retain",
        .category = .restrictive_default,
        .consumer = "src/agent/session/binding.zig tryRetain caller",
        .reason = "false says the lease was not retained, which is as true of a refusal " ++
            "for capacity as it is of a gone link -- nothing was retained either way. " ++
            "The caller turns false into `return null`, and whoever wanted the lease " ++
            "asks again when it next needs one.",
    },
    .{
        .owner = .session,
        .name = "skill_policy_matches",
        .category = .already_total,
        .consumer = "src/product/task/runtime.zig catalogBindingMatches",
        .reason = "false costs a catalog refresh, and that refresh crosses the link " ++
            "through `Allocating!void`, which now carries LinkBusy. So a busy link " ++
            "spends a refresh instead of pinning a policy nobody confirmed, and the " ++
            "refusal is reported honestly by the next call rather than hidden in this " ++
            "one.",
    },
    .{
        .owner = .run_control,
        .name = "input_observation",
        .category = .restrictive_default,
        .consumer = "src/product/task/runtime.zig inputAction (.wait), submitInputImpl " ++
            "(error.RunNotReady), inputBlocksAutomaticAllow (true, blocks automatic " ++
            "approval), and src/product/task/view.zig inputReady (false, offers no " ++
            "input box)",
        .reason = "All four already answer that way for a lease they could not acquire " ++
            "one line above, and none of them asserts anything about the Run. Three are " ++
            "states that come round again on their own: `.wait` asks again by " ++
            "construction, the input box reappears when an observation succeeds, and " ++
            "blocking automatic approval is the conservative side of that question.",
    },
    .{
        .owner = .session,
        .name = "pending_ui_observation",
        .category = .restrictive_default,
        .consumer = "src/product/task/runtime.zig respondUi (error.NoPendingUiRequest), " ++
            "preparePermissionReview (null, no automatic approval), " ++
            "syncOperationRecords (projected as none)",
        .reason = "Nothing is committed on the absence: the user's answer is refused " ++
            "and can be given again, the automatic path declines to act, and the " ++
            "projection shows no parked request until one is observed. The request " ++
            "itself stays parked on the far side -- this read does not consume it -- so " ++
            "a later pass sees it.",
    },
    .{
        .owner = .session,
        .name = "permission_stop_request",
        .category = .restrictive_default,
        .consumer = "src/product/task/runtime.zig requestPermissionStops",
        .reason = "The sweep skips this Task and nothing is recorded, and the read does " ++
            "not consume the request on the far side, so the stop is delayed rather " ++
            "than dropped. Answering a run id nobody reported would terminate a Run on " ++
            "a permission stop that was never asked for.",
    },
    .{
        .owner = .runtime,
        .name = "borrow_skill_restore_inputs",
        .category = .restrictive_default,
        .consumer = "src/product/task/recovery_job.zig borrowRestoreSkills (.unavailable, which " ++
            "its own caller turns into a failed recovery attempt), " ++
            "src/product/task/runtime.zig sameRestoreFilters (false) and " ++
            "syncTaskRecovery (empty list, which the comment there says cannot be " ++
            "mistaken for an unchanged one)",
        .reason = "Every consumer treats a borrow it could not take as a capability it " ++
            "cannot vouch for, which is what a busy link leaves it with. The one that " ++
            "substitutes a list substitutes the empty one deliberately, and the " ++
            "comparison it feeds cannot read that as unchanged.",
    },
};

/// A method that can be refused for capacity and has no way to say so.
///
/// What happens today is not in the field below: it is `stubs.noRoom`, a
/// panic. `gone_answer_lands` says where the method's *gone* answer would
/// land if the panic were replaced by it, which is what makes each entry a
/// change still owed rather than a defect being tolerated -- the panic is
/// loud, and the answer it stands in for would not be.
pub const PressurePending = struct {
    owner: method.Owner,
    name: []const u8,
    gone_answer_lands: []const u8,
    step: []const u8,
};

pub const pressure_pending = [_]PressurePending{
    .{
        .owner = .session,
        .name = "retain_reference",
        .gone_answer_lands = "`false`, which `agent_session.Binding.acquireAccess` turns " ++
            "into error.SessionClosing -- and that is where this stopped being " ++
            "exemptible. Most of the twenty-odd consumers answer restrictively and " ++
            "harmlessly (TaskClosing, null, false, continue), but " ++
            "`recovery_job.zig` has two that call " ++
            "`rejectCandidate(.restore_rejected)`: a Session that was just restored " ++
            "successfully is thrown away because one `retain_reference` could not be " ++
            "sent. Destroying completed work over a refusal the link itself made is " ++
            "the same harm as `snapshot` poisoning a healthy Session, and the gone " ++
            "exemption does not cover it because a gone link really has no Session to " ++
            "keep. `bool` has no room for a refusal, so what is owed is a type that " ++
            "can say it.",
        .step = "retain refusal",
    },
    .{
        .owner = .run,
        .name = "execute",
        .gone_answer_lands = "The Run is failed rather than started: the chosen gone answer is a " ++
            "TerminalResult whose failure classifies as dependency_contract_failure, " ++
            "which is true -- nothing ran -- but it ends a Run that asking again would " ++
            "have begun. A vocabulary word is not the fix here. `execute` blocks until " ++
            "the Run reaches a terminal, so its caller is the executing thread rather " ++
            "than the UI's, and it is the one method that may legitimately *wait* for " ++
            "room (channel.Outbound.submitWaiting). Which thread calls it is " ++
            "`method.caller`, and this entry still says `unattributed`, so the waiting " ++
            "cannot be justified yet.",
        .step = "method.Caller attribution",
    },
    .{
        .owner = .run_control,
        .name = "release",
        .gone_answer_lands = "Nowhere. It returns void, so the refusal is invisible to the caller " ++
            "and the retained Run control block stays live on the far side with nothing " ++
            "on this side able to name it again. This is precisely where the gone " ++
            "rule's `void_release` stops carrying: that category rests on the peer " ++
            "having dropped what was to be released, which a peer the link never " ++
            "reached for has not.",
        .step = "release quota",
    },
    .{
        .owner = .session,
        .name = "release_reference",
        .gone_answer_lands = "Nowhere, and the Session reference stays held on the far side. Same " ++
            "reason as `run_control.release`: void cannot report a refusal, and a peer " ++
            "with no room has not dropped the thing being released.",
        .step = "release quota",
    },
    .{
        .owner = .session,
        .name = "stop_event_delivery",
        .gone_answer_lands = "Nowhere, and delivery continues. The gone exemption's fact is that " ++
            "the link is what carried the events, so losing it stops them; a link that " ++
            "is merely full still carries them, so the request has to arrive to have " ++
            "any effect at all.",
        .step = "release quota",
    },
    .{
        .owner = .session,
        .name = "snapshot",
        .gone_answer_lands = "`.poisoned`, through the chosen gone answer, and four Product " ++
            "downstreams act on it: two approval-job dispositions, a checkpoint " ++
            "session_disposition, and credential renewal's error.SessionPoisoned. The " ++
            "gone exemption rests on `.poisoned` being *true* of a Session whose link " ++
            "is gone. It is false of a Session whose link is merely full, so that " ++
            "argument does not carry and this answer poisons a healthy Session. " ++
            "SessionSnapshot is a plain struct with no arm for a refusal, so what is " ++
            "owed is a return type that can refuse, not a word in an existing one.",
        .step = "snapshot refusal",
    },
};

fn pressureExemptionFor(
    comptime owner: method.Owner,
    comptime name: []const u8,
) ?PressureExemption {
    inline for (pressure_exemptions) |entry| {
        if (entry.owner == owner and comptime std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

fn pressurePendingFor(
    comptime owner: method.Owner,
    comptime name: []const u8,
) ?PressurePending {
    inline for (pressure_pending) |entry| {
        if (entry.owner == owner and comptime std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

/// Whether this method's gone answer is also its busy answer, by a listed and
/// checked claim. `stubs.zig` reads this to decide whether it may answer at
/// all; without an entry it refuses loudly.
pub fn pressureExempt(comptime owner: method.Owner, comptime name: []const u8) bool {
    return pressureExemptionFor(owner, name) != null;
}

// Every callable method can say it, is exempt, or is pending -- exactly one.
comptime {
    @setEvalBranchQuota(1_000_000);
    for (method.entries) |entry| {
        const described = "the port method " ++ @tagName(entry.owner) ++ "." ++ entry.name;
        const listed = pressureExemptionFor(entry.owner, entry.name);
        const owed = pressurePendingFor(entry.owner, entry.name);
        if (entry.transport == .stream) {
            if (listed != null or owed != null) @compileError(
                described ++ " is answered from the caller's own pump, so capacity on " ++
                    "the send path cannot refuse it; remove its pressure listing",
            );
            continue;
        }
        const Return = switch (entry.owner) {
            inline else => |tag| ReturnType(tag, entry.name),
        };
        if (listed != null and owed != null) @compileError(
            described ++ " is both pressure-exempt and pressure-pending; it is one or " ++
                "the other",
        );
        if (saysPressure(Return)) {
            if (listed != null or owed != null) @compileError(
                described ++ " can already say it was refused for capacity, so remove " ++
                    "its pressure listing from src/agent/link/unreachability.zig",
            );
        } else if (listed == null and owed == null) @compileError(
            "call was not performed and can be made again. Either give it a type " ++
                "side was reached and had no room. Either give it a type that can -- an " ++
                "error union carrying `" ++ pressure_error ++ "`, or an enum or union " ++
                "declaring `" ++ pressure_decl ++ "` -- or list it in " ++
                "src/agent/link/unreachability.zig as pressure-exempt with the call site " ++
                "whose answer is true of a busy link, or as pressure-pending with what " ++
                "the refusal lands on today. Gone and busy call for opposite behaviour, " ++
                "so inheriting the gone answer without saying why is how a caller stops " ++
                "asking about work that is still running.",
        );
    }
}

// Every pressure listing names a method that still exists and still needs it.
comptime {
    @setEvalBranchQuota(1_000_000);
    for (pressure_exemptions, 0..) |entry, index| {
        if (!isRegistered(entry.owner, entry.name)) @compileError(
            "src/agent/link/unreachability.zig pressure-exempts " ++ @tagName(entry.owner) ++
                "." ++ entry.name ++ ", which is not a registered method",
        );
        if (entry.reason.len < 40 or entry.consumer.len == 0) @compileError(
            "the pressure exemption for " ++ entry.name ++ " must name the call site it " ++
                "claims something about, and give a reason rather than a label",
        );
        for (pressure_exemptions[index + 1 ..]) |other| {
            if (other.owner == entry.owner and std.mem.eql(u8, other.name, entry.name))
                @compileError("duplicate pressure exemption for " ++ entry.name);
        }
    }
    for (pressure_pending, 0..) |entry, index| {
        if (!isRegistered(entry.owner, entry.name)) @compileError(
            "src/agent/link/unreachability.zig lists " ++ @tagName(entry.owner) ++ "." ++
                entry.name ++ " as pressure-pending, which is not a registered method",
        );
        if (entry.gone_answer_lands.len < 40 or entry.step.len == 0) @compileError(
            "the pressure-pending entry for " ++ entry.name ++ " must say where the gone " ++
                "answer would land and which step owes the change",
        );
        for (pressure_pending[index + 1 ..]) |other| {
            if (other.owner == entry.owner and std.mem.eql(u8, other.name, entry.name))
                @compileError("duplicate pressure-pending entry for " ++ entry.name);
        }
    }
}

pub const PressureCounts = struct {
    total: usize,
    /// Not a call, so capacity on the send path cannot refuse it.
    not_a_call: usize,
    answerable: usize,
    /// The gone answer is also true of a busy link, by a listed claim.
    exempt: usize,
    owed: usize,
};

pub fn pressureCounts() PressureCounts {
    @setEvalBranchQuota(1_000_000);
    var tally: PressureCounts = .{
        .total = 0,
        .not_a_call = 0,
        .answerable = 0,
        .exempt = 0,
        .owed = 0,
    };
    inline for (method.entries) |entry| {
        tally.total += 1;
        if (entry.transport == .stream) {
            tally.not_a_call += 1;
            continue;
        }
        const Return = switch (entry.owner) {
            inline else => |tag| ReturnType(tag, entry.name),
        };
        if (comptime saysPressure(Return)) {
            tally.answerable += 1;
        } else if (comptime pressureExemptionFor(entry.owner, entry.name) != null) {
            tally.exempt += 1;
        } else {
            tally.owed += 1;
        }
    }
    return tally;
}

const testing = std.testing;

test "the callable surface divides into answerable, exempt and pending" {
    const tally = comptime pressureCounts();
    try testing.expectEqual(method.entries.len, tally.total);
    try testing.expectEqual(
        tally.total,
        tally.not_a_call + tally.answerable + tally.exempt + tally.owed,
    );
    try testing.expectEqual(@as(usize, 4), tally.not_a_call);
    const callable = tally.total - tally.not_a_call;

    // What the vocabulary bought. `LinkBusy` in `surface.Error` reaches every
    // `Error!T` and `Allocating!T` method at once, which is most of the
    // surface; `port.CompactCancellation` carries its own, and five enums and
    // unions declare `link_busy`.
    try testing.expectEqual(@as(usize, 38), tally.answerable);

    // The ones whose existing answer is true of a busy link as well, each
    // with the call site the claim is about.
    try testing.expectEqual(pressure_exemptions.len, tally.exempt);
    try testing.expectEqual(@as(usize, 6), tally.exempt);

    // The ones still owed a change, and the number this rule exists to drive
    // to zero. Three of them are the `void_release` methods, which is the
    // finding this table records rather than inherits: a release refused for
    // capacity leaves the object held on a peer that is still there.
    try testing.expectEqual(pressure_pending.len, tally.owed);
    try testing.expectEqual(@as(usize, 6), tally.owed);
    try testing.expectEqual(callable, tally.answerable + tally.exempt + tally.owed);
}

test "no pressure exemption may claim what only a gone peer makes true" {
    // The gone rule has three categories and this one has two. The absent
    // category is `void_release`, and its absence is load-bearing: its claim
    // is that the peer has already dropped what was to be released, which is
    // false of a peer that answered and had no room. So the three methods it
    // exempts there are pending here.
    try testing.expectEqual(@as(usize, 2), @typeInfo(PressureCategory).@"enum".fields.len);
    var void_release_methods: usize = 0;
    inline for (exemptions) |entry| {
        if (entry.category != .void_release) continue;
        void_release_methods += 1;
        try testing.expect(!pressureExempt(entry.owner, entry.name));
        var found = false;
        for (pressure_pending) |owed| {
            if (owed.owner == entry.owner and std.mem.eql(u8, owed.name, entry.name))
                found = true;
        }
        try testing.expect(found);
    }
    try testing.expectEqual(@as(usize, 3), void_release_methods);
}

test "an optional does not double as the backpressure answer" {
    // It qualifies for gone, because a call site must say what absence
    // means. Absence cannot then also mean "not now": the two call for
    // opposite behaviour.
    try testing.expect(expressibility(?u64) != null);
    try testing.expect(!saysPressure(?u64));

    // And the vocabulary is read from the type, not pattern-matched on a
    // spelling: a set with the member qualifies, one without it does not.
    try testing.expect(saysPressure(error{ Whatever, LinkBusy }!void));
    try testing.expect(!saysPressure(error{Whatever}!void));
}

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
