const fixture = @import("lifecycle_fixture");
const std = fixture.std;
const lifecycle = fixture.lifecycle;
const workbench_executor = fixture.workbench_executor;
const sdk = fixture.sdk;
const wire = fixture.wire;
const textChunk = fixture.textChunk;
const Plan = fixture.Plan;
const fake_core = &fixture.fake_core;
const diagnostic_byte: u8 = 0xA5;
const diagnostic = fixture.diagnostic;
const runtimeDestroy = fixture.runtimeDestroy;
const bufferRelease = fixture.bufferRelease;
const fake_api = fixture.fake_api;
const openSession = fixture.openSession;
const unavailableEventConsumer = fixture.unavailableEventConsumer;
const registerTestComposition = fixture.registerTestComposition;
const submitSession = fixture.submitSession;
const cancelSession = fixture.cancelSession;
const closeSession = fixture.closeSession;
const takeTestTerminal = fixture.takeTestTerminal;
const shutdownTestComposition = fixture.shutdownTestComposition;
const deinitTestComposition = fixture.deinitTestComposition;
const createTestComposition = fixture.createTestComposition;
const createTestRuntime = fixture.createTestRuntime;
const closeOnThread = fixture.closeOnThread;
const cancelOnThread = fixture.cancelOnThread;
const failPipelineOnThread = fixture.failPipelineOnThread;
const CallbackSignal = fixture.CallbackSignal;

const CheckpointCollector = struct {
    bytes: [256]u8 = undefined,
    len: usize = 0,
    result: lifecycle.CheckpointSinkWriteResult = .ok,

    fn sink(self: *CheckpointCollector) lifecycle.CheckpointSink {
        return .{ .context = self, .write_fn = write };
    }

    fn write(context: ?*anyopaque, chunk: []const u8) lifecycle.CheckpointSinkWriteResult {
        const self: *CheckpointCollector = @ptrCast(@alignCast(context orelse return .contract_failed));
        if (self.result != .ok) return self.result;
        if (chunk.len > self.bytes.len - self.len) return .io_failed;
        @memcpy(self.bytes[self.len..][0..chunk.len], chunk);
        self.len += chunk.len;
        return .ok;
    }
};

const CheckpointRestoreSource = struct {
    bytes: []const u8,
    offset: usize = 0,
    max_read: usize = 3,
    cancelled: bool = false,

    fn source(self: *CheckpointRestoreSource) lifecycle.CheckpointSource {
        return .{ .context = self, .read_fn = read };
    }

    fn read(context: ?*anyopaque, destination: []u8) lifecycle.CheckpointSourceReadResult {
        const self: *CheckpointRestoreSource = @ptrCast(@alignCast(context.?));
        if (self.cancelled) return .cancelled;
        if (self.offset == self.bytes.len) return .eof;
        const count = @min(
            @min(destination.len, self.max_read),
            self.bytes.len - self.offset,
        );
        @memcpy(destination[0..count], self.bytes[self.offset..][0..count]);
        self.offset += count;
        return .{ .bytes = count };
    }
};

const checkpoint_test_limits: lifecycle.CheckpointLimits = .{
    .hard_bytes = 1024,
    .max_section_bytes = 1024,
    .max_string_bytes = 512,
    .max_messages = 32,
    .max_blocks_per_message = 16,
    .chunk_bytes = 512,
};

fn restoreOptions(
    source: lifecycle.CheckpointSource,
    logical_session_id: []const u8,
    last_run_id: u64,
    last_compact_id: u64,
) lifecycle.SessionRestoreOptions {
    const workspace_root = if (std.fs.path.sep == '\\') "C:\\tmp\\metawork-gate2" else "/tmp/metawork-gate2";
    const temporary_root = if (std.fs.path.sep == '\\') "C:\\tmp" else "/tmp";
    return .{
        .session = .{
            .provider = .anthropic,
            .permission_mode = .default,
            .shell_policy = .disabled,
            .credential = "fixture-secret",
            .model = "fixture-model",
            .workspace = .{
                .canonical_root = workspace_root,
                .trust = .{ .temporary = temporary_root },
            },
        },
        .checkpoint_limits = checkpoint_test_limits,
        .source = source,
        .expectation = .{
            .logical_session_id = logical_session_id,
            .checkpoint_generation = 3,
            .last_run_id = last_run_id,
            .last_compact_id = last_compact_id,
            .model = "fixture-model",
        },
    };
}

const McpFixtureTransport = struct {
    fn descriptor(self: *McpFixtureTransport) lifecycle.McpTransport {
        return .{ .context = self, .open_fn = open, .request_fn = request, .notify_fn = notify, .close_fn = close };
    }
    fn open(context: *anyopaque, _: lifecycle.McpPurpose, _: lifecycle.McpEra, _: u32) lifecycle.McpOpenOutcome {
        return .{ .connection = context };
    }
    fn request(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: u32, _: lifecycle.McpCancellation) lifecycle.McpExchangeOutcome {
        return .{ .failure = .fatal };
    }
    fn notify(_: *anyopaque, _: []const u8, _: u32, _: lifecycle.McpCancellation) ?lifecycle.McpTransportFailure {
        return .fatal;
    }
    fn close(_: *anyopaque) void {}
    fn deinit(_: *anyopaque) void {}
};

const CanonicalUnavailableMcpTransport = struct {
    opens: std.atomic.Value(usize) = .init(0),

    fn descriptor(self: *CanonicalUnavailableMcpTransport) lifecycle.McpTransport {
        return .{ .context = self, .open_fn = open, .request_fn = request, .notify_fn = notify, .close_fn = close };
    }
    fn open(context: *anyopaque, _: lifecycle.McpPurpose, _: lifecycle.McpEra, _: u32) lifecycle.McpOpenOutcome {
        const self: *CanonicalUnavailableMcpTransport = @ptrCast(@alignCast(context));
        _ = self.opens.fetchAdd(1, .acq_rel);
        return .{ .failure = .network };
    }
    fn request(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: u32, _: lifecycle.McpCancellation) lifecycle.McpExchangeOutcome {
        return .{ .failure = .fatal };
    }
    fn notify(_: *anyopaque, _: []const u8, _: u32, _: lifecycle.McpCancellation) ?lifecycle.McpTransportFailure {
        return .fatal;
    }
    fn close(_: *anyopaque) void {}
    fn deinit(_: *anyopaque) void {}
};

test "canonical AgentCore refresh invokes the Host MCP connector and returns a bounded unavailable catalog" {
    var transport: CanonicalUnavailableMcpTransport = .{};
    var transport_owner = lifecycle.McpTransportOwner.init(
        transport.descriptor(),
        CanonicalUnavailableMcpTransport.deinit,
    );
    var input = try lifecycle.McpRuntimeInput.init(std.testing.allocator, 1, &.{.{
        .id = "offline",
        .transport_owner = &transport_owner,
        .transport = .streamable_http,
        .namespace = "offline",
        .client_name = "MetaWork",
        .client_version = "test",
        .timeout_ms = 100,
        .configuration_fingerprint = [_]u8{1} ** 32,
    }});
    defer input.deinit();
    const runtime = try lifecycle.Runtime.init(std.testing.io, std.testing.allocator, .{
        .max_sessions = 1,
        .mcp_input = &input,
    });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    try std.testing.expectEqual(@as(usize, 0), transport.opens.load(.acquire));
    const activation = switch (try runtime.activateMcp()) {
        .activated => |value| value,
        else => return error.TestUnexpectedResult,
    };
    defer activation.deinit();
    try std.testing.expect(transport.opens.load(.acquire) > 0);
    try std.testing.expectEqual(lifecycle.McpActivationState.unavailable, activation.state());
    try std.testing.expectEqual(@as(usize, 0), activation.catalogServers().len);
    try std.testing.expect(activation.catalogIssues().len > 0);
    try std.testing.expectEqualDeep(
        lifecycle.mcpBindingIdentity("offline"),
        activation.catalogIssues()[0].binding_identity,
    );
}

test "canonical AgentCore accepts an empty complete MCP Session replacement" {
    const runtime = try lifecycle.Runtime.init(std.testing.io, std.testing.allocator, .{
        .max_sessions = 1,
    });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    const workspace_root = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(workspace_root);
    const session = try runtime.createSession(.{
        .provider = .anthropic,
        .permission_mode = .default,
        .shell_policy = .unrestricted,
        .credential = "fixture-secret",
        .model = "fixture-model",
        .workspace = .{
            .canonical_root = workspace_root,
            .trust = .explicitly_trusted,
        },
        .canonical_user_home = workspace_root,
        .workspace_epoch = "canonical-mcp-empty-replacement",
    });
    try session.updateMcpSelection(null);
    try std.testing.expectEqual(lifecycle.SessionState.idle, session.snapshot().state);
}

test "MCP Runtime takes one complete input and activation publishes unavailable health" {
    fake_core.reset();
    var transport: McpFixtureTransport = .{};
    var transport_owner = lifecycle.McpTransportOwner.init(
        transport.descriptor(),
        McpFixtureTransport.deinit,
    );
    var input = try lifecycle.McpRuntimeInput.init(std.testing.allocator, 1, &.{.{
        .id = "fixture",
        .transport_owner = &transport_owner,
        .transport = .stdio,
        .namespace = "fixture",
        .client_name = "MetaWork",
        .client_version = "test",
        .timeout_ms = 1000,
        .configuration_fingerprint = [_]u8{1} ** 32,
    }});
    defer input.deinit();
    const runtime = try createTestRuntime(.{
        .max_sessions = 1,
        .mcp_input = &input,
    });
    const activation = switch (try runtime.activateMcp()) {
        .activated => |value| value,
        else => return error.TestUnexpectedResult,
    };
    defer activation.deinit();
    try std.testing.expectEqual(lifecycle.McpActivationState.unavailable, activation.state());
    try std.testing.expectEqual(@as(usize, 1), activation.serverHealth().len);
    try std.testing.expectEqual(
        lifecycle.McpActivationServerState.unavailable,
        activation.serverHealth()[0].state,
    );
    try std.testing.expectEqual(@as(?*lifecycle.McpSelection, null), activation.takeSelection());
    fake_core.forceNextMcpRefreshStatus(wire.STATUS_CORE_ERROR);
    switch (try runtime.activateMcp()) {
        .unavailable => |reason| try std.testing.expectEqual(
            lifecycle.McpActivationUnavailableReason.refresh_failed,
            reason,
        ),
        else => return error.TestUnexpectedResult,
    }
    try runtime.shutdown();
    runtime.deinit();
    fake_core.lock();
    const count = fake_core.mcp_server_count;
    const valid = fake_core.mcp_descriptor_valid;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expect(valid);
}

test "MCP empty Runtime accepts the initial declarative configuration apply" {
    fake_core.reset();
    const runtime = try lifecycle.Runtime.initWithApi(
        std.testing.io,
        std.testing.allocator,
        &fake_api,
        .{ .max_sessions = 1 },
    );
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    var transport: McpFixtureTransport = .{};
    var owner = lifecycle.McpTransportOwner.init(
        transport.descriptor(),
        McpFixtureTransport.deinit,
    );
    var replacement = try lifecycle.McpRuntimeInput.init(std.testing.allocator, 1, &.{.{
        .id = "initial",
        .transport_owner = &owner,
        .transport = .stdio,
        .namespace = "initial",
        .client_name = "MetaWork",
        .client_version = "test",
        .timeout_ms = 100,
        .configuration_fingerprint = [_]u8{1} ** 32,
    }});
    defer replacement.deinit();
    try std.testing.expectEqual(
        lifecycle.McpConfigurationApplyOutcome.applied,
        try runtime.applyMcpConfiguration(&replacement),
    );
    try std.testing.expectEqual(@as(usize, 1), fake_core.mcp_configuration_applies);
    try std.testing.expectEqual(@as(usize, 1), fake_core.last_mcp_apply_server_count);
    const activation = switch (try runtime.activateMcp()) {
        .activated => |value| value,
        else => return error.TestUnexpectedResult,
    };
    activation.deinit();
}

