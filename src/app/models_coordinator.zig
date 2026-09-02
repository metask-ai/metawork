const std = @import("std");
const agent = @import("metawork_agent");
const account_api = @import("metawork_account");
const account_contract = @import("metawork_account_contract");
const models_contract = @import("metawork_product_models_contract");
const models_ports = @import("product_models_ports");
const models_metask = @import("product_models_metask");
const metask_transport = @import("metask_transport");
const control_ports = @import("metawork_product_control_ports");
const agent_protocol = @import("product_agent_protocol_adapter");

pub const ProbeNotifier = struct {
    context: *anyopaque,
    notify_fn: *const fn (*anyopaque) void,

    fn notify(self: ProbeNotifier) void {
        self.notify_fn(self.context);
    }
};

const ProbeJob = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    completion_transport: agent.CompletionTransport,
    notifier: ProbeNotifier,
    source_id: []u8,
    model_id: []u8,
    expected_connection_revision: u64,
    expected_source_generation: u64,
    expected_catalog_generation: u64,
    execution: ?models_contract.OwnedConfig = null,
    cancellation: agent.ProviderProbeCancellation = .{},
    succeeded: bool = false,
    finished: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        completion_transport: agent.CompletionTransport,
        notifier: ProbeNotifier,
        command_value: models_contract.ModelConnectionTestCommand,
    ) std.mem.Allocator.Error!*ProbeJob {
        const self = try allocator.create(ProbeJob);
        errdefer allocator.destroy(self);
        const source_id = try allocator.dupe(
            u8,
            command_value.model.source_id,
        );
        errdefer allocator.free(source_id);
        const model_id = try allocator.dupe(u8, command_value.model.model_id);
        errdefer allocator.free(model_id);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .completion_transport = completion_transport,
            .notifier = notifier,
            .source_id = source_id,
            .model_id = model_id,
            .expected_connection_revision = command_value.expected_connection_revision,
            .expected_source_generation = command_value.expected_source_generation,
            .expected_catalog_generation = command_value.expected_catalog_generation,
        };
        return self;
    }

    fn installExecution(
        self: *ProbeJob,
        execution: *models_contract.OwnedConfig,
    ) void {
        std.debug.assert(self.execution == null);
        self.execution = execution.take();
    }

    fn start(self: *ProbeJob) std.Thread.SpawnError!void {
        std.debug.assert(self.execution != null);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn run(self: *ProbeJob) void {
        const execution = &self.execution.?;
        const input = execution.input();
        self.succeeded = agent.runProviderProbe(self.io, self.completion_transport, .{
            .provider_id = input.target.provider_id,
            .protocol = agent_protocol.toAgent(input.target.protocol),
            .credential = input.api_key,
            .model = input.target.model,
            .base_url = input.target.base_url,
        }, &self.cancellation) == .connected;
        execution.deinit();
        self.execution = null;
        self.finished.store(true, .release);
        self.notifier.notify();
    }

    fn join(self: *ProbeJob) void {
        const thread = self.thread orelse return;
        thread.join();
        self.thread = null;
    }

    fn cancel(self: *ProbeJob) void {
        self.cancellation.request();
    }

    fn command(self: *const ProbeJob) models_contract.ModelConnectionTestCommand {
        return .{
            .model = .{
                .source_id = self.source_id,
                .model_id = self.model_id,
            },
            .expected_connection_revision = self.expected_connection_revision,
            .expected_source_generation = self.expected_source_generation,
            .expected_catalog_generation = self.expected_catalog_generation,
        };
    }

    fn deinit(self: *ProbeJob) void {
        std.debug.assert(self.thread == null);
        if (self.execution) |*execution| execution.deinit();
        self.allocator.free(self.model_id);
        self.allocator.free(self.source_id);
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }
};

