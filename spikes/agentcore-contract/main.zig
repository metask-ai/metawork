const std = @import("std");
const sdk = @import("metacodes_agentcore");
const wire = sdk.types;
const MockServer = @import("mock_server.zig").MockServer;

const FINAL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m4\",\"role\":\"assistant\",\"model\":\"fixture\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"metawork gate1 complete\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const BASH_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m2\",\"role\":\"assistant\",\"model\":\"fixture\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"bash1\",\"name\":\"Bash\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"command\\\":\\\"printf gate1-bash-ok\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const ASK_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"ask-message\",\"role\":\"assistant\",\"model\":\"fixture\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"ask1\",\"name\":\"AskUserQuestion\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"questions\\\":[{\\\"question\\\":\\\"Continue?\\\",\\\"header\\\":\\\"Choice\\\",\\\"options\\\":[{\\\"label\\\":\\\"Yes\\\",\\\"description\\\":\\\"Proceed\\\"},{\\\"label\\\":\\\"No\\\",\\\"description\\\":\\\"Stop\\\"}]}]}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const SLEEP_BASH_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"sleep-message\",\"role\":\"assistant\",\"model\":\"fixture\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"sleep1\",\"name\":\"Bash\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"command\\\":\\\"sleep 10\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const UiMode = enum { answered, unavailable, fatal };

