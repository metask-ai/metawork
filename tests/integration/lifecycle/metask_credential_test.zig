//! Real Account/Models/Product lifecycle with a synthetic Core ABI.
//! Expired-token rejection is injected; this does not claim live Metask evidence.
const fixture = @import("lifecycle_fixture");
const std = fixture.std;
const account = fixture.account;
const control_api = fixture.product_control;
const coordinator_api = fixture.models_coordinator;
const models = fixture.models_contract;
const fake_core = &fixture.fake_core;

const access_a = "synthetic-lifecycle-access-a";
const access_b = "synthetic-lifecycle-access-b";
const model_id = "glm-5.3-flash";

const Network = struct {
    expected_access: []const u8 = access_a,
    catalog_calls: std.atomic.Value(usize) = .init(0),
    refresh_calls: std.atomic.Value(usize) = .init(0),
    fail_catalog: bool = false,
    login_principal: []const u8 = "credential-lifecycle",
    catalog_drift: bool = false,
    rotate_token: bool = true,
    next_access: ?[]const u8 = null,

    fn wake(_: *anyopaque) void {}

    fn refresh(context: *anyopaque, request: account.TransportRequest, buffer: []u8) account.TransportError!account.TransportResponse {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (request.kind == .userinfo) {
            const body = std.fmt.bufPrint(buffer, "{{\"sub\":\"{s}\",\"name\":\"Synthetic user\",\"client_id\":\"metawork\",\"authorization_id\":\"synthetic-authorization\"}}", .{self.login_principal}) catch return error.ResponseTooLarge;
            return .{ .status = 200, .body = body };
        }
        if (request.kind != .refresh_token and request.kind != .exchange_code) return error.ProtocolFailed;
        const refresh_index = if (request.kind == .refresh_token) self.refresh_calls.fetchAdd(1, .monotonic) + 1 else 0;
        const body = std.fmt.bufPrint(buffer, "{{\"access_token\":\"{s}\",\"refresh_token\":\"synthetic-lifecycle-refresh-{d}\",\"token_type\":\"Bearer\",\"expires_in\":3600}}", .{ self.next_access orelse if (self.rotate_token) access_b else access_a, refresh_index }) catch return error.ResponseTooLarge;
        return .{ .status = 200, .body = body };
    }

    fn catalog(context: *anyopaque, request: fixture.metask_transport.Request, buffer: []u8) fixture.metask_transport.TransportError!fixture.metask_transport.Response {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (request.kind != .models or !std.mem.eql(u8, request.bearer orelse "", self.expected_access)) return error.ProtocolFailed;
        _ = self.catalog_calls.fetchAdd(1, .monotonic);
        if (self.fail_catalog) return .{ .status = 503, .body = "unavailable" };
        const body = if (self.catalog_drift and std.mem.eql(u8, self.expected_access, access_a)) "{\"object\":\"list\",\"has_more\":false,\"data\":[{\"id\":\"catalog-default-model\",\"object\":\"model\",\"type\":\"model\",\"capabilities\":{\"endpoints\":{\"messages\":{\"supported\":true}}}},{\"id\":\"" ++ model_id ++ "\",\"object\":\"model\",\"type\":\"model\",\"capabilities\":{\"endpoints\":{\"messages\":{\"supported\":true}}}}]}" else "{\"object\":\"list\",\"has_more\":false,\"data\":[{\"id\":\"" ++ model_id ++ "\",\"object\":\"model\",\"type\":\"model\",\"capabilities\":{\"endpoints\":{\"messages\":{\"supported\":true}}}}]}";
        @memcpy(buffer[0..body.len], body);
        return .{ .status = 200, .body = buffer[0..body.len] };
    }

    // No Custom Provider is created; any credential-vault access is a bug in
    // this Metask-only composition. Account has its own in-memory platform.
    fn generate(_: *anyopaque, _: *[fixture.models_ports.credential_slot_bytes]u8) anyerror!void {
        return error.UnexpectedVaultAccess;
    }
    fn store(_: *anyopaque, _: []const u8, _: []const u8) anyerror!void {
        return error.UnexpectedVaultAccess;
    }
    fn get(_: *anyopaque, _: []const u8, _: []u8) anyerror!?[]const u8 {
        return error.UnexpectedVaultAccess;
    }
    fn delete(_: *anyopaque, _: []const u8) anyerror!void {
        return error.UnexpectedVaultAccess;
    }
};

fn drainCatalog(coordinator: *coordinator_api.Coordinator) !void {
    for (0..5000) |_| {
        coordinator.drain();
        if (coordinator.catalog_job == null) return;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    return error.CatalogDidNotSettle;
}

/// Force the worker into checkpoint export after renewal's state observation.
const CheckpointRotationAllocator = struct {
    parent: std.mem.Allocator = std.testing.allocator,
    armed: bool = true,

    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (self.armed) {
            self.armed = false;
            fake_core.releaseControlled();
            fake_core.waitCheckpointExportEntered();
        }
        return self.parent.rawAlloc(len, alignment, ra);
    }
    fn resize(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) bool {
        const self: *@This() = @ptrCast(@alignCast(context));
        return self.parent.rawResize(bytes, alignment, len, ra);
    }
    fn remap(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        return self.parent.rawRemap(bytes, alignment, len, ra);
    }
    fn free(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.parent.rawFree(bytes, alignment, ra);
    }
};

fn createTask(control: *control_api.Runtime, workspace: u64) !u64 {
    return createTaskWithMode(control, workspace, .manual);
}

fn createTaskWithMode(control: *control_api.Runtime, workspace: u64, mode: control_api.ApprovalMode) !u64 {
    const view = control.modelsView();
    const provider = view.providers[0];
    return control.createTaskInWorkspace(workspace, try control.workspaceEpoch(workspace), .{
        .target = .{ .source_id = models.metask_source_id, .model_id = model_id },
        .expected_source_generation = provider.source_generation,
        .expected_catalog_generation = provider.catalog_generation,
    }, null, null, .{ .interactive = mode });
}

fn runCalls() usize {
    fake_core.lock();
    defer fake_core.unlock();
    return fake_core.run_calls;
}

