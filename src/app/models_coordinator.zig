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
const product_task = @import("metawork_product_task");
const product_workspace = @import("metawork_product_workspace");
const image_output = @import("image_output");
const video_output = @import("video_output");

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
    expected_provider_revision: u64,
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
        command_value: models_contract.CustomModelTestCommand,
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
            .expected_provider_revision = command_value.expected_provider_revision,
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
            .target = .{
                .provider_id = input.target.provider_id,
                .protocol = agent_protocol.toAgent(input.target.protocol),
                .base_url = input.target.base_url,
                .model = input.target.model,
            },
            .credential = input.api_key,
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

    fn command(self: *const ProbeJob) models_contract.CustomModelTestCommand {
        return .{
            .model = .{
                .source_id = self.source_id,
                .model_id = self.model_id,
            },
            .expected_provider_revision = self.expected_provider_revision,
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
        self.* = .{
            .allocator = allocator,
            .io = io,
            .transport = transport,
            .notifier = notifier,
            .attempt_id = preparation.attempt_id,
            .authorization_generation = preparation.authorization_generation,
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
        session.loadModels(
            self.transport,
            self.lease.access_token,
            self.lease.principal_ref,
            control,
        ) catch |err| {
            self.error_code = models_metask.errorCode(err);
            return;
        };
        self.completion = models_metask.OwnedCatalogCompletion.init(&session);
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
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }
};

/// Application binder for Account credential delivery and Models effects.
/// Product Control owns consumer scope and registry/default-selection policy;
/// credential delivery uses a separate port before catalog work.
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
    credential_renewal: ?control_ports.MetaskCredentialRenewal = null,

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

    pub fn metaskAuthorizationCheck(self: *Coordinator) control_ports.MetaskAuthorizationCheck {
        return .{ .context = self, .current_fn = currentMetaskAuthorization };
    }

    fn currentMetaskAuthorization(context: *anyopaque) ?control_ports.MetaskAuthorization {
        const self: *Coordinator = @ptrCast(@alignCast(context));
        self.assertMainThread();
        const state = self.account.authorizationState() orelse return null;
        return .{ .scope = state.scope, .generation = state.generation };
    }

    pub fn imageRunPreparation(self: *Coordinator) control_ports.ImageRunPreparation {
        return .{ .context = self, .prepare_fn = prepareImageRun };
    }

    pub fn videoRunPreparation(self: *Coordinator) control_ports.VideoRunPreparation {
        return .{ .context = self, .prepare_fn = prepareVideoRun };
    }

    const PreparedMedia = struct {
        candidate: models_contract.OwnedMediaCandidate,
        scope: u64,
        generation: u64,
    };

    fn prepareMedia(self: *Coordinator, kind: models_contract.MediaKind) ?PreparedMedia {
        self.assertMainThread();
        const authorization = self.account.authorizationState() orelse return null;
        var lease = (self.account.authorizationLease() catch return null) orelse return null;
        defer lease.deinit();
        if (authorization.generation != lease.authorization_generation) return null;
        const candidate = switch (self.management.prepareMediaCandidate(.{
            .kind = kind,
            .principal_ref = lease.principal_ref,
            .authorization_generation = lease.authorization_generation,
            .bearer = lease.access_token,
        })) {
            .ready => |value| value,
            .rejected => return null,
        };
        return .{ .candidate = candidate, .scope = authorization.scope, .generation = authorization.generation };
    }

    fn prepareImageRun(context: *anyopaque, workspace: product_workspace.TaskAuthority) ?product_task.OwnedImageExecution {
        const self: *Coordinator = @ptrCast(@alignCast(context));
        const transport = self.completion_transport orelse return null;
        var prepared = self.prepareMedia(.image) orelse return null;
        defer prepared.candidate.deinit();
        const allocator = std.heap.c_allocator;
        const output = allocator.create(image_output.Output) catch return null;
        output.* = image_output.Output.init(allocator, self.io, self.main_thread_id, workspace) catch {
            allocator.destroy(output);
            return null;
        };
        var result: product_task.OwnedImageExecution = .{
            .candidate = prepared.candidate.take(),
            .transport = transport,
            .output = output.port(),
            .output_owner = output,
            .release_output_fn = releaseImageOutput,
        };
        result.enableCredentialRenewal(allocator, self.io, prepared.scope, prepared.generation) catch {
            result.deinit();
            return null;
        };
        return result;
    }

    fn prepareVideoRun(context: *anyopaque, workspace: product_workspace.TaskAuthority) ?product_task.OwnedVideoExecution {
        const self: *Coordinator = @ptrCast(@alignCast(context));
        const transport = self.completion_transport orelse return null;
        var prepared = self.prepareMedia(.video) orelse return null;
        defer prepared.candidate.deinit();
        const allocator = std.heap.c_allocator;
        const output = allocator.create(video_output.Output) catch return null;
        output.* = video_output.Output.init(allocator, self.io, self.main_thread_id, workspace) catch {
            allocator.destroy(output);
            return null;
        };
        var result: product_task.OwnedVideoExecution = .{
            .candidate = prepared.candidate.take(),
            .transport = transport,
            .output = output.port(),
            .release_output_fn = releaseVideoOutput,
        };
        result.authorization.enable(allocator, self.io, result.candidate.input().bearer, prepared.scope, prepared.generation) catch {
            result.deinit();
            return null;
        };
        return result;
    }

    fn releaseVideoOutput(context: *anyopaque) void {
        const output: *video_output.Output = @ptrCast(@alignCast(context));
        const allocator = output.allocator;
        output.deinit();
        allocator.destroy(output);
    }

    fn releaseImageOutput(context: *anyopaque) void {
        const output: *image_output.Output = @ptrCast(@alignCast(context));
        const allocator = output.allocator;
        output.deinit();
        allocator.destroy(output);
    }

    fn submitCommand(
        context: *anyopaque,
        command: models_contract.CustomProviderCommand,
    ) models_contract.CommandResult {
        const self: *Coordinator = @ptrCast(@alignCast(context));
        self.assertMainThread();
        if (command == .test_model)
            return self.startProbe(command.test_model);
        return self.management.submitCustomProviderCommand(command);
    }

    fn startProbe(
        self: *Coordinator,
        command: models_contract.CustomModelTestCommand,
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
        var execution = switch (self.management.beginCustomProviderProbe(
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
            _ = self.management.completeCustomModelTest(job.command(), false);
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
        self.management.startCustomProviders(directory, vault) catch
            self.management.startCustomProvidersUnavailable();
    }

    pub fn startUnavailable(self: *Coordinator) void {
        self.assertMainThread();
        self.management.startCustomProvidersUnavailable();
    }

    pub fn setCredentialRenewal(self: *Coordinator, renewal: control_ports.MetaskCredentialRenewal) void {
        self.credential_renewal = renewal;
    }

    fn renewDeferredCredential(self: *Coordinator) void {
        const renewal = self.credential_renewal orelse return;
        const state = self.account.authorizationState() orelse return;
        const authority: control_ports.MetaskAuthorization = .{ .scope = state.scope, .generation = state.generation };
        if (!renewal.needs(authority)) return;
        var lease = (self.account.authorizationLease() catch {
            renewal.renew(authority, null);
            return;
        }) orelse return;
        defer lease.deinit();
        if (lease.authorization_generation != authority.generation) return;
        renewal.renew(authority, lease.access_token);
    }

    fn cancelCatalog(self: *Coordinator) void {
        const job = self.catalog_job orelse return;
        job.cancel();
        job.join();
        self.management.failMetaskCatalogRefresh(job.attempt_id, job.authorization_generation, .authorization_unavailable, "");
        job.deinit();
        self.catalog_job = null;
    }

    pub fn authorizationChanged(self: *Coordinator) void {
        self.assertMainThread();
        // Existing executions renew before any catalog work, using Account
        // authority alone. Catalog failure cannot roll this handoff back.
        var lease = (self.account.authorizationLease() catch {
            if (self.account.authorizationState()) |state| if (self.credential_renewal) |renewal| {
                renewal.renew(.{ .scope = state.scope, .generation = state.generation }, null);
            };
            self.cancelCatalog();
            self.management.setMetaskAuthorizationUnavailable();
            self.observed_authorization_generation = 0;
            return;
        }) orelse {
            self.cancelCatalog();
            if (self.observed_authorization_generation != 0)
                self.management.setMetaskAuthorizationUnavailable();
            self.observed_authorization_generation = 0;
            return;
        };
        defer lease.deinit();
        if (lease.authorization_generation == self.observed_authorization_generation) return;
        if (self.account.authorizationState()) |state| if (self.credential_renewal) |renewal| {
            if (state.generation == lease.authorization_generation)
                renewal.renew(.{ .scope = state.scope, .generation = state.generation }, lease.access_token);
        };
        self.cancelCatalog();
        self.observed_authorization_generation = lease.authorization_generation;
        _ = self.startCatalogJob(&lease);
    }

    pub fn refreshCatalog(self: *Coordinator) models_contract.CommandResult {
        self.assertMainThread();
        if (self.catalog_job != null)
            return .rejected(.operation_in_progress);
        var lease = (self.account.authorizationLease() catch
            return .rejected(.local_resource_exhausted)) orelse {
            self.management.setMetaskAuthorizationUnavailable();
            self.observed_authorization_generation = 0;
            return .rejected(.authorization_unavailable);
        };
        defer lease.deinit();
        self.observed_authorization_generation = lease.authorization_generation;
        return self.startCatalogJob(&lease);
    }

    /// Resets Product-owned Models state through the snapshot CAS boundary,
    /// then lets the normal authorization change path repopulate Metask
    /// catalog data when an account is available. Acceptance only confirms
    /// the durable reset; catalog readiness is observed asynchronously.
    pub fn resetModelsStore(
        self: *Coordinator,
        expected_revision: u64,
    ) models_contract.CommandResult {
        self.assertMainThread();
        if (self.catalog_job != null)
            return .rejected(.operation_in_progress);
        const result = self.management.resetModelStore(expected_revision);
        if (!result.accepted) return result;
        self.observed_authorization_generation = 0;
        self.authorizationChanged();
        return result;
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
            // The Models owner already exposes the precise rejection.
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
        self.renewDeferredCredential();
        if (self.catalog_job) |job| {
            if (job.finished.load(.acquire)) {
                job.join();
                if (self.account.acceptsAuthorizationGeneration(
                    job.authorization_generation,
                )) {
                    if (job.completion) |*completion| {
                        var completion_port = completion.ownedPort();
                        _ = self.management.completeMetaskCatalogRefresh(
                            job.attempt_id,
                            job.authorization_generation,
                            &completion_port,
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
            _ = self.management.completeCustomModelTest(
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
        self.management.stopCustomProviders();
    }

    fn assertMainThread(self: *const Coordinator) void {
        std.debug.assert(std.Thread.getCurrentId() == self.main_thread_id);
    }
};

fn managementError(error_code: models_contract.ModelsError) models_contract.ManagementError {
    return switch (error_code) {
        .none => unreachable,
        .authorization_unavailable => .authorization_unavailable,
        .persistence_unavailable, .preference_not_saved => .persistence_unavailable,
        .operation_in_progress => .operation_in_progress,
        .local_resource_exhausted => .local_resource_exhausted,
        .catalog_unavailable,
        .catalog_invalid,
        .catalog_too_large,
        .no_models,
        => .catalog_unavailable,
    };
}

test "image Run preparation borrows a fresh Account lease and freezes owned output authority" {
    const Fixture = struct {
        available: bool = false,
        reject: bool = false,
        calls: usize = 0,
        expected_generation: u64 = 0,
        expected_token: []const u8 = "image-access-a",
        model: []const u8 = "image-model-a",

        fn prepare(context: *anyopaque, input: models_contract.MediaPreparationInput) models_contract.MediaPreparation {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (!self.available) return .{ .rejected = .model_not_found };
            self.calls += 1;
            std.testing.expectEqualStrings("account-image", input.principal_ref) catch unreachable;
            std.testing.expectEqual(self.expected_generation, input.authorization_generation) catch unreachable;
            std.testing.expectEqualStrings(self.expected_token, input.bearer) catch unreachable;
            if (self.reject) return .{ .rejected = .generation_mismatch };
            return .{ .ready = models_contract.OwnedMediaCandidate.copy(std.testing.allocator, .image, self.model, input.bearer, 7) catch unreachable };
        }
        fn accountHttp(_: *anyopaque, request: account_api.TransportRequest, output: []u8) account_api.TransportError!account_api.TransportResponse {
            if (request.kind != .refresh_token) return error.ProtocolFailed;
            const body = "{\"access_token\":\"image-access-b\",\"refresh_token\":\"synthetic-refresh-b\",\"token_type\":\"Bearer\",\"expires_in\":3600}";
            @memcpy(output[0..body.len], body);
            return .{ .status = 200, .body = output[0..body.len] };
        }
        fn modelsHttp(_: *anyopaque, _: metask_transport.Request, _: []u8) metask_transport.TransportError!metask_transport.Response {
            @panic("image preparation must not refresh the catalog");
        }
        fn imageHttp(_: ?*anyopaque, _: agent.CompletionHttpRequest, _: *const agent.CompletionCancellation, _: []u8) agent.CompletionTransportError!agent.CompletionTransportResponse {
            @panic("image preparation must not generate or reserve a file");
        }
        fn wake(_: *anyopaque) void {}
    };
    var fixture: Fixture = .{};
    var account = account_api.Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId(), .{ .context = &fixture, .perform_fn = Fixture.accountHttp }, account_api.TestSupport.loopbackEndpoint(), .{ .context = &fixture, .notify_fn = Fixture.wake });
    var platform: account_api.TestSupport.Platform = .{ .now_unix_seconds = 100 };
    account_api.TestSupport.attachPlatform(&account, &platform);
    defer {
        account_api.TestSupport.detachPlatform(&account);
        account.deinit();
    }
    var authenticated = try account_api.TestSupport.prepareAuthenticated(&account, "account-image", "Image User", fixture.expected_token, "synthetic-refresh", 200);
    defer authenticated.deinit();
    account.commit(&authenticated);
    var lease = (try account.authorizationLease()).?;
    fixture.expected_generation = lease.authorization_generation;
    lease.deinit();
    // This unit observes only the two image management methods; catalog and
    // selection behavior are independently tested against the real Models owner.
    var management: control_ports.ModelsManagement = undefined;
    management.context = &fixture;
    management.prepare_media_candidate_fn = Fixture.prepare;
    var coordinator = Coordinator.init(&account, .{ .context = &fixture, .perform_fn = Fixture.modelsHttp }, management, std.Thread.getCurrentId(), std.testing.io);
    coordinator.setCompletionTransport(.{ .perform_fn = Fixture.imageHttp });
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root);
    const authority: product_workspace.TaskAuthority = .{ .id = 5, .epoch = 2, .kind = .manual, .canonical_root = root[0..root_len], .trust = .explicitly_trusted };
    const port = coordinator.imageRunPreparation();
    try std.testing.expect(port.prepare(authority) == null);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    fixture.available = true;
    var first = port.prepare(authority).?;
    defer first.deinit();
    try std.testing.expectEqualStrings(models_contract.metask_images_generations_url, first.input().binding.endpoint);
    try std.testing.expectEqualStrings("image-model-a", first.input().binding.model);
    try std.testing.expectEqualStrings("image-access-a", first.input().binding.credential);
    const output: *image_output.Output = @ptrCast(@alignCast(first.output_owner));
    @memset(root[0..root_len], 'x');
    try std.testing.expect(!std.mem.eql(u8, root[0..root_len], output.root));
    // Hard expiry requires no Account notification or cached-view change.
    platform.now_unix_seconds = 200;
    try std.testing.expect(port.prepare(authority) == null);
    platform.now_unix_seconds = null;
    try std.testing.expect(port.prepare(authority) == null);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    platform.now_unix_seconds = 150;
    fixture.expected_token = "image-access-b";
    fixture.model = "image-model-b";
    // Drive the real Account refresh transition with a synthetic in-process
    // transport. Image preparation itself never dispatches Account work.
    var refresh = switch (account.prepareTokenRefresh()) {
        .prepared => |value| value,
        else => return error.TestUnexpectedResult,
    };
    defer refresh.deinit();
    try std.testing.expect(account.admitEffect(&refresh));
    account.commit(&refresh);
    try std.testing.expect(account.dispatchCommitted(&refresh) == null);
    account_api.TestSupport.joinNetwork(&account);
    var rotated = switch (account.prepareNextCompletion().?) {
        .prepared => |value| value,
        else => return error.TestUnexpectedResult,
    };
    defer rotated.deinit();
    account.commit(&rotated);
    lease = (try account.authorizationLease()).?;
    fixture.expected_generation = lease.authorization_generation;
    lease.deinit();
    _ = try tmp.dir.realPath(std.testing.io, &root);
    var second = port.prepare(authority).?;
    defer second.deinit();
    try std.testing.expectEqualStrings("image-access-b", second.input().binding.credential);
    try std.testing.expectEqualStrings("image-model-b", second.input().binding.model);
    try std.testing.expectEqualStrings("image-access-a", first.input().binding.credential);
    fixture.reject = true;
    try std.testing.expect(port.prepare(authority) == null);
    fixture.available = false;
    try std.testing.expect(port.prepare(authority) == null);
    try std.testing.expectEqual(@as(usize, 3), fixture.calls);
    var logged_out = account_api.TestSupport.prepareLoggedOutAfterExternalCommit(&account);
    defer logged_out.deinit();
    account.commit(&logged_out);
    fixture.available = true;
    try std.testing.expect(port.prepare(authority) == null);
    try std.testing.expectEqual(@as(usize, 3), fixture.calls);
    try std.testing.expectEqualStrings("image-access-a", first.input().binding.credential);
}
