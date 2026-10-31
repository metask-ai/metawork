pub const std = @import("std");
pub const lifecycle = @import("metawork_agent");
pub const product_control = @import("metawork_product_control");
pub const product_skill = @import("metawork_product_skill");
pub const product_task = @import("metawork_product_task");
pub const product_workspace = @import("metawork_product_workspace");
pub const account_contract = @import("metawork_account_contract");
pub const account = @import("metawork_account");
pub const models_coordinator = @import("models_coordinator");
pub const metask_transport = @import("metask_transport");
pub const models_contract = @import("metawork_product_models_contract");
pub const models_ports = @import("product_models_ports");
pub const event_pump = @import("event_pump");
pub const product_control_executor = @import("product_control_executor");
pub const sdk = @import("metask_agentcore");
pub const wire = sdk.types;

// tasks.run is synchronous: a fresh catalog wait returns no Run identity.
// Only successful direct-admission fixtures wait and retry that public command;
// sendInput tests below exercise one-shot reception and Host-owned preparation.
pub fn runPreparedTask(workbench: *product_control.Runtime, task_id: u64, input: product_control.TaskRunInput) !u64 {
    for (0..5000) |_| {
        return workbench.runTask(task_id, input) catch |err| switch (err) {
            error.CatalogLoading => {
                try workbench.drainAgentEvents();
                try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
                continue;
            },
            else => return err,
        };
    }
    return error.TestUnexpectedResult;
}

/// Framed storage is a test double here; production history uses typed SQLite.
pub const TypedHistory = struct {
    fixture_restore: ?[]const u8 = null,
    file_store: *product_task.history.FileStore,
    pending: ?[]u8 = null,
    token: product_task.history.CommitToken = @splat(0),

    fn restoreFixture(context: ?*anyopaque) anyerror!?product_task.history.RecoveredState {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        const bytes = self.fixture_restore orelse return null;
        return try product_task.history.decodeRecovering(std.testing.allocator, bytes, product_control.persistenceLimits(.{}, 16));
    }

    pub fn capability(self: *@This()) product_task.history.Capability {
        return .{ .context = self, .enabled = true, .restore_fn = restoreFixture, .commit_fn = commit, .confirmed_commit_fn = commit, .resolve_commit_fn = resolve };
    }
    pub fn deinit(self: *@This()) void {
        if (self.pending) |bytes| std.testing.allocator.free(bytes);
    }
    fn commit(context: ?*anyopaque, candidate: *product_task.history.Candidate) product_task.history.Commit {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        if (self.pending != null) return .outcome_unknown;
        std.Io.randomSecure(std.testing.io, &self.token) catch return .failed;
        candidate.token = self.token;
        const bytes = product_task.history.encodeAlloc(std.testing.allocator, candidate.value, candidate.preserved, product_control.persistenceLimits(.{}, 16)) catch return .failed;
        const result = self.file_store.commitConfirmed(std.testing.allocator, bytes);
        if (result == .outcome_unknown) self.pending = bytes else std.testing.allocator.free(bytes);
        return result;
    }
    fn resolve(context: ?*anyopaque, token: product_task.history.CommitToken) product_task.history.Commit {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        if (!std.mem.eql(u8, &token, &self.token)) return .outcome_unknown;
        const bytes = self.pending orelse return .outcome_unknown;
        const result = self.file_store.resolveCommit(std.testing.allocator, bytes);
        if (result != .outcome_unknown) {
            std.testing.allocator.free(bytes);
            self.pending = null;
        }
        return result;
    }
};

pub fn credentialDigest(bytes: []const u8) [32]u8 {
    var result: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}

pub fn pumpEnvelope(session_id: u64, run_id: u64, json: []const u8) !event_pump.OwnedCoreEvent {
    const owned_json = try std.testing.allocator.dupe(u8, json);
    errdefer std.testing.allocator.free(owned_json);
    return .{
        .session_id = session_id,
        .run_id = run_id,
        .encoded_bytes = json.len,
        .json = owned_json,
        .event = try sdk.decodeCoreEvent(std.testing.allocator, json),
        .allocator = std.testing.allocator,
    };
}

pub fn textChunk(event: sdk.DecodedCoreEvent) ![]const u8 {
    return switch (event) {
        .known => |known| switch (known) {
            .text_chunk => |text| text,
            else => error.UnexpectedEvent,
        },
        .unknown => error.UnexpectedEvent,
    };
}

pub const PumpEnqueueContext = struct {
    pump: *event_pump.EventPump,
    envelope: event_pump.OwnedCoreEvent,
    timeout: std.Io.Duration,
    succeeded: bool = false,
    failure: ?event_pump.Error = null,
};

pub fn enqueuePumpOnThread(context: *PumpEnqueueContext) void {
    context.pump.enqueueWithDeadline(context.envelope, context.timeout) catch |err| {
        context.failure = err;
        return;
    };
    context.succeeded = true;
}

pub const Plan = enum {
    immediate,
    controlled,
    ui_wait,
    ui_wait_twice,
    ui_wait_repeated,
    ask_question,
    callback_failed,
    controlled_callback_failed,
    event_callback,
    file_changes_callback,
    unknown_event_callback,
    malformed_event_callback,
    invalid_utf8_event_callback,
    wrong_event_session_handle,
    wrong_event_run_id,
    same_run_session_id_mismatch,
    concurrent_session_id_mismatch,
    cross_run_session_id_mismatch,
    ui_callback_outlives_run,
    malformed_ui_callback,
    wrong_ui_request_run_id,
    wrong_ui_request_session_id,
    resource_limit,
    max_turns,
    tool_loop,
    checkpoint_budget_required,
    checkpoint_budget_required_invalid_result,
    checkpoint_budget_exhausted,
    checkpoint_resource_limit,
    stale_catalog,
    skill_not_found,
    invalid_skill_arguments,
    skill_policy_violation,
    skill_unavailable,
    unknown_stop_result,
    invalid_result_layout,
    invalid_checkpoint_outcome,
    invalid_result_flags,
    mismatched_checkpoint_outcome,
    unknown_status,
    stale_compact_status,
    image_input_unsupported_status,
    image_input_capability_unknown_status,
    unexpected_input_receipt,
    unexpected_input_receipt_failure,
    model_error,
    model_error_missing,
    model_error_duplicate,
    model_error_wrong_id,
    model_error_after_terminal,
    model_error_wrong_stop,
    model_error_oversized,
    model_error_callback_failed,
    model_error_core_error,
    model_error_identity_failed,
    model_error_counts_failed,
    model_error_callback_outlives_run,
    model_error_controlled,
};

pub const FakeRuntime = struct {};

pub const FakeCatalog = struct {
    in_use: bool = false,
    released: bool = false,
};

pub const CatalogPlan = enum {
    healthy,
    degraded,
    controlled,
    duplicate_skill_id,
    malformed,
    query_incomplete,
    query_failure,
};

pub const CallbackSignal = struct {
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    armed: bool = false,
    entered: bool = false,
    finished: bool = false,

    pub fn notify(context: ?*anyopaque) lifecycle.EventReadyNotification {
        const self: *CallbackSignal = @ptrCast(@alignCast(context orelse
            return .unavailable));
        self.mutex.lockUncancelable(std.testing.io);
        if (!self.armed) {
            self.mutex.unlock(std.testing.io);
            return .already_pending;
        }
        self.entered = true;
        self.condition.broadcast(std.testing.io);
        self.mutex.unlock(std.testing.io);
        return .scheduled;
    }

    pub fn arm(self: *CallbackSignal) void {
        self.mutex.lockUncancelable(std.testing.io);
        self.armed = true;
        self.entered = false;
        self.finished = false;
        self.mutex.unlock(std.testing.io);
    }

    pub fn waitUntilEntered(self: *CallbackSignal) void {
        self.mutex.lockUncancelable(std.testing.io);
        defer self.mutex.unlock(std.testing.io);
        while (!self.entered)
            self.condition.waitUncancelable(std.testing.io, &self.mutex);
    }

    pub fn markFinished(self: *CallbackSignal) void {
        self.mutex.lockUncancelable(std.testing.io);
        self.finished = true;
        self.condition.broadcast(std.testing.io);
        self.mutex.unlock(std.testing.io);
    }

    pub fn waitUntilFinished(self: *CallbackSignal) void {
        self.mutex.lockUncancelable(std.testing.io);
        defer self.mutex.unlock(std.testing.io);
        while (!self.finished)
            self.condition.waitUncancelable(std.testing.io, &self.mutex);
    }
};

// Bounded owned snapshots of actual Host ABI input; tests inspect what was sent.
pub const FakePromptProfile = struct {
    count: usize = 0,
    ids: [4][64]u8 = @splat(@splat(0)),
    id_lens: [4]usize = @splat(0),
    texts: [4][2048]u8 = @splat(@splat(0)),
    text_lens: [4]usize = @splat(0),

    fn copy(input: ?*const wire.PromptProfileV1) ?FakePromptProfile {
        var result = FakePromptProfile{};
        const profile = input orelse return result;
        if (profile.struct_size != @sizeOf(wire.PromptProfileV1) or
            profile.reserved0 != 0 or !std.mem.allEqual(u64, &profile.reserved, 0) or
            profile.section_count > result.ids.len) return null;
        if (profile.section_count == 0) return result;
        const sections = profile.sections orelse return null;
        result.count = @intCast(profile.section_count);
        for (sections[0..result.count], 0..) |section, i| {
            if (section.struct_size != @sizeOf(wire.PromptSectionV1) or
                section.op_code != wire.PROMPT_OP_REPLACE or section.order != 0 or
                section.interpolate != 0 or section.reserved0 != 0 or
                !std.mem.allEqual(u64, &section.reserved, 0)) return null;
            const id = sdk.borrowedBytes(section.id) catch return null;
            const text = sdk.borrowedBytes(section.text) catch return null;
            if (id.len > result.ids[i].len or text.len > result.texts[i].len) return null;
            @memcpy(result.ids[i][0..id.len], id);
            @memcpy(result.texts[i][0..text.len], text);
            result.id_lens[i] = id.len;
            result.text_lens[i] = text.len;
        }
        return result;
    }
};

pub const FakeSession = struct {
    input_accepted: u32 = 0,
    input_adopted: u32 = 0,
    prompt_profile: FakePromptProfile = .{},
    in_use: bool = false,
    running: bool = false,
    destroyed: bool = false,
    restored: bool = false,
    restore_degraded: bool = false,
    plan: Plan = .immediate,
    callbacks: wire.SessionCallbacksV1 = std.mem.zeroes(wire.SessionCallbacksV1),
    session_id: [wire.MAX_SESSION_ID_BYTES_V1]u8 = [_]u8{0} ** wire.MAX_SESSION_ID_BYTES_V1,
    session_id_len: usize = 0,
    run_id: u64 = 0,
    compact_id: u64 = 0,
    compacting: bool = false,
    compact_abort_requested: bool = false,
    catalog: ?*FakeCatalog = null,
    abort_requested: bool = false,
    allow_finish: bool = false,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    description_buffer: [8192]u8 = [_]u8{0} ** 8192,
    permission_session_granted: bool = false,
    permission_mode_code: u32 = wire.PERMISSION_DEFAULT,
    policy_generation: u64 = 1,
    forced_permission_mode_status: ?u32 = null,
    model: [256]u8 = [_]u8{0} ** 256,
    model_len: usize = 0,
    /// Observe the immutable credential supplied at the ABI boundary without
    /// retaining its bytes. Only synthetic test credentials are used here.
    credential_digest: [32]u8 = @splat(0),

    pub fn lock(self: *FakeSession) void {
        self.mutex.lockUncancelable(std.testing.io);
    }

    pub fn unlock(self: *FakeSession) void {
        self.mutex.unlock(std.testing.io);
    }

    pub fn wait(self: *FakeSession) void {
        self.condition.waitUncancelable(std.testing.io, &self.mutex);
    }

    pub fn broadcast(self: *FakeSession) void {
        self.condition.broadcast(std.testing.io);
    }
};

pub const CatalogSourceObservation = struct {
    scope: u32 = 0,
    priority: i32 = 0,
    root_hash: [32]u8 = @splat(0),
    id: [128]u8 = @splat(0),
    id_len: usize = 0,
};

