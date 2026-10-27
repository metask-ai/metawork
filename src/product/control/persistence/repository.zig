//! Atomic, row-differential history commits. The caller serializes access and
//! owns the concrete Database lifecycle; this owner never opens SQLite itself.
const std = @import("std");
const schema = @import("schema.zig");
const sql = schema.sql;
const codec = schema.codec;
const wire = codec.wire;

pub const Witness = struct {
    generation: u64 = 0,
    digest: [32]u8 = @splat(0),
    pub fn eql(a: Witness, b: Witness) bool {
        return a.generation == b.generation and std.mem.eql(u8, &a.digest, &b.digest);
    }
};

const Entry = struct {
    table: []const u8,
    names: []const []const u8,
    primary: []const sql.Value,
    digest: [32]u8,
};

const Index = struct {
    arena: std.heap.ArenaAllocator,
    entries: std.StringHashMapUnmanaged(Entry) = .empty,
    fn create(allocator: std.mem.Allocator, rows: []const codec.Row) !*Index {
        const self = try allocator.create(Index);
        self.* = .{ .arena = .init(allocator) };
        errdefer {
            self.arena.deinit();
            allocator.destroy(self);
        }
        const a = self.arena.allocator();
        try self.entries.ensureTotalCapacity(a, @intCast(rows.len));
        for (rows) |row| {
            const names = try a.alloc([]const u8, row.primary.len);
            const primary = try a.alloc(sql.Value, row.primary.len);
            for (row.primary, 0..) |field, i| {
                names[i] = row.columns[field];
                primary[i] = try copyValue(a, row.values[field]);
            }
            self.entries.putAssumeCapacity(try a.dupe(u8, row.key), .{ .table = row.table, .names = names, .primary = primary, .digest = row.digest });
        }
        return self;
    }
    fn deinit(self: *Index) void {
        const a = self.arena.child_allocator;
        self.arena.deinit();
        a.destroy(self);
    }
};

fn copyValue(a: std.mem.Allocator, value: sql.Value) !sql.Value {
    return switch (value) {
        .blob => |v| .{ .blob = try a.dupe(u8, v) },
        .text => |v| .{ .text = try a.dupe(u8, v) },
        else => value,
    };
}

// JSON is only a bounded transport for a set-based typed INSERT/DELETE.
// BLOB values retain their byte identity through SQLite's unhex(), including
// unsigned ids and NUL. No JSON is stored in place of a whole history file.
const Cell = struct {
    value: sql.Value,
    hex: []const u8 = "",
    fn init(a: std.mem.Allocator, value: sql.Value) !Cell {
        var result = Cell{ .value = value };
        if (value == .blob) {
            const hex = try a.alloc(u8, value.blob.len * 2);
            const digits = "0123456789abcdef";
            for (value.blob, 0..) |b, i| {
                hex[i * 2] = digits[b >> 4];
                hex[i * 2 + 1] = digits[b & 15];
            }
            result.hex = hex;
        }
        return result;
    }
    pub fn jsonStringify(self: Cell, out: anytype) !void {
        try out.beginArray();
        try out.write(@intFromEnum(std.meta.activeTag(self.value)));
        switch (self.value) {
            .null_value => try out.write(@as(?u8, null)),
            .integer => |v| try out.write(v),
            .real => |v| try out.write(v),
            .text => |v| try out.write(v),
            .blob => try out.write(self.hex),
        }
        try out.endArray();
    }
};

fn cells(a: std.mem.Allocator, values: []const sql.Value) ![]const Cell {
    const result = try a.alloc(Cell, values.len);
    for (values, 0..) |v, i| result[i] = try Cell.init(a, v);
    return result;
}

fn expression(a: std.mem.Allocator, index: usize) ![]const u8 {
    return std.fmt.allocPrint(a, "CASE json_extract(j.value,'$[{d}][0]') WHEN {d} THEN unhex(json_extract(j.value,'$[{d}][1]')) ELSE json_extract(j.value,'$[{d}][1]') END", .{ index, @intFromEnum(std.meta.Tag(sql.Value).blob), index, index });
}

fn join(a: std.mem.Allocator, values: []const []const u8, separator: []const u8) ![]const u8 {
    return std.mem.join(a, separator, values);
}