const Probe = struct {
    event_calls: usize = 0,
    ui_calls: usize = 0,
    ui_releases: usize = 0,
    saw_read: bool = false,
    saw_bash: bool = false,
    saw_edit: bool = false,
    saw_final: bool = false,
    ui_mode: UiMode = .answered,
    sleep_started: std.atomic.Value(bool) = .init(false),

    fn onEvent(raw: ?*anyopaque, session: ?*wire.SessionHandle, run_id: u64, view: wire.BytesViewV1) callconv(.c) u32 {
        const self: *Probe = @ptrCast(@alignCast(raw orelse return wire.CALLBACK_FATAL));
        if (session == null or run_id != 1) return wire.CALLBACK_FATAL;
        const json = sdk.borrowedBytes(view) catch return wire.CALLBACK_FATAL;
        var parsed = sdk.decodeCoreEvent(std.heap.c_allocator, json) catch return wire.CALLBACK_FATAL;
        defer parsed.deinit();
        self.event_calls += 1;
        switch (parsed.value) {
            .tool_result => |result| {
                if (std.mem.eql(u8, result.name, "Read") and
                    std.mem.indexOf(u8, result.content, "gate1-before") != null)
                    self.saw_read = true;
                if (std.mem.eql(u8, result.name, "Bash") and
                    std.mem.indexOf(u8, result.content, "gate1-bash-ok") != null)
                    self.saw_bash = true;
                if (std.mem.eql(u8, result.name, "Edit") and !result.is_error)
                    self.saw_edit = true;
            },
            .text_chunk => |chunk| {
                if (std.mem.indexOf(u8, chunk, "metawork gate1 complete") != null)
                    self.saw_final = true;
            },
            .tool_start => |tool_start| {
                if (std.mem.indexOf(u8, tool_start.input, "sleep 10") != null)
                    self.sleep_started.store(true, .release);
            },
            else => {},
        }
        return wire.CALLBACK_CONTINUE;
    }

    fn onUiRequest(raw: ?*anyopaque, session: ?*wire.SessionHandle, request: wire.BytesViewV1, out: ?*wire.OwnedBytesV1) callconv(.c) u32 {
        const self: *Probe = @ptrCast(@alignCast(raw orelse return wire.UI_FATAL));
        if (session == null) return wire.UI_FATAL;
        const output = out orelse return wire.UI_FATAL;
        const json = sdk.borrowedBytes(request) catch return wire.UI_FATAL;
        var parsed = sdk.decodeUiRequest(std.heap.c_allocator, json) catch return wire.UI_FATAL;
        defer parsed.deinit();
        self.ui_calls += 1;
        switch (self.ui_mode) {
            .unavailable => return wire.UI_UNAVAILABLE,
            .fatal => return wire.UI_FATAL,
            .answered => {},
        }
        const response = switch (parsed.value) {
            .ask_question => |questions| response: {
                const answers = std.heap.c_allocator.alloc([]const u8, questions.len) catch
                    return wire.UI_FATAL;
                defer std.heap.c_allocator.free(answers);
                for (answers) |*answer| answer.* = "Yes";
                break :response sdk.encodeUiResponse(
                    std.heap.c_allocator,
                    parsed.value,
                    .{ .answers = answers },
                ) catch return wire.UI_FATAL;
            },
            .permission => sdk.encodeUiResponse(
                std.heap.c_allocator,
                parsed.value,
                .{ .permission = .allow_once },
            ) catch return wire.UI_FATAL,
            .plan_approval => sdk.encodeUiResponse(
                std.heap.c_allocator,
                parsed.value,
                .{ .plan_approval = .approve_default },
            ) catch return wire.UI_FATAL,
            .custom => sdk.encodeUiResponse(
                std.heap.c_allocator,
                parsed.value,
                .{ .custom = "{}" },
            ) catch return wire.UI_FATAL,
        };
        output.* = .{
            .ptr = response.ptr,
            .len = response.len,
        };
        return wire.UI_ANSWERED;
    }

    fn releaseUiResponse(raw: ?*anyopaque, out: ?*wire.OwnedBytesV1) callconv(.c) void {
        const self: *Probe = @ptrCast(@alignCast(raw orelse return));
        const value = out orelse return;
        const len = std.math.cast(usize, value.len) orelse return;
        const ptr = value.ptr orelse return;
        std.heap.c_allocator.free(ptr[0..len]);
        self.ui_releases += 1;
        value.* = .{ .ptr = null, .len = 0 };
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const api = try sdk.Api.discover();
    if (sdk.metacodes_agentcore_get_api(wire.ABI_VERSION_V1 + 1) != null)
        return error.UnexpectedAbiVersion;

    var root_buffer: [256]u8 = undefined;
    const root = try std.fmt.bufPrintZ(&root_buffer, "/tmp/metawork-agentcore-{d}", .{std.c.getpid()});
    if (std.c.mkdir(root.ptr, 0o700) != 0) return error.CreateWorkspaceFailed;
    defer _ = std.c.rmdir(root.ptr);
    var file_buffer: [320]u8 = undefined;
    const file_path = try std.fmt.bufPrintZ(&file_buffer, "{s}/fixture.txt", .{root});
    defer _ = std.c.unlink(file_path.ptr);
    try writeFile(file_path.ptr, "gate1-before");

    const read_sse = try readSse(allocator, file_path);
    const edit_sse = try editSse(allocator, file_path);
    const responses = [_][]const u8{ read_sse, BASH_SSE, edit_sse, FINAL_SSE };
    const server = try MockServer.start(&responses);
    defer server.stop();
    const base_url = try server.url(allocator);

    const builtins = [_]wire.BytesViewV1{
        sdk.bytesView("Read"),
        sdk.bytesView("Bash"),
        sdk.bytesView("Edit"),
        sdk.bytesView("AskUserQuestion"),
    };
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    runtime_config.builtin_tools = &builtins;
    runtime_config.builtin_tool_count = builtins.len;
    var diagnostic = wire.OwnedBytesV1{ .ptr = null, .len = 0 };
    defer api.bufferRelease()(&diagnostic);
    var diagnostic_releases: usize = 0;
    var runtime: ?*wire.RuntimeHandle = null;
    try expectStatus(wire.STATUS_OK, api.runtimeCreate()(&runtime_config, &runtime, &diagnostic), diagnostic);
    defer {
        if (runtime) |handle| _ = api.runtimeDestroy()(handle, &diagnostic);
    }

    var probe = Probe{};
    const allowed = [_]wire.BytesViewV1{
        sdk.bytesView("Read"),
        sdk.bytesView("Bash"),
        sdk.bytesView("Edit"),
    };
    var session_config = std.mem.zeroes(wire.SessionConfigV1);
    session_config.struct_size = @sizeOf(wire.SessionConfigV1);
    session_config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    session_config.permission_mode_code = wire.PERMISSION_DEFAULT;
    session_config.shell_policy_code = wire.SHELL_UNRESTRICTED;
    session_config.api_key = sdk.bytesView("metawork-contract-fixture-key");
    session_config.model = sdk.bytesView("metawork-contract-fixture-model");
    session_config.base_url = sdk.bytesView(base_url);
    session_config.workspace_root = sdk.bytesView(root);
    session_config.workspace_home = sdk.bytesView(root);
    session_config.allowed_tools = &allowed;
    session_config.allowed_tool_count = allowed.len;
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.ctx = &probe;
    callbacks.on_event = Probe.onEvent;
    callbacks.on_ui_request = Probe.onUiRequest;
    callbacks.release_response = Probe.releaseUiResponse;
    var session: ?*wire.SessionHandle = null;
    try expectStatus(
        wire.STATUS_OK,
        api.sessionCreate()(runtime, &session_config, &callbacks, &session, &diagnostic),
        diagnostic,
    );
    defer {
        if (session) |handle| _ = api.sessionDestroy()(handle, &diagnostic);
    }

    try expectStatus(wire.STATUS_BUSY, api.runtimeDestroy()(runtime, &diagnostic), diagnostic);
    try releaseDiagnostic(api, &diagnostic, &diagnostic_releases);

    var options = wire.RunOptionsV1{
        .struct_size = @sizeOf(wire.RunOptionsV1),
        .max_turns = 8,
        .reserved = [_]u64{0} ** 4,
    };
    var result: wire.RunResultV1 = undefined;
    try expectStatus(
        wire.STATUS_INVALID_ARGUMENT,
        api.sessionRun()(session, 0, sdk.bytesView("invalid"), &options, &result, &diagnostic),
        diagnostic,
    );
    try releaseDiagnostic(api, &diagnostic, &diagnostic_releases);

    try expectStatus(
        wire.STATUS_OK,
        api.sessionRun()(session, 1, sdk.bytesView("exercise Read, Bash, and Edit"), &options, &result, &diagnostic),
        diagnostic,
    );
    if (result.struct_size != @sizeOf(wire.RunResultV1) or
        result.stop_reason_code != wire.STOP_END_TURN or result.tool_calls != 3)
        return error.UnexpectedRunResult;
    if (probe.event_calls == 0 or !probe.saw_read or !probe.saw_bash or !probe.saw_edit or !probe.saw_final)
        return error.MissingCoreEvent;
    if (probe.ui_calls == 0 or probe.ui_calls != probe.ui_releases)
        return error.UiOwnershipMismatch;
    try expectFile(file_path.ptr, "gate1-after");

    try expectStatus(
        wire.STATUS_TOO_LATE,
        api.sessionAbort()(session, 1, wire.ABORT_USER_REQUEST, &diagnostic),
        diagnostic,
    );
    try releaseDiagnostic(api, &diagnostic, &diagnostic_releases);
    try expectStatus(
        wire.STATUS_INVALID_ARGUMENT,
        api.sessionAbort()(session, 0, wire.ABORT_USER_REQUEST, &diagnostic),
        diagnostic,
    );
    try releaseDiagnostic(api, &diagnostic, &diagnostic_releases);

    try expectStatus(wire.STATUS_OK, api.sessionDestroy()(session, &diagnostic), diagnostic);
    session = null;

    try verifyUiOutcome(allocator, api, runtime, root, .unavailable);
    try verifyUiOutcome(allocator, api, runtime, root, .fatal);
    try verifyActiveAbort(init.io, allocator, api, runtime, root);

    try expectStatus(wire.STATUS_OK, api.runtimeDestroy()(runtime, &diagnostic), diagnostic);
    runtime = null;
    if (diagnostic_releases != 4) return error.DiagnosticReleaseMismatch;
    std.debug.print(
        "MetaWork AgentCore raw probe: Read/Bash/Edit, UI, events, lifecycle and releases OK\n",
        .{},
    );
}

fn verifyUiOutcome(
    allocator: std.mem.Allocator,
    api: sdk.Api,
    runtime: ?*wire.RuntimeHandle,
    root: []const u8,
    mode: UiMode,
) !void {
    const responses = if (mode == .unavailable)
        [_][]const u8{ ASK_SSE, FINAL_SSE }
    else
        [_][]const u8{ ASK_SSE, ASK_SSE };
    const server = try MockServer.start(&responses);
    defer server.stop();
    const base_url = try server.url(allocator);

    const allowed = [_]wire.BytesViewV1{sdk.bytesView("AskUserQuestion")};
    var config = std.mem.zeroes(wire.SessionConfigV1);
    config.struct_size = @sizeOf(wire.SessionConfigV1);
    config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    config.permission_mode_code = wire.PERMISSION_BYPASS;
    config.shell_policy_code = wire.SHELL_DISABLED;
    config.api_key = sdk.bytesView("metawork-ui-fixture-key");
    config.model = sdk.bytesView("metawork-ui-fixture-model");
    config.base_url = sdk.bytesView(base_url);
    config.workspace_root = sdk.bytesView(root);
    config.workspace_home = sdk.bytesView(root);
    config.allowed_tools = &allowed;
    config.allowed_tool_count = allowed.len;
    var probe = Probe{ .ui_mode = mode };
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.ctx = &probe;
    callbacks.on_event = Probe.onEvent;
    callbacks.on_ui_request = Probe.onUiRequest;
    callbacks.release_response = Probe.releaseUiResponse;
    var diagnostic = wire.OwnedBytesV1{ .ptr = null, .len = 0 };
    defer api.bufferRelease()(&diagnostic);
    var releases: usize = 0;
    var session: ?*wire.SessionHandle = null;
    try expectStatus(
        wire.STATUS_OK,
        api.sessionCreate()(runtime, &config, &callbacks, &session, &diagnostic),
        diagnostic,
    );
    defer {
        if (session) |handle| _ = api.sessionDestroy()(handle, &diagnostic);
    }

    var options = wire.RunOptionsV1{
        .struct_size = @sizeOf(wire.RunOptionsV1),
        .max_turns = 3,
        .reserved = [_]u64{0} ** 4,
    };
    var result: wire.RunResultV1 = undefined;
    const status = api.sessionRun()(
        session,
        1,
        sdk.bytesView("exercise synchronous UI outcome"),
        &options,
        &result,
        &diagnostic,
    );
    switch (mode) {
        .unavailable => {
            try expectStatus(wire.STATUS_OK, status, diagnostic);
            if (result.stop_reason_code != wire.STOP_END_TURN or probe.ui_calls != 1 or
                probe.ui_releases != 0)
                return error.UnexpectedUiUnavailableOutcome;
        },
        .fatal => {
            try expectStatus(wire.STATUS_CALLBACK_FAILED, status, diagnostic);
            try releaseDiagnostic(api, &diagnostic, &releases);
            if (probe.ui_calls != 1 or probe.ui_releases != 0)
                return error.UnexpectedUiFatalOutcome;
            try expectStatus(
                wire.STATUS_INVALID_STATE,
                api.sessionRun()(
                    session,
                    2,
                    sdk.bytesView("poisoned session must reject"),
                    &options,
                    &result,
                    &diagnostic,
                ),
                diagnostic,
            );
            try releaseDiagnostic(api, &diagnostic, &releases);
            if (releases != 2) return error.DiagnosticReleaseMismatch;
        },
        .answered => unreachable,
    }
    try expectStatus(wire.STATUS_OK, api.sessionDestroy()(session, &diagnostic), diagnostic);
    session = null;
}

const AsyncRun = struct {
    api: sdk.Api,
    session: ?*wire.SessionHandle,
    status: u32 = wire.STATUS_INTERNAL_ERROR,
    result: wire.RunResultV1 = undefined,
    diagnostic: wire.OwnedBytesV1 = .{ .ptr = null, .len = 0 },

    fn run(self: *AsyncRun) void {
        var options = wire.RunOptionsV1{
            .struct_size = @sizeOf(wire.RunOptionsV1),
            .max_turns = 3,
            .reserved = [_]u64{0} ** 4,
        };
        self.status = self.api.sessionRun()(
            self.session,
            1,
            sdk.bytesView("start a cancellable Bash"),
            &options,
            &self.result,
            &self.diagnostic,
        );
    }
};

fn verifyActiveAbort(
    io: std.Io,
    allocator: std.mem.Allocator,
    api: sdk.Api,
    runtime: ?*wire.RuntimeHandle,
    root: []const u8,
) !void {
    const responses = [_][]const u8{SLEEP_BASH_SSE};
    const server = try MockServer.start(&responses);
    defer server.stop();
    const base_url = try server.url(allocator);
    const allowed = [_]wire.BytesViewV1{sdk.bytesView("Bash")};
    var config = std.mem.zeroes(wire.SessionConfigV1);
    config.struct_size = @sizeOf(wire.SessionConfigV1);
    config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    config.permission_mode_code = wire.PERMISSION_BYPASS;
    config.shell_policy_code = wire.SHELL_UNRESTRICTED;
    config.api_key = sdk.bytesView("metawork-abort-fixture-key");
    config.model = sdk.bytesView("metawork-abort-fixture-model");
    config.base_url = sdk.bytesView(base_url);
    config.workspace_root = sdk.bytesView(root);
    config.workspace_home = sdk.bytesView(root);
    config.allowed_tools = &allowed;
    config.allowed_tool_count = allowed.len;
    var probe = Probe{};
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.ctx = &probe;
    callbacks.on_event = Probe.onEvent;
    var diagnostic = wire.OwnedBytesV1{ .ptr = null, .len = 0 };
    defer api.bufferRelease()(&diagnostic);
    var releases: usize = 0;
    var session: ?*wire.SessionHandle = null;
    try expectStatus(
        wire.STATUS_OK,
        api.sessionCreate()(runtime, &config, &callbacks, &session, &diagnostic),
        diagnostic,
    );
    defer {
        if (session) |handle| _ = api.sessionDestroy()(handle, &diagnostic);
    }

    var run = AsyncRun{ .api = api, .session = session };
    const thread = try std.Thread.spawn(.{}, AsyncRun.run, .{&run});
    var thread_joined = false;
    defer {
        if (!thread_joined) {
            var cleanup_diagnostic = wire.OwnedBytesV1{ .ptr = null, .len = 0 };
            _ = api.sessionAbort()(session, 1, wire.ABORT_USER_REQUEST, &cleanup_diagnostic);
            api.bufferRelease()(&cleanup_diagnostic);
            thread.join();
            api.bufferRelease()(&run.diagnostic);
        }
    }
    var attempts: usize = 0;
    while (!probe.sleep_started.load(.acquire) and attempts < 500) : (attempts += 1)
        try io.sleep(.fromMilliseconds(10), .awake);
    if (!probe.sleep_started.load(.acquire)) return error.CancellableToolDidNotStart;

    try expectStatus(wire.STATUS_BUSY, api.sessionDestroy()(session, &diagnostic), diagnostic);
    try releaseDiagnostic(api, &diagnostic, &releases);
    try expectStatus(
        wire.STATUS_STALE_RUN,
        api.sessionAbort()(session, 2, wire.ABORT_USER_REQUEST, &diagnostic),
        diagnostic,
    );
    try releaseDiagnostic(api, &diagnostic, &releases);
    try expectStatus(
        wire.STATUS_OK,
        api.sessionAbort()(session, 1, wire.ABORT_USER_REQUEST, &diagnostic),
        diagnostic,
    );
    thread.join();
    thread_joined = true;
    try expectStatus(wire.STATUS_OK, run.status, run.diagnostic);
    if (run.result.stop_reason_code != wire.STOP_ABORTED) return error.UnexpectedAbortResult;
    api.bufferRelease()(&run.diagnostic);

    try expectStatus(
        wire.STATUS_TOO_LATE,
        api.sessionAbort()(session, 1, wire.ABORT_USER_REQUEST, &diagnostic),
        diagnostic,
    );
    try releaseDiagnostic(api, &diagnostic, &releases);
    if (releases != 3) return error.DiagnosticReleaseMismatch;
    try expectStatus(wire.STATUS_OK, api.sessionDestroy()(session, &diagnostic), diagnostic);
    session = null;
}

fn readSse(allocator: std.mem.Allocator, file_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"m1\",\"role\":\"assistant\",\"model\":\"fixture\",\"usage\":{{\"input_tokens\":1,\"output_tokens\":1}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"tool_use\",\"id\":\"read1\",\"name\":\"Read\",\"input\":{{}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":\"{{\\\"file_path\\\":\\\"{s}\\\"}}\"}}}}\n\n" ++
            "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
            "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"tool_use\"}},\"usage\":{{\"output_tokens\":1}}}}\n\n" ++
            "data: {{\"type\":\"message_stop\"}}\n\n",
        .{file_path},
    );
}