test "MCP Runtime declaratively applies a replacement configuration" {
    fake_core.reset();
    var first_transport: McpFixtureTransport = .{};
    var first_owner = lifecycle.McpTransportOwner.init(
        first_transport.descriptor(),
        McpFixtureTransport.deinit,
    );
    var initial = try lifecycle.McpRuntimeInput.init(std.testing.allocator, 1, &.{.{
        .id = "first",
        .transport_owner = &first_owner,
        .transport = .stdio,
        .namespace = "first",
        .client_name = "MetaWork",
        .client_version = "test",
        .timeout_ms = 100,
        .configuration_fingerprint = [_]u8{1} ** 32,
    }});
    defer initial.deinit();
    const runtime = try lifecycle.Runtime.initWithApi(
        std.testing.io,
        std.testing.allocator,
        &fake_api,
        .{
            .max_sessions = 1,
            .mcp_input = &initial,
        },
    );
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }

    var second_transport: McpFixtureTransport = .{};
    var second_owner = lifecycle.McpTransportOwner.init(
        second_transport.descriptor(),
        McpFixtureTransport.deinit,
    );
    var replacement = try lifecycle.McpRuntimeInput.init(std.testing.allocator, 2, &.{.{
        .id = "second",
        .transport_owner = &second_owner,
        .transport = .stdio,
        .namespace = "second",
        .client_name = "MetaWork",
        .client_version = "test",
        .timeout_ms = 100,
        .configuration_fingerprint = [_]u8{2} ** 32,
    }});
    defer replacement.deinit();
    try std.testing.expectEqual(
        lifecycle.McpConfigurationApplyOutcome.applied,
        try runtime.applyMcpConfiguration(&replacement),
    );
    try std.testing.expectEqual(@as(usize, 1), fake_core.mcp_configuration_applies);
    try std.testing.expectEqual(@as(usize, 1), fake_core.last_mcp_apply_server_count);

    var rejected_transport: McpFixtureTransport = .{};
    var rejected_owner = lifecycle.McpTransportOwner.init(
        rejected_transport.descriptor(),
        McpFixtureTransport.deinit,
    );
    var rejected = try lifecycle.McpRuntimeInput.init(std.testing.allocator, 3, &.{.{
        .id = "rejected",
        .transport_owner = &rejected_owner,
        .transport = .stdio,
        .namespace = "rejected",
        .client_name = "MetaWork",
        .client_version = "test",
        .timeout_ms = 100,
        .configuration_fingerprint = [_]u8{3} ** 32,
    }});
    defer rejected.deinit();
    fake_core.forceNextMcpApplyDisposition(wire.MCP_APPLY_REJECTED);
    try std.testing.expectEqual(
        lifecycle.McpConfigurationApplyOutcome.rejected,
        try runtime.applyMcpConfiguration(&rejected),
    );
}

test "MCP refresh failure immediately invalidates the previous selection generation" {
    fake_core.reset();
    const runtime = try createTestRuntime(.{ .max_sessions = 1 });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    const projection = try runtime.refreshMcpCatalog();
    defer projection.deinit();
    const selection = try runtime.createMcpSelection(projection, &.{});
    defer selection.deinit();
    fake_core.forceNextMcpRefreshStatus(wire.STATUS_CORE_ERROR);
    try std.testing.expectError(error.McpRefreshFailed, runtime.refreshMcpCatalog());
    try std.testing.expectError(
        error.StaleMcpSelection,
        runtime.createMcpSelection(projection, &.{}),
    );
}

test "MCP catalog refresh binds explicit Session selection and idle replacement" {
    fake_core.reset();
    const runtime = try createTestRuntime(.{ .max_sessions = 1 });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    const projection = try runtime.refreshMcpCatalog();
    defer projection.deinit();
    try std.testing.expectEqual(@as(u64, 7), projection.catalogGeneration());
    const selection = try runtime.createMcpSelection(projection, &.{});
    defer selection.deinit();
    const workspace_root = if (std.fs.path.sep == '\\')
        "C:\\tmp\\metawork-mcp-selection"
    else
        "/tmp/metawork-mcp-selection";
    const temporary_root = if (std.fs.path.sep == '\\') "C:\\tmp" else "/tmp";
    const session = try runtime.createSession(.{
        .provider = .anthropic,
        .permission_mode = .default,
        .shell_policy = .disabled,
        .credential = "fixture-secret",
        .model = "fixture-model",
        .workspace = .{
            .canonical_root = workspace_root,
            .trust = .{ .temporary = temporary_root },
        },
        .mcp_selection = selection,
    });
    try session.updateMcpSelection(null);
    fake_core.lock();
    const updates_after_clear = fake_core.mcp_updates;
    const selectors_after_clear = fake_core.last_mcp_update_selector_count;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), updates_after_clear);
    try std.testing.expectEqual(@as(?u64, 0), selectors_after_clear);
    try session.updateMcpSelection(selection);
    const queued_run = try session.prepareRun(.{ .text = "hold selection" });
    try std.testing.expectError(
        error.SessionNotIdle,
        session.updateMcpSelection(null),
    );
    try session.cancelPreparedRun(queued_run);
    fake_core.lock();
    const refreshes = fake_core.mcp_refreshes;
    const descriptions = fake_core.mcp_descriptions;
    const updates = fake_core.mcp_updates;
    const last_selector_count = fake_core.last_mcp_update_selector_count;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), refreshes);
    try std.testing.expectEqual(@as(usize, 1), descriptions);
    try std.testing.expectEqual(@as(usize, 2), updates);
    try std.testing.expectEqual(@as(?u64, 0), last_selector_count);
}

test "MCP selection mutation preserves reusable and poison status contracts" {
    fake_core.reset();
    const runtime = try createTestRuntime(.{ .max_sessions = 1 });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    const projection = try runtime.refreshMcpCatalog();
    defer projection.deinit();
    const selection = try runtime.createMcpSelection(projection, &.{});
    defer selection.deinit();
    const session = try runtime.createSession(.{
        .provider = .anthropic,
        .permission_mode = .default,
        .shell_policy = .disabled,
        .credential = "fixture-secret",
        .model = "fixture-model",
        .workspace = .{
            .canonical_root = if (std.fs.path.sep == '\\') "C:\\tmp\\metawork-mcp-status" else "/tmp/metawork-mcp-status",
            .trust = .{ .temporary = if (std.fs.path.sep == '\\') "C:\\tmp" else "/tmp" },
        },
        .mcp_selection = selection,
    });
    fake_core.forceNextMcpUpdateStatus(wire.STATUS_BUSY);
    try std.testing.expectError(error.SessionNotIdle, session.updateMcpSelection(null));
    try std.testing.expectEqual(lifecycle.SessionState.idle, session.snapshot().state);
    fake_core.forceNextMcpUpdateStatus(wire.STATUS_CHECKPOINT_BUDGET_REQUIRED);
    try std.testing.expectError(
        error.McpCheckpointBudgetRequired,
        session.updateMcpSelection(selection),
    );
    try std.testing.expectEqual(lifecycle.SessionState.idle, session.snapshot().state);
    try session.updateMcpSelection(null);
    fake_core.forceNextMcpUpdateStatus(wire.STATUS_STALE_CATALOG);
    try std.testing.expectError(
        error.McpSelectionUpdateFailed,
        session.updateMcpSelection(selection),
    );
    try std.testing.expectEqual(lifecycle.SessionState.poisoned, session.snapshot().state);
}

const CompactThreadContext = struct {
    session: *lifecycle.Session,
    operation_id: u64,
    result: ?lifecycle.CompactTerminalResult = null,
};

fn compactOnThread(context: *CompactThreadContext) void {
    context.result = context.session.executePreparedCompact(
        context.operation_id,
    ) catch unreachable;
}

test "manual compact is a typed Session operation and preserves Run identity" {
    fake_core.reset();
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);
    const operation_id = try session.prepareCompact();
    try std.testing.expectEqual(@as(u64, 1), operation_id);
    try std.testing.expectEqual(
        lifecycle.SessionState.compact_queued,
        session.snapshot().state,
    );
    try std.testing.expectError(
        error.SessionNotIdle,
        session.prepareRun(.{ .text = "must wait" }),
    );
    var terminal = try session.executePreparedCompact(operation_id);
    defer terminal.deinit();
    try std.testing.expectEqual(@as(?lifecycle.CompactOutcome, .compacted), terminal.outcome);
    try std.testing.expectEqual(@as(u64, 100), terminal.before_context_tokens);
    try std.testing.expectEqual(@as(u64, 40), terminal.after_context_tokens);
    try std.testing.expectEqual(@as(u64, 5), terminal.input_tokens);
    try std.testing.expectEqual(lifecycle.SessionDisposition.reusable, terminal.session_disposition_at_completion);
    try std.testing.expectEqual(lifecycle.SessionState.idle, session.snapshot().state);

    const run_id = try submitSession(session, "continue after compact");
    try session.waitRun(run_id);
    var run_terminal = takeTestTerminal(session, run_id);
    defer run_terminal.deinit();
    try std.testing.expectEqual(@as(u64, 1), run_id);

    fake_core.forceNextCompactStatus(wire.STATUS_CHECKPOINT_BUDGET_REQUIRED);
    const budget_operation_id = try session.prepareCompact();
    var budget_terminal = try session.executePreparedCompact(budget_operation_id);
    defer budget_terminal.deinit();
    try std.testing.expectEqual(
        @as(?sdk.Status, .checkpoint_budget_required),
        budget_terminal.abi_status,
    );
    try std.testing.expectEqual(
        @as(?lifecycle.TerminalFailure, .abi_status),
        budget_terminal.failure,
    );
    try std.testing.expectEqual(
        lifecycle.SessionDisposition.reusable,
        budget_terminal.session_disposition_at_completion,
    );
    try std.testing.expectEqual(lifecycle.SessionState.idle, session.snapshot().state);

    const retry_run_id = try submitSession(session, "continue after compact budget rejection");
    try session.waitRun(retry_run_id);
    var retry_terminal = takeTestTerminal(session, retry_run_id);
    defer retry_terminal.deinit();
    try std.testing.expectEqual(@as(?sdk.StopReason, .end_turn), retry_terminal.stop_reason);
    try closeSession(session, .session_close);
}

test "manual compact cancellation waits for the typed aborted result" {
    fake_core.reset();
    fake_core.setNextPlan(.controlled);
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);
    const operation_id = try session.prepareCompact();
    var context = CompactThreadContext{
        .session = session,
        .operation_id = operation_id,
    };
    const thread = try std.Thread.spawn(.{}, compactOnThread, .{&context});
    try session.waitForState(.compacting);
    try session.requestCompactCancellation(operation_id, .user_cancel);
    thread.join();
    var terminal = context.result.?;
    defer terminal.deinit();
    try std.testing.expectEqual(@as(?lifecycle.CompactOutcome, .aborted), terminal.outcome);
    try std.testing.expectEqual(@as(?sdk.Status, .ok), terminal.abort_status);
    try std.testing.expectEqual(@as(?lifecycle.ExternalInterruption, .user_cancel), terminal.interruption);
    fake_core.lock();
    const abort_calls = fake_core.compact_abort_calls;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), abort_calls);
    try closeSession(session, .session_close);
}

test "accepted compact cancellation requires the typed aborted result" {
    fake_core.reset();
    fake_core.setNextPlan(.controlled);
    fake_core.forceNextCompactAbortStatus(wire.STATUS_OK);
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);
    const operation_id = try session.prepareCompact();
    var context = CompactThreadContext{
        .session = session,
        .operation_id = operation_id,
    };
    const thread = try std.Thread.spawn(.{}, compactOnThread, .{&context});
    try session.waitForState(.compacting);
    try session.requestCompactCancellation(operation_id, .user_cancel);
    fake_core.releaseControlled();
    thread.join();
    var terminal = context.result.?;
    defer terminal.deinit();
    try std.testing.expectEqual(
        @as(?lifecycle.TerminalFailure, .dependency_contract),
        terminal.failure,
    );
    try std.testing.expectEqual(@as(?sdk.Status, .ok), terminal.abort_status);
    try std.testing.expectEqual(
        lifecycle.SessionDisposition.poisoned,
        terminal.session_disposition_at_completion,
    );
    try std.testing.expectEqual(lifecycle.SessionState.poisoned, session.snapshot().state);
    try closeSession(session, .session_close);
}

