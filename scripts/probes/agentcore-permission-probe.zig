const std = @import("std");
const agentcore = @import("metask_agentcore");
const wire = agentcore.types;

const base_url = __BASE_URL__;
const workspace = __WORKSPACE__;
const checkpoint_capacity = 4 * 1024 * 1024;

const UiBehavior = enum {
    allow_once,
    allow_session,
    deny_once,
    unavailable,
};

const RuleFlavor = enum {
    none,
    allow_bash,
    ask_bash,
    deny_bash,
    ask_allow_bash,
    deny_ask_allow_bash,
};

const Probe = struct {
    behavior: UiBehavior,
    ui_calls: u32 = 0,
    ui_releases: u32 = 0,
    provenance: u32 = 0,
    callback_sources: u32 = 0,
    explicit_allow: u32 = 0,
    explicit_deny: u32 = 0,
    session_allow: u32 = 0,
    core_safety: u32 = 0,
    builtin_classification: u32 = 0,
    mode_fallback: u32 = 0,
    unavailable_outcomes: u32 = 0,
    last_source: ?agentcore.protocol.PermissionDecisionSource = null,

    fn sourceCount(self: Probe, source: agentcore.protocol.PermissionDecisionSource) u32 {
        return switch (source) {
            .callback => self.callback_sources,
            .explicit_allow => self.explicit_allow,
            .explicit_deny => self.explicit_deny,
            .session_allow => self.session_allow,
            .core_safety => self.core_safety,
            .builtin_classification => self.builtin_classification,
            .mode_fallback => self.mode_fallback,
            else => 0,
        };
    }

    fn event(
        raw: ?*anyopaque,
        _: ?*const wire.RunContextV1,
        event_json: wire.BytesViewV1,
    ) callconv(.c) u32 {
        const self: *Probe = @ptrCast(@alignCast(raw orelse return wire.EVENT_FATAL));
        const encoded = agentcore.borrowedBytes(event_json) catch return wire.EVENT_FATAL;
        const parsed = agentcore.decodeCoreEvent(std.heap.c_allocator, encoded) catch
            return wire.EVENT_FATAL;
        defer parsed.deinit();
        const event_value = switch (parsed.value) {
            .known => |value| value,
            .unknown => return wire.EVENT_CONTINUE,
        };
        switch (event_value) {
            .permission_provenance => |value| {
                self.provenance += 1;
                self.last_source = value.source;
                switch (value.source) {
                    .callback => self.callback_sources += 1,
                    .explicit_allow => self.explicit_allow += 1,
                    .explicit_deny => self.explicit_deny += 1,
                    .session_allow => self.session_allow += 1,
                    .core_safety => self.core_safety += 1,
                    .builtin_classification => self.builtin_classification += 1,
                    .mode_fallback => self.mode_fallback += 1,
                    else => {},
                }
                if (value.callback_outcome == .unavailable)
                    self.unavailable_outcomes += 1;
            },
            else => {},
        }
        return wire.EVENT_CONTINUE;
    }

    fn ui(
        raw: ?*anyopaque,
        _: ?*const wire.RunContextV1,
        request_json: wire.BytesViewV1,
        out_response: ?*wire.OwnedBytesV1,
    ) callconv(.c) u32 {
        const self: *Probe = @ptrCast(@alignCast(raw orelse return wire.UI_FATAL));
        self.ui_calls += 1;
        const encoded = agentcore.borrowedBytes(request_json) catch return wire.UI_FATAL;
        const parsed = agentcore.decodeUiRequest(std.heap.c_allocator, encoded) catch
            return wire.UI_FATAL;
        defer parsed.deinit();
        const request = switch (parsed.value) {
            .permission => |value| value,
            else => return wire.UI_FATAL,
        };
        if (self.behavior == .unavailable) {
            if (out_response) |output| output.* = emptyOwned();
            return wire.UI_UNAVAILABLE;
        }
        const choice: agentcore.protocol.PermissionChoice = switch (self.behavior) {
            .allow_once => .allow_once,
            .allow_session => .allow_session,
            .deny_once => .deny_once,
            .unavailable => unreachable,
        };
        const rule_id = switch (choice) {
            .allow_session, .deny_session => if (request.candidate) |candidate|
                candidate.rule_id
            else
                return wire.UI_FATAL,
            .allow_once, .deny_once => null,
        };
        const response_json = agentcore.encodeUiResponse(
            std.heap.c_allocator,
            parsed.value,
            .{ .permission = .{
                .permission = choice,
                .request_id = request.request_id,
                .policy_generation = request.policy_generation,
                .rule_id = rule_id,
            } },
        ) catch return wire.UI_FATAL;
        const output = out_response orelse {
            std.heap.c_allocator.free(response_json);
            return wire.UI_FATAL;
        };
        output.* = .{ .ptr = response_json.ptr, .len = response_json.len };
        return wire.UI_ANSWERED;
    }

    fn releaseUi(raw: ?*anyopaque, response: ?*wire.OwnedBytesV1) callconv(.c) void {
        const self: *Probe = @ptrCast(@alignCast(raw orelse return));
        const output = response orelse return;
        if (output.ptr) |ptr| {
            const len = std.math.cast(usize, output.len) orelse return;
            std.heap.c_allocator.free(ptr[0..len]);
            self.ui_releases += 1;
        }
        output.* = emptyOwned();
    }
};

