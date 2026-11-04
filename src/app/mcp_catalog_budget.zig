//! Application attempt deadline for the single not-yet-adopted MCP candidate.
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
    epoch: u64 = 0,
    active: bool = false,
    bounded: bool = false,
    started_ns: i96 = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, runtime: *agent.Runtime) std.mem.Allocator.Error!*Budget {
        const self = try allocator.create(Budget);
        self.* = .{ .allocator = allocator, .io = io, .runtime = runtime };
        return self;
    }

    fn retain(self: *Budget) void {
        _ = self.references.fetchAdd(1, .monotonic);
    }
    pub fn release(self: *Budget) void {
        if (self.references.fetchSub(1, .acq_rel) == 1) self.allocator.destroy(self);
    }
    fn now(self: *Budget) i96 {
        return std.Io.Timestamp.now(self.io, .awake).nanoseconds;
    }

    /// Only wrappers constructed for this next apply carry this epoch. Existing
    /// members never participate. Empty Runtime needs no extra total deadline.
    pub fn begin(self: *Budget, existing_members: usize) agent.Error!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.active) return error.McpRefreshInProgress;
        if (self.epoch == std.math.maxInt(u64)) return error.McpRuntimeIdentityExhausted;
        self.started_ns = self.now();
        self.epoch += 1;
        self.bounded = existing_members != 0;
        self.active = true;
    }

    /// APPLIED ends candidate ownership before Activation or Session use.
    pub fn applied(self: *Budget) void {
        self.end();
    }
    pub fn end(self: *Budget) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.active = false;
    }

    pub fn catalog(self: *Budget) product_mcp.Catalog {
        return .{ .context = self, .activate_fn = activate, .create_admission_selection_fn = createAdmission, .prepare_restore_selection_fn = prepareRestore };
    }

    fn activate(raw: *anyopaque) product_mcp.CatalogError!agent.McpActivationOutcome {
        const self: *Budget = @ptrCast(@alignCast(raw));
        return self.runtime.activateMcp();
    }

    fn createAdmission(raw: *anyopaque, activation: *const agent.McpActivation, allowlists: []const agent.McpServerAllowlist) product_mcp.CatalogError!?*agent.McpSelection {
        const self: *Budget = @ptrCast(@alignCast(raw));
        return self.runtime.createMcpAdmissionSelection(activation, allowlists);
    }

    fn prepareRestore(raw: *anyopaque, original: *const agent.McpRestoreSelection, activation: *const agent.McpActivation, ceiling: []const agent.McpActivationTool) product_mcp.CatalogError!*agent.McpSelection {
        const self: *Budget = @ptrCast(@alignCast(raw));
        return self.runtime.prepareMcpRestoreSelection(original, activation, ceiling);
    }
};

/// Management limits also apply to isolated connection-test Runtimes. Only
/// the optional candidate scope adds an absolute pre-adoption deadline.
pub fn wrapTransport(allocator: std.mem.Allocator, owner: *agent.McpTransportOwner, timeout_ms: u32, budget: ?*Budget) std.mem.Allocator.Error!agent.McpTransportOwner {
    const wrapper = try allocator.create(Transport);
    var epoch: u64 = 0;
    if (budget) |scope| {
        scope.mutex.lockUncancelable(scope.io);
        epoch = scope.epoch +| 1;
        scope.mutex.unlock(scope.io);
        scope.retain();
    }
    wrapper.* = .{ .allocator = allocator, .budget = budget, .underlying = owner.take(), .epoch = epoch, .timeout_ms = product_mcp.contract.managementTimeoutMs(timeout_ms) };
    return .init(.{ .context = wrapper, .open_fn = Transport.open, .request_fn = Transport.request, .tool_request_fn = Transport.toolRequest, .notify_fn = Transport.notify, .close_fn = Transport.close }, Transport.deinit);
}

