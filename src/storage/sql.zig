//! Stable SQL contract shared by concrete storage backends and Product owners.
//! Physical database ownership, schema content, and recovery policy stay out of
//! this module.

const std = @import("std");

pub const Limits = struct {
    pub const sql_bytes: usize = 64 * 1024;
    pub const parameters: usize = 64;
    pub const exec_statements: usize = 128;
    pub const exec_chunks: usize = 128;
    pub const query_parameter_bytes: usize = 1024 * 1024;
    pub const exec_parameter_bytes: usize = 32 * 1024 * 1024;
    pub const result_rows: usize = 8 * 1024;
    pub const result_bytes: usize = 32 * 1024 * 1024;
    pub const migrations: usize = 9999;
    pub const migration_bytes: usize = 1024 * 1024;
};

pub const Value = union(enum) {
    null_value,
    integer: i64,
    real: f64,
    text: []const u8,
    blob: []const u8,
};

pub const Statement = struct {
    sql: []const u8,
    params: []const Value = &.{},
};

pub const ChangeExpectation = union(enum) {
    any,
    exactly: u64,
};

pub const Mutation = struct {
    statement: Statement,
    expected_changes: ChangeExpectation = .any,
};

pub const Migration = struct {
    version: u32,
    name: []const u8,
    sql: []const u8,
};

/// A row and all slices returned from it are borrowed for the duration of one
/// synchronous RowReceiver callback. Every index must be less than
/// columnCount().
pub const Row = struct {
    context: *anyopaque,
    column_count: usize,
    column_name_fn: *const fn (context: *anyopaque, index: usize) []const u8,
    value_fn: *const fn (context: *anyopaque, index: usize) Value,

    pub fn columnCount(self: Row) usize {
        return self.column_count;
    }

    pub fn columnName(self: Row, index: usize) []const u8 {
        std.debug.assert(index < self.column_count);
        return self.column_name_fn(self.context, index);
    }

    pub fn value(self: Row, index: usize) Value {
        std.debug.assert(index < self.column_count);
        return self.value_fn(self.context, index);
    }
};

pub const RowReceiver = struct {
    context: *anyopaque,
    receive_fn: *const fn (context: *anyopaque, row: Row) void,

    pub fn receive(self: RowReceiver, row: Row) void {
        self.receive_fn(self.context, row);
    }
};

pub const QueryOutcome = enum {
    ok,
    busy,
    cancelled,
    corrupt,
    rejected,
    resource_exhausted,
    definite_io_failure,
    unavailable,
};

pub const MutationOutcome = enum {
    committed,
    conflict,
    constraint,
    busy,
    cancelled,
    corrupt,
    rejected,
    resource_exhausted,
    definite_io_failure,
    outcome_unknown,
    unavailable,
};

/// Physical durability/cleanup only. Neither operation changes logical rows.
/// `confirm` synchronizes the current committed state; `purge` additionally
/// removes older WAL frames. Callers still own witness checks and secret leases.
pub const Maintenance = enum { confirm, purge };

/// Borrowed capability. The concrete backend instance and every resource it
/// owns must outlive this value and all synchronous calls made through it.
///
/// A RowReceiver may call another Database, but must not directly or
/// indirectly call query or mutate on the Database currently dispatching it.
/// An otherwise valid nested call returns rejected. Calls from other threads
/// block without spinning and execute serially; local contention is not busy.
pub const Database = struct {
    context: *anyopaque,
    query_fn: *const fn (
        context: *anyopaque,
        sql_text: []const u8,
        params: []const Value,
        receiver: RowReceiver,
    ) QueryOutcome,
    mutate_fn: *const fn (
        context: *anyopaque,
        mutations: []const Mutation,
    ) MutationOutcome,
    maintain_fn: *const fn (context: *anyopaque, operation: Maintenance) QueryOutcome,
    mutate_chunks_fn: ?*const fn (context: *anyopaque, chunks: []const []const Mutation) MutationOutcome = null,

    pub fn query(
        self: Database,
        sql_text: []const u8,
        params: []const Value,
        receiver: RowReceiver,
    ) QueryOutcome {
        if (!validSql(sql_text) or
            !validParameters(params, Limits.query_parameter_bytes))
            return .rejected;
        return self.query_fn(self.context, sql_text, params, receiver);
    }

    /// The complete batch is one transaction. Each statement must be DML that
    /// produces no row. Every exact change expectation is checked inside that
    /// transaction; a mismatch returns conflict and rolls the batch back.
    pub fn mutate(self: Database, mutations: []const Mutation) MutationOutcome {
        if (!validMutations(mutations)) return .rejected;
        return self.mutate_fn(self.context, mutations);
    }

    /// Bounded input chunks, one transaction and one final outcome. This does
    /// not expose a transaction handle or permit partial acknowledgement.
    pub fn mutateChunks(self: Database, chunks: []const []const Mutation) MutationOutcome {
        if (chunks.len == 0 or chunks.len > Limits.exec_chunks) return .rejected;
        for (chunks) |chunk| if (!validMutations(chunk)) return .rejected;
        if (self.mutate_chunks_fn) |mutate_chunks| return mutate_chunks(self.context, chunks);
        if (chunks.len == 1) return self.mutate_fn(self.context, chunks[0]);
        return .rejected;
    }

    pub fn maintain(self: Database, operation: Maintenance) QueryOutcome {
        return self.maintain_fn(self.context, operation);
    }
};

pub fn validSql(sql_text: []const u8) bool {
    return sql_text.len > 0 and sql_text.len <= Limits.sql_bytes and
        std.mem.indexOfScalar(u8, sql_text, 0) == null;
}

pub fn validParameters(params: []const Value, byte_limit: usize) bool {
    if (params.len > Limits.parameters) return false;
    return (parameterBytes(params, 0) orelse return false) <= byte_limit;
}

pub fn validMutations(mutations: []const Mutation) bool {
    if (mutations.len == 0 or mutations.len > Limits.exec_statements)
        return false;
    var parameter_bytes: usize = 0;
    for (mutations) |mutation| {
        const statement = mutation.statement;
        if (!validSql(statement.sql) or statement.params.len > Limits.parameters)
            return false;
        parameter_bytes = parameterBytes(statement.params, parameter_bytes) orelse
            return false;
        if (parameter_bytes > Limits.exec_parameter_bytes) return false;
    }
    return true;
}

pub fn validMigrations(migrations: []const Migration) bool {
    if (migrations.len > Limits.migrations) return false;
    var expected: u32 = 1;
    for (migrations) |migration| {
        if (migration.version != expected or migration.name.len == 0 or
            std.mem.indexOfScalar(u8, migration.name, 0) != null or
            !validMigrationSql(migration.sql)) return false;
        expected += 1;
    }
    return true;
}

fn validMigrationSql(sql_text: []const u8) bool {
    return sql_text.len > 0 and sql_text.len <= Limits.migration_bytes and
        std.mem.indexOfScalar(u8, sql_text, 0) == null;
}

fn parameterBytes(params: []const Value, initial: usize) ?usize {
    var total = initial;
    for (params) |value| switch (value) {
        .text => |bytes| {
            if (!std.unicode.utf8ValidateSlice(bytes)) return null;
            if (std.mem.indexOfScalar(u8, bytes, 0) != null) return null;
            total = std.math.add(usize, total, bytes.len) catch return null;
        },
        .blob => |bytes| total = std.math.add(usize, total, bytes.len) catch
            return null,
        .real => |number| if (!std.math.isFinite(number)) return null,
        else => {},
    };
    return total;
}
