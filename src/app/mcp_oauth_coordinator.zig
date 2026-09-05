//! Application lifecycle adapter for the one MCP OAuth expiry timer and the
//! single refresh network effect. Product Control owns every durable transition;
//! this owner only sequences platform time/credential/network capabilities.

const std = @import("std");
const control_ports = @import("metawork_product_control_ports");
const mcp_types = @import("metawork_product_mcp");
const mcp_oauth = @import("metawork_mcp_oauth");
const mcp_platform = @import("metawork_mcp_platform");
const app_platform = @import("platform.zig");

const refresh_timeout: std.Io.Clock.Duration = .{
    .raw = .fromSeconds(30),
    .clock = .boot,
};
const retry_delay_ms: u64 = 30_000;

pub const Host = struct {
    context: *anyopaque,
    now_unix_ms_fn: *const fn (*anyopaque) ?u64,
    arm_fn: *const fn (*anyopaque, u64) bool,
    cancel_fn: *const fn (*anyopaque) void,
    notify_fn: *const fn (*anyopaque) void,

    fn nowRequired(self: Host) u64 {
        return self.now_unix_ms_fn(self.context) orelse
            @panic("MCP OAuth refresh lost the required system clock");
    }

    fn armRequired(self: Host, due_unix_ms: u64) void {
        if (!self.arm_fn(self.context, due_unix_ms))
            @panic("MCP OAuth refresh lost its required expiry timer");
    }

    fn cancel(self: Host) void {
        self.cancel_fn(self.context);
    }

    fn notify(self: Host) void {
        self.notify_fn(self.context);
    }
};

pub fn platformHost(platform: *app_platform.Adapter) Host {
    return .{
        .context = platform,
        .now_unix_ms_fn = platformNowUnixMs,
        .arm_fn = platformArm,
        .cancel_fn = platformCancel,
        .notify_fn = platformNotify,
    };
}

fn platformNowUnixMs(context: *anyopaque) ?u64 {
    const platform: *app_platform.Adapter = @ptrCast(@alignCast(context));
    return platform.nowUnixMilliseconds();
}

fn platformArm(context: *anyopaque, due_unix_ms: u64) bool {
    const platform: *app_platform.Adapter = @ptrCast(@alignCast(context));
    return platform.armMcpOauthTimer(due_unix_ms);
}

fn platformCancel(context: *anyopaque) void {
    const platform: *app_platform.Adapter = @ptrCast(@alignCast(context));
    platform.cancelMcpOauthTimer();
}

fn platformNotify(context: *anyopaque) void {
    const platform: *app_platform.Adapter = @ptrCast(@alignCast(context));
    app_platform.Adapter.notifyRequired(platform);
}

const RefreshResult = union(enum) {
    pending,
    tokens: mcp_oauth.TokenSet,
    clear_marker,
    recover,

    fn deinit(self: *RefreshResult) void {
        switch (self.*) {
            .tokens => |*tokens| tokens.deinit(),
            .pending, .clear_marker, .recover => {},
        }
        self.* = .pending;
    }
};

