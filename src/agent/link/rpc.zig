//! The calls the execution link carries, and their bytes.
//!
//! One process hosts every Session, and the one way the link fails is that
//! process being gone. So a call is a request and a response matched by
//! correlation, nothing more: no per-call busy answer, no reservation, no
//! handle table on the caller's side. What crosses is plain data, encoded by
//! `payload.zig`; the types that own an allocator or name an object cross as
//! the mirrors `shapes.zig` already defines.
//!
//! A Session is named by the handle the execution half assigned it. A Run is
//! not named at all: in process its port's context is its Session and its
//! control's context is the Session's control block, so a Run is a Session
//! plus `(run_id, generation)`, and that is what crosses.
//!
//! Frames:
//!
//!   * `request`  -- `[u16 method][u64 handle]` then the method's request.
//!   * `response` -- `[u16 status]` then, when the status is zero, the
//!     method's response. Any other status is the error's registered number.
//!   * `event`    -- an `Event`.
//!   * `control`  -- a `Credit`, from the caller to the execution half.

const std = @import("std");
const contract = @import("agent_contract");
const checkpoint = @import("agent_checkpoint");
const checkpoint_restore = @import("agent_checkpoint_restore");
const payload = @import("payload.zig");
const shapes = @import("shapes.zig");
const error_code = @import("error_code.zig");
const handle_table = @import("handle_table.zig");

const port = contract.port;
const surface = contract.surface;
const control = contract.control;

pub const Method = enum(u16) {
    create_session = 1,
    restore_session = 2,
    release_closed_session = 3,
    request_run_termination = 4,
    restore_admission = 5,
    stop_event_delivery = 6,
    close = 7,
    clear_skill_policy = 8,
    set_model = 9,
    snapshot = 10,
    update_permission_mode = 11,
    conversation_bounds = 12,
    rewind_to_user_message = 13,
    update_credential = 14,
    request_termination = 15,
    prepare_run = 16,
    begin_run = 17,
    cancel_prepared_run = 18,
    prepare_compact = 19,
    cancel_prepared_compact = 20,
    execute_prepared_compact = 21,
    request_compact_cancellation = 22,
    respond_permission = 23,
    fail_ui_request_identity_contract = 24,
    pending_ui_observation = 25,
    permission_stop_request = 26,
    copy_pending_ui_request = 27,
    export_checkpoint = 28,
    run_execute = 29,
    run_submit_input = 30,
    run_input_observation = 31,
    run_request_termination = 32,

    /// Whether the call names a Session. The rest are the Runtime's.
    pub fn namesSession(self: Method) bool {
        return switch (self) {
            .create_session, .restore_session, .request_run_termination, .restore_admission => false,
            else => true,
        };
    }

    /// Whether the answer is a Run's or a compact's terminal, which the
    /// execution half sends only once every event before it has been sent.
    pub fn isTerminal(self: Method) bool {
        return self == .run_execute or self == .execute_prepared_compact;
    }
};

pub const SessionRoute = struct {
    route_id: u64,
    handle: u64,
};

pub const SessionRestoreRoute = struct {
    route_id: u64,
    handle: u64,
    report: checkpoint_restore.Report,
};

pub const RestoreExpectation = struct {
    logical_session_id: []const u8,
    checkpoint_generation: u64,
    last_run_id: u64,
    last_compact_id: u64,
    model: []const u8,
};

/// What a restore reads from, carried whole.
///
/// The caller read its checkpoint through its own source on its own thread;
/// these are those bytes, and `end` is what its last read returned. The
/// execution half replays both to the Session's restore, so a source that
/// failed or ran past the limit is judged there by the same rules as in
/// process.
pub const RestoreSource = struct {
    bytes: []const u8,
    end: checkpoint_restore.SourceReadResult,
};

pub const RestoreRequest = struct {
    session: shapes.SessionOpenOptions,
    checkpoint_limits: checkpoint.Limits,
    expectation: RestoreExpectation,
    source: RestoreSource,
};

pub const BeginRun = union(enum) {
    run: struct { run_id: u64, generation: u64 },
    failure: shapes.BeginRunFailure,
};