pub const FakeCore = struct {
    input_enabled: bool = false,
    adopt_input_before_receipt: bool = false,
    omit_input_adopted_event: bool = false,
    forced_input_status: ?u32 = null,
    forced_update_credential_status: ?u32 = null,
    credential_updates: usize = 0,
    hold_credential_update: bool = false,
    credential_update_entered: bool = false,
    allow_credential_update: bool = false,
    credential_update_condition: std.Io.Condition = .init,
    forced_input_run_status: ?u32 = null,
    expected_run_text: ?[]const u8 = null,
    run_text_matches: bool = false,
    input_signal: ?*CallbackSignal = null,
    mutex: std.Io.Mutex = .init,
    catalog_condition: std.Io.Condition = .init,
    checkpoint_condition: std.Io.Condition = .init,
    completion_condition: std.Io.Condition = .init,
    runtime: FakeRuntime = .{},
    catalogs: [16]FakeCatalog = [_]FakeCatalog{.{}} ** 16,
    // Retired handles remain address-stable for stale-handle assertions.
    sessions: [128]FakeSession = [_]FakeSession{.{}} ** 128,
    next_plan: Plan = .immediate,
    runtime_created: usize = 0,
    runtime_destroyed: usize = 0,
    runtime_destroy_busy_attempts: usize = 0,
    catalog_queries: usize = 0,
    catalog_source_count: usize = 0,
    catalog_default_user_priority: i32 = 0,
    catalog_default_workspace_priority: i32 = 0,
    catalog_sources: [wire.MAX_SKILL_SOURCES_V1]CatalogSourceObservation = @splat(.{}),
    catalog_releases: usize = 0,
    catalog_release_failures: usize = 0,
    catalog_refreshes: usize = 0,
    mcp_refreshes: usize = 0,
    mcp_descriptions: usize = 0,
    mcp_updates: usize = 0,
    mcp_configuration_applies: usize = 0,
    last_mcp_apply_server_count: usize = 0,
    mcp_server_count: usize = 0,
    mcp_descriptor_valid: bool = false,
    last_mcp_update_selector_count: ?u64 = null,
    catalog_plan: CatalogPlan = .healthy,
    catalog_query_entered: bool = false,
    allow_catalog_query: bool = false,
    session_created: usize = 0,
    session_destroyed: usize = 0,
    run_calls: usize = 0,
    abort_calls: usize = 0,
    compact_calls: usize = 0,
    compact_abort_calls: usize = 0,
    last_abort_reason: ?u32 = null,
    buffer_releases: usize = 0,
    credential_seen: bool = false,
    /// Models a provider rejecting one expired synthetic credential. This is
    /// an injected Core outcome, not evidence of an actual HTTP status.
    rejected_credential_digest: ?[32]u8 = null,
    image_tool_seen: bool = false,
    image_tool: ?wire.HostToolV1 = null,
    delivery_tool: ?wire.HostToolV1 = null,
    product_allowlist_seen: bool = false,
    last_allowed_tool_count: usize = 0,
    last_allowed_tool_names: [16][32]u8 = [_][32]u8{.{0} ** 32} ** 16,
    last_restored_allowed_tool_count: usize = 0,
    last_restored_allowed_tool_names: [16][32]u8 = [_][32]u8{.{0} ** 32} ** 16,
    workspace_home_seen: bool = false,
    workspace_epoch_seen: bool = false,
    skill_session_bound: bool = false,
    skill_policy_seen: bool = false,
    permission_rules_absent: bool = false,
    last_permission_mode_code: ?u32 = null,
    last_shell_policy_code: ?u32 = null,
    last_created_provider_kind_code: ?u32 = null,
    last_created_protocol_kind_code: ?u32 = null,
    last_restored_provider_kind_code: ?u32 = null,
    last_restored_protocol_kind_code: ?u32 = null,
    skill_run_seen: bool = false,
    skill_input_matches: bool = false,
    expected_multimodal_parts: ?[]const wire.RunInputPartV1 = null,
    multimodal_input_matches: bool = false,
    multimodal_part_count: usize = 0,
    multimodal_prompt_bytes: usize = 0,
    multimodal_reference_count: usize = 0,
    expected_multimodal_text: ?[]const u8 = null,
    multimodal_text_matches: bool = false,
    session_destroy_probe: ?struct { context: *anyopaque, observe_fn: *const fn (*anyopaque) void } = null,
    session_destroy_failures: usize = 0,
    permission_mode_updates: usize = 0,
    runtime_destroy_failures: usize = 0,
    session_create_failures: usize = 0,
    forced_session_create_status: ?u32 = null,
    malformed_session_create_handle: bool = false,
    forced_skill_update_status: ?u32 = null,
    forced_set_model_status: ?u32 = null,
    forced_mcp_update_status: ?u32 = null,
    forced_mcp_refresh_status: ?u32 = null,
    forced_mcp_apply_status: ?u32 = null,
    forced_mcp_apply_disposition: ?u32 = null,
    forced_abort_status: ?u32 = null,
    forced_compact_status: ?u32 = null,
    forced_compact_abort_status: ?u32 = null,
    forced_compact_outcome: ?u32 = null,
    malformed_compact_result: bool = false,
    forced_session_destroy_status: ?u32 = null,
    forced_checkpoint_export_status: ?u32 = null,
    forced_checkpoint_describe_status: ?u32 = null,
    forced_checkpoint_restore_status: ?u32 = null,
    forced_prompt_status: ?u32 = null,
    malformed_prompt_diagnostic: bool = false,
    prompt_updates: usize = 0,
    prompt_changes: usize = 0,
    restored_prompt_profile: FakePromptProfile = .{},
    prompt_controlled: bool = false,
    prompt_entered: bool = false,
    allow_prompt: bool = false,
    forced_checkpoint_restore_degraded: bool = false,
    checkpoint_generation: u64 = 0,
    checkpoint_payload: []const u8 = "fixture-checkpoint",
    malformed_checkpoint_result: bool = false,
    malformed_checkpoint_description: bool = false,
    checkpoint_description_session_id_mismatch: bool = false,
    checkpoint_exports: usize = 0,
    checkpoint_descriptions: usize = 0,
    checkpoint_restores: usize = 0,
    restore_last_run_id: u64 = 0,
    restore_last_compact_id: u64 = 0,
    restore_session_id: [wire.MAX_SESSION_ID_BYTES_V1]u8 = @splat(0),
    restore_session_id_len: usize = 0,
    restore_model: [256]u8 = @splat(0),
    restore_model_len: usize = 0,
    restore_controlled: bool = false,
    restore_after_create: bool = false,
    restore_entered: bool = false,
    allow_restore: bool = false,
    checkpoint_export_controlled: bool = false,
    checkpoint_export_entered: bool = false,
    allow_checkpoint_export: bool = false,
    ui_answered_callbacks: usize = 0,
    permission_callback_count: usize = 0,
    permission_arguments_json: []const u8 = "{}",
    permission_tool_namespace: []const u8 = "builtin",
    permission_tool_name: []const u8 = "Bash",
    permission_session_choices: bool = true,
    ui_unavailable_callbacks: usize = 0,
    ui_fatal_callbacks: usize = 0,
    permission_response_valid: bool = false,
    callback_signal: ?*CallbackSignal = null,
    completion_enabled: bool = false,
    completion_title: [512]u8 = [_]u8{0} ** 512,
    completion_title_len: usize = 0,
    completion_response: [4096]u8 = [_]u8{0} ** 4096,
    completion_response_len: usize = 0,
    completion_requests: usize = 0,
    completion_controlled: bool = false,
    completion_entered: bool = false,
    allow_completion: bool = false,

    pub fn lock(self: *FakeCore) void {
        self.mutex.lockUncancelable(std.testing.io);
    }

    pub fn unlock(self: *FakeCore) void {
        self.mutex.unlock(std.testing.io);
    }

    pub fn reset(self: *FakeCore) void {
        self.* = .{};
    }

    pub fn setNextPlan(self: *FakeCore, plan: Plan) void {
        self.lock();
        self.next_plan = plan;
        self.unlock();
    }

    pub fn setCompletionTitle(self: *FakeCore, title: []const u8) void {
        std.debug.assert(title.len != 0 and title.len <= self.completion_title.len);
        std.debug.assert(std.mem.indexOfAny(u8, title, "\\\"\r\n") == null);
        self.lock();
        @memset(&self.completion_title, 0);
        @memcpy(self.completion_title[0..title.len], title);
        self.completion_title_len = title.len;
        const prefix =
            "{\"type\":\"message\",\"content\":[{\"type\":\"text\",\"text\":\"";
        const suffix =
            "\"}],\"stop_reason\":\"end_turn\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}";
        std.debug.assert(prefix.len + title.len + suffix.len <= self.completion_response.len);
        @memcpy(self.completion_response[0..prefix.len], prefix);
        @memcpy(self.completion_response[prefix.len..][0..title.len], title);
        @memcpy(self.completion_response[prefix.len + title.len ..][0..suffix.len], suffix);
        self.completion_response_len = prefix.len + title.len + suffix.len;
        self.completion_enabled = true;
        self.unlock();
    }

    pub fn controlNextCompletion(self: *FakeCore) void {
        self.lock();
        self.completion_controlled = true;
        self.completion_entered = false;
        self.allow_completion = false;
        self.unlock();
    }

    pub fn waitCompletionEntered(self: *FakeCore) void {
        self.lock();
        defer self.unlock();
        while (!self.completion_entered)
            self.completion_condition.waitUncancelable(
                std.testing.io,
                &self.mutex,
            );
    }

    pub fn releaseCompletion(self: *FakeCore) void {
        self.lock();
        self.allow_completion = true;
        self.completion_condition.broadcast(std.testing.io);
        self.unlock();
    }

    pub fn setSessionPlan(self: *FakeCore, plan: Plan) void {
        for (&self.sessions) |*session| {
            session.lock();
            if (session.in_use and !session.destroyed) session.plan = plan;
            session.unlock();
        }
    }

    pub fn setCatalogPlan(self: *FakeCore, plan: CatalogPlan) void {
        self.lock();
        self.catalog_plan = plan;
        self.unlock();
    }

    pub fn waitCatalogQueryEntered(self: *FakeCore) void {
        self.lock();
        defer self.unlock();
        while (!self.catalog_query_entered)
            self.catalog_condition.waitUncancelable(
                std.testing.io,
                &self.mutex,
            );
    }

    pub fn releaseCatalogQuery(self: *FakeCore) void {
        self.lock();
        self.allow_catalog_query = true;
        self.catalog_condition.broadcast(std.testing.io);
        self.unlock();
    }

    pub fn releaseControlled(self: *FakeCore) void {
        for (&self.sessions) |*session| {
            session.lock();
            session.allow_finish = true;
            session.broadcast();
            session.unlock();
        }
    }

    pub fn rearmControlled(self: *FakeCore) void {
        for (&self.sessions) |*session| {
            session.lock();
            session.allow_finish = false;
            session.abort_requested = false;
            session.compact_abort_requested = false;
            session.unlock();
        }
    }

    pub fn waitRunEntered(self: *FakeCore) void {
        for (&self.sessions) |*session| {
            session.lock();
            if (!session.in_use or session.destroyed) {
                session.unlock();
                continue;
            }
            while (!session.running and !session.destroyed) session.wait();
            const entered = session.running;
            session.unlock();
            if (entered) return;
        }
        unreachable;
    }

    pub fn failNextSessionDestroy(self: *FakeCore) void {
        self.lock();
        self.session_destroy_failures += 1;
        self.unlock();
    }

    pub fn failNextRuntimeDestroy(self: *FakeCore) void {
        self.lock();
        self.runtime_destroy_failures += 1;
        self.unlock();
    }

    pub fn failNextSessionCreate(self: *FakeCore) void {
        self.lock();
        self.session_create_failures += 1;
        self.unlock();
    }

    pub fn setRestoredLogicalId(self: *FakeCore, id: []const u8) void {
        std.debug.assert(id.len != 0 and id.len <= self.restore_session_id.len);
        self.lock();
        defer self.unlock();
        @memcpy(self.restore_session_id[0..id.len], id);
        self.restore_session_id_len = id.len;
    }

    pub fn setRestoredModel(self: *FakeCore, model: []const u8) void {
        std.debug.assert(model.len != 0 and model.len <= self.restore_model.len);
        self.lock();
        defer self.unlock();
        @memcpy(self.restore_model[0..model.len], model);
        self.restore_model_len = model.len;
    }

    pub fn forceNextMcpRefreshStatus(self: *FakeCore, status: u32) void {
        self.lock();
        self.forced_mcp_refresh_status = status;
        self.unlock();
    }

    pub fn forceNextMcpApplyStatus(self: *FakeCore, status: u32) void {
        self.lock();
        self.forced_mcp_apply_status = status;
        self.unlock();
    }

    pub fn forceNextMcpApplyDisposition(self: *FakeCore, disposition: u32) void {
        self.lock();
        self.forced_mcp_apply_disposition = disposition;
        self.unlock();
    }

    pub fn forceNextAbortStatus(self: *FakeCore, status: u32) void {
        self.lock();
        self.forced_abort_status = status;
        self.unlock();
    }

    pub fn forceNextCompactStatus(self: *FakeCore, status: u32) void {
        self.lock();
        self.forced_compact_status = status;
        self.unlock();
    }

    pub fn forceNextCompactAbortStatus(self: *FakeCore, status: u32) void {
        self.lock();
        self.forced_compact_abort_status = status;
        self.unlock();
    }

    pub fn forceNextCompactOutcome(self: *FakeCore, outcome: u32) void {
        self.lock();
        self.forced_compact_outcome = outcome;
        self.unlock();
    }

    pub fn makeNextCompactResultMalformed(self: *FakeCore) void {
        self.lock();
        self.malformed_compact_result = true;
        self.unlock();
    }

    pub fn forceNextSkillUpdateStatus(self: *FakeCore, status: u32) void {
        self.lock();
        self.forced_skill_update_status = status;
        self.unlock();
    }

    pub fn forceNextMcpUpdateStatus(self: *FakeCore, status: u32) void {
        self.lock();
        self.forced_mcp_update_status = status;
        self.unlock();
    }

    pub fn forceNextSessionDestroyStatus(self: *FakeCore, status: u32) void {
        self.lock();
        self.forced_session_destroy_status = status;
        self.unlock();
    }

    pub fn forceNextCheckpointExportStatus(self: *FakeCore, status: u32) void {
        self.lock();
        self.forced_checkpoint_export_status = status;
        self.unlock();
    }

    pub fn forceNextCheckpointDescribeStatus(self: *FakeCore, status: u32) void {
        self.lock();
        self.forced_checkpoint_describe_status = status;
        self.unlock();
    }

    pub fn makeNextCheckpointResultMalformed(self: *FakeCore) void {
        self.lock();
        self.malformed_checkpoint_result = true;
        self.unlock();
    }

    pub fn makeNextCheckpointDescriptionMalformed(self: *FakeCore) void {
        self.lock();
        self.malformed_checkpoint_description = true;
        self.unlock();
    }

    pub fn mismatchNextCheckpointDescriptionSessionId(self: *FakeCore) void {
        self.lock();
        self.checkpoint_description_session_id_mismatch = true;
        self.unlock();
    }

    pub fn setCheckpointGeneration(self: *FakeCore, generation: u64) void {
        self.lock();
        self.checkpoint_generation = generation;
        self.unlock();
    }

    pub fn setRestoreHistory(self: *FakeCore, last_run_id: u64, last_compact_id: u64) void {
        self.lock();
        defer self.unlock();
        self.restore_last_run_id = last_run_id;
        self.restore_last_compact_id = last_compact_id;
    }

    pub fn forceNextCheckpointRestoreStatus(self: *FakeCore, status: u32) void {
        self.lock();
        defer self.unlock();
        self.forced_checkpoint_restore_status = status;
    }

    pub fn forceNextCheckpointRestoreDegraded(self: *FakeCore) void {
        self.lock();
        defer self.unlock();
        self.forced_checkpoint_restore_degraded = true;
    }

    pub fn armControlledPrompt(self: *FakeCore) void {
        self.lock();
        defer self.unlock();
        self.prompt_controlled = true;
        self.prompt_entered = false;
        self.allow_prompt = false;
    }

    pub fn waitUntilPromptEntered(self: *FakeCore) void {
        self.lock();
        defer self.unlock();
        while (!self.prompt_entered)
            self.checkpoint_condition.waitUncancelable(std.testing.io, &self.mutex);
    }

    pub fn releaseControlledPrompt(self: *FakeCore) void {
        self.lock();
        defer self.unlock();
        self.allow_prompt = true;
        self.checkpoint_condition.broadcast(std.testing.io);
    }

    pub fn armControlledRestore(self: *FakeCore) void {
        self.lock();
        defer self.unlock();
        self.restore_controlled = true;
        self.restore_after_create = false;
        self.restore_entered = false;
        self.allow_restore = false;
    }

    pub fn armControlledRestoreAfterCreate(self: *FakeCore) void {
        self.lock();
        defer self.unlock();
        self.restore_controlled = true;
        self.restore_after_create = true;
        self.restore_entered = false;
        self.allow_restore = false;
    }

    pub fn waitUntilRestoreEntered(self: *FakeCore) void {
        self.lock();
        defer self.unlock();
        while (!self.restore_entered)
            self.checkpoint_condition.waitUncancelable(std.testing.io, &self.mutex);
    }

    pub fn releaseControlledRestore(self: *FakeCore) void {
        self.lock();
        defer self.unlock();
        self.allow_restore = true;
        self.checkpoint_condition.broadcast(std.testing.io);
    }

    pub fn controlNextCheckpointExport(self: *FakeCore) void {
        self.lock();
        self.checkpoint_export_controlled = true;
        self.checkpoint_export_entered = false;
        self.allow_checkpoint_export = false;
        self.unlock();
    }

    pub fn waitCheckpointExportEntered(self: *FakeCore) void {
        self.lock();
        defer self.unlock();
        while (!self.checkpoint_export_entered)
            self.checkpoint_condition.waitUncancelable(std.testing.io, &self.mutex);
    }

    pub fn releaseCheckpointExport(self: *FakeCore) void {
        self.lock();
        self.allow_checkpoint_export = true;
        self.checkpoint_condition.broadcast(std.testing.io);
        self.unlock();
    }

    pub fn setCallbackSignal(self: *FakeCore, signal: ?*CallbackSignal) void {
        self.lock();
        self.callback_signal = signal;
        self.unlock();
    }

    pub fn invokeRunningIdentityMismatch(self: *FakeCore) ?u32 {
        for (&self.sessions) |*session| {
            session.lock();
            if (!session.in_use or !session.running) {
                session.unlock();
                continue;
            }
            const callback = session.callbacks.on_event orelse {
                session.unlock();
                return null;
            };
            const callback_context = session.callbacks.ctx;
            const run_id = session.run_id;
            session.unlock();

            var run = std.mem.zeroes(wire.RunContextV1);
            run.struct_size = @sizeOf(wire.RunContextV1);
            run.session = @ptrCast(session);
            run.run_id = run_id;
            run.session_id = sdk.bytesView("mismatched-ui-session");
            return callback(
                callback_context,
                &run,
                sdk.bytesView("{\"text_chunk\":\"must fail\"}"),
            );
        }
        return null;
    }
};

pub var fake_core = FakeCore{};
pub var diagnostic_byte: u8 = 0xA5;

pub const fixture_catalog_revision = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
pub const fixture_skill_id = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
const fixture_catalog_scope = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const healthy_catalog_json =
    "{\"schema\":\"metask.skill-catalog/v1\",\"catalog_scope_id\":\"" ++
    fixture_catalog_scope ++
    "\",\"catalog_revision\":\"" ++
    fixture_catalog_revision ++
    "\",\"health\":\"healthy\",\"skills\":[{\"skill_id\":\"" ++
    fixture_skill_id ++
    "\",\"skill_policy_key\":\"review\",\"invocation_name\":\"review\",\"source\":{\"provider_id\":\"agents.directory\",\"source_scope\":\"workspace\",\"source_instance_id\":\"agents.workspace.default\",\"contribution_id\":\"" ++
    fixture_catalog_scope ++
    "\"},\"content_revision\":\"" ++
    fixture_catalog_revision ++
    "\",\"display_name\":\"Review\",\"description\":\"Review one target\",\"argument_schema\":{\"schema\":\"metask.skill-arguments/v1\",\"max_values\":64,\"names\":[\"target\",\"focus\"]}}],\"issues\":[]}";
const degraded_catalog_json =
    "{\"schema\":\"metask.skill-catalog/v1\",\"catalog_scope_id\":\"" ++
    fixture_catalog_scope ++
    "\",\"catalog_revision\":\"" ++
    fixture_catalog_revision ++
    "\",\"health\":\"degraded\",\"skills\":[{\"skill_id\":\"" ++
    fixture_skill_id ++
    "\",\"skill_policy_key\":\"review\",\"invocation_name\":\"review\",\"source\":{\"provider_id\":\"agents.directory\",\"source_scope\":\"workspace\",\"source_instance_id\":\"agents.workspace.default\",\"contribution_id\":\"" ++
    fixture_catalog_scope ++
    "\"},\"content_revision\":\"" ++
    fixture_catalog_revision ++
    "\",\"display_name\":\"Review\",\"description\":\"Review one target\",\"argument_schema\":{\"schema\":\"metask.skill-arguments/v1\",\"max_values\":64,\"names\":[\"target\",\"focus\"]}}],\"issues\":[{\"kind\":\"invalid\",\"code\":\"invalid_definition\",\"reason\":null,\"skill_policy_key\":\"broken\",\"provider_id\":\"agents.directory\",\"source_scope\":\"workspace\",\"source_instance_id\":\"agents.workspace.default\"}]}";
