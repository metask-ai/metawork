//! Application-owned MCP management effects. Product Control remains the sole
//! product-state owner; this coordinator sequences native confirmation,
//! credential submission, browser, loopback, bounded network workers and isolated
//! connection-test Runtimes around the Product Control transaction seams.

const std = @import("std");
const http_execution = @import("app_http_transport");
const builtin = @import("builtin");
const agent = @import("metawork_agent");
const control_ports = @import("metawork_product_control_ports");
const test_fixture = if (builtin.is_test) @import("lifecycle_fixture") else struct {};
const test_control = if (builtin.is_test) test_fixture.product_control else struct {};
const product_mcp = @import("metawork_product_mcp");
const mcp_configuration = product_mcp.contract;
const mcp_types = product_mcp;
const mcp_oauth = @import("metawork_mcp_oauth");
const mcp_platform = @import("metawork_mcp_platform");
const mcp_startup = @import("mcp_startup.zig");
const app_platform = @import("platform.zig");

pub const InstallationTestTransportRequest = if (builtin.is_test) mcp_oauth.Request else void;
pub const InstallationTestTransportResponse = if (builtin.is_test) mcp_oauth.Response else void;
pub const InstallationTestFetchError = if (builtin.is_test) mcp_oauth.FetchError else error{};

const connection_approval_details_bytes: usize = mcp_configuration.max_store_bytes * 6 + 4096;
const oauth_consent_details_bytes: usize = mcp_oauth.Limits.metadata_body_bytes * 6 + 4096;

const Dialog = control_ports.NativeDialog;
pub const Approval = control_ports.McpApproval;

pub const Host = struct {
    context: *anyopaque,
    confirmation_available: bool = false,
    capture_available: bool = false,
    oauth_available: bool = false,
    request_dialog_fn: *const fn (*anyopaque, u64, Dialog.Message, *const Dialog.Completion) anyerror!u64,
    cancel_dialog_fn: *const fn (*anyopaque, u64) void = cancelUnavailable,

    open_url_fn: *const fn (*anyopaque, []const u8) bool,
    now_unix_ms_fn: *const fn (*anyopaque) ?u64,
    notify_fn: *const fn (*anyopaque) void,

    fn cancelUnavailable(_: *anyopaque, _: u64) void {}

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
        // Credential entry is provided by the Renderer on every desktop platform.
        .capture_available = true,
        .oauth_available = platform.supportsMcpExternalAuthorization(),
        .request_dialog_fn = platformRequest,
        .cancel_dialog_fn = platformCancel,
        .open_url_fn = platformOpenUrl,
        .now_unix_ms_fn = platformNowUnixMs,
        .notify_fn = platformNotify,
    };
}

fn platformRequest(context: *anyopaque, id: u64, message: Dialog.Message, completion: *const Dialog.Completion) !u64 {
    return app_platform.Adapter.requestDialog(context, id, 0, .{ .message = message }, completion);
}
fn platformCancel(context: *anyopaque, handle: u64) void {
    app_platform.Adapter.cancelDialog(context, handle);
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

pub const Outcome = control_ports.McpHostOutcome;

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
    not_sent,
    cancelled_before_send,
    rejected,
    invalid_grant,
    outcome_unknown,
};

