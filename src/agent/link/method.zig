//! The execution link's method registry.
//!
//! Every field of every port vtable is registered here with a stable wire
//! number and the frame kind it travels on. The registry is closed at compile
//! time in both directions: adding a method to `port.zig` without registering
//! it does not compile, and registering a name the vtable no longer declares
//! does not compile either. That is what "no unmapped method" means -- a
//! property of the build, not a table someone keeps by hand.
//!
//! The transport column is the design content. `control` is the short list
//! that may overtake queued fragments, because a Stop that waits behind an
//! 11 MB Run input is a product failure; `stream` is the event path, which is
//! not a call at all; `ui_answer` releases a parked UI request.
//!
//! No entry invents an Agent fact on the caller's side. The four `stream`
//! entries are answered from the caller's own event pump, but that pump holds
//! nothing except what arrived as `event` frames, so the answer is still the
//! execution half's fact, buffered. Nothing here licenses the caller to decide
//! an Agent outcome locally.
//!
//! One ordering invariant rides on these classifications and is easy to break
//! by accident. `event` frames and the `response` that carries a Run's
//! terminal travel the same ordered data queue, and only non-fragmenting
//! `control` frames may pass between fragments. So a Run's terminal can never
//! arrive before the events that preceded it, which is what lets a caller read
//! "my pump holds nothing for this route" as "every event of that terminal's
//! Run has arrived". Moving a terminal onto `control`, or adding a second data
//! channel, would break that silently -- the reader would simply see fewer
//! events and conclude the stream was complete. `channel.zig` pins the
//! ordering with a test for the same reason.

const std = @import("std");
const contract = @import("agent_contract");
const frame = @import("frame.zig");

const port = contract.port;

pub const Owner = enum {
    runtime,
    session,
    run,
    run_control,

    pub fn VTable(comptime self: Owner) type {
        return switch (self) {
            .runtime => port.RuntimePort.VTable,
            .session => port.SessionPort.VTable,
            .run => port.RunPort.VTable,
            .run_control => port.RunControl.VTable,
        };
    }
};

pub const Transport = enum {
    /// A request frame out, a response frame back.
    call,
    /// A control frame: never fragmented, and allowed to overtake fragments.
    control,
    /// Releases a parked UI request; travels as `ui_response`.
    ui_answer,
    /// Not a call. The exec side pushes `event` and `event_ready` frames and
    /// the UI-side pump answers this from what has already arrived.
    stream,

    pub fn kind(self: Transport) ?frame.Kind {
        return switch (self) {
            .call => .request,
            .control => .control,
            .ui_answer => .ui_response,
            .stream => null,
        };
    }
};

/// Which thread may start this call. The UI half's main loop owns the
/// projection budget, so a method it calls becomes a round trip inside that
/// budget; a method only a worker starts may block as long as it likes,
/// because blocking is what that thread already does.
///
/// This is a closed classification rather than a latency budget on purpose. A
/// number like "at most N round trips per command" has to be maintained by
/// hand and goes stale while staying green -- the same fault as a count
/// repeated in prose. What matters is *which* calls may appear on the thread
/// that must not stall, and that set can be stated and enforced.
pub const Caller = enum {
    /// Verified to be started by the UI half's main loop. Its round trip
    /// lands inside the projection budget.
    main_loop,
    /// Verified to be started only from a worker, where blocking is normal.
    worker,
    /// Not yet attributed to a thread. This is tracked debt, not a default:
    /// `unattributedCount` must reach zero before the forwarding stubs can
    /// claim a threading contract, because a stub that blocks on a thread
    /// which must not stall is exactly the failure this field exists to stop.
    unattributed,
};

pub const Entry = struct {
    owner: Owner,
    name: [:0]const u8,
    code: u16,
    transport: Transport,
    /// No default: every method states its thread, or the build fails.
    caller: Caller,
};