const duplicate_catalog_json =
    "{\"schema\":\"metask.skill-catalog/v1\",\"catalog_scope_id\":\"" ++
    fixture_catalog_scope ++
    "\",\"catalog_revision\":\"" ++
    fixture_catalog_revision ++
    "\",\"health\":\"healthy\",\"skills\":[{\"skill_id\":\"" ++
    fixture_skill_id ++
    "\",\"skill_policy_key\":\"review\",\"invocation_name\":\"review\",\"source\":{\"provider_id\":\"agents.directory\",\"source_scope\":\"workspace\",\"source_instance_id\":\"agents.workspace.default\",\"contribution_id\":\"" ++
    fixture_catalog_scope ++
    "\"},\"content_revision\":\"" ++
    fixture_catalog_revision ++
    "\",\"display_name\":\"Review\",\"description\":\"First\",\"argument_schema\":{\"schema\":\"metask.skill-arguments/v1\",\"max_values\":64,\"names\":[]}},{\"skill_id\":\"" ++
    fixture_skill_id ++
    "\",\"skill_policy_key\":\"audit\",\"invocation_name\":\"audit\",\"source\":{\"provider_id\":\"agents.directory\",\"source_scope\":\"workspace\",\"source_instance_id\":\"agents.workspace.default\",\"contribution_id\":\"" ++
    fixture_catalog_scope ++
    "\"},\"content_revision\":\"" ++
    fixture_catalog_revision ++
    "\",\"display_name\":\"Audit\",\"description\":\"Duplicate id\",\"argument_schema\":{\"schema\":\"metask.skill-arguments/v1\",\"max_values\":64,\"names\":[]}}],\"issues\":[]}";

const empty_mcp_catalog_json =
    "{\"schema\":\"agentcore.mcp-catalog/v1\",\"catalog_generation\":7," ++
    "\"catalog_fingerprint\":\"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\"," ++
    "\"servers\":[],\"tools\":[],\"issues\":[]}";

pub fn diagnostic(out: ?*wire.OwnedBytesV1) void {
    if (out) |value| value.* = .{ .ptr = @ptrCast(&diagnostic_byte), .len = 1 };
}

fn recordAllowedTools(
    host: *const wire.SessionHostConfigV1,
    count: *usize,
    names: *[16][32]u8,
) void {
    const allowed_count: usize = @intCast(host.allowed_tool_count);
    count.* = allowed_count;
    if (host.allowed_tools) |allowed_tools| {
        for (allowed_tools[0..allowed_count], 0..) |name, index| {
            const bytes = sdk.borrowedBytes(name) catch continue;
            if (bytes.len <= names[index].len)
                @memcpy(names[index][0..bytes.len], bytes);
        }
    }
}

pub fn runtimeCreate(
    config: ?*const wire.RuntimeConfigV1,
    plugins: ?*const wire.RuntimePluginConfigV1,
    out_runtime: ?*?*wire.RuntimeHandle,
    out_error: ?*wire.OwnedBytesV1,
) callconv(.c) u32 {
    if (out_error) |out| out.* = .{ .ptr = null, .len = 0 };
    if (config == null or plugins != null or out_runtime == null) {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    }
    std.debug.assert(config.?.enable_teams == 0);
    fake_core.lock();
    defer fake_core.unlock();
    fake_core.runtime_created += 1;
    fake_core.image_tool = if (config.?.host_tool_count == 2) config.?.host_tools.?[0] else null;
    fake_core.delivery_tool = if (config.?.host_tool_count == 2) config.?.host_tools.?[1] else null;
    fake_core.image_tool_seen = if (config.?.host_tools) |tools|
        config.?.host_tool_count == 2 and
            config.?.builtin_tools != null and config.?.builtin_tool_count == 10 and
            std.mem.eql(u8, sdk.borrowedBytes(tools[0].name) catch "", "GenerateImage") and
            tools[0].execute != null and tools[0].release_result != null
    else
        false;
    fake_core.mcp_server_count = @intCast(config.?.mcp_server_count);
    fake_core.mcp_descriptor_valid = if (config.?.mcp_server_count == 0)
        config.?.mcp_servers == null
    else if (config.?.mcp_servers) |servers|
        servers[0].struct_size == @sizeOf(wire.McpServerV1) and
            servers[0].connector.open != null and
            servers[0].connector.request != null and
            servers[0].connector.request_tool_stream != null and
            servers[0].connector.notify != null and
            servers[0].connector.close != null and
            servers[0].connector.release_response != null
    else
        false;
    out_runtime.?.* = @ptrCast(&fake_core.runtime);
    return wire.STATUS_OK;
}

pub fn runtimeDestroy(
    _: ?*wire.RuntimeHandle,
    out_error: ?*wire.OwnedBytesV1,
) callconv(.c) u32 {
    if (out_error) |out| out.* = .{ .ptr = null, .len = 0 };
    fake_core.lock();
    defer fake_core.unlock();
    if (fake_core.runtime_destroy_failures > 0) {
        fake_core.runtime_destroy_failures -= 1;
        diagnostic(out_error);
        return wire.STATUS_BUSY;
    }
    for (&fake_core.sessions) |*session| {
        session.lock();
        const live = session.in_use and !session.destroyed;
        session.unlock();
        if (live) {
            fake_core.runtime_destroy_busy_attempts += 1;
            diagnostic(out_error);
            return wire.STATUS_BUSY;
        }
    }
    for (&fake_core.catalogs) |*catalog_entry| {
        if (catalog_entry.in_use and !catalog_entry.released) {
            fake_core.runtime_destroy_busy_attempts += 1;
            diagnostic(out_error);
            return wire.STATUS_BUSY;
        }
    }
    fake_core.runtime_destroyed += 1;
    return wire.STATUS_OK;
}

pub fn sessionCreate(
    _: ?*wire.RuntimeHandle,
    config: ?*const wire.SessionCreateConfigV1,
    callbacks: ?*const wire.SessionCallbacksV1,
    out_session: ?*?*wire.SessionHandle,
    out_error: ?*wire.OwnedBytesV1,
) callconv(.c) u32 {
    if (out_error) |out| out.* = .{ .ptr = null, .len = 0 };
    if (config == null or callbacks == null or out_session == null) {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    }
    const profile = FakePromptProfile.copy(config.?.prompt_profile) orelse return wire.STATUS_INVALID_ARGUMENT;
    const host = config.?.host orelse {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    };
    std.debug.assert(host.team == null);
    const key = sdk.borrowedBytes(host.api_key) catch {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    };
    const model = sdk.borrowedBytes(config.?.model) catch {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    };
    if (model.len == 0 or model.len > 256) {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    }
    const workspace_home = sdk.borrowedBytes(host.workspace_home) catch {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    };
    const bound_catalog: ?*FakeCatalog = if (host.skill_catalog) |handle|
        @ptrCast(@alignCast(handle))
    else
        null;
    const policy_valid = if (host.skill_policy) |policy|
        validSkillPolicy(policy)
    else
        false;
    const mcp_selection_valid = if (host.mcp_selection) |selection|
        validMcpSelection(selection)
    else
        true;
    if ((bound_catalog != null and !policy_valid) or
        (bound_catalog == null and host.skill_policy != null) or
        host.permission_rules != null or
        !mcp_selection_valid or
        host.durable_budget != null)
    {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    }
    if (bound_catalog) |catalog_entry| {
        if (!catalog_entry.in_use or catalog_entry.released) {
            diagnostic(out_error);
            return wire.STATUS_SKILL_CATALOG_INVALID;
        }
    }
    fake_core.lock();
    defer fake_core.unlock();
    if (fake_core.forced_session_create_status) |status| {
        fake_core.forced_session_create_status = null;
        out_session.?.* = if (fake_core.malformed_session_create_handle) @ptrCast(&fake_core) else null;
        fake_core.malformed_session_create_handle = false;
        diagnostic(out_error);
        return status;
    }
    if (fake_core.session_create_failures > 0) {
        fake_core.session_create_failures -= 1;
        diagnostic(out_error);
        return wire.STATUS_CORE_ERROR;
    }
    for (&fake_core.sessions) |*session| {
        if (!session.in_use) {
            var session_id = [_]u8{0} ** wire.MAX_SESSION_ID_BYTES_V1;
            const id = std.fmt.bufPrint(
                &session_id,
                "{d:0>24}",
                .{fake_core.session_created + 1},
            ) catch {
                diagnostic(out_error);
                return wire.STATUS_OUT_OF_MEMORY;
            };
            session.* = .{
                .in_use = true,
                .plan = fake_core.next_plan,
                .prompt_profile = profile,
                .callbacks = callbacks.?.*,
                .session_id = session_id,
                .session_id_len = id.len,
                .catalog = bound_catalog,
                .permission_mode_code = host.permission_mode_code,
                .credential_digest = credentialDigest(key),
            };
            @memcpy(session.model[0..model.len], model);
            session.model_len = model.len;
            fake_core.next_plan = .immediate;
            fake_core.session_created += 1;
            fake_core.credential_seen = std.mem.eql(u8, key, "fixture-secret");
            fake_core.product_allowlist_seen = host.allowed_tools != null and
                host.allowed_tool_count == 12 and
                std.mem.eql(u8, sdk.borrowedBytes(host.allowed_tools.?[10]) catch "", "GenerateImage") and
                std.mem.eql(u8, sdk.borrowedBytes(host.allowed_tools.?[11]) catch "", "DeliverFile");
            recordAllowedTools(
                host,
                &fake_core.last_allowed_tool_count,
                &fake_core.last_allowed_tool_names,
            );
            fake_core.workspace_home_seen = workspace_home.len != 0;
            fake_core.skill_session_bound = bound_catalog != null;
            fake_core.skill_policy_seen = bound_catalog != null and policy_valid;
            fake_core.permission_rules_absent = host.permission_rules == null;
            fake_core.last_permission_mode_code = host.permission_mode_code;
            fake_core.last_shell_policy_code = host.shell_policy_code;
            fake_core.last_created_provider_kind_code = host.provider_kind_code;
            fake_core.last_created_protocol_kind_code = host.protocol_kind_code;
            out_session.?.* = @ptrCast(session);
            return wire.STATUS_OK;
        }
    }
    diagnostic(out_error);
    return wire.STATUS_OUT_OF_MEMORY;
}

pub fn runtimeQuerySkillCatalog(
    runtime: ?*wire.RuntimeHandle,
    query: ?*const wire.SkillCatalogQueryV1,
    out_catalog: ?*?*wire.SkillCatalogHandle,
    out_descriptor: ?*wire.OwnedBytesV1,
    out_error: ?*wire.OwnedBytesV1,
) callconv(.c) u32 {
    if (out_error) |out| out.* = .{ .ptr = null, .len = 0 };
    if (out_descriptor) |out| out.* = .{ .ptr = null, .len = 0 };
    if (out_catalog) |out| out.* = null;
    const input = query orelse {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    };
    if (runtime == null or out_catalog == null or out_descriptor == null or
        input.struct_size != @sizeOf(wire.SkillCatalogQueryV1) or
        input.reserved0 != 0 or
        input.additional_source_count > wire.MAX_SKILL_SOURCES_V1 or
        ((input.additional_source_count == 0) != (input.additional_sources == null)))
    {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    }
    const root = sdk.borrowedBytes(input.workspace_root) catch {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    };
    const home = sdk.borrowedBytes(input.workspace_home) catch {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    };
    const epoch = sdk.borrowedBytes(input.workspace_epoch) catch {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    };
    if (root.len == 0 or home.len == 0) {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    }

    fake_core.lock();
    defer fake_core.unlock();
    fake_core.catalog_queries += 1;
    fake_core.catalog_source_count = @intCast(input.additional_source_count);
    fake_core.catalog_default_user_priority = input.default_user_source_priority;
    fake_core.catalog_default_workspace_priority = input.default_workspace_source_priority;
    if (input.additional_sources) |sources| {
        for (sources[0..fake_core.catalog_source_count], 0..) |source, index| {
            if (source.struct_size != @sizeOf(wire.SkillSourceV1) or
                source.reserved0 != 0 or
                !std.mem.allEqual(u64, &source.reserved, 0) or
                (source.scope_code != wire.SKILL_SOURCE_USER and
                    source.scope_code != wire.SKILL_SOURCE_WORKSPACE)) return wire.STATUS_INVALID_ARGUMENT;
            const source_root = sdk.borrowedBytes(source.root) catch return wire.STATUS_INVALID_ARGUMENT;
            const source_id = sdk.borrowedBytes(source.source_instance_id) catch return wire.STATUS_INVALID_ARGUMENT;
            if (source_root.len == 0 or source_id.len == 0 or source_id.len > 128)
                return wire.STATUS_INVALID_ARGUMENT;
            const observation = &fake_core.catalog_sources[index];
            observation.* = .{ .scope = source.scope_code, .priority = source.priority, .id_len = source_id.len };
            std.crypto.hash.sha2.Sha256.hash(source_root, &observation.root_hash, .{});
            @memcpy(observation.id[0..source_id.len], source_id);
        }
    }
    fake_core.workspace_home_seen = true;
    fake_core.workspace_epoch_seen = epoch.len != 0;
    if (fake_core.catalog_plan == .controlled) {
        fake_core.catalog_query_entered = true;
        fake_core.catalog_condition.broadcast(std.testing.io);
        while (!fake_core.allow_catalog_query)
            fake_core.catalog_condition.waitUncancelable(
                std.testing.io,
                &fake_core.mutex,
            );
    }
    if (fake_core.catalog_plan == .query_failure) {
        diagnostic(out_error);
        return wire.STATUS_SKILL_CATALOG_INVALID;
    }
    if (fake_core.catalog_plan == .query_incomplete) {
        diagnostic(out_error);
        return wire.STATUS_SKILL_CATALOG_INCOMPLETE;
    }
    for (&fake_core.catalogs) |*catalog_entry| {
        if (catalog_entry.in_use and !catalog_entry.released) continue;
        catalog_entry.* = .{ .in_use = true };
        out_catalog.?.* = @ptrCast(catalog_entry);
        const descriptor: []const u8 = switch (fake_core.catalog_plan) {
            .healthy => healthy_catalog_json,
            .degraded => degraded_catalog_json,
            .controlled => healthy_catalog_json,
            .duplicate_skill_id => duplicate_catalog_json,
            .malformed => "{}",
            .query_incomplete => unreachable,
            .query_failure => unreachable,
        };
        out_descriptor.?.* = .{
            .ptr = @ptrCast(@constCast(descriptor.ptr)),
            .len = descriptor.len,
        };
        return wire.STATUS_OK;
    }
    diagnostic(out_error);
    return wire.STATUS_OUT_OF_MEMORY;
}

pub fn skillCatalogRelease(
    handle: ?*wire.SkillCatalogHandle,
    out_error: ?*wire.OwnedBytesV1,
) callconv(.c) u32 {
    if (out_error) |out| out.* = .{ .ptr = null, .len = 0 };
    const catalog_entry: *FakeCatalog = @ptrCast(@alignCast(handle orelse {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    }));
    fake_core.lock();
    defer fake_core.unlock();
    if (!catalog_entry.in_use or catalog_entry.released) {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    }
    catalog_entry.released = true;
    fake_core.catalog_releases += 1;
    if (fake_core.catalog_release_failures != 0) {
        fake_core.catalog_release_failures -= 1;
        return wire.STATUS_CORE_ERROR;
    }
    return wire.STATUS_OK;
}

pub fn sessionDestroy(
    handle: ?*wire.SessionHandle,
    out_error: ?*wire.OwnedBytesV1,
) callconv(.c) u32 {
    if (out_error) |out| out.* = .{ .ptr = null, .len = 0 };
    const session: *FakeSession = @ptrCast(@alignCast(handle orelse {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    }));
    session.lock();
    if (session.running or session.compacting) {
        session.unlock();
        diagnostic(out_error);
        return wire.STATUS_BUSY;
    }
    session.unlock();
    fake_core.lock();
    const probe = fake_core.session_destroy_probe;
    fake_core.unlock();
    if (probe) |observer| observer.observe_fn(observer.context);
    fake_core.lock();
    const forced_status = fake_core.forced_session_destroy_status;
    fake_core.forced_session_destroy_status = null;
    if (forced_status) |status| {
        fake_core.unlock();
        diagnostic(out_error);
        return status;
    }
    if (fake_core.session_destroy_failures > 0) {
        fake_core.session_destroy_failures -= 1;
        fake_core.unlock();
        diagnostic(out_error);
        return wire.STATUS_BUSY;
    }
    fake_core.unlock();
    session.lock();
    session.destroyed = true;
    session.unlock();
    fake_core.lock();
    fake_core.session_destroyed += 1;
    fake_core.unlock();
    return wire.STATUS_OK;
}