const DiscoveryResult = struct {
    resource: mcp_oauth.ResourceDiscovery,
    authorization: mcp_oauth.AuthorizationServer,
    private_resource: bool = false,

    fn deinit(self: *DiscoveryResult) void {
        self.authorization.deinit();
        if (self.private_resource) std.crypto.secureZero(u8, @constCast(self.resource.resource));
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
    private_resource: bool = false,
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
    http_engine: ?*http_execution.Engine = null,
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
            .http_engine = self.http_engine.?,
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
        defer if (resource_owned) {
            if (input.private_resource) std.crypto.secureZero(u8, @constCast(resource.resource));
            resource.deinit();
        };
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
            .private_resource = input.private_resource,
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
                error.NetworkBeforeSend, error.DeadlineExceededBeforeSend, error.InvalidResponseBeforeSend => .not_sent,
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
                error.NetworkBeforeSend, error.DeadlineExceededBeforeSend, error.InvalidResponseBeforeSend => .not_sent,
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
        .discovery => |value| secureFree(allocator, value.endpoint),
        .registration => |value| allocator.free(value.redirect_uri),
        .callback => {},
        .exchange => |*value| {
            allocator.free(value.client_id);
            if (value.client_secret) |secret| secureFree(allocator, secret);
            value.code.deinit();
            secureFree(allocator, value.verifier);
            allocator.free(value.redirect_uri);
            secureFree(allocator, value.resource);
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
    private_resource_identity: ?[35]u8 = null,
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
    http_engine: ?*http_execution.Engine = null,
    allocator: std.mem.Allocator,
    host: Host,
    io: std.Io,
    draft_http_observation: mcp_platform.DraftHttpObservation = .{},
    detection: mcp_configuration.HttpDraftDetection = .failed,
    target: Target,
    runtime: ?*agent.Runtime,
    authorizations: mcp_platform.HttpAuthorizations,
    result: ConnectionTestResult = .{},
    finished: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    const Target = union(enum) {
        saved: []const u8,
        draft: struct {
            endpoint: []u8,
            context: *anyopaque,
            complete: *const fn (*anyopaque, mcp_configuration.HttpDraftDetection) void,
        },
        verified: VerifiedDraft,
    };

    pub const VerifiedDraft = struct {
        mutation: mcp_configuration.MutationPreparation,
        generation: u64,
        context: *anyopaque,
        active: *const fn (*anyopaque) bool,
        complete: *const fn (*anyopaque, ?mcp_configuration.CreateResult) void,
    };

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
        if (self.target == .draft) self.detection = self.detectDraft();
        self.finished.store(true, .release);
        self.host.notify();
    }

    fn detectDraft(self: *ConnectionTestJob) mcp_configuration.HttpDraftDetection {
        if (self.result.outcome == .connected) return .connected;
        const status = self.draft_http_observation.status;
        if (status != 401 and status != 403) {
            const observation = &self.draft_http_observation;
            return if (observation.redirect_len == 0) .failed else .{ .redirected = observation.redirect[0..observation.redirect_len] };
        }
        const fallback: mcp_configuration.HttpDraftDetection = if (status == 401) .authentication_required else .access_denied;
        var cancellation: mcp_oauth.Cancellation = .{ .io = self.io };
        var http: mcp_oauth.StdHttpTransport = .{
            .http_engine = self.http_engine orelse return fallback,
            .cancellation = &cancellation,
            .deadline = std.Io.Clock.Timestamp.fromNow(self.io, .{ .raw = .fromSeconds(5), .clock = .awake }),
        };
        const transport = http.transport();
        var resource = mcp_oauth.discoverResourceWithChallengeEffect(self.allocator, transport, self.target.draft.endpoint, self.draft_http_observation.header()) catch return fallback;
        defer resource.deinit();
        var authorization = mcp_oauth.discoverAuthorizationServer(self.allocator, transport, &resource, resource.authorization_servers[0]) catch return fallback;
        defer authorization.deinit();
        return if (authorization.registration_endpoint != null) .oauth_automatic else .oauth_existing;
    }

    fn join(self: *ConnectionTestJob) void {
        const thread = self.thread orelse return;
        thread.join();
        self.thread = null;
    }

    fn deinit(self: *ConnectionTestJob) void {
        std.debug.assert(self.thread == null and self.runtime == null);
        switch (self.target) {
            .saved => |id| self.allocator.free(id),
            .draft => |draft| {
                secureFree(self.allocator, draft.endpoint);
                std.crypto.secureZero(u8, &self.draft_http_observation.challenge);
                std.crypto.secureZero(u8, &self.draft_http_observation.redirect);
            },
            .verified => |*verified| verified.mutation.deinit(),
        }
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
    unknown,
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
    processes: mcp_platform.StdioObservations,
    allowlists: []agent.McpServerAllowlist,
    budget: ?*mcp_platform.CatalogBudget = null,
    existing_member_count: usize = 0,
    initial_installation: bool = false,
    product_state_installed: bool = false,
    result: ConfigurationApplyResult = .pending,
    finished: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    fn start(self: *ConfigurationApplyJob) std.Thread.SpawnError!void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn run(self: *ConfigurationApplyJob) void {
        if (self.budget) |budget| budget.begin(self.existing_member_count, self.initial_installation) catch {
            self.publish(.failed);
            return;
        };
        defer if (self.budget) |budget| budget.end();
        const input = if (self.input) |*value| value else {
            self.publish(.failed);
            return;
        };
        const apply = self.runtime.applyMcpConfiguration(input) catch |err| {
            self.publish(if (err == error.McpConfigurationApplyUncertain) .unknown else .failed);
            return;
        };
        if (apply != .applied) {
            self.publish(.rejected);
            return;
        }
        if (self.budget) |budget| budget.applied();
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
            .pending, .rejected, .failed, .unknown => {},
        }
        if (self.input) |*input| input.deinit();
        self.authorizations.deinit();
        self.processes.deinit();
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

const InstallationJob = struct {
    http_engine: ?*http_execution.Engine = null,
    allocator: std.mem.Allocator,
    io: std.Io,
    host: Host,
    server: [mcp_configuration.created_identity_bytes]u8,
    revision: u64,
    request: agent.McpParsedInstallRequest,
    transport_override: ?mcp_oauth.Transport,
    cancellation: mcp_oauth.Cancellation,
    values: [16]?[]u8 = @splat(null),
    failed: bool = false,
    finished: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    fn run(self: *@This()) void {
        defer {
            self.finished.store(true, .release);
            self.host.notify();
        }
        var http: mcp_oauth.StdHttpTransport = undefined;
        const transport = self.transport_override orelse configured: {
            const engine = self.http_engine orelse {
                self.failed = true;
                return;
            };
            http = .{ .http_engine = engine, .cancellation = &self.cancellation, .deadline = .fromNow(self.io, .{ .clock = .awake, .raw = .fromSeconds(30) }) };
            break :configured http.transport();
        };
        for (self.request.parsed.value.credentials, 0..) |plan, i| {
            if (self.cancellation.isCancelled()) {
                self.failed = true;
                return;
            }
            if (plan.kind != .http_json) continue;
            self.values[i] = mcp_oauth.fetchInstallationCredential(self.allocator, transport, plan.url.?, plan.jsonPointer.?, mcp_platform.max_credential_secret_bytes) catch {
                self.failed = true;
                return;
            };
        }
    }
    fn deinit(self: *@This()) void {
        if (self.thread) |thread| thread.join();
        for (self.values) |value| if (value) |bytes| secureFree(self.allocator, bytes);
        self.request.deinit();
        const allocator = self.allocator;
        allocator.destroy(self);
    }
};

const ConfirmationState = struct {
    id: u64,
    page_token: u64 = 0,
    dialog_handle: u64 = 0,
    details: []u8,
    title: []const u8,
    approval_label: []const u8,
    offset: usize = 0,
    end: usize = 0,
    kind: union(enum) {
        approval: struct { operation: u64, generation: u64, server: []u8, completion: *const Approval.Completion },
        oauth: []u8,
        installation: struct { server: [mcp_configuration.created_identity_bytes]u8, revision: u64 },
    },
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
    installation_job: ?*InstallationJob = null,
    installation_server: ?[mcp_configuration.created_identity_bytes]u8 = null,
    installation_request_id: u64 = 0,
    installation_active_since: ?std.Io.Timestamp = null,
    installation_elapsed: u32 = 0,
    connection_test_job: ?*ConnectionTestJob = null,
    active_processes: ?mcp_platform.StdioObservations = null,
    process_attempt: u64 = 0,
    configuration_apply_job: ?*ConfigurationApplyJob = null,
    apply_pending: bool = false,
    last_cancel_outcome: ?Outcome = null,
    stopping: bool = false,
    confirmation: ?ConfirmationState = null,
    next_confirmation_id: u64 = 1,
    dialog_completion: Dialog.Completion = undefined,

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
        if (self.confirmation != null) return .rejected;
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
        errdefer if (start_owned) {
            _ = self.control.finishMcpAuthorization(start.operation_id);
        };
        if (start.private_endpoint) |endpoint|
            start.endpoint = try mcp_configuration.resolvePrivateEndpoint(start.arena.allocator(), endpoint, self.credential_store.resolver(), mcp_startup.configuration_limits);
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
        if (self.confirmation != null) return .busy;
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

        return self.startConnectionTest(&preparation, .{ .saved = server_id });
    }

    pub fn probeHttpDraft(self: *Coordinator, preparation: *const mcp_configuration.Preparation, context: *anyopaque, complete: *const fn (*anyopaque, mcp_configuration.HttpDraftDetection) void) !bool {
        if (self.draftCheckBusy()) return false;
        const endpoint = try self.allocator.dupe(u8, preparation.registry.?.value.servers[preparation.registry.?.value.servers.len - 1].transport.url.?);
        var started = false;
        defer if (!started) secureFree(self.allocator, endpoint);
        started = try self.startConnectionTest(preparation, .{ .draft = .{ .endpoint = endpoint, .context = context, .complete = complete } }) == .started;
        return started;
    }

    pub const VerifiedDraft = ConnectionTestJob.VerifiedDraft;

    pub fn verifyAndAddHttpDraft(self: *Coordinator, draft: *VerifiedDraft) !bool {
        if (self.draftCheckBusy() or draft.mutation != .prepared) return false;
        var preparation = (try draft.mutation.prepared.httpDraftPreparation(mcp_startup.configuration_limits)) orelse return false;
        defer preparation.deinit();
        if (try self.startConnectionTest(&preparation, .{ .verified = draft.* }) != .started) return false;
        draft.mutation = .rejected;
        return true;
    }

    fn draftCheckBusy(self: *const Coordinator) bool {
        return self.stopping or self.confirmation != null or self.connection_test_job != null or self.configuration_apply_job != null or self.flow != null;
    }

    fn startConnectionTest(self: *Coordinator, preparation: *const mcp_configuration.Preparation, target: ConnectionTestJob.Target) !ConnectionTestStartOutcome {
        const job = try self.allocator.create(ConnectionTestJob);
        var started = false;
        defer if (!started) self.allocator.destroy(job);
        job.* = .{
            .http_engine = self.host_environment.http_engine,
            .allocator = self.allocator,
            .host = self.host,
            .io = self.io,
            .target = switch (target) {
                .saved => |id| .{ .saved = try self.allocator.dupe(u8, id) },
                else => target,
            },
            .runtime = null,
            .authorizations = .{ .allocator = self.allocator },
        };
        defer if (!started and job.target == .saved) self.allocator.free(job.target.saved);
        // Diagnostic Runtimes do not borrow the formal Runtime's catalog budget.
        var test_environment = self.host_environment;
        test_environment.catalog_budget = null;
        if (target == .draft) test_environment.draft_http_observation = &job.draft_http_observation;
        var runtime_build = mcp_platform.buildRuntime(self.io, self.allocator, preparation, test_environment) catch return .unavailable;
        defer runtime_build.deinit();
        const input = if (runtime_build.input) |*value| value else return .unavailable;
        const runtime = agent.Runtime.init(self.io, self.allocator, .{ .max_sessions = 1, .mcp_input = input }) catch return .unavailable;
        job.runtime = runtime;
        job.authorizations = runtime_build.takeAuthorizations();
        defer if (!started) {
            runtime.shutdown() catch {};
            runtime.deinit();
            job.authorizations.deinit();
        };
        if (job.target == .saved) try self.control.beginMcpConnectionTest(job.target.saved);
        job.start() catch {
            if (job.target == .saved) self.control.completeMcpConnectionTest(job.target.saved, .failed, 0, 0);
            return .unavailable;
        };
        started = true;
        self.connection_test_job = job;
        return .started;
    }

    pub fn applyConfiguration(self: *Coordinator, intent: mcp_configuration.RuntimeApplyIntent) !ConfigurationApplyStartOutcome {
        if (self.confirmation != null) return .busy;
        if (self.stopping) return .unavailable;
        if (self.configuration_apply_job != null or self.connection_test_job != null or
            self.flow != null) return .busy;
        if (self.active_authorizations.pending_slots.len != 0) return .busy;
        const inspection = self.control.inspectMcpDesiredConfiguration() orelse return .unavailable;
        if (inspection.health != .ready) return .unavailable;
        const generation = inspection.desired_generation orelse return .rejected;
        if (generation == 0) return .rejected;
        var step = (self.control.prepareMcpConfigurationStep(generation, intent) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.McpManagementUnavailable => return .unavailable,
            else => return .busy,
        }) orelse {
            self.apply_pending = false;
            if (self.control.inspectMcpDesiredConfiguration()) |current| if (current.authorization_recovery_pending) {
                self.host.notify();
                return .started;
            };
            return .rejected;
        };
        self.apply_pending = false;
        var preparation_owned = true;
        defer if (preparation_owned) step.deinit();
        var apply_state_owned = true;
        defer if (apply_state_owned) self.control.failMcpConfigurationApply(generation, .preparation);

        const registry_storage = try self.allocator.alloc(u8, mcp_configuration.max_store_bytes);
        defer self.allocator.free(registry_storage);
        const registry_bytes = self.control.writeMcpDesiredConfiguration(generation, registry_storage) catch return .unavailable;
        var credentials = try mcp_configuration.prepare(self.allocator, registry_bytes, true, false, self.credential_store.resolver(), mcp_startup.configuration_limits);
        defer credentials.deinit();
        const desired = if (credentials.registry) |registry| registry.value else return .unavailable;
        var candidate_eligible = step.candidate_id == null;
        for (desired.servers, credentials.server_states) |server, *state| {
            if (step.candidate_id != null and std.mem.eql(u8, server.id, step.candidate_id.?)) {
                candidate_eligible = state.* == .eligible;
            } else state.* = .disabled;
        }
        if (!candidate_eligible) {
            self.apply_pending = true;
            self.host.notify();
            return .rejected;
        }
        self.process_attempt = std.math.add(u64, self.process_attempt, 1) catch return .unavailable;
        var environment = self.host_environment;
        environment.process_attempt = self.process_attempt;
        environment.process_notifier = .{ .context = self.host.context, .notify_fn = self.host.notify_fn };
        var runtime_build = try mcp_platform.buildRuntime(self.io, self.allocator, &credentials, environment);
        defer runtime_build.deinit();
        const empty_processes: mcp_platform.StdioObservations = .{ .allocator = self.allocator };
        for ((runtime_build.processes orelse empty_processes).slots) |slot| {
            _ = try self.control.observeMcpProcess(slot.snapshot());
        }
        var processes = try (self.active_processes orelse empty_processes).compose(runtime_build.processes orelse empty_processes, step.member_ids, step.candidate_id);
        var processes_owned = true;
        defer if (processes_owned) processes.deinit();
        var input = try self.agent_runtime.prepareMcpMembership(generation, if (runtime_build.input) |*value| value else null, step.member_ids);
        var input_owned = true;
        defer if (input_owned) input.deinit();
        var authorizations = try self.active_authorizations.compose(&runtime_build.authorizations, step.member_ids, step.candidate_id);
        var authorizations_owned = true;
        defer if (authorizations_owned) authorizations.deinit();
        authorizations.setRuntimeAuthFailureNotifier(.{ .context = self.host.context, .notify_fn = self.host.notify_fn });
        credentials.releaseCredentials();
        var manifest = (try mcp_configuration.RuntimeManifest.candidate(self.allocator, &step.preparation)) orelse return .unavailable;
        var manifest_owned = true;
        defer if (manifest_owned) manifest.deinit();
        const allowlists = try self.allocator.alloc(agent.McpServerAllowlist, step.grants.len);
        errdefer self.allocator.free(allowlists);
        for (step.grants, allowlists) |grant, *allowlist|
            allowlist.* = .{ .id = grant.id, .tools = grant.tools };
        const job = try self.allocator.create(ConfigurationApplyJob);
        errdefer self.allocator.destroy(job);
        job.* = .{
            .allocator = self.allocator,
            .host = self.host,
            .generation = generation,
            .runtime = self.agent_runtime,
            .preparation = step.preparation,
            .manifest = manifest,
            .input = input,
            .authorizations = authorizations,
            .processes = processes,
            .allowlists = allowlists,
            .budget = self.host_environment.catalog_budget,
            .existing_member_count = step.member_ids.len - @intFromBool(step.target.kind == .add),
            .initial_installation = if (step.preparation.registry) |registry| blk: {
                for (registry.value.servers) |server| if (std.mem.eql(u8, server.id, step.target.id()) and mcp_configuration.initialInstallation(server)) break :blk true;
                break :blk false;
            } else false,
        };
        // Ownership has moved even if thread creation fails.
        processes_owned = false;
        preparation_owned = false;
        input_owned = false;
        authorizations_owned = false;
        manifest_owned = false;
        job.start() catch {
            job.deinit();
            return .unavailable;
        };
        self.configuration_apply_job = job;
        apply_state_owned = false;
        return .started;
    }

    fn installationValue(self: *Coordinator, id: []const u8, name: []const u8) ![]u8 {
        const observed = self.control.installation(id) orelse return error.InvalidState;
        const slot = for (observed.credentials) |slot| {
            if (std.mem.eql(u8, slot.name, name)) break slot;
        } else return error.InvalidState;
        const locator = slot.credential_ref orelse return error.CredentialUnavailable;
        const resolver = self.credential_store.resolver();
        return switch (resolver.resolve_fn(resolver.context, self.allocator, locator)) {
            .value => |value| value,
            else => error.CredentialUnavailable,
        };
    }

    fn prepareInstallationConnection(self: *Coordinator, observation: control_ports.McpInstallObservation, request: agent.McpInstallRequest) !void {
        const id = observation.server_id;
        const d = request.connection;
        // Framed headers/environment are separate from the raw protected source.
        for (request.credentials) |plan| {
            if (plan.target == .endpoint) continue;
            const raw = try self.installationValue(&id, plan.slot);
            defer secureFree(self.allocator, raw);
            const value = try std.fmt.allocPrint(self.allocator, "{s}{s}{s}", .{ plan.prefix, raw, plan.suffix });
            defer secureFree(self.allocator, value);
            const current = self.control.installation(&id) orelse return error.InvalidState;
            const outcome = switch (plan.target) {
                .header, .environment => try self.control.captureMcpStaticSecret(current.generation, .{ .server_id = &id, .slot_name = plan.name.?, .secret = value }),
                .client_secret => try self.control.captureMcpOauthClientSecret(current.generation, .{ .server_id = &id, .secret = value }),
                .endpoint => unreachable,
            };
            if (outcome != .saved and outcome != .saved_recovery_required) return error.CredentialUnavailable;
        }
        var endpoint_bytes: [4096]u8 = undefined;
        defer std.crypto.secureZero(u8, &endpoint_bytes);
        var writer = std.Io.Writer.fixed(&endpoint_bytes);
        var parts: std.array_list.Managed(mcp_configuration.EndpointPartInput) = .init(self.allocator);
        defer parts.deinit();
        if (d.endpoint) |template| {
            var rest = template;
            while (std.mem.indexOf(u8, rest, "{credential:")) |start| {
                if (start != 0) {
                    const before = writer.buffered().len;
                    try writer.writeAll(rest[0..start]);
                    try parts.append(.{ .value = writer.buffered()[before..], .is_credential = false });
                }
                const tail = rest[start + "{credential:".len ..];
                const end = std.mem.indexOfScalar(u8, tail, '}') orelse return error.InvalidState;
                const name = tail[0..end];
                const plan = for (request.credentials) |plan| {
                    if (plan.target == .endpoint and std.mem.eql(u8, plan.slot, name)) break plan;
                } else return error.InvalidState;
                const raw = try self.installationValue(&id, name);
                defer secureFree(self.allocator, raw);
                const value = try std.fmt.allocPrint(self.allocator, "{s}{s}{s}", .{ plan.prefix, raw, plan.suffix });
                defer secureFree(self.allocator, value);
                const before = writer.buffered().len;
                try std.Uri.Component.percentEncode(&writer, value, struct {
                    fn unreserved(byte: u8) bool {
                        return std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "-._~", byte) != null;
                    }
                }.unreserved);
                try parts.append(.{ .value = writer.buffered()[before..], .is_credential = true });
                rest = tail[end + 1 ..];
            }
            if (rest.len != 0) {
                const before = writer.buffered().len;
                try writer.writeAll(rest);
                try parts.append(.{ .value = writer.buffered()[before..], .is_credential = false });
            }
        }
        const current = self.control.installation(&id) orelse return error.InvalidState;
        const connection: mcp_configuration.InstallationConnection = if (std.mem.eql(u8, d.transport, "stdio")) .{ .stdio = .{
            .display_name = d.displayName,
            .command = d.command.?,
            .arguments = d.arguments,
            .cwd = d.cwd,
            .auth_mode = if (std.mem.eql(u8, d.authMode, "static")) .static else .none,
            .environment_names = d.environmentNames,
        } } else if (std.mem.eql(u8, d.authMode, "oauth")) .{ .oauth = .{ .display_name = d.displayName, .url = writer.buffered(), .sensitive_endpoint = true, .endpoint_parts = parts.items, .client = .dynamic_registration } } else .{ .http = .{
            .display_name = d.displayName,
            .url = writer.buffered(),
            .sensitive_endpoint = true,
            .endpoint_parts = parts.items,
            .auth_mode = if (std.mem.eql(u8, d.authMode, "static")) .static else .none,
            .header_names = d.headerNames,
        } };
        const outcome = try self.control.replaceInstallation(current.generation, &id, current.revision, connection);
        if (outcome != .saved and outcome != .saved_recovery_required and outcome != .unchanged) return error.InvalidState;
    }

    fn confirmInstallation(self: *Coordinator, observation: control_ports.McpInstallObservation) !void {
        if (!self.host.confirmation_available) return;
        const operation = observation;
        var request = try self.installationRequest(operation.request_refs);
        defer request.deinit();
        var storage: [32 * 1024]u8 = undefined;
        var writer = std.Io.Writer.fixed(&storage);
        try writer.writeAll("Allow this MCP installation and its credential destinations?\nThe saved connection will reconnect or start automatically on future launches.\n");
        try writeQuotedDetailField(&writer, "Installation source", operation.source_origin);
        if (observation.endpoint_origin) |origin| try writeQuotedDetailField(&writer, "Use credentials on", origin);
        for (request.parsed.value.credentials) |plan| if (plan.url) |url| {
            const origin = mcp_configuration.endpointOrigin(url, 4096) orelse return error.InvalidState;
            try writeQuotedDetailField(&writer, "Get credentials from", origin);
        };
        if (request.parsed.value.connection.command) |command| {
            try writeQuotedDetailField(&writer, "Command", command);
            for (request.parsed.value.connection.arguments) |argument| try writeQuotedDetailField(&writer, "Argument", argument);
            if (request.parsed.value.connection.cwd) |cwd| try writeQuotedDetailField(&writer, "Working directory", cwd);
        }
        const details = try self.allocator.dupe(u8, writer.buffered());
        errdefer self.allocator.free(details);
        self.confirmation = .{ .id = try self.nextConfirmationId(), .details = details, .title = "Authorize MCP installation", .approval_label = "Allow installation", .kind = .{ .installation = .{
            .server = observation.server_id,
            .revision = operation.revision,
        } } };
        self.requestConfirmationPage() catch |err| {
            self.confirmation = null;
            return err;
        };
    }

    fn installationElapsed(self: *Coordinator) u32 {
        const since = self.installation_active_since orelse return self.installation_elapsed;
        const elapsed = @max(@as(i96, 0), std.Io.Timestamp.now(self.io, .awake).nanoseconds - since.nanoseconds);
        return @intCast(@min(@as(i96, mcp_configuration.installation_active_budget_ms), self.installation_elapsed + @divFloor(elapsed, std.time.ns_per_ms)));
    }

    fn installationPhase(self: *Coordinator, phase: mcp_configuration.InstallationPhase, failure: ?mcp_configuration.InstallationFailure) !bool {
        const id = self.installation_server orelse return false;
        const observation = self.control.installation(&id) orelse return false;
        const operation = observation;
        const elapsed = self.installationElapsed();
        const result = try self.control.updateInstallation(observation.generation, .{ .server_id = &id, .expected_revision = operation.revision, .phase = phase, .failure = failure, .active_elapsed_ms = elapsed });
        if (result != .saved and result != .saved_recovery_required) return false;
        self.installation_elapsed = elapsed;
        self.installation_active_since = if (phase == .preparing or phase == .acquiring_credentials or phase == .connecting) .now(self.io, .awake) else null;
        self.host.notify();
        return true;
    }

    fn failInstallation(self: *Coordinator, failure: mcp_configuration.InstallationFailure) !void {
        if (self.installation_server) |id| if (self.control.installation(&id)) |observed| {
            if (observed.phase.active()) _ = try self.installationPhase(.failed, failure);
        };
    }

    fn installationRequest(self: *Coordinator, request_refs: []const []const u8) !agent.McpParsedInstallRequest {
        var bytes: [agent.max_mcp_installation_bytes]u8 = undefined;
        defer std.crypto.secureZero(u8, &bytes);
        var writer = std.Io.Writer.fixed(&bytes);
        const resolver = self.credential_store.resolver();
        for (request_refs) |locator| {
            const value = switch (resolver.resolve_fn(resolver.context, self.allocator, locator)) {
                .value => |value| value,
                else => return error.CredentialUnavailable,
            };
            defer secureFree(self.allocator, value);
            try writer.writeAll(value);
        }
        return agent.parseMcpInstallRequest(self.allocator, writer.buffered());
    }

    fn installationRetry(self: *Coordinator, pending: control_ports.McpInstallIngress, request: agent.McpInstallRequest) !?[mcp_configuration.created_identity_bytes]u8 {
        if (request.serverId != null) return null;
        var candidate: ?[mcp_configuration.created_identity_bytes]u8 = null;
        var index: usize = 0;
        while (try self.control.nextInstallationRetryCandidate(pending.task_id, &index)) |retired| {
            var original = try self.installationRequest(retired.request_refs);
            defer original.deinit();
            if (!std.mem.eql(u8, original.parsed.value.sourceUrl, request.sourceUrl)) continue;
            if (candidate != null) return error.AmbiguousInstallationTarget;
            candidate = retired.server_id;
        }
        return candidate;
    }

    fn drainInstallation(self: *Coordinator) !bool {
        if (self.stopping) return false;
        if (self.installation_server == null) {
            if (self.control.installation(null)) |observed| {
                self.installation_server = observed.server_id;
                self.installation_elapsed = observed.active_elapsed_ms;
            } else if (self.control.pendingInstallation()) |pending| {
                var request = agent.parseMcpInstallRequest(self.allocator, pending.json) catch {
                    self.control.releaseInstallation(pending.id);
                    return true;
                };
                defer request.deinit();
                if (self.configuration_apply_job != null) return false;
                const retry = self.installationRetry(pending, request.parsed.value) catch {
                    self.control.releaseInstallation(pending.id);
                    return true;
                };
                const created = self.control.startInstallation(pending.id, if (retry) |*id| id else null) catch |err| switch (err) {
                    error.McpManagementBusy => return false, // Refresh completion will wake us; retain the request.
                    else => return err,
                };
                if (created.outcome != .saved and created.outcome != .saved_recovery_required) {
                    self.control.releaseInstallation(pending.id);
                    return true;
                }
                self.installation_server = created.server_id;
                self.installation_request_id = pending.id;
                self.host.notify();
                return true;
            } else return false;
        }
        const id = self.installation_server.?;
        const observed = self.control.installation(&id) orelse {
            if (self.installation_request_id != 0) self.control.releaseInstallation(self.installation_request_id);
            self.installation_server = null;
            self.installation_request_id = 0;
            self.installation_active_since = null;
            return true;
        };
        const operation = observed;
        if (!observed.source_available and operation.phase.active()) {
            _ = try self.control.cancelInstallation(&id, operation.revision);
            return true;
        }
        if (self.installation_job) |job| {
            if (!operation.phase.active() or !observed.source_available) job.cancellation.cancel();
            if (!job.finished.load(.acquire)) return false;
            self.installation_job = null;
            defer job.deinit();
            if (!operation.phase.active() or operation.revision != job.revision or !observed.source_available) return true;
            if (job.failed) {
                try self.failInstallation(.credential_request_failed);
                return true;
            }
            for (job.request.parsed.value.credentials, 0..) |plan, i| if (job.values[i]) |value| {
                const current = self.control.installation(&id) orelse return error.InvalidState;
                const outcome = try self.control.captureInstallation(current.generation, &id, plan.slot, false, value);
                if (outcome != .saved and outcome != .saved_recovery_required) return error.CredentialUnavailable;
            };
            _ = try self.installationPhase(.preparing, null);
            return true;
        }
        if (!operation.phase.active() and operation.phase != .ready) {
            if (self.confirmation) |pending| if (pending.kind == .installation and std.mem.eql(u8, &pending.kind.installation.server, &id)) self.cancelConfirmation();
            if (self.flow) |flow| if (std.mem.eql(u8, flow.start.server_id, &id)) {
                _ = self.cancelAuthorization(flow.start.operation_id);
            };
        }
        if (operation.phase == .cancelled) {
            if (operation.stop_pending) {
                _ = try self.control.cancelInstallation(&id, operation.revision);
                return false;
            }
        }
        if (!operation.phase.active()) {
            if (self.installation_request_id != 0) self.control.releaseInstallation(self.installation_request_id);
            self.installation_server = null;
            self.installation_request_id = 0;
            self.installation_active_since = null;
            return true;
        }
        if (self.configuration_apply_job != null) return false;
        if (operation.phase == .needs_oauth) {
            // Network work consumes the installation budget; consent and the
            // browser callback wait do not. Persist elapsed time on transitions.
            const working = if (self.flow) |flow| if (flow.job) |job| job.input != .callback else false else false;
            if (working and self.installation_active_since == null) self.installation_active_since = .now(self.io, .awake);
            if (!working and self.installation_active_since != null) {
                self.installation_elapsed = self.installationElapsed();
                self.installation_active_since = null;
            }
        }
        if (self.installationElapsed() >= mcp_configuration.installation_active_budget_ms) {
            try self.failInstallation(.timeout);
            return true;
        }
        switch (operation.action) {
            .confirm => {
                if (self.confirmation == null) try self.confirmInstallation(observed);
                return false;
            },
            .fetch_credentials => {
                var parsed = try self.installationRequest(operation.request_refs);
                var owned = true;
                defer if (owned) parsed.deinit();
                if (!try self.installationPhase(.acquiring_credentials, null)) return false;
                const next = self.control.installation(&id) orelse return error.InvalidState;
                const job = try self.allocator.create(InstallationJob);
                job.* = .{ .http_engine = self.host_environment.http_engine, .allocator = self.allocator, .io = self.io, .host = self.host, .server = id, .revision = next.revision, .request = parsed, .transport_override = self.transport_override, .cancellation = .init(self.io) };
                owned = false;
                errdefer job.deinit();
                job.thread = try std.Thread.spawn(.{}, InstallationJob.run, .{job});
                self.installation_job = job;
                return true;
            },
            .prepare_connection => {
                var parsed = try self.installationRequest(operation.request_refs);
                defer parsed.deinit();
                try self.prepareInstallationConnection(observed, parsed.parsed.value);
                const next = self.control.installation(&id) orelse return error.InvalidState;
                return self.installationPhase(next.connection_phase, null);
            },
            .authorize_oauth => {
                if (self.flow == null) _ = try self.authorizeOauth(observed.generation, &id);
                return false;
            },
            .advance => |phase| {
                if (phase == .needs_credentials or phase == .preparing) {
                    var parsed = try self.installationRequest(operation.request_refs);
                    parsed.deinit();
                }
                return self.installationPhase(phase, null);
            },
            .fail => |failure| {
                try self.failInstallation(failure);
                return true;
            },
            .finish => {
                if (self.installation_active_since == null) self.installation_active_since = .now(self.io, .awake);
                const outcome = try self.control.finishInstallation(&id, operation.revision, self.installationElapsed());
                const saved = outcome == .saved or outcome == .saved_recovery_required;
                if (saved) self.host.notify();
                return saved;
            },
            .none => return false,
        }
    }

    pub fn drain(self: *Coordinator) bool {
        var changed = self.drainInstallation() catch blk: {
            self.failInstallation(.invalid_request) catch {};
            break :blk true;
        };
        if (!self.stopping) if (self.active_processes) |processes| for (processes.slots) |slot| {
            changed = (self.control.observeMcpProcess(slot.snapshot()) catch |err| failed: {
                std.log.warn("MCP process observation unavailable: {s}", .{@errorName(err)});
                break :failed false;
            }) or changed;
        };

        if (self.configuration_apply_job) |apply_job| {
            if (apply_job.finished.load(.acquire)) {
                apply_job.join();
                if (!self.stopping) for (apply_job.processes.slots) |slot| {
                    _ = self.control.observeMcpProcess(slot.snapshot()) catch |err| {
                        std.log.warn("MCP process observation unavailable: {s}", .{@errorName(err)});
                    };
                };
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
                            if (self.active_processes) |*old| old.deinit();
                            self.active_processes = apply_job.processes;
                            apply_job.processes = .{ .allocator = self.allocator };

                            apply_job.product_state_installed = true;
                            apply_job.result = .pending;
                            self.apply_pending = !self.stopping;
                        } else self.control.failMcpConfigurationApply(
                            apply_job.generation,
                            .unknown,
                        );
                    },
                    .rejected => {
                        self.control.failMcpConfigurationApply(apply_job.generation, .rejected);
                        self.apply_pending = !self.stopping;
                    },
                    .failed => self.control.failMcpConfigurationApply(apply_job.generation, .preparation),
                    .unknown => self.control.failMcpConfigurationApply(apply_job.generation, .unknown),
                    .pending => unreachable,
                }
                if (apply_job.result == .rejected or apply_job.result == .failed)
                    self.active_authorizations.retainRejectedFailures(&apply_job.authorizations);
                self.configuration_apply_job = null;
                apply_job.deinit();
                // Give due maintenance one main-loop opportunity before the
                // next candidate. Admission already reflects this settled step.
                self.host.notify();
                return true;
            }
        }
        if (self.connection_test_job) |test_job| {
            if (test_job.finished.load(.acquire)) {
                test_job.join();
                self.connection_test_job = null;
                switch (test_job.target) {
                    .saved => |id| self.control.completeMcpConnectionTest(id, test_job.result.outcome, test_job.result.tool_count, test_job.result.issue_count),
                    .draft => |draft| draft.complete(draft.context, if (self.stopping) .failed else test_job.detection),
                    .verified => |*draft| {
                        if (!self.stopping and draft.active(draft.context)) {
                            const result: ?mcp_configuration.CreateResult = if (test_job.result.outcome == .connected)
                                self.control.commit_http_draft_fn(self.control.context, draft.generation, &draft.mutation) catch mcp_configuration.CreateResult{ .outcome = .rejected }
                            else
                                null;
                            draft.complete(draft.context, result);
                        }
                    },
                }
                test_job.deinit();
                changed = true;
            }
        }
        if (!self.stopping and self.configuration_apply_job == null) {
            if (self.control.inspectMcpDesiredConfiguration()) |inspection| {
                if (inspection.health == .ready and inspection.runtime_alignment == .restart_required)
                    self.apply_pending = true;
            }
        }
        if (self.apply_pending and !self.stopping and self.configuration_apply_job == null) {
            const outcome = self.applyConfiguration(.automatic) catch {
                self.apply_pending = false;
                return true;
            };
            if (outcome == .unavailable) self.apply_pending = false;
            changed = changed or outcome == .started;
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
        if (self.installation_job) |job| {
            job.cancellation.cancel();
            job.deinit();
            self.installation_job = null;
        }
        if (self.active_processes) |*processes| processes.stopNotifications();
        if (self.configuration_apply_job) |job| job.processes.stopNotifications();

        self.cancelConfirmation();
        self.apply_pending = false;
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
        if (self.active_processes) |*processes| processes.deinit();
        self.* = undefined;
    }

    pub fn beginApproval(self: *Coordinator, operation: u64, expected_generation: u64, server_id: []const u8, completion: *const Approval.Completion) !Approval.Start {
        if (self.stopping or self.confirmation != null or self.configuration_apply_job != null or self.connection_test_job != null or self.flow != null) return .{ .immediate = .rejected };
        if (!self.connectionApprovalAvailable()) return .{ .immediate = .capability_unavailable };
        const inspection = self.control.inspectMcpDesiredConfiguration() orelse return .{ .immediate = .rejected };
        if (inspection.desired_generation != expected_generation) return .{ .immediate = .stale_generation };
        const storage = try self.allocator.alloc(u8, connection_approval_details_bytes);
        defer self.allocator.free(storage);
        const details = try self.control.writeMcpConnectionApprovalDetails(expected_generation, server_id, storage);
        const server = try self.allocator.dupe(u8, server_id);
        errdefer self.allocator.free(server);
        const text = try self.allocator.dupe(u8, details);
        errdefer self.allocator.free(text);
        const id = try self.nextConfirmationId();
        self.confirmation = .{ .id = id, .details = text, .title = "Approve MCP connection", .approval_label = "Approve connection", .kind = .{ .approval = .{ .operation = operation, .generation = expected_generation, .server = server, .completion = completion } } };
        self.requestConfirmationPage() catch |err| {
            self.confirmation = null;
            return err;
        };
        return .{ .started = id };
    }

    pub fn cancelApproval(self: *Coordinator, handle: u64) void {
        const pending = self.confirmation orelse return;
        if (pending.id != handle or pending.kind != .approval) return;
        self.cancelConfirmation();
    }

    fn nextConfirmationId(self: *Coordinator) !u64 {
        if (self.next_confirmation_id == std.math.maxInt(u64)) return error.Capacity;
        const id = self.next_confirmation_id;
        self.next_confirmation_id += 1;
        return id;
    }

    fn freeConfirmation(self: *Coordinator, pending: ConfirmationState) void {
        self.allocator.free(pending.details);
        switch (pending.kind) {
            .approval => |approval| self.allocator.free(approval.server),
            .oauth => |operation| self.allocator.free(operation),
            .installation => {},
        }
    }

    fn cancelConfirmation(self: *Coordinator) void {
        const pending = self.confirmation orelse return;
        self.confirmation = null;
        self.host.cancel_dialog_fn(self.host.context, pending.dialog_handle);
        self.freeConfirmation(pending);
    }

    fn requestConfirmationPage(self: *Coordinator) !void {
        const pending = if (self.confirmation) |*value| value else return error.InvalidState;
        var end = @min(pending.details.len, pending.offset + 4096);
        while (end > pending.offset and !std.unicode.utf8ValidateSlice(pending.details[pending.offset..end])) end -= 1;
        if (end == pending.offset) return error.InvalidConfirmation;
        pending.end = end;
        const token = try self.nextConfirmationId();
        pending.page_token = token;
        self.dialog_completion = .{ .context = self, .result_fn = confirmationResult };
        pending.dialog_handle = try self.host.request_dialog_fn(self.host.context, token, .{
            .title = pending.title,
            .message = pending.details[pending.offset..end],
            .style = .warning,
            .primary_button = if (end == pending.details.len) pending.approval_label else "Next",
            .secondary_button = "Cancel",
        }, &self.dialog_completion);
    }

    fn confirmationResult(context: *anyopaque, token: u64, result: Dialog.Result) void {
        const self: *Coordinator = @ptrCast(@alignCast(context));
        self.confirmationResultChecked(token, result) catch |err| self.finishConfirmation(.{ .failed = err });
    }

    fn confirmationResultChecked(self: *Coordinator, token: u64, result: Dialog.Result) !void {
        const pending = if (self.confirmation) |*value| value else return;
        if (pending.page_token != token) return;
        pending.dialog_handle = 0;
        if (self.stopping) {
            self.finishConfirmation(.{ .outcome = .cancelled });
            return;
        }
        if (pending.kind == .oauth) {
            const flow = self.flow orelse {
                self.cancelConfirmation();
                return;
            };
            if (!std.mem.eql(u8, flow.start.operation_id, pending.kind.oauth) or flow.cancelling or flow.deadline.raw.nanoseconds <= flow.deadline.clock.now(self.io).nanoseconds) {
                self.finishConfirmation(.{ .outcome = .cancelled });
                return;
            }
        }
        switch (result) {
            .cancelled => {
                self.finishConfirmation(.{ .outcome = .cancelled });
                return;
            },
            .failed => return error.DialogFailed,
            .files => return error.InvalidDialogResult,
            .button => |button| if (button != .primary) {
                self.finishConfirmation(.{ .outcome = .cancelled });
                return;
            },
        }
        pending.offset = pending.end;
        if (pending.offset < pending.details.len) {
            try self.requestConfirmationPage();
            return;
        }
        self.finishConfirmation(.confirmed);
    }

    fn finishConfirmation(self: *Coordinator, requested: Approval.Result) void {
        const pending = self.confirmation orelse return;
        self.confirmation = null;
        defer self.freeConfirmation(pending);
        switch (pending.kind) {
            .approval => |approval| {
                var result = requested;
                if (result == .confirmed) {
                    const inspection = self.control.inspectMcpDesiredConfiguration();
                    if (self.stopping or self.configuration_apply_job != null or self.connection_test_job != null or self.flow != null) result = .{ .outcome = .rejected } else if (inspection == null or inspection.?.desired_generation != approval.generation) result = .{ .outcome = .stale_generation };
                }
                approval.completion.complete_fn(approval.completion.context, approval.operation, result);
            },
            .installation => |installation| {
                const observed = self.control.installation(&installation.server) orelse return;
                const operation = observed;
                if (operation.revision != installation.revision or operation.phase != .needs_authorization) return;
                if (requested == .confirmed and !self.stopping and observed.source_available) {
                    _ = self.control.updateInstallation(observed.generation, .{ .server_id = &installation.server, .expected_revision = operation.revision, .phase = .preparing, .active_elapsed_ms = operation.active_elapsed_ms, .cross_origin_authorized = true }) catch {};
                    self.installation_active_since = .now(self.io, .awake);
                } else {
                    _ = self.control.cancelInstallation(&installation.server, operation.revision) catch {};
                }
                self.host.notify();
            },
            .oauth => |operation| {
                const flow = self.flow orelse return;
                if (!std.mem.eql(u8, flow.start.operation_id, operation)) return;
                if (requested == .confirmed and !self.stopping and !flow.cancelling) self.resumeConsent(flow) catch self.finishFlow(flow) else {
                    flow.cancelling = true;
                    self.finishFlow(flow);
                }
                self.host.notify();
            },
        }
    }

    pub fn captureSecret(
        self: *Coordinator,
        expected_generation: u64,
        server_id: []const u8,
        slot: SecretSlot,
        value: []const u8,
    ) !Outcome {
        if (self.confirmation != null) return .rejected;
        if (self.stopping or self.configuration_apply_job != null or
            self.connection_test_job != null or self.flow != null) return .rejected;
        if (!self.secretCaptureAvailable()) return .capability_unavailable;
        const inspection = self.control.inspectMcpDesiredConfiguration() orelse
            return .rejected;
        if (inspection.desired_generation != expected_generation)
            return .stale_generation;
        self.control.validateMcpSecretCapture(
            expected_generation,
            server_id,
            slot,
        ) catch return .rejected;
        var secret_storage: [mcp_platform.max_credential_secret_bytes]u8 = undefined;
        defer std.crypto.secureZero(u8, &secret_storage);
        if (value.len == 0 or value.len > secret_storage.len) return .rejected;
        const secret = secret_storage[0..value.len];
        @memcpy(secret, value);
        const outcome = switch (slot) {
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
            .installation_credential => |name| mapManagementOutcome(try self.control.captureInstallation(expected_generation, server_id, name, true, secret)),
            .oauth_client_secret => mapManagementOutcome(
                try self.control.captureMcpOauthClientSecret(
                    expected_generation,
                    .{ .server_id = server_id, .secret = secret },
                ),
            ),
        };
        if (slot == .installation_credential and (outcome == .saved or outcome == .saved_recovery_required)) self.host.notify();
        return outcome;
    }

    fn startDiscovery(self: *Coordinator, flow: *Flow) !void {
        try self.installJob(flow, .{ .discovery = .{
            .endpoint = try self.allocator.dupe(u8, flow.start.endpoint),
            .private_resource = flow.start.private_endpoint != null,
        } });
    }

    fn installJob(self: *Coordinator, flow: *Flow, input_value: JobInput) !void {
        std.debug.assert(flow.job == null);
        var input = input_value;
        var input_owned = true;
        errdefer if (input_owned) deinitJobInput(self.allocator, &input);
        if (input != .callback and self.transport_override == null and self.host_environment.http_engine == null) return error.InvalidConfig;
        const job = try self.allocator.create(Job);
        job.* = .{
            .http_engine = self.host_environment.http_engine,
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
        var displayed_resource = discovery.resource;
        if (flow.start.private_endpoint != null)
            displayed_resource.resource = mcp_configuration.endpointOrigin(discovery.resource.resource, mcp_startup.configuration_limits.max_oauth_uri_bytes) orelse return error.InvalidState;
        const details = try writeConsentDetails(
            details_storage,
            &displayed_resource,
            &discovery.authorization,
            attempt.redirectUri(),
            flow.start.registration_kind,
            flow.start.client_id,
            flow.start.token_endpoint_auth_method,
            flow.start.client_id == null,
        );
        const text = try self.allocator.dupe(u8, details);
        errdefer self.allocator.free(text);
        const operation = try self.allocator.dupe(u8, flow.start.operation_id);
        errdefer self.allocator.free(operation);
        const id = try self.nextConfirmationId();
        self.confirmation = .{ .id = id, .details = text, .title = "Authorize MCP server", .approval_label = "Continue to browser", .kind = .{ .oauth = operation } };
        self.requestConfirmationPage() catch |err| {
            self.confirmation = null;
            return err;
        };
    }

    fn resumeConsent(self: *Coordinator, flow: *Flow) !void {
        const discovery = if (flow.discovery) |*value| value else return error.InvalidState;
        const attempt = flow.attempt orelse return error.InvalidState;
        if (flow.start.private_endpoint != null and flow.private_resource_identity == null) {
            const resource_copy = try self.allocator.dupe(u8, discovery.resource.resource);
            defer secureFree(self.allocator, resource_copy);
            const current = self.control.inspectMcpDesiredConfiguration() orelse return error.InvalidState;
            const captured = try self.control.captureMcpOauthResource(current.desired_generation orelse return error.InvalidState, .{ .server_id = flow.start.server_id, .resource = resource_copy });
            if (captured.outcome != .saved or captured.identity == null) return error.StateRejected;
            flow.private_resource_identity = captured.identity;
        }
        if (flow.start.client_id == null) {
            if (!std.mem.eql(u8, flow.start.registration_kind, "dynamic_registration"))
                return error.InvalidState;
            const begin = try self.control.beginMcpOauthDynamicRegistration(.{
                .server_id = flow.start.server_id,
                .resource = discovery.resource.resource,
                .private_resource_identity = if (flow.private_resource_identity) |*identity| identity else null,
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
        const resource = if (binding.private_resource) |private|
            try mcp_configuration.resolvePrivateEndpoint(self.allocator, private, self.credential_store.resolver(), mcp_startup.configuration_limits)
        else
            try self.allocator.dupe(u8, binding.resource);
        var resource_owned = true;
        errdefer if (resource_owned) secureFree(self.allocator, resource);
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
                if (apply_after_finish) _ = self.applyConfiguration(.automatic) catch {};
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
            .private_resource_identity = if (self.flow) |flow| if (flow.private_resource_identity) |*identity| identity else null else null,
            .scopes = plan.scopes,
            .redirect_uri = plan.redirect_uri,
        }) catch return error.StatePersistenceFailed) {
            .ready => |binding| .{
                .attempt_id = binding.attempt_id,
                .server_id = binding.server_id,
                .issuer = binding.issuer,
                .resource = if (binding.private_resource != null) plan.resource else binding.resource,
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
        if (self.confirmation) |pending| if (pending.kind == .oauth and std.mem.eql(u8, pending.kind.oauth, flow.start.operation_id)) self.cancelConfirmation();
        var requires_recovery = flow.durable_request_started;
        if (flow.job) |job| {
            job.cancel();
            job.join();
            if (job.result == .failed)
                requires_recovery = durableFailureRequiresRecovery(job.result.failed);
            self.destroyJob(flow, job);
        }
        if (flow.durable_operation_id != null) {
            if (requires_recovery)
                _ = self.recoverDurable(flow)
            else
                _ = self.clearDurable(flow);
        }
        _ = self.control.finishMcpAuthorization(flow.start.operation_id);
        if (self.flow == flow) self.flow = null;
        if (!self.stopping) if (self.installation_server) |id| if (std.mem.eql(u8, &id, flow.start.server_id)) {
            if (self.control.installation(&id)) |observed| {
                if (observed.action == .authorize_oauth) {
                    if (flow.cancelling)
                        _ = self.control.cancelInstallation(&id, observed.revision) catch {}
                    else
                        _ = self.installationPhase(.failed, .authorization_failed) catch {};
                }
            }
        };
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
    try writer.writeAll("Confirming replaces any saved authorization. If you cancel after confirmation or the browser cannot finish, you must sign in again.\n\n");
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
    return switch (failure) {
        .invalid_grant, .outcome_unknown => true,
        .definitive, .not_sent, .cancelled_before_send, .rejected => false,
    };
}

pub fn mapManagementOutcome(value: mcp_configuration.ManagementOutcome) Outcome {
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
    try std.testing.expect(!durableFailureRequiresRecovery(.not_sent));
    try std.testing.expect(!durableFailureRequiresRecovery(.rejected));
    try std.testing.expect(!durableFailureRequiresRecovery(.definitive));
    try std.testing.expect(durableFailureRequiresRecovery(.invalid_grant));
    try std.testing.expect(durableFailureRequiresRecovery(.outcome_unknown));
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
        fn request(_: *anyopaque, _: u64, _: Dialog.Message, _: *const Dialog.Completion) !u64 {
            return error.UnsupportedService;
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
    const agent_runtime = try test_fixture.createTestRuntime(.{ .max_sessions = 1 });
    defer {
        agent_runtime.shutdown() catch {};
        agent_runtime.deinit();
    }
    var workbench_owner = try test_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        agent_runtime,
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
        (try workbench_owner.createMcpHttpServer(0, .{
            .display_name = "Remote",
            .url = "https://mcp.example.test/mcp",
        })).outcome,
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
        agent_runtime,
        &credential_store,
        &authorizations,
        .{
            .context = &host_context,
            .request_dialog_fn = TestHost.request,
            .open_url_fn = TestHost.open,
            .now_unix_ms_fn = TestHost.now,
            .notify_fn = TestHost.notify,
        },
        .{},
    );
    defer coordinator.deinit();

    try std.testing.expectError(error.OutOfMemory, coordinator.applyConfiguration(.automatic));
    try std.testing.expectEqual(
        mcp_types.McpConfigurationApplyState.failed,
        product_mcp.testing.state(&workbench_owner.mcp.?).configuration_apply_state,
    );
    const state = product_mcp.testing.state(&workbench_owner.mcp.?);
    try std.testing.expect(state.admission == .ready);
    try std.testing.expect(state.admission.ready.selection == null);
    try std.testing.expectEqual(.current, workbench_owner.inspectMcpDesiredConfiguration().?.runtime_alignment);
    for (0..3) |_| {
        try std.testing.expect(!coordinator.drain());
        try std.testing.expect(coordinator.configuration_apply_job == null);
        try std.testing.expect(!coordinator.apply_pending);
    }
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
        opens: usize = 0,
        fail_open: bool = false,
        saw_replacement_notice: bool = false,

        completion: ?*const Dialog.Completion = null,
        token: u64 = 0,
        fn request(context: *anyopaque, token: u64, message: Dialog.Message, completion: *const Dialog.Completion) !u64 {
            const self: *@This() = @ptrCast(@alignCast(context));
            _ = self.confirmations.fetchAdd(1, .acq_rel);
            self.saw_replacement_notice = self.saw_replacement_notice or std.mem.indexOf(u8, message.message, "Confirming replaces any saved authorization.") != null;
            self.completion = completion;
            self.token = token;
            return token;
        }
        fn finish(self: *@This()) void {
            while (self.completion) |completion| {
                self.completion = null;
                completion.result_fn(completion.context, self.token, .{ .button = .primary });
            }
        }
        fn open(context: *anyopaque, _: []const u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.opens += 1;
            return !self.fail_open;
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
    const agent_runtime = try test_fixture.createTestRuntime(.{ .max_sessions = 1 });
    defer {
        agent_runtime.shutdown() catch {};
        agent_runtime.deinit();
    }
    var identity_generator: IdentityGenerator = .{};
    var workbench_owner = try test_control.Runtime.init(
        std.testing.allocator,
        std.testing.io,
        agent_runtime,
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
        (try workbench_owner.createMcpOauthHttpServer(0, .{
            .display_name = "Remote",
            .url = "https://mcp.example.test/mcp",
            .client = .dynamic_registration,
        })).outcome,
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
        agent_runtime,
        &credential_store,
        &active_authorizations,
        .{
            .context = &host_context,
            .confirmation_available = true,
            .oauth_available = true,
            .request_dialog_fn = FakeHost.request,
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
        (try workbench_owner.createMcpOauthHttpServer(1, .{
            .display_name = "Remote to cancel",
            .url = "https://mcp.example.test/mcp",
            .client = .dynamic_registration,
        })).outcome,
    );
    const cancelled_server_id = "mcp-7d7d7d7d7d7d7d7d7d7d";
    try std.testing.expectEqual(
        mcp_configuration.ManagementOutcome.saved,
        (try workbench_owner.createMcpOauthHttpServer(2, .{
            .display_name = "Remote with uncertain cancel",
            .url = "https://mcp.example.test/mcp",
            .client = .dynamic_registration,
        })).outcome,
    );
    const uncertain_server_id = "mcp-7e7e7e7e7e7e7e7e7e7e";
    const started = try coordinator.authorizeOauth(3, canonical_server_id);
    try std.testing.expect(started == .started);
    waitForCoordinatorJob(&coordinator);
    try std.testing.expect(coordinator.drain());
    host_context.finish();
    waitForCoordinatorJob(&coordinator);
    try std.testing.expect(coordinator.drain());
    host_context.finish();
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
    host_context.finish();
    waitForCoordinatorJob(&coordinator);
    try std.testing.expect(coordinator.drain());
    host_context.finish();
    try std.testing.expect(coordinator.flow == null);
    try std.testing.expectEqual(@as(usize, 5), fake_http.calls.load(.acquire));
    try std.testing.expect(workbench_owner.mcpAuthorizationOperation() == null);
    try std.testing.expectEqual(@as(usize, 1), host_context.confirmations.load(.acquire));
    try std.testing.expect(host_context.saw_replacement_notice);

    fake_http.registration_failure.store(1, .release);
    const cancelled_start = try coordinator.authorizeOauth(5, cancelled_server_id);
    try std.testing.expect(cancelled_start == .started);
    waitForCoordinatorJob(&coordinator);
    try std.testing.expect(coordinator.drain());
    host_context.finish();
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
    host_context.finish();
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
    host_context.finish();
    try std.testing.expect(coordinator.flow != null);
    try std.testing.expect(coordinator.flow.?.job != null);
    waitForCoordinatorJob(&coordinator);
    try std.testing.expectEqual(
        Outcome.cancelled,
        coordinator.cancelAuthorization(retry_start.started),
    );
    try std.testing.expectEqual(@as(usize, 4), host_context.confirmations.load(.acquire));

    // Cancelled and stale registration completions never reach the browser.
    try std.testing.expectEqual(@as(usize, 1), host_context.opens);
    fake_http.registration_failure.store(0, .release);
    host_context.fail_open = true;
    const failed_start = try coordinator.authorizeOauth(6, canonical_server_id);
    try std.testing.expect(failed_start == .started);
    waitForCoordinatorJob(&coordinator);
    try std.testing.expect(coordinator.drain());
    host_context.finish();
    try std.testing.expect(coordinator.flow == null);
    try std.testing.expect(workbench_owner.mcpAuthorizationOperation() == null);
    try std.testing.expectEqual(@as(usize, 2), host_context.opens);
    _ = coordinator.drain();
    try std.testing.expectEqual(@as(usize, 2), host_context.opens);
    host_context.fail_open = false;

    const shutdown_generation = coordinator.control.inspectMcpDesiredConfiguration().?.desired_generation.?;
    const shutdown_start = try coordinator.authorizeOauth(shutdown_generation, uncertain_server_id);
    try std.testing.expect(shutdown_start == .started);
    waitForCoordinatorJob(&coordinator);
    try std.testing.expect(coordinator.drain());
    host_context.finish();
    try std.testing.expect(coordinator.flow.?.durable_operation_id != null);
    coordinator.shutdown();
    try std.testing.expect(coordinator.flow == null);
    try std.testing.expect(workbench_owner.mcpAuthorizationOperation() == null);
    try std.testing.expectEqual(@as(usize, 6), host_context.confirmations.load(.acquire));
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

test "MCP asynchronous confirmation owns paging cancellation and failure terminals" {
    const Probe = struct {
        completion: ?*const Dialog.Completion = null,
        token: u64 = 0,
        handle: u64 = 0,
        cancelled: u64 = 0,
        requests: usize = 0,
        responses: usize = 0,
        failed: bool = false,
        fail_next: bool = false,
        fn request(raw: *anyopaque, token: u64, message: Dialog.Message, completion: *const Dialog.Completion) !u64 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.fail_next) return error.DialogQueueFull;
            try std.testing.expect(message.message.len <= 4096);
            try std.testing.expectEqualStrings(if (self.requests < 2) "Next" else "Approve", message.primary_button);
            self.requests += 1;
            self.token = token;
            self.handle += 1;
            self.completion = completion;
            return self.handle;
        }
        fn cancel(raw: *anyopaque, handle: u64) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.cancelled = handle;
        }
        fn complete(raw: *anyopaque, id: u64, result: Approval.Result) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            std.debug.assert(id == 91 and result != .confirmed);
            self.responses += 1;
            self.failed = result == .failed;
        }
        fn open(_: *anyopaque, _: []const u8) bool {
            return false;
        }
        fn now(_: *anyopaque) ?u64 {
            return 1;
        }
        fn notify(_: *anyopaque) void {}
        fn deliver(self: *@This(), result: Dialog.Result) void {
            const completion = self.completion.?;
            completion.result_fn(completion.context, self.token, result);
        }
    };
    // Each terminal occurs on page two. A stale page-one result must never
    // advance a newer page or acquire Product authority.
    for (0..5) |scenario| {
        var probe: Probe = .{};
        var completion: Approval.Completion = .{ .context = &probe, .complete_fn = Probe.complete };
        var coordinator = Coordinator.init(std.testing.allocator, std.testing.io, undefined, undefined, undefined, undefined, .{
            .context = &probe,
            .confirmation_available = true,
            .request_dialog_fn = Probe.request,
            .cancel_dialog_fn = Probe.cancel,
            .open_url_fn = Probe.open,
            .now_unix_ms_fn = Probe.now,
            .notify_fn = Probe.notify,
        }, undefined);
        const text = try std.testing.allocator.alloc(u8, 8300);
        @memset(text, 'x');
        coordinator.confirmation = .{ .id = 90, .details = text, .title = "Test", .approval_label = "Approve", .kind = .{ .approval = .{
            .operation = 91,
            .generation = 1,
            .server = try std.testing.allocator.dupe(u8, "server"),
            .completion = &completion,
        } } };
        defer coordinator.cancelConfirmation();
        try coordinator.requestConfirmationPage();
        try std.testing.expectEqual(AuthorizationStartOutcome.rejected, try coordinator.authorizeOauth(1, "server"));
        try std.testing.expectEqual(ConnectionTestStartOutcome.busy, try coordinator.testConnection(1, "server"));
        try std.testing.expectEqual(ConfigurationApplyStartOutcome.busy, try coordinator.applyConfiguration(.automatic));
        try std.testing.expectEqual(Outcome.rejected, try coordinator.captureSecret(1, "server", .oauth_client_secret, "value"));
        try std.testing.expectEqual(Approval.Start{ .immediate = .rejected }, try coordinator.beginApproval(99, 1, "server", &completion));
        const old_token = probe.token;
        if (scenario == 3) probe.fail_next = true;
        probe.deliver(.{ .button = .primary });
        if (scenario == 3) {
            try std.testing.expect(probe.failed);
        } else {
            try std.testing.expectEqual(@as(usize, 2), probe.requests);
            Coordinator.confirmationResult(&coordinator, old_token, .{ .button = .primary });
            try std.testing.expectEqual(@as(usize, 2), probe.requests);
            switch (scenario) {
                0 => probe.deliver(.cancelled),
                1 => probe.deliver(.failed),
                2 => probe.deliver(.{ .button = .secondary }),
                4 => {
                    probe.deliver(.{ .button = .primary });
                    try std.testing.expectEqual(@as(usize, 3), probe.requests);
                    coordinator.cancelApproval(90);
                    try std.testing.expectEqual(@as(u64, 3), probe.cancelled);
                },
                else => unreachable,
            }
        }
        try std.testing.expect(coordinator.confirmation == null);
        try std.testing.expectEqual(@as(usize, if (scenario == 4) 0 else 1), probe.responses);
        probe.deliver(.{ .button = .primary });
        try std.testing.expectEqual(@as(usize, if (scenario == 4) 0 else 1), probe.responses);
    }
    try std.testing.expectEqual(Outcome.rejected, mapManagementOutcome(.unchanged));
}
