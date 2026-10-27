//! Product-owned source identity and encoded block cache. All bytes are sanitized.
const std = @import("std");
pub const Kind = enum { context, workspaces, taskIndex, taskPage, historyPage, management, searchIndex };
/// Independent encoded byte ceilings. Their sum plus 768 KiB of scope,
/// receipts and transport metadata fits the production 64 MiB envelope.
/// Collection admission limits remain authoritative; these are fail-closed
/// view guards, not permission to truncate retained records.
pub fn blockByteLimit(kind: Kind) usize {
    return switch (kind) {
        .context => 12 * 1024 * 1024,
        .workspaces, .taskIndex => 1024 * 1024,
        .taskPage, .historyPage => 12 * 1024 * 1024,
        .management => 25 * 1024 * 1024,
        .searchIndex => 256 * 1024,
    };
}
pub const Versions = struct { context: u64 = 0, workspaces: u64 = 0, taskIndex: u64 = 0, taskPage: u64 = 0, historyPage: u64 = 0, management: u64 = 0, searchIndex: u64 = 0 };
pub const Key = struct {
    kind: Kind,
    task_id: u64 = 0,
    cursor: u64 = 0,
    limit: u8 = 0,
    management: u8 = 0,
    search_query: []const u8 = "",
    search_cursor: [6]u64 = @splat(0),
    fn eql(a: Key, b: Key) bool {
        return a.kind == b.kind and a.task_id == b.task_id and a.cursor == b.cursor and a.limit == b.limit and a.management == b.management and std.mem.eql(u8, a.search_query, b.search_query) and std.meta.eql(a.search_cursor, b.search_cursor);
    }
};
pub const Entry = struct { key: Key, source: []u8, bytes: []u8 = &.{}, version: u64, age: u64, dirty: bool = false };
pub const Error = std.mem.Allocator.Error || error{ ViewVersionExhausted, ViewCacheTooLarge, ViewContentMismatch };
pub const Cache = struct {
    entries: [7]?Entry = @splat(null),
    bytes: usize = 0,
    sequence: u64 = 0,
    clock: u64 = 0,

    pub fn get(self: *Cache, key: Key) ?*const Entry {
        if (self.entries[@intFromEnum(key.kind)]) |*entry| {
            if (entry.dirty or entry.bytes.len == 0 or !Key.eql(entry.key, key)) return null;
            self.clock +|= 1;
            entry.age = self.clock;
            return entry;
        }
        return null;
    }
    pub fn needsEncoded(self: *const Cache, budget: usize, key: Key, version: u64, length: usize) bool {
        const entry = self.entries[@intFromEnum(key.kind)] orelse return false;
        return !entry.dirty and entry.version == version and Key.eql(entry.key, key) and entry.bytes.len == 0 and length <= budget -| (entry.source.len + entry.key.search_query.len);
    }

    /// The one frozen read takes ownership instead of copying an encoded body.
    /// Source/version metadata can be invalidated or evicted independently.
    pub fn takeEncoded(self: *Cache, key: Key, version: u64) ?[]u8 {
        const entry = if (self.entries[@intFromEnum(key.kind)]) |*entry| entry else return null;
        if (entry.dirty or entry.version != version or !Key.eql(entry.key, key) or entry.bytes.len == 0) return null;
        const owned = entry.bytes;
        entry.bytes = &.{};
        self.bytes -= owned.len;
        return owned;
    }

    /// Always consumes ownership. A stale read cannot restore an obsolete body.
    pub fn returnEncoded(self: *Cache, allocator: std.mem.Allocator, budget: usize, key: Key, version: u64, owned: []u8) void {
        const slot = @intFromEnum(key.kind);
        if (self.entries[slot]) |entry| {
            if (!entry.dirty and entry.version == version and Key.eql(entry.key, key) and entry.bytes.len == 0 and owned.len <= budget -| (entry.source.len + entry.key.search_query.len)) {
                self.makeRoom(allocator, budget - owned.len, slot);
                self.entries[slot].?.bytes = owned;
                self.bytes += owned.len;
                return;
            }
        }
        std.crypto.secureZero(u8, owned);
        allocator.free(owned);
    }

    /// Always consumes the exact unescaped source, including on error or a
    /// cache hit. A new version adopts it directly instead of copying and
    /// immediately zeroing another full body on the composition thread.
    pub fn frozenSource(self: *Cache, allocator: std.mem.Allocator, budget: usize, key: Key, source: []u8, current: bool) Error!u64 {
        var adopted = false;
        defer if (!adopted) {
            std.crypto.secureZero(u8, source);
            allocator.free(source);
        };
        const slot = @intFromEnum(key.kind);
        if (self.entries[slot]) |*entry| {
            if (Key.eql(entry.key, key) and std.mem.eql(u8, entry.source, source)) {
                if (current) {
                    entry.dirty = false;
                    self.clock +|= 1;
                    entry.age = self.clock;
                }
                return entry.version;
            }
        }
        const version = std.math.add(u64, self.sequence, 1) catch return error.ViewVersionExhausted;
        if (!current) {
            self.sequence = version;
            return version;
        }
        const source_bytes = std.math.add(usize, source.len, key.search_query.len) catch return error.ViewCacheTooLarge;
        if (source_bytes > budget) return error.ViewCacheTooLarge;
        var owned_key = key;
        owned_key.search_query = try allocator.dupe(u8, key.search_query);
        self.remove(allocator, slot);
        self.makeRoom(allocator, budget - source_bytes, slot);
        self.clock +|= 1;
        self.sequence = version;
        self.entries[slot] = .{ .key = owned_key, .source = source, .version = version, .age = self.clock };
        adopted = true;
        self.bytes += source_bytes;
        return version;
    }
    /// A later Product mutation may have invalidated this frozen read. Such bytes
    /// remain valid for that read, but must not repopulate the current cache.
    pub fn installOwnedEncoded(self: *Cache, allocator: std.mem.Allocator, budget: usize, key: Key, version: u64, owned: []u8) error{ViewContentMismatch}!void {
        if (self.entries[@intFromEnum(key.kind)]) |current| {
            if (!current.dirty and current.version == version and Key.eql(current.key, key) and current.bytes.len != 0 and !std.mem.eql(u8, current.bytes, owned)) {
                std.crypto.secureZero(u8, owned);
                allocator.free(owned);
                return error.ViewContentMismatch;
            }
        }
        self.returnEncoded(allocator, budget, key, version, owned);
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
        std.crypto.secureZero(u8, @constCast(entry.key.search_query));
        allocator.free(entry.key.search_query);
        self.bytes -= entry.bytes.len + entry.source.len + entry.key.search_query.len;
        self.entries[index] = null;
    }
    pub fn clear(self: *Cache, allocator: std.mem.Allocator) void {
        for (0..self.entries.len) |index| self.remove(allocator, index);
    }
};