const RefreshJob = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    host: Host,
    binding: mcp_types.McpOauthRefreshBinding,
    client_secret: ?[]u8,
    refresh_token: []u8,
    now_unix_ms: u64,
    cancellation: mcp_oauth.Cancellation,
    deadline: std.Io.Clock.Timestamp,
    result: RefreshResult = .pending,
    finished: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    fn start(self: *RefreshJob) std.Thread.SpawnError!void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn run(self: *RefreshJob) void {
        var http: mcp_oauth.StdHttpTransport = .{
            .allocator = self.allocator,
            .io = self.io,
            .cancellation = &self.cancellation,
            .deadline = self.deadline,
        };
        var resource = mcp_oauth.discoverResourceEffect(
            self.allocator,
            http.transport(),
            self.binding.endpoint,
        ) catch {
            self.publish(.clear_marker);
            return;
        };
        defer resource.deinit();
        if (!refreshDiscoveryCoveredByConsent(
            &self.binding,
            resource.resource,
            resource.requested_scopes,
        )) {
            self.publish(.recover);
            return;
        }
        var authorization = mcp_oauth.discoverAuthorizationServer(
            self.allocator,
            http.transport(),
            &resource,
            self.binding.issuer,
        ) catch |err| {
            self.publish(if (err == error.UnsupportedAuthorizationServer)
                .recover
            else
                .clear_marker);
            return;
        };
        defer authorization.deinit();
        const method = mcp_oauth.TokenEndpointAuthMethod.fromWire(
            self.binding.token_endpoint_auth_method,
        ) orelse {
            self.publish(.clear_marker);
            return;
        };
        const tokens = mcp_oauth.refreshAccessTokenEffect(
            self.allocator,
            http.transport(),
            &authorization,
            .{
                .issuer = self.binding.issuer,
                .client_id = self.binding.client_id,
                .token_endpoint_auth_method = method,
                .resource = self.binding.resource,
                .consent_epoch = self.binding.consent_epoch,
                .token_revision = self.binding.token_revision,
            },
            self.client_secret,
            self.refresh_token,
            self.now_unix_ms,
        ) catch |err| {
            self.publish(switch (err) {
                error.CancelledBeforeSend => .clear_marker,
                else => .recover,
            });
            return;
        };
        self.result = .{ .tokens = tokens };
        self.finish();
    }

    fn publish(self: *RefreshJob, result: RefreshResult) void {
        self.result = result;
        self.finish();
    }

    fn finish(self: *RefreshJob) void {
        self.finished.store(true, .release);
        self.host.notify();
    }

    fn cancel(self: *RefreshJob) void {
        self.cancellation.cancel();
    }

    fn join(self: *RefreshJob) void {
        const thread = self.thread orelse return;
        thread.join();
        self.thread = null;
    }

    fn deinit(self: *RefreshJob) void {
        std.debug.assert(self.thread == null);
        self.result.deinit();
        if (self.client_secret) |secret| secureFree(self.allocator, secret);
        secureFree(self.allocator, self.refresh_token);
        self.binding.deinit();
        self.* = undefined;
    }
};

