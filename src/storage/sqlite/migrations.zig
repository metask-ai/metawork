//! Storage-owned migration identity and atomic prefix application.

const std = @import("std");
const sql = @import("../sql.zig");
const backend = @import("connection.zig");

const c = backend.c;
const Connection = backend.Connection;

pub fn apply(
    allocator: std.mem.Allocator,
    connection: *Connection,
    migrations: []const sql.Migration,
) backend.OpenError!u32 {
    connection.setAuthorizer(backend.internalTransactionAuthorizer) catch |err|
        return migrationFailure(err);
    connection.execRaw("BEGIN IMMEDIATE;") catch |err|
        return migrationFailure(err);
    var transaction_active = true;
    errdefer if (transaction_active) rollback(connection);

    connection.setAuthorizer(backend.metadataAuthorizer) catch |err|
        return migrationFailure(err);
    connection.execRaw(
        "CREATE TABLE IF NOT EXISTS _metawork_storage_migrations(" ++ "version INTEGER PRIMARY KEY," ++ "name TEXT NOT NULL," ++ "checksum BLOB NOT NULL CHECK(length(checksum)=32));",
    ) catch |err| return migrationFailure(err);

    const persisted = try verifyPrefix(connection, migrations);
    for (migrations[persisted..]) |migration| {
        connection.setAuthorizer(backend.migrationAuthorizer) catch |err|
            return migrationFailure(err);
        const text = allocator.dupeZ(u8, migration.sql) catch
            return error.OutOfMemory;
        defer allocator.free(text);
        connection.execRaw(text) catch |err| return migrationFailure(err);

        connection.setAuthorizer(backend.metadataAuthorizer) catch |err|
            return migrationFailure(err);
        insertIdentity(connection, migration) catch |err|
            return migrationFailure(err);
    }

    connection.setAuthorizer(backend.internalTransactionAuthorizer) catch
        return error.MigrationOutcomeUnknown;
    connection.execRaw("COMMIT;") catch |err| {
        if (c.sqlite3_get_autocommit(connection.handle) != 0)
            return error.MigrationOutcomeUnknown;
        rollback(connection);
        return migrationFailure(err);
    };
    transaction_active = false;
    if (c.sqlite3_get_autocommit(connection.handle) == 0)
        return error.MigrationOutcomeUnknown;
    return @intCast(migrations.len);
}

fn verifyPrefix(
    connection: *Connection,
    migrations: []const sql.Migration,
) backend.OpenError!usize {
    const statement = backend.prepareOne(
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
            if (!std.mem.eql(u8, backend.columnText(statement, 1), migration.name))
                return error.MigrationMismatch;
            var expected: [32]u8 = undefined;
            checksum(migration, &expected);
            if (!std.mem.eql(u8, backend.columnBlob(statement, 2), &expected))
                return error.MigrationMismatch;
            persisted += 1;
        },
        else => |result| return migrationFailure(backend.sqlFailure(result)),
    };
}

fn insertIdentity(connection: *Connection, migration: sql.Migration) backend.SqlError!void {
    const statement = try backend.prepareOne(
        connection,
        "INSERT INTO _metawork_storage_migrations(version,name,checksum) VALUES(?,?,?)",
    );
    defer _ = c.sqlite3_finalize(statement);
    var digest: [32]u8 = undefined;
    checksum(migration, &digest);
    try backend.bindAll(statement, &.{
        .{ .integer = migration.version },
        .{ .text = migration.name },
        .{ .blob = &digest },
    });
    const result = c.sqlite3_step(statement);
    if (result != c.SQLITE_DONE) return backend.sqlFailure(result);
}

fn checksum(migration: sql.Migration, output: *[32]u8) void {
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

fn rollback(connection: *Connection) void {
    connection.setAuthorizer(backend.internalTransactionAuthorizer) catch return;
    connection.execRaw("ROLLBACK;") catch {};
}

fn migrationFailure(err: backend.SqlError) backend.OpenError {
    return switch (err) {
        error.ResourceExhausted => error.OutOfMemory,
        error.Busy => error.Busy,
        error.Corrupt => error.Corrupt,
        else => error.MigrationFailed,
    };
}
