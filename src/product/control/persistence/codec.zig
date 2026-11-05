//! Product-owned typed history row codec. Database ownership belongs to Application.
const std = @import("std");
const sql = @import("schema.zig").sql;
pub const wire = @import("product_task_persistence");

fn validateState(allocator: std.mem.Allocator, state: wire.StateWire, limits: wire.Limits) !void {
    // validateCandidate alone omits failure-record bounds and checkpoint
    // restoration rules. Reuse both real Product paths rather than copy them.
    if (wire.validateCandidate(&state, limits) != null) return error.Invalid;
    if (state.failures.len > wire.max_failure_records) return error.Invalid;
    for (state.failures) |failure| {
        if (failure.task_id == 0 or failure.recent_order == 0 or failure.reason.len == 0 or failure.reason.len > wire.max_failure_reason_bytes or !std.unicode.utf8ValidateSlice(failure.reason)) return error.Invalid;
    }
    for (state.tasks) |task| try wire.validateRestorableTask(allocator, task, limits);
}

pub const Row = struct {
    table: []const u8,
    columns: []const []const u8,
    primary: []const usize,
    values: []const sql.Value,
    key: []const u8,
    digest: [32]u8,

    pub fn position(self: Row) ?i64 {
        for (self.columns, self.values) |name, value| {
            if (std.mem.eql(u8, name, "ordinal")) return value.integer;
        }
        return null;
    }
};

fn primaryNames(comptime table: []const u8) []const []const u8 {
    if (std.mem.eql(u8, table, "history_state")) return &.{"singleton"};
    if (std.mem.eql(u8, table, "workspaces") or std.mem.eql(u8, table, "tasks")) return &.{"id"};
    if (std.mem.eql(u8, table, "retained_records")) return &.{ "kind", "id", "occurrence" };
    if (std.mem.eql(u8, table, "task_ui_history")) return &.{ "task_id", "request_id" };
    if (std.mem.eql(u8, table, "task_input_submissions")) return &.{ "task_id", "operation_id" };
    if (std.mem.eql(u8, table, "runs") or std.mem.eql(u8, table, "task_compacts")) return &.{ "task_id", "id" };
    return &.{ "task_id", "run_id", "id" };
}

fn identityValue(allocator: std.mem.Allocator, bytes: *std.ArrayList(u8), value: sql.Value) !void {
    try bytes.append(allocator, @intFromEnum(std.meta.activeTag(value)));
    switch (value) {
        .null_value => {},
        .integer => |v| {
            var b8: [8]u8 = undefined;
            std.mem.writeInt(u64, &b8, @bitCast(v), .big);
            try bytes.appendSlice(allocator, &b8);
        },
        .real => |v| {
            var b8: [8]u8 = undefined;
            std.mem.writeInt(u64, &b8, @bitCast(v), .big);
            try bytes.appendSlice(allocator, &b8);
        },
        .blob, .text => |v| {
            var b8: [8]u8 = undefined;
            std.mem.writeInt(u64, &b8, v.len, .big);
            try bytes.appendSlice(allocator, &b8);
            try bytes.appendSlice(allocator, v);
        },
    }
}

fn rowFor(allocator: std.mem.Allocator, comptime table: []const u8, values: anytype) !Row {
    const fields = std.meta.fields(@TypeOf(values));
    const names = try allocator.alloc([]const u8, fields.len);
    const params = try allocator.alloc(sql.Value, fields.len);
    inline for (fields, 0..) |field, i| {
        names[i] = field.name;
        params[i] = @field(values, field.name);
    }
    const primary = try allocator.alloc(usize, primaryNames(table).len);
    inline for (comptime primaryNames(table), 0..) |name, i| {
        var found = false;
        inline for (fields, 0..) |field, j| {
            if (comptime std.mem.eql(u8, name, field.name)) {
                primary[i] = j;
                found = true;
            }
        }
        if (!found) return error.Invalid;
    }
    var key: std.ArrayList(u8) = .empty;
    try key.appendSlice(allocator, table);
    try key.append(allocator, 0);
    for (primary) |index| try identityValue(allocator, &key, params[index]);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(key.items);
    for (params) |value| {
        const tag = [_]u8{@intFromEnum(std.meta.activeTag(value))};
        hash.update(&tag);
        switch (value) {
            .null_value => {},
            .integer => |v| {
                var b8: [8]u8 = undefined;
                std.mem.writeInt(u64, &b8, @bitCast(v), .big);
                hash.update(&b8);
            },
            .real => |v| {
                var b8: [8]u8 = undefined;
                std.mem.writeInt(u64, &b8, @bitCast(v), .big);
                hash.update(&b8);
            },
            .blob, .text => |v| {
                var b8: [8]u8 = undefined;
                std.mem.writeInt(u64, &b8, v.len, .big);
                hash.update(&b8);
                hash.update(v);
            },
        }
    }
    return .{ .table = table, .columns = names, .primary = primary, .values = params, .key = try key.toOwnedSlice(allocator), .digest = hash.finalResult() };
}

