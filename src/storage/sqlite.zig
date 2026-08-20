//! Direct SQLite backend for the stable Storage SQL contract.
//! This module owns every SQLite C value and never exposes one to callers.

const std = @import("std");
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
    MigrationFailed,
    VersionUnknown,
};

const SqlError = error{
    NoMemory,
    Busy,
    Constraint,
    Corrupt,
    IoFailed,
    Misuse,
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
        _ = c.sqlite3_close_v2(self.handle);
    }

    fn execRaw(self: *Connection, text: [*:0]const u8) SqlError!void {
        const result = c.sqlite3_exec(self.handle, text, null, null, null);
        if (result != c.SQLITE_OK) return sqlFailure(result);
    }

    fn setAuthorizer(
        self: *Connection,
        callback: Authorizer,
    ) SqlError!void {
        const result = c.sqlite3_set_authorizer(self.handle, callback, null);
        if (result != c.SQLITE_OK) return sqlFailure(result);
    }
};

/// Concrete owner. Keep this value at one stable address after open; a
/// capability returned by capability() borrows this address.
pub const Database = struct {
    allocator: std.mem.Allocator,
    writer: Connection,
    reader: ?Connection = null,
    writer_mutex: std.atomic.Mutex = .unlocked,
    reader_mutex: std.atomic.Mutex = .unlocked,
    schema_version: u32 = 0,

    pub fn open(
        allocator: std.mem.Allocator,
        target: Target,
        migrations: []const sql.Migration,
    ) OpenError!Database {
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

        var writer = try Connection.open(path);
        errdefer writer.close();
        try initializeWriter(&writer, is_file);

        var database: Database = .{
            .allocator = allocator,
            .writer = writer,
        };
        database.schema_version = try database.applyMigrations(migrations);
        database.writer.setAuthorizer(normalAuthorizer) catch |err|
            return initializeFailure(err);

        if (is_file) {
            var reader = try Connection.open(path);
            errdefer reader.close();
            try initializeReader(&reader);
            reader.setAuthorizer(normalAuthorizer) catch |err|
                return initializeFailure(err);
            database.reader = reader;
        }
        return database;
    }

    pub fn deinit(self: *Database) void {
        if (self.reader) |*reader| reader.close();
        self.writer.close();
        self.* = undefined;
    }

    pub fn capability(self: *Database) sql.Database {
        return .{
            .context = self,
            .query_fn = queryBound,
            .exec_fn = execBound,
        };
    }

    pub fn schemaVersion(self: *const Database) u32 {
        return self.schema_version;
    }

    fn query(
        self: *Database,
        text: []const u8,
        params: []const sql.Value,
        receiver: sql.RowReceiver,
    ) sql.QueryOutcome {
        const connection, const mutex = if (self.reader) |*reader|
            .{ reader, &self.reader_mutex }
        else
            .{ &self.writer, &self.writer_mutex };
        lock(mutex);
        defer mutex.unlock();

        const statement = prepareOne(connection, text) catch |err|
            return queryFailure(err);
        defer _ = c.sqlite3_finalize(statement);
        if (c.sqlite3_stmt_readonly(statement) == 0 or
            parameterCount(statement) != params.len)
            return .misuse;
        bindAll(statement, params) catch |err| return queryFailure(err);

        const column_count: usize = @intCast(c.sqlite3_column_count(statement));
        var total_bytes: usize = 0;
        for (0..column_count) |index| {
            const name = columnName(statement, index);
            if (!std.unicode.utf8ValidateSlice(name)) return .misuse;
            total_bytes = std.math.add(usize, total_bytes, name.len) catch
                return .rejected;
            if (total_bytes > sql.Limits.result_bytes) return .rejected;
        }

        var row_count: usize = 0;
        while (true) switch (c.sqlite3_step(statement)) {
            c.SQLITE_DONE => return .ok,
            c.SQLITE_ROW => {
                if (row_count == sql.Limits.result_rows) return .rejected;
                total_bytes = rowBytes(statement, column_count, total_bytes) catch |err|
                    return queryFailure(err);
                if (total_bytes > sql.Limits.result_bytes) return .rejected;
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

    fn exec(
        self: *Database,
        statements: []const sql.Statement,
    ) sql.ExecOutcome {
        lock(&self.writer_mutex);
        defer self.writer_mutex.unlock();

        self.writer.execRaw("BEGIN IMMEDIATE;") catch |err|
            return execFailure(err);
        self.writer.setAuthorizer(containedAuthorizer) catch |err| {
            return self.rollback(execFailure(err));
        };

        for (statements) |item| {
            const statement = prepareOne(&self.writer, item.sql) catch |err| {
                return self.restoreAndRollback(execFailure(err));
            };
            const outcome = executeMutation(statement, item.params);
            _ = c.sqlite3_finalize(statement);
            if (outcome) |failure| return self.restoreAndRollback(failure);
        }

        self.writer.setAuthorizer(normalAuthorizer) catch |err|
            return self.rollback(execFailure(err));
        self.writer.execRaw("COMMIT;") catch |err|
            return self.rollback(execFailure(err));
        return .ok;
    }

    fn restoreAndRollback(
        self: *Database,
        outcome: sql.ExecOutcome,
    ) sql.ExecOutcome {
        self.writer.setAuthorizer(normalAuthorizer) catch return self.rollback(.io_failed);
        return self.rollback(outcome);
    }

    fn rollback(self: *Database, outcome: sql.ExecOutcome) sql.ExecOutcome {
        self.writer.execRaw("ROLLBACK;") catch return .io_failed;
        return outcome;
    }

    fn applyMigrations(
        self: *Database,
        migrations: []const sql.Migration,
    ) OpenError!u32 {
        const current = readSchemaVersion(&self.writer) catch |err|
            return migrationFailure(err);
        const target: u32 = if (migrations.len == 0)
            0
        else
            migrations[migrations.len - 1].version;
        if (current > target) return error.VersionUnknown;
        if (current == target) return current;

        self.writer.execRaw("BEGIN IMMEDIATE;") catch |err|
            return migrationFailure(err);
        self.writer.setAuthorizer(containedAuthorizer) catch |err| {
            _ = self.writer.execRaw("ROLLBACK;") catch {};
            return migrationFailure(err);
        };

        for (migrations) |migration| {
            if (migration.version <= current) continue;
            const text = self.allocator.dupeZ(u8, migration.sql) catch {
                _ = self.restoreMigrationAndRollback();
                return error.OutOfMemory;
            };
            defer self.allocator.free(text);
            self.writer.execRaw(text) catch |err| {
                _ = self.restoreMigrationAndRollback();
                return migrationFailure(err);
            };
        }

        self.writer.setAuthorizer(normalAuthorizer) catch |err| {
            _ = self.restoreMigrationAndRollback();
            return migrationFailure(err);
        };
        var version_storage: [64]u8 = undefined;
        const version_sql = std.fmt.bufPrintZ(
            &version_storage,
            "PRAGMA user_version={d};",
            .{target},
        ) catch {
            _ = self.writer.execRaw("ROLLBACK;") catch {};
            return error.MigrationFailed;
        };
        self.writer.setAuthorizer(null) catch |err| {
            _ = self.writer.execRaw("ROLLBACK;") catch {};
            return migrationFailure(err);
        };
        self.writer.execRaw(version_sql) catch |err| {
            _ = self.writer.execRaw("ROLLBACK;") catch {};
            return migrationFailure(err);
        };
        self.writer.setAuthorizer(normalAuthorizer) catch |err| {
            _ = self.writer.execRaw("ROLLBACK;") catch {};
            return migrationFailure(err);
        };
        self.writer.execRaw("COMMIT;") catch |err| {
            _ = self.writer.execRaw("ROLLBACK;") catch {};
            return migrationFailure(err);
        };
        return target;
    }

    fn restoreMigrationAndRollback(self: *Database) bool {
        self.writer.setAuthorizer(normalAuthorizer) catch return false;
        self.writer.execRaw("ROLLBACK;") catch return false;
        return true;
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

    fn execBound(
        context: *anyopaque,
        statements: []const sql.Statement,
    ) sql.ExecOutcome {
        const self: *Database = @ptrCast(@alignCast(context));
        return self.exec(statements);
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

fn initializeWriter(connection: *Connection, durable: bool) OpenError!void {
    if (durable) {
        connection.execRaw("PRAGMA journal_mode=WAL;") catch |err|
            return initializeFailure(err);
        connection.execRaw("PRAGMA synchronous=NORMAL;") catch |err|
            return initializeFailure(err);
    }
    connection.execRaw("PRAGMA busy_timeout=250;") catch |err|
        return initializeFailure(err);
    connection.execRaw("PRAGMA foreign_keys=ON;") catch |err|
        return initializeFailure(err);
}

fn initializeReader(connection: *Connection) OpenError!void {
    connection.execRaw("PRAGMA busy_timeout=250;") catch |err|
        return initializeFailure(err);
    connection.execRaw("PRAGMA foreign_keys=ON;") catch |err|
        return initializeFailure(err);
    connection.execRaw("PRAGMA query_only=ON;") catch |err|
        return initializeFailure(err);
}

fn readSchemaVersion(connection: *Connection) SqlError!u32 {
    const statement = try prepareOne(connection, "PRAGMA user_version;");
    defer _ = c.sqlite3_finalize(statement);
    if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.Misuse;
    const value = c.sqlite3_column_int64(statement, 0);
    if (value < 0 or value > sql.Limits.migrations) return error.Corrupt;
    if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.Misuse;
    return @intCast(value);
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
    const first = statement orelse return error.Misuse;

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
                return error.Misuse;
            }
        }
    }
    return first;
}

fn executeMutation(
    statement: *c.sqlite3_stmt,
    params: []const sql.Value,
) ?sql.ExecOutcome {
    if (c.sqlite3_stmt_readonly(statement) != 0 or
        c.sqlite3_column_count(statement) != 0 or
        parameterCount(statement) != params.len)
        return .misuse;
    bindAll(statement, params) catch |err| return execFailure(err);
    const result = c.sqlite3_step(statement);
    if (result == c.SQLITE_DONE) return null;
    if (result == c.SQLITE_ROW) return .misuse;
    return execFailure(sqlFailure(result));
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
                if (!std.unicode.utf8ValidateSlice(value)) return error.Misuse;
                break :text value.len;
            },
            c.SQLITE_BLOB => columnBlob(statement, index).len,
            else => return error.Misuse,
        };
        if (c.sqlite3_column_type(statement, column) == c.SQLITE_FLOAT and
            !std.math.isFinite(c.sqlite3_column_double(statement, column)))
            return error.Misuse;
        total = std.math.add(usize, total, bytes) catch return error.Rejected;
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

fn lock(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) std.atomic.spinLoopHint();
}

fn normalAuthorizer(
    _: ?*anyopaque,
    action: c_int,
    first: [*c]const u8,
    second: [*c]const u8,
    _: [*c]const u8,
    _: [*c]const u8,
) callconv(.c) c_int {
    return authorize(action, first, second, false);
}

fn containedAuthorizer(
    _: ?*anyopaque,
    action: c_int,
    first: [*c]const u8,
    second: [*c]const u8,
    _: [*c]const u8,
    _: [*c]const u8,
) callconv(.c) c_int {
    return authorize(action, first, second, true);
}

fn authorize(
    action: c_int,
    first: [*c]const u8,
    second: [*c]const u8,
    contained: bool,
) c_int {
    if (action == c.SQLITE_ATTACH or action == c.SQLITE_DETACH)
        return c.SQLITE_DENY;
    if (contained and (action == c.SQLITE_TRANSACTION or
        action == c.SQLITE_SAVEPOINT)) return c.SQLITE_DENY;
    if (temporarySchemaOperation(action)) return c.SQLITE_DENY;
    if (action == c.SQLITE_PRAGMA and second != null) {
        const name = if (first != null) std.mem.span(first) else "";
        for (owned_pragmas) |owned| {
            if (std.ascii.eqlIgnoreCase(name, owned)) return c.SQLITE_DENY;
        }
    }
    return c.SQLITE_OK;
}

fn temporarySchemaOperation(action: c_int) bool {
    return (action >= c.SQLITE_CREATE_TEMP_INDEX and
        action <= c.SQLITE_CREATE_TEMP_VIEW) or
        (action >= c.SQLITE_DROP_TEMP_INDEX and
            action <= c.SQLITE_DROP_TEMP_VIEW);
}

const owned_pragmas = [_][]const u8{
    "user_version",
    "schema_version",
    "writable_schema",
    "query_only",
    "journal_mode",
    "synchronous",
    "locking_mode",
    "foreign_keys",
    "defer_foreign_keys",
    "busy_timeout",
    "wal_autocheckpoint",
    "temp_store",
    "temp_store_directory",
    "data_store_directory",
};

fn sqlFailure(result: c_int) SqlError {
    return switch (result & 0xff) {
        c.SQLITE_NOMEM => error.NoMemory,
        c.SQLITE_BUSY, c.SQLITE_LOCKED => error.Busy,
        c.SQLITE_CONSTRAINT => error.Constraint,
        c.SQLITE_CORRUPT, c.SQLITE_NOTADB => error.Corrupt,
        c.SQLITE_IOERR, c.SQLITE_FULL, c.SQLITE_READONLY, c.SQLITE_CANTOPEN, c.SQLITE_PERM => error.IoFailed,
        c.SQLITE_TOOBIG => error.Rejected,
        else => error.Misuse,
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
        error.NoMemory => error.OutOfMemory,
        error.Busy => error.Busy,
        error.Corrupt => error.Corrupt,
        error.IoFailed => error.PathUnavailable,
        else => error.OpenFailed,
    };
}

fn migrationFailure(err: SqlError) OpenError {
    return switch (err) {
        error.NoMemory => error.OutOfMemory,
        error.Busy => error.Busy,
        error.Corrupt => error.Corrupt,
        else => error.MigrationFailed,
    };
}

fn queryFailure(err: SqlError) sql.QueryOutcome {
    return switch (err) {
        error.Busy => .busy,
        error.Corrupt => .corrupt,
        error.NoMemory, error.IoFailed => .io_failed,
        error.Rejected => .rejected,
        error.Constraint, error.Misuse => .misuse,
    };
}

fn execFailure(err: SqlError) sql.ExecOutcome {
    return switch (err) {
        error.Constraint => .constraint,
        error.Busy => .busy,
        error.Corrupt => .corrupt,
        error.NoMemory, error.IoFailed => .io_failed,
        error.Rejected => .rejected,
        error.Misuse => .misuse,
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

test "memory database uses one connection and passes backend conformance" {
    var database = try Database.open(
        std.testing.allocator,
        .memory,
        &test_migrations,
    );
    defer database.deinit();
    try std.testing.expectEqual(@as(u32, 1), database.schemaVersion());
    try conformance.expectBackendContract(database.capability());
}

test "file database persists rows and migration version across reopen" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var directory_storage: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temporary.dir.realPath(
        std.testing.io,
        &directory_storage,
    );
    const path = try std.fs.path.join(
        std.testing.allocator,
        &.{ directory_storage[0..directory_len], "storage.db" },
    );
    defer std.testing.allocator.free(path);

    {
        var database = try Database.open(
            std.testing.allocator,
            .{ .file = path },
            &test_migrations,
        );
        defer database.deinit();
        try conformance.expectBackendContract(database.capability());
    }
    {
        var database = try Database.open(
            std.testing.allocator,
            .{ .file = path },
            &test_migrations,
        );
        defer database.deinit();
        var count: i64 = 0;
        const receiver: sql.RowReceiver = .{
            .context = &count,
            .receive_fn = struct {
                fn receive(context: *anyopaque, row: sql.Row) void {
                    const output: *i64 = @ptrCast(@alignCast(context));
                    output.* = row.value(0).integer;
                }
            }.receive,
        };
        try std.testing.expectEqual(
            sql.QueryOutcome.ok,
            database.capability().query(
                "SELECT COUNT(*) FROM storage_conformance",
                &.{},
                receiver,
            ),
        );
        try std.testing.expectEqual(@as(i64, 1), count);
    }
    try std.testing.expectError(
        error.VersionUnknown,
        Database.open(std.testing.allocator, .{ .file = path }, &.{}),
    );
}

test "failed migration rolls back schema and user version" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var directory_storage: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temporary.dir.realPath(
        std.testing.io,
        &directory_storage,
    );
    const path = try std.fs.path.join(
        std.testing.allocator,
        &.{ directory_storage[0..directory_len], "migration.db" },
    );
    defer std.testing.allocator.free(path);

    try std.testing.expectError(
        error.MigrationFailed,
        Database.open(std.testing.allocator, .{ .file = path }, &.{
            .{ .version = 1, .name = "first", .sql = "CREATE TABLE first(id INTEGER);" },
            .{ .version = 2, .name = "broken", .sql = "THIS IS NOT SQL;" },
        }),
    );
    const recovered_migrations = [_]sql.Migration{.{
        .version = 1,
        .name = "same first table proves rollback",
        .sql = "CREATE TABLE first(id INTEGER);",
    }};
    var database = try Database.open(
        std.testing.allocator,
        .{ .file = path },
        &recovered_migrations,
    );
    defer database.deinit();
    try std.testing.expectEqual(@as(u32, 1), database.schemaVersion());
}

test "file engine profile is observable and protected" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var directory_storage: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temporary.dir.realPath(
        std.testing.io,
        &directory_storage,
    );
    const path = try std.fs.path.join(
        std.testing.allocator,
        &.{ directory_storage[0..directory_len], "profile.db" },
    );
    defer std.testing.allocator.free(path);
    var database = try Database.open(
        std.testing.allocator,
        .{ .file = path },
        &test_migrations,
    );
    defer database.deinit();

    try expectTextPragma(&database.writer, "PRAGMA journal_mode;", "wal");
    try expectIntegerPragma(&database.writer, "PRAGMA synchronous;", 1);
    try expectIntegerPragma(&database.writer, "PRAGMA foreign_keys;", 1);
    try expectIntegerPragma(&database.reader.?, "PRAGMA query_only;", 1);
    var ignored = false;
    try std.testing.expectEqual(
        sql.QueryOutcome.misuse,
        database.capability().query("PRAGMA synchronous=FULL;", &.{}, .{
            .context = &ignored,
            .receive_fn = struct {
                fn receive(_: *anyopaque, _: sql.Row) void {}
            }.receive,
        }),
    );
}