fn encodeForTest(cache: *Cache, allocator: std.mem.Allocator, budget: usize, key: Key, version: u64, value: []const u8) Error!void {
    return cache.installOwnedEncoded(allocator, budget, key, version, try allocator.dupe(u8, value));
}

fn seed(cache: *Cache, allocator: std.mem.Allocator, budget: usize, key: Key, value: []const u8) Error!u64 {
    const version = try cache.frozenSource(allocator, budget, key, try allocator.dupe(u8, value), true);
    try encodeForTest(cache, allocator, budget, key, version, value);
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
    const old = try cache.frozenSource(std.testing.allocator, 128, key, try std.testing.allocator.dupe(u8, "old source"), true);
    cache.invalidateEvent(1, 1);
    try encodeForTest(&cache, std.testing.allocator, 128, key, old, "old encoded");
    try std.testing.expect(cache.get(key) == null);
    const current = try cache.frozenSource(std.testing.allocator, 128, key, try std.testing.allocator.dupe(u8, "new source"), true);
    try encodeForTest(&cache, std.testing.allocator, 128, key, old, "old encoded");
    try std.testing.expect(cache.get(key) == null);
    try encodeForTest(&cache, std.testing.allocator, 128, key, current, "new encoded");
    try std.testing.expectEqualStrings("new encoded", cache.get(key).?.bytes);
    try std.testing.expectError(error.ViewContentMismatch, encodeForTest(&cache, std.testing.allocator, 128, key, current, "different encoding"));
}

