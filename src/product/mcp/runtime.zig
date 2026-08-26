//! Live Product MCP aggregate for product state, refresh, apply, and test lifecycle.
//! Concrete executor, Agent Runtime, timer resources, publication, and complete
//! snapshot ownership remain outside and enter only through narrow capabilities.

const std = @import("std");
const agent = @import("metawork_agent");
const configuration = @import("product_mcp_configuration");
const state_module = @import("product_mcp_state");
const policy = @import("product_mcp_policy");
const ports_module = @import("product_mcp_ports");
const refresh_job = @import("product_mcp_refresh_job");

pub const Error = std.mem.Allocator.Error || error{
    ExecutorShuttingDown,
    QueueFull,
    CatalogLoading,
    CatalogUnavailable,
    McpManagementUnavailable,
    CatalogRequestGenerationExhausted,
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    ports: ports_module.Ports,
    /// Temporary migration seam for management/OAuth callers. The final
    /// surface-closure cut makes every kernel field private to this module.
    state: state_module.McpProductState,
    refresh_job: ?*refresh_job.Job = null,
    shutting_down: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        ports: ports_module.Ports,
        initial_state: state_module.McpProductState,
    ) Runtime {
        return .{
            .allocator = allocator,
            .ports = ports,
            .state = initial_state,
        };
    }

    pub fn deinit(self: *Runtime) void {
        std.debug.assert(self.refresh_job == null);
        self.ports.timer.cancel();
        self.state.deinit();
        self.* = undefined;
    }

    pub fn hasRefreshJob(self: *const Runtime) bool {
        return self.refresh_job != null;
    }

    pub fn cancelRefreshTimer(self: *Runtime) void {
        self.ports.timer.cancel();
    }

    pub fn refreshJobForTesting(self: *Runtime) ?*refresh_job.Job {
        if (!@import("builtin").is_test) @compileError("test-only MCP refresh seam");
        return self.refresh_job;
    }

    pub fn installRefreshJobForTesting(self: *Runtime, job: *refresh_job.Job) void {
        if (!@import("builtin").is_test) @compileError("test-only MCP refresh seam");
        std.debug.assert(self.refresh_job == null);
        self.refresh_job = job;
    }

    pub fn syncInitialHealth(self: *Runtime) bool {
        if (self.state.committed) return false;
        self.state.committed = true;
        return true;
    }

    pub fn requestRefresh(self: *Runtime, invalidate_admission: bool) Error!bool {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        const mcp = &self.state;
        if (!mcp.committed) return error.CatalogUnavailable;
        switch (mcp.preparation.state) {
            .empty, .available => {},
            .unavailable => return error.CatalogUnavailable,
        }
        const management = if (mcp.management) |*value| value else return error.CatalogUnavailable;
        const inspection = management.inspect();
        if (inspection.health != .ready) return error.McpManagementUnavailable;
        _ = management.desiredRegistry() orelse
            return error.McpManagementUnavailable;
        if (mcp.refresh_request_generation == std.math.maxInt(u64))
            return error.CatalogRequestGenerationExhausted;
        self.ports.timer.cancel();
        mcp.refresh_request_generation += 1;
        mcp.refresh_pending = true;
        mcp.refresh_pending_blocks_admission =
            mcp.refresh_pending_blocks_admission or invalidate_admission;
        if (invalidate_admission) policy.blockAdmission(mcp, .refreshing);
        return self.startPendingRefresh();
    }

    fn startPendingRefresh(self: *Runtime) Error!bool {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        const mcp = &self.state;
        if (!mcp.refresh_pending) return false;
        if (self.refresh_job != null or
            mcp.configuration_apply_state == .applying or
            mcp.authorization_operation != null)
            return false;
        const management = if (mcp.management) |*value| value else return error.CatalogUnavailable;
        const inspection = management.inspect();
        if (inspection.health != .ready) return error.McpManagementUnavailable;
        const desired = management.desiredRegistry() orelse
            return error.McpManagementUnavailable;
        if (desired.oauth_operation != null) return false;
        const generation = mcp.refresh_request_generation;
        std.debug.assert(generation != 0);
        var refresh_arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer refresh_arena.deinit();
        const allowlists = try policy.buildRefreshAllowlists(
            refresh_arena.allocator(),
            mcp,
            desired,
        );
        const job = try self.allocator.create(refresh_job.Job);
        errdefer self.allocator.destroy(job);
        job.* = .{
            .allocator = self.allocator,
            .catalog = self.ports.catalog,
            .notifier = self.ports.notifier,
            .request_generation = generation,
            .requested_at_ms = self.ports.timer.now(),
            .arena = refresh_arena,
            .allowlists = allowlists,
            .build_admission = inspection.runtime_alignment == .current,
        };
        try self.ports.executor.enqueue(job.executorJob());
        policy.blockAdmission(mcp, .refreshing);
        mcp.refresh_pending = false;
        mcp.refresh_pending_blocks_admission = false;
        self.refresh_job = job;
        return true;
    }

    pub fn onRefreshTimer(self: *Runtime) bool {
        if (self.shutting_down) return false;
        _ = self.requestRefresh(true) catch {
            if (self.refresh_job == null and !self.state.refresh_pending)
                policy.blockAdmissionForCurrentState(&self.state);
        };
        return true;
    }

    pub fn syncRefreshJob(self: *Runtime) bool {
        const job = self.refresh_job orelse return false;
        const job_state = job.state.load(.acquire);
        if (job_state == .queued or job_state == .running) return false;
        self.refresh_job = null;
        const still_current = !self.shutting_down and
            self.state.refresh_request_generation == job.request_generation;
        switch (job_state) {
            .completed => switch (job.outcome) {
                .activated => |activated| {
                    if (still_current) {
                        if (self.state.activation) |old| old.deinit();
                        self.state.activation = activated.activation;
                        self.state.activation_failed = false;
                        self.state.refresh_deadline_ms = state_module.mcpRefreshDeadlineMs(
                            activated.activation.catalogServers(),
                            job.requested_at_ms,
                        );
                        if (job.build_admission) {
                            policy.replaceAdmission(&self.state, .{ .ready = .{
                                .selection = activated.selection,
                                .catalog_generation = activated.activation.catalogGeneration(),
                            } });
                        } else {
                            policy.blockAdmissionForCurrentState(&self.state);
                        }
                        job.outcome = .empty;
                    }
                },
                .empty => if (still_current) {
                    if (self.state.activation) |old| old.deinit();
                    self.state.activation = null;
                    self.state.activation_failed = false;
                    self.state.refresh_deadline_ms = null;
                    if (job.build_admission)
                        policy.replaceAdmission(&self.state, .{ .ready = .{
                            .selection = null,
                            .catalog_generation = null,
                        } })
                    else
                        policy.blockAdmissionForCurrentState(&self.state);
                },
                .unavailable => if (still_current) {
                    if (self.state.activation) |old| old.deinit();
                    self.state.activation = null;
                    self.state.activation_failed = true;
                    self.state.refresh_deadline_ms = null;
                    policy.blockAdmission(&self.state, .activation_unavailable);
                },
            },
            .cancelled => {},
            .queued, .running => unreachable,
        }
        job.deinit();
        self.rearmRefreshTimer();
        return true;
    }

    pub fn beginConnectionTest(self: *Runtime, server_id: []const u8) Error!bool {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        if (self.state.configuration_apply_state == .applying)
            return error.CatalogLoading;
        if (self.state.connection_test) |test_state|
            if (test_state.state == .testing) return error.CatalogLoading;
        const management = if (self.state.management) |*value| value else return error.McpManagementUnavailable;
        const registry = management.desiredRegistry() orelse
            return error.McpManagementUnavailable;
        if (state_module.findMcpServer(registry.servers, server_id) == null)
            return error.McpManagementUnavailable;
        self.state.connection_test = state_module.McpConnectionTest.init(server_id) orelse
            return error.McpManagementUnavailable;
        return true;
    }

    pub fn completeConnectionTest(
        self: *Runtime,
        server_id: []const u8,
        outcome: state_module.McpConnectionTestOutcome,
        tool_count: u32,
        issue_count: u32,
    ) bool {
        const test_state = if (self.state.connection_test) |*value| value else return false;
        if (test_state.state != .testing or
            !std.mem.eql(u8, test_state.serverId(), server_id)) return false;
        test_state.state = switch (outcome) {
            .connected => .connected,
            .failed => .failed,
        };
        test_state.tool_count = tool_count;
        test_state.issue_count = issue_count;
        return true;
    }

    pub fn beginConfigurationApply(
        self: *Runtime,
        expected_generation: u64,
    ) Error!bool {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        if (self.state.configuration_apply_state == .applying or
            self.refresh_job != null or
            self.state.authorization_operation != null)
            return error.CatalogLoading;
        const management = if (self.state.management) |*value| value else return error.McpManagementUnavailable;
        const inspection = management.inspect();
        if (inspection.health != .ready or
            inspection.desired_generation != expected_generation)
            return error.McpManagementUnavailable;
        const registry = management.desiredRegistry() orelse
            return error.McpManagementUnavailable;
        if (registry.oauth_operation != null) return error.CatalogLoading;
        self.ports.timer.cancel();
        self.state.configuration_apply_state = .applying;
        policy.blockAdmission(&self.state, .refreshing);
        return true;
    }

    pub fn completeConfigurationApply(
        self: *Runtime,
        expected_generation: u64,
        preparation: *configuration.Preparation,
        manifest: *configuration.RuntimeManifest,
        activation: ?*agent.McpActivation,
        selection: ?*agent.McpSelection,
        activation_failed: bool,
    ) bool {
        if (self.state.configuration_apply_state != .applying) return false;
        const management = if (self.state.management) |*value| value else return false;
        const inspection = management.inspect();
        if (inspection.health != .ready or
            inspection.desired_generation != expected_generation or
            preparation.generation() != expected_generation)
            return false;

        if (self.state.activation) |old| old.deinit();
        self.state.activation = activation;
        self.state.activation_failed = activation_failed;
        self.state.preparation.deinit();
        self.state.preparation = preparation.take();
        management.installRuntimeManifest(manifest);
        self.state.configuration_apply_state = .idle;
        self.state.refresh_pending = false;
        self.state.refresh_pending_blocks_admission = false;
        if (activation_failed) {
            if (selection) |value| value.deinit();
            policy.blockAdmission(&self.state, .activation_unavailable);
        } else {
            policy.replaceAdmission(&self.state, .{ .ready = .{
                .selection = selection,
                .catalog_generation = if (activation) |value|
                    value.catalogGeneration()
                else
                    null,
            } });
        }
        self.state.connection_test = null;
        self.updateRefreshDeadline();
        self.rearmRefreshTimer();
        return true;
    }

    pub fn failConfigurationApply(self: *Runtime, expected_generation: u64) bool {
        if (self.state.configuration_apply_state != .applying) return false;
        const management = if (self.state.management) |*value| value else return false;
        if (management.inspect().desired_generation != expected_generation) return false;
        self.state.configuration_apply_state = .failed;
        policy.blockAdmissionForCurrentState(&self.state);
        self.rearmRefreshTimer();
        return true;
    }

    pub fn updateRefreshDeadline(self: *Runtime) void {
        self.state.refresh_deadline_ms = null;
        const activation = self.state.activation orelse return;
        self.state.refresh_deadline_ms = state_module.mcpRefreshDeadlineMs(
            activation.catalogServers(),
            self.ports.timer.now(),
        );
    }

    pub fn rearmRefreshTimer(self: *Runtime) void {
        self.ports.timer.cancel();
        if (self.shutting_down) return;
        if (self.state.refresh_pending) {
            const started = self.startPendingRefresh() catch return;
            if (started or self.state.refresh_pending) return;
        }
        if (!self.ports.timer.enabled) return;
        if (!self.state.committed or
            self.refresh_job != null or
            self.state.configuration_apply_state == .applying or
            self.state.authorization_operation != null or
            self.state.runtime_auth_failure_blocked or
            self.state.activation_failed)
            return;
        const management = if (self.state.management) |*value| value else return;
        const inspection = management.inspect();
        if (inspection.health != .ready or inspection.runtime_alignment != .current)
            return;
        const desired = management.desiredRegistry() orelse return;
        if (desired.oauth_operation != null) return;
        const deadline_ms = self.state.refresh_deadline_ms orelse return;
        const now_ms = self.ports.timer.now() orelse return;
        if (deadline_ms <= now_ms) {
            _ = self.requestRefresh(true) catch {};
            return;
        }
        _ = self.ports.timer.armAt(deadline_ms);
    }

    pub fn recoverExpiredCatalog(self: *Runtime) bool {
        if (self.shutting_down) return false;
        _ = self.requestRefresh(true) catch {
            if (self.refresh_job == null and !self.state.refresh_pending)
                policy.blockAdmissionForCurrentState(&self.state);
        };
        return true;
    }

    pub fn beginShutdown(self: *Runtime) void {
        if (self.shutting_down) return;
        self.shutting_down = true;
        policy.blockAdmission(&self.state, .shutting_down);
        if (self.state.activation) |activation| activation.deinit();
        self.state.activation = null;
        self.state.activation_failed = true;
        self.ports.timer.cancel();
        if (self.refresh_job) |job| _ = self.ports.executor.cancel(job);
    }

    pub fn finishShutdownAfterExecutorJoin(self: *Runtime) void {
        std.debug.assert(self.shutting_down);
        _ = self.syncRefreshJob();
        std.debug.assert(self.refresh_job == null);
    }
};

