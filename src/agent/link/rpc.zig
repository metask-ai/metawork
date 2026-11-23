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
//! Calls go both ways. The UI half calls the execution half's Runtime
//! (`Method`); the execution half calls back for the effects that stay where
//! they were configured (`Callback`), such as an MCP server's transport. Both
//! use the same frames and the same correlation table; which set a `request`
//! names is said by the direction it travels, and each side numbers its own
//! calls.
//!
//! Frames:
//!
//!   * `request`  -- `[u16 method][u64 handle]` then the method's request.
//!   * `response` -- `[u16 status]` then, when the status is zero, the
//!     method's response. Any other status is the error's registered number.
//!   * `event`    -- an `Event`, from the execution half.
//!   * `control`  -- a `Control`: credit and pings from the UI half, pongs and
//!     cancellations from the execution half.

const std = @import("std");
const contract = @import("agent_contract");
const checkpoint = @import("agent_checkpoint");
const checkpoint_restore = @import("agent_checkpoint_restore");
const payload = @import("payload.zig");
const shapes = @import("shapes.zig");
const error_code = @import("error_code.zig");

const port = contract.port;
const surface = contract.surface;
const control = contract.control;
const mcp_catalog = contract.mcp.catalog;
const mcp_runtime = contract.mcp.runtime;
const mcp_connector = contract.mcp.connector;

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
    activate_mcp = 33,
    create_mcp_admission_selection = 34,
    prepare_mcp_restore_selection = 35,
    apply_mcp_configuration = 36,
    probe_mcp = 37,
    capture_restore_inputs = 38,
    /// Names nothing; answers with the name of the lease it acquired.
    query_skill_catalog = 39,
    /// Names the lease.
    release_skill_catalog = 40,
    refresh_skill_catalog = 41,
    skill_policy_matches = 42,
    set_instructions = 43,

    /// Whether the call names a Session. The rest are the Runtime's.
    pub fn namesSession(self: Method) bool {
        return switch (self) {
            .create_session,
            .restore_session,
            .request_run_termination,
            .restore_admission,
            .activate_mcp,
            .create_mcp_admission_selection,
            .prepare_mcp_restore_selection,
            .apply_mcp_configuration,
            .probe_mcp,
            .query_skill_catalog,
            .release_skill_catalog,
            => false,
            else => true,
        };
    }

    /// Whether the answer is a Run's or a compact's terminal, which the
    /// execution half sends only once every event before it has been sent.
    pub fn isTerminal(self: Method) bool {
        return self == .run_execute or self == .execute_prepared_compact;
    }
};

/// The calls the execution half makes of the UI half.
pub const Callback = enum(u16) {
    /// Opens a connection on a transport the UI half holds. Names the
    /// transport.
    mcp_open = 1,
    /// One exchange on a connection. Names the connection.
    mcp_request = 2,
    mcp_notify = 3,
    mcp_close = 4,
    /// The execution half no longer reaches the server through this
    /// transport. Names the transport.
    mcp_release = 5,
    /// A Run's MCP installation request, for the Host to carry out. Names
    /// the Session whose Run made it.
    mcp_install_put = 6,
    mcp_install_wake = 7,
    /// A Run's file delivery, image and video effects, which stay with the
    /// Host. Each names the Session and carries the Run.
    delivery_inspect = 8,
    media_credential_read = 9,
    media_perform = 10,
    image_commit = 11,
    video_commit = 12,
};

pub const MediaTool = enum { image, video };

/// A Run's image generation binding, but its effects: the transport, the
/// credential reader and the output stay with the Host and are called back.
/// The credential is the copy execution needs, as a model binding's is.
pub const ImageRun = struct {
    endpoint: []const u8,
    source: []const u8,
    model: []const u8,
    credential: []const u8,
    renews_credential: bool,
};

pub const VideoRun = struct {
    endpoint: []const u8,
    source: []const u8,
    model: []const u8,
};

pub const HttpRequest = struct {
    url: []const u8,
    headers: []const contract.http_transport.Header,
    body: []const u8,
    method: @FieldType(contract.http_transport.HttpRequest, "method"),
    streams: bool,
    connect_timeout_ms: u32,
    source: []const u8,
};

