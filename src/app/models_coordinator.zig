const std = @import("std");
const agent = @import("metawork_agent");
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
    request_id: u64,
    authorization_generation: u64,
    lease: account_contract.OwnedAuthorizationLease,
    lease_active: bool = true,
    cancellation: metask_transport.Cancellation,
    completion: ?models_metask.OwnedCatalogCompletion = null,
    failure: models_contract.CatalogFailure = .{ .code = .catalog_invalid, .retryable = false },
    unauthorized: ?account_contract.UnauthorizedReport = null,
    finished: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        transport: metask_transport.Transport,
        notifier: ProbeNotifier,
        request_id: u64,
        lease: *account_contract.OwnedAuthorizationLease,
    ) std.mem.Allocator.Error!*CatalogJob {
        const self = try allocator.create(CatalogJob);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .transport = transport,
            .notifier = notifier,
            .request_id = request_id,
            .authorization_generation = lease.authorization_generation,
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
            // What it means for the next try is Models' to say.
            self.failure = models_metask.failure(err);
            // The gateway's reason is not parsed: Account asks Metask itself.
            if (err == error.Unauthorized) if (self.unauthorized) |report| report.report(self.authorization_generation, .other);
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

/// The one platform timer the catalog uses.
pub const timer_id: u64 = 0x4d57_4d44;

/// Application binder for Models effects. Product Control owns consumer scope
/// and registry/default-selection policy; Account is one borrowed credential
/// per operation and the authorization each of its commits leaves. When to
/// ask for the Metask catalog, whether to retry and what anyone sees are
/// Models' own: this binder runs the timer and the request it is told to.
pub const Coordinator = struct {
    pub const Host = struct {
        context: ?*anyopaque,
        now_ns_fn: *const fn (?*anyopaque) u64,
        start_timer_fn: *const fn (?*anyopaque, u64, u64, bool) anyerror!void,
        cancel_timer_fn: *const fn (?*anyopaque, u64) anyerror!void,
    };

    io: std.Io,
    credentials: account_contract.CredentialSource,
    metask_transport: metask_transport.Transport,
    management: control_ports.ModelsManagement,
    main_thread_id: std.Thread.Id,
    probe_notifier: ?ProbeNotifier = null,
    completion_transport: ?agent.CompletionTransport = null,
    probe_job: ?*ProbeJob = null,
    catalog_job: ?*CatalogJob = null,
    host: ?Host = null,
    /// Where a 401 on the Account token goes.
    unauthorized: ?account_contract.UnauthorizedReport = null,

    pub fn init(
        credentials: account_contract.CredentialSource,
        transport: metask_transport.Transport,
        management: control_ports.ModelsManagement,
        main_thread_id: std.Thread.Id,
        io: std.Io,
    ) Coordinator {
        return .{
            .io = io,
            .credentials = credentials,
            .metask_transport = transport,
            .management = management,
            .main_thread_id = main_thread_id,
        };
    }

    pub fn setProbeNotifier(self: *Coordinator, notifier: ?ProbeNotifier) void {
        self.probe_notifier = notifier;
    }

    pub fn setUnauthorizedReport(self: *Coordinator, report: account_contract.UnauthorizedReport) void {
        self.unauthorized = report;
    }

    pub fn setHost(self: *Coordinator, host: Host) void {
        self.host = host;
    }

    /// MetaWork came to the front or left it; the beat runs only in front.
    pub fn setActive(self: *Coordinator, active: bool) void {
        self.assertMainThread();
        self.management.setMetaskCatalogActive(active);
        self.reconcile();
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

    /// Models' Metask credential port over Account's one way out for the
    /// current credential: each read takes one lease, copies it into the
    /// reader's storage and zeroes it at once.
    pub fn metaskCredentials(self: *Coordinator) models_ports.MetaskCredentials {
        return .{ .context = self, .read_fn = readMetaskCredential };
    }

    fn readMetaskCredential(context: *anyopaque, account_storage: []u8, token_storage: []u8) std.mem.Allocator.Error!?models_ports.MetaskCredential {
        const self: *Coordinator = @ptrCast(@alignCast(context));
        self.assertMainThread();
        var lease = (try self.credentials.take()) orelse return null;
        defer lease.deinit();
        if (lease.principal_ref.len > account_storage.len or lease.access_token.len > token_storage.len) return null;
        @memcpy(account_storage[0..lease.principal_ref.len], lease.principal_ref);
        @memcpy(token_storage[0..lease.access_token.len], lease.access_token);
        return .{
            .account = account_storage[0..lease.principal_ref.len],
            .token = token_storage[0..lease.access_token.len],
            .generation = lease.authorization_generation,
        };
    }

    pub fn imageRunPreparation(self: *Coordinator) control_ports.ImageRunPreparation {
        return .{ .context = self, .prepare_fn = prepareImageRun };
    }

    pub fn videoRunPreparation(self: *Coordinator) control_ports.VideoRunPreparation {
        return .{ .context = self, .prepare_fn = prepareVideoRun };
    }

    const PreparedMedia = struct {
        candidate: models_contract.OwnedMediaCandidate,
        generation: u64,
    };

    fn prepareMedia(self: *Coordinator, kind: models_contract.MediaKind) ?PreparedMedia {
        self.assertMainThread();
        // Models takes the credential of this moment through its port, as
        // it does for dialogue; the candidate carries its generation.
        const candidate = switch (self.management.prepareMediaCandidate(kind)) {
            .ready => |value| value,
            .rejected => return null,
        };
        return .{ .candidate = candidate, .generation = candidate.credential_generation };
    }

    /// A media execution's output and the transport it sends through, which
    /// tells Account of a 401 on the token it sends now: a renewal of the
    /// Run replaces it, and its generation with it.
    fn MediaOwner(comptime Output: type) type {
        return struct {
            output: Output,
            inner: agent.CompletionTransport,
            unauthorized: ?account_contract.UnauthorizedReport,
            generation: ?product_task.MediaCredentialGeneration = null,

            const Owner = @This();

            fn create(coordinator: *Coordinator, workspace: product_workspace.TaskAuthority, inner: agent.CompletionTransport) ?*Owner {
                const allocator = std.heap.c_allocator;
                const owner = allocator.create(Owner) catch return null;
                owner.* = .{
                    .output = Output.init(allocator, coordinator.io, coordinator.main_thread_id, workspace) catch {
                        allocator.destroy(owner);
                        return null;
                    },
                    .inner = inner,
                    .unauthorized = coordinator.unauthorized,
                };
                return owner;
            }

            fn follow(self: *Owner, credentials: *const product_task.MediaCredentials) void {
                self.generation = credentials.watchGeneration();
            }

            fn transport(self: *Owner) agent.CompletionTransport {
                return .{
                    .context = self,
                    .perform_fn = perform,
                    .signal_cancellation_fn = if (self.inner.signal_cancellation_fn != null) signal else null,
                };
            }

            fn perform(context: ?*anyopaque, request: agent.CompletionHttpRequest, cancellation: *const agent.CompletionCancellation, buffer: []u8) agent.CompletionTransportError!agent.CompletionTransportResponse {
                const self: *Owner = @ptrCast(@alignCast(context.?));
                const response = try self.inner.perform(request, cancellation, buffer);
                if (response.status == 401) if (self.unauthorized) |report| if (self.generation) |generation|
                    report.report(generation.current(), .other);
                return response;
            }

            fn signal(context: ?*anyopaque, cancellation: *agent.CompletionCancellation) void {
                const self: *Owner = @ptrCast(@alignCast(context.?));
                self.inner.signal_cancellation_fn.?(self.inner.context, cancellation);
            }

            fn release(context: *anyopaque) void {
                const self: *Owner = @ptrCast(@alignCast(context));
                if (self.generation) |*generation| generation.deinit();
                self.output.deinit();
                std.heap.c_allocator.destroy(self);
            }

            /// For an execution that releases what its output port points at.
            fn releaseOutput(context: *anyopaque) void {
                const output: *Output = @ptrCast(@alignCast(context));
                release(@as(*Owner, @fieldParentPtr("output", output)));
            }
        };
    }

    const ImageOwner = MediaOwner(image_output.Output);
    const VideoOwner = MediaOwner(video_output.Output);

    fn prepareImageRun(context: *anyopaque, workspace: product_workspace.TaskAuthority) ?product_task.OwnedImageExecution {
        const self: *Coordinator = @ptrCast(@alignCast(context));
        const transport = self.completion_transport orelse return null;
        var prepared = self.prepareMedia(.image) orelse return null;
        defer prepared.candidate.deinit();
        const allocator = std.heap.c_allocator;
        const owner = ImageOwner.create(self, workspace, transport) orelse return null;
        var result: product_task.OwnedImageExecution = .{
            .candidate = prepared.candidate.take(),
            .transport = owner.transport(),
            .output = owner.output.port(),
            .output_owner = owner,
            .release_output_fn = ImageOwner.release,
        };
        result.enableCredentialRenewal(allocator, self.io, prepared.generation) catch {
            result.deinit();
            return null;
        };
        owner.follow(&result.authorization);
        return result;
    }

    fn prepareVideoRun(context: *anyopaque, workspace: product_workspace.TaskAuthority) ?product_task.OwnedVideoExecution {
        const self: *Coordinator = @ptrCast(@alignCast(context));
        const transport = self.completion_transport orelse return null;
        var prepared = self.prepareMedia(.video) orelse return null;
        defer prepared.candidate.deinit();
        const allocator = std.heap.c_allocator;
        const owner = VideoOwner.create(self, workspace, transport) orelse return null;
        var result: product_task.OwnedVideoExecution = .{
            .candidate = prepared.candidate.take(),
            .transport = owner.transport(),
            .output = owner.output.port(),
            .release_output_fn = VideoOwner.releaseOutput,
        };
        result.authorization.enable(allocator, self.io, result.candidate.input().bearer, prepared.generation) catch {
            result.deinit();
            return null;
        };
        owner.follow(&result.authorization);
        return result;
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

    /// A request for an account no longer followed is only cancelled:
    /// waiting for it here would hold the main thread for as long as the
    /// network does. It keeps the slot until it ends, and `drain` hands
    /// Models what it brings, which Models discards by its number.
    fn cancelCatalog(self: *Coordinator) void {
        const job = self.catalog_job orelse return;
        job.cancel();
    }

    fn nowMs(self: *const Coordinator) u64 {
        const host = self.host orelse return 0;
        return host.now_ns_fn(host.context) / std.time.ns_per_ms;
    }

    /// Follows the authorization an Account publication leaves. Models
    /// keeps the catalog for the account and decides whether anything is
    /// due; a new credential for the same account asks for nothing here.
    pub fn follow(self: *Coordinator, authorization: account_contract.Authorization) void {
        self.assertMainThread();
        switch (authorization) {
            .checking, .recovering => {},
            .signed_out => if (self.management.followMetaskPrincipal(null, 0).dropped) self.cancelCatalog(),
            .available => |current| if (self.management.followMetaskPrincipal(current.account_id, current.generation).dropped) self.cancelCatalog(),
        }
        self.reconcile();
    }

    pub fn refreshCatalog(self: *Coordinator) models_contract.CommandResult {
        self.assertMainThread();
        const result = self.requestCatalog(.user);
        self.reconcile();
        return result;
    }

    /// Resets Product-owned Models state through the snapshot CAS boundary.
    /// The Metask catalog never stood on models.json, so a request underway
    /// goes on; acceptance only confirms the durable reset.
    pub fn resetModelsStore(
        self: *Coordinator,
        expected_revision: u64,
    ) models_contract.CommandResult {
        self.assertMainThread();
        const result = self.management.resetModelStore(expected_revision);
        if (result.accepted) self.reconcile();
        return result;
    }

    /// One catalog request, when Models finds it due or the person asks.
    /// The person asking while one is underway makes it theirs.
    fn requestCatalog(self: *Coordinator, kind: models_contract.CatalogRequestKind) models_contract.CommandResult {
        if (self.catalog_job != null) {
            if (kind == .due) return .rejected(.operation_in_progress);
            _ = self.management.joinMetaskCatalogRequest();
            return .acceptedResult();
        }
        const now = self.nowMs();
        var lease: ?account_contract.OwnedAuthorizationLease = null;
        defer if (lease) |*value| value.deinit();
        const credential: models_contract.CatalogCredential = if (self.credentials.take()) |taken| credential: {
            lease = taken;
            const value = if (lease) |*held| held else break :credential .unavailable;
            break :credential .{ .ready = .{ .principal_ref = value.principal_ref, .generation = value.authorization_generation } };
        } else |_| .exhausted;
        const id = switch (self.management.beginMetaskCatalogRequest(kind, credential, now).outcome) {
            .started => |value| value,
            .skipped => return .acceptedResult(),
            .rejected => |error_code| return .rejected(managementError(error_code)),
        };
        const notifier = self.probe_notifier orelse {
            _ = self.management.failMetaskCatalogRequest(id, .{ .code = .catalog_unavailable, .retryable = false }, now);
            return .rejected(.catalog_unavailable);
        };
        const job = CatalogJob.create(std.heap.c_allocator, self.io, self.metask_transport, notifier, id, &lease.?) catch {
            _ = self.management.failMetaskCatalogRequest(id, .{ .code = .local_resource_exhausted, .retryable = false }, now);
            return .rejected(.local_resource_exhausted);
        };
        job.unauthorized = self.unauthorized;
        job.start() catch {
            _ = self.management.failMetaskCatalogRequest(id, .{ .code = .local_resource_exhausted, .retryable = false }, now);
            job.deinit();
            return .rejected(.local_resource_exhausted);
        };
        self.catalog_job = job;
        return .acceptedResult();
    }

    /// Sends what Models finds due, then arms the one timer for the next
    /// time Models names. Any wake passes here, so a timer that ran late or
    /// slept through a suspend changes only when, never whether.
    fn reconcile(self: *Coordinator) void {
        // Without a timer only what is due at once is sent: a load, never a
        // retry or a beat.
        if (self.catalog_job == null and self.management.metaskCatalogDue(self.nowMs())) _ = self.requestCatalog(.due);
        const host = self.host orelse return;
        // A request underway wakes the drain when it lands.
        if (self.catalog_job != null) return host.cancel_timer_fn(host.context, timer_id) catch {};
        const at = self.management.metaskCatalogNext() orelse return host.cancel_timer_fn(host.context, timer_id) catch {};
        const wait_ms = @max(1, at -| self.nowMs());
        host.start_timer_fn(host.context, timer_id, wait_ms *| std.time.ns_per_ms, false) catch {};
    }

    pub fn onTimer(self: *Coordinator) void {
        self.assertMainThread();
        self.reconcile();
    }

    pub fn drain(self: *Coordinator) void {
        self.assertMainThread();
        if (self.catalog_job) |job| {
            if (job.finished.load(.acquire)) {
                job.join();
                const now = self.nowMs();
                // A job another account superseded was cancelled when that
                // commit was followed; Models no longer knows its number.
                if (job.completion) |*completion| {
                    var completion_port = completion.ownedPort();
                    _ = self.management.completeMetaskCatalogRequest(job.request_id, &completion_port, now);
                    job.completion = null;
                } else {
                    _ = self.management.failMetaskCatalogRequest(job.request_id, job.failure, now);
                }
                self.catalog_job = null;
                job.deinit();
                self.reconcile();
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
        if (self.host) |host| host.cancel_timer_fn(host.context, timer_id) catch {};
        self.host = null;
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
        .persistence_unavailable, .credentials_retained => .persistence_unavailable,
        .operation_in_progress => .operation_in_progress,
        .local_resource_exhausted => .local_resource_exhausted,
        .catalog_unavailable,
        .account_suspended,
        .catalog_invalid,
        .catalog_too_large,
        .no_models,
        => .catalog_unavailable,
    };
}

test "a catalog refused for its token is worth a second try, one refused for the account is not" {
    const Fixture = struct {
        status: u16,
        failed: ?models_contract.CatalogFailure = null,
        reported: ?u64 = null,

        fn take(_: *anyopaque) std.mem.Allocator.Error!?account_contract.OwnedAuthorizationLease {
            return account_contract.OwnedAuthorizationLease.init(std.testing.allocator, "account-catalog", "catalog-access", 3) catch |err| switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => unreachable,
            };
        }
        fn begin(_: *anyopaque, kind: models_contract.CatalogRequestKind, credential: models_contract.CatalogCredential, _: u64) models_contract.CatalogRequestStart {
            std.debug.assert(kind == .user);
            std.testing.expectEqualStrings("account-catalog", credential.ready.principal_ref) catch unreachable;
            std.testing.expectEqual(@as(u64, 3), credential.ready.generation) catch unreachable;
            return .{ .outcome = .{ .started = 1 }, .changed = true };
        }
        fn fail(context: *anyopaque, id: u64, failure: models_contract.CatalogFailure, _: u64) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            std.debug.assert(id == 1);
            self.failed = failure;
            return true;
        }
        fn modelsHttp(context: *anyopaque, _: metask_transport.Request, _: []u8) metask_transport.TransportError!metask_transport.Response {
            const self: *@This() = @ptrCast(@alignCast(context));
            return .{ .status = self.status, .body = "" };
        }
        fn notDue(_: *anyopaque, _: u64) bool {
            return false;
        }
        fn notify(_: *anyopaque) void {}
        fn report(context: *anyopaque, generation: u64, kind: account_contract.Unauthorized) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            std.debug.assert(kind == .other);
            self.reported = generation;
        }
    };
    for ([_]u16{ 401, 403 }) |status| {
        var fixture: Fixture = .{ .status = status };
        var management: control_ports.ModelsManagement = undefined;
        management.context = &fixture;
        management.begin_metask_catalog_request_fn = Fixture.begin;
        management.fail_metask_catalog_request_fn = Fixture.fail;
        management.metask_catalog_due_fn = Fixture.notDue;
        var coordinator = Coordinator.init(.{ .context = &fixture, .take_fn = Fixture.take }, .{ .context = &fixture, .perform_fn = Fixture.modelsHttp }, management, std.Thread.getCurrentId(), std.testing.io);
        coordinator.setProbeNotifier(.{ .context = &fixture, .notify_fn = Fixture.notify });
        coordinator.setUnauthorizedReport(.{ .context = &fixture, .report_fn = Fixture.report });
        try std.testing.expect(coordinator.refreshCatalog().accepted);
        while (!coordinator.catalog_job.?.finished.load(.acquire)) try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        coordinator.drain();
        // Neither ends the login here; only Account may. Whether and when
        // to try again is Models' to decide from its classification.
        try std.testing.expectEqual(@as(models_contract.ModelsError, if (status == 401) .catalog_unavailable else .account_suspended), fixture.failed.?.code);
        try std.testing.expectEqual(status == 401, fixture.failed.?.retryable);
        // Account hears of the refused token, with the generation it was.
        try std.testing.expectEqual(@as(?u64, if (status == 401) 3 else null), fixture.reported);
    }
}

test "the catalog timer runs only when Models names a time, and a renewal asks for nothing" {
    const Fixture = struct {
        now_ms: u64 = 1_000,
        next: ?u64 = null,
        followed: usize = 0,
        begun: usize = 0,
        joined: usize = 0,
        settled: usize = 0,
        armed_ms: ?u64 = null,
        hold: std.atomic.Value(bool) = .init(true),

        fn take(_: *anyopaque) std.mem.Allocator.Error!?account_contract.OwnedAuthorizationLease {
            return account_contract.OwnedAuthorizationLease.init(std.testing.allocator, "account-timer", "timer-access", 4) catch |err| switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => unreachable,
            };
        }
        fn follow(context: *anyopaque, principal: ?[]const u8, generation: u64) models_contract.MetaskFollow {
            const self: *@This() = @ptrCast(@alignCast(context));
            std.testing.expectEqualStrings("account-timer", principal.?) catch unreachable;
            std.debug.assert(generation == 5);
            self.followed += 1;
            return .{ .changed = false, .dropped = false };
        }
        fn nextFn(context: *anyopaque) ?u64 {
            const self: *@This() = @ptrCast(@alignCast(context));
            return self.next;
        }
        fn due(context: *anyopaque, now_ms: u64) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            return now_ms >= (self.next orelse return false);
        }
        fn begin(context: *anyopaque, kind: models_contract.CatalogRequestKind, _: models_contract.CatalogCredential, _: u64) models_contract.CatalogRequestStart {
            const self: *@This() = @ptrCast(@alignCast(context));
            std.debug.assert(kind == .due);
            self.begun += 1;
            self.next = null;
            return .{ .outcome = .{ .started = 1 }, .changed = false };
        }
        fn join(context: *anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.joined += 1;
            return true;
        }
        fn complete(context: *anyopaque, id: u64, completion: *models_ports.OwnedCatalogCompletion, now_ms: u64) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            std.debug.assert(id == 1);
            completion.deinit();
            self.settled += 1;
            self.next = now_ms + models_metask.refresh_interval_ms;
            return false;
        }
        fn modelsHttp(context: *anyopaque, _: metask_transport.Request, output: []u8) metask_transport.TransportError!metask_transport.Response {
            const self: *@This() = @ptrCast(@alignCast(context));
            while (self.hold.load(.acquire)) std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch return error.NetworkFailed;
            const body = "{\"object\":\"list\",\"has_more\":false,\"data\":[]}";
            @memcpy(output[0..body.len], body);
            return .{ .status = 200, .body = output[0..body.len] };
        }
        fn notify(_: *anyopaque) void {}
        fn now(context: ?*anyopaque) u64 {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            return self.now_ms * std.time.ns_per_ms;
        }
        fn start(context: ?*anyopaque, id: u64, ns: u64, repeats: bool) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            std.debug.assert(id == timer_id and !repeats);
            self.armed_ms = ns / std.time.ns_per_ms;
        }
        fn cancel(context: ?*anyopaque, id: u64) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            std.debug.assert(id == timer_id);
            self.armed_ms = null;
        }
    };
    var fixture: Fixture = .{ .next = 6_000 };
    var management: control_ports.ModelsManagement = undefined;
    management.context = &fixture;
    management.follow_metask_principal_fn = Fixture.follow;
    management.metask_catalog_next_fn = Fixture.nextFn;
    management.metask_catalog_due_fn = Fixture.due;
    management.begin_metask_catalog_request_fn = Fixture.begin;
    management.join_metask_catalog_request_fn = Fixture.join;
    management.complete_metask_catalog_request_fn = Fixture.complete;
    var coordinator = Coordinator.init(.{ .context = &fixture, .take_fn = Fixture.take }, .{ .context = &fixture, .perform_fn = Fixture.modelsHttp }, management, std.Thread.getCurrentId(), std.testing.io);
    coordinator.setProbeNotifier(.{ .context = &fixture, .notify_fn = Fixture.notify });
    coordinator.setHost(.{ .context = &fixture, .now_ns_fn = Fixture.now, .start_timer_fn = Fixture.start, .cancel_timer_fn = Fixture.cancel });
    // A renewal is followed, and asks for nothing: Models names no time
    // before its own, so the timer waits for that.
    coordinator.follow(.{ .available = .{ .account_id = "account-timer", .generation = 5 } });
    try std.testing.expectEqual(@as(usize, 1), fixture.followed);
    try std.testing.expectEqual(@as(usize, 0), fixture.begun);
    try std.testing.expectEqual(@as(?u64, 5_000), fixture.armed_ms);
    // Early, a timer sends nothing; at the time Models named, it sends once.
    fixture.now_ms = 5_999;
    coordinator.onTimer();
    try std.testing.expectEqual(@as(usize, 0), fixture.begun);
    fixture.now_ms = 6_000;
    coordinator.onTimer();
    try std.testing.expectEqual(@as(usize, 1), fixture.begun);
    // No timer runs while the request does.
    try std.testing.expectEqual(@as(?u64, null), fixture.armed_ms);
    // The person asking meanwhile makes that request theirs; there is
    // still one.
    try std.testing.expect(coordinator.refreshCatalog().accepted);
    try std.testing.expectEqual(@as(usize, 1), fixture.joined);
    try std.testing.expectEqual(@as(usize, 1), fixture.begun);
    fixture.hold.store(false, .release);
    while (!coordinator.catalog_job.?.finished.load(.acquire)) try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    coordinator.drain();
    try std.testing.expectEqual(@as(usize, 1), fixture.settled);
    try std.testing.expect(coordinator.catalog_job == null);
    try std.testing.expectEqual(@as(?u64, models_metask.refresh_interval_ms), fixture.armed_ms);
}