test "malformed compact result poisons Session and queued compact can be cancelled" {
    fake_core.reset();
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);
    const cancelled_id = try session.prepareCompact();
    try session.cancelPreparedCompact(cancelled_id);
    try std.testing.expectEqual(lifecycle.SessionState.idle, session.snapshot().state);
    fake_core.makeNextCompactResultMalformed();
    const operation_id = try session.prepareCompact();
    var terminal = try session.executePreparedCompact(operation_id);
    defer terminal.deinit();
    try std.testing.expectEqual(
        @as(?lifecycle.TerminalFailure, .dependency_contract),
        terminal.failure,
    );
    try std.testing.expectEqual(lifecycle.SessionDisposition.poisoned, terminal.session_disposition_at_completion);
    try std.testing.expectEqual(lifecycle.SessionState.poisoned, session.snapshot().state);
    try closeSession(session, .session_close);
}

test "Runtime rejects tables missing required capabilities" {
    var api = fake_api;
    api.capabilities &= ~wire.CAP_SKILL_CATALOG;
    try std.testing.expectError(
        error.UnsupportedAbi,
        lifecycle.Runtime.initWithApi(
            std.testing.io,
            std.testing.allocator,
            &api,
            .{ .max_sessions = 1 },
        ),
    );

    api = fake_api;
    api.capabilities &= ~wire.CAP_TYPED_RUN_INPUT;
    try std.testing.expectError(
        error.UnsupportedAbi,
        lifecycle.Runtime.initWithApi(
            std.testing.io,
            std.testing.allocator,
            &api,
            .{ .max_sessions = 1 },
        ),
    );

    api = fake_api;
    api.capabilities &= ~wire.CAP_RUN_STATE_OBSERVATION;
    try std.testing.expectError(
        error.UnsupportedAbi,
        lifecycle.Runtime.initWithApi(
            std.testing.io,
            std.testing.allocator,
            &api,
            .{ .max_sessions = 1 },
        ),
    );

    api = fake_api;
    api.runtime_apply_mcp_configuration = null;
    try std.testing.expectError(
        error.UnsupportedAbi,
        lifecycle.Runtime.initWithApi(
            std.testing.io,
            std.testing.allocator,
            &api,
            .{ .max_sessions = 1 },
        ),
    );
}

test "Catalog leases copy descriptors and block Runtime destroy until exactly-once release" {
    fake_core.reset();
    const runtime = try createTestRuntime(.{ .max_sessions = 1 });
    var runtime_done = false;
    var lease: ?*lifecycle.CatalogLease = null;
    var projection: ?lifecycle.CatalogProjection = null;
    defer {
        if (projection) |*value| value.deinit();
        if (lease) |value| runtime.releaseSkillCatalog(value) catch {};
        if (!runtime_done) runtime.shutdown() catch {};
        runtime.deinit();
    }
    const root = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(root);

    const acquisition = try runtime.querySkillCatalog(.{
        .workspace_root = root,
        .canonical_user_home = root,
        .workspace_epoch = "workspace-1",
    });
    lease = acquisition.lease;
    projection = acquisition.projection;
    try std.testing.expectEqualStrings(
        fixture.fixture_catalog_revision,
        projection.?.revision,
    );
    try std.testing.expectEqual(lifecycle.CatalogHealth.healthy, projection.?.health);
    try std.testing.expectEqual(@as(usize, 1), projection.?.skills.len);
    try std.testing.expectEqualStrings("review", projection.?.skills[0].invocation_name);
    try std.testing.expectEqualStrings("target", projection.?.skills[0].argument_names[0]);

    fake_core.lock();
    const queried = fake_core.catalog_queries;
    const released_before = fake_core.catalog_releases;
    const descriptor_releases = fake_core.buffer_releases;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), queried);
    try std.testing.expectEqual(@as(usize, 0), released_before);
    try std.testing.expectEqual(@as(usize, 1), descriptor_releases);
    try std.testing.expectError(
        error.CatalogLeasesOutstanding,
        runtime.shutdown(),
    );

    projection.?.deinit();
    projection = null;
    try runtime.releaseSkillCatalog(lease.?);
    lease = null;
    fake_core.lock();
    const released_after = fake_core.catalog_releases;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), released_after);
    try runtime.shutdown();
    runtime_done = true;
}

test "invalid and duplicate catalog descriptors release every AgentCore owner" {
    inline for (.{ fixture.CatalogPlan.malformed, fixture.CatalogPlan.duplicate_skill_id }) |plan| {
        fake_core.reset();
        fake_core.setCatalogPlan(plan);
        const runtime = try createTestRuntime(.{ .max_sessions = 1 });
        defer {
            runtime.shutdown() catch unreachable;
            runtime.deinit();
        }
        const root = try std.Io.Dir.cwd().realPathFileAlloc(
            std.testing.io,
            ".",
            std.testing.allocator,
        );
        defer std.testing.allocator.free(root);
        try std.testing.expectError(error.InvalidCatalogDescriptor, runtime.querySkillCatalog(.{
            .workspace_root = root,
            .canonical_user_home = root,
            .workspace_epoch = "workspace-1",
        }));
        fake_core.lock();
        const releases = fake_core.catalog_releases;
        const buffers = fake_core.buffer_releases;
        fake_core.unlock();
        try std.testing.expectEqual(@as(usize, 1), releases);
        try std.testing.expectEqual(@as(usize, 1), buffers);
    }
}

test "Skill input is deep-copied and encoded only for the typed Core call" {
    fake_core.reset();
    const runtime = try createTestRuntime(.{ .max_sessions = 1 });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    const root = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(root);
    var acquisition = try runtime.querySkillCatalog(.{
        .workspace_root = root,
        .canonical_user_home = root,
        .workspace_epoch = "workspace-1",
    });
    defer acquisition.projection.deinit();
    const session = try runtime.createSession(.{
        .provider = .anthropic,
        .permission_mode = .default,
        .shell_policy = .disabled,
        .credential = "fixture-secret",
        .model = "fixture-model",
        .workspace = .{
            .canonical_root = root,
            .trust = .explicitly_trusted,
        },
        .canonical_user_home = root,
        .workspace_epoch = "workspace-1",
        .skill_catalog = acquisition.lease,
        .skill_policy = .{ .granted_skill_ids = &.{fixture.fixture_skill_id} },
    });
    try runtime.releaseSkillCatalog(acquisition.lease);

    const skill_id = try std.testing.allocator.dupe(
        u8,
        fixture.fixture_skill_id,
    );
    defer std.testing.allocator.free(skill_id);
    const revision = try std.testing.allocator.dupe(
        u8,
        fixture.fixture_catalog_revision,
    );
    defer std.testing.allocator.free(revision);
    const target = try std.testing.allocator.dupe(u8, "src/main.zig");
    defer std.testing.allocator.free(target);
    const focus = try std.testing.allocator.dupe(u8, "correctness");
    defer std.testing.allocator.free(focus);
    const run_id = try session.prepareRun(.{ .skill = .{
        .skill_id = skill_id,
        .catalog_revision = revision,
        .argument_values = &.{ target, focus },
    } });
    @memset(skill_id, 'x');
    @memset(revision, 'x');
    @memset(target, 'x');
    @memset(focus, 'x');
    var run = try session.beginRun(run_id);
    var terminal = run.execute();
    defer terminal.deinit();
    run.deinit();
    try std.testing.expectEqual(lifecycle.Status.ok, terminal.abi_status.?);
    fake_core.lock();
    const saw_skill = fake_core.skill_run_seen;
    const input_matches = fake_core.skill_input_matches;
    const home_seen = fake_core.workspace_home_seen;
    const bound = fake_core.skill_session_bound;
    const policy_seen = fake_core.skill_policy_seen;
    const permission_rules_absent = fake_core.permission_rules_absent;
    fake_core.unlock();
    try std.testing.expect(saw_skill);
    try std.testing.expect(input_matches);
    try std.testing.expect(home_seen);
    try std.testing.expect(bound);
    try std.testing.expect(policy_seen);
    try std.testing.expect(permission_rules_absent);
    try session.close(.session_close);
}

test "Skill rejection statuses leave the Session reusable" {
    fake_core.reset();
    const runtime = try createTestRuntime(.{ .max_sessions = 1 });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    const root = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(root);
    const cases = [_]struct {
        plan: Plan,
        status: lifecycle.Status,
    }{
        .{ .plan = .stale_catalog, .status = .stale_catalog },
        .{ .plan = .skill_not_found, .status = .skill_not_found },
        .{ .plan = .invalid_skill_arguments, .status = .invalid_skill_arguments },
        .{ .plan = .skill_policy_violation, .status = .skill_policy_violation },
        .{ .plan = .skill_unavailable, .status = .skill_unavailable },
    };
    for (cases) |case| {
        fake_core.setNextPlan(case.plan);
        var acquisition = try runtime.querySkillCatalog(.{
            .workspace_root = root,
            .canonical_user_home = root,
            .workspace_epoch = "workspace-1",
        });
        const session = try runtime.createSession(.{
            .provider = .anthropic,
            .permission_mode = .default,
            .shell_policy = .disabled,
            .credential = "fixture-secret",
            .model = "fixture-model",
            .workspace = .{
                .canonical_root = root,
                .trust = .explicitly_trusted,
            },
            .canonical_user_home = root,
            .workspace_epoch = "workspace-1",
            .skill_catalog = acquisition.lease,
            .skill_policy = .{ .granted_skill_ids = &.{fixture.fixture_skill_id} },
        });
        try runtime.releaseSkillCatalog(acquisition.lease);
        acquisition.projection.deinit();
        const run_id = try session.prepareRun(.{ .skill = .{
            .skill_id = fixture.fixture_skill_id,
            .catalog_revision = fixture.fixture_catalog_revision,
            .argument_values = &.{ "src/main.zig", "correctness" },
        } });
        var run = try session.beginRun(run_id);
        var terminal = run.execute();
        run.deinit();
        try std.testing.expectEqual(case.status, terminal.abi_status.?);
        try std.testing.expectEqual(
            lifecycle.SessionDisposition.reusable,
            terminal.session_disposition_at_completion,
        );
        terminal.deinit();
        const retry = try session.prepareRun(.{ .text = "still reusable" });
        try session.cancelPreparedRun(retry);
        try session.close(.session_close);
        try runtime.releaseClosedSession(session);
    }
}

test "Session catalog refresh binds explicit selection only while idle and rejects another Workspace epoch" {
    fake_core.reset();
    const runtime = try createTestRuntime(.{ .max_sessions = 1 });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    const root = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(root);
    var current = try runtime.querySkillCatalog(.{
        .workspace_root = root,
        .canonical_user_home = root,
        .workspace_epoch = "workspace-1",
    });
    defer current.projection.deinit();
    defer runtime.releaseSkillCatalog(current.lease) catch unreachable;
    const session = try runtime.createSession(.{
        .provider = .anthropic,
        .permission_mode = .default,
        .shell_policy = .disabled,
        .credential = "fixture-secret",
        .model = "fixture-model",
        .workspace = .{
            .canonical_root = root,
            .trust = .explicitly_trusted,
        },
        .canonical_user_home = root,
        .workspace_epoch = "workspace-1",
    });

    const queued = try session.prepareRun(.{ .text = "queued" });
    try std.testing.expectError(
        error.SessionNotIdle,
        session.refreshSkillCatalog(current.lease, .{ .granted_skill_ids = &.{} }),
    );
    try session.cancelPreparedRun(queued);
    try session.refreshSkillCatalog(current.lease, .{
        .granted_skill_ids = &.{fixture.fixture_skill_id},
    });

    var other = try runtime.querySkillCatalog(.{
        .workspace_root = root,
        .canonical_user_home = root,
        .workspace_epoch = "workspace-2",
    });
    defer other.projection.deinit();
    defer runtime.releaseSkillCatalog(other.lease) catch unreachable;
    try std.testing.expectError(
        error.CatalogBindingMismatch,
        session.refreshSkillCatalog(other.lease, .{ .granted_skill_ids = &.{} }),
    );
    for ([_]u32{
        wire.STATUS_RESOURCE_LIMIT,
        wire.STATUS_CHECKPOINT_BUDGET_REQUIRED,
    }) |recoverable_status| {
        fake_core.forceNextSkillUpdateStatus(recoverable_status);
        try std.testing.expectError(
            error.CatalogRefreshFailed,
            session.refreshSkillCatalog(current.lease, .{ .granted_skill_ids = &.{} }),
        );
        try std.testing.expectEqual(lifecycle.SessionState.idle, session.snapshot().state);
        const reusable = try session.prepareRun(.{ .text = "still reusable" });
        try session.cancelPreparedRun(reusable);
    }
    fake_core.forceNextSkillUpdateStatus(wire.STATUS_STALE_COMPACT);
    try std.testing.expectError(
        error.CatalogRefreshFailed,
        session.refreshSkillCatalog(current.lease, .{ .granted_skill_ids = &.{} }),
    );
    try std.testing.expectEqual(lifecycle.SessionState.poisoned, session.snapshot().state);
    try std.testing.expectError(
        error.SessionPoisoned,
        session.prepareRun(.{ .text = "must not continue" }),
    );
    fake_core.lock();
    const refreshes = fake_core.catalog_refreshes;
    const policy_seen = fake_core.skill_policy_seen;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), refreshes);
    try std.testing.expect(policy_seen);
    try session.close(.session_close);
}