pub const Batch = struct {
    allocator: std.mem.Allocator,
    mutations: std.ArrayList(sql.Mutation) = .empty,
    capture: bool = false,
    rows: std.ArrayList(Row) = .empty,
    pending_table: []const u8 = "",
    pending_sql: std.ArrayList(u8) = .empty,
    params: std.ArrayList(sql.Value) = .empty,

    fn add(self: *@This(), comptime table: []const u8, values: anytype) !void {
        if (self.capture) {
            try self.rows.append(self.allocator, try rowFor(self.allocator, table, values));
            return;
        }
        const fields = std.meta.fields(@TypeOf(values));
        if (!std.mem.eql(u8, self.pending_table, table) or self.params.items.len + fields.len > sql.Limits.parameters)
            try self.flush();
        if (self.pending_sql.items.len == 0) {
            self.pending_table = table;
            try self.pending_sql.appendSlice(self.allocator, "INSERT INTO " ++ table ++ "(");
            inline for (fields, 0..) |field, index| {
                if (index != 0) try self.pending_sql.append(self.allocator, ',');
                try self.pending_sql.appendSlice(self.allocator, field.name);
            }
            try self.pending_sql.appendSlice(self.allocator, ") VALUES");
        } else try self.pending_sql.append(self.allocator, ',');
        try self.pending_sql.append(self.allocator, '(');
        inline for (fields, 0..) |field, index| {
            if (index != 0) try self.pending_sql.append(self.allocator, ',');
            const marker = try std.fmt.allocPrint(self.allocator, "?{d}", .{self.params.items.len + 1});
            try self.pending_sql.appendSlice(self.allocator, marker);
            try self.params.append(self.allocator, @field(values, field.name));
        }
        try self.pending_sql.append(self.allocator, ')');
    }

    fn flush(self: *@This()) !void {
        if (self.pending_sql.items.len == 0) return;
        try self.mutations.append(self.allocator, .{ .statement = .{
            .sql = try self.pending_sql.toOwnedSlice(self.allocator),
            .params = try self.params.toOwnedSlice(self.allocator),
        } });
        self.pending_table = "";
    }

    fn u(self: *@This(), value: u64) !sql.Value {
        const bytes = try self.allocator.create([8]u8);
        std.mem.writeInt(u64, bytes, value, .big);
        return .{ .blob = bytes };
    }
    fn ou(self: *@This(), value: ?u64) !sql.Value {
        return if (value) |number| try self.u(number) else .null_value;
    }
    fn json(self: *@This(), value: anytype) !sql.Value {
        return .{ .text = try std.json.Stringify.valueAlloc(self.allocator, value, .{}) };
    }
    fn ojson(self: *@This(), value: anytype) !sql.Value {
        return if (value) |item| try self.json(item) else .null_value;
    }
    fn digest(self: *@This(), value: []const u8) !sql.Value {
        if (value.len != 64) return error.Invalid;
        const bytes = try self.allocator.create([32]u8);
        _ = try std.fmt.hexToBytes(bytes, value);
        const canonical = std.fmt.bytesToHex(bytes.*, .lower);
        if (!std.mem.eql(u8, &canonical, value)) return error.Invalid;
        return .{ .blob = bytes };
    }
    fn odigest(self: *@This(), value: ?[]const u8) !sql.Value {
        return if (value) |item| try self.digest(item) else .null_value;
    }
};

fn b(value: []const u8) sql.Value {
    return .{ .blob = value };
}
fn ob(value: ?[]const u8) sql.Value {
    return if (value) |item| b(item) else .null_value;
}
fn t(value: []const u8) sql.Value {
    return .{ .text = value };
}
fn ot(value: ?[]const u8) sql.Value {
    return if (value) |item| t(item) else .null_value;
}
fn boolean(value: bool) sql.Value {
    return .{ .integer = @intFromBool(value) };
}
fn integer(value: u64) !sql.Value {
    return .{ .integer = std.math.cast(i64, value) orelse return error.Invalid };
}
fn ordinal(value: usize) !sql.Value {
    if (value >= 2147483648) return error.Invalid;
    return integer(value);
}
fn oi(value: ?u64) !sql.Value {
    return if (value) |item| try integer(item) else .null_value;
}

const Records = struct {
    allocator: std.mem.Allocator,
    columns: []const []const u8 = &.{},
    values: std.ArrayList([]sql.Value) = .empty,
    failed: bool = false,
    fn receive(context: *anyopaque, incoming: sql.Row) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (!self.failed) self.copy(incoming) catch {
            self.failed = true;
        };
    }
    fn copy(self: *@This(), incoming: sql.Row) !void {
        if (self.columns.len == 0) {
            const names = try self.allocator.alloc([]const u8, incoming.columnCount());
            for (names, 0..) |*name, index| name.* = try self.allocator.dupe(u8, incoming.columnName(index));
            self.columns = names;
        }
        const values = try self.allocator.alloc(sql.Value, incoming.columnCount());
        for (values, 0..) |*value, index| value.* = switch (incoming.value(index)) {
            .blob => |bytes| .{ .blob = try self.allocator.dupe(u8, bytes) },
            .text => |bytes| .{ .text = try self.allocator.dupe(u8, bytes) },
            else => |scalar| scalar,
        };
        try self.values.append(self.allocator, values);
    }
    fn adopt(self: *@This(), source: *const Records) !void {
        if (source.values.items.len == 0) return;
        if (self.columns.len == 0) {
            const names = try self.allocator.alloc([]const u8, source.columns.len);
            for (names, source.columns) |*name, value| name.* = try self.allocator.dupe(u8, value);
            self.columns = names;
        }
        for (source.values.items) |row_values| {
            const values = try self.allocator.alloc(sql.Value, row_values.len);
            for (values, row_values) |*value, incoming| value.* = switch (incoming) {
                .blob => |bytes| .{ .blob = try self.allocator.dupe(u8, bytes) },
                .text => |bytes| .{ .text = try self.allocator.dupe(u8, bytes) },
                else => incoming,
            };
            try self.values.append(self.allocator, values);
        }
    }
    fn row(self: *const @This(), index: usize) Record {
        return .{ .allocator = self.allocator, .columns = self.columns, .values = self.values.items[index] };
    }
};

