//! Backend-shared contract checks. Concrete backends add their integration
//! fixtures here without changing Product-facing types.

const std = @import("std");
const sql = @import("sql.zig");

/// Exercise behavior that every concrete backend must preserve. The fixture
/// migration must create the table used below before this function runs.
pub fn expectBackendContract(database: sql.Database) !void {
    try std.testing.expectEqual(
        sql.MutationOutcome.committed,
        database.mutate(&.{.{ .statement = .{ .sql = "DELETE FROM storage_conformance" } }}),
    );
    try std.testing.expectEqual(
        sql.MutationOutcome.committed,
        database.mutate(&.{.{
            .statement = .{
                .sql =
                \\INSERT INTO storage_conformance(
                \\  id, integer_value, real_value, text_value, blob_value, nullable
                \\) VALUES (?, ?, ?, ?, ?, ?)
                ,
                .params = &.{
                    .{ .integer = 1 },
                    .{ .integer = -7 },
                    .{ .real = 2.5 },
                    .{ .text = "ready" },
                    .{ .blob = "\x00\xff" },
                    .null_value,
                },
            },
            .expected_changes = .{ .exactly = 1 },
        }}),
    );

    var observed = BackendObservation{};
    const receiver: sql.RowReceiver = .{
        .context = &observed,
        .receive_fn = BackendObservation.receive,
    };
    try std.testing.expectEqual(
        sql.QueryOutcome.ok,
        database.query(
            \\SELECT id, integer_value, real_value, text_value, blob_value, nullable
            \\FROM storage_conformance ORDER BY id
        , &.{}, receiver),
    );
    try std.testing.expect(observed.valid);
    try std.testing.expectEqual(@as(usize, 1), observed.rows);

    try std.testing.expectEqual(
        sql.MutationOutcome.constraint,
        database.mutate(&.{.{
            .statement = .{
                .sql = "INSERT INTO storage_conformance(id) VALUES (?)",
                .params = &.{.{ .integer = 1 }},
            },
        }}),
    );

    try std.testing.expectEqual(
        sql.MutationOutcome.rejected,
        database.mutate(&.{
            .{
                .statement = .{
                    .sql = "INSERT INTO storage_conformance(id) VALUES (?)",
                    .params = &.{.{ .integer = 2 }},
                },
            },
            .{ .statement = .{ .sql = "SELECT id FROM storage_conformance" } },
        }),
    );
    var count = IntegerObservation{};
    try std.testing.expectEqual(
        sql.QueryOutcome.ok,
        database.query(
            "SELECT COUNT(*) FROM storage_conformance WHERE id = ?",
            &.{.{ .integer = 2 }},
            .{ .context = &count, .receive_fn = IntegerObservation.receive },
        ),
    );
    try std.testing.expectEqual(@as(i64, 0), count.value);

    var reentry = ReentryObservation{ .database = database };
    try std.testing.expectEqual(
        sql.QueryOutcome.ok,
        database.query(
            "SELECT id FROM storage_conformance LIMIT 1",
            &.{},
            .{ .context = &reentry, .receive_fn = ReentryObservation.receive },
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), reentry.rows);
    try std.testing.expectEqual(sql.QueryOutcome.rejected, reentry.query_outcome);
    try std.testing.expectEqual(sql.MutationOutcome.rejected, reentry.mutation_outcome);

    try std.testing.expectEqual(
        sql.QueryOutcome.rejected,
        database.query(
            "SELECT 1; SELECT 2",
            &.{},
            .{ .context = &count, .receive_fn = IntegerObservation.receive },
        ),
    );
}

const BackendObservation = struct {
    rows: usize = 0,
    valid: bool = true,

    fn receive(context: *anyopaque, row: sql.Row) void {
        const self: *BackendObservation = @ptrCast(@alignCast(context));
        self.rows += 1;
        self.valid = self.valid and row.columnCount() == 6;
        self.valid = self.valid and row.value(0).integer == 1;
        self.valid = self.valid and row.value(1).integer == -7;
        self.valid = self.valid and row.value(2).real == 2.5;
        self.valid = self.valid and std.mem.eql(u8, row.value(3).text, "ready");
        self.valid = self.valid and std.mem.eql(u8, row.value(4).blob, "\x00\xff");
        self.valid = self.valid and row.value(5) == .null_value;
    }
};

const ReentryObservation = struct {
    database: sql.Database,
    rows: usize = 0,
    query_outcome: sql.QueryOutcome = .ok,
    mutation_outcome: sql.MutationOutcome = .committed,

    fn receive(context: *anyopaque, _: sql.Row) void {
        const self: *ReentryObservation = @ptrCast(@alignCast(context));
        self.rows += 1;
        var ignored = IntegerObservation{};
        self.query_outcome = self.database.query(
            "SELECT 1",
            &.{},
            .{ .context = &ignored, .receive_fn = IntegerObservation.receive },
        );
        self.mutation_outcome = self.database.mutate(&.{.{
            .statement = .{ .sql = "DELETE FROM storage_conformance" },
        }});
    }
};

const IntegerObservation = struct {
    value: i64 = -1,

    fn receive(context: *anyopaque, row: sql.Row) void {
        const self: *IntegerObservation = @ptrCast(@alignCast(context));
        self.value = row.value(0).integer;
    }
};