const TestHarness = struct {
    queued: ?ports_module.Job = null,
    notifications: usize = 0,

    fn enqueue(
        context: *anyopaque,
        job: ports_module.Job,
    ) error{ ExecutorShuttingDown, QueueFull }!void {
        const self: *TestHarness = @ptrCast(@alignCast(context));
        std.debug.assert(self.queued == null);
        self.queued = job;
    }

    fn cancel(context: *anyopaque, identity: *anyopaque) bool {
        const self: *TestHarness = @ptrCast(@alignCast(context));
        const job = self.queued orelse return false;
        if (job.identity != identity) return false;
        self.queued = null;
        job.cancel_fn(job.context);
        return true;
    }

    fn activate(_: *anyopaque) anyerror!agent.McpActivationOutcome {
        return .empty;
    }

    fn createAdmissionSelection(
        _: *anyopaque,
        _: *const agent.McpActivation,
        _: []const agent.McpServerAllowlist,
    ) anyerror!?*agent.McpSelection {
        return null;
    }

    fn now(_: ?*anyopaque) ?u64 {
        return 100;
    }

    fn armAt(_: ?*anyopaque, _: u64) bool {
        return true;
    }

    fn cancelTimer(_: ?*anyopaque) void {}

    fn notify(context: ?*anyopaque) bool {
        const self: *TestHarness = @ptrCast(@alignCast(context.?));
        self.notifications += 1;
        return true;
    }

    fn ports(self: *TestHarness) ports_module.Ports {
        return .{
            .executor = .{
                .context = self,
                .enqueue_fn = enqueue,
                .cancel_fn = cancel,
            },
            .catalog = .{
                .context = self,
                .activate_fn = activate,
                .create_admission_selection_fn = createAdmissionSelection,
            },
            .timer = .{
                .enabled = true,
                .context = self,
                .now_fn = now,
                .arm_at_fn = armAt,
                .cancel_fn = cancelTimer,
            },
            .notifier = .{
                .context = self,
                .notify_fn = notify,
            },
        };
    }

    fn executeQueued(self: *TestHarness) void {
        const job = self.queued.?;
        self.queued = null;
        job.execute_fn(job.context);
    }
};