/// `transport.Error`, as data.
pub const HttpFailure = enum {
    Cancelled,
    DnsFailed,
    ConnectFailed,
    TlsFailed,
    WriteFailed,
    ReadFailed,
    InvalidHttp,
    ResponseTooLarge,
    ResourceLimit,
    OutOfMemory,
    Unexpected,
};

comptime {
    for (@typeInfo(contract.http_transport.Error).error_set.?) |member| {
        if (!@hasField(HttpFailure, member.name)) @compileError("HttpFailure lacks " ++ member.name);
    }
}

pub const HttpOutcome = union(enum) {
    response: struct {
        status: u16,
        body: []const u8,
        /// A streamed response, read whole by the Host, for the Run's
        /// receiver to read once the request is over.
        stream: ?struct { content_type: ?[]const u8, content_length: ?u64, bytes: []const u8 },
    },
    failure: HttpFailure,
};

/// That a Run may ask the Host to install an MCP server, for this Task. The
/// capability itself stays with the UI half.
pub const McpInstallation = struct {
    task_id: u64,
};

/// One MCP member as the execution half stands in for it: the transport the
/// UI half keeps, by the UI half's name for it, and everything else about
/// the server.
pub const McpMember = struct {
    transport: u64,
    descriptor: mcp_runtime.ServerDescriptor,
};

pub const McpMembership = struct {
    generation: u64,
    members: []const McpMember,
};

pub const McpActivationOutcome = union(enum) {
    empty,
    activated: mcp_catalog.ActivationWire,
    unavailable: surface.McpActivationUnavailableReason,
};

/// What `capture_restore_inputs` captures, as data. The skill part is its
/// grants: its lease is the one the Session was bound with, which the UI half
/// already names.
pub const RestoreInputs = struct {
    skill: ?[]const []const u8,
    mcp: ?mcp_catalog.RestoreSelectionWire,
    permission_mode: control.PermissionMode,
    shell_policy: control.ShellPolicy,
    permission_interaction: surface.PermissionInteraction,
};

/// A skill catalog query without its source lifetime: the UI half keeps that
/// pinned for as long as anything there refers to the lease.
pub const SkillQuery = struct {
    canonical_user_home: []const u8,
    target: contract.CatalogQueryTarget,
    additional_sources: []const contract.CatalogSource,
    default_source_priority: i32,
};

pub const SkillAcquisition = struct {
    lease: u64,
    revision: []const u8,
    health: contract.CatalogHealth,
    skills: []const contract.CatalogSkill,
    issues: []const contract.CatalogIssue,
};

pub const McpOpened = union(enum) {
    connection: u64,
    failure: mcp_connector.Failure,
};

pub const McpExchanged = union(enum) {
    response: struct { http_status: u32, body: []const u8 },
    failure: mcp_connector.Failure,
};