const FakeBackend = struct {
    query_calls: usize = 0,
    mutate_calls: usize = 0,
    query_outcome: sql.QueryOutcome = .ok,
    mutation_outcome: sql.MutationOutcome = .committed,

    fn capability(self: *FakeBackend) sql.Database {
        return .{
            .context = self,
            .query_fn = query,
            .mutate_fn = mutate,
        };
    }

    fn query(
        context: *anyopaque,
        _: []const u8,
        _: []const sql.Value,
        _: sql.RowReceiver,
    ) sql.QueryOutcome {
        const self: *FakeBackend = @ptrCast(@alignCast(context));
        self.query_calls += 1;
        return self.query_outcome;
    }

    fn mutate(
        context: *anyopaque,
        _: []const sql.Mutation,
    ) sql.MutationOutcome {
        const self: *FakeBackend = @ptrCast(@alignCast(context));
        self.mutate_calls += 1;
        return self.mutation_outcome;
    }
};

const FakeRow = struct {
    names: []const []const u8,
    values: []const sql.Value,

    fn row(self: *FakeRow) sql.Row {
        return .{
            .context = self,
            .column_count = self.values.len,
            .column_name_fn = columnName,
            .value_fn = value,
        };
    }

    fn columnName(context: *anyopaque, index: usize) []const u8 {
        const self: *FakeRow = @ptrCast(@alignCast(context));
        return self.names[index];
    }

    fn value(context: *anyopaque, index: usize) sql.Value {
        const self: *FakeRow = @ptrCast(@alignCast(context));
        return self.values[index];
    }
};

test "SQL contract rejects invalid query input before backend dispatch" {
    var backend: FakeBackend = .{};
    const database = backend.capability();
    var ignored: u8 = 0;
    const receiver: sql.RowReceiver = .{
        .context = &ignored,
        .receive_fn = struct {
            fn receive(_: *anyopaque, _: sql.Row) void {}
        }.receive,
    };

    try std.testing.expectEqual(
        sql.QueryOutcome.rejected,
        database.query("", &.{}, receiver),
    );
    try std.testing.expectEqual(
        sql.QueryOutcome.rejected,
        database.query("SELECT\x00 1", &.{}, receiver),
    );
    var too_many: [sql.Limits.parameters + 1]sql.Value =
        @splat(.null_value);
    try std.testing.expectEqual(
        sql.QueryOutcome.rejected,
        database.query("SELECT 1", &too_many, receiver),
    );
    try std.testing.expectEqual(@as(usize, 0), backend.query_calls);

    backend.query_outcome = .busy;
    try std.testing.expectEqual(
        sql.QueryOutcome.busy,
        database.query("SELECT ?", &.{.{ .integer = 1 }}, receiver),
    );
    try std.testing.expectEqual(@as(usize, 1), backend.query_calls);
}

test "SQL contract validates values and mutation batches" {
    try std.testing.expect(!sql.validParameters(
        &.{.{ .text = "a\x00b" }},
        sql.Limits.query_parameter_bytes,
    ));
    try std.testing.expect(!sql.validParameters(
        &.{.{ .real = std.math.inf(f64) }},
        sql.Limits.query_parameter_bytes,
    ));
    try std.testing.expect(!sql.validParameters(
        &.{.{ .text = "\xff" }},
        sql.Limits.query_parameter_bytes,
    ));

    var backend: FakeBackend = .{ .mutation_outcome = .constraint };
    const database = backend.capability();
    try std.testing.expectEqual(
        sql.MutationOutcome.rejected,
        database.mutate(&.{}),
    );
    try std.testing.expectEqual(@as(usize, 0), backend.mutate_calls);
    try std.testing.expectEqual(
        sql.MutationOutcome.constraint,
        database.mutate(&.{.{
            .statement = .{
                .sql = "INSERT INTO t(value) VALUES (?)",
                .params = &.{.{ .text = "value" }},
            },
        }}),
    );
    try std.testing.expectEqual(@as(usize, 1), backend.mutate_calls);
}

test "SQL migrations are contiguous append-only inputs" {
    try std.testing.expect(sql.validMigrations(&.{}));
    try std.testing.expect(sql.validMigrations(&.{
        .{ .version = 1, .name = "create", .sql = "CREATE TABLE t(id INTEGER);" },
        .{ .version = 2, .name = "index", .sql = "CREATE INDEX t_id ON t(id);" },
    }));
    try std.testing.expect(!sql.validMigrations(&.{
        .{ .version = 2, .name = "gap", .sql = "SELECT 1;" },
    }));
    try std.testing.expect(!sql.validMigrations(&.{
        .{ .version = 1, .name = "", .sql = "SELECT 1;" },
    }));
}

test "row receiver exposes typed borrowed values synchronously" {
    const names = [_][]const u8{ "id", "label" };
    const values = [_]sql.Value{
        .{ .integer = 7 },
        .{ .text = "ready" },
    };
    var fake_row: FakeRow = .{ .names = &names, .values = &values };
    var observed: bool = false;
    const receiver: sql.RowReceiver = .{
        .context = &observed,
        .receive_fn = struct {
            fn receive(context: *anyopaque, row: sql.Row) void {
                const result: *bool = @ptrCast(@alignCast(context));
                std.debug.assert(row.columnCount() == 2);
                std.debug.assert(std.mem.eql(u8, row.columnName(1), "label"));
                std.debug.assert(row.value(0).integer == 7);
                std.debug.assert(std.mem.eql(u8, row.value(1).text, "ready"));
                result.* = true;
            }
        }.receive,
    };

    receiver.receive(fake_row.row());
    try std.testing.expect(observed);
}