const Record = struct {
    allocator: std.mem.Allocator,
    columns: []const []const u8,
    values: []sql.Value,
    fn value(self: @This(), name: []const u8) !sql.Value {
        for (self.columns, 0..) |column, index| if (std.mem.eql(u8, name, column)) return self.values[index];
        return error.MissingColumn;
    }
    fn isNull(self: @This(), name: []const u8) !bool {
        return try self.value(name) == .null_value;
    }
    fn optionalGroup(self: @This(), comptime names: anytype) !void {
        const absent = try self.isNull(names[0]);
        inline for (names) |name| {
            if (try self.isNull(name) != absent) return error.Invalid;
        }
    }
    fn u(self: @This(), name: []const u8) !u64 {
        const raw = try self.value(name);
        if (raw != .blob or raw.blob.len != 8) return error.Invalid;
        return std.mem.readInt(u64, raw.blob[0..8], .big);
    }
    fn ou(self: @This(), name: []const u8) !?u64 {
        return if (try self.isNull(name)) null else try self.u(name);
    }
    fn b(self: @This(), name: []const u8) ![]const u8 {
        const raw = try self.value(name);
        if (raw != .blob or !std.unicode.utf8ValidateSlice(raw.blob)) return error.Invalid;
        return raw.blob;
    }
    fn ob(self: @This(), name: []const u8) !?[]const u8 {
        return if (try self.isNull(name)) null else try self.b(name);
    }
    fn t(self: @This(), name: []const u8) ![]const u8 {
        const raw = try self.value(name);
        if (raw != .text) return error.Invalid;
        return raw.text;
    }
    fn ot(self: @This(), name: []const u8) !?[]const u8 {
        return if (try self.isNull(name)) null else try self.t(name);
    }
    fn i(self: @This(), name: []const u8) !u64 {
        const raw = try self.value(name);
        if (raw != .integer or raw.integer < 0) return error.Invalid;
        return @intCast(raw.integer);
    }
    fn oi(self: @This(), name: []const u8) !?u64 {
        return if (try self.isNull(name)) null else try self.i(name);
    }
    fn boolean(self: @This(), name: []const u8) !bool {
        return switch (try self.i(name)) {
            0 => false,
            1 => true,
            else => error.Invalid,
        };
    }
    fn json(self: @This(), comptime T: type, name: []const u8) !T {
        return std.json.parseFromSliceLeaky(T, self.allocator, try self.t(name), .{ .allocate = .alloc_always });
    }
    fn ojson(self: @This(), comptime T: type, name: []const u8) !?T {
        return if (try self.isNull(name)) null else try self.json(T, name);
    }
    fn digest(self: @This(), name: []const u8) ![]const u8 {
        const raw = try self.value(name);
        if (raw != .blob or raw.blob.len != 32) return error.Invalid;
        const hex = std.fmt.bytesToHex(raw.blob[0..32].*, .lower);
        return try self.allocator.dupe(u8, &hex);
    }
};

fn query(allocator: std.mem.Allocator, database: sql.Database, statement: []const u8, params: []const sql.Value) !Records {
    var records = Records{ .allocator = allocator };
    const outcome = database.query(statement, params, .{ .context = &records, .receive_fn = Records.receive });
    if (records.failed) return error.OutOfMemory;
    if (outcome != .ok) return error.QueryFailed;
    return records;
}

// The sink may have received rows before Storage reports its byte limit.
// Adopt only a successful whole page; release failed attempts before retrying.
fn pageQuery(allocator: std.mem.Allocator, temporary: std.mem.Allocator, database: sql.Database, text: []const u8, params: []const sql.Value, page_limit: *usize) !Records {
    while (true) {
        var arena = std.heap.ArenaAllocator.init(temporary);
        defer arena.deinit();
        const a = arena.allocator();
        const statement = try std.fmt.allocPrint(a, "{s} LIMIT {d}", .{ text, page_limit.* });
        var page: Records = .{ .allocator = a };
        const outcome = database.query(statement, params, .{ .context = &page, .receive_fn = Records.receive });
        if (page.failed) return error.OutOfMemory;
        if (outcome == .resource_exhausted and page_limit.* > 1) {
            page_limit.* = @max(1, page_limit.* / 2);
            continue;
        }
        if (outcome != .ok) return error.QueryFailed;
        var result: Records = .{ .allocator = allocator };
        try result.adopt(&page);
        return result;
    }
}

// A single largest legal row fits the SQL result budget; a whole Task need
// not. Use indexed identity/position keysets, never partial-result adoption.
fn ordered(allocator: std.mem.Allocator, temporary: std.mem.Allocator, database: sql.Database, comptime table: []const u8, parents: []const sql.Value) !Records {
    const identity = comptime std.mem.eql(u8, table, "workspaces") or std.mem.eql(u8, table, "tasks") or std.mem.eql(u8, table, "run_additional_inputs");
    const key = if (identity) "id" else "ordinal";
    const condition = switch (parents.len) {
        0 => "WHERE " ++ key ++ ">?1",
        1 => "WHERE task_id=?1 AND " ++ key ++ ">?2",
        2 => "WHERE task_id=?1 AND run_id=?2 AND " ++ key ++ ">?3",
        else => return error.Invalid,
    };
    const text = try std.fmt.allocPrint(allocator, "SELECT * FROM {s} {s} ORDER BY {s}", .{ table, condition, key });
    const initial_condition = switch (parents.len) {
        0 => "",
        1 => "WHERE task_id=?1",
        2 => "WHERE task_id=?1 AND run_id=?2",
        else => unreachable,
    };
    const initial_text = try std.fmt.allocPrint(allocator, "SELECT * FROM {s} {s} ORDER BY {s}", .{ table, initial_condition, key });
    const params = try allocator.alloc(sql.Value, parents.len + 1);
    @memcpy(params[0..parents.len], parents);
    var result = Records{ .allocator = allocator };
    var cursor: i64 = -1;
    var last_id: u64 = 0;
    var identity_bytes: [8]u8 = @splat(0);
    var first = true;
    var page_limit: usize = 64;
    while (true) {
        if (identity) std.mem.writeInt(u64, &identity_bytes, last_id, .big);
        params[parents.len] = if (identity) .{ .blob = &identity_bytes } else .{ .integer = cursor };
        const page = try pageQuery(allocator, temporary, database, if (first) initial_text else text, if (first) parents else params, &page_limit);
        if (page.values.items.len == 0) break;
        for (0..page.values.items.len) |index| {
            if (identity) {
                const next = try page.row(index).u("id");
                if (next <= last_id) return error.Invalid;
                last_id = next;
            } else {
                const next = try page.row(index).i("ordinal");
                if (next != result.values.items.len + index or next >= 2147483648) return error.Invalid;
                cursor = @intCast(next);
            }
        }
        if (result.columns.len == 0) result.columns = page.columns;
        try result.values.appendSlice(allocator, page.values.items);
        first = false;
    }
    return result;
}

