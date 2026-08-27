//! Application-owned MCP management effects. Workbench remains the sole
//! product-state owner; this coordinator sequences native confirmation,
//! secure capture, browser, loopback, bounded network workers and isolated
//! connection-test Runtimes around the Workbench transaction seams.

const std = @import("std");
const builtin = @import("builtin");
const agent = @import("metawork_agent");
const workbench = @import("metawork_workbench");
const control_ports = @import("metawork_product_control_ports");
const product_mcp = @import("metawork_product_mcp");
const mcp_configuration = product_mcp.contract;
const mcp_types = product_mcp;
const mcp_oauth = @import("metawork_mcp_oauth");
const mcp_platform = @import("metawork_mcp_platform");
const mcp_startup = @import("mcp_startup.zig");
const app_platform = @import("platform.zig");

const connection_approval_details_bytes: usize = mcp_configuration.max_store_bytes * 6 + 4096;
const oauth_consent_details_bytes: usize = mcp_oauth.Limits.metadata_body_bytes * 6 + 4096;
const secret_capture_prompt_bytes: usize = 32 * 1024;

pub const Confirmation = enum { approved, cancelled, unavailable };

pub const CaptureResult = union(enum) {
    captured: usize,
    cancelled,
    unavailable,
};

pub const Host = struct {
    context: *anyopaque,
    confirmation_available: bool = false,
    capture_available: bool = false,
    oauth_available: bool = false,
    confirm_fn: *const fn (*anyopaque, []const u8, []const u8, []const u8) Confirmation,
    capture_fn: *const fn (*anyopaque, []const u8, []const u8, []u8) CaptureResult,
    open_url_fn: *const fn (*anyopaque, []const u8) bool,
    now_unix_ms_fn: *const fn (*anyopaque) ?u64,
    notify_fn: *const fn (*anyopaque) void,

    fn confirm(
        self: Host,
        title: []const u8,
        details: []const u8,
        approval_label: []const u8,
    ) Confirmation {
        return self.confirm_fn(self.context, title, details, approval_label);
    }

    fn capture(
        self: Host,
        title: []const u8,
        prompt: []const u8,
        output: []u8,
    ) CaptureResult {
        return self.capture_fn(self.context, title, prompt, output);
    }

    fn openUrl(self: Host, url: []const u8) bool {
        return self.open_url_fn(self.context, url);
    }

    fn nowUnixMs(self: Host) ?u64 {
        return self.now_unix_ms_fn(self.context);
    }

    fn notify(self: Host) void {
        self.notify_fn(self.context);
    }
};

pub fn platformHost(platform: *app_platform.Adapter) Host {
    return .{
        .context = platform,
        .confirmation_available = platform.supportsMcpConnectionApproval(),
        .capture_available = builtin.os.tag == .windows and
            platform.supportsSecureInput(),
        .oauth_available = platform.supportsMcpExternalAuthorization(),
        .confirm_fn = platformConfirm,
        .capture_fn = platformCapture,
        .open_url_fn = platformOpenUrl,
        .now_unix_ms_fn = platformNowUnixMs,
        .notify_fn = platformNotify,
    };
}

fn platformConfirm(
    context: *anyopaque,
    title: []const u8,
    details: []const u8,
    approval_label: []const u8,
) Confirmation {
    const platform: *app_platform.Adapter = @ptrCast(@alignCast(context));
    const result = platform.confirmMcpDetails(title, details, approval_label) orelse
        return .unavailable;
    return if (result) .approved else .cancelled;
}

fn platformCapture(
    context: *anyopaque,
    title: []const u8,
    prompt: []const u8,
    output: []u8,
) CaptureResult {
    const platform: *app_platform.Adapter = @ptrCast(@alignCast(context));
    const result = platform.captureSecureInput(
        title,
        prompt,
        "Save",
        "Cancel",
        output,
    ) orelse return .unavailable;
    return mapPlatformCapture(result);
}

fn mapPlatformCapture(result: app_platform.SecureInputResult) CaptureResult {
    return switch (result) {
        .submitted => |length| .{ .captured = length },
        .cancelled => .cancelled,
    };
}

fn platformOpenUrl(context: *anyopaque, url: []const u8) bool {
    const platform: *app_platform.Adapter = @ptrCast(@alignCast(context));
    return platform.openMcpAuthorizationUrl(url);
}

fn platformNowUnixMs(context: *anyopaque) ?u64 {
    const platform: *app_platform.Adapter = @ptrCast(@alignCast(context));
    return platform.nowUnixMilliseconds();
}

fn platformNotify(context: *anyopaque) void {
    const platform: *app_platform.Adapter = @ptrCast(@alignCast(context));
    app_platform.Adapter.notifyRequired(platform);
}

pub const Outcome = enum {
    saved,
    saved_recovery_required,
    stale_generation,
    rejected,
    indeterminate,
    cancelled,
    capability_unavailable,
};

pub const AuthorizationStartOutcome = union(enum) {
    started: []const u8,
    rejected,
    stale_generation,
    capability_unavailable,
};

pub const ConnectionTestStartOutcome = enum {
    started,
    busy,
    stale_generation,
    needs_authentication,
    rejected,
    unavailable,
};

pub const ConfigurationApplyStartOutcome = enum {
    started,
    busy,
    rejected,
    unavailable,
};

pub const SecretSlot = mcp_types.McpSecretCaptureTarget;

const oauth_timeout: std.Io.Clock.Duration = .{
    .raw = .fromSeconds(5 * 60),
    .clock = .boot,
};

const JobFailure = enum {
    definitive,
    cancelled_before_send,
    rejected,
    invalid_grant,
    outcome_unknown,
};

const DiscoveryResult = struct {
    resource: mcp_oauth.ResourceDiscovery,
    authorization: mcp_oauth.AuthorizationServer,

    fn deinit(self: *DiscoveryResult) void {
        self.authorization.deinit();
        self.resource.deinit();
        self.* = undefined;
    }
};

const JobResult = union(enum) {
    pending,
    discovery: DiscoveryResult,
    registration: mcp_oauth.Registration,
    callback: mcp_oauth.AuthorizationCallback,
    tokens: mcp_oauth.TokenSet,
    failed: JobFailure,

    fn deinit(self: *JobResult) void {
        switch (self.*) {
            .discovery => |*value| value.deinit(),
            .registration => |*value| value.deinit(),
            .callback => |*value| value.deinit(),
            .tokens => |*value| value.deinit(),
            .pending, .failed => {},
        }
        self.* = .pending;
    }
};

const DiscoveryInput = struct {
    endpoint: []u8,
};

const RegistrationInput = struct {
    resource: *const mcp_oauth.ResourceDiscovery,
    authorization: *const mcp_oauth.AuthorizationServer,
    redirect_uri: []u8,
};

const CallbackInput = struct {
    attempt: *mcp_oauth.AuthorizationAttempt,
};

const ExchangeInput = struct {
    authorization: *const mcp_oauth.AuthorizationServer,
    client_id: []u8,
    client_secret: ?[]u8,
    token_endpoint_auth_method: mcp_oauth.TokenEndpointAuthMethod,
    code: mcp_oauth.AuthorizationCode,
    verifier: []u8,
    redirect_uri: []u8,
    resource: []u8,
    now_unix_ms: u64,
};

const JobInput = union(enum) {
    discovery: DiscoveryInput,
    registration: RegistrationInput,
    callback: CallbackInput,
    exchange: ExchangeInput,
};