const UiAnswerThenIdentityMismatch = struct {
    session: ?*lifecycle.Session = null,
    invoked: bool = false,
    failed: bool = false,
    mismatch_status: ?u32 = null,

    fn notify(context: ?*anyopaque) lifecycle.EventReadyNotification {
        const self: *UiAnswerThenIdentityMismatch = @ptrCast(@alignCast(context orelse
            return .unavailable));
        if (self.invoked) return .already_pending;
        const session = self.session orelse return .already_pending;
        const request_id = session.pendingUiRequest() orelse return .already_pending;
        self.invoked = true;
        const run_id = session.snapshot().active_run_id;
        session.respondPermission(
            run_id,
            request_id,
            .allow_once,
        ) catch {
            self.failed = true;
            return .unavailable;
        };
        self.mismatch_status = fake_core.invokeRunningIdentityMismatch();
        if (self.mismatch_status == null) self.failed = true;
        return .scheduled;
    }
};

test "RunControlLease remains safe after natural completion" {
    fake_core.reset();
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);
    const run_id = try session.prepareRun(.{
        .text = "complete before the retained lease is released",
    });
    var run = try session.beginRun(run_id);
    var lease = run.control().tryAcquireLease().?;
    var terminal = run.execute();
    defer terminal.deinit();
    run.deinit();

    try std.testing.expectEqual(
        lifecycle.TerminationRequestResult.already_terminal,
        lease.requestTermination(.{ .interrupted = .user_cancel }),
    );
    lease.deinit();
    try closeSession(session, .session_close);
}

test "RunControlLease rejects a stale generation after slot reuse" {
    fake_core.reset();
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);

    const first_id = try session.prepareRun(.{ .text = "first generation" });
    var first = try session.beginRun(first_id);
    var stale = first.control().tryAcquireLease().?;
    var first_terminal = first.execute();
    defer first_terminal.deinit();
    first.deinit();

    const second_id = try session.prepareRun(.{ .text = "second generation" });
    var second = try session.beginRun(second_id);
    try std.testing.expectEqual(
        lifecycle.TerminationRequestResult.stale_run,
        stale.requestTermination(.{ .interrupted = .user_cancel }),
    );
    stale.deinit();
    var second_terminal = second.execute();
    defer second_terminal.deinit();
    second.deinit();
    try closeSession(session, .session_close);
}

test "RunControlLease termination before execute avoids the Core call" {
    fake_core.reset();
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);
    const run_id = try session.prepareRun(.{
        .text = "cancel before entering Core",
    });
    var run = try session.beginRun(run_id);
    var lease = run.control().tryAcquireLease().?;
    try std.testing.expectEqual(
        lifecycle.TerminationRequestResult.requested,
        lease.requestTermination(.{ .interrupted = .user_cancel }),
    );
    lease.deinit();
    var terminal = run.execute();
    defer terminal.deinit();
    run.deinit();

    try std.testing.expectEqual(@as(?u32, null), terminal.raw_status_code);
    try std.testing.expectEqual(
        lifecycle.TerminationSignal{ .interrupted = .user_cancel },
        terminal.termination_signal.?,
    );
    fake_core.lock();
    const run_calls = fake_core.run_calls;
    const abort_calls = fake_core.abort_calls;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 0), run_calls);
    try std.testing.expectEqual(@as(usize, 0), abort_calls);
    try closeSession(session, .session_close);
}

test "RunControlLease close disables acquisition and waits for quiescence" {
    fake_core.reset();
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);
    const run_id = try session.prepareRun(.{
        .text = "retain control across close",
    });
    var run = try session.beginRun(run_id);
    const control = run.control();
    var lease = control.tryAcquireLease().?;
    var terminal = run.execute();
    terminal.deinit();
    run.deinit();

    const close_thread = try std.Thread.spawn(.{}, closeOnThread, .{session});
    try session.waitForState(.closing);
    try std.testing.expect(control.tryAcquireLease() == null);
    fake_core.lock();
    const destroyed_while_leased = fake_core.session_destroyed;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 0), destroyed_while_leased);
    lease.deinit();
    close_thread.join();
    try std.testing.expectEqual(lifecycle.SessionState.closed, session.snapshot().state);
}

test "Agent Runtime creates and destroys an idle Session" {
    fake_core.reset();
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 2,
        .max_sessions = 2,
    });
    defer deinitTestComposition(runtime);
    const session = try openSession(runtime);
    try std.testing.expect(fake_core.credential_seen);
    try std.testing.expect(fake_core.zero_host_tools_seen);
    try std.testing.expect(fake_core.builtin_allowlist_seen);
    try std.testing.expectEqual(lifecycle.SessionState.idle, session.snapshot().state);
    try closeSession(session, .session_close);
    try closeSession(session, .session_close);
    try shutdownTestComposition(runtime);
    try shutdownTestComposition(runtime);
    try std.testing.expectEqual(@as(usize, 1), fake_core.runtime_created);
    try std.testing.expectEqual(@as(usize, 1), fake_core.runtime_destroyed);
    try std.testing.expectEqual(@as(usize, 1), fake_core.session_destroyed);
}

test "Agent Runtime applies the fixed MetaWork built-in surface to Session" {
    fake_core.reset();
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_storage);
    const workspace_root = root_storage[0..root_len];
    const session = try runtime.createSession(.{
        .provider = .anthropic,
        .permission_mode = .default,
        .shell_policy = .unrestricted,
        .credential = "fixture-secret",
        .model = "fixture-model",
        .workspace = .{
            .canonical_root = workspace_root,
            .trust = .{ .temporary = workspace_root },
        },
        .canonical_user_home = workspace_root,
        .workspace_epoch = "metawork-agent-tools",
    });
    defer closeSession(session, .session_close) catch {};

    const expected = [_][]const u8{
        "Read", "Write", "Edit", "Glob", "Grep", "Bash", "BashOutput", "KillShell", "WebSearch", "WebFetch",
    };
    try std.testing.expectEqual(expected.len, fake_core.last_allowed_tool_count);
    for (expected, 0..) |name, index| {
        try std.testing.expectEqualStrings(
            name,
            fake_core.last_allowed_tool_names[index][0..name.len],
        );
    }
    for (fake_core.last_allowed_tool_names[0..fake_core.last_allowed_tool_count]) |storage|
        try std.testing.expect(std.mem.indexOf(u8, &storage, "AskUserQuestion") == null);
}

test "Workspace requires an absolute temporary or explicit trusted root" {
    fake_core.reset();
    const outside_temporary = if (std.fs.path.sep == '\\') "C:\\var\\not-temp" else "/var/not-temp";
    const temporary_root = if (std.fs.path.sep == '\\') "C:\\tmp" else "/tmp";
    const non_canonical = if (std.fs.path.sep == '\\') "C:\\tmp\\..\\etc" else "/tmp/../etc";
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    try std.testing.expectError(error.InvalidWorkspace, runtime.createSession(.{
        .provider = .anthropic,
        .permission_mode = .default,
        .shell_policy = .disabled,
        .credential = "fixture-secret",
        .model = "fixture-model",
        .workspace = .{ .canonical_root = "relative", .trust = .explicitly_trusted },
    }));
    try std.testing.expectError(error.WorkspaceNotTrusted, runtime.createSession(.{
        .provider = .anthropic,
        .permission_mode = .default,
        .shell_policy = .disabled,
        .credential = "fixture-secret",
        .model = "fixture-model",
        .workspace = .{
            .canonical_root = outside_temporary,
            .trust = .{ .temporary = temporary_root },
        },
    }));
    try std.testing.expectError(error.InvalidWorkspace, runtime.createSession(.{
        .provider = .anthropic,
        .permission_mode = .default,
        .shell_policy = .disabled,
        .credential = "fixture-secret",
        .model = "fixture-model",
        .workspace = .{
            .canonical_root = non_canonical,
            .trust = .{ .temporary = temporary_root },
        },
    }));
}

test "queued prompt memory is bounded before allocation" {
    fake_core.reset();
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
        .max_prompt_bytes = 4,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);
    try std.testing.expectError(error.RunInputTooLarge, submitSession(session, "12345"));
    try std.testing.expectEqual(lifecycle.SessionState.idle, session.snapshot().state);
    try closeSession(session, .session_close);
}

test "pre-admission resource limit leaves the Session reusable" {
    fake_core.reset();
    fake_core.setNextPlan(.resource_limit);
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);
    const first_run = try submitSession(session, "exceed a Core resource limit");
    try session.waitRun(first_run);
    var first_terminal = takeTestTerminal(session, first_run);
    defer first_terminal.deinit();
    const first = session.snapshot();
    try std.testing.expectEqual(@as(?u32, wire.STATUS_RESOURCE_LIMIT), first_terminal.raw_status_code);
    try std.testing.expectEqual(@as(?lifecycle.TerminalFailure, .abi_status), first_terminal.failure);
    try std.testing.expectEqual(lifecycle.SessionDisposition.reusable, first_terminal.session_disposition_at_completion);
    try std.testing.expectEqualSlices(u8, &.{diagnostic_byte}, first_terminal.diagnostic());
    try std.testing.expect(!first_terminal.diagnostic_truncated);
    try std.testing.expectEqual(lifecycle.SessionState.idle, first.state);

    const second_run = try submitSession(session, "the Session remains admitted");
    try session.waitRun(second_run);
    try std.testing.expectEqual(lifecycle.SessionState.idle, session.snapshot().state);
    try closeSession(session, .session_close);
}

test "closing an active Run aborts, joins, and preserves the first termination signal" {
    fake_core.reset();
    fake_core.setNextPlan(.controlled_callback_failed);
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);
    const run_id = try submitSession(session, "race cancel with callback failure");
    try session.waitForState(.running);

    const cancel_thread = try std.Thread.spawn(.{}, cancelOnThread, .{ session, run_id });
    const failure_thread = try std.Thread.spawn(.{}, failPipelineOnThread, .{session});
    cancel_thread.join();
    failure_thread.join();
    try session.waitRun(run_id);

    var terminal = takeTestTerminal(session, run_id);
    defer terminal.deinit();
    const signal = terminal.termination_signal.?;
    try std.testing.expect(switch (signal) {
        .interrupted => |value| value == .user_cancel,
        .event_pump_failure => |value| value == .consumer_rejected,
        else => false,
    });
    try std.testing.expectEqual(@as(?u32, wire.STATUS_CALLBACK_FAILED), terminal.raw_status_code);
    session.recordTerminationSignal(.{ .interrupted = .timeout });
    try closeSession(session, .session_close);
    fake_core.lock();
    const abort_calls = fake_core.abort_calls;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), abort_calls);
}

