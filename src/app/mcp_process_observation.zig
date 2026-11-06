//! Application-owned, reference-counted facts shared with a concrete STDIO owner.
//! No diagnostic text, stderr, model data, or Product pointer crosses this seam.
const std = @import("std");
const contract = @import("metawork_product_mcp").contract;

pub const Notifier = struct {
    context: *anyopaque,
    notify_fn: *const fn (*anyopaque) void,
};

pub const Slot = struct {
    allocator: std.mem.Allocator,
    refs: std.atomic.Value(usize) = .init(1),
    server_id: []u8,
    source: [32]u8,
    attempt: u64,
    fact: std.atomic.Value(contract.ProcessFact) = .init(.pending),
    notifier: Notifier,
    notifications: std.atomic.Value(bool) = .init(true),

    pub fn init(allocator: std.mem.Allocator, server: contract.ServerWire, attempt: u64, notifier: Notifier) !*Slot {
        const slot = try allocator.create(Slot);
        errdefer allocator.destroy(slot);
        slot.* = .{ .allocator = allocator, .server_id = try allocator.dupe(u8, server.id), .source = contract.runtimeDescriptorFingerprint(server), .attempt = attempt, .notifier = notifier };
        return slot;
    }
    pub fn retain(self: *Slot) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }
    pub fn release(self: *Slot) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        const allocator = self.allocator;
        allocator.free(self.server_id);
        allocator.destroy(self);
    }
    pub fn record(self: *Slot, fact: contract.ProcessFact) void {
        if (self.fact.swap(fact, .acq_rel) != fact and self.notifications.load(.acquire))
            self.notifier.notify_fn(self.notifier.context);
    }
    pub fn snapshot(self: *const Slot) contract.ProcessObservation {
        return .{ .server_id = self.server_id, .source = self.source, .attempt = self.attempt, .fact = self.fact.load(.acquire) };
    }
};

pub const Collection = struct {
    allocator: std.mem.Allocator,
    slots: []*Slot = &.{},

    pub fn deinit(self: *Collection) void {
        for (self.slots) |slot| slot.release();
        if (self.slots.len != 0) self.allocator.free(self.slots);
        self.slots = &.{};
    }
    pub fn stopNotifications(self: *Collection) void {
        for (self.slots) |slot| slot.notifications.store(false, .release);
    }
    /// Keep exactly the candidate membership, sharing retained owners by identity.
    pub fn compose(self: Collection, replacement: Collection, members: []const []const u8, candidate_id: ?[]const u8) !Collection {
        var slots: std.ArrayList(*Slot) = .empty;
        defer slots.deinit(self.allocator);
        errdefer for (slots.items) |slot| slot.release();
        for (members) |id| {
            const candidate = if (candidate_id) |candidate| std.mem.eql(u8, id, candidate) else false;
            const source = if (candidate) replacement.slots else self.slots;
            for (source) |slot| {
                if (!std.mem.eql(u8, id, slot.server_id)) continue;
                try slots.append(self.allocator, slot);
                slot.retain();
                break;
            }
        }
        return .{ .allocator = self.allocator, .slots = try slots.toOwnedSlice(self.allocator) };
    }
};

test "MCP process observations retain only the selected membership owners" {
    const Host = struct {
        fn notify(_: *anyopaque) void {}
    };
    var marker: u8 = 0;
    const server: contract.ServerWire = .{ .id = "local", .namespace = "local", .display_name = "Local", .enabled = true, .negotiation = "automatic", .timeout_ms = 1000, .transport = .{ .kind = "stdio", .command = "node" }, .auth = .{ .kind = "none", .oauth = null }, .connection_approval = null, .tools = &.{} };
    const slots = try std.testing.allocator.alloc(*Slot, 1);
    slots[0] = try Slot.init(std.testing.allocator, server, 1, .{ .context = &marker, .notify_fn = Host.notify });
    var original: Collection = .{ .allocator = std.testing.allocator, .slots = slots };
    const replacement_slots = try std.testing.allocator.alloc(*Slot, 1);
    replacement_slots[0] = try Slot.init(std.testing.allocator, server, 2, .{ .context = &marker, .notify_fn = Host.notify });
    var replacement: Collection = .{ .allocator = std.testing.allocator, .slots = replacement_slots };
    var composed = try original.compose(replacement, &.{"local"}, "local");
    defer composed.deinit();
    original.deinit();
    replacement.deinit();
    try std.testing.expectEqual(@as(usize, 1), composed.slots.len);
    try std.testing.expectEqual(@as(u64, 2), composed.slots[0].snapshot().attempt);
    composed.slots[0].record(.spawned);
    try std.testing.expectEqual(contract.ProcessFact.spawned, composed.slots[0].snapshot().fact);
    var removed = try composed.compose(.{ .allocator = std.testing.allocator }, &.{}, null);
    defer removed.deinit();
    try std.testing.expectEqual(@as(usize, 0), removed.slots.len);
}
