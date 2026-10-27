//! Direct SQLite backend for the backend-neutral Storage SQL contract.
//! SQLite values, handles, authorizers, profile, and recovery state never
//! escape this owner.

const std = @import("std");
const builtin = @import("builtin");
const sql = @import("metawork_storage_sql");
const conformance = @import("conformance.zig");
const backend = @import("sqlite/connection.zig");
const migration_engine = @import("sqlite/migrations.zig");

const c = backend.c;
const Connection = backend.Connection;
const SqlError = backend.SqlError;
const bindAll = backend.bindAll;
const columnBlob = backend.columnBlob;
const columnName = backend.columnName;
const columnText = backend.columnText;
const columnValue = backend.columnValue;
const denyAllAuthorizer = backend.denyAllAuthorizer;
const initializeConnection = backend.initialize;
const initializeFailure = backend.initializeFailure;
const internalTransactionAuthorizer = backend.internalTransactionAuthorizer;
const mutationAuthorizer = backend.mutationAuthorizer;
const parameterCount = backend.parameterCount;
const prepareOne = backend.prepareOne;
const queryAuthorizer = backend.queryAuthorizer;
const rowBytes = backend.rowBytes;
const setTextPragma = backend.setTextPragma;
const sqlFailure = backend.sqlFailure;
const applyMigrations = migration_engine.apply;

pub const Target = union(enum) {
    file: []const u8,
    memory,
};

pub const OpenError = backend.OpenError;
pub const LifecycleError = error{ReentrantOperation};

const Lifecycle = enum { active, stopping, stopped, poisoned };
const Admission = enum { entered, rejected, unavailable };
const TestHooks = if (builtin.is_test) struct {
    fail_before_commit: bool = false,
    lose_ack_after_commit: bool = false,
    fail_rollback: bool = false,
    fail_authorizer_restore: bool = false,
    fail_maintenance_sync: bool = false,
    waiting_callers: usize = 0,
} else struct {};

/// Stable concrete owner. create() allocates the instance so capabilities can
/// safely borrow its address until shutdown() and destroy().
pub const Database = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    connection: Connection,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    lifecycle: Lifecycle = .active,
    operating: bool = false,
    active_thread: ?std.Thread.Id = null,
    schema_version: u32,
    durable: bool,
    test_hooks: TestHooks = .{},

    pub fn create(
        io: std.Io,
        allocator: std.mem.Allocator,
        target: Target,
        migrations: []const sql.Migration,
    ) OpenError!*Database {
        if (!sql.validMigrations(migrations)) return error.InvalidMigrations;

        var owned_path: ?[:0]u8 = null;
        defer if (owned_path) |path| allocator.free(path);
        const is_file = target == .file;
        const path: [:0]const u8 = switch (target) {
            .memory => ":memory:",
            .file => |file_path| path: {
                if (file_path.len == 0 or !std.fs.path.isAbsolute(file_path) or
                    !std.unicode.utf8ValidateSlice(file_path) or
                    std.mem.indexOfScalar(u8, file_path, 0) != null)
                    return error.InvalidTarget;
                const duplicated = allocator.dupeZ(u8, file_path) catch
                    return error.OutOfMemory;
                owned_path = duplicated;
                break :path duplicated;
            },
        };

        var connection = try Connection.open(path);
        errdefer connection.close();
        try initializeConnection(&connection, is_file);
        const schema_version = try applyMigrations(allocator, &connection, migrations);
        connection.setAuthorizer(denyAllAuthorizer) catch |err|
            return initializeFailure(err);

        const self = allocator.create(Database) catch return error.OutOfMemory;
        self.* = .{
            .io = io,
            .allocator = allocator,
            .connection = connection,
            .schema_version = schema_version,
            .durable = is_file,
        };
        return self;
    }

    pub fn shutdown(self: *Database) LifecycleError!void {
        self.lock();
        defer self.unlock();
        if (self.operating and self.active_thread == std.Thread.getCurrentId())
            return error.ReentrantOperation;
        if (self.lifecycle == .stopped) {
            return;
        }
        if (self.lifecycle == .stopping) {
            while (self.lifecycle != .stopped) self.wait();
            return;
        }
        self.lifecycle = .stopping;
        self.broadcast();
        if (self.operating) c.sqlite3_interrupt(self.connection.handle);
        while (self.operating) self.wait();
        self.connection.close();
        self.lifecycle = .stopped;
        self.broadcast();
    }

    /// The owner must first stop and join every other caller, including
    /// admission waiters and concurrent shutdown callers, before destruction.
    pub fn destroy(self: *Database) LifecycleError!void {
        try self.shutdown();
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn interrupt(self: *Database) void {
        self.lock();
        defer self.unlock();
        if (self.operating and self.lifecycle != .stopped)
            c.sqlite3_interrupt(self.connection.handle);
    }

    pub fn capability(self: *Database) sql.Database {
        return .{
            .context = self,
            .query_fn = queryBound,
            .mutate_fn = mutateBound,
            .maintain_fn = maintainBound,
            .mutate_chunks_fn = mutateChunksBound,
        };
    }

    fn maintain(self: *Database, operation: sql.Maintenance) sql.QueryOutcome {
        switch (self.beginOperation()) {
            .entered => {},
            .rejected => return .rejected,
            .unavailable => return .unavailable,
        }
        defer self.endOperation();
        if (!self.durable or c.sqlite3_get_autocommit(self.connection.handle) == 0)
            return .rejected;
        var log: c_int = -1;
        var copied: c_int = -1;
        const mode = if (operation == .purge) c.SQLITE_CHECKPOINT_TRUNCATE else c.SQLITE_CHECKPOINT_FULL;
        const result = c.sqlite3_wal_checkpoint_v2(self.connection.handle, "main", mode, &log, &copied);
        if (result != c.SQLITE_OK) {
            const failure = queryFailure(sqlFailure(result));
            if (failure == .definite_io_failure or failure == .corrupt) self.markPoisoned();
            return failure;
        }
        // -1/-1 is an unperformed checkpoint, not a durable acknowledgment.
        if (log < 0 or copied != log or (operation == .purge and log != 0))
            return .rejected;
        if (builtin.is_test and self.test_hooks.fail_maintenance_sync) {
            self.test_hooks.fail_maintenance_sync = false;
            self.markPoisoned();
            return .definite_io_failure;
        }
        backend.syncFile(&self.connection, true) catch |err| {
            self.markPoisoned();
            return queryFailure(err);
        };
        backend.syncFile(&self.connection, false) catch |err| {
            self.markPoisoned();
            return queryFailure(err);
        };
        return .ok;
    }

    pub fn schemaVersion(self: *Database) u32 {
        self.lock();
        defer self.unlock();
        return self.schema_version;
    }

    fn query(
        self: *Database,
        text: []const u8,
        params: []const sql.Value,
        receiver: sql.RowReceiver,
    ) sql.QueryOutcome {
        switch (self.beginOperation()) {
            .entered => {},
            .rejected => return .rejected,
            .unavailable => return .unavailable,
        }
        defer self.endOperation();

        self.connection.setAuthorizer(queryAuthorizer) catch |err|
            return queryFailure(err);
        const outcome = self.runQuery(text, params, receiver);
        self.connection.setAuthorizer(denyAllAuthorizer) catch {
            self.markPoisoned();
            return .unavailable;
        };
        return outcome;
    }

    fn runQuery(
        self: *Database,
        text: []const u8,
        params: []const sql.Value,
        receiver: sql.RowReceiver,
    ) sql.QueryOutcome {
        const statement = prepareOne(&self.connection, text) catch |err|
            return queryFailure(err);
        defer _ = c.sqlite3_finalize(statement);
        if (c.sqlite3_stmt_readonly(statement) == 0 or
            parameterCount(statement) != params.len)
            return .rejected;
        bindAll(statement, params) catch |err| return queryFailure(err);

        var column_count: usize = 0;
        var total_bytes: usize = 0;
        var row_count: usize = 0;
        while (true) switch (c.sqlite3_step(statement)) {
            c.SQLITE_DONE => return .ok,
            c.SQLITE_ROW => {
                // The first step may recompile against another connection's
                // schema change. Only the executing statement owns the shape.
                if (row_count == 0) {
                    column_count = @intCast(c.sqlite3_column_count(statement));
                    for (0..column_count) |index| {
                        const name = columnName(statement, index);
                        if (!std.unicode.utf8ValidateSlice(name)) return .rejected;
                        total_bytes = std.math.add(usize, total_bytes, name.len) catch
                            return .resource_exhausted;
                        if (total_bytes > sql.Limits.result_bytes) return .resource_exhausted;
                    }
                }
                if (row_count == sql.Limits.result_rows) return .resource_exhausted;
                total_bytes = rowBytes(statement, column_count, total_bytes) catch |err|
                    return queryFailure(err);
                if (total_bytes > sql.Limits.result_bytes) return .resource_exhausted;
                var row_context: RowContext = .{
                    .statement = statement,
                    .column_count = column_count,
                };
                receiver.receive(row_context.row());
                row_count += 1;
            },
            else => |result| return queryFailure(sqlFailure(result)),
        };
    }

    fn mutate(
        self: *Database,
        mutations: []const sql.Mutation,
    ) sql.MutationOutcome {
        return self.mutateChunks(&.{mutations});
    }

    fn mutateChunks(self: *Database, chunks: []const []const sql.Mutation) sql.MutationOutcome {
        switch (self.beginOperation()) {
            .entered => {},
            .rejected => return .rejected,
            .unavailable => return .unavailable,
        }
        defer self.endOperation();
        if (c.sqlite3_get_autocommit(self.connection.handle) == 0) {
            self.markPoisoned();
            return .outcome_unknown;
        }

        self.connection.setAuthorizer(internalTransactionAuthorizer) catch |err|
            return mutationFailure(err);
        self.connection.execRaw("BEGIN IMMEDIATE;") catch |err| {
            return self.finishKnownMutation(mutationFailure(err));
        };
        self.connection.setAuthorizer(mutationAuthorizer) catch |err|
            return self.rollbackMutation(mutationFailure(err));

        for (chunks) |chunk| for (chunk) |mutation| {
            const item = mutation.statement;
            const statement = prepareOne(&self.connection, item.sql) catch |err|
                return self.rollbackMutation(mutationFailure(err));
            const failure = executeMutation(
                &self.connection,
                statement,
                item.params,
                mutation.expected_changes,
            );
            _ = c.sqlite3_finalize(statement);
            if (failure) |outcome| return self.rollbackMutation(outcome);
        };
        return self.commitMutation();
    }

    fn commitMutation(self: *Database) sql.MutationOutcome {
        self.connection.setAuthorizer(internalTransactionAuthorizer) catch
            return self.unknownMutation();
        self.attemptCommit() catch |err| {
            if (c.sqlite3_get_autocommit(self.connection.handle) != 0)
                return self.unknownMutation();
            return self.rollbackMutation(mutationFailure(err));
        };
        if (c.sqlite3_get_autocommit(self.connection.handle) == 0)
            return self.unknownMutation();
        return self.finishKnownMutation(.committed);
    }

    fn attemptCommit(self: *Database) SqlError!void {
        // Inject at the engine-result boundary, so tests exercise the same
        // autocommit/rollback classification as an actual COMMIT error.
        if (builtin.is_test and self.test_hooks.fail_before_commit) {
            self.test_hooks.fail_before_commit = false;
            return error.IoFailed;
        }
        try self.connection.execRaw("COMMIT;");
        if (builtin.is_test and self.test_hooks.lose_ack_after_commit) {
            self.test_hooks.lose_ack_after_commit = false;
            return error.IoFailed;
        }
    }

    fn rollbackMutation(
        self: *Database,
        outcome: sql.MutationOutcome,
    ) sql.MutationOutcome {
        if (builtin.is_test and self.test_hooks.fail_rollback and
            c.sqlite3_get_autocommit(self.connection.handle) == 0)
        {
            self.test_hooks.fail_rollback = false;
            return self.unknownMutation();
        }
        if (!self.connection.rollbackConfirmed()) return self.unknownMutation();
        return self.finishKnownMutation(outcome);
    }

    fn finishKnownMutation(self: *Database, outcome: sql.MutationOutcome) sql.MutationOutcome {
        // Connection health is separate from a known commit/rollback result.
        if (!self.restoreDeny()) self.markPoisoned();
        return outcome;
    }

    fn unknownMutation(self: *Database) sql.MutationOutcome {
        _ = self.restoreDeny();
        self.markPoisoned();
        return .outcome_unknown;
    }

    fn restoreDeny(self: *Database) bool {
        if (builtin.is_test and self.test_hooks.fail_authorizer_restore) {
            self.test_hooks.fail_authorizer_restore = false;
            return false;
        }
        self.connection.setAuthorizer(denyAllAuthorizer) catch return false;
        return true;
    }

    fn beginOperation(self: *Database) Admission {
        const thread_id = std.Thread.getCurrentId();
        self.lock();
        defer self.unlock();
        var registered_waiter = false;
        defer if (builtin.is_test and registered_waiter) {
            self.test_hooks.waiting_callers -= 1;
        };
        while (true) {
            if (self.lifecycle != .active) return .unavailable;
            if (!self.operating) {
                self.operating = true;
                self.active_thread = thread_id;
                return .entered;
            }
            if (self.active_thread == thread_id) return .rejected;
            if (builtin.is_test and !registered_waiter) {
                registered_waiter = true;
                self.test_hooks.waiting_callers += 1;
                self.broadcast();
            }
            self.wait();
        }
    }

    fn endOperation(self: *Database) void {
        self.lock();
        std.debug.assert(self.operating);
        std.debug.assert(self.active_thread == std.Thread.getCurrentId());
        self.operating = false;
        self.active_thread = null;
        self.broadcast();
        self.unlock();
    }

    fn markPoisoned(self: *Database) void {
        self.lock();
        if (self.lifecycle == .active) self.lifecycle = .poisoned;
        self.broadcast();
        self.unlock();
    }

    fn lock(self: *Database) void {
        self.mutex.lockUncancelable(self.io);
    }

    fn unlock(self: *Database) void {
        self.mutex.unlock(self.io);
    }

    fn wait(self: *Database) void {
        self.condition.waitUncancelable(self.io, &self.mutex);
    }

    fn broadcast(self: *Database) void {
        self.condition.broadcast(self.io);
    }

    fn queryBound(
        context: *anyopaque,
        text: []const u8,
        params: []const sql.Value,
        receiver: sql.RowReceiver,
    ) sql.QueryOutcome {
        const self: *Database = @ptrCast(@alignCast(context));
        return self.query(text, params, receiver);
    }

    fn mutateBound(
        context: *anyopaque,
        mutations: []const sql.Mutation,
    ) sql.MutationOutcome {
        const self: *Database = @ptrCast(@alignCast(context));
        return self.mutate(mutations);
    }

    fn maintainBound(context: *anyopaque, operation: sql.Maintenance) sql.QueryOutcome {
        const self: *Database = @ptrCast(@alignCast(context));
        return self.maintain(operation);
    }

    fn mutateChunksBound(context: *anyopaque, chunks: []const []const sql.Mutation) sql.MutationOutcome {
        const self: *Database = @ptrCast(@alignCast(context));
        return self.mutateChunks(chunks);
    }
};