test "malformed Core events fail the Run instead of entering the bounded sink" {
    fake_core.reset();
    fake_core.setNextPlan(.malformed_event_callback);
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);
    const run_id = try submitSession(session, "emit malformed event");
    try session.waitRun(run_id);
    var terminal = takeTestTerminal(session, run_id);
    defer terminal.deinit();
    const snapshot = session.snapshot();
    try std.testing.expectEqual(@as(?u32, wire.STATUS_CALLBACK_FAILED), terminal.raw_status_code);
    try std.testing.expectEqual(
        lifecycle.TerminationSignal{ .event_pump_failure = .invalid_event },
        terminal.termination_signal.?,
    );
    try std.testing.expectEqual(lifecycle.SessionState.poisoned, snapshot.state);
    try std.testing.expectError(error.SessionPoisoned, submitSession(session, "must not continue"));
    try std.testing.expect(runtime.takeEvent() == null);
    try closeSession(session, .session_close);
    fake_core.lock();
    const releases = fake_core.buffer_releases;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), releases);
}

test "non-UTF-8 Core events fail the Run before entering the bounded sink" {
    fake_core.reset();
    fake_core.setNextPlan(.invalid_utf8_event_callback);
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);
    const run_id = try submitSession(session, "emit non-UTF-8 event");
    try session.waitRun(run_id);
    var terminal = takeTestTerminal(session, run_id);
    defer terminal.deinit();
    const snapshot = session.snapshot();
    try std.testing.expectEqual(@as(?u32, wire.STATUS_CALLBACK_FAILED), terminal.raw_status_code);
    try std.testing.expectEqual(
        lifecycle.TerminationSignal{ .event_pump_failure = .invalid_event },
        terminal.termination_signal.?,
    );
    try std.testing.expectEqual(lifecycle.SessionState.poisoned, snapshot.state);
    try std.testing.expect(runtime.takeEvent() == null);
    try closeSession(session, .session_close);
}

test "RunContext identity violations fail closed and poison the Session" {
    fake_core.reset();
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 4,
        .event_capacity = 8,
        .per_session_event_capacity = 2,
        .control_reserved_capacity = 0,
        .per_session_control_reserved_capacity = 0,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }

    const plans = [_]Plan{
        .wrong_event_session_handle,
        .wrong_event_run_id,
        .same_run_session_id_mismatch,
        .concurrent_session_id_mismatch,
    };
    for (plans) |plan| {
        fake_core.setNextPlan(plan);
        const session = try openSession(runtime);
        const run_id = try submitSession(session, "reject invalid callback identity");
        try session.waitRun(run_id);
        var terminal = takeTestTerminal(session, run_id);
        defer terminal.deinit();
        try std.testing.expectEqual(
            @as(?u32, wire.STATUS_CALLBACK_FAILED),
            terminal.raw_status_code,
        );
        try std.testing.expectEqual(
            @as(?lifecycle.TerminalFailure, .dependency_contract),
            terminal.failure,
        );
        try std.testing.expectEqual(lifecycle.SessionState.poisoned, session.snapshot().state);
        try std.testing.expectError(
            error.SessionPoisoned,
            submitSession(session, "identity failure is permanent"),
        );
        try closeSession(session, .session_close);
    }
    while (runtime.takeEvent()) |event| {
        var owned = event;
        owned.deinit();
    }
}

test "RunContext session identity remains stable across Runs" {
    fake_core.reset();
    fake_core.setNextPlan(.cross_run_session_id_mismatch);
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
        .event_capacity = 2,
        .per_session_event_capacity = 2,
        .control_reserved_capacity = 0,
        .per_session_control_reserved_capacity = 0,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);

    const first_run = try submitSession(session, "bind Core session identity");
    try session.waitRun(first_run);
    var first_terminal = takeTestTerminal(session, first_run);
    defer first_terminal.deinit();
    try std.testing.expectEqual(@as(?u32, wire.STATUS_OK), first_terminal.raw_status_code);
    var first_event = runtime.takeEvent().?;
    first_event.deinit();

    const second_run = try submitSession(session, "reject changed Core session identity");
    try session.waitRun(second_run);
    var second_terminal = takeTestTerminal(session, second_run);
    defer second_terminal.deinit();
    try std.testing.expectEqual(
        @as(?u32, wire.STATUS_CALLBACK_FAILED),
        second_terminal.raw_status_code,
    );
    try std.testing.expectEqual(
        @as(?lifecycle.TerminalFailure, .dependency_contract),
        second_terminal.failure,
    );
    try std.testing.expectEqual(lifecycle.SessionState.poisoned, session.snapshot().state);
    try closeSession(session, .session_close);
}

test "valid unknown observations are ignored without consuming pump capacity" {
    fake_core.reset();
    fake_core.setNextPlan(.unknown_event_callback);
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
        .event_capacity = 1,
        .per_session_event_capacity = 1,
        .control_reserved_capacity = 0,
        .per_session_control_reserved_capacity = 0,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);
    const run_id = try submitSession(session, "emit a future observation");
    try session.waitRun(run_id);
    var terminal = takeTestTerminal(session, run_id);
    defer terminal.deinit();
    const snapshot = session.snapshot();
    try std.testing.expectEqual(@as(?u32, wire.STATUS_OK), terminal.raw_status_code);
    try std.testing.expectEqual(@as(?sdk.StopReason, .end_turn), terminal.stop_reason);
    try std.testing.expectEqual(lifecycle.SessionState.idle, snapshot.state);
    try std.testing.expect(runtime.takeEvent() == null);
    try closeSession(session, .session_close);
}

test "typed Core events are deep-copied into a bounded routed sink" {
    fake_core.reset();
    fake_core.setNextPlan(.event_callback);
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
        .event_capacity = 2,
        .per_session_event_capacity = 2,
        .control_reserved_capacity = 0,
        .per_session_control_reserved_capacity = 0,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);
    const first_run = try submitSession(session, "emit typed event");
    try session.waitRun(first_run);
    var first_terminal = takeTestTerminal(session, first_run);
    defer first_terminal.deinit();
    try std.testing.expectEqual(@as(?u32, wire.STATUS_OK), first_terminal.raw_status_code);
    try std.testing.expectEqual(@as(?u32, wire.STOP_END_TURN), first_terminal.raw_stop_reason_code);
    try std.testing.expectEqual(@as(?sdk.StopReason, .end_turn), first_terminal.stop_reason);

    const second_run = try submitSession(session, "preserve FIFO order");
    try session.waitRun(second_run);
    var second_terminal = takeTestTerminal(session, second_run);
    defer second_terminal.deinit();
    try std.testing.expectEqual(@as(?sdk.StopReason, .end_turn), second_terminal.stop_reason);

    var envelope = runtime.takeEvent().?;
    defer envelope.deinit();
    try std.testing.expect(envelope.session_id != 0);
    try std.testing.expectEqual(first_run, envelope.run_id);
    try std.testing.expectEqualStrings("{\"text_chunk\":\"typed event\"}", envelope.json);
    try std.testing.expectEqualStrings("typed event", try textChunk(envelope.event.value));
    var second = runtime.takeEvent().?;
    try std.testing.expectEqual(second_run, second.run_id);
    second.deinit();
    try closeSession(session, .session_close);
}

test "bounded event sink overflow returns callback fatal and preserves the pump failure" {
    fake_core.reset();
    fake_core.setNextPlan(.event_callback);
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
        .event_capacity = 1,
        .per_session_event_capacity = 1,
        .control_reserved_capacity = 0,
        .per_session_control_reserved_capacity = 0,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);
    const first_run = try submitSession(session, "retain first event");
    try session.waitRun(first_run);
    const second_run = try submitSession(session, "overflow sink");
    try session.waitRun(second_run);
    var terminal = takeTestTerminal(session, second_run);
    defer terminal.deinit();
    try std.testing.expectEqual(@as(?u32, wire.STATUS_CALLBACK_FAILED), terminal.raw_status_code);
    try std.testing.expectEqual(
        lifecycle.TerminationSignal{ .event_pump_failure = .capacity },
        terminal.termination_signal.?,
    );
    var retained = runtime.takeEvent().?;
    retained.deinit();
    try closeSession(session, .session_close);
}

test "UI request validates identity and close wakes a suspended callback" {
    fake_core.reset();
    fake_core.setNextPlan(.ui_wait);
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 3 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const answered = try openSession(runtime);
    const run_id = try submitSession(answered, "request UI");
    try answered.waitForState(.waiting_ui);
    const request_id = answered.pendingUiRequest().?;
    var pending = try answered.copyPendingUiRequest(std.testing.allocator);
    defer pending.deinit();
    try std.testing.expectEqual(run_id, pending.run_id);
    try std.testing.expectEqual(request_id, pending.request_id);
    var decoded = try sdk.decodeUiRequest(std.testing.allocator, pending.json);
    defer decoded.deinit();
    try std.testing.expectEqual(std.meta.Tag(sdk.UiRequest).permission, std.meta.activeTag(decoded.value));
    try std.testing.expectError(error.StaleUiResponse, answered.respondPermission(run_id + 1, request_id, .allow_once));
    try std.testing.expectError(error.StaleUiResponse, answered.respondPermission(run_id, request_id + 1, .allow_once));
    try answered.respondPermission(run_id, request_id, .allow_session);
    try std.testing.expectError(error.StaleUiResponse, answered.respondPermission(run_id, request_id, .allow_once));
    fake_core.releaseControlled();
    try answered.waitRun(run_id);
    fake_core.lock();
    const permission_response_valid = fake_core.permission_response_valid;
    fake_core.unlock();
    try std.testing.expect(permission_response_valid);
    try closeSession(answered, .session_close);

    fake_core.setNextPlan(.ui_wait);
    const closing = try openSession(runtime);
    _ = try submitSession(closing, "close while UI waits");
    const closing_run = closing.snapshot().active_run_id;
    try closing.waitForState(.waiting_ui);
    try closeSession(closing, .session_close);
    var closing_terminal = takeTestTerminal(closing, closing_run);
    defer closing_terminal.deinit();
    const snapshot = closing.snapshot();
    try std.testing.expectEqual(lifecycle.SessionState.closed, snapshot.state);
    try std.testing.expectEqual(
        lifecycle.TerminationSignal{ .interrupted = .session_close },
        closing_terminal.termination_signal.?,
    );

    fake_core.setNextPlan(.ui_wait);
    const cancelled = try openSession(runtime);
    const cancelled_run = try submitSession(cancelled, "cancel while UI waits");
    try cancelled.waitForState(.waiting_ui);
    try cancelSession(cancelled, cancelled_run, .user_cancel);
    try cancelled.waitRun(cancelled_run);
    var cancelled_terminal = takeTestTerminal(cancelled, cancelled_run);
    defer cancelled_terminal.deinit();
    try std.testing.expectEqual(
        lifecycle.TerminationSignal{ .interrupted = .user_cancel },
        cancelled_terminal.termination_signal.?,
    );
    try closeSession(cancelled, .session_close);
}

test "MetaWork Agent rejects structured questions before product projection" {
    fake_core.reset();
    fake_core.setNextPlan(.ask_question);
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);
    const run_id = try submitSession(session, "attempt structured question");
    try session.waitRun(run_id);
    var terminal = takeTestTerminal(session, run_id);
    defer terminal.deinit();
    try std.testing.expectEqual(
        lifecycle.TerminationSignal{ .callback_failure = .ui },
        terminal.termination_signal.?,
    );
    try std.testing.expect(session.pendingUiRequest() == null);
    fake_core.lock();
    const fatal_callbacks = fake_core.ui_fatal_callbacks;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), fatal_callbacks);
    try closeSession(session, .session_close);
}

test "Session permission grants are reused only by AgentCore within that Session" {
    fake_core.reset();
    fake_core.setNextPlan(.ui_wait_twice);
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 2, .max_sessions = 3 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }

    const session = try openSession(runtime);
    const first_run = try submitSession(session, "grant session permission");
    try session.waitForState(.waiting_ui);
    const first_request = session.pendingUiRequest().?;
    try session.respondPermission(first_run, first_request, .allow_session);
    fake_core.releaseControlled();
    try session.waitRun(first_run);
    var first_terminal = takeTestTerminal(session, first_run);
    first_terminal.deinit();

    const second_run = try submitSession(session, "reuse session permission");
    try session.waitRun(second_run);
    var second_terminal = takeTestTerminal(session, second_run);
    second_terminal.deinit();
    fake_core.lock();
    const same_session_callbacks = fake_core.permission_callback_count;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), same_session_callbacks);
    try closeSession(session, .session_close);

    fake_core.setNextPlan(.ui_wait_twice);
    const fresh_session = try openSession(runtime);
    const fresh_run = try submitSession(fresh_session, "fresh session permission");
    try fresh_session.waitForState(.waiting_ui);
    const fresh_request = fresh_session.pendingUiRequest().?;
    try fresh_session.respondPermission(fresh_run, fresh_request, .allow_session);
    fake_core.releaseControlled();
    try fresh_session.waitRun(fresh_run);
    var fresh_terminal = takeTestTerminal(fresh_session, fresh_run);
    fresh_terminal.deinit();
    fake_core.lock();
    const cross_session_callbacks = fake_core.permission_callback_count;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 2), cross_session_callbacks);
    try closeSession(fresh_session, .session_close);
}