pub const Coordinator = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    control: control_ports.McpOauthPort,
    credential_store: *mcp_platform.CredentialStore,
    authorizations: *mcp_platform.HttpAuthorizations,
    host: Host,
    job: ?*RefreshJob = null,
    retry_not_before_unix_ms: ?u64 = null,
    stopping: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        control: control_ports.McpOauthPort,
        credential_store: *mcp_platform.CredentialStore,
        authorizations: *mcp_platform.HttpAuthorizations,
        host: Host,
    ) Coordinator {
        return .{
            .allocator = allocator,
            .io = io,
            .control = control,
            .credential_store = credential_store,
            .authorizations = authorizations,
            .host = host,
        };
    }

    pub fn start(self: *Coordinator) void {
        self.authorizations.setRuntimeAuthFailureNotifier(.{
            .context = self.host.context,
            .notify_fn = self.host.notify_fn,
        });
        _ = self.drainRuntimeAuthFailures();
        self.armEarliest();
    }

    pub fn reconcileTimer(self: *Coordinator) void {
        self.armEarliest();
    }

    pub fn onTimer(self: *Coordinator) bool {
        const now_unix_ms = self.host.nowRequired();
        if (self.stopping or self.job != null) return true;
        if (self.retry_not_before_unix_ms) |not_before| {
            if (now_unix_ms < not_before) {
                self.host.armRequired(not_before);
                return true;
            }
            self.retry_not_before_unix_ms = null;
        }
        const expiry = self.control.nextMcpOauthExpiry() orelse return true;
        if (expiry.expires_at_unix_ms > now_unix_ms) {
            self.host.armRequired(expiry.expires_at_unix_ms);
            return true;
        }
        self.begin(expiry.server_id, now_unix_ms) catch {
            self.deferRetry(now_unix_ms);
            self.armEarliest();
        };
        return true;
    }

    pub fn drain(self: *Coordinator) bool {
        var changed = false;
        if (self.job) |job| {
            if (!job.finished.load(.acquire)) return false;
            job.join();
            switch (job.result) {
                .pending => unreachable,
                .tokens => |*tokens| self.commitTokens(job, tokens) catch
                    self.recover(job.binding.operation_id),
                .clear_marker => {
                    self.clear(job.binding.operation_id);
                    if (!self.stopping) self.deferRetry(self.host.nowRequired());
                },
                .recover => {
                    self.retry_not_before_unix_ms = null;
                    self.recover(job.binding.operation_id);
                },
            }
            job.deinit();
            self.allocator.destroy(job);
            self.job = null;
            changed = true;
        }
        changed = self.drainRuntimeAuthFailures() or changed;
        if (!self.stopping) self.armEarliest();
        return changed;
    }

    pub fn shutdown(self: *Coordinator) void {
        if (self.stopping) return;
        self.stopping = true;
        self.authorizations.setRuntimeAuthFailureNotifier(null);
        self.host.cancel();
        if (self.job) |job| {
            job.cancel();
            job.join();
            if (!job.finished.load(.acquire)) {
                job.result = .recover;
                job.finished.store(true, .release);
            }
            _ = self.drain();
        }
        _ = self.drainRuntimeAuthFailures();
    }

    pub fn deinit(self: *Coordinator) void {
        self.shutdown();
        std.debug.assert(self.job == null);
        self.* = undefined;
    }

    fn begin(
        self: *Coordinator,
        server_id: []const u8,
        now_unix_ms: u64,
    ) !void {
        var binding = switch (try self.control.beginMcpOauthRefresh(server_id)) {
            .started => |value| value,
            .rejected, .persistence_outcome_unknown => return error.StateRejected,
        };
        var binding_owned = true;
        defer if (binding_owned) binding.deinit();
        const method = mcp_oauth.TokenEndpointAuthMethod.fromWire(
            binding.token_endpoint_auth_method,
        ) orelse {
            self.recover(binding.operation_id);
            return error.InvalidBinding;
        };
        const client_secret = if (binding.client_secret_ref) |locator|
            self.resolveSecret(locator) catch |err| {
                self.recover(binding.operation_id);
                return err;
            }
        else
            null;
        var client_secret_owned = client_secret != null;
        defer if (client_secret_owned) if (client_secret) |secret|
            secureFree(self.allocator, secret);
        if ((method == .none) != (client_secret == null)) {
            self.recover(binding.operation_id);
            return error.InvalidBinding;
        }
        const refresh_token = self.resolveSecret(binding.refresh_token_ref) catch |err| {
            self.recover(binding.operation_id);
            return err;
        };
        var refresh_owned = true;
        defer if (refresh_owned) secureFree(self.allocator, refresh_token);
        const job = self.allocator.create(RefreshJob) catch |err| {
            self.clear(binding.operation_id);
            return err;
        };
        job.* = .{
            .allocator = self.allocator,
            .io = self.io,
            .host = self.host,
            .binding = binding,
            .client_secret = client_secret,
            .refresh_token = refresh_token,
            .now_unix_ms = now_unix_ms,
            .cancellation = .init(self.io),
            .deadline = std.Io.Clock.Timestamp.fromNow(self.io, refresh_timeout),
        };
        binding_owned = false;
        client_secret_owned = false;
        refresh_owned = false;
        job.start() catch |err| {
            self.clear(job.binding.operation_id);
            job.thread = null;
            job.deinit();
            self.allocator.destroy(job);
            return err;
        };
        self.job = job;
    }

    fn commitTokens(
        self: *Coordinator,
        job: *RefreshJob,
        tokens: *mcp_oauth.TokenSet,
    ) !void {
        var pending = (try self.authorizations.prepareRotation(
            job.binding.server_id,
            job.binding.consent_epoch,
            job.binding.token_revision,
            tokens.access_token.view(),
        )) orelse {
            self.recover(job.binding.operation_id);
            return;
        };
        defer pending.deinit();
        const access = try self.allocator.dupe(u8, tokens.access_token.view());
        defer {
            std.crypto.secureZero(u8, access);
            self.allocator.free(access);
        }
        const refresh = if (tokens.refresh_token) |*secret|
            try self.allocator.dupe(u8, secret.view())
        else
            null;
        defer if (refresh) |secret| {
            std.crypto.secureZero(u8, secret);
            self.allocator.free(secret);
        };
        const outcome = try self.control.completeMcpOauthRefresh(.{
            .operation_id = job.binding.operation_id,
            .server_id = job.binding.server_id,
            .access_token = access,
            .refresh_token = refresh,
            .expires_at_unix_ms = tokens.expires_at_unix_ms,
        }, .{
            .context = &pending,
            .commit_fn = commitRotation,
        });
        switch (outcome) {
            .saved, .saved_recovery_required => {},
            .rejected => self.recover(job.binding.operation_id),
            .indeterminate => {},
            .unchanged, .stale_generation => unreachable,
        }
    }

    fn drainRuntimeAuthFailures(self: *Coordinator) bool {
        var batch = self.authorizations.snapshotRuntimeAuthFailures() catch return false;
        defer batch.deinit();
        var changed = false;
        for (batch.values) |*failure| {
            const outcome = self.control.requireMcpOauthReauthorization(.{
                .server_id = failure.server_id,
                .consent_epoch = failure.consent_epoch,
                .token_revision = failure.token_revision,
                .challenge_scopes = failure.challenge_scopes,
                .challenge_scopes_complete = failure.challenge_scopes_complete,
            }) catch continue;
            switch (outcome) {
                .applied, .stale, .persistence_outcome_unknown => {
                    _ = self.authorizations.acknowledgeRuntimeAuthFailure(failure);
                    changed = true;
                },
                .pending, .rejected => {},
            }
        }
        return changed;
    }

    fn resolveSecret(self: *Coordinator, locator: []const u8) ![]u8 {
        return switch (self.credential_store.resolveSecret(self.allocator, locator)) {
            .value => |secret| secret,
            .out_of_memory => error.OutOfMemory,
            .missing => error.SecretMissing,
            .unavailable => error.SecretUnavailable,
        };
    }

    fn clear(self: *Coordinator, operation_id: []const u8) void {
        _ = self.control.clearMcpOauthOperation(operation_id) catch {};
    }

    fn recover(self: *Coordinator, operation_id: []const u8) void {
        _ = self.control.recoverMcpOauthOperation(operation_id) catch {};
    }

    fn deferRetry(self: *Coordinator, now_unix_ms: u64) void {
        self.retry_not_before_unix_ms = std.math.add(
            u64,
            now_unix_ms,
            retry_delay_ms,
        ) catch std.math.maxInt(u64);
    }

    fn armEarliest(self: *Coordinator) void {
        if (self.stopping or self.job != null) return;
        const expiry = self.control.nextMcpOauthExpiry() orelse {
            self.host.cancel();
            return;
        };
        const now = self.host.nowRequired();
        const not_before = self.retry_not_before_unix_ms orelse now;
        self.host.armRequired(@max(expiry.expires_at_unix_ms, not_before));
    }
};

