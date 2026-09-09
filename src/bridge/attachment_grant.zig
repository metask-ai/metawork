const std = @import("std");
const native_sdk = @import("native_sdk");

pub const max_grants: usize = 8;
pub const token_bytes: usize = 24;
pub const token_text_bytes: usize = token_bytes * 2;

const Grant = struct {
    token: [token_text_bytes]u8,
    attachment_id: u64,
    generation: u64,
    window_id: native_sdk.platform.WindowId,
    receive_batch_id: ?u64 = null,
};

pub const Issued = struct {
    token: []const u8,
    attachment_id: u64,
};

pub const Error = error{
    Capacity,
    InvalidAuthority,
    UnknownToken,
    DuplicateToken,
};

/// Bridge-owned authority for Product staging identities. Tokens are random,
/// connection/window-bound, and never expose the monotonic Product identity.
pub const State = struct {
    slots: [max_grants]?Grant = @splat(null),

    pub fn issueBatch(
        self: *State,
        generation: u64,
        window_id: native_sdk.platform.WindowId,
        attachment_ids: []const u64,
        output: []Issued,
        random_context: ?*anyopaque,
        random_fn: *const fn (?*anyopaque, []u8) bool,
    ) Error![]const Issued {
        if (generation == 0 or window_id == 0) return error.InvalidAuthority;
        if (attachment_ids.len == 0 or attachment_ids.len > max_grants or
            output.len < attachment_ids.len or self.freeCount() < attachment_ids.len)
            return error.Capacity;
        var created: usize = 0;
        errdefer while (created != 0) {
            created -= 1;
            self.slots[self.findId(output[created].attachment_id).?] = null;
        };
        for (attachment_ids, 0..) |attachment_id, index| {
            if (attachment_id == 0) return error.InvalidAuthority;
            const slot = self.emptyIndex() orelse return error.Capacity;
            var grant: Grant = .{
                .token = undefined,
                .attachment_id = attachment_id,
                .generation = generation,
                .window_id = window_id,
            };
            while (true) {
                var random: [token_bytes]u8 = undefined;
                if (!random_fn(random_context, &random)) return error.InvalidAuthority;
                grant.token = std.fmt.bytesToHex(random, .lower);
                if (self.findToken(&grant.token) == null) break;
            }
            self.slots[slot] = grant;
            const stored = &self.slots[slot].?;
            output[index] = .{
                .token = &stored.token,
                .attachment_id = attachment_id,
            };
            created += 1;
        }
        return output[0..attachment_ids.len];
    }

    pub fn resolve(
        self: *const State,
        tokens: []const []const u8,
        generation: u64,
        window_id: native_sdk.platform.WindowId,
        output: []u64,
    ) Error![]const u64 {
        if (tokens.len == 0 or tokens.len > max_grants or output.len < tokens.len)
            return error.Capacity;
        for (tokens, 0..) |token, index| {
            for (tokens[0..index]) |previous|
                if (std.mem.eql(u8, previous, token)) return error.DuplicateToken;
            const slot = self.findToken(token) orelse return error.UnknownToken;
            const grant = self.slots[slot].?;
            if (grant.generation != generation or grant.window_id != window_id)
                return error.UnknownToken;
            output[index] = grant.attachment_id;
        }
        return output[0..tokens.len];
    }

    pub fn consume(
        self: *State,
        tokens: []const []const u8,
        generation: u64,
        window_id: native_sdk.platform.WindowId,
    ) void {
        for (tokens) |token| {
            const slot = self.findToken(token) orelse continue;
            const grant = self.slots[slot].?;
            if (grant.generation == generation and grant.window_id == window_id)
                self.slots[slot] = null;
        }
    }

    pub fn release(
        self: *State,
        token: []const u8,
        generation: u64,
        window_id: native_sdk.platform.WindowId,
    ) ?u64 {
        const slot = self.findToken(token) orelse return null;
        const grant = self.slots[slot].?;
        if (grant.generation != generation or grant.window_id != window_id) return null;
        self.slots[slot] = null;
        return grant.attachment_id;
    }

    pub fn takeAll(self: *State, output: []u64) []const u64 {
        var count: usize = 0;
        for (&self.slots) |*slot| {
            const grant = slot.* orelse continue;
            if (count < output.len) {
                output[count] = grant.attachment_id;
                count += 1;
            }
            slot.* = null;
        }
        return output[0..count];
    }

    fn freeCount(self: *const State) usize {
        var count: usize = 0;
        for (self.slots) |slot| if (slot == null) {
            count += 1;
        };
        return count;
    }

    pub fn tagReceiveBatch(self: *State, ids: []const u64, batch_id: u64) void {
        for (ids) |id| self.slots[self.findId(id).?].?.receive_batch_id = batch_id;
    }

    pub fn takeReceiveBatch(self: *State, generation: u64, window_id: native_sdk.platform.WindowId, batch_id: u64, output: []u64) []const u64 {
        var count: usize = 0;
        for (&self.slots) |*slot| {
            const grant = slot.* orelse continue;
            if (grant.generation != generation or grant.window_id != window_id or grant.receive_batch_id != batch_id) continue;
            std.debug.assert(count < output.len);
            output[count] = grant.attachment_id;
            count += 1;
            slot.* = null;
        }
        return output[0..count];
    }

    fn emptyIndex(self: *const State) ?usize {
        for (self.slots, 0..) |slot, index| if (slot == null) return index;
        return null;
    }

    fn findId(self: *const State, id: u64) ?usize {
        for (self.slots, 0..) |slot, index| if (slot) |grant|
            if (grant.attachment_id == id) return index;
        return null;
    }

    fn findToken(self: *const State, token: []const u8) ?usize {
        if (token.len != token_text_bytes) return null;
        for (self.slots, 0..) |slot, index| if (slot) |grant|
            if (std.mem.eql(u8, &grant.token, token)) return index;
        return null;
    }
};

