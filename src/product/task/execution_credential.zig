//! Independently retained credential reader for delayed request preparation.
//! No aggregate or Account pointer crosses into a worker.
const std = @import("std");
const models_contract = @import("metawork_product_models_contract");

pub const max_bytes = models_contract.Limits.credential_bytes;

pub const Owned = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,

    pub fn deinit(self: *Owned) void {
        std.crypto.secureZero(u8, self.bytes);
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub const Source = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    references: std.atomic.Value(usize) = .init(1),
    current: [max_bytes]u8 = @splat(0),
    length: usize,
    available: bool = true,

    pub fn create(allocator: std.mem.Allocator, io: std.Io, credential: []const u8) std.mem.Allocator.Error!*Source {
        std.debug.assert(credential.len > 0 and credential.len <= max_bytes);
        const self = try allocator.create(Source);
        self.* = .{ .allocator = allocator, .io = io, .length = credential.len };
        @memcpy(self.current[0..credential.len], credential);
        return self;
    }

    pub fn retain(self: *Source) *Source {
        const before = self.references.fetchAdd(1, .monotonic);
        std.debug.assert(before > 0 and before < std.math.maxInt(usize));
        return self;
    }

    pub fn release(self: *Source) void {
        if (self.references.fetchSub(1, .acq_rel) != 1) return;
        const allocator = self.allocator;
        std.crypto.secureZero(u8, &self.current);
        allocator.destroy(self);
    }

    /// Only the main-thread execution owner writes. Existing requests own
    /// their copies, so no reader borrows bytes across this exchange.
    pub fn replace(self: *Source, credential: []const u8) void {
        std.debug.assert(credential.len > 0 and credential.len <= max_bytes);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        std.crypto.secureZero(u8, &self.current);
        @memcpy(self.current[0..credential.len], credential);
        self.length = credential.len;
        self.available = true;
    }

    pub fn invalidate(self: *Source) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.available = false;
    }

    pub fn matches(self: *Source, credential: []const u8) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return std.mem.eql(u8, self.current[0..self.length], credential);
    }

    pub fn copyInto(self: *Source, buffer: []u8) error{CredentialUnavailable}![]const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.available or buffer.len < self.length) return error.CredentialUnavailable;
        @memcpy(buffer[0..self.length], self.current[0..self.length]);
        return buffer[0..self.length];
    }

    pub fn copy(self: *Source, allocator: std.mem.Allocator) (std.mem.Allocator.Error || error{CredentialUnavailable})!Owned {
        var temporary: [max_bytes]u8 = undefined;
        defer std.crypto.secureZero(u8, &temporary);
        const value = try self.copyInto(&temporary);
        return .{ .allocator = allocator, .bytes = try allocator.dupe(u8, value) };
    }
};

test "Task model credential reader survives its owner and preserves in-flight request copies" {
    const source = try Source.create(std.testing.allocator, std.testing.io, "synthetic-a");
    var first = try source.copy(std.testing.allocator);
    defer first.deinit();
    const reader = source.retain();
    source.replace("synthetic-b");
    source.release();
    defer reader.release();
    var second = try reader.copy(std.testing.allocator);
    defer second.deinit();
    try std.testing.expectEqualStrings("synthetic-a", first.bytes);
    try std.testing.expectEqualStrings("synthetic-b", second.bytes);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, reader.copy(failing.allocator()));
    var after_failure = try reader.copy(std.testing.allocator);
    defer after_failure.deinit();
    try std.testing.expectEqualStrings("synthetic-b", after_failure.bytes);
}

test "Task model credential reader fails closed until a later successful handoff" {
    const source = try Source.create(std.testing.allocator, std.testing.io, "synthetic-a");
    defer source.release();
    source.invalidate();
    var buffer: [max_bytes]u8 = undefined;
    try std.testing.expectError(error.CredentialUnavailable, source.copyInto(&buffer));
    source.replace("synthetic-b");
    try std.testing.expectEqualStrings("synthetic-b", try source.copyInto(&buffer));
}