fn runAndExpect(wake_loop: *fixture.LifecycleWakeLoop, control: *control_api.Runtime, task_id: u64, operation: []const u8, expected: fixture.product_task.RunOutcome) !void {
    const task = control.task_runtime.find(task_id).?;
    const previous_calls = runCalls();
    const accepted = try control.sendInput(operation, task_id, .{ .text = "Reply with a short text; do not call tools." });
    try std.testing.expectEqual(.accepted, accepted.outcome);
    for (0..5000) |_| {
        try wake_loop.drain(control);
        if (runCalls() > previous_calls and task.runtime.active_operation == .none and !task.runtime.worker_leases.hasLive()) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    } else {
        if (task.runtime.restore_job) |job| if (job.rebind) |rebind|
            std.debug.print("isolated input stalled: phase={s}, binding_commit={s}\n", .{ @tagName(rebind.phase), @tagName(job.binding_commit) });
        return error.RunDidNotSettle;
    }
    try std.testing.expectEqual(previous_calls + 1, runCalls());
    const run = fixture.product_task.testing.policy_module.latestTerminalRun(task.durable.runs).?;
    const terminal = fixture.product_task.testing.state_module.productTerminalFacts(run).?;
    try std.testing.expectEqual(expected, terminal.outcome);
    if (expected == .failed) {
        try std.testing.expectEqual(.provider_failure, terminal.cause.?);
        try std.testing.expectEqual(.absent, terminal.diagnostic_disposition);
        try std.testing.expectEqual(.reusable, terminal.session_disposition_at_completion);
    }
    for (run.tools) |tool| try std.testing.expect(tool == null);
}

test "Metask token rotation renews an idle old Task without changing its model intent" {
    try characterizeCredentialExpiry(.rotation);
}

test "Metask hard expiry blocks an old Task before Core without a notification" {
    try characterizeCredentialExpiry(.expiry);
}

test "Metask explicit relogin cannot renew an old Task even for the same principal" {
    try characterizeCredentialExpiry(.relogin);
}

test "Metask account replacement cannot lend its credential to an old Task" {
    try characterizeCredentialExpiry(.account_switch);
}

test "Metask catalog refresh failure never falls back to an old credential" {
    try characterizeCredentialExpiry(.catalog_failure);
}

test "Metask rejected credential update does not replay a Run and permits one explicit retry" {
    try characterizeCredentialExpiry(.update_rejected);
}

test "Metask credential update contract failure poisons the Session without replay" {
    try characterizeCredentialExpiry(.update_contract);
}

test "Metask stale restore candidate is rejected without a credential hot update" {
    try characterizeCredentialExpiry(.candidate_rotation);
}

test "Metask restore candidate never borrows credentials after relogin" {
    try characterizeCredentialExpiry(.candidate_relogin);
}

test "Metask restore rejects a replaced scope even when token bytes are unchanged" {
    try characterizeCredentialExpiry(.candidate_same_token_relogin);
}

test "Metask queued input reuses the Session renewed during an active Run" {
    try characterizeCredentialExpiry(.queued_rotation);
}

test "Metask renewed main Agent and automatic reviewer use the same new credential" {
    try characterizeCredentialExpiry(.reviewer);
}

test "Metask logout blocks old Tasks before and after login" {
    try characterizeCredentialExpiry(.logout);
}

test "Metask detached Task retains its authorization scope across login replacement" {
    try characterizeCredentialExpiry(.detached);
}

test "Metask catalog capability change keeps model intent and uses renewed credentials" {
    try characterizeCredentialExpiry(.catalog_drift);
}

test "Metask unadopted additional input survives credential renewal exactly once" {
    try characterizeCredentialExpiry(.continuation_rotation);
}

test "Metask continuation with unchanged credential does not recreate the Session" {
    try characterizeCredentialExpiry(.continuation_unchanged);
}

test "Metask stopping a continuation during renewal never resubmits it" {
    try characterizeCredentialExpiry(.continuation_cancelled);
}

test "Metask relogin during continuation renewal rejects its pending input" {
    try characterizeCredentialExpiry(.continuation_stale_auth);
}

test "Metask hard expiry during continuation renewal prevents the next Run" {
    try characterizeCredentialExpiry(.continuation_expired);
}

test "Metask automatic title reads the current credential after the main Run finishes" {
    try characterizeCredentialExpiry(.title_rotation);
}

test "Metask renewal defers when checkpoint starts after its state observation" {
    try characterizeCredentialExpiry(.checkpoint_rotation);
}

test "Metask idle renewal does not self-wake while history maintenance is not ready" {
    try characterizeCredentialExpiry(.retirement_not_ready);
}

test "Metask waiting approval Run resumes with the renewed credential" {
    try characterizeCredentialExpiry(.waiting_ui_rotation);
}

test "Metask rejected update terminates an active Run once without replay" {
    try characterizeCredentialExpiry(.active_update_rejected);
}

test "Metask renewal allocation failure terminates before Core mutation" {
    try characterizeCredentialExpiry(.active_update_oom);
}

test "Metask long Run retains more than 128 rotations and protects unrelated Task titles" {
    try characterizeCredentialExpiry(.many_rotations);
}

fn commitRefresh(account_runtime: *account.Runtime, control: *control_api.Runtime) !void {
    var refresh = switch (account_runtime.prepareTokenRefresh()) {
        .prepared => |value| value,
        else => return error.TestUnexpectedResult,
    };
    defer refresh.deinit();
    try std.testing.expect(account_runtime.admitEffect(&refresh));
    account_runtime.commit(&refresh);
    try std.testing.expect(account_runtime.dispatchCommitted(&refresh) == null);
    account.TestSupport.joinNetwork(account_runtime);
    var rotated = switch (account_runtime.prepareNextCompletion().?) {
        .prepared => |value| value,
        else => return error.TestUnexpectedResult,
    };
    defer rotated.deinit();
    try std.testing.expect(account_runtime.admitEffect(&rotated));
    account_runtime.commit(&rotated);
    try std.testing.expect(account_runtime.dispatchCommitted(&rotated) == null);
    control.commitAccountFactNoFail(account_runtime.preparedFact(&rotated));
}