test "permission callback request identity mismatch fails closed" {
    fake_core.reset();
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 2 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }

    for ([_]Plan{ .wrong_ui_request_run_id, .wrong_ui_request_session_id }) |plan| {
        fake_core.setNextPlan(plan);
        const session = try openSession(runtime);
        const run_id = try submitSession(session, "reject mismatched permission identity");
        try session.waitRun(run_id);
        var terminal = takeTestTerminal(session, run_id);
        defer terminal.deinit();
        try std.testing.expectEqual(@as(?u32, wire.STATUS_CALLBACK_FAILED), terminal.raw_status_code);
        try std.testing.expectEqual(
            @as(?lifecycle.TerminalFailure, .dependency_contract),
            terminal.failure,
        );
        try std.testing.expectEqual(lifecycle.SessionState.poisoned, session.snapshot().state);
        try closeSession(session, .session_close);
    }
}

test "Core identity failure discards an accepted UI permission response" {
    fake_core.reset();
    fake_core.setNextPlan(.ui_wait);
    var notifier = UiAnswerThenIdentityMismatch{};
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
        .event_ready_notifier = .{
            .context = &notifier,
            .notify_fn = UiAnswerThenIdentityMismatch.notify,
        },
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);
    notifier.session = session;

    const run_id = try submitSession(session, "reject permission after identity failure");
    try session.waitRun(run_id);
    var terminal = takeTestTerminal(session, run_id);
    defer terminal.deinit();

    try std.testing.expect(notifier.invoked);
    try std.testing.expect(!notifier.failed);
    try std.testing.expectEqual(@as(?u32, wire.EVENT_FATAL), notifier.mismatch_status);
    try std.testing.expectEqual(@as(?u32, wire.STATUS_CALLBACK_FAILED), terminal.raw_status_code);
    try std.testing.expectEqual(
        @as(?lifecycle.TerminalFailure, .dependency_contract),
        terminal.failure,
    );
    try std.testing.expectEqual(lifecycle.SessionState.poisoned, session.snapshot().state);
    try std.testing.expect(session.pendingUiRequest() == null);

    fake_core.lock();
    const answered_callbacks = fake_core.ui_answered_callbacks;
    const fatal_callbacks = fake_core.ui_fatal_callbacks;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 0), answered_callbacks);
    try std.testing.expectEqual(@as(usize, 1), fatal_callbacks);
    try std.testing.expectError(error.SessionPoisoned, submitSession(session, "must remain poisoned"));
    try closeSession(session, .session_close);
}

test "UI wait has no deadline and malformed UI fails the Run" {
    fake_core.reset();
    fake_core.setNextPlan(.ui_wait);
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 2,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const waiting = try openSession(runtime);
    const wait_run = try submitSession(waiting, "wait for the user");
    try waiting.waitForState(.waiting_ui);
    // No expiry timer exists any more: well past the former test deadline
    // the request must still be pending, and only an answer ends the wait.
    std.Io.Timeout.sleep(.{ .duration = .{
        .raw = std.Io.Duration.fromMilliseconds(120),
        .clock = .awake,
    } }, std.testing.io) catch {};
    const request_id = waiting.pendingUiRequest() orelse
        return error.TestExpectedPendingUi;
    try waiting.respondPermission(wait_run, request_id, .allow_once);
    fake_core.releaseControlled();
    try waiting.waitRun(wait_run);
    var wait_terminal = takeTestTerminal(waiting, wait_run);
    defer wait_terminal.deinit();
    try std.testing.expectEqual(@as(?sdk.StopReason, .end_turn), wait_terminal.stop_reason);
    try closeSession(waiting, .session_close);

    fake_core.setNextPlan(.malformed_ui_callback);
    const malformed = try openSession(runtime);
    const malformed_run = try submitSession(malformed, "malformed UI request");
    try malformed.waitRun(malformed_run);
    var malformed_terminal = takeTestTerminal(malformed, malformed_run);
    defer malformed_terminal.deinit();
    try std.testing.expectEqual(@as(?u32, wire.STATUS_CALLBACK_FAILED), malformed_terminal.raw_status_code);
    try std.testing.expectEqual(
        lifecycle.TerminationSignal{ .callback_failure = .ui },
        malformed_terminal.termination_signal.?,
    );
    try closeSession(malformed, .session_close);
}

test "UI notification failure is a typed fatal terminal signal" {
    fake_core.reset();
    fake_core.setNextPlan(.ui_wait);
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
        .event_ready_notifier = .{
            .context = null,
            .notify_fn = unavailableEventConsumer,
        },
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);
    const run_id = try submitSession(session, "notification cannot reach canonical consumer");
    try session.waitRun(run_id);
    var terminal = takeTestTerminal(session, run_id);
    defer terminal.deinit();
    try std.testing.expectEqual(@as(?u32, wire.STATUS_CALLBACK_FAILED), terminal.raw_status_code);
    try std.testing.expectEqual(
        lifecycle.TerminationSignal{
            .event_consumer_notification_failure = .unavailable,
        },
        terminal.termination_signal.?,
    );
    try closeSession(session, .session_close);
}

test "event notification deadline preserves the pump-owned event" {
    fake_core.reset();
    fake_core.setNextPlan(.event_callback);
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
        .event_ready_notifier = .{
            .context = null,
            .notify_fn = unavailableEventConsumer,
        },
        .event_ready_retry_interval = .fromNanoseconds(1),
        .event_ready_timeout = .fromNanoseconds(2),
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);
    const run_id = try submitSession(session, "notification deadline retains owned event");
    try session.waitRun(run_id);
    var terminal = takeTestTerminal(session, run_id);
    defer terminal.deinit();
    try std.testing.expectEqual(
        lifecycle.TerminationSignal{
            .event_consumer_notification_failure = .unavailable,
        },
        terminal.termination_signal.?,
    );
    var retained = runtime.takeEvent() orelse return error.ExpectedOwnedEvent;
    defer retained.deinit();
    try std.testing.expectEqual(session.id, retained.session_id);
    try std.testing.expectEqual(run_id, retained.run_id);
    try closeSession(session, .session_close);
}

test "UI response encoding is bounded before ownership transfer" {
    fake_core.reset();
    fake_core.setNextPlan(.ui_wait);
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
        .max_ui_response_bytes = 8,
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);
    const run_id = try submitSession(session, "bound response");
    try session.waitForState(.waiting_ui);
    const request_id = session.pendingUiRequest().?;
    try std.testing.expectError(
        error.InvalidUiResponse,
        session.respondPermission(run_id, request_id, .allow_once),
    );
    try std.testing.expectEqual(request_id, session.pendingUiRequest().?);
    try cancelSession(session, run_id, .user_cancel);
    try session.waitRun(run_id);
    var terminal = takeTestTerminal(session, run_id);
    defer terminal.deinit();
    try std.testing.expectEqual(
        lifecycle.TerminationSignal{ .interrupted = .user_cancel },
        terminal.termination_signal.?,
    );
    try closeSession(session, .session_close);
}

test "status is validated before RunResult and invalid results poison the Session" {
    fake_core.reset();
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 16 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }

    const cases = [_]struct {
        plan: Plan,
        expected_status: u32,
        expected_stop: ?u32,
    }{
        .{ .plan = .unknown_stop_result, .expected_status = wire.STATUS_OK, .expected_stop = 42 },
        .{ .plan = .invalid_result_layout, .expected_status = wire.STATUS_OK, .expected_stop = null },
        .{ .plan = .invalid_checkpoint_outcome, .expected_status = wire.STATUS_OK, .expected_stop = null },
        .{ .plan = .invalid_result_flags, .expected_status = wire.STATUS_OK, .expected_stop = null },
        .{ .plan = .mismatched_checkpoint_outcome, .expected_status = wire.STATUS_OK, .expected_stop = wire.STOP_END_TURN },
        .{ .plan = .checkpoint_budget_required_invalid_result, .expected_status = wire.STATUS_CHECKPOINT_BUDGET_REQUIRED, .expected_stop = null },
        .{ .plan = .unknown_status, .expected_status = 42, .expected_stop = null },
        .{ .plan = .stale_compact_status, .expected_status = wire.STATUS_STALE_COMPACT, .expected_stop = null },
    };
    for (cases) |case| {
        fake_core.setNextPlan(case.plan);
        const session = try openSession(runtime);
        const run_id = try submitSession(session, "validate result boundary");
        try session.waitRun(run_id);
        var terminal = takeTestTerminal(session, run_id);
        defer terminal.deinit();
        const snapshot = session.snapshot();
        try std.testing.expectEqual(@as(?u32, case.expected_status), terminal.raw_status_code);
        try std.testing.expectEqual(case.expected_stop, terminal.raw_stop_reason_code);
        try std.testing.expectEqual(
            @as(?lifecycle.TerminalFailure, .dependency_contract),
            terminal.failure,
        );
        if (case.expected_status != wire.STATUS_OK and
            case.expected_status != wire.STATUS_CHECKPOINT_BUDGET_REQUIRED)
            try std.testing.expectEqual(
                @as(?lifecycle.DurableBudgetObservation, null),
                terminal.durable_budget,
            );
        try std.testing.expectEqual(lifecycle.SessionState.poisoned, snapshot.state);
        try std.testing.expectError(error.SessionPoisoned, submitSession(session, "must not continue"));
        try closeSession(session, .session_close);
    }
}

test "checkpoint outcomes are typed and budget admission remains retryable" {
    fake_core.reset();
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 3 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }

    fake_core.setNextPlan(.checkpoint_budget_required);
    const budget_session = try openSession(runtime);
    const budget_run = try submitSession(budget_session, "require checkpoint before admission");
    try budget_session.waitRun(budget_run);
    var budget_terminal = takeTestTerminal(budget_session, budget_run);
    defer budget_terminal.deinit();
    try std.testing.expectEqual(
        @as(?sdk.Status, .checkpoint_budget_required),
        budget_terminal.abi_status,
    );
    try std.testing.expectEqual(
        @as(?lifecycle.TerminalFailure, .abi_status),
        budget_terminal.failure,
    );
    try std.testing.expectEqualDeep(
        @as(?lifecycle.DurableBudgetObservation, .{
            .durable_usage_bytes = 4096,
            .required_checkpoint_bytes = 8192,
        }),
        budget_terminal.durable_budget,
    );
    try std.testing.expectEqual(lifecycle.SessionState.idle, budget_session.snapshot().state);
    fake_core.setSessionPlan(.immediate);
    const retry_run = try submitSession(budget_session, "retry after product checkpoint handling");
    try budget_session.waitRun(retry_run);
    var retry_terminal = takeTestTerminal(budget_session, retry_run);
    defer retry_terminal.deinit();
    try std.testing.expectEqual(@as(?sdk.StopReason, .end_turn), retry_terminal.stop_reason);
    try std.testing.expect(retry_terminal.durable_budget != null);
    try closeSession(budget_session, .session_close);

    const terminal_cases = [_]struct {
        plan: Plan,
        expected: sdk.StopReason,
    }{
        .{ .plan = .checkpoint_budget_exhausted, .expected = .checkpoint_budget_exhausted },
        .{ .plan = .checkpoint_resource_limit, .expected = .checkpoint_resource_limit },
    };
    for (terminal_cases) |case| {
        fake_core.setNextPlan(case.plan);
        const session = try openSession(runtime);
        const run_id = try submitSession(session, "validate checkpoint terminal outcome");
        try session.waitRun(run_id);
        var terminal = takeTestTerminal(session, run_id);
        defer terminal.deinit();
        try std.testing.expectEqual(@as(?sdk.StopReason, case.expected), terminal.stop_reason);
        try std.testing.expectEqual(@as(?lifecycle.TerminalFailure, null), terminal.failure);
        try closeSession(session, .session_close);
    }
}