/// Stable wire numbers, grouped by owner. A number is never reassigned.
pub const entries = [_]Entry{
    .{ .owner = .runtime, .name = "create_session_route", .code = 0x0101, .transport = .call, .caller = .unattributed }, // route id is the handle; the Product-assigned correlation identity rides here
    .{ .owner = .runtime, .name = "restore_session_route", .code = 0x0102, .transport = .call, .caller = .unattributed }, // checkpoint bytes stay on disk; the source descriptor crosses
    .{ .owner = .runtime, .name = "release_closed_session", .code = 0x0103, .transport = .call, .caller = .unattributed }, // ordered against the close sequence
    .{ .owner = .runtime, .name = "take_event", .code = 0x0104, .transport = .stream, .caller = .main_loop }, // popped from the UI-side pump that event frames filled
    .{ .owner = .runtime, .name = "has_pending_events", .code = 0x0105, .transport = .stream, .caller = .main_loop }, // read of the UI-side pump
    .{ .owner = .runtime, .name = "pending_event_count", .code = 0x0106, .transport = .stream, .caller = .main_loop }, // read of the UI-side pump, per route
    .{ .owner = .runtime, .name = "notify_event_consumer", .code = 0x0107, .transport = .stream, .caller = .main_loop }, // the exec-side notifier becomes an event_ready frame
    .{ .owner = .runtime, .name = "request_run_termination", .code = 0x0108, .transport = .control, .caller = .main_loop }, // must overtake queued fragments
    .{ .owner = .runtime, .name = "restore_admission", .code = 0x0109, .transport = .call, .caller = .main_loop }, // exec-side capacity and MCP state decide it
    .{ .owner = .runtime, .name = "activate_mcp", .code = 0x010A, .transport = .call, .caller = .main_loop }, // activation handle id out, projection as data
    .{ .owner = .runtime, .name = "create_mcp_admission_selection", .code = 0x010B, .transport = .call, .caller = .main_loop }, // activation handle id and allowlists in, selection handle id out
    .{ .owner = .runtime, .name = "prepare_mcp_restore_selection", .code = 0x010C, .transport = .call, .caller = .main_loop }, // same handle-id shape as the admission selection
    .{ .owner = .runtime, .name = "query_skill_catalog", .code = 0x010D, .transport = .call, .caller = .main_loop }, // lease stays exec-side as an id; the arena-flat projection crosses
    .{ .owner = .runtime, .name = "release_skill_catalog", .code = 0x010E, .transport = .call, .caller = .main_loop }, // releases an exec-side lease by id
    .{ .owner = .runtime, .name = "narrow_skill_restore_inputs", .code = 0x010F, .transport = .call, .caller = .main_loop }, // handle id in, new handle id out
    .{ .owner = .runtime, .name = "clone_skill_restore_inputs", .code = 0x0110, .transport = .call, .caller = .unattributed }, // handle id in, new handle id out
    .{ .owner = .runtime, .name = "borrow_skill_restore_inputs", .code = 0x0111, .transport = .call, .caller = .unattributed }, // borrowed lease pointer becomes an id plus a policy copy
    .{ .owner = .runtime, .name = "release_skill_restore_inputs", .code = 0x0112, .transport = .call, .caller = .main_loop }, // releases an exec-side handle by id
    .{ .owner = .runtime, .name = "release_restore_inputs", .code = 0x0113, .transport = .call, .caller = .unattributed }, // releases the whole captured set by id
    .{ .owner = .session, .name = "retain_reference", .code = 0x0201, .transport = .call, .caller = .unattributed }, // the refcount is exec-side state, so it cannot be faked locally
    .{ .owner = .session, .name = "release_reference", .code = 0x0202, .transport = .call, .caller = .unattributed }, // pairs with the retain above
    .{ .owner = .session, .name = "stop_event_delivery", .code = 0x0203, .transport = .call, .caller = .main_loop }, // ordered inside the close sequence, so it must not overtake
    .{ .owner = .session, .name = "close_outcome", .code = 0x0204, .transport = .call, .caller = .unattributed }, // outcome and disposition are exec-side facts
    .{ .owner = .session, .name = "refresh_skill_catalog", .code = 0x0205, .transport = .call, .caller = .unattributed }, // lease id plus policy data
    .{ .owner = .session, .name = "set_model", .code = 0x0206, .transport = .call, .caller = .unattributed }, // model name only
    .{ .owner = .session, .name = "update_credential", .code = 0x0207, .transport = .call, .caller = .unattributed }, // credential-bearing frame
    .{ .owner = .session, .name = "clear_skill_policy", .code = 0x0208, .transport = .call, .caller = .unattributed }, // no payload beyond the session handle
    .{ .owner = .session, .name = "skill_policy_matches", .code = 0x0209, .transport = .call, .caller = .unattributed }, // compares against exec-side session state
    .{ .owner = .session, .name = "capture_restore_inputs", .code = 0x020A, .transport = .call, .caller = .unattributed }, // returns handle ids the UI only retains and hands back
    .{ .owner = .session, .name = "snapshot", .code = 0x020B, .transport = .call, .caller = .unattributed }, // plain data out
    .{ .owner = .session, .name = "update_permission_mode", .code = 0x020C, .transport = .call, .caller = .unattributed }, // compare-and-set against exec-side state
    .{ .owner = .session, .name = "request_termination", .code = 0x020D, .transport = .control, .caller = .unattributed }, // must overtake queued fragments
    .{ .owner = .session, .name = "prepare_run", .code = 0x020E, .transport = .call, .caller = .unattributed }, // text or skill input
    .{ .owner = .session, .name = "prepare_run_with_tools", .code = 0x020F, .transport = .call, .caller = .unattributed }, // the largest request; multimodal previews stay inline
    .{ .owner = .session, .name = "begin_run_outcome", .code = 0x0210, .transport = .call, .caller = .worker }, // hands back a Run handle or a typed failure
    .{ .owner = .session, .name = "cancel_prepared_run", .code = 0x0211, .transport = .call, .caller = .main_loop }, // ordered against the prepare above
    .{ .owner = .session, .name = "prepare_compact", .code = 0x0212, .transport = .call, .caller = .unattributed }, // small
    .{ .owner = .session, .name = "cancel_prepared_compact", .code = 0x0213, .transport = .call, .caller = .main_loop }, // ordered against the prepare above
    .{ .owner = .session, .name = "execute_prepared_compact", .code = 0x0214, .transport = .call, .caller = .worker }, // blocks until the compact terminal, like a Run
    .{ .owner = .session, .name = "request_compact_cancellation", .code = 0x0215, .transport = .control, .caller = .unattributed }, // must overtake queued fragments
    .{ .owner = .session, .name = "respond_permission", .code = 0x0216, .transport = .ui_answer, .caller = .unattributed }, // answers a parked UI request
    .{ .owner = .session, .name = "fail_ui_request_identity_contract", .code = 0x0217, .transport = .ui_answer, .caller = .unattributed }, // the negative answer to the same request
    .{ .owner = .session, .name = "pending_ui_observation", .code = 0x0218, .transport = .call, .caller = .unattributed }, // the adopted input count is exec-side and moves
    .{ .owner = .session, .name = "permission_stop_request", .code = 0x0219, .transport = .call, .caller = .unattributed }, // read of exec-side state
    .{ .owner = .session, .name = "copy_pending_ui_request", .code = 0x021A, .transport = .call, .caller = .main_loop }, // the UI holds the bytes, but liveness is exec's fact
    .{ .owner = .session, .name = "export_checkpoint", .code = 0x021B, .transport = .call, .caller = .worker }, // the sink stays exec-side; only the request and the outcome cross
    .{ .owner = .session, .name = "conversation_bounds", .code = 0x021C, .transport = .call, .caller = .unattributed }, // two counts out
    .{ .owner = .session, .name = "rewind_to_user_message", .code = 0x021D, .transport = .call, .caller = .unattributed }, // a position in, a typed outcome back
    .{ .owner = .run, .name = "execute", .code = 0x0301, .transport = .call, .caller = .worker }, // blocks until the Run terminal; a slow response is not a dead link
    .{ .owner = .run_control, .name = "try_retain", .code = 0x0401, .transport = .call, .caller = .unattributed }, // exec-side lease acquisition
    .{ .owner = .run_control, .name = "release", .code = 0x0402, .transport = .call, .caller = .unattributed }, // pairs with the retain above
    .{ .owner = .run_control, .name = "submit_input", .code = 0x0403, .transport = .call, .caller = .main_loop }, // bounded text
    .{ .owner = .run_control, .name = "input_observation", .code = 0x0404, .transport = .call, .caller = .unattributed }, // read of exec-side counters
    .{ .owner = .run_control, .name = "request_termination", .code = 0x0405, .transport = .control, .caller = .unattributed }, // must overtake queued fragments
};