pub const ExportRequest = struct {
    limits: checkpoint.Limits,
    expected_last_run_id: u64,
    expected_last_compact_id: u64,
    expected_model: []const u8,
};

/// An export's outcome and, on success, its bytes. The caller writes them
/// into its own sink on its own thread; nothing on the reading thread ever
/// touches that sink.
pub const ExportResponse = struct {
    outcome: shapes.CheckpointOutcome,
    bytes: []const u8,
};

pub const Event = struct {
    session_id: u64,
    run_id: u64,
    encoded_bytes: u64,
    json: []const u8,
};

/// How much the caller has ever made room for, as running totals.
///
/// Totals rather than increments, so a frame that could not be queued is
/// made up by the next one rather than lost.
pub const Credit = struct {
    count: u64,
    bytes: u64,
};

const Empty = struct {};

pub fn Request(comptime method: Method) type {
    return switch (method) {
        .create_session => shapes.SessionOpenOptions,
        .restore_session => RestoreRequest,
        .release_closed_session,
        .stop_event_delivery,
        .clear_skill_policy,
        .snapshot,
        .conversation_bounds,
        .prepare_compact,
        .pending_ui_observation,
        .permission_stop_request,
        .copy_pending_ui_request,
        => Empty,
        .request_run_termination => struct { session_id: u64, run_id: u64, signal: control.TerminationSignal },
        .restore_admission => struct { releasing_route_id: ?u64 },
        .close => struct { interruption: control.ExternalInterruption },
        .set_model => struct { model: []const u8 },
        .update_permission_mode => struct { expected: control.PermissionMode, target: control.PermissionMode },
        .rewind_to_user_message => struct { position: u64 },
        .update_credential => struct { credential: []const u8 },
        .request_termination => struct { run_id: u64, signal: control.TerminationSignal },
        .prepare_run => struct { input: surface.RunInput },
        .begin_run, .cancel_prepared_run, .fail_ui_request_identity_contract => struct { run_id: u64 },
        .cancel_prepared_compact, .execute_prepared_compact => struct { operation_id: u64 },
        .request_compact_cancellation => struct { operation_id: u64, interruption: control.ExternalInterruption },
        .respond_permission => struct { run_id: u64, request_id: u64, choice: contract.PermissionChoice },
        .export_checkpoint => ExportRequest,
        .run_execute, .run_input_observation => struct { run_id: u64, generation: u64 },
        .run_submit_input => struct { run_id: u64, generation: u64, input_id: u64, text: []const u8 },
        .run_request_termination => struct { run_id: u64, generation: u64, signal: control.TerminationSignal },
    };
}

pub fn Response(comptime method: Method) type {
    return switch (method) {
        .create_session => SessionRoute,
        .restore_session => SessionRestoreRoute,
        .release_closed_session,
        .request_run_termination,
        .stop_event_delivery,
        .clear_skill_policy,
        .set_model,
        .update_credential,
        .request_termination,
        .cancel_prepared_run,
        .cancel_prepared_compact,
        .request_compact_cancellation,
        .respond_permission,
        .fail_ui_request_identity_contract,
        => void,
        .restore_admission => port.RuntimePort.RestoreAdmission,
        .close => shapes.CloseOutcome,
        .snapshot => surface.SessionSnapshot,
        .update_permission_mode => surface.PermissionModeUpdate,
        .conversation_bounds => surface.ConversationBounds,
        .rewind_to_user_message => surface.RewindOutcome,
        .prepare_run, .prepare_compact => u64,
        .begin_run => BeginRun,
        .execute_prepared_compact => shapes.CompactTerminalResult,
        .pending_ui_observation => ?port.SessionPort.PendingUiObservation,
        .permission_stop_request => ?u64,
        .copy_pending_ui_request => shapes.PendingUiRequest,
        .export_checkpoint => ExportResponse,
        .run_execute => shapes.TerminalResult,
        .run_submit_input => control.InputSubmission,
        .run_input_observation => ?control.InputObservation,
        .run_request_termination => control.TerminationRequestResult,
    };
}