const RowContext = struct {
    statement: *c.sqlite3_stmt,
    column_count: usize,

    fn row(self: *RowContext) sql.Row {
        return .{
            .context = self,
            .column_count = self.column_count,
            .column_name_fn = name,
            .value_fn = value,
        };
    }

    fn name(context: *anyopaque, index: usize) []const u8 {
        const self: *RowContext = @ptrCast(@alignCast(context));
        return columnName(self.statement, index);
    }

    fn value(context: *anyopaque, index: usize) sql.Value {
        const self: *RowContext = @ptrCast(@alignCast(context));
        return columnValue(self.statement, index);
    }
};

fn executeMutation(
    connection: *Connection,
    statement: *c.sqlite3_stmt,
    params: []const sql.Value,
    expectation: sql.ChangeExpectation,
) ?sql.MutationOutcome {
    if (c.sqlite3_stmt_readonly(statement) != 0 or
        c.sqlite3_column_count(statement) != 0 or
        parameterCount(statement) != params.len)
        return .rejected;
    bindAll(statement, params) catch |err| return mutationFailure(err);
    const result = c.sqlite3_step(statement);
    if (result != c.SQLITE_DONE)
        return if (result == c.SQLITE_ROW) .rejected else mutationFailure(sqlFailure(result));
    const changes: u64 = @intCast(c.sqlite3_changes64(connection.handle));
    switch (expectation) {
        .any => {},
        .exactly => |expected| if (changes != expected) return .conflict,
    }
    return null;
}

fn queryFailure(err: SqlError) sql.QueryOutcome {
    return switch (err) {
        error.Busy => .busy,
        error.Cancelled => .cancelled,
        error.Corrupt => .corrupt,
        error.OutOfMemory, error.TooBig, error.StorageFull, error.ResourceExhausted => .resource_exhausted,
        error.IoFailed => .definite_io_failure,
        error.Constraint, error.Rejected => .rejected,
    };
}

fn mutationFailure(err: SqlError) sql.MutationOutcome {
    return switch (err) {
        error.Constraint => .constraint,
        error.Busy => .busy,
        error.Cancelled => .cancelled,
        error.Corrupt => .corrupt,
        error.OutOfMemory, error.TooBig, error.StorageFull, error.ResourceExhausted => .resource_exhausted,
        error.IoFailed => .definite_io_failure,
        error.Rejected => .rejected,
    };
}

const test_migrations = [_]sql.Migration{.{
    .version = 1,
    .name = "create storage conformance table",
    .sql =
    \\CREATE TABLE storage_conformance(
    \\  id INTEGER PRIMARY KEY,
    \\  integer_value INTEGER,
    \\  real_value REAL,
    \\  text_value TEXT,
    \\  blob_value BLOB,
    \\  nullable TEXT
    \\);
    ,
}};

const IntegerObservation = struct {
    value: i64 = -1,
    rows: usize = 0,

    fn receive(context: *anyopaque, row: sql.Row) void {
        const self: *IntegerObservation = @ptrCast(@alignCast(context));
        self.value = row.value(0).integer;
        self.rows += 1;
    }

    fn receiver(self: *IntegerObservation) sql.RowReceiver {
        return .{ .context = self, .receive_fn = receive };
    }
};

const BlockingReceiver = struct {
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    entered: bool = false,
    released: bool = false,

    fn receive(context: *anyopaque, _: sql.Row) void {
        const self: *BlockingReceiver = @ptrCast(@alignCast(context));
        self.lock();
        self.entered = true;
        self.condition.broadcast(std.testing.io);
        while (!self.released)
            self.condition.waitUncancelable(std.testing.io, &self.mutex);
        self.mutex.unlock(std.testing.io);
    }

    fn waitUntilEntered(self: *BlockingReceiver) void {
        self.lock();
        while (!self.entered)
            self.condition.waitUncancelable(std.testing.io, &self.mutex);
        self.mutex.unlock(std.testing.io);
    }

    fn release(self: *BlockingReceiver) void {
        self.lock();
        self.released = true;
        self.condition.broadcast(std.testing.io);
        self.mutex.unlock(std.testing.io);
    }

    fn receiver(self: *BlockingReceiver) sql.RowReceiver {
        return .{ .context = self, .receive_fn = receive };
    }

    fn lock(self: *BlockingReceiver) void {
        self.mutex.lockUncancelable(std.testing.io);
    }
};

fn ignoreRow(_: *anyopaque, _: sql.Row) void {}

test "memory database has a stable owner and passes backend conformance" {
    const database = try Database.create(
        std.testing.io,
        std.testing.allocator,
        .memory,
        &test_migrations,
    );
    defer database.destroy() catch unreachable;
    try std.testing.expectEqual(@as(u32, 1), database.schemaVersion());
    try conformance.expectBackendContract(database.capability());
}

test "query and mutation authorities reject transaction and schema escape" {
    const database = try Database.create(
        std.testing.io,
        std.testing.allocator,
        .memory,
        &test_migrations,
    );
    defer database.destroy() catch unreachable;
    const capability = database.capability();
    const ignored: sql.RowReceiver = .{ .context = database, .receive_fn = ignoreRow };

    const alter = "ALTER TABLE storage_conformance ALTER COLUMN text_value SET NOT NULL";
    try std.testing.expectEqual(sql.QueryOutcome.rejected, capability.query(alter, &.{}, ignored));
    try std.testing.expectEqual(sql.MutationOutcome.rejected, capability.mutate(&.{.{ .statement = .{ .sql = alter } }}));

    try std.testing.expectEqual(
        sql.QueryOutcome.rejected,
        capability.query("BEGIN", &.{}, ignored),
    );
    try std.testing.expectEqual(
        sql.QueryOutcome.rejected,
        capability.query("SAVEPOINT escaped", &.{}, ignored),
    );
    try std.testing.expectEqual(
        sql.MutationOutcome.rejected,
        capability.mutate(&.{.{ .statement = .{ .sql = "CREATE TABLE escaped(id INTEGER)" } }}),
    );
    try std.testing.expectEqual(
        sql.MutationOutcome.rejected,
        capability.mutate(&.{.{ .statement = .{
            .sql = "INSERT INTO storage_conformance(id) VALUES(7) RETURNING id",
        } }}),
    );
    try std.testing.expectEqual(
        sql.QueryOutcome.rejected,
        capability.query("PRAGMA foreign_keys", &.{}, ignored),
    );
    try std.testing.expectEqual(
        sql.QueryOutcome.rejected,
        capability.query(
            "SELECT version FROM _metawork_storage_migrations",
            &.{},
            ignored,
        ),
    );

    try std.testing.expectEqual(
        sql.MutationOutcome.committed,
        capability.mutate(&.{.{
            .statement = .{ .sql = "INSERT INTO storage_conformance(id) VALUES(8)" },
            .expected_changes = .{ .exactly = 1 },
        }}),
    );
}

