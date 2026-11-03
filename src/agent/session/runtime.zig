//! Agent runtime lifecycle and shared execution helpers.

const std = @import("std");
const multimodal = @import("multimodal.zig");
const identity_profile = @import("identity.zig");
const sdk = @import("metask_agentcore");
const wire = sdk.types;
const event_pump = @import("event_pump");
const catalog = @import("agent_catalog");
const mcp_runtime = @import("agent_mcp_runtime");
const mcp_catalog = @import("agent_mcp_catalog");
const checkpoint = @import("agent_checkpoint");
const checkpoint_restore = @import("agent_checkpoint_restore");
const session_control = @import("control.zig");
const session_wire = @import("wire.zig");
const model_binding = @import("agent_model_binding");
const capabilities = @import("../capabilities.zig");
const session_binding = @import("binding.zig");
const image = @import("../image_generation.zig");
const image_tool = @import("../generate_image.zig");
const delivery_tool = @import("agent_file_delivery");
// Intentional same-module cycle with session.zig; Runtime and Session retain
// direct typed references without introducing a speculative context layer.
const root = @import("../session.zig");

var next_mcp_owner_id: std.atomic.Value(u64) = .init(1);

const Session = root.Session;
const Error = root.Error;
const Limits = root.Limits;
const SessionOpenOptions = root.SessionOpenOptions;
const SessionRestoreOptions = root.SessionRestoreOptions;
const SessionRestoreRoute = root.SessionRestoreRoute;
const SessionRoute = root.SessionRoute;
const CoreSessionIdentity = root.CoreSessionIdentity;
const WorkspaceInput = root.WorkspaceInput;
const WorkspaceTrust = root.WorkspaceTrust;
const EventReadyNotifier = root.EventReadyNotifier;
const EventReadyNotification = root.EventReadyNotification;
const OwnedCoreEvent = event_pump.OwnedCoreEvent;
const McpActivation = root.McpActivation;
const McpActivationOutcome = root.McpActivationOutcome;
const McpActivationUnavailableReason = root.McpActivationUnavailableReason;
const McpConfigurationApplyOutcome = root.McpConfigurationApplyOutcome;
const McpSelection = root.McpSelection;
const McpSelector = root.McpSelector;
const McpServerAllowlist = root.McpServerAllowlist;
const McpCatalogProjection = root.McpCatalogProjection;
const CatalogAcquisition = root.CatalogAcquisition;
const CatalogLease = root.CatalogLease;
const CatalogQuery = root.CatalogQuery;
const TerminationSignal = session_control.TerminationSignal;
const SessionDisposition = session_control.SessionDisposition;
const SessionControlBlock = session_binding.SessionControlBlock;
const providerKindCode = session_wire.providerKindCode;
const permissionModeCode = session_wire.permissionModeCode;
const shellPolicyCode = session_wire.shellPolicyCode;
const mcpUpdateStatusDisposition = root.mcpUpdateStatusDisposition;

const McpRefreshLease = struct {
    raw_runtime: *wire.RuntimeHandle,
    expected_servers: []const mcp_runtime.ExpectedServer,
    registry_generation: ?u64,
};

const max_mcp_configuration_applies: usize = 128;