/// A `control` frame. Never fragmented, so each one passes a data message in
/// flight within one fragment.
pub const Control = union(enum) {
    /// UI half to execution half: the room made for events, as totals.
    credit: Credit,
    /// UI half to execution half: answer with a `pong` of the same number.
    ping: u64,
    /// Execution half to UI half.
    pong: u64,
    /// Execution half to UI half: the callback under this correlation is no
    /// longer wanted. Its answer still comes.
    cancel: u64,
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
    /// What a media tool wrote or a delivery verified, which the Agent
    /// attaches to the event, never read from the event's JSON.
    generated_image_path: ?[]const u8,
    generated_video_path: ?[]const u8,
    delivered_file: ?contract.FileDeliveryReceipt,
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

/// The method set a method belongs to. An untyped literal is a `Method`.
fn Set(comptime method: anytype) type {
    const T = @TypeOf(method);
    return if (T == @TypeOf(.enum_literal)) Method else T;
}

/// A request's body type, for either direction's method set.
pub fn Request(comptime method: anytype) type {
    return switch (Set(method)) {
        Method => MethodRequest(method),
        Callback => CallbackRequest(method),
        else => @compileError("not a link method"),
    };
}

/// A response's body type, for either direction's method set.
pub fn Response(comptime method: anytype) type {
    return switch (Set(method)) {
        Method => MethodResponse(method),
        Callback => CallbackResponse(method),
        else => @compileError("not a link method"),
    };
}

fn CallbackRequest(comptime callback: Callback) type {
    return switch (callback) {
        .mcp_open => struct { purpose: mcp_connector.Purpose, era: mcp_connector.Era, timeout_ms: u32 },
        .mcp_request => struct { bytes: []const u8, timeout_ms: u32, tool: bool },
        .mcp_notify => struct { bytes: []const u8, timeout_ms: u32 },
        .mcp_close, .mcp_release, .mcp_install_wake => Empty,
        .mcp_install_put => struct { task_id: u64, run_id: u64, generation: u64, json: []const u8 },
        .delivery_inspect => struct { run_id: u64, path: []const u8 },
        .media_credential_read => struct { run_id: u64, tool: MediaTool, capacity: u32 },
        .media_perform => struct { run_id: u64, tool: MediaTool, request: HttpRequest, response_capacity: u64 },
        .image_commit => struct { run_id: u64, bytes: []const u8, format: contract.image_generation.Format },
        .video_commit => struct { run_id: u64, bytes: []const u8, length: ?u64 },
    };
}

fn CallbackResponse(comptime callback: Callback) type {
    return switch (callback) {
        .mcp_open => McpOpened,
        .mcp_request => McpExchanged,
        .mcp_notify => ?mcp_connector.Failure,
        .mcp_close, .mcp_release, .mcp_install_wake => void,
        .mcp_install_put => contract.McpInstallationResult,
        .delivery_inspect => contract.FileDeliveryInspection,
        .media_credential_read => ?[]const u8,
        .media_perform => HttpOutcome,
        .image_commit => contract.image_generation.OutputResult,
        .video_commit => contract.generate_video.Outcome,
    };
}

fn MethodRequest(comptime method: Method) type {
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
        .set_instructions => surface.Instructions,
        .update_credential => struct { credential: []const u8 },
        .request_termination => struct { run_id: u64, signal: control.TerminationSignal },
        .prepare_run => struct {
            input: surface.RunInput,
            mcp_installation: ?McpInstallation,
            image: ?ImageRun,
            video: ?VideoRun,
            delivery: bool,
        },
        .begin_run, .cancel_prepared_run, .fail_ui_request_identity_contract => struct { run_id: u64 },
        .cancel_prepared_compact, .execute_prepared_compact => struct { operation_id: u64 },
        .request_compact_cancellation => struct { operation_id: u64, interruption: control.ExternalInterruption },
        .respond_permission => struct { run_id: u64, request_id: u64, choice: contract.PermissionChoice },
        .export_checkpoint => ExportRequest,
        .run_execute, .run_input_observation => struct { run_id: u64, generation: u64 },
        .run_submit_input => struct { run_id: u64, generation: u64, input_id: u64, text: []const u8 },
        .run_request_termination => struct { run_id: u64, generation: u64, signal: control.TerminationSignal },
        .activate_mcp, .capture_restore_inputs => Empty,
        .create_mcp_admission_selection => struct {
            activation: mcp_catalog.ActivationWire,
            allowlists: []const mcp_catalog.ServerAllowlist,
        },
        .prepare_mcp_restore_selection => struct {
            original: mcp_catalog.RestoreSelectionWire,
            activation: mcp_catalog.ActivationWire,
            ceiling: []const mcp_catalog.ActivationTool,
        },
        .apply_mcp_configuration, .probe_mcp => McpMembership,
        .query_skill_catalog => SkillQuery,
        .release_skill_catalog => Empty,
        .refresh_skill_catalog, .skill_policy_matches => struct { lease: u64, policy: surface.SkillPolicyInput },
    };
}

fn MethodResponse(comptime method: Method) type {
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
        .set_instructions => surface.InstructionsApplied,
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
        .activate_mcp, .probe_mcp => McpActivationOutcome,
        .create_mcp_admission_selection => ?mcp_catalog.SelectionWire,
        .prepare_mcp_restore_selection => mcp_catalog.SelectionWire,
        .apply_mcp_configuration => surface.McpConfigurationApplyOutcome,
        .capture_restore_inputs => RestoreInputs,
        .query_skill_catalog => SkillAcquisition,
        .release_skill_catalog, .refresh_skill_catalog => void,
        .skill_policy_matches => bool,
    };
}