const Job = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    host: Host,
    transport_override: ?mcp_oauth.Transport = null,
    input: JobInput,
    cancellation: mcp_oauth.Cancellation,
    deadline: std.Io.Clock.Timestamp,
    result: JobResult = .pending,
    finished: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    fn start(self: *Job) std.Thread.SpawnError!void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn run(self: *Job) void {
        switch (self.input) {
            .discovery => |input| self.runDiscovery(input),
            .registration => |input| self.runRegistration(input),
            .callback => |input| self.runCallback(input),
            .exchange => |*input| self.runExchange(input),
        }
    }

    fn transport(self: *Job, storage: *mcp_oauth.StdHttpTransport) mcp_oauth.Transport {
        if (self.transport_override) |transport_value| return transport_value;
        storage.* = .{
            .allocator = self.allocator,
            .io = self.io,
            .cancellation = &self.cancellation,
            .deadline = self.deadline,
        };
        return storage.transport();
    }

    fn runDiscovery(self: *Job, input: DiscoveryInput) void {
        var http: mcp_oauth.StdHttpTransport = undefined;
        var resource = mcp_oauth.discoverResourceEffect(
            self.allocator,
            self.transport(&http),
            input.endpoint,
        ) catch {
            self.publish(.{ .failed = .definitive });
            return;
        };
        var resource_owned = true;
        defer if (resource_owned) resource.deinit();
        const issuer = resource.authorization_servers[0];
        const authorization = mcp_oauth.discoverAuthorizationServer(
            self.allocator,
            self.transport(&http),
            &resource,
            issuer,
        ) catch {
            self.publish(.{ .failed = .definitive });
            return;
        };
        resource_owned = false;
        self.result = .{ .discovery = .{
            .resource = resource,
            .authorization = authorization,
        } };
        self.finish();
    }

    fn runRegistration(self: *Job, input: RegistrationInput) void {
        var http: mcp_oauth.StdHttpTransport = undefined;
        const registration = mcp_oauth.registerDynamicClientEffect(
            self.allocator,
            self.transport(&http),
            input.authorization,
            input.redirect_uri,
        ) catch |err| {
            self.publish(.{ .failed = switch (err) {
                error.RegistrationRejected => .rejected,
                error.CancelledBeforeSend => .cancelled_before_send,
                error.RegistrationOutcomeUnknown => .outcome_unknown,
                else => .definitive,
            } });
            return;
        };
        self.result = .{ .registration = registration };
        self.finish();
    }

    fn runCallback(self: *Job, input: CallbackInput) void {
        const callback = input.attempt.wait(
            self.allocator,
            self.deadline,
        ) catch {
            self.publish(.{ .failed = .definitive });
            return;
        };
        self.result = .{ .callback = callback };
        self.finish();
    }

    fn runExchange(self: *Job, input: *ExchangeInput) void {
        var http: mcp_oauth.StdHttpTransport = undefined;
        const tokens = mcp_oauth.exchangeAuthorizationCodeEffect(
            self.allocator,
            self.transport(&http),
            input.authorization,
            input.client_id,
            input.client_secret,
            input.token_endpoint_auth_method,
            &input.code,
            input.verifier,
            input.redirect_uri,
            input.resource,
            input.now_unix_ms,
        ) catch |err| {
            self.publish(.{ .failed = switch (err) {
                error.InvalidGrant => .invalid_grant,
                error.CancelledBeforeSend => .cancelled_before_send,
                error.TokenOutcomeUnknown => .outcome_unknown,
                else => .definitive,
            } });
            return;
        };
        self.result = .{ .tokens = tokens };
        self.finish();
    }

    fn publish(self: *Job, result: JobResult) void {
        self.result = result;
        self.finish();
    }

    fn finish(self: *Job) void {
        self.finished.store(true, .release);
        self.host.notify();
    }

    fn cancel(self: *Job) void {
        self.cancellation.cancel();
        switch (self.input) {
            .callback => |input| input.attempt.cancel(),
            else => {},
        }
    }

    fn join(self: *Job) void {
        const thread = self.thread orelse return;
        thread.join();
        self.thread = null;
    }

    fn deinit(self: *Job) void {
        std.debug.assert(self.thread == null);
        self.result.deinit();
        deinitJobInput(self.allocator, &self.input);
        self.* = undefined;
    }
};

fn deinitJobInput(allocator: std.mem.Allocator, input: *JobInput) void {
    switch (input.*) {
        .discovery => |value| allocator.free(value.endpoint),
        .registration => |value| allocator.free(value.redirect_uri),
        .callback => {},
        .exchange => |*value| {
            allocator.free(value.client_id);
            if (value.client_secret) |secret| secureFree(allocator, secret);
            value.code.deinit();
            secureFree(allocator, value.verifier);
            allocator.free(value.redirect_uri);
            allocator.free(value.resource);
        },
    }
    input.* = undefined;
}

const Flow = struct {
    start: mcp_types.McpAuthorizationStart,
    deadline: std.Io.Clock.Timestamp,
    discovery: ?DiscoveryResult = null,
    attempt: ?*mcp_oauth.AuthorizationAttempt = null,
    job: ?*Job = null,
    durable_operation_id: ?[]u8 = null,
    durable_request_started: bool = false,
    cancelling: bool = false,

    fn deinit(self: *Flow, allocator: std.mem.Allocator) void {
        std.debug.assert(self.job == null);
        if (self.attempt) |attempt| {
            attempt.deinit();
            allocator.destroy(attempt);
        }
        if (self.discovery) |*discovery| discovery.deinit();
        if (self.durable_operation_id) |operation_id| allocator.free(operation_id);
        self.start.deinit();
        self.* = undefined;
    }
};

const ConnectionTestResult = struct {
    outcome: mcp_types.McpConnectionTestOutcome = .failed,
    tool_count: u32 = 0,
    issue_count: u32 = 0,
};

const ConnectionTestJob = struct {
    allocator: std.mem.Allocator,
    host: Host,
    server_id: []u8,
    runtime: ?*agent.Runtime,
    authorizations: mcp_platform.HttpAuthorizations,
    result: ConnectionTestResult = .{},
    finished: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    fn start(self: *ConnectionTestJob) std.Thread.SpawnError!void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn run(self: *ConnectionTestJob) void {
        const runtime = self.runtime.?;
        if (runtime.activateMcp()) |activation_outcome| switch (activation_outcome) {
            .activated => |activation| {
                defer activation.deinit();
                if (activation.serverHealth().len == 1 and
                    activation.serverHealth()[0].state != .unavailable)
                {
                    self.result = .{
                        .outcome = .connected,
                        .tool_count = std.math.cast(u32, activation.catalogTools().len) orelse
                            std.math.maxInt(u32),
                        .issue_count = std.math.cast(u32, activation.catalogIssues().len) orelse
                            std.math.maxInt(u32),
                    };
                }
            },
            .empty, .unavailable => {},
        } else |_| {}
        runtime.shutdown() catch {
            self.result.outcome = .failed;
        };
        runtime.deinit();
        self.runtime = null;
        self.authorizations.deinit();
        self.finished.store(true, .release);
        self.host.notify();
    }

    fn join(self: *ConnectionTestJob) void {
        const thread = self.thread orelse return;
        thread.join();
        self.thread = null;
    }

    fn deinit(self: *ConnectionTestJob) void {
        std.debug.assert(self.thread == null and self.runtime == null);
        self.allocator.free(self.server_id);
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }
};

const ConfigurationApplyResult = union(enum) {
    pending,
    applied: struct {
        activation: ?*agent.McpActivation,
        selection: ?*agent.McpSelection,
        activation_failed: bool,
    },
    rejected,
    failed,
};

const ConfigurationApplyJob = struct {
    allocator: std.mem.Allocator,
    host: Host,
    generation: u64,
    runtime: *agent.Runtime,
    preparation: mcp_configuration.Preparation,
    manifest: mcp_configuration.RuntimeManifest,
    input: ?agent.McpRuntimeInput,
    authorizations: mcp_platform.HttpAuthorizations,
    allowlists: []agent.McpServerAllowlist,
    product_state_installed: bool = false,
    result: ConfigurationApplyResult = .pending,
    finished: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    fn start(self: *ConfigurationApplyJob) std.Thread.SpawnError!void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn run(self: *ConfigurationApplyJob) void {
        const input = if (self.input) |*value| value else {
            self.publish(.failed);
            return;
        };
        const apply = self.runtime.applyMcpConfiguration(input) catch {
            self.publish(.failed);
            return;
        };
        if (apply != .applied) {
            self.publish(.rejected);
            return;
        }
        const activation_outcome = self.runtime.activateMcp() catch {
            self.publish(.{ .applied = .{
                .activation = null,
                .selection = null,
                .activation_failed = true,
            } });
            return;
        };
        switch (activation_outcome) {
            .empty => self.publish(.{ .applied = .{
                .activation = null,
                .selection = null,
                .activation_failed = false,
            } }),
            .unavailable => self.publish(.{ .applied = .{
                .activation = null,
                .selection = null,
                .activation_failed = true,
            } }),
            .activated => |activation| {
                if (activation.takeSelection()) |startup_selection|
                    startup_selection.deinit();
                const selection = self.runtime.createMcpAdmissionSelection(
                    activation,
                    self.allowlists,
                ) catch {
                    activation.deinit();
                    self.publish(.{ .applied = .{
                        .activation = null,
                        .selection = null,
                        .activation_failed = true,
                    } });
                    return;
                };
                self.publish(.{ .applied = .{
                    .activation = activation,
                    .selection = selection,
                    .activation_failed = false,
                } });
            },
        }
    }

    fn publish(self: *ConfigurationApplyJob, result: ConfigurationApplyResult) void {
        self.result = result;
        self.finished.store(true, .release);
        self.host.notify();
    }

    fn join(self: *ConfigurationApplyJob) void {
        const thread = self.thread orelse return;
        thread.join();
        self.thread = null;
    }

    fn takeAuthorizations(self: *ConfigurationApplyJob) mcp_platform.HttpAuthorizations {
        const moved = self.authorizations;
        self.authorizations = .{ .allocator = moved.allocator };
        return moved;
    }

    fn deinit(self: *ConfigurationApplyJob) void {
        std.debug.assert(self.thread == null);
        switch (self.result) {
            .applied => |applied| {
                if (applied.selection) |selection| selection.deinit();
                if (applied.activation) |activation| activation.deinit();
            },
            .pending, .rejected, .failed => {},
        }
        if (self.input) |*input| input.deinit();
        self.authorizations.deinit();
        if (!self.product_state_installed) {
            self.manifest.deinit();
            self.preparation.deinit();
        }
        if (self.allowlists.len != 0) self.allocator.free(self.allowlists);
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }
};