pub const Runtime = struct {
    image_test: ?root.ImageGenerationTestOptions = null,
    image_budget: image.Budget = .{ .limit = 0 },
    image_results_created: std.atomic.Value(usize) = .init(0),
    image_results_released: std.atomic.Value(usize) = .init(0),
    delivery_results_outstanding: std.atomic.Value(usize) = .init(0),
    io: std.Io,
    allocator: std.mem.Allocator,
    api: sdk.Api,
    runtime: ?*wire.RuntimeHandle,
    max_prompt_bytes: usize,
    multimodal_input_budget: multimodal.Budget,
    max_event_bytes: usize,
    event_enqueue_timeout: std.Io.Duration,
    max_ui_request_bytes: usize,
    max_ui_response_bytes: usize,
    max_terminal_diagnostic_bytes: usize,
    event_ready_notifier: ?EventReadyNotifier,
    event_ready_retry_interval: std.Io.Duration,
    event_ready_timeout: std.Io.Duration,
    events: event_pump.EventPump,
    sessions_mutex: std.Io.Mutex = .init,
    shutdown_condition: std.Io.Condition = .init,
    sessions: []?*Session,
    session_reservations: []bool,
    shutting_down: std.atomic.Value(bool) = .init(false),
    shutdown_running: bool = false,
    shutdown_complete: bool = false,
    last_shutdown_error: ?Error = null,
    active_catalog_calls: usize = 0,
    active_catalog_leases: usize = 0,
    active_restore_calls: usize = 0,
    mcp_operation: mcp_runtime.OperationState = .{},
    mcp_registry_generation: ?u64,
    mcp_owner_id: u64,
    mcp_servers: mcp_runtime.Servers,
    retired_mcp_servers: std.ArrayList(mcp_runtime.Servers) = .empty,
    mcp_apply_revision: u64 = 0,
    next_session_id: u64 = 0,

    pub fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        limits: Limits,
    ) (Error || std.mem.Allocator.Error || error{UnsupportedAbi})!*Runtime {
        return initWithValidatedApi(io, allocator, try sdk.Api.discover(), limits, null);
    }

    /// Test-only injection boundary. `raw_api` is borrowed for the Agent
    /// Runtime lifetime and must outlive the Runtime.
    pub fn initWithApi(
        io: std.Io,
        allocator: std.mem.Allocator,
        raw_api: *const wire.ApiV1,
        limits: Limits,
    ) (Error || std.mem.Allocator.Error || error{UnsupportedAbi})!*Runtime {
        return initWithValidatedApi(io, allocator, try sdk.Api.validate(raw_api), limits, null);
    }

    /// Isolated transport and budget injection; the tool set matches product init.
    pub fn initImageGenerationForTesting(io: std.Io, allocator: std.mem.Allocator, limits: Limits, options: root.ImageGenerationTestOptions) !*Runtime {
        return initWithValidatedApi(io, allocator, try sdk.Api.discover(), limits, options);
    }

    pub fn initImageGenerationWithApiForTesting(io: std.Io, allocator: std.mem.Allocator, raw_api: *const wire.ApiV1, limits: Limits, options: root.ImageGenerationTestOptions) !*Runtime {
        return initWithValidatedApi(io, allocator, try sdk.Api.validate(raw_api), limits, options);
    }

    fn initWithValidatedApi(
        io: std.Io,
        allocator: std.mem.Allocator,
        api: sdk.Api,
        limits: Limits,
        image_test: ?root.ImageGenerationTestOptions,
    ) (Error || std.mem.Allocator.Error)!*Runtime {
        if (limits.max_sessions == 0 or limits.max_prompt_bytes == 0 or limits.max_multimodal_input_bytes == 0 or limits.event_capacity == 0 or
            limits.event_bytes == 0 or limits.per_session_event_capacity == 0 or
            limits.per_session_event_bytes == 0 or limits.max_event_bytes == 0 or
            limits.event_enqueue_timeout.nanoseconds <= 0 or limits.max_ui_request_bytes == 0 or
            limits.max_ui_response_bytes == 0 or limits.max_terminal_diagnostic_bytes == 0 or
            limits.event_ready_retry_interval.nanoseconds <= 0 or
            limits.event_ready_timeout.nanoseconds <= 0 or
            limits.event_ready_retry_interval.nanoseconds > limits.event_ready_timeout.nanoseconds)
            return error.InvalidLimits;
        if (image_test) |options| if (!options.limits.validate()) return error.InvalidLimits;
        const mcp_owner_id = try allocateMcpOwnerId();
        _ = std.math.mul(usize, limits.event_capacity, limits.max_event_bytes) catch
            return error.InvalidLimits;
        const self = try allocator.create(Runtime);
        errdefer allocator.destroy(self);
        const sessions = try allocator.alloc(?*Session, limits.max_sessions);
        errdefer allocator.free(sessions);
        @memset(sessions, null);
        const session_reservations = try allocator.alloc(bool, limits.max_sessions);
        errdefer allocator.free(session_reservations);
        @memset(session_reservations, false);
        var events = try event_pump.EventPump.init(
            io,
            allocator,
            .{
                .max_event_bytes = limits.max_event_bytes,
                .global_count = limits.event_capacity,
                .global_bytes = limits.event_bytes,
                .global_control_reserved_count = limits.control_reserved_capacity,
                .global_control_reserved_bytes = limits.control_reserved_bytes,
                .per_session_count = limits.per_session_event_capacity,
                .per_session_bytes = limits.per_session_event_bytes,
                .per_session_control_reserved_count = limits.per_session_control_reserved_capacity,
                .per_session_control_reserved_bytes = limits.per_session_control_reserved_bytes,
                .session_slots = limits.max_sessions,
            },
        );
        errdefer events.deinit();

        var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
        runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
        var builtin_views: [capabilities.builtins.len]wire.BytesViewV1 = undefined;
        for (capabilities.builtins, 0..) |builtin, index|
            builtin_views[index] = sdk.bytesView(capabilities.wireName(builtin));
        runtime_config.builtin_tools = &builtin_views;
        runtime_config.builtin_tool_count = builtin_views.len;
        var image_descriptor = std.mem.zeroes(wire.HostToolV1);
        image_descriptor.struct_size = @sizeOf(wire.HostToolV1);
        image_descriptor.ctx = self;
        image_descriptor.name = sdk.bytesView(image_tool.name);
        image_descriptor.description = sdk.bytesView(image_tool.description);
        image_descriptor.input_schema_json = sdk.bytesView(image_tool.schema);
        image_descriptor.execute = Session.executeImage;
        image_descriptor.release_result = Session.releaseImageResult;
        var delivery_descriptor = std.mem.zeroes(wire.HostToolV1);
        delivery_descriptor.struct_size = @sizeOf(wire.HostToolV1);
        delivery_descriptor.ctx = self;
        delivery_descriptor.name = sdk.bytesView(delivery_tool.name);
        delivery_descriptor.description = sdk.bytesView(delivery_tool.description);
        delivery_descriptor.input_schema_json = sdk.bytesView(delivery_tool.schema);
        delivery_descriptor.execute = Session.executeDelivery;
        delivery_descriptor.release_result = Session.releaseDeliveryResult;
        const host_tools = [_]wire.HostToolV1{ image_descriptor, delivery_descriptor };
        runtime_config.host_tools = &host_tools;
        runtime_config.host_tool_count = host_tools.len;
        const mcp_registry_generation = if (limits.mcp_input) |input|
            input.generation
        else
            null;
        var mcp_servers = if (limits.mcp_input) |input|
            input.take() catch return error.InvalidLimits
        else
            mcp_runtime.Servers.init(allocator, &.{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidConfig => return error.InvalidLimits,
            };
        errdefer mcp_servers.deinit();
        mcp_servers.attach(&runtime_config);
        var diagnostic = emptyOwnedBytes();
        var runtime: ?*wire.RuntimeHandle = null;
        const status = api.runtime().create()(&runtime_config, null, &runtime, &diagnostic);
        defer releaseOwned(api, &diagnostic);
        const typed_status = sdk.Status.fromCode(status) catch return error.CoreCallFailed;
        if (typed_status != .ok or runtime == null) return error.CoreCallFailed;
        errdefer {
            var destroy_diagnostic = emptyOwnedBytes();
            _ = api.runtime().destroy()(runtime, &destroy_diagnostic);
            releaseOwned(api, &destroy_diagnostic);
        }

        self.* = .{
            .image_test = image_test,
            .image_budget = .{ .limit = if (image_test) |options| options.limits.memory_bytes else image.production_limits.memory_bytes },
            .io = io,
            .allocator = allocator,
            .api = api,
            .runtime = runtime,
            .max_prompt_bytes = limits.max_prompt_bytes,
            .multimodal_input_budget = .{ .limit = limits.max_multimodal_input_bytes },
            .max_event_bytes = limits.max_event_bytes,
            .event_enqueue_timeout = limits.event_enqueue_timeout,
            .max_ui_request_bytes = limits.max_ui_request_bytes,
            .max_ui_response_bytes = limits.max_ui_response_bytes,
            .max_terminal_diagnostic_bytes = limits.max_terminal_diagnostic_bytes,
            .event_ready_notifier = limits.event_ready_notifier,
            .event_ready_retry_interval = limits.event_ready_retry_interval,
            .event_ready_timeout = limits.event_ready_timeout,
            .events = events,
            .sessions = sessions,
            .session_reservations = session_reservations,
            .mcp_owner_id = mcp_owner_id,
            .mcp_registry_generation = mcp_registry_generation,
            .mcp_servers = mcp_servers,
        };
        return self;
    }

    /// Performs one synchronous AgentCore discovery call. The caller decides
    /// where this blocking operation runs and owns the returned projection and
    /// opaque lease as two independent linear values.
    pub fn querySkillCatalog(
        self: *Runtime,
        input: CatalogQuery,
    ) (Error || std.mem.Allocator.Error)!CatalogAcquisition {
        try catalog.validateQuery(input);
        try validateCanonicalDirectory(self.io, self.allocator, input.workspaceRoot());
        try validateCanonicalDirectory(
            self.io,
            self.allocator,
            input.canonical_user_home,
        );
        for (input.additional_sources) |source|
            try validateCanonicalDirectory(self.io, self.allocator, source.canonical_root);

        self.sessions_mutex.lockUncancelable(self.io);
        if (self.shutting_down.load(.acquire)) {
            self.sessions_mutex.unlock(self.io);
            return error.RuntimeShuttingDown;
        }
        const raw_runtime = self.runtime orelse {
            self.sessions_mutex.unlock(self.io);
            return error.RuntimeShuttingDown;
        };
        self.active_catalog_calls += 1;
        self.sessions_mutex.unlock(self.io);

        var acquisition = catalog.query(
            self.allocator,
            self.api,
            raw_runtime,
            self,
            input,
        ) catch |err| {
            self.finishCatalogCall();
            return err;
        };

        self.sessions_mutex.lockUncancelable(self.io);
        std.debug.assert(self.active_catalog_calls > 0);
        self.active_catalog_calls -= 1;
        self.active_catalog_leases += 1;
        const reject = self.shutting_down.load(.acquire);
        self.shutdown_condition.broadcast(self.io);
        self.sessions_mutex.unlock(self.io);
        if (reject) {
            acquisition.projection.deinit();
            try self.releaseSkillCatalog(acquisition.lease);
            return error.RuntimeShuttingDown;
        }
        return acquisition;
    }

    /// Consumes one Host lease reference. Only its last release calls Core,
    /// exactly once even if that call reports failure.
    pub fn releaseSkillCatalog(
        self: *Runtime,
        lease: *CatalogLease,
    ) Error!void {
        if (!catalog.belongsTo(lease, self))
            return error.CatalogBindingMismatch;
        if (!catalog.releaseReference(lease)) return;
        self.sessions_mutex.lockUncancelable(self.io);
        if (self.runtime == null or self.active_catalog_leases == 0) {
            self.sessions_mutex.unlock(self.io);
            return error.CatalogBindingMismatch;
        }
        self.active_catalog_calls += 1;
        self.sessions_mutex.unlock(self.io);

        var release_error: ?Error = null;
        catalog.release(lease) catch |err| {
            release_error = err;
        };
        self.sessions_mutex.lockUncancelable(self.io);
        std.debug.assert(self.active_catalog_calls > 0);
        std.debug.assert(self.active_catalog_leases > 0);
        self.active_catalog_calls -= 1;
        self.active_catalog_leases -= 1;
        self.shutdown_condition.broadcast(self.io);
        self.sessions_mutex.unlock(self.io);
        if (release_error) |err| return err;
    }

    fn finishCatalogCall(self: *Runtime) void {
        self.sessions_mutex.lockUncancelable(self.io);
        std.debug.assert(self.active_catalog_calls > 0);
        self.active_catalog_calls -= 1;
        self.shutdown_condition.broadcast(self.io);
        self.sessions_mutex.unlock(self.io);
    }

    /// Refreshes and describes the immutable AgentCore MCP catalog in one
    /// serialized Runtime operation. Only the official SDK decoder sees the
    /// raw descriptor; callers receive the reduced MetaWork-owned projection.
    pub fn refreshMcpCatalog(
        self: *Runtime,
    ) (Error || std.mem.Allocator.Error)!*McpCatalogProjection {
        const projection = try self.performMcpRefresh(try self.beginMcpRefresh());
        self.completeMcpRefresh(mcp_catalog.projectionGeneration(projection)) catch |err| {
            projection.deinit();
            return err;
        };
        return projection;
    }

    /// Applies one complete MCP server set to the shared AgentCore Runtime.
    /// Errors before input.take leave it owned by the caller. Once taken,
    /// every outcome consumes it: applied transfers the candidate to Runtime;
    /// rejection/failure destroys it locally. Retired owners remain alive until
    /// Core references and active connections quiesce, or Runtime destruction.
    pub fn applyMcpConfiguration(
        self: *Runtime,
        input: *root.McpRuntimeInput,
    ) (Error || std.mem.Allocator.Error)!McpConfigurationApplyOutcome {
        var reaped: [max_mcp_configuration_applies]mcp_runtime.Servers = undefined;
        self.sessions_mutex.lockUncancelable(self.io);
        if (self.shutting_down.load(.acquire)) {
            self.sessions_mutex.unlock(self.io);
            return error.RuntimeShuttingDown;
        }
        if (self.mcp_operation.busy()) {
            self.sessions_mutex.unlock(self.io);
            return error.McpRefreshInProgress;
        }
        std.debug.assert(self.mcp_operation.begin(.apply));
        var reap_count: usize = 0;
        var retired_index: usize = 0;
        while (retired_index < self.retired_mcp_servers.items.len) {
            if (!self.retired_mcp_servers.items[retired_index].isQuiescent()) {
                retired_index += 1;
                continue;
            }
            reaped[reap_count] = self.retired_mcp_servers.swapRemove(retired_index);
            reap_count += 1;
        }
        self.sessions_mutex.unlock(self.io);
        for (reaped[0..reap_count]) |*servers| servers.deinit();

        self.sessions_mutex.lockUncancelable(self.io);
        if (self.shutting_down.load(.acquire) or self.runtime == null) {
            self.sessions_mutex.unlock(self.io);
            self.finishMcpCall(false);
            return error.RuntimeShuttingDown;
        }
        if (self.retired_mcp_servers.items.len >= max_mcp_configuration_applies or
            self.mcp_apply_revision == std.math.maxInt(u64))
        {
            self.sessions_mutex.unlock(self.io);
            self.finishMcpCall(false);
            return error.McpConfigurationApplyLimit;
        }
        self.retired_mcp_servers.ensureUnusedCapacity(self.allocator, 1) catch |err| {
            self.sessions_mutex.unlock(self.io);
            self.finishMcpCall(false);
            return err;
        };
        const raw_runtime = self.runtime orelse {
            self.sessions_mutex.unlock(self.io);
            self.finishMcpCall(false);
            return error.RuntimeShuttingDown;
        };
        const desired_revision = self.mcp_apply_revision + 1;
        const desired_generation = input.generation;
        self.sessions_mutex.unlock(self.io);

        var replacement = input.take() catch {
            self.finishMcpCall(false);
            return error.McpConfigurationApplyFailed;
        };
        var replacement_owned = true;
        defer if (replacement_owned) replacement.deinit();
        const configuration = replacement.configuration(desired_revision);
        var report = std.mem.zeroes(wire.McpApplyReportV1);
        report.struct_size = @sizeOf(wire.McpApplyReportV1);
        var diagnostic = emptyOwnedBytes();
        const status_code = self.api.mcp().applyConfiguration()(
            raw_runtime,
            &configuration,
            &report,
            &diagnostic,
        );
        releaseOwned(self.api, &diagnostic);
        const status = sdk.Status.fromCode(status_code) catch {
            self.finishMcpCall(false);
            return error.McpConfigurationApplyFailed;
        };
        const disposition: McpConfigurationApplyOutcome = if (status == .ok)
            switch (report.disposition_code) {
                wire.MCP_APPLY_APPLIED => .applied,
                wire.MCP_APPLY_SUPERSEDED => .superseded,
                wire.MCP_APPLY_REJECTED => .rejected,
                else => {
                    self.finishMcpCall(false);
                    return error.McpConfigurationApplyFailed;
                },
            }
        else {
            self.finishMcpCall(false);
            return switch (status) {
                .busy => error.McpRefreshInProgress,
                .resource_limit => error.McpConfigurationApplyLimit,
                else => error.McpConfigurationApplyFailed,
            };
        };
        if (report.struct_size != @sizeOf(wire.McpApplyReportV1) or
            report.desired_revision != desired_revision or
            !std.mem.allEqual(u64, &report.reserved, 0) or
            (disposition == .applied and report.active_revision != desired_revision))
        {
            self.finishMcpCall(false);
            return error.McpConfigurationApplyFailed;
        }

        self.sessions_mutex.lockUncancelable(self.io);
        std.debug.assert(self.mcp_operation.busy());
        if (disposition == .applied) {
            const previous = self.mcp_servers;
            self.mcp_servers = replacement;
            replacement_owned = false;
            self.retired_mcp_servers.appendAssumeCapacity(previous);
            self.mcp_registry_generation = desired_generation;
            self.mcp_apply_revision = desired_revision;
        }
        self.mcp_operation.completeApply();
        const reject = self.shutting_down.load(.acquire);
        self.shutdown_condition.broadcast(self.io);
        self.sessions_mutex.unlock(self.io);
        if (reject) return error.RuntimeShuttingDown;
        return disposition;
    }

    fn beginMcpRefresh(self: *Runtime) Error!McpRefreshLease {
        self.sessions_mutex.lockUncancelable(self.io);
        if (self.shutting_down.load(.acquire)) {
            self.sessions_mutex.unlock(self.io);
            return error.RuntimeShuttingDown;
        }
        if (self.mcp_operation.busy()) {
            self.sessions_mutex.unlock(self.io);
            return error.McpRefreshInProgress;
        }
        const raw_runtime = self.runtime orelse {
            self.sessions_mutex.unlock(self.io);
            return error.RuntimeShuttingDown;
        };
        const expected_servers = self.mcp_servers.expectedServers();
        // Transport refresh does not invalidate the published catalog. Retire
        // the previous handoff now; Product serializes and installs each job
        // before starting another. Core still validates the actual selectors.
        std.debug.assert(self.mcp_operation.begin(.refresh));
        self.sessions_mutex.unlock(self.io);
        return .{
            .raw_runtime = raw_runtime,
            .expected_servers = expected_servers,
            .registry_generation = self.mcp_registry_generation,
        };
    }

    fn performMcpRefresh(
        self: *Runtime,
        lease: McpRefreshLease,
    ) (Error || std.mem.Allocator.Error)!*McpCatalogProjection {
        const projection = mcp_catalog.refresh(
            self.io,
            self.allocator,
            self.api,
            lease.raw_runtime,
            self.mcp_owner_id,
            lease.expected_servers,
        ) catch |err| {
            self.finishMcpCall(err == error.RefreshRejected);
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return mapMcpCatalogError(err);
        };
        return projection;
    }

    fn completeMcpRefresh(self: *Runtime, generation: u64) Error!void {
        self.sessions_mutex.lockUncancelable(self.io);
        std.debug.assert(self.mcp_operation.busy());
        const reject = self.shutting_down.load(.acquire);
        if (!reject) self.mcp_operation.completeRefresh(generation) else self.mcp_operation.fail(false);
        self.shutdown_condition.broadcast(self.io);
        self.sessions_mutex.unlock(self.io);
        if (reject) return error.RuntimeShuttingDown;
    }

    /// Builds one complete catalog/allowlist authority generation. Expected
    /// post-Runtime MCP failures become an unavailable outcome; Runtime and
    /// ordinary Session creation remain usable with a null selection.
    pub fn activateMcp(
        self: *Runtime,
    ) (Error || std.mem.Allocator.Error)!McpActivationOutcome {
        const lease = try self.beginMcpRefresh();
        if (lease.expected_servers.len == 0) {
            self.finishMcpCall(false);
            return .empty;
        }
        const projection = self.performMcpRefresh(lease) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.RuntimeShuttingDown,
            error.McpRefreshInProgress,
            => return err,
            else => return .{ .unavailable = mcpActivationUnavailableReason(err) },
        };
        const durable_generation = lease.registry_generation orelse {
            projection.deinit();
            self.finishMcpCall(false);
            return error.McpCatalogBindingMismatch;
        };
        const activation = mcp_catalog.createActivation(
            self.allocator,
            durable_generation,
            self.mcp_owner_id,
            projection,
            lease.expected_servers,
        ) catch |err| {
            projection.deinit();
            self.finishMcpCall(false);
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => .{ .unavailable = mcpActivationUnavailableReason(
                    mapMcpCatalogError(err),
                ) },
            };
        };
        self.completeMcpRefresh(activation.catalogGeneration()) catch |err| {
            activation.deinit();
            return err;
        };
        return .{ .activated = activation };
    }

    pub fn createMcpSelection(
        self: *Runtime,
        projection: *const McpCatalogProjection,
        selectors: []const McpSelector,
    ) (Error || std.mem.Allocator.Error)!*McpSelection {
        self.sessions_mutex.lockUncancelable(self.io);
        defer self.sessions_mutex.unlock(self.io);
        if (self.shutting_down.load(.acquire))
            return error.RuntimeShuttingDown;
        if (self.mcp_operation.phase == .apply) return error.McpRefreshInProgress;
        if (!mcp_catalog.projectionBelongsTo(
            projection,
            self.mcp_owner_id,
        )) return error.McpCatalogBindingMismatch;
        if (!self.acceptsMcpGeneration(mcp_catalog.projectionGeneration(projection)))
            return error.StaleMcpSelection;
        return mcp_catalog.createSelection(
            self.allocator,
            self.mcp_owner_id,
            projection,
            selectors,
        ) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return mapMcpCatalogError(err);
        };
    }

    pub fn createMcpAdmissionSelection(
        self: *Runtime,
        activation: *const McpActivation,
        allowlists: []const McpServerAllowlist,
    ) (Error || std.mem.Allocator.Error)!?*McpSelection {
        self.sessions_mutex.lockUncancelable(self.io);
        defer self.sessions_mutex.unlock(self.io);
        if (self.shutting_down.load(.acquire))
            return error.RuntimeShuttingDown;
        if (self.mcp_operation.phase == .apply) return error.McpRefreshInProgress;
        if (!self.acceptsMcpGeneration(activation.catalogGeneration()))
            return error.StaleMcpSelection;
        return mcp_catalog.createSelectionForActivation(
            self.allocator,
            self.mcp_owner_id,
            activation,
            allowlists,
        ) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return mapMcpCatalogError(err);
        };
    }

    /// Replaces one idle Session's complete MCP authority view. Holding the
    /// Runtime mutex across the synchronous ABI call prevents a catalog
    /// refresh, shutdown, or Session release from changing the validated
    /// Runtime generation while AgentCore copies the selection.
    pub fn updateSessionMcpSelection(
        self: *Runtime,
        session: *Session,
        selection: ?*const McpSelection,
    ) (Error || std.mem.Allocator.Error)!void {
        self.sessions_mutex.lockUncancelable(self.io);
        defer self.sessions_mutex.unlock(self.io);
        if (self.shutting_down.load(.acquire))
            return error.RuntimeShuttingDown;
        if (self.mcp_operation.busy()) return error.McpRefreshInProgress;

        var found = false;
        for (self.sessions) |entry| if (entry == session) {
            found = true;
            break;
        };
        if (!found) return error.UnknownSession;
        if (selection) |value| {
            if (!mcp_catalog.belongsTo(value, self.mcp_owner_id))
                return error.McpCatalogBindingMismatch;
            if (self.mcp_operation.current_generation == null or
                mcp_catalog.selectionGeneration(value) != self.mcp_operation.current_generation.?)
                return error.StaleMcpSelection;
        }

        const restore_selection = try self.captureMcpRestoreSelectionLocked(selection);
        errdefer if (restore_selection) |saved| saved.deinit();
        session.lock();
        defer session.unlock();
        if (session.credential_updates_in_progress != 0) return error.SessionNotIdle;
        switch (session.state) {
            .idle => {},
            .queued, .running, .waiting_ui, .compact_queued, .compacting, .checkpointing => return error.SessionNotIdle,
            .poisoned => return error.SessionPoisoned,
            .closing, .closed => return error.SessionClosing,
        }
        std.debug.assert(session.run_done);
        std.debug.assert(session.compact_done);
        std.debug.assert(!session.core_call_in_progress);
        std.debug.assert(session.abort_calls_in_progress == 0);

        const raw_selection = mcp_catalog.rawSelectionReplacement(selection);
        var diagnostic = emptyOwnedBytes();
        const status_code = self.api.mcp().updateSelection()(
            session.raw,
            &raw_selection,
            &diagnostic,
        );
        releaseOwned(self.api, &diagnostic);
        const status = sdk.Status.fromCode(status_code) catch
            return session.failMcpUpdateContractLocked();
        const disposition = mcpUpdateStatusDisposition(status) orelse
            return session.failMcpUpdateContractLocked();
        if (disposition == .poisoned) {
            session.state = .poisoned;
            session.broadcast();
            return error.SessionPoisoned;
        }
        return switch (status) {
            .ok => {
                if (session.mcp_restore_selection) |saved| saved.deinit();
                session.mcp_restore_selection = restore_selection;
            },
            .busy => error.SessionNotIdle,
            .mcp_not_refreshed => error.McpNotRefreshed,
            .invalid_mcp_selection => error.InvalidMcpSelection,
            .checkpoint_budget_required => error.McpCheckpointBudgetRequired,
            .out_of_memory, .core_error, .resource_limit => error.McpSelectionUpdateFailed,
            else => unreachable,
        };
    }

    /// The caller holds sessions_mutex and has validated this live selection.
    fn captureMcpRestoreSelectionLocked(self: *Runtime, selection: ?*const McpSelection) (Error || std.mem.Allocator.Error)!?*root.McpRestoreSelection {
        return if (selection) |value| mcp_catalog.captureRestoreSelection(self.allocator, self.mcp_owner_id, value, self.mcp_servers.expectedServers()) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return mapMcpCatalogError(err);
        } else null;
    }

    /// The Host supplies its current admission ceiling. A ready Core
    /// catalog alone does not prove that a connection or tool is still granted.
    pub fn prepareMcpRestoreSelection(self: *Runtime, original: *const root.McpRestoreSelection, activation: *const McpActivation, ceiling: []const root.McpActivationTool) (Error || std.mem.Allocator.Error)!*McpSelection {
        self.sessions_mutex.lockUncancelable(self.io);
        defer self.sessions_mutex.unlock(self.io);
        if (self.shutting_down.load(.acquire)) return error.RuntimeShuttingDown;
        if (self.mcp_operation.phase == .apply) return error.McpRefreshInProgress;
        if (!self.acceptsMcpGeneration(activation.catalogGeneration())) return error.StaleMcpSelection;
        return mcp_catalog.restoreSelectionForActivation(self.allocator, self.mcp_owner_id, original, activation, self.mcp_servers.expectedServers(), ceiling) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return mapMcpCatalogError(err);
        };
    }

    fn finishMcpCall(self: *Runtime, keep_catalog: bool) void {
        self.sessions_mutex.lockUncancelable(self.io);
        std.debug.assert(self.mcp_operation.busy());
        // Only a typed pre-publication rejection preserves the current catalog.
        self.mcp_operation.fail(keep_catalog);
        self.shutdown_condition.broadcast(self.io);
        self.sessions_mutex.unlock(self.io);
    }

    pub fn createSession(
        self: *Runtime,
        options: SessionOpenOptions,
    ) (Error || std.mem.Allocator.Error)!*Session {
        return (try self.createSessionRoute(options)).session;
    }

    /// Lightweight recovery observation, not a reservation. A rebind may
    /// release its own still-owned route before restoring. Actual restore
    /// revalidates capacity under this mutex after that release.
    pub const RestoreAdmission = enum { available, capacity_reached, mcp_busy, unavailable };

    pub fn restoreAdmission(self: *Runtime, releasing_route_id: ?u64) RestoreAdmission {
        self.sessions_mutex.lockUncancelable(self.io);
        defer self.sessions_mutex.unlock(self.io);
        if (self.shutting_down.load(.acquire) or self.runtime == null) return .unavailable;
        if (self.mcp_operation.phase == .apply) return .mcp_busy;
        if (releasing_route_id) |route_id| {
            if (route_id == 0) return .unavailable;
            for (self.sessions) |entry| if (entry) |session|
                if (session.id == route_id) return .available;
            return .unavailable;
        }
        for (self.sessions, self.session_reservations) |entry, reserved|
            if (entry == null and !reserved) return .available;
        return .capacity_reached;
    }

    /// Caller holds sessions_mutex. Only the published generation and the
    /// single in-progress publication handoff belong to this config epoch.
    fn acceptsMcpGeneration(self: *const Runtime, generation: u64) bool {
        return self.mcp_operation.accepts(generation);
    }

    /// Creates one Agent Session and returns its canonical routing identity in
    /// the same operation. The identity must not be reconstructed from a live
    /// Session snapshot.
    pub fn createSessionRoute(
        self: *Runtime,
        options: SessionOpenOptions,
    ) (Error || std.mem.Allocator.Error)!SessionRoute {
        const binding = options.model_binding;
        try validateWorkspace(options.workspace);
        model_binding.validate(binding, .optional_sdk_default) catch
            return error.CoreCallFailed;
        if (options.canonical_user_home.len != 0)
            try validateCanonicalDirectory(
                self.io,
                self.allocator,
                options.canonical_user_home,
            );
        if (options.skill_catalog) |lease| {
            if (!catalog.belongsTo(lease, self) or
                !catalog.matchesSession(
                    lease,
                    options.workspace.canonical_root,
                    options.canonical_user_home,
                    options.workspace_epoch,
                ))
                return error.CatalogBindingMismatch;
        }
        if ((options.skill_catalog == null) != (options.skill_policy == null))
            return error.InvalidSkillPolicy;
        const skill_policy_views = try self.allocator.alloc(
            wire.BytesViewV1,
            if (options.skill_policy) |policy|
                policy.granted_skill_ids.len
            else
                0,
        );
        defer self.allocator.free(skill_policy_views);
        const skill_policy = if (options.skill_policy) |policy|
            session_wire.skillPolicy(
                policy.granted_skill_ids,
                skill_policy_views,
            ) catch return error.InvalidSkillPolicy
        else
            undefined;
        const skill_restore_inputs = if (options.skill_catalog) |lease|
            try root.SkillRestoreInputs.init(self, lease, options.skill_policy.?)
        else
            null;
        // The caller still owns its synchronous borrow, so this reference
        // cannot be the last one on a failed create.
        errdefer if (skill_restore_inputs) |inputs| inputs.deinit() catch unreachable;

        self.sessions_mutex.lockUncancelable(self.io);
        defer self.sessions_mutex.unlock(self.io);
        if (self.shutting_down.load(.acquire)) return error.RuntimeShuttingDown;
        // Apply can change the configuration epoch. A pure catalog refresh
        // preserves the published authority; Core checks actual availability.
        if (self.mcp_operation.phase == .apply and options.mcp_selection != null)
            return error.McpRefreshInProgress;
        if (options.mcp_selection) |selection| {
            if (!mcp_catalog.belongsTo(selection, self.mcp_owner_id))
                return error.McpCatalogBindingMismatch;
            if (!self.acceptsMcpGeneration(mcp_catalog.selectionGeneration(selection)))
                return error.StaleMcpSelection;
        }
        const mcp_restore_selection = try self.captureMcpRestoreSelectionLocked(options.mcp_selection);
        errdefer if (mcp_restore_selection) |saved| saved.deinit();
        var slot: ?usize = null;
        for (self.sessions, self.session_reservations, 0..) |entry, reserved, index| {
            if (entry == null and !reserved) {
                slot = index;
                break;
            }
        }
        const session_slot = slot orelse return error.SessionCapacity;
        if (self.next_session_id == std.math.maxInt(u64)) return error.SessionIdExhausted;
        self.next_session_id += 1;
        const session_id = self.next_session_id;

        const session = try self.allocator.create(Session);
        errdefer self.allocator.destroy(session);
        const control_block = try self.allocator.create(SessionControlBlock);
        errdefer self.allocator.destroy(control_block);
        const provider_id = try self.allocator.dupe(u8, binding.target.provider_id);
        errdefer self.allocator.free(provider_id);
        const workspace_root = try self.allocator.dupe(u8, options.workspace.canonical_root);
        errdefer self.allocator.free(workspace_root);
        const workspace_home = try self.allocator.dupe(
            u8,
            options.canonical_user_home,
        );
        errdefer self.allocator.free(workspace_home);
        const workspace_epoch = try self.allocator.dupe(
            u8,
            options.workspace_epoch,
        );
        errdefer self.allocator.free(workspace_epoch);
        session.* = .{
            .agent_runtime = self,
            .id = session_id,
            .provider_id = provider_id,
            .protocol = binding.target.protocol,
            .workspace_root = workspace_root,
            .workspace_home = workspace_home,
            .workspace_epoch = workspace_epoch,
            .permission_interaction = options.permission_interaction,
            .shell_policy = options.shell_policy,
            .skill_restore_inputs = skill_restore_inputs,
            .mcp_restore_selection = mcp_restore_selection,
            .control_block = control_block,
            .next_run_id = options.operation_id_floor.last_run_id,
            .next_compact_id = options.operation_id_floor.last_compact_id,
            .ui_request_id = options.operation_id_floor.last_ui_request_id,
        };
        control_block.* = .{ .session = session };

        const secret = try self.allocator.dupe(u8, binding.credential);
        defer {
            secureZero(secret);
            self.allocator.free(secret);
        }
        var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
        callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
        callbacks.ctx = session;
        callbacks.on_event = Session.onEvent;
        callbacks.on_ui_request = Session.onUiRequest;
        callbacks.release_response = Session.releaseUiResponse;
        var host_config = std.mem.zeroes(wire.SessionHostConfigV1);
        host_config.struct_size = @sizeOf(wire.SessionHostConfigV1);
        var model_capabilities: [wire.MAX_MODEL_CAPABILITIES_V1]wire.ModelCapabilityV1 = undefined;
        configureImageCapabilities(&host_config, binding.image_capabilities, &model_capabilities);
        host_config.protocol_kind_code = session_wire.protocolKindCode(binding.target.protocol);
        host_config.provider_kind_code = providerKindCode(binding.target.protocol);
        host_config.permission_mode_code = permissionModeCode(options.permission_mode);
        host_config.shell_policy_code = shellPolicyCode(options.shell_policy);
        host_config.api_key = sdk.bytesView(secret);
        host_config.base_url = sdk.bytesView(binding.target.base_url);
        host_config.workspace_root = sdk.bytesView(workspace_root);
        host_config.workspace_home = sdk.bytesView(workspace_home);
        host_config.skill_catalog = if (options.skill_catalog) |lease|
            catalog.rawHandle(lease)
        else
            null;
        host_config.skill_policy = if (options.skill_policy != null)
            &skill_policy
        else
            null;
        host_config.permission_rules = null;
        const raw_mcp_selection = if (options.mcp_selection != null)
            mcp_catalog.rawSelectionReplacement(options.mcp_selection)
        else
            undefined;
        host_config.mcp_selection = if (options.mcp_selection != null)
            &raw_mcp_selection
        else
            null;
        host_config.durable_budget = null;
        // MetaWork persists finalized Conversation checkpoints. AgentCore's
        // active-Run journal remains disabled until a crash-recovery policy is
        // defined for its intent/result evidence.
        host_config.run_journal_mode_code = wire.RUN_JOURNAL_EPHEMERAL;
        const allowed_views = try self.allocator.alloc(wire.BytesViewV1, capabilities.builtins.len + 2);
        defer self.allocator.free(allowed_views);
        for (capabilities.builtins, 0..) |builtin, index|
            allowed_views[index] = sdk.bytesView(capabilities.wireName(builtin));
        allowed_views[capabilities.builtins.len] = sdk.bytesView(image_tool.name);
        allowed_views[capabilities.builtins.len + 1] = sdk.bytesView(delivery_tool.name);
        host_config.allowed_tools = if (allowed_views.len == 0) null else allowed_views.ptr;
        host_config.allowed_tool_count = allowed_views.len;
        var config = std.mem.zeroes(wire.SessionCreateConfigV1);
        config.struct_size = @sizeOf(wire.SessionCreateConfigV1);
        config.host = &host_config;
        config.model = sdk.bytesView(binding.target.model);
        config.prompt_profile = &identity_profile.profile;

        var diagnostic = emptyOwnedBytes();
        var raw_session: ?*wire.SessionHandle = null;
        const status = self.api.session().create()(
            self.runtime,
            &config,
            &callbacks,
            &raw_session,
            &diagnostic,
        );
        defer releaseOwned(self.api, &diagnostic);
        const typed_status = sdk.Status.fromCode(status) catch return error.CoreCallFailed;
        if (typed_status != .ok) {
            // AgentCore must not return a live handle for a rejected create.
            // Preserve MCP authority rejection only for a well-formed failure,
            // so ordinary Task creation can continue without that selection.
            if (raw_session != null) return error.CoreCallFailed;
            return switch (typed_status) {
                .mcp_not_refreshed => error.McpNotRefreshed,
                .invalid_mcp_selection => error.InvalidMcpSelection,
                else => error.CoreCallFailed,
            };
        }
        if (raw_session == null) return error.CoreCallFailed;
        session.raw = raw_session;
        self.sessions[session_slot] = session;
        return .{ .id = session_id, .session = session };
    }

    /// Restores one Session without holding `sessions_mutex` across the
    /// streaming AgentCore call. The reservation and in-flight fence keep the
    /// route slot and Runtime handle valid until the candidate is either
    /// installed or destroyed.
    pub fn restoreSessionRoute(
        self: *Runtime,
        options: SessionRestoreOptions,
    ) (Error || std.mem.Allocator.Error)!SessionRestoreRoute {
        const session_options = options.session;
        const binding = session_options.model_binding;
        try validateWorkspace(session_options.workspace);
        try checkpoint.validateLimits(options.checkpoint_limits);
        model_binding.validate(binding, .optional_sdk_default) catch
            return error.CoreCallFailed;
        if (!std.mem.eql(u8, binding.target.model, options.expectation.model) or
            options.expectation.logical_session_id.len == 0 or
            options.expectation.logical_session_id.len > max_core_session_id_bytes or
            options.expectation.checkpoint_generation == 0 or
            session_options.operation_id_floor.last_run_id < options.expectation.last_run_id or
            session_options.operation_id_floor.last_compact_id < options.expectation.last_compact_id)
            return error.RestoreInvalid;
        if (session_options.canonical_user_home.len != 0)
            try validateCanonicalDirectory(
                self.io,
                self.allocator,
                session_options.canonical_user_home,
            );
        if (session_options.skill_catalog) |lease| {
            if (!catalog.belongsTo(lease, self) or
                !catalog.matchesSession(
                    lease,
                    session_options.workspace.canonical_root,
                    session_options.canonical_user_home,
                    session_options.workspace_epoch,
                ))
                return error.CatalogBindingMismatch;
        }
        if ((session_options.skill_catalog == null) !=
            (session_options.skill_policy == null))
            return error.InvalidSkillPolicy;
        const skill_policy_views = try self.allocator.alloc(
            wire.BytesViewV1,
            if (session_options.skill_policy) |policy|
                policy.granted_skill_ids.len
            else
                0,
        );
        defer self.allocator.free(skill_policy_views);
        const skill_policy = if (session_options.skill_policy) |policy|
            session_wire.skillPolicy(
                policy.granted_skill_ids,
                skill_policy_views,
            ) catch return error.InvalidSkillPolicy
        else
            undefined;

        const session = try self.allocator.create(Session);
        var session_installed = false;
        defer if (!session_installed) self.allocator.destroy(session);
        const skill_restore_inputs = if (session_options.skill_catalog) |lease|
            try root.SkillRestoreInputs.init(self, lease, session_options.skill_policy.?)
        else
            null;
        defer if (!session_installed) if (skill_restore_inputs) |inputs| inputs.deinit() catch unreachable;
        const provider_id = try self.allocator.dupe(u8, binding.target.provider_id);
        defer if (!session_installed) self.allocator.free(provider_id);
        const control_block = try self.allocator.create(SessionControlBlock);
        var control_installed = false;
        defer if (!control_installed) self.allocator.destroy(control_block);
        const workspace_root = try self.allocator.dupe(
            u8,
            session_options.workspace.canonical_root,
        );
        var workspace_root_installed = false;
        defer if (!workspace_root_installed) self.allocator.free(workspace_root);
        const workspace_home = try self.allocator.dupe(
            u8,
            session_options.canonical_user_home,
        );
        var workspace_home_installed = false;
        defer if (!workspace_home_installed) self.allocator.free(workspace_home);
        const workspace_epoch = try self.allocator.dupe(
            u8,
            session_options.workspace_epoch,
        );
        var workspace_epoch_installed = false;
        defer if (!workspace_epoch_installed) self.allocator.free(workspace_epoch);
        const secret = try self.allocator.dupe(u8, binding.credential);
        defer {
            secureZero(secret);
            self.allocator.free(secret);
        }
        const allowed_views = try self.allocator.alloc(
            wire.BytesViewV1,
            capabilities.builtins.len + 2,
        );
        defer self.allocator.free(allowed_views);
        for (capabilities.builtins, 0..) |builtin, index|
            allowed_views[index] = sdk.bytesView(capabilities.wireName(builtin));
        allowed_views[capabilities.builtins.len] = sdk.bytesView(image_tool.name);
        allowed_views[capabilities.builtins.len + 1] = sdk.bytesView(delivery_tool.name);

        self.sessions_mutex.lockUncancelable(self.io);
        if (self.shutting_down.load(.acquire)) {
            self.sessions_mutex.unlock(self.io);
            return error.RuntimeShuttingDown;
        }
        const raw_runtime = self.runtime orelse {
            self.sessions_mutex.unlock(self.io);
            return error.RuntimeShuttingDown;
        };
        if (self.mcp_operation.phase == .apply) {
            self.sessions_mutex.unlock(self.io);
            return error.McpRefreshInProgress;
        }
        if (session_options.mcp_selection) |selection| {
            if (!mcp_catalog.belongsTo(selection, self.mcp_owner_id)) {
                self.sessions_mutex.unlock(self.io);
                return error.McpCatalogBindingMismatch;
            }
            if (!self.acceptsMcpGeneration(mcp_catalog.selectionGeneration(selection))) {
                self.sessions_mutex.unlock(self.io);
                return error.StaleMcpSelection;
            }
        }
        const mcp_restore_selection = self.captureMcpRestoreSelectionLocked(session_options.mcp_selection) catch |err| {
            self.sessions_mutex.unlock(self.io);
            return err;
        };
        defer if (!session_installed) if (mcp_restore_selection) |saved| saved.deinit();
        var slot: ?usize = null;
        for (self.sessions, self.session_reservations, 0..) |entry, reserved, index| {
            if (entry == null and !reserved) {
                slot = index;
                break;
            }
        }
        const session_slot = slot orelse {
            self.sessions_mutex.unlock(self.io);
            return error.SessionCapacity;
        };
        if (self.next_session_id == std.math.maxInt(u64)) {
            self.sessions_mutex.unlock(self.io);
            return error.SessionIdExhausted;
        }
        self.next_session_id += 1;
        const route_id = self.next_session_id;
        self.session_reservations[session_slot] = true;
        self.active_restore_calls += 1;
        self.sessions_mutex.unlock(self.io);

        var identity = CoreSessionIdentity{ .bound = .{
            .len = options.expectation.logical_session_id.len,
            .bytes = [_]u8{0} ** max_core_session_id_bytes,
        } };
        @memcpy(
            identity.bound.bytes[0..options.expectation.logical_session_id.len],
            options.expectation.logical_session_id,
        );
        session.* = .{
            .agent_runtime = self,
            .id = route_id,
            .provider_id = provider_id,
            .protocol = binding.target.protocol,
            .workspace_root = workspace_root,
            .workspace_home = workspace_home,
            .workspace_epoch = workspace_epoch,
            .permission_interaction = session_options.permission_interaction,
            .shell_policy = session_options.shell_policy,
            .skill_restore_inputs = skill_restore_inputs,
            .mcp_restore_selection = mcp_restore_selection,
            .control_block = control_block,
            .next_run_id = session_options.operation_id_floor.last_run_id,
            .next_compact_id = session_options.operation_id_floor.last_compact_id,
            .ui_request_id = session_options.operation_id_floor.last_ui_request_id,
            .core_session_identity = identity,
        };
        control_block.* = .{ .session = session };

        var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
        callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
        callbacks.ctx = session;
        callbacks.on_event = Session.onEvent;
        callbacks.on_ui_request = Session.onUiRequest;
        callbacks.release_response = Session.releaseUiResponse;
        var host_config = std.mem.zeroes(wire.SessionHostConfigV1);
        host_config.struct_size = @sizeOf(wire.SessionHostConfigV1);
        var model_capabilities: [wire.MAX_MODEL_CAPABILITIES_V1]wire.ModelCapabilityV1 = undefined;
        configureImageCapabilities(&host_config, binding.image_capabilities, &model_capabilities);
        host_config.protocol_kind_code = session_wire.protocolKindCode(binding.target.protocol);
        host_config.provider_kind_code = providerKindCode(binding.target.protocol);
        host_config.permission_mode_code = permissionModeCode(session_options.permission_mode);
        host_config.shell_policy_code = shellPolicyCode(session_options.shell_policy);
        host_config.api_key = sdk.bytesView(secret);
        host_config.base_url = sdk.bytesView(binding.target.base_url);
        host_config.workspace_root = sdk.bytesView(workspace_root);
        host_config.workspace_home = sdk.bytesView(workspace_home);
        host_config.skill_catalog = if (session_options.skill_catalog) |lease|
            catalog.rawHandle(lease)
        else
            null;
        host_config.skill_policy = if (session_options.skill_policy != null)
            &skill_policy
        else
            null;
        host_config.permission_rules = null;
        const raw_mcp_selection = if (session_options.mcp_selection != null)
            mcp_catalog.rawSelectionReplacement(session_options.mcp_selection)
        else
            undefined;
        host_config.mcp_selection = if (session_options.mcp_selection != null)
            &raw_mcp_selection
        else
            null;
        host_config.durable_budget = null;
        host_config.run_journal_mode_code = wire.RUN_JOURNAL_EPHEMERAL;
        host_config.allowed_tools = if (allowed_views.len == 0) null else allowed_views.ptr;
        host_config.allowed_tool_count = allowed_views.len;

        const outcome = checkpoint_restore.restore(
            self.allocator,
            self.api,
            raw_runtime,
            &host_config,
            &callbacks,
            options.checkpoint_limits,
            options.source,
            options.expectation,
        );
        switch (outcome) {
            .failure => |failure| {
                if (failure.retained_candidate) |candidate| {
                    self.retainFailedRestoreCandidate(session_slot, session, candidate);
                    session_installed = true;
                    control_installed = true;
                    workspace_root_installed = true;
                    workspace_home_installed = true;
                    workspace_epoch_installed = true;
                } else {
                    self.finishRestoreReservation(session_slot);
                }
                return mapRestoreFailure(failure);
            },
            .success => {},
        }
        var success = outcome.success;
        var metadata_live = true;
        defer if (metadata_live) success.deinitMetadata();

        // Updating identity is part of restore admission. Keep the candidate
        // unpublished and the Runtime fenced until mutation and cleanup finish.
        const identity_error: ?Error = blk: {
            identity_profile.apply(self.api, success.raw_session) catch |err|
                break :blk err;
            break :blk null;
        };
        self.sessions_mutex.lockUncancelable(self.io);
        std.debug.assert(self.active_restore_calls > 0);
        std.debug.assert(self.session_reservations[session_slot]);
        std.debug.assert(self.sessions[session_slot] == null);
        const reject = identity_error != null or self.shutting_down.load(.acquire) or self.runtime != raw_runtime;
        if (!reject) {
            session.raw = success.raw_session;
            self.sessions[session_slot] = session;
            self.session_reservations[session_slot] = false;
            self.active_restore_calls -= 1;
            self.shutdown_condition.broadcast(self.io);
            self.sessions_mutex.unlock(self.io);
            const report = success.report;
            success.deinitMetadata();
            metadata_live = false;
            session_installed = true;
            control_installed = true;
            workspace_root_installed = true;
            workspace_home_installed = true;
            workspace_epoch_installed = true;
            return .{ .id = route_id, .session = session, .report = report };
        }
        self.sessions_mutex.unlock(self.io);

        const destroyed = checkpoint_restore.destroyCandidate(self.api, success.raw_session);
        if (!destroyed) {
            // A non-OK destroy status keeps the handle valid. Install the
            // poisoned candidate so Runtime.shutdown owns the final retry.
            self.retainFailedRestoreCandidate(session_slot, session, success.raw_session);
            session_installed = true;
            control_installed = true;
            workspace_root_installed = true;
            workspace_home_installed = true;
            workspace_epoch_installed = true;
        } else {
            self.finishRestoreReservation(session_slot);
        }
        if (!destroyed) return error.RestoreContractFailed;
        return identity_error orelse error.RuntimeShuttingDown;
    }

    fn retainFailedRestoreCandidate(
        self: *Runtime,
        session_slot: usize,
        session: *Session,
        candidate: *wire.SessionHandle,
    ) void {
        self.sessions_mutex.lockUncancelable(self.io);
        std.debug.assert(self.active_restore_calls > 0);
        std.debug.assert(self.session_reservations[session_slot]);
        std.debug.assert(self.sessions[session_slot] == null);
        session.raw = candidate;
        session.state = .poisoned;
        self.sessions[session_slot] = session;
        self.session_reservations[session_slot] = false;
        self.active_restore_calls -= 1;
        self.shutdown_condition.broadcast(self.io);
        self.sessions_mutex.unlock(self.io);
    }

    fn finishRestoreReservation(self: *Runtime, session_slot: usize) void {
        self.sessions_mutex.lockUncancelable(self.io);
        std.debug.assert(self.active_restore_calls > 0);
        std.debug.assert(self.session_reservations[session_slot]);
        std.debug.assert(self.sessions[session_slot] == null);
        self.session_reservations[session_slot] = false;
        self.active_restore_calls -= 1;
        self.shutdown_condition.broadcast(self.io);
        self.sessions_mutex.unlock(self.io);
    }

    pub fn shutdown(self: *Runtime) Error!void {
        self.sessions_mutex.lockUncancelable(self.io);
        var waited = false;
        while (self.shutdown_running) {
            waited = true;
            self.shutdown_condition.waitUncancelable(self.io, &self.sessions_mutex);
        }
        if (self.shutdown_complete) {
            self.sessions_mutex.unlock(self.io);
            return;
        }
        if (waited) {
            const prior_error = self.last_shutdown_error;
            self.sessions_mutex.unlock(self.io);
            if (prior_error) |err| return err;
            return;
        }
        self.shutdown_running = true;
        self.last_shutdown_error = null;
        self.shutting_down.store(true, .release);
        while (self.active_catalog_calls != 0 or self.mcp_operation.busy() or
            self.active_restore_calls != 0)
            self.shutdown_condition.waitUncancelable(
                self.io,
                &self.sessions_mutex,
            );
        const sessions = self.sessions;
        self.sessions_mutex.unlock(self.io);

        var first_error: ?Error = null;
        for (sessions) |entry| {
            if (entry) |session| {
                session.close(.app_shutdown) catch |err| if (first_error == null) {
                    first_error = err;
                };
            }
        }
        if (first_error != null) return self.finishShutdown(first_error);

        self.sessions_mutex.lockUncancelable(self.io);
        const outstanding_catalogs = self.active_catalog_leases;
        self.sessions_mutex.unlock(self.io);
        if (outstanding_catalogs != 0)
            return self.finishShutdown(error.CatalogLeasesOutstanding);

        if (self.runtime != null) {
            var diagnostic = emptyOwnedBytes();
            const status = self.api.runtime().destroy()(self.runtime, &diagnostic);
            releaseOwned(self.api, &diagnostic);
            const typed_status = sdk.Status.fromCode(status) catch null;
            if (typed_status == .ok) {
                self.runtime = null;
            } else {
                first_error = error.RuntimeDestroyFailed;
            }
        }

        return self.finishShutdown(first_error);
    }

    pub fn releaseClosedSession(self: *Runtime, session: *Session) Error!void {
        // Successful release transfers the last owner reference to Runtime and
        // invalidates `session`; callers must quiesce their own references.
        self.sessions_mutex.lockUncancelable(self.io);
        defer self.sessions_mutex.unlock(self.io);
        if (self.shutting_down.load(.acquire)) return error.RuntimeShuttingDown;

        var slot: ?usize = null;
        for (self.sessions, 0..) |entry, index| {
            if (entry == session) {
                slot = index;
                break;
            }
        }
        const session_slot = slot orelse return error.UnknownSession;
        session.lock();
        if (session.state != .closed) {
            session.unlock();
            return error.SessionNotClosed;
        }
        std.debug.assert(session.active_refs == 0);
        session.unlock();

        self.sessions[session_slot] = null;
        session.deinit();
        self.allocator.destroy(session);
    }

    pub fn takeEvent(self: *Runtime) ?OwnedCoreEvent {
        return self.events.takeFair();
    }

    pub fn notifyEventConsumer(self: *Runtime) EventReadyNotification {
        const notifier = self.event_ready_notifier orelse return .scheduled;
        return notifier.notifyWithRetry(
            self.io,
            self.event_ready_retry_interval,
            self.event_ready_timeout,
        );
    }

    pub fn requestWake(self: *Runtime) bool {
        return self.notifyEventConsumer() != .unavailable;
    }

    pub fn requestRunTermination(
        self: *Runtime,
        session_id: u64,
        run_id: u64,
        signal: TerminationSignal,
    ) Error!void {
        self.sessions_mutex.lockUncancelable(self.io);
        var retained: ?*Session = null;
        var found = false;
        for (self.sessions) |entry| {
            const session = entry orelse continue;
            if (session.id != session_id) continue;
            found = true;
            if (session.retainReference()) retained = session;
            break;
        }
        self.sessions_mutex.unlock(self.io);
        const session = retained orelse return if (found) error.SessionClosing else error.UnknownSession;
        defer session.releaseReference();
        return session.requestTermination(run_id, signal);
    }

    fn finishShutdown(self: *Runtime, result: ?Error) Error!void {
        self.sessions_mutex.lockUncancelable(self.io);
        self.shutdown_running = false;
        self.shutdown_complete = result == null;
        self.last_shutdown_error = result;
        self.shutdown_condition.broadcast(self.io);
        self.sessions_mutex.unlock(self.io);
        if (result) |err| return err;
    }

    pub fn deinit(self: *Runtime) void {
        std.debug.assert(self.shutdown_complete);
        std.debug.assert(self.active_catalog_calls == 0);
        std.debug.assert(self.active_catalog_leases == 0);
        std.debug.assert(!self.mcp_operation.busy());
        std.debug.assert(self.active_restore_calls == 0);
        for (self.session_reservations) |reserved| std.debug.assert(!reserved);
        for (self.sessions) |entry| {
            if (entry) |session| {
                session.deinit();
                self.allocator.destroy(session);
            }
        }
        std.debug.assert(self.multimodal_input_budget.used.load(.monotonic) == 0);
        std.debug.assert(self.image_budget.used.load(.acquire) == 0);
        std.debug.assert(self.image_results_created.load(.acquire) == self.image_results_released.load(.acquire));
        std.debug.assert(self.delivery_results_outstanding.load(.acquire) == 0);
        self.events.deinit();
        self.mcp_servers.deinit();
        for (self.retired_mcp_servers.items) |*servers| servers.deinit();
        self.retired_mcp_servers.deinit(self.allocator);
        self.allocator.free(self.session_reservations);
        self.allocator.free(self.sessions);
        const allocator = self.allocator;
        allocator.destroy(self);
    }
};

