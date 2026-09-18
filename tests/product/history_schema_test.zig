const std = @import("std");
const schema = @import("product_control_history_schema");
const sql = @import("metawork_storage_sql");
const storage = @import("storage");

test "history schema accepts one complete relational set atomically" {
    const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .memory, schema.migrations);
    defer database.destroy() catch unreachable;
    var mutations: [10]sql.Mutation = undefined;
    var statements = std.mem.splitScalar(u8, @embedFile("history_schema_minimal.sql"), ';');
    var len: usize = 0;
    while (statements.next()) |raw| {
        const statement = std.mem.trim(u8, raw, " \r\n\t");
        if (statement.len == 0) continue;
        mutations[len] = .{ .statement = .{ .sql = statement }, .expected_changes = .{ .exactly = 1 } };
        len += 1;
    }
    try std.testing.expectEqual(@as(usize, 10), len);
    try std.testing.expectEqual(sql.MutationOutcome.committed, database.capability().mutate(&mutations));
    var count: Count = .{};
    try std.testing.expectEqual(sql.QueryOutcome.ok, database.capability().query(
        "SELECT COUNT(*) FROM tasks t JOIN runs r ON r.task_id=t.id JOIN run_tools tool ON tool.task_id=r.task_id AND tool.run_id=r.id JOIN run_file_changes f ON f.task_id=r.task_id AND f.run_id=r.id JOIN task_compacts c ON c.task_id=r.task_id AND c.after_run_id=r.id JOIN task_ui_history ui ON ui.task_id=r.task_id AND ui.run_id=r.id JOIN task_checkpoints cp ON cp.task_id=t.id JOIN workspaces w ON w.id=t.workspace_id",
        &.{},
        count.receiver(),
    ));
    try std.testing.expectEqual(@as(?i64, 1), count.value);
    try std.testing.expectEqual(sql.MutationOutcome.constraint, database.capability().mutate(&.{.{
        .statement = .{ .sql = "DELETE FROM runs" },
    }}));
}

test "history schema creates every business table without bootstrapping business state" {
    // A single module identity is required at the capability boundary.
    comptime if (sql.Database != storage.sql.Database or sql.Migration != storage.sql.Migration)
        @compileError("Storage and Product must share one SQL contract module");
    const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .memory, schema.migrations);
    defer database.destroy() catch unreachable;
    try std.testing.expectEqual(schema.migrations.len, database.schemaVersion());
    for ([_][]const u8{
        "history_state", "history_failures", "workspaces",    "tasks",           "runs",
        "run_tools",     "run_file_changes", "task_compacts", "task_ui_history", "task_checkpoints",
    }) |name| {
        const query = try std.fmt.allocPrint(std.testing.allocator, "SELECT COUNT(*) FROM {s}", .{name});
        defer std.testing.allocator.free(query);
        var count: Count = .{};
        try std.testing.expectEqual(sql.QueryOutcome.ok, database.capability().query(query, &.{}, count.receiver()));
        try std.testing.expectEqual(@as(?i64, 0), count.value);
    }
}

test "history schema preserves unsigned identity and NUL bytes through the public capability" {
    const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .memory, schema.migrations);
    defer database.destroy() catch unreachable;
    const high_id = sql.Value{ .blob = &.{ 0x80, 0, 0, 0, 0, 0, 0, 1 } };
    const one = sql.Value{ .blob = &.{ 0, 0, 0, 0, 0, 0, 0, 1 } };
    const root = sql.Value{ .blob = "C:/history\x00bytes" };
    const insert = "INSERT INTO workspaces(id,epoch,kind,canonical_root,display_name,visible,recent_order) VALUES(?1,?2,'manual',?3,?4,1,?2)";
    const capability = database.capability();
    try std.testing.expectEqual(sql.MutationOutcome.committed, capability.mutate(&.{.{
        .statement = .{ .sql = insert, .params = &.{ high_id, one, root, .{ .blob = "Workspace" } } },
    }}));
    var count: Count = .{};
    try std.testing.expectEqual(sql.QueryOutcome.ok, capability.query("SELECT COUNT(*) FROM workspaces WHERE id=?1 AND canonical_root=?2", &.{ high_id, root }, count.receiver()));
    try std.testing.expectEqual(@as(?i64, 1), count.value);
    try std.testing.expectEqual(sql.MutationOutcome.constraint, capability.mutate(&.{.{
        .statement = .{ .sql = insert, .params = &.{ .null_value, one, root, .{ .blob = "Invalid" } } },
    }}));
    try std.testing.expectEqual(sql.QueryOutcome.rejected, capability.query("SELECT name FROM sqlite_schema", &.{}, count.receiver()));
}

const Count = struct {
    value: ?i64 = null,
    fn receive(context: *anyopaque, row: sql.Row) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.value = switch (row.value(0)) {
            .integer => |value| value,
            else => null,
        };
    }
    fn receiver(self: *@This()) sql.RowReceiver {
        return .{ .context = self, .receive_fn = receive };
    }
};
