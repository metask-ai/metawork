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
//! not a call at all; `ui_answer` releases a parked UI request. Nothing is
//! answered from UI-side state alone, which is the same as saying the UI-side
//! stub holds no authoritative Agent fact.

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

pub const Entry = struct {
    owner: Owner,
    name: [:0]const u8,
    code: u16,
    transport: Transport,
};

/// Stable wire numbers, grouped by owner. A number is never reassigned.
pub const entries = [_]Entry{
    .{ .owner = .runtime, .name = "create_session_route", .code = 0x0101, .transport = .call }, // route id is the handle; the Product-assigned correlation identity rides here
    .{ .owner = .runtime, .name = "restore_session_route", .code = 0x0102, .transport = .call }, // checkpoint bytes stay on disk; the source descriptor crosses
    .{ .owner = .runtime, .name = "release_closed_session", .code = 0x0103, .transport = .call }, // ordered against the close sequence
    .{ .owner = .runtime, .name = "take_event", .code = 0x0104, .transport = .stream }, // popped from the UI-side pump that event frames filled
    .{ .owner = .runtime, .name = "has_pending_events", .code = 0x0105, .transport = .stream }, // read of the UI-side pump
    .{ .owner = .runtime, .name = "pending_event_count", .code = 0x0106, .transport = .stream }, // read of the UI-side pump, per route
    .{ .owner = .runtime, .name = "notify_event_consumer", .code = 0x0107, .transport = .stream }, // the exec-side notifier becomes an event_ready frame
    .{ .owner = .runtime, .name = "request_run_termination", .code = 0x0108, .transport = .control }, // must overtake queued fragments
    .{ .owner = .runtime, .name = "restore_admission", .code = 0x0109, .transport = .call }, // exec-side capacity and MCP state decide it
    .{ .owner = .runtime, .name = "activate_mcp", .code = 0x010A, .transport = .call }, // activation handle id out, projection as data
    .{ .owner = .runtime, .name = "create_mcp_admission_selection", .code = 0x010B, .transport = .call }, // activation handle id and allowlists in, selection handle id out
    .{ .owner = .runtime, .name = "prepare_mcp_restore_selection", .code = 0x010C, .transport = .call }, // same handle-id shape as the admission selection
    .{ .owner = .runtime, .name = "query_skill_catalog", .code = 0x010D, .transport = .call }, // lease stays exec-side as an id; the arena-flat projection crosses
    .{ .owner = .runtime, .name = "release_skill_catalog", .code = 0x010E, .transport = .call }, // releases an exec-side lease by id
    .{ .owner = .runtime, .name = "narrow_skill_restore_inputs", .code = 0x010F, .transport = .call }, // handle id in, new handle id out
    .{ .owner = .runtime, .name = "clone_skill_restore_inputs", .code = 0x0110, .transport = .call }, // handle id in, new handle id out
    .{ .owner = .runtime, .name = "borrow_skill_restore_inputs", .code = 0x0111, .transport = .call }, // borrowed lease pointer becomes an id plus a policy copy
    .{ .owner = .runtime, .name = "release_skill_restore_inputs", .code = 0x0112, .transport = .call }, // releases an exec-side handle by id
    .{ .owner = .runtime, .name = "release_restore_inputs", .code = 0x0113, .transport = .call }, // releases the whole captured set by id
    .{ .owner = .session, .name = "retain_reference", .code = 0x0201, .transport = .call }, // the refcount is exec-side state, so it cannot be faked locally
    .{ .owner = .session, .name = "release_reference", .code = 0x0202, .transport = .call }, // pairs with the retain above
    .{ .owner = .session, .name = "stop_event_delivery", .code = 0x0203, .transport = .call }, // ordered inside the close sequence, so it must not overtake
    .{ .owner = .session, .name = "close_outcome", .code = 0x0204, .transport = .call }, // outcome and disposition are exec-side facts
    .{ .owner = .session, .name = "refresh_skill_catalog", .code = 0x0205, .transport = .call }, // lease id plus policy data
    .{ .owner = .session, .name = "set_model", .code = 0x0206, .transport = .call }, // model name only
    .{ .owner = .session, .name = "update_credential", .code = 0x0207, .transport = .call }, // credential-bearing frame
    .{ .owner = .session, .name = "clear_skill_policy", .code = 0x0208, .transport = .call }, // no payload beyond the session handle
    .{ .owner = .session, .name = "skill_policy_matches", .code = 0x0209, .transport = .call }, // compares against exec-side session state
    .{ .owner = .session, .name = "capture_restore_inputs", .code = 0x020A, .transport = .call }, // returns handle ids the UI only retains and hands back
    .{ .owner = .session, .name = "snapshot", .code = 0x020B, .transport = .call }, // plain data out
    .{ .owner = .session, .name = "update_permission_mode", .code = 0x020C, .transport = .call }, // compare-and-set against exec-side state
    .{ .owner = .session, .name = "request_termination", .code = 0x020D, .transport = .control }, // must overtake queued fragments
    .{ .owner = .session, .name = "prepare_run", .code = 0x020E, .transport = .call }, // text or skill input
    .{ .owner = .session, .name = "prepare_run_with_tools", .code = 0x020F, .transport = .call }, // the largest request; multimodal previews stay inline
    .{ .owner = .session, .name = "begin_run_outcome", .code = 0x0210, .transport = .call }, // hands back a Run handle or a typed failure
    .{ .owner = .session, .name = "cancel_prepared_run", .code = 0x0211, .transport = .call }, // ordered against the prepare above
    .{ .owner = .session, .name = "prepare_compact", .code = 0x0212, .transport = .call }, // small
    .{ .owner = .session, .name = "cancel_prepared_compact", .code = 0x0213, .transport = .call }, // ordered against the prepare above
    .{ .owner = .session, .name = "execute_prepared_compact", .code = 0x0214, .transport = .call }, // blocks until the compact terminal, like a Run
    .{ .owner = .session, .name = "request_compact_cancellation", .code = 0x0215, .transport = .control }, // must overtake queued fragments
    .{ .owner = .session, .name = "respond_permission", .code = 0x0216, .transport = .ui_answer }, // answers a parked UI request
    .{ .owner = .session, .name = "fail_ui_request_identity_contract", .code = 0x0217, .transport = .ui_answer }, // the negative answer to the same request
    .{ .owner = .session, .name = "pending_ui_observation", .code = 0x0218, .transport = .call }, // the adopted input count is exec-side and moves
    .{ .owner = .session, .name = "permission_stop_request", .code = 0x0219, .transport = .call }, // read of exec-side state
    .{ .owner = .session, .name = "copy_pending_ui_request", .code = 0x021A, .transport = .call }, // the UI holds the bytes, but liveness is exec's fact
    .{ .owner = .session, .name = "export_checkpoint", .code = 0x021B, .transport = .call }, // the sink stays exec-side; only the request and the outcome cross
    .{ .owner = .run, .name = "execute", .code = 0x0301, .transport = .call }, // blocks until the Run terminal; a slow response is not a dead link
    .{ .owner = .run_control, .name = "try_retain", .code = 0x0401, .transport = .call }, // exec-side lease acquisition
    .{ .owner = .run_control, .name = "release", .code = 0x0402, .transport = .call }, // pairs with the retain above
    .{ .owner = .run_control, .name = "submit_input", .code = 0x0403, .transport = .call }, // bounded text
    .{ .owner = .run_control, .name = "input_observation", .code = 0x0404, .transport = .call }, // read of exec-side counters
    .{ .owner = .run_control, .name = "request_termination", .code = 0x0405, .transport = .control }, // must overtake queued fragments
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

pub const DecodeError = error{UnknownMethodCode};

pub fn find(code: u16) DecodeError!Entry {
    @setEvalBranchQuota(entries.len * 64);
    inline for (entries) |entry| {
        if (entry.code == code) return entry;
    }
    return error.UnknownMethodCode;
}

pub fn codeOf(comptime owner: Owner, comptime name: []const u8) u16 {
    comptime {
        for (entries) |entry| {
            if (entry.owner == owner and std.mem.eql(u8, entry.name, name)) return entry.code;
        }
        @compileError("no link method named " ++ name ++ " on " ++ @tagName(owner));
    }
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
    try std.testing.expectEqual(@as(usize, 52), entries.len);
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