fn validateWorkspace(input: WorkspaceInput) Error!void {
    if (!isCanonicalAbsolutePath(input.canonical_root)) return error.InvalidWorkspace;
    switch (input.trust) {
        .explicitly_trusted => {},
        .temporary => |canonical_temp_root| {
            if (!isCanonicalAbsolutePath(canonical_temp_root) or
                !pathWithin(canonical_temp_root, input.canonical_root))
                return error.WorkspaceNotTrusted;
        },
    }
}

fn validateCanonicalDirectory(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
) Error!void {
    if (!isCanonicalAbsolutePath(path) or
        !std.unicode.utf8ValidateSlice(path))
        return error.InvalidCatalogQuery;
    const canonical = std.Io.Dir.realPathFileAbsoluteAlloc(
        io,
        path,
        allocator,
    ) catch return error.InvalidCatalogQuery;
    defer allocator.free(canonical);
    if (!std.mem.eql(u8, canonical, path))
        return error.InvalidCatalogQuery;
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch
        return error.InvalidCatalogQuery;
    if (stat.kind != .directory) return error.InvalidCatalogQuery;
}

fn isCanonicalAbsolutePath(path: []const u8) bool {
    if (!std.fs.path.isAbsolute(path)) return false;
    if (path.len == 1) return path[0] == std.fs.path.sep;
    if (path.len > 1 and path[path.len - 1] == std.fs.path.sep) return false;
    var components = std.mem.splitScalar(u8, path[1..], std.fs.path.sep);
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or
            std.mem.eql(u8, component, "..")) return false;
    }
    return true;
}

