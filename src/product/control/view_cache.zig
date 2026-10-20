//! Product-owned source identity and encoded block cache. All bytes are sanitized.
const std = @import("std");
pub const Kind = enum { context, workspaces, taskIndex, taskPage, historyPage, management, searchIndex };
pub const Versions = struct { context: u64 = 0, workspaces: u64 = 0, taskIndex: u64 = 0, taskPage: u64 = 0, historyPage: u64 = 0, management: u64 = 0, searchIndex: u64 = 0 };
pub const Key = struct { kind: Kind, task_id: u64 = 0, cursor: u64 = 0, limit: u8 = 0, management: u8 = 0 };
pub const Entry = struct { key: Key, source: []u8, bytes: []u8 = &.{}, version: u64, age: u64, dirty: bool = false };
pub const Error = std.mem.Allocator.Error || error{ ViewVersionExhausted, ViewCacheTooLarge, ViewContentMismatch };
pub const Cache = struct {
    entries: [7]?Entry = @splat(null),
    bytes: usize = 0,
    sequence: u64 = 0,
    clock: u64 = 0,

    pub fn get(self: *Cache, key: Key) ?*const Entry {
        if (self.entries[@intFromEnum(key.kind)]) |*entry| {
            if (entry.dirty or entry.bytes.len == 0 or !std.meta.eql(entry.key, key)) return null;
            self.clock +|= 1;
            entry.age = self.clock;
            return entry;
        }
        return null;
    }
    /// Equality is over canonical unescaped source, not a probabilistic hash.
    /// Versions can therefore be confirmed without synchronously escaping long strings.
    pub fn putSource(self: *Cache, allocator: std.mem.Allocator, budget: usize, key: Key, source: []const u8) Error!u64 {
        const slot = @intFromEnum(key.kind);
        if (self.entries[slot]) |*entry| {
            if (std.meta.eql(entry.key, key) and std.mem.eql(u8, entry.source, source)) {
                entry.dirty = false;
                self.clock +|= 1;
                entry.age = self.clock;
                return entry.version;
            }
        }
        const version = std.math.add(u64, self.sequence, 1) catch return error.ViewVersionExhausted;
        if (source.len > budget) return error.ViewCacheTooLarge;
        const owned = try allocator.dupe(u8, source);
        self.remove(allocator, slot);
        self.makeRoom(allocator, budget - source.len, slot);
        self.clock +|= 1;
        self.sequence = version;
        self.entries[slot] = .{ .key = key, .source = owned, .version = version, .age = self.clock };
        self.bytes += source.len;
        return version;
    }
    /// A later Product mutation may have invalidated this frozen read. Such bytes
    /// remain valid for that read, but must not repopulate the current cache.
    pub fn installEncoded(self: *Cache, allocator: std.mem.Allocator, budget: usize, key: Key, version: u64, value: []const u8) Error!void {
        const slot = @intFromEnum(key.kind);
        const current = self.entries[slot] orelse return;
        if (current.dirty or current.version != version or !std.meta.eql(current.key, key)) return;
        if (current.bytes.len != 0) {
            if (!std.mem.eql(u8, current.bytes, value)) return error.ViewContentMismatch;
            return;
        }
        // Oversized cache entries remain deliverable through the bounded read plan.
        if (value.len > budget -| current.source.len) return;
        const owned = try allocator.dupe(u8, value);
        self.makeRoom(allocator, budget - value.len, slot);
        self.entries[slot].?.bytes = owned;
        self.bytes += value.len;
    }
    fn makeRoom(self: *Cache, allocator: std.mem.Allocator, available: usize, protected: usize) void {
        while (self.bytes > available) {
            var oldest: ?usize = null;
            for (self.entries, 0..) |maybe, index| if (maybe) |entry| {
                if (index != protected and (oldest == null or entry.age < self.entries[oldest.?].?.age)) oldest = index;
            };
            self.remove(allocator, oldest.?);
        }
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
        // Search contains immutable inputs and completed output. Admission,
        // terminal publication and security changes invalidate it through the
        // Product revision boundary; streaming deltas cannot change its body.
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
        std.crypto.secureZero(u8, entry.source);
        allocator.free(entry.source);
        self.bytes -= entry.bytes.len + entry.source.len;
        self.entries[index] = null;
    }
    pub fn clear(self: *Cache, allocator: std.mem.Allocator) void {
        for (0..self.entries.len) |index| self.remove(allocator, index);
    }
};

