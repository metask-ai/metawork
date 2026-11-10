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
const installation = @import("installation.zig");

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
    secret_max_bytes: usize = 0,
};
pub const NewTaskAdmission = struct {
    available: bool,
    selection: ?*const agent.McpSelection,
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
    installation_mailbox: installation.Mailbox,
    installation_request: ?installation.Payload = null,
    installation_notice: bool = false,
    installation_notice_task: u64 = 0,
    installation_notice_run: u64 = 0,
    refresh_job: ?*refresh_job.Job = null,
    runtime_auth_delivery_pending: bool = false,
    shutting_down: bool = false,
    changed: bool = false,

    fn init(
        allocator: std.mem.Allocator,
        ports: ports_module.Ports,
        initial_state: state_module.McpProductState,
    ) Runtime {
        var runtime: Runtime = .{
            .allocator = allocator,
            .ports = ports,
            .state = initial_state,
            .installation_mailbox = .{ .allocator = allocator, .notifier = ports.notifier },
        };
        runtime.observeOauthTime();
        return runtime;
    }

    fn observeOauthTime(self: *Runtime) void {
        if (self.state.management) |*management|
            management.oauth_schedule.observeTime(self.ports.unix_clock.nowMs());
    }

    fn installCommittedDesired(self: *Runtime, admission: McpAdmissionAuthority) void {
        self.observeOauthTime();
        policy.installCommittedDesiredState(&self.state, &self.state.management.?, admission);
        self.finishConvergence();
    }

    pub fn deinit(self: *Runtime) void {
        if (self.installation_request) |*value| value.deinit();
        self.installation_mailbox.deinit();
        std.debug.assert(self.refresh_job == null);
        self.ports.timer.cancel();
        self.state.deinit();
        self.* = undefined;
    }

    pub fn hasRefreshJob(self: *const Runtime) bool {
        return self.refresh_job != null;
    }

    /// Capture availability together with the synchronous Selection borrow,
    /// rather than sampling readiness again after copying that pointer.
    pub fn selectionForNewTask(self: *Runtime) NewTaskAdmission {
        self.expireAdmission();
        if (self.shutting_down or !self.state.committed or self.state.admission != .ready or self.admissionExpired())
            return .{ .available = false, .selection = null };
        const selection = policy.selectionForNewTask(&self.state);
        if (selection == null and self.state.admission.ready.selection != null)
            return .{ .available = false, .selection = null };
        return .{ .available = true, .selection = selection };
    }

    pub fn newTaskAuthorityReady(self: *const Runtime) bool {
        return !self.shutting_down and self.state.committed and self.state.admission == .ready and !self.admissionExpired();
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
            .secret_max_bytes = if (management)
                self.state.management.?.limits.max_credential_secret_bytes
            else
                0,
        };
    }

    pub fn recoveryGeneration(self: *const Runtime) ?u64 {
        if (!self.authorityStable()) return null;
        return policy.recoveryGeneration(&self.state, self.refresh_job != null);
    }

    pub fn authorityStable(self: *const Runtime) bool {
        return self.state.admissionFresh() and !self.admissionExpired();
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

    /// Rebind the original Task's exact selectors under today's Product grants.
    /// Null original authority stays null even while unrelated MCP state moves.
    pub fn restoreAuthority(self: *Runtime, original: ?*const agent.McpRestoreSelection) Error!state_module.RecoveryMcpAuthority {
        const saved = original orelse return .{ .selection = null, .catalog_generation = null };
        var current = try self.recoveryAuthority();
        defer current.deinit();
        const activation = self.state.activation orelse return error.RecoveryUnavailable;
        return .{
            .selection = try self.ports.catalog.prepareRestoreSelection(saved, activation, if (current.selection) |selection| selection.selectedTools() else &.{}),
            .catalog_generation = current.catalog_generation,
        };
    }

    pub fn retainTaskReference(self: *Runtime, task_id: u64, selection: ?*const agent.McpSelection) Error!void {
        const selected = selection orelse return;
        if (selected.selectedTools().len == 0) return;
        for (self.state.task_references.items) |reference| if (reference.task_id == task_id) return error.InvalidMcpSelection;
        const registry = self.state.preparation.registry orelse return error.InvalidMcpSelection;
        var reference = try state_module.McpTaskReference.init(self.allocator, task_id, selected, registry.value.servers);
        errdefer reference.deinit();
        if (self.state.management) |*management| if (management.desiredRegistry()) |desired| reference.reconcile(desired);
        try self.state.task_references.append(self.allocator, reference);
        self.updateMemberReferenceCounts();
    }

    pub fn releaseTaskReference(self: *Runtime, task_id: u64) void {
        for (self.state.task_references.items, 0..) |reference, index| {
            if (reference.task_id != task_id) continue;
            var removed = self.state.task_references.orderedRemove(index);
            removed.deinit();
            self.updateMemberReferenceCounts();
            self.markChanged();
            if (!self.shutting_down) if (self.state.management) |*management| if (management.runtime_manifest) |*manifest| {
                if (manifest.nextStep(management.desiredRegistry(), management.limits, &management.convergence) != null)
                    _ = self.ports.notifier.notify();
            };
            return;
        }
    }

    fn updateMemberReferenceCounts(self: *Runtime) void {
        const management = if (self.state.management) |*value| value else return;
        const manifest = if (management.runtime_manifest) |*value| value else return;
        for (manifest.entries) |*entry| {
            entry.task_references = 0;
            if (entry.state != .loaded) continue;
            for (self.state.task_references.items) |reference| {
                for (reference.tools) |tool| {
                    if (std.mem.eql(u8, tool.server_id, entry.id)) {
                        entry.task_references += 1;
                        break;
                    }
                }
            }
        }
    }

    /// Restore only this process-lifetime Task cap; unrelated Desired rows
    /// cannot invalidate it and a deleted row cannot resurrect a revoked tool.
    pub fn restoreAuthorityForTask(self: *Runtime, task_id: u64, original: ?*const agent.McpRestoreSelection) Error!state_module.RecoveryMcpAuthority {
        const saved = original orelse return .{ .selection = null, .catalog_generation = null };
        if (saved.isEmpty()) return .{ .selection = null, .catalog_generation = null };
        if (self.shutting_down or self.state.runtime_uncertain or self.state.activation_failed or !self.state.committed) return error.RecoveryUnavailable;
        const management = if (self.state.management) |*value| value else return error.RecoveryUnavailable;
        if (management.inspect().health != .ready) return error.RecoveryUnavailable;
        const desired = management.desiredRegistry() orelse return error.RecoveryUnavailable;
        const activation = self.state.activation orelse return error.RecoveryUnavailable;
        const reference = for (self.state.task_references.items) |*value| {
            if (value.task_id == task_id) break value;
        } else return error.RecoveryUnavailable;
        var tools: std.ArrayList(agent.McpActivationTool) = .empty;
        defer tools.deinit(self.allocator);
        const age_ms = activation.catalogAgeMs() orelse return error.RecoveryUnavailable;
        for (reference.tools) |tool| {
            if (state_module.findMcpServer(desired.servers, tool.server_id)) |server| {
                if (server.enabled and !std.mem.eql(u8, &tool.fingerprint, &configuration.runtimeDescriptorFingerprint(server))) return error.RecoveryUnavailable;
            }
            if (!tool.allowed) continue;
            const binding = for (activation.serverHealth()) |health| {
                if (std.mem.eql(u8, health.id, tool.server_id)) break health.binding_identity;
            } else continue;
            const fresh = for (activation.catalogServers()) |server| {
                if (std.mem.eql(u8, &server.binding_identity, &binding)) break server.fresh and age_ms < server.ttl_remaining_ms;
            } else false;
            if (fresh) try tools.append(self.allocator, .{ .server_id = tool.server_id, .name = tool.name });
        }
        return .{
            .selection = self.ports.catalog.prepareRestoreSelection(saved, activation, tools.items) catch |err| switch (err) {
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
        var inspection = management.inspect();
        inspection.authorization_recovery_pending = policy.authorizationRecoveryPending(&self.state);
        return inspection;
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
            try writeQuotedField(&writer, "Endpoint", configuration.endpointDisplay(server.transport));
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

    pub fn validateSecretCapture(
        self: *const Runtime,
        expected_generation: u64,
        server_id: []const u8,
        target: state_module.McpSecretCaptureTarget,
    ) !void {
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
        switch (target) {
            .stdio_environment => |requested_name| {
                if (!std.mem.eql(u8, server.auth.kind, "static") or
                    !std.mem.eql(u8, server.transport.kind, "stdio"))
                    return error.McpManagementUnavailable;
                for (server.transport.environment) |slot| {
                    if (!std.ascii.eqlIgnoreCase(slot.name, requested_name)) continue;
                    return;
                }
                return error.McpManagementUnavailable;
            },
            .http_header => |requested_name| {
                if (!std.mem.eql(u8, server.auth.kind, "static") or
                    !std.mem.eql(u8, server.transport.kind, "streamable_http"))
                    return error.McpManagementUnavailable;
                for (server.transport.headers) |slot| {
                    if (!std.ascii.eqlIgnoreCase(slot.name, requested_name)) continue;
                    return;
                }
                return error.McpManagementUnavailable;
            },
            .installation_credential => |name| {
                const operation = server.installation orelse return error.McpManagementUnavailable;
                if (operation.phase != .needs_credentials) return error.McpManagementUnavailable;
                for (operation.credentials) |slot| if (slot.manual and std.mem.eql(u8, slot.name, name)) return;
                return error.McpManagementUnavailable;
            },
            .oauth_client_secret => {
                if (registry.oauth_operation != null) return error.McpManagementUnavailable;
                const oauth = server.auth.oauth orelse return error.McpManagementUnavailable;
                const method = oauth.registration.token_endpoint_auth_method orelse
                    return error.McpManagementUnavailable;
                if (!std.mem.eql(u8, oauth.registration.kind, "pre_registered") or
                    std.mem.eql(u8, method, "none") or oauth.registration.client_id == null)
                    return error.McpManagementUnavailable;
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
        self.state.refresh_failures = 0;
        self.state.refresh_paused = false;
        return self.queueRefresh(invalidate_admission, true);
    }

    fn queueRefresh(self: *Runtime, invalidate_admission: bool, visible: bool) Error!bool {
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
        mcp.refresh_visible = mcp.refresh_visible or visible;
        if (invalidate_admission) policy.blockAdmission(mcp, .refreshing);
        if (self.refresh_job != null or mcp.refresh_pending) {
            self.rearmRefreshTimer();
            return false;
        }
        if (mcp.refresh_request_generation == std.math.maxInt(u64))
            return error.CatalogRequestGenerationExhausted;
        self.ports.timer.cancel();
        mcp.refresh_request_generation += 1;
        mcp.refresh_pending = true;
        const started = self.startPendingRefresh() catch |err| {
            self.armRefreshRetry();
            return err;
        };
        self.rearmRefreshTimer();
        return started;
    }

    fn catalogBoundaryBusy(self: *const Runtime) bool {
        if (self.refresh_job != null or self.state.configuration_apply_state == .applying) return true;
        const management = if (self.state.management) |*value| value else return false;
        const registry = management.desiredRegistry() orelse return false;
        return registry.oauth_operation != null;
    }

    fn startPendingRefresh(self: *Runtime) Error!bool {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        const mcp = &self.state;
        if (mcp.runtime_uncertain) return error.CatalogUnavailable;
        if (!mcp.refresh_pending) return false;
        if (self.catalogBoundaryBusy()) return false;
        const management = if (mcp.management) |*value| value else return error.CatalogUnavailable;
        const inspection = management.inspect();
        if (inspection.health != .ready) return error.McpManagementUnavailable;
        const desired = management.desiredRegistry() orelse
            return error.McpManagementUnavailable;
        if (self.ports.timer.now()) |now_ms| if (mcp.refresh_not_before_ms) |not_before|
            if (now_ms < not_before) return false;
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
            .arena = refresh_arena,
            .allowlists = allowlists,
            .build_admission = !self.state.runtime_uncertain,
        };
        try self.ports.executor.enqueue(job.executorJob());
        mcp.refresh_pending = false;
        self.refresh_job = job;
        return true;
    }

    pub fn onRefreshTimer(self: *Runtime) bool {
        if (self.shutting_down) return false;
        self.expireAdmission();
        if (self.refresh_job != null) {
            self.rearmRefreshTimer();
            return true;
        }
        if (self.state.refresh_pending) {
            _ = self.startPendingRefresh() catch self.armRefreshRetry();
            self.rearmRefreshTimer();
            return true;
        }
        if (self.state.refresh_paused) return true;
        if (self.state.refresh_deadline_ms) |deadline| if (self.ports.timer.now()) |now_ms|
            if (now_ms < deadline) {
                self.rearmRefreshTimer();
                return true;
            };
        _ = self.queueRefresh(false, false) catch {
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
                        if (job.build_admission) {
                            policy.replaceAdmission(&self.state, .{ .ready = .{
                                .selection = activated.selection,
                                .catalog_generation = activated.activation.catalogGeneration(),
                            } });
                        } else {
                            policy.blockAdmissionForCurrentState(&self.state);
                        }
                        job.outcome = .empty;
                        self.state.refresh_visible = false;
                        self.state.refresh_schedule_failed = false;
                        self.updateRefreshDeadline();
                        if (activated.activation.state() == .unavailable or (job.build_admission and !self.state.admissionFresh()))
                            self.recordRefreshFailure()
                        else {
                            self.state.refresh_failures = 0;
                            self.state.refresh_paused = false;
                        }
                    }
                },
                .empty => if (still_current) {
                    if (self.state.activation) |old| old.deinit();
                    self.state.activation = null;
                    self.state.activation_failed = false;
                    self.state.refresh_deadline_ms = null;
                    self.state.expiry_deadline_ms = null;
                    self.state.refresh_failures = 0;
                    self.state.refresh_paused = false;
                    self.state.refresh_visible = false;
                    self.state.refresh_schedule_failed = false;
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
                    self.state.expiry_deadline_ms = null;
                    self.state.refresh_visible = false;
                    policy.blockAdmission(&self.state, .activation_unavailable);
                    self.recordRefreshFailure();
                },
                .retained => if (still_current) {
                    // Only the typed pre-publication rejection proves Core
                    // kept its catalog. The original deadline still applies.
                    self.state.refresh_visible = false;
                    self.expireAdmission();
                    self.recordRefreshFailure();
                },
            },
            .cancelled => {},
            .queued, .running => unreachable,
        }
        if (still_current) {
            if (self.ports.timer.now()) |now_ms|
                self.state.refresh_not_before_ms = @max(self.state.refresh_not_before_ms orelse 0, now_ms +| 1_000);
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

    /// Freeze one real membership change and reserve its completion record.
    /// The returned snapshot is the complete candidate Runtime, not Desired.
    pub fn prepareConfigurationStep(
        self: *Runtime,
        expected_generation: u64,
        intent: configuration.RuntimeApplyIntent,
    ) Error!?configuration.RuntimeApplyStep {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        if (self.state.runtime_uncertain) return error.McpManagementUnavailable;
        if (self.catalogBoundaryBusy() or self.state.authorization_operation != null)
            return error.CatalogLoading;
        const management = if (self.state.management) |*value| value else return error.McpManagementUnavailable;
        if (management.inspect().health != .ready) return error.McpManagementUnavailable;
        const desired = management.desiredRegistry() orelse return error.McpManagementUnavailable;
        if (desired.generation != expected_generation or desired.oauth_operation != null)
            return error.McpManagementUnavailable;
        switch (intent) {
            .automatic => {},
            .retry_all => {
                for (desired.servers) |server| self.requestRejectedGrantRefresh(server);
                management.convergence.retry();
            },
            .retry_server => |id| {
                const server = state_module.findMcpServer(desired.servers, id) orelse return error.McpManagementUnavailable;
                self.requestRejectedGrantRefresh(server);
                management.convergence.retryServer(id);
            },
        }
        if (self.state.refresh_pending and try self.startPendingRefresh()) return error.CatalogLoading;
        if (self.ports.timer.now()) |now_ms| {
            if (self.state.refresh_deadline_ms) |deadline| {
                if (!self.state.refresh_paused and now_ms >= deadline and now_ms >= (self.state.refresh_not_before_ms orelse 0)) {
                    if (try self.queueRefresh(false, false)) return error.CatalogLoading;
                }
            }
        }
        var members: std.ArrayList(configuration.ServerWire) = .empty;
        defer members.deinit(self.allocator);
        const manifest = if (management.runtime_manifest) |*value| value else return error.McpManagementUnavailable;
        for (manifest.entries) |entry| {
            if (entry.state != .loaded) continue;
            const saved = self.state.preparation.registry orelse return error.McpManagementUnavailable;
            const server = state_module.findMcpServer(saved.value.servers, entry.id) orelse return error.McpManagementUnavailable;
            if (!std.mem.eql(u8, &configuration.runtimeDescriptorFingerprint(server), &entry.state.loaded))
                return error.McpManagementUnavailable;
            try members.append(self.allocator, server);
        }
        const plan = manifest.nextStep(desired, management.limits, &management.convergence) orelse {
            self.finishConvergence();
            return null;
        };
        if (plan.next_round) std.debug.assert(management.convergence.nextRound());
        const selected = plan.target;
        const existing = for (members.items, 0..) |member, index| {
            if (std.mem.eql(u8, member.id, selected.id())) break index;
        } else null;
        switch (selected.kind) {
            .remove => {
                _ = members.orderedRemove(existing orelse return error.McpManagementUnavailable);
            },
            .replace => members.items[existing orelse return error.McpManagementUnavailable] = state_module.findMcpServer(desired.servers, selected.id()) orelse return error.McpManagementUnavailable,
            .add => try members.append(self.allocator, state_module.findMcpServer(desired.servers, selected.id()) orelse return error.McpManagementUnavailable),
        }
        try management.convergence.prepare(self.allocator, selected);
        if (selected.kind != .remove) {
            const server = state_module.findMcpServer(desired.servers, selected.id()) orelse return error.McpManagementUnavailable;
            if (server.auth.oauth) |oauth| if (oauth.grant) |grant| {
                const expired = if (grant.expires_at_unix_ms) |expiry| if (self.ports.unix_clock.nowMs()) |now_ms| now_ms >= expiry else false else false;
                if (expired or management.oauth_schedule.refreshRequested(server.id)) {
                    // A live nonrefreshable grant must not be retired by local
                    // time. Its replacement has no automatic recovery route:
                    // report failure so the user can retry or authorize again.
                    const outcome: configuration.RuntimeConvergence.Outcome = if (selected.kind == .replace and grant.refresh_token_ref == null) .failed else .waiting_auth;
                    management.convergence.reject(selected, outcome);
                    self.markChanged();
                    return self.prepareConfigurationStep(expected_generation, .automatic);
                }
            };
        }
        var step = configuration.RuntimeApplyStep.init(self.allocator, desired, members.items, selected, management.limits) catch |err| {
            // A rejected composition has no Core effect, but is still a processed
            // attempt. Keep R intact and let the next candidate make progress.
            management.convergence.reject(selected, if (members.items.len > management.limits.max_servers) .capacity else .failed);
            self.state.configuration_apply_state = .failed;
            self.markChanged();
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return self.prepareConfigurationStep(expected_generation, .automatic);
        };
        errdefer step.deinit();
        _ = try self.beginConfigurationApply(expected_generation);
        self.state.apply_target = selected;
        self.markChanged();
        return step;
    }

    fn requestRejectedGrantRefresh(self: *Runtime, server: configuration.ServerWire) void {
        if (!server.enabled) return;
        const oauth = server.auth.oauth orelse return;
        const grant = oauth.grant orelse return;
        if (grant.refresh_token_ref == null) return;
        const management = &self.state.management.?;
        const manifest = management.runtime_manifest orelse return;
        const target = manifest.targetFor(server.id, management.desiredRegistry(), management.limits) orelse configuration.RuntimeApplyTarget.init(server.id, server, .replace);
        if (management.convergence.httpAuthRejected(target)) management.oauth_schedule.requestRefresh(server.id);
    }

    fn finishConvergence(self: *Runtime) void {
        if (self.shutting_down or self.state.configuration_apply_state == .applying or self.state.runtime_uncertain) return;
        const management = if (self.state.management) |*value| value else return;
        if (management.inspect().health != .ready) return;
        const manifest = if (management.runtime_manifest) |*value| value else return;
        management.convergence.discardObsolete(manifest, management.desiredRegistry(), management.limits);
        const apply_state: McpConfigurationApplyState = if (manifest.failureCount(management.desiredRegistry(), management.limits, &management.convergence) != 0) .failed else .idle;
        if (self.state.configuration_apply_state != apply_state) {
            self.state.configuration_apply_state = apply_state;
            self.markChanged();
        }
        if (self.state.admission == .blocked and self.state.admission.blocked == .pending_restart) {
            if (manifest.nextStep(management.desiredRegistry(), management.limits, &management.convergence) != null) return;
            const desired = management.desiredRegistry() orelse return;
            const admission: McpAdmissionAuthority = self.admissionForTarget(desired) catch .{ .blocked = .activation_unavailable };
            policy.replaceAdmission(&self.state, admission);
            self.updateAdmissionDeadline();
            self.markChanged();
        }
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
        self.state.configuration_apply_state = .applying;
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
        if (self.shutting_down) {
            // Core already took the configuration. Accept its Manifest below,
            // but do not recreate leases released by beginShutdown.
            if (selection) |value| value.deinit();
            if (activation) |value| value.deinit();
            self.state.activation = null;
            self.state.activation_failed = true;
        } else {
            self.state.activation = activation;
            self.state.activation_failed = activation_failed;
        }
        self.state.preparation.deinit();
        self.state.preparation = preparation.take();
        management.installRuntimeManifest(manifest);
        self.updateMemberReferenceCounts();
        if (self.state.apply_target) |target| management.convergence.applied(target);
        self.state.apply_target = null;
        self.state.configuration_apply_state = .idle;
        self.state.refresh_pending = false;
        self.state.refresh_failures = 0;
        self.state.refresh_paused = false;
        self.state.refresh_visible = false;
        if (self.shutting_down) {
            policy.blockAdmission(&self.state, .shutting_down);
        } else if (activation_failed) {
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
        self.finishConvergence();
        if (activation_failed and !self.shutting_down)
            _ = self.queueRefresh(false, false) catch self.armRefreshRetry();
        self.releaseBoundary();
        return true;
    }

    pub fn failConfigurationApply(self: *Runtime, expected_generation: u64, reason: configuration.RuntimeApplyFailure) bool {
        if (self.state.configuration_apply_state != .applying) return false;
        const management = if (self.state.management) |*value| value else return false;
        if (management.inspect().desired_generation != expected_generation) return false;
        const targeted = self.state.apply_target != null;
        if (self.state.apply_target) |target| {
            if (reason != .unknown) management.convergence.reject(target, if (reason == .rejected) .rejected else .failed);
        }
        self.state.apply_target = null;
        self.state.configuration_apply_state = .failed;
        if (self.shutting_down)
            policy.blockAdmission(&self.state, .shutting_down)
        else if (reason == .unknown) {
            self.state.runtime_uncertain = true;
            self.state.refresh_pending = false;
            self.state.refresh_paused = true;
            self.state.refresh_deadline_ms = null;
            self.state.expiry_deadline_ms = null;
            self.ports.timer.cancel();
            policy.blockAdmission(&self.state, .activation_unavailable);
        } else {
            self.expireAdmission();
        }
        if (targeted) self.finishConvergence();
        self.releaseBoundary();
        return true;
    }

    pub fn installationInput(self: *Runtime, io: std.Io) ?agent.McpInstallationInput {
        if (self.shutting_down) return null;
        const management = if (self.state.management) |*value| value else return null;
        if (management.inspect().health != .ready) return null;
        return self.installation_mailbox.input(io);
    }
    pub fn takeInstallation(self: *Runtime, io: std.Io) bool {
        const incoming = self.installation_mailbox.take(io) orelse return false;
        std.debug.assert(self.installation_request == null);
        self.installation_request = incoming;
        self.installation_notice = false;
        self.markChanged();
        return true;
    }
    pub fn pendingInstallation(self: *const Runtime) ?struct { id: u64, task_id: u64, run_id: u64, json: []const u8 } {
        const value = self.installation_request orelse return null;
        return .{ .id = value.id, .task_id = value.task_id, .run_id = value.run_id, .json = value.draft.json };
    }
    pub fn dismissInstallation(self: *Runtime, io: std.Io, id: u64, rejected: bool) bool {
        const value = if (self.installation_request) |*value| value else return false;
        if (id == 0 or value.id != id) return false;
        if (rejected) {
            self.installation_notice_task = value.task_id;
            self.installation_notice_run = value.run_id;
        }
        value.deinit();
        self.installation_request = null;
        _ = self.installation_mailbox.release(io, id);
        self.installation_notice = rejected;
        self.markChanged();
        return true;
    }
    pub fn closeInstallation(self: *Runtime, io: std.Io) void {
        self.installation_mailbox.close(io);
        if (self.installation_request) |*value| value.deinit();
        self.installation_request = null;
        self.installation_notice = false;
    }
    pub fn dismissInstallationNotice(self: *Runtime) bool {
        if (!self.installation_notice) return false;
        self.installation_notice = false;
        self.markChanged();
        return true;
    }
    pub fn writeInstallation(self: *const Runtime, writer: *std.Io.Writer, text: TextProjection) ViewError!void {
        writer.writeAll("{\"operations\":[") catch return error.SnapshotTooLarge;
        var count: usize = 0;
        if (self.state.management) |*management| if (management.desiredRegistry()) |registry| for (registry.servers) |server| {
            const operation = server.installation orelse continue;
            if (count != 0) writer.writeByte(',') catch return error.SnapshotTooLarge;
            count += 1;
            const phase: []const u8 = if (operation.stop_pending) "cancelling" else @tagName(operation.phase);
            writer.print("{{\"serverId\":\"{s}\",\"taskId\":\"{d}\",\"runId\":\"{d}\",\"revision\":\"{d}\",\"desiredGeneration\":\"{d}\",\"displayName\":", .{ server.id, operation.task_id, operation.run_id, operation.revision, registry.generation }) catch return error.SnapshotTooLarge;
            try text.write_json_fn(text.context, writer, server.display_name);
            writer.print(",\"phase\":\"{s}\",\"failure\":", .{phase}) catch return error.SnapshotTooLarge;
            if (operation.failure) |failure| writer.print("\"{s}\"", .{@tagName(failure)}) catch return error.SnapshotTooLarge else writer.writeAll("null") catch return error.SnapshotTooLarge;
            writer.writeAll(",\"sourceOrigin\":") catch return error.SnapshotTooLarge;
            try text.write_json_fn(text.context, writer, operation.source_origin);
            writer.writeAll(",\"targetOrigin\":") catch return error.SnapshotTooLarge;
            if (server.transport.sensitive_endpoint) |endpoint| try text.write_json_fn(text.context, writer, endpoint.origin) else writer.writeAll("null") catch return error.SnapshotTooLarge;
            writer.print(",\"canCancel\":{},\"missingCredentials\":[", .{operation.phase.active()}) catch return error.SnapshotTooLarge;
            var missing: usize = 0;
            for (operation.credentials) |slot| if (slot.manual and slot.credential_ref == null) {
                if (missing != 0) writer.writeByte(',') catch return error.SnapshotTooLarge;
                missing += 1;
                try text.write_json_fn(text.context, writer, slot.name);
            };
            writer.writeAll("]}") catch return error.SnapshotTooLarge;
        };
        writer.writeAll("],\"notice\":") catch return error.SnapshotTooLarge;
        if (self.installation_notice) writer.print("{{\"taskId\":\"{d}\",\"runId\":\"{d}\"}}", .{ self.installation_notice_task, self.installation_notice_run }) catch return error.SnapshotTooLarge else writer.writeAll("null") catch return error.SnapshotTooLarge;
        writer.writeByte('}') catch return error.SnapshotTooLarge;
    }

    pub fn observeProcess(self: *Runtime, observation: configuration.ProcessObservation) Error!bool {
        if (self.shutting_down or observation.attempt == 0) return false;
        const management = if (self.state.management) |*value| value else return false;
        const registry = management.desiredRegistry() orelse return false;
        const server = state_module.findMcpServer(registry.servers, observation.server_id) orelse return false;
        if (!server.enabled or !std.mem.eql(u8, server.transport.kind, "stdio") or !std.mem.eql(u8, &observation.source, &configuration.runtimeDescriptorFingerprint(server))) return false;
        var index: usize = 0;
        while (index < self.state.process_observations.items.len) {
            const old = self.state.process_observations.items[index];
            const current = state_module.findMcpServer(registry.servers, old.server_id);
            if (current == null or !std.mem.eql(u8, &old.source, &configuration.runtimeDescriptorFingerprint(current.?))) {
                self.allocator.free(old.server_id);
                _ = self.state.process_observations.swapRemove(index);
            } else index += 1;
        }
        for (self.state.process_observations.items) |*old| {
            if (!std.mem.eql(u8, old.server_id, observation.server_id)) continue;
            if (observation.attempt < old.attempt or (observation.attempt > old.attempt and observation.fact != .pending)) return false;
            if (old.attempt == observation.attempt and old.fact == observation.fact) return false;
            old.attempt = observation.attempt;
            old.fact = observation.fact;
            self.markChanged();
            return true;
        }
        if (observation.fact != .pending or self.state.process_observations.items.len >= management.limits.max_servers) return false;
        const owned_id = try self.allocator.dupe(u8, observation.server_id);
        errdefer self.allocator.free(owned_id);
        var owned = observation;
        owned.server_id = owned_id;
        try self.state.process_observations.append(self.allocator, owned);
        self.markChanged();
        return true;
    }

    pub fn startInstallation(self: *Runtime, expected_generation: u64, connection: configuration.InstallationConnection, input: configuration.InstallationStart) Error!configuration.CreateResult {
        const management = self.mutableManagement(expected_generation, input.existing_server_id) orelse return .{ .outcome = self.generationOutcome(expected_generation) };
        var preparation = try management.prepareInstallationStart(expected_generation, connection, input);
        const id: ?[configuration.created_identity_bytes]u8 = switch (preparation) {
            .prepared => |*mutation| blk: {
                const servers = mutation.target().servers;
                const identity = input.existing_server_id orelse servers[servers.len - 1].id;
                if (identity.len != configuration.created_identity_bytes) {
                    mutation.deinit();
                    return .{ .outcome = .rejected };
                }
                break :blk identity[0..configuration.created_identity_bytes].*;
            },
            else => null,
        };
        const outcome = try self.commitPreparedMutation(&preparation);
        return .{ .outcome = outcome, .server_id = if (outcome == .saved or outcome == .saved_recovery_required) id else null };
    }

    pub fn captureInstallationCredential(self: *Runtime, generation: u64, server_id: []const u8, name: []const u8, manual: bool, secret: []u8) Error!configuration.ManagementOutcome {
        defer std.crypto.secureZero(u8, secret);
        const management = self.mutableManagement(generation, server_id) orelse return self.generationOutcome(generation);
        var preparation = try management.prepareCaptureInstallationCredential(generation, server_id, name, manual, secret);
        return self.commitPreparedMutation(&preparation);
    }

    pub fn installationConnectionFailed(self: *const Runtime, server_id: []const u8) bool {
        const management = if (self.state.management) |*value| value else return false;
        const registry = management.desiredRegistry() orelse return false;
        const manifest = management.runtime_manifest orelse return false;
        if (manifest.targetFor(server_id, registry, management.limits)) |target| for (management.convergence.results.items) |result| {
            if (std.mem.eql(u8, result.target.id(), server_id) and std.mem.eql(u8, &result.target.fingerprint, &target.fingerprint) and result.outcome != .pending and result.outcome != .waiting_auth) return true;
        };
        return false;
    }

    pub fn updateInstallation(self: *Runtime, expected_generation: u64, input: configuration.InstallationUpdate) Error!configuration.ManagementOutcome {
        const management = self.mutableManagement(expected_generation, null) orelse return self.generationOutcome(expected_generation);
        var preparation = try management.prepareInstallationUpdate(expected_generation, input);
        const outcome = try self.commitPreparedMutation(&preparation);
        if (outcome == .saved or outcome == .saved_recovery_required) {
            self.updateAdmissionDeadline();
            self.expireAdmission();
        }
        return outcome;
    }

    pub fn cancelInstallation(self: *Runtime, server_id: []const u8, revision: u64) Error!configuration.ManagementOutcome {
        const management = if (self.state.management) |*value| value else return .rejected;
        if (management.desiredRegistry()) |registry| if (state_module.findMcpServer(registry.servers, server_id)) |server| if (server.installation) |operation| {
            if (operation.phase == .cancelled) {
                if (operation.stop_pending and !self.catalogBoundaryBusy() and self.state.authorization_operation == null)
                    return self.setServerEnabled(registry.generation, .{ .server_id = server_id, .enabled = false });
                return .unchanged;
            }
        };
        var prepared = switch (try management.prepareInstallationCancellation(server_id, revision)) {
            .rejected => return .rejected,
            .prepared => |value| value,
        };
        defer prepared.deinit();
        // Selection creation uses only our immutable Activation and local copies.
        // It never calls Runtime apply, refresh, or waits on a worker.
        var candidate = try self.admissionForTarget(prepared.target());
        var candidate_owned = true;
        defer if (candidate_owned) candidate.deinit();
        const outcome = try management.commitPreparedOperationState(&prepared);
        switch (outcome) {
            .saved => {
                self.installCommittedDesired(candidate);
                candidate_owned = false;
                self.updateAdmissionDeadline();
                self.expireAdmission();
                self.markChanged();
            },
            .indeterminate => {
                policy.blockAdmission(&self.state, .persistence_outcome_unknown);
                self.markChanged();
            },
            else => {},
        }
        return outcome;
    }

    /// Observe the exact current formal catalog, then commit its initial grant
    /// and a prepared Admission together. No subsequent discovery can expand it.
    fn installationHasAdmission(self: *const Runtime, server_id: []const u8) bool {
        if (self.state.admission != .ready or self.admissionExpired()) return false;
        const selection = self.state.admission.ready.selection orelse return false;
        for (selection.selectedTools()) |tool| if (std.mem.eql(u8, tool.server_id, server_id)) return true;
        return false;
    }

    pub fn installationReady(self: *const Runtime, server_id: []const u8) bool {
        const management = if (self.state.management) |*value| value else return false;
        const registry = management.desiredRegistry() orelse return false;
        const server = state_module.findMcpServer(registry.servers, server_id) orelse return false;
        const operation = server.installation orelse return false;
        return operation.phase == .ready and operation.initial_grant_completed and self.installationHasAdmission(server_id);
    }

    pub fn finishInstallation(self: *Runtime, server_id: []const u8, revision: u64, elapsed_ms: u32) Error!configuration.ManagementOutcome {
        const management = if (self.state.management) |*value| value else return .rejected;
        const registry = management.desiredRegistry() orelse return .rejected;
        const server = state_module.findMcpServer(registry.servers, server_id) orelse return .rejected;
        const operation = server.installation orelse return .rejected;
        if (operation.revision != revision or operation.phase != .connecting or self.state.runtime_uncertain or self.state.activation_failed or self.catalogBoundaryBusy()) return .rejected;
        const manifest = management.runtime_manifest orelse return .rejected;
        const loaded = for (manifest.entries) |entry| {
            if (entry.state == .loaded and std.mem.eql(u8, entry.id, server_id) and std.mem.eql(u8, &entry.state.loaded, &configuration.runtimeDescriptorFingerprint(server))) break true;
        } else false;
        if (!loaded) return .rejected;
        const activation = self.state.activation orelse return .rejected;
        const health = for (activation.serverHealth()) |value| {
            if (std.mem.eql(u8, value.id, server_id)) break value;
        } else return .rejected;
        if (health.state != .ready or health.issue_count != 0) return .rejected;
        const catalog = for (activation.catalogServers()) |value| {
            if (std.mem.eql(u8, &value.binding_identity, &health.binding_identity)) break value;
        } else return .rejected;
        const age = self.admissionCatalogAgeMs() orelse return .rejected;
        if (!catalog.fresh or catalog.ttl_remaining_ms <= age) return .rejected;
        var tools: std.array_list.Managed([]const u8) = .init(self.allocator);
        defer tools.deinit();
        for (activation.catalogTools()) |tool| {
            if (std.mem.eql(u8, &tool.binding_identity, &health.binding_identity)) try tools.append(tool.name);
        }
        if (tools.items.len > management.limits.max_tools_per_server) return .rejected;
        const usable = if (operation.initial_grant_pending) tools.items.len != 0 else blk: {
            for (tools.items) |tool| for (server.tools) |allowed| {
                if (std.mem.eql(u8, tool, allowed)) break :blk true;
            };
            break :blk false;
        };
        // First commit the exact grant while retaining the connecting phase.
        // After restart the same set is reused, never recaptured from new tools.
        if (operation.initial_grant_pending and usable) return self.updateInstallation(registry.generation, .{
            .server_id = server_id,
            .expected_revision = revision,
            .phase = .connecting,
            .active_elapsed_ms = elapsed_ms,
            .initial_tools = tools.items,
        });
        if (usable and !self.installationHasAdmission(server_id)) return .rejected;
        return self.updateInstallation(registry.generation, .{
            .server_id = server_id,
            .expected_revision = revision,
            .phase = if (usable) .ready else .no_tools,
            .active_elapsed_ms = elapsed_ms,
            .initial_tools = if (operation.initial_grant_pending) tools.items else null,
        });
    }

    pub fn createHttpServer(
        self: *Runtime,
        expected_generation: u64,
        input: configuration.CreateHttpServerInput,
    ) Error!configuration.CreateResult {
        const management = self.mutableManagement(expected_generation, null) orelse
            return .{ .outcome = self.generationOutcome(expected_generation) };
        var preparation = try management.prepareCreateHttpServer(expected_generation, input);
        return self.commitPreparedCreate(&preparation);
    }

    pub fn prepareHttpDraft(self: *Runtime, expected_generation: u64, display_name: []const u8, endpoint: []const u8) Error!?configuration.Preparation {
        const management = self.mutableManagement(expected_generation, null) orelse return null;
        return management.prepareHttpDraft(expected_generation, display_name, endpoint);
    }

    pub fn prepareHttpDraftCreate(self: *Runtime, expected_generation: u64, name: []const u8, endpoint: []const u8, headers: []const configuration.HttpDraftHeader) Error!configuration.MutationPreparation {
        const management = self.mutableManagement(expected_generation, null) orelse return .rejected;
        return management.prepareHttpDraftCreate(expected_generation, name, endpoint, headers);
    }

    pub fn commitHttpDraftCreate(self: *Runtime, generation: u64, draft: *configuration.MutationPreparation) Error!configuration.CreateResult {
        if (self.mutableManagement(generation, null) == null) {
            draft.deinit();
            return .{ .outcome = self.generationOutcome(generation) };
        }
        defer draft.* = .rejected;
        return self.commitPreparedCreate(draft);
    }

    pub fn createOauthHttpServer(
        self: *Runtime,
        expected_generation: u64,
        input: configuration.CreateOauthHttpServerInput,
    ) Error!configuration.CreateResult {
        const management = self.mutableManagement(expected_generation, null) orelse
            return .{ .outcome = self.generationOutcome(expected_generation) };
        var preparation = try management.prepareCreateOauthHttpServer(
            expected_generation,
            input,
        );
        return self.commitPreparedCreate(&preparation);
    }

    pub fn createStdioServer(
        self: *Runtime,
        expected_generation: u64,
        input: configuration.CreateStdioServerInput,
    ) Error!configuration.CreateResult {
        const management = self.mutableManagement(expected_generation, null) orelse
            return .{ .outcome = self.generationOutcome(expected_generation) };
        var preparation = try management.prepareCreateStdioServer(expected_generation, input);
        return self.commitPreparedCreate(&preparation);
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

    pub fn captureOauthResource(self: *Runtime, expected_generation: u64, input: configuration.CaptureOauthResourceInput) Error!configuration.CaptureOauthResourceResult {
        defer std.crypto.secureZero(u8, input.resource);
        if (self.shutting_down or !policy.authorizationAt(&self.state, input.server_id, &.{.awaiting_consent})) return .{ .outcome = .rejected };
        const management = if (self.state.management) |*value| value else return .{ .outcome = .rejected };
        var prepared = try management.prepareCaptureOauthResource(expected_generation, input);
        const outcome = try self.commitPreparedMutation(&prepared);
        var result: configuration.CaptureOauthResourceResult = .{ .outcome = outcome };
        if (outcome == .saved) {
            const registry = management.desiredRegistry() orelse return result;
            const server = state_module.findMcpServer(registry.servers, input.server_id) orelse return result;
            const resource = server.auth.oauth.?.pending_resource orelse return result;
            if (resource.identity.len != 35) return result;
            var identity: [35]u8 = undefined;
            @memcpy(&identity, resource.identity);
            result.identity = identity;
        }
        return result;
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

    fn commitPreparedCreate(self: *Runtime, preparation: *configuration.MutationPreparation) Error!configuration.CreateResult {
        const identity: ?[configuration.created_identity_bytes]u8 = switch (preparation.*) {
            .prepared => |*mutation| identity: {
                // Creation appends its generated server to the prepared target.
                const servers = mutation.target().servers;
                const id = servers[servers.len - 1].id;
                std.debug.assert(id.len == configuration.created_identity_bytes);
                break :identity id[0..configuration.created_identity_bytes].*;
            },
            else => null,
        };
        const outcome = try self.commitPreparedMutation(preparation);
        return .{ .outcome = outcome, .server_id = if (outcome == .saved or outcome == .saved_recovery_required) identity else null };
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
                        self.installCommittedDesired(candidate);
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

    fn admissionForTarget(self: *Runtime, target: configuration.RegistryWire) Error!state_module.McpAdmissionAuthority {
        const management = &self.state.management.?;
        const manifest = if (management.runtime_manifest) |*value| value else return .{ .blocked = .alignment_unknown };
        if (self.state.runtime_uncertain or self.state.activation_failed)
            return .{ .blocked = .activation_unavailable };
        const activation = self.state.activation orelse {
            if (management.runtimeAlignmentFor(target) == .restart_required) return .{ .blocked = .pending_restart };
            for (manifest.entries) |entry|
                if (entry.state == .loaded) return .{ .blocked = .activation_unavailable };
            return .{ .ready = .{ .selection = null, .catalog_generation = null } };
        };
        const health = activation.serverHealth();
        const allowlists = try self.allocator.alloc(agent.McpServerAllowlist, health.len);
        defer self.allocator.free(allowlists);
        var matched_source = false;
        for (health, allowlists) |server, *allowlist| {
            const desired = state_module.findMcpServer(target.servers, server.id);
            var tools: []const []const u8 = &.{};
            if (desired) |current| {
                for (manifest.entries) |entry| {
                    if (entry.state == .loaded and std.mem.eql(u8, entry.id, server.id) and
                        std.mem.eql(u8, &entry.state.loaded, &configuration.runtimeDescriptorFingerprint(current)))
                    {
                        tools = policy.serverToolsForAdmission(target, current);
                        matched_source = matched_source or configuration.runtimeLoadEligible(current, management.limits);
                        break;
                    }
                }
            }
            allowlist.* = .{ .id = server.id, .tools = tools };
        }
        if (!matched_source) {
            if (management.runtimeAlignmentFor(target) == .restart_required) return .{ .blocked = .pending_restart };
        }
        return .{ .ready = .{
            .selection = try self.ports.catalog.createAdmissionSelection(activation, allowlists),
            .catalog_generation = activation.catalogGeneration(),
        } };
    }

    /// Accept versioned authentication observations. A bare HTTP rejection is
    /// retained for explicit recovery; only challenge/expiry can retire a grant.
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
        const trusted_challenge_scopes: []const []const u8 = if (failure.challenge_scopes_complete and
            configuration.validOauthScopeSet(failure.challenge_scopes, management.limits))
            failure.challenge_scopes
        else
            &.{};
        if (management.inspect().health != .ready) return .rejected;
        const registry = management.desiredRegistry() orelse return .rejected;
        if (registry.oauth_operation) |operation|
            if (std.mem.eql(u8, operation.server_id, failure.server_id))
                return .rejected;
        const server = state_module.findMcpServer(registry.servers, failure.server_id) orelse
            return .stale;
        if (!std.mem.eql(u8, &failure.source_fingerprint, &configuration.runtimeDescriptorFingerprint(server))) return .stale;
        // Disabled sources cannot enter reauthorization. Their retained
        // transports may still report failures; consume those as inapplicable.
        if (!server.enabled) return .stale;
        const oauth = server.auth.oauth orelse return .stale;
        const consent = oauth.consent orelse return .stale;
        if (consent.epoch != failure.consent_epoch) return .stale;
        if (failure.reason == .http_rejection) {
            const grant = oauth.grant orelse return .stale;
            if (!std.mem.eql(u8, oauth.status, "ready") or grant.token_revision != failure.token_revision) return .stale;
            const manifest = management.runtime_manifest orelse return .rejected;
            const target = manifest.targetFor(server.id, registry, management.limits) orelse configuration.RuntimeApplyTarget.init(server.id, server, .replace);
            try management.convergence.recordHttpAuthRejection(self.allocator, target);
            self.finishConvergence();
            self.markChanged();
            return .applied;
        }
        if (failure.reason == .expired_grant) {
            const grant = oauth.grant orelse return .stale;
            const expiry = grant.expires_at_unix_ms orelse return .stale;
            const now_ms = self.ports.unix_clock.nowMs() orelse return .rejected;
            if (now_ms < expiry or grant.token_revision != failure.token_revision) return .stale;
        }
        const scope_step_up = policy.scopeSetAddsRequirement(
            consent.scopes,
            trusted_challenge_scopes,
        );
        if (std.mem.eql(u8, oauth.status, "reauth_required")) {
            var pending = if (trusted_challenge_scopes.len != 0)
                try policy.preparePendingReauthorization(
                    self.allocator,
                    &self.state,
                    server.id,
                    consent.epoch,
                    trusted_challenge_scopes,
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
        var pending = if (trusted_challenge_scopes.len != 0)
            try policy.preparePendingReauthorization(
                self.allocator,
                &self.state,
                server.id,
                consent.epoch,
                trusted_challenge_scopes,
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
        const owned_endpoint = try owned.dupe(u8, configuration.endpointDisplay(server.transport));
        const private_endpoint = try configuration.ownSensitiveEndpoint(&arena, server.transport.sensitive_endpoint);
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
            .private_endpoint = private_endpoint,
            .registration_kind = owned_registration_kind,
            .client_id = owned_client_id,
            .token_endpoint_auth_method = owned_auth_method,
            .additional_scopes = owned_additional_scopes,
        };
        const operation_server_id = try self.allocator.dupe(u8, server.id);
        errdefer self.allocator.free(operation_server_id);
        const operation_identity = try self.allocator.dupe(u8, operation_id);
        self.state.authorization_operation = .{
            .phase = .discovering,
            .server_id = operation_server_id,
            .operation_id = operation_identity,
        };
        self.rearmRefreshTimer();
        self.markChanged();
        return result;
    }

    pub fn canBeginAuthorization(
        self: *const Runtime,
        expected_generation: u64,
        server_id: []const u8,
    ) bool {
        if (self.shutting_down) return false;
        const management = if (self.state.management) |*value| value else return false;
        if (!policy.expectedGenerationMatches(management, expected_generation)) return false;
        const registry = management.desiredRegistry() orelse return false;
        const server = state_module.findMcpServer(registry.servers, server_id) orelse return false;
        return policy.canAuthorizeServer(&self.state, self.refresh_job != null, server);
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
                configuration.consentResourceMatches(consent, plan.resource, plan.private_resource_identity) and
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
                    .private_resource_identity = plan.private_resource_identity,
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
            !configuration.consentResourceMatches(consent, plan.resource, plan.private_resource_identity) or
            !std.mem.eql(u8, consent.redirect_uri, plan.redirect_uri) or
            !textSetsEqual(consent.scopes, plan.scopes))
            return .rejected;
        return .{ .ready = .{
            .attempt_id = plan.attempt_id,
            .server_id = server.id,
            .issuer = consent.issuer,
            .resource = consent.resource,
            .private_resource = consent.private_resource,
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
        defer preparation.deinit();
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
        defer preparation.deinit();
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
            .private_resource = consent.private_resource,
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
        preparation: *configuration.PreparedOperationState,
    ) Error!state_module.McpOauthOperationBeginOutcome {
        if (self.state.runtime_uncertain) return .rejected;
        var reduced = try self.admissionForTarget(preparation.target());
        var reduced_owned = true;
        defer if (reduced_owned) reduced.deinit();
        // A blocked authority already grants no new MCP access. Requiring a
        // ready catalog here would deadlock token renewal after catalog/auth
        // failure; the marker must atomically preserve that reduced state.
        const management = &self.state.management.?;
        switch (try management.commitPreparedOperationState(preparation)) {
            .saved => {
                self.ports.timer.cancel();
                self.installCommittedDesired(reduced);
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
        if (self.shutting_down or self.state.runtime_uncertain or !self.state.committed or self.refresh_job != null or
            self.state.configuration_apply_state == .applying)
            return .rejected;
        if (self.state.authorization_operation) |operation|
            if (std.mem.eql(u8, operation.server_id, server_id)) return .rejected;
        const management = if (self.state.management) |*value| value else return .rejected;
        const inspection = management.inspect();
        if (inspection.health != .ready) return .rejected;
        if (management.desiredRegistry().?.oauth_operation != null) return .rejected;
        var started = false;
        defer if (!started and management.inspect().health == .ready)
            management.oauth_schedule.deferServer(server_id, self.ports.unix_clock.nowMs());
        const desired = management.desiredRegistry() orelse return .rejected;
        const server = state_module.findMcpServer(desired.servers, server_id) orelse return .rejected;
        if (!policy.runtimeOauthRefreshEligible(&self.state, server)) return .rejected;
        var preparation = switch (try management.prepareBeginRefresh(
            desired.generation,
            .{ .server_id = server_id, .retained_member = !server.enabled },
        )) {
            .rejected => return .rejected,
            .prepared => |prepared| prepared,
        };
        defer preparation.deinit();
        var binding = try policy.buildOauthRefreshBinding(self.allocator, preparation.target(), policy.runtimeOauthBinding(&self.state, server));
        var binding_owned = true;
        defer if (binding_owned) binding.deinit();
        return switch (try self.commitOauthOperationBegin(&preparation)) {
            .started => ready: {
                binding_owned = false;
                started = true;
                break :ready .{ .started = binding };
            },
            .rejected => .rejected,
            .persistence_outcome_unknown => .persistence_outcome_unknown,
        };
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
                        self.installCommittedDesired(candidate);
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
        const operation = if (management.desiredRegistry()) |registry| registry.oauth_operation else null;
        const failed_server = if (operation) |marker|
            if (std.mem.eql(u8, marker.id, operation_id) and std.mem.eql(u8, marker.kind, "refresh"))
                try self.allocator.dupe(u8, marker.server_id)
            else
                null
        else
            null;
        defer if (failed_server) |server_id| self.allocator.free(server_id);
        var preparation = switch (try management.prepareClearOauthOperation(operation_id)) {
            .rejected => return .rejected,
            .prepared => |prepared| prepared,
        };
        defer preparation.deinit();
        var candidate = try self.admissionForTarget(preparation.target());
        var candidate_owned = true;
        defer if (candidate_owned) candidate.deinit();
        const outcome = try management.commitPreparedOperationState(&preparation);
        switch (outcome) {
            .saved => {
                self.installCommittedDesired(candidate);
                if (failed_server) |server_id| management.oauth_schedule.deferServer(server_id, self.ports.unix_clock.nowMs());
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
        if (self.state.runtime_uncertain) return null;
        if (self.shutting_down or self.catalogBoundaryBusy()) return null;
        return policy.nextOauthExpiry(&self.state, self.ports.unix_clock.nowMs());
    }

    pub fn updateRefreshDeadline(self: *Runtime) void {
        self.state.catalog_observed_at_ms = null;
        self.state.refresh_deadline_ms = null;
        self.state.expiry_deadline_ms = null;
        const activation = self.state.activation orelse return;
        const now_ms = self.ports.timer.now() orelse {
            if (self.ports.timer.enabled) {
                self.state.refresh_schedule_failed = true;
                self.markChanged();
            }
            return;
        };
        const age_ms = activation.catalogAgeMs() orelse return;
        const observed_at_ms = std.math.sub(u64, now_ms, age_ms) catch return;
        self.state.refresh_not_before_ms = @max(self.state.refresh_not_before_ms orelse 0, observed_at_ms +| 1_000);
        self.state.refresh_deadline_ms = state_module.mcpRefreshDeadlineMs(
            activation.catalogServers(),
            observed_at_ms,
        );
        self.state.catalog_observed_at_ms = observed_at_ms;
        self.updateAdmissionDeadline();
        self.expireAdmission();
    }

    fn updateAdmissionDeadline(self: *Runtime) void {
        self.state.expiry_deadline_ms = null;
        const activation = self.state.activation orelse return;
        const observed_at_ms = self.state.catalog_observed_at_ms orelse return;
        var ttl_ms: ?u64 = null;
        if (self.state.admission == .ready) if (self.state.admission.ready.selection) |selection| {
            for (selection.selectedTools()) |tool| {
                const binding = for (activation.serverHealth()) |health| {
                    if (std.mem.eql(u8, health.id, tool.server_id)) break health.binding_identity;
                } else continue;
                for (activation.catalogServers()) |server| {
                    if (std.mem.eql(u8, &binding, &server.binding_identity) and server.fresh and server.ttl_remaining_ms != 0)
                        ttl_ms = @min(ttl_ms orelse server.ttl_remaining_ms, server.ttl_remaining_ms);
                }
            }
        };
        if (ttl_ms) |ttl|
            self.state.expiry_deadline_ms = std.math.add(u64, observed_at_ms, ttl) catch null;
    }

    fn admissionCatalogAgeMs(self: *const Runtime) ?u64 {
        const activation = self.state.activation orelse return null;
        const age = activation.catalogAgeMs() orelse return null;
        const observed = self.state.catalog_observed_at_ms orelse return age;
        const now = self.ports.timer.now() orelse return age;
        return @max(age, now -| observed);
    }

    /// Rebuild only from the already-published tool cap and still-fresh source
    /// proofs. This is a local Selection copy, with no refresh or new authority.
    fn narrowExpiredAdmission(self: *Runtime) Error!bool {
        if (self.state.admission != .ready) return false;
        const original = self.state.admission.ready.selection orelse return false;
        const activation = self.state.activation orelse return false;
        const age = self.admissionCatalogAgeMs() orelse return false;
        const desired = if (self.state.management) |*management| management.desiredRegistry() else null;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const allowlists = @constCast(try policy.buildRefreshAllowlists(arena.allocator(), &self.state, desired));
        for (allowlists) |*allowlist| {
            const binding = for (activation.serverHealth()) |health| {
                if (std.mem.eql(u8, health.id, allowlist.id)) break health.binding_identity;
            } else {
                allowlist.tools = &.{};
                continue;
            };
            const fresh = for (activation.catalogServers()) |server| {
                if (std.mem.eql(u8, &binding, &server.binding_identity)) break server.fresh and age < server.ttl_remaining_ms;
            } else false;
            if (!fresh) {
                allowlist.tools = &.{};
                continue;
            }
            var count: usize = 0;
            const tools = @constCast(allowlist.tools);
            for (allowlist.tools) |tool| {
                const selected = for (original.selectedTools()) |entry| {
                    if (std.mem.eql(u8, entry.server_id, allowlist.id) and std.mem.eql(u8, entry.name, tool)) break true;
                } else false;
                if (selected) {
                    tools[count] = tool;
                    count += 1;
                }
            }
            allowlist.tools = tools[0..count];
        }
        const selection = (try self.ports.catalog.createAdmissionSelection(activation, allowlists)) orelse return false;
        policy.replaceAdmission(&self.state, .{ .ready = .{ .selection = selection, .catalog_generation = activation.catalogGeneration() } });
        self.updateAdmissionDeadline();
        return true;
    }

    pub fn admissionExpired(self: *const Runtime) bool {
        if (self.state.admission != .ready) return false;
        const expired = if (self.state.expiry_deadline_ms) |deadline|
            if (self.ports.timer.now()) |now_ms| now_ms >= deadline else false
        else
            false;
        return expired or !self.state.admissionFresh();
    }

    /// Cached management views must also age while admission is already
    /// blocked (for example after an apply rejection).
    pub fn catalogObservationExpired(self: *const Runtime) bool {
        const activation = self.state.activation orelse return false;
        const age = activation.catalogAgeMs() orelse return true;
        for (activation.catalogServers()) |server|
            if (server.fresh and age >= server.ttl_remaining_ms) return true;
        return false;
    }

    fn expireAdmission(self: *Runtime) void {
        if (self.admissionExpired()) {
            const narrowed = self.narrowExpiredAdmission() catch false;
            if (!narrowed) policy.blockAdmission(&self.state, .activation_unavailable);
            self.markChanged();
        }
    }

    pub fn syncFreshness(self: *Runtime) bool {
        self.observeOauthTime();
        const expired = self.admissionExpired();
        self.expireAdmission();
        if (!expired) return false;
        if (!self.state.refresh_paused)
            _ = self.queueRefresh(false, false) catch {};
        return true;
    }

    fn recordRefreshFailure(self: *Runtime) void {
        self.state.refresh_failures +|= 1;
        // Retry a bounded series, then require an explicit refresh or a new
        // configuration. This avoids permanent polling of failed services.
        if (self.state.refresh_failures >= 5) {
            self.state.refresh_paused = true;
            self.state.refresh_pending = false;
            self.state.refresh_deadline_ms = null;
            return;
        }
        const now_ms = self.ports.timer.now() orelse return;
        const delay_ms = @as(u64, 1_000) << @as(u6, @intCast(self.state.refresh_failures - 1));
        self.state.refresh_deadline_ms = std.math.add(u64, now_ms, delay_ms) catch null;
        self.state.refresh_not_before_ms = self.state.refresh_deadline_ms;
    }

    fn releaseBoundary(self: *Runtime) void {
        self.rearmRefreshTimer();
        if (!self.runtime_auth_delivery_pending or self.shutting_down) return;
        if (self.ports.notifier.notify())
            self.runtime_auth_delivery_pending = false;
    }

    fn armRefreshRetry(self: *Runtime) void {
        if (self.shutting_down or !self.ports.timer.enabled) return;
        const now_ms = self.ports.timer.now() orelse return;
        const deadline_ms = std.math.add(u64, now_ms, 1_000) catch std.math.maxInt(u64);
        self.state.refresh_not_before_ms = deadline_ms;
        self.armRefreshAt(if (self.state.expiry_deadline_ms) |expiry|
            if (self.state.admissionFresh()) @min(expiry, deadline_ms) else deadline_ms
        else
            deadline_ms);
    }

    fn armRefreshAt(self: *Runtime, deadline_ms: u64) void {
        const failed = !self.ports.timer.armAt(deadline_ms);
        if (failed != self.state.refresh_schedule_failed) {
            self.state.refresh_schedule_failed = failed;
            self.markChanged();
        }
    }

    pub fn rearmRefreshTimer(self: *Runtime) void {
        self.ports.timer.cancel();
        if (self.shutting_down) return;
        self.expireAdmission();
        if (self.state.refresh_pending) {
            const started = self.startPendingRefresh() catch {
                self.armRefreshRetry();
                return;
            };
            if (!started and self.state.refresh_pending) {
                const now_ms = self.ports.timer.now() orelse return;
                // Busy transactions and running jobs have explicit completion
                // wakeups. Only time/capacity waits need a retry timer.
                if (self.catalogBoundaryBusy()) {
                    if (self.state.expiry_deadline_ms) |expiry| if (self.state.admissionFresh() and expiry > now_ms)
                        self.armRefreshAt(expiry);
                    return;
                }
                const retry = @max(self.state.refresh_not_before_ms orelse now_ms +| 1_000, now_ms +| 1);
                self.armRefreshAt(if (self.state.expiry_deadline_ms) |expiry|
                    if (self.state.admissionFresh() and expiry > now_ms) @min(expiry, retry) else retry
                else
                    retry);
                return;
            }
        }
        if (!self.ports.timer.enabled) return;
        const now_ms = self.ports.timer.now() orelse return;
        if (!self.state.committed or self.state.configuration_apply_state == .applying)
            return;
        const management = if (self.state.management) |*value| value else return;
        const inspection = management.inspect();
        if (inspection.health != .ready or self.state.runtime_uncertain)
            return;
        const desired = management.desiredRegistry() orelse return;
        if (desired.oauth_operation != null) return;
        if (self.refresh_job != null or self.state.refresh_paused) {
            if (self.state.expiry_deadline_ms) |expiry| if (self.state.admissionFresh() and expiry > now_ms)
                self.armRefreshAt(expiry);
            return;
        }
        var deadline_ms = self.state.refresh_deadline_ms orelse return;
        if (self.state.refresh_not_before_ms) |floor| deadline_ms = @max(floor, deadline_ms);
        if (self.state.expiry_deadline_ms) |expiry| if (self.state.admissionFresh() and expiry > now_ms) {
            deadline_ms = @min(expiry, deadline_ms);
        };
        self.armRefreshAt(@max(now_ms +| 1, deadline_ms));
    }

    pub fn recoverExpiredCatalog(self: *Runtime) bool {
        if (self.shutting_down) return false;
        if (self.state.refresh_paused) {
            policy.blockAdmission(&self.state, .activation_unavailable);
            return true;
        }
        _ = self.queueRefresh(true, false) catch {
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
    failed_enqueues: usize = 0,
    armed_deadline_ms: ?u64 = null,
    now_ms: u64 = 100,
    unix_seconds: ?u64 = 1,
    activation_outcome: agent.McpActivationOutcome = .empty,
    activations: usize = 0,
    arm_succeeds: bool = true,

    fn enqueue(
        context: *anyopaque,
        job: ports_module.Job,
    ) error{ ExecutorShuttingDown, QueueFull }!void {
        const self: *TestHarness = @ptrCast(@alignCast(context));
        if (self.failed_enqueues != 0) {
            self.failed_enqueues -= 1;
            return error.QueueFull;
        }
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

    fn activate(context: *anyopaque) ports_module.CatalogError!agent.McpActivationOutcome {
        const self: *TestHarness = @ptrCast(@alignCast(context));
        self.activations += 1;
        return self.activation_outcome;
    }

    fn createAdmissionSelection(
        _: *anyopaque,
        _: *const agent.McpActivation,
        _: []const agent.McpServerAllowlist,
    ) ports_module.CatalogError!?*agent.McpSelection {
        return null;
    }

    fn prepareRestoreSelection(_: *anyopaque, _: *const agent.McpRestoreSelection, _: *const agent.McpActivation, _: []const agent.McpActivationTool) ports_module.CatalogError!*agent.McpSelection {
        return error.InvalidMcpSelection;
    }

    fn now(context: ?*anyopaque) ?u64 {
        const self: *TestHarness = @ptrCast(@alignCast(context.?));
        return self.now_ms;
    }

    fn unixNow(context: ?*anyopaque) ?u64 {
        const self: *TestHarness = @ptrCast(@alignCast(context.?));
        return self.unix_seconds;
    }

    fn armAt(context: ?*anyopaque, deadline_ms: u64) bool {
        const self: *TestHarness = @ptrCast(@alignCast(context.?));
        self.armed_deadline_ms = deadline_ms;
        return self.arm_succeeds;
    }

    fn cancelTimer(context: ?*anyopaque) void {
        const self: *TestHarness = @ptrCast(@alignCast(context.?));
        self.armed_deadline_ms = null;
    }

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
                .prepare_restore_selection_fn = prepareRestoreSelection,
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
            .unix_clock = .{ .enabled = true, .context = self, .now_seconds_fn = unixNow },
        };
    }

    fn executeQueued(self: *TestHarness) void {
        const job = self.queued.?;
        self.queued = null;
        job.execute_fn(job.context);
    }
};

const OauthTestEffects = struct {
    const StoredSecret = struct { locator: [64]u8 = undefined, locator_len: usize = 0, value: [64]u8 = undefined, value_len: usize = 0 };
    entropy: u8 = 0,
    deleted: usize = 0,
    registry_effect: configuration.PersistenceEffect = .committed,
    created_secrets: [16]StoredSecret = .{StoredSecret{}} ** 16,

    fn fill(raw: ?*anyopaque, output: *[16]u8) bool {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.entropy += 1;
        @memset(output, self.entropy);
        return true;
    }
    fn journal(_: ?*anyopaque, _: []const u8) configuration.PersistenceEffect {
        return .committed;
    }
    fn registry(raw: ?*anyopaque, _: []const u8) configuration.PersistenceEffect {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        return self.registry_effect;
    }
    fn clear(_: ?*anyopaque) configuration.PersistenceEffect {
        return .committed;
    }
    fn probe(_: ?*anyopaque, _: []const u8) configuration.CredentialPresence {
        return .missing;
    }
    fn create(raw: ?*anyopaque, locator: []const u8, secret: []const u8) bool {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        for (&self.created_secrets) |*entry| if (entry.locator_len == 0) {
            if (locator.len > entry.locator.len or secret.len > entry.value.len) return false;
            @memcpy(entry.locator[0..locator.len], locator);
            @memcpy(entry.value[0..secret.len], secret);
            entry.locator_len = locator.len;
            entry.value_len = secret.len;
            return true;
        };
        return false;
    }
    fn resolve(raw: ?*anyopaque, allocator: std.mem.Allocator, locator: []const u8) configuration.CredentialResolution {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        for (self.created_secrets) |entry| if (std.mem.eql(u8, entry.locator[0..entry.locator_len], locator))
            return .{ .value = allocator.dupe(u8, entry.value[0..entry.value_len]) catch return .out_of_memory };
        return .missing;
    }
    fn delete(raw: ?*anyopaque, _: []const u8) bool {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.deleted += 1;
        return true;
    }

    fn coldRuntime(self: *@This(), harness: *TestHarness, initial_status: []const u8) !Runtime {
        const allocator = std.testing.allocator;
        const dynamic = std.mem.eql(u8, initial_status, "client_registration_required");
        var server: configuration.ServerWire = .{
            .id = "oauth",
            .namespace = "oauth",
            .display_name = "OAuth",
            .enabled = true,
            .negotiation = "automatic",
            .timeout_ms = 1000,
            .transport = .{ .kind = "streamable_http", .url = "https://mcp.example.test/mcp" },
            .auth = .{ .kind = "oauth", .oauth = .{
                .status = initial_status,
                .registration = .{ .kind = if (dynamic) "dynamic_registration" else "pre_registered", .issuer = null, .client_id = if (dynamic) null else "client", .token_endpoint_auth_method = if (dynamic) null else "none", .client_credential_revision = if (dynamic) 0 else 1, .client_secret_ref = null },
                .consent = null,
                .grant = null,
            } },
            .connection_approval = null,
            .tools = &.{},
        };
        const approval = configuration.connectionFingerprint(server);
        server.connection_approval = .{ .fingerprint = &approval };
        var servers = [_]configuration.ServerWire{server};
        const initial: configuration.RegistryWire = .{ .schema_version = configuration.schema_version, .generation = 1, .oauth_operation = null, .servers = &servers };
        var buffer: [8192]u8 = undefined;
        var preparation = try configuration.prepare(allocator, try configuration.encode(&buffer, initial, test_limits), true, false, .{}, test_limits);
        errdefer preparation.deinit();
        var manifest = (try configuration.RuntimeManifest.candidate(allocator, &preparation)).?;
        errdefer manifest.deinit();
        const management = try configuration.ManagementPort.init(allocator, initial, .{
            .persistence = .{ .context = self, .available = true, .commit_journal_fn = journal, .commit_registry_fn = registry, .clear_journal_fn = clear },
            .credentials = .{ .context = self, .available = true, .probe_fn = probe, .create_fn = create, .delete_fn = delete },
            .locator_generator = .{ .context = self, .available = true, .fill_fn = fill },
            .identity_generator = .{ .context = self, .available = true, .fill_fn = fill },
            .limits = test_limits,
            .runtime_manifest = &manifest,
        });
        return Runtime.init(allocator, harness.ports(), .{
            .preparation = preparation,
            .activation = null,
            .activation_failed = false,
            .management = management,
            .admission = .{ .ready = .{ .selection = null, .catalog_generation = null } },
            .host_capabilities = .{ .oauth = true },
            .committed = true,
        });
    }
};

fn testRetainOauthTaskReference(runtime: *Runtime) !void {
    try runtime.state.task_references.ensureUnusedCapacity(std.testing.allocator, 1);
    const reference: state_module.McpTaskReference = reference: {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        errdefer arena.deinit();
        const owned = arena.allocator();
        const tools = try owned.alloc(state_module.McpTaskReference.Tool, 1);
        tools[0] = .{ .server_id = try owned.dupe(u8, "oauth"), .name = try owned.dupe(u8, "echo"), .fingerprint = configuration.runtimeDescriptorFingerprint(runtime.state.management.?.desiredRegistry().?.servers[0]) };
        break :reference .{ .arena = arena, .task_id = 7, .tools = tools };
    };
    runtime.state.task_references.appendAssumeCapacity(reference);
    runtime.updateMemberReferenceCounts();
}

test "installation Stop persists a veto during apply without waiting for the apply worker" {
    var effects: OauthTestEffects = .{};
    var harness: TestHarness = .{};
    var runtime = try effects.coldRuntime(&harness, "consent_required");
    defer runtime.deinit();
    const created = try runtime.startInstallation(1, .{ .stdio = .{ .display_name = "Install", .command = "node" } }, .{
        .task_id = 7,
        .run_id = 9,
        .source_message_id = 8,
        .source_origin = "https://install.example",
        .request = "{}",
    });
    try std.testing.expectEqual(.saved, created.outcome);
    const id = created.server_id.?;
    try std.testing.expectEqual(.saved, try runtime.updateInstallation(2, .{ .server_id = &id, .expected_revision = 1, .phase = .connecting, .active_elapsed_ms = 1 }));
    runtime.state.configuration_apply_state = .applying;
    defer runtime.state.configuration_apply_state = .idle;
    try std.testing.expectEqual(.rejected, try runtime.finishInstallation(&id, 2, 2));
    try std.testing.expectEqual(.saved, try runtime.cancelInstallation(&id, 2));
    const registry = runtime.state.management.?.desiredRegistry().?;
    try std.testing.expectEqual(@as(u64, 3), registry.generation);
    const cancelled = state_module.findMcpServer(registry.servers, &id).?;
    try std.testing.expectEqual(.cancelled, cancelled.installation.?.phase);
    try std.testing.expect(!configuration.serverEnabled(cancelled));
    try std.testing.expect(!cancelled.installation.?.initial_grant_pending);
    try std.testing.expect(!runtime.installationReady(&id));
    try std.testing.expectEqual(@as(usize, 0), harness.activations);
    var buffer: [configuration.max_store_bytes]u8 = undefined;
    var preparation = try configuration.prepare(std.testing.allocator, try configuration.encode(&buffer, registry, test_limits), true, false, .{}, test_limits);
    defer preparation.deinit();
    try std.testing.expectEqual(.disabled, std.meta.activeTag(preparation.server_states[1]));
}

test "private OAuth endpoints keep resource bytes out of durable consent including dynamic registration" {
    for ([_]bool{ false, true }) |dynamic| {
        var effects: OauthTestEffects = .{};
        var harness: TestHarness = .{};
        var runtime = try effects.coldRuntime(&harness, if (dynamic) "client_registration_required" else "consent_required");
        defer runtime.deinit();
        const private_url = "https://mcp.example.test/k/synthetic?route=private";
        try std.testing.expectEqual(.saved, try runtime.updateOauthHttpConnection(1, .{
            .server_id = "oauth",
            .display_name = "Private OAuth",
            .negotiation = "automatic",
            .timeout_ms = 1000,
            .url = private_url,
            .sensitive_endpoint = true,
            .client = if (dynamic) .dynamic_registration else .{ .pre_registered = .{ .client_id = "client" } },
        }));
        var start = (try runtime.beginAuthorization(2, "oauth", "private-attempt")).?;
        defer start.deinit();
        try std.testing.expectEqualStrings("https://mcp.example.test", start.endpoint);
        try std.testing.expect(start.private_endpoint != null);
        try std.testing.expect(runtime.advanceAuthorization("private-attempt", .awaiting_consent));
        const resource_copy = try std.testing.allocator.dupe(u8, private_url);
        defer std.testing.allocator.free(resource_copy);
        const captured = try runtime.captureOauthResource(2, .{ .server_id = "oauth", .resource = resource_copy });
        try std.testing.expectEqual(.saved, captured.outcome);
        const resource_identity = captured.identity.?;
        if (dynamic) {
            const operation = (try runtime.beginOauthDynamicRegistration(.{
                .server_id = "oauth",
                .resource = private_url,
                .private_resource_identity = &resource_identity,
                .issuer = "https://issuer.example.test",
                .scopes = &.{"read"},
                .redirect_uri = "http://127.0.0.1/callback",
            })).started;
            try std.testing.expect(runtime.advanceAuthorization("private-attempt", .registering));
            try std.testing.expectEqual(.saved, try runtime.completeOauthDynamicRegistration(.{
                .operation_id = operation.id,
                .server_id = "oauth",
                .client_id = "issued-client",
                .token_endpoint_auth_method = "none",
            }));
        }
        const authorized = try runtime.authorizeOauth(.{
            .attempt_id = 1,
            .server_id = "oauth",
            .resource = private_url,
            .private_resource_identity = &resource_identity,
            .issuer = "https://issuer.example.test",
            .scopes = &.{"read"},
            .redirect_uri = "http://127.0.0.1/callback",
        });
        try std.testing.expect(authorized == .ready);
        try std.testing.expectEqualStrings("https://mcp.example.test", authorized.ready.resource);
        const private_resource = authorized.ready.private_resource.?;
        const resolved = try configuration.resolvePrivateEndpoint(std.testing.allocator, private_resource, .{ .context = &effects, .available = true, .resolve_fn = OauthTestEffects.resolve }, test_limits);
        defer {
            std.crypto.secureZero(u8, resolved);
            std.testing.allocator.free(resolved);
        }
        try std.testing.expectEqualStrings(private_url, resolved);
        var encoded: [configuration.max_store_bytes]u8 = undefined;
        const bytes = try configuration.encode(&encoded, runtime.state.management.?.desiredRegistry().?, test_limits);
        try std.testing.expect(std.mem.indexOf(u8, bytes, "synthetic") == null);
        try std.testing.expect(std.mem.indexOf(u8, bytes, "route=private") == null);
        try std.testing.expect(runtime.state.management.?.desiredRegistry().?.servers[0].auth.oauth.?.pending_resource == null);
        try std.testing.expect(runtime.advanceAuthorization("private-attempt", .awaiting_browser));
        const exchange = (try runtime.beginOauthCodeExchange("oauth")).started;
        try std.testing.expectEqualStrings(&resource_identity, exchange.private_resource.?.identity);
    }
}

fn testGrantedOauthRuntime(effects: *OauthTestEffects, harness: *TestHarness, refreshable: bool, expiry: ?u64) !Runtime {
    var runtime = try effects.coldRuntime(harness, "consent_required");
    errdefer runtime.deinit();
    var start = (try runtime.beginAuthorization(1, "oauth", "attempt")).?;
    defer start.deinit();
    try std.testing.expect(runtime.advanceAuthorization("attempt", .awaiting_consent));
    try std.testing.expect((try runtime.authorizeOauth(.{ .attempt_id = 1, .server_id = "oauth", .resource = "https://mcp.example.test/mcp", .issuer = "https://issuer.example.test", .scopes = &.{"files.read"}, .redirect_uri = "http://127.0.0.1:43123/auth/callback" })) == .ready);
    try std.testing.expect(runtime.advanceAuthorization("attempt", .awaiting_browser));
    const exchange = (try runtime.beginOauthCodeExchange("oauth")).started;
    try std.testing.expect(runtime.advanceAuthorization("attempt", .exchanging));
    var access = "access-token".*;
    var refresh = "refresh-token".*;
    try std.testing.expectEqual(.saved, try runtime.completeOauthCodeExchange(.{ .operation_id = exchange.operation.id, .server_id = "oauth", .access_token = &access, .refresh_token = if (refreshable) &refresh else null, .expires_at_unix_ms = expiry }));
    try std.testing.expect(runtime.finishAuthorization("attempt"));
    return runtime;
}

fn testOauthRecoveryProjection(runtime: *const Runtime, fixture_name: []const u8) !void {
    const Text = struct {
        fn contains(_: *const anyopaque, _: []const u8) bool {
            return false;
        }
        fn write(_: *const anyopaque, writer: *std.Io.Writer, value: []const u8) view.Error!void {
            std.json.Stringify.value(value, .{}, writer) catch return error.SnapshotTooLarge;
        }
    };
    var bytes: [32 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try writeProjection(runtime, &writer, .{ .context = runtime, .contains_sensitive_fn = Text.contains, .write_json_fn = Text.write });
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "new-access-token") == null);
    const actual = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, writer.buffered(), .{});
    defer actual.deinit();
    const expected = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, @embedFile("testdata/oauth-recovery-view.json"), .{});
    defer expected.deinit();
    const server = actual.value.object.get("servers").?.array.items[0].object;
    var fields = expected.value.object.get(fixture_name).?.object.iterator();
    while (fields.next()) |field| {
        const value = server.get(field.key_ptr.*).?;
        switch (field.value_ptr.*) {
            .string => |wanted| try std.testing.expectEqualStrings(wanted, value.string),
            .bool => |wanted| try std.testing.expectEqual(wanted, value.bool),
            else => unreachable,
        }
    }
}

test "Product MCP expired cold grant waits without changing membership and resumes with new credentials" {
    var effects = OauthTestEffects{};
    var harness = TestHarness{};
    var runtime = try testGrantedOauthRuntime(&effects, &harness, true, 90_000);
    defer runtime.deinit();
    try testOauthRecoveryProjection(&runtime, "untried");
    harness.unix_seconds = 100;
    try std.testing.expect((try runtime.prepareConfigurationStep(3, .automatic)) == null);
    try std.testing.expectEqual(.current, runtime.state.management.?.inspect().runtime_alignment);
    try std.testing.expectEqual(.idle, runtime.state.configuration_apply_state);
    try std.testing.expectEqual(.waiting_auth, runtime.state.management.?.convergence.results.items[0].outcome);
    try std.testing.expect(runtime.inspectDesiredConfiguration().?.authorization_recovery_pending);
    try testOauthRecoveryProjection(&runtime, "waiting");
    var binding = (try runtime.beginOauthRefresh("oauth")).started;
    defer binding.deinit();
    try std.testing.expectEqual(.absent, binding.runtime_binding);
    try testOauthRecoveryProjection(&runtime, "refreshing");
    var new_access = "new-access-token".*;
    const Commit = struct {
        called: bool = false,
        fn commit(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.called = true;
        }
    };
    var commit = Commit{};
    try std.testing.expectEqual(.saved, try runtime.completeOauthRefresh(.{ .operation_id = binding.operation_id, .server_id = "oauth", .access_token = &new_access, .expires_at_unix_ms = 999_000 }, .{ .context = &commit, .commit_fn = Commit.commit }));
    try std.testing.expect(commit.called);
    var step = (try runtime.prepareConfigurationStep(4, .automatic)).?;
    defer step.deinit();
    try std.testing.expectEqual(.add, step.target.kind);
    const desired = runtime.state.management.?.desiredRegistry().?;
    var buffer: [8192]u8 = undefined;
    var prepared = try configuration.prepare(std.testing.allocator, try configuration.encode(&buffer, desired, test_limits), true, false, .{ .context = &effects, .available = true, .resolve_fn = OauthTestEffects.resolve }, test_limits);
    defer prepared.deinit();
    try std.testing.expectEqual(.eligible, prepared.server_states[0]);
    var found = false;
    for (prepared.credentials) |credential| if (std.mem.eql(u8, credential.locator, desired.servers[0].auth.oauth.?.grant.?.access_token_ref)) {
        try std.testing.expectEqualStrings("new-access-token", credential.secret);
        found = true;
    };
    try std.testing.expect(found);
}

test "Product MCP expired grant without refresh token schedules reauthorization without an apply loop" {
    var effects = OauthTestEffects{};
    var harness = TestHarness{};
    var runtime = try testGrantedOauthRuntime(&effects, &harness, false, 90_000);
    defer runtime.deinit();
    harness.unix_seconds = 100;
    const expiry = runtime.nextOauthExpiry().?;
    try std.testing.expect(!expiry.refresh);
    try std.testing.expectEqual(@as(u64, 90_000), expiry.expires_at_unix_ms);
    try std.testing.expect((try runtime.prepareConfigurationStep(3, .automatic)) == null);
    try std.testing.expectEqual(.applied, try runtime.requireOauthReauthorization(.{ .server_id = expiry.server_id, .source_fingerprint = expiry.source_fingerprint, .reason = .expired_grant, .consent_epoch = expiry.consent_epoch, .token_revision = expiry.token_revision, .challenge_scopes = &.{}, .challenge_scopes_complete = false }));
    try std.testing.expectEqualStrings("reauth_required", runtime.state.management.?.desiredRegistry().?.servers[0].auth.oauth.?.status);
    try std.testing.expect(runtime.nextOauthExpiry() == null);
    try std.testing.expect((try runtime.prepareConfigurationStep(4, .automatic)) == null);
    try std.testing.expect(runtime.canBeginAuthorization(4, "oauth"));
}

test "Product MCP token expiry never becomes a loaded member removal" {
    for ([_]bool{ false, true }) |refreshable| {
        var effects = OauthTestEffects{};
        var harness = TestHarness{};
        var runtime = try testGrantedOauthRuntime(&effects, &harness, refreshable, 90_000);
        defer runtime.deinit();
        var step = (try runtime.prepareConfigurationStep(3, .automatic)).?;
        defer step.deinit();
        var manifest = (try configuration.RuntimeManifest.candidate(std.testing.allocator, &step.preparation)).?;
        try std.testing.expect(runtime.completeConfigurationApply(3, &step.preparation, &manifest, null, null, false));
        step.preparation = .{ .allocator = std.testing.allocator, .state = .empty };
        harness.unix_seconds = 100;
        try std.testing.expect((try runtime.prepareConfigurationStep(3, .automatic)) == null);
        try std.testing.expect(runtime.state.management.?.runtime_manifest.?.entries[0].state == .loaded);
        if (refreshable) try std.testing.expect(runtime.nextOauthExpiry().?.runtime_loaded) else try std.testing.expect(runtime.nextOauthExpiry() == null);
        const oauth = runtime.state.management.?.desiredRegistry().?.servers[0].auth.oauth.?;
        try std.testing.expectEqualStrings("ready", oauth.status);
        try std.testing.expect(oauth.grant != null);
        try std.testing.expectEqual(.current, runtime.state.management.?.inspect().runtime_alignment);
    }
}

test "disabled retained OAuth auth refusal is terminal and does not prevent final removal" {
    for ([_]bool{ false, true }) |refreshable| {
        var effects = OauthTestEffects{};
        var harness = TestHarness{};
        var runtime = try testGrantedOauthRuntime(&effects, &harness, refreshable, 90_000);
        defer runtime.deinit();
        var step = (try runtime.prepareConfigurationStep(3, .automatic)).?;
        defer step.deinit();
        var manifest = (try configuration.RuntimeManifest.candidate(std.testing.allocator, &step.preparation)).?;
        try std.testing.expect(runtime.completeConfigurationApply(3, &step.preparation, &manifest, null, null, false));
        step.preparation = .{ .allocator = std.testing.allocator, .state = .empty };
        const source = configuration.runtimeDescriptorFingerprint(runtime.state.management.?.desiredRegistry().?.servers[0]);
        try runtime.state.task_references.ensureUnusedCapacity(std.testing.allocator, 1);
        const reference: state_module.McpTaskReference = reference: {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            errdefer arena.deinit();
            const owned = arena.allocator();
            const tools = try owned.alloc(state_module.McpTaskReference.Tool, 1);
            tools[0] = .{ .server_id = try owned.dupe(u8, "oauth"), .name = try owned.dupe(u8, "echo"), .fingerprint = source };
            break :reference .{ .arena = arena, .task_id = 7, .tools = tools };
        };
        runtime.state.task_references.appendAssumeCapacity(reference);
        runtime.updateMemberReferenceCounts();
        try std.testing.expectEqual(.saved, try runtime.setServerEnabled(3, .{ .server_id = "oauth", .enabled = false }));
        try std.testing.expectEqual(@as(u32, 1), runtime.state.management.?.runtime_manifest.?.entries[0].task_references);
        for (0..3) |_| try std.testing.expectEqual(.stale, try runtime.requireOauthReauthorization(.{ .server_id = "oauth", .source_fingerprint = source, .reason = .challenge, .consent_epoch = 1, .token_revision = 1, .challenge_scopes = &.{}, .challenge_scopes_complete = false }));
        const oauth = runtime.state.management.?.desiredRegistry().?.servers[0].auth.oauth.?;
        try std.testing.expectEqualStrings("ready", oauth.status);
        try std.testing.expect(oauth.grant != null);
        try std.testing.expect((try runtime.prepareConfigurationStep(4, .automatic)) == null);
        runtime.releaseTaskReference(7);
        var removal = (try runtime.prepareConfigurationStep(4, .automatic)).?;
        defer removal.deinit();
        try std.testing.expectEqual(.remove, removal.target.kind);
    }
}

test "expired nonrefreshable replacement fails with login available and preserves the loaded member" {
    for ([_]bool{ false, true }) |referenced| {
        var effects = OauthTestEffects{};
        var harness = TestHarness{};
        var runtime = try testGrantedOauthRuntime(&effects, &harness, false, 90_000);
        defer runtime.deinit();
        var original = (try runtime.prepareConfigurationStep(3, .automatic)).?;
        defer original.deinit();
        var manifest = (try configuration.RuntimeManifest.candidate(std.testing.allocator, &original.preparation)).?;
        try std.testing.expect(runtime.completeConfigurationApply(3, &original.preparation, &manifest, null, null, false));
        original.preparation = .{ .allocator = std.testing.allocator, .state = .empty };
        if (referenced) try testRetainOauthTaskReference(&runtime);
        const current = runtime.state.management.?.desiredRegistry().?.servers[0];
        const loaded_source = configuration.runtimeDescriptorFingerprint(current);
        try std.testing.expectEqual(.saved, try runtime.updateOauthHttpConnection(3, .{ .server_id = "oauth", .display_name = "OAuth", .negotiation = current.negotiation, .timeout_ms = current.timeout_ms + 1, .url = "https://mcp.example.test/mcp", .client = .{ .pre_registered = .{ .client_id = current.auth.oauth.?.registration.client_id.?, .token_endpoint_auth_method = "none" } } }));
        harness.unix_seconds = 100;
        const retired_before = effects.deleted;
        try std.testing.expect((try runtime.prepareConfigurationStep(4, .automatic)) == null);
        try std.testing.expectEqual(.failed, runtime.state.management.?.convergence.results.items[0].outcome);
        try std.testing.expect(!runtime.inspectDesiredConfiguration().?.authorization_recovery_pending);
        try std.testing.expect(runtime.nextOauthExpiry() == null);
        try std.testing.expect(runtime.canBeginAuthorization(4, "oauth"));
        try testOauthRecoveryProjection(&runtime, "blocked_replacement");
        for (0..3) |_| try std.testing.expect((try runtime.prepareConfigurationStep(4, .automatic)) == null);
        try std.testing.expect((try runtime.prepareConfigurationStep(4, .{ .retry_server = "oauth" })) == null);
        try std.testing.expect(runtime.canBeginAuthorization(4, "oauth"));
        const oauth = runtime.state.management.?.desiredRegistry().?.servers[0].auth.oauth.?;
        try std.testing.expectEqualStrings("ready", oauth.status);
        try std.testing.expect(oauth.grant != null);
        try std.testing.expectEqual(retired_before, effects.deleted);
        const actual = runtime.state.management.?.runtime_manifest.?.entries[0];
        try std.testing.expect(actual.state == .loaded);
        try std.testing.expectEqualSlices(u8, &loaded_source, &actual.state.loaded);
        try std.testing.expectEqual(@as(u32, if (referenced) 1 else 0), actual.task_references);
    }
}

test "OAuth refresh protects a loaded id across rejected timeout replacement and rollback" {
    var effects = OauthTestEffects{};
    var harness = TestHarness{};
    var runtime = try testGrantedOauthRuntime(&effects, &harness, true, 90_000);
    defer runtime.deinit();
    var original = (try runtime.prepareConfigurationStep(3, .automatic)).?;
    defer original.deinit();
    var manifest = (try configuration.RuntimeManifest.candidate(std.testing.allocator, &original.preparation)).?;
    try std.testing.expect(runtime.completeConfigurationApply(3, &original.preparation, &manifest, null, null, false));
    original.preparation = .{ .allocator = std.testing.allocator, .state = .empty };
    const current = runtime.state.management.?.desiredRegistry().?.servers[0];
    const original_timeout = current.timeout_ms;
    try std.testing.expectEqual(.saved, try runtime.updateOauthHttpConnection(3, .{ .server_id = "oauth", .display_name = "OAuth", .negotiation = current.negotiation, .timeout_ms = original_timeout + 1, .url = "https://mcp.example.test/mcp", .client = .{ .pre_registered = .{ .client_id = current.auth.oauth.?.registration.client_id.?, .token_endpoint_auth_method = "none" } } }));
    try std.testing.expect(!policy.runtimeOauthLoaded(&runtime.state, runtime.state.management.?.desiredRegistry().?.servers[0]));
    const Commit = struct {
        count: usize = 0,
        fn commit(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.count += 1;
        }
    };
    var commit = Commit{};
    var first = (try runtime.beginOauthRefresh("oauth")).started;
    defer first.deinit();
    try std.testing.expectEqual(.retained_descriptor, first.runtime_binding);
    var access = "new-access-token".*;
    try std.testing.expectEqual(.saved, try runtime.completeOauthRefresh(.{ .operation_id = first.operation_id, .server_id = "oauth", .access_token = &access, .expires_at_unix_ms = 999_000 }, .{ .context = &commit, .commit_fn = Commit.commit }));
    var replacement = (try runtime.prepareConfigurationStep(5, .automatic)).?;
    defer replacement.deinit();
    try std.testing.expectEqual(.replace, replacement.target.kind);
    try std.testing.expect(runtime.failConfigurationApply(5, .rejected));
    const changed = runtime.state.management.?.desiredRegistry().?.servers[0];
    try std.testing.expectEqual(.saved, try runtime.updateOauthHttpConnection(5, .{ .server_id = "oauth", .display_name = "OAuth", .negotiation = changed.negotiation, .timeout_ms = original_timeout, .url = "https://mcp.example.test/mcp", .client = .{ .pre_registered = .{ .client_id = changed.auth.oauth.?.registration.client_id.?, .token_endpoint_auth_method = "none" } } }));
    var second = (try runtime.beginOauthRefresh("oauth")).started;
    defer second.deinit();
    try std.testing.expectEqual(.matching_descriptor, second.runtime_binding);
    try std.testing.expectEqual(@as(u64, 2), second.token_revision);
    var next = "next-access-token".*;
    try std.testing.expectEqual(.saved, try runtime.completeOauthRefresh(.{ .operation_id = second.operation_id, .server_id = "oauth", .access_token = &next, .expires_at_unix_ms = 1_999_000 }, .{ .context = &commit, .commit_fn = Commit.commit }));
    try std.testing.expectEqual(@as(usize, 2), commit.count);
    try std.testing.expectEqualStrings("ready", runtime.state.management.?.desiredRegistry().?.servers[0].auth.oauth.?.status);
}

test "refresh of a new consent retains the referenced old descriptor and retries replacement" {
    var effects = OauthTestEffects{};
    var harness = TestHarness{};
    var runtime = try testGrantedOauthRuntime(&effects, &harness, true, 90_000);
    defer runtime.deinit();
    var initial = (try runtime.prepareConfigurationStep(3, .automatic)).?;
    defer initial.deinit();
    var manifest = (try configuration.RuntimeManifest.candidate(std.testing.allocator, &initial.preparation)).?;
    try std.testing.expect(runtime.completeConfigurationApply(3, &initial.preparation, &manifest, null, null, false));
    initial.preparation = .{ .allocator = std.testing.allocator, .state = .empty };
    try testRetainOauthTaskReference(&runtime);
    const current = runtime.state.management.?.desiredRegistry().?.servers[0];
    const original_source = configuration.runtimeDescriptorFingerprint(current);
    try std.testing.expectEqual(.saved, try runtime.updateOauthHttpConnection(3, .{ .server_id = "oauth", .display_name = "OAuth", .negotiation = current.negotiation, .timeout_ms = current.timeout_ms + 1, .url = "https://mcp.example.test/mcp", .client = .{ .pre_registered = .{ .client_id = current.auth.oauth.?.registration.client_id.?, .token_endpoint_auth_method = "none" } } }));
    var first = (try runtime.prepareConfigurationStep(4, .automatic)).?;
    defer first.deinit();
    try std.testing.expect(runtime.failConfigurationApply(4, .rejected));
    var relogin = (try runtime.beginAuthorization(4, "oauth", "relogin")).?;
    defer relogin.deinit();
    try std.testing.expect(runtime.advanceAuthorization("relogin", .awaiting_consent));
    try std.testing.expect((try runtime.authorizeOauth(.{ .attempt_id = 2, .server_id = "oauth", .resource = "https://mcp.example.test/mcp", .issuer = "https://issuer.example.test", .scopes = &.{"files.read"}, .redirect_uri = "http://127.0.0.1:43123/auth/callback" })) == .ready);
    try std.testing.expect(runtime.advanceAuthorization("relogin", .awaiting_browser));
    const exchange = (try runtime.beginOauthCodeExchange("oauth")).started;
    try std.testing.expect(runtime.advanceAuthorization("relogin", .exchanging));
    var access = "consent-2-access".*;
    var refresh = "consent-2-refresh".*;
    try std.testing.expectEqual(.saved, try runtime.completeOauthCodeExchange(.{ .operation_id = exchange.operation.id, .server_id = "oauth", .access_token = &access, .refresh_token = &refresh, .expires_at_unix_ms = 90_000 }));
    try std.testing.expect(runtime.finishAuthorization("relogin"));
    var replacement = (try runtime.prepareConfigurationStep(6, .automatic)).?;
    defer replacement.deinit();
    try std.testing.expect(runtime.failConfigurationApply(6, .rejected));
    harness.unix_seconds = 100;
    try std.testing.expect((try runtime.prepareConfigurationStep(6, .{ .retry_server = "oauth" })) == null);
    try std.testing.expect(runtime.nextOauthExpiry().?.runtime_loaded);
    var binding = (try runtime.beginOauthRefresh("oauth")).started;
    defer binding.deinit();
    try std.testing.expectEqual(.retained_descriptor, binding.runtime_binding);
    try std.testing.expectEqual(@as(u64, 2), binding.consent_epoch);
    const Commit = struct {
        count: usize = 0,
        fn commit(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.count += 1;
        }
    };
    var commit = Commit{};
    var renewed = "new-access-token".*;
    try std.testing.expectEqual(.saved, try runtime.completeOauthRefresh(.{ .operation_id = binding.operation_id, .server_id = "oauth", .access_token = &renewed, .expires_at_unix_ms = 999_000 }, .{ .context = &commit, .commit_fn = Commit.commit }));
    const oauth = runtime.state.management.?.desiredRegistry().?.servers[0].auth.oauth.?;
    try std.testing.expectEqualStrings("ready", oauth.status);
    try std.testing.expectEqual(@as(u64, 2), oauth.grant.?.consent_epoch);
    try std.testing.expectEqual(@as(u64, 2), oauth.grant.?.token_revision);
    try std.testing.expectEqual(@as(usize, 1), commit.count);
    const actual = runtime.state.management.?.runtime_manifest.?.entries[0];
    try std.testing.expectEqualSlices(u8, &original_source, &actual.state.loaded);
    try std.testing.expectEqual(@as(u32, 1), actual.task_references);
    var retry = (try runtime.prepareConfigurationStep(7, .automatic)).?;
    defer retry.deinit();
    try std.testing.expectEqual(.replace, retry.target.kind);
}

test "ready OAuth re-login cancellation preserves grant only before confirmed consent" {
    for ([_]bool{ false, true }) |replace_pending| for ([_]bool{ false, true }) |confirmed| {
        var effects = OauthTestEffects{};
        var harness = TestHarness{};
        var runtime = try testGrantedOauthRuntime(&effects, &harness, true, 90_000);
        defer runtime.deinit();
        var generation: u64 = 3;
        if (replace_pending) {
            var initial = (try runtime.prepareConfigurationStep(generation, .automatic)).?;
            defer initial.deinit();
            var manifest = (try configuration.RuntimeManifest.candidate(std.testing.allocator, &initial.preparation)).?;
            try std.testing.expect(runtime.completeConfigurationApply(generation, &initial.preparation, &manifest, null, null, false));
            initial.preparation = .{ .allocator = std.testing.allocator, .state = .empty };
            const current = runtime.state.management.?.desiredRegistry().?.servers[0];
            try std.testing.expectEqual(.saved, try runtime.updateOauthHttpConnection(generation, .{ .server_id = "oauth", .display_name = "OAuth", .negotiation = current.negotiation, .timeout_ms = current.timeout_ms + 1, .url = "https://mcp.example.test/mcp", .client = .{ .pre_registered = .{ .client_id = current.auth.oauth.?.registration.client_id.?, .token_endpoint_auth_method = "none" } } }));
            generation += 1;
        }
        var rejected = (try runtime.prepareConfigurationStep(generation, .automatic)).?;
        defer rejected.deinit();
        try std.testing.expect(runtime.failConfigurationApply(generation, .rejected));
        var start = (try runtime.beginAuthorization(generation, "oauth", "ready-relogin")).?;
        defer start.deinit();
        try std.testing.expect(runtime.advanceAuthorization("ready-relogin", .awaiting_consent));
        const retired_before = effects.deleted;
        if (confirmed) {
            try std.testing.expect((try runtime.authorizeOauth(.{ .attempt_id = 2, .server_id = "oauth", .resource = "https://mcp.example.test/mcp", .issuer = "https://issuer.example.test", .scopes = &.{"files.read"}, .redirect_uri = "http://127.0.0.1:43123/auth/callback" })) == .ready);
            generation += 1;
        }
        try std.testing.expect(runtime.finishAuthorization("ready-relogin"));
        const oauth = runtime.state.management.?.desiredRegistry().?.servers[0].auth.oauth.?;
        try std.testing.expectEqualStrings(if (confirmed) "awaiting_tokens" else "ready", oauth.status);
        try std.testing.expectEqual(!confirmed, oauth.grant != null);
        if (confirmed) try std.testing.expect(effects.deleted > retired_before) else try std.testing.expectEqual(retired_before, effects.deleted);
        try std.testing.expect(runtime.canBeginAuthorization(generation, "oauth"));
        const pending = try runtime.prepareConfigurationStep(generation, .automatic);
        if (pending) |value| {
            var step = value;
            defer step.deinit();
            try std.testing.expect(confirmed and replace_pending);
            try std.testing.expectEqual(.remove, step.target.kind);
        } else try std.testing.expect(!confirmed or !replace_pending);
    };
}

test "Product MCP manual recovery distinguishes HTTP auth refusal from network failure and stops new-token loops" {
    for ([_]bool{ false, true }) |has_expiry| for ([_]bool{ false, true }) |http_rejection| {
        var effects = OauthTestEffects{};
        var harness = TestHarness{};
        var runtime = try testGrantedOauthRuntime(&effects, &harness, true, if (has_expiry) 90_000 else null);
        defer runtime.deinit();
        var first = (try runtime.prepareConfigurationStep(3, .automatic)).?;
        defer first.deinit();
        try std.testing.expect(runtime.failConfigurationApply(3, .rejected));
        try std.testing.expect(runtime.canBeginAuthorization(3, "oauth"));
        try testOauthRecoveryProjection(&runtime, "failed");
        try std.testing.expect(runtime.nextOauthExpiry() == null);
        const source = configuration.runtimeDescriptorFingerprint(runtime.state.management.?.desiredRegistry().?.servers[0]);
        if (http_rejection) {
            try std.testing.expectEqual(.stale, try runtime.requireOauthReauthorization(.{ .server_id = "oauth", .source_fingerprint = @splat(0), .reason = .http_rejection, .consent_epoch = 1, .token_revision = 1, .challenge_scopes = &.{}, .challenge_scopes_complete = false }));
            try std.testing.expectEqual(.applied, try runtime.requireOauthReauthorization(.{ .server_id = "oauth", .source_fingerprint = source, .reason = .http_rejection, .consent_epoch = 1, .token_revision = 1, .challenge_scopes = &.{}, .challenge_scopes_complete = false }));
            try std.testing.expectEqualStrings("ready", runtime.state.management.?.desiredRegistry().?.servers[0].auth.oauth.?.status);
        }
        var retry = try runtime.prepareConfigurationStep(3, .{ .retry_server = "oauth" });
        defer if (retry) |*value| value.deinit();
        if (!http_rejection) {
            try std.testing.expect(retry != null);
            try std.testing.expect(!runtime.state.management.?.oauth_schedule.refreshRequested("oauth"));
            try std.testing.expect(runtime.state.management.?.desiredRegistry().?.oauth_operation == null);
            try std.testing.expect(runtime.failConfigurationApply(3, .rejected));
            continue;
        }
        try std.testing.expect(retry == null);
        try std.testing.expect(runtime.nextOauthExpiry().?.expires_at_unix_ms <= 1000);
        var binding = (try runtime.beginOauthRefresh("oauth")).started;
        defer binding.deinit();
        const Commit = struct {
            fn commit(_: *anyopaque) void {}
        };
        var token = "new-access-token".*;
        try std.testing.expectEqual(.saved, try runtime.completeOauthRefresh(.{ .operation_id = binding.operation_id, .server_id = "oauth", .access_token = &token, .expires_at_unix_ms = 999_000 }, .{ .context = &effects, .commit_fn = Commit.commit }));
        var fresh = (try runtime.prepareConfigurationStep(4, .automatic)).?;
        defer fresh.deinit();
        try std.testing.expect(runtime.failConfigurationApply(4, .rejected));
        harness.unix_seconds = 2000;
        for (0..3) |_| try std.testing.expect(runtime.nextOauthExpiry() == null);
        try std.testing.expectEqual(.stale, try runtime.requireOauthReauthorization(.{ .server_id = "oauth", .source_fingerprint = source, .reason = .http_rejection, .consent_epoch = 1, .token_revision = 1, .challenge_scopes = &.{}, .challenge_scopes_complete = false }));
        try std.testing.expect(try runtime.requestRefresh(false));
        harness.executeQueued();
        try std.testing.expect(runtime.syncRefreshJob());
        try std.testing.expect(runtime.nextOauthExpiry() == null);
        try std.testing.expectEqual(.saved, (try runtime.createHttpServer(4, .{ .display_name = "Unrelated", .url = "https://other.example.test/mcp" })).outcome);
        try std.testing.expect(runtime.nextOauthExpiry() == null);
        try std.testing.expect(runtime.canBeginAuthorization(5, "oauth"));
        // Exercise an actual unrelated add/remove, including the membership
        // epoch and the planner's next-round reopening. It must not refresh
        // the failed OAuth binding after its new token expires.
        var unrelated = (try runtime.prepareConfigurationStep(5, .automatic)).?;
        defer unrelated.deinit();
        try std.testing.expect(!std.mem.eql(u8, unrelated.target.id(), "oauth"));
        var unrelated_manifest = (try configuration.RuntimeManifest.candidate(std.testing.allocator, &unrelated.preparation)).?;
        try std.testing.expect(runtime.completeConfigurationApply(5, &unrelated.preparation, &unrelated_manifest, null, null, false));
        unrelated.preparation = .{ .allocator = std.testing.allocator, .state = .empty };
        const unrelated_id = runtime.state.management.?.desiredRegistry().?.servers[1].id;
        try std.testing.expectEqual(.saved, try runtime.setServerEnabled(5, .{ .server_id = unrelated_id, .enabled = false }));
        var removal = (try runtime.prepareConfigurationStep(6, .automatic)).?;
        defer removal.deinit();
        try std.testing.expectEqual(.remove, removal.target.kind);
        var removed_manifest = (try configuration.RuntimeManifest.candidate(std.testing.allocator, &removal.preparation)).?;
        try std.testing.expect(runtime.completeConfigurationApply(6, &removal.preparation, &removed_manifest, null, null, false));
        removal.preparation = .{ .allocator = std.testing.allocator, .state = .empty };
        try std.testing.expect((try runtime.prepareConfigurationStep(6, .automatic)) == null);
        try std.testing.expect(!runtime.inspectDesiredConfiguration().?.authorization_recovery_pending);
        try std.testing.expect(runtime.nextOauthExpiry() == null);
        // Explicitly withdrawing then restoring this source is a new user
        // intent. Inactive results must not resurrect the previous failure.
        try std.testing.expectEqual(.saved, try runtime.setServerEnabled(6, .{ .server_id = "oauth", .enabled = false }));
        try std.testing.expectEqual(.idle, runtime.state.configuration_apply_state);
        try std.testing.expectEqual(.saved, try runtime.setServerEnabled(7, .{ .server_id = "oauth", .enabled = true }));
        try std.testing.expect(runtime.nextOauthExpiry() != null);
        try std.testing.expect((try runtime.prepareConfigurationStep(8, .automatic)) == null);
        try std.testing.expect(runtime.inspectDesiredConfiguration().?.authorization_recovery_pending);
    };
}

test "cold absence supports consent DCR with a secret and reauthorization through token commit" {
    for ([_][]const u8{ "consent_required", "client_registration_required", "reauth_required" }) |initial_status| {
        var effects = OauthTestEffects{};
        var harness = TestHarness{};
        var runtime = try effects.coldRuntime(&harness, initial_status);
        defer runtime.deinit();
        try std.testing.expectEqual(.current, runtime.state.management.?.inspect().runtime_alignment);
        var start = (try runtime.beginAuthorization(1, "oauth", "attempt")).?;
        defer start.deinit();
        try std.testing.expect(runtime.advanceAuthorization("attempt", .awaiting_consent));
        if (std.mem.eql(u8, initial_status, "client_registration_required")) {
            const begun = try runtime.beginOauthDynamicRegistration(.{ .server_id = "oauth", .resource = "https://mcp.example.test/mcp", .issuer = "https://issuer.example.test", .scopes = &.{"files.read"}, .redirect_uri = "http://127.0.0.1:43123/auth/callback" });
            try std.testing.expect(begun == .started);
            try std.testing.expect(runtime.advanceAuthorization("attempt", .registering));
            var secret = "client-secret".*;
            try std.testing.expectEqual(.saved, try runtime.completeOauthDynamicRegistration(.{ .operation_id = begun.started.id, .server_id = "oauth", .client_id = "issued-client", .token_endpoint_auth_method = "client_secret_basic", .client_secret = &secret }));
            try std.testing.expect(runtime.state.management.?.desiredRegistry().?.servers[0].auth.oauth.?.registration.client_secret_ref != null);
        }
        try std.testing.expect((try runtime.authorizeOauth(.{ .attempt_id = 1, .server_id = "oauth", .resource = "https://mcp.example.test/mcp", .issuer = "https://issuer.example.test", .scopes = &.{"files.read"}, .redirect_uri = "http://127.0.0.1:43123/auth/callback" })) == .ready);
        try std.testing.expectEqual(.current, runtime.state.management.?.inspect().runtime_alignment);
        try std.testing.expect(runtime.advanceAuthorization("attempt", .awaiting_browser));
        const exchange = try runtime.beginOauthCodeExchange("oauth");
        try std.testing.expect(exchange == .started);
        try std.testing.expect(runtime.advanceAuthorization("attempt", .exchanging));
        var access = "access-token".*;
        var refresh = "refresh-token".*;
        try std.testing.expectEqual(.saved, try runtime.completeOauthCodeExchange(.{ .operation_id = exchange.started.operation.id, .server_id = "oauth", .access_token = &access, .refresh_token = &refresh, .expires_at_unix_ms = 90_000 }));
        try std.testing.expect(runtime.finishAuthorization("attempt"));
        const current = runtime.state.management.?.desiredRegistry().?;
        try std.testing.expectEqualStrings("ready", current.servers[0].auth.oauth.?.status);
        const deadline = runtime.state.management.?.oauth_schedule.eligibleAt("oauth", 90_000);
        try std.testing.expectEqual(@as(u64, 67_750), deadline);
        try std.testing.expectEqual(deadline, runtime.nextOauthExpiry().?.expires_at_unix_ms);
        harness.unix_seconds = 80;
        try std.testing.expectEqual(deadline, runtime.state.management.?.oauth_schedule.eligibleAt("oauth", 90_000));
        try std.testing.expectEqual(deadline, runtime.nextOauthExpiry().?.expires_at_unix_ms);
        try std.testing.expectEqual(@as(?u64, 90_000), current.servers[0].auth.oauth.?.grant.?.expires_at_unix_ms);
        harness.unix_seconds = 1;
        // Tokens now require real configuration apply; absence cannot pretend loaded.
        try std.testing.expectEqual(.restart_required, runtime.state.management.?.inspect().runtime_alignment);
        const auth_ref = try std.testing.allocator.dupe(u8, current.servers[0].auth.oauth.?.grant.?.access_token_ref);
        defer std.testing.allocator.free(auth_ref);
        const revision = current.servers[0].auth.oauth.?.grant.?.token_revision;
        const deletion_count = effects.deleted;
        try std.testing.expectEqual(.saved, try runtime.updateOauthHttpConnection(current.generation, .{ .server_id = "oauth", .display_name = "Renamed", .negotiation = "compat_only", .timeout_ms = 2000, .url = "https://mcp.example.test/mcp", .client = if (std.mem.eql(u8, initial_status, "client_registration_required")) .dynamic_registration else .{ .pre_registered = .{ .client_id = "client" } } }));
        const edited = runtime.state.management.?.desiredRegistry().?.servers[0].auth.oauth.?;
        try std.testing.expectEqualStrings(auth_ref, edited.grant.?.access_token_ref);
        try std.testing.expectEqual(revision, edited.grant.?.token_revision);
        try std.testing.expectEqual(deletion_count, effects.deleted);
        if (std.mem.eql(u8, initial_status, "client_registration_required")) try std.testing.expect(edited.registration.client_secret_ref != null);
        const edited_generation = runtime.state.management.?.desiredRegistry().?.generation;
        const replacement: configuration.UpdateOauthHttpConnectionInput = .{
            .server_id = "oauth",
            .display_name = "Replacement",
            .negotiation = "automatic",
            .timeout_ms = 2000,
            .url = "https://other.example.test/mcp",
            .client = .{ .pre_registered = .{ .client_id = "other-client" } },
        };
        effects.registry_effect = .failed;
        try std.testing.expectEqual(.rejected, try runtime.updateOauthHttpConnection(edited_generation, replacement));
        try std.testing.expectEqualStrings(auth_ref, runtime.state.management.?.desiredRegistry().?.servers[0].auth.oauth.?.grant.?.access_token_ref);
        try std.testing.expectEqual(deletion_count, effects.deleted);
        effects.registry_effect = .committed;
        try std.testing.expectEqual(.saved, try runtime.updateOauthHttpConnection(edited_generation, replacement));
        const replaced = runtime.state.management.?.desiredRegistry().?.servers[0].auth.oauth.?;
        try std.testing.expect(replaced.grant == null and replaced.consent == null and replaced.registration.client_secret_ref == null);
        try std.testing.expectEqualStrings("consent_required", replaced.status);
        try std.testing.expect(effects.deleted >= deletion_count + 2);
    }
}

test "catalog refresh waits for OAuth marker without timer spin and resumes on release" {
    var effects = OauthTestEffects{};
    var harness = TestHarness{};
    var runtime = try effects.coldRuntime(&harness, "client_registration_required");
    defer runtime.deinit();
    var start = (try runtime.beginAuthorization(1, "oauth", "attempt")).?;
    defer start.deinit();
    try std.testing.expect(runtime.advanceAuthorization("attempt", .awaiting_consent));
    const begin = try runtime.beginOauthDynamicRegistration(.{ .server_id = "oauth", .resource = "https://mcp.example.test/mcp", .issuer = "https://issuer.example.test", .scopes = &.{"files.read"}, .redirect_uri = "http://127.0.0.1:43123/auth/callback" });
    try std.testing.expect(begin == .started);
    try std.testing.expect(!(try runtime.requestRefresh(false)));
    // A previously elapsed retry floor must not turn the transaction wait into
    // a one-millisecond loop. Spurious timer deliveries remain harmless.
    runtime.state.refresh_not_before_ms = 1;
    for (0..5) |_| {
        harness.now_ms += 1;
        _ = runtime.onRefreshTimer();
        try std.testing.expect(harness.armed_deadline_ms == null);
        try std.testing.expect(runtime.state.refresh_pending and harness.queued == null);
    }
    try std.testing.expectEqual(.saved, try runtime.recoverOauthOperation(begin.started.id));
    try std.testing.expect(!runtime.state.refresh_pending and harness.queued != null);
    harness.executeQueued();
    try std.testing.expect(runtime.syncRefreshJob());
    try std.testing.expectEqual(@as(usize, 1), harness.activations);
}

fn testEmptyRuntime(harness: *TestHarness) !Runtime {
    const allocator = std.testing.allocator;
    const preparation: configuration.Preparation = .{ .allocator = allocator, .state = .empty };
    var manifest = (try configuration.RuntimeManifest.candidate(allocator, &preparation)).?;
    const management = try configuration.ManagementPort.init(allocator, .{
        .schema_version = configuration.schema_version,
        .generation = 1,
        .oauth_operation = null,
        .servers = &.{},
    }, .{
        .persistence = .{ .available = true },
        .credentials = .{ .available = true },
        .limits = test_limits,
        .runtime_manifest = &manifest,
    });
    return Runtime.init(allocator, harness.ports(), .{
        .preparation = .{ .allocator = allocator, .state = .empty },
        .activation = null,
        .activation_failed = false,
        .management = management,
        .admission = .{ .ready = .{ .selection = null, .catalog_generation = null } },
        .host_capabilities = .{},
        .committed = true,
    });
}

test "Product MCP automatic failures back off then pause until explicit refresh" {
    var harness = TestHarness{ .activation_outcome = .{ .unavailable = .refresh_failed } };
    var runtime = try testEmptyRuntime(&harness);
    defer runtime.deinit();
    try std.testing.expect(try runtime.requestRefresh(false));
    var previous_delay: u64 = 0;
    for (0..5) |index| {
        harness.executeQueued();
        try std.testing.expect(runtime.syncRefreshJob());
        try std.testing.expectEqual(index + 1, harness.activations);
        if (index == 4) break;
        const deadline = harness.armed_deadline_ms orelse return error.TestUnexpectedResult;
        const delay = deadline - harness.now_ms;
        try std.testing.expect(delay > previous_delay);
        previous_delay = delay;
        // A new Task's freshness recovery cannot skip the backoff.
        _ = runtime.recoverExpiredCatalog();
        try std.testing.expect(harness.queued == null);
        harness.now_ms = deadline;
        _ = runtime.onRefreshTimer();
        try std.testing.expect(harness.queued != null);
    }
    try std.testing.expect(runtime.state.refresh_paused);
    for (0..8) |_| {
        harness.now_ms += 60_000;
        _ = runtime.onRefreshTimer();
        _ = runtime.recoverExpiredCatalog();
        try std.testing.expect(harness.queued == null);
    }
    try std.testing.expectEqual(@as(usize, 5), harness.activations);
    harness.activation_outcome = .empty;
    try std.testing.expect(try runtime.requestRefresh(false));
    harness.executeQueued();
    try std.testing.expect(runtime.syncRefreshJob());
    try std.testing.expect(!runtime.state.refresh_paused);
    try std.testing.expectEqual(@as(u8, 0), runtime.state.refresh_failures);
}

test "Product MCP timer arm failure is observable and recovery clears it" {
    var harness = TestHarness{ .failed_enqueues = 1, .arm_succeeds = false };
    var runtime = try testEmptyRuntime(&harness);
    defer runtime.deinit();
    try std.testing.expectError(error.QueueFull, runtime.requestRefresh(false));
    try std.testing.expect(runtime.state.refresh_schedule_failed);
    try std.testing.expect(runtime.takeChanged());
    harness.arm_succeeds = true;
    runtime.rearmRefreshTimer();
    try std.testing.expect(!runtime.state.refresh_schedule_failed);
    try std.testing.expect(runtime.takeChanged());
    harness.now_ms = harness.armed_deadline_ms.?;
    _ = runtime.onRefreshTimer();
    harness.executeQueued();
    _ = runtime.syncRefreshJob();
}

test "Product MCP rejected refresh keeps its original expiry even across retry backoff" {
    var harness = TestHarness{ .activation_outcome = .{ .unavailable = .refresh_rejected } };
    var runtime = try testEmptyRuntime(&harness);
    defer runtime.deinit();
    runtime.state.expiry_deadline_ms = 1_000;
    try std.testing.expect(try runtime.requestRefresh(false));
    harness.executeQueued();
    _ = runtime.syncRefreshJob();
    try std.testing.expect(runtime.newTaskAuthorityReady());
    try std.testing.expectEqual(@as(?u64, 1_000), runtime.state.expiry_deadline_ms);
    try std.testing.expectEqual(@as(?u64, 1_000), harness.armed_deadline_ms);
    harness.now_ms = 1_000;
    _ = runtime.onRefreshTimer();
    try std.testing.expect(!runtime.newTaskAuthorityReady());
    try std.testing.expect(harness.queued == null);
    try std.testing.expectEqual(@as(?u64, 1_000), runtime.state.expiry_deadline_ms);
    harness.now_ms = 1_100;
    _ = runtime.onRefreshTimer();
    try std.testing.expect(harness.queued != null);
    harness.executeQueued();
    _ = runtime.syncRefreshJob();
}

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

test "Product MCP secret validation preserves target transport and authority checks" {
    for ([_]bool{ true, false }) |stdio| {
        var limits = test_limits;
        limits.max_credential_secret_bytes = if (stdio) 4096 else 8192;
        var slots = [_]configuration.SecretSlotWire{.{ .name = "TOKEN", .credential_ref = null }};
        var servers = [_]configuration.ServerWire{.{
            .id = "fixture",
            .namespace = "fixture",
            .display_name = "Fixture",
            .enabled = false,
            .negotiation = "automatic",
            .timeout_ms = 1000,
            .transport = if (stdio)
                .{ .kind = "stdio", .command = "fixture-mcp", .environment = &slots }
            else
                .{ .kind = "streamable_http", .url = "https://mcp.example.test/rpc", .headers = &slots },
            .auth = .{ .kind = "static", .oauth = null },
            .connection_approval = null,
            .tools = &.{},
        }};
        const fingerprint = configuration.connectionFingerprint(servers[0]);
        servers[0].connection_approval = .{ .fingerprint = &fingerprint };
        var harness = TestHarness{};
        var runtime = Runtime.init(std.testing.allocator, harness.ports(), .{
            .preparation = .{ .allocator = std.testing.allocator, .state = .empty },
            .activation = null,
            .activation_failed = false,
            .management = try configuration.ManagementPort.init(std.testing.allocator, .{
                .schema_version = configuration.schema_version,
                .generation = 1,
                .oauth_operation = null,
                .servers = &servers,
            }, .{
                .persistence = .{ .available = true },
                .credentials = .{ .available = true },
                .limits = limits,
            }),
            .admission = .{ .ready = .{ .selection = null, .catalog_generation = null } },
            .host_capabilities = .{ .secret_capture = true },
        });
        defer runtime.deinit();
        try std.testing.expect(!runtime.capabilities().host.secret_capture);
        try std.testing.expectEqual(0, runtime.capabilities().secret_max_bytes);
        try std.testing.expect(runtime.syncInitialHealth());
        try std.testing.expect(runtime.capabilities().host.secret_capture);
        try std.testing.expectEqual(limits.max_credential_secret_bytes, runtime.capabilities().secret_max_bytes);

        const target: McpSecretCaptureTarget = if (stdio)
            .{ .stdio_environment = "token" }
        else
            .{ .http_header = "token" };
        const mismatched: McpSecretCaptureTarget = if (stdio)
            .{ .http_header = "TOKEN" }
        else
            .{ .stdio_environment = "TOKEN" };
        try runtime.validateSecretCapture(1, "fixture", target);
        try std.testing.expectError(error.McpManagementUnavailable, runtime.validateSecretCapture(1, "fixture", mismatched));
        try std.testing.expectError(error.McpManagementUnavailable, runtime.validateSecretCapture(1, "fixture", .oauth_client_secret));
        try std.testing.expectError(error.McpManagementUnavailable, runtime.validateSecretCapture(2, "fixture", target));
        try std.testing.expectError(error.McpManagementUnavailable, runtime.validateSecretCapture(1, "missing", target));
        const missing: McpSecretCaptureTarget = if (stdio)
            .{ .stdio_environment = "MISSING" }
        else
            .{ .http_header = "MISSING" };
        try std.testing.expectError(error.McpManagementUnavailable, runtime.validateSecretCapture(1, "fixture", missing));

        const desired = runtime.state.management.?.desiredRegistry().?;
        desired.servers[0].connection_approval = null;
        try std.testing.expectError(error.McpManagementUnavailable, runtime.validateSecretCapture(1, "fixture", target));
    }
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

    try std.testing.expect(runtime.failConfigurationApply(1, .preparation));
    try std.testing.expect(!runtime.state.refresh_pending);
    try std.testing.expect(runtime.hasRefreshJob());
    try std.testing.expect(harness.queued != null);

    harness.executeQueued();
    try std.testing.expect(runtime.syncRefreshJob());
    try std.testing.expect(!runtime.hasRefreshJob());
    try std.testing.expectEqual(@as(usize, 1), harness.notifications);
}

test "Product MCP Runtime retries a pending refresh after executor enqueue failure" {
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
    var harness = TestHarness{ .failed_enqueues = 1 };
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
    try std.testing.expectError(error.QueueFull, runtime.requestRefresh(true));
    try std.testing.expect(runtime.state.refresh_pending);
    try std.testing.expect(!runtime.hasRefreshJob());
    try std.testing.expectEqual(@as(?u64, 1_100), harness.armed_deadline_ms);

    try std.testing.expect(runtime.onRefreshTimer());
    try std.testing.expect(runtime.state.refresh_pending);
    try std.testing.expect(harness.queued == null);
    harness.now_ms = 1_100;
    try std.testing.expect(runtime.onRefreshTimer());
    try std.testing.expect(!runtime.state.refresh_pending);
    try std.testing.expect(runtime.hasRefreshJob());
    try std.testing.expect(harness.queued != null);
    harness.executeQueued();
    try std.testing.expect(runtime.syncRefreshJob());
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
        (try runtime.createHttpServer(1, .{
            .display_name = "Prepared while applying",
            .url = "https://mcp.example.test/rpc",
        })).outcome,
    );
    try std.testing.expectEqual(@as(u64, 1), runtime.state.management.?.inspect().desired_generation);
}

test "Product MCP apply keeps stale ownership and settles late success without reopening shutdown" {
    for ([_]bool{ false, true }) |shutdown| {
        const allocator = std.testing.allocator;
        const registry: configuration.RegistryWire = .{
            .schema_version = configuration.schema_version,
            .generation = 1,
            .oauth_operation = null,
            .servers = &.{},
        };
        const management = try configuration.ManagementPort.init(allocator, registry, .{
            .persistence = .{ .available = true },
            .credentials = .{ .available = true },
            .limits = test_limits,
        });
        var harness = TestHarness{};
        var runtime = Runtime.init(allocator, harness.ports(), .{
            .preparation = .{ .allocator = allocator, .state = .empty },
            .activation = null,
            .activation_failed = false,
            .management = management,
            .admission = .{ .ready = .{ .selection = null, .catalog_generation = null } },
            .host_capabilities = .{},
        });
        defer {
            runtime.beginShutdown();
            if (harness.queued != null) harness.executeQueued();
            if (runtime.hasRefreshJob()) _ = runtime.syncRefreshJob();
            runtime.deinit();
        }
        _ = runtime.syncInitialHealth();
        try std.testing.expect(try runtime.beginConfigurationApply(1));
        var bytes: [configuration.max_store_bytes]u8 = undefined;
        const encoded = try configuration.encode(&bytes, registry, test_limits);
        var preparation = try configuration.prepare(allocator, encoded, true, false, .{}, test_limits);
        var preparation_owned = true;
        defer if (preparation_owned) preparation.deinit();
        var manifest = (try configuration.RuntimeManifest.candidate(allocator, &preparation)).?;
        var manifest_owned = true;
        defer if (manifest_owned) manifest.deinit();

        try std.testing.expect(!runtime.completeConfigurationApply(2, &preparation, &manifest, null, null, false));
        try std.testing.expectEqual(@as(?u64, 1), preparation.generation());
        try std.testing.expectEqual(McpConfigurationApplyState.applying, runtime.state.configuration_apply_state);
        if (shutdown) runtime.beginShutdown();
        try std.testing.expect(runtime.completeConfigurationApply(1, &preparation, &manifest, null, null, !shutdown));
        preparation_owned = false;
        manifest_owned = false;
        try std.testing.expectEqual(@as(?u64, 1), runtime.state.preparation.generation());
        try std.testing.expectEqual(configuration.RuntimeAlignment.current, runtime.state.management.?.inspect().runtime_alignment);
        try std.testing.expectEqual(McpConfigurationApplyState.idle, runtime.state.configuration_apply_state);
        try std.testing.expectEqual(if (shutdown) McpAdmissionBlockReason.shutting_down else .activation_unavailable, runtime.state.admission.blocked);
        try std.testing.expect(runtime.state.activation == null);
        try std.testing.expectEqual(!shutdown, harness.queued != null);
        try std.testing.expectEqual(!shutdown, runtime.hasRefreshJob());
        try std.testing.expect(!runtime.selectionForNewTask().available);
    }
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
            .source_fingerprint = @splat(0),
            .reason = .challenge,
            .consent_epoch = 1,
            .token_revision = 1,
            .challenge_scopes = &.{},
            .challenge_scopes_complete = true,
        }),
    );
    try std.testing.expect(runtime.runtime_auth_delivery_pending);
    try std.testing.expectEqual(@as(usize, 0), harness.notifications);
    try std.testing.expect(runtime.failConfigurationApply(1, .preparation));
    try std.testing.expect(!runtime.runtime_auth_delivery_pending);
    try std.testing.expectEqual(@as(usize, 1), harness.notifications);
}

test "Product MCP composition capacity failure is processed and does not starve a replacement" {
    const allocator = std.testing.allocator;
    var limits = test_limits;
    limits.max_servers = 2;
    var servers: [4]configuration.ServerWire = undefined;
    var fingerprints: [4][64]u8 = undefined;
    const ids = [_][]const u8{ "a", "b", "c", "a" };
    for (&servers, 0..) |*server, i| {
        server.* = .{
            .id = ids[i],
            .namespace = ids[i],
            .display_name = ids[i],
            .enabled = true,
            .negotiation = "automatic",
            .timeout_ms = if (i == 3) 2000 else 1000,
            .transport = .{ .kind = "streamable_http", .url = "https://example.test/mcp" },
            .auth = .{ .kind = "none", .oauth = null },
            .connection_approval = null,
            .tools = &.{},
        };
        fingerprints[i] = configuration.connectionFingerprint(server.*);
        server.connection_approval = .{ .fingerprint = &fingerprints[i] };
    }
    const actual: configuration.RegistryWire = .{ .schema_version = configuration.schema_version, .generation = 1, .oauth_operation = null, .servers = servers[0..2] };
    var bytes: [8192]u8 = undefined;
    var preparation = try configuration.prepare(allocator, try configuration.encode(&bytes, actual, limits), true, false, .{}, limits);
    var preparation_owned = true;
    defer if (preparation_owned) preparation.deinit();
    var manifest = (try configuration.RuntimeManifest.candidate(allocator, &preparation)).?;
    var manifest_owned = true;
    defer if (manifest_owned) manifest.deinit();
    for (manifest.entries) |*entry| entry.task_references = 1;
    const desired: configuration.RegistryWire = .{ .schema_version = configuration.schema_version, .generation = 2, .oauth_operation = null, .servers = servers[2..4] };
    const management = try configuration.ManagementPort.init(allocator, desired, .{ .persistence = .{ .available = true }, .credentials = .{ .available = true }, .limits = limits, .runtime_manifest = &manifest });
    manifest_owned = false;
    var harness = TestHarness{};
    var runtime = Runtime.init(allocator, harness.ports(), .{ .preparation = preparation, .activation = null, .activation_failed = false, .management = management, .admission = .{ .ready = .{ .selection = null, .catalog_generation = null } }, .host_capabilities = .{}, .committed = true });
    preparation_owned = false;
    defer runtime.deinit();
    var step = (try runtime.prepareConfigurationStep(2, .automatic)).?;
    defer step.deinit();
    try std.testing.expectEqualStrings("a", step.target.id());
    try std.testing.expectEqual(.replace, step.target.kind);
    try std.testing.expectEqual(@as(usize, 2), step.member_ids.len);
    const ledger = &runtime.state.management.?.convergence;
    const c = configuration.RuntimeApplyTarget.init("c", servers[2], .add);
    try std.testing.expect(ledger.handled(c));
    try std.testing.expectEqual(.capacity, ledger.results.items[0].outcome);
    try std.testing.expect(runtime.takeChanged());
    try std.testing.expect(runtime.failConfigurationApply(2, .preparation));
    try std.testing.expect((try runtime.prepareConfigurationStep(2, .automatic)) == null);
    try std.testing.expectEqual(configuration.RuntimeAlignment.current, runtime.state.management.?.inspect().runtime_alignment);
    for (runtime.state.management.?.runtime_manifest.?.entries) |entry| try std.testing.expectEqual(@as(u32, 1), entry.task_references);
    try std.testing.expect(harness.queued == null);
}

test "Product MCP obsolete add failures clear after disable or delete without another apply" {
    for ([_]bool{ false, true }) |remove| {
        var effects = OauthTestEffects{};
        var harness = TestHarness{};
        var runtime = try effects.coldRuntime(&harness, "consent_required");
        defer runtime.deinit();
        try std.testing.expectEqual(.saved, (try runtime.createHttpServer(1, .{ .display_name = "Unavailable", .url = "https://unavailable.example.test/mcp" })).outcome);
        var step = (try runtime.prepareConfigurationStep(2, .automatic)).?;
        defer step.deinit();
        const id = step.target.id();
        try std.testing.expect(runtime.failConfigurationApply(2, .rejected));
        try std.testing.expectEqual(.failed, runtime.state.configuration_apply_state);
        try std.testing.expectEqual(.current, runtime.state.management.?.inspect().runtime_alignment);
        try std.testing.expect(runtime.state.admission == .ready);
        const outcome = if (remove) try runtime.removeServer(2, id) else try runtime.setServerEnabled(2, .{ .server_id = id, .enabled = false });
        try std.testing.expectEqual(.saved, outcome);
        try std.testing.expectEqual(.idle, runtime.state.configuration_apply_state);
        try std.testing.expect((try runtime.prepareConfigurationStep(3, .retry_all)) == null);
        try std.testing.expectEqual(.idle, runtime.state.configuration_apply_state);
        try std.testing.expect(harness.queued == null);
    }
}

test "Product MCP later apply success preserves another current target failure" {
    var effects = OauthTestEffects{};
    var harness = TestHarness{};
    var runtime = try effects.coldRuntime(&harness, "consent_required");
    defer runtime.deinit();
    try std.testing.expectEqual(.saved, (try runtime.createHttpServer(1, .{ .display_name = "First", .url = "https://first.example.test/mcp" })).outcome);
    try std.testing.expectEqual(.saved, (try runtime.createHttpServer(2, .{ .display_name = "Second", .url = "https://second.example.test/mcp" })).outcome);
    var first = (try runtime.prepareConfigurationStep(3, .automatic)).?;
    defer first.deinit();
    try std.testing.expect(runtime.failConfigurationApply(3, .rejected));
    var second = (try runtime.prepareConfigurationStep(3, .automatic)).?;
    defer second.deinit();
    var manifest = (try configuration.RuntimeManifest.candidate(std.testing.allocator, &second.preparation)).?;
    try std.testing.expect(runtime.completeConfigurationApply(3, &second.preparation, &manifest, null, null, false));
    second.preparation = .{ .allocator = std.testing.allocator, .state = .empty };
    try std.testing.expectEqual(.failed, runtime.state.configuration_apply_state);
    const management = &runtime.state.management.?;
    try std.testing.expectEqual(@as(usize, 1), management.runtime_manifest.?.failureCount(management.desiredRegistry(), management.limits, &management.convergence));
}

test "Product MCP rejected replacement settles admission without waiting for catalog refresh" {
    var effects = OauthTestEffects{};
    var harness = TestHarness{};
    var runtime = try effects.coldRuntime(&harness, "consent_required");
    defer runtime.deinit();
    try std.testing.expectEqual(.saved, (try runtime.createHttpServer(1, .{ .display_name = "Original", .url = "https://original.example.test/mcp" })).outcome);
    var original = (try runtime.prepareConfigurationStep(2, .automatic)).?;
    defer original.deinit();
    var manifest = (try configuration.RuntimeManifest.candidate(std.testing.allocator, &original.preparation)).?;
    try std.testing.expect(runtime.completeConfigurationApply(2, &original.preparation, &manifest, null, null, false));
    original.preparation = .{ .allocator = std.testing.allocator, .state = .empty };
    try std.testing.expectEqual(.saved, try runtime.updateHttpConnection(2, .{ .server_id = original.target.id(), .display_name = "Changed", .url = "https://bad.example.test/mcp", .header_names = &.{}, .auth_mode = .none, .negotiation = "automatic", .timeout_ms = 1000 }));
    try std.testing.expectEqual(.pending_restart, runtime.state.admission.blocked);
    var replacement = (try runtime.prepareConfigurationStep(3, .automatic)).?;
    defer replacement.deinit();
    try std.testing.expectEqual(.replace, replacement.target.kind);
    try std.testing.expect(runtime.failConfigurationApply(3, .rejected));
    try std.testing.expectEqual(.current, runtime.state.management.?.inspect().runtime_alignment);
    try std.testing.expectEqual(.activation_unavailable, runtime.state.admission.blocked);
    try std.testing.expectEqual(.failed, runtime.state.configuration_apply_state);
    try std.testing.expect(harness.queued == null);
}

test "MCP create receipts only expose committed identity and own it across mutations" {
    var effects = OauthTestEffects{};
    var harness = TestHarness{};
    var runtime = try effects.coldRuntime(&harness, "consent_required");
    defer runtime.deinit();
    const first = try runtime.createHttpServer(1, .{ .display_name = "First", .url = "https://first.example.test/mcp" });
    try std.testing.expectEqual(.saved, first.outcome);
    const identity = first.server_id.?;
    try std.testing.expectEqualStrings(&identity, runtime.state.management.?.desiredRegistry().?.servers[1].id);
    const stale = try runtime.createHttpServer(1, .{ .display_name = "Stale", .url = "https://stale.example.test/mcp" });
    try std.testing.expectEqual(.stale_generation, stale.outcome);
    try std.testing.expect(stale.server_id == null);
    try std.testing.expectEqual(.saved, try runtime.renameServer(2, .{ .server_id = &identity, .display_name = "Renamed" }));
    try std.testing.expectEqualStrings(&identity, runtime.state.management.?.desiredRegistry().?.servers[1].id);
}

test "MCP process observations reject old attempts and changed sources" {
    var effects = OauthTestEffects{};
    var harness = TestHarness{};
    var runtime = try effects.coldRuntime(&harness, "consent_required");
    defer runtime.deinit();
    const created = try runtime.createStdioServer(1, .{ .display_name = "Local", .command = "node" });
    const id = created.server_id.?;
    const server = runtime.state.management.?.desiredRegistry().?.servers[1];
    var observation: configuration.ProcessObservation = .{ .server_id = &id, .source = configuration.runtimeDescriptorFingerprint(server), .attempt = 1, .fact = .pending };
    try std.testing.expect(try runtime.observeProcess(observation));
    observation.fact = .executable_missing;
    try std.testing.expect(try runtime.observeProcess(observation));
    try std.testing.expect(!try runtime.observeProcess(observation));
    observation.attempt = 2;
    observation.fact = .pending;
    try std.testing.expect(try runtime.observeProcess(observation));
    observation.attempt = 1;
    observation.fact = .stdio_closed;
    try std.testing.expect(!try runtime.observeProcess(observation));
    observation.attempt = 2;
    observation.source = @splat(0);
    try std.testing.expect(!try runtime.observeProcess(observation));
    try std.testing.expectEqual(configuration.ProcessFact.pending, runtime.state.process_observations.items[0].fact);
    observation.source = configuration.runtimeDescriptorFingerprint(server);
    try std.testing.expectEqual(.saved, try runtime.updateStdioConnection(2, .{ .server_id = &id, .display_name = "Local", .command = "other-node", .negotiation = "automatic", .timeout_ms = 30000, .auth_mode = .none }));
    try std.testing.expect(!try runtime.observeProcess(observation));
}