const Scenario = enum { retirement_not_ready, checkpoint_rotation, title_rotation, waiting_ui_rotation, active_update_rejected, active_update_oom, many_rotations, rotation, expiry, relogin, account_switch, logout, detached, catalog_failure, catalog_drift, update_rejected, update_contract, candidate_rotation, candidate_relogin, candidate_same_token_relogin, queued_rotation, continuation_rotation, continuation_unchanged, continuation_cancelled, continuation_stale_auth, continuation_expired, reviewer };

fn characterizeCredentialExpiry(scenario: Scenario) !void {
    const rotate = scenario != .expiry;
    const continuation = switch (scenario) {
        .continuation_rotation, .continuation_unchanged, .continuation_cancelled, .continuation_stale_auth, .continuation_expired => true,
        else => false,
    };
    const continuation_failure = continuation and scenario != .continuation_rotation and scenario != .continuation_unchanged;
    const renewed_token = if (scenario == .continuation_unchanged or scenario == .candidate_same_token_relogin) access_a else access_b;
    fake_core.reset();
    fake_core.setCheckpointGeneration(1);
    var wake_loop: fixture.LifecycleWakeLoop = .{};
    const runtime = try fixture.createTestComposition(.{ .worker_count = 1, .queue_capacity = 2, .max_sessions = 2, .event_ready_notifier = .{ .context = &wake_loop, .notify_fn = fixture.LifecycleWakeLoop.agentWake } });
    defer {
        fixture.shutdownTestComposition(runtime) catch unreachable;
        fixture.deinitTestComposition(runtime);
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);
    var checkpoints = try fixture.product_task.checkpoint_store.FileStore.init(std.testing.io, home);
    defer checkpoints.deinit();
    var history = try fixture.product_task.history.FileStore.init(std.testing.io, home);
    defer history.deinit();
    var typed_history: History = .{ .file_store = &history };
    defer typed_history.deinit();
    var review = ReviewProbe{};
    var configuration = fixture.productControlConfiguration();
    configuration.change_notifier = .{ .context = &wake_loop, .wake = fixture.LifecycleWakeLoop.wake };
    if (scenario == .reviewer or scenario == .title_rotation) configuration.completion_factory = .{ .context = &review, .create_fn = ReviewProbe.create };
    configuration.task_persistence = typed_history.capability();
    configuration.checkpoint_store = .{ .file_store = &checkpoints };
    configuration.directories.canonical_user_home = home;
    var control = try control_api.Runtime.init(std.testing.allocator, std.testing.io, runtime, .{ .worker_count = 1, .queue_capacity = 2, .max_tasks = 2, .max_workspaces = 1, .max_runs_per_task = 5 }, configuration);
    defer control.deinit();
    defer fake_core.releaseControlledRestore();
    defer fake_core.releaseControlled();

    var network: Network = .{ .catalog_drift = scenario == .catalog_drift, .rotate_token = scenario != .continuation_unchanged and scenario != .candidate_same_token_relogin };
    var account_runtime = account.Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId(), .{ .context = &network, .perform_fn = Network.refresh }, account.TestSupport.loopbackEndpoint(), .{ .context = &network, .notify_fn = Network.wake });
    var platform: account.TestSupport.Platform = .{ .now_unix_seconds = 100 };
    account.TestSupport.attachPlatform(&account_runtime, &platform);
    defer {
        account.TestSupport.detachPlatform(&account_runtime);
        account_runtime.deinit();
    }
    var authenticated = try account.TestSupport.prepareAuthenticated(&account_runtime, "credential-lifecycle", "Synthetic user", access_a, "synthetic-lifecycle-refresh-a", 200);
    defer authenticated.deinit();
    account_runtime.commit(&authenticated);
    control.commitAccountFactNoFail(account_runtime.preparedFact(&authenticated));

    var coordinator = coordinator_api.Coordinator.init(&account_runtime, .{ .context = &network, .perform_fn = Network.catalog }, control.modelsManagement(), std.Thread.getCurrentId(), std.testing.io);
    coordinator.setProbeNotifier(.{ .context = &network, .notify_fn = Network.wake });
    coordinator.start(home, .{ .context = &network, .generate_slot_fn = Network.generate, .store_fn = Network.store, .get_fn = Network.get, .delete_fn = Network.delete });
    defer coordinator.shutdown();
    // Product may consult the admission port while settling recovery at shutdown.
    defer {
        fake_core.releaseControlledRestore();
        fake_core.releaseControlled();
        control.shutdownExecutor();
    }
    control.setMetaskAuthorizationCheck(coordinator.metaskAuthorizationCheck());
    coordinator.setCredentialRenewal(control.metaskCredentialRenewal());
    coordinator.authorizationChanged();
    try drainCatalog(&coordinator);
    try std.testing.expectEqual(@as(usize, 1), network.catalog_calls.load(.acquire));
    try std.testing.expectEqual(.ready, control.modelsView().providers[0].catalog_state);

    const workspace = try control.openWorkspace(.{ .workspace_root = home, .trust = .explicitly_trusted });
    const old_id = try createTaskWithMode(&control, workspace, if (scenario == .reviewer) .auto_review else .manual);
    const old = control.task_runtime.find(old_id).?;
    const old_epoch = old.durable.binding_epoch;
    const old_source = old.runtime.executionConst().?.source_generation;
    const old_revision = old.durable.model_intent.?.revision;
    if (scenario == .title_rotation) {
        review.title_success = true;
        fake_core.setSessionPlan(.controlled);
        _ = try control.sendInput("title-after-refresh", old_id, .{ .text = "A title should use the current credential." });
        defer fake_core.releaseControlled();
        for (0..5000) |_| {
            try wake_loop.drain(&control);
            if (runCalls() == 1) break;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        } else return error.RunDidNotStart;
        platform.now_unix_seconds = 150;
        try commitRefresh(&account_runtime, &control);
        network.expected_access = access_b;
        coordinator.authorizationChanged();
        try drainCatalog(&coordinator);
        fake_core.releaseControlled();
        for (0..5000) |_| {
            try wake_loop.drain(&control);
            if (old.runtime.active_operation == .none and !old.runtime.worker_leases.hasLive()) break;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        } else return error.RunDidNotSettle;
        control.syncLifecycle();
        try std.testing.expectEqual(@as(usize, 1), review.title_calls.load(.acquire));
        try std.testing.expect(review.title_credential_matched.load(.acquire));
        try std.testing.expect(old.durable.title_redacted);
        try std.testing.expect(std.mem.indexOf(u8, old.durable.title, access_b) == null);
        try std.testing.expectEqual(@as(usize, 1), fake_core.session_created);
        return;
    }
    try runAndExpect(&wake_loop, &control, old_id, "before-expiry", .completed);
    try std.testing.expectEqualStrings(access_a, old.runtime.executionConst().?.secret);
    try std.testing.expectEqualDeep(fixture.credentialDigest(access_a), fake_core.sessions[0].credential_digest);

    const old_generation = old.durable.execution_generation;
    const old_scope = old.runtime.metask_authorization_scope;
    try std.testing.expect(old_scope != 0);
    try std.testing.expect(old.durable.checkpoint != null);
    fake_core.setRestoredLogicalId(old.durable.checkpoint.?.session.logical_session_id);
    fake_core.setRestoreHistory(1, 0);
    fake_core.setRestoredModel(model_id);
    const default_revision = control.modelsView().selection_revision;
    if (scenario == .detached) {
        try std.testing.expect(try control_api.TestSupport.retryTaskSessionClose(&control, old_id));
        for (0..5000) |_| {
            try wake_loop.drain(&control);
            if (old.runtime.attachment == .detached and old.runtime.close_thread == null) break;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        } else return error.DetachDidNotSettle;
        try std.testing.expectEqual(old_scope, old.runtime.metask_authorization_scope);
        try relogin(&account_runtime);
        network.expected_access = access_b;
        coordinator.authorizationChanged();
        try drainCatalog(&coordinator);
        try expectBlocked(&control, old_id, "detached-after-login");
        try std.testing.expectEqual(@as(usize, 1), fake_core.session_created);
        return;
    }
    if (scenario == .logout) {
        var signed_out = account.TestSupport.prepareLoggedOutAfterExternalCommit(&account_runtime);
        defer signed_out.deinit();
        account_runtime.commit(&signed_out);
        try expectBlocked(&control, old_id, "logged-out-without-notification");
        coordinator.authorizationChanged();
        try relogin(&account_runtime);
        network.expected_access = access_b;
        coordinator.authorizationChanged();
        try drainCatalog(&coordinator);
        try expectBlocked(&control, old_id, "logged-in-again");
        return;
    }
    if (scenario == .relogin or scenario == .account_switch) {
        network.login_principal = if (scenario == .relogin) "credential-lifecycle" else "different-principal";
        try relogin(&account_runtime);
        network.expected_access = access_b;
        coordinator.authorizationChanged();
        try drainCatalog(&coordinator);
        try std.testing.expect(old_scope != account_runtime.authorizationState().?.scope);
        try expectBlocked(&control, old_id, "replaced-authorization");
        try std.testing.expectEqualStrings(access_a, old.runtime.executionConst().?.secret);
        const new_id = try createTask(&control, workspace);
        try runAndExpect(&wake_loop, &control, new_id, "new-authorization", .completed);
        return;
    }
    const restoring_candidate = scenario == .candidate_rotation or scenario == .candidate_relogin or scenario == .candidate_same_token_relogin;
    if (restoring_candidate) {
        try std.testing.expect(try control_api.TestSupport.retryTaskSessionClose(&control, old_id));
        for (0..5000) |_| {
            try wake_loop.drain(&control);
            if (old.runtime.attachment == .detached and old.runtime.close_thread == null) break;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        } else return error.DetachDidNotSettle;
        fake_core.armControlledRestoreAfterCreate();
        _ = try control.restoreTaskConversation(old_id, old.durable.binding_epoch);
        for (0..5000) |_| {
            try wake_loop.drain(&control);
            fake_core.lock();
            const entered = fake_core.restore_entered;
            fake_core.unlock();
            if (entered) break;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        } else return error.RestoreDidNotStart;
    }
    const held_run = scenario == .queued_rotation or continuation or scenario == .many_rotations or scenario == .waiting_ui_rotation or scenario == .active_update_rejected or scenario == .active_update_oom or scenario == .checkpoint_rotation;
    if (held_run) {
        fake_core.input_enabled = continuation;
        fake_core.setCheckpointGeneration(2);
        fake_core.setSessionPlan(if (scenario == .waiting_ui_rotation) .ui_wait else .controlled);
        const accepted = try control.sendInput("in-flight", old_id, .{ .text = "Finish the existing Run." });
        try std.testing.expectEqual(.accepted, accepted.outcome);
        for (0..5000) |_| {
            try wake_loop.drain(&control);
            if (runCalls() == 2 and (scenario != .waiting_ui_rotation or old.runtime.pending_ui_request_id != 0)) break;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        } else return error.RunDidNotStart;
        fake_core.setRestoreHistory(2, 0);
    }
    defer fake_core.releaseControlled();
    var checkpoint_rotation_allocator: CheckpointRotationAllocator = .{};
    if (scenario == .checkpoint_rotation) {
        fake_core.controlNextCheckpointExport();
        old.runtime.execution().?.allocator = checkpoint_rotation_allocator.allocator();
    }
    defer if (scenario == .checkpoint_rotation) {
        old.runtime.execution().?.allocator = std.testing.allocator;
        fake_core.releaseCheckpointExport();
    };
    var renewal_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    if (scenario == .active_update_oom) old.runtime.execution().?.allocator = renewal_allocator.allocator();
    if (rotate) {
        platform.now_unix_seconds = 150;
        try commitRefresh(&account_runtime, &control);
        try std.testing.expectEqual(old_scope, account_runtime.authorizationState().?.scope);
        network.expected_access = renewed_token;
        network.fail_catalog = scenario == .catalog_failure or scenario == .many_rotations;
        if (scenario == .update_rejected or scenario == .update_contract or scenario == .active_update_rejected) {
            fake_core.forced_update_credential_status = if (scenario == .update_contract) fixture.wire.STATUS_BUSY else fixture.wire.STATUS_INVALID_ARGUMENT;
        }
        const previous_credentials = control.task_persistence.credentials_fn;
        defer control.task_persistence.credentials_fn = previous_credentials;
        if (scenario == .retirement_not_ready) control.task_persistence.credentials_fn = struct {
            fn credentials(_: ?*anyopaque, _: []const []const u8, _: bool, _: fixture.product_task.history.CredentialScrub) fixture.product_task.history.CredentialStatus {
                return .{ .epoch = 1, .ready = false };
            }
        }.credentials;
        coordinator.authorizationChanged();
        try drainCatalog(&coordinator);
        if (scenario == .retirement_not_ready) {
            for (0..32) |_| {
                if (wake_loop.pending.load(.acquire) == 0) break;
                try wake_loop.drain(&control);
            } else return error.CredentialRetirementDidNotQuiesce;
            try std.testing.expectEqualStrings(access_b, old.runtime.executionConst().?.secret);
            try std.testing.expectEqual(@as(usize, 0), old.runtime.executionConst().?.retired_credentials.items.len);
            try std.testing.expectEqual(.write_failed, control.task_persistence_health);
            const security_epoch = control.projectionSecurityEpoch();
            for (0..3) |_| try control.drainAgentEvents();
            try std.testing.expectEqual(security_epoch, control.projectionSecurityEpoch());
            try std.testing.expectEqual(@as(usize, 0), wake_loop.pending.load(.acquire));
            try std.testing.expectEqual(@as(usize, 1), fake_core.credential_updates);
            return;
        }
        if (scenario == .checkpoint_rotation) {
            try std.testing.expect(!checkpoint_rotation_allocator.armed);
            try std.testing.expect(old.runtime.credential_renewal_deferred);
            try std.testing.expect(!old.runtime.credential_update_failed);
            try std.testing.expectEqualStrings(access_a, old.runtime.executionConst().?.secret);
            try std.testing.expectEqual(@as(usize, 0), fake_core.credential_updates);
            old.runtime.execution().?.allocator = std.testing.allocator;
            fake_core.releaseCheckpointExport();
            for (0..5000) |_| {
                coordinator.drain();
                try wake_loop.drain(&control);
                if (!old.runtime.credential_renewal_deferred and old.runtime.active_operation == .none and !old.runtime.worker_leases.hasLive()) break;
                try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
            } else return error.DeferredCredentialDidNotSettle;
            try std.testing.expectEqualStrings(access_b, old.runtime.executionConst().?.secret);
            try std.testing.expectEqual(@as(usize, 1), fake_core.credential_updates);
            try std.testing.expectEqual(@as(u64, 2), old.durable.checkpoint.?.session.last_run_id);
            try std.testing.expectEqual(.none, old.durable.checkpoint_attempt);
            try std.testing.expectEqual(@as(usize, 2), runCalls());
            try std.testing.expectEqual(@as(usize, 1), fake_core.session_created);
            return;
        }
        if (restoring_candidate) {
            if (scenario == .candidate_relogin or scenario == .candidate_same_token_relogin) {
                try relogin(&account_runtime);
                coordinator.authorizationChanged();
                try drainCatalog(&coordinator);
            }
            fake_core.releaseControlledRestore();
            for (0..5000) |_| {
                try wake_loop.drain(&control);
                if (old.runtime.restore_job == null and !old.runtime.worker_leases.hasLive() and old.runtime.close_thread == null) break;
                try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
            } else return error.RestoreDidNotSettle;
            try std.testing.expectEqual(@as(usize, 0), fake_core.credential_updates);
            try std.testing.expectEqual(.detached, std.meta.activeTag(old.runtime.attachment));
            try std.testing.expectEqual(@as(usize, 1), runCalls());
            if (scenario == .candidate_rotation) {
                // A new explicit restore obtains the current config. Refresh
                // itself never repairs or restarts the stale candidate.
                _ = try control.restoreTaskConversation(old_id, old.durable.binding_epoch);
                for (0..5000) |_| {
                    try wake_loop.drain(&control);
                    if (old.runtime.active_operation == .none and !old.runtime.worker_leases.hasLive()) break;
                    try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
                } else return error.RestoreDidNotSettle;
                try std.testing.expectEqualStrings(access_b, old.runtime.executionConst().?.secret);
                try std.testing.expectEqual(@as(usize, 1), runCalls());
            } else try expectBlocked(&control, old_id, "stale-restore-scope");
            return;
        }
        if (scenario == .active_update_rejected or scenario == .active_update_oom) {
            for (0..5000) |_| {
                try wake_loop.drain(&control);
                if (old.runtime.active_operation == .none and !old.runtime.worker_leases.hasLive()) break;
                try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
            } else return error.RunDidNotSettle;
            const terminal = fixture.product_task.testing.state_module.productTerminalFacts(&old.durable.runs[1].?).?;
            try std.testing.expectEqual(.failed, terminal.outcome);
            try std.testing.expectEqual(if (scenario == .active_update_oom) fixture.product_task.testing.state_module.RunCause.resource_limit else .agent_failure, terminal.cause.?);
            try std.testing.expectEqual(@as(usize, if (scenario == .active_update_oom) 0 else 1), fake_core.credential_updates);
            try std.testing.expectEqual(@as(usize, 2), runCalls());
            try std.testing.expectEqual(@as(usize, 1), fake_core.session_created);
            var current = (try account_runtime.authorizationLease()).?;
            defer current.deinit();
            try std.testing.expectEqualStrings(access_b, current.access_token);
            for (0..5) |_| try wake_loop.drain(&control);
            try std.testing.expectEqual(@as(usize, 2), runCalls());
            return;
        }
        if (scenario == .waiting_ui_rotation) {
            try std.testing.expectEqualStrings(access_b, old.runtime.executionConst().?.secret);
            try std.testing.expectEqual(@as(usize, 1), old.runtime.executionConst().?.retired_credentials.items.len);
            try control.respondUi(old_id, old.runtime.active_run_id, old.runtime.pending_ui_request_id, .{ .permission = .allow_once });
            fake_core.releaseControlled();
            for (0..5000) |_| {
                try wake_loop.drain(&control);
                if (old.runtime.active_operation == .none and !old.runtime.worker_leases.hasLive()) break;
                try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
            } else return error.RunDidNotSettle;
            try std.testing.expectEqual(.completed, fixture.product_task.testing.state_module.productTerminalFacts(&old.durable.runs[1].?).?.outcome);
            try std.testing.expectEqual(@as(usize, 1), fake_core.session_created);
            try std.testing.expectEqual(@as(usize, 0), old.runtime.executionConst().?.retired_credentials.items.len);
            return;
        }
        if (scenario == .many_rotations) {
            var token_buffer: [64]u8 = undefined;
            for (0..130) |index| {
                const token = try std.fmt.bufPrint(&token_buffer, "synthetic-lifecycle-rotation-{d}", .{index});
                network.next_access = token;
                platform.now_unix_seconds = platform.now_unix_seconds.? + 3540;
                try commitRefresh(&account_runtime, &control);
                network.expected_access = token;
                coordinator.authorizationChanged();
                try drainCatalog(&coordinator);
                try std.testing.expectEqual(old_scope, account_runtime.authorizationState().?.scope);
            }
            try std.testing.expectEqual(@as(usize, 131), fake_core.credential_updates);
            try std.testing.expectEqual(@as(usize, 131), old.runtime.executionConst().?.retired_credentials.items.len);
            try std.testing.expectEqual(@as(usize, 133), old.durable.runs[1].?.redactionSecrets().len);
            try std.testing.expect(control.task_runtime.containsExecutionCredential(access_a));
            // A is long expired, but its operation is still live. Its value
            // must remain known to global projection, including another Task.
            network.fail_catalog = false;
            _ = coordinator.refreshCatalog();
            try drainCatalog(&coordinator);
            const other_id = try createTask(&control, workspace);
            try control.renameTask(other_id, access_a);
            try std.testing.expect(std.mem.indexOf(u8, control.task_runtime.find(other_id).?.durable.title, access_a) == null);
            const snapshot_buffer = try std.testing.allocator.alloc(u8, 1024 * 1024);
            defer std.testing.allocator.free(snapshot_buffer);
            const snapshot = try control_api.TestSupport.writeAggregateFixture(&control, snapshot_buffer);
            try std.testing.expect(std.mem.indexOf(u8, snapshot, access_a) == null);
            fake_core.releaseControlled();
            for (0..5000) |_| {
                try wake_loop.drain(&control);
                if (old.runtime.active_operation == .none and !old.runtime.worker_leases.hasLive()) break;
                try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
            } else return error.RunDidNotSettle;
            try std.testing.expectEqual(@as(usize, 0), old.runtime.executionConst().?.retired_credentials.items.len);
            try std.testing.expect(!control.task_runtime.containsExecutionCredential(access_a));
            try std.testing.expectEqual(@as(usize, 2), runCalls());
            try std.testing.expectEqual(old_epoch, old.durable.binding_epoch);
            try std.testing.expectEqual(old_generation, old.durable.execution_generation);
            return;
        }
        if (scenario == .catalog_failure) {
            try expectBlocked(&control, old_id, "catalog-failed");
            try std.testing.expectEqualStrings(access_b, old.runtime.executionConst().?.secret);
            try std.testing.expectEqualDeep(fixture.credentialDigest(access_b), fake_core.sessions[0].credential_digest);
            try std.testing.expectEqual(@as(usize, 1), fake_core.session_created);
            return;
        }
        try std.testing.expectEqual(@as(usize, 1), network.refresh_calls.load(.acquire));
        try std.testing.expectEqual(@as(usize, 2), network.catalog_calls.load(.acquire));
        try std.testing.expectEqual(scenario != .continuation_unchanged, old_source != control.modelsView().providers[0].source_generation);
        try std.testing.expectEqual(default_revision, control.modelsView().selection_revision);
        if (scenario == .catalog_drift) {
            try std.testing.expectEqualStrings(model_id, control.modelsView().default_selection.?.model_id);
            try std.testing.expectEqual(old_revision, old.durable.model_intent.?.revision);
        }
        if (scenario == .update_rejected or scenario == .update_contract) {
            try std.testing.expect(old.runtime.credential_update_failed);
            if (scenario == .update_rejected) try std.testing.expectEqualStrings(access_a, old.runtime.executionConst().?.secret);
            try std.testing.expectEqual(@as(usize, 1), fake_core.credential_updates);
            for (0..5) |_| try wake_loop.drain(&control);
            try std.testing.expectEqual(@as(usize, 1), fake_core.credential_updates);
            try std.testing.expectEqual(@as(usize, 1), runCalls());
            if (scenario == .update_rejected) {
                fake_core.forced_update_credential_status = null;
                try runAndExpect(&wake_loop, &control, old_id, "explicit-retry-current-token", .completed);
                try std.testing.expectEqual(@as(usize, 2), fake_core.credential_updates);
                try std.testing.expectEqualStrings(access_b, old.runtime.executionConst().?.secret);
            } else {
                for (0..5000) |_| {
                    try wake_loop.drain(&control);
                    if (old.runtime.attachment == .detached and old.runtime.close_thread == null) break;
                    try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
                } else return error.DetachDidNotSettle;
                try std.testing.expectEqual(@as(usize, 1), fake_core.session_destroyed);
                _ = try control.restoreTaskConversation(old_id, old.durable.binding_epoch);
                for (0..5000) |_| {
                    try wake_loop.drain(&control);
                    if (old.runtime.active_operation == .none and !old.runtime.worker_leases.hasLive()) break;
                    try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
                } else return error.RestoreDidNotSettle;
                try std.testing.expectEqualStrings(access_b, old.runtime.executionConst().?.secret);
                try std.testing.expect(!old.runtime.credential_update_failed);
                try std.testing.expectEqual(@as(usize, 2), fake_core.session_created);
                try std.testing.expectEqual(@as(usize, 1), runCalls());
                return;
            }
            try std.testing.expectEqual(@as(usize, 1), fake_core.session_created);
            return;
        }
        if (scenario == .queued_rotation or continuation) {
            const queued = try control.sendInput("queued-after-rotation", old_id, .{ .text = "Start the next Run with the renewed token." });
            try std.testing.expectEqual(.accepted, queued.outcome);
            try std.testing.expectEqual(@as(usize, 1), fake_core.session_created);
            try std.testing.expectEqualStrings(renewed_token, old.runtime.executionConst().?.secret);
            if (continuation) {
                for (0..1000) |_| {
                    try wake_loop.drain(&control);
                    if (old.durable.runs[1].?.additional_inputs[0] != null) break;
                    try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
                } else return error.AdditionalInputNotSubmitted;
            }
            if (scenario == .continuation_cancelled) try control.stopTask(old_id);
            if (scenario == .continuation_stale_auth) try relogin(&account_runtime);
            if (scenario == .continuation_expired) platform.now_unix_seconds = 4000;
            fake_core.releaseControlled();
            if (continuation_failure) {
                for (0..5000) |_| {
                    try wake_loop.drain(&control);
                    if (old.runtime.active_operation == .none and !old.runtime.worker_leases.hasLive() and old.runtime.close_thread == null) break;
                    try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
                } else return error.RestoreDidNotSettle;
                const source = old.durable.runs[1].?;
                try std.testing.expectEqual(if (scenario == .continuation_cancelled) fixture.product_task.RunOutcome.cancelled else .completed, fixture.product_task.testing.state_module.productTerminalFacts(&source).?.outcome);
                try std.testing.expect(source.input_continuation_failure != null);
                try std.testing.expect(!source.input_continuation_pending);
                try std.testing.expectEqual(.unadopted, source.additional_inputs[0].?.state);
                try std.testing.expect(source.additional_inputs[0].?.raw_text == null);
                try std.testing.expectEqual(@as(usize, 0), control.task_runtime.pending_input_bytes);
                for (0..10) |_| try wake_loop.drain(&control);
                try std.testing.expectEqual(@as(usize, 2), runCalls());
                return;
            }
            for (0..5000) |_| {
                try wake_loop.drain(&control);
                if (runCalls() == 3 and old.runtime.active_operation == .none and !old.runtime.worker_leases.hasLive()) break;
                try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
            } else return error.QueuedRunDidNotSettle;
            try std.testing.expectEqualStrings(renewed_token, old.runtime.executionConst().?.secret);
            try std.testing.expectEqual(@as(usize, 1), fake_core.session_created);
            if (continuation) {
                const source = old.durable.runs[1].?;
                const additional = source.additional_inputs[0].?;
                try std.testing.expectEqual(.transferred, additional.state);
                try std.testing.expectEqual(old.durable.runs[2].?.id, additional.transferred_to_run_id.?);
                try std.testing.expect(additional.raw_text == null);
                try std.testing.expect(source.input_continuation_failure == null);
                try std.testing.expectEqual(@as(usize, 0), control.task_runtime.pending_input_bytes);
                for (0..5) |_| try wake_loop.drain(&control);
                try std.testing.expectEqual(@as(usize, 3), runCalls());
            }
            return;
        }
        if (scenario == .rotation) {
            // Model an idle desktop before the sole post-refresh input. Earlier
            // baseline/catalog notifications must not rescue a missing handoff.
            for (0..100) |_| {
                try wake_loop.drain(&control);
                try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
            }
            try std.testing.expectEqual(@as(usize, 0), wake_loop.pending.load(.acquire));
        }
        try runAndExpect(&wake_loop, &control, old_id, "rotated-before-old-expiry", .completed);
        if (scenario == .reviewer) {
            fake_core.setSessionPlan(.ui_wait);
            const accepted = try control.sendInput("review-new-authority", old_id, .{ .text = "Ask permission for this operation." });
            try std.testing.expectEqual(.accepted, accepted.outcome);
            for (0..5000) |_| {
                try wake_loop.drain(&control);
                if (old.permissionReviewPhase() == .needs_user) break;
                try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
            } else return error.ReviewDidNotSettle;
            try std.testing.expectEqual(@as(usize, 1), review.calls.load(.acquire));
            try std.testing.expect(review.credential_matched.load(.acquire));
            try std.testing.expectEqualDeep(fixture.credentialDigest(access_b), fake_core.sessions[0].credential_digest);
            // Reviewer HTTP failure does not fail the main Run or approve the tool.
            try std.testing.expectEqual(.run, std.meta.activeTag(old.runtime.active_operation));
            try control.respondUi(old_id, old.runtime.active_run_id, old.runtime.pending_ui_request_id, .{ .permission = .allow_once });
            fake_core.releaseControlled();
            for (0..5000) |_| {
                try wake_loop.drain(&control);
                if (old.runtime.active_operation == .none and !old.runtime.worker_leases.hasLive()) break;
                try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
            } else return error.RunDidNotSettle;
            const run = fixture.product_task.testing.policy_module.latestTerminalRun(old.durable.runs).?;
            try std.testing.expectEqual(.completed, fixture.product_task.testing.state_module.productTerminalFacts(run).?.outcome);
            return;
        }
    }

    platform.now_unix_seconds = 201;
    var lease = try account_runtime.authorizationLease();
    defer if (lease) |*value| value.deinit();
    if (rotate) {
        try std.testing.expectEqualStrings(access_b, lease.?.access_token);
    } else {
        try std.testing.expect(lease == null);
        // The Account clock alone must block admission, before any Models notification.
        try expectBlocked(&control, old_id, "expired-no-notification");
        coordinator.authorizationChanged();
        try std.testing.expectEqual(.needs_authentication, control.modelsView().providers[0].catalog_state);
        try std.testing.expectEqual(@as(usize, 1), network.catalog_calls.load(.acquire));
        try std.testing.expectEqual(@as(usize, 0), network.refresh_calls.load(.acquire));
        try std.testing.expectError(error.ModelSelectionChanged, createTask(&control, workspace));
    }
    // A is now rejected by the synthetic provider. The existing Session must
    // already hold B without restoring history or replaying tools.
    fake_core.lock();
    fake_core.rejected_credential_digest = fixture.credentialDigest(access_a);
    fake_core.unlock();
    if (rotate) {
        try runAndExpect(&wake_loop, &control, old_id, "expired-old-first", .completed);
        try runAndExpect(&wake_loop, &control, old_id, "expired-old-repeat", .completed);
        try std.testing.expectEqualStrings(access_b, old.runtime.executionConst().?.secret);
        try std.testing.expectEqual(old_epoch + @as(u64, if (scenario == .catalog_drift) 1 else 0), old.durable.binding_epoch);
        if (scenario == .catalog_drift) try std.testing.expect(old_generation != old.durable.execution_generation) else try std.testing.expectEqual(old_generation, old.durable.execution_generation);
        try std.testing.expectEqual(old_scope, old.runtime.metask_authorization_scope);
        try std.testing.expectEqual(@as(usize, if (scenario == .catalog_drift) 2 else 1), fake_core.session_created);
        try std.testing.expectEqual(@as(usize, if (scenario == .catalog_drift) 1 else 0), fake_core.session_destroyed);
        const new_id = try createTask(&control, workspace);
        try runAndExpect(&wake_loop, &control, new_id, "fresh-task-control", .completed);
        const new = control.task_runtime.find(new_id).?;
        try std.testing.expectEqualStrings(access_b, new.runtime.executionConst().?.secret);
        try std.testing.expectEqualDeep(fixture.credentialDigest(access_b), fake_core.sessions[if (scenario == .catalog_drift) 2 else 1].credential_digest);
        try std.testing.expectEqualStrings(old.durable.execution_model, new.durable.execution_model);
        try std.testing.expectEqual(old.durable.execution_protocol, new.durable.execution_protocol);
    } else {
        try expectBlocked(&control, old_id, "expired-old-first");
        try expectBlocked(&control, old_id, "expired-old-repeat");
        try std.testing.expectEqual(old_epoch, old.durable.binding_epoch);
        try std.testing.expectEqual(@as(usize, if (scenario == .catalog_drift) 2 else 1), fake_core.session_created);
        try std.testing.expectEqual(@as(usize, if (scenario == .catalog_drift) 1 else 0), fake_core.session_destroyed);
    }
    try std.testing.expectEqual(old_revision, old.durable.model_intent.?.revision);
    var snapshot: [512 * 1024]u8 = undefined;
    const json = try control.writeAggregateFixture(&snapshot);
    for ([_][]const u8{ access_a, access_b, "synthetic-lifecycle-refresh-a", "synthetic-lifecycle-refresh-b" }) |secret|
        try std.testing.expect(std.mem.indexOf(u8, json, secret) == null);
}