pub const Coordinator = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    control: control_ports.McpManagementPort,
    agent_runtime: *agent.Runtime,
    credential_store: *mcp_platform.CredentialStore,
    active_authorizations: *mcp_platform.HttpAuthorizations,
    host: Host,
    host_environment: mcp_platform.HostEnvironment,
    transport_override: ?mcp_oauth.Transport = null,
    flow: ?*Flow = null,
    connection_test_job: ?*ConnectionTestJob = null,
    configuration_apply_job: ?*ConfigurationApplyJob = null,
    last_cancel_outcome: ?Outcome = null,
    stopping: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        control: control_ports.McpManagementPort,
        agent_runtime: *agent.Runtime,
        credential_store: *mcp_platform.CredentialStore,
        active_authorizations: *mcp_platform.HttpAuthorizations,
        host: Host,
        host_environment: mcp_platform.HostEnvironment,
    ) Coordinator {
        return .{
            .allocator = allocator,
            .io = io,
            .control = control,
            .agent_runtime = agent_runtime,
            .credential_store = credential_store,
            .active_authorizations = active_authorizations,
            .host = host,
            .host_environment = host_environment,
        };
    }

    pub fn connectionApprovalAvailable(self: *const Coordinator) bool {
        return self.host.confirmation_available;
    }

    pub fn secretCaptureAvailable(self: *const Coordinator) bool {
        return self.host.capture_available;
    }

    pub fn oauthAvailable(self: *const Coordinator) bool {
        return self.host.oauth_available and self.host.confirmation_available;
    }

    pub fn authorizeOauth(
        self: *Coordinator,
        expected_generation: u64,
        server_id: []const u8,
    ) !AuthorizationStartOutcome {
        if (self.stopping or self.flow != null or self.connection_test_job != null or
            self.configuration_apply_job != null)
            return .rejected;
        self.last_cancel_outcome = null;
        if (!self.oauthAvailable()) return .capability_unavailable;
        const inspection = self.control.inspectMcpDesiredConfiguration() orelse
            return .rejected;
        if (inspection.desired_generation != expected_generation)
            return .stale_generation;
        var start = (try self.control.beginMcpAuthorization(
            expected_generation,
            server_id,
        )) orelse return .rejected;
        var start_owned = true;
        defer if (start_owned) start.deinit();
        const flow = try self.allocator.create(Flow);
        flow.* = .{
            .start = start,
            .deadline = std.Io.Clock.Timestamp.fromNow(self.io, oauth_timeout),
        };
        start_owned = false;
        errdefer {
            _ = self.control.finishMcpAuthorization(flow.start.operation_id);
            if (self.flow == flow) self.flow = null;
            flow.deinit(self.allocator);
            self.allocator.destroy(flow);
        }
        self.flow = flow;
        try self.startDiscovery(flow);
        return .{ .started = flow.start.operation_id };
    }

    pub fn cancelAuthorization(
        self: *Coordinator,
        operation_id: []const u8,
    ) Outcome {
        const flow = self.flow orelse return .rejected;
        if (!std.mem.eql(u8, flow.start.operation_id, operation_id))
            return .rejected;
        self.last_cancel_outcome = null;
        _ = self.control.advanceMcpAuthorization(
            operation_id,
            .cancelling,
        );
        flow.cancelling = true;
        const job = flow.job orelse {
            self.finishFlow(flow);
            return .cancelled;
        };
        job.cancel();
        job.join();
        if (!job.finished.load(.acquire)) {
            job.result = .{ .failed = .outcome_unknown };
            job.finished.store(true, .release);
        }
        _ = self.drain();
        const outcome = self.last_cancel_outcome orelse .cancelled;
        self.last_cancel_outcome = null;
        return outcome;
    }

    pub fn testConnection(
        self: *Coordinator,
        expected_generation: u64,
        server_id: []const u8,
    ) !ConnectionTestStartOutcome {
        if (self.stopping) return .unavailable;
        if (self.connection_test_job != null or self.configuration_apply_job != null or
            self.flow != null) return .busy;
        const inspection = self.control.inspectMcpDesiredConfiguration() orelse
            return .unavailable;
        if (inspection.desired_generation != expected_generation)
            return .stale_generation;

        const registry_storage = try self.allocator.alloc(
            u8,
            mcp_configuration.max_store_bytes,
        );
        defer self.allocator.free(registry_storage);
        const registry_bytes = self.control.writeMcpDesiredConfiguration(
            expected_generation,
            registry_storage,
        ) catch return .unavailable;
        var preparation = try mcp_configuration.prepare(
            self.allocator,
            registry_bytes,
            true,
            false,
            self.credential_store.resolver(),
            mcp_startup.configuration_limits,
        );
        defer preparation.deinit();
        const registry = preparation.registry orelse return .unavailable;
        var selected_index: ?usize = null;
        for (registry.value.servers, 0..) |server, index| {
            if (std.mem.eql(u8, server.id, server_id)) {
                selected_index = index;
                break;
            }
        }
        const index = selected_index orelse return .rejected;
        switch (preparation.server_states[index]) {
            .eligible => {},
            .needs_authentication, .reauth_required => return .needs_authentication,
            .disabled, .unapproved, .invalid_catalog => return .rejected,
        }
        for (preparation.server_states, 0..) |*state, state_index| {
            if (state_index != index) state.* = .disabled;
        }

        var runtime_build = mcp_platform.buildRuntime(
            self.io,
            self.allocator,
            &preparation,
            self.host_environment,
        ) catch return .unavailable;
        defer runtime_build.deinit();
        const input = if (runtime_build.input) |*value| value else return .unavailable;
        const runtime = agent.Runtime.init(self.io, self.allocator, .{
            .max_sessions = 1,
            .mcp_input = input,
        }) catch return .unavailable;
        var authorizations = runtime_build.takeAuthorizations();
        var runtime_owned = true;
        defer if (runtime_owned) {
            runtime.shutdown() catch {};
            runtime.deinit();
            authorizations.deinit();
        };
        const job = try self.allocator.create(ConnectionTestJob);
        errdefer self.allocator.destroy(job);
        job.* = .{
            .allocator = self.allocator,
            .host = self.host,
            .server_id = try self.allocator.dupe(u8, server_id),
            .runtime = runtime,
            .authorizations = authorizations,
        };
        errdefer self.allocator.free(job.server_id);
        try self.control.beginMcpConnectionTest(server_id);
        job.start() catch {
            self.control.completeMcpConnectionTest(
                server_id,
                .failed,
                0,
                0,
            );
            self.allocator.free(job.server_id);
            self.allocator.destroy(job);
            return .unavailable;
        };
        runtime_owned = false;
        self.connection_test_job = job;
        return .started;
    }

    pub fn applyConfiguration(self: *Coordinator) !ConfigurationApplyStartOutcome {
        if (self.stopping) return .unavailable;
        if (self.configuration_apply_job != null or self.connection_test_job != null or
            self.flow != null) return .busy;
        const inspection = self.control.inspectMcpDesiredConfiguration() orelse
            return .unavailable;
        if (inspection.health != .ready) return .unavailable;
        const generation = inspection.desired_generation orelse return .rejected;
        if (generation == 0) return .rejected;

        self.control.beginMcpConfigurationApply(generation) catch
            return .busy;
        var apply_state_owned = true;
        defer if (apply_state_owned)
            self.control.failMcpConfigurationApply(generation);

        const registry_storage = try self.allocator.alloc(
            u8,
            mcp_configuration.max_store_bytes,
        );
        defer self.allocator.free(registry_storage);
        const registry_bytes = self.control.writeMcpDesiredConfiguration(
            generation,
            registry_storage,
        ) catch return .unavailable;
        var preparation = try mcp_configuration.prepare(
            self.allocator,
            registry_bytes,
            true,
            false,
            self.credential_store.resolver(),
            mcp_startup.configuration_limits,
        );
        var preparation_owned = true;
        defer if (preparation_owned) preparation.deinit();
        const manifest_optional = try mcp_configuration.RuntimeManifest.candidate(
            self.allocator,
            &preparation,
        );
        var manifest = manifest_optional orelse return .unavailable;
        var manifest_owned = true;
        defer if (manifest_owned) manifest.deinit();
        var runtime_build = mcp_platform.buildRuntime(
            self.io,
            self.allocator,
            &preparation,
            self.host_environment,
        ) catch return .unavailable;
        var build_owned = true;
        defer if (build_owned) runtime_build.deinit();
        preparation.releaseCredentials();
        if (runtime_build.input == null) return .rejected;

        const registry = preparation.registry orelse return .unavailable;
        var eligible_count: usize = 0;
        for (preparation.server_states) |state| {
            if (state == .eligible) eligible_count += 1;
        }
        const allowlists = try self.allocator.alloc(
            agent.McpServerAllowlist,
            eligible_count,
        );
        errdefer if (allowlists.len != 0) self.allocator.free(allowlists);
        var write: usize = 0;
        for (registry.value.servers, preparation.server_states) |server, state| {
            if (state != .eligible) continue;
            allowlists[write] = .{ .id = server.id, .tools = server.tools };
            write += 1;
        }
        const job = try self.allocator.create(ConfigurationApplyJob);
        errdefer self.allocator.destroy(job);
        job.* = .{
            .allocator = self.allocator,
            .host = self.host,
            .generation = generation,
            .runtime = self.agent_runtime,
            .preparation = preparation,
            .manifest = manifest,
            .input = runtime_build.input,
            .authorizations = runtime_build.takeAuthorizations(),
            .allowlists = allowlists,
        };
        runtime_build.input = null;
        build_owned = false;
        runtime_build.deinit();
        preparation_owned = false;
        manifest_owned = false;
        job.start() catch {
            job.deinit();
            return .unavailable;
        };
        self.configuration_apply_job = job;
        apply_state_owned = false;
        return .started;
    }

    pub fn drain(self: *Coordinator) bool {
        var changed = false;
        if (self.configuration_apply_job) |apply_job| {
            if (apply_job.finished.load(.acquire)) {
                apply_job.join();
                switch (apply_job.result) {
                    .applied => |applied| {
                        self.active_authorizations.deinit();
                        self.active_authorizations.* = apply_job.takeAuthorizations();
                        const installed = self.control.completeMcpConfigurationApply(
                            apply_job.generation,
                            &apply_job.preparation,
                            &apply_job.manifest,
                            applied.activation,
                            applied.selection,
                            applied.activation_failed,
                        );
                        if (installed) {
                            apply_job.product_state_installed = true;
                            apply_job.result = .pending;
                        } else self.control.failMcpConfigurationApply(
                            apply_job.generation,
                        );
                    },
                    .rejected, .failed => self.control.failMcpConfigurationApply(
                        apply_job.generation,
                    ),
                    .pending => unreachable,
                }
                self.configuration_apply_job = null;
                apply_job.deinit();
                changed = true;
            }
        }
        if (self.connection_test_job) |test_job| {
            if (test_job.finished.load(.acquire)) {
                test_job.join();
                self.control.completeMcpConnectionTest(
                    test_job.server_id,
                    test_job.result.outcome,
                    test_job.result.tool_count,
                    test_job.result.issue_count,
                );
                self.connection_test_job = null;
                test_job.deinit();
                changed = true;
            }
        }
        const flow = self.flow orelse return changed;
        const job = flow.job orelse return changed;
        if (!job.finished.load(.acquire)) return changed;
        job.join();
        switch (job.input) {
            .discovery => self.completeDiscovery(flow, job),
            .registration => self.completeRegistration(flow, job),
            .callback => self.completeCallback(flow, job),
            .exchange => self.completeExchange(flow, job),
        }
        return true;
    }

    pub fn shutdown(self: *Coordinator) void {
        if (self.stopping) return;
        self.stopping = true;
        if (self.configuration_apply_job) |apply_job| {
            apply_job.join();
            _ = self.drain();
        }
        if (self.connection_test_job) |test_job| {
            test_job.join();
            _ = self.drain();
        }
        const flow = self.flow orelse return;
        flow.cancelling = true;
        if (flow.job) |job| {
            job.cancel();
            job.join();
            if (!job.finished.load(.acquire)) {
                job.result = .{ .failed = .outcome_unknown };
                job.finished.store(true, .release);
            }
            _ = self.drain();
        } else self.finishFlow(flow);
        if (self.flow) |remaining| {
            if (remaining.durable_operation_id) |operation_id|
                _ = self.control.recoverMcpOauthOperation(operation_id) catch {};
            self.finishFlow(remaining);
        }
    }

    pub fn deinit(self: *Coordinator) void {
        self.shutdown();
        std.debug.assert(self.flow == null);
        self.* = undefined;
    }

    pub fn approveConnection(
        self: *Coordinator,
        expected_generation: u64,
        server_id: []const u8,
    ) !Outcome {
        if (self.stopping or self.configuration_apply_job != null or
            self.connection_test_job != null or self.flow != null) return .rejected;
        if (!self.connectionApprovalAvailable()) return .capability_unavailable;
        const inspection = self.control.inspectMcpDesiredConfiguration() orelse
            return .rejected;
        if (inspection.desired_generation != expected_generation)
            return .stale_generation;
        const details_storage = try self.allocator.alloc(
            u8,
            connection_approval_details_bytes,
        );
        defer self.allocator.free(details_storage);
        const details = self.control.writeMcpConnectionApprovalDetails(
            expected_generation,
            server_id,
            details_storage,
        ) catch return .rejected;
        return switch (self.host.confirm(
            "Approve MCP connection",
            details,
            "Approve connection",
        )) {
            .approved => mapManagementOutcome(try self.control.approveMcpConnection(
                expected_generation,
                .{ .server_id = server_id },
            )),
            .cancelled => .cancelled,
            .unavailable => .capability_unavailable,
        };
    }

    pub fn captureSecret(
        self: *Coordinator,
        expected_generation: u64,
        server_id: []const u8,
        slot: SecretSlot,
    ) !Outcome {
        if (self.stopping or self.configuration_apply_job != null or
            self.connection_test_job != null or self.flow != null) return .rejected;
        if (!self.secretCaptureAvailable()) return .capability_unavailable;
        const inspection = self.control.inspectMcpDesiredConfiguration() orelse
            return .rejected;
        if (inspection.desired_generation != expected_generation)
            return .stale_generation;
        var prompt_storage: [secret_capture_prompt_bytes]u8 = undefined;
        const prompt = self.control.writeMcpSecretCapturePrompt(
            expected_generation,
            server_id,
            slot,
            &prompt_storage,
        ) catch return .rejected;
        var secret_storage: [mcp_platform.max_credential_secret_bytes]u8 = undefined;
        defer std.crypto.secureZero(u8, &secret_storage);
        const captured = switch (self.host.capture(
            "Set MCP secret",
            prompt,
            &secret_storage,
        )) {
            .captured => |length| length,
            .cancelled => return .cancelled,
            .unavailable => return .capability_unavailable,
        };
        if (captured == 0 or captured > secret_storage.len) return .rejected;
        const secret = secret_storage[0..captured];
        return switch (slot) {
            .stdio_environment => |name| mapManagementOutcome(
                try self.control.captureMcpStaticSecret(
                    expected_generation,
                    .{ .server_id = server_id, .slot_name = name, .secret = secret },
                ),
            ),
            .http_header => |name| mapManagementOutcome(
                try self.control.captureMcpStaticSecret(
                    expected_generation,
                    .{ .server_id = server_id, .slot_name = name, .secret = secret },
                ),
            ),
            .oauth_client_secret => mapManagementOutcome(
                try self.control.captureMcpOauthClientSecret(
                    expected_generation,
                    .{ .server_id = server_id, .secret = secret },
                ),
            ),
        };
    }

    fn startDiscovery(self: *Coordinator, flow: *Flow) !void {
        try self.installJob(flow, .{ .discovery = .{
            .endpoint = try self.allocator.dupe(u8, flow.start.endpoint),
        } });
    }

    fn installJob(self: *Coordinator, flow: *Flow, input_value: JobInput) !void {
        std.debug.assert(flow.job == null);
        var input = input_value;
        var input_owned = true;
        errdefer if (input_owned) deinitJobInput(self.allocator, &input);
        const job = try self.allocator.create(Job);
        job.* = .{
            .allocator = self.allocator,
            .io = self.io,
            .host = self.host,
            .transport_override = self.transport_override,
            .input = input,
            .cancellation = .init(self.io),
            .deadline = flow.deadline,
        };
        input_owned = false;
        errdefer {
            job.thread = null;
            job.deinit();
            self.allocator.destroy(job);
        }
        try job.start();
        flow.job = job;
    }

    fn destroyJob(self: *Coordinator, flow: *Flow, job: *Job) void {
        std.debug.assert(flow.job == job and job.thread == null);
        flow.job = null;
        job.deinit();
        self.allocator.destroy(job);
    }

    fn completeDiscovery(self: *Coordinator, flow: *Flow, job: *Job) void {
        var result = job.result;
        job.result = .pending;
        self.destroyJob(flow, job);
        if (flow.cancelling) {
            result.deinit();
            self.last_cancel_outcome = .cancelled;
            self.finishFlow(flow);
            return;
        }
        switch (result) {
            .discovery => |discovery_value| {
                var discovery = discovery_value;
                discovery.resource.mergeRequestedScopes(
                    flow.start.additional_scopes,
                ) catch {
                    discovery.deinit();
                    self.finishFlow(flow);
                    return;
                };
                flow.discovery = discovery;
                self.presentConsent(flow) catch self.finishFlow(flow);
            },
            .failed, .pending, .registration, .callback, .tokens => self.finishFlow(flow),
        }
    }

    fn presentConsent(self: *Coordinator, flow: *Flow) !void {
        const discovery = if (flow.discovery) |*value| value else return error.InvalidState;
        if (flow.start.client_id != null) {
            const configured_method = mcp_oauth.TokenEndpointAuthMethod.fromWire(
                flow.start.token_endpoint_auth_method orelse return error.InvalidState,
            ) orelse return error.InvalidState;
            if (!containsAuthMethod(
                discovery.authorization.token_endpoint_auth_methods,
                configured_method,
            )) return error.InvalidState;
        } else if (discovery.authorization.registration_endpoint == null) {
            return error.DynamicRegistrationUnavailable;
        }
        if (!self.control.advanceMcpAuthorization(
            flow.start.operation_id,
            .awaiting_consent,
        )) return error.InvalidState;

        const attempt = try self.allocator.create(mcp_oauth.AuthorizationAttempt);
        attempt.* = .{};
        var attempt_owned = true;
        errdefer if (attempt_owned) {
            attempt.deinit();
            self.allocator.destroy(attempt);
        };
        var attempt_id: u64 = 0;
        while (attempt_id == 0) std.Io.randomSecure(self.io, std.mem.asBytes(&attempt_id)) catch
            return error.RandomUnavailable;
        try attempt.start(self.io, attempt_id);
        flow.attempt = attempt;
        attempt_owned = false;

        const details_storage = try self.allocator.alloc(u8, oauth_consent_details_bytes);
        defer self.allocator.free(details_storage);
        const details = try writeConsentDetails(
            details_storage,
            &discovery.resource,
            &discovery.authorization,
            attempt.redirectUri(),
            flow.start.registration_kind,
            flow.start.client_id,
            flow.start.token_endpoint_auth_method,
            flow.start.client_id == null,
        );
        switch (self.host.confirm(
            "Authorize MCP server",
            details,
            "Continue to browser",
        )) {
            .approved => {},
            .cancelled, .unavailable => {
                self.finishFlow(flow);
                return;
            },
        }

        if (flow.start.client_id == null) {
            if (!std.mem.eql(u8, flow.start.registration_kind, "dynamic_registration"))
                return error.InvalidState;
            const begin = try self.control.beginMcpOauthDynamicRegistration(.{
                .server_id = flow.start.server_id,
                .resource = discovery.resource.resource,
                .issuer = discovery.authorization.issuer,
                .scopes = discovery.resource.requested_scopes,
                .redirect_uri = attempt.redirectUri(),
            });
            const operation = switch (begin) {
                .started => |value| value,
                .rejected, .persistence_outcome_unknown => return error.StateRejected,
            };
            flow.durable_operation_id = self.allocator.dupe(u8, operation.id) catch |err| {
                _ = self.control.clearMcpOauthOperation(operation.id) catch {};
                return err;
            };
            if (!self.control.advanceMcpAuthorization(
                flow.start.operation_id,
                .registering,
            )) return error.InvalidState;
            try self.installJob(flow, .{ .registration = .{
                .resource = &discovery.resource,
                .authorization = &discovery.authorization,
                .redirect_uri = try self.allocator.dupe(u8, attempt.redirectUri()),
            } });
            flow.durable_request_started = true;
            return;
        }
        try self.bindAndOpen(flow);
    }

    fn bindAndOpen(self: *Coordinator, flow: *Flow) !void {
        const discovery = if (flow.discovery) |*value| value else return error.InvalidState;
        const attempt = flow.attempt orelse return error.InvalidState;
        try attempt.bind(
            self.authorizationPort(),
            flow.start.server_id,
            &discovery.resource,
            &discovery.authorization,
        );
        if (!self.host.openUrl(attempt.authorizationUrl()))
            return error.BrowserUnavailable;
        if (!self.control.advanceMcpAuthorization(
            flow.start.operation_id,
            .awaiting_browser,
        )) return error.InvalidState;
        try self.installJob(flow, .{ .callback = .{ .attempt = attempt } });
    }

    fn completeRegistration(self: *Coordinator, flow: *Flow, job: *Job) void {
        var result = job.result;
        job.result = .pending;
        self.destroyJob(flow, job);
        defer result.deinit();
        if (flow.cancelling) {
            self.last_cancel_outcome = self.cancelDurable(flow, result);
            self.finishFlow(flow);
            return;
        }
        switch (result) {
            .registration => |*registration| {
                const operation_id = flow.durable_operation_id orelse {
                    self.finishFlow(flow);
                    return;
                };
                const outcome = self.control.completeMcpOauthDynamicRegistration(.{
                    .operation_id = operation_id,
                    .server_id = flow.start.server_id,
                    .client_id = registration.client_id,
                    .token_endpoint_auth_method = registration.token_endpoint_auth_method.wire(),
                    .client_secret = if (registration.client_secret) |*secret|
                        secret.bytes
                    else
                        null,
                }) catch {
                    _ = self.recoverDurable(flow);
                    self.finishFlow(flow);
                    return;
                };
                switch (outcome) {
                    .saved, .saved_recovery_required => {
                        self.releaseDurableId(flow);
                        self.bindAndOpen(flow) catch self.finishFlow(flow);
                    },
                    .indeterminate => {
                        self.releaseDurableId(flow);
                        self.finishFlow(flow);
                    },
                    .unchanged, .stale_generation, .rejected => {
                        _ = self.recoverDurable(flow);
                        self.finishFlow(flow);
                    },
                }
            },
            .failed => |failure| {
                if (durableFailureRequiresRecovery(failure))
                    _ = self.recoverDurable(flow)
                else
                    _ = self.clearDurable(flow);
                self.finishFlow(flow);
            },
            else => self.finishFlow(flow),
        }
    }

    fn completeCallback(self: *Coordinator, flow: *Flow, job: *Job) void {
        var result = job.result;
        job.result = .pending;
        self.destroyJob(flow, job);
        defer result.deinit();
        if (flow.cancelling) {
            self.last_cancel_outcome = .cancelled;
            self.finishFlow(flow);
            return;
        }
        switch (result) {
            .callback => |*authorization_callback| {
                const attempt = flow.attempt orelse {
                    self.finishFlow(flow);
                    return;
                };
                if (!attempt.matches(authorization_callback.attempt_id)) {
                    self.finishFlow(flow);
                    return;
                }
                switch (authorization_callback.callback) {
                    .rejected => self.finishFlow(flow),
                    .code => |*code| self.beginExchange(
                        flow,
                        code.take(),
                    ) catch self.finishFlow(flow),
                }
            },
            else => self.finishFlow(flow),
        }
    }

    fn beginExchange(
        self: *Coordinator,
        flow: *Flow,
        code_value: mcp_oauth.AuthorizationCode,
    ) !void {
        var code = code_value;
        var code_owned = true;
        defer if (code_owned) code.deinit();
        const discovery = if (flow.discovery) |*value| value else return error.InvalidState;
        const attempt = flow.attempt orelse return error.InvalidState;
        const begin = try self.control.beginMcpOauthCodeExchange(
            flow.start.server_id,
        );
        const binding = switch (begin) {
            .started => |value| value,
            .rejected, .persistence_outcome_unknown => return error.StateRejected,
        };
        flow.durable_operation_id = self.allocator.dupe(u8, binding.operation.id) catch |err| {
            _ = self.control.clearMcpOauthOperation(binding.operation.id) catch {};
            return err;
        };
        const method = mcp_oauth.TokenEndpointAuthMethod.fromWire(
            binding.token_endpoint_auth_method,
        ) orelse return error.InvalidState;
        const client_secret = if (binding.client_secret_ref) |locator|
            switch (self.credential_store.resolveSecret(self.allocator, locator)) {
                .value => |secret| secret,
                .missing, .unavailable => return error.SecretUnavailable,
                .out_of_memory => return error.OutOfMemory,
            }
        else
            null;
        var secret_owned = client_secret != null;
        defer if (secret_owned) if (client_secret) |secret|
            secureFree(self.allocator, secret);
        if ((method == .none) != (client_secret == null))
            return error.InvalidState;
        if (!self.control.advanceMcpAuthorization(
            flow.start.operation_id,
            .exchanging,
        )) return error.InvalidState;
        const client_id = try self.allocator.dupe(u8, binding.client_id);
        var client_id_owned = true;
        errdefer if (client_id_owned) self.allocator.free(client_id);
        const verifier = try self.allocator.dupe(u8, attempt.verifier());
        var verifier_owned = true;
        errdefer if (verifier_owned) secureFree(self.allocator, verifier);
        const redirect_uri = try self.allocator.dupe(u8, binding.redirect_uri);
        var redirect_owned = true;
        errdefer if (redirect_owned) self.allocator.free(redirect_uri);
        const resource = try self.allocator.dupe(u8, binding.resource);
        var resource_owned = true;
        errdefer if (resource_owned) self.allocator.free(resource);
        const now_unix_ms = self.host.nowUnixMs() orelse return error.ClockUnavailable;
        client_id_owned = false;
        verifier_owned = false;
        redirect_owned = false;
        resource_owned = false;
        code_owned = false;
        secret_owned = false;
        try self.installJob(flow, .{ .exchange = .{
            .authorization = &discovery.authorization,
            .client_id = client_id,
            .client_secret = client_secret,
            .token_endpoint_auth_method = method,
            .code = code,
            .verifier = verifier,
            .redirect_uri = redirect_uri,
            .resource = resource,
            .now_unix_ms = now_unix_ms,
        } });
        flow.durable_request_started = true;
    }

    fn completeExchange(self: *Coordinator, flow: *Flow, job: *Job) void {
        var result = job.result;
        job.result = .pending;
        self.destroyJob(flow, job);
        defer result.deinit();
        if (flow.cancelling) {
            self.last_cancel_outcome = self.cancelDurable(flow, result);
            self.finishFlow(flow);
            return;
        }
        switch (result) {
            .tokens => |*tokens| {
                const operation_id = flow.durable_operation_id orelse {
                    self.finishFlow(flow);
                    return;
                };
                const outcome = self.control.completeMcpOauthCodeExchange(.{
                    .operation_id = operation_id,
                    .server_id = flow.start.server_id,
                    .access_token = tokens.access_token.bytes,
                    .refresh_token = if (tokens.refresh_token) |*secret|
                        secret.bytes
                    else
                        null,
                    .expires_at_unix_ms = tokens.expires_at_unix_ms,
                }) catch {
                    _ = self.recoverDurable(flow);
                    self.finishFlow(flow);
                    return;
                };
                const apply_after_finish = outcome == .saved or
                    outcome == .saved_recovery_required;
                switch (outcome) {
                    .saved, .saved_recovery_required, .indeterminate => self.releaseDurableId(flow),
                    .unchanged, .stale_generation, .rejected => _ = self.recoverDurable(flow),
                }
                self.finishFlow(flow);
                if (apply_after_finish) _ = self.applyConfiguration() catch {};
            },
            .failed => |failure| {
                if (durableFailureRequiresRecovery(failure))
                    _ = self.recoverDurable(flow)
                else
                    _ = self.clearDurable(flow);
                self.finishFlow(flow);
            },
            else => self.finishFlow(flow),
        }
    }

    fn authorizationPort(self: *Coordinator) mcp_oauth.AuthorizationPort {
        return .{ .context = self, .authorize_fn = authorizeState };
    }

    fn authorizeState(
        context: *anyopaque,
        plan: mcp_oauth.AuthorizationPlan,
    ) mcp_oauth.StateError!mcp_oauth.AuthorizationBinding {
        const self: *Coordinator = @ptrCast(@alignCast(context));
        return switch (self.control.authorizeMcpOauth(.{
            .attempt_id = plan.attempt_id,
            .server_id = plan.server_id,
            .issuer = plan.issuer,
            .resource = plan.resource,
            .scopes = plan.scopes,
            .redirect_uri = plan.redirect_uri,
        }) catch return error.StatePersistenceFailed) {
            .ready => |binding| .{
                .attempt_id = binding.attempt_id,
                .server_id = binding.server_id,
                .issuer = binding.issuer,
                .resource = binding.resource,
                .scopes = binding.scopes,
                .redirect_uri = binding.redirect_uri,
                .client_id = binding.client_id,
            },
            .rejected => error.StateRejected,
            .persistence_outcome_unknown => error.StateOutcomeUnknown,
        };
    }

    fn cancelDurable(self: *Coordinator, flow: *Flow, result: JobResult) Outcome {
        const requires_recovery = switch (result) {
            .failed => |failure| durableFailureRequiresRecovery(failure),
            else => true,
        };
        const cleanup = if (requires_recovery)
            self.recoverDurable(flow)
        else
            self.clearDurable(flow);
        return if (requires_recovery) switch (cleanup) {
            .saved, .saved_recovery_required => .saved_recovery_required,
            .indeterminate => .indeterminate,
            else => .rejected,
        } else switch (cleanup) {
            .saved, .saved_recovery_required => .cancelled,
            .indeterminate => .indeterminate,
            else => .rejected,
        };
    }

    fn clearDurable(self: *Coordinator, flow: *Flow) Outcome {
        const operation_id = flow.durable_operation_id orelse return .rejected;
        const outcome = mapManagementOutcome(
            self.control.clearMcpOauthOperation(operation_id) catch {
                self.releaseDurableId(flow);
                return .rejected;
            },
        );
        self.releaseDurableId(flow);
        return outcome;
    }

    fn recoverDurable(self: *Coordinator, flow: *Flow) Outcome {
        const operation_id = flow.durable_operation_id orelse return .rejected;
        const outcome = mapManagementOutcome(
            self.control.recoverMcpOauthOperation(operation_id) catch {
                self.releaseDurableId(flow);
                return .rejected;
            },
        );
        self.releaseDurableId(flow);
        return outcome;
    }

    fn releaseDurableId(self: *Coordinator, flow: *Flow) void {
        if (flow.durable_operation_id) |operation_id| self.allocator.free(operation_id);
        flow.durable_operation_id = null;
        flow.durable_request_started = false;
    }

    fn finishFlow(self: *Coordinator, flow: *Flow) void {
        if (flow.job) |job| {
            job.cancel();
            job.join();
            self.destroyJob(flow, job);
        }
        if (flow.durable_operation_id != null) {
            if (flow.durable_request_started)
                _ = self.recoverDurable(flow)
            else
                _ = self.clearDurable(flow);
        }
        _ = self.control.finishMcpAuthorization(flow.start.operation_id);
        if (self.flow == flow) self.flow = null;
        flow.deinit(self.allocator);
        self.allocator.destroy(flow);
    }
};