pub fn sessionSetModel(
    handle: ?*wire.SessionHandle,
    value: wire.BytesViewV1,
    out_error: ?*wire.OwnedBytesV1,
) callconv(.c) u32 {
    if (out_error) |out| out.* = .{ .ptr = null, .len = 0 };
    fake_core.lock();
    const forced_status = fake_core.forced_set_model_status;
    fake_core.forced_set_model_status = null;
    fake_core.unlock();
    if (forced_status) |status| {
        diagnostic(out_error);
        return status;
    }
    const session: *FakeSession = @ptrCast(@alignCast(handle orelse {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    }));
    const model = sdk.borrowedBytes(value) catch {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    };
    if (model.len == 0 or model.len > session.model.len) {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    }
    session.lock();
    defer session.unlock();
    if (!session.in_use or session.destroyed) {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    }
    if (session.running or session.compacting) {
        diagnostic(out_error);
        return wire.STATUS_BUSY;
    }
    @memcpy(session.model[0..model.len], model);
    session.model_len = model.len;
    return wire.STATUS_OK;
}

pub fn sessionBindSkillPolicy(
    session_handle: ?*wire.SessionHandle,
    catalog_handle: ?*wire.SkillCatalogHandle,
    policy: ?*const wire.SkillPolicyV1,
    out_error: ?*wire.OwnedBytesV1,
) callconv(.c) u32 {
    if (out_error) |out| out.* = .{ .ptr = null, .len = 0 };
    const session: *FakeSession = @ptrCast(@alignCast(session_handle orelse {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    }));
    const catalog_entry: *FakeCatalog = @ptrCast(@alignCast(catalog_handle orelse {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    }));
    const selected = policy orelse {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    };
    if (!validSkillPolicy(selected)) {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    }
    fake_core.lock();
    const forced_status = fake_core.forced_skill_update_status;
    fake_core.forced_skill_update_status = null;
    fake_core.skill_policy_seen = true;
    fake_core.unlock();
    if (forced_status) |status| {
        diagnostic(out_error);
        return status;
    }
    session.lock();
    if (session.running or session.compacting) {
        session.unlock();
        diagnostic(out_error);
        return wire.STATUS_BUSY;
    }
    if (!catalog_entry.in_use or catalog_entry.released) {
        session.unlock();
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    }
    session.catalog = catalog_entry;
    session.unlock();
    fake_core.lock();
    fake_core.catalog_refreshes += 1;
    fake_core.unlock();
    return wire.STATUS_OK;
}

pub fn sessionUpdatePermissionRules(
    _: ?*wire.SessionHandle,
    _: ?*const wire.PermissionRuleSetV1,
    out_error: ?*wire.OwnedBytesV1,
) callconv(.c) u32 {
    if (out_error) |out| out.* = .{ .ptr = null, .len = 0 };
    diagnostic(out_error);
    return wire.STATUS_INVALID_STATE;
}

pub fn runtimeRefreshMcp(
    runtime: ?*wire.RuntimeHandle,
    out_generation: ?*u64,
    out_error: ?*wire.OwnedBytesV1,
) callconv(.c) u32 {
    if (out_error) |out| out.* = .{ .ptr = null, .len = 0 };
    if (runtime == null or out_generation == null) {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    }
    fake_core.lock();
    fake_core.mcp_refreshes += 1;
    const forced_status = fake_core.forced_mcp_refresh_status;
    fake_core.forced_mcp_refresh_status = null;
    fake_core.unlock();
    if (forced_status) |status| {
        diagnostic(out_error);
        return status;
    }
    out_generation.?.* = 7;
    return wire.STATUS_OK;
}

pub fn runtimeDescribeMcp(
    runtime: ?*wire.RuntimeHandle,
    out_descriptor: ?*wire.OwnedBytesV1,
    out_error: ?*wire.OwnedBytesV1,
) callconv(.c) u32 {
    if (out_error) |out| out.* = .{ .ptr = null, .len = 0 };
    if (out_descriptor) |out| out.* = .{ .ptr = null, .len = 0 };
    if (runtime == null or out_descriptor == null) {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    }
    fake_core.lock();
    fake_core.mcp_descriptions += 1;
    fake_core.unlock();
    out_descriptor.?.* = .{
        .ptr = @ptrCast(@constCast(empty_mcp_catalog_json.ptr)),
        .len = empty_mcp_catalog_json.len,
    };
    return wire.STATUS_OK;
}

pub fn runtimeApplyMcpConfiguration(
    runtime: ?*wire.RuntimeHandle,
    configuration: ?*const wire.McpConfigurationV1,
    out_report: ?*wire.McpApplyReportV1,
    out_error: ?*wire.OwnedBytesV1,
) callconv(.c) u32 {
    if (out_error) |out| out.* = .{ .ptr = null, .len = 0 };
    const input = configuration orelse {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    };
    const report = out_report orelse {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    };
    if (runtime == null or input.struct_size != @sizeOf(wire.McpConfigurationV1) or
        input.desired_revision == 0 or
        (input.server_count == 0) != (input.servers == null))
    {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    }
    fake_core.lock();
    defer fake_core.unlock();
    fake_core.mcp_configuration_applies += 1;
    fake_core.last_mcp_apply_server_count = @intCast(input.server_count);
    if (fake_core.forced_mcp_apply_status) |status| {
        fake_core.forced_mcp_apply_status = null;
        diagnostic(out_error);
        return status;
    }
    const disposition = fake_core.forced_mcp_apply_disposition orelse
        wire.MCP_APPLY_APPLIED;
    fake_core.forced_mcp_apply_disposition = null;
    report.* = .{
        .struct_size = @sizeOf(wire.McpApplyReportV1),
        .disposition_code = disposition,
        .desired_revision = input.desired_revision,
        .active_revision = if (disposition == wire.MCP_APPLY_APPLIED)
            input.desired_revision
        else
            input.desired_revision - 1,
        .catalog_generation = 0,
        .reserved = [_]u64{0} ** 4,
    };
    return wire.STATUS_OK;
}

pub fn sessionRestore(
    runtime: ?*wire.RuntimeHandle,
    config: ?*const wire.SessionRestoreConfigV1,
    callbacks: ?*const wire.SessionCallbacksV1,
    out_session: ?*?*wire.SessionHandle,
    out_report: ?*wire.OwnedBytesV1,
    out_error: ?*wire.OwnedBytesV1,
) callconv(.c) u32 {
    if (out_error) |out| out.* = .{ .ptr = null, .len = 0 };
    if (out_report) |out| out.* = .{ .ptr = null, .len = 0 };
    if (out_session) |out| out.* = null;
    const input = config orelse {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    };
    const host = input.host orelse {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    };
    std.debug.assert(host.team == null);
    const source = input.source orelse {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    };
    if (runtime == null or callbacks == null or out_session == null or out_report == null or
        input.struct_size != @sizeOf(wire.SessionRestoreConfigV1) or
        input.limits == null or source.struct_size != @sizeOf(wire.CheckpointSourceV1) or
        source.read == null or host.struct_size != @sizeOf(wire.SessionHostConfigV1))
    {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    }

    fake_core.lock();
    fake_core.checkpoint_restores += 1;
    fake_core.last_restored_provider_kind_code = host.provider_kind_code;
    fake_core.last_restored_protocol_kind_code = host.protocol_kind_code;
    const forced_status = fake_core.forced_checkpoint_restore_status;
    fake_core.forced_checkpoint_restore_status = null;
    const restore_degraded = fake_core.forced_checkpoint_restore_degraded;
    fake_core.forced_checkpoint_restore_degraded = false;
    if (fake_core.restore_controlled and !fake_core.restore_after_create) {
        fake_core.restore_controlled = false;
        fake_core.restore_entered = true;
        fake_core.checkpoint_condition.broadcast(std.testing.io);
        while (!fake_core.allow_restore)
            fake_core.checkpoint_condition.waitUncancelable(std.testing.io, &fake_core.mutex);
    }
    const generation = fake_core.checkpoint_generation;
    const last_run_id = fake_core.restore_last_run_id;
    const last_compact_id = fake_core.restore_last_compact_id;
    fake_core.unlock();
    if (forced_status) |status| {
        diagnostic(out_error);
        return status;
    }

    var source_buffer: [5]u8 = undefined;
    while (true) {
        var read_len: u64 = 0;
        const io_status = source.read.?(
            source.ctx,
            &source_buffer,
            source_buffer.len,
            &read_len,
        );
        if (io_status != wire.CHECKPOINT_IO_OK) {
            diagnostic(out_error);
            return wire.STATUS_CHECKPOINT_IO;
        }
        if (read_len == 0) break;
        if (read_len > source_buffer.len) {
            diagnostic(out_error);
            return wire.STATUS_CHECKPOINT_IO;
        }
    }

    const key = sdk.borrowedBytes(host.api_key) catch {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    };
    fake_core.lock();
    defer fake_core.unlock();
    for (&fake_core.sessions) |*session| {
        if (session.in_use) continue;
        var session_id = [_]u8{0} ** wire.MAX_SESSION_ID_BYTES_V1;
        const id = if (fake_core.restore_session_id_len != 0) preserved: {
            const length = fake_core.restore_session_id_len;
            @memcpy(session_id[0..length], fake_core.restore_session_id[0..length]);
            break :preserved session_id[0..length];
        } else std.fmt.bufPrint(
            &session_id,
            "{d:0>24}",
            .{fake_core.session_created + 1},
        ) catch {
            diagnostic(out_error);
            return wire.STATUS_OUT_OF_MEMORY;
        };
        session.* = .{
            .in_use = true,
            .restored = true,
            .permission_mode_code = host.permission_mode_code,
            .prompt_profile = fake_core.restored_prompt_profile,
            .credential_digest = credentialDigest(key),
            .restore_degraded = restore_degraded,
            .callbacks = callbacks.?.*,
            .session_id = session_id,
            .session_id_len = id.len,
            .run_id = last_run_id,
            .compact_id = last_compact_id,
        };
        @memcpy(session.model[0..fake_core.restore_model_len], fake_core.restore_model[0..fake_core.restore_model_len]);
        session.model_len = fake_core.restore_model_len;
        const encoded = (if (restore_degraded)
            std.fmt.bufPrint(
                &session.description_buffer,
                "{{\"schema\":\"agentcore.restore-report/v1\",\"health\":\"degraded\",\"session_id\":\"{s}\",\"checkpoint_generation\":{d},\"policy_generation\":1,\"catalog_generation\":0,\"skill\":{{\"disposition\":\"unavailable\",\"checkpoint_enabled\":1,\"restored_enabled\":0,\"invalidated\":1}},\"permission\":{{\"restored_rules\":0,\"invalidated_rules\":1}},\"mcp\":{{\"restored_bindings\":0,\"invalidated_bindings\":1}},\"issues\":[{{\"issue_id\":\"1111111111111111111111111111111111111111111111111111111111111111\",\"subsystem\":\"mcp\",\"reason\":\"unavailable\",\"skill_id\":null,\"permission_rule_id\":null,\"server_binding_identity\":null,\"authority_binding\":null,\"canonical_name\":null}}]}}",
                .{ id, generation },
            )
        else
            std.fmt.bufPrint(
                &session.description_buffer,
                "{{\"schema\":\"agentcore.restore-report/v1\",\"health\":\"complete\",\"session_id\":\"{s}\",\"checkpoint_generation\":{d},\"policy_generation\":1,\"catalog_generation\":0,\"skill\":{{\"disposition\":\"not_bound\",\"checkpoint_enabled\":0,\"restored_enabled\":0,\"invalidated\":0}},\"permission\":{{\"restored_rules\":0,\"invalidated_rules\":0}},\"mcp\":{{\"restored_bindings\":0,\"invalidated_bindings\":0}},\"issues\":[]}}",
                .{ id, generation },
            )) catch {
            diagnostic(out_error);
            return wire.STATUS_OUT_OF_MEMORY;
        };
        fake_core.session_created += 1;
        fake_core.credential_seen = std.mem.eql(u8, key, "fixture-secret");
        recordAllowedTools(
            host,
            &fake_core.last_restored_allowed_tool_count,
            &fake_core.last_restored_allowed_tool_names,
        );
        out_session.?.* = @ptrCast(session);
        out_report.?.* = .{ .ptr = @ptrCast(encoded.ptr), .len = encoded.len };
        if (fake_core.restore_controlled and fake_core.restore_after_create) {
            fake_core.restore_controlled = false;
            fake_core.restore_entered = true;
            fake_core.checkpoint_condition.broadcast(std.testing.io);
            while (!fake_core.allow_restore)
                fake_core.checkpoint_condition.waitUncancelable(std.testing.io, &fake_core.mutex);
        }
        return wire.STATUS_OK;
    }
    diagnostic(out_error);
    return wire.STATUS_OUT_OF_MEMORY;
}

pub fn sessionDescribe(
    handle: ?*wire.SessionHandle,
    out_description: ?*wire.OwnedBytesV1,
    out_error: ?*wire.OwnedBytesV1,
) callconv(.c) u32 {
    if (out_description) |out| out.* = .{ .ptr = null, .len = 0 };
    if (out_error) |out| out.* = .{ .ptr = null, .len = 0 };
    const session: *FakeSession = @ptrCast(@alignCast(handle orelse {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    }));
    if (out_description == null) {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    }
    fake_core.lock();
    const forced_status = fake_core.forced_checkpoint_describe_status;
    fake_core.forced_checkpoint_describe_status = null;
    const malformed = fake_core.malformed_checkpoint_description;
    fake_core.malformed_checkpoint_description = false;
    const session_id_mismatch = fake_core.checkpoint_description_session_id_mismatch;
    fake_core.checkpoint_description_session_id_mismatch = false;
    const generation = fake_core.checkpoint_generation;
    fake_core.checkpoint_descriptions += 1;
    fake_core.unlock();
    if (forced_status) |status| {
        diagnostic(out_error);
        return status;
    }
    session.lock();
    defer session.unlock();
    if (!session.in_use or session.destroyed) {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    }
    var entries: [4]sdk.PromptProfileSection = undefined;
    for (entries[0..session.prompt_profile.count], 0..) |*entry, i| entry.* = .{
        .op = .replace,
        .id = session.prompt_profile.ids[i][0..session.prompt_profile.id_lens[i]],
        .text = session.prompt_profile.texts[i][0..session.prompt_profile.text_lens[i]],
        .order = 0,
        .interpolate = false,
    };
    const profile_json = std.json.Stringify.valueAlloc(std.testing.allocator, entries[0..session.prompt_profile.count], .{}) catch
        return wire.STATUS_OUT_OF_MEMORY;
    defer std.testing.allocator.free(profile_json);
    const described_session_id: []const u8 = if (session_id_mismatch)
        "ffffffffffffffffffffffff"
    else
        session.session_id[0..session.session_id_len];
    const model_json = std.json.Stringify.valueAlloc(std.testing.allocator, if (session.model_len != 0) session.model[0..session.model_len] else "fixture-model", .{}) catch return wire.STATUS_OUT_OF_MEMORY;
    defer std.testing.allocator.free(model_json);
    const encoded = if (malformed)
        std.fmt.bufPrint(&session.description_buffer, "{{}}", .{}) catch {
            diagnostic(out_error);
            return wire.STATUS_OUT_OF_MEMORY;
        }
    else
        (if (session.restore_degraded)
            std.fmt.bufPrint(
                &session.description_buffer,
                "{{\"schema\":\"agentcore.session-description/v1\",\"session_id\":\"{s}\",\"origin\":\"{s}\",\"lifecycle\":\"idle\",\"registered\":true,\"last_run_id\":{d},\"last_compact_id\":{d},\"checkpoint_generation\":{d},\"permission_mode\":\"{s}\",\"policy_generation\":{d},\"catalog_generation\":0,\"model\":{s},\"image_input\":{{\"supported\":false,\"source\":\"unknown\"}},\"conversation\":{{\"message_count\":0,\"compact_boundary\":0}},\"skill\":{{\"catalog_revision\":null}},\"mcp\":{{\"selection_fingerprint\":\"0000000000000000000000000000000000000000000000000000000000000000\",\"tools\":[]}},\"prompt\":{{\"profile\":{s},\"manifest\":null}},\"budget\":{{\"hard_bytes\":1024,\"soft_bytes\":512,\"durable_usage_bytes\":0,\"available_bytes\":1024,\"compaction_recommended\":false,\"last_outcome\":\"none\",\"required_bytes\":0}},\"restore\":{{\"health\":\"degraded\",\"invalidated_skill_authority\":1,\"invalidated_permission_rules\":1,\"invalidated_mcp_bindings\":1,\"issues\":[{{\"issue_id\":\"1111111111111111111111111111111111111111111111111111111111111111\",\"subsystem\":\"mcp\",\"reason\":\"unavailable\",\"skill_id\":null,\"permission_rule_id\":null,\"server_binding_identity\":null,\"authority_binding\":null,\"canonical_name\":null}}]}}}}",
                .{
                    described_session_id,
                    if (session.restored) "restored" else "fresh",
                    session.run_id,
                    session.compact_id,
                    generation,
                    permissionModeName(session.permission_mode_code),
                    session.policy_generation,
                    model_json,
                    profile_json,
                },
            )
        else
            std.fmt.bufPrint(
                &session.description_buffer,
                "{{\"schema\":\"agentcore.session-description/v1\",\"session_id\":\"{s}\",\"origin\":\"{s}\",\"lifecycle\":\"idle\",\"registered\":true,\"last_run_id\":{d},\"last_compact_id\":{d},\"checkpoint_generation\":{d},\"permission_mode\":\"{s}\",\"policy_generation\":{d},\"catalog_generation\":0,\"model\":{s},\"image_input\":{{\"supported\":false,\"source\":\"unknown\"}},\"conversation\":{{\"message_count\":0,\"compact_boundary\":0}},\"skill\":{{\"catalog_revision\":null}},\"mcp\":{{\"selection_fingerprint\":\"0000000000000000000000000000000000000000000000000000000000000000\",\"tools\":[]}},\"prompt\":{{\"profile\":{s},\"manifest\":null}},\"budget\":{{\"hard_bytes\":1024,\"soft_bytes\":512,\"durable_usage_bytes\":0,\"available_bytes\":1024,\"compaction_recommended\":false,\"last_outcome\":\"none\",\"required_bytes\":0}},\"restore\":{{\"health\":\"complete\",\"invalidated_skill_authority\":0,\"invalidated_permission_rules\":0,\"invalidated_mcp_bindings\":0,\"issues\":[]}}}}",
                .{
                    described_session_id,
                    if (session.restored) "restored" else "fresh",
                    session.run_id,
                    session.compact_id,
                    generation,
                    permissionModeName(session.permission_mode_code),
                    session.policy_generation,
                    model_json,
                    profile_json,
                },
            )) catch {
            diagnostic(out_error);
            return wire.STATUS_OUT_OF_MEMORY;
        };
    out_description.?.* = .{ .ptr = @ptrCast(encoded.ptr), .len = encoded.len };
    return wire.STATUS_OK;
}