const Sink = struct {
    bytes: []u8,
    len: usize = 0,

    fn write(raw: ?*anyopaque, chunk: wire.BytesViewV1) callconv(.c) u32 {
        const self: *Sink = @ptrCast(@alignCast(raw orelse return wire.CHECKPOINT_IO_FATAL));
        const bytes = agentcore.borrowedBytes(chunk) catch return wire.CHECKPOINT_IO_FATAL;
        if (bytes.len > self.bytes.len - self.len) return wire.CHECKPOINT_IO_FAILED;
        @memcpy(self.bytes[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
        return wire.CHECKPOINT_IO_OK;
    }
};

const Source = struct {
    bytes: []const u8,
    offset: usize = 0,

    fn read(
        raw: ?*anyopaque,
        destination: ?[*]u8,
        capacity: u64,
        out_len: ?*u64,
    ) callconv(.c) u32 {
        const self: *Source = @ptrCast(@alignCast(raw orelse return wire.CHECKPOINT_IO_FATAL));
        const output = out_len orelse return wire.CHECKPOINT_IO_FATAL;
        output.* = 0;
        if (self.offset == self.bytes.len) return wire.CHECKPOINT_IO_OK;
        const destination_len = std.math.cast(usize, capacity) orelse
            return wire.CHECKPOINT_IO_FATAL;
        if (destination_len == 0) return wire.CHECKPOINT_IO_FATAL;
        const target = destination orelse return wire.CHECKPOINT_IO_FATAL;
        const count = @min(destination_len, self.bytes.len - self.offset);
        @memcpy(target[0..count], self.bytes[self.offset..][0..count]);
        self.offset += count;
        output.* = count;
        return wire.CHECKPOINT_IO_OK;
    }
};

fn emptyOwned() wire.OwnedBytesV1 {
    return .{ .ptr = null, .len = 0 };
}

fn releaseOwned(api: agentcore.Api, bytes: *wire.OwnedBytesV1) void {
    if (bytes.ptr != null or bytes.len != 0) api.bufferRelease()(bytes);
    bytes.* = emptyOwned();
}

fn expectOk(api: agentcore.Api, operation: []const u8, status_code: u32, diagnostic: *wire.OwnedBytesV1) !void {
    const status = agentcore.Status.fromCode(status_code) catch return error.UnknownStatus;
    if (status == .ok) return;
    const message = agentcore.borrowedBytes(.{ .ptr = diagnostic.ptr, .len = diagnostic.len }) catch "";
    std.debug.print("{s}: {s} {s}\n", .{ operation, @tagName(status), message });
    releaseOwned(api, diagnostic);
    return error.AgentCoreCallFailed;
}

fn makeCallbacks(probe: *Probe) wire.SessionCallbacksV1 {
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.ctx = probe;
    callbacks.on_event = Probe.event;
    callbacks.on_ui_request = Probe.ui;
    callbacks.release_response = Probe.releaseUi;
    return callbacks;
}

fn makeRules(flavor: RuleFlavor, views: *[1]wire.BytesViewV1, rules: *wire.PermissionRuleSetV1) ?*const wire.PermissionRuleSetV1 {
    rules.* = std.mem.zeroes(wire.PermissionRuleSetV1);
    rules.struct_size = @sizeOf(wire.PermissionRuleSetV1);
    views[0] = agentcore.bytesView("Bash");
    switch (flavor) {
        .none => return null,
        .allow_bash => {
            rules.allow = views;
            rules.allow_count = 1;
        },
        .ask_bash => {
            rules.ask = views;
            rules.ask_count = 1;
        },
        .deny_bash => {
            rules.deny = views;
            rules.deny_count = 1;
        },
        .ask_allow_bash => {
            rules.ask = views;
            rules.ask_count = 1;
            rules.allow = views;
            rules.allow_count = 1;
        },
        .deny_ask_allow_bash => {
            rules.deny = views;
            rules.deny_count = 1;
            rules.ask = views;
            rules.ask_count = 1;
            rules.allow = views;
            rules.allow_count = 1;
        },
    }
    return rules;
}

fn makeHost(
    permission_mode: u32,
    shell_policy: u32,
    rules: ?*const wire.PermissionRuleSetV1,
    allowed_tools: *const [4]wire.BytesViewV1,
) wire.SessionHostConfigV1 {
    var host = std.mem.zeroes(wire.SessionHostConfigV1);
    host.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host.permission_mode_code = permission_mode;
    host.shell_policy_code = shell_policy;
    host.api_key = agentcore.bytesView("permission-probe-key");
    host.base_url = agentcore.bytesView(base_url);
    host.workspace_root = agentcore.bytesView(workspace);
    host.workspace_home = agentcore.bytesView(workspace);
    host.allowed_tools = allowed_tools;
    host.allowed_tool_count = allowed_tools.len;
    host.permission_rules = rules;
    return host;
}

fn createSession(
    api: agentcore.Api,
    runtime: *wire.RuntimeHandle,
    host: *const wire.SessionHostConfigV1,
    callbacks: *const wire.SessionCallbacksV1,
    diagnostic: *wire.OwnedBytesV1,
) !*wire.SessionHandle {
    var config = std.mem.zeroes(wire.SessionCreateConfigV1);
    config.struct_size = @sizeOf(wire.SessionCreateConfigV1);
    config.host = host;
    config.model = agentcore.bytesView("permission-probe-model");
    var session: ?*wire.SessionHandle = null;
    try expectOk(api, "session_create", api.session().create()(
        runtime,
        &config,
        callbacks,
        &session,
        diagnostic,
    ), diagnostic);
    return session orelse error.MissingSession;
}

fn expectShellDisabledRejected(
    api: agentcore.Api,
    runtime: *wire.RuntimeHandle,
    allowed_tools: *const [4]wire.BytesViewV1,
) !void {
    const host = makeHost(wire.PERMISSION_FULL_ACCESS, wire.SHELL_DISABLED, null, allowed_tools);
    var probe = Probe{ .behavior = .unavailable };
    const callbacks = makeCallbacks(&probe);
    var config = std.mem.zeroes(wire.SessionCreateConfigV1);
    config.struct_size = @sizeOf(wire.SessionCreateConfigV1);
    config.host = &host;
    config.model = agentcore.bytesView("permission-probe-model");
    var session: ?*wire.SessionHandle = null;
    var diagnostic = emptyOwned();
    defer releaseOwned(api, &diagnostic);
    const status = api.session().create()(runtime, &config, &callbacks, &session, &diagnostic);
    if (status != wire.STATUS_INVALID_ARGUMENT or session != null)
        return error.ShellDisabledWasNotRejected;
    const message = try agentcore.borrowedBytes(.{ .ptr = diagnostic.ptr, .len = diagnostic.len });
    if (std.mem.indexOf(u8, message, "ShellToolDisabled") == null)
        return error.UnexpectedShellDisabledDiagnostic;
    std.debug.print("scenario=shell_disabled create=invalid_argument diagnostic=ShellToolDisabled\n", .{});
}

fn run(
    api: agentcore.Api,
    session: *wire.SessionHandle,
    run_id: u64,
    scenario: []const u8,
    diagnostic: *wire.OwnedBytesV1,
) !agentcore.StopReason {
    var prompt_buffer: [128]u8 = undefined;
    const prompt = try std.fmt.bufPrint(&prompt_buffer, "scenario:{s}", .{scenario});
    var options = std.mem.zeroes(wire.RunOptionsV1);
    options.struct_size = @sizeOf(wire.RunOptionsV1);
    options.max_turns = 3;
    var result = std.mem.zeroes(wire.RunResultV1);
    try expectOk(api, scenario, api.session().runText(
        session,
        run_id,
        agentcore.bytesView(prompt),
        &options,
        &result,
        diagnostic,
    ), diagnostic);
    return agentcore.StopReason.fromCode(result.stop_reason_code) catch error.UnknownStopReason;
}

fn runFresh(
    api: agentcore.Api,
    runtime: *wire.RuntimeHandle,
    allowed_tools: *const [4]wire.BytesViewV1,
    scenario: []const u8,
    permission_mode: u32,
    shell_policy: u32,
    rule_flavor: RuleFlavor,
    behavior: UiBehavior,
    expected_ui_calls: u32,
    expected_provenance: u32,
    expected_source: agentcore.protocol.PermissionDecisionSource,
) !void {
    var rule_views: [1]wire.BytesViewV1 = undefined;
    var rules: wire.PermissionRuleSetV1 = undefined;
    const host = makeHost(permission_mode, shell_policy, makeRules(rule_flavor, &rule_views, &rules), allowed_tools);
    var probe = Probe{ .behavior = behavior };
    const callbacks = makeCallbacks(&probe);
    var diagnostic = emptyOwned();
    defer releaseOwned(api, &diagnostic);
    const session = try createSession(api, runtime, &host, &callbacks, &diagnostic);
    defer _ = api.session().destroy()(session, null);
    const stop = try run(api, session, 1, scenario, &diagnostic);
    if (stop != .end_turn and stop != .tool_error) return error.UnexpectedStopReason;
    std.debug.print(
        "scenario={s} stop={s} ui={d} provenance={d} source={s} unavailable={d}\n",
        .{
            scenario,
            @tagName(stop),
            probe.ui_calls,
            probe.provenance,
            if (probe.last_source) |source| @tagName(source) else "none",
            probe.unavailable_outcomes,
        },
    );
    try expectProbe(&probe, behavior, expected_ui_calls, expected_provenance, expected_source);
}

fn expectProbe(
    probe: *const Probe,
    behavior: UiBehavior,
    expected_ui_calls: u32,
    expected_provenance: u32,
    expected_source: agentcore.protocol.PermissionDecisionSource,
) !void {
    const expected_releases: u32 = if (behavior == .unavailable) 0 else expected_ui_calls;
    if (probe.ui_calls != expected_ui_calls or probe.ui_releases != expected_releases)
        return error.UnexpectedUiCount;
    const expected_unavailable: u32 = if (behavior == .unavailable and expected_ui_calls != 0) 1 else 0;
    if (probe.unavailable_outcomes != expected_unavailable)
        return error.UnexpectedCallbackOutcome;
    if (probe.provenance != expected_provenance or probe.last_source != expected_source or probe.sourceCount(expected_source) != expected_provenance)
        return error.UnexpectedPermissionProvenance;
}

fn checkpointLimits() wire.CheckpointLimitsV1 {
    var limits = std.mem.zeroes(wire.CheckpointLimitsV1);
    limits.struct_size = @sizeOf(wire.CheckpointLimitsV1);
    limits.hard_bytes = checkpoint_capacity;
    limits.max_section_bytes = checkpoint_capacity / 2;
    limits.max_string_bytes = 256 * 1024;
    limits.max_messages = 256;
    limits.max_blocks_per_message = 64;
    limits.chunk_bytes = 4096;
    return limits;
}

fn exportCheckpoint(
    api: agentcore.Api,
    session: *wire.SessionHandle,
    storage: []u8,
    diagnostic: *wire.OwnedBytesV1,
) ![]const u8 {
    var sink_context = Sink{ .bytes = storage };
    var sink = std.mem.zeroes(wire.CheckpointSinkV1);
    sink.struct_size = @sizeOf(wire.CheckpointSinkV1);
    sink.ctx = &sink_context;
    sink.write = Sink.write;
    const limits = checkpointLimits();
    var config = std.mem.zeroes(wire.CheckpointExportConfigV1);
    config.struct_size = @sizeOf(wire.CheckpointExportConfigV1);
    config.limits = &limits;
    config.sink = &sink;
    var result = std.mem.zeroes(wire.CheckpointExportResultV1);
    try expectOk(api, "checkpoint_export", api.sessionControl().exportCheckpoint()(
        session,
        &config,
        &result,
        diagnostic,
    ), diagnostic);
    if (sink_context.len == 0 or result.total_bytes != sink_context.len)
        return error.InvalidCheckpoint;
    return storage[0..sink_context.len];
}

fn restoreSession(
    api: agentcore.Api,
    runtime: *wire.RuntimeHandle,
    host: *const wire.SessionHostConfigV1,
    callbacks: *const wire.SessionCallbacksV1,
    bytes: []const u8,
    expected_restored_rules: u32,
    diagnostic: *wire.OwnedBytesV1,
) !*wire.SessionHandle {
    var source_context = Source{ .bytes = bytes };
    var source = std.mem.zeroes(wire.CheckpointSourceV1);
    source.struct_size = @sizeOf(wire.CheckpointSourceV1);
    source.ctx = &source_context;
    source.read = Source.read;
    const limits = checkpointLimits();
    var config = std.mem.zeroes(wire.SessionRestoreConfigV1);
    config.struct_size = @sizeOf(wire.SessionRestoreConfigV1);
    config.host = host;
    config.source = &source;
    config.limits = &limits;
    var session: ?*wire.SessionHandle = null;
    var report = emptyOwned();
    defer releaseOwned(api, &report);
    try expectOk(api, "session_restore", api.sessionControl().restore()(
        runtime,
        &config,
        callbacks,
        &session,
        &report,
        diagnostic,
    ), diagnostic);
    const report_bytes = try agentcore.borrowedBytes(.{ .ptr = report.ptr, .len = report.len });
    var parsed = try agentcore.decodeRestoreReport(std.heap.c_allocator, report_bytes);
    defer parsed.deinit();
    if (parsed.value.permission.restored_rules != expected_restored_rules or
        parsed.value.permission.invalidated_rules != 0)
        return error.UnexpectedPermissionRestore;
    return session orelse error.MissingRestoredSession;
}

fn runSessionGrant(
    api: agentcore.Api,
    runtime: *wire.RuntimeHandle,
    allowed_tools: *const [4]wire.BytesViewV1,
) !void {
    const host = makeHost(wire.PERMISSION_ACCEPT_EDITS, wire.SHELL_UNRESTRICTED, null, allowed_tools);
    var probe = Probe{ .behavior = .allow_session };
    const callbacks = makeCallbacks(&probe);
    var diagnostic = emptyOwned();
    defer releaseOwned(api, &diagnostic);
    const session = try createSession(api, runtime, &host, &callbacks, &diagnostic);
    defer _ = api.session().destroy()(session, null);
    _ = try run(api, session, 1, "session_grant", &diagnostic);
    _ = try run(api, session, 2, "session_grant", &diagnostic);
    if (probe.ui_calls != 1 or probe.ui_releases != 1 or probe.provenance != 2 or probe.callback_sources != 1 or probe.session_allow != 1)
        return error.SessionGrantNotReused;
    std.debug.print("scenario=session_grant ui={d} session_allow={d}\n", .{ probe.ui_calls, probe.session_allow });
}

fn runRestore(
    api: agentcore.Api,
    runtime: *wire.RuntimeHandle,
    allowed_tools: *const [4]wire.BytesViewV1,
    seed_permission_mode: u32,
    restored_permission_mode: u32,
    seed_scenario: []const u8,
    after_scenario: []const u8,
    seed_behavior: UiBehavior,
    expected_seed_ui: u32,
    expected_restored_rules: u32,
    restored_behavior: UiBehavior,
    expected_restored_ui: u32,
    expected_seed_source: agentcore.protocol.PermissionDecisionSource,
    expected_restored_source: agentcore.protocol.PermissionDecisionSource,
) !void {
    const seed_host = makeHost(seed_permission_mode, wire.SHELL_UNRESTRICTED, null, allowed_tools);
    var seed_probe = Probe{ .behavior = seed_behavior };
    const seed_callbacks = makeCallbacks(&seed_probe);
    var diagnostic = emptyOwned();
    defer releaseOwned(api, &diagnostic);
    const first = try createSession(api, runtime, &seed_host, &seed_callbacks, &diagnostic);
    _ = try run(api, first, 1, seed_scenario, &diagnostic);
    try expectProbe(&seed_probe, seed_behavior, expected_seed_ui, 1, expected_seed_source);
    const storage = try std.heap.c_allocator.alloc(u8, checkpoint_capacity);
    defer std.heap.c_allocator.free(storage);
    const checkpoint = try exportCheckpoint(api, first, storage, &diagnostic);
    try expectOk(api, "seed_destroy", api.session().destroy()(first, &diagnostic), &diagnostic);

    const restored_host = makeHost(restored_permission_mode, wire.SHELL_UNRESTRICTED, null, allowed_tools);
    var restored_probe = Probe{ .behavior = restored_behavior };
    const restored_callbacks = makeCallbacks(&restored_probe);
    const restored = try restoreSession(
        api,
        runtime,
        &restored_host,
        &restored_callbacks,
        checkpoint,
        expected_restored_rules,
        &diagnostic,
    );
    defer _ = api.session().destroy()(restored, null);
    _ = try run(api, restored, 2, after_scenario, &diagnostic);
    try expectProbe(&restored_probe, restored_behavior, expected_restored_ui, 1, expected_restored_source);
    std.debug.print(
        "scenario=restore seed={s} after={s} restored_rules={d} ui_after={d}\n",
        .{ seed_scenario, after_scenario, expected_restored_rules, expected_restored_ui },
    );
}

fn expectModeChangeRestoreUnsupported(
    api: agentcore.Api,
    runtime: *wire.RuntimeHandle,
    allowed_tools: *const [4]wire.BytesViewV1,
    seed_permission_mode: u32,
    restored_permission_mode: u32,
    seed_scenario: []const u8,
    seed_behavior: UiBehavior,
    expected_seed_ui: u32,
    expected_seed_source: agentcore.protocol.PermissionDecisionSource,
) !void {
    const seed_host = makeHost(seed_permission_mode, wire.SHELL_UNRESTRICTED, null, allowed_tools);
    var seed_probe = Probe{ .behavior = seed_behavior };
    const seed_callbacks = makeCallbacks(&seed_probe);
    var diagnostic = emptyOwned();
    defer releaseOwned(api, &diagnostic);
    const first = try createSession(api, runtime, &seed_host, &seed_callbacks, &diagnostic);
    _ = try run(api, first, 1, seed_scenario, &diagnostic);
    try expectProbe(&seed_probe, seed_behavior, expected_seed_ui, 1, expected_seed_source);
    const storage = try std.heap.c_allocator.alloc(u8, checkpoint_capacity);
    defer std.heap.c_allocator.free(storage);
    const checkpoint = try exportCheckpoint(api, first, storage, &diagnostic);
    try expectOk(api, "mode_seed_destroy", api.session().destroy()(first, &diagnostic), &diagnostic);

    const restored_host = makeHost(restored_permission_mode, wire.SHELL_UNRESTRICTED, null, allowed_tools);
    var restored_probe = Probe{ .behavior = .unavailable };
    const restored_callbacks = makeCallbacks(&restored_probe);
    var source_context = Source{ .bytes = checkpoint };
    var source = std.mem.zeroes(wire.CheckpointSourceV1);
    source.struct_size = @sizeOf(wire.CheckpointSourceV1);
    source.ctx = &source_context;
    source.read = Source.read;
    const limits = checkpointLimits();
    var config = std.mem.zeroes(wire.SessionRestoreConfigV1);
    config.struct_size = @sizeOf(wire.SessionRestoreConfigV1);
    config.host = &restored_host;
    config.source = &source;
    config.limits = &limits;
    var candidate: ?*wire.SessionHandle = null;
    var report = emptyOwned();
    defer releaseOwned(api, &report);
    try expectOk(api, "mode_change_restore", api.sessionControl().restore()(
        runtime,
        &config,
        &restored_callbacks,
        &candidate,
        &report,
        &diagnostic,
    ), &diagnostic);
    const restored = candidate orelse return error.MissingRestoredSession;
    defer _ = api.session().destroy()(restored, null);
    const report_bytes = try agentcore.borrowedBytes(.{ .ptr = report.ptr, .len = report.len });
    if (agentcore.decodeRestoreReport(std.heap.c_allocator, report_bytes)) |parsed_report| {
        var parsed = parsed_report;
        parsed.deinit();
        return error.ModeChangeRestoreUnexpectedlySupported;
    } else |err| {
        if (err != error.InvalidPayload) return err;
    }
    if (std.mem.indexOf(u8, report_bytes, "\"health\":\"degraded\"") == null or
        std.mem.indexOf(u8, report_bytes, "\"issues\":[]") == null)
        return error.UnexpectedModeChangeRestoreReport;
    std.debug.print("scenario=restore_mode_change seed={s} result=unsupported_invalid_report\n", .{seed_scenario});
}

pub fn main() !void {
    const api = try agentcore.Api.discover();
    var builtin_tools = [_]wire.BytesViewV1{
        agentcore.bytesView("Read"),
        agentcore.bytesView("Edit"),
        agentcore.bytesView("Write"),
        agentcore.bytesView("Bash"),
    };
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    runtime_config.builtin_tools = &builtin_tools;
    runtime_config.builtin_tool_count = builtin_tools.len;
    var runtime: ?*wire.RuntimeHandle = null;
    var diagnostic = emptyOwned();
    defer releaseOwned(api, &diagnostic);
    try expectOk(api, "runtime_create", api.runtime().create()(
        &runtime_config,
        null,
        &runtime,
        &diagnostic,
    ), &diagnostic);
    const core_runtime = runtime orelse return error.MissingRuntime;
    defer _ = api.runtime().destroy()(core_runtime, null);

    try runFresh(api, core_runtime, &builtin_tools, "accept_inside_edit", wire.PERMISSION_ACCEPT_EDITS, wire.SHELL_UNRESTRICTED, .none, .unavailable, 0, 2, .builtin_classification);
    try runFresh(api, core_runtime, &builtin_tools, "accept_inside_write", wire.PERMISSION_ACCEPT_EDITS, wire.SHELL_UNRESTRICTED, .none, .unavailable, 0, 1, .builtin_classification);
    try runFresh(api, core_runtime, &builtin_tools, "accept_outside_write", wire.PERMISSION_ACCEPT_EDITS, wire.SHELL_UNRESTRICTED, .none, .allow_once, 1, 1, .callback);
    try runFresh(api, core_runtime, &builtin_tools, "accept_bash", wire.PERMISSION_ACCEPT_EDITS, wire.SHELL_UNRESTRICTED, .none, .allow_once, 1, 1, .callback);
    try runFresh(api, core_runtime, &builtin_tools, "full_bash", wire.PERMISSION_FULL_ACCESS, wire.SHELL_UNRESTRICTED, .none, .unavailable, 0, 1, .builtin_classification);
    try runFresh(api, core_runtime, &builtin_tools, "full_outside_write", wire.PERMISSION_FULL_ACCESS, wire.SHELL_UNRESTRICTED, .none, .unavailable, 0, 1, .builtin_classification);
    try runFresh(api, core_runtime, &builtin_tools, "full_protected_write", wire.PERMISSION_FULL_ACCESS, wire.SHELL_UNRESTRICTED, .none, .deny_once, 1, 1, .callback);
    try runFresh(api, core_runtime, &builtin_tools, "deny_full_bash", wire.PERMISSION_FULL_ACCESS, wire.SHELL_UNRESTRICTED, .deny_bash, .unavailable, 0, 1, .explicit_deny);
    try runFresh(api, core_runtime, &builtin_tools, "ask_full_bash", wire.PERMISSION_FULL_ACCESS, wire.SHELL_UNRESTRICTED, .ask_bash, .allow_once, 1, 1, .callback);
    try runFresh(api, core_runtime, &builtin_tools, "allow_accept_bash", wire.PERMISSION_ACCEPT_EDITS, wire.SHELL_UNRESTRICTED, .allow_bash, .unavailable, 0, 1, .explicit_allow);
    try runFresh(api, core_runtime, &builtin_tools, "ask_over_allow_bash", wire.PERMISSION_FULL_ACCESS, wire.SHELL_UNRESTRICTED, .ask_allow_bash, .allow_once, 1, 1, .callback);
    try runFresh(api, core_runtime, &builtin_tools, "deny_over_ask_allow_bash", wire.PERMISSION_FULL_ACCESS, wire.SHELL_UNRESTRICTED, .deny_ask_allow_bash, .unavailable, 0, 1, .explicit_deny);
    try runSessionGrant(api, core_runtime, &builtin_tools);
    try runFresh(api, core_runtime, &builtin_tools, "unavailable_accept_write", wire.PERMISSION_ACCEPT_EDITS, wire.SHELL_UNRESTRICTED, .none, .unavailable, 1, 1, .callback);
    try runFresh(api, core_runtime, &builtin_tools, "auto_write", wire.PERMISSION_AUTO, wire.SHELL_UNRESTRICTED, .none, .allow_once, 1, 1, .callback);
    try runFresh(api, core_runtime, &builtin_tools, "auto_bash", wire.PERMISSION_AUTO, wire.SHELL_UNRESTRICTED, .none, .allow_once, 1, 1, .callback);
    try runFresh(api, core_runtime, &builtin_tools, "dont_ask_write", wire.PERMISSION_DONT_ASK, wire.SHELL_UNRESTRICTED, .none, .unavailable, 0, 1, .mode_fallback);
    try runFresh(api, core_runtime, &builtin_tools, "dont_ask_bash", wire.PERMISSION_DONT_ASK, wire.SHELL_UNRESTRICTED, .none, .unavailable, 0, 1, .mode_fallback);
    try expectShellDisabledRejected(api, core_runtime, &builtin_tools);
    try runFresh(api, core_runtime, &builtin_tools, "sandbox_inside", wire.PERMISSION_FULL_ACCESS, wire.SHELL_SANDBOXED, .none, .unavailable, 0, 1, .builtin_classification);
    try runFresh(api, core_runtime, &builtin_tools, "sandbox_outside", wire.PERMISSION_FULL_ACCESS, wire.SHELL_SANDBOXED, .none, .unavailable, 0, 1, .builtin_classification);
    try runFresh(api, core_runtime, &builtin_tools, "unrestricted_outside", wire.PERMISSION_FULL_ACCESS, wire.SHELL_UNRESTRICTED, .none, .unavailable, 0, 1, .builtin_classification);
    try runRestore(api, core_runtime, &builtin_tools, wire.PERMISSION_ACCEPT_EDITS, wire.PERMISSION_ACCEPT_EDITS, "restore_grant", "restore_grant", .allow_session, 1, 1, .unavailable, 0, .callback, .session_allow);
    try runRestore(api, core_runtime, &builtin_tools, wire.PERMISSION_FULL_ACCESS, wire.PERMISSION_FULL_ACCESS, "restore_full_seed", "restore_full_after", .unavailable, 0, 0, .unavailable, 0, .builtin_classification, .builtin_classification);
    try expectModeChangeRestoreUnsupported(api, core_runtime, &builtin_tools, wire.PERMISSION_FULL_ACCESS, wire.PERMISSION_ACCEPT_EDITS, "restore_full_to_accept_seed", .unavailable, 0, .builtin_classification);
    try expectModeChangeRestoreUnsupported(api, core_runtime, &builtin_tools, wire.PERMISSION_ACCEPT_EDITS, wire.PERMISSION_FULL_ACCESS, "restore_accept_to_full_seed", .unavailable, 0, .builtin_classification);
}