test "exact change conflict rolls the complete mutation batch back" {
    const database = try Database.create(
        std.testing.io,
        std.testing.allocator,
        .memory,
        &test_migrations,
    );
    defer database.destroy() catch unreachable;
    const capability = database.capability();
    try std.testing.expectEqual(
        sql.MutationOutcome.conflict,
        capability.mutate(&.{
            .{
                .statement = .{ .sql = "INSERT INTO storage_conformance(id) VALUES(21)" },
                .expected_changes = .{ .exactly = 1 },
            },
            .{
                .statement = .{ .sql = "UPDATE storage_conformance SET text_value='x' WHERE id=999" },
                .expected_changes = .{ .exactly = 1 },
            },
        }),
    );
    var count: IntegerObservation = .{};
    try std.testing.expectEqual(
        sql.QueryOutcome.ok,
        capability.query(
            "SELECT COUNT(*) FROM storage_conformance WHERE id=21",
            &.{},
            count.receiver(),
        ),
    );
    try std.testing.expectEqual(@as(i64, 0), count.value);
}

test "chunked mutation exceeds batch count atomically and rolls back a later conflict" {
    const database = try Database.create(std.testing.io, std.testing.allocator, .memory, &test_migrations);
    defer database.destroy() catch unreachable;
    const capability = database.capability();
    var values: [129][1]sql.Value = undefined;
    var mutations: [129]sql.Mutation = undefined;
    for (&mutations, 0..) |*mutation, i| {
        values[i] = .{.{ .integer = @intCast(i + 1) }};
        mutation.* = .{ .statement = .{ .sql = "INSERT INTO storage_conformance(id) VALUES(?)", .params = &values[i] } };
    }
    try std.testing.expectEqual(sql.MutationOutcome.rejected, capability.mutate(&mutations));
    try std.testing.expectEqual(sql.MutationOutcome.committed, capability.mutateChunks(&.{ mutations[0..128], mutations[128..] }));
    var count: IntegerObservation = .{};
    try std.testing.expectEqual(sql.QueryOutcome.ok, capability.query("SELECT COUNT(*) FROM storage_conformance", &.{}, count.receiver()));
    try std.testing.expectEqual(@as(i64, 129), count.value);
    const first = [_]sql.Mutation{.{ .statement = .{ .sql = "INSERT INTO storage_conformance(id) VALUES(1000)" } }};
    const last = [_]sql.Mutation{.{ .statement = .{ .sql = "UPDATE storage_conformance SET text_value='x' WHERE id=999" }, .expected_changes = .{ .exactly = 1 } }};
    try std.testing.expectEqual(sql.MutationOutcome.conflict, capability.mutateChunks(&.{ &first, &last }));
    count = .{};
    try std.testing.expectEqual(sql.QueryOutcome.ok, capability.query("SELECT COUNT(*) FROM storage_conformance WHERE id=1000", &.{}, count.receiver()));
    try std.testing.expectEqual(@as(i64, 0), count.value);
    try std.testing.expectEqual(sql.MutationOutcome.rejected, capability.mutateChunks(&.{ &first, &.{} }));
    count = .{};
    try std.testing.expectEqual(sql.QueryOutcome.ok, capability.query("SELECT COUNT(*) FROM storage_conformance WHERE id=1000", &.{}, count.receiver()));
    try std.testing.expectEqual(@as(i64, 0), count.value);
}

test "automatic rollback preserves constraint outcome data and reuse after reopen" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = try temporary.dir.realPath(std.testing.io, &path_buffer);
    const path = try std.fs.path.join(std.testing.allocator, &.{ path_buffer[0..length], "auto-rollback.db" });
    defer std.testing.allocator.free(path);
    {
        const database = try Database.create(std.testing.io, std.testing.allocator, .{ .file = path }, &test_migrations);
        defer database.destroy() catch unreachable;
        const capability = database.capability();
        try std.testing.expectEqual(sql.MutationOutcome.committed, capability.mutate(&.{.{ .statement = .{ .sql = "INSERT INTO storage_conformance(id) VALUES(1)" } }}));
        try std.testing.expectEqual(sql.MutationOutcome.constraint, capability.mutate(&.{
            .{ .statement = .{ .sql = "INSERT INTO storage_conformance(id) VALUES(2)" } },
            .{ .statement = .{ .sql = "INSERT OR ROLLBACK INTO storage_conformance(id) VALUES(1)" } },
        }));
        try std.testing.expectEqual(sql.MutationOutcome.committed, capability.mutate(&.{.{ .statement = .{ .sql = "INSERT INTO storage_conformance(id) VALUES(3)" } }}));
    }
    const reopened = try Database.create(std.testing.io, std.testing.allocator, .{ .file = path }, &test_migrations);
    defer reopened.destroy() catch unreachable;
    var count: IntegerObservation = .{};
    try std.testing.expectEqual(sql.QueryOutcome.ok, reopened.capability().query("SELECT count(*) FROM storage_conformance WHERE id IN (1,3)", &.{}, count.receiver()));
    try std.testing.expectEqual(@as(i64, 2), count.value);
    try std.testing.expectEqual(sql.QueryOutcome.ok, reopened.capability().query("SELECT count(*) FROM storage_conformance WHERE id=2", &.{}, count.receiver()));
    try std.testing.expectEqual(@as(i64, 0), count.value);
}

test "real write interrupt automatically rolls back without poisoning" {
    const database = try Database.create(std.testing.io, std.testing.allocator, .memory, &test_migrations);
    defer database.destroy() catch unreachable;
    var blocker: BlockingReceiver = .{};
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_create_function_v2(database.connection.handle, "pause_write", 1, c.SQLITE_UTF8, &blocker, struct {
        fn run(context: ?*c.sqlite3_context, _: c_int, args: [*c]?*c.sqlite3_value) callconv(.c) void {
            const state = c.sqlite3_user_data(context).?;
            BlockingReceiver.receive(state, undefined);
            c.sqlite3_result_int64(context, c.sqlite3_value_int64(args[0]));
        }
    }.run, null, null, null));
    var outcome: sql.MutationOutcome = .committed;
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(capability: sql.Database, output: *sql.MutationOutcome) void {
            output.* = capability.mutate(&.{.{ .statement = .{ .sql =
                \\WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<100000)
                \\INSERT INTO storage_conformance(id) SELECT pause_write(x) FROM n
            } }});
        }
    }.run, .{ database.capability(), &outcome });
    blocker.waitUntilEntered();
    database.interrupt();
    blocker.release();
    thread.join();
    try std.testing.expectEqual(sql.MutationOutcome.cancelled, outcome);
    var count: IntegerObservation = .{};
    try std.testing.expectEqual(sql.QueryOutcome.ok, database.capability().query("SELECT count(*) FROM storage_conformance", &.{}, count.receiver()));
    try std.testing.expectEqual(@as(i64, 0), count.value);
    try std.testing.expectEqual(sql.MutationOutcome.committed, database.capability().mutate(&.{.{ .statement = .{ .sql = "INSERT INTO storage_conformance(id) VALUES(7)" } }}));
}

test "deferred foreign key failure at COMMIT is definite and reusable" {
    const migrations = [_]sql.Migration{.{ .version = 1, .name = "deferred FK", .sql =
        \\CREATE TABLE parents(id INTEGER PRIMARY KEY);
        \\CREATE TABLE children(parent INTEGER REFERENCES parents(id) DEFERRABLE INITIALLY DEFERRED);
    }};
    const database = try Database.create(std.testing.io, std.testing.allocator, .memory, &migrations);
    defer database.destroy() catch unreachable;
    try std.testing.expectEqual(sql.MutationOutcome.constraint, database.capability().mutate(&.{.{ .statement = .{ .sql = "INSERT INTO children VALUES(1)" } }}));
    var count: IntegerObservation = .{};
    try std.testing.expectEqual(sql.QueryOutcome.ok, database.capability().query("SELECT count(*) FROM children", &.{}, count.receiver()));
    try std.testing.expectEqual(@as(i64, 0), count.value);
    try std.testing.expectEqual(sql.MutationOutcome.committed, database.capability().mutate(&.{
        .{ .statement = .{ .sql = "INSERT INTO parents VALUES(1)" } },
        .{ .statement = .{ .sql = "INSERT INTO children VALUES(1)" } },
    }));
}

test "failure before commit is definite and leaves the instance usable" {
    const database = try Database.create(
        std.testing.io,
        std.testing.allocator,
        .memory,
        &test_migrations,
    );
    defer database.destroy() catch unreachable;
    database.test_hooks.fail_before_commit = true;
    try std.testing.expectEqual(
        sql.MutationOutcome.definite_io_failure,
        database.capability().mutate(&.{.{
            .statement = .{ .sql = "INSERT INTO storage_conformance(id) VALUES(41)" },
            .expected_changes = .{ .exactly = 1 },
        }}),
    );
    var count: IntegerObservation = .{};
    try std.testing.expectEqual(
        sql.QueryOutcome.ok,
        database.capability().query(
            "SELECT COUNT(*) FROM storage_conformance WHERE id=41",
            &.{},
            count.receiver(),
        ),
    );
    try std.testing.expectEqual(@as(i64, 0), count.value);
    try std.testing.expectEqual(
        sql.MutationOutcome.committed,
        database.capability().mutate(&.{.{
            .statement = .{ .sql = "INSERT INTO storage_conformance(id) VALUES(41)" },
        }}),
    );
}