test "a catalog request takes a credential only when due, and goes with the account it was for" {
    const Fixture = struct {
        due_now: bool = false,
        dropped: bool = false,
        account: []const u8 = "account-drop",
        taken: usize = 0,
        begun: usize = 0,
        failed: ?u64 = null,
        cancelled: std.atomic.Value(bool) = .init(false),
        released: std.atomic.Value(bool) = .init(false),

        fn take(context: *anyopaque) std.mem.Allocator.Error!?account_contract.OwnedAuthorizationLease {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.taken += 1;
            return account_contract.OwnedAuthorizationLease.init(std.testing.allocator, self.account, "drop-access", 4) catch |err| switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => unreachable,
            };
        }
        fn follow(context: *anyopaque, _: ?[]const u8, _: u64) models_contract.MetaskFollow {
            const self: *@This() = @ptrCast(@alignCast(context));
            return .{ .changed = self.dropped, .dropped = self.dropped };
        }
        fn due(context: *anyopaque, _: u64) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            return self.due_now;
        }
        fn begin(context: *anyopaque, _: models_contract.CatalogRequestKind, _: models_contract.CatalogCredential, _: u64) models_contract.CatalogRequestStart {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.begun += 1;
            self.due_now = false;
            return .{ .outcome = .{ .started = self.begun }, .changed = false };
        }
        fn fail(context: *anyopaque, id: u64, _: models_contract.CatalogFailure, _: u64) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.failed = id;
            return false;
        }
        /// Underway until cancelled, then until let go (at most two seconds).
        fn modelsHttp(context: *anyopaque, request: metask_transport.Request, _: []u8) metask_transport.TransportError!metask_transport.Response {
            const self: *@This() = @ptrCast(@alignCast(context));
            request.control.?.cancellation.wait();
            self.cancelled.store(true, .release);
            var waited: usize = 0;
            while (!self.released.load(.acquire) and waited < 2_000) : (waited += 1) std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch break;
            return error.Cancelled;
        }
        fn notify(_: *anyopaque) void {}
    };
    var fixture: Fixture = .{};
    var management: control_ports.ModelsManagement = undefined;
    management.context = &fixture;
    management.follow_metask_principal_fn = Fixture.follow;
    management.metask_catalog_due_fn = Fixture.due;
    management.begin_metask_catalog_request_fn = Fixture.begin;
    management.fail_metask_catalog_request_fn = Fixture.fail;
    var coordinator = Coordinator.init(.{ .context = &fixture, .take_fn = Fixture.take }, .{ .context = &fixture, .perform_fn = Fixture.modelsHttp }, management, std.Thread.getCurrentId(), std.testing.io);
    coordinator.setProbeNotifier(.{ .context = &fixture, .notify_fn = Fixture.notify });
    const available: account_contract.Authorization = .{ .available = .{ .account_id = "account-drop", .generation = 4 } };
    // Nothing due: no credential is taken, on a publication or a wake.
    coordinator.follow(available);
    coordinator.onTimer();
    try std.testing.expectEqual(@as(usize, 0), fixture.taken);
    try std.testing.expectEqual(@as(usize, 0), fixture.begun);
    fixture.due_now = true;
    coordinator.onTimer();
    try std.testing.expectEqual(@as(usize, 1), fixture.taken);
    try std.testing.expectEqual(@as(usize, 1), fixture.begun);
    // A publication that keeps the account leaves the request alone.
    coordinator.follow(available);
    try std.testing.expect(coordinator.catalog_job != null);
    try std.testing.expect(!fixture.cancelled.load(.acquire));
    // One that drops it cancels the request and returns without waiting
    // for it.
    fixture.dropped = true;
    coordinator.follow(.signed_out);
    try std.testing.expect(coordinator.catalog_job != null);
    try std.testing.expect(!coordinator.catalog_job.?.finished.load(.acquire));
    // The next account's due request waits while the old one holds the slot.
    fixture.dropped = false;
    fixture.account = "account-next";
    fixture.due_now = true;
    coordinator.follow(.{ .available = .{ .account_id = "account-next", .generation = 5 } });
    try std.testing.expectEqual(@as(usize, 1), fixture.begun);
    // Once it ends, Models hears its number and frees it, its credential
    // copy included; the due request then goes with the next account.
    fixture.released.store(true, .release);
    while (!coordinator.catalog_job.?.finished.load(.acquire)) try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    try std.testing.expect(fixture.cancelled.load(.acquire));
    coordinator.drain();
    try std.testing.expectEqual(@as(?u64, 1), fixture.failed);
    try std.testing.expectEqual(@as(u64, 2), coordinator.catalog_job.?.request_id);
    try std.testing.expectEqualStrings("account-next", coordinator.catalog_job.?.lease.principal_ref);
    // That one goes the same way, and leaves the slot empty.
    fixture.dropped = true;
    coordinator.follow(.signed_out);
    while (!coordinator.catalog_job.?.finished.load(.acquire)) try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    coordinator.drain();
    try std.testing.expect(coordinator.catalog_job == null);
    try std.testing.expectEqual(@as(usize, 2), fixture.taken);
}