fn insertGroup(a: std.mem.Allocator, rows: []const codec.Row) !sql.Mutation {
    const first = rows[0];
    const encoded = try a.alloc([]const Cell, rows.len);
    for (rows, 0..) |row, i| encoded[i] = try cells(a, row.values);
    const expressions = try a.alloc([]const u8, first.columns.len);
    const updates = try a.alloc([]const u8, first.columns.len);
    for (first.columns, 0..) |name, i| {
        expressions[i] = try expression(a, i);
        updates[i] = try std.fmt.allocPrint(a, "{s}=excluded.{s}", .{ name, name });
    }
    const primary = try a.alloc([]const u8, first.primary.len);
    for (first.primary, 0..) |field, i| primary[i] = first.columns[field];
    const text = try std.fmt.allocPrint(a, "INSERT INTO {s}({s}) SELECT {s} FROM json_each(?1) AS j WHERE 1 ON CONFLICT({s}) DO UPDATE SET {s}", .{ first.table, try join(a, first.columns, ","), try join(a, expressions, ","), try join(a, primary, ","), try join(a, updates, ",") });
    return .{ .statement = .{ .sql = text, .params = try a.dupe(sql.Value, &.{.{ .text = try std.json.Stringify.valueAlloc(a, encoded, .{}) }}) } };
}

fn deleteGroup(a: std.mem.Allocator, entries: []const Entry) !sql.Mutation {
    const first = entries[0];
    const encoded = try a.alloc([]const Cell, entries.len);
    for (entries, 0..) |entry, i| encoded[i] = try cells(a, entry.primary);
    const predicates = try a.alloc([]const u8, first.names.len);
    for (first.names, 0..) |name, i| predicates[i] = try std.fmt.allocPrint(a, "t.{s}={s}", .{ name, try expression(a, i) });
    const text = try std.fmt.allocPrint(a, "DELETE FROM {s} AS t WHERE EXISTS(SELECT 1 FROM json_each(?1) AS j WHERE {s})", .{ first.table, try join(a, predicates, " AND ") });
    return .{ .statement = .{ .sql = text, .params = try a.dupe(sql.Value, &.{.{ .text = try std.json.Stringify.valueAlloc(a, encoded, .{}) }}) } };
}

// Parent order is also the inverse physical-delete order.
const tables = [_][]const u8{ "history_state", "workspaces", "tasks", "runs", "run_tools", "run_file_changes", "task_compacts", "task_ui_history", "task_input_submissions", "run_additional_inputs", "retained_records" };

pub const Prepared = struct {
    arena: *std.heap.ArenaAllocator,
    next_index: ?*Index,
    previous: Witness,
    next: Witness,
    mutations: []const sql.Mutation,
    changed_rows: usize,
    deleted_rows: usize,
    pub fn deinit(self: *Prepared) void {
        const a = self.arena.child_allocator;
        if (self.next_index) |index| index.deinit();
        self.arena.deinit();
        a.destroy(self.arena);
        self.* = undefined;
    }
};

