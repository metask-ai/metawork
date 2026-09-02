const std = @import("std");
const agent = @import("metawork_agent");
const models_contract = @import("metawork_product_models_contract");
const models_ports = @import("product_models_ports");
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
    selection: models_contract.ModelConnectionSelectionCommand,
    connection_id: []u8,
    model_id: []u8,
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
        const connection_id = try allocator.dupe(
            u8,
            command_value.selection.connection_id,
        );
        errdefer allocator.free(connection_id);
        const model_id = try allocator.dupe(u8, command_value.model_id);
        errdefer allocator.free(model_id);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .completion_transport = completion_transport,
            .notifier = notifier,
            .selection = .{
                .connection_id = connection_id,
                .expected_connection_generation = command_value.selection.expected_connection_generation,
            },
            .connection_id = connection_id,
            .model_id = model_id,
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
            .selection = .{
                .connection_id = self.connection_id,
                .expected_connection_generation = self.selection.expected_connection_generation,
            },
            .model_id = self.model_id,
        };
    }

    fn deinit(self: *ProbeJob) void {
        std.debug.assert(self.thread == null);
        if (self.execution) |*execution| execution.deinit();
        self.allocator.free(self.model_id);
        self.allocator.free(self.connection_id);
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
    management: control_ports.ModelsManagement,
    main_thread_id: std.Thread.Id,
    probe_notifier: ?ProbeNotifier = null,
    completion_transport: ?agent.CompletionTransport = null,
    probe_job: ?*ProbeJob = null,

    pub fn init(
        management: control_ports.ModelsManagement,
        main_thread_id: std.Thread.Id,
        io: std.Io,
    ) Coordinator {
        return .{
            .io = io,
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
        model_id: []const u8,
        model_display_name: []const u8,
    ) models_contract.CommandResult {
        self.assertMainThread();
        return self.management.createModelConnectionWithCredential(
            secret,
            spec,
            model_id,
            model_display_name,
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

    pub fn drain(self: *Coordinator) void {
        self.assertMainThread();
        const job = self.probe_job orelse return;
        if (!job.finished.load(.acquire)) return;
        job.join();
        _ = self.management.completeModelConnectionTest(
            job.command(),
            job.succeeded,
        );
        self.probe_job = null;
        job.deinit();
    }

    pub fn shutdown(self: *Coordinator) void {
        self.assertMainThread();
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