const History = fixture.TypedHistory;

fn expectBlocked(control: *control_api.Runtime, task_id: u64, operation: []const u8) !void {
    const before = runCalls();
    const result = try control.sendInput(operation, task_id, .{ .text = "No tools; this must not reach the provider." });
    try std.testing.expectEqual(.accepted, result.outcome);
    const task = control.task_runtime.find(task_id).?;
    const record = task.input_submissions.items[task.input_submissions.items.len - 1];
    try std.testing.expectEqual(.failed, record.state);
    try std.testing.expectEqual(before, runCalls());
    try std.testing.expectEqual(.none, task.runtime.active_operation);
}

fn relogin(runtime: *account.Runtime) !void {
    _ = account.TestSupport.commitBeginLoginWithoutDispatch(runtime);
    var input = try account.TestSupport.exchangeInput(std.testing.allocator, "synthetic-authorization-code");
    defer input.deinit();
    var exchange = account.TestSupport.prepareLoginExchange(runtime, &input);
    defer exchange.deinit();
    try std.testing.expect(runtime.admitEffect(&exchange));
    runtime.commit(&exchange);
    try std.testing.expect(runtime.dispatchCommitted(&exchange) == null);
    // Token exchange, durable rotation, then Userinfo identity confirmation.
    for (0..2) |_| {
        account.TestSupport.joinNetwork(runtime);
        var prepared = switch (runtime.prepareNextCompletion().?) {
            .prepared => |value| value,
            else => return error.LoginDidNotComplete,
        };
        defer prepared.deinit();
        try std.testing.expect(runtime.admitEffect(&prepared));
        runtime.commit(&prepared);
        try std.testing.expect(runtime.dispatchCommitted(&prepared) == null);
    }
    try std.testing.expectEqual(.authenticated, runtime.view().state);
}