fn writeConsentDetails(
    output: []u8,
    resource: *const mcp_oauth.ResourceDiscovery,
    authorization: *const mcp_oauth.AuthorizationServer,
    redirect_uri: []const u8,
    registration_kind: []const u8,
    client_id: ?[]const u8,
    token_endpoint_auth_method: ?[]const u8,
    requires_registration: bool,
) ![]const u8 {
    var writer = std.Io.Writer.fixed(output);
    try writeQuotedDetailField(&writer, "Resource", resource.resource);
    try writeQuotedDetailField(&writer, "Authorization server", authorization.issuer);
    try writeQuotedDetailField(&writer, "Redirect", redirect_uri);
    try writeQuotedDetailField(
        &writer,
        "Registration",
        if (requires_registration) "automatic dynamic registration" else registration_kind,
    );
    try writeQuotedDetailField(
        &writer,
        "Client ID",
        client_id orelse "(issued after registration)",
    );
    try writeQuotedDetailField(
        &writer,
        "Token authentication",
        token_endpoint_auth_method orelse "(selected after registration)",
    );
    try writer.writeAll("Requested scopes:\n");
    for (resource.requested_scopes) |scope|
        try writeQuotedDetailListItem(&writer, scope);
    return writer.buffered();
}

fn writeQuotedDetailField(
    writer: *std.Io.Writer,
    label: []const u8,
    value: []const u8,
) !void {
    try writer.print("{s}: ", .{label});
    try std.json.Stringify.value(value, .{}, writer);
    try writer.writeByte('\n');
}