fn validatePreserved(allocator: std.mem.Allocator, state: wire.StateWire, preserved: wire.PreservedFrames) !void {
    for (preserved.retained) |v| {
        if (v.id == 0 or (v.kind == .task and v.id >= state.next_task_id) or (v.kind == .workspace and v.id >= state.next_workspace_id)) return error.Invalid;
    }
    for (preserved.read_only_tasks) |v| {
        const original = try std.json.parseFromSliceLeaky(wire.TaskWire, allocator, v.payload, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        if (original.id != v.task_id or original.recent_order != v.recent_order) return error.Invalid;
        var found = false;
        for (state.tasks) |task| {
            if (task.id == v.task_id) {
                found = true;
                if (task.workspace_id != original.workspace_id) return error.Invalid;
                break;
            }
        }
        if (!found) return error.Invalid;
    }
}

pub fn batchFor(allocator: std.mem.Allocator, state: wire.StateWire, limits: wire.Limits) !Batch {
    return batchForPreserving(allocator, state, .{}, limits);
}

pub fn rowsFor(allocator: std.mem.Allocator, state: wire.StateWire, preserved: wire.PreservedFrames, limits: wire.Limits) ![]const Row {
    return (try build(allocator, state, preserved, limits, true)).rows.items;
}

pub fn batchForPreserving(allocator: std.mem.Allocator, state: wire.StateWire, preserved: wire.PreservedFrames, limits: wire.Limits) !Batch {
    return build(allocator, state, preserved, limits, false);
}

fn build(allocator: std.mem.Allocator, state: wire.StateWire, preserved: wire.PreservedFrames, limits: wire.Limits, capture: bool) !Batch {
    try validateState(allocator, state, limits);
    try validatePreserved(allocator, state, preserved);
    var batch = Batch{ .allocator = allocator, .capture = capture };
    try writeState(&batch, state);
    for (state.workspaces) |value| try writeWorkspace(&batch, value);
    for (state.tasks) |task| try writeTask(&batch, task);
    for (state.tasks) |task| for (task.runs, 0..) |run, position| {
        try writeRun(&batch, run, task.id, position);
    };
    for (state.tasks) |task| for (task.runs) |run| for (run.tools, 0..) |tool, position| {
        try writeTool(&batch, tool, task.id, run.id, position);
    };
    for (state.tasks) |task| for (task.runs) |run| if (run.file_changes) |changes| {
        for (changes, 0..) |change, position| try writeChange(&batch, change, task.id, run.id, position);
    };
    for (state.tasks) |task| {
        for (task.compacts, 0..) |v, position| try batch.add("task_compacts", .{ .task_id = try batch.u(task.id), .id = try batch.u(v.id), .ordinal = try ordinal(position), .payload = try batch.json(v) });
        for (task.ui_history, 0..) |v, position| try batch.add("task_ui_history", .{ .task_id = try batch.u(task.id), .request_id = try batch.u(v.request_id), .ordinal = try ordinal(position), .payload = try batch.json(v) });
        for (task.input_submissions, 0..) |v, position| try batch.add("task_input_submissions", .{ .task_id = try batch.u(task.id), .operation_id = b(v.submission.operation_id), .ordinal = try ordinal(position), .payload = try batch.json(v) });
        for (task.runs) |run| for (run.additional_inputs) |v| try batch.add("run_additional_inputs", .{ .task_id = try batch.u(task.id), .run_id = try batch.u(run.id), .id = try batch.u(v.id), .payload = try batch.json(v) });
    }
    // Several original frames may have the same identity. Preserve each one,
    // including byte-identical repetitions, without inventing a new frame id.
    var occurrences: std.AutoHashMap(struct { kind: wire.RetainedKind, id: u64 }, usize) = .init(allocator);
    defer occurrences.deinit();
    for (preserved.retained) |v| {
        const entry = try occurrences.getOrPut(.{ .kind = v.kind, .id = v.id });
        if (!entry.found_existing) entry.value_ptr.* = 0;
        const occurrence = entry.value_ptr.*;
        if (occurrence >= 2147483648) return error.Invalid;
        entry.value_ptr.* += 1;
        try batch.add("retained_records", .{ .kind = t(@tagName(v.kind)), .id = try batch.u(v.id), .occurrence = try integer(occurrence), .recent_order = try batch.u(v.order), .payload = b(v.payload) });
    }
    for (preserved.read_only_tasks) |v| try batch.add("retained_records", .{ .kind = t("read_only_task"), .id = try batch.u(v.task_id), .occurrence = try integer(0), .recent_order = try batch.u(v.recent_order), .payload = b(v.payload) });
    try batch.flush();
    return batch;
}

pub const Loaded = struct { value: wire.StateWire, preserved: wire.PreservedFrames = .{} };

pub fn load(allocator: std.mem.Allocator, temporary: std.mem.Allocator, database: sql.Database, limits: wire.Limits) !wire.StateWire {
    return (try loadPreserving(allocator, temporary, database, limits)).value;
}

pub fn loadPreserving(allocator: std.mem.Allocator, temporary: std.mem.Allocator, database: sql.Database, limits: wire.Limits) !Loaded {
    const state = try loadRows(allocator, temporary, database, limits);
    var retained: std.ArrayList(wire.RetainedRecord) = .empty;
    var readonly: std.ArrayList(wire.ReadOnlyPayload) = .empty;
    var bindings: Batch = .{ .allocator = allocator };
    for ([_][]const u8{ "workspace", "task", "read_only_task" }) |kind| {
        var cursor: u64 = 0;
        var last_occurrence: i64 = -1;
        var first = true;
        var page_limit: usize = 64;
        while (true) {
            const text = if (first) "SELECT * FROM retained_records WHERE kind=?1 ORDER BY id,occurrence" else "SELECT * FROM retained_records WHERE kind=?1 AND (id,occurrence)>(?2,?3) ORDER BY id,occurrence";
            const rows = try pageQuery(allocator, temporary, database, text, if (first) &.{t(kind)} else &.{ t(kind), try bindings.u(cursor), .{ .integer = last_occurrence } }, &page_limit);
            if (rows.values.items.len == 0) break;
            for (0..rows.values.items.len) |index| {
                const row = rows.row(index);
                const id = try row.u("id");
                const order = try row.u("recent_order");
                const occurrence = try row.i("occurrence");
                if (id == 0 or (!first and id < cursor)) return error.Invalid;
                const expected: u64 = if (first or id != cursor) 0 else @intCast(last_occurrence + 1);
                if (occurrence != expected or occurrence >= 2147483648) return error.Invalid;
                const raw = try row.value("payload");
                if (raw != .blob) return error.Invalid;
                if (std.mem.eql(u8, kind, "read_only_task")) {
                    if (occurrence != 0) return error.Invalid;
                    var found = false;
                    for (state.tasks) |task| {
                        if (task.id == id) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) return error.Invalid;
                    try readonly.append(allocator, .{ .task_id = id, .recent_order = order, .payload = raw.blob });
                } else try retained.append(allocator, .{ .kind = if (std.mem.eql(u8, kind, "workspace")) .workspace else .task, .id = id, .order = order, .payload = raw.blob });
                cursor = id;
                last_occurrence = @intCast(occurrence);
                first = false;
            }
        }
    }
    const total = try query(allocator, database, "SELECT COUNT(*) AS total FROM retained_records", &.{});
    if (try total.row(0).i("total") != retained.items.len + readonly.items.len) return error.Invalid;
    const result: Loaded = .{ .value = state, .preserved = .{ .retained = try retained.toOwnedSlice(allocator), .read_only_tasks = try readonly.toOwnedSlice(allocator) } };
    try validatePreserved(allocator, result.value, result.preserved);
    return result;
}

/// The Product history owner holds its writer/admission gate throughout load.
/// Rows are candidates until full Product validation succeeds.
fn loadRows(allocator: std.mem.Allocator, temporary: std.mem.Allocator, database: sql.Database, limits: wire.Limits) !wire.StateWire {
    const roots = try query(allocator, database, "SELECT * FROM history_state", &.{});
    if (roots.values.items.len == 0) {
        const existing = try query(allocator, database, "SELECT (SELECT COUNT(*) FROM workspaces)+(SELECT COUNT(*) FROM tasks)+(SELECT COUNT(*) FROM runs)+(SELECT COUNT(*) FROM run_tools)+(SELECT COUNT(*) FROM run_file_changes)+(SELECT COUNT(*) FROM task_compacts)+(SELECT COUNT(*) FROM task_ui_history)+(SELECT COUNT(*) FROM task_input_submissions)+(SELECT COUNT(*) FROM run_additional_inputs)+(SELECT COUNT(*) FROM retained_records) AS total", &.{});
        if (try existing.row(0).i("total") != 0) return error.MissingState;
        return error.EmptyHistory;
    }
    if (roots.values.items.len != 1) return error.Invalid;
    var state = try readState(roots.row(0));
    const workspaces = try ordered(allocator, temporary, database, "workspaces", &.{});
    state.workspaces = try allocator.alloc(wire.WorkspaceWire, workspaces.values.items.len);
    for (state.workspaces, 0..) |*value, index| value.* = try readWorkspace(workspaces.row(index));
    const tasks = try ordered(allocator, temporary, database, "tasks", &.{});
    state.tasks = try allocator.alloc(wire.TaskWire, tasks.values.items.len);
    var bindings = Batch{ .allocator = allocator };
    for (state.tasks, 0..) |*task, index| {
        task.* = try readTask(tasks.row(index));
        const task_params = &.{try bindings.u(task.id)};
        const compacts = try ordered(allocator, temporary, database, "task_compacts", task_params);
        task.compacts = try allocator.alloc(wire.CompactWire, compacts.values.items.len);
        for (task.compacts, 0..) |*v, i| {
            v.* = try compacts.row(i).json(wire.CompactWire, "payload");
            if (v.id != try compacts.row(i).u("id")) return error.Invalid;
        }
        const decisions = try ordered(allocator, temporary, database, "task_ui_history", task_params);
        task.ui_history = try allocator.alloc(wire.UiRecordWire, decisions.values.items.len);
        for (task.ui_history, 0..) |*v, i| {
            v.* = try decisions.row(i).json(wire.UiRecordWire, "payload");
            if (v.request_id != try decisions.row(i).u("request_id")) return error.Invalid;
        }
        const submissions = try ordered(allocator, temporary, database, "task_input_submissions", task_params);
        task.input_submissions = try allocator.alloc(wire.InputSubmissionWire, submissions.values.items.len);
        for (task.input_submissions, 0..) |*v, i| {
            v.* = try submissions.row(i).json(wire.InputSubmissionWire, "payload");
            if (!std.mem.eql(u8, v.submission.operation_id, try submissions.row(i).b("operation_id"))) return error.Invalid;
        }

        const runs = try ordered(allocator, temporary, database, "runs", task_params);
        task.runs = try allocator.alloc(wire.RunWire, runs.values.items.len);
        for (task.runs, 0..) |*run, run_index| {
            run.* = try readRun(runs.row(run_index));
            const run_params = &.{ try bindings.u(task.id), try bindings.u(run.id) };
            const inputs = try ordered(allocator, temporary, database, "run_additional_inputs", run_params);
            run.additional_inputs = try allocator.alloc(wire.AdditionalInputWire, inputs.values.items.len);
            for (run.additional_inputs, 0..) |*v, i| {
                v.* = try inputs.row(i).json(wire.AdditionalInputWire, "payload");
                if (v.id != try inputs.row(i).u("id")) return error.Invalid;
            }

            const tools = try ordered(allocator, temporary, database, "run_tools", run_params);
            run.tools = try allocator.alloc(wire.ToolWire, tools.values.items.len);
            for (run.tools, 0..) |*value, child| value.* = try readTool(tools.row(child));
            const changes = try ordered(allocator, temporary, database, "run_file_changes", run_params);
            if (run.file_change_observation != null) {
                const values = try allocator.alloc(wire.FileChangeWire, changes.values.items.len);
                for (values, 0..) |*value, child| value.* = try readChange(changes.row(child));
                run.file_changes = values;
            } else if (changes.values.items.len != 0) return error.Invalid;
        }
    }
    try validateState(allocator, state, limits);
    return state;
}

fn writeState(batch: *Batch, v: wire.StateWire) !void {
    try batch.add("history_state", .{
        .singleton = try integer(1),
        .default_permission_profile = t(v.default_permission_profile),
        .default_approval_mode = ot(v.default_approval_mode),
        .next_workspace_id = try batch.u(v.next_workspace_id),
        .next_workspace_recent_order = try batch.u(v.next_workspace_recent_order),
        .next_task_id = try batch.u(v.next_task_id),
        .next_task_recent_order = try batch.u(v.next_task_recent_order),
        .failures_json = try batch.json(v.failures),
    });
}

fn readState(row: Record) !wire.StateWire {
    var v: wire.StateWire = undefined;
    v.default_permission_profile = try row.t("default_permission_profile");
    v.default_approval_mode = try row.ot("default_approval_mode");
    v.next_workspace_id = try row.u("next_workspace_id");
    v.next_workspace_recent_order = try row.u("next_workspace_recent_order");
    v.next_task_id = try row.u("next_task_id");
    v.next_task_recent_order = try row.u("next_task_recent_order");
    v.workspaces = &.{};
    v.tasks = &.{};
    v.failures = try row.json([]wire.TaskFailureWire, "failures_json");
    return v;
}

fn writeWorkspace(batch: *Batch, v: wire.WorkspaceWire) !void {
    try batch.add("workspaces", .{
        .id = try batch.u(v.id),
        .epoch = try batch.u(v.epoch),
        .kind = t(v.kind),
        .canonical_root = b(v.canonical_root),
        .display_name = b(v.display_name),
        .visible = boolean(v.visible),
        .project_removed = boolean(v.project_removed),
        .recent_order = try batch.u(v.recent_order),
    });
}

fn readWorkspace(row: Record) !wire.WorkspaceWire {
    var v: wire.WorkspaceWire = undefined;
    v.id = try row.u("id");
    v.epoch = try row.u("epoch");
    v.kind = try row.t("kind");
    v.canonical_root = try row.b("canonical_root");
    v.display_name = try row.b("display_name");
    v.visible = try row.boolean("visible");
    v.project_removed = try row.boolean("project_removed");
    v.recent_order = try row.u("recent_order");
    return v;
}

fn writeTask(batch: *Batch, v: wire.TaskWire) !void {
    const checkpoint = v.checkpoint;
    try batch.add("tasks", .{
        .presentation_format = try oi(if (v.presentation_format) |format| @as(u64, format) else null),
        .next_presentation_order = try batch.ou(v.next_presentation_order),
        .id = try batch.u(v.id),
        .recent_order = try batch.u(v.recent_order),
        .completion_seen_run_id = try batch.ou(v.completion_seen_run_id),
        .workspace_id = try batch.u(v.workspace_id),
        .workspace_epoch = try batch.u(v.workspace_epoch),
        .workspace_root = b(v.workspace_root),
        .title = b(v.title),
        .title_redacted = boolean(v.title_redacted),
        .archived = boolean(v.archived),
        .permission_profile = t(v.permission_profile),
        .permission_interaction = t(v.permission_interaction),
        .permission_review_delegated = boolean(v.permission_review_delegated),
        .approval_revision = try batch.u(v.approval_revision),
        .binding_epoch = try batch.u(v.binding.epoch),
        .execution_generation = try batch.u(v.binding.execution_generation),
        .protocol = t(v.binding.protocol),
        .model = b(v.binding.model),
        .model_intent_json = try batch.ojson(v.model_intent),
        .next_run_generation = try batch.u(v.next_run_generation),
        .checkpoint_anchor = t(v.checkpoint_anchor),
        .checkpoint_attempt = t(v.checkpoint_attempt),
        .active_operation_kind = ot(if (v.active_operation) |op| op.kind else null),
        .active_operation_id = try batch.ou(if (v.active_operation) |op| op.id else null),
        .checkpoint_generation = try batch.ou(if (checkpoint) |cp| cp.blob.generation else null),
        .checkpoint_byte_size = try batch.ou(if (checkpoint) |cp| cp.blob.byte_size else null),
        .checkpoint_digest = try batch.odigest(if (checkpoint) |cp| cp.blob.digest else null),
        .checkpoint_logical_session_id = ob(if (checkpoint) |cp| cp.session.logical_session_id else null),
        .checkpoint_last_run_id = try batch.ou(if (checkpoint) |cp| cp.session.last_run_id else null),
        .checkpoint_last_compact_id = try batch.ou(if (checkpoint) |cp| cp.session.last_compact_id else null),
        .checkpoint_model = ob(if (checkpoint) |cp| cp.session.model else null),
        .checkpoint_terminal_kind = ot(if (checkpoint) |cp| cp.anchor.terminal.kind else null),
        .checkpoint_terminal_id = try batch.ou(if (checkpoint) |cp| cp.anchor.terminal.id else null),
        .checkpoint_binding_epoch = try batch.ou(if (checkpoint) |cp| cp.anchor.binding_epoch else null),
    });
}

fn readTask(row: Record) !wire.TaskWire {
    try row.optionalGroup(.{ "active_operation_kind", "active_operation_id" });
    var v: wire.TaskWire = undefined;
    v.presentation_format = if (try row.oi("presentation_format")) |format| std.math.cast(u8, format) orelse return error.Invalid else null;
    v.next_presentation_order = try row.ou("next_presentation_order");
    v.id = try row.u("id");
    v.recent_order = try row.u("recent_order");
    v.completion_seen_run_id = try row.ou("completion_seen_run_id");
    v.workspace_id = try row.u("workspace_id");
    v.workspace_epoch = try row.u("workspace_epoch");
    v.workspace_root = try row.b("workspace_root");
    v.title = try row.b("title");
    v.title_redacted = try row.boolean("title_redacted");
    v.archived = try row.boolean("archived");
    v.permission_profile = try row.t("permission_profile");
    v.permission_interaction = try row.t("permission_interaction");
    v.permission_review_delegated = try row.boolean("permission_review_delegated");
    v.approval_revision = try row.u("approval_revision");
    v.binding.epoch = try row.u("binding_epoch");
    v.binding.execution_generation = try row.u("execution_generation");
    v.binding.protocol = try row.t("protocol");
    v.binding.model = try row.b("model");
    v.model_intent = try row.ojson(wire.ModelIntentWire, "model_intent_json");
    v.next_run_generation = try row.u("next_run_generation");
    v.checkpoint_anchor = try row.t("checkpoint_anchor");
    v.checkpoint_attempt = try row.t("checkpoint_attempt");
    v.active_operation = if (try row.ot("active_operation_kind")) |kind| .{ .kind = kind, .id = try row.u("active_operation_id") } else null;
    v.runs = &.{};
    v.compacts = &.{};
    v.input_submissions = &.{};
    v.ui_history = &.{};
    v.checkpoint = try readCheckpoint(row);
    return v;
}

fn writeRun(batch: *Batch, v: wire.RunWire, task_id: u64, position: usize) !void {
    try batch.add("runs", .{
        .task_id = try batch.u(task_id),
        .ordinal = try ordinal(position),
        .id = try batch.u(v.id),
        .coverage = t(v.coverage),
        .generation = try batch.u(v.generation),
        .execution_generation = try batch.u(v.execution_generation),
        .execution_protocol = t(v.execution_protocol),
        .execution_model = b(v.execution_model),
        .permission_profile = t(v.permission_profile),
        .permission_interaction = t(v.permission_interaction),
        .assistant = b(v.assistant),
        .assistant_redacted = boolean(v.assistant_redacted),
        .assistant_output_kind = ot(v.assistant_output_kind),
        .assistant_output_start = try batch.ou(v.assistant_output_start),
        .elapsed_ms = try batch.ou(v.elapsed_ms),
        .submitted_at_unix_ms = try oi(v.submitted_at_unix_ms),
        .finished_at_unix_ms = try oi(v.finished_at_unix_ms),
        .phase = t(v.phase),
        .outcome = ot(v.outcome),
        .cause = ot(v.cause),
        .outputs_json = try batch.json(v.outputs),
        .input_json = try batch.json(v.input),
        .submission_json = try batch.ojson(v.submission),
        .commentary_ends_json = try batch.json(v.commentary_ends),
        .file_change_observation = ot(v.file_change_observation),
        .diagnostic = b(v.diagnostic),
        .diagnostic_truncated = boolean(v.diagnostic_truncated),
        .diagnostic_redacted = boolean(v.diagnostic_redacted),
        .model_error_json = try batch.ojson(v.model_error),
        .event_projection_failure = ot(v.event_projection_failure),
        .next_activity_order = try batch.u(v.next_activity_order),
        .input_tokens = try batch.u(v.usage.input_tokens),
        .output_tokens = try batch.u(v.usage.output_tokens),
        .cache_read_input_tokens = try batch.u(v.usage.cache_read_input_tokens),
        .cache_creation_input_tokens = try batch.u(v.usage.cache_creation_input_tokens),
    });
}

fn readRun(row: Record) !wire.RunWire {
    var v: wire.RunWire = undefined;
    v.id = try row.u("id");
    v.coverage = try row.t("coverage");
    v.generation = try row.u("generation");
    v.execution_generation = try row.u("execution_generation");
    v.execution_protocol = try row.t("execution_protocol");
    v.execution_model = try row.b("execution_model");
    v.permission_profile = try row.t("permission_profile");
    v.permission_interaction = try row.t("permission_interaction");
    v.assistant = try row.b("assistant");
    v.assistant_redacted = try row.boolean("assistant_redacted");
    v.assistant_output_kind = try row.ot("assistant_output_kind");
    v.assistant_output_start = try row.ou("assistant_output_start");
    v.elapsed_ms = try row.ou("elapsed_ms");
    v.submitted_at_unix_ms = try row.oi("submitted_at_unix_ms");
    v.finished_at_unix_ms = try row.oi("finished_at_unix_ms");
    v.phase = try row.t("phase");
    v.outcome = try row.ot("outcome");
    v.cause = try row.ot("cause");
    v.input = try row.json(wire.RunInputWire, "input_json");
    v.additional_inputs = &.{};
    v.submission = try row.ojson(wire.SubmissionWire, "submission_json");
    v.commentary_ends = try row.json([]const u64, "commentary_ends_json");
    v.file_change_observation = try row.ot("file_change_observation");
    v.diagnostic = try row.b("diagnostic");
    v.diagnostic_truncated = try row.boolean("diagnostic_truncated");
    v.diagnostic_redacted = try row.boolean("diagnostic_redacted");
    v.model_error = try row.ojson(wire.ModelErrorWire, "model_error_json");
    v.event_projection_failure = try row.ot("event_projection_failure");
    v.next_activity_order = try row.u("next_activity_order");
    v.usage.input_tokens = try row.u("input_tokens");
    v.usage.output_tokens = try row.u("output_tokens");
    v.usage.cache_read_input_tokens = try row.u("cache_read_input_tokens");
    v.usage.cache_creation_input_tokens = try row.u("cache_creation_input_tokens");
    v.tools = &.{};
    v.file_changes = if (v.file_change_observation == null) null else &.{};
    v.outputs = try row.json([]wire.OutputWire, "outputs_json");
    return v;
}

fn writeTool(batch: *Batch, v: wire.ToolWire, task_id: u64, run_id: u64, position: usize) !void {
    try batch.add("run_tools", .{
        .task_id = try batch.u(task_id),
        .run_id = try batch.u(run_id),
        .ordinal = try ordinal(position),
        .activity_order = try batch.u(v.order),
        .id = b(v.id),
        .name = b(v.name),
        .input = b(v.input),
        .progress = b(v.progress),
        .content = b(v.content),
        .state = t(v.state),
        .is_error = boolean(v.is_error),
        .elapsed_ms = try batch.u(v.elapsed_ms),
        .input_truncated = boolean(v.input_truncated),
        .progress_truncated = boolean(v.progress_truncated),
        .content_truncated = boolean(v.content_truncated),
        .redacted = boolean(v.redacted),
        .file_refs_json = try batch.ojson(v.file_refs),
    });
}

fn readTool(row: Record) !wire.ToolWire {
    var v: wire.ToolWire = undefined;
    v.order = try row.u("activity_order");
    v.id = try row.b("id");
    v.name = try row.b("name");
    v.input = try row.b("input");
    v.progress = try row.b("progress");
    v.content = try row.b("content");
    v.state = try row.t("state");
    v.is_error = try row.boolean("is_error");
    v.elapsed_ms = try row.u("elapsed_ms");
    v.input_truncated = try row.boolean("input_truncated");
    v.progress_truncated = try row.boolean("progress_truncated");
    v.content_truncated = try row.boolean("content_truncated");
    v.redacted = try row.boolean("redacted");
    v.file_refs = try row.ojson([]wire.FileReferenceWire, "file_refs_json");
    return v;
}

fn writeChange(batch: *Batch, v: wire.FileChangeWire, task_id: u64, run_id: u64, position: usize) !void {
    try batch.add("run_file_changes", .{
        .task_id = try batch.u(task_id),
        .run_id = try batch.u(run_id),
        .ordinal = try ordinal(position),
        .activity_order = try batch.u(v.order),
        .id = b(v.id),
        .kind = t(v.kind),
        .status = t(v.status),
        .display_path = b(v.display_path),
        .from_display_path = ob(v.from_display_path),
        .before_bytes = try batch.u(v.before_bytes),
        .after_bytes = try batch.u(v.after_bytes),
        .diff_complete = boolean(v.diff_complete),
        .redacted = boolean(v.redacted),
        .artifact_run_generation = try batch.ou(if (v.artifact) |item| item.run_generation else null),
        .artifact_change_order = try batch.ou(if (v.artifact) |item| item.change_order else null),
        .artifact_digest = try batch.odigest(if (v.artifact) |item| item.digest else null),
        .artifact_byte_size = try batch.ou(if (v.artifact) |item| item.byte_size else null),
    });
}

fn readChange(row: Record) !wire.FileChangeWire {
    try row.optionalGroup(.{ "artifact_run_generation", "artifact_change_order", "artifact_digest", "artifact_byte_size" });
    var v: wire.FileChangeWire = undefined;
    v.order = try row.u("activity_order");
    v.id = try row.b("id");
    v.kind = try row.t("kind");
    v.status = try row.t("status");
    v.display_path = try row.b("display_path");
    v.from_display_path = try row.ob("from_display_path");
    v.before_bytes = try row.u("before_bytes");
    v.after_bytes = try row.u("after_bytes");
    v.diff_complete = try row.boolean("diff_complete");
    v.redacted = try row.boolean("redacted");
    v.artifact = if (try row.isNull("artifact_run_generation")) null else .{
        .run_generation = try row.u("artifact_run_generation"),
        .change_order = try row.u("artifact_change_order"),
        .digest = try row.digest("artifact_digest"),
        .byte_size = try row.u("artifact_byte_size"),
    };
    return v;
}

fn readCheckpoint(row: Record) !?wire.CheckpointWire {
    try row.optionalGroup(.{ "checkpoint_generation", "checkpoint_byte_size", "checkpoint_digest", "checkpoint_logical_session_id", "checkpoint_last_run_id", "checkpoint_last_compact_id", "checkpoint_model", "checkpoint_terminal_kind", "checkpoint_terminal_id", "checkpoint_binding_epoch" });
    if (try row.isNull("checkpoint_generation")) return null;
    var v: wire.CheckpointWire = undefined;
    v.blob.generation = try row.u("checkpoint_generation");
    v.blob.byte_size = try row.u("checkpoint_byte_size");
    v.blob.digest = try row.digest("checkpoint_digest");
    v.session.logical_session_id = try row.b("checkpoint_logical_session_id");
    v.session.last_run_id = try row.u("checkpoint_last_run_id");
    v.session.last_compact_id = try row.u("checkpoint_last_compact_id");
    v.session.model = try row.b("checkpoint_model");
    v.anchor.terminal.kind = try row.t("checkpoint_terminal_kind");
    v.anchor.terminal.id = try row.u("checkpoint_terminal_id");
    v.anchor.binding_epoch = try row.u("checkpoint_binding_epoch");
    return v;
}

comptime {
    if (std.meta.fields(wire.StateWire).len != 9) @compileError("Review every history SQL field mapping after StateWire changes");
    if (std.meta.fields(wire.TaskFailureWire).len != 3) @compileError("Review every history SQL field mapping after TaskFailureWire changes");
    if (std.meta.fields(wire.WorkspaceWire).len != 8) @compileError("Review every history SQL field mapping after WorkspaceWire changes");
    if (std.meta.fields(wire.TaskWire).len != 26) @compileError("Review every history SQL field mapping after TaskWire changes");
    if (std.meta.fields(wire.ModelIntentWire).len != 3) @compileError("Review every history SQL field mapping after ModelIntentWire changes");
    // model_error is a nullable typed JSON value read and written with its Run.
    if (std.meta.fields(wire.RunWire).len != 33) @compileError("Review every history SQL field mapping after RunWire changes");
    // batch.json/row.json preserve the full typed input, including its reading anchor.
    if (std.meta.fields(wire.AdditionalInputWire).len != 11) @compileError("Review history input JSON mapping after AdditionalInputWire changes");
    if (std.meta.fields(wire.ToolWire).len != 14) @compileError("Review every history SQL field mapping after ToolWire changes");
    if (std.meta.fields(wire.FileChangeWire).len != 11) @compileError("Review every history SQL field mapping after FileChangeWire changes");
    if (std.meta.fields(wire.CompactWire).len != 11) @compileError("Review every history SQL field mapping after CompactWire changes");
    if (std.meta.fields(wire.UiRecordWire).len != 13) @compileError("Review every history SQL field mapping after UiRecordWire changes");
    if (std.meta.fields(wire.CheckpointWire).len != 3) @compileError("Review every history SQL field mapping after CheckpointWire changes");
    if (std.meta.fields(wire.CheckpointBlobWire).len != 3) @compileError("Review history fixture coverage after CheckpointBlobWire changes");
    if (std.meta.fields(wire.CheckpointSessionWire).len != 4) @compileError("Review history fixture coverage after CheckpointSessionWire changes");
    if (std.meta.fields(wire.CheckpointAnchorWire).len != 2) @compileError("Review history fixture coverage after CheckpointAnchorWire changes");
    if (std.meta.fields(wire.CheckpointTerminalWire).len != 2) @compileError("Review history fixture coverage after CheckpointTerminalWire changes");
    if (std.meta.fields(wire.BindingWire).len != 4) @compileError("Review history fixture coverage after BindingWire changes");
    if (std.meta.fields(wire.OperationWire).len != 2) @compileError("Review history fixture coverage after OperationWire changes");
    if (std.meta.fields(wire.RunInputWire).len != 9) @compileError("Review history fixture coverage after RunInputWire changes");
    if (std.meta.fields(wire.AttachmentWire).len != 5) @compileError("Review history fixture coverage after AttachmentWire changes");
    if (std.meta.fields(wire.FileReferencePositionWire).len != 2) @compileError("Review history fixture coverage after FileReferencePositionWire changes");
    if (std.meta.fields(wire.FileReferenceRangeWire).len != 2) @compileError("Review history fixture coverage after FileReferenceRangeWire changes");
    // generated_image is preserved inside file_refs_json; history_schema_test covers absent/false/true.
    if (std.meta.fields(wire.FileReferenceWire).len != 10) @compileError("Review history fixture coverage after FileReferenceWire changes");
    if (std.meta.fields(wire.FileChangeArtifactWire).len != 4) @compileError("Review history fixture coverage after FileChangeArtifactWire changes");
    if (std.meta.fields(wire.UsageWire).len != 4) @compileError("Review history fixture coverage after UsageWire changes");
    if (std.meta.fields(wire.PermissionSummaryWire).len != 11) @compileError("Review history fixture coverage after PermissionSummaryWire changes");
}