comptime {
    @setEvalBranchQuota(10_000_000);
    for (std.enums.values(Method)) |method| {
        payload.requireStructural(Request(method));
        const Out = Response(method);
        if (Out != void) payload.requireStructural(Out);
    }
    for (std.enums.values(Callback)) |callback| {
        payload.requireStructural(Request(callback));
        const Out = Response(callback);
        if (Out != void) payload.requireStructural(Out);
    }
    payload.requireStructural(Event);
    payload.requireStructural(Control);
}

// ---------------------------------------------------------------------------
// Requests
// ---------------------------------------------------------------------------

pub const request_header_bytes: usize = 2 + 8;

pub fn encodeRequest(
    comptime method: anytype,
    allocator: std.mem.Allocator,
    handle: u64,
    value: Request(method),
) std.mem.Allocator.Error![]u8 {
    const body_len = payload.encodedSize(Request(method), value);
    const buffer = try allocator.alloc(u8, request_header_bytes + body_len);
    std.mem.writeInt(u16, buffer[0..2], @intFromEnum(@as(Set(method), method)), .little);
    std.mem.writeInt(u64, buffer[2..10], handle, .little);
    const written = payload.encode(Request(method), value, buffer[request_header_bytes..]);
    std.debug.assert(written == body_len);
    return buffer;
}

pub fn Header(comptime M: type) type {
    return struct {
        method: M,
        handle: u64,
        body: []const u8,
    };
}

pub const Received = Header(Method);

pub const HeaderError = error{ Truncated, UnknownMethod };

/// A request's header, read as `M`: `Method` on the execution half,
/// `Callback` on the UI half.
pub fn decodeHeader(comptime M: type, bytes: []const u8) HeaderError!Header(M) {
    if (bytes.len < request_header_bytes) return error.Truncated;
    const raw = std.mem.readInt(u16, bytes[0..2], .little);
    const method = std.enums.fromInt(M, raw) orelse return error.UnknownMethod;
    return .{
        .method = method,
        .handle = std.mem.readInt(u64, bytes[2..10], .little),
        .body = bytes[request_header_bytes..],
    };
}

pub fn decodeRequestHeader(bytes: []const u8) HeaderError!Received {
    return decodeHeader(Method, bytes);
}

pub fn decodeRequest(
    comptime method: anytype,
    arena: std.mem.Allocator,
    body: []const u8,
) payload.DecodeError!Request(method) {
    return payload.decodeExact(Request(method), arena, body);
}

// ---------------------------------------------------------------------------
// Responses
// ---------------------------------------------------------------------------