test "lost acknowledgement after commit returns unknown and poisons" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var directory_storage: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temporary.dir.realPath(std.testing.io, &directory_storage);
    const path = try std.fs.path.join(
        std.testing.allocator,
        &.{ directory_storage[0..directory_len], "unknown.db" },
    );
    defer std.testing.allocator.free(path);
    {
        const database = try Database.create(
            std.testing.io,
            std.testing.allocator,
            .{ .file = path },
            &test_migrations,
        );
        database.test_hooks.lose_ack_after_commit = true;
        try std.testing.expectEqual(
            sql.MutationOutcome.outcome_unknown,
            database.capability().mutate(&.{.{
                .statement = .{ .sql = "INSERT INTO storage_conformance(id) VALUES(42)" },
            }}),
        );
        try std.testing.expectEqual(
            sql.MutationOutcome.unavailable,
            database.capability().mutate(&.{.{
                .statement = .{ .sql = "DELETE FROM storage_conformance WHERE id=42" },
            }}),
        );
        try database.destroy();
    }
    {
        const database = try Database.create(
            std.testing.io,
            std.testing.allocator,
            .{ .file = path },
            &test_migrations,
        );
        defer database.destroy() catch unreachable;
        var count: IntegerObservation = .{};
        try std.testing.expectEqual(
            sql.QueryOutcome.ok,
            database.capability().query(
                "SELECT COUNT(*) FROM storage_conformance WHERE id=42",
                &.{},
                count.receiver(),
            ),
        );
        try std.testing.expectEqual(@as(i64, 1), count.value);
    }
}

test "cleanup failures poison without changing known transaction outcomes" {
    {
        const database = try Database.create(
            std.testing.io,
            std.testing.allocator,
            .memory,
            &test_migrations,
        );
        database.test_hooks.fail_rollback = true;
        try std.testing.expectEqual(
            sql.MutationOutcome.outcome_unknown,
            database.capability().mutate(&.{.{
                .statement = .{ .sql = "SELECT 1" },
            }}),
        );
        try std.testing.expectEqual(
            sql.QueryOutcome.unavailable,
            database.capability().query(
                "SELECT 1",
                &.{},
                .{ .context = database, .receive_fn = ignoreRow },
            ),
        );
        try database.destroy();
    }
    {
        const database = try Database.create(
            std.testing.io,
            std.testing.allocator,
            .memory,
            &test_migrations,
        );
        database.test_hooks.fail_authorizer_restore = true;
        try std.testing.expectEqual(
            sql.MutationOutcome.committed,
            database.capability().mutate(&.{.{
                .statement = .{ .sql = "INSERT INTO storage_conformance(id) VALUES(43)" },
            }}),
        );
        try std.testing.expectEqual(
            sql.MutationOutcome.unavailable,
            database.capability().mutate(&.{.{
                .statement = .{ .sql = "DELETE FROM storage_conformance WHERE id=43" },
            }}),
        );
        try database.connection.setAuthorizer(null);
        try expectIntegerPragma(&database.connection, "SELECT count(*) FROM storage_conformance WHERE id=43", 1);
        try database.destroy();
    }
    {
        const database = try Database.create(std.testing.io, std.testing.allocator, .memory, &test_migrations);
        defer database.destroy() catch unreachable;
        database.test_hooks.fail_before_commit = true;
        database.test_hooks.fail_authorizer_restore = true;
        try std.testing.expectEqual(sql.MutationOutcome.definite_io_failure, database.capability().mutate(&.{.{ .statement = .{ .sql = "INSERT INTO storage_conformance(id) VALUES(44)" } }}));
        try std.testing.expectEqual(sql.MutationOutcome.unavailable, database.capability().mutate(&.{.{ .statement = .{ .sql = "INSERT INTO storage_conformance(id) VALUES(45)" } }}));
        try database.connection.setAuthorizer(null);
        try expectIntegerPragma(&database.connection, "SELECT count(*) FROM storage_conformance", 0);
    }
}

test "migration identity is an append-only checksummed prefix" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var directory_storage: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temporary.dir.realPath(std.testing.io, &directory_storage);
    const path = try std.fs.path.join(
        std.testing.allocator,
        &.{ directory_storage[0..directory_len], "identity.db" },
    );
    defer std.testing.allocator.free(path);

    {
        const database = try Database.create(
            std.testing.io,
            std.testing.allocator,
            .{ .file = path },
            &test_migrations,
        );
        try database.destroy();
    }
    {
        const database = try Database.create(
            std.testing.io,
            std.testing.allocator,
            .{ .file = path },
            &test_migrations,
        );
        try database.destroy();
    }
    const changed_name = [_]sql.Migration{.{
        .version = 1,
        .name = "same version but changed identity",
        .sql = test_migrations[0].sql,
    }};
    try std.testing.expectError(
        error.MigrationMismatch,
        Database.create(
            std.testing.io,
            std.testing.allocator,
            .{ .file = path },
            &changed_name,
        ),
    );
    const changed_sql = [_]sql.Migration{.{
        .version = 1,
        .name = test_migrations[0].name,
        .sql = test_migrations[0].sql ++ " -- changed",
    }};
    try std.testing.expectError(
        error.MigrationMismatch,
        Database.create(
            std.testing.io,
            std.testing.allocator,
            .{ .file = path },
            &changed_sql,
        ),
    );
    try std.testing.expectError(
        error.VersionUnknown,
        Database.create(
            std.testing.io,
            std.testing.allocator,
            .{ .file = path },
            &.{},
        ),
    );
}

test "migration authority rejects metadata through associated schema objects" {
    const forbidden = [_][]const u8{
        "CREATE TRIGGER suppress_identity BEFORE INSERT ON _metawork_storage_migrations BEGIN SELECT RAISE(IGNORE); END;",
        "CREATE INDEX identity_index ON _metawork_storage_migrations(name);",
        "ALTER TABLE _metawork_storage_migrations ADD COLUMN injected TEXT;",
        "ALTER TABLE _metawork_storage_migrations ALTER COLUMN name DROP NOT NULL;",
        "CREATE VIEW identity_view AS SELECT * FROM _metawork_storage_migrations; SELECT * FROM identity_view;",
    };
    for (forbidden) |text| {
        const migrations = [_]sql.Migration{.{ .version = 1, .name = "escape", .sql = text }};
        const result = Database.create(std.testing.io, std.testing.allocator, .memory, &migrations);
        if (result) |database| {
            try database.destroy();
            return error.MetadataEscapeAccepted;
        } else |err| try std.testing.expectEqual(error.MigrationFailed, err);
    }
}

test "migration permits application DDL and persists exact identity after reopen" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = try temporary.dir.realPath(std.testing.io, &path_buffer);
    const path = try std.fs.path.join(std.testing.allocator, &.{ path_buffer[0..length], "ddl.db" });
    defer std.testing.allocator.free(path);
    const migrations = [_]sql.Migration{
        .{ .version = 1, .name = "create", .sql = "CREATE TABLE items(id INTEGER PRIMARY KEY); CREATE TABLE audit(id INTEGER);" },
        .{ .version = 2, .name = "evolve", .sql =
        \\ALTER TABLE items ADD COLUMN label TEXT;
        \\CREATE INDEX item_label ON items(label);
        \\CREATE TRIGGER item_audit AFTER INSERT ON items BEGIN INSERT INTO audit VALUES(new.id); END;
        \\CREATE VIEW item_view AS SELECT id FROM items;
        \\INSERT INTO items VALUES(7, 'seven');
        },
    };
    for (0..2) |_| {
        const database = try Database.create(std.testing.io, std.testing.allocator, .{ .file = path }, &migrations);
        defer database.destroy() catch unreachable;
        try std.testing.expectEqual(@as(u32, 2), database.schemaVersion());
        var observed: IntegerObservation = .{};
        try std.testing.expectEqual(sql.QueryOutcome.ok, database.capability().query("SELECT id FROM audit", &.{}, observed.receiver()));
        try std.testing.expectEqual(@as(i64, 7), observed.value);
        try database.connection.setAuthorizer(null); // Test-only observation, not metadata authority.
        try expectIntegerPragma(&database.connection, "SELECT count(*) FROM _metawork_storage_migrations", 2);
    }
}

test "migration SET NOT NULL persists and rejects NULL after reopen" {
    try expectMigratedNullConstraint("TEXT", "SET NOT NULL", .constraint);
}

test "migration DROP NOT NULL persists and accepts NULL after reopen" {
    try expectMigratedNullConstraint("TEXT NOT NULL", "DROP NOT NULL", .committed);
}

fn expectMigratedNullConstraint(column_type: []const u8, alteration: []const u8, expected: sql.MutationOutcome) !void {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = try temporary.dir.realPath(std.testing.io, &path_buffer);
    const path = try std.fs.path.join(std.testing.allocator, &.{ path_buffer[0..length], "not-null.db" });
    defer std.testing.allocator.free(path);
    const initial_sql = try std.fmt.allocPrint(std.testing.allocator, "CREATE TABLE items(label {s}); INSERT INTO items VALUES('original');", .{column_type});
    defer std.testing.allocator.free(initial_sql);
    const alter_sql = try std.fmt.allocPrint(std.testing.allocator, "ALTER TABLE items ALTER COLUMN label {s};", .{alteration});
    defer std.testing.allocator.free(alter_sql);
    const migrations = [_]sql.Migration{
        .{ .version = 1, .name = "create", .sql = initial_sql },
        .{ .version = 2, .name = "alter constraint", .sql = alter_sql },
    };
    const migrated = try Database.create(std.testing.io, std.testing.allocator, .{ .file = path }, &migrations);
    try migrated.destroy();
    const reopened = try Database.create(std.testing.io, std.testing.allocator, .{ .file = path }, &migrations);
    defer reopened.destroy() catch unreachable;
    try std.testing.expectEqual(@as(u32, 2), reopened.schemaVersion());
    try std.testing.expectEqual(expected, reopened.capability().mutate(&.{.{ .statement = .{ .sql = "INSERT INTO items VALUES(NULL)" } }}));
    var observed: IntegerObservation = .{};
    try std.testing.expectEqual(sql.QueryOutcome.ok, reopened.capability().query("SELECT count(*) FROM items WHERE label='original'", &.{}, observed.receiver()));
    try std.testing.expectEqual(@as(i64, 1), observed.value);
    try std.testing.expectEqual(sql.QueryOutcome.ok, reopened.capability().query("SELECT count(*) FROM items WHERE label IS NULL", &.{}, observed.receiver()));
    try std.testing.expectEqual(@as(i64, if (expected == .committed) 1 else 0), observed.value);
}