comptime {
    @setEvalBranchQuota(10_000_000);
    for (std.enums.values(Method)) |method| {
        payload.requireStructural(Request(method));
        const Out = Response(method);
        if (Out != void) payload.requireStructural(Out);
    }
    payload.requireStructural(Event);
    payload.requireStructural(Credit);
}

// ---------------------------------------------------------------------------
// Requests
// ---------------------------------------------------------------------------

pub const request_header_bytes: usize = 2 + 8;

pub fn encodeRequest(
    comptime method: Method,
    allocator: std.mem.Allocator,
    handle: u64,
    value: Request(method),
) std.mem.Allocator.Error![]u8 {
    const body_len = payload.encodedSize(Request(method), value);
    const buffer = try allocator.alloc(u8, request_header_bytes + body_len);
    std.mem.writeInt(u16, buffer[0..2], @intFromEnum(method), .little);
    std.mem.writeInt(u64, buffer[2..10], handle, .little);
    const written = payload.encode(Request(method), value, buffer[request_header_bytes..]);
    std.debug.assert(written == body_len);
    return buffer;
}

pub const Received = struct {
    method: Method,
    handle: u64,
    body: []const u8,
};

pub const HeaderError = error{ Truncated, UnknownMethod };

pub fn decodeRequestHeader(bytes: []const u8) HeaderError!Received {
    if (bytes.len < request_header_bytes) return error.Truncated;
    const raw = std.mem.readInt(u16, bytes[0..2], .little);
    const method = std.enums.fromInt(Method, raw) orelse return error.UnknownMethod;
    return .{
        .method = method,
        .handle = std.mem.readInt(u64, bytes[2..10], .little),
        .body = bytes[request_header_bytes..],
    };
}

pub fn decodeRequest(
    comptime method: Method,
    arena: std.mem.Allocator,
    body: []const u8,
) payload.DecodeError!Request(method) {
    return payload.decodeExact(Request(method), arena, body);
}

// ---------------------------------------------------------------------------
// Responses
// ---------------------------------------------------------------------------

pub fn encodeOk(
    comptime method: Method,
    allocator: std.mem.Allocator,
    value: Response(method),
) std.mem.Allocator.Error![]u8 {
    const Out = Response(method);
    const body_len = if (Out == void) 0 else payload.encodedSize(Out, value);
    const buffer = try allocator.alloc(u8, 2 + body_len);
    std.mem.writeInt(u16, buffer[0..2], 0, .little);
    if (Out != void) {
        const written = payload.encode(Out, value, buffer[2..]);
        std.debug.assert(written == body_len);
    }
    return buffer;
}

pub fn encodeError(allocator: std.mem.Allocator, err: error_code.LinkError) std.mem.Allocator.Error![]u8 {
    const buffer = try allocator.alloc(u8, 2);
    std.mem.writeInt(u16, buffer[0..2], error_code.encode(err), .little);
    return buffer;
}

pub fn Answer(comptime method: Method) type {
    return union(enum) {
        ok: Response(method),
        /// The far side's own error, as its registered number.
        err: error_code.LinkError,
    };
}

pub const ResponseError = payload.DecodeError || error{UnknownErrorCode};

/// `[]const u8` in the answer borrows `bytes`; every other slice is in
/// `arena`.
pub fn decodeResponse(
    comptime method: Method,
    arena: std.mem.Allocator,
    bytes: []const u8,
) ResponseError!Answer(method) {
    if (bytes.len < 2) return error.Truncated;
    const status = std.mem.readInt(u16, bytes[0..2], .little);
    if (status != 0) {
        if (bytes.len != 2) return error.TrailingBytes;
        return .{ .err = error_code.decode(status) orelse return error.UnknownErrorCode };
    }
    const Out = Response(method);
    if (Out == void) {
        if (bytes.len != 2) return error.TrailingBytes;
        return .{ .ok = {} };
    }
    return .{ .ok = try payload.decodeExact(Out, arena, bytes[2..]) };
}

// ---------------------------------------------------------------------------
// Mirrors in the direction `shapes.zig` does not already provide
// ---------------------------------------------------------------------------