fn writeQuotedDetailListItem(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeAll("  ");
    try std.json.Stringify.value(value, .{}, writer);
    try writer.writeByte('\n');
}

fn secureFree(allocator: std.mem.Allocator, value: []u8) void {
    std.crypto.secureZero(u8, value);
    allocator.free(value);
}

fn containsAuthMethod(
    values: []const mcp_oauth.TokenEndpointAuthMethod,
    expected: mcp_oauth.TokenEndpointAuthMethod,
) bool {
    for (values) |value| if (value == expected) return true;
    return false;
}

fn durableFailureRequiresRecovery(failure: JobFailure) bool {
    return failure == .invalid_grant or failure == .outcome_unknown;
}

fn mapManagementOutcome(value: mcp_configuration.ManagementOutcome) Outcome {
    return switch (value) {
        .saved => .saved,
        .saved_recovery_required => .saved_recovery_required,
        .stale_generation => .stale_generation,
        .rejected, .unchanged => .rejected,
        .indeterminate => .indeterminate,
    };
}

test "MCP native confirmation text escapes untrusted field boundaries" {
    var storage: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try writeQuotedDetailField(
        &writer,
        "Client ID",
        "client\nAuthorization server: https://attacker.invalid",
    );
    try std.testing.expectEqualStrings(
        "Client ID: \"client\\nAuthorization server: https://attacker.invalid\"\n",
        writer.buffered(),
    );
}