test "SET NOT NULL with existing NULL rolls back all pending migrations" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = try temporary.dir.realPath(std.testing.io, &path_buffer);
    const path = try std.fs.path.join(std.testing.allocator, &.{ path_buffer[0..length], "null-rollback.db" });
    defer std.testing.allocator.free(path);
    const migrations = [_]sql.Migration{
        .{ .version = 1, .name = "create", .sql = "CREATE TABLE items(label TEXT); INSERT INTO items VALUES(NULL),('original');" },
        .{ .version = 2, .name = "pending changes", .sql = "CREATE TABLE must_rollback(id INTEGER); INSERT INTO items VALUES('pending');" },
        .{ .version = 3, .name = "invalid constraint", .sql = "ALTER TABLE items ALTER COLUMN label SET NOT NULL;" },
    };
    const initial = try Database.create(std.testing.io, std.testing.allocator, .{ .file = path }, migrations[0..1]);
    try initial.destroy();
    try std.testing.expectError(error.MigrationFailed, Database.create(std.testing.io, std.testing.allocator, .{ .file = path }, &migrations));
    // Opening the original prefix also verifies that no pending identity survived.
    const reopened = try Database.create(std.testing.io, std.testing.allocator, .{ .file = path }, migrations[0..1]);
    defer reopened.destroy() catch unreachable;
    try std.testing.expectEqual(@as(u32, 1), reopened.schemaVersion());
    var observed: IntegerObservation = .{};
    try std.testing.expectEqual(sql.QueryOutcome.rejected, reopened.capability().query("SELECT id FROM must_rollback", &.{}, observed.receiver()));
    try std.testing.expectEqual(sql.QueryOutcome.ok, reopened.capability().query("SELECT count(*) FROM items", &.{}, observed.receiver()));
    try std.testing.expectEqual(@as(i64, 2), observed.value);
    try std.testing.expectEqual(sql.QueryOutcome.ok, reopened.capability().query("SELECT count(*) FROM items WHERE label='original' OR label IS NULL", &.{}, observed.receiver()));
    try std.testing.expectEqual(@as(i64, 2), observed.value);
    try std.testing.expectEqual(sql.MutationOutcome.committed, reopened.capability().mutate(&.{.{ .statement = .{ .sql = "INSERT INTO items VALUES(NULL)" } }}));
}

test "oversized migration data is a migration failure and rolls back the pending prefix" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = try temporary.dir.realPath(std.testing.io, &path_buffer);
    const path = try std.fs.path.join(std.testing.allocator, &.{ path_buffer[0..length], "too-big.db" });
    defer std.testing.allocator.free(path);
    const migrations = [_]sql.Migration{
        .{ .version = 1, .name = "create", .sql = "CREATE TABLE items(id INTEGER PRIMARY KEY, payload BLOB); INSERT INTO items VALUES(1,X'1234');" },
        .{ .version = 2, .name = "pending changes", .sql = "CREATE TABLE must_rollback(id INTEGER); INSERT INTO items VALUES(2,X'abcd');" },
        .{ .version = 3, .name = "oversized value", .sql = std.fmt.comptimePrint("INSERT INTO items VALUES(3,zeroblob({d}));", .{sql.Limits.result_bytes + 1}) },
    };
    const initial = try Database.create(std.testing.io, std.testing.allocator, .{ .file = path }, migrations[0..1]);
    try initial.destroy();
    try std.testing.expectError(error.MigrationFailed, Database.create(std.testing.io, std.testing.allocator, .{ .file = path }, &migrations));
    const reopened = try Database.create(std.testing.io, std.testing.allocator, .{ .file = path }, migrations[0..1]);
    defer reopened.destroy() catch unreachable;
    try std.testing.expectEqual(@as(u32, 1), reopened.schemaVersion());
    var observed: IntegerObservation = .{};
    try std.testing.expectEqual(sql.QueryOutcome.rejected, reopened.capability().query("SELECT id FROM must_rollback", &.{}, observed.receiver()));
    try std.testing.expectEqual(sql.QueryOutcome.ok, reopened.capability().query("SELECT count(*) FROM items", &.{}, observed.receiver()));
    try std.testing.expectEqual(@as(i64, 1), observed.value);
    try std.testing.expectEqual(sql.QueryOutcome.ok, reopened.capability().query("SELECT count(*) FROM items WHERE id=1 AND payload=X'1234'", &.{}, observed.receiver()));
    try std.testing.expectEqual(@as(i64, 1), observed.value);
    try std.testing.expectEqual(sql.MutationOutcome.committed, reopened.capability().mutate(&.{.{ .statement = .{ .sql = "INSERT INTO items VALUES(2,NULL)" } }}));
}

test "page capacity exhaustion is StorageFull and rolls back the pending prefix" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = try temporary.dir.realPath(std.testing.io, &path_buffer);
    const path = try std.fs.path.join(std.testing.allocator, &.{ path_buffer[0..length], "full.db" });
    defer std.testing.allocator.free(path);
    const terminated_path = try std.testing.allocator.dupeZ(u8, path);
    defer std.testing.allocator.free(terminated_path);
    var connection = try Connection.open(terminated_path);
    defer connection.close();
    try initializeConnection(&connection, true);
    // Configure the fixture before any production authorizer is installed.
    // Sixteen pages leave room for the baseline and one complete pending
    // migration, while a value this large must exceed the remaining pages.
    try expectIntegerPragma(&connection, "PRAGMA max_page_count=16", 16);
    const page_size = size: {
        const statement = try prepareOne(&connection, "PRAGMA page_size");
        defer _ = c.sqlite3_finalize(statement);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(statement));
        const value = c.sqlite3_column_int64(statement, 0);
        try std.testing.expectEqual(c.SQLITE_DONE, c.sqlite3_step(statement));
        break :size value;
    };
    const blob_bytes = page_size * 16;
    try std.testing.expect(blob_bytes > 0 and blob_bytes + 64 < sql.Limits.result_bytes);
    const full_sql = try std.fmt.allocPrint(std.testing.allocator, "INSERT INTO items VALUES(3,zeroblob({d}));", .{blob_bytes});
    defer std.testing.allocator.free(full_sql);
    const migrations = [_]sql.Migration{
        .{ .version = 1, .name = "create", .sql = "CREATE TABLE items(id INTEGER PRIMARY KEY, payload BLOB); INSERT INTO items VALUES(1,X'1234');" },
        .{ .version = 2, .name = "pending changes", .sql = "CREATE TABLE must_rollback(id INTEGER); INSERT INTO items VALUES(2,X'abcd');" },
        .{ .version = 3, .name = "exceed page capacity", .sql = full_sql },
    };
    try std.testing.expect(sql.validMigrations(&migrations));
    try std.testing.expectEqual(@as(u32, 1), try applyMigrations(std.testing.allocator, &connection, migrations[0..1]));
    const result = applyMigrations(std.testing.allocator, &connection, &migrations);
    try std.testing.expectEqual(c.SQLITE_FULL, c.sqlite3_errcode(connection.handle));
    try std.testing.expectError(error.StorageFull, result);
    try std.testing.expect(c.sqlite3_get_autocommit(connection.handle) != 0);
    // SQLite counts even rolled-back changes: the data and identity inserts
    // of both the baseline and the first pending migration actually ran.
    try std.testing.expectEqual(@as(i64, 4), c.sqlite3_total_changes64(connection.handle));
    try std.testing.expectEqual(@as(u32, 1), try applyMigrations(std.testing.allocator, &connection, migrations[0..1]));
    try connection.setAuthorizer(backend.metadataAuthorizer);
    try expectIntegerPragma(&connection, "SELECT version FROM _metawork_storage_migrations", 1);
    try connection.setAuthorizer(backend.migrationAuthorizer);
    try expectIntegerPragma(&connection, "SELECT count(*) FROM sqlite_schema WHERE name='must_rollback'", 0);
    try expectIntegerPragma(&connection, "SELECT count(*) FROM items", 1);
    try expectIntegerPragma(&connection, "SELECT count(*) FROM items WHERE id=1 AND payload=X'1234'", 1);
    try connection.execRaw("INSERT INTO items VALUES(2,NULL)");
    try expectIntegerPragma(&connection, "SELECT count(*) FROM items", 2);
}

test "resource errors retain their causes and preserve ordinary operation outcomes" {
    const cases = [_]struct { code: c_int, cause: anyerror, initialization: anyerror }{
        .{ .code = c.SQLITE_NOMEM, .cause = error.OutOfMemory, .initialization = error.OutOfMemory },
        .{ .code = c.SQLITE_TOOBIG, .cause = error.TooBig, .initialization = error.ProfileMismatch },
        .{ .code = c.SQLITE_FULL, .cause = error.StorageFull, .initialization = error.StorageFull },
    };
    for (cases) |case| {
        const cause = sqlFailure(case.code);
        try std.testing.expectEqual(case.cause, cause);
        try std.testing.expectEqual(case.initialization, initializeFailure(cause));
        try std.testing.expectEqual(sql.QueryOutcome.resource_exhausted, queryFailure(cause));
        try std.testing.expectEqual(sql.MutationOutcome.resource_exhausted, mutationFailure(cause));
    }
    try std.testing.expectEqual(sql.QueryOutcome.resource_exhausted, queryFailure(error.ResourceExhausted));
    try std.testing.expectEqual(sql.MutationOutcome.resource_exhausted, mutationFailure(error.ResourceExhausted));
    try std.testing.expectEqual(@as(anyerror, error.ProfileMismatch), initializeFailure(error.ResourceExhausted));
}

test "metadata authority cannot alter application tables" {
    var connection = try Connection.open(":memory:");
    defer connection.close();
    try initializeConnection(&connection, false);
    _ = try applyMigrations(std.testing.allocator, &connection, &test_migrations);
    try connection.setAuthorizer(backend.metadataAuthorizer);
    try std.testing.expectError(error.Rejected, connection.execRaw("ALTER TABLE storage_conformance ALTER COLUMN text_value SET NOT NULL"));
}

test "metadata authority rejects persisted trigger side effects" {
    var connection = try Connection.open(":memory:");
    defer connection.close();
    try initializeConnection(&connection, false);
    _ = try applyMigrations(std.testing.allocator, &connection, &.{});
    try connection.setAuthorizer(null);
    try connection.execRaw("CREATE TABLE illicit(id INTEGER); CREATE TRIGGER bad_identity BEFORE INSERT ON _metawork_storage_migrations BEGIN INSERT INTO illicit VALUES(1); SELECT RAISE(IGNORE); END;");
    try std.testing.expectError(error.MigrationFailed, applyMigrations(std.testing.allocator, &connection, &test_migrations));
    try connection.setAuthorizer(null);
    try expectIntegerPragma(&connection, "SELECT count(*) FROM illicit", 0);
    try expectIntegerPragma(&connection, "SELECT count(*) FROM _metawork_storage_migrations", 0);
    try expectIntegerPragma(&connection, "SELECT count(*) FROM sqlite_schema WHERE name='storage_conformance'", 0);
}