fn seed(cache: *Cache, allocator: std.mem.Allocator, budget: usize, key: Key, value: []const u8) Error!u64 {
    const version = try cache.putSource(allocator, budget, key, value);
    try cache.installEncoded(allocator, budget, key, version, value);
    return version;
}

test "Product view blocks retain versions through unrelated events and invalidate exact scopes" {
    var cache: Cache = .{};
    defer cache.clear(std.testing.allocator);
    const selected = Key{ .kind = .taskPage, .task_id = 1, .limit = 4 };
    const older = Key{ .kind = .historyPage, .task_id = 1, .cursor = 9, .limit = 4 };
    const version = try seed(&cache, std.testing.allocator, 64, selected, "selected");
    _ = try seed(&cache, std.testing.allocator, 64, older, "history");
    cache.invalidateEvent(2, 3);
    try std.testing.expectEqual(version, cache.get(selected).?.version);
    cache.invalidateEvent(1, 16);
    try std.testing.expect(cache.get(selected) == null);
    try std.testing.expect(cache.get(older) != null);
    try std.testing.expectEqual(version, try seed(&cache, std.testing.allocator, 64, selected, "selected"));
    cache.invalidateEvent(1, 7);
    try std.testing.expect(cache.get(older) == null);
    try std.testing.expect(cache.get(.{ .kind = .taskPage, .task_id = 2, .limit = 4 }) == null);
}

test "Product view block capacity eviction and safety clearing cannot reuse revoked identities" {
    var cache: Cache = .{};
    defer cache.clear(std.testing.allocator);
    const first = Key{ .kind = .context };
    const second = Key{ .kind = .taskIndex };
    const old = try seed(&cache, std.testing.allocator, 14, first, "context");
    _ = try seed(&cache, std.testing.allocator, 14, second, "index");
    try std.testing.expect(cache.get(first) == null);
    try std.testing.expect(cache.bytes <= 14);
    cache.clear(std.testing.allocator);
    try std.testing.expect(cache.get(second) == null);
    const fresh = try seed(&cache, std.testing.allocator, 14, first, "context");
    try std.testing.expect(fresh > old);
}

test "Product view search survives streaming and invalidates at lifecycle boundaries" {
    var cache: Cache = .{};
    defer cache.clear(std.testing.allocator);
    const key = Key{ .kind = .searchIndex, .limit = 1 };
    const version = try seed(&cache, std.testing.allocator, 128, key, "completed search corpus");
    cache.invalidateEvent(1, 2);
    try std.testing.expectEqual(version, cache.get(key).?.version);
    cache.invalidateAll();
    try std.testing.expect(cache.get(key) == null);
}

test "Product view cache allocation failure and version exhaustion preserve the previous block" {
    var cache: Cache = .{};
    defer cache.clear(std.testing.allocator);
    const key = Key{ .kind = .context };
    const version = try seed(&cache, std.testing.allocator, 16, key, "old");
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, seed(&cache, failing.allocator(), 16, key, "new"));
    try std.testing.expectEqualStrings("old", cache.get(key).?.bytes);
    try std.testing.expectEqual(version, cache.sequence);
    try std.testing.expectError(error.ViewCacheTooLarge, seed(&cache, std.testing.allocator, 2, key, "large"));
    cache.sequence = std.math.maxInt(u64);
    try std.testing.expectError(error.ViewVersionExhausted, seed(&cache, std.testing.allocator, 16, key, "new"));
    try std.testing.expectEqual(version, cache.get(key).?.version);
    try std.testing.expectEqual(@as(usize, 6), cache.bytes);
}

test "Product view stale frozen encoding cannot refill a newer or invalidated source" {
    var cache: Cache = .{};
    defer cache.clear(std.testing.allocator);
    const key = Key{ .kind = .taskPage, .task_id = 1, .limit = 4 };
    const old = try cache.putSource(std.testing.allocator, 128, key, "old source");
    cache.invalidateEvent(1, 1);
    try cache.installEncoded(std.testing.allocator, 128, key, old, "old encoded");
    try std.testing.expect(cache.get(key) == null);
    const current = try cache.putSource(std.testing.allocator, 128, key, "new source");
    try cache.installEncoded(std.testing.allocator, 128, key, old, "old encoded");
    try std.testing.expect(cache.get(key) == null);
    try cache.installEncoded(std.testing.allocator, 128, key, current, "new encoded");
    try std.testing.expectEqualStrings("new encoded", cache.get(key).?.bytes);
    try std.testing.expectError(error.ViewContentMismatch, cache.installEncoded(std.testing.allocator, 128, key, current, "different encoding"));
}