test "checkpoint export streams bytes and accepts opaque generation zero" {
    fake_core.reset();
    const runtime = try createTestRuntime(.{ .max_sessions = 1 });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    const session = try openSession(runtime);
    defer closeSession(session, .session_close) catch unreachable;
    var collector = CheckpointCollector{};
    var outcome = try session.exportCheckpoint(
        checkpoint_test_limits,
        collector.sink(),
        0,
        0,
        "fixture-model",
    );
    defer outcome.deinit();
    switch (outcome) {
        .success => |success| {
            try std.testing.expectEqual(@as(u64, 0), success.checkpoint.generation);
            try std.testing.expectEqual(@as(u64, collector.len), success.checkpoint.total_bytes);
            try std.testing.expectEqualStrings("fixture-checkpoint", collector.bytes[0..collector.len]);
            try std.testing.expectEqualStrings("fixture-model", success.description.model);
        },
        .failure => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(lifecycle.SessionState.idle, session.snapshot().state);
}

test "checkpoint restore installs one exact logical Session and continues identities" {
    fake_core.reset();
    fake_core.setCheckpointGeneration(3);
    fake_core.setRestoreHistory(7, 2);
    const runtime = try createTestRuntime(.{ .max_sessions = 2 });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    var source = CheckpointRestoreSource{ .bytes = "fixture-checkpoint" };
    const route = try runtime.restoreSessionRoute(restoreOptions(
        source.source(),
        "000000000000000000000001",
        7,
        2,
    ));
    try std.testing.expectEqual(@as(u64, 1), route.id);
    try std.testing.expectEqual(lifecycle.CheckpointRestoreHealth.complete, route.report.health);
    try std.testing.expectEqual(@as(u64, 3), route.report.checkpoint_generation);
    try std.testing.expectEqual(source.bytes.len, source.offset);
    const next_run_id = try route.session.prepareRun(.{ .text = "continue" });
    try std.testing.expectEqual(@as(u64, 8), next_run_id);
    try route.session.cancelPreparedRun(next_run_id);
    try closeSession(route.session, .session_close);
    try runtime.releaseClosedSession(route.session);
}

test "Runtime shutdown waits for restore and rejects its late candidate" {
    const RestoreHarness = struct {
        runtime: *lifecycle.Runtime,
        source: *CheckpointRestoreSource,
        result: std.atomic.Value(enum(u8) { pending, rejected, unexpected }) = .init(.pending),

        fn run(self: *@This()) void {
            _ = self.runtime.restoreSessionRoute(restoreOptions(
                self.source.source(),
                "000000000000000000000001",
                0,
                0,
            )) catch |err| {
                self.result.store(
                    if (err == error.RuntimeShuttingDown) .rejected else .unexpected,
                    .release,
                );
                return;
            };
            self.result.store(.unexpected, .release);
        }
    };
    const ShutdownHarness = struct {
        runtime: *lifecycle.Runtime,
        failed: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            self.runtime.shutdown() catch self.failed.store(true, .release);
        }
    };

    fake_core.reset();
    fake_core.setCheckpointGeneration(3);
    fake_core.setRestoreHistory(0, 0);
    fake_core.armControlledRestore();
    const runtime = try createTestRuntime(.{ .max_sessions = 1 });
    var runtime_live = true;
    defer if (runtime_live) {
        runtime.shutdown() catch {};
        runtime.deinit();
    };
    var source = CheckpointRestoreSource{ .bytes = "fixture-checkpoint" };
    var restore_harness = RestoreHarness{ .runtime = runtime, .source = &source };
    const restore_thread = try std.Thread.spawn(.{}, RestoreHarness.run, .{&restore_harness});
    fake_core.waitUntilRestoreEntered();
    try std.testing.expectError(error.SessionCapacity, openSession(runtime));

    var shutdown_harness = ShutdownHarness{ .runtime = runtime };
    const shutdown_thread = try std.Thread.spawn(.{}, ShutdownHarness.run, .{&shutdown_harness});
    for (0..100) |_| std.Thread.yield() catch {};
    fake_core.lock();
    const destroyed_while_restore_blocked = fake_core.runtime_destroyed;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 0), destroyed_while_restore_blocked);

    fake_core.releaseControlledRestore();
    restore_thread.join();
    shutdown_thread.join();
    try std.testing.expectEqual(.rejected, restore_harness.result.load(.acquire));
    try std.testing.expect(!shutdown_harness.failed.load(.acquire));
    fake_core.lock();
    const restored = fake_core.checkpoint_restores;
    const sessions_destroyed = fake_core.session_destroyed;
    const runtimes_destroyed = fake_core.runtime_destroyed;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), restored);
    try std.testing.expectEqual(@as(usize, 1), sessions_destroyed);
    try std.testing.expectEqual(@as(usize, 1), runtimes_destroyed);
    runtime.deinit();
    runtime_live = false;
}

test "restore cleanup failure remains Runtime-owned until shutdown" {
    fake_core.reset();
    fake_core.setCheckpointGeneration(3);
    fake_core.setRestoreHistory(0, 0);
    fake_core.forceNextSessionDestroyStatus(wire.STATUS_BUSY);
    const runtime = try createTestRuntime(.{ .max_sessions = 1 });
    var runtime_live = true;
    defer if (runtime_live) {
        runtime.shutdown() catch {};
        runtime.deinit();
    };
    var source = CheckpointRestoreSource{ .bytes = "fixture-checkpoint" };
    try std.testing.expectError(
        error.RestoreContractFailed,
        runtime.restoreSessionRoute(restoreOptions(
            source.source(),
            "ffffffffffffffffffffffff",
            0,
            0,
        )),
    );
    fake_core.lock();
    const destroyed_before_shutdown = fake_core.session_destroyed;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 0), destroyed_before_shutdown);
    try runtime.shutdown();
    fake_core.lock();
    const destroyed_after_shutdown = fake_core.session_destroyed;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), destroyed_after_shutdown);
    runtime.deinit();
    runtime_live = false;
}

test "checkpoint description cannot change the bound logical Session identity" {
    fake_core.reset();
    const runtime = try createTestRuntime(.{ .max_sessions = 1 });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    const session = try openSession(runtime);
    defer closeSession(session, .session_close) catch unreachable;
    var collector = CheckpointCollector{};
    var first = try session.exportCheckpoint(
        checkpoint_test_limits,
        collector.sink(),
        0,
        0,
        "fixture-model",
    );
    switch (first) {
        .success => {},
        .failure => return error.TestUnexpectedResult,
    }
    first.deinit();

    fake_core.setCheckpointGeneration(1);
    fake_core.mismatchNextCheckpointDescriptionSessionId();
    collector = .{};
    var second = try session.exportCheckpoint(
        checkpoint_test_limits,
        collector.sink(),
        0,
        0,
        "fixture-model",
    );
    defer second.deinit();
    switch (second) {
        .failure => |failure| try std.testing.expectEqual(
            lifecycle.CheckpointFailureReason.dependency_contract,
            failure.reason,
        ),
        .success => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(lifecycle.SessionState.poisoned, session.snapshot().state);
}

test "checkpoint IO and product limits keep Session reusable" {
    const cases = [_]struct {
        status: ?u32 = null,
        sink_result: lifecycle.CheckpointSinkWriteResult,
        expected: lifecycle.CheckpointFailureReason,
    }{
        .{ .sink_result = .cancelled, .expected = .cancelled },
        .{ .sink_result = .io_failed, .expected = .io_failed },
        .{ .status = wire.STATUS_INVALID_ARGUMENT, .sink_result = .ok, .expected = .invalid_argument },
        .{ .status = wire.STATUS_RESOURCE_LIMIT, .sink_result = .ok, .expected = .resource_limit },
        .{ .status = wire.STATUS_BUSY, .sink_result = .ok, .expected = .busy },
    };
    for (cases) |case| {
        fake_core.reset();
        if (case.status) |status| fake_core.forceNextCheckpointExportStatus(status);
        const runtime = try createTestRuntime(.{ .max_sessions = 1 });
        defer {
            runtime.shutdown() catch unreachable;
            runtime.deinit();
        }
        const session = try openSession(runtime);
        defer closeSession(session, .session_close) catch unreachable;
        var collector = CheckpointCollector{ .result = case.sink_result };
        var outcome = try session.exportCheckpoint(
            checkpoint_test_limits,
            collector.sink(),
            0,
            0,
            "fixture-model",
        );
        defer outcome.deinit();
        switch (outcome) {
            .failure => |failure| {
                try std.testing.expectEqual(case.expected, failure.reason);
                try std.testing.expectEqual(lifecycle.SessionState.idle, session.snapshot().state);
            },
            .success => return error.TestUnexpectedResult,
        }
    }
}

test "checkpoint Core fatal and entry-illegal budget status close Session admission" {
    const statuses = [_]u32{
        wire.STATUS_OUT_OF_MEMORY,
        wire.STATUS_CORE_ERROR,
        wire.STATUS_CHECKPOINT_BUDGET_REQUIRED,
        wire.STATUS_CHECKPOINT_CORRUPT,
        wire.STATUS_CHECKPOINT_UNSUPPORTED,
        wire.STATUS_CHECKPOINT_INCOMPATIBLE,
        wire.STATUS_LOGICAL_SESSION_CONFLICT,
    };
    for (statuses) |status| {
        fake_core.reset();
        fake_core.forceNextCheckpointExportStatus(status);
        const runtime = try createTestRuntime(.{ .max_sessions = 1 });
        defer {
            runtime.shutdown() catch unreachable;
            runtime.deinit();
        }
        const session = try openSession(runtime);
        defer closeSession(session, .session_close) catch unreachable;
        var collector = CheckpointCollector{};
        var outcome = try session.exportCheckpoint(
            checkpoint_test_limits,
            collector.sink(),
            0,
            0,
            "fixture-model",
        );
        defer outcome.deinit();
        switch (outcome) {
            .failure => |failure| {
                if (status == wire.STATUS_CHECKPOINT_BUDGET_REQUIRED or
                    status == wire.STATUS_CHECKPOINT_CORRUPT or
                    status == wire.STATUS_CHECKPOINT_UNSUPPORTED or
                    status == wire.STATUS_CHECKPOINT_INCOMPATIBLE or
                    status == wire.STATUS_LOGICAL_SESSION_CONFLICT)
                    try std.testing.expectEqual(lifecycle.CheckpointFailureReason.dependency_contract, failure.reason)
                else
                    try std.testing.expect(failure.reason == .out_of_memory or failure.reason == .core_error);
                try std.testing.expectEqual(lifecycle.SessionState.poisoned, session.snapshot().state);
            },
            .success => return error.TestUnexpectedResult,
        }
    }
}

test "checkpoint describe has an independent conservative status disposition" {
    const cases = [_]struct {
        status: u32,
        expected: lifecycle.CheckpointFailureReason,
        state: lifecycle.SessionState,
    }{
        .{ .status = wire.STATUS_INVALID_ARGUMENT, .expected = .invalid_argument, .state = .idle },
        .{ .status = wire.STATUS_RESOURCE_LIMIT, .expected = .resource_limit, .state = .idle },
        .{ .status = wire.STATUS_BUSY, .expected = .busy, .state = .idle },
        .{ .status = wire.STATUS_OUT_OF_MEMORY, .expected = .out_of_memory, .state = .poisoned },
        .{ .status = wire.STATUS_CORE_ERROR, .expected = .core_error, .state = .poisoned },
        .{ .status = wire.STATUS_CHECKPOINT_BUDGET_REQUIRED, .expected = .dependency_contract, .state = .poisoned },
    };
    for (cases) |case| {
        fake_core.reset();
        fake_core.forceNextCheckpointDescribeStatus(case.status);
        const runtime = try createTestRuntime(.{ .max_sessions = 1 });
        defer {
            runtime.shutdown() catch unreachable;
            runtime.deinit();
        }
        const session = try openSession(runtime);
        defer closeSession(session, .session_close) catch unreachable;
        var collector = CheckpointCollector{};
        var outcome = try session.exportCheckpoint(
            checkpoint_test_limits,
            collector.sink(),
            0,
            0,
            "fixture-model",
        );
        defer outcome.deinit();
        switch (outcome) {
            .failure => |failure| try std.testing.expectEqual(case.expected, failure.reason),
            .success => return error.TestUnexpectedResult,
        }
        try std.testing.expectEqual(case.state, session.snapshot().state);
    }
}

test "checkpoint malformed results and sink fatal are dependency contract failures" {
    const cases = [_]enum { result, description, sink_fatal, sink_missing }{
        .result,
        .description,
        .sink_fatal,
        .sink_missing,
    };
    for (cases) |case| {
        fake_core.reset();
        switch (case) {
            .result => fake_core.makeNextCheckpointResultMalformed(),
            .description => fake_core.makeNextCheckpointDescriptionMalformed(),
            .sink_fatal => {},
            .sink_missing => fake_core.forceNextCheckpointExportStatus(
                wire.STATUS_CHECKPOINT_IO,
            ),
        }
        const runtime = try createTestRuntime(.{ .max_sessions = 1 });
        defer {
            runtime.shutdown() catch unreachable;
            runtime.deinit();
        }
        const session = try openSession(runtime);
        defer closeSession(session, .session_close) catch unreachable;
        var collector = CheckpointCollector{
            .result = if (case == .sink_fatal) .contract_failed else .ok,
        };
        var outcome = try session.exportCheckpoint(
            checkpoint_test_limits,
            collector.sink(),
            0,
            0,
            "fixture-model",
        );
        defer outcome.deinit();
        switch (outcome) {
            .failure => |failure| try std.testing.expectEqual(
                lifecycle.CheckpointFailureReason.dependency_contract,
                failure.reason,
            ),
            .success => return error.TestUnexpectedResult,
        }
        try std.testing.expectEqual(lifecycle.SessionState.poisoned, session.snapshot().state);
    }
}

test "run epilogue waits for an active Core callback before poisoning" {
    fake_core.reset();
    var signal = CallbackSignal{};
    fake_core.setCallbackSignal(&signal);
    defer fake_core.setCallbackSignal(null);
    fake_core.setNextPlan(.ui_callback_outlives_run);
    const runtime = try createTestComposition(.{
        .worker_count = 1,
        .queue_capacity = 1,
        .max_sessions = 1,
        .event_ready_notifier = .{
            .context = &signal,
            .notify_fn = CallbackSignal.notify,
        },
    });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);
    const run_id = try submitSession(session, "wait for callback quiescence");
    try session.waitRun(run_id);
    signal.waitUntilFinished();
    var terminal = takeTestTerminal(session, run_id);
    defer terminal.deinit();
    try std.testing.expectEqual(@as(?u32, wire.STATUS_OK), terminal.raw_status_code);
    try std.testing.expectEqual(
        @as(?lifecycle.TerminalFailure, .dependency_contract),
        terminal.failure,
    );
    try std.testing.expectEqual(lifecycle.SessionState.poisoned, session.snapshot().state);
    try closeSession(session, .session_close);

    fake_core.lock();
    const destroys = fake_core.session_destroyed;
    const answered_callbacks = fake_core.ui_answered_callbacks;
    const fatal_callbacks = fake_core.ui_fatal_callbacks;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), destroys);
    try std.testing.expectEqual(@as(usize, 0), answered_callbacks);
    try std.testing.expectEqual(@as(usize, 1), fatal_callbacks);
}

