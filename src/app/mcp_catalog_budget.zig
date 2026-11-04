//! Application deadlines for serialized MCP configuration/catalog effects.
//! The official connector identifies tool execution; those requests keep their
//! own timeout and never borrow a catalog operation's remaining budget.
const std = @import("std");
const agent = @import("metawork_agent");
const product_mcp = @import("metawork_product_mcp");

pub const Budget = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    runtime: *agent.Runtime,
    references: std.atomic.Value(usize) = .init(1),
    mutex: std.Io.Mutex = .init,
    max_step_ms: u32 = 5_000,
    member_count: usize = 0,
    epoch: u64 = 0,
    active: bool = false,
    deadline_ns: i96 = 0,
    member_ns: i96 = 0,
    fresh_deadlines: std.ArrayList(i96) = .empty,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, runtime: *agent.Runtime) std.mem.Allocator.Error!*Budget {
        const self = try allocator.create(Budget);
        self.* = .{ .allocator = allocator, .io = io, .runtime = runtime };
        return self;
    }

    fn retain(self: *Budget) void {
        _ = self.references.fetchAdd(1, .monotonic);
    }

    pub fn release(self: *Budget) void {
        if (self.references.fetchSub(1, .acq_rel) == 1) {
            self.fresh_deadlines.deinit(self.allocator);
            self.allocator.destroy(self);
        }
    }

    fn now(self: *Budget) i96 {
        return std.Io.Timestamp.now(self.io, .awake).nanoseconds;
    }

    fn limitLocked(self: *Budget, maximum_ms: u32, at: i96) u32 {
        var earliest: ?i96 = null;
        for (self.fresh_deadlines.items) |deadline| if (deadline > at) {
            earliest = @min(earliest orelse deadline, deadline);
        };
        if (earliest) |deadline| return @intCast(@max(1, @min(@as(i96, maximum_ms), @divFloor(deadline - at, 3 * std.time.ns_per_ms))));
        return maximum_ms;
    }

    /// Bounds OAuth maintenance as well, without changing an OAuth result or
    /// pretending that a deadline proves a non-idempotent request was not sent.
    pub fn maintenanceLimitMs(self: *Budget, maximum_ms: u32) u32 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.limitLocked(maximum_ms, self.now());
    }

    pub fn limitDeadline(self: *Budget, original: std.Io.Clock.Timestamp, maximum_ms: u32) std.Io.Clock.Timestamp {
        const bounded = std.Io.Clock.Timestamp.fromNow(self.io, .{ .raw = .fromMilliseconds(self.maintenanceLimitMs(maximum_ms)), .clock = original.clock });
        return if (original.raw.nanoseconds <= bounded.raw.nanoseconds) original else bounded;
    }

    pub fn begin(self: *Budget, members: usize) (agent.Error || std.mem.Allocator.Error)!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.active) return error.McpRefreshInProgress;
        if (self.epoch == std.math.maxInt(u64)) return error.McpRuntimeIdentityExhausted;
        // Reserve observation storage before any SDK effect, not after adoption.
        try self.fresh_deadlines.ensureTotalCapacity(self.allocator, members);
        const at = self.now();
        self.deadline_ns = at + @as(i96, self.limitLocked(self.max_step_ms, at)) * std.time.ns_per_ms;
        self.member_ns = @divFloor(self.deadline_ns - at, @as(i96, @intCast(@max(1, members))));
        self.epoch += 1;
        self.active = true;
    }

    /// Apply and subsequent Activation share one absolute step deadline.
    /// A new phase gives each actual member a share of the remaining time.
    pub fn applied(self: *Budget, members: usize) agent.Error!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.member_count = members;
        if (members == 0) self.fresh_deadlines.clearRetainingCapacity();
        if (self.epoch == std.math.maxInt(u64)) return error.McpRuntimeIdentityExhausted;
        self.member_ns = @divFloor(@max(0, self.deadline_ns - self.now()), @as(i96, @intCast(@max(1, members))));
        self.epoch += 1;
    }

    pub fn end(self: *Budget) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.active = false;
    }

    pub fn observe(self: *Budget, activation: *const agent.McpActivation) agent.Error!void {
        const age_ms = activation.catalogAgeMs() orelse return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (activation.catalogServers().len > self.fresh_deadlines.capacity) return error.McpCatalogResourceLimit;
        self.fresh_deadlines.clearRetainingCapacity();
        const at = self.now();
        for (activation.catalogServers()) |server| {
            if (server.fresh and server.ttl_remaining_ms > age_ms)
                self.fresh_deadlines.appendAssumeCapacity(at + @as(i96, server.ttl_remaining_ms - age_ms) * std.time.ns_per_ms);
        }
    }

    pub fn catalog(self: *Budget) product_mcp.Catalog {
        return .{ .context = self, .activate_fn = activate, .create_admission_selection_fn = createAdmission, .prepare_restore_selection_fn = prepareRestore };
    }

    fn activate(raw: *anyopaque) product_mcp.CatalogError!agent.McpActivationOutcome {
        const self: *Budget = @ptrCast(@alignCast(raw));
        self.mutex.lockUncancelable(self.io);
        const members = self.member_count;
        self.mutex.unlock(self.io);
        self.begin(members) catch |err| switch (err) {
            error.OutOfMemory => return .{ .unavailable = .refresh_rejected },
            else => return err,
        };
        defer self.end();
        const outcome = try self.runtime.activateMcp();
        if (outcome == .activated) self.observe(outcome.activated) catch |err| {
            outcome.activated.deinit();
            return err;
        };
        return outcome;
    }

    fn createAdmission(raw: *anyopaque, activation: *const agent.McpActivation, allowlists: []const agent.McpServerAllowlist) product_mcp.CatalogError!?*agent.McpSelection {
        const self: *Budget = @ptrCast(@alignCast(raw));
        return self.runtime.createMcpAdmissionSelection(activation, allowlists);
    }

    fn prepareRestore(raw: *anyopaque, original: *const agent.McpRestoreSelection, activation: *const agent.McpActivation, ceiling: []const agent.McpActivationTool) product_mcp.CatalogError!*agent.McpSelection {
        const self: *Budget = @ptrCast(@alignCast(raw));
        return self.runtime.prepareMcpRestoreSelection(original, activation, ceiling);
    }

    pub fn wrap(self: *Budget, owner: *agent.McpTransportOwner) std.mem.Allocator.Error!agent.McpTransportOwner {
        const wrapper = try self.allocator.create(Transport);
        wrapper.* = .{ .budget = self, .underlying = owner.take() };
        self.retain();
        return .init(.{ .context = wrapper, .open_fn = Transport.open, .request_fn = Transport.request, .tool_request_fn = Transport.toolRequest, .notify_fn = Transport.notify, .close_fn = Transport.close }, Transport.deinit);
    }
};

