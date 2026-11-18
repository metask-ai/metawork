//! Revision 27 `rewind_to_user_message` against the canonical bundle.
//! Driven by run-agentcore-rewind-probe.mjs. Answers one load-bearing
//! question before #114 designs anything on top of the call: whether an
//! exported checkpoint carries the rewound Conversation or the pre-rewind
//! one. The ABI documents the call but says nothing about export, and
//! MetaWork treats checkpoint bytes as opaque, so the answer can only be
//! measured. Everything else the probe prints -- the describe counters
//! either side of the call, which positions are user messages, and the
//! rejection status for each refused position -- pins the numbers the
//! position mapping in #114 depends on.
const std = @import("std");
const builtin = @import("builtin");
const agentcore = @import("metask_agentcore");
const wire = agentcore.types;

const checkpoint_capacity = 1024 * 1024;
const short_read_limit = 97;

const Sink = struct {
    bytes: [checkpoint_capacity]u8 = undefined,
    len: usize = 0,
    calls: u64 = 0,

    fn write(context: ?*anyopaque, chunk: wire.BytesViewV1) callconv(.c) u32 {
        const self: *Sink = @ptrCast(@alignCast(context orelse return wire.CHECKPOINT_IO_FATAL));
        const bytes = agentcore.borrowedBytes(chunk) catch return wire.CHECKPOINT_IO_FATAL;
        if (bytes.len > self.bytes.len - self.len) return wire.CHECKPOINT_IO_FAILED;
        @memcpy(self.bytes[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
        self.calls += 1;
        return wire.CHECKPOINT_IO_OK;
    }
};

const Source = struct {
    bytes: []const u8,
    offset: usize = 0,
    calls: u64 = 0,
    eof_calls: u64 = 0,

    fn read(
        context: ?*anyopaque,
        destination: ?[*]u8,
        capacity: u64,
        out_len: ?*u64,
    ) callconv(.c) u32 {
        const self: *Source = @ptrCast(@alignCast(context orelse return wire.CHECKPOINT_IO_FATAL));
        const output = out_len orelse return wire.CHECKPOINT_IO_FATAL;
        output.* = 0;
        self.calls += 1;
        if (self.offset == self.bytes.len) {
            self.eof_calls += 1;
            return wire.CHECKPOINT_IO_OK;
        }
        const destination_capacity = std.math.cast(usize, capacity) orelse
            return wire.CHECKPOINT_IO_FATAL;
        if (destination_capacity == 0) return wire.CHECKPOINT_IO_FATAL;
        const output_pointer = destination orelse return wire.CHECKPOINT_IO_FATAL;
        const count = @min(
            @min(self.bytes.len - self.offset, destination_capacity),
            short_read_limit,
        );
        @memcpy(output_pointer[0..count], self.bytes[self.offset..][0..count]);
        self.offset += count;
        output.* = count;
        return wire.CHECKPOINT_IO_OK;
    }
};

/// Every describe field #114 reads, captured so the probe can prove a
/// refused position changed nothing.
const Snapshot = struct {
    session_id: []u8,
    model: []u8,
    last_run_id: u64,
    last_compact_id: u64,
    checkpoint_generation: u64,
    policy_generation: u64,
    message_count: u64,
    compact_boundary: u64,

    fn deinit(self: Snapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        allocator.free(self.model);
    }

    fn report(self: Snapshot, label: []const u8) void {
        std.debug.print(
            "rewind-probe describe {s}: message_count={d} compact_boundary={d} last_run_id={d} last_compact_id={d} checkpoint_generation={d} policy_generation={d}\n",
            .{
                label,
                self.message_count,
                self.compact_boundary,
                self.last_run_id,
                self.last_compact_id,
                self.checkpoint_generation,
                self.policy_generation,
            },
        );
    }

    /// The conversation-shaped fields only. A refused position must leave
    /// every one of them where it was.
    fn sameConversation(self: Snapshot, other: Snapshot) bool {
        return self.message_count == other.message_count and
            self.compact_boundary == other.compact_boundary and
            self.last_run_id == other.last_run_id and
            self.last_compact_id == other.last_compact_id and
            self.checkpoint_generation == other.checkpoint_generation and
            self.policy_generation == other.policy_generation and
            std.mem.eql(u8, self.session_id, other.session_id) and
            std.mem.eql(u8, self.model, other.model);
    }
};

fn onEvent(
    _: ?*anyopaque,
    _: ?*const wire.RunContextV1,
    _: wire.BytesViewV1,
) callconv(.c) u32 {
    return wire.EVENT_CONTINUE;
}

fn onUiRequest(
    _: ?*anyopaque,
    _: ?*const wire.RunContextV1,
    _: wire.BytesViewV1,
    out_response: ?*wire.OwnedBytesV1,
) callconv(.c) u32 {
    if (out_response) |output| output.* = emptyOwnedBytes();
    return wire.UI_UNAVAILABLE;
}

fn releaseResponse(_: ?*anyopaque, response: ?*wire.OwnedBytesV1) callconv(.c) void {
    if (response) |output| output.* = emptyOwnedBytes();
}

fn makeRuntime(api: agentcore.Api) !*wire.RuntimeHandle {
    const builtin_names = [_][]const u8{
        "Read",
        "Write",
        "Edit",
        "Glob",
        "Grep",
        "Bash",
        "BashOutput",
        "KillShell",
        "AskUserQuestion",
        "WebSearch",
        "WebFetch",
    };
    var builtin_views: [builtin_names.len]wire.BytesViewV1 = undefined;
    for (builtin_names, 0..) |name, index| builtin_views[index] = agentcore.bytesView(name);
    var config = std.mem.zeroes(wire.RuntimeConfigV1);
    config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    config.builtin_tools = &builtin_views;
    config.builtin_tool_count = builtin_views.len;
    var runtime: ?*wire.RuntimeHandle = null;
    try expectStatus(api, "runtime_create", api.runtime().create()(&config, null, &runtime, null));
    return runtime orelse error.MissingRuntime;
}

fn makeHostConfig() wire.SessionHostConfigV1 {
    const workspace = if (builtin.os.tag == .windows) "C:\\" else "/";
    var host = std.mem.zeroes(wire.SessionHostConfigV1);
    host.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host.provider_kind_code = wire.PROVIDER_OPENAI;
    host.permission_mode_code = wire.PERMISSION_DEFAULT;
    host.shell_policy_code = wire.SHELL_DISABLED;
    host.api_key = agentcore.bytesView("probe-not-used");
    host.base_url = agentcore.bytesView("https://api.openai.com/v1");
    host.workspace_root = agentcore.bytesView(workspace);
    host.workspace_home = agentcore.bytesView(workspace);
    return host;
}

fn makeCallbacks() wire.SessionCallbacksV1 {
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.on_event = onEvent;
    callbacks.on_ui_request = onUiRequest;
    callbacks.release_response = releaseResponse;
    return callbacks;
}

fn makeLimits() wire.CheckpointLimitsV1 {
    var limits = std.mem.zeroes(wire.CheckpointLimitsV1);
    limits.struct_size = @sizeOf(wire.CheckpointLimitsV1);
    limits.hard_bytes = checkpoint_capacity;
    limits.max_section_bytes = checkpoint_capacity / 2;
    limits.max_string_bytes = 64 * 1024;
    limits.max_messages = 128;
    limits.max_blocks_per_message = 128;
    limits.chunk_bytes = 127;
    return limits;
}

fn describe(
    allocator: std.mem.Allocator,
    api: agentcore.Api,
    session: *wire.SessionHandle,
) !Snapshot {
    var encoded = emptyOwnedBytes();
    defer releaseOwned(api, &encoded);
    try expectStatus(api, "session_describe", api.sessionControl().describe()(session, &encoded, null));
    const bytes = try agentcore.borrowedBytes(.{ .ptr = encoded.ptr, .len = encoded.len });
    var parsed = try agentcore.decodeSessionDescription(allocator, bytes);
    defer parsed.deinit();
    const session_id = try allocator.dupe(u8, parsed.value.session_id);
    errdefer allocator.free(session_id);
    return .{
        .session_id = session_id,
        .model = try allocator.dupe(u8, parsed.value.model),
        .last_run_id = parsed.value.last_run_id,
        .last_compact_id = parsed.value.last_compact_id,
        .checkpoint_generation = parsed.value.checkpoint_generation,
        .policy_generation = parsed.value.policy_generation,
        .message_count = parsed.value.conversation.message_count,
        .compact_boundary = parsed.value.conversation.compact_boundary,
    };
}

fn destroySession(api: agentcore.Api, session: *wire.SessionHandle) !void {
    try expectStatus(api, "session_destroy", api.session().destroy()(session, null));
}

fn destroyRuntime(api: agentcore.Api, runtime: *wire.RuntimeHandle) !void {
    try expectStatus(api, "runtime_destroy", api.runtime().destroy()(runtime, null));
}

fn expectStatus(api: agentcore.Api, operation: []const u8, status_code: u32) !void {
    _ = api;
    const status = agentcore.Status.fromCode(status_code) catch {
        std.debug.print("{s} returned unknown status {d}\n", .{ operation, status_code });
        return error.UnknownStatus;
    };
    if (status != .ok) {
        std.debug.print("{s} returned {s}\n", .{ operation, @tagName(status) });
        return error.AgentCoreCallFailed;
    }
}

fn emptyOwnedBytes() wire.OwnedBytesV1 {
    return .{ .ptr = null, .len = 0 };
}

fn releaseOwned(api: agentcore.Api, bytes: *wire.OwnedBytesV1) void {
    if (bytes.ptr != null or bytes.len != 0) api.bufferRelease()(bytes);
}

fn runText(api: agentcore.Api, session: *wire.SessionHandle, id: u64, text: []const u8) !void {
    var options = std.mem.zeroes(wire.RunOptionsV1);
    options.struct_size = @sizeOf(wire.RunOptionsV1);
    options.max_turns = 1;
    var result = std.mem.zeroes(wire.RunResultV1);
    var diagnostic = emptyOwnedBytes();
    defer releaseOwned(api, &diagnostic);
    try expectStatus(api, "conversation_run", api.session().runText(session, id, agentcore.bytesView(text), &options, &result, &diagnostic));
    if (try agentcore.StopReason.fromCode(result.stop_reason_code) != .end_turn)
        return error.ConversationRunFailed;
}

/// One rewind attempt, reported with its diagnostic length. The caller
/// decides whether the status is the expected one.
fn rewind(
    api: agentcore.Api,
    session: *wire.SessionHandle,
    position: u64,
    label: []const u8,
) !agentcore.Status {
    var diagnostic = emptyOwnedBytes();
    defer releaseOwned(api, &diagnostic);
    const status_code = api.sessionControl().rewindToUserMessage()(session, position, &diagnostic);
    const status = agentcore.Status.fromCode(status_code) catch {
        std.debug.print(
            "rewind-probe rewind {s} position={d} unknown status {d}\n",
            .{ label, position, status_code },
        );
        return error.UnknownStatus;
    };
    std.debug.print(
        "rewind-probe rewind {s}: position={d} status={s} diagnostic_bytes={d}\n",
        .{ label, position, @tagName(status), diagnostic.len },
    );
    return status;
}

/// A refused position must change nothing. Re-describe and compare every
/// conversation-shaped field, not just the count.
fn expectRefused(
    allocator: std.mem.Allocator,
    api: agentcore.Api,
    session: *wire.SessionHandle,
    position: u64,
    label: []const u8,
    expected: agentcore.Status,
    before: Snapshot,
) !void {
    const status = try rewind(api, session, position, label);
    if (status != expected) {
        std.debug.print(
            "rewind-probe expected {s} at position {d}, got {s}\n",
            .{ @tagName(expected), position, @tagName(status) },
        );
        return error.UnexpectedRewindStatus;
    }
    var after = try describe(allocator, api, session);
    defer after.deinit(allocator);
    if (!after.sameConversation(before)) {
        after.report("after refused rewind");
        return error.RefusedRewindChangedSession;
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    const api = try agentcore.Api.discover();

    // The SDK's own required-surface check rejects a bundle whose
    // session_control table has a null rewind slot, so discovery succeeding
    // is already the answer. Print the raw slot anyway: the Agent method in
    // #114 should not carry a null branch this bundle cannot reach.
    std.debug.print(
        "rewind-probe surface: abi_revision={d} rewind_slot_non_null={}\n",
        .{ api.raw.abi_revision, api.sessionControl().raw.rewind_to_user_message != null },
    );

    const callbacks = makeCallbacks();
    var host = makeHostConfig();
    host.base_url = agentcore.bytesView(
        init.environ_map.get("METAWORK_REWIND_PROBE_URL") orelse return error.MissingFixtureUrl,
    );
    const limits = makeLimits();

    const first_runtime = try makeRuntime(api);
    var first_runtime_live = true;
    defer if (first_runtime_live) destroyRuntime(api, first_runtime) catch {};

    var create_config = std.mem.zeroes(wire.SessionCreateConfigV1);
    create_config.struct_size = @sizeOf(wire.SessionCreateConfigV1);
    create_config.host = &host;
    create_config.model = agentcore.bytesView("gpt-5-mini");
    var first_session: ?*wire.SessionHandle = null;
    try expectStatus(api, "session_create", api.session().create()(
        first_runtime,
        &create_config,
        &callbacks,
        &first_session,
        null,
    ));
    const session = first_session orelse return error.MissingSession;
    var first_session_live = true;
    defer if (first_session_live) destroySession(api, session) catch {};

    // Three measurements of the same counter: empty, after one turn, after
    // two. #114 persists the position of a user message from the count read
    // before its Run is submitted, so both the per-turn increment and the
    // offset between that count and the message's own position have to be
    // measured rather than assumed.
    var empty = try describe(allocator, api, session);
    defer empty.deinit(allocator);
    empty.report("empty session");

    try runText(api, session, 1, "rewind alpha question");
    var after_first = try describe(allocator, api, session);
    defer after_first.deinit(allocator);
    after_first.report("after first turn");

    try runText(api, session, 2, "rewind beta question");
    var before_rewind = try describe(allocator, api, session);
    defer before_rewind.deinit(allocator);
    before_rewind.report("before rewind");

    // Map the history without mutating it. A refused position changes
    // nothing, so NOT_USER_MESSAGE at every even position is proof the odd
    // ones are the user messages -- and the only way to learn the layout
    // short of a rewind that would destroy it.
    try expectRefused(allocator, api, session, 0, "zero", .invalid_argument, before_rewind);
    try expectRefused(
        allocator,
        api,
        session,
        before_rewind.message_count + 1,
        "past the end",
        .message_position_out_of_range,
        before_rewind,
    );
    var position: u64 = 2;
    while (position <= before_rewind.message_count) : (position += 2)
        try expectRefused(
            allocator,
            api,
            session,
            position,
            "even position",
            .not_user_message,
            before_rewind,
        );

    // The second user message. Its position is asserted against the counter
    // read before that turn was submitted, which is the mapping #114 needs.
    const second_user_position = after_first.message_count + 1;
    if (second_user_position > before_rewind.message_count) return error.UnexpectedHistoryLayout;
    const status = try rewind(api, session, second_user_position, "second user message");
    if (status != .ok) return error.RewindRefused;

    var after_rewind = try describe(allocator, api, session);
    defer after_rewind.deinit(allocator);
    after_rewind.report("after rewind");
    if (after_rewind.message_count != second_user_position - 1)
        return error.UnexpectedRewoundCount;

    // The load-bearing question. Export the rewound Session, restore it
    // through the official entry in a fresh Runtime, and read the counter
    // back. MetaWork never parses these bytes, so only the restored
    // describe -- and the Conversation the next Run actually sends -- can
    // say whether the export carried the rewind.
    var sink_context = Sink{};
    var sink = std.mem.zeroes(wire.CheckpointSinkV1);
    sink.struct_size = @sizeOf(wire.CheckpointSinkV1);
    sink.ctx = &sink_context;
    sink.write = Sink.write;
    var export_config = std.mem.zeroes(wire.CheckpointExportConfigV1);
    export_config.struct_size = @sizeOf(wire.CheckpointExportConfigV1);
    export_config.limits = &limits;
    export_config.sink = &sink;
    var export_result = std.mem.zeroes(wire.CheckpointExportResultV1);
    try expectStatus(api, "session_export_checkpoint", api.sessionControl().exportCheckpoint()(
        session,
        &export_config,
        &export_result,
        null,
    ));
    if (sink_context.len == 0 or
        export_result.total_bytes != sink_context.len or
        export_result.chunk_count != sink_context.calls)
        return error.InvalidCheckpointExport;
    std.debug.print(
        "rewind-probe export: bytes={d} chunks={d} checkpoint_generation={d}\n",
        .{ sink_context.len, sink_context.calls, export_result.checkpoint_generation },
    );

    try destroySession(api, session);
    first_session_live = false;
    try destroyRuntime(api, first_runtime);
    first_runtime_live = false;

    const restored_runtime = try makeRuntime(api);
    var restored_runtime_live = true;
    defer if (restored_runtime_live) destroyRuntime(api, restored_runtime) catch {};

    var source_context = Source{ .bytes = sink_context.bytes[0..sink_context.len] };
    var source = std.mem.zeroes(wire.CheckpointSourceV1);
    source.struct_size = @sizeOf(wire.CheckpointSourceV1);
    source.ctx = &source_context;
    source.read = Source.read;
    var restore_config = std.mem.zeroes(wire.SessionRestoreConfigV1);
    restore_config.struct_size = @sizeOf(wire.SessionRestoreConfigV1);
    restore_config.host = &host;
    restore_config.source = &source;
    restore_config.limits = &limits;
    var restored_session: ?*wire.SessionHandle = null;
    var restore_report = emptyOwnedBytes();
    defer releaseOwned(api, &restore_report);
    try expectStatus(api, "session_restore", api.sessionControl().restore()(
        restored_runtime,
        &restore_config,
        &callbacks,
        &restored_session,
        &restore_report,
        null,
    ));
    const restored = restored_session orelse return error.MissingRestoredSession;
    var restored_session_live = true;
    defer if (restored_session_live) destroySession(api, restored) catch {};

    const report_bytes = try agentcore.borrowedBytes(.{
        .ptr = restore_report.ptr,
        .len = restore_report.len,
    });
    var parsed_report = try agentcore.decodeRestoreReport(allocator, report_bytes);
    defer parsed_report.deinit();
    std.debug.print(
        "rewind-probe restore report: health={s} checkpoint_generation={d} session_id_matches={}\n",
        .{
            @tagName(parsed_report.value.health),
            parsed_report.value.checkpoint_generation,
            std.mem.eql(u8, parsed_report.value.session_id, after_rewind.session_id),
        },
    );
    if (parsed_report.value.health != .complete or
        parsed_report.value.checkpoint_generation != export_result.checkpoint_generation or
        !std.mem.eql(u8, parsed_report.value.session_id, after_rewind.session_id))
        return error.InvalidRestoreReport;

    var after_restore = try describe(allocator, api, restored);
    defer after_restore.deinit(allocator);
    after_restore.report("after restore");
    std.debug.print(
        "rewind-probe answer: before_rewind={d} after_rewind={d} after_restore={d} checkpoint_remembers_rewind={}\n",
        .{
            before_rewind.message_count,
            after_rewind.message_count,
            after_restore.message_count,
            after_restore.message_count == after_rewind.message_count,
        },
    );

    // The counter alone would not settle it: the Conversation the restored
    // Session sends to the Provider is what a user would see rerun. The
    // fixture asserts this request carries the first turn and neither half
    // of the dropped one.
    try runText(api, restored, after_restore.last_run_id + 1, "rewind gamma question");
    var after_gamma = try describe(allocator, api, restored);
    defer after_gamma.deinit(allocator);
    after_gamma.report("after post-restore run");

    try destroySession(api, restored);
    restored_session_live = false;
    try destroyRuntime(api, restored_runtime);
    restored_runtime_live = false;

    const compaction = try probeCompaction(allocator, api, &host, &callbacks);

    if (init.environ_map.get("METAWORK_REWIND_PROBE_REPORT")) |file_path| {
        const report = Report{
            .abi_revision = api.raw.abi_revision,
            .rewind_slot_non_null = api.sessionControl().raw.rewind_to_user_message != null,
            .count_empty = empty.message_count,
            .count_after_first_turn = after_first.message_count,
            .count_before_rewind = before_rewind.message_count,
            .rewound_position = second_user_position,
            .count_after_rewind = after_rewind.message_count,
            .count_after_restore = after_restore.message_count,
            .checkpoint_bytes = sink_context.len,
            .checkpoint_remembers_rewind = after_restore.message_count == after_rewind.message_count,
            .compaction = compaction,
        };
        const encoded = try std.json.Stringify.valueAlloc(allocator, report, .{});
        defer allocator.free(encoded);
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = file_path, .data = encoded });
    }

    std.debug.print("rewind-probe passed\n", .{});
}

/// What the probe measured, written out for the runner to assert against.
/// The conclusions are numbers, not prose, so they can be checked rather
/// than read.
const Report = struct {
    abi_revision: u32,
    rewind_slot_non_null: bool,
    count_empty: u64,
    count_after_first_turn: u64,
    count_before_rewind: u64,
    rewound_position: u64,
    count_after_rewind: u64,
    count_after_restore: u64,
    checkpoint_bytes: usize,
    checkpoint_remembers_rewind: bool,
    compaction: Compaction,
};

/// The compaction half. `positions_stable` is the load-bearing one: #114
/// records a position once, at submit time, and never recomputes it, which
/// only works if a compact leaves the numbering alone.
const Compaction = struct {
    engaged: bool,
    turns: u64,
    outcome_code: u32,
    before_context_tokens: u64,
    after_context_tokens: u64,
    count_before: u64,
    count_after: u64,
    boundary_before: u64,
    boundary_after: u64,
    /// message_count unchanged across the compact: the compacted prefix is
    /// still counted, so no position moved.
    positions_stable: bool,
    /// A position recorded before the compact, rewound to after it.
    probed_position: u64,
    probed_position_status: []const u8,
    count_after_probed_rewind: u64,
    /// The marker carried by the user message at `probed_position`. The
    /// runner asserts the Conversation after the rewind no longer has it.
    probed_marker: []const u8,
    position_rewound: bool,
    /// Which status each kind of below-boundary position reported. The
    /// precedence is measured, not documented: 32 outranks 33.
    compacted_user_position: u64,
    compacted_assistant_position: u64,
};

const fill_text_bytes = 256 * 1024;
const max_fill_turns = 18;

/// Varied filler. A long run of one byte would tokenize far cheaper than
/// prose and never reach the model's window, so the bytes have to look like
/// words. The marker sits at both ends so a truncated log still identifies
/// the turn.
fn fillText(allocator: std.mem.Allocator, turn: u64) ![]u8 {
    const buffer = try allocator.alloc(u8, fill_text_bytes);
    errdefer allocator.free(buffer);
    var state: u64 = 0x9e3779b97f4a7c15 ^ turn;
    for (buffer, 0..) |*byte, index| {
        state = state *% 6364136223846793005 +% 1442695040888963407;
        byte.* = if ((index + 1) % 9 == 0) ' ' else 'a' + @as(u8, @intCast((state >> 33) % 26));
    }
    const marker = try fillMarker(allocator, turn);
    defer allocator.free(marker);
    @memcpy(buffer[0..marker.len], marker);
    buffer[marker.len] = ' ';
    @memcpy(buffer[buffer.len - marker.len ..], marker);
    buffer[buffer.len - marker.len - 1] = ' ';
    return buffer;
}

fn fillMarker(allocator: std.mem.Allocator, turn: u64) ![]u8 {
    return std.fmt.allocPrint(allocator, "drift-marker-{d:0>3}", .{turn});
}

/// Compaction is the other premise #114 rests on. If a compact collapsed the
/// prefix and renumbered what follows, every position persisted at submit
/// time would silently name the wrong message afterwards, and the design
/// would need an anchor instead of a number. The canonical policy is
/// best-effort and declines a small Conversation, so the only way to ask is
/// to fill one until it acts: large user messages, a tiny reply each time,
/// and a compact attempt after every turn whose declined `before_context_
/// tokens` reports the climb for free.
fn probeCompaction(
    allocator: std.mem.Allocator,
    api: agentcore.Api,
    host: *const wire.SessionHostConfigV1,
    callbacks: *const wire.SessionCallbacksV1,
) !Compaction {
    const runtime = try makeRuntime(api);
    var runtime_live = true;
    defer if (runtime_live) destroyRuntime(api, runtime) catch {};

    var create_config = std.mem.zeroes(wire.SessionCreateConfigV1);
    create_config.struct_size = @sizeOf(wire.SessionCreateConfigV1);
    create_config.host = host;
    create_config.model = agentcore.bytesView("gpt-5-mini");
    var created: ?*wire.SessionHandle = null;
    try expectStatus(api, "session_create", api.session().create()(
        runtime,
        &create_config,
        callbacks,
        &created,
        null,
    ));
    const session = created orelse return error.MissingSession;
    var session_live = true;
    defer if (session_live) destroySession(api, session) catch {};

    var result = std.mem.zeroes(wire.CompactResultV1);
    var user_positions = [_]u64{0} ** (max_fill_turns + 1);
    var count_before: u64 = 0;
    var boundary_before: u64 = 0;
    var turn: u64 = 1;
    var engaged = false;
    while (turn <= max_fill_turns) : (turn += 1) {
        var before_turn = try describe(allocator, api, session);
        defer before_turn.deinit(allocator);
        // The mapping under test: the position this turn's user message will
        // take, recorded before the Run, exactly as #114 would persist it.
        user_positions[turn] = before_turn.message_count + 1;

        const text = try fillText(allocator, turn);
        defer allocator.free(text);
        try runText(api, session, turn, text);

        var after_turn = try describe(allocator, api, session);
        defer after_turn.deinit(allocator);

        result = std.mem.zeroes(wire.CompactResultV1);
        var diagnostic = emptyOwnedBytes();
        defer releaseOwned(api, &diagnostic);
        const status_code = api.sessionControl().compact()(session, turn, &result, &diagnostic);
        const status = agentcore.Status.fromCode(status_code) catch
            return error.UnknownCompactStatus;
        std.debug.print(
            "rewind-probe fill turn {d}: message_count={d} user_position={d} compact_status={s} outcome_code={d} context_tokens={d}->{d}\n",
            .{
                turn,
                after_turn.message_count,
                user_positions[turn],
                @tagName(status),
                result.outcome_code,
                result.before_context_tokens,
                result.after_context_tokens,
            },
        );
        if (status != .ok) return error.CompactRefused;
        if (result.outcome_code != wire.COMPACT_NO_CHANGE) {
            engaged = true;
            count_before = after_turn.message_count;
            boundary_before = after_turn.compact_boundary;
            break;
        }
    }
    if (!engaged) {
        std.debug.print(
            "rewind-probe compaction: never engaged within {d} turns of {d} bytes\n",
            .{ max_fill_turns, fill_text_bytes },
        );
        return .{
            .engaged = false,
            .turns = max_fill_turns,
            .outcome_code = result.outcome_code,
            .before_context_tokens = result.before_context_tokens,
            .after_context_tokens = result.after_context_tokens,
            .count_before = 0,
            .count_after = 0,
            .boundary_before = 0,
            .boundary_after = 0,
            .positions_stable = false,
            .probed_position = 0,
            .probed_position_status = "not attempted",
            .count_after_probed_rewind = 0,
            .probed_marker = "",
            .position_rewound = false,
            .compacted_user_position = 0,
            .compacted_assistant_position = 0,
        };
    }

    var after_compact = try describe(allocator, api, session);
    defer after_compact.deinit(allocator);
    after_compact.report("after compact");
    const positions_stable = after_compact.message_count == count_before;
    std.debug.print(
        "rewind-probe compaction: turns={d} outcome_code={d} count={d}->{d} boundary={d}->{d} positions_stable={}\n",
        .{
            turn,
            result.outcome_code,
            count_before,
            after_compact.message_count,
            boundary_before,
            after_compact.compact_boundary,
            positions_stable,
        },
    );

    // Code 33, refused first because a refusal changes nothing while the
    // rewind below spends the history. Measured here, and not what the
    // status list alone suggests: under the boundary NOT_USER_MESSAGE wins
    // over MESSAGE_POSITION_COMPACTED, so a below-boundary assistant
    // position reports 32, not 33. Only a user position under the boundary
    // reports 33. That is exactly why #114 must refuse a compacted position
    // locally: without that check, 32 would carry two meanings and could no
    // longer be reported as our own mapping bug.
    var compacted_user_position: u64 = 0;
    var compacted_assistant_position: u64 = 0;
    if (after_compact.compact_boundary > 0) {
        compacted_user_position = if (after_compact.compact_boundary % 2 == 1)
            after_compact.compact_boundary
        else
            after_compact.compact_boundary - 1;
        if (compacted_user_position >= 1) try expectRefused(
            allocator,
            api,
            session,
            compacted_user_position,
            "user message under the boundary",
            .message_position_compacted,
            after_compact,
        );
        if (after_compact.compact_boundary % 2 == 0) {
            compacted_assistant_position = after_compact.compact_boundary;
            try expectRefused(
                allocator,
                api,
                session,
                compacted_assistant_position,
                "assistant reply under the boundary",
                .not_user_message,
                after_compact,
            );
        }
    }

    // The drift verdict. This position was recorded before the compact; if
    // the numbering held, it still names that turn's user message, so the
    // call returns OK and the count lands one below it. A drifted numbering
    // shows up as NOT_USER_MESSAGE, a refusal, or the wrong count.
    const probed = user_positions[turn];
    const marker = try fillMarker(allocator, turn);
    var probed_status = agentcore.Status.ok;
    var count_after_probed: u64 = 0;
    var rewound = false;
    if (probed > after_compact.compact_boundary) {
        probed_status = try rewind(api, session, probed, "pre-compaction position");
        if (probed_status == .ok) {
            var after_probed = try describe(allocator, api, session);
            defer after_probed.deinit(allocator);
            after_probed.report("after rewinding to the pre-compaction position");
            count_after_probed = after_probed.message_count;
            rewound = true;
            // Behavioural confirmation: the runner checks this Run's request
            // no longer carries the marker of the turn just dropped.
            try runText(api, session, turn + 1, "drift tail question");
        }
        std.debug.print(
            "rewind-probe drift: position={d} marker={s} status={s} count_after={d} expected_count={d} verdict={s}\n",
            .{
                probed,
                marker,
                @tagName(probed_status),
                count_after_probed,
                probed - 1,
                if (probed_status == .ok and count_after_probed == probed - 1)
                    "positions did not drift"
                else
                    "POSITIONS DRIFTED",
            },
        );
    } else {
        std.debug.print(
            "rewind-probe drift: position={d} is at or under the boundary {d}; no pre-compaction position survived above it\n",
            .{ probed, after_compact.compact_boundary },
        );
    }

    try destroySession(api, session);
    session_live = false;
    try destroyRuntime(api, runtime);
    runtime_live = false;

    return .{
        .engaged = true,
        .turns = turn,
        .outcome_code = result.outcome_code,
        .before_context_tokens = result.before_context_tokens,
        .after_context_tokens = result.after_context_tokens,
        .count_before = count_before,
        .count_after = after_compact.message_count,
        .boundary_before = boundary_before,
        .boundary_after = after_compact.compact_boundary,
        .positions_stable = positions_stable,
        .probed_position = probed,
        .probed_position_status = @tagName(probed_status),
        .count_after_probed_rewind = count_after_probed,
        .probed_marker = marker,
        .position_rewound = rewound,
        .compacted_user_position = compacted_user_position,
        .compacted_assistant_position = compacted_assistant_position,
    };
}
