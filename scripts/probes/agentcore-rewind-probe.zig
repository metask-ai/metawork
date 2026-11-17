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

    // Compaction is the other premise #114 rests on: a position recorded
    // before a compact must still name the same message afterwards, which
    // holds only if message_count keeps counting the compacted prefix. The
    // canonical policy is best-effort and may well decline a Conversation
    // this small, so this is an observation, not an assertion -- the
    // outcome code says which it was.
    var compact_result = std.mem.zeroes(wire.CompactResultV1);
    var compact_diagnostic = emptyOwnedBytes();
    defer releaseOwned(api, &compact_diagnostic);
    const compact_status_code = api.sessionControl().compact()(
        restored,
        1,
        &compact_result,
        &compact_diagnostic,
    );
    const compact_status = agentcore.Status.fromCode(compact_status_code) catch
        return error.UnknownCompactStatus;
    std.debug.print(
        "rewind-probe compact: status={s} outcome_code={d} before_context_tokens={d} after_context_tokens={d}\n",
        .{
            @tagName(compact_status),
            compact_result.outcome_code,
            compact_result.before_context_tokens,
            compact_result.after_context_tokens,
        },
    );
    if (compact_status == .ok) {
        var after_compact = try describe(allocator, api, restored);
        defer after_compact.deinit(allocator);
        after_compact.report("after compact");
        std.debug.print(
            "rewind-probe compaction: count_before={d} count_after={d} boundary_after={d} prefix_still_counted={}\n",
            .{
                after_gamma.message_count,
                after_compact.message_count,
                after_compact.compact_boundary,
                after_compact.message_count >= after_gamma.message_count,
            },
        );
        if (after_compact.compact_boundary > 0)
            try expectRefused(
                allocator,
                api,
                restored,
                after_compact.compact_boundary,
                "at the compact boundary",
                .message_position_compacted,
                after_compact,
            );
    }

    try destroySession(api, restored);
    restored_session_live = false;
    try destroyRuntime(api, restored_runtime);
    restored_runtime_live = false;

    std.debug.print("rewind-probe passed\n", .{});
}