pub fn sessionUpdateMcp(
    handle: ?*wire.SessionHandle,
    selection: ?*const wire.McpSelectionV1,
    out_error: ?*wire.OwnedBytesV1,
) callconv(.c) u32 {
    if (out_error) |out| out.* = .{ .ptr = null, .len = 0 };
    const session: *FakeSession = @ptrCast(@alignCast(handle orelse {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    }));
    const value = selection orelse {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    };
    if (!validMcpSelection(value)) {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    }
    fake_core.lock();
    const forced_status = fake_core.forced_mcp_update_status;
    fake_core.forced_mcp_update_status = null;
    fake_core.unlock();
    if (forced_status) |status| {
        diagnostic(out_error);
        return status;
    }
    session.lock();
    const unavailable = !session.in_use or session.destroyed;
    const busy = session.running or session.compacting;
    session.unlock();
    if (unavailable) {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    }
    if (busy) {
        diagnostic(out_error);
        return wire.STATUS_BUSY;
    }
    fake_core.lock();
    fake_core.mcp_updates += 1;
    fake_core.last_mcp_update_selector_count = value.selector_count;
    fake_core.unlock();
    return wire.STATUS_OK;
}

pub fn sessionExportCheckpoint(
    handle: ?*wire.SessionHandle,
    raw_config: ?*const wire.CheckpointExportConfigV1,
    out_result: ?*wire.CheckpointExportResultV1,
    out_error: ?*wire.OwnedBytesV1,
) callconv(.c) u32 {
    if (out_error) |out| out.* = .{ .ptr = null, .len = 0 };
    const session: *FakeSession = @ptrCast(@alignCast(handle orelse {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    }));
    const config = raw_config orelse {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    };
    const limits = config.limits orelse {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    };
    const sink = config.sink orelse {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    };
    const write = sink.write orelse {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    };
    if (out_result == null or
        config.struct_size != @sizeOf(wire.CheckpointExportConfigV1) or
        limits.struct_size != @sizeOf(wire.CheckpointLimitsV1) or
        sink.struct_size != @sizeOf(wire.CheckpointSinkV1))
    {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    }
    session.lock();
    const unavailable = !session.in_use or session.destroyed or session.running or session.compacting;
    session.unlock();
    if (unavailable) {
        diagnostic(out_error);
        return wire.STATUS_BUSY;
    }
    fake_core.lock();
    const forced_status = fake_core.forced_checkpoint_export_status;
    fake_core.forced_checkpoint_export_status = null;
    const malformed = fake_core.malformed_checkpoint_result;
    fake_core.malformed_checkpoint_result = false;
    const generation = fake_core.checkpoint_generation;
    const payload = fake_core.checkpoint_payload;
    fake_core.checkpoint_exports += 1;
    if (fake_core.checkpoint_export_controlled) {
        fake_core.checkpoint_export_controlled = false;
        fake_core.checkpoint_export_entered = true;
        fake_core.checkpoint_condition.broadcast(std.testing.io);
        while (!fake_core.allow_checkpoint_export)
            fake_core.checkpoint_condition.waitUncancelable(
                std.testing.io,
                &fake_core.mutex,
            );
    }
    fake_core.unlock();
    if (forced_status) |status| {
        diagnostic(out_error);
        return status;
    }
    const split = payload.len / 2;
    const chunk_count: u64 = if (split == 0) 1 else 2;
    var index: u64 = 0;
    while (index < chunk_count) : (index += 1) {
        const chunk = if (chunk_count == 1)
            payload
        else if (index == 0)
            payload[0..split]
        else
            payload[split..];
        const io_status = write(sink.ctx, sdk.bytesView(chunk));
        if (io_status != wire.CHECKPOINT_IO_OK) {
            diagnostic(out_error);
            return wire.STATUS_CHECKPOINT_IO;
        }
    }
    out_result.?.* = std.mem.zeroes(wire.CheckpointExportResultV1);
    out_result.?.struct_size = @sizeOf(wire.CheckpointExportResultV1);
    out_result.?.checkpoint_generation = generation;
    out_result.?.total_bytes = if (malformed) payload.len + 1 else payload.len;
    out_result.?.chunk_count = chunk_count;
    // The ABI does not define the digest algorithm. Keep this deliberately
    // different from the payload SHA-256 so MetaWork tests prove that product
    // integrity is derived from the streamed bytes instead of this field.
    out_result.?.digest = [_]u8{0xa5} ** 32;
    return wire.STATUS_OK;
}

pub fn sessionCompact(
    handle: ?*wire.SessionHandle,
    operation_id: u64,
    out_result: ?*wire.CompactResultV1,
    out_error: ?*wire.OwnedBytesV1,
) callconv(.c) u32 {
    if (out_error) |out| out.* = .{ .ptr = null, .len = 0 };
    const session: *FakeSession = @ptrCast(@alignCast(handle orelse {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    }));
    if (operation_id == 0 or out_result == null) {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    }
    session.lock();
    if (session.running or session.compacting) {
        session.unlock();
        diagnostic(out_error);
        return wire.STATUS_BUSY;
    }
    if (operation_id <= session.compact_id) {
        session.unlock();
        diagnostic(out_error);
        return wire.STATUS_STALE_COMPACT;
    }
    session.compact_id = operation_id;
    session.compacting = true;
    session.compact_abort_requested = false;
    const plan = session.plan;
    session.broadcast();
    session.unlock();

    fake_core.lock();
    fake_core.compact_calls += 1;
    const forced_status = fake_core.forced_compact_status;
    fake_core.forced_compact_status = null;
    const forced_outcome = fake_core.forced_compact_outcome;
    fake_core.forced_compact_outcome = null;
    const malformed = fake_core.malformed_compact_result;
    fake_core.malformed_compact_result = false;
    fake_core.unlock();

    session.lock();
    while (plan == .controlled and !session.allow_finish and
        !session.compact_abort_requested)
        session.wait();
    const aborted = session.compact_abort_requested;
    session.compacting = false;
    session.broadcast();
    session.unlock();

    if (forced_status) |status| {
        diagnostic(out_error);
        return status;
    }
    const result = out_result.?;
    result.* = std.mem.zeroes(wire.CompactResultV1);
    result.struct_size = if (malformed) 0 else @sizeOf(wire.CompactResultV1);
    result.outcome_code = if (aborted)
        wire.COMPACT_ABORTED
    else
        forced_outcome orelse wire.COMPACT_COMPACTED;
    result.before_context_tokens = 100;
    result.after_context_tokens = 40;
    result.input_tokens = 5;
    result.output_tokens = 2;
    return wire.STATUS_OK;
}

pub fn sessionAbortCompact(
    handle: ?*wire.SessionHandle,
    operation_id: u64,
    out_error: ?*wire.OwnedBytesV1,
) callconv(.c) u32 {
    if (out_error) |out| out.* = .{ .ptr = null, .len = 0 };
    const session: *FakeSession = @ptrCast(@alignCast(handle orelse {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    }));
    fake_core.lock();
    fake_core.compact_abort_calls += 1;
    const forced_status = fake_core.forced_compact_abort_status;
    fake_core.forced_compact_abort_status = null;
    fake_core.unlock();
    if (forced_status) |status| {
        diagnostic(out_error);
        return status;
    }
    session.lock();
    defer session.unlock();
    if (session.compacting and operation_id == session.compact_id) {
        session.compact_abort_requested = true;
        session.broadcast();
        return wire.STATUS_OK;
    }
    diagnostic(out_error);
    if (operation_id < session.compact_id) return wire.STATUS_STALE_COMPACT;
    if (!session.compacting and operation_id == session.compact_id)
        return wire.STATUS_TOO_LATE;
    return wire.STATUS_INVALID_ARGUMENT;
}