fn pathWithin(parent: []const u8, child: []const u8) bool {
    if (std.mem.eql(u8, parent, child)) return true;
    if (!std.mem.startsWith(u8, child, parent)) return false;
    if (parent.len == 1 and parent[0] == std.fs.path.sep) return true;
    return child.len > parent.len and child[parent.len] == std.fs.path.sep;
}

fn mapRestoreFailure(failure: checkpoint_restore.Failure) Error {
    return switch (failure.reason) {
        .invalid_argument => error.RestoreInvalid,
        .busy => error.RestoreBusy,
        .checkpoint_corrupt => error.CheckpointCorrupt,
        .checkpoint_unsupported => error.CheckpointUnsupported,
        .checkpoint_incompatible => error.CheckpointIncompatible,
        .logical_session_conflict => error.LogicalSessionConflict,
        .mcp_not_refreshed => error.McpNotRefreshed,
        .cancelled => error.RestoreCancelled,
        .io_failed => error.RestoreIoFailed,
        .dependency_contract => error.RestoreContractFailed,
        .out_of_memory,
        .resource_limit,
        .core_error,
        .invalid_state,
        .host_out_of_memory,
        => error.RestoreFailed,
    };
}

test "restore preserves typed MCP freshness rejection" {
    try std.testing.expectEqual(
        error.McpNotRefreshed,
        mapRestoreFailure(.{
            .stage = .restore,
            .reason = .mcp_not_refreshed,
        }),
    );
}