test "file target must be an absolute UTF-8 path" {
    try std.testing.expectError(
        error.InvalidTarget,
        Database.open(std.testing.allocator, .{ .file = "relative.db" }, &.{}),
    );
}

test "busy and corrupt failures remain distinct" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var directory_storage: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temporary.dir.realPath(
        std.testing.io,
        &directory_storage,
    );
    const path = try std.fs.path.join(
        std.testing.allocator,
        &.{ directory_storage[0..directory_len], "busy.db" },
    );
    defer std.testing.allocator.free(path);
    var first = try Database.open(
        std.testing.allocator,
        .{ .file = path },
        &test_migrations,
    );
    defer first.deinit();
    var second = try Database.open(
        std.testing.allocator,
        .{ .file = path },
        &test_migrations,
    );
    defer second.deinit();
    try first.writer.execRaw("BEGIN IMMEDIATE;");
    defer first.writer.execRaw("ROLLBACK;") catch {};
    try std.testing.expectEqual(
        sql.ExecOutcome.busy,
        second.capability().exec(&.{.{
            .sql = "INSERT INTO storage_conformance(id) VALUES (9)",
        }}),
    );

    const corrupt_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ directory_storage[0..directory_len], "corrupt.db" },
    );
    defer std.testing.allocator.free(corrupt_path);
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "corrupt.db",
        .data = "not a sqlite database",
    });
    try std.testing.expectError(
        error.Corrupt,
        Database.open(
            std.testing.allocator,
            .{ .file = corrupt_path },
            &test_migrations,
        ),
    );
}

