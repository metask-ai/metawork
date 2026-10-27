//! Isolated Stage A measurement of the existing public backend, not a history adapter.
const std = @import("std");
const storage = @import("storage");
const sql = storage.sql;
const migrations = [_]sql.Migration{.{ .version = 1, .name = "stage_a_sample", .sql = "CREATE TABLE sample_root(id INTEGER PRIMARY KEY,witness INTEGER);" ++
    "INSERT INTO sample_root VALUES(1,0);" ++
    "CREATE TABLE sample_tasks(id INTEGER PRIMARY KEY,seen INTEGER);" ++
    "CREATE TABLE sample_runs(id INTEGER PRIMARY KEY,task INTEGER,payload BLOB,covered INTEGER);" ++
    "CREATE TABLE sample_approvals(task INTEGER PRIMARY KEY,decision INTEGER);" }};

const IoCounters = extern struct { read_ops: u64, write_ops: u64, other_ops: u64, read_bytes: u64, write_bytes: u64, other_bytes: u64 };
extern "kernel32" fn GetProcessIoCounters(std.os.windows.HANDLE, *IoCounters) callconv(.winapi) i32;
fn counters() IoCounters {
    var result: IoCounters = undefined;
    std.debug.assert(GetProcessIoCounters(std.os.windows.GetCurrentProcess(), &result) != 0);
    return result;
}
fn elapsed(t: std.Io.Timestamp) i96 {
    return t.durationTo(.now(std.testing.io, .awake)).nanoseconds;
}
fn emit(value: anytype) !void {
    const bytes = try std.json.Stringify.valueAlloc(std.testing.allocator, value, .{});
    defer std.testing.allocator.free(bytes);
    std.debug.print("A_BACKEND {s}\n", .{bytes});
}
const Rows = struct {
    rows: usize = 0,
    bytes: usize = 0,
    fn receive(context: *anyopaque, row: sql.Row) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.rows += 1;
        switch (row.value(0)) {
            .blob => |b| self.bytes += b.len,
            else => {},
        }
    }
    fn receiver(self: *@This()) sql.RowReceiver {
        return .{ .context = self, .receive_fn = receive };
    }
};

test "stage A public backend latency and limits" {
    const path = std.mem.span(std.c.getenv("METAWORK_SQLITE_A_DB") orelse return error.MissingPath);
    const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .{ .file = path }, &migrations);
    defer database.destroy() catch unreachable;
    const db = database.capability();
    try std.testing.expectEqual(sql.MutationOutcome.committed, db.mutate(&.{
        .{ .statement = .{ .sql = "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<100) INSERT INTO sample_tasks SELECT x,0 FROM n" } },
        .{ .statement = .{ .sql = "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<25600) INSERT INTO sample_runs SELECT x,(x-1)/256+1,zeroblob(4096),0 FROM n" } },
    }));
    var rows: Rows = .{};
    const query_start: std.Io.Timestamp = .now(std.testing.io, .awake);
    try std.testing.expectEqual(sql.QueryOutcome.ok, db.query("SELECT payload FROM sample_runs ORDER BY id LIMIT 256", &.{}, rows.receiver()));
    try emit(.{ .kind = "bounded_query", .rows = rows.rows, .bytes = rows.bytes, .wall_ns = elapsed(query_start) });
    rows = .{};
    try std.testing.expectEqual(sql.QueryOutcome.resource_exhausted, db.query("SELECT payload FROM sample_runs ORDER BY id", &.{}, rows.receiver()));
    try emit(.{ .kind = "unbounded_query", .outcome = "resource_exhausted", .partial_rows = rows.rows, .partial_bytes = rows.bytes, .note = "consumer must discard incomplete observation" });
    var body: [4096]u8 = @splat('a');
    var mutations: [64]sql.Mutation = undefined;
    var params: [64][2]sql.Value = undefined;
    var witness: i64 = 0;
    // An indivisible representative group: Task receipt + Run + approval.
    // Three statements/group plus one deduplicated root witness -> 21 groups/batch.
    for ([_]usize{ 1, 10, 100 }) |groups| {
        for ([_]bool{ false, true }) |coalesced| {
            for (0..31) |sample| {
                const io_before = counters();
                const start: std.Io.Timestamp = .now(std.testing.io, .awake);
                var completed: usize = 0;
                var commits: usize = 0;
                while (completed < groups) {
                    const count = @min(if (coalesced) @as(usize, 21) else 1, groups - completed);
                    var used: usize = 0;
                    for (0..count) |offset| {
                        const id: i64 = @intCast(completed + offset + 1);
                        params[used] = .{ .{ .integer = id }, .{ .integer = @intCast(sample) } };
                        mutations[used] = .{ .statement = .{ .sql = "UPDATE sample_tasks SET seen=?2 WHERE id=?1", .params = &params[used] }, .expected_changes = .{ .exactly = 1 } };
                        used += 1;
                        params[used] = .{ .{ .integer = (id - 1) * 256 + 1 }, .{ .blob = &body } };
                        body[0] = @intCast('a' + sample % 26);
                        mutations[used] = .{ .statement = .{ .sql = "UPDATE sample_runs SET payload=?2 WHERE id=?1", .params = &params[used] }, .expected_changes = .{ .exactly = 1 } };
                        used += 1;
                        params[used] = .{ .{ .integer = id }, .{ .integer = @intCast(sample) } };
                        mutations[used] = .{ .statement = .{ .sql = "INSERT INTO sample_approvals VALUES(?1,?2) ON CONFLICT(task) DO UPDATE SET decision=excluded.decision", .params = &params[used] }, .expected_changes = .{ .exactly = 1 } };
                        used += 1;
                    }
                    witness += 1;
                    const w = [_]sql.Value{.{ .integer = witness }};
                    mutations[used] = .{ .statement = .{ .sql = "UPDATE sample_root SET witness=?1 WHERE id=1", .params = &w }, .expected_changes = .{ .exactly = 1 } };
                    try std.testing.expectEqual(sql.MutationOutcome.committed, db.mutate(mutations[0 .. used + 1]));
                    completed += count;
                    commits += 1;
                }
                const wall_ns = elapsed(start);
                const io_after = counters();
                try emit(.{ .process_write_bytes = io_after.write_bytes - io_before.write_bytes, .process_write_ops = io_after.write_ops - io_before.write_ops, .kind = "drain", .groups = groups, .coalesced = coalesced, .sample = sample, .commits = commits, .wall_ns = wall_ns, .logical_body_bytes = groups * body.len });
            }
        }
    }
    // Existing admission limits are observed without changing them.
    const over = try std.testing.allocator.alloc(sql.Mutation, sql.Limits.exec_statements + 1);
    defer std.testing.allocator.free(over);
    @memset(over, .{ .statement = .{ .sql = "UPDATE sample_root SET witness=witness+1" } });
    try std.testing.expectEqual(sql.MutationOutcome.rejected, db.mutate(over));
    database.test_hooks.lose_ack_after_commit = true;
    try std.testing.expectEqual(sql.MutationOutcome.outcome_unknown, db.mutate(&.{.{ .statement = .{ .sql = "UPDATE sample_root SET witness=999999" } }}));
    try std.testing.expectEqual(sql.MutationOutcome.unavailable, db.mutate(&.{.{ .statement = .{ .sql = "UPDATE sample_root SET witness=0" } }}));
    try emit(.{ .kind = "limits_unknown", .statements_over_limit = sql.Limits.exec_statements + 1, .lost_commit_ack = "outcome_unknown", .poisoned_write = "unavailable", .note = "reopen/sync primitive is measured separately; no public maintenance method added" });
}