const Transport = struct {
    allocator: std.mem.Allocator,
    budget: ?*Budget,
    underlying: agent.McpTransportOwner,
    epoch: u64,
    timeout_ms: u32,
    const Connection = struct { transport: *Transport, underlying: *anyopaque };

    fn remaining(self: *Transport, requested: u32) ?u32 {
        const timeout = product_mcp.contract.managementTimeoutMs(requested);
        const budget = self.budget orelse return timeout;
        budget.mutex.lockUncancelable(budget.io);
        defer budget.mutex.unlock(budget.io);
        if (!budget.active or !budget.bounded or self.epoch != budget.epoch) return timeout;
        // A request timeout is not an apply timeout. Allow negotiation/startup
        // and catalog exchanges separate windows, under an explicit total cap.
        const total_ms = @as(i96, self.timeout_ms) * product_mcp.contract.candidate_timeout_windows;
        const left_ms = @divFloor(budget.started_ns + total_ms * std.time.ns_per_ms - budget.now(), std.time.ns_per_ms);
        if (left_ms < 1) return null;
        return @intCast(@min(@as(i96, timeout), left_ms));
    }

    fn open(raw: *anyopaque, purpose: agent.McpPurpose, era: agent.McpEra, timeout_ms: u32) agent.McpOpenOutcome {
        const self: *Transport = @ptrCast(@alignCast(raw));
        const timeout = self.remaining(timeout_ms) orelse return .{ .failure = .timeout };
        const result = self.underlying.transport.open_fn(self.underlying.transport.context, purpose, era, timeout);
        return switch (result) {
            .failure => result,
            .connection => |connection| blk: {
                const wrapped = self.allocator.create(Connection) catch {
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
        self.allocator.destroy(connection);
    }

    fn deinit(raw: *anyopaque) void {
        const self: *Transport = @ptrCast(@alignCast(raw));
        const budget = self.budget;
        const allocator = self.allocator;
        self.underlying.deinit();
        allocator.destroy(self);
        if (budget) |scope| scope.release();
    }
};

test "candidate deadline ends at adoption and never follows old members into later applies" {
    var budget: Budget = .{ .allocator = std.testing.allocator, .io = std.testing.io, .runtime = undefined };
    var candidate: Transport = .{ .allocator = std.testing.allocator, .budget = &budget, .underlying = undefined, .epoch = 1, .timeout_ms = 20 };
    try budget.begin(1);
    budget.started_ns -= 1000 * std.time.ns_per_ms;
    try std.testing.expect(candidate.remaining(20) == null);
    budget.applied();
    try std.testing.expectEqual(@as(?u32, 20), candidate.remaining(20));
    try budget.begin(2);
    budget.started_ns -= 1000 * std.time.ns_per_ms;
    try std.testing.expectEqual(@as(?u32, 20), candidate.remaining(20));
    budget.end();
    candidate.epoch = 3;
    try budget.begin(0);
    budget.started_ns -= 1000 * std.time.ns_per_ms;
    try std.testing.expectEqual(@as(?u32, 20), candidate.remaining(20));
    budget.end();
}

test "management timeout limit preserves long tool calls with and without a candidate scope" {
    const Capture = struct {
        management_ms: u32 = 0,
        tool_ms: u32 = 0,
        destroyed: bool = false,
        fn open(raw: *anyopaque, _: agent.McpPurpose, _: agent.McpEra, _: u32) agent.McpOpenOutcome {
            return .{ .connection = raw };
        }
        fn request(raw: *anyopaque, _: std.mem.Allocator, _: []const u8, timeout_ms: u32, _: agent.McpCancellation) agent.McpExchangeOutcome {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.management_ms = timeout_ms;
            return .{ .failure = .network };
        }
        fn tool(raw: *anyopaque, _: std.mem.Allocator, _: []const u8, timeout_ms: u32, _: agent.McpCancellation) agent.McpExchangeOutcome {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.tool_ms = timeout_ms;
            return .{ .failure = .network };
        }
        fn notify(_: *anyopaque, _: []const u8, _: u32, _: agent.McpCancellation) ?agent.McpTransportFailure {
            return null;
        }
        fn close(_: *anyopaque) void {}
        fn destroy(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.destroyed = true;
        }
    };
    var budget: Budget = .{ .allocator = std.testing.allocator, .io = std.testing.io, .runtime = undefined };
    for ([_]?*Budget{ null, &budget }) |scope| {
        var capture: Capture = .{};
        var source = agent.McpTransportOwner.init(.{ .context = &capture, .open_fn = Capture.open, .request_fn = Capture.request, .tool_request_fn = Capture.tool, .notify_fn = Capture.notify, .close_fn = Capture.close }, Capture.destroy);
        var owner = try wrapTransport(std.testing.allocator, &source, 180_000, scope);
        if (scope) |active| try active.begin(1);
        const transport = owner.transport;
        const connection = switch (transport.open_fn(transport.context, .actual, .modern_2026_07_28, 180_000)) {
            .connection => |value| value,
            else => return error.TestUnexpectedResult,
        };
        _ = transport.request_fn(connection, std.testing.allocator, "management", 180_000, .{});
        _ = transport.tool_request_fn.?(connection, std.testing.allocator, "tool", 180_000, .{});
        try std.testing.expectEqual(product_mcp.contract.max_management_timeout_ms, capture.management_ms);
        try std.testing.expectEqual(@as(u32, 180_000), capture.tool_ms);
        if (scope) |active| {
            active.applied();
            try active.begin(2);
            active.started_ns -= 1000 * std.time.ns_per_s;
            _ = transport.tool_request_fn.?(connection, std.testing.allocator, "tool", 180_000, .{});
            try std.testing.expectEqual(@as(u32, 180_000), capture.tool_ms);
            active.end();
        }
        transport.close_fn(connection);
        owner.deinit();
        try std.testing.expect(capture.destroyed);
    }
}