pub fn encodeOk(
    comptime method: anytype,
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

pub fn Answer(comptime method: anytype) type {
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
    comptime method: anytype,
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

/// The options as the wire carries them, with `skill_lease` the execution
/// half's name for the lease `value` binds. The selection's selectors are
/// rebuilt in `scratch`; everything else borrows from `value`.
pub fn openOptionsToWire(
    value: surface.SessionOpenOptions,
    skill_lease: ?u64,
    scratch: std.mem.Allocator,
) std.mem.Allocator.Error!shapes.SessionOpenOptions {
    std.debug.assert((value.skill_catalog == null) == (skill_lease == null));
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
        .skill_catalog = skill_lease,
        .skill_policy = value.skill_policy,
        .mcp_selection = if (value.mcp_selection) |selection|
            try mcp_catalog.selectionToWire(selection, scratch)
        else
            null,
        .operation_id_floor = value.operation_id_floor,
    };
}

/// Options received over the link, and the selection copy they name, which
/// the receiver frees once the Session they open has taken what it needs.
pub const OpenOptions = struct {
    options: surface.SessionOpenOptions,
    selection: ?*mcp_catalog.Selection,

    pub fn deinit(self: *OpenOptions) void {
        if (self.selection) |selection| selection.deinit();
        self.* = undefined;
    }
};

/// `skill_lease` is the lease the options name, resolved by the receiver.
pub fn openOptionsFromWire(
    value: shapes.SessionOpenOptions,
    skill_lease: ?*contract.CatalogLease,
    allocator: std.mem.Allocator,
) std.mem.Allocator.Error!OpenOptions {
    std.debug.assert((value.skill_catalog == null) == (skill_lease == null));
    const selection = if (value.mcp_selection) |wire_selection|
        try mcp_catalog.selectionFromWire(allocator, wire_selection)
    else
        null;
    return .{
        .options = .{
            .task_id = value.task_id,
            .binding_epoch = value.binding_epoch,
            .model_binding = value.model_binding,
            .permission_mode = value.permission_mode,
            .shell_policy = value.shell_policy,
            .permission_interaction = value.permission_interaction,
            .workspace = value.workspace,
            .canonical_user_home = value.canonical_user_home,
            .workspace_epoch = value.workspace_epoch,
            .skill_catalog = skill_lease,
            .skill_policy = value.skill_policy,
            .mcp_selection = selection,
            .operation_id_floor = value.operation_id_floor,
        },
        .selection = selection,
    };
}

pub fn activationOutcomeToWire(
    value: surface.McpActivationOutcome,
    scratch: std.mem.Allocator,
) std.mem.Allocator.Error!McpActivationOutcome {
    return switch (value) {
        .empty => .empty,
        .unavailable => |reason| .{ .unavailable = reason },
        .activated => |activation| .{ .activated = try mcp_catalog.activationToWire(activation, scratch) },
    };
}

/// The receiver owns the activation in the result.
pub fn activationOutcomeFromWire(
    value: McpActivationOutcome,
    allocator: std.mem.Allocator,
    io: std.Io,
) std.mem.Allocator.Error!surface.McpActivationOutcome {
    return switch (value) {
        .empty => .empty,
        .unavailable => |reason| .{ .unavailable = reason },
        .activated => |activation| .{ .activated = try mcp_catalog.activationFromWire(allocator, io, activation) },
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

test "a Run's selected Skill crosses with its parts" {
    const skill_id = "0123456789abcdef" ** 4;
    const parts = [_]contract.InputPart{
        .{ .text = "Summarize by month" },
        .{ .text_attachment = .{ .display_name = "sales.xlsx", .bytes = "reference" } },
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    for ([_]?surface.SelectedSkill{ .{ .skill_id = skill_id, .invocation_name = "xlsx" }, null }) |selected| {
        const bytes = try encodeRequest(.prepare_run, testing.allocator, 9, .{
            .input = .{ .multimodal = .{ .parts = &parts, .selected_skill = selected } },
            .mcp_installation = null,
            .image = null,
            .video = null,
            .delivery = false,
        });
        defer testing.allocator.free(bytes);
        const received = try decodeRequestHeader(bytes);
        const value = try decodeRequest(.prepare_run, arena.allocator(), received.body);
        const input = value.input.multimodal;
        try testing.expectEqual(@as(usize, 2), input.parts.len);
        try testing.expectEqualStrings("Summarize by month", input.parts[0].text);
        try testing.expectEqualStrings("reference", input.parts[1].text_attachment.bytes);
        if (selected) |expected| {
            try testing.expectEqualStrings(expected.skill_id, input.selected_skill.?.skill_id);
            try testing.expectEqualStrings(expected.invocation_name, input.selected_skill.?.invocation_name);
        } else try testing.expect(input.selected_skill == null);
    }
}

test "user instruction documents cross whole, both at their limit, and the answer says what Core took" {
    const path = "/home/user/.metawork/AGENTS.md";
    const text = try testing.allocator.alloc(u8, surface.max_instruction_text_bytes);
    defer testing.allocator.free(text);
    for (text, 0..) |*byte, index| byte.* = 'a' + @as(u8, @intCast(index % 26));
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cases = [_]surface.Instructions{
        .{ .global = .{ .path = path, .text = text, .truncated = true }, .project = .{ .path = "D:\\repo\\AGENTS.md", .text = text, .truncated = false } },
        .{ .project = .{ .path = "D:\\repo\\AGENTS.md", .text = "only the project", .truncated = false } },
        .{},
    };
    for (cases) |sent| {
        const bytes = try encodeRequest(.set_instructions, testing.allocator, 5, sent);
        defer testing.allocator.free(bytes);
        // Larger than one frame, so the request is carried in fragments.
        if (sent.global != null) try testing.expect(bytes.len > @import("frame.zig").max_fragment_payload_bytes);
        const received = try decodeRequestHeader(bytes);
        try testing.expectEqual(Method.set_instructions, received.method);
        const value = try decodeRequest(.set_instructions, arena.allocator(), received.body);
        for ([_]?surface.InstructionDocument{ sent.global, sent.project }, [_]?surface.InstructionDocument{ value.global, value.project }) |expected, actual| {
            if (expected) |document| {
                try testing.expectEqualStrings(document.path, actual.?.path);
                try testing.expectEqualStrings(document.text, actual.?.text);
                try testing.expectEqual(document.truncated, actual.?.truncated);
            } else try testing.expect(actual == null);
        }
    }
    const applied = try encodeOk(.set_instructions, testing.allocator, .{ .global = true, .project = false });
    defer testing.allocator.free(applied);
    try testing.expectEqual(
        surface.InstructionsApplied{ .global = true, .project = false },
        (try decodeResponse(.set_instructions, arena.allocator(), applied)).ok,
    );
    const refused = try encodeError(testing.allocator, error.InstructionsUpdateFailed);
    defer testing.allocator.free(refused);
    try testing.expectEqual(
        @as(error_code.LinkError, error.InstructionsUpdateFailed),
        (try decodeResponse(.set_instructions, arena.allocator(), refused)).err,
    );
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
    const event: Event = .{
        .session_id = 1 << 32,
        .run_id = 3,
        .encoded_bytes = 5,
        .json = "{}",
        .generated_image_path = "images/one.png",
        .generated_video_path = null,
        .delivered_file = null,
    };
    const bytes = try payload.encodeAlloc(Event, testing.allocator, event);
    defer testing.allocator.free(bytes);
    const back = try payload.decodeExact(Event, arena.allocator(), bytes);
    try testing.expectEqual(event.session_id, back.session_id);
    try testing.expectEqualStrings("{}", back.json);
    try testing.expectEqualStrings("images/one.png", back.generated_image_path.?);

    const credit: Credit = .{ .count = 448, .bytes = 30 << 20 };
    const credit_bytes = try payload.encodeAlloc(Credit, testing.allocator, credit);
    defer testing.allocator.free(credit_bytes);
    try testing.expectEqual(credit, try payload.decodeExact(Credit, arena.allocator(), credit_bytes));
}

test "a callback is read with the callback set, and a control frame says which it is" {
    const bytes = try encodeRequest(Callback.mcp_request, testing.allocator, 9, .{ .bytes = "{}", .timeout_ms = 5, .tool = true });
    defer testing.allocator.free(bytes);
    const received = try decodeHeader(Callback, bytes);
    try testing.expectEqual(Callback.mcp_request, received.method);
    try testing.expectEqual(@as(u64, 9), received.handle);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const value = try decodeRequest(Callback.mcp_request, arena.allocator(), received.body);
    try testing.expectEqualStrings("{}", value.bytes);
    try testing.expect(value.tool);

    const answer = try encodeOk(Callback.mcp_request, testing.allocator, .{ .failure = .cancelled });
    defer testing.allocator.free(answer);
    try testing.expectEqual(
        mcp_connector.Failure.cancelled,
        (try decodeResponse(Callback.mcp_request, arena.allocator(), answer)).ok.failure,
    );

    for ([_]Control{ .{ .ping = 3 }, .{ .pong = 3 }, .{ .cancel = 77 }, .{ .credit = .{ .count = 1, .bytes = 2 } } }) |sent| {
        const encoded = try payload.encodeAlloc(Control, testing.allocator, sent);
        defer testing.allocator.free(encoded);
        try testing.expectEqualDeep(sent, try payload.decodeExact(Control, arena.allocator(), encoded));
    }
}