fn mapMcpCatalogError(err: anyerror) Error {
    return switch (err) {
        error.RefreshFailed, error.DescribeFailed => error.McpRefreshFailed,
        error.RefreshRejected => error.McpRefreshRejected,
        error.InvalidCatalogDescriptor => error.InvalidMcpCatalogDescriptor,
        error.CatalogResourceLimit => error.McpCatalogResourceLimit,
        error.CatalogGenerationMismatch => error.McpCatalogGenerationMismatch,
        error.CatalogBindingMismatch => error.McpCatalogBindingMismatch,
        error.DuplicateCatalogIdentity => error.InvalidMcpCatalogDescriptor,
        error.InvalidSelection => error.InvalidMcpSelection,
        error.StaleSelection => error.StaleMcpSelection,
        error.RestoreSourceChanged => error.McpRestoreSourceChanged,
        else => error.McpRefreshFailed,
    };
}

fn mcpActivationUnavailableReason(err: anyerror) McpActivationUnavailableReason {
    return switch (err) {
        error.McpRefreshFailed => .refresh_failed,
        error.McpRefreshRejected => .refresh_rejected,
        error.InvalidMcpCatalogDescriptor => .invalid_catalog,
        error.McpCatalogResourceLimit => .resource_limit,
        error.McpCatalogGenerationMismatch => .generation_mismatch,
        error.McpCatalogBindingMismatch => .binding_mismatch,
        error.InvalidMcpSelection, error.StaleMcpSelection => .invalid_selection,
        else => .refresh_failed,
    };
}