pub const MirrorError = error{
    /// The options name a skill catalog or an MCP selection. Neither crosses
    /// in this step, so a caller that has one is not using this link.
    CapabilityNotOffered,
    /// A handle id where this step never sends one.
    UnexpectedHandle,
};

pub fn openOptionsToWire(value: surface.SessionOpenOptions) MirrorError!shapes.SessionOpenOptions {
    if (value.skill_catalog != null or value.mcp_selection != null) return error.CapabilityNotOffered;
    return .{
        .task_id = value.task_id,
        .binding_epoch = value.binding_epoch,
        .model_binding = value.model_binding,
        .permission_mode = value.permission_mode,
        .shell_policy = value.shell_policy,
        .permission_interaction = value.permission_interaction,
        .workspace = value.workspace,
        .canonical_user_home = value.canonical_user_home,
        .workspace_epoch = value.workspace_epoch,
        .skill_catalog = handle_table.Id.none,
        .skill_policy = value.skill_policy,
        .mcp_selection = handle_table.Id.none,
        .operation_id_floor = value.operation_id_floor,
    };
}

pub fn openOptionsFromWire(value: shapes.SessionOpenOptions) MirrorError!surface.SessionOpenOptions {
    if (value.skill_catalog.valid() or value.mcp_selection.valid()) return error.UnexpectedHandle;
    return .{
        .task_id = value.task_id,
        .binding_epoch = value.binding_epoch,
        .model_binding = value.model_binding,
        .permission_mode = value.permission_mode,
        .shell_policy = value.shell_policy,
        .permission_interaction = value.permission_interaction,
        .workspace = value.workspace,
        .canonical_user_home = value.canonical_user_home,
        .workspace_epoch = value.workspace_epoch,
        .skill_catalog = null,
        .skill_policy = value.skill_policy,
        .mcp_selection = null,
        .operation_id_floor = value.operation_id_floor,
    };
}

/// `checkpoint.Description` as its mirror, field by field. The mirror has a
/// field for every field the description has except its allocator, which
/// `shapes.zig` checks, so this cannot leave one behind.
pub fn descriptionToWire(value: *const checkpoint.Description) shapes.CheckpointDescription {
    var result: shapes.CheckpointDescription = undefined;
    inline for (@typeInfo(shapes.CheckpointDescription).@"struct".fields) |field|
        @field(result, field.name) = @field(value, field.name);
    return result;
}