fn editSse(allocator: std.mem.Allocator, file_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"m3\",\"role\":\"assistant\",\"model\":\"fixture\",\"usage\":{{\"input_tokens\":1,\"output_tokens\":1}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"tool_use\",\"id\":\"edit1\",\"name\":\"Edit\",\"input\":{{}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":\"{{\\\"file_path\\\":\\\"{s}\\\",\\\"old_string\\\":\\\"gate1-before\\\",\\\"new_string\\\":\\\"gate1-after\\\"}}\"}}}}\n\n" ++
            "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
            "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"tool_use\"}},\"usage\":{{\"output_tokens\":1}}}}\n\n" ++
            "data: {{\"type\":\"message_stop\"}}\n\n",
        .{file_path},
    );
}

fn writeFile(path: [*:0]const u8, content: []const u8) !void {
    const file = std.c.open(path, std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
    if (file < 0) return error.OpenFailed;
    defer _ = std.c.close(file);
    if (std.c.write(file, content.ptr, content.len) != content.len) return error.WriteFailed;
}

fn expectFile(path: [*:0]const u8, expected: []const u8) !void {
    const file = std.c.open(path, std.c.O{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (file < 0) return error.OpenFailed;
    defer _ = std.c.close(file);
    var buffer: [128]u8 = undefined;
    const count = std.c.read(file, &buffer, buffer.len);
    if (count < 0 or !std.mem.eql(u8, buffer[0..@intCast(count)], expected))
        return error.UnexpectedFileContent;
}

fn expectStatus(expected: u32, actual: u32, diagnostic: wire.OwnedBytesV1) !void {
    if (actual == expected) return;
    const message = sdk.borrowedBytes(.{ .ptr = diagnostic.ptr, .len = diagnostic.len }) catch
        "invalid diagnostic";
    std.debug.print("AgentCore status {d}, expected {d}: {s}\n", .{ actual, expected, message });
    return error.UnexpectedStatus;
}

fn releaseDiagnostic(api: sdk.Api, diagnostic: *wire.OwnedBytesV1, releases: *usize) !void {
    if (diagnostic.ptr == null or diagnostic.len == 0) return error.MissingDiagnostic;
    api.bufferRelease()(diagnostic);
    releases.* += 1;
    if (diagnostic.ptr != null or diagnostic.len != 0) return error.InvalidReleasedDiagnostic;
}