test "denied migration rolls back file schema and keeps its original identity" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = try temporary.dir.realPath(std.testing.io, &path_buffer);
    const path = try std.fs.path.join(std.testing.allocator, &.{ path_buffer[0..length], "denied.db" });
    defer std.testing.allocator.free(path);
    const initial = try Database.create(std.testing.io, std.testing.allocator, .{ .file = path }, &test_migrations);
    try initial.destroy();
    const extended = test_migrations ++ [_]sql.Migration{.{
        .version = 2,
        .name = "denied",
        .sql = "CREATE TABLE must_rollback(id INTEGER); CREATE INDEX stolen ON _metawork_storage_migrations(name);",
    }};
    try std.testing.expectError(error.MigrationFailed, Database.create(std.testing.io, std.testing.allocator, .{ .file = path }, &extended));
    const reopened = try Database.create(std.testing.io, std.testing.allocator, .{ .file = path }, &test_migrations);
    defer reopened.destroy() catch unreachable;
    try std.testing.expectEqual(@as(u32, 1), reopened.schemaVersion());
    try reopened.connection.setAuthorizer(null);
    try expectIntegerPragma(&reopened.connection, "SELECT count(*) FROM sqlite_schema WHERE name='must_rollback'", 0);
    try expectIntegerPragma(&reopened.connection, "SELECT count(*) FROM _metawork_storage_migrations", 1);
}

test "migration metadata rejects coerced identity types" {
    var connection = try Connection.open(":memory:");
    defer connection.close();
    try initializeConnection(&connection, false);
    _ = try applyMigrations(std.testing.allocator, &connection, &test_migrations);
    try connection.setAuthorizer(null);
    // Same name bytes, wrong persisted storage class: implicit conversion
    // must not hide malformed identity records.
    try connection.execRaw("UPDATE _metawork_storage_migrations SET name=CAST(name AS BLOB);");
    try std.testing.expectError(error.Corrupt, applyMigrations(std.testing.allocator, &connection, &test_migrations));
}

test "failed migrations roll back schema and identity together" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var directory_storage: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temporary.dir.realPath(std.testing.io, &directory_storage);
    const path = try std.fs.path.join(
        std.testing.allocator,
        &.{ directory_storage[0..directory_len], "rollback.db" },
    );
    defer std.testing.allocator.free(path);

    try std.testing.expectError(
        error.MigrationFailed,
        Database.create(std.testing.io, std.testing.allocator, .{ .file = path }, &.{
            .{ .version = 1, .name = "first", .sql = "CREATE TABLE first(id INTEGER);" },
            .{ .version = 2, .name = "broken", .sql = "THIS IS NOT SQL;" },
        }),
    );
    const recovered = [_]sql.Migration{.{
        .version = 1,
        .name = "first",
        .sql = "CREATE TABLE first(id INTEGER);",
    }};
    const database = try Database.create(
        std.testing.io,
        std.testing.allocator,
        .{ .file = path },
        &recovered,
    );
    defer database.destroy() catch unreachable;
    try std.testing.expectEqual(@as(u32, 1), database.schemaVersion());
}

test "migration handles automatic rollback and COMMIT constraint failure" {
    const failing = [_][]const u8{
        "CREATE TABLE partial(id INTEGER); INSERT INTO partial VALUES(1); INSERT OR ROLLBACK INTO storage_conformance(id) VALUES(1),(1);",
        "CREATE TABLE partial(id INTEGER REFERENCES storage_conformance(id) DEFERRABLE INITIALLY DEFERRED); INSERT INTO partial VALUES(99);",
    };
    for (failing) |text| {
        var connection = try Connection.open(":memory:");
        defer connection.close();
        try initializeConnection(&connection, false);
        _ = try applyMigrations(std.testing.allocator, &connection, &test_migrations);
        const migrations = test_migrations ++ [_]sql.Migration{.{ .version = 2, .name = "failing", .sql = text }};
        try std.testing.expectError(error.MigrationFailed, applyMigrations(std.testing.allocator, &connection, &migrations));
        try std.testing.expect(c.sqlite3_get_autocommit(connection.handle) != 0);
        try connection.setAuthorizer(null);
        try expectIntegerPragma(&connection, "SELECT count(*) FROM _metawork_storage_migrations", 1);
        try expectIntegerPragma(&connection, "SELECT count(*) FROM sqlite_schema WHERE name='partial'", 0);
        const valid = test_migrations ++ [_]sql.Migration{.{ .version = 2, .name = "valid", .sql = "CREATE TABLE partial(id INTEGER);" }};
        try std.testing.expectEqual(@as(u32, 2), try applyMigrations(std.testing.allocator, &connection, &valid));
    }
}

test "file profile is FULL WAL and every setting is verified" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var directory_storage: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temporary.dir.realPath(std.testing.io, &directory_storage);
    const path = try std.fs.path.join(
        std.testing.allocator,
        &.{ directory_storage[0..directory_len], "profile.db" },
    );
    defer std.testing.allocator.free(path);
    const database = try Database.create(
        std.testing.io,
        std.testing.allocator,
        .{ .file = path },
        &test_migrations,
    );
    defer database.destroy() catch unreachable;

    try database.connection.setAuthorizer(null);
    defer database.connection.setAuthorizer(denyAllAuthorizer) catch {};
    try expectTextPragma(&database.connection, "PRAGMA journal_mode", "wal");
    try expectIntegerPragma(&database.connection, "PRAGMA synchronous", 2);
    try expectIntegerPragma(&database.connection, "PRAGMA foreign_keys", 1);
    try expectIntegerPragma(&database.connection, "PRAGMA busy_timeout", 250);
    try expectIntegerPragma(&database.connection, "PRAGMA mmap_size", 0);
    try std.testing.expectEqual(
        @as(c_int, sql.Limits.parameters),
        c.sqlite3_limit(database.connection.handle, c.SQLITE_LIMIT_VARIABLE_NUMBER, -1),
    );
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.sqlite3_limit(database.connection.handle, c.SQLITE_LIMIT_ATTACHED, -1),
    );
    try expectDatabaseConfig(
        &database.connection,
        c.SQLITE_DBCONFIG_DEFENSIVE,
        1,
    );
    try expectDatabaseConfig(
        &database.connection,
        c.SQLITE_DBCONFIG_TRUSTED_SCHEMA,
        0,
    );
}

test "journal mode setter fails closed when SQLite returns another mode" {
    var connection = try Connection.open(":memory:");
    defer connection.close();
    try std.testing.expectError(
        error.ProfileMismatch,
        setTextPragma(&connection, "PRAGMA journal_mode=WAL;", "wal"),
    );
}

test "callback lifecycle reentry is rejected without changing the owner" {
    const database = try Database.create(std.testing.io, std.testing.allocator, .memory, &test_migrations);
    defer database.destroy() catch unreachable;
    const Observation = struct {
        database: *Database,
        shutdown_error: ?LifecycleError = null,
        destroy_error: ?LifecycleError = null,
        fn receive(context: *anyopaque, _: sql.Row) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.database.shutdown() catch |err| {
                self.shutdown_error = err;
            };
            self.database.destroy() catch |err| {
                self.destroy_error = err;
            };
        }
    };
    var observation: Observation = .{ .database = database };
    try std.testing.expectEqual(sql.QueryOutcome.ok, database.capability().query("SELECT 1", &.{}, .{ .context = &observation, .receive_fn = Observation.receive }));
    try std.testing.expectEqual(error.ReentrantOperation, observation.shutdown_error.?);
    try std.testing.expectEqual(error.ReentrantOperation, observation.destroy_error.?);
    try std.testing.expectEqual(sql.MutationOutcome.committed, database.capability().mutate(&.{.{ .statement = .{ .sql = "INSERT INTO storage_conformance(id) VALUES(1)" } }}));
}

fn shutdownForTest(database: *Database) void {
    database.shutdown() catch unreachable;
}

test "queued callers serialize normally and are released by shutdown" {
    for ([_]bool{ false, true }) |stop| {
        const database = try Database.create(std.testing.io, std.testing.allocator, .memory, &.{});
        defer database.destroy() catch unreachable;
        var blocker: BlockingReceiver = .{};
        var first_outcome: sql.QueryOutcome = .ok;
        const first = try std.Thread.spawn(.{}, struct {
            fn run(db: sql.Database, receiver: sql.RowReceiver, output: *sql.QueryOutcome) void {
                output.* = db.query("SELECT 1 UNION ALL SELECT 2", &.{}, receiver);
            }
        }.run, .{ database.capability(), blocker.receiver(), &first_outcome });
        blocker.waitUntilEntered();
        var second_outcome: sql.QueryOutcome = .ok;
        const second = try std.Thread.spawn(.{}, struct {
            fn run(db: *Database, output: *sql.QueryOutcome) void {
                output.* = db.capability().query("SELECT 3", &.{}, .{ .context = db, .receive_fn = ignoreRow });
            }
        }.run, .{ database, &second_outcome });
        database.lock();
        while (database.test_hooks.waiting_callers == 0) database.wait();
        database.unlock();
        if (stop) {
            const stopping = try std.Thread.spawn(.{}, shutdownForTest, .{database});
            const also_stopping = try std.Thread.spawn(.{}, shutdownForTest, .{database});
            // The queued call must finish while the active callback is still
            // blocked. shutdown must not wait for it to become an operator.
            second.join();
            blocker.release();
            first.join();
            stopping.join();
            also_stopping.join();
            try std.testing.expectEqual(sql.QueryOutcome.unavailable, second_outcome);
            try std.testing.expectEqual(Lifecycle.stopped, database.lifecycle);
        } else {
            blocker.release();
            first.join();
            second.join();
            try std.testing.expectEqual(sql.QueryOutcome.ok, first_outcome);
            try std.testing.expectEqual(sql.QueryOutcome.ok, second_outcome);
        }
    }
}

test "shutdown is idempotent and borrowed capability becomes unavailable" {
    const database = try Database.create(
        std.testing.io,
        std.testing.allocator,
        .memory,
        &test_migrations,
    );
    const capability = database.capability();
    try database.shutdown();
    try database.shutdown();
    var ignored: IntegerObservation = .{};
    try std.testing.expectEqual(
        sql.QueryOutcome.unavailable,
        capability.query("SELECT 1", &.{}, ignored.receiver()),
    );
    try std.testing.expectEqual(
        sql.MutationOutcome.unavailable,
        capability.mutate(&.{.{ .statement = .{ .sql = "DELETE FROM storage_conformance" } }}),
    );
    try database.destroy();
}