const test_limits: configuration.Limits = .{
    .max_servers = 4,
    .max_tools_per_server = 8,
    .max_namespace_bytes = 128,
    .max_credential_locators = 16,
    .max_runtime_secrets_per_server = 8,
    .max_runtime_secret_bytes_per_server = 4096,
};

test "Product MCP Runtime retains refresh requested during apply and starts it on settlement" {
    const allocator = std.testing.allocator;
    const registry: configuration.RegistryWire = .{
        .schema_version = configuration.schema_version,
        .generation = 1,
        .oauth_operation = null,
        .servers = &.{},
    };
    var management = try configuration.ManagementPort.init(
        allocator,
        registry,
        .{
            .persistence = .{ .available = true },
            .credentials = .{ .available = true },
            .limits = test_limits,
        },
    );
    var management_owned = true;
    defer if (management_owned) management.deinit();
    var harness = TestHarness{};
    var runtime = Runtime.init(
        allocator,
        harness.ports(),
        .{
            .preparation = .{ .allocator = allocator, .state = .empty },
            .activation = null,
            .activation_failed = false,
            .management = management,
            .admission = .{ .ready = .{
                .selection = null,
                .catalog_generation = null,
            } },
            .host_capabilities = .{},
        },
    );
    management_owned = false;
    defer runtime.deinit();

    try std.testing.expect(runtime.syncInitialHealth());
    try std.testing.expect(try runtime.beginConfigurationApply(1));
    try std.testing.expect(!try runtime.requestRefresh(true));
    try std.testing.expect(runtime.state.refresh_pending);
    try std.testing.expect(!runtime.hasRefreshJob());

    try std.testing.expect(runtime.failConfigurationApply(1));
    try std.testing.expect(!runtime.state.refresh_pending);
    try std.testing.expect(runtime.hasRefreshJob());
    try std.testing.expect(harness.queued != null);

    harness.executeQueued();
    try std.testing.expect(runtime.syncRefreshJob());
    try std.testing.expect(!runtime.hasRefreshJob());
    try std.testing.expectEqual(@as(usize, 1), harness.notifications);
}