const Transport = struct {
    budget: *Budget,
    underlying: agent.McpTransportOwner,
    epoch: u64 = 0,
    deadline_ns: i96 = 0,
    const Connection = struct { transport: *Transport, underlying: *anyopaque };

    fn remaining(self: *Transport, requested: u32) ?u32 {
        const budget = self.budget;
        budget.mutex.lockUncancelable(budget.io);
        defer budget.mutex.unlock(budget.io);
        if (!budget.active) return requested;
        const at = budget.now();
        if (self.epoch != budget.epoch) {
            self.epoch = budget.epoch;
            self.deadline_ns = @min(budget.deadline_ns, at + budget.member_ns);
        }
        const left_ms = @divFloor(@min(self.deadline_ns, budget.deadline_ns) - at, std.time.ns_per_ms);
        if (left_ms < 1) return null;
        return @intCast(@min(@as(i96, requested), left_ms));
    }

    fn open(raw: *anyopaque, purpose: agent.McpPurpose, era: agent.McpEra, timeout_ms: u32) agent.McpOpenOutcome {
        const self: *Transport = @ptrCast(@alignCast(raw));
        const timeout = self.remaining(timeout_ms) orelse return .{ .failure = .timeout };
        const result = self.underlying.transport.open_fn(self.underlying.transport.context, purpose, era, timeout);
        return switch (result) {
            .failure => result,
            .connection => |connection| blk: {
                const wrapped = self.budget.allocator.create(Connection) catch {
                    self.underlying.transport.close_fn(connection);
                    return .{ .failure = .fatal };
                };
                wrapped.* = .{ .transport = self, .underlying = connection };
                break :blk .{ .connection = wrapped };
            },
        };
    }

    fn request(raw: *anyopaque, allocator: std.mem.Allocator, bytes: []const u8, timeout_ms: u32, cancellation: agent.McpCancellation) agent.McpExchangeOutcome {
        const connection: *Connection = @ptrCast(@alignCast(raw));
        const self = connection.transport;
        const timeout = self.remaining(timeout_ms) orelse return .{ .failure = .timeout };
        return self.underlying.transport.request_fn(connection.underlying, allocator, bytes, timeout, cancellation);
    }

    fn toolRequest(raw: *anyopaque, allocator: std.mem.Allocator, bytes: []const u8, timeout_ms: u32, cancellation: agent.McpCancellation) agent.McpExchangeOutcome {
        const connection: *Connection = @ptrCast(@alignCast(raw));
        const transport = connection.transport.underlying.transport;
        return (transport.tool_request_fn orelse transport.request_fn)(connection.underlying, allocator, bytes, timeout_ms, cancellation);
    }

    fn notify(raw: *anyopaque, bytes: []const u8, timeout_ms: u32, cancellation: agent.McpCancellation) ?agent.McpTransportFailure {
        const connection: *Connection = @ptrCast(@alignCast(raw));
        const self = connection.transport;
        const timeout = self.remaining(timeout_ms) orelse return .timeout;
        return self.underlying.transport.notify_fn(connection.underlying, bytes, timeout, cancellation);
    }

    fn close(raw: *anyopaque) void {
        const connection: *Connection = @ptrCast(@alignCast(raw));
        const self = connection.transport;
        self.underlying.transport.close_fn(connection.underlying);
        self.budget.allocator.destroy(connection);
    }

    fn deinit(raw: *anyopaque) void {
        const self: *Transport = @ptrCast(@alignCast(raw));
        const budget = self.budget;
        self.underlying.deinit();
        budget.allocator.destroy(self);
        budget.release();
    }
};