test "sandbox and statement shape cannot escape an exec transaction" {
    var database = try Database.open(
        std.testing.allocator,
        .memory,
        &test_migrations,
    );
    defer database.deinit();
    const capability = database.capability();
    try std.testing.expectEqual(
        sql.ExecOutcome.misuse,
        capability.exec(&.{.{ .sql = "ATTACH DATABASE ':memory:' AS other" }}),
    );
    try std.testing.expectEqual(
        sql.ExecOutcome.misuse,
        capability.exec(&.{.{ .sql = "COMMIT" }}),
    );
    try std.testing.expectEqual(
        sql.ExecOutcome.misuse,
        capability.exec(&.{.{
            .sql = "INSERT INTO storage_conformance(id) VALUES (11) RETURNING id",
        }}),
    );
    var count: i64 = -1;
    try std.testing.expectEqual(
        sql.QueryOutcome.ok,
        capability.query(
            "SELECT COUNT(*) FROM storage_conformance WHERE id = 11",
            &.{},
            .{
                .context = &count,
                .receive_fn = struct {
                    fn receive(context: *anyopaque, row: sql.Row) void {
                        const output: *i64 = @ptrCast(@alignCast(context));
                        output.* = row.value(0).integer;
                    }
                }.receive,
            },
        ),
    );
    try std.testing.expectEqual(@as(i64, 0), count);
    try std.testing.expectEqual(
        sql.QueryOutcome.misuse,
        capability.query("SELECT CAST(X'FF' AS TEXT)", &.{}, .{
            .context = &count,
            .receive_fn = struct {
                fn receive(_: *anyopaque, _: sql.Row) void {}
            }.receive,
        }),
    );
}