const ReviewProbe = struct {
    calls: std.atomic.Value(usize) = .init(0),
    credential_matched: std.atomic.Value(bool) = .init(false),
    title_success: bool = false,
    title_calls: std.atomic.Value(usize) = .init(0),
    title_credential_matched: std.atomic.Value(bool) = .init(false),

    fn create(context: ?*anyopaque, allocator: std.mem.Allocator, binding: fixture.lifecycle.ModelBinding) anyerror!*fixture.lifecycle.Completion {
        return fixture.lifecycle.Completion.init(allocator, .{ .context = context, .perform_fn = perform }, binding);
    }
    fn perform(context: ?*anyopaque, request: fixture.lifecycle.CompletionHttpRequest, _: *const fixture.lifecycle.CompletionCancellation, _: []u8) fixture.lifecycle.CompletionTransportError!fixture.lifecycle.CompletionTransportResponse {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        if (std.mem.indexOf(u8, request.body, "allow_once") != null) {
            _ = self.calls.fetchAdd(1, .acq_rel);
            for (request.headers) |header| if (std.ascii.eqlIgnoreCase(header.name, "x-api-key")) {
                self.credential_matched.store(std.mem.eql(u8, header.value, access_b), .release);
            };
        } else {
            _ = self.title_calls.fetchAdd(1, .acq_rel);
            for (request.headers) |header| if (std.ascii.eqlIgnoreCase(header.name, "x-api-key")) {
                self.title_credential_matched.store(std.mem.eql(u8, header.value, access_b), .release);
            };
            if (self.title_success) return .{ .status = 200, .body = "{\"id\":\"title\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"glm-5.3-flash\",\"content\":[{\"type\":\"text\",\"text\":\"safe synthetic-lifecycle-access-b title\"}],\"stop_reason\":\"end_turn\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}" };
        }
        return .{ .status = 400, .body = "synthetic reviewer rejection" };
    }
};