test "concurrent close waits for retained Session references and destroys once" {
    fake_core.reset();
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);
    try std.testing.expect(session.retainReference());
    const first = try std.Thread.spawn(.{}, closeOnThread, .{session});
    try session.waitForState(.closing);
    const second = try std.Thread.spawn(.{}, closeOnThread, .{session});

    fake_core.lock();
    const destroys_while_retained = fake_core.session_destroyed;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 0), destroys_while_retained);
    session.releaseReference();
    first.join();
    second.join();
    fake_core.lock();
    const final_destroy_count = fake_core.session_destroyed;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), final_destroy_count);
}

test "Runtime destroy while a Session is live returns busy without consuming ownership" {
    fake_core.reset();
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);
    var diagnostic_buffer = wire.OwnedBytesV1{ .ptr = null, .len = 0 };
    try std.testing.expectEqual(
        wire.STATUS_BUSY,
        runtimeDestroy(runtime.runtime, &diagnostic_buffer),
    );
    bufferRelease(&diagnostic_buffer);
    try closeSession(session, .session_close);
    try shutdownTestComposition(runtime);

    fake_core.lock();
    const busy_attempts = fake_core.runtime_destroy_busy_attempts;
    const runtime_destroyed = fake_core.runtime_destroyed;
    const releases = fake_core.buffer_releases;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), busy_attempts);
    try std.testing.expectEqual(@as(usize, 1), runtime_destroyed);
    try std.testing.expectEqual(@as(usize, 1), releases);
}

test "Session and Runtime destroy failures are explicit and retryable" {
    fake_core.reset();
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 2 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);
    fake_core.failNextSessionDestroy();
    try std.testing.expectError(error.SessionDestroyFailed, closeSession(session, .session_close));
    try std.testing.expectEqual(lifecycle.SessionState.closing, session.snapshot().state);
    try closeSession(session, .session_close);

    const contract_session = try openSession(runtime);
    fake_core.forceNextSessionDestroyStatus(wire.STATUS_STALE_COMPACT);
    try std.testing.expectError(
        error.SessionDestroyFailed,
        closeSession(contract_session, .session_close),
    );
    try std.testing.expectEqual(
        lifecycle.SessionState.closing,
        contract_session.snapshot().state,
    );
    try closeSession(contract_session, .session_close);

    fake_core.failNextRuntimeDestroy();
    try std.testing.expectError(error.RuntimeDestroyFailed, shutdownTestComposition(runtime));
    try shutdownTestComposition(runtime);
    fake_core.lock();
    const releases = fake_core.buffer_releases;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 3), releases);
}

test "Core Session creation failure releases diagnostics and leaves capacity reusable" {
    fake_core.reset();
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    fake_core.failNextSessionCreate();
    try std.testing.expectError(error.CoreCallFailed, openSession(runtime));
    const session = try openSession(runtime);
    try closeSession(session, .session_close);
    fake_core.lock();
    const releases = fake_core.buffer_releases;
    const creates = fake_core.session_created;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 1), creates);
    try std.testing.expectEqual(@as(usize, 1), releases);
}

test "closed Session storage is reused only after explicit Runtime release" {
    fake_core.reset();
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const first = try openSession(runtime);
    try std.testing.expectError(error.SessionNotClosed, runtime.releaseClosedSession(first));
    try closeSession(first, .session_close);
    try std.testing.expectError(error.SessionCapacity, openSession(runtime));
    try runtime.releaseClosedSession(first);

    const second = try openSession(runtime);
    try closeSession(second, .session_close);
}

test "abort stale and too-late statuses remain observable without losing diagnostics" {
    fake_core.reset();
    fake_core.setNextPlan(.controlled);
    const runtime = try createTestComposition(.{ .worker_count = 1, .queue_capacity = 1, .max_sessions = 1 });
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    const session = try openSession(runtime);

    const first = try submitSession(session, "too late");
    fake_core.waitRunEntered();
    try std.testing.expectError(error.NoSuchRun, cancelSession(session, first + 1, .user_cancel));
    fake_core.forceNextAbortStatus(wire.STATUS_TOO_LATE);
    try cancelSession(session, first, .user_cancel);
    try cancelSession(session, first, .user_cancel);
    fake_core.releaseControlled();
    try session.waitRun(first);
    var first_terminal = takeTestTerminal(session, first);
    defer first_terminal.deinit();
    try std.testing.expectEqual(@as(?u32, wire.STATUS_TOO_LATE), first_terminal.raw_abort_status_code);

    fake_core.rearmControlled();
    const second = try submitSession(session, "stale");
    fake_core.waitRunEntered();
    fake_core.forceNextAbortStatus(wire.STATUS_STALE_RUN);
    try cancelSession(session, second, .user_cancel);
    try cancelSession(session, second, .user_cancel);
    fake_core.releaseControlled();
    try session.waitRun(second);
    var second_terminal = takeTestTerminal(session, second);
    defer second_terminal.deinit();
    try std.testing.expectEqual(@as(?u32, wire.STATUS_STALE_RUN), second_terminal.raw_abort_status_code);

    fake_core.rearmControlled();
    const third = try submitSession(session, "timeout");
    fake_core.waitRunEntered();
    try cancelSession(session, third, .timeout);
    try session.waitRun(third);
    var timeout_terminal = takeTestTerminal(session, third);
    defer timeout_terminal.deinit();
    try std.testing.expectEqual(@as(?u32, wire.STATUS_OK), timeout_terminal.raw_abort_status_code);
    try std.testing.expectEqual(
        lifecycle.TerminationSignal{ .interrupted = .timeout },
        timeout_terminal.termination_signal.?,
    );

    fake_core.rearmControlled();
    const fourth = try submitSession(session, "wrong operation status");
    fake_core.waitRunEntered();
    fake_core.forceNextAbortStatus(wire.STATUS_STALE_COMPACT);
    try cancelSession(session, fourth, .user_cancel);
    fake_core.releaseControlled();
    try session.waitRun(fourth);
    var contract_terminal = takeTestTerminal(session, fourth);
    defer contract_terminal.deinit();
    try std.testing.expectEqual(
        @as(?u32, wire.STATUS_STALE_COMPACT),
        contract_terminal.raw_abort_status_code,
    );
    try std.testing.expectEqual(
        @as(?lifecycle.TerminalFailure, .dependency_contract),
        contract_terminal.failure,
    );
    try std.testing.expectEqual(lifecycle.SessionState.poisoned, session.snapshot().state);
    try closeSession(session, .session_close);

    fake_core.lock();
    const releases = fake_core.buffer_releases;
    const abort_calls = fake_core.abort_calls;
    const last_abort_reason = fake_core.last_abort_reason;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 3), releases);
    try std.testing.expectEqual(@as(usize, 4), abort_calls);
    try std.testing.expectEqual(@as(?u32, wire.ABORT_USER_REQUEST), last_abort_reason);
}

test "Agent Runtime initialization OOM fails before acquiring the Runtime" {
    fake_core.reset();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 3 });
    try std.testing.expectError(error.OutOfMemory, lifecycle.Runtime.initWithApi(
        std.testing.io,
        failing.allocator(),
        &fake_api,
        .{ .max_sessions = 1 },
    ));
    try std.testing.expect(failing.has_induced_failure);
    fake_core.lock();
    const runtime_created = fake_core.runtime_created;
    const runtime_destroyed = fake_core.runtime_destroyed;
    fake_core.unlock();
    try std.testing.expectEqual(@as(usize, 0), runtime_created);
    try std.testing.expectEqual(@as(usize, 0), runtime_destroyed);
}

test "Session creation OOM leaves Runtime reusable and credential process-only" {
    fake_core.reset();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const executor = try workbench_executor.Executor.create(
        std.testing.io,
        std.testing.allocator,
        .{ .worker_count = 1, .queue_capacity = 1 },
    );
    var executor_registered = false;
    errdefer if (!executor_registered) executor.deinit();
    const runtime = try lifecycle.Runtime.initWithApi(
        std.testing.io,
        failing.allocator(),
        &fake_api,
        .{ .max_sessions = 1 },
    );
    try registerTestComposition(runtime, executor);
    executor_registered = true;
    defer {
        shutdownTestComposition(runtime) catch unreachable;
        deinitTestComposition(runtime);
    }
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, openSession(runtime));
    try std.testing.expect(failing.has_induced_failure);
    failing.fail_index = std.math.maxInt(usize);
    const session = try openSession(runtime);
    const snapshot = session.snapshot();
    const expected_workspace = if (std.fs.path.sep == '\\') "C:\\tmp\\metawork-gate2" else "/tmp/metawork-gate2";
    try std.testing.expectEqualStrings(expected_workspace, snapshot.workspace_root);
    try std.testing.expect(fake_core.credential_seen);
    try closeSession(session, .session_close);
}