const CatalogJob = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    transport: metask_transport.Transport,
    notifier: ProbeNotifier,
    attempt_id: u64,
    authorization_generation: u64,
    preferred_api_key_id: []u8,
    preferred_model_id: []u8,
    lease: account_contract.OwnedAuthorizationLease,
    lease_active: bool = true,
    cancellation: metask_transport.Cancellation,
    completion: ?models_metask.OwnedCatalogCompletion = null,
    error_code: models_contract.ModelsError = .none,
    finished: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        transport: metask_transport.Transport,
        notifier: ProbeNotifier,
        preparation: models_contract.CatalogRefreshPreparation,
        lease: *account_contract.OwnedAuthorizationLease,
    ) std.mem.Allocator.Error!*CatalogJob {
        std.debug.assert(std.mem.eql(u8, preparation.principal_ref, lease.principal_ref));
        std.debug.assert(preparation.authorization_generation == lease.authorization_generation);
        const self = try allocator.create(CatalogJob);
        errdefer allocator.destroy(self);
        const preferred_api_key_id = try allocator.dupe(u8, preparation.preferred_api_key_id);
        errdefer allocator.free(preferred_api_key_id);
        const preferred_model_id = try allocator.dupe(u8, preparation.preferred_model_id);
        errdefer allocator.free(preferred_model_id);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .transport = transport,
            .notifier = notifier,
            .attempt_id = preparation.attempt_id,
            .authorization_generation = preparation.authorization_generation,
            .preferred_api_key_id = preferred_api_key_id,
            .preferred_model_id = preferred_model_id,
            .lease = lease.take(),
            .cancellation = metask_transport.Cancellation.init(io),
        };
        return self;
    }

    fn start(self: *CatalogJob) std.Thread.SpawnError!void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn run(self: *CatalogJob) void {
        defer {
            self.lease.deinit();
            self.lease_active = false;
            self.finished.store(true, .release);
            self.notifier.notify();
        }
        var session = models_metask.CatalogSession.init(self.allocator);
        defer session.deinit();
        const deadline = std.Io.Clock.Timestamp.fromNow(self.io, .{
            .raw = .fromSeconds(30),
            .clock = .boot,
        });
        const control: metask_transport.RequestControl = .{
            .cancellation = &self.cancellation,
            .deadline = deadline,
        };
        session.loadApiKeys(
            self.transport,
            self.lease.access_token,
            self.lease.principal_ref,
            control,
        ) catch |err| {
            self.error_code = models_metask.errorCode(err);
            return;
        };
        const api_key_id = if (self.preferred_api_key_id.len != 0 and
            session.hasApiKey(self.preferred_api_key_id))
            self.preferred_api_key_id
        else
            session.firstApiKeyId() orelse {
                self.error_code = .no_api_keys;
                return;
            };
        session.selectApiKey(api_key_id) catch |err| {
            self.error_code = models_metask.errorCode(err);
            return;
        };
        session.loadModels(self.transport, control) catch |err| {
            self.error_code = models_metask.errorCode(err);
            return;
        };
        const model_id = if (self.preferred_model_id.len != 0 and
            session.hasModel(self.preferred_model_id))
            self.preferred_model_id
        else
            session.firstModelId() orelse {
                self.error_code = .no_models;
                return;
            };
        self.completion = models_metask.OwnedCatalogCompletion.init(
            self.allocator,
            &session,
            model_id,
        ) catch |err| {
            self.error_code = models_metask.errorCode(err);
            return;
        };
    }

    fn cancel(self: *CatalogJob) void {
        self.cancellation.cancel();
    }

    fn join(self: *CatalogJob) void {
        const thread = self.thread orelse return;
        thread.join();
        self.thread = null;
    }

    fn deinit(self: *CatalogJob) void {
        std.debug.assert(self.thread == null);
        if (self.completion) |*completion| completion.deinit();
        if (self.lease_active) self.lease.deinit();
        self.allocator.free(self.preferred_model_id);
        self.allocator.free(self.preferred_api_key_id);
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }
};

