//! Direct SQLite backend for the backend-neutral Storage SQL contract.
//! SQLite values, handles, authorizers, profile, and recovery state never
//! escape this owner.

const std = @import("std");
const builtin = @import("builtin");
const sql = @import("sql.zig");
const conformance = @import("conformance.zig");

const c = @cImport({
    @cInclude("sqlite3.h");
});

const Authorizer = ?*const fn (
    ?*anyopaque,
    c_int,
    [*c]const u8,
    [*c]const u8,
    [*c]const u8,
    [*c]const u8,
) callconv(.c) c_int;

const migration_table = "_metawork_storage_migrations";

pub const Target = union(enum) {
    file: []const u8,
    memory,
};

pub const OpenError = error{
    OutOfMemory,
    InvalidTarget,
    InvalidMigrations,
    PathUnavailable,
    OpenFailed,
    Busy,
    Corrupt,
    ProfileMismatch,
    MigrationFailed,
    MigrationMismatch,
    MigrationOutcomeUnknown,
    VersionUnknown,
};

const SqlError = error{
    ResourceExhausted,
    Busy,
    Constraint,
    Corrupt,
    IoFailed,
    Cancelled,
    Rejected,
};

const Connection = struct {
    handle: *c.sqlite3,

    fn open(path: [:0]const u8) OpenError!Connection {
        var handle: ?*c.sqlite3 = null;
        const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE |
            c.SQLITE_OPEN_FULLMUTEX;
        const result = c.sqlite3_open_v2(path.ptr, &handle, flags, null);
        if (result != c.SQLITE_OK) {
            if (handle) |opened| _ = c.sqlite3_close_v2(opened);
            return openFailure(result);
        }
        const opened = handle orelse return error.OpenFailed;
        _ = c.sqlite3_extended_result_codes(opened, 1);
        return .{ .handle = opened };
    }

    fn close(self: *Connection) void {
        std.debug.assert(c.sqlite3_close_v2(self.handle) == c.SQLITE_OK);
    }

    fn execRaw(self: *Connection, text: [*:0]const u8) SqlError!void {
        const result = c.sqlite3_exec(self.handle, text, null, null, null);
        if (result != c.SQLITE_OK) return sqlFailure(result);
    }

    fn setAuthorizer(self: *Connection, callback: Authorizer) SqlError!void {
        const result = c.sqlite3_set_authorizer(self.handle, callback, null);
        if (result != c.SQLITE_OK) return sqlFailure(result);
    }
};