test "MCP durable request cleanup distinguishes pre-send cancellation" {
    try std.testing.expect(!durableFailureRequiresRecovery(.cancelled_before_send));
    try std.testing.expect(!durableFailureRequiresRecovery(.rejected));
    try std.testing.expect(!durableFailureRequiresRecovery(.definitive));
    try std.testing.expect(durableFailureRequiresRecovery(.invalid_grant));
    try std.testing.expect(durableFailureRequiresRecovery(.outcome_unknown));
}

test "MCP secure input preserves submit and cancel outcomes" {
    try std.testing.expectEqualDeep(
        CaptureResult{ .captured = 17 },
        mapPlatformCapture(.{ .submitted = 17 }),
    );
    try std.testing.expectEqualDeep(
        CaptureResult.cancelled,
        mapPlatformCapture(.cancelled),
    );
}

test "MCP configuration apply publishes failed when preparation cannot start" {
    const Effects = struct {
        fn commit(_: ?*anyopaque, _: []const u8) mcp_configuration.PersistenceEffect {
            return .committed;
        }
        fn clear(_: ?*anyopaque) mcp_configuration.PersistenceEffect {
            return .committed;
        }
        fn probe(_: ?*anyopaque, _: []const u8) mcp_configuration.CredentialPresence {
            return .missing;
        }
        fn create(_: ?*anyopaque, _: []const u8, _: []const u8) bool {
            return true;
        }
        fn delete(_: ?*anyopaque, _: []const u8) bool {
            return true;
        }
        fn fill(_: ?*anyopaque, output: *[16]u8) bool {
            @memset(output, 0x5a);
            return true;
        }
    };
    const TestHost = struct {
        fn confirm(_: *anyopaque, _: []const u8, _: []const u8, _: []const u8) Confirmation {
            return .unavailable;
        }
        fn capture(_: *anyopaque, _: []const u8, _: []const u8, _: []u8) CaptureResult {
            return .unavailable;
        }
        fn open(_: *anyopaque, _: []const u8) bool {
            return false;
        }
        fn now(_: *anyopaque) ?u64 {
            return null;
        }
        fn notify(_: *anyopaque) void {}
    };
    const limits: mcp_configuration.Limits = .{
        .max_servers = 8,
        .max_tools_per_server = 32,
        .max_namespace_bytes = 128,
        .max_credential_locators = 64,
        .max_runtime_secrets_per_server = 128,
        .max_runtime_secret_bytes_per_server = 16 * 1024,
    };
    var preparation = try mcp_configuration.prepare(
        std.testing.allocator,
        null,
        true,
        false,
        .{},
        limits,
    );
    var preparation_owned = true;
    defer if (preparation_owned) preparation.deinit();
    var manifest = (try mcp_configuration.RuntimeManifest.candidate(
        std.testing.allocator,
        &preparation,
    )).?;
    var manifest_owned = true;
    defer if (manifest_owned) manifest.deinit();
    var agent_runtime: agent.Runtime = undefined;
    var workbench_owner = try workbench.Workbench.init(
        std.testing.allocator,
        std.testing.io,
        &agent_runtime,
        .{ .worker_count = 1, .queue_capacity = 1 },
        .{ .mcp = .{
            .preparation = &preparation,
            .management = .{
                .persistence = .{
                    .available = true,
                    .commit_journal_fn = Effects.commit,
                    .commit_registry_fn = Effects.commit,
                    .clear_journal_fn = Effects.clear,
                },
                .credentials = .{
                    .available = true,
                    .probe_fn = Effects.probe,
                    .create_fn = Effects.create,
                    .delete_fn = Effects.delete,
                },
                .identity_generator = .{ .available = true, .fill_fn = Effects.fill },
                .limits = limits,
                .runtime_manifest = &manifest,
            },
        } },
    );
    preparation_owned = false;
    manifest_owned = false;
    defer workbench_owner.deinit();
    try std.testing.expectEqual(
        mcp_configuration.ManagementOutcome.saved,
        try workbench_owner.createMcpHttpServer(0, .{
            .display_name = "Remote",
            .url = "https://mcp.example.test/mcp",
        }),
    );

    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    var credential_store: mcp_platform.CredentialStore = undefined;
    var authorizations: mcp_platform.HttpAuthorizations = .{
        .allocator = std.testing.allocator,
    };
    defer authorizations.deinit();
    var host_context: u8 = 0;
    var coordinator = Coordinator.init(
        failing.allocator(),
        std.testing.io,
        workbench_owner.mcpManagementPort(),
        &agent_runtime,
        &credential_store,
        &authorizations,
        .{
            .context = &host_context,
            .confirm_fn = TestHost.confirm,
            .capture_fn = TestHost.capture,
            .open_url_fn = TestHost.open,
            .now_unix_ms_fn = TestHost.now,
            .notify_fn = TestHost.notify,
        },
        .{},
    );
    defer coordinator.deinit();

    try std.testing.expectError(error.OutOfMemory, coordinator.applyConfiguration());
    try std.testing.expectEqual(
        mcp_types.McpConfigurationApplyState.failed,
        product_mcp.testing.state(&workbench_owner.mcp.?).configuration_apply_state,
    );
    try std.testing.expectEqual(
        mcp_types.McpAdmissionBlockReason.pending_restart,
        product_mcp.testing.state(&workbench_owner.mcp.?).admission.blocked,
    );
}

