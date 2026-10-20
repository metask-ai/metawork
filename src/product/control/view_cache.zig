//! Product-owned encoded view blocks. No execution state or credentials live here.
const std = @import("std");

pub const Kind = enum { context, workspaces, taskIndex, taskPage, historyPage, management, searchIndex };
pub const Versions = struct {
    context: u64 = 0,
    workspaces: u64 = 0,
    taskIndex: u64 = 0,
    taskPage: u64 = 0,
    historyPage: u64 = 0,
    management: u64 = 0,
    searchIndex: u64 = 0,
};
pub const Key = struct {
    kind: Kind,
    task_id: u64 = 0,
    cursor: u64 = 0,
    limit: u8 = 0,
    management: u8 = 0,
};
pub const Entry = struct {
    key: Key,
    bytes: []u8,
    version: u64,
    age: u64,
    dirty: bool = false,
};
pub const Error = std.mem.Allocator.Error || error{ ViewVersionExhausted, ViewCacheTooLarge };

pub const Cache = struct {
    entries: [7]?Entry = @splat(null),
    bytes: usize = 0,
    sequence: u64 = 0,
    clock: u64 = 0,

    pub fn get(self: *Cache, key: Key) ?*const Entry {
        if (self.entries[@intFromEnum(key.kind)]) |*entry| {
            if (entry.dirty or !std.meta.eql(entry.key, key)) return null;
            self.clock +|= 1;
            entry.age = self.clock;
            return entry;
        }
        return null;
    }

    pub fn put(self: *Cache, allocator: std.mem.Allocator, budget: usize, key: Key, value: []const u8) Error!u64 {
        const slot = @intFromEnum(key.kind);
        if (self.entries[slot]) |*entry| {
            if (std.meta.eql(entry.key, key) and std.mem.eql(u8, entry.bytes, value)) {
                entry.dirty = false;
                self.clock +|= 1;
                entry.age = self.clock;
                return entry.version;
            }
        }
        const version = std.math.add(u64, self.sequence, 1) catch return error.ViewVersionExhausted;
        if (value.len > budget) return error.ViewCacheTooLarge;
        // Allocate before eviction so allocation failure cannot publish a partial block.
        const owned = try allocator.dupe(u8, value);
        self.remove(allocator, slot);
        while (self.bytes > budget - value.len) {
            var oldest: ?usize = null;
            for (self.entries, 0..) |maybe, index| if (maybe) |entry| {
                if (oldest == null or entry.age < self.entries[oldest.?].?.age) oldest = index;
            };
            self.remove(allocator, oldest.?);
        }
        self.clock +|= 1;
        self.sequence = version;
        self.entries[slot] = .{ .key = key, .bytes = owned, .version = version, .age = self.clock };
        self.bytes += owned.len;
        return version;
    }

    pub fn invalidateAll(self: *Cache) void {
        for (&self.entries) |*entry| if (entry.*) |*value| {
            value.dirty = true;
        };
    }

    pub fn invalidate(self: *Cache, kind: Kind) void {
        if (self.entries[@intFromEnum(kind)]) |*entry| entry.dirty = true;
    }

    pub fn invalidateEvent(self: *Cache, task_id: u64, run_id: u64) void {
        self.invalidate(.workspaces);
        self.invalidate(.taskIndex);
        self.invalidate(.searchIndex);
        if (self.entries[@intFromEnum(Kind.taskPage)]) |*entry| {
            if (entry.key.task_id == task_id) entry.dirty = true;
        }
        if (self.entries[@intFromEnum(Kind.historyPage)]) |*entry| {
            if (entry.key.task_id == task_id and run_id < entry.key.cursor) entry.dirty = true;
        }
    }

    fn remove(self: *Cache, allocator: std.mem.Allocator, index: usize) void {
        const entry = self.entries[index] orelse return;
        std.crypto.secureZero(u8, entry.bytes);
        allocator.free(entry.bytes);
        self.bytes -= entry.bytes.len;
        self.entries[index] = null;
    }

    pub fn clear(self: *Cache, allocator: std.mem.Allocator) void {
        for (0..self.entries.len) |index| self.remove(allocator, index);
    }
};

test "Product view blocks retain versions through unrelated events and invalidate exact scopes" {
    var cache: Cache = .{};
    defer cache.clear(std.testing.allocator);
    const selected = Key{ .kind = .taskPage, .task_id = 1, .limit = 4 };
    const older = Key{ .kind = .historyPage, .task_id = 1, .cursor = 9, .limit = 4 };
    const version = try cache.put(std.testing.allocator, 32, selected, "selected");
    _ = try cache.put(std.testing.allocator, 32, older, "history");
    cache.invalidateEvent(2, 3);
    try std.testing.expectEqual(version, cache.get(selected).?.version);
    cache.invalidateEvent(1, 16);
    try std.testing.expect(cache.get(selected) == null);
    try std.testing.expect(cache.get(older) != null);
    try std.testing.expectEqual(version, try cache.put(std.testing.allocator, 32, selected, "selected"));
    cache.invalidateEvent(1, 7);
    try std.testing.expect(cache.get(older) == null);
    try std.testing.expect(cache.get(.{ .kind = .taskPage, .task_id = 2, .limit = 4 }) == null);
}

test "Product view block capacity eviction and safety clearing cannot reuse revoked identities" {
    var cache: Cache = .{};
    defer cache.clear(std.testing.allocator);
    const first = Key{ .kind = .context };
    const second = Key{ .kind = .taskIndex };
    const old = try cache.put(std.testing.allocator, 8, first, "context");
    _ = try cache.put(std.testing.allocator, 8, second, "index");
    try std.testing.expect(cache.get(first) == null);
    try std.testing.expect(cache.bytes <= 8);
    cache.clear(std.testing.allocator);
    try std.testing.expect(cache.get(second) == null);
    const fresh = try cache.put(std.testing.allocator, 8, first, "context");
    try std.testing.expect(fresh > old);
}

test "Product view cache allocation failure and version exhaustion preserve the previous block" {
    var cache: Cache = .{};
    defer cache.clear(std.testing.allocator);
    const key = Key{ .kind = .context };
    const version = try cache.put(std.testing.allocator, 16, key, "old");
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, cache.put(failing.allocator(), 16, key, "new"));
    try std.testing.expectEqualStrings("old", cache.get(key).?.bytes);
    try std.testing.expectEqual(version, cache.sequence);
    try std.testing.expectError(error.ViewCacheTooLarge, cache.put(std.testing.allocator, 2, key, "large"));
    cache.sequence = std.math.maxInt(u64);
    try std.testing.expectError(error.ViewVersionExhausted, cache.put(std.testing.allocator, 16, key, "new"));
    try std.testing.expectEqual(version, cache.get(key).?.version);
    try std.testing.expectEqual(@as(usize, 3), cache.bytes);
}