test "attachment grants are opaque authority-bound and one shot" {
    const Random = struct {
        next: u8 = 1,
        fn fill(context: ?*anyopaque, output: []u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            @memset(output, self.next);
            self.next +%= 1;
            return true;
        }
    };
    var state: State = .{};
    var random = Random{};
    var issued_storage: [2]Issued = undefined;
    const issued = try state.issueBatch(
        3,
        7,
        &.{ 11, 12 },
        &issued_storage,
        &random,
        Random.fill,
    );
    try std.testing.expectEqual(@as(usize, token_text_bytes), issued[0].token.len);
    try std.testing.expect(!std.mem.eql(u8, issued[0].token, issued[1].token));
    var ids: [2]u64 = undefined;
    try std.testing.expectEqualSlices(u64, &.{ 11, 12 }, try state.resolve(
        &.{ issued[0].token, issued[1].token },
        3,
        7,
        &ids,
    ));
    try std.testing.expectError(error.UnknownToken, state.resolve(
        &.{issued[0].token},
        4,
        7,
        &ids,
    ));
    try std.testing.expectError(error.UnknownToken, state.resolve(
        &.{issued[0].token},
        3,
        8,
        &ids,
    ));
    try std.testing.expectError(error.DuplicateToken, state.resolve(
        &.{ issued[0].token, issued[0].token },
        3,
        7,
        &ids,
    ));
    state.consume(&.{issued[0].token}, 3, 7);
    try std.testing.expectError(error.UnknownToken, state.resolve(
        &.{issued[0].token},
        3,
        7,
        &ids,
    ));
    try std.testing.expectEqual(@as(?u64, 12), state.release(issued[1].token, 3, 7));
    try std.testing.expectEqual(@as(?u64, null), state.release(issued[1].token, 3, 7));
}

test "attachment grant teardown drains every staged Product identity" {
    const Random = struct {
        next: u8 = 3,
        fn fill(context: ?*anyopaque, output: []u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            @memset(output, self.next);
            self.next +%= 1;
            return true;
        }
    };
    var state: State = .{};
    var random = Random{};
    var issued_storage: [2]Issued = undefined;
    _ = try state.issueBatch(9, 2, &.{ 31, 32 }, &issued_storage, &random, Random.fill);
    var drained: [max_grants]u64 = undefined;
    try std.testing.expectEqualSlices(u64, &.{ 31, 32 }, state.takeAll(&drained));
    try std.testing.expectEqual(@as(usize, max_grants), state.freeCount());
}

test "batch cancellation excludes consumed grants and other batches or connections" {
    const Random = struct {
        next: u8 = 1,
        fn fill(context: ?*anyopaque, output: []u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            @memset(output, self.next);
            self.next += 1;
            return true;
        }
    };
    var state: State = .{};
    var random = Random{};
    var storage: [3]Issued = undefined;
    const issued = try state.issueBatch(2, 3, &.{ 10, 11, 12 }, &storage, &random, Random.fill);
    state.tagReceiveBatch(&.{ 10, 11 }, 1);
    state.tagReceiveBatch(&.{12}, 2);
    state.consume(&.{issued[0].token}, 2, 3);
    var ids: [max_grants]u64 = undefined;
    try std.testing.expectEqual(@as(usize, 0), state.takeReceiveBatch(1, 3, 1, &ids).len);
    try std.testing.expectEqual(@as(usize, 0), state.takeReceiveBatch(2, 4, 1, &ids).len);
    try std.testing.expectEqualSlices(u64, &.{11}, state.takeReceiveBatch(2, 3, 1, &ids));
    try std.testing.expectEqualSlices(u64, &.{12}, try state.resolve(&.{issued[2].token}, 2, 3, &ids));
}