pub const Repository = struct {
    allocator: std.mem.Allocator,
    database: sql.Database,
    limits: wire.Limits,
    index: ?*Index = null,
    witness: Witness = .{},
    pub fn init(a: std.mem.Allocator, database: sql.Database, limits: wire.Limits) Repository {
        return .{ .allocator = a, .database = database, .limits = limits };
    }
    pub fn deinit(self: *Repository) void {
        if (self.index) |index| index.deinit();
        self.index = null;
    }

    pub fn seed(self: *Repository, state: wire.StateWire, preserved: wire.PreservedFrames) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const rows = try codec.rowsFor(arena.allocator(), state, preserved, self.limits);
        const index = try Index.create(self.allocator, rows);
        errdefer index.deinit();
        const witness = try readWitness(self.database);
        if (self.index) |old| old.deinit();
        self.index = index;
        self.witness = witness;
    }

    pub fn prepare(self: *Repository, state: wire.StateWire, preserved: wire.PreservedFrames, digest: [32]u8) !Prepared {
        const arena = try self.allocator.create(std.heap.ArenaAllocator);
        arena.* = .init(self.allocator);
        errdefer {
            arena.deinit();
            self.allocator.destroy(arena);
        }
        const a = arena.allocator();
        const rows = try codec.rowsFor(a, state, preserved, self.limits);
        const next_index = try Index.create(self.allocator, rows);
        errdefer next_index.deinit();
        var mutations: std.ArrayList(sql.Mutation) = .empty;
        var changed: usize = 0;
        var deleted: usize = 0;
        var reverse: usize = tables.len;
        while (reverse != 0) {
            reverse -= 1;
            var missing: std.ArrayList(Entry) = .empty;
            if (self.index) |old| {
                var it = old.entries.iterator();
                while (it.next()) |entry| {
                    if (std.mem.eql(u8, entry.value_ptr.table, tables[reverse]) and !next_index.entries.contains(entry.key_ptr.*)) try missing.append(a, entry.value_ptr.*);
                }
            }
            if (missing.items.len != 0) {
                try mutations.append(a, try deleteGroup(a, missing.items));
                deleted += missing.items.len;
            }
        }
        for (tables) |table| {
            var group: std.ArrayList(codec.Row) = .empty;
            for (rows) |row| {
                if (!std.mem.eql(u8, row.table, table)) continue;
                if (self.index) |old| if (old.entries.get(row.key)) |entry| {
                    if (std.mem.eql(u8, &entry.digest, &row.digest)) continue;
                };
                // Opaque legacy payloads can approach 16MiB. Bind them as BLOB,
                // rather than doubling them through the bulk hex transport.
                if (std.mem.eql(u8, table, "retained_records")) {
                    try mutations.append(a, .{ .statement = .{ .sql = "INSERT INTO retained_records(kind,id,recent_order,payload) VALUES(?1,?2,?3,?4) ON CONFLICT(kind,id) DO UPDATE SET recent_order=excluded.recent_order,payload=excluded.payload", .params = try cloneValues(a, row.values) } });
                    changed += 1;
                } else try group.append(a, row);
            }
            if (group.items.len != 0) {
                try mutations.append(a, try insertGroup(a, group.items));
                changed += group.items.len;
            }
        }
        const next = Witness{ .generation = std.math.add(u64, self.witness.generation, 1) catch return error.GenerationExhausted, .digest = digest };
        const generation = try a.create([8]u8);
        std.mem.writeInt(u64, generation, next.generation, .big);
        const previous = try a.create([8]u8);
        std.mem.writeInt(u64, previous, self.witness.generation, .big);
        const next_digest = try a.dupe(u8, &next.digest);
        const previous_digest = try a.dupe(u8, &self.witness.digest);
        try mutations.append(a, .{ .statement = .{ .sql = "UPDATE history_state SET witness_generation=?1,witness_digest=?2 WHERE singleton=1 AND witness_generation=?3 AND witness_digest=?4", .params = try a.dupe(sql.Value, &.{ .{ .blob = generation }, .{ .blob = next_digest }, .{ .blob = previous }, .{ .blob = previous_digest } }) }, .expected_changes = .{ .exactly = 1 } });
        if (!sql.validMutations(mutations.items)) return error.AtomicGroupCapacity;
        return .{ .arena = arena, .next_index = next_index, .previous = self.witness, .next = next, .mutations = try mutations.toOwnedSlice(a), .changed_rows = changed, .deleted_rows = deleted };
    }

    pub fn commit(self: *Repository, prepared: *Prepared) sql.MutationOutcome {
        if (!Witness.eql(prepared.previous, self.witness)) return .conflict;
        const result = self.database.mutate(prepared.mutations);
        if (result == .committed) self.accept(prepared);
        return result;
    }

    pub fn resolve(self: *Repository, prepared: *Prepared) wire.Commit {
        const observed = readWitness(self.database) catch return .outcome_unknown;
        if (!Witness.eql(observed, prepared.next) and !Witness.eql(observed, prepared.previous)) return .outcome_unknown;
        if (self.database.maintain(.confirm) != .ok) return .outcome_unknown;
        const confirmed = readWitness(self.database) catch return .outcome_unknown;
        if (!Witness.eql(observed, confirmed)) return .outcome_unknown;
        if (Witness.eql(confirmed, prepared.next)) {
            self.accept(prepared);
            return .committed;
        }
        return .failed;
    }

    fn accept(self: *Repository, prepared: *Prepared) void {
        if (self.index) |old| old.deinit();
        self.index = prepared.next_index;
        prepared.next_index = null;
        self.witness = prepared.next;
    }
};

fn cloneValues(a: std.mem.Allocator, values: []const sql.Value) ![]const sql.Value {
    const result = try a.alloc(sql.Value, values.len);
    for (values, 0..) |v, i| result[i] = try copyValue(a, v);
    return result;
}

pub fn readWitness(database: sql.Database) !Witness {
    const Observation = struct {
        value: Witness = .{},
        count: usize = 0,
        invalid: bool = false,
        fn receive(context: *anyopaque, row: sql.Row) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.count += 1;
            const generation = row.value(0);
            const digest = row.value(1);
            if (generation != .blob or generation.blob.len != 8 or digest != .blob or digest.blob.len != 32) {
                self.invalid = true;
                return;
            }
            self.value.generation = std.mem.readInt(u64, generation.blob[0..8], .big);
            @memcpy(&self.value.digest, digest.blob);
        }
    };
    var observed: Observation = .{};
    if (database.query("SELECT witness_generation,witness_digest FROM history_state WHERE singleton=1", &.{}, .{ .context = &observed, .receive_fn = Observation.receive }) != .ok) return error.ReadFailed;
    if (observed.invalid or observed.count > 1) return error.Invalid;
    return observed.value;
}