const Lifecycle = enum { active, stopping, stopped, poisoned };
const Admission = enum { entered, rejected, unavailable };
const TestHooks = if (builtin.is_test) struct {
    fail_before_commit: bool = false,
    lose_ack_after_commit: bool = false,
    fail_rollback: bool = false,
    fail_authorizer_restore: bool = false,
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
        };
        return self;
    }

    pub fn shutdown(self: *Database) void {
        self.lock();
        if (self.lifecycle == .stopped) {
            self.unlock();
            return;
        }
        if (self.lifecycle == .stopping) {
            while (self.lifecycle != .stopped) self.wait();
            self.unlock();
            return;
        }
        self.lifecycle = .stopping;
        self.broadcast();
        if (self.operating) c.sqlite3_interrupt(self.connection.handle);
        while (self.operating) self.wait();
        self.connection.close();
        self.lifecycle = .stopped;
        self.broadcast();
        self.unlock();
    }

    pub fn destroy(self: *Database) void {
        self.shutdown();
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
        };
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

        const column_count: usize = @intCast(c.sqlite3_column_count(statement));
        var total_bytes: usize = 0;
        for (0..column_count) |index| {
            const name = columnName(statement, index);
            if (!std.unicode.utf8ValidateSlice(name)) return .rejected;
            total_bytes = std.math.add(usize, total_bytes, name.len) catch
                return .resource_exhausted;
            if (total_bytes > sql.Limits.result_bytes) return .resource_exhausted;
        }

        var row_count: usize = 0;
        while (true) switch (c.sqlite3_step(statement)) {
            c.SQLITE_DONE => return .ok,
            c.SQLITE_ROW => {
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
            _ = self.restoreDeny();
            return mutationFailure(err);
        };
        self.connection.setAuthorizer(mutationAuthorizer) catch |err|
            return self.rollbackMutation(mutationFailure(err));

        for (mutations) |mutation| {
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
        }
        return self.commitMutation();
    }

    fn commitMutation(self: *Database) sql.MutationOutcome {
        if (builtin.is_test and self.test_hooks.fail_before_commit) {
            self.test_hooks.fail_before_commit = false;
            return self.rollbackMutation(.definite_io_failure);
        }
        self.connection.setAuthorizer(internalTransactionAuthorizer) catch
            return self.unknownMutation();
        self.connection.execRaw("COMMIT;") catch |err| {
            if (c.sqlite3_get_autocommit(self.connection.handle) != 0)
                return self.unknownMutation();
            return self.rollbackMutation(mutationFailure(err));
        };
        if (c.sqlite3_get_autocommit(self.connection.handle) == 0)
            return self.unknownMutation();
        if (builtin.is_test and self.test_hooks.lose_ack_after_commit) {
            self.test_hooks.lose_ack_after_commit = false;
            return self.unknownMutation();
        }
        if (!self.restoreDeny()) return self.unknownMutation();
        return .committed;
    }

    fn rollbackMutation(
        self: *Database,
        outcome: sql.MutationOutcome,
    ) sql.MutationOutcome {
        if (builtin.is_test and self.test_hooks.fail_rollback) {
            self.test_hooks.fail_rollback = false;
            return self.unknownMutation();
        }
        self.connection.setAuthorizer(internalTransactionAuthorizer) catch
            return self.unknownMutation();
        self.connection.execRaw("ROLLBACK;") catch return self.unknownMutation();
        if (c.sqlite3_get_autocommit(self.connection.handle) == 0)
            return self.unknownMutation();
        if (!self.restoreDeny()) return self.unknownMutation();
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
        while (true) {
            if (self.lifecycle != .active) return .unavailable;
            if (!self.operating) {
                self.operating = true;
                self.active_thread = thread_id;
                return .entered;
            }
            if (self.active_thread == thread_id) return .rejected;
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

fn initializeConnection(connection: *Connection, durable: bool) OpenError!void {
    configureDatabase(connection, c.SQLITE_DBCONFIG_DEFENSIVE, 1) catch |err|
        return initializeFailure(err);
    configureDatabase(connection, c.SQLITE_DBCONFIG_TRUSTED_SCHEMA, 0) catch |err|
        return initializeFailure(err);
    setLimit(connection, c.SQLITE_LIMIT_LENGTH, sql.Limits.result_bytes) catch |err|
        return initializeFailure(err);
    setLimit(connection, c.SQLITE_LIMIT_SQL_LENGTH, sql.Limits.migration_bytes) catch |err|
        return initializeFailure(err);
    setLimit(connection, c.SQLITE_LIMIT_VARIABLE_NUMBER, sql.Limits.parameters) catch |err|
        return initializeFailure(err);
    setLimit(connection, c.SQLITE_LIMIT_ATTACHED, 0) catch |err|
        return initializeFailure(err);
    setLimit(connection, c.SQLITE_LIMIT_WORKER_THREADS, 0) catch |err|
        return initializeFailure(err);

    if (durable) {
        try setTextPragma(connection, "PRAGMA journal_mode=WAL;", "wal");
        try setIntegerPragma(
            connection,
            "PRAGMA synchronous=FULL;",
            "PRAGMA synchronous;",
            2,
        );
        try setIntegerPragma(
            connection,
            "PRAGMA mmap_size=0;",
            "PRAGMA mmap_size;",
            0,
        );
    }
    try setIntegerPragma(
        connection,
        "PRAGMA foreign_keys=ON;",
        "PRAGMA foreign_keys;",
        1,
    );
    try setIntegerPragma(
        connection,
        "PRAGMA busy_timeout=250;",
        "PRAGMA busy_timeout;",
        250,
    );
}

fn configureDatabase(connection: *Connection, operation: c_int, expected: c_int) SqlError!void {
    var actual: c_int = -1;
    const result = c.sqlite3_db_config(connection.handle, operation, expected, &actual);
    if (result != c.SQLITE_OK) return sqlFailure(result);
    if (actual != expected) return error.Rejected;
}

fn setLimit(connection: *Connection, category: c_int, value: usize) SqlError!void {
    _ = c.sqlite3_limit(connection.handle, category, @intCast(value));
    if (c.sqlite3_limit(connection.handle, category, -1) != @as(c_int, @intCast(value)))
        return error.Rejected;
}

fn setTextPragma(
    connection: *Connection,
    text: []const u8,
    expected: []const u8,
) OpenError!void {
    const statement = prepareOne(connection, text) catch |err|
        return initializeFailure(err);
    defer _ = c.sqlite3_finalize(statement);
    if (c.sqlite3_step(statement) != c.SQLITE_ROW or
        !std.ascii.eqlIgnoreCase(columnText(statement, 0), expected) or
        c.sqlite3_step(statement) != c.SQLITE_DONE)
        return error.ProfileMismatch;
}

fn setIntegerPragma(
    connection: *Connection,
    setter: [*:0]const u8,
    reader: []const u8,
    expected: i64,
) OpenError!void {
    connection.execRaw(setter) catch |err| return initializeFailure(err);
    const statement = prepareOne(connection, reader) catch |err|
        return initializeFailure(err);
    defer _ = c.sqlite3_finalize(statement);
    if (c.sqlite3_step(statement) != c.SQLITE_ROW or
        c.sqlite3_column_int64(statement, 0) != expected or
        c.sqlite3_step(statement) != c.SQLITE_DONE)
        return error.ProfileMismatch;
}

fn applyMigrations(
    allocator: std.mem.Allocator,
    connection: *Connection,
    migrations: []const sql.Migration,
) OpenError!u32 {
    connection.setAuthorizer(internalTransactionAuthorizer) catch |err|
        return migrationFailure(err);
    connection.execRaw("BEGIN IMMEDIATE;") catch |err|
        return migrationFailure(err);
    var transaction_active = true;
    errdefer if (transaction_active) rollbackMigration(connection);

    connection.setAuthorizer(metadataAuthorizer) catch |err|
        return migrationFailure(err);
    connection.execRaw(
        "CREATE TABLE IF NOT EXISTS _metawork_storage_migrations(" ++ "version INTEGER PRIMARY KEY," ++ "name TEXT NOT NULL," ++ "checksum BLOB NOT NULL CHECK(length(checksum)=32));",
    ) catch |err| return migrationFailure(err);

    const persisted = try verifyMigrationPrefix(connection, migrations);
    for (migrations[persisted..]) |migration| {
        connection.setAuthorizer(migrationAuthorizer) catch |err|
            return migrationFailure(err);
        const text = allocator.dupeZ(u8, migration.sql) catch
            return error.OutOfMemory;
        defer allocator.free(text);
        connection.execRaw(text) catch |err| return migrationFailure(err);

        connection.setAuthorizer(metadataAuthorizer) catch |err|
            return migrationFailure(err);
        insertMigrationIdentity(connection, migration) catch |err|
            return migrationFailure(err);
    }

    connection.setAuthorizer(internalTransactionAuthorizer) catch
        return error.MigrationOutcomeUnknown;
    connection.execRaw("COMMIT;") catch |err| {
        if (c.sqlite3_get_autocommit(connection.handle) != 0)
            return error.MigrationOutcomeUnknown;
        rollbackMigration(connection);
        return migrationFailure(err);
    };
    transaction_active = false;
    if (c.sqlite3_get_autocommit(connection.handle) == 0)
        return error.MigrationOutcomeUnknown;
    return @intCast(migrations.len);
}

fn verifyMigrationPrefix(
    connection: *Connection,
    migrations: []const sql.Migration,
) OpenError!usize {
    const statement = prepareOne(
        connection,
        "SELECT version,name,checksum FROM _metawork_storage_migrations ORDER BY version",
    ) catch |err| return migrationFailure(err);
    defer _ = c.sqlite3_finalize(statement);
    var persisted: usize = 0;
    while (true) switch (c.sqlite3_step(statement)) {
        c.SQLITE_DONE => return persisted,
        c.SQLITE_ROW => {
            if (persisted >= migrations.len) return error.VersionUnknown;
            const migration = migrations[persisted];
            const version = c.sqlite3_column_int64(statement, 0);
            if (version != @as(i64, migration.version)) return error.Corrupt;
            if (!std.mem.eql(u8, columnText(statement, 1), migration.name))
                return error.MigrationMismatch;
            var expected: [32]u8 = undefined;
            migrationChecksum(migration, &expected);
            if (!std.mem.eql(u8, columnBlob(statement, 2), &expected))
                return error.MigrationMismatch;
            persisted += 1;
        },
        else => |result| return migrationFailure(sqlFailure(result)),
    };
}

fn insertMigrationIdentity(
    connection: *Connection,
    migration: sql.Migration,
) SqlError!void {
    const statement = try prepareOne(
        connection,
        "INSERT INTO _metawork_storage_migrations(version,name,checksum) VALUES(?,?,?)",
    );
    defer _ = c.sqlite3_finalize(statement);
    var checksum: [32]u8 = undefined;
    migrationChecksum(migration, &checksum);
    try bindAll(statement, &.{
        .{ .integer = migration.version },
        .{ .text = migration.name },
        .{ .blob = &checksum },
    });
    const result = c.sqlite3_step(statement);
    if (result != c.SQLITE_DONE) return sqlFailure(result);
}

fn migrationChecksum(migration: sql.Migration, output: *[32]u8) void {
    var version: [4]u8 = undefined;
    std.mem.writeInt(u32, &version, migration.version, .big);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(&version);
    hasher.update(&.{0});
    hasher.update(migration.name);
    hasher.update(&.{0});
    hasher.update(migration.sql);
    hasher.final(output);
}

fn rollbackMigration(connection: *Connection) void {
    connection.setAuthorizer(internalTransactionAuthorizer) catch return;
    connection.execRaw("ROLLBACK;") catch {};
}

fn prepareOne(connection: *Connection, text: []const u8) SqlError!*c.sqlite3_stmt {
    var statement: ?*c.sqlite3_stmt = null;
    var tail: [*c]const u8 = null;
    const result = c.sqlite3_prepare_v2(
        connection.handle,
        text.ptr,
        @intCast(text.len),
        &statement,
        &tail,
    );
    if (result != c.SQLITE_OK) return sqlFailure(result);
    errdefer {
        if (statement) |prepared| _ = c.sqlite3_finalize(prepared);
    }
    const first = statement orelse return error.Rejected;
    if (tail != null) {
        const consumed: usize = @intFromPtr(tail) - @intFromPtr(text.ptr);
        if (consumed < text.len) {
            const remaining = text[consumed..];
            var extra: ?*c.sqlite3_stmt = null;
            const extra_result = c.sqlite3_prepare_v2(
                connection.handle,
                remaining.ptr,
                @intCast(remaining.len),
                &extra,
                null,
            );
            if (extra_result != c.SQLITE_OK) return sqlFailure(extra_result);
            if (extra) |prepared| {
                _ = c.sqlite3_finalize(prepared);
                return error.Rejected;
            }
        }
    }
    return first;
}

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

fn bindAll(statement: *c.sqlite3_stmt, params: []const sql.Value) SqlError!void {
    for (params, 0..) |value, index| {
        const parameter_index: c_int = @intCast(index + 1);
        const result = switch (value) {
            .null_value => c.sqlite3_bind_null(statement, parameter_index),
            .integer => |number| c.sqlite3_bind_int64(statement, parameter_index, number),
            .real => |number| c.sqlite3_bind_double(statement, parameter_index, number),
            .text => |bytes| c.sqlite3_bind_text(
                statement,
                parameter_index,
                bytes.ptr,
                @intCast(bytes.len),
                null,
            ),
            .blob => |bytes| if (bytes.len == 0)
                c.sqlite3_bind_zeroblob64(statement, parameter_index, 0)
            else
                c.sqlite3_bind_blob64(
                    statement,
                    parameter_index,
                    bytes.ptr,
                    bytes.len,
                    null,
                ),
        };
        if (result != c.SQLITE_OK) return sqlFailure(result);
    }
}

fn rowBytes(
    statement: *c.sqlite3_stmt,
    column_count: usize,
    initial: usize,
) SqlError!usize {
    var total = initial;
    for (0..column_count) |index| {
        const column: c_int = @intCast(index);
        const bytes: usize = switch (c.sqlite3_column_type(statement, column)) {
            c.SQLITE_INTEGER, c.SQLITE_FLOAT => 8,
            c.SQLITE_NULL => 1,
            c.SQLITE_TEXT => text: {
                const value = columnText(statement, index);
                if (!std.unicode.utf8ValidateSlice(value)) return error.Rejected;
                break :text value.len;
            },
            c.SQLITE_BLOB => columnBlob(statement, index).len,
            else => return error.Rejected,
        };
        if (c.sqlite3_column_type(statement, column) == c.SQLITE_FLOAT and
            !std.math.isFinite(c.sqlite3_column_double(statement, column)))
            return error.Rejected;
        total = std.math.add(usize, total, bytes) catch
            return error.ResourceExhausted;
    }
    return total;
}

fn columnValue(statement: *c.sqlite3_stmt, index: usize) sql.Value {
    const column: c_int = @intCast(index);
    return switch (c.sqlite3_column_type(statement, column)) {
        c.SQLITE_INTEGER => .{ .integer = c.sqlite3_column_int64(statement, column) },
        c.SQLITE_FLOAT => .{ .real = c.sqlite3_column_double(statement, column) },
        c.SQLITE_TEXT => .{ .text = columnText(statement, index) },
        c.SQLITE_BLOB => .{ .blob = columnBlob(statement, index) },
        c.SQLITE_NULL => .null_value,
        else => .null_value,
    };
}

fn columnName(statement: *c.sqlite3_stmt, index: usize) []const u8 {
    const pointer = c.sqlite3_column_name(statement, @intCast(index)) orelse
        return "";
    return std.mem.span(pointer);
}

fn columnText(statement: *c.sqlite3_stmt, index: usize) []const u8 {
    const column: c_int = @intCast(index);
    const length = c.sqlite3_column_bytes(statement, column);
    if (length <= 0) return "";
    const pointer = c.sqlite3_column_text(statement, column) orelse return "";
    return pointer[0..@intCast(length)];
}

fn columnBlob(statement: *c.sqlite3_stmt, index: usize) []const u8 {
    const column: c_int = @intCast(index);
    const length = c.sqlite3_column_bytes(statement, column);
    if (length <= 0) return "";
    const raw = c.sqlite3_column_blob(statement, column) orelse return "";
    const pointer: [*]const u8 = @ptrCast(raw);
    return pointer[0..@intCast(length)];
}

fn parameterCount(statement: *c.sqlite3_stmt) usize {
    return @intCast(c.sqlite3_bind_parameter_count(statement));
}

const Authority = enum { deny_all, query, mutation, migration, metadata, transaction };

fn denyAllAuthorizer(
    _: ?*anyopaque,
    action: c_int,
    first: [*c]const u8,
    second: [*c]const u8,
    database: [*c]const u8,
    _: [*c]const u8,
) callconv(.c) c_int {
    return authorize(.deny_all, action, first, second, database);
}

fn queryAuthorizer(
    _: ?*anyopaque,
    action: c_int,
    first: [*c]const u8,
    second: [*c]const u8,
    database: [*c]const u8,
    _: [*c]const u8,
) callconv(.c) c_int {
    return authorize(.query, action, first, second, database);
}

fn mutationAuthorizer(
    _: ?*anyopaque,
    action: c_int,
    first: [*c]const u8,
    second: [*c]const u8,
    database: [*c]const u8,
    _: [*c]const u8,
) callconv(.c) c_int {
    return authorize(.mutation, action, first, second, database);
}

fn migrationAuthorizer(
    _: ?*anyopaque,
    action: c_int,
    first: [*c]const u8,
    second: [*c]const u8,
    database: [*c]const u8,
    _: [*c]const u8,
) callconv(.c) c_int {
    return authorize(.migration, action, first, second, database);
}

fn metadataAuthorizer(
    _: ?*anyopaque,
    action: c_int,
    first: [*c]const u8,
    second: [*c]const u8,
    database: [*c]const u8,
    _: [*c]const u8,
) callconv(.c) c_int {
    return authorize(.metadata, action, first, second, database);
}

fn internalTransactionAuthorizer(
    _: ?*anyopaque,
    action: c_int,
    first: [*c]const u8,
    second: [*c]const u8,
    database: [*c]const u8,
    _: [*c]const u8,
) callconv(.c) c_int {
    return authorize(.transaction, action, first, second, database);
}

fn authorize(
    authority: Authority,
    action: c_int,
    first: [*c]const u8,
    _: [*c]const u8,
    database: [*c]const u8,
) c_int {
    if (authority == .deny_all) return c.SQLITE_DENY;
    if (action == c.SQLITE_ATTACH or action == c.SQLITE_DETACH or
        action == c.SQLITE_SAVEPOINT or action == c.SQLITE_PRAGMA or
        temporarySchemaOperation(action))
        return c.SQLITE_DENY;
    if (action == c.SQLITE_TRANSACTION)
        return if (authority == .transaction) c.SQLITE_OK else c.SQLITE_DENY;
    if (authority == .transaction) return c.SQLITE_DENY;

    if (database != null) {
        const name = std.mem.span(database);
        if (name.len != 0 and !std.ascii.eqlIgnoreCase(name, "main"))
            return c.SQLITE_DENY;
    }
    const object = if (first == null) "" else std.mem.span(first);
    if (authority == .migration and
        std.ascii.eqlIgnoreCase(object, migration_table)) return c.SQLITE_DENY;
    if ((authority == .query or authority == .mutation) and
        protectedObject(object)) return c.SQLITE_DENY;

    return switch (authority) {
        .query => switch (action) {
            c.SQLITE_SELECT, c.SQLITE_READ, c.SQLITE_FUNCTION, c.SQLITE_RECURSIVE => c.SQLITE_OK,
            else => c.SQLITE_DENY,
        },
        .mutation => switch (action) {
            c.SQLITE_SELECT,
            c.SQLITE_READ,
            c.SQLITE_FUNCTION,
            c.SQLITE_RECURSIVE,
            c.SQLITE_INSERT,
            c.SQLITE_UPDATE,
            c.SQLITE_DELETE,
            => c.SQLITE_OK,
            else => c.SQLITE_DENY,
        },
        .migration, .metadata => c.SQLITE_OK,
        .deny_all, .transaction => c.SQLITE_DENY,
    };
}

fn protectedObject(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, migration_table) or
        std.ascii.eqlIgnoreCase(name, "sqlite_master") or
        std.ascii.eqlIgnoreCase(name, "sqlite_schema");
}

fn temporarySchemaOperation(action: c_int) bool {
    return (action >= c.SQLITE_CREATE_TEMP_INDEX and
        action <= c.SQLITE_CREATE_TEMP_VIEW) or
        (action >= c.SQLITE_DROP_TEMP_INDEX and
            action <= c.SQLITE_DROP_TEMP_VIEW);
}

fn sqlFailure(result: c_int) SqlError {
    return switch (result & 0xff) {
        c.SQLITE_NOMEM, c.SQLITE_TOOBIG, c.SQLITE_FULL => error.ResourceExhausted,
        c.SQLITE_BUSY, c.SQLITE_LOCKED => error.Busy,
        c.SQLITE_CONSTRAINT => error.Constraint,
        c.SQLITE_CORRUPT, c.SQLITE_NOTADB => error.Corrupt,
        c.SQLITE_IOERR, c.SQLITE_READONLY, c.SQLITE_CANTOPEN, c.SQLITE_PERM => error.IoFailed,
        c.SQLITE_INTERRUPT => error.Cancelled,
        else => error.Rejected,
    };
}

fn openFailure(result: c_int) OpenError {
    return switch (result & 0xff) {
        c.SQLITE_NOMEM => error.OutOfMemory,
        c.SQLITE_BUSY, c.SQLITE_LOCKED => error.Busy,
        c.SQLITE_CORRUPT, c.SQLITE_NOTADB => error.Corrupt,
        c.SQLITE_CANTOPEN, c.SQLITE_PERM, c.SQLITE_READONLY => error.PathUnavailable,
        else => error.OpenFailed,
    };
}

fn initializeFailure(err: SqlError) OpenError {
    return switch (err) {
        error.ResourceExhausted => error.OutOfMemory,
        error.Busy => error.Busy,
        error.Corrupt => error.Corrupt,
        error.IoFailed => error.PathUnavailable,
        else => error.ProfileMismatch,
    };
}

fn migrationFailure(err: SqlError) OpenError {
    return switch (err) {
        error.ResourceExhausted => error.OutOfMemory,
        error.Busy => error.Busy,
        error.Corrupt => error.Corrupt,
        else => error.MigrationFailed,
    };
}

fn queryFailure(err: SqlError) sql.QueryOutcome {
    return switch (err) {
        error.Busy => .busy,
        error.Cancelled => .cancelled,
        error.Corrupt => .corrupt,
        error.ResourceExhausted => .resource_exhausted,
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
        error.ResourceExhausted => .resource_exhausted,
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
    defer database.destroy();
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
    defer database.destroy();
    const capability = database.capability();
    const ignored: sql.RowReceiver = .{ .context = database, .receive_fn = ignoreRow };

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
    defer database.destroy();
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

test "failure before commit is definite and leaves the instance usable" {
    const database = try Database.create(
        std.testing.io,
        std.testing.allocator,
        .memory,
        &test_migrations,
    );
    defer database.destroy();
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
        database.destroy();
    }
    {
        const database = try Database.create(
            std.testing.io,
            std.testing.allocator,
            .{ .file = path },
            &test_migrations,
        );
        defer database.destroy();
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

test "rollback and authorizer restore failures poison instead of guessing" {
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
        database.destroy();
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
            sql.MutationOutcome.outcome_unknown,
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
        database.destroy();
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
        database.destroy();
    }
    {
        const database = try Database.create(
            std.testing.io,
            std.testing.allocator,
            .{ .file = path },
            &test_migrations,
        );
        database.destroy();
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
    defer database.destroy();
    try std.testing.expectEqual(@as(u32, 1), database.schemaVersion());
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
    defer database.destroy();

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

test "shutdown is idempotent and borrowed capability becomes unavailable" {
    const database = try Database.create(
        std.testing.io,
        std.testing.allocator,
        .memory,
        &test_migrations,
    );
    const capability = database.capability();
    database.shutdown();
    database.shutdown();
    var ignored: IntegerObservation = .{};
    try std.testing.expectEqual(
        sql.QueryOutcome.unavailable,
        capability.query("SELECT 1", &.{}, ignored.receiver()),
    );
    try std.testing.expectEqual(
        sql.MutationOutcome.unavailable,
        capability.mutate(&.{.{ .statement = .{ .sql = "DELETE FROM storage_conformance" } }}),
    );
    database.destroy();
}

test "interrupt cancels the active query without poisoning the instance" {
    const database = try Database.create(
        std.testing.io,
        std.testing.allocator,
        .memory,
        &.{},
    );
    defer database.destroy();
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
    const shutdown_thread = try std.Thread.spawn(.{}, Database.shutdown, .{database});

    database.lock();
    while (database.lifecycle != .stopping) database.wait();
    database.unlock();
    blocker.release();
    query_thread.join();
    shutdown_thread.join();
    try std.testing.expectEqual(sql.QueryOutcome.cancelled, outcome);
    try std.testing.expectEqual(Lifecycle.stopped, database.lifecycle);
    database.destroy();
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
    defer first.destroy();
    const second = try Database.create(
        std.testing.io,
        std.testing.allocator,
        .{ .file = path },
        &test_migrations,
    );
    defer second.destroy();

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
    const fixture = std.process.Environ.getAlloc(
        std.testing.environ,
        std.testing.allocator,
        "METAWORK_STORAGE_CRASH_FIXTURE",
    ) catch |err| switch (err) {
        error.EnvironmentVariableMissing => return error.SkipZigTest,
        else => return err,
    };
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
        database.destroy();
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
    defer database.destroy();
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
    defer database.destroy();
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
