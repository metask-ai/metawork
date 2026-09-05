//! Live Product MCP aggregate for product state, refresh, apply, and test lifecycle.
//! Concrete executor, Agent Runtime, timer resources, publication, and complete
//! snapshot ownership remain outside and enter only through narrow capabilities.

const std = @import("std");
const builtin = @import("builtin");
const agent = @import("metawork_agent");
const configuration = @import("product_mcp_configuration");
const state_module = @import("product_mcp_state");
const policy = @import("product_mcp_policy");
const ports_module = @import("product_mcp_ports");
const refresh_job = @import("product_mcp_refresh_job");
const view = @import("product_mcp_view");

pub const Error = agent.Error || std.mem.Allocator.Error || error{
    ExecutorShuttingDown,
    QueueFull,
    CatalogLoading,
    CatalogUnavailable,
    McpManagementUnavailable,
    McpOauthScopeCapacity,
    RecoveryUnavailable,
    CatalogRequestGenerationExhausted,
};

pub const Capabilities = struct {
    management: bool,
    host: state_module.McpHostCapabilities,
};
pub const ViewError = view.Error;
pub const TextProjection = view.TextProjection;
pub const McpHostCapabilities = state_module.McpHostCapabilities;
pub const McpStartupConfiguration = state_module.McpStartupConfiguration;
pub const McpAdmissionBlockReason = state_module.McpAdmissionBlockReason;
pub const McpAdmissionReady = state_module.McpAdmissionReady;
pub const McpAdmissionAuthority = state_module.McpAdmissionAuthority;
pub const RecoveryMcpAuthority = state_module.RecoveryMcpAuthority;
pub const McpOauthRefreshBinding = state_module.McpOauthRefreshBinding;
pub const McpOauthRefreshBeginOutcome = state_module.McpOauthRefreshBeginOutcome;
pub const McpOauthAuthorizationPlan = state_module.McpOauthAuthorizationPlan;
pub const McpOauthAuthorizationBinding = state_module.McpOauthAuthorizationBinding;
pub const McpOauthAuthorizationOutcome = state_module.McpOauthAuthorizationOutcome;
pub const McpOauthOperationHandle = state_module.McpOauthOperationHandle;
pub const McpOauthCodeExchangeBinding = state_module.McpOauthCodeExchangeBinding;
pub const McpOauthOperationBeginOutcome = state_module.McpOauthOperationBeginOutcome;
pub const McpOauthCodeExchangeBeginOutcome = state_module.McpOauthCodeExchangeBeginOutcome;
pub const McpOauthExpiry = state_module.McpOauthExpiry;
pub const McpRuntimeAuthorizationFailure = state_module.McpRuntimeAuthorizationFailure;
pub const McpRuntimeAuthorizationFailureOutcome = state_module.McpRuntimeAuthorizationFailureOutcome;
pub const McpAuthorizationPhase = state_module.McpAuthorizationPhase;
pub const McpConnectionTestOutcome = state_module.McpConnectionTestOutcome;
pub const McpConfigurationApplyState = state_module.McpConfigurationApplyState;
pub const McpAuthorizationOperationView = state_module.McpAuthorizationOperationView;
pub const McpAuthorizationStart = state_module.McpAuthorizationStart;
pub const McpSecretCaptureTarget = state_module.McpSecretCaptureTarget;
pub const McpOauthRuntimeCommit = state_module.McpOauthRuntimeCommit;
pub const McpRefreshTimer = state_module.McpRefreshTimer;

/// Test-only access to the aggregate's internal kernel types and fixture
/// constructor. The production Product root publishes an empty struct here.
pub const testing = if (builtin.is_test) struct {
    pub const State = state_module.McpProductState;
    pub const RefreshJob = refresh_job.Job;

    pub fn init(
        allocator: std.mem.Allocator,
        ports: ports_module.Ports,
        initial_state: State,
    ) Runtime {
        return Runtime.init(allocator, ports, initial_state);
    }

    pub fn state(runtime: *Runtime) *State {
        return &runtime.state;
    }

    pub fn refreshJob(runtime: *Runtime) ?*RefreshJob {
        return runtime.refresh_job;
    }

    pub fn installRefreshJob(runtime: *Runtime, job: *RefreshJob) void {
        std.debug.assert(runtime.refresh_job == null);
        runtime.refresh_job = job;
    }
} else struct {};

/// Fallible startup preparation happens before the composition aggregate is
/// installed. `takeRuntime` is the final no-fail ownership move.
pub const Startup = struct {
    allocator: std.mem.Allocator,
    preparation: *configuration.Preparation,
    activation: ?*agent.McpActivation,
    activation_failed: bool,
    management: ?configuration.ManagementPort,
    host_capabilities: McpHostCapabilities,

    pub fn prepare(
        allocator: std.mem.Allocator,
        input: McpStartupConfiguration,
    ) Error!?Startup {
        const preparation = input.preparation orelse return null;
        const management = if (input.management) |management|
            try configuration.ManagementPort.init(
                allocator,
                if (preparation.registry) |registry| registry.value else null,
                management,
            )
        else
            null;
        return .{
            .allocator = allocator,
            .preparation = preparation,
            .activation = input.activation,
            .activation_failed = input.activation_failed,
            .management = management,
            .host_capabilities = input.host_capabilities,
        };
    }

    pub fn deinit(self: *Startup) void {
        if (self.management) |*management| management.deinit();
        self.* = undefined;
    }

    pub fn takeRuntime(self: *Startup, ports: ports_module.Ports) Runtime {
        const admission = state_module.initialMcpAdmission(
            self.activation,
            self.activation_failed,
            if (self.management) |*management| management else null,
        );
        const runtime = Runtime.init(
            self.allocator,
            ports,
            .{
                .preparation = self.preparation.take(),
                .activation = self.activation,
                .activation_failed = self.activation_failed,
                .management = self.management,
                .admission = admission,
                .host_capabilities = self.host_capabilities,
            },
        );
        self.management = null;
        self.* = undefined;
        return runtime;
    }
};