pub fn sessionRunInput(
    handle: ?*wire.SessionHandle,
    run_id: u64,
    input: ?*const wire.RunInputV1,
    options: ?*const wire.RunOptionsV1,
    out_result: ?*wire.RunResultV1,
    out_error: ?*wire.OwnedBytesV1,
) callconv(.c) u32 {
    if (out_error) |out| out.* = .{ .ptr = null, .len = 0 };
    const typed_input = input orelse {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    };
    if (typed_input.struct_size != @sizeOf(wire.RunInputV1)) {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    }
    const session: *FakeSession = @ptrCast(@alignCast(handle orelse {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    }));
    const run_options = options orelse return wire.STATUS_INVALID_ARGUMENT;
    std.debug.assert(run_options.time_context_code == wire.TIME_CONTEXT_SYSTEM);
    std.debug.assert(run_options.utc_offset_minutes == 0);
    if (run_options.struct_size != @sizeOf(wire.RunOptionsV1) or
        run_options.context_blocks != null or run_options.context_block_count != 0)
        return wire.STATUS_INVALID_ARGUMENT;
    switch (typed_input.kind_code) {
        wire.RUN_INPUT_TEXT => {
            fake_core.lock();
            defer fake_core.unlock();
            if (fake_core.expected_run_text) |expected|
                fake_core.run_text_matches = std.mem.eql(u8, expected, sdk.borrowedBytes(typed_input.text) catch return wire.STATUS_INVALID_ARGUMENT);
        },
        wire.RUN_INPUT_MULTIMODAL => {
            const parts = (typed_input.parts orelse return wire.STATUS_INVALID_ARGUMENT)[0..@intCast(typed_input.part_count)];
            fake_core.lock();
            defer fake_core.unlock();
            fake_core.multimodal_part_count = parts.len;
            fake_core.multimodal_prompt_bytes = 0;
            fake_core.multimodal_reference_count = 0;
            for (parts) |part| {
                const bytes = sdk.borrowedBytes(part.text) catch return wire.STATUS_INVALID_ARGUMENT;
                const data = sdk.borrowedBytes(part.data) catch return wire.STATUS_INVALID_ARGUMENT;
                fake_core.multimodal_prompt_bytes += bytes.len + data.len;
                if (std.mem.indexOf(u8, bytes, "file_path=") != null) fake_core.multimodal_reference_count += 1;
            }
            if (fake_core.expected_multimodal_text) |expected| {
                fake_core.multimodal_text_matches = parts.len != 0 and std.mem.eql(u8, expected, sdk.borrowedBytes(parts[0].text) catch return wire.STATUS_INVALID_ARGUMENT);
            }
            if (fake_core.expected_multimodal_parts) |expected| {
                var matches = parts.len == expected.len and
                    typed_input.text.len == 0 and typed_input.skill_id.len == 0 and
                    typed_input.catalog_revision.len == 0 and typed_input.arguments_json.len == 0;
                if (matches) for (parts, expected) |actual, wanted| {
                    matches = matches and actual.struct_size == @sizeOf(wire.RunInputPartV1) and
                        actual.kind_code == wanted.kind_code and
                        std.mem.allEqual(u64, &actual.reserved, 0) and
                        std.mem.eql(u8, sdk.borrowedBytes(actual.text) catch return wire.STATUS_INVALID_ARGUMENT, sdk.borrowedBytes(wanted.text) catch unreachable) and
                        std.mem.eql(u8, sdk.borrowedBytes(actual.media_type) catch return wire.STATUS_INVALID_ARGUMENT, sdk.borrowedBytes(wanted.media_type) catch unreachable) and
                        std.mem.eql(u8, sdk.borrowedBytes(actual.data) catch return wire.STATUS_INVALID_ARGUMENT, sdk.borrowedBytes(wanted.data) catch unreachable);
                };
                fake_core.multimodal_input_matches = matches;
            }
        },
        wire.RUN_INPUT_SKILL => {
            const skill_id = sdk.borrowedBytes(typed_input.skill_id) catch {
                diagnostic(out_error);
                return wire.STATUS_INVALID_ARGUMENT;
            };
            const revision = sdk.borrowedBytes(typed_input.catalog_revision) catch {
                diagnostic(out_error);
                return wire.STATUS_INVALID_ARGUMENT;
            };
            const arguments = sdk.borrowedBytes(typed_input.arguments_json) catch {
                diagnostic(out_error);
                return wire.STATUS_INVALID_ARGUMENT;
            };
            session.lock();
            const has_catalog = session.catalog != null;
            session.unlock();
            if (!has_catalog) {
                diagnostic(out_error);
                return wire.STATUS_SKILL_CATALOG_INVALID;
            }
            fake_core.lock();
            fake_core.skill_run_seen = true;
            fake_core.skill_input_matches =
                std.mem.eql(u8, skill_id, fixture_skill_id) and
                std.mem.eql(u8, revision, fixture_catalog_revision) and
                std.mem.eql(
                    u8,
                    arguments,
                    "{\"values\":[\"src/main.zig\",\"correctness\"]}",
                );
            fake_core.unlock();
        },
        else => {
            diagnostic(out_error);
            return wire.STATUS_INVALID_ARGUMENT;
        },
    }
    fake_core.lock();
    fake_core.run_calls += 1;
    const rejected_credential = fake_core.rejected_credential_digest;
    fake_core.unlock();
    session.lock();
    if (session.compacting) {
        session.unlock();
        diagnostic(out_error);
        return wire.STATUS_BUSY;
    }
    session.running = true;
    session.run_id = run_id;
    session.input_accepted = 0;
    session.input_adopted = 0;
    const plan = session.plan;
    const credential_rejected = if (rejected_credential) |digest|
        std.mem.eql(u8, &digest, &session.credential_digest)
    else
        false;
    const permission_generation = session.policy_generation;
    session.broadcast();
    session.unlock();

    if (fake_core.input_enabled) {
        var buffer: [256]u8 = undefined;
        const json = std.fmt.bufPrint(
            &buffer,
            "{{\"run_state\":{{\"run_id\":{d},\"transition_seq\":1,\"phase\":\"starting\",\"turn\":0,\"tool_calls\":0,\"in_flight_tools\":[]}}}}",
            .{run_id},
        ) catch unreachable;
        if (!emitInputEvent(session, handle, run_id, json)) return wire.STATUS_CALLBACK_FAILED;
    }

    const model_failure = credential_rejected or modelErrorPlan(plan);
    if (model_failure) {
        var accepted = fake_core.input_enabled or emitModelRunState(session, handle, run_id, "starting", 1);
        if (accepted) accepted = emitModelRunState(session, handle, run_id, "finalizing", 2);
        if (accepted and plan == .model_error_after_terminal)
            accepted = emitModelRunState(session, handle, run_id, "failed", 3);
        if (accepted and plan != .model_error_missing)
            accepted = emitModelError(session, handle, run_id, plan);
        if (accepted and plan == .model_error_duplicate)
            accepted = emitModelError(session, handle, run_id, plan);
        if (accepted and plan == .model_error_identity_failed)
            accepted = emitInputEvent(session, handle, run_id + 1, "{\"text_chunk\":\"wrong Run\"}");
        if (accepted and plan == .model_error_callback_failed)
            accepted = emitInputEvent(session, handle, run_id, "{\"text_chunk\":\"fills the bounded pump\"}");
        if (!accepted) {
            session.lock();
            session.running = false;
            session.broadcast();
            session.unlock();
            diagnostic(out_error);
            return wire.STATUS_CALLBACK_FAILED;
        }
        if (plan == .model_error_controlled) {
            fake_core.lock();
            const signal = fake_core.callback_signal;
            fake_core.unlock();
            if (signal) |value| _ = CallbackSignal.notify(value);
        }
    }

    if (plan == .ui_callback_outlives_run or plan == .model_error_callback_outlives_run) {
        fake_core.lock();
        const signal = fake_core.callback_signal;
        fake_core.unlock();
        const active_signal = signal orelse {
            diagnostic(out_error);
            return wire.STATUS_CALLBACK_FAILED;
        };
        active_signal.arm();
        const callback_thread = std.Thread.spawn(
            .{},
            invokeDetachedUiCallback,
            .{session},
        ) catch {
            diagnostic(out_error);
            return wire.STATUS_OUT_OF_MEMORY;
        };
        callback_thread.detach();
        active_signal.waitUntilEntered();
    }

    if (plan == .event_callback or plan == .file_changes_callback or
        plan == .unknown_event_callback or
        plan == .malformed_event_callback or plan == .invalid_utf8_event_callback or
        plan == .wrong_event_session_handle or
        plan == .wrong_event_run_id or plan == .same_run_session_id_mismatch or
        plan == .concurrent_session_id_mismatch or plan == .cross_run_session_id_mismatch)
    {
        const callback = session.callbacks.on_event orelse {
            diagnostic(out_error);
            return wire.STATUS_CALLBACK_FAILED;
        };
        var event_buffer = "{\"text_chunk\":\"typed event\"}".*;
        const invalid_utf8_event =
            "{\"tool_result\":{\"id\":\"tool-1\",\"name\":\"Bash\",\"input\":\"{}\",\"content\":[203],\"is_error\":false,\"elapsed_ms\":1}}";
        const file_changes_event =
            "{\"file_changes\":{\"id\":\"tool-1\",\"name\":\"Edit\",\"changes\":[{\"locator\":{\"workspace_path\":\"src/main.zig\"},\"kind\":\"modified\",\"status\":\"applied\",\"tool\":\"Edit\",\"tool_use_id\":\"tool-1\",\"agent_depth\":0,\"before_bytes\":1,\"after_bytes\":2,\"unified_diff\":\"-a\\n+b\\n\",\"diff_complete\":true}],\"overflow\":false,\"lost\":false}}";
        const event_json: []const u8 = switch (plan) {
            .event_callback => &event_buffer,
            .file_changes_callback => file_changes_event,
            .unknown_event_callback => "{\"future_observation\":{\"answer\":42}}",
            .malformed_event_callback => "{}",
            .invalid_utf8_event_callback => invalid_utf8_event,
            else => &event_buffer,
        };
        var run = std.mem.zeroes(wire.RunContextV1);
        run.struct_size = @sizeOf(wire.RunContextV1);
        run.session = if (plan == .wrong_event_session_handle)
            @ptrCast(&fake_core.runtime)
        else
            handle;
        run.run_id = if (plan == .wrong_event_run_id) run_id + 1 else run_id;
        run.session_id = sdk.bytesView(session.session_id[0..session.session_id_len]);
        if (plan == .cross_run_session_id_mismatch and run_id > 1)
            run.session_id = sdk.bytesView("changed-cross-run-id");

        var callback_status: u32 = wire.EVENT_CONTINUE;
        if (plan == .concurrent_session_id_mismatch) {
            callback_status = invokeConcurrentIdentityCallbacks(
                callback,
                session.callbacks.ctx,
                &run,
                event_json,
            ) catch wire.EVENT_FATAL;
        } else {
            callback_status = callback(session.callbacks.ctx, &run, sdk.bytesView(event_json));
            if (callback_status == wire.EVENT_CONTINUE and plan == .same_run_session_id_mismatch) {
                run.session_id = sdk.bytesView("changed-same-run-id");
                callback_status = callback(session.callbacks.ctx, &run, sdk.bytesView(event_json));
            }
        }
        @memset(&event_buffer, 'x');
        if (callback_status != wire.EVENT_CONTINUE) {
            session.lock();
            session.running = false;
            session.broadcast();
            session.unlock();
            diagnostic(out_error);
            return wire.STATUS_CALLBACK_FAILED;
        }
    }

    const ui_request_count: usize = if (plan == .ui_wait_repeated) 2 else 1;
    for (0..ui_request_count) |_| {
        if ((plan == .ui_wait or plan == .ui_wait_twice or plan == .ui_wait_repeated) and
            !(plan == .ui_wait_twice and session.permission_session_granted) or
            plan == .malformed_ui_callback or
            plan == .wrong_ui_request_run_id or plan == .wrong_ui_request_session_id or
            plan == .ask_question)
        {
            var response = wire.OwnedBytesV1{ .ptr = null, .len = 0 };
            const callback = session.callbacks.on_ui_request orelse {
                diagnostic(out_error);
                return wire.STATUS_CALLBACK_FAILED;
            };
            var request_storage: [2048]u8 = undefined;
            const request_json = if (plan == .ask_question)
                "{\"ask_question\":[{\"question\":\"Choose?\",\"header\":\"Choice\",\"multi\":false,\"options\":[]}]}"
            else if (plan != .malformed_ui_callback)
                permissionRequestJson(
                    &request_storage,
                    if (plan == .wrong_ui_request_session_id)
                        "999999999999999999999999"
                    else
                        session.session_id[0..session.session_id_len],
                    if (plan == .wrong_ui_request_run_id) run_id + 1 else run_id,
                    permission_generation,
                ) catch {
                    diagnostic(out_error);
                    return wire.STATUS_OUT_OF_MEMORY;
                }
            else
                "{}";
            const callback_status = callback(
                session.callbacks.ctx,
                &wire.RunContextV1{
                    .struct_size = @sizeOf(wire.RunContextV1),
                    .reserved0 = 0,
                    .session = handle,
                    .run_id = run_id,
                    .session_id = sdk.bytesView(session.session_id[0..session.session_id_len]),
                    .reserved = [_]u64{0} ** 2,
                },
                sdk.bytesView(request_json),
                &response,
            );
            fake_core.lock();
            if (callback_status == wire.UI_ANSWERED)
                fake_core.ui_answered_callbacks += 1;
            if (callback_status == wire.UI_ANSWERED)
                fake_core.permission_callback_count += 1;
            if (callback_status == wire.UI_UNAVAILABLE)
                fake_core.ui_unavailable_callbacks += 1;
            if (callback_status == wire.UI_FATAL)
                fake_core.ui_fatal_callbacks += 1;
            fake_core.unlock();
            if (callback_status == wire.UI_ANSWERED) {
                const response_ptr = response.ptr orelse {
                    diagnostic(out_error);
                    return wire.STATUS_CALLBACK_FAILED;
                };
                const response_len = std.math.cast(usize, response.len) orelse {
                    diagnostic(out_error);
                    return wire.STATUS_CALLBACK_FAILED;
                };
                const encoded_response = response_ptr[0..response_len];
                var decoded_response = sdk.protocol.decodeUiResponse(
                    std.testing.allocator,
                    encoded_response,
                ) catch {
                    diagnostic(out_error);
                    return wire.STATUS_CALLBACK_FAILED;
                };
                defer decoded_response.deinit();
                var provenance_failed = false;
                const response_valid = switch (decoded_response.value) {
                    .permission => |permission| blk: {
                        const valid = std.mem.eql(
                            u8,
                            permission.request_id,
                            "1111111111111111111111111111111111111111111111111111111111111111",
                        ) and permission.policy_generation == permission_generation and
                            switch (permission.permission) {
                                .allow_session, .deny_session => if (permission.rule_id) |rule_id|
                                    std.mem.eql(
                                        u8,
                                        rule_id,
                                        "2222222222222222222222222222222222222222222222222222222222222222",
                                    )
                                else
                                    false,
                                .allow_once, .deny_once => permission.rule_id == null,
                            };
                        if (valid and plan == .ui_wait_twice) switch (permission.permission) {
                            .allow_session, .deny_session => session.permission_session_granted = true,
                            .allow_once, .deny_once => {},
                        };
                        // Official Core emits provenance after every answered
                        // permission callback. Exercise the same Agent event
                        // stream, including the current policy generation.
                        if (valid and !emitPermissionProvenance(session, handle, run_id, request_json, permission))
                            provenance_failed = true;
                        break :blk valid;
                    },
                    .answers => false,
                };
                fake_core.lock();
                fake_core.permission_response_valid = response_valid;
                fake_core.unlock();
                const release = session.callbacks.release_response orelse {
                    diagnostic(out_error);
                    return wire.STATUS_CALLBACK_FAILED;
                };
                release(session.callbacks.ctx, &response);
                if (response.ptr != null or response.len != 0) {
                    diagnostic(out_error);
                    return wire.STATUS_CALLBACK_FAILED;
                }
                if (provenance_failed) {
                    session.lock();
                    session.running = false;
                    session.broadcast();
                    session.unlock();
                    diagnostic(out_error);
                    return wire.STATUS_CALLBACK_FAILED;
                }
            } else if (callback_status == wire.UI_FATAL) {
                session.lock();
                session.running = false;
                session.broadcast();
                session.unlock();
                diagnostic(out_error);
                return wire.STATUS_CALLBACK_FAILED;
            }
        }
    }
    session.lock();
    while ((plan == .controlled or plan == .controlled_callback_failed or plan == .ui_wait or plan == .ui_wait_twice or plan == .ui_wait_repeated or plan == .model_error_controlled) and
        !session.allow_finish and !session.abort_requested)
        session.wait();
    const aborted = session.abort_requested;
    session.running = false;
    session.broadcast();
    session.unlock();

    if (plan == .callback_failed or plan == .controlled_callback_failed) {
        diagnostic(out_error);
        return wire.STATUS_CALLBACK_FAILED;
    }
    if (plan == .resource_limit) {
        diagnostic(out_error);
        return wire.STATUS_RESOURCE_LIMIT;
    }
    if (plan == .checkpoint_budget_required or
        plan == .checkpoint_budget_required_invalid_result)
    {
        if (out_result) |result| {
            result.* = std.mem.zeroes(wire.RunResultV1);
            result.struct_size = @sizeOf(wire.RunResultV1);
            result.checkpoint_outcome_code = if (plan == .checkpoint_budget_required)
                wire.RUN_CHECKPOINT_BUDGET_REQUIRED
            else
                wire.RUN_CHECKPOINT_NONE;
            result.durable_usage_bytes = 4096;
            result.required_checkpoint_bytes = 8192;
        }
        diagnostic(out_error);
        return wire.STATUS_CHECKPOINT_BUDGET_REQUIRED;
    }
    if (plan == .stale_catalog) {
        diagnostic(out_error);
        return wire.STATUS_STALE_CATALOG;
    }
    if (plan == .skill_not_found) {
        diagnostic(out_error);
        return wire.STATUS_SKILL_NOT_FOUND;
    }
    if (plan == .invalid_skill_arguments) {
        diagnostic(out_error);
        return wire.STATUS_INVALID_SKILL_ARGUMENTS;
    }
    if (plan == .skill_policy_violation) {
        diagnostic(out_error);
        return wire.STATUS_SKILL_POLICY_VIOLATION;
    }
    if (plan == .skill_unavailable) {
        diagnostic(out_error);
        return wire.STATUS_SKILL_UNAVAILABLE;
    }
    if (plan == .unknown_status) {
        if (out_result) |result| {
            result.* = std.mem.zeroes(wire.RunResultV1);
            result.struct_size = @sizeOf(wire.RunResultV1);
            result.stop_reason_code = wire.STOP_END_TURN;
        }
        diagnostic(out_error);
        return 42;
    }
    if (plan == .stale_compact_status) {
        diagnostic(out_error);
        return wire.STATUS_STALE_COMPACT;
    }
    if (plan == .image_input_unsupported_status or plan == .image_input_capability_unknown_status) {
        if (out_result) |result| {
            // Other result fields remain undefined on this refusal; revision
            // 24 defines only active-input counts on every return.
            @memset(std.mem.asBytes(result), 0xA5);
            result.input_accepted_count = 0;
            result.input_adopted_count = 0;
        }
        diagnostic(out_error);
        return if (plan == .image_input_unsupported_status) wire.STATUS_IMAGE_INPUT_UNSUPPORTED else wire.STATUS_IMAGE_INPUT_CAPABILITY_UNKNOWN;
    }
    if (out_result) |result| {
        result.* = std.mem.zeroes(wire.RunResultV1);
        result.struct_size = if (plan == .invalid_result_layout) 0 else @sizeOf(wire.RunResultV1);
        result.stop_reason_code = if (aborted)
            wire.STOP_ABORTED
        else if (model_failure and plan != .model_error_wrong_stop)
            wire.STOP_API_ERROR
        else switch (plan) {
            .unknown_stop_result => 42,
            .max_turns => wire.STOP_MAX_TURNS,
            .tool_loop => wire.STOP_TOOL_LOOP,
            .checkpoint_budget_exhausted => wire.STOP_CHECKPOINT_BUDGET_EXHAUSTED,
            .checkpoint_resource_limit => wire.STOP_CHECKPOINT_RESOURCE_LIMIT,
            else => wire.STOP_END_TURN,
        };
        result.checkpoint_outcome_code = switch (plan) {
            .checkpoint_budget_exhausted => wire.RUN_CHECKPOINT_BUDGET_EXHAUSTED,
            .checkpoint_resource_limit => wire.RUN_CHECKPOINT_RESOURCE_LIMIT,
            .invalid_checkpoint_outcome => 42,
            .mismatched_checkpoint_outcome => wire.RUN_CHECKPOINT_RESOURCE_LIMIT,
            else => wire.RUN_CHECKPOINT_NONE,
        };
        if (plan == .invalid_result_flags) result.result_flags = 1 << 31;
        result.input_accepted_count = session.input_accepted;
        result.input_adopted_count = session.input_adopted;
        if (plan == .unexpected_input_receipt or plan == .unexpected_input_receipt_failure or plan == .model_error_counts_failed)
            result.input_accepted_count = 1;
        if (plan == .model_error_core_error) result.stop_reason_code = 0xFFFFFFFF;
    }
    if (plan == .model_error_core_error) {
        diagnostic(out_error);
        return wire.STATUS_CORE_ERROR;
    }
    if (model_failure and !emitModelRunState(session, handle, run_id, if (plan == .model_error_wrong_stop) "completed" else "failed", 3)) {
        diagnostic(out_error);
        return wire.STATUS_CALLBACK_FAILED;
    }
    if (plan == .unexpected_input_receipt_failure) return wire.STATUS_RESOURCE_LIMIT;
    if (fake_core.forced_input_run_status) |status| return status;
    return wire.STATUS_OK;
}

fn modelErrorPlan(plan: Plan) bool {
    return switch (plan) {
        .model_error,
        .model_error_missing,
        .model_error_duplicate,
        .model_error_wrong_id,
        .model_error_after_terminal,
        .model_error_wrong_stop,
        .model_error_oversized,
        .model_error_callback_failed,
        .model_error_core_error,
        .model_error_identity_failed,
        .model_error_counts_failed,
        .model_error_callback_outlives_run,
        .model_error_controlled,
        => true,
        else => false,
    };
}

fn emitModelRunState(session: *FakeSession, handle: ?*wire.SessionHandle, run_id: u64, phase: []const u8, sequence: u64) bool {
    var buffer: [256]u8 = undefined;
    const json = std.fmt.bufPrint(&buffer, "{{\"run_state\":{{\"run_id\":{d},\"transition_seq\":{d},\"phase\":\"{s}\",\"turn\":{d},\"tool_calls\":0,\"in_flight_tools\":[]}}}}", .{ run_id, sequence, phase, @as(u32, if (std.mem.eql(u8, phase, "starting")) 0 else 1) }) catch unreachable;
    return emitInputEvent(session, handle, run_id, json);
}

fn emitModelError(session: *FakeSession, handle: ?*wire.SessionHandle, run_id: u64, plan: Plan) bool {
    var buffer: [2048]u8 = undefined;
    const oversized = [_]u8{'x'} ** (lifecycle.ModelError.limits.message_bytes + 1);
    const message = if (plan == .model_error_oversized) &oversized else "fixture provider rejected credential";
    const json = std.fmt.bufPrint(&buffer, "{{\"model_error\":{{\"run_id\":{d},\"category\":\"authentication\",\"code\":\"fixture_auth_code\",\"type\":\"authentication_error\",\"message\":\"{s}\",\"http_status\":401,\"request_id\":\"fixture_request\",\"retry\":\"not_retryable\",\"attempts\":1,\"truncated\":false}}}}", .{ if (plan == .model_error_wrong_id) run_id + 1 else run_id, message }) catch unreachable;
    const accepted = emitInputEvent(session, handle, run_id, json);
    @memset(&buffer, 'x');
    return accepted;
}

pub fn sessionAbort(
    handle: ?*wire.SessionHandle,
    run_id: u64,
    reason: u32,
    out_error: ?*wire.OwnedBytesV1,
) callconv(.c) u32 {
    if (out_error) |out| out.* = .{ .ptr = null, .len = 0 };
    const session: *FakeSession = @ptrCast(@alignCast(handle orelse {
        diagnostic(out_error);
        return wire.STATUS_INVALID_ARGUMENT;
    }));
    fake_core.lock();
    fake_core.abort_calls += 1;
    fake_core.last_abort_reason = reason;
    const forced_status = fake_core.forced_abort_status;
    fake_core.forced_abort_status = null;
    fake_core.unlock();
    if (forced_status) |status| {
        diagnostic(out_error);
        return status;
    }
    session.lock();
    defer session.unlock();
    if (!session.running) {
        diagnostic(out_error);
        return wire.STATUS_TOO_LATE;
    }
    if (session.run_id != run_id) {
        diagnostic(out_error);
        return wire.STATUS_STALE_RUN;
    }
    session.abort_requested = true;
    session.broadcast();
    return wire.STATUS_OK;
}