comptime {
    @setEvalBranchQuota(entries.len * entries.len * 16);
    // Every vtable field is registered exactly once.
    for (std.enums.values(Owner)) |owner| switch (owner) {
        inline else => |tag| {
            const fields = @typeInfo(tag.VTable()).@"struct".fields;
            var registered = 0;
            for (fields) |field| {
                var found = false;
                for (entries) |entry| {
                    if (entry.owner != tag) continue;
                    if (!std.mem.eql(u8, entry.name, field.name)) continue;
                    if (found) @compileError("duplicate link method entry for " ++ field.name);
                    found = true;
                }
                if (!found) @compileError(
                    "port." ++ @tagName(tag) ++ "." ++ field.name ++
                        " has no execution link method; register it in " ++
                        "src/agent/link/method.zig and never reuse a number",
                );
                registered += 1;
            }
            var owned = 0;
            for (entries) |entry| {
                if (entry.owner == tag) owned += 1;
            }
            if (owned != registered) @compileError(
                "the link registers methods for " ++ @tagName(tag) ++
                    " that its vtable no longer declares",
            );
        },
    };
    // No number repeats across owners.
    for (entries, 0..) |entry, index| {
        if (entry.code == 0) @compileError("method code 0 is reserved");
        for (entries[index + 1 ..]) |other| {
            if (entry.code == other.code) @compileError(
                "method code " ++ std.fmt.comptimePrint("{d}", .{entry.code}) ++
                    " is used by both " ++ entry.name ++ " and " ++ other.name,
            );
        }
    }
    // A control method must fit one frame, since control is never fragmented.
    for (entries) |entry| {
        if (entry.transport != .control) continue;
        if (!@hasDecl(frame, "max_fragment_payload_bytes")) @compileError("missing fragment bound");
    }
}