pub fn outcomeToWire(value: *const checkpoint.Outcome) shapes.CheckpointOutcome {
    return switch (value.*) {
        .success => |*success| .{ .success = .{
            .checkpoint = success.checkpoint,
            .placement = success.placement,
            .description = descriptionToWire(&success.description),
        } },
        .failure => |failure| .{ .failure = failure },
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "a request carries its method and handle ahead of its body" {
    const bytes = try encodeRequest(.set_model, testing.allocator, 42, .{ .model = "fixture" });
    defer testing.allocator.free(bytes);
    const received = try decodeRequestHeader(bytes);
    try testing.expectEqual(Method.set_model, received.method);
    try testing.expectEqual(@as(u64, 42), received.handle);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const value = try decodeRequest(.set_model, arena.allocator(), received.body);
    try testing.expectEqualStrings("fixture", value.model);
}

test "a method number this build does not declare is refused, not guessed" {
    var bytes: [request_header_bytes]u8 = @splat(0);
    std.mem.writeInt(u16, bytes[0..2], 0xffff, .little);
    try testing.expectError(error.UnknownMethod, decodeRequestHeader(&bytes));
    try testing.expectError(error.Truncated, decodeRequestHeader(bytes[0..3]));
}

test "a response is the value, or the error by its registered number" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const ok = try encodeOk(.prepare_run, testing.allocator, 7);
    defer testing.allocator.free(ok);
    try testing.expectEqual(@as(u64, 7), (try decodeResponse(.prepare_run, arena.allocator(), ok)).ok);

    const failed = try encodeError(testing.allocator, error.SessionClosing);
    defer testing.allocator.free(failed);
    try testing.expectEqual(
        @as(error_code.LinkError, error.SessionClosing),
        (try decodeResponse(.prepare_run, arena.allocator(), failed)).err,
    );

    const empty = try encodeOk(.cancel_prepared_run, testing.allocator, {});
    defer testing.allocator.free(empty);
    _ = (try decodeResponse(.cancel_prepared_run, arena.allocator(), empty)).ok;

    // Bytes after a void answer are not padding to ignore.
    var padded: [3]u8 = .{ 0, 0, 1 };
    try testing.expectError(error.TrailingBytes, decodeResponse(.cancel_prepared_run, arena.allocator(), &padded));
}

test "a Run's terminal survives the trip with its interruption and lost events" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const sent: shapes.TerminalResult = .{
        .diagnostic = "cut",
        .diagnostic_truncated = false,
        .abi_status = null,
        .raw_status_code = null,
        .stop_reason = null,
        .raw_stop_reason_code = null,
        .abort_status = null,
        .raw_abort_status_code = null,
        .termination_signal = .{ .interrupted = .session_close },
        .file_changes_lost = false,
        .event_delivery_lost = true,
        .receipts = .{},
        .failure = null,
        .session_disposition_at_completion = .poisoned,
        .durable_budget = null,
        .input_counts = null,
        .first_callback_rejection = null,
        .first_host_failure = null,
        .controlled_callback_close = null,
        .model_error = null,
    };
    const bytes = try encodeOk(.run_execute, testing.allocator, sent);
    defer testing.allocator.free(bytes);
    const back = (try decodeResponse(.run_execute, arena.allocator(), bytes)).ok;
    try testing.expectEqualStrings("cut", back.diagnostic);
    try testing.expect(back.event_delivery_lost);
    try testing.expectEqual(control.ExternalInterruption.session_close, back.termination_signal.?.interrupted);
    try testing.expectEqual(@as(?control.TerminalFailure, null), back.failure);
}

test "an export's bytes and a restore's source cross whole" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const blob = "checkpoint-bytes";
    const failure: checkpoint.Failure = .{ .stage = .checkpoint_export, .reason = .io_failed, .disposition = .reusable };
    const bytes = try encodeOk(.export_checkpoint, testing.allocator, .{ .outcome = .{ .failure = failure }, .bytes = blob });
    defer testing.allocator.free(bytes);
    const back = (try decodeResponse(.export_checkpoint, arena.allocator(), bytes)).ok;
    try testing.expectEqualStrings(blob, back.bytes);
    try testing.expectEqual(failure, back.outcome.failure);

    const source: RestoreSource = .{ .bytes = blob, .end = .io_failed };
    const encoded = try payload.encodeAlloc(RestoreSource, testing.allocator, source);
    defer testing.allocator.free(encoded);
    const decoded = try payload.decodeExact(RestoreSource, arena.allocator(), encoded);
    try testing.expectEqualStrings(blob, decoded.bytes);
    try testing.expectEqual(checkpoint_restore.SourceReadResult.io_failed, decoded.end);
}

test "events and credit round-trip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const event: Event = .{ .session_id = 1 << 32, .run_id = 3, .encoded_bytes = 5, .json = "{}" };
    const bytes = try payload.encodeAlloc(Event, testing.allocator, event);
    defer testing.allocator.free(bytes);
    const back = try payload.decodeExact(Event, arena.allocator(), bytes);
    try testing.expectEqual(event.session_id, back.session_id);
    try testing.expectEqualStrings("{}", back.json);

    const credit: Credit = .{ .count = 448, .bytes = 30 << 20 };
    const credit_bytes = try payload.encodeAlloc(Credit, testing.allocator, credit);
    defer testing.allocator.free(credit_bytes);
    try testing.expectEqual(credit, try payload.decodeExact(Credit, arena.allocator(), credit_bytes));
}

test "options that name a capability this step does not carry are refused" {
    var options: surface.SessionOpenOptions = undefined;
    options.skill_catalog = @ptrFromInt(0x1000);
    options.mcp_selection = null;
    try testing.expectError(error.CapabilityNotOffered, openOptionsToWire(options));
}