pub fn bufferRelease(out: ?*wire.OwnedBytesV1) callconv(.c) void {
    if (out) |value| value.* = .{ .ptr = null, .len = 0 };
    fake_core.lock();
    fake_core.buffer_releases += 1;
    fake_core.unlock();
}

fn fakeCompletionPerform(
    context: ?*anyopaque,
    _: lifecycle.CompletionHttpRequest,
    cancellation: *const lifecycle.CompletionCancellation,
    response_buffer: []u8,
) lifecycle.CompletionTransportError!lifecycle.CompletionTransportResponse {
    if (cancellation.isRequested()) return error.Cancelled;
    const core: *FakeCore = @ptrCast(@alignCast(context orelse
        return error.Unexpected));
    core.lock();
    defer core.unlock();
    if (!core.completion_enabled) return error.Unexpected;
    core.completion_requests += 1;
    if (core.completion_controlled) {
        core.completion_controlled = false;
        core.completion_entered = true;
        core.completion_condition.broadcast(std.testing.io);
        while (!core.allow_completion)
            core.completion_condition.waitUncancelable(
                std.testing.io,
                &core.mutex,
            );
        if (cancellation.isRequested()) return error.Cancelled;
    }
    if (core.completion_response_len > response_buffer.len)
        return error.ResponseTooLarge;
    @memcpy(
        response_buffer[0..core.completion_response_len],
        core.completion_response[0..core.completion_response_len],
    );
    return .{
        .status = 200,
        .body = response_buffer[0..core.completion_response_len],
    };
}

fn fakeCompletionTransport() lifecycle.CompletionTransport {
    return .{
        .context = &fake_core,
        .perform_fn = fakeCompletionPerform,
    };
}

const fake_runtime_api = wire.RuntimeApiV1{
    .struct_size = @sizeOf(wire.RuntimeApiV1),
    .reserved0 = 0,
    .create = runtimeCreate,
    .destroy = runtimeDestroy,
};

const fake_session_api = wire.SessionApiV1{
    .struct_size = @sizeOf(wire.SessionApiV1),
    .reserved0 = 0,
    .create = sessionCreate,
    .destroy = sessionDestroy,
    .run_input = sessionRunInput,
    .abort = sessionAbort,
    .submit_input = sessionSubmitInput,
    .update_credential = sessionUpdateCredential,
};

fn sessionUpdateCredential(handle: ?*wire.SessionHandle, value: wire.BytesViewV1, out_error: ?*wire.OwnedBytesV1) callconv(.c) u32 {
    if (out_error) |out| out.* = .{ .ptr = null, .len = 0 };
    fake_core.lock();
    fake_core.credential_updates += 1;
    fake_core.credential_update_entered = true;
    fake_core.credential_update_condition.broadcast(std.testing.io);
    while (fake_core.hold_credential_update and !fake_core.allow_credential_update)
        fake_core.credential_update_condition.waitUncancelable(std.testing.io, &fake_core.mutex);
    const forced = fake_core.forced_update_credential_status;
    fake_core.forced_update_credential_status = null;
    fake_core.unlock();
    if (forced) |code| return code;
    const session: *FakeSession = @ptrCast(@alignCast(handle orelse return wire.STATUS_INVALID_ARGUMENT));
    const credential = sdk.borrowedBytes(value) catch return wire.STATUS_INVALID_ARGUMENT;
    session.lock();
    defer session.unlock();
    if (!session.in_use or session.destroyed) return wire.STATUS_INVALID_STATE;
    std.crypto.hash.sha2.Sha256.hash(credential, &session.credential_digest, .{});
    return wire.STATUS_OK;
}

fn sessionSubmitInput(handle: ?*wire.SessionHandle, run_id: u64, input: ?*const wire.SubmittedInputV1, receipt: ?*wire.InputReceiptV1, diagnostic_out: ?*wire.OwnedBytesV1) callconv(.c) u32 {
    if (diagnostic_out) |out| out.* = .{ .ptr = null, .len = 0 };
    if (fake_core.forced_input_status) |status| return status;
    const session: *FakeSession = @ptrCast(@alignCast(handle.?));
    session.lock();
    if (!session.running or session.run_id != run_id or session.abort_requested) {
        session.unlock();
        return wire.STATUS_TOO_LATE;
    }
    session.input_accepted += 1;
    const sequence = session.input_accepted;
    const adopt = fake_core.adopt_input_before_receipt;
    if (adopt) session.input_adopted = sequence;
    session.unlock();
    if (fake_core.input_signal) |signal| {
        _ = CallbackSignal.notify(signal);
        signal.waitUntilFinished();
    }
    if (adopt and !fake_core.omit_input_adopted_event) {
        var buffer: [192]u8 = undefined;
        const json = std.fmt.bufPrint(&buffer, "{{\"input_adopted\":{{\"input_id\":{d},\"sequence\":{d},\"turn\":2}}}}", .{ input.?.input_id, sequence }) catch unreachable;
        if (!emitInputEvent(session, handle, run_id, json)) return wire.STATUS_CALLBACK_FAILED;
    }
    receipt.?.* = .{ .struct_size = @sizeOf(wire.InputReceiptV1), .sequence = sequence, .reserved = @splat(0) };
    return wire.STATUS_OK;
}

fn emitInputEvent(session: *FakeSession, handle: ?*wire.SessionHandle, run_id: u64, json: []const u8) bool {
    const callback = session.callbacks.on_event orelse return false;
    const context: wire.RunContextV1 = .{
        .struct_size = @sizeOf(wire.RunContextV1),
        .reserved0 = 0,
        .session = handle,
        .run_id = run_id,
        .session_id = sdk.bytesView(session.session_id[0..session.session_id_len]),
        .reserved = @splat(0),
    };
    return callback(session.callbacks.ctx, &context, sdk.bytesView(json)) == wire.EVENT_CONTINUE;
}

fn unopenedSessionJson(_: ?*wire.SessionHandle, _: ?*wire.OwnedBytesV1, _: ?*wire.OwnedBytesV1) callconv(.c) u32 {
    @panic("MetaWork must not call Goal or Team entries");
}

fn unopenedGoalSet(_: ?*wire.SessionHandle, _: ?*const wire.GoalSetV1, _: ?*wire.OwnedBytesV1) callconv(.c) u32 {
    @panic("MetaWork must not set a Goal");
}

fn unopenedGoalUpdate(_: ?*wire.SessionHandle, _: ?*const wire.GoalUpdateV1, _: ?*wire.OwnedBytesV1) callconv(.c) u32 {
    @panic("MetaWork must not update a Goal");
}

fn unopenedGoalClear(_: ?*wire.SessionHandle, _: ?*wire.OwnedBytesV1) callconv(.c) u32 {
    @panic("MetaWork must not clear a Goal");
}

const fake_goal_api = wire.GoalApiV1{
    .struct_size = @sizeOf(wire.GoalApiV1),
    .reserved0 = 0,
    .get = unopenedSessionJson,
    .set = unopenedGoalSet,
    .update = unopenedGoalUpdate,
    .clear = unopenedGoalClear,
};

const fake_team_api = wire.TeamApiV1{
    .struct_size = @sizeOf(wire.TeamApiV1),
    .reserved0 = 0,
    .describe = unopenedSessionJson,
    .poll = unopenedSessionJson,
};

fn sessionSetPromptProfile(handle: ?*wire.SessionHandle, profile: ?*const wire.PromptProfileV1, out_diagnostic: ?*wire.OwnedBytesV1) callconv(.c) u32 {
    if (out_diagnostic) |output| output.* = std.mem.zeroes(wire.OwnedBytesV1);
    const session: *FakeSession = @ptrCast(@alignCast(handle orelse return wire.STATUS_INVALID_ARGUMENT));
    const replacement = FakePromptProfile.copy(profile) orelse return wire.STATUS_INVALID_ARGUMENT;
    fake_core.lock();
    fake_core.prompt_updates += 1;
    if (fake_core.prompt_controlled) {
        fake_core.prompt_controlled = false;
        fake_core.prompt_entered = true;
        fake_core.checkpoint_condition.broadcast(std.testing.io);
        while (!fake_core.allow_prompt)
            fake_core.checkpoint_condition.waitUncancelable(std.testing.io, &fake_core.mutex);
    }
    const forced = fake_core.forced_prompt_status;
    fake_core.forced_prompt_status = null;
    const malformed = fake_core.malformed_prompt_diagnostic;
    fake_core.malformed_prompt_diagnostic = false;
    fake_core.unlock();
    if (malformed) {
        if (out_diagnostic) |out| out.* = .{ .ptr = null, .len = 1 };
        return wire.STATUS_OK;
    }
    if (forced) |code| return code;
    session.lock();
    defer session.unlock();
    if (!session.in_use or session.destroyed) return wire.STATUS_INVALID_STATE;
    if (session.running or session.compacting) return wire.STATUS_BUSY;
    if (!std.meta.eql(session.prompt_profile, replacement)) {
        session.prompt_profile = replacement;
        fake_core.lock();
        fake_core.prompt_changes += 1;
        fake_core.unlock();
    }
    return wire.STATUS_OK;
}

fn permissionModeName(code: u32) []const u8 {
    const mode: sdk.protocol.PermissionMode = switch (code) {
        wire.PERMISSION_DEFAULT => .default,
        wire.PERMISSION_ACCEPT_EDITS => .accept_edits,
        wire.PERMISSION_AUTO => .auto,
        wire.PERMISSION_DONT_ASK => .dont_ask,
        wire.PERMISSION_FULL_ACCESS => .full_access,
        else => unreachable,
    };
    return @tagName(mode);
}

pub fn sessionUpdatePermissionMode(handle: ?*wire.SessionHandle, code: u32, out_error: ?*wire.OwnedBytesV1) callconv(.c) u32 {
    if (out_error) |out| out.* = .{ .ptr = null, .len = 0 };
    fake_core.lock();
    fake_core.permission_mode_updates += 1;
    fake_core.unlock();
    const session: *FakeSession = @ptrCast(@alignCast(handle orelse return wire.STATUS_INVALID_ARGUMENT));
    switch (code) {
        wire.PERMISSION_DEFAULT, wire.PERMISSION_ACCEPT_EDITS, wire.PERMISSION_AUTO, wire.PERMISSION_DONT_ASK, wire.PERMISSION_FULL_ACCESS => {},
        else => return wire.STATUS_INVALID_ARGUMENT,
    }
    session.lock();
    defer session.unlock();
    if (!session.in_use or session.destroyed) return wire.STATUS_INVALID_STATE;
    if (session.running or session.compacting) return wire.STATUS_BUSY;
    if (session.forced_permission_mode_status) |status| {
        session.forced_permission_mode_status = null;
        return status;
    }
    if (session.permission_mode_code != code) {
        session.permission_mode_code = code;
        session.policy_generation += 1;
        session.permission_session_granted = false;
    }
    return wire.STATUS_OK;
}

const fake_session_control_api = wire.SessionControlApiV1{
    .struct_size = @sizeOf(wire.SessionControlApiV1),
    .reserved0 = 0,
    .restore = sessionRestore,
    .describe = sessionDescribe,
    .set_model = sessionSetModel,
    .update_permission_rules = sessionUpdatePermissionRules,
    .compact = sessionCompact,
    .abort_compact = sessionAbortCompact,
    .export_checkpoint = sessionExportCheckpoint,
    .set_prompt_profile = sessionSetPromptProfile,
    .update_permission_mode = sessionUpdatePermissionMode,
};

const fake_skill_api = wire.SkillApiV1{
    .struct_size = @sizeOf(wire.SkillApiV1),
    .reserved0 = 0,
    .resolve_catalog = runtimeQuerySkillCatalog,
    .release_catalog = skillCatalogRelease,
    .bind_policy = sessionBindSkillPolicy,
};

const fake_mcp_api = wire.McpApiV1{
    .struct_size = @sizeOf(wire.McpApiV1),
    .reserved0 = 0,
    .apply_configuration = runtimeApplyMcpConfiguration,
    .refresh = runtimeRefreshMcp,
    .describe = runtimeDescribeMcp,
    .update_selection = sessionUpdateMcp,
};

pub const fake_api = wire.ApiV1{
    .struct_size = @sizeOf(wire.ApiV1),
    .abi_version = wire.ABI_VERSION_V1,
    .abi_revision = wire.ABI_REVISION,
    .reserved0 = 0,
    .buffer_release = bufferRelease,
    .runtime = &fake_runtime_api,
    .session = &fake_session_api,
    .session_control = &fake_session_control_api,
    .skill = &fake_skill_api,
    .mcp = &fake_mcp_api,
    .goal = &fake_goal_api,
    .team = &fake_team_api,
};

pub fn createCompletion(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    binding: lifecycle.ModelBinding,
) anyerror!*lifecycle.Completion {
    return lifecycle.Completion.init(
        allocator,
        fakeCompletionTransport(),
        binding,
    );
}

fn validSkillPolicy(policy: *const wire.SkillPolicyV1) bool {
    if (policy.struct_size != @sizeOf(wire.SkillPolicyV1) or
        policy.reserved0 != 0 or
        (policy.granted_skill_ids == null) !=
            (policy.granted_skill_id_count == 0))
        return false;
    if (policy.granted_skill_ids) |grants| {
        for (grants[0..policy.granted_skill_id_count], 0..) |grant, index| {
            const skill_id = sdk.borrowedBytes(grant) catch return false;
            if (skill_id.len == 0) return false;
            for (grants[0..index]) |previous| {
                const previous_id = sdk.borrowedBytes(previous) catch return false;
                if (std.mem.eql(u8, skill_id, previous_id)) return false;
            }
        }
    }
    for (policy.reserved) |value| {
        if (value != 0) return false;
    }
    return true;
}

fn validMcpSelection(selection: *const wire.McpSelectionV1) bool {
    if (selection.struct_size != @sizeOf(wire.McpSelectionV1) or
        selection.reserved0 != 0 or
        (selection.selectors == null) != (selection.selector_count == 0))
        return false;
    for (selection.reserved) |value| if (value != 0) return false;
    if (selection.selectors) |selectors| for (selectors[0..selection.selector_count]) |selector| {
        if (selector.struct_size != @sizeOf(wire.McpSelectorV1) or
            selector.reserved0 != 0)
            return false;
        const name = sdk.borrowedBytes(selector.tool_name) catch return false;
        if (name.len == 0) return false;
        for (selector.reserved) |value| if (value != 0) return false;
    };
    return true;
}

fn invokeDetachedUiCallback(session: *FakeSession) void {
    session.lock();
    const callback = session.callbacks.on_ui_request orelse {
        session.unlock();
        return;
    };
    const callback_context = session.callbacks.ctx;
    const run_id = session.run_id;
    const permission_generation = session.policy_generation;
    var session_id = [_]u8{0} ** wire.MAX_SESSION_ID_BYTES_V1;
    const session_id_len = session.session_id_len;
    @memcpy(session_id[0..session_id_len], session.session_id[0..session_id_len]);
    session.unlock();

    var run = std.mem.zeroes(wire.RunContextV1);
    run.struct_size = @sizeOf(wire.RunContextV1);
    run.session = @ptrCast(session);
    run.run_id = run_id;
    run.session_id = sdk.bytesView(session_id[0..session_id_len]);
    var response = wire.OwnedBytesV1{ .ptr = null, .len = 0 };
    var request_storage: [2048]u8 = undefined;
    const request_json = permissionRequestJson(
        &request_storage,
        session_id[0..session_id_len],
        run_id,
        permission_generation,
    ) catch return;
    const callback_status = callback(
        callback_context,
        &run,
        sdk.bytesView(request_json),
        &response,
    );
    fake_core.lock();
    if (callback_status == wire.UI_ANSWERED)
        fake_core.ui_answered_callbacks += 1;
    if (callback_status == wire.UI_FATAL)
        fake_core.ui_fatal_callbacks += 1;
    fake_core.unlock();
    if (callback_status == wire.UI_ANSWERED) {
        const release = session.callbacks.release_response orelse return;
        release(callback_context, &response);
    }
    fake_core.lock();
    const signal = fake_core.callback_signal;
    fake_core.unlock();
    if (signal) |active_signal| active_signal.markFinished();
}