pub fn writeProjection(
    runtime: ?*const Runtime,
    writer: *std.Io.Writer,
    text: view.TextProjection,
) view.Error!void {
    return view.writeProjection(writer, .{
        .state = if (runtime) |value| &value.state else null,
        .refresh_job_active = if (runtime) |value| value.refresh_job != null else false,
        .text = text,
    });
}

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    ports: ports_module.Ports,
    /// Aggregate-owned MCP state. Production composition consumes it only
    /// through Runtime typed operations; direct access is test-seam only.
    state: state_module.McpProductState,
    refresh_job: ?*refresh_job.Job = null,
    runtime_auth_delivery_pending: bool = false,
    shutting_down: bool = false,
    changed: bool = false,

    fn init(
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

    pub fn blocksNewTaskAdmission(self: *const Runtime) bool {
        return self.refresh_job != null or self.state.refresh_pending_blocks_admission;
    }

    pub fn selectionForNewTask(self: *const Runtime) ?*const agent.McpSelection {
        return policy.selectionForNewTask(&self.state);
    }

    pub fn authorizationOperation(
        self: *const Runtime,
    ) ?state_module.McpAuthorizationOperationView {
        return policy.authorizationOperation(&self.state);
    }

    pub fn serverOperationBusy(self: *const Runtime, server_id: []const u8) bool {
        return policy.serverOperationBusy(&self.state, server_id);
    }

    pub fn capabilities(self: *const Runtime) Capabilities {
        const management = self.state.committed and self.state.management != null;
        return .{
            .management = management,
            .host = if (management) self.state.host_capabilities else .{},
        };
    }

    pub fn recoveryGeneration(self: *const Runtime) ?u64 {
        return policy.recoveryGeneration(&self.state, self.refresh_job != null);
    }

    pub fn authorityStable(self: *const Runtime) bool {
        if (!self.state.committed or self.refresh_job != null or
            self.state.refresh_pending_blocks_admission or
            self.state.authorization_operation != null)
            return false;
        return self.state.admission == .ready;
    }

    pub fn recoveryAuthority(self: *Runtime) Error!state_module.RecoveryMcpAuthority {
        if (!self.authorityStable()) return error.RecoveryUnavailable;
        const ready = switch (self.state.admission) {
            .ready => |value| value,
            .blocked => return error.RecoveryUnavailable,
        };
        const activation = self.state.activation orelse {
            if (ready.catalog_generation != null) return error.RecoveryUnavailable;
            return .{ .selection = null, .catalog_generation = null };
        };
        if (ready.catalog_generation == null or
            ready.catalog_generation.? != activation.catalogGeneration())
            return error.RecoveryUnavailable;
        const registry = if (self.state.management) |*management|
            management.desiredRegistry() orelse return error.RecoveryUnavailable
        else if (self.state.preparation.registry) |registry|
            registry.value
        else
            return error.RecoveryUnavailable;
        const health = activation.serverHealth();
        const allowlists = try self.allocator.alloc(agent.McpServerAllowlist, health.len);
        defer self.allocator.free(allowlists);
        for (health, allowlists) |server, *allowlist| {
            const desired = state_module.findMcpServer(registry.servers, server.id) orelse
                return error.RecoveryUnavailable;
            allowlist.* = .{
                .id = server.id,
                .tools = policy.serverToolsForAdmission(registry, desired),
            };
        }
        return .{
            .selection = self.ports.catalog.createAdmissionSelection(
                activation,
                allowlists,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.RecoveryUnavailable,
            },
            .catalog_generation = activation.catalogGeneration(),
        };
    }

    pub fn inspectDesiredConfiguration(
        self: *const Runtime,
    ) ?configuration.ManagementInspection {
        const management = if (self.state.management) |*value| value else return null;
        return management.inspect();
    }

    pub fn writeDesiredConfiguration(
        self: *const Runtime,
        expected_generation: u64,
        output: []u8,
    ) Error![]const u8 {
        const management = if (self.state.management) |*value| value else return error.McpManagementUnavailable;
        const inspection = management.inspect();
        if (inspection.health != .ready or
            inspection.desired_generation != expected_generation)
            return error.McpManagementUnavailable;
        const registry = management.desiredRegistry() orelse
            return error.McpManagementUnavailable;
        return configuration.encode(output, registry, management.limits) catch
            return error.McpManagementUnavailable;
    }

    pub fn writeConnectionApprovalDetails(
        self: *const Runtime,
        expected_generation: u64,
        server_id: []const u8,
        output: []u8,
    ) ![]const u8 {
        if (self.refresh_job != null or policy.serverMutationBusy(&self.state, server_id))
            return error.McpManagementUnavailable;
        const management = if (self.state.management) |*value| value else return error.McpManagementUnavailable;
        if (management.inspect().health != .ready or
            !policy.expectedGenerationMatches(management, expected_generation))
            return error.McpManagementUnavailable;
        const registry = management.desiredRegistry() orelse
            return error.McpManagementUnavailable;
        const server = state_module.findMcpServer(registry.servers, server_id) orelse
            return error.McpManagementUnavailable;
        if (configuration.serverProblem(server, management.limits)) |problem|
            if (problem != .invalid_connection_approval)
                return error.McpManagementUnavailable;
        if (registry.oauth_operation) |operation|
            if (std.mem.eql(u8, operation.server_id, server_id))
                return error.McpManagementUnavailable;
        var writer = std.Io.Writer.fixed(output);
        try writeQuotedField(&writer, "Name", server.display_name);
        try writeQuotedField(&writer, "Protocol policy", server.negotiation);
        try writer.print("Timeout: {d} ms\n", .{server.timeout_ms});
        try writeQuotedField(&writer, "Authentication", server.auth.kind);
        if (!std.mem.eql(u8, server.transport.kind, "streamable_http")) {
            try writer.writeAll("Transport: STDIO\n");
            try writeQuotedField(&writer, "Executable", server.transport.command.?);
            try writer.writeAll("Arguments:\n");
            for (server.transport.arguments) |argument|
                try writeQuotedListItem(&writer, argument.literal.?);
            try writeQuotedField(
                &writer,
                "Working directory",
                server.transport.cwd orelse "(none)",
            );
            try writer.writeAll("Environment names:\n");
            for (server.transport.environment) |slot|
                try writeQuotedListItem(&writer, slot.name);
        } else {
            try writer.writeAll("Transport: Streamable HTTP\n");
            try writeQuotedField(&writer, "Endpoint", server.transport.url.?);
            try writer.writeAll("Header names:\n");
            for (server.transport.headers) |slot|
                try writeQuotedListItem(&writer, slot.name);
            if (server.auth.oauth) |oauth| {
                try writeQuotedField(&writer, "OAuth registration", oauth.registration.kind);
                if (oauth.registration.client_id) |client_id|
                    try writeQuotedField(&writer, "OAuth client ID", client_id);
            }
        }
        return writer.buffered();
    }

    pub fn writeSecretCapturePrompt(
        self: *const Runtime,
        expected_generation: u64,
        server_id: []const u8,
        target: state_module.McpSecretCaptureTarget,
        output: []u8,
    ) ![]const u8 {
        if (self.refresh_job != null or policy.serverMutationBusy(&self.state, server_id))
            return error.McpManagementUnavailable;
        const management = if (self.state.management) |*value| value else return error.McpManagementUnavailable;
        if (management.inspect().health != .ready or
            !policy.expectedGenerationMatches(management, expected_generation))
            return error.McpManagementUnavailable;
        const registry = management.desiredRegistry() orelse
            return error.McpManagementUnavailable;
        const server = state_module.findMcpServer(registry.servers, server_id) orelse
            return error.McpManagementUnavailable;
        if (server.connection_approval == null or
            configuration.serverProblem(server, management.limits) != null)
            return error.McpManagementUnavailable;
        var writer = std.Io.Writer.fixed(output);
        try writeQuotedField(&writer, "MCP server", server.display_name);
        switch (target) {
            .stdio_environment => |requested_name| {
                if (!std.mem.eql(u8, server.auth.kind, "static") or
                    !std.mem.eql(u8, server.transport.kind, "stdio"))
                    return error.McpManagementUnavailable;
                for (server.transport.environment) |slot| {
                    if (!std.ascii.eqlIgnoreCase(slot.name, requested_name)) continue;
                    try writeQuotedField(&writer, "Environment variable", slot.name);
                    return writer.buffered();
                }
                return error.McpManagementUnavailable;
            },
            .http_header => |requested_name| {
                if (!std.mem.eql(u8, server.auth.kind, "static") or
                    !std.mem.eql(u8, server.transport.kind, "streamable_http"))
                    return error.McpManagementUnavailable;
                for (server.transport.headers) |slot| {
                    if (!std.ascii.eqlIgnoreCase(slot.name, requested_name)) continue;
                    try writeQuotedField(&writer, "HTTP header", slot.name);
                    return writer.buffered();
                }
                return error.McpManagementUnavailable;
            },
            .oauth_client_secret => {
                if (registry.oauth_operation != null) return error.McpManagementUnavailable;
                const oauth = server.auth.oauth orelse return error.McpManagementUnavailable;
                const method = oauth.registration.token_endpoint_auth_method orelse
                    return error.McpManagementUnavailable;
                if (!std.mem.eql(u8, oauth.registration.kind, "pre_registered") or
                    std.mem.eql(u8, method, "none"))
                    return error.McpManagementUnavailable;
                try writeQuotedField(
                    &writer,
                    "OAuth client ID",
                    oauth.registration.client_id orelse return error.McpManagementUnavailable,
                );
                return writer.buffered();
            },
        }
    }

    /// Returns and clears the product-state publication fact. The composition
    /// layer remains the sole owner of the global revision counter.
    pub fn takeChanged(self: *Runtime) bool {
        const changed = self.changed;
        self.changed = false;
        return changed;
    }

    fn markChanged(self: *Runtime) void {
        self.changed = true;
    }

    pub fn cancelRefreshTimer(self: *Runtime) void {
        self.ports.timer.cancel();
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
        self.releaseBoundary();
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
        self.releaseBoundary();
        return true;
    }

    pub fn failConfigurationApply(self: *Runtime, expected_generation: u64) bool {
        if (self.state.configuration_apply_state != .applying) return false;
        const management = if (self.state.management) |*value| value else return false;
        if (management.inspect().desired_generation != expected_generation) return false;
        self.state.configuration_apply_state = .failed;
        policy.blockAdmissionForCurrentState(&self.state);
        self.releaseBoundary();
        return true;
    }

    pub fn createHttpServer(
        self: *Runtime,
        expected_generation: u64,
        input: configuration.CreateHttpServerInput,
    ) Error!configuration.ManagementOutcome {
        const management = self.mutableManagement(expected_generation, null) orelse
            return self.generationOutcome(expected_generation);
        var preparation = try management.prepareCreateHttpServer(expected_generation, input);
        return self.commitPreparedMutation(&preparation);
    }

    pub fn createOauthHttpServer(
        self: *Runtime,
        expected_generation: u64,
        input: configuration.CreateOauthHttpServerInput,
    ) Error!configuration.ManagementOutcome {
        const management = self.mutableManagement(expected_generation, null) orelse
            return self.generationOutcome(expected_generation);
        var preparation = try management.prepareCreateOauthHttpServer(
            expected_generation,
            input,
        );
        return self.commitPreparedMutation(&preparation);
    }

    pub fn createStdioServer(
        self: *Runtime,
        expected_generation: u64,
        input: configuration.CreateStdioServerInput,
    ) Error!configuration.ManagementOutcome {
        const management = self.mutableManagement(expected_generation, null) orelse
            return self.generationOutcome(expected_generation);
        var preparation = try management.prepareCreateStdioServer(expected_generation, input);
        return self.commitPreparedMutation(&preparation);
    }

    pub fn updateHttpConnection(
        self: *Runtime,
        expected_generation: u64,
        input: configuration.UpdateHttpConnectionInput,
    ) Error!configuration.ManagementOutcome {
        const management = self.mutableManagement(expected_generation, input.server_id) orelse
            return self.generationOutcome(expected_generation);
        var preparation = try management.prepareUpdateHttpConnection(expected_generation, input);
        return self.commitPreparedMutation(&preparation);
    }

    pub fn updateOauthHttpConnection(
        self: *Runtime,
        expected_generation: u64,
        input: configuration.UpdateOauthHttpConnectionInput,
    ) Error!configuration.ManagementOutcome {
        const management = self.mutableManagement(expected_generation, input.server_id) orelse
            return self.generationOutcome(expected_generation);
        var preparation = try management.prepareUpdateOauthHttpConnection(
            expected_generation,
            input,
        );
        return self.commitPreparedMutation(&preparation);
    }

    pub fn updateStdioConnection(
        self: *Runtime,
        expected_generation: u64,
        input: configuration.UpdateStdioConnectionInput,
    ) Error!configuration.ManagementOutcome {
        const management = self.mutableManagement(expected_generation, input.server_id) orelse
            return self.generationOutcome(expected_generation);
        var preparation = try management.prepareUpdateStdioConnection(expected_generation, input);
        return self.commitPreparedMutation(&preparation);
    }

    pub fn captureStaticSecret(
        self: *Runtime,
        expected_generation: u64,
        input: configuration.CaptureStaticSecretInput,
    ) Error!configuration.ManagementOutcome {
        defer std.crypto.secureZero(u8, input.secret);
        const management = self.mutableManagement(expected_generation, input.server_id) orelse
            return self.generationOutcome(expected_generation);
        var preparation = try management.prepareCaptureStaticSecret(expected_generation, input);
        return self.commitPreparedMutation(&preparation);
    }

    pub fn captureOauthClientSecret(
        self: *Runtime,
        expected_generation: u64,
        input: configuration.CaptureOauthClientSecretInput,
    ) Error!configuration.ManagementOutcome {
        defer std.crypto.secureZero(u8, input.secret);
        const management = self.mutableManagement(expected_generation, input.server_id) orelse
            return self.generationOutcome(expected_generation);
        var preparation = try management.prepareCaptureOauthClientSecret(
            expected_generation,
            input,
        );
        return self.commitPreparedMutation(&preparation);
    }

    pub fn renameServer(
        self: *Runtime,
        expected_generation: u64,
        input: configuration.RenameServerInput,
    ) Error!configuration.ManagementOutcome {
        const management = self.mutableManagement(expected_generation, input.server_id) orelse
            return self.generationOutcome(expected_generation);
        var preparation = try management.prepareRenameServer(expected_generation, input);
        return self.commitPreparedMutation(&preparation);
    }

    pub fn approveConnection(
        self: *Runtime,
        expected_generation: u64,
        input: configuration.ApproveConnectionInput,
    ) Error!configuration.ManagementOutcome {
        const management = self.mutableManagement(expected_generation, input.server_id) orelse
            return self.generationOutcome(expected_generation);
        var preparation = try management.prepareApproveConnection(expected_generation, input);
        return self.commitPreparedMutation(&preparation);
    }

    pub fn setServerEnabled(
        self: *Runtime,
        expected_generation: u64,
        input: configuration.SetServerEnabledInput,
    ) Error!configuration.ManagementOutcome {
        const management = self.mutableManagement(expected_generation, input.server_id) orelse
            return self.generationOutcome(expected_generation);
        var preparation = try management.prepareSetServerEnabled(expected_generation, input);
        return self.commitPreparedMutation(&preparation);
    }

    pub fn setAllowedTools(
        self: *Runtime,
        expected_generation: u64,
        input: configuration.SetAllowedToolsInput,
    ) Error!configuration.ManagementOutcome {
        const management = self.mutableManagement(expected_generation, input.server_id) orelse
            return self.generationOutcome(expected_generation);
        var preparation = try management.prepareSetAllowedTools(expected_generation, input);
        return self.commitPreparedMutation(&preparation);
    }

    pub fn removeServer(
        self: *Runtime,
        expected_generation: u64,
        server_id: []const u8,
    ) Error!configuration.ManagementOutcome {
        const management = self.mutableManagement(expected_generation, server_id) orelse
            return self.generationOutcome(expected_generation);
        var preparation = try management.prepareRemoveServer(expected_generation, server_id);
        return self.commitPreparedMutation(&preparation);
    }

    fn mutableManagement(
        self: *Runtime,
        expected_generation: u64,
        server_id: ?[]const u8,
    ) ?*configuration.ManagementPort {
        if (self.shutting_down or self.refresh_job != null) return null;
        if (server_id) |id| if (policy.serverMutationBusy(&self.state, id)) return null;
        const management = if (self.state.management) |*value| value else return null;
        if (!policy.expectedGenerationMatches(management, expected_generation)) return null;
        return management;
    }

    fn generationOutcome(
        self: *const Runtime,
        expected_generation: u64,
    ) configuration.ManagementOutcome {
        if (self.shutting_down or self.refresh_job != null) return .rejected;
        const management = if (self.state.management) |*value| value else return .rejected;
        if (!policy.expectedGenerationMatches(management, expected_generation))
            return .stale_generation;
        return .rejected;
    }

    fn commitPreparedMutation(
        self: *Runtime,
        preparation: *configuration.MutationPreparation,
    ) Error!configuration.ManagementOutcome {
        switch (preparation.*) {
            .unchanged => return .unchanged,
            .rejected => return .rejected,
            .prepared => |*mutation| {
                defer mutation.deinit();
                if (self.state.configuration_apply_state == .applying) return .rejected;
                var candidate = try self.admissionForTarget(mutation.target());
                var candidate_owned = true;
                defer if (candidate_owned) candidate.deinit();
                const management = &self.state.management.?;
                const outcome = try management.commitPreparedMutation(mutation);
                const reported_outcome = if (outcome == .saved_recovery_required and
                    management.inspect().health == .outcome_unknown)
                    configuration.ManagementOutcome.indeterminate
                else
                    outcome;
                switch (reported_outcome) {
                    .saved, .saved_recovery_required => {
                        policy.installCommittedDesiredState(&self.state, management, candidate);
                        self.state.connection_test = null;
                        candidate_owned = false;
                        self.markChanged();
                    },
                    .indeterminate => {
                        self.state.connection_test = null;
                        policy.blockAdmission(&self.state, .persistence_outcome_unknown);
                        self.markChanged();
                    },
                    .rejected => if (management.inspect().health != .ready) {
                        policy.blockAdmissionForCurrentState(&self.state);
                        self.markChanged();
                    },
                    .unchanged, .stale_generation => unreachable,
                }
                return reported_outcome;
            },
        }
    }

    fn admissionForTarget(
        self: *Runtime,
        target: configuration.RegistryWire,
    ) Error!state_module.McpAdmissionAuthority {
        const management = &self.state.management.?;
        return switch (management.runtimeAlignmentFor(target)) {
            .restart_required => .{ .blocked = .pending_restart },
            .unknown => .{ .blocked = .alignment_unknown },
            .current => current: {
                if (self.state.activation_failed)
                    break :current .{ .blocked = .activation_unavailable };
                const activation = self.state.activation orelse break :current .{ .ready = .{
                    .selection = null,
                    .catalog_generation = null,
                } };
                const health = activation.serverHealth();
                const allowlists = try self.allocator.alloc(agent.McpServerAllowlist, health.len);
                defer self.allocator.free(allowlists);
                for (health, allowlists) |server, *allowlist| {
                    const desired = state_module.findMcpServer(target.servers, server.id) orelse
                        return error.McpCatalogBindingMismatch;
                    allowlist.* = .{
                        .id = server.id,
                        .tools = policy.serverToolsForAdmission(target, desired),
                    };
                }
                break :current .{ .ready = .{
                    .selection = try self.ports.catalog.createAdmissionSelection(
                        activation,
                        allowlists,
                    ),
                    .catalog_generation = activation.catalogGeneration(),
                } };
            },
        };
    }

    pub fn requireOauthReauthorization(
        self: *Runtime,
        failure: state_module.McpRuntimeAuthorizationFailure,
    ) Error!state_module.McpRuntimeAuthorizationFailureOutcome {
        if (self.shutting_down) return .rejected;
        if (self.refresh_job != null or self.state.configuration_apply_state == .applying) {
            self.runtime_auth_delivery_pending = true;
            return .pending;
        }
        if (self.state.authorization_operation) |operation|
            if (std.mem.eql(u8, operation.server_id, failure.server_id)) {
                self.runtime_auth_delivery_pending = true;
                return .pending;
            };
        const management = if (self.state.management) |*value| value else return .rejected;
        if (!failure.challenge_scopes_complete or
            !configuration.validOauthScopeSet(failure.challenge_scopes, management.limits))
            return error.McpOauthScopeCapacity;
        if (management.inspect().health != .ready) return .rejected;
        const registry = management.desiredRegistry() orelse return .rejected;
        if (registry.oauth_operation) |operation|
            if (std.mem.eql(u8, operation.server_id, failure.server_id))
                return .rejected;
        const server = state_module.findMcpServer(registry.servers, failure.server_id) orelse
            return .stale;
        const oauth = server.auth.oauth orelse return .stale;
        const consent = oauth.consent orelse return .stale;
        if (consent.epoch != failure.consent_epoch) return .stale;
        const scope_step_up = policy.scopeSetAddsRequirement(
            consent.scopes,
            failure.challenge_scopes,
        );
        if (std.mem.eql(u8, oauth.status, "reauth_required")) {
            var pending = if (failure.challenge_scopes.len != 0)
                try policy.preparePendingReauthorization(
                    self.allocator,
                    &self.state,
                    server.id,
                    consent.epoch,
                    failure.challenge_scopes,
                    management.limits.max_oauth_scopes,
                )
            else
                null;
            if (pending) |*replacement| {
                policy.installPendingReauthorization(&self.state, replacement);
                self.markChanged();
            }
            return .applied;
        }
        const grant = oauth.grant orelse return .stale;
        if (!std.mem.eql(u8, oauth.status, "ready") or
            grant.consent_epoch != consent.epoch or
            failure.token_revision > grant.token_revision or
            (!scope_step_up and failure.token_revision != grant.token_revision))
            return .stale;
        var pending = if (failure.challenge_scopes.len != 0)
            try policy.preparePendingReauthorization(
                self.allocator,
                &self.state,
                server.id,
                consent.epoch,
                failure.challenge_scopes,
                management.limits.max_oauth_scopes,
            )
        else
            null;
        var pending_owned = pending != null;
        defer if (pending_owned) pending.?.deinit();
        var preparation = try management.prepareRequireOauthReauthorization(
            registry.generation,
            .{
                .server_id = server.id,
                .consent_epoch = consent.epoch,
                .token_revision = grant.token_revision,
            },
        );
        const result: state_module.McpRuntimeAuthorizationFailureOutcome = switch (try self.commitPreparedMutation(&preparation)) {
            .saved, .saved_recovery_required => .applied,
            .indeterminate => .persistence_outcome_unknown,
            .rejected => .rejected,
            .unchanged, .stale_generation => unreachable,
        };
        if (result != .rejected) if (pending) |*replacement| {
            policy.installPendingReauthorization(&self.state, replacement);
            pending_owned = false;
            self.markChanged();
        };
        return result;
    }

    pub fn beginAuthorization(
        self: *Runtime,
        expected_generation: u64,
        server_id: []const u8,
        operation_id: []const u8,
    ) Error!?state_module.McpAuthorizationStart {
        if (operation_id.len == 0 or
            !self.canBeginAuthorization(expected_generation, server_id)) return null;
        const management = if (self.state.management) |*value| value else return null;
        const registry = management.desiredRegistry() orelse return null;
        const server = state_module.findMcpServer(registry.servers, server_id) orelse return null;
        const oauth = server.auth.oauth orelse return null;

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const owned = arena.allocator();
        const consent_scopes = if (oauth.consent) |consent| consent.scopes else &.{};
        const pending_scopes = if (oauth.consent) |consent|
            policy.pendingReauthorizationScopes(&self.state, server.id, consent.epoch)
        else
            &.{};
        const owned_operation_id = try owned.dupe(u8, operation_id);
        const owned_server_id = try owned.dupe(u8, server.id);
        const owned_endpoint = try owned.dupe(u8, server.transport.url orelse return null);
        const owned_registration_kind = try owned.dupe(u8, oauth.registration.kind);
        const owned_client_id = if (oauth.registration.client_id) |value|
            try owned.dupe(u8, value)
        else
            null;
        const owned_auth_method = if (oauth.registration.token_endpoint_auth_method) |value|
            try owned.dupe(u8, value)
        else
            null;
        const owned_additional_scopes = try state_module.ownMcpScopeUnion(
            owned,
            consent_scopes,
            pending_scopes,
            management.limits.max_oauth_scopes,
        );
        const result: state_module.McpAuthorizationStart = .{
            .arena = arena,
            .operation_id = owned_operation_id,
            .server_id = owned_server_id,
            .endpoint = owned_endpoint,
            .registration_kind = owned_registration_kind,
            .client_id = owned_client_id,
            .token_endpoint_auth_method = owned_auth_method,
            .additional_scopes = owned_additional_scopes,
        };
        const operation_server_id = try self.allocator.dupe(u8, server.id);
        errdefer self.allocator.free(operation_server_id);
        const operation_identity = try self.allocator.dupe(u8, operation_id);
        self.ports.timer.cancel();
        self.state.authorization_operation = .{
            .phase = .discovering,
            .server_id = operation_server_id,
            .operation_id = operation_identity,
        };
        self.markChanged();
        return result;
    }

    pub fn canBeginAuthorization(
        self: *const Runtime,
        expected_generation: u64,
        server_id: []const u8,
    ) bool {
        if (self.shutting_down or self.refresh_job != null or
            self.state.authorization_operation != null or
            self.state.configuration_apply_state == .applying)
            return false;
        const management = if (self.state.management) |*value| value else return false;
        if (!policy.expectedGenerationMatches(management, expected_generation) or
            management.inspect().health != .ready)
            return false;
        const registry = management.desiredRegistry() orelse return false;
        if (registry.oauth_operation != null) return false;
        const server = state_module.findMcpServer(registry.servers, server_id) orelse return false;
        const oauth = server.auth.oauth orelse return false;
        if (server.connection_approval == null or
            configuration.serverProblem(server, management.limits) != null or
            !std.mem.eql(u8, server.transport.kind, "streamable_http") or
            !std.mem.eql(u8, server.auth.kind, "oauth") or
            !(std.mem.eql(u8, oauth.status, "client_registration_required") or
                std.mem.eql(u8, oauth.status, "consent_required") or
                std.mem.eql(u8, oauth.status, "awaiting_tokens") or
                std.mem.eql(u8, oauth.status, "reauth_required")))
            return false;
        if (oauth.registration.client_id != null) {
            const method = oauth.registration.token_endpoint_auth_method orelse return false;
            if (!std.mem.eql(u8, method, "none") and
                oauth.registration.client_secret_ref == null)
                return false;
        }
        return true;
    }

    pub fn advanceAuthorization(
        self: *Runtime,
        operation_id: []const u8,
        phase: state_module.McpAuthorizationPhase,
    ) bool {
        if (self.shutting_down) return false;
        const operation = if (self.state.authorization_operation) |*value| value else return false;
        if (!std.mem.eql(u8, operation.operation_id, operation_id) or
            !policy.validAuthorizationTransition(operation.phase, phase))
            return false;
        operation.phase = phase;
        self.markChanged();
        return true;
    }

    pub fn finishAuthorization(self: *Runtime, operation_id: []const u8) bool {
        const operation = if (self.state.authorization_operation) |*value| value else return false;
        if (!std.mem.eql(u8, operation.operation_id, operation_id)) return false;
        operation.deinit(self.allocator);
        self.state.authorization_operation = null;
        self.releaseBoundary();
        self.markChanged();
        return true;
    }

    pub fn authorizeOauth(
        self: *Runtime,
        plan: state_module.McpOauthAuthorizationPlan,
    ) Error!state_module.McpOauthAuthorizationOutcome {
        if (self.shutting_down or plan.attempt_id == 0 or
            self.refresh_job != null or
            self.state.configuration_apply_state == .applying)
            return .rejected;
        if (!policy.authorizationAt(
            &self.state,
            plan.server_id,
            &.{ .awaiting_consent, .registering },
        )) return .rejected;
        const management = if (self.state.management) |*value| value else return .rejected;
        if (management.inspect().health != .ready) return .rejected;
        const before = management.desiredRegistry() orelse return .rejected;
        if (before.oauth_operation != null) return .rejected;
        const before_server = state_module.findMcpServer(before.servers, plan.server_id) orelse
            return .rejected;
        const before_oauth = before_server.auth.oauth orelse return .rejected;
        const consent_already_bound = if (before_oauth.consent) |consent|
            std.mem.eql(u8, before_oauth.status, "awaiting_tokens") and
                std.mem.eql(u8, consent.issuer, plan.issuer) and
                std.mem.eql(u8, consent.resource, plan.resource) and
                std.mem.eql(u8, consent.redirect_uri, plan.redirect_uri) and
                textSetsEqual(consent.scopes, plan.scopes)
        else
            false;
        if (!consent_already_bound) {
            var preparation = try management.prepareOauthConsent(
                before.generation,
                .{
                    .server_id = plan.server_id,
                    .resource = plan.resource,
                    .issuer = plan.issuer,
                    .scopes = plan.scopes,
                    .redirect_uri = plan.redirect_uri,
                },
            );
            switch (try self.commitPreparedMutation(&preparation)) {
                .saved, .saved_recovery_required => {},
                .indeterminate => return .persistence_outcome_unknown,
                .unchanged, .stale_generation, .rejected => return .rejected,
            }
        }
        const current = management.desiredRegistry() orelse return .rejected;
        const server = state_module.findMcpServer(current.servers, plan.server_id) orelse
            return .rejected;
        const oauth = server.auth.oauth orelse return .rejected;
        const consent = oauth.consent orelse return .rejected;
        const client_id = oauth.registration.client_id orelse return .rejected;
        if (!std.mem.eql(u8, oauth.status, "awaiting_tokens") or
            !std.mem.eql(u8, consent.issuer, plan.issuer) or
            !std.mem.eql(u8, consent.resource, plan.resource) or
            !std.mem.eql(u8, consent.redirect_uri, plan.redirect_uri) or
            !textSetsEqual(consent.scopes, plan.scopes))
            return .rejected;
        return .{ .ready = .{
            .attempt_id = plan.attempt_id,
            .server_id = server.id,
            .issuer = consent.issuer,
            .resource = consent.resource,
            .scopes = consent.scopes,
            .redirect_uri = consent.redirect_uri,
            .client_id = client_id,
        } };
    }

    pub fn beginOauthDynamicRegistration(
        self: *Runtime,
        consent: configuration.OauthConsentInput,
    ) Error!state_module.McpOauthOperationBeginOutcome {
        if (self.shutting_down or self.refresh_job != null or
            !policy.authorizationAt(&self.state, consent.server_id, &.{.awaiting_consent}))
            return .rejected;
        const management = if (self.state.management) |*value| value else return .rejected;
        const desired = management.desiredRegistry() orelse return .rejected;
        var preparation = switch (try management.prepareBeginDynamicRegistration(
            desired.generation,
            .{ .consent = consent },
        )) {
            .rejected => return .rejected,
            .prepared => |prepared| prepared,
        };
        return self.commitOauthOperationBegin(&preparation);
    }

    pub fn completeOauthDynamicRegistration(
        self: *Runtime,
        input: configuration.CompleteDynamicRegistrationInput,
    ) Error!configuration.ManagementOutcome {
        defer if (input.client_secret) |secret| std.crypto.secureZero(u8, secret);
        if (self.shutting_down or self.refresh_job != null or
            !policy.authorizationAt(&self.state, input.server_id, &.{.registering}))
            return .rejected;
        const management = if (self.state.management) |*value| value else return .rejected;
        var preparation = try management.prepareCompleteDynamicRegistration(input);
        const outcome = try self.commitPreparedMutation(&preparation);
        switch (outcome) {
            .saved, .saved_recovery_required => self.releaseBoundary(),
            else => {},
        }
        return outcome;
    }

    pub fn beginOauthCodeExchange(
        self: *Runtime,
        server_id: []const u8,
    ) Error!state_module.McpOauthCodeExchangeBeginOutcome {
        if (self.shutting_down or self.refresh_job != null or
            self.state.configuration_apply_state == .applying or
            !policy.authorizationAt(&self.state, server_id, &.{.awaiting_browser}))
            return .rejected;
        const management = if (self.state.management) |*value| value else return .rejected;
        const desired = management.desiredRegistry() orelse return .rejected;
        var preparation = switch (try management.prepareBeginCodeExchange(
            desired.generation,
            .{ .server_id = server_id },
        )) {
            .rejected => return .rejected,
            .prepared => |prepared| prepared,
        };
        const outcome = try self.commitOauthOperationBegin(&preparation);
        const handle = switch (outcome) {
            .started => |value| value,
            .rejected => return .rejected,
            .persistence_outcome_unknown => return .persistence_outcome_unknown,
        };
        const current = management.desiredRegistry() orelse return .rejected;
        const server = state_module.findMcpServer(current.servers, server_id) orelse return .rejected;
        const oauth = server.auth.oauth orelse return .rejected;
        const consent = oauth.consent orelse return .rejected;
        return .{ .started = .{
            .operation = handle,
            .issuer = consent.issuer,
            .client_id = oauth.registration.client_id orelse return .rejected,
            .token_endpoint_auth_method = oauth.registration.token_endpoint_auth_method orelse
                return .rejected,
            .client_secret_ref = oauth.registration.client_secret_ref,
            .resource = consent.resource,
            .redirect_uri = consent.redirect_uri,
        } };
    }

    pub fn completeOauthCodeExchange(
        self: *Runtime,
        input: configuration.CompleteCodeExchangeInput,
    ) Error!configuration.ManagementOutcome {
        defer std.crypto.secureZero(u8, input.access_token);
        defer if (input.refresh_token) |secret| std.crypto.secureZero(u8, secret);
        if (self.shutting_down or self.refresh_job != null or
            !policy.authorizationAt(&self.state, input.server_id, &.{.exchanging}))
            return .rejected;
        const management = if (self.state.management) |*value| value else return .rejected;
        var preparation = try management.prepareCompleteCodeExchange(input);
        const outcome = try self.commitPreparedMutation(&preparation);
        switch (outcome) {
            .saved, .saved_recovery_required => self.releaseBoundary(),
            else => {},
        }
        return outcome;
    }

    fn commitOauthOperationBegin(
        self: *Runtime,
        preparation: *configuration.PreparedOauthOperationState,
    ) Error!state_module.McpOauthOperationBeginOutcome {
        defer preparation.deinit();
        var reduced = try self.admissionForTarget(preparation.target());
        var reduced_owned = true;
        defer if (reduced_owned) reduced.deinit();
        if (reduced != .ready) return .rejected;
        const management = &self.state.management.?;
        switch (try management.commitPreparedOauthOperationState(preparation)) {
            .saved => {
                self.ports.timer.cancel();
                policy.installCommittedDesiredState(&self.state, management, reduced);
                reduced_owned = false;
                self.markChanged();
                const registry = management.desiredRegistry() orelse return .rejected;
                const operation = registry.oauth_operation orelse return .rejected;
                return .{ .started = .{
                    .id = operation.id,
                    .server_id = operation.server_id,
                } };
            },
            .indeterminate => {
                self.ports.timer.cancel();
                policy.blockAdmission(&self.state, .persistence_outcome_unknown);
                self.markChanged();
                return .persistence_outcome_unknown;
            },
            .rejected => return .rejected,
            .unchanged, .stale_generation, .saved_recovery_required => unreachable,
        }
    }

    pub fn beginOauthRefresh(
        self: *Runtime,
        server_id: []const u8,
    ) Error!state_module.McpOauthRefreshBeginOutcome {
        if (self.shutting_down or !self.state.committed or self.refresh_job != null or
            self.state.configuration_apply_state == .applying or
            self.state.authorization_operation != null)
            return .rejected;
        const management = if (self.state.management) |*value| value else return .rejected;
        const inspection = management.inspect();
        if (inspection.health != .ready or inspection.runtime_alignment != .current or
            self.state.activation_failed)
            return .rejected;
        const activation = self.state.activation orelse return .rejected;
        var runtime_loaded = false;
        for (activation.serverHealth()) |server| {
            if (!std.mem.eql(u8, server.id, server_id)) continue;
            runtime_loaded = true;
            break;
        }
        if (!runtime_loaded) return .rejected;
        const desired = management.desiredRegistry() orelse return .rejected;
        var preparation = switch (try management.prepareBeginRefresh(
            desired.generation,
            .{ .server_id = server_id },
        )) {
            .rejected => return .rejected,
            .prepared => |prepared| prepared,
        };
        defer preparation.deinit();
        var reduced = try self.admissionForTarget(preparation.target());
        var reduced_owned = true;
        defer if (reduced_owned) reduced.deinit();
        if (reduced != .ready) return .rejected;
        var binding = try policy.buildOauthRefreshBinding(self.allocator, preparation.target());
        var binding_owned = true;
        defer if (binding_owned) binding.deinit();
        switch (try management.commitPreparedOauthOperationState(&preparation)) {
            .saved => {
                self.ports.timer.cancel();
                policy.installCommittedDesiredState(&self.state, management, reduced);
                reduced_owned = false;
                binding_owned = false;
                self.markChanged();
                return .{ .started = binding };
            },
            .indeterminate => {
                self.ports.timer.cancel();
                policy.blockAdmission(&self.state, .persistence_outcome_unknown);
                self.markChanged();
                return .persistence_outcome_unknown;
            },
            .rejected => return .rejected,
            .unchanged, .stale_generation, .saved_recovery_required => unreachable,
        }
    }

    pub fn completeOauthRefresh(
        self: *Runtime,
        input: configuration.CompleteRefreshInput,
        runtime_commit: state_module.McpOauthRuntimeCommit,
    ) Error!configuration.ManagementOutcome {
        defer std.crypto.secureZero(u8, input.access_token);
        defer if (input.refresh_token) |secret| std.crypto.secureZero(u8, secret);
        if (self.shutting_down or self.refresh_job != null) return .rejected;
        const management = if (self.state.management) |*value| value else return .rejected;
        var preparation = try management.prepareCompleteRefresh(input);
        switch (preparation) {
            .unchanged, .rejected => return .rejected,
            .prepared => |*mutation| {
                defer mutation.deinit();
                var candidate = try self.admissionForTarget(mutation.target());
                var candidate_owned = true;
                defer if (candidate_owned) candidate.deinit();
                const outcome = try management.commitPreparedMutation(mutation);
                const reported_outcome = if (outcome == .saved_recovery_required and
                    management.inspect().health == .outcome_unknown)
                    configuration.ManagementOutcome.indeterminate
                else
                    outcome;
                switch (reported_outcome) {
                    .saved, .saved_recovery_required => {
                        runtime_commit.commit();
                        policy.installCommittedDesiredState(&self.state, management, candidate);
                        candidate_owned = false;
                        self.releaseBoundary();
                        self.markChanged();
                    },
                    .indeterminate => {
                        policy.blockAdmission(&self.state, .persistence_outcome_unknown);
                        self.markChanged();
                    },
                    .rejected => if (management.inspect().health != .ready) {
                        policy.blockAdmissionForCurrentState(&self.state);
                        self.markChanged();
                    },
                    .unchanged, .stale_generation => unreachable,
                }
                return reported_outcome;
            },
        }
    }

    pub fn clearOauthOperation(
        self: *Runtime,
        operation_id: []const u8,
    ) Error!configuration.ManagementOutcome {
        if (self.shutting_down or self.refresh_job != null) return .rejected;
        const management = if (self.state.management) |*value| value else return .rejected;
        var preparation = switch (try management.prepareClearOauthOperation(operation_id)) {
            .rejected => return .rejected,
            .prepared => |prepared| prepared,
        };
        defer preparation.deinit();
        var candidate = try self.admissionForTarget(preparation.target());
        var candidate_owned = true;
        defer if (candidate_owned) candidate.deinit();
        const outcome = try management.commitPreparedOauthOperationState(&preparation);
        switch (outcome) {
            .saved => {
                policy.installCommittedDesiredState(&self.state, management, candidate);
                candidate_owned = false;
                self.releaseBoundary();
                self.markChanged();
            },
            .indeterminate => {
                policy.blockAdmission(&self.state, .persistence_outcome_unknown);
                self.markChanged();
            },
            .rejected => {},
            .unchanged, .stale_generation, .saved_recovery_required => unreachable,
        }
        return outcome;
    }

    pub fn recoverOauthOperation(
        self: *Runtime,
        operation_id: []const u8,
    ) Error!configuration.ManagementOutcome {
        if (self.shutting_down or self.refresh_job != null) return .rejected;
        const management = if (self.state.management) |*value| value else return .rejected;
        var preparation = try management.prepareOauthOperationRecovery(operation_id);
        const outcome = try self.commitPreparedMutation(&preparation);
        switch (outcome) {
            .saved, .saved_recovery_required => self.releaseBoundary(),
            else => {},
        }
        return outcome;
    }

    pub fn nextOauthExpiry(self: *const Runtime) ?state_module.McpOauthExpiry {
        if (self.shutting_down) return null;
        return policy.nextOauthExpiry(&self.state);
    }

    pub fn updateRefreshDeadline(self: *Runtime) void {
        self.state.refresh_deadline_ms = null;
        const activation = self.state.activation orelse return;
        self.state.refresh_deadline_ms = state_module.mcpRefreshDeadlineMs(
            activation.catalogServers(),
            self.ports.timer.now(),
        );
    }

    fn releaseBoundary(self: *Runtime) void {
        self.rearmRefreshTimer();
        if (!self.runtime_auth_delivery_pending or self.shutting_down) return;
        if (self.ports.notifier.notify())
            self.runtime_auth_delivery_pending = false;
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

fn textSetsEqual(left: []const []const u8, right: []const []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_value, right_value|
        if (!std.mem.eql(u8, left_value, right_value)) return false;
    return true;
}

fn writeQuotedField(
    writer: *std.Io.Writer,
    label: []const u8,
    value: []const u8,
) !void {
    try writer.print("{s}: ", .{label});
    try std.json.Stringify.value(value, .{}, writer);
    try writer.writeByte('\n');
}

fn writeQuotedListItem(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeAll("  ");
    try std.json.Stringify.value(value, .{}, writer);
    try writer.writeByte('\n');
}

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

    fn activate(_: *anyopaque) ports_module.CatalogError!agent.McpActivationOutcome {
        return .empty;
    }

    fn createAdmissionSelection(
        _: *anyopaque,
        _: *const agent.McpActivation,
        _: []const agent.McpServerAllowlist,
    ) ports_module.CatalogError!?*agent.McpSelection {
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

fn fillTestMcpIdentity(_: ?*anyopaque, bytes: *[16]u8) bool {
    bytes.* = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    return true;
}

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

test "Product MCP Runtime releases a prepared mutation rejected during apply" {
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
            .identity_generator = .{
                .available = true,
                .fill_fn = fillTestMcpIdentity,
            },
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
    try std.testing.expectEqual(
        configuration.ManagementOutcome.rejected,
        try runtime.createHttpServer(1, .{
            .display_name = "Prepared while applying",
            .url = "https://mcp.example.test/rpc",
        }),
    );
    try std.testing.expectEqual(@as(u64, 1), runtime.state.management.?.inspect().desired_generation);
}

test "Product MCP Runtime wakes retained auth delivery when apply releases the boundary" {
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
    try std.testing.expectEqual(
        state_module.McpRuntimeAuthorizationFailureOutcome.pending,
        try runtime.requireOauthReauthorization(.{
            .server_id = "oauth-server",
            .consent_epoch = 1,
            .token_revision = 1,
            .challenge_scopes = &.{},
            .challenge_scopes_complete = true,
        }),
    );
    try std.testing.expect(runtime.runtime_auth_delivery_pending);
    try std.testing.expectEqual(@as(usize, 0), harness.notifications);
    try std.testing.expect(runtime.failConfigurationApply(1));
    try std.testing.expect(!runtime.runtime_auth_delivery_pending);
    try std.testing.expectEqual(@as(usize, 1), harness.notifications);
}