test "interrupt cancels the active query without poisoning the instance" {
    const database = try Database.create(
        std.testing.io,
        std.testing.allocator,
        .memory,
        &.{},
    );
    defer database.destroy() catch unreachable;
    var blocker: BlockingReceiver = .{};
    var outcome: sql.QueryOutcome = .ok;
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(
            capability: sql.Database,
            receiver: sql.RowReceiver,
            output: *sql.QueryOutcome,
        ) void {
            output.* = capability.query(
                \\WITH RECURSIVE values_(value) AS (
                \\  VALUES(1) UNION ALL SELECT value + 1 FROM values_ WHERE value < 100000
                \\) SELECT value FROM values_
            , &.{}, receiver);
        }
    }.run, .{ database.capability(), blocker.receiver(), &outcome });
    blocker.waitUntilEntered();
    database.interrupt();
    blocker.release();
    thread.join();
    try std.testing.expectEqual(sql.QueryOutcome.cancelled, outcome);

    var observed: IntegerObservation = .{};
    try std.testing.expectEqual(
        sql.QueryOutcome.ok,
        database.capability().query("SELECT 1", &.{}, observed.receiver()),
    );
    try std.testing.expectEqual(@as(i64, 1), observed.value);
}

test "shutdown interrupts an active callback and converges before close" {
    const database = try Database.create(
        std.testing.io,
        std.testing.allocator,
        .memory,
        &.{},
    );
    var blocker: BlockingReceiver = .{};
    var outcome: sql.QueryOutcome = .ok;
    const query_thread = try std.Thread.spawn(.{}, struct {
        fn run(
            capability: sql.Database,
            receiver: sql.RowReceiver,
            output: *sql.QueryOutcome,
        ) void {
            output.* = capability.query(
                \\WITH RECURSIVE values_(value) AS (
                \\  VALUES(1) UNION ALL SELECT value + 1 FROM values_ WHERE value < 100000
                \\) SELECT value FROM values_
            , &.{}, receiver);
        }
    }.run, .{ database.capability(), blocker.receiver(), &outcome });
    blocker.waitUntilEntered();
    const shutdown_thread = try std.Thread.spawn(.{}, shutdownForTest, .{database});

    database.lock();
    while (database.lifecycle != .stopping) database.wait();
    database.unlock();
    blocker.release();
    query_thread.join();
    shutdown_thread.join();
    try std.testing.expectEqual(sql.QueryOutcome.cancelled, outcome);
    try std.testing.expectEqual(Lifecycle.stopped, database.lifecycle);
    try database.destroy();
}

test "file contention is busy rather than local gate contention" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var directory_storage: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temporary.dir.realPath(std.testing.io, &directory_storage);
    const path = try std.fs.path.join(
        std.testing.allocator,
        &.{ directory_storage[0..directory_len], "busy.db" },
    );
    defer std.testing.allocator.free(path);
    const first = try Database.create(
        std.testing.io,
        std.testing.allocator,
        .{ .file = path },
        &test_migrations,
    );
    defer first.destroy() catch unreachable;
    const second = try Database.create(
        std.testing.io,
        std.testing.allocator,
        .{ .file = path },
        &test_migrations,
    );
    defer second.destroy() catch unreachable;

    try first.connection.setAuthorizer(internalTransactionAuthorizer);
    try first.connection.execRaw("BEGIN IMMEDIATE;");
    defer {
        first.connection.execRaw("ROLLBACK;") catch {};
        first.connection.setAuthorizer(denyAllAuthorizer) catch {};
    }
    try std.testing.expectEqual(
        sql.MutationOutcome.busy,
        second.capability().mutate(&.{.{
            .statement = .{ .sql = "INSERT INTO storage_conformance(id) VALUES(33)" },
        }}),
    );
}

test "abrupt child exit leaves a WAL that reopens with committed data" {
    const fixture = try std.process.Environ.getAlloc(
        std.testing.environ,
        std.testing.allocator,
        "METAWORK_STORAGE_CRASH_FIXTURE",
    );
    defer std.testing.allocator.free(fixture);
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var directory_storage: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temporary.dir.realPath(std.testing.io, &directory_storage);
    const path = try std.fs.path.join(
        std.testing.allocator,
        &.{ directory_storage[0..directory_len], "crash.db" },
    );
    defer std.testing.allocator.free(path);
    {
        const database = try Database.create(
            std.testing.io,
            std.testing.allocator,
            .{ .file = path },
            &test_migrations,
        );
        try database.destroy();
    }

    var environment = try std.process.Environ.createMap(
        std.testing.environ,
        std.testing.allocator,
    );
    defer environment.deinit();
    try environment.put("METAWORK_STORAGE_CRASH_DB", path);
    const arguments = [_][]const u8{fixture};
    var child = try std.process.spawn(std.testing.io, .{
        .argv = &arguments,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .inherit,
        .environ_map = &environment,
        .create_no_window = true,
    });
    const termination = try child.wait(std.testing.io);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 86 }, termination);

    const wal_path = try std.fmt.allocPrint(std.testing.allocator, "{s}-wal", .{path});
    defer std.testing.allocator.free(wal_path);
    const wal_stat = try std.Io.Dir.cwd().statFile(std.testing.io, wal_path, .{});
    try std.testing.expect(wal_stat.size > 0);

    const database = try Database.create(
        std.testing.io,
        std.testing.allocator,
        .{ .file = path },
        &test_migrations,
    );
    defer database.destroy() catch unreachable;
    var length: IntegerObservation = .{};
    try std.testing.expectEqual(
        sql.QueryOutcome.ok,
        database.capability().query(
            "SELECT length(blob_value) FROM storage_conformance WHERE id=77",
            &.{},
            length.receiver(),
        ),
    );
    try std.testing.expectEqual(@as(i64, 1048576), length.value);
}

test "corrupt files are not collapsed into path or empty-database outcomes" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var directory_storage: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temporary.dir.realPath(std.testing.io, &directory_storage);
    const path = try std.fs.path.join(
        std.testing.allocator,
        &.{ directory_storage[0..directory_len], "corrupt.db" },
    );
    defer std.testing.allocator.free(path);
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "corrupt.db",
        .data = "not a sqlite database",
    });
    try std.testing.expectError(
        error.Corrupt,
        Database.create(
            std.testing.io,
            std.testing.allocator,
            .{ .file = path },
            &test_migrations,
        ),
    );
}

test "streaming query exposes provisional rows before terminal failure" {
    const database = try Database.create(
        std.testing.io,
        std.testing.allocator,
        .memory,
        &.{},
    );
    defer database.destroy() catch unreachable;
    var observed: IntegerObservation = .{};
    try std.testing.expectEqual(
        sql.QueryOutcome.resource_exhausted,
        database.capability().query(
            \\WITH RECURSIVE values_(value) AS (
            \\  VALUES(1) UNION ALL SELECT value + 1 FROM values_ WHERE value < 8193
            \\) SELECT value FROM values_
        , &.{}, observed.receiver()),
    );
    try std.testing.expectEqual(sql.Limits.result_rows, observed.rows);
}

test "query observes the result shape after another instance migrates the file" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = try temporary.dir.realPath(std.testing.io, &path_buffer);
    const path = try std.fs.path.join(std.testing.allocator, &.{ path_buffer[0..length], "shape.db" });
    defer std.testing.allocator.free(path);
    const migrations = [_]sql.Migration{
        .{ .version = 1, .name = "create", .sql = "CREATE TABLE items(id INTEGER); INSERT INTO items VALUES(1),(2);" },
        .{ .version = 2, .name = "add label", .sql = "ALTER TABLE items ADD COLUMN label TEXT; UPDATE items SET label='new';" },
    };
    const first = try Database.create(std.testing.io, std.testing.allocator, .{ .file = path }, migrations[0..1]);
    defer first.destroy() catch unreachable;
    const second = try Database.create(std.testing.io, std.testing.allocator, .{ .file = path }, &migrations);
    defer second.destroy() catch unreachable;

    const Rows = struct {
        count: usize = 0,
        valid: bool = true,

        fn receive(context: *anyopaque, row: sql.Row) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.count += 1;
            if (row.columnCount() != 2) {
                self.valid = false;
                return;
            }
            self.valid = self.valid and
                std.mem.eql(u8, row.columnName(0), "id") and
                std.mem.eql(u8, row.columnName(1), "label") and
                row.value(0) == .integer and row.value(0).integer == self.count and
                row.value(1) == .text and std.mem.eql(u8, row.value(1).text, "new");
        }
    };
    var rows: Rows = .{};
    const receiver: sql.RowReceiver = .{ .context = &rows, .receive_fn = Rows.receive };
    try std.testing.expectEqual(sql.QueryOutcome.ok, first.capability().query("SELECT * FROM items ORDER BY id", &.{}, receiver));
    try std.testing.expect(rows.valid);
    try std.testing.expectEqual(@as(usize, 2), rows.count);
    try std.testing.expectEqual(@as(u32, 1), first.schemaVersion());
    try std.testing.expectEqual(@as(u32, 2), second.schemaVersion());
    rows = .{};
    try std.testing.expectEqual(sql.QueryOutcome.ok, first.capability().query("SELECT * FROM items WHERE id=1", &.{}, receiver));
    try std.testing.expect(rows.valid);
    try std.testing.expectEqual(@as(usize, 1), rows.count);
    rows = .{};
    try std.testing.expectEqual(sql.QueryOutcome.ok, first.capability().query("SELECT * FROM items WHERE 0", &.{}, receiver));
    try std.testing.expectEqual(@as(usize, 0), rows.count);
}

test "query validates new columns after another instance migrates the file" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = try temporary.dir.realPath(std.testing.io, &path_buffer);
    const path = try std.fs.path.join(std.testing.allocator, &.{ path_buffer[0..length], "new-text.db" });
    defer std.testing.allocator.free(path);
    const migrations = [_]sql.Migration{
        .{ .version = 1, .name = "create", .sql = "CREATE TABLE items(id INTEGER); INSERT INTO items VALUES(1);" },
        .{ .version = 2, .name = "add invalid text", .sql = "ALTER TABLE items ADD COLUMN label TEXT; UPDATE items SET label=char(0);" },
    };
    const first = try Database.create(std.testing.io, std.testing.allocator, .{ .file = path }, migrations[0..1]);
    defer first.destroy() catch unreachable;
    const second = try Database.create(std.testing.io, std.testing.allocator, .{ .file = path }, &migrations);
    defer second.destroy() catch unreachable;
    var observed: IntegerObservation = .{};
    try std.testing.expectEqual(sql.QueryOutcome.rejected, first.capability().query("SELECT * FROM items", &.{}, observed.receiver()));
    try std.testing.expectEqual(@as(usize, 0), observed.rows);
}