/// Application coordinator for Models-only effects. Product Control owns
/// registry/default-selection policy; this type only binds platform and Agent
/// effects to its scoped management capability.
pub const Coordinator = struct {
    io: std.Io,
    account: *account_api.Runtime,
    metask_transport: metask_transport.Transport,
    management: control_ports.ModelsManagement,
    main_thread_id: std.Thread.Id,
    probe_notifier: ?ProbeNotifier = null,
    completion_transport: ?agent.CompletionTransport = null,
    probe_job: ?*ProbeJob = null,
    catalog_job: ?*CatalogJob = null,
    observed_authorization_generation: u64 = 0,

    pub fn init(
        account: *account_api.Runtime,
        transport: metask_transport.Transport,
        management: control_ports.ModelsManagement,
        main_thread_id: std.Thread.Id,
        io: std.Io,
    ) Coordinator {
        return .{
            .io = io,
            .account = account,
            .metask_transport = transport,
            .management = management,
            .main_thread_id = main_thread_id,
        };
    }

    pub fn setProbeNotifier(self: *Coordinator, notifier: ?ProbeNotifier) void {
        self.probe_notifier = notifier;
    }

    pub fn setCompletionTransport(
        self: *Coordinator,
        transport: agent.CompletionTransport,
    ) void {
        self.completion_transport = transport;
    }

    pub fn commandSink(self: *Coordinator) models_contract.CommandSink {
        return .{ .context = self, .submit_fn = submitCommand };
    }

    fn submitCommand(
        context: *anyopaque,
        command: models_contract.ModelConnectionCommand,
    ) models_contract.CommandResult {
        const self: *Coordinator = @ptrCast(@alignCast(context));
        self.assertMainThread();
        if (command == .test_connection)
            return self.startProbe(command.test_connection);
        return self.management.submitModelConnectionCommand(command);
    }

    /// Continuation after trusted native secret capture. The borrowed secret
    /// never enters Bridge or a Product projection.
    pub fn createWithCapturedCredential(
        self: *Coordinator,
        secret: []const u8,
        spec: models_contract.ModelConnectionSpec,
        model: models_contract.CustomModelInput,
    ) models_contract.CommandResult {
        self.assertMainThread();
        return self.management.createModelConnectionWithCredential(
            secret,
            spec,
            model,
        );
    }

    fn startProbe(
        self: *Coordinator,
        command: models_contract.ModelConnectionTestCommand,
    ) models_contract.CommandResult {
        const notifier = self.probe_notifier orelse
            return .rejected(.test_unavailable);
        const completion_transport = self.completion_transport orelse
            return .rejected(.test_unavailable);
        if (self.probe_job != null)
            return .rejected(.operation_in_progress);
        const job = ProbeJob.create(
            std.heap.c_allocator,
            self.io,
            completion_transport,
            notifier,
            command,
        ) catch return .rejected(.local_resource_exhausted);
        var execution = switch (self.management.beginModelConnectionProbe(
            job.command(),
        )) {
            .ready => |value| value,
            .rejected => |error_code| {
                job.deinit();
                return .rejected(error_code);
            },
        };
        job.installExecution(&execution);
        job.start() catch {
            _ = self.management.completeModelConnectionTest(job.command(), false);
            job.deinit();
            return .rejected(.local_resource_exhausted);
        };
        self.probe_job = job;
        return .acceptedResult();
    }

    pub fn start(
        self: *Coordinator,
        directory: []const u8,
        vault: models_ports.CredentialVault,
    ) void {
        self.assertMainThread();
        self.management.startModelConnections(directory, vault) catch
            self.management.startModelConnectionsUnavailable();
    }

    pub fn startUnavailable(self: *Coordinator) void {
        self.assertMainThread();
        self.management.startModelConnectionsUnavailable();
    }

    pub fn authorizationChanged(self: *Coordinator) void {
        self.assertMainThread();
        var lease = self.account.authorizationLease() orelse {
            if (self.catalog_job) |job| {
                job.cancel();
                job.join();
                self.management.failMetaskCatalogRefresh(
                    job.attempt_id,
                    job.authorization_generation,
                    .authorization_unavailable,
                    "",
                );
                job.deinit();
                self.catalog_job = null;
            }
            if (self.observed_authorization_generation != 0)
                self.management.setMetaskAuthorizationUnavailable();
            self.observed_authorization_generation = 0;
            return;
        };
        defer lease.deinit();
        if (lease.authorization_generation == self.observed_authorization_generation)
            return;
        if (self.catalog_job) |job| {
            job.cancel();
            job.join();
            self.management.failMetaskCatalogRefresh(
                job.attempt_id,
                job.authorization_generation,
                .authorization_unavailable,
                "",
            );
            job.deinit();
            self.catalog_job = null;
        }
        self.observed_authorization_generation = lease.authorization_generation;
        _ = self.startCatalogJob(&lease);
    }

    pub fn refreshCatalog(self: *Coordinator) models_contract.CommandResult {
        self.assertMainThread();
        if (self.catalog_job != null)
            return .rejected(.operation_in_progress);
        var lease = self.account.authorizationLease() orelse {
            self.management.setMetaskAuthorizationUnavailable();
            self.observed_authorization_generation = 0;
            return .rejected(.authorization_unavailable);
        };
        defer lease.deinit();
        self.observed_authorization_generation = lease.authorization_generation;
        return self.startCatalogJob(&lease);
    }

    fn startCatalogJob(
        self: *Coordinator,
        lease: *account_contract.OwnedAuthorizationLease,
    ) models_contract.CommandResult {
        const notifier = self.probe_notifier orelse {
            self.management.setMetaskAuthorizationUnavailable();
            return .rejected(.catalog_unavailable);
        };
        const preparation = switch (self.management.prepareMetaskCatalogRefresh(
            lease.principal_ref,
            lease.authorization_generation,
        )) {
            .ready => |value| value,
            // The Models owner already exposes the precise rejection
            // (persistence unavailable, operation in progress, and so on).
            // Application must not rewrite those failures as an Account
            // authorization loss.
            .rejected => |error_code| return .rejected(managementError(error_code)),
        };
        const job = CatalogJob.create(
            std.heap.c_allocator,
            self.io,
            self.metask_transport,
            notifier,
            preparation,
            lease,
        ) catch {
            self.management.failMetaskCatalogRefresh(
                preparation.attempt_id,
                preparation.authorization_generation,
                .local_resource_exhausted,
                "",
            );
            return .rejected(.local_resource_exhausted);
        };
        job.start() catch {
            self.management.failMetaskCatalogRefresh(
                preparation.attempt_id,
                preparation.authorization_generation,
                .local_resource_exhausted,
                "",
            );
            job.deinit();
            return .rejected(.local_resource_exhausted);
        };
        self.catalog_job = job;
        return .acceptedResult();
    }

    pub fn drain(self: *Coordinator) void {
        self.assertMainThread();
        if (self.catalog_job) |job| {
            if (job.finished.load(.acquire)) {
                job.join();
                if (self.account.acceptsAuthorizationGeneration(
                    job.authorization_generation,
                )) {
                    if (job.completion) |*completion| {
                        _ = self.management.completeMetaskCatalogRefresh(
                            job.attempt_id,
                            job.authorization_generation,
                            completion,
                        );
                        job.completion = null;
                    } else {
                        self.management.failMetaskCatalogRefresh(
                            job.attempt_id,
                            job.authorization_generation,
                            job.error_code,
                            "",
                        );
                    }
                } else {
                    self.management.setMetaskAuthorizationUnavailable();
                }
                self.catalog_job = null;
                job.deinit();
            }
        }
        if (self.probe_job) |job| {
            if (!job.finished.load(.acquire)) return;
            job.join();
            _ = self.management.completeModelConnectionTest(
                job.command(),
                job.succeeded,
            );
            self.probe_job = null;
            job.deinit();
        }
    }

    pub fn shutdown(self: *Coordinator) void {
        self.assertMainThread();
        if (self.catalog_job) |job| {
            job.cancel();
            job.join();
            job.deinit();
            self.catalog_job = null;
        }
        if (self.probe_job) |job| {
            job.cancel();
            job.join();
            self.drain();
        }
        self.management.stopModelConnections();
    }

    fn assertMainThread(self: *const Coordinator) void {
        std.debug.assert(std.Thread.getCurrentId() == self.main_thread_id);
    }
};

fn managementError(error_code: models_contract.ModelsError) models_contract.ManagementError {
    return switch (error_code) {
        .none => unreachable,
        .authorization_unavailable => .authorization_unavailable,
        .persistence_unavailable, .migration_required => .persistence_unavailable,
        .operation_in_progress => .operation_in_progress,
        .local_resource_exhausted => .local_resource_exhausted,
        .catalog_unavailable,
        .catalog_invalid,
        .catalog_too_large,
        .no_api_keys,
        .no_models,
        => .catalog_unavailable,
    };
}