fn allocateMcpOwnerId() Error!u64 {
    var current = next_mcp_owner_id.load(.acquire);
    while (current != std.math.maxInt(u64)) {
        if (next_mcp_owner_id.cmpxchgWeak(
            current,
            current + 1,
            .acq_rel,
            .acquire,
        )) |observed| {
            current = observed;
        } else return current;
    }
    return error.McpRuntimeIdentityExhausted;
}

fn secureZero(bytes: []u8) void {
    std.crypto.secureZero(u8, bytes);
}

fn emptyOwnedBytes() wire.OwnedBytesV1 {
    return .{ .ptr = null, .len = 0 };
}

/// Both ABI entry points borrow this table only until their synchronous return.
fn configureImageCapabilities(host: *wire.SessionHostConfigV1, entries: []const model_binding.ModelImageCapability, storage: *[wire.MAX_MODEL_CAPABILITIES_V1]wire.ModelCapabilityV1) void {
    for (entries, 0..) |entry, index| {
        storage[index] = std.mem.zeroes(wire.ModelCapabilityV1);
        storage[index].struct_size = @sizeOf(wire.ModelCapabilityV1);
        storage[index].model = sdk.bytesView(entry.model);
        storage[index].image_input_code = if (entry.supported) wire.CAPABILITY_SUPPORTED else wire.CAPABILITY_UNSUPPORTED;
    }
    host.model_capabilities = if (entries.len == 0) null else storage;
    host.model_capability_count = entries.len;
}

fn releaseOwned(api: sdk.Api, buffer: *wire.OwnedBytesV1) void {
    if (buffer.ptr != null or buffer.len != 0) api.bufferRelease()(buffer);
}

const max_core_session_id_bytes: usize = @intCast(wire.MAX_SESSION_ID_BYTES_V1);

test "image capability consumer limit matches the canonical ABI" {
    try std.testing.expectEqual(@as(u64, 256), wire.MAX_MODEL_CAPABILITIES_V1);
    try std.testing.expectEqual(@as(u64, model_binding.max_model_bytes), wire.MAX_MODEL_CAPABILITY_MODEL_BYTES_V1);
}