test "a media request refused for its token tells Account the generation it sends" {
    const Fixture = struct {
        status: u16 = 401,
        reported: ?u64 = null,
        const Stub = struct {
            fn init(_: std.mem.Allocator, _: std.Io, _: std.Thread.Id, _: product_workspace.TaskAuthority) !Stub {
                return .{};
            }
            fn deinit(_: *Stub) void {}
        };
        fn take(_: *anyopaque) std.mem.Allocator.Error!?account_contract.OwnedAuthorizationLease {
            return null;
        }
        fn modelsHttp(_: *anyopaque, _: metask_transport.Request, _: []u8) metask_transport.TransportError!metask_transport.Response {
            return error.ProtocolFailed;
        }
        fn media(context: ?*anyopaque, _: agent.CompletionHttpRequest, _: *const agent.CompletionCancellation, _: []u8) agent.CompletionTransportError!agent.CompletionTransportResponse {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            return .{ .status = self.status, .body = "" };
        }
        fn report(context: *anyopaque, generation: u64, kind: account_contract.Unauthorized) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            std.debug.assert(kind == .other);
            self.reported = generation;
        }
    };
    var fixture: Fixture = .{};
    var management: control_ports.ModelsManagement = undefined;
    management.context = &fixture;
    var coordinator = Coordinator.init(.{ .context = &fixture, .take_fn = Fixture.take }, .{ .context = &fixture, .perform_fn = Fixture.modelsHttp }, management, std.Thread.getCurrentId(), std.testing.io);
    coordinator.setUnauthorizedReport(.{ .context = &fixture, .report_fn = Fixture.report });
    const Owner = Coordinator.MediaOwner(Fixture.Stub);
    const authority: product_workspace.TaskAuthority = .{ .id = 5, .epoch = 2, .kind = .manual, .canonical_root = "", .trust = .explicitly_trusted };
    const owner = Owner.create(&coordinator, authority, .{ .context = &fixture, .perform_fn = Fixture.media }).?;
    defer Owner.release(owner);
    var credentials: product_task.MediaCredentials = .{};
    try credentials.enable(std.testing.allocator, std.testing.io, "token-a", 7);
    defer credentials.source.?.release();
    owner.follow(&credentials);
    var cancellation: agent.CompletionCancellation = .{};
    var buffer: [8]u8 = undefined;
    for ([_]u16{ 200, 401 }) |status| {
        fixture.status = status;
        const response = try owner.transport().perform(.{ .url = "https://www.metask-ai.com/v1/images/generations", .headers = &.{}, .body = "", .connect_timeout_ms = 1000, .source = "metask" }, &cancellation, &buffer);
        // The answer itself goes on unchanged.
        try std.testing.expectEqual(status, response.status);
        try std.testing.expectEqual(@as(?u64, if (status == 401) 7 else null), fixture.reported);
    }
    // Renewed, the Run sends the next generation's token, and that is the
    // generation refused.
    credentials.source.?.replaceAt("token-b", 8);
    _ = try owner.transport().perform(.{ .url = "https://www.metask-ai.com/v1/images/generations", .headers = &.{}, .body = "", .connect_timeout_ms = 1000, .source = "metask" }, &cancellation, &buffer);
    try std.testing.expectEqual(@as(?u64, 8), fixture.reported);
}