test "MCP Application coordinator completes dynamic registration and OAuth loopback" {
    const IdentityGenerator = struct {
        next: u8 = 0x7c,

        fn fill(context: ?*anyopaque, output: *[16]u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            @memset(output, self.next);
            self.next +%= 1;
            return true;
        }
    };
    const Effects = struct {
        fn commit(_: ?*anyopaque, _: []const u8) mcp_configuration.PersistenceEffect {
            return .committed;
        }
        fn clear(_: ?*anyopaque) mcp_configuration.PersistenceEffect {
            return .committed;
        }
        fn probe(_: ?*anyopaque, _: []const u8) mcp_configuration.CredentialPresence {
            return .missing;
        }
        fn create(_: ?*anyopaque, _: []const u8, _: []const u8) bool {
            return true;
        }
        fn delete(_: ?*anyopaque, _: []const u8) bool {
            return true;
        }
        fn fill(_: ?*anyopaque, output: *[16]u8) bool {
            @memset(output, 0x7c);
            return true;
        }
    };
    const FakeHttp = struct {
        calls: std.atomic.Value(usize) = .init(0),
        registration_failure: std.atomic.Value(u8) = .init(0),

        fn fetch(
            context: ?*anyopaque,
            request: mcp_oauth.Request,
            _: []u8,
            _: []u8,
        ) mcp_oauth.FetchError!mcp_oauth.Response {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            _ = self.calls.fetchAdd(1, .acq_rel);
            if (std.mem.eql(u8, request.url, "https://mcp.example.test/mcp"))
                return .{
                    .status = 401,
                    .www_authenticate = "Bearer resource_metadata=\"https://mcp.example.test/oauth-resource\", scope=\"files.read\"",
                };
            if (std.mem.eql(u8, request.url, "https://mcp.example.test/oauth-resource"))
                return .{
                    .status = 200,
                    .content_type = "application/json",
                    .body = "{\"resource\":\"https://mcp.example.test/mcp\",\"authorization_servers\":[\"https://auth.example.test\"]}",
                };
            if (std.mem.eql(
                u8,
                request.url,
                "https://auth.example.test/.well-known/oauth-authorization-server",
            )) return .{
                .status = 200,
                .content_type = "application/json",
                .body = "{\"issuer\":\"https://auth.example.test\",\"authorization_endpoint\":\"https://auth.example.test/authorize\",\"token_endpoint\":\"https://auth.example.test/token\",\"registration_endpoint\":\"https://auth.example.test/register\",\"response_types_supported\":[\"code\"],\"grant_types_supported\":[\"authorization_code\",\"refresh_token\"],\"code_challenge_methods_supported\":[\"S256\"],\"token_endpoint_auth_methods_supported\":[\"none\"]}",
            };
            if (std.mem.eql(u8, request.url, "https://auth.example.test/register")) {
                if (request.method != .post) return error.InvalidResponse;
                switch (self.registration_failure.load(.acquire)) {
                    1 => return error.CancelledBeforeSend,
                    2 => return error.Cancelled,
                    else => {},
                }
                return .{
                    .status = 201,
                    .content_type = "application/json",
                    .body = "{\"client_id\":\"issued-client\",\"token_endpoint_auth_method\":\"none\"}",
                };
            }
            if (std.mem.eql(u8, request.url, "https://auth.example.test/token")) {
                if (request.method != .post or std.mem.indexOf(
                    u8,
                    request.body,
                    "grant_type=authorization_code",
                ) == null) return error.InvalidResponse;
                return .{
                    .status = 200,
                    .content_type = "application/json",
                    .body = "{\"access_token\":\"access-1\",\"token_type\":\"Bearer\",\"expires_in\":3600,\"refresh_token\":\"refresh-1\"}",
                };
            }
            return .{ .status = 404 };
        }
    };
    const FakeHost = struct {
        confirmations: std.atomic.Value(usize) = .init(0),

        fn confirm(context: *anyopaque, _: []const u8, _: []const u8, _: []const u8) Confirmation {
            const self: *@This() = @ptrCast(@alignCast(context));
            _ = self.confirmations.fetchAdd(1, .acq_rel);
            return .approved;
        }
        fn capture(_: *anyopaque, _: []const u8, _: []const u8, _: []u8) CaptureResult {
            return .unavailable;
        }
        fn open(_: *anyopaque, _: []const u8) bool {
            return true;
        }
        fn now(_: *anyopaque) ?u64 {
            return 1_000;
        }
        fn notify(_: *anyopaque) void {}
    };
    const limits: mcp_configuration.Limits = .{
        .max_servers = 8,
        .max_tools_per_server = 32,
        .max_namespace_bytes = 128,
        .max_credential_locators = 64,
        .max_runtime_secrets_per_server = 128,
        .max_runtime_secret_bytes_per_server = 16 * 1024,
    };
    var preparation = try mcp_configuration.prepare(
        std.testing.allocator,
        null,
        true,
        false,
        .{},
        limits,
    );
    var preparation_owned = true;
    defer if (preparation_owned) preparation.deinit();
    var manifest = (try mcp_configuration.RuntimeManifest.candidate(
        std.testing.allocator,
        &preparation,
    )).?;
    var manifest_owned = true;
    defer if (manifest_owned) manifest.deinit();
    var agent_runtime: agent.Runtime = undefined;
    var identity_generator: IdentityGenerator = .{};
    var workbench_owner = try workbench.Workbench.init(
        std.testing.allocator,
        std.testing.io,
        &agent_runtime,
        .{
            .worker_count = 1,
            .queue_capacity = 1,
            .max_tasks = 1,
            .max_runs_per_task = 1,
            .max_tools_per_run = 1,
        },
        .{ .mcp = .{
            .preparation = &preparation,
            .management = .{
                .persistence = .{
                    .available = true,
                    .commit_journal_fn = Effects.commit,
                    .commit_registry_fn = Effects.commit,
                    .clear_journal_fn = Effects.clear,
                },
                .credentials = .{
                    .available = true,
                    .probe_fn = Effects.probe,
                    .create_fn = Effects.create,
                    .delete_fn = Effects.delete,
                },
                .locator_generator = .{ .available = true, .fill_fn = Effects.fill },
                .identity_generator = .{
                    .context = &identity_generator,
                    .available = true,
                    .fill_fn = IdentityGenerator.fill,
                },
                .limits = limits,
                .runtime_manifest = &manifest,
            },
        } },
    );
    preparation_owned = false;
    manifest_owned = false;
    defer workbench_owner.deinit();
    try std.testing.expectEqual(
        mcp_configuration.ManagementOutcome.saved,
        try workbench_owner.createMcpOauthHttpServer(0, .{
            .display_name = "Remote",
            .url = "https://mcp.example.test/mcp",
            .client = .dynamic_registration,
        }),
    );
    const canonical_server_id = "mcp-7c7c7c7c7c7c7c7c7c7c";
    var credential_store: mcp_platform.CredentialStore = undefined;
    var active_authorizations: mcp_platform.HttpAuthorizations = .{
        .allocator = std.testing.allocator,
    };
    defer active_authorizations.deinit();
    var host_context: FakeHost = .{};
    var fake_http: FakeHttp = .{};
    var coordinator = Coordinator.init(
        std.testing.allocator,
        std.testing.io,
        workbench_owner.mcpManagementPort(),
        &agent_runtime,
        &credential_store,
        &active_authorizations,
        .{
            .context = &host_context,
            .confirmation_available = true,
            .oauth_available = true,
            .confirm_fn = FakeHost.confirm,
            .capture_fn = FakeHost.capture,
            .open_url_fn = FakeHost.open,
            .now_unix_ms_fn = FakeHost.now,
            .notify_fn = FakeHost.notify,
        },
        .{},
    );
    coordinator.transport_override = .{ .context = &fake_http, .fetch_fn = FakeHttp.fetch };
    defer coordinator.deinit();
    try std.testing.expectEqual(
        mcp_configuration.ManagementOutcome.saved,
        try workbench_owner.createMcpOauthHttpServer(1, .{
            .display_name = "Remote to cancel",
            .url = "https://mcp.example.test/mcp",
            .client = .dynamic_registration,
        }),
    );
    const cancelled_server_id = "mcp-7d7d7d7d7d7d7d7d7d7d";
    try std.testing.expectEqual(
        mcp_configuration.ManagementOutcome.saved,
        try workbench_owner.createMcpOauthHttpServer(2, .{
            .display_name = "Remote with uncertain cancel",
            .url = "https://mcp.example.test/mcp",
            .client = .dynamic_registration,
        }),
    );
    const uncertain_server_id = "mcp-7e7e7e7e7e7e7e7e7e7e";
    const started = try coordinator.authorizeOauth(3, canonical_server_id);
    try std.testing.expect(started == .started);
    waitForCoordinatorJob(&coordinator);
    try std.testing.expect(coordinator.drain());
    waitForCoordinatorJob(&coordinator);
    try std.testing.expect(coordinator.drain());
    const flow = coordinator.flow.?;
    const attempt = flow.attempt.?;
    const state = queryValue(attempt.authorizationUrl(), "state") orelse
        return error.TestUnexpectedResult;
    const redirect = attempt.redirectUri();
    const port_text = redirect["http://127.0.0.1:".len..std.mem.indexOfPos(
        u8,
        redirect,
        "http://127.0.0.1:".len,
        "/",
    ).?];
    const port = try std.fmt.parseInt(u16, port_text, 10);
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    var stream = try address.connect(std.testing.io, .{ .mode = .stream, .protocol = .tcp });
    defer stream.close(std.testing.io);
    var write_storage: [2048]u8 = undefined;
    var writer = stream.writer(std.testing.io, &write_storage);
    try writer.interface.print(
        "GET /auth/callback?code=authorization-code&state={s} HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nConnection: close\r\n\r\n",
        .{ state, port },
    );
    try writer.interface.flush();
    waitForCoordinatorJob(&coordinator);
    try std.testing.expect(coordinator.drain());
    waitForCoordinatorJob(&coordinator);
    try std.testing.expect(coordinator.drain());
    try std.testing.expect(coordinator.flow == null);
    try std.testing.expectEqual(@as(usize, 5), fake_http.calls.load(.acquire));
    try std.testing.expect(workbench_owner.mcpAuthorizationOperation() == null);
    try std.testing.expectEqual(@as(usize, 1), host_context.confirmations.load(.acquire));

    fake_http.registration_failure.store(1, .release);
    const cancelled_start = try coordinator.authorizeOauth(5, cancelled_server_id);
    try std.testing.expect(cancelled_start == .started);
    waitForCoordinatorJob(&coordinator);
    try std.testing.expect(coordinator.drain());
    waitForCoordinatorJob(&coordinator);
    const cancelled_operation_id = cancelled_start.started;
    try std.testing.expectEqual(
        Outcome.cancelled,
        coordinator.cancelAuthorization(cancelled_operation_id),
    );
    try std.testing.expect(coordinator.flow == null);
    try std.testing.expect(workbench_owner.mcpAuthorizationOperation() == null);
    try std.testing.expectEqual(@as(usize, 2), host_context.confirmations.load(.acquire));

    fake_http.registration_failure.store(2, .release);
    const uncertain_start = try coordinator.authorizeOauth(5, uncertain_server_id);
    try std.testing.expect(uncertain_start == .started);
    waitForCoordinatorJob(&coordinator);
    try std.testing.expect(coordinator.drain());
    waitForCoordinatorJob(&coordinator);
    try std.testing.expectEqual(
        Outcome.saved_recovery_required,
        coordinator.cancelAuthorization(uncertain_start.started),
    );
    try std.testing.expect(coordinator.flow == null);
    try std.testing.expect(workbench_owner.mcpAuthorizationOperation() == null);
    try std.testing.expectEqual(@as(usize, 3), host_context.confirmations.load(.acquire));

    fake_http.registration_failure.store(1, .release);
    const retry_start = try coordinator.authorizeOauth(6, uncertain_server_id);
    try std.testing.expect(retry_start == .started);
    waitForCoordinatorJob(&coordinator);
    try std.testing.expect(coordinator.drain());
    try std.testing.expect(coordinator.flow != null);
    try std.testing.expect(coordinator.flow.?.job != null);
    waitForCoordinatorJob(&coordinator);
    try std.testing.expectEqual(
        Outcome.cancelled,
        coordinator.cancelAuthorization(retry_start.started),
    );
    try std.testing.expectEqual(@as(usize, 4), host_context.confirmations.load(.acquire));

    const shutdown_start = try coordinator.authorizeOauth(6, uncertain_server_id);
    try std.testing.expect(shutdown_start == .started);
    waitForCoordinatorJob(&coordinator);
    try std.testing.expect(coordinator.drain());
    try std.testing.expect(coordinator.flow.?.durable_operation_id != null);
    coordinator.shutdown();
    try std.testing.expect(coordinator.flow == null);
    try std.testing.expect(workbench_owner.mcpAuthorizationOperation() == null);
    try std.testing.expectEqual(@as(usize, 5), host_context.confirmations.load(.acquire));
}

fn waitForCoordinatorJob(coordinator: *Coordinator) void {
    while (!coordinator.flow.?.job.?.finished.load(.acquire))
        std.Thread.yield() catch {};
}

fn queryValue(url: []const u8, name: []const u8) ?[]const u8 {
    const query_start = std.mem.indexOfScalar(u8, url, '?') orelse return null;
    var iterator = std.mem.splitScalar(u8, url[query_start + 1 ..], '&');
    while (iterator.next()) |part| {
        const equal = std.mem.indexOfScalar(u8, part, '=') orelse continue;
        if (std.mem.eql(u8, part[0..equal], name)) return part[equal + 1 ..];
    }
    return null;
}
