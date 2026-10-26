//! Product-owned consumer scope. Bridge only parses and transports this request.
pub const Management = enum { none, skills, mcp, schedules };
pub const ReceiptQuery = struct { task_id: u64, operation_id: []const u8 };
pub const Versions = @import("view_cache.zig").Versions;

pub const Request = struct {
    task_id: ?u64 = null,
    before_run_id: ?u64 = null,
    run_limit: u8 = 4,
    management: Management = .none,
    search: bool = false,
    search_query: []const u8 = "",
    search_cursor: ?@import("metawork_product_task").SearchCursor = null,
    receipts: []const ReceiptQuery = &.{},
    known_epoch: u64 = 0,
    known_versions: Versions = .{},

    pub fn validate(self: Request) error{InvalidViewRequest}!void {
        if (self.run_limit == 0 or self.run_limit > 4) return error.InvalidViewRequest;
        if (self.task_id == 0 or self.before_run_id == 0) return error.InvalidViewRequest;
        if (self.before_run_id != null and self.task_id == null) return error.InvalidViewRequest;
        if (self.receipts.len > 64) return error.InvalidViewRequest;
        const std = @import("std");
        if (self.search_query.len > @import("metawork_product_task").search_query_bytes or !std.unicode.utf8ValidateSlice(self.search_query) or
            (!self.search and (self.search_query.len != 0 or self.search_cursor != null))) return error.InvalidViewRequest;
        if (self.search_cursor) |cursor| if (cursor.revision == 0 or cursor.security_epoch == 0) return error.InvalidViewRequest;
        for (self.receipts, 0..) |query, index| {
            if (query.task_id == 0 or query.operation_id.len == 0 or query.operation_id.len > 64) return error.InvalidViewRequest;
            for (query.operation_id) |byte| if (byte < 0x21 or byte > 0x7e) return error.InvalidViewRequest;
            for (self.receipts[0..index]) |earlier| if (earlier.task_id == query.task_id and std.mem.eql(u8, earlier.operation_id, query.operation_id)) return error.InvalidViewRequest;
        }
    }
};

test "Product view scope rejects unbounded and unassociated history" {
    const std = @import("std");
    try (Request{}).validate();
    try (Request{ .search = true, .search_query = "任务" }).validate();
    try std.testing.expectError(error.InvalidViewRequest, (Request{ .search_query = "hidden query" }).validate());
    try std.testing.expectError(error.InvalidViewRequest, (Request{ .search = true, .search_query = "x" ** 257 }).validate());
    try std.testing.expectError(error.InvalidViewRequest, (Request{ .search = true, .search_query = &.{0xff} }).validate());
    try std.testing.expectError(error.InvalidViewRequest, (Request{ .search = true, .search_cursor = .{ .revision = 0, .security_epoch = 1 } }).validate());
    try (Request{ .task_id = 1, .before_run_id = 9 }).validate();
    try std.testing.expectError(error.InvalidViewRequest, (Request{ .run_limit = 0 }).validate());
    try std.testing.expectError(error.InvalidViewRequest, (Request{ .run_limit = 5 }).validate());
    try std.testing.expectError(error.InvalidViewRequest, (Request{ .before_run_id = 1 }).validate());
    try std.testing.expectError(error.InvalidViewRequest, (Request{ .task_id = 0 }).validate());
    const query = ReceiptQuery{ .task_id = 1, .operation_id = "operation-1" };
    try (Request{ .receipts = &.{query} }).validate();
    try std.testing.expectError(error.InvalidViewRequest, (Request{ .receipts = &.{ query, query } }).validate());
    try std.testing.expectError(error.InvalidViewRequest, (Request{ .receipts = &.{.{ .task_id = 0, .operation_id = "operation-1" }} }).validate());
    try std.testing.expectError(error.InvalidViewRequest, (Request{ .receipts = &.{.{ .task_id = 1, .operation_id = "unsafe\nidentity" }} }).validate());
    var excess: [65]ReceiptQuery = undefined;
    for (&excess, 1..) |*entry, id| entry.* = .{ .task_id = @intCast(id), .operation_id = "operation-1" };
    try (Request{ .receipts = excess[0..64] }).validate();
    try std.testing.expectError(error.InvalidViewRequest, (Request{ .receipts = &excess }).validate());
}