test "Product view obsolete preparation cannot confirm current cache source" {
    var cache: Cache = .{};
    defer cache.clear(std.testing.allocator);
    const key: Key = .{ .kind = .taskPage, .task_id = 3, .limit = 4 };
    const first = try seed(&cache, std.testing.allocator, 128, key, "original");
    cache.invalidate(.taskPage);
    try std.testing.expectEqual(first, try cache.frozenSource(std.testing.allocator, 128, key, try std.testing.allocator.dupe(u8, "original"), false));
    try std.testing.expect(cache.get(key) == null);
    const obsolete = try cache.frozenSource(std.testing.allocator, 128, key, try std.testing.allocator.dupe(u8, "changed"), false);
    try std.testing.expect(obsolete != first);
    try std.testing.expect(cache.get(key) == null);
    const current = try cache.frozenSource(std.testing.allocator, 128, key, try std.testing.allocator.dupe(u8, "current"), true);
    try encodeForTest(&cache, std.testing.allocator, 128, key, obsolete, "changed");
    try std.testing.expect(cache.get(key) == null);
    try encodeForTest(&cache, std.testing.allocator, 128, key, current, "current encoded");
    try std.testing.expectEqualStrings("current encoded", cache.get(key).?.bytes);
}

test "Product view encoded transfer returns only to its exact live source and version" {
    var cache: Cache = .{};
    defer cache.clear(std.testing.allocator);
    const key: Key = .{ .kind = .taskPage, .task_id = 1, .limit = 4 };
    const version = try seed(&cache, std.testing.allocator, 128, key, "body");
    const pointer = cache.get(key).?.bytes.ptr;
    const owned = cache.takeEncoded(key, version).?;
    try std.testing.expectEqual(pointer, owned.ptr);
    try std.testing.expect(cache.get(key) == null);
    try std.testing.expectEqual(@as(usize, 4), cache.bytes);
    cache.returnEncoded(std.testing.allocator, 128, key, version, owned);
    try std.testing.expectEqual(pointer, cache.get(key).?.bytes.ptr);
    const stale = cache.takeEncoded(key, version).?;
    cache.invalidate(.taskPage);
    cache.returnEncoded(std.testing.allocator, 128, key, version, stale);
    try std.testing.expect(cache.get(key) == null);
    const next = try seed(&cache, std.testing.allocator, 128, key, "next");
    const evicted = cache.takeEncoded(key, next).?;
    cache.clear(std.testing.allocator);
    cache.returnEncoded(std.testing.allocator, 128, key, next, evicted);
    try std.testing.expectEqual(@as(usize, 0), cache.bytes);
}

test "Product view independent byte budgets fit one production envelope" {
    var total: usize = 768 * 1024;
    inline for (std.meta.tags(Kind)) |kind| total += blockByteLimit(kind);
    try std.testing.expectEqual(@as(usize, 64 * 1024 * 1024), total);
    try std.testing.expect(blockByteLimit(.searchIndex) >= 50 * (512 * 6 + 256));
}

test "Product view search cache owns exact query bytes under every allocation failure" {
    const Harness = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var cache: Cache = .{};
            defer cache.clear(allocator);
            var query = "needle".*;
            const source = try allocator.dupe(u8, "safe page");
            const source_address = source.ptr;
            const key: Key = .{ .kind = .searchIndex, .limit = 1, .search_query = &query };
            const version = try cache.frozenSource(allocator, 128, key, source, true);
            try std.testing.expectEqual(source_address, cache.entries[@intFromEnum(Kind.searchIndex)].?.source.ptr);
            try encodeForTest(&cache, allocator, 128, key, version, "safe page");
            @memset(&query, 'x');
            try std.testing.expect(cache.get(.{ .kind = .searchIndex, .limit = 1, .search_query = "needle" }) != null);
            try std.testing.expect(cache.get(.{ .kind = .searchIndex, .limit = 1, .search_query = &query }) == null);
            try std.testing.expect(cache.get(.{ .kind = .searchIndex, .limit = 1, .search_query = "needle", .search_cursor = .{ 1, 2, 0, 0, 0, 1 } }) == null);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Harness.run, .{});
}