test "query budgets new columns after another instance migrates the file" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = try temporary.dir.realPath(std.testing.io, &path_buffer);
    const path = try std.fs.path.join(std.testing.allocator, &.{ path_buffer[0..length], "new-blob.db" });
    defer std.testing.allocator.free(path);
    const migrations = [_]sql.Migration{
        .{ .version = 1, .name = "create", .sql = "CREATE TABLE items(id INTEGER); INSERT INTO items VALUES(1),(2);" },
        .{ .version = 2, .name = "add blob", .sql = "ALTER TABLE items ADD COLUMN payload BLOB;" ++
            std.fmt.comptimePrint("UPDATE items SET payload=zeroblob({d});", .{sql.Limits.result_bytes / 2}) },
    };
    const first = try Database.create(std.testing.io, std.testing.allocator, .{ .file = path }, migrations[0..1]);
    defer first.destroy() catch unreachable;
    const second = try Database.create(std.testing.io, std.testing.allocator, .{ .file = path }, &migrations);
    defer second.destroy() catch unreachable;
    var observed: IntegerObservation = .{};
    try std.testing.expectEqual(sql.QueryOutcome.resource_exhausted, first.capability().query("SELECT * FROM items", &.{}, observed.receiver()));
    try std.testing.expectEqual(@as(usize, 1), observed.rows);
}

test "TEXT NUL rejection covers parameters and rows without restricting BLOB" {
    const database = try Database.create(std.testing.io, std.testing.allocator, .memory, &test_migrations);
    defer database.destroy() catch unreachable;
    var ignored: u8 = 0;
    const receiver: sql.RowReceiver = .{ .context = &ignored, .receive_fn = ignoreRow };
    try std.testing.expectEqual(sql.QueryOutcome.rejected, database.capability().query("SELECT ?", &.{.{ .text = "a\x00b" }}, receiver));
    try std.testing.expectEqual(sql.MutationOutcome.rejected, database.capability().mutate(&.{.{ .statement = .{
        .sql = "INSERT INTO storage_conformance(text_value) VALUES(?)",
        .params = &.{.{ .text = "a\x00b" }},
    } }}));
    try std.testing.expectEqual(sql.QueryOutcome.rejected, database.capability().query("SELECT char(0)", &.{}, receiver));
    try std.testing.expectEqual(sql.QueryOutcome.ok, database.capability().query("SELECT ?", &.{.{ .blob = "a\x00b" }}, receiver));
    var observed: IntegerObservation = .{};
    try std.testing.expectEqual(sql.QueryOutcome.rejected, database.capability().query("SELECT 1 UNION ALL SELECT char(0)", &.{}, observed.receiver()));
    try std.testing.expectEqual(@as(usize, 1), observed.rows);
}

fn expectTextPragma(
    connection: *Connection,
    text: []const u8,
    expected: []const u8,
) !void {
    const statement = try prepareOne(connection, text);
    defer _ = c.sqlite3_finalize(statement);
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(statement));
    try std.testing.expect(std.ascii.eqlIgnoreCase(columnText(statement, 0), expected));
    try std.testing.expectEqual(c.SQLITE_DONE, c.sqlite3_step(statement));
}

fn expectIntegerPragma(
    connection: *Connection,
    text: []const u8,
    expected: i64,
) !void {
    const statement = try prepareOne(connection, text);
    defer _ = c.sqlite3_finalize(statement);
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(statement));
    try std.testing.expectEqual(expected, c.sqlite3_column_int64(statement, 0));
    try std.testing.expectEqual(c.SQLITE_DONE, c.sqlite3_step(statement));
}

fn expectDatabaseConfig(
    connection: *Connection,
    operation: c_int,
    expected: c_int,
) !void {
    var actual: c_int = -1;
    try std.testing.expectEqual(
        c.SQLITE_OK,
        c.sqlite3_db_config(
            connection.handle,
            operation,
            @as(c_int, -1),
            &actual,
        ),
    );
    try std.testing.expectEqual(expected, actual);
}

test "maintenance confirms file durability and rejects memory or stopped capabilities" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var directory: [std.fs.max_path_bytes]u8 = undefined;
    const len = try temporary.dir.realPath(std.testing.io, &directory);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory[0..len], "maintenance.db" });
    defer std.testing.allocator.free(path);
    const database = try Database.create(std.testing.io, std.testing.allocator, .{ .file = path }, &test_migrations);
    defer database.destroy() catch unreachable;
    const db = database.capability();
    try std.testing.expectEqual(sql.MutationOutcome.committed, db.mutate(&.{.{ .statement = .{ .sql = "INSERT INTO storage_conformance(id) VALUES(818)" } }}));
    try std.testing.expectEqual(sql.QueryOutcome.ok, db.maintain(.confirm));
    try std.testing.expectEqual(sql.QueryOutcome.ok, db.maintain(.purge));
    try database.shutdown();
    try std.testing.expectEqual(sql.QueryOutcome.unavailable, db.maintain(.confirm));
    const memory = try Database.create(std.testing.io, std.testing.allocator, .memory, &test_migrations);
    defer memory.destroy() catch unreachable;
    try std.testing.expectEqual(sql.QueryOutcome.rejected, memory.capability().maintain(.confirm));
}

test "maintenance cannot acknowledge a readable witness while an older reader blocks checkpoint" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var directory: [std.fs.max_path_bytes]u8 = undefined;
    const len = try temporary.dir.realPath(std.testing.io, &directory);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory[0..len], "maintenance-reader.db" });
    defer std.testing.allocator.free(path);
    const database = try Database.create(std.testing.io, std.testing.allocator, .{ .file = path }, &test_migrations);
    defer database.destroy() catch unreachable;
    try std.testing.expectEqual(sql.QueryOutcome.ok, database.capability().maintain(.purge));
    const zero_path = try std.testing.allocator.dupeZ(u8, path);
    defer std.testing.allocator.free(zero_path);
    var reader = try Connection.open(zero_path);
    defer reader.close();
    try initializeConnection(&reader, true);
    try reader.execRaw("BEGIN;");
    const observed = try prepareOne(&reader, "SELECT COUNT(*) FROM storage_conformance");
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(observed));
    _ = c.sqlite3_finalize(observed);
    try std.testing.expectEqual(sql.MutationOutcome.committed, database.capability().mutate(&.{.{ .statement = .{ .sql = "INSERT INTO storage_conformance(id) VALUES(819)" } }}));
    var value: IntegerObservation = .{};
    try std.testing.expectEqual(sql.QueryOutcome.ok, database.capability().query("SELECT COUNT(*) FROM storage_conformance WHERE id=819", &.{}, value.receiver()));
    try std.testing.expectEqual(@as(i64, 1), value.value);
    try std.testing.expectEqual(sql.QueryOutcome.busy, database.capability().maintain(.confirm));
    try std.testing.expectEqual(sql.QueryOutcome.busy, database.capability().maintain(.purge));
    try reader.execRaw("ROLLBACK;");
    try std.testing.expectEqual(sql.QueryOutcome.ok, database.capability().maintain(.confirm));
    try std.testing.expectEqual(sql.QueryOutcome.ok, database.capability().maintain(.purge));
}

test "maintenance sync failure poisons instance and never reports confirmation" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var directory: [std.fs.max_path_bytes]u8 = undefined;
    const len = try temporary.dir.realPath(std.testing.io, &directory);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory[0..len], "maintenance-sync.db" });
    defer std.testing.allocator.free(path);
    const database = try Database.create(std.testing.io, std.testing.allocator, .{ .file = path }, &test_migrations);
    defer database.destroy() catch unreachable;
    database.test_hooks.fail_maintenance_sync = true;
    try std.testing.expectEqual(sql.QueryOutcome.definite_io_failure, database.capability().maintain(.confirm));
    try std.testing.expectEqual(sql.QueryOutcome.unavailable, database.capability().maintain(.purge));
}

test "secure purge removes replaced values from database free pages and truncates WAL" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var directory: [std.fs.max_path_bytes]u8 = undefined;
    const len = try temporary.dir.realPath(std.testing.io, &directory);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory[0..len], "purge.db" });
    defer std.testing.allocator.free(path);
    const database = try Database.create(std.testing.io, std.testing.allocator, .{ .file = path }, &test_migrations);
    defer database.destroy() catch unreachable;
    const marker = "storage-disposable-redaction-regression";
    const body = try std.testing.allocator.alloc(u8, 64 * 1024);
    defer std.testing.allocator.free(body);
    @memset(body, 'x');
    @memcpy(body[4090..][0..marker.len], marker);
    try std.testing.expectEqual(sql.MutationOutcome.committed, database.capability().mutate(&.{.{ .statement = .{ .sql = "INSERT INTO storage_conformance(id,blob_value) VALUES(820,?)", .params = &.{.{ .blob = body }} } }}));
    try std.testing.expectEqual(sql.QueryOutcome.ok, database.capability().maintain(.purge));
    try std.testing.expectEqual(sql.MutationOutcome.committed, database.capability().mutate(&.{.{ .statement = .{ .sql = "UPDATE storage_conformance SET blob_value=X'00' WHERE id=820" } }}));
    try std.testing.expectEqual(sql.QueryOutcome.ok, database.capability().maintain(.purge));
    var journal: [*c]c.sqlite3_file = null;
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_file_control(database.connection.handle, "main", c.SQLITE_FCNTL_JOURNAL_POINTER, @ptrCast(&journal)));
    if (journal != null) {
        var size: c.sqlite3_int64 = -1;
        try std.testing.expectEqual(c.SQLITE_OK, journal.*.pMethods.*.xFileSize.?(journal, &size));
        try std.testing.expectEqual(@as(c.sqlite3_int64, 0), size);
    }
    try database.shutdown();
    const bytes = try temporary.dir.readFileAlloc(std.testing.io, "purge.db", std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, marker) == null);
}

test "maintenance shares the query reentry gate" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var directory: [std.fs.max_path_bytes]u8 = undefined;
    const len = try temporary.dir.realPath(std.testing.io, &directory);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory[0..len], "maintenance-reentry.db" });
    defer std.testing.allocator.free(path);
    const database = try Database.create(std.testing.io, std.testing.allocator, .{ .file = path }, &test_migrations);
    defer database.destroy() catch unreachable;
    const Observation = struct {
        db: sql.Database,
        outcome: sql.QueryOutcome = .ok,
        fn receive(context: *anyopaque, _: sql.Row) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.outcome = self.db.maintain(.confirm);
        }
    };
    var observation: Observation = .{ .db = database.capability() };
    try std.testing.expectEqual(sql.QueryOutcome.ok, observation.db.query("SELECT 1", &.{}, .{ .context = &observation, .receive_fn = Observation.receive }));
    try std.testing.expectEqual(sql.QueryOutcome.rejected, observation.outcome);
    try std.testing.expectEqual(sql.QueryOutcome.ok, observation.db.maintain(.confirm));
}
