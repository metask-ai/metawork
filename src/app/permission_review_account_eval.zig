//! Opt-in test composition. Account remains the sole refresh credential owner.
//! No Product stores, task tools, Bridge, or credential export are started here.
const std = @import("std");
const native = @import("native_sdk");
const runner = @import("runner");
const account = @import("metawork_account");
const agent = @import("metawork_agent");
const identity = @import("metawork_product_identity");
const catalog_api = @import("product_models_metask");
const protocol_adapter = @import("product_agent_protocol_adapter");
const evaluation = @import("permission_review_evaluation");
const Coordinator = @import("account_coordinator.zig").Coordinator;
const Platform = @import("account_platform_binding.zig").Adapter;
const Http = @import("metask_http_transport.zig").Adapter;
const CompletionHttp = @import("completion_http_transport.zig").Backend;
const Loopback = @import("oauth_loopback_transport").Adapter;
const Paths = @import("paths.zig").Paths;
const SingleInstance = @import("single_instance_coordinator.zig").Coordinator;
const ports = @import("metawork_product_control_ports");

const poll_timer = 0x4d57_4556_414c_0001;

fn line(init: std.process.Init, value: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    try std.json.Stringify.value(value, .{}, &output.interface);
    try output.interface.writeByte('\n');
    try output.interface.flush();
}

const Host = struct {
    init: std.process.Init,
    runtime: ?*native.Runtime = null,
    account_runtime: *account.Runtime,
    coordinator: *Coordinator,
    platform: ?Platform = null,
    http: *Http,
    model: []const u8,
    revision: []const u8,
    repeats: usize,
    worker: ?std.Thread = null,
    lease: ?@import("metawork_account_contract").OwnedAuthorizationLease = null,
    stop_requested: std.atomic.Value(bool) = .init(false),
    finished: std.atomic.Value(bool) = .init(false),
    failure: ?anyerror = null,
    phase: enum { restoring, evaluating, billing, done } = .restoring,
    phase_start: std.Io.Clock.Timestamp,

    fn wake(context: *anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(context));
        if (self.runtime) |runtime| runtime.options.platform.services.wake() catch {};
        // The bounded poll timer also drains completions if an OS wake fails.
    }

    fn commit(_: *anyopaque, value: ports.AccountCommit) void {
        value.assertValid();
    }

    fn start(context: *anyopaque, runtime: *native.Runtime) !void {
        const self: *Host = @ptrCast(@alignCast(context));
        self.runtime = runtime;
        runtime.hideWindow(1) catch {};
        self.platform = try Platform.init(runtime, self.init.io, std.Thread.getCurrentId());
        try runtime.startTimer(poll_timer, 250 * std.time.ns_per_ms, true);
        self.coordinator.start(self.platform.?.ports());
    }

    fn billing(self: *Host, stage: []const u8) !void {
        const history = self.account_runtime.view().summary.history;
        try line(self.init, .{
            .kind = "account_billing",
            .stage = stage,
            .availability = history.availability,
            .error_code = history.error_code,
            .latest_day = if (history.days.len > 0) history.days[history.days.len - 1] else null,
            .attribution = "whole-account recorded cost; concurrent usage and delayed billing may affect the delta",
        });
    }

    fn event(context: *anyopaque, runtime: *native.Runtime, value: native.Event) !void {
        const self: *Host = @ptrCast(@alignCast(context));
        switch (value) {
            .effects_wake => self.coordinator.drain(),
            .timer => |timer| {
                if (timer.id != poll_timer) {
                    _ = self.coordinator.onTimer(timer.id);
                    return;
                }
                self.coordinator.drain();
            },
            else => return,
        }
        const elapsed = self.phase_start.durationTo(std.Io.Clock.Timestamp.now(self.init.io, .awake)).raw.toSeconds();
        switch (self.phase) {
            .restoring => {
                const view = self.account_runtime.view();
                if (view.state == .signed_out or elapsed > 60) {
                    try line(self.init, .{ .kind = "account_unavailable", .state = view.state, .error_code = view.error_code });
                    self.failure = error.ExistingLoginUnavailable;
                    self.phase = .done;
                    try runtime.quitApp();
                } else if (view.state == .authenticated and view.summary.operation == .idle) {
                    try self.billing("before");
                    self.beginEvaluation() catch |failure| {
                        self.failure = failure;
                        self.phase = .done;
                        try runtime.quitApp();
                    };
                }
            },
            .evaluating => if (self.finished.load(.acquire)) {
                self.worker.?.join();
                self.worker = null;
                self.phase = .billing;
                self.phase_start = std.Io.Clock.Timestamp.now(self.init.io, .awake);
                _ = self.coordinator.commandSink().submit(.refresh_summary);
            },
            .billing => if (self.account_runtime.view().summary.operation == .idle or elapsed > 45) {
                try self.billing("after");
                self.phase = .done;
                try runtime.quitApp();
            },
            .done => {},
        }
    }

    fn beginEvaluation(self: *Host) !void {
        self.lease = (try self.account_runtime.authorizationLease()) orelse return error.AuthorizationUnavailable;
        errdefer {
            self.lease.?.deinit();
            self.lease = null;
        }
        self.worker = try std.Thread.spawn(.{}, evaluate, .{self});
        self.phase = .evaluating;
    }

    fn evaluate(self: *Host) void {
        self.evaluateFallible() catch |failure| {
            self.failure = failure;
        };
        self.finished.store(true, .release);
        wake(self);
    }

    fn evaluateFallible(self: *Host) !void {
        // This worker exclusively owns the transferred lease and clears it on
        // every path. Neither the parent thread nor any projection reads it.
        defer self.lease.?.deinit();
        const lease = &self.lease.?;
        var catalog = catalog_api.CatalogSession.init(self.init.gpa);
        defer catalog.deinit();
        try catalog.loadModels(self.http.modelsTransport(), lease.access_token, lease.principal_ref, null);
        var candidate = try catalog.prepareSourceCandidate(self.model, 1);
        defer candidate.deinit();
        const input = candidate.input();
        var backend = CompletionHttp{ .allocator = self.init.gpa, .io = self.init.io };
        const protocol = protocol_adapter.toAgent(input.target.protocol);
        var observed = evaluation.ObservedTransport{ .inner = backend.transport() };
        const completion = try agent.Completion.init(self.init.gpa, observed.transport(), .{
            .target = .{ .provider_id = input.target.provider_id, .protocol = protocol, .base_url = input.target.base_url, .model = input.target.model },
            .credential = input.api_key,
        });
        defer completion.deinit();
        try evaluation.runWithCompletion(self.init, completion, self.revision, protocol, input.target.model, self.repeats, &self.stop_requested, &observed);
    }

    fn stop(context: *anyopaque, runtime: *native.Runtime) !void {
        const self: *Host = @ptrCast(@alignCast(context));
        self.stop_requested.store(true, .release);
        if (self.worker) |worker| {
            worker.join(); // Current production review deadline is 30 seconds.
            self.worker = null;
            if (self.failure == null) self.failure = error.Cancelled;
        }
        self.coordinator.shutdown();
        self.coordinator.drain();
        runtime.cancelTimer(poll_timer) catch {};
        if (self.platform) |*platform| platform.deinit();
        self.runtime = null;
    }
};