fn commitRotation(context: *anyopaque) void {
    const pending: *mcp_platform.PendingHttpAuthRotation =
        @ptrCast(@alignCast(context));
    pending.commit();
}

fn secureFree(allocator: std.mem.Allocator, secret: []u8) void {
    std.crypto.secureZero(u8, secret);
    allocator.free(secret);
}

fn refreshDiscoveryCoveredByConsent(
    binding: *const mcp_types.McpOauthRefreshBinding,
    resource: []const u8,
    requested_scopes: []const []const u8,
) bool {
    if (!std.mem.eql(u8, binding.resource, resource)) return false;
    for (requested_scopes) |requested| {
        for (binding.scopes) |approved|
            if (std.mem.eql(u8, requested, approved)) break else return false;
    }
    return true;
}

test "MCP OAuth refresh reuses consent only for the same resource and covered scopes" {
    const binding: mcp_types.McpOauthRefreshBinding = .{
        .arena = undefined,
        .operation_id = "refresh-1",
        .server_id = "server",
        .endpoint = "https://mcp.example.test/mcp",
        .resource = "https://mcp.example.test/mcp",
        .issuer = "https://issuer.example.test",
        .scopes = &.{ "files.read", "files.write" },
        .client_id = "client",
        .token_endpoint_auth_method = "none",
        .client_secret_ref = null,
        .refresh_token_ref = "refresh-token",
        .consent_epoch = 1,
        .token_revision = 2,
    };
    try std.testing.expect(refreshDiscoveryCoveredByConsent(
        &binding,
        binding.resource,
        &.{"files.read"},
    ));
    try std.testing.expect(!refreshDiscoveryCoveredByConsent(
        &binding,
        "https://other.example.test/mcp",
        &.{"files.read"},
    ));
    try std.testing.expect(!refreshDiscoveryCoveredByConsent(
        &binding,
        binding.resource,
        &.{ "files.read", "files.delete" },
    ));
}