/// How many methods still have no thread attributed. Tracked debt, like the
/// payload inventory's `owed`: the forwarding stubs cannot claim a threading
/// contract while this is non-zero, because a stub that blocks on the thread
/// which must not stall is the failure the classification exists to stop.
pub fn unattributedCount() usize {
    var total: usize = 0;
    for (entries) |entry| {
        if (entry.caller == .unattributed) total += 1;
    }
    return total;
}

pub fn callerCount(caller: Caller) usize {
    var total: usize = 0;
    for (entries) |entry| {
        if (entry.caller == caller) total += 1;
    }
    return total;
}

/// Whether every method has a thread. The condition the stubs wait on.
pub fn threadsAttributed() bool {
    return unattributedCount() == 0;
}

pub const DecodeError = error{UnknownMethodCode};

pub fn find(code: u16) DecodeError!Entry {
    @setEvalBranchQuota(entries.len * 64);
    inline for (entries) |entry| {
        if (entry.code == code) return entry;
    }
    return error.UnknownMethodCode;
}

pub fn codeOf(comptime owner: Owner, comptime name: []const u8) u16 {
    @setEvalBranchQuota(entries.len * 128);
    inline for (entries) |entry| {
        if (entry.owner == owner and comptime std.mem.eql(u8, entry.name, name)) return entry.code;
    }
    @compileError("no link method named " ++ name ++ " on " ++ @tagName(owner));
}