test "query result limits reject instead of truncating to success" {
    var database = try Database.open(
        std.testing.allocator,
        .memory,
        &test_migrations,
    );
    defer database.deinit();
    const capability = database.capability();
    var rows: usize = 0;
    const receiver: sql.RowReceiver = .{
        .context = &rows,
        .receive_fn = struct {
            fn receive(context: *anyopaque, _: sql.Row) void {
                const output: *usize = @ptrCast(@alignCast(context));
                output.* += 1;
            }
        }.receive,
    };
    try std.testing.expectEqual(
        sql.QueryOutcome.rejected,
        capability.query(
            \\WITH RECURSIVE values_(value) AS (
            \\  VALUES(1) UNION ALL SELECT value + 1 FROM values_ WHERE value < 8193
            \\) SELECT value FROM values_
        , &.{}, receiver),
    );
    try std.testing.expectEqual(sql.Limits.result_rows, rows);

    rows = 0;
    try std.testing.expectEqual(
        sql.QueryOutcome.rejected,
        capability.query("SELECT zeroblob(8388609)", &.{}, receiver),
    );
    try std.testing.expectEqual(@as(usize, 0), rows);
}

fn expectTextPragma(
    connection: *Connection,
    text: []const u8,
    expected: []const u8,
) !void {
    const statement = try prepareOne(connection, text);
    defer _ = c.sqlite3_finalize(statement);
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(statement));
    try std.testing.expect(std.ascii.eqlIgnoreCase(
        columnText(statement, 0),
        expected,
    ));
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