test "catalog budget protects a later fresh member after the earliest deadline expires" {
    var budget: Budget = .{ .allocator = std.testing.allocator, .io = std.testing.io, .runtime = undefined };
    defer budget.fresh_deadlines.deinit(std.testing.allocator);
    try budget.fresh_deadlines.append(std.testing.allocator, 1_000 * std.time.ns_per_ms);
    try budget.fresh_deadlines.append(std.testing.allocator, 10_000 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(u32, 333), budget.limitLocked(5_000, 0));
    try std.testing.expectEqual(@as(u32, 3_000), budget.limitLocked(5_000, 1_000 * std.time.ns_per_ms));
    try std.testing.expectEqual(@as(u32, 5_000), budget.limitLocked(5_000, 10_000 * std.time.ns_per_ms));
}

test "catalog budget allocation failure is a definite rejection before any SDK effect" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var budget: Budget = .{ .allocator = failing.allocator(), .io = std.testing.io, .runtime = undefined, .member_count = 2 };
    defer budget.fresh_deadlines.deinit(failing.allocator());
    const outcome = try budget.catalog().activate();
    try std.testing.expect(outcome == .unavailable);
    try std.testing.expectEqual(agent.McpActivationUnavailableReason.refresh_rejected, outcome.unavailable);
    try std.testing.expect(!budget.active);
    try std.testing.expectEqual(@as(u64, 0), budget.epoch);
}