pub fn run(init: std.process.Init) !void {
    if (identity.artifact_kind != .development) return error.DevelopmentArtifactRequired;
    const model = init.environ_map.get("METAWORK_REVIEW_EVAL_MODEL") orelse return error.MissingEvaluationModel;
    const revision = init.environ_map.get("METAWORK_REVIEW_EVAL_REVISION") orelse return error.MissingEvaluationRevision;
    const repeats = try std.fmt.parseInt(usize, init.environ_map.get("METAWORK_REVIEW_EVAL_REPEATS") orelse "3", 10);
    if (model.len == 0 or repeats < 1 or repeats > 5) return error.InvalidEvaluationConfiguration;
    var paths: Paths = undefined;
    try paths.init(init.io, init.gpa, init.environ_map, null);
    defer paths.deinit();
    var single_instance: SingleInstance = undefined;
    // Same canonical root/lease as the desktop: never restore or rotate a
    // production refresh token concurrently with another MetaWork Host.
    _ = try single_instance.init(init.io, init.gpa, init.minimal.args, paths.dataDir(), identity.runnerBundleId(), false, true);
    defer single_instance.deinit();
    var http = Http{ .allocator = init.gpa, .io = init.io };
    var loopback = Loopback.init(init.io);
    defer loopback.deinit();
    var account_runtime: account.Runtime = undefined;
    var coordinator: Coordinator = undefined;
    var host = Host{ .init = init, .account_runtime = &account_runtime, .coordinator = &coordinator, .http = &http, .model = model, .revision = revision, .repeats = repeats, .phase_start = std.Io.Clock.Timestamp.now(init.io, .awake) };
    account_runtime = account.Runtime.init(init.gpa, init.io, std.Thread.getCurrentId(), http.accountTransport(), loopback.endpoint(), .{ .context = &host, .notify_fn = Host.wake });
    defer account_runtime.deinit();
    coordinator = Coordinator.init(&account_runtime, .{ .context = &host, .commit_fn = Host.commit }, std.Thread.getCurrentId());
    try runner.runWithOptions(.{ .context = &host, .name = "MetaWork approval evaluation", .start_fn = Host.start, .event_fn = Host.event, .stop_fn = Host.stop }, .{
        .app_name = "MetaWork approval evaluation",
        .window_title = "MetaWork approval evaluation",
        .bundle_id = identity.runnerBundleId(),
        .restore_state = false,
        .security = .{ .permissions = &.{} },
    }, init);
    if (host.failure) |failure| return failure;
    if (host.phase != .done) return error.EvaluationInterrupted;
}