/// Writes the registry, one `code owner.method transport` line each. The
/// cross-process port review reads this rather than a hand-kept table.
pub fn writeTable(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    for (entries) |entry| try writer.print("0x{X:0>4} {s}.{s} {s}\n", .{
        entry.code,
        @tagName(entry.owner),
        entry.name,
        @tagName(entry.transport),
    });
}

test "every port method round-trips through its wire number" {
    @setEvalBranchQuota(entries.len * 128);
    inline for (entries) |entry| {
        const found = try find(entry.code);
        try std.testing.expectEqual(entry.owner, found.owner);
        try std.testing.expectEqualStrings(entry.name, found.name);
        try std.testing.expectEqual(entry.transport, found.transport);
    }
    try std.testing.expectError(error.UnknownMethodCode, find(0));
    try std.testing.expectError(error.UnknownMethodCode, find(0x0999));
}

test "the registry covers each vtable exactly" {
    @setEvalBranchQuota(entries.len * 128);
    inline for (comptime std.enums.values(Owner)) |owner| {
        const fields = @typeInfo(owner.VTable()).@"struct".fields;
        var owned: usize = 0;
        for (entries) |entry| {
            if (entry.owner == owner) owned += 1;
        }
        try std.testing.expectEqual(fields.len, owned);
    }
    try std.testing.expectEqual(@as(usize, 54), entries.len);
}

test "the control list is exactly the operations that must overtake bytes" {
    var control: usize = 0;
    for (entries) |entry| {
        if (entry.transport != .control) continue;
        control += 1;
        // Every one of them is a termination or cancellation request.
        try std.testing.expect(
            std.mem.indexOf(u8, entry.name, "termination") != null or
                std.mem.indexOf(u8, entry.name, "cancellation") != null,
        );
    }
    try std.testing.expectEqual(@as(usize, 4), control);
}

test "every method states a thread, and the debt is what is left to attribute" {
    // `Caller` has no default, so a new method cannot avoid the question. What
    // is asserted here is the shape of the answer, not a total: the counts add
    // up, and the methods a worker drives are the ones that block until a
    // terminal, which is why they may block at all.
    try std.testing.expectEqual(
        entries.len,
        callerCount(.main_loop) + callerCount(.worker) + callerCount(.unattributed),
    );
    try std.testing.expectEqual(unattributedCount(), callerCount(.unattributed));
    for (entries) |entry| {
        if (entry.caller != .worker) continue;
        // A worker-driven call is one that waits for execution to finish.
        try std.testing.expect(
            std.mem.indexOf(u8, entry.name, "execute") != null or
                std.mem.indexOf(u8, entry.name, "begin_run") != null or
                std.mem.indexOf(u8, entry.name, "export_checkpoint") != null,
        );
    }
}

test "a main-loop method is never one that blocks until a terminal" {
    // The point of the classification. If one of these ever appears on the
    // main loop, the round trip is unbounded and the projection budget is
    // gone, so the pairing is asserted rather than remembered.
    for (entries) |entry| {
        if (entry.caller != .main_loop) continue;
        try std.testing.expect(!std.mem.eql(u8, entry.name, "execute"));
        try std.testing.expect(!std.mem.eql(u8, entry.name, "execute_prepared_compact"));
    }
}

test "the event path is not a call" {
    @setEvalBranchQuota(entries.len * 64);
    inline for (entries) |entry| {
        if (entry.transport != .stream) continue;
        try std.testing.expectEqual(@as(?frame.Kind, null), entry.transport.kind());
    }
    try std.testing.expectEqual(frame.Kind.request, Transport.call.kind().?);
    try std.testing.expectEqual(frame.Kind.control, Transport.control.kind().?);
    try std.testing.expectEqual(frame.Kind.ui_response, Transport.ui_answer.kind().?);
}