fn emitPermissionProvenance(
    session: *FakeSession,
    handle: ?*wire.SessionHandle,
    run_id: u64,
    request_json: []const u8,
    response: sdk.protocol.PermissionResponse,
) bool {
    var parsed = sdk.protocol.decodeUiRequest(std.testing.allocator, request_json) catch return false;
    defer parsed.deinit();
    const request = switch (parsed.value) {
        .permission => |value| value,
        else => return false,
    };
    const provenance: sdk.protocol.PermissionProvenance = .{
        .decision = if (response.permission == .allow_once or response.permission == .allow_session) .allow else .deny,
        .source = .callback,
        .matched_rule_id = null,
        .session_id = request.session_id,
        .run_id = run_id,
        .tool_call_id = request.tool_call_id,
        .request_id = request.request_id,
        .tool = request.tool,
        .canonical_arguments_digest = request.canonical_arguments_digest,
        .policy_generation = request.policy_generation,
        .used_session_rule = false,
        .callback_outcome = .answered,
        .response = response.permission,
    };
    var storage: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    std.json.Stringify.value(.{ .permission_provenance = provenance }, .{}, &writer) catch return false;
    const callback = session.callbacks.on_event orelse return false;
    var run = std.mem.zeroes(wire.RunContextV1);
    run.struct_size = @sizeOf(wire.RunContextV1);
    run.session = handle;
    run.run_id = run_id;
    run.session_id = sdk.bytesView(request.session_id);
    return callback(session.callbacks.ctx, &run, sdk.bytesView(writer.buffered())) == wire.EVENT_CONTINUE;
}

fn permissionRequestJson(
    storage: []u8,
    session_id: []const u8,
    run_id: u64,
    policy_generation: u64,
) std.fmt.BufPrintError![]const u8 {
    fake_core.lock();
    const arguments = fake_core.permission_arguments_json;
    const namespace = fake_core.permission_tool_namespace;
    const name = fake_core.permission_tool_name;
    const session_choices = fake_core.permission_session_choices;
    fake_core.unlock();
    const binding = if (std.mem.eql(u8, namespace, "builtin"))
        "0000000000000000000000000000000000000000000000000000000000000000"
    else
        "5555555555555555555555555555555555555555555555555555555555555555";
    var encoded_arguments: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&encoded_arguments);
    std.json.Stringify.value(arguments, .{}, &writer) catch return error.NoSpaceLeft;
    return std.fmt.bufPrint(
        storage,
        "{{\"type\":\"permission\",\"request_id\":\"1111111111111111111111111111111111111111111111111111111111111111\",\"session_id\":\"{s}\",\"run_id\":{d},\"tool_call_id\":\"tool-1\",\"tool\":{{\"namespace\":\"{s}\",\"name\":\"{s}\",\"binding\":\"{s}\"}},\"canonical_arguments_digest\":\"3333333333333333333333333333333333333333333333333333333333333333\",\"policy_generation\":{d},\"arguments_json\":{s},\"responses\":{s},\"candidate\":{s}}}",
        .{ session_id, run_id, namespace, name, binding, policy_generation, writer.buffered(), if (session_choices) "[\"deny_once\",\"deny_session\",\"allow_once\",\"allow_session\"]" else "[\"deny_once\",\"allow_once\"]", if (session_choices) "{\"rule_id\":\"2222222222222222222222222222222222222222222222222222222222222222\",\"scope\":\"exact_arguments\",\"target\":null}" else "null" },
    );
}

const ConcurrentEventInvocation = struct {
    callback: wire.OnEventFnV1,
    callback_context: ?*anyopaque,
    run: wire.RunContextV1,
    event_json: wire.BytesViewV1,
    ready: *std.Io.Semaphore,
    start: *std.Io.Semaphore,
    result: u32 = wire.EVENT_FATAL,

    fn invoke(self: *ConcurrentEventInvocation) void {
        self.ready.post(std.testing.io);
        self.start.waitUncancelable(std.testing.io);
        self.result = self.callback(
            self.callback_context,
            &self.run,
            self.event_json,
        );
    }
};

fn invokeConcurrentIdentityCallbacks(
    callback: wire.OnEventFnV1,
    callback_context: ?*anyopaque,
    run: *const wire.RunContextV1,
    event_json: []const u8,
) !u32 {
    var ready: std.Io.Semaphore = .{};
    var start: std.Io.Semaphore = .{};
    var first = ConcurrentEventInvocation{
        .callback = callback,
        .callback_context = callback_context,
        .run = run.*,
        .event_json = sdk.bytesView(event_json),
        .ready = &ready,
        .start = &start,
    };
    var second = first;
    second.run.session_id = sdk.bytesView("concurrent-other-id");
    const first_thread = try std.Thread.spawn(.{}, ConcurrentEventInvocation.invoke, .{&first});
    const second_thread = std.Thread.spawn(
        .{},
        ConcurrentEventInvocation.invoke,
        .{&second},
    ) catch |err| {
        start.post(std.testing.io);
        first_thread.join();
        return err;
    };
    ready.waitUncancelable(std.testing.io);
    ready.waitUncancelable(std.testing.io);
    start.post(std.testing.io);
    start.post(std.testing.io);
    first_thread.join();
    second_thread.join();
    return if (first.result == wire.EVENT_CONTINUE and second.result == wire.EVENT_CONTINUE)
        wire.EVENT_CONTINUE
    else
        wire.EVENT_FATAL;
}

pub fn openSession(runtime: *lifecycle.Runtime) !*lifecycle.Session {
    const workspace_root = if (std.fs.path.sep == '\\') "C:\\tmp\\metawork-gate2" else "/tmp/metawork-gate2";
    const temporary_root = if (std.fs.path.sep == '\\') "C:\\tmp" else "/tmp";
    return runtime.createSession(.{
        .model_binding = .{
            .target = .{
                .provider_id = "fixture-provider",
                .protocol = .anthropic_messages,
                .base_url = "",
                .model = "fixture-model",
            },
            .credential = "fixture-secret",
        },
        .permission_mode = .default,
        .shell_policy = .disabled,
        .workspace = .{
            .canonical_root = workspace_root,
            .trust = .{ .temporary = temporary_root },
        },
    });
}

pub const TestCompositionLimits = struct {
    worker_count: usize,
    queue_capacity: usize,
    max_sessions: usize,
    max_prompt_bytes: ?usize = null,
    event_capacity: ?usize = null,
    per_session_event_capacity: ?usize = null,
    control_reserved_capacity: ?usize = null,
    per_session_control_reserved_capacity: ?usize = null,
    max_event_bytes: ?usize = null,
    event_enqueue_timeout: ?std.Io.Duration = null,
    max_ui_response_bytes: ?usize = null,
    event_ready_notifier: ?lifecycle.EventReadyNotifier = null,
    event_ready_retry_interval: ?std.Io.Duration = null,
    event_ready_timeout: ?std.Io.Duration = null,

    pub fn hostLimits(self: @This()) lifecycle.Limits {
        var limits = lifecycle.Limits{ .max_sessions = self.max_sessions };
        if (self.max_prompt_bytes) |value| limits.max_prompt_bytes = value;
        if (self.event_capacity) |value| limits.event_capacity = value;
        if (self.per_session_event_capacity) |value| limits.per_session_event_capacity = value;
        if (self.control_reserved_capacity) |value| limits.control_reserved_capacity = value;
        if (self.per_session_control_reserved_capacity) |value|
            limits.per_session_control_reserved_capacity = value;
        if (self.max_event_bytes) |value| limits.max_event_bytes = value;
        if (self.event_enqueue_timeout) |value| limits.event_enqueue_timeout = value;
        if (self.max_ui_response_bytes) |value| limits.max_ui_response_bytes = value;
        limits.event_ready_notifier = self.event_ready_notifier;
        if (self.event_ready_retry_interval) |value| limits.event_ready_retry_interval = value;
        if (self.event_ready_timeout) |value| limits.event_ready_timeout = value;
        return limits;
    }
};

pub fn unavailableEventConsumer(_: ?*anyopaque) lifecycle.EventReadyNotification {
    return .unavailable;
}

pub const TestCompositionEntry = struct {
    runtime: *lifecycle.Runtime,
    executor: *product_control_executor.Executor,
    executor_shutdown: std.atomic.Value(enum(u8) { open, running, complete }) = .init(.open),
    terminal_mutex: std.Io.Mutex = .init,
    terminal_condition: std.Io.Condition = .init,
    terminal_results: [64]?StoredTerminalResult = @splat(null),
};

pub const StoredTerminalResult = struct {
    session_id: u64,
    run_id: u64,
    result: lifecycle.TerminalResult,
};

pub var test_compositions: [32]?TestCompositionEntry = @splat(null);

pub fn registerTestComposition(runtime: *lifecycle.Runtime, executor: *product_control_executor.Executor) !void {
    for (&test_compositions) |*entry| {
        if (entry.* == null) {
            entry.* = .{ .runtime = runtime, .executor = executor };
            return;
        }
    }
    return error.TestCompositionCapacity;
}

pub fn testCompositionEntry(runtime: *lifecycle.Runtime) *TestCompositionEntry {
    for (&test_compositions) |*entry| {
        const value = &(entry.* orelse continue);
        if (value.runtime == runtime) return value;
    }
    unreachable;
}

pub fn testExecutor(runtime: *lifecycle.Runtime) *product_control_executor.Executor {
    return testCompositionEntry(runtime).executor;
}

pub fn unregisterTestComposition(runtime: *lifecycle.Runtime) *product_control_executor.Executor {
    for (&test_compositions) |*entry| {
        const value = entry.* orelse continue;
        if (value.runtime == runtime) {
            const stored_entry = &entry.*.?;
            for (&stored_entry.terminal_results) |*result| {
                if (result.*) |*stored| stored.result.deinit();
                result.* = null;
            }
            entry.* = null;
            return value.executor;
        }
    }
    unreachable;
}

pub fn executeTestRun(context: *anyopaque) void {
    const session: *lifecycle.Session = @ptrCast(@alignCast(context));
    const snapshot = session.snapshot();
    var run = session.beginRun(snapshot.active_run_id) catch return;
    const result = run.execute();
    run.deinit();
    storeTestTerminal(session, snapshot.active_run_id, result);
}

pub fn cancelTestRunForShutdown(context: *anyopaque) void {
    const session: *lifecycle.Session = @ptrCast(@alignCast(context));
    const run_id = session.snapshot().active_run_id;
    session.cancelPreparedRun(run_id) catch {};
}

pub fn submitSession(session: *lifecycle.Session, prompt: []const u8) !u64 {
    const run_id = try session.prepareRun(.{ .text = prompt });
    testExecutor(session.agent_runtime).enqueue(.{
        .identity = session,
        .context = session,
        .execute_fn = executeTestRun,
        .cancel_fn = cancelTestRunForShutdown,
    }) catch |err| {
        session.cancelPreparedRun(run_id) catch {};
        return err;
    };
    return run_id;
}

pub fn cancelSession(
    session: *lifecycle.Session,
    run_id: u64,
    interruption: lifecycle.ExternalInterruption,
) !void {
    if (testExecutor(session.agent_runtime).cancel(session)) return;
    return session.requestTermination(run_id, .{ .interrupted = interruption });
}

pub fn closeSession(session: *lifecycle.Session, interruption: lifecycle.ExternalInterruption) !void {
    const snapshot = session.snapshot();
    if (snapshot.state == .queued) _ = testExecutor(session.agent_runtime).cancel(session);
    return session.close(interruption);
}

pub fn storeTestTerminal(
    session: *lifecycle.Session,
    run_id: u64,
    result: lifecycle.TerminalResult,
) void {
    const entry = testCompositionEntry(session.agent_runtime);
    entry.terminal_mutex.lockUncancelable(std.testing.io);
    defer entry.terminal_mutex.unlock(std.testing.io);
    for (&entry.terminal_results) |*slot| {
        if (slot.* == null) {
            slot.* = .{ .session_id = session.id, .run_id = run_id, .result = result };
            entry.terminal_condition.broadcast(std.testing.io);
            return;
        }
    }
    std.debug.panic("test TerminalResult capacity exhausted", .{});
}

pub fn takeTestTerminal(session: *lifecycle.Session, run_id: u64) lifecycle.TerminalResult {
    const entry = testCompositionEntry(session.agent_runtime);
    entry.terminal_mutex.lockUncancelable(std.testing.io);
    defer entry.terminal_mutex.unlock(std.testing.io);
    while (true) {
        for (&entry.terminal_results) |*slot| {
            const stored = slot.* orelse continue;
            if (stored.session_id != session.id or stored.run_id != run_id) continue;
            slot.* = null;
            return stored.result;
        }
        entry.terminal_condition.waitUncancelable(std.testing.io, &entry.terminal_mutex);
    }
}

pub fn shutdownTestComposition(runtime: *lifecycle.Runtime) !void {
    const entry = testCompositionEntry(runtime);
    if (entry.executor_shutdown.cmpxchgStrong(.open, .running, .acq_rel, .acquire) == null) {
        var runtime_error: ?lifecycle.Error = null;
        runtime.shutdown() catch |err| {
            runtime_error = err;
        };
        entry.executor.shutdown();
        entry.executor_shutdown.store(.complete, .release);
        if (runtime_error) |err| return err;
    } else {
        while (entry.executor_shutdown.load(.acquire) != .complete)
            std.Thread.yield() catch {};
    }
    return runtime.shutdown();
}

pub fn deinitTestComposition(runtime: *lifecycle.Runtime) void {
    const executor = unregisterTestComposition(runtime);
    executor.deinit();
    runtime.deinit();
}

pub fn createTestComposition(limits: TestCompositionLimits) !*lifecycle.Runtime {
    const executor = try product_control_executor.Executor.create(
        std.testing.io,
        std.testing.allocator,
        .{ .worker_count = limits.worker_count, .queue_capacity = limits.queue_capacity },
    );
    var executor_registered = false;
    errdefer if (!executor_registered) executor.deinit();
    const runtime = try createTestRuntime(limits.hostLimits());
    errdefer {
        runtime.shutdown() catch {};
        runtime.deinit();
    }
    try registerTestComposition(runtime, executor);
    executor_registered = true;
    return runtime;
}

pub fn createTestRuntime(limits: lifecycle.Limits) !*lifecycle.Runtime {
    return lifecycle.Runtime.initWithApi(
        std.testing.io,
        std.testing.allocator,
        &fake_api,
        limits,
    );
}

/// Models native wake queuing and the Agent coordinator's separate coalescing
/// flag. Every delivered effects_wake drains Product exactly once.
pub const LifecycleWakeLoop = struct {
    pending: std.atomic.Value(usize) = .init(0),
    agent_pending: std.atomic.Value(bool) = .init(false),

    pub fn wake(context: ?*anyopaque) bool {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        _ = self.pending.fetchAdd(1, .release);
        return true;
    }

    pub fn agentWake(context: ?*anyopaque) lifecycle.EventReadyNotification {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        if (self.agent_pending.swap(true, .acq_rel)) return .already_pending;
        _ = wake(context);
        return .scheduled;
    }

    pub fn drain(self: *@This(), control: *product_control.Runtime) !void {
        if (self.pending.load(.acquire) == 0) return;
        _ = self.pending.fetchSub(1, .acq_rel);
        self.agent_pending.store(false, .release);
        try control.drainAgentEvents();
    }
};

pub fn productControlConfiguration() product_control.Configuration {
    return .{ .skill_sources = .{ .restored = .{ .loaded = .{ .ready = .{} } } } };
}

pub fn installProductControlExecution(
    workbench: *product_control.Runtime,
) !void {
    return installProductControlExecutionGeneration(workbench, 1);
}

pub fn installProductControlExecutionGeneration(
    workbench: *product_control.Runtime,
    generation: u64,
) !void {
    try product_control.TestSupport.installMetaskExecutionWithCredential(
        workbench,
        generation,
        "fixture-secret",
    );
}

pub fn productControlTaskInput() product_control.TaskCreateInput {
    const workspace_root = if (std.fs.path.sep == '\\') "C:\\tmp" else "/tmp";
    const temporary_root = if (std.fs.path.sep == '\\') "C:\\tmp" else "/tmp";
    return .{
        .workspace_root = workspace_root,
        .trust = .{ .temporary = temporary_root },
    };
}

pub fn waitProductControlSnapshot(
    workbench: *product_control.Runtime,
    needle: []const u8,
) !void {
    var output: [512 * 1024]u8 = undefined;
    for (0..10_000) |_| {
        try workbench.drainAgentEvents();
        const snapshot = try workbench.writeAggregateFixture(&output);
        if (std.mem.indexOf(u8, snapshot, needle) != null) return;
        std.Thread.yield() catch {};
    }
    return error.TestUnexpectedResult;
}

pub fn closeOnThread(session: *lifecycle.Session) void {
    closeSession(session, .session_close) catch unreachable;
}

pub fn cancelOnThread(session: *lifecycle.Session, run_id: u64) void {
    cancelSession(session, run_id, .user_cancel) catch unreachable;
}

pub fn failPipelineOnThread(session: *lifecycle.Session) void {
    session.recordTerminationSignal(.{ .event_pump_failure = .consumer_rejected });
}

pub fn shutdownOnThread(runtime: *lifecycle.Runtime) void {
    shutdownTestComposition(runtime) catch unreachable;
}

pub fn prepareTestAttachmentImage(_: ?*anyopaque, allocator: std.mem.Allocator, bytes: []const u8, _: usize) anyerror![]u8 {
    return allocator.dupe(u8, bytes);
}
