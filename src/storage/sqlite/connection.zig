//! SQLite C boundary: connection ownership, profile, prepare/bind/row access,
//! authorizers, limits, and raw error classification.

const std = @import("std");
const sql = @import("../sql.zig");

pub const c = @cImport({
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

pub const migration_table = "_metawork_storage_migrations";

pub const OpenError = error{
    OutOfMemory,
    StorageFull,
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

pub const SqlError = error{
    OutOfMemory,
    TooBig,
    StorageFull,
    ResourceExhausted,
    Busy,
    Constraint,
    Corrupt,
    IoFailed,
    Cancelled,
    Rejected,
};

pub const Connection = struct {
    handle: *c.sqlite3,

    pub fn open(path: [:0]const u8) OpenError!Connection {
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

    pub fn close(self: *Connection) void {
        std.debug.assert(c.sqlite3_close_v2(self.handle) == c.SQLITE_OK);
    }

    pub fn execRaw(self: *Connection, text: [*:0]const u8) SqlError!void {
        const result = c.sqlite3_exec(self.handle, text, null, null, null);
        if (result != c.SQLITE_OK) return sqlFailure(result);
    }

    pub fn setAuthorizer(self: *Connection, callback: Authorizer) SqlError!void {
        const result = c.sqlite3_set_authorizer(self.handle, callback, null);
        if (result != c.SQLITE_OK) return sqlFailure(result);
    }

    /// Used only after a failed statement or a failed COMMIT with an active
    /// transaction. SQLite may already have rolled a statement's transaction
    /// back (OR ROLLBACK, interrupt, or resource errors).
    pub fn rollbackConfirmed(self: *Connection) bool {
        if (c.sqlite3_get_autocommit(self.handle) != 0) return true;
        self.setAuthorizer(internalTransactionAuthorizer) catch return false;
        self.execRaw("ROLLBACK;") catch return false;
        return c.sqlite3_get_autocommit(self.handle) != 0;
    }
};

pub fn initialize(connection: *Connection, durable: bool) OpenError!void {
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

pub fn setTextPragma(
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

pub fn prepareOne(connection: *Connection, text: []const u8) SqlError!*c.sqlite3_stmt {
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

pub fn bindAll(statement: *c.sqlite3_stmt, params: []const sql.Value) SqlError!void {
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

pub fn rowBytes(
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
                if (std.mem.indexOfScalar(u8, value, 0) != null) return error.Rejected;
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

pub fn columnValue(statement: *c.sqlite3_stmt, index: usize) sql.Value {
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

pub fn columnName(statement: *c.sqlite3_stmt, index: usize) []const u8 {
    const pointer = c.sqlite3_column_name(statement, @intCast(index)) orelse
        return "";
    return std.mem.span(pointer);
}

pub fn columnText(statement: *c.sqlite3_stmt, index: usize) []const u8 {
    const column: c_int = @intCast(index);
    const length = c.sqlite3_column_bytes(statement, column);
    if (length <= 0) return "";
    const pointer = c.sqlite3_column_text(statement, column) orelse return "";
    return pointer[0..@intCast(length)];
}

pub fn columnBlob(statement: *c.sqlite3_stmt, index: usize) []const u8 {
    const column: c_int = @intCast(index);
    const length = c.sqlite3_column_bytes(statement, column);
    if (length <= 0) return "";
    const raw = c.sqlite3_column_blob(statement, column) orelse return "";
    const pointer: [*]const u8 = @ptrCast(raw);
    return pointer[0..@intCast(length)];
}

pub fn parameterCount(statement: *c.sqlite3_stmt) usize {
    return @intCast(c.sqlite3_bind_parameter_count(statement));
}

const Authority = enum { deny_all, query, mutation, migration, metadata, transaction };

pub fn denyAllAuthorizer(_: ?*anyopaque, action: c_int, first: [*c]const u8, second: [*c]const u8, database: [*c]const u8, _: [*c]const u8) callconv(.c) c_int {
    return authorize(.deny_all, action, first, second, database);
}

pub fn queryAuthorizer(_: ?*anyopaque, action: c_int, first: [*c]const u8, second: [*c]const u8, database: [*c]const u8, _: [*c]const u8) callconv(.c) c_int {
    return authorize(.query, action, first, second, database);
}

pub fn mutationAuthorizer(_: ?*anyopaque, action: c_int, first: [*c]const u8, second: [*c]const u8, database: [*c]const u8, _: [*c]const u8) callconv(.c) c_int {
    return authorize(.mutation, action, first, second, database);
}

pub fn migrationAuthorizer(_: ?*anyopaque, action: c_int, first: [*c]const u8, second: [*c]const u8, database: [*c]const u8, _: [*c]const u8) callconv(.c) c_int {
    return authorize(.migration, action, first, second, database);
}

pub fn metadataAuthorizer(_: ?*anyopaque, action: c_int, first: [*c]const u8, second: [*c]const u8, database: [*c]const u8, source: [*c]const u8) callconv(.c) c_int {
    // Metadata statements are authored here, never by a stored trigger/view.
    if (source != null) return c.SQLITE_DENY;
    return authorize(.metadata, action, first, second, database);
}

pub fn internalTransactionAuthorizer(_: ?*anyopaque, action: c_int, first: [*c]const u8, second: [*c]const u8, database: [*c]const u8, _: [*c]const u8) callconv(.c) c_int {
    return authorize(.transaction, action, first, second, database);
}

fn authorize(authority: Authority, action: c_int, first: [*c]const u8, second: [*c]const u8, database: [*c]const u8) c_int {
    if (authority == .deny_all) return c.SQLITE_DENY;
    if (action == c.SQLITE_ATTACH or action == c.SQLITE_DETACH or
        action == c.SQLITE_SAVEPOINT or action == c.SQLITE_PRAGMA or
        temporarySchemaOperation(action))
        return c.SQLITE_DENY;
    if (action == c.SQLITE_TRANSACTION)
        return if (authority == .transaction) c.SQLITE_OK else c.SQLITE_DENY;
    if (authority == .transaction) return c.SQLITE_DENY;
    // ALTER_TABLE supplies its schema in first; database may instead name
    // the altered column. Its target is checked by the migration rule below.
    if (action != c.SQLITE_ALTER_TABLE and database != null) {
        const name = std.mem.span(database);
        if (name.len != 0 and !std.ascii.eqlIgnoreCase(name, "main"))
            return c.SQLITE_DENY;
    }
    const object = if (first == null) "" else std.mem.span(first);
    const related = if (second == null) "" else std.mem.span(second);
    if (authority == .migration) {
        // SQLite action arguments have different meanings. In particular,
        // indexes/triggers and ALTER name their table in the second argument.
        const allowed = switch (action) {
            c.SQLITE_SELECT, c.SQLITE_FUNCTION, c.SQLITE_RECURSIVE => true,
            c.SQLITE_CREATE_INDEX,
            c.SQLITE_DROP_INDEX,
            c.SQLITE_CREATE_TRIGGER,
            c.SQLITE_DROP_TRIGGER,
            => !isMetadata(object) and !isMetadata(related),
            c.SQLITE_ALTER_TABLE => std.ascii.eqlIgnoreCase(object, "main") and
                related.len != 0 and !isMetadata(related),
            c.SQLITE_READ,
            c.SQLITE_INSERT,
            c.SQLITE_UPDATE,
            c.SQLITE_DELETE,
            c.SQLITE_CREATE_TABLE,
            c.SQLITE_DROP_TABLE,
            c.SQLITE_CREATE_VIEW,
            c.SQLITE_DROP_VIEW,
            c.SQLITE_CREATE_VTABLE,
            c.SQLITE_DROP_VTABLE,
            c.SQLITE_REINDEX,
            c.SQLITE_ANALYZE,
            => !isMetadata(object),
            else => false,
        };
        return if (allowed) c.SQLITE_OK else c.SQLITE_DENY;
    }
    if (authority == .metadata) {
        const allowed = switch (action) {
            c.SQLITE_SELECT => true,
            c.SQLITE_CREATE_TABLE => isMetadata(object),
            c.SQLITE_READ, c.SQLITE_INSERT => isMetadata(object) or isCatalog(object),
            c.SQLITE_UPDATE => isCatalog(object), // SQLite's CREATE TABLE bookkeeping.
            c.SQLITE_FUNCTION => std.ascii.eqlIgnoreCase(related, "length"),
            else => false,
        };
        return if (allowed) c.SQLITE_OK else c.SQLITE_DENY;
    }
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
        .deny_all, .transaction, .migration, .metadata => c.SQLITE_DENY,
    };
}

fn isMetadata(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, migration_table);
}

fn isCatalog(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "sqlite_master") or
        std.ascii.eqlIgnoreCase(name, "sqlite_schema");
}

fn protectedObject(name: []const u8) bool {
    return isMetadata(name) or isCatalog(name);
}

fn temporarySchemaOperation(action: c_int) bool {
    return (action >= c.SQLITE_CREATE_TEMP_INDEX and
        action <= c.SQLITE_CREATE_TEMP_VIEW) or
        (action >= c.SQLITE_DROP_TEMP_INDEX and
            action <= c.SQLITE_DROP_TEMP_VIEW);
}

pub fn sqlFailure(result: c_int) SqlError {
    return switch (result & 0xff) {
        c.SQLITE_NOMEM => error.OutOfMemory,
        c.SQLITE_TOOBIG => error.TooBig,
        c.SQLITE_FULL => error.StorageFull,
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

pub fn initializeFailure(err: SqlError) OpenError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.StorageFull => error.StorageFull,
        error.Busy => error.Busy,
        error.Corrupt => error.Corrupt,
        error.IoFailed => error.PathUnavailable,
        else => error.ProfileMismatch,
    };
}