test "image Run preparation renews from the candidate's own generation and freezes owned output authority" {
    const Fixture = struct {
        available: bool = false,
        reject: bool = false,
        calls: usize = 0,
        token: []const u8 = "image-access-a",
        generation: u64 = 3,
        model: []const u8 = "image-model-a",

        fn take(_: *anyopaque) std.mem.Allocator.Error!?account_contract.OwnedAuthorizationLease {
            @panic("Models reads the credential for an image itself");
        }
        fn prepare(context: *anyopaque, kind: models_contract.MediaKind) models_contract.MediaPreparation {
            const self: *@This() = @ptrCast(@alignCast(context));
            std.debug.assert(kind == .image);
            if (!self.available) return .{ .rejected = .model_not_found };
            self.calls += 1;
            if (self.reject) return .{ .rejected = .generation_mismatch };
            var candidate = models_contract.OwnedMediaCandidate.copy(std.testing.allocator, .image, self.model, self.token, 7) catch unreachable;
            candidate.credential_generation = self.generation;
            return .{ .ready = candidate };
        }
        fn modelsHttp(_: *anyopaque, _: metask_transport.Request, _: []u8) metask_transport.TransportError!metask_transport.Response {
            @panic("image preparation must not refresh the catalog");
        }
        fn imageHttp(_: ?*anyopaque, _: agent.CompletionHttpRequest, _: *const agent.CompletionCancellation, _: []u8) agent.CompletionTransportError!agent.CompletionTransportResponse {
            @panic("image preparation must not generate or reserve a file");
        }
    };
    var fixture: Fixture = .{};
    // This unit observes only the image management method; catalog and
    // selection behavior are tested against the real Models owner.
    var management: control_ports.ModelsManagement = undefined;
    management.context = &fixture;
    management.prepare_media_candidate_fn = Fixture.prepare;
    var coordinator = Coordinator.init(.{ .context = &fixture, .take_fn = Fixture.take }, .{ .context = &fixture, .perform_fn = Fixture.modelsHttp }, management, std.Thread.getCurrentId(), std.testing.io);
    coordinator.setCompletionTransport(.{ .perform_fn = Fixture.imageHttp });
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root);
    const authority: product_workspace.TaskAuthority = .{ .id = 5, .epoch = 2, .kind = .manual, .canonical_root = root[0..root_len], .trust = .explicitly_trusted };
    const port = coordinator.imageRunPreparation();
    try std.testing.expect(port.prepare(authority) == null);
    fixture.available = true;
    var first = port.prepare(authority).?;
    defer first.deinit();
    try std.testing.expectEqualStrings(models_contract.metask_images_generations_url, first.input().binding.endpoint);
    try std.testing.expectEqualStrings("image-model-a", first.input().binding.model);
    try std.testing.expectEqualStrings("image-access-a", first.input().binding.credential);
    // Renewal starts from the generation the candidate's credential has.
    try std.testing.expectEqual(@as(u64, 3), first.authorization.generation);
    const owner: *Coordinator.ImageOwner = @ptrCast(@alignCast(first.output_owner));
    @memset(root[0..root_len], 'x');
    try std.testing.expect(!std.mem.eql(u8, root[0..root_len], owner.output.root));
    fixture.token = "image-access-b";
    fixture.generation = 4;
    fixture.model = "image-model-b";
    _ = try tmp.dir.realPath(std.testing.io, &root);
    var second = port.prepare(authority).?;
    defer second.deinit();
    try std.testing.expectEqualStrings("image-access-b", second.input().binding.credential);
    try std.testing.expectEqualStrings("image-model-b", second.input().binding.model);
    try std.testing.expectEqual(@as(u64, 4), second.authorization.generation);
    try std.testing.expectEqualStrings("image-access-a", first.input().binding.credential);
    fixture.reject = true;
    try std.testing.expect(port.prepare(authority) == null);
    fixture.available = false;
    try std.testing.expect(port.prepare(authority) == null);
    try std.testing.expectEqual(@as(usize, 3), fixture.calls);
}
