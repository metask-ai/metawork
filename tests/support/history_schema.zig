//! Test-only history bindings and observation. Never imported by Product code.
const std = @import("std");
const sql = @import("metawork_storage_sql");
pub const wire = @import("product_task_persistence");

pub const limits: wire.Limits = .{
    .max_workspaces = 16,
    .max_tasks = 50,
    .max_runs_per_task = 16,
    .max_compacts_per_task = 16,
    .max_tools_per_run = 32,
    .max_commentary_segments_per_run = 256,
    .max_file_refs_per_tool = 32,
    .max_file_changes_per_run = 256,
    .max_ui_history_per_task = 8,
    .max_workspace_bytes = 16 * 1024,
    .max_task_title_bytes = 512,
    .max_user_message_bytes = 64 * 1024,
    .max_assistant_message_bytes = 256 * 1024,
    .max_tool_field_bytes = 256 * 1024,
    .max_file_ref_field_bytes = 8192,
    .max_execution_model_bytes = 512,
    .max_terminal_diagnostic_bytes = 512,
};

pub fn fixture(allocator: std.mem.Allocator) !wire.StateWire {
    const state = try std.json.parseFromSliceLeaky(wire.StateWire, allocator, @embedFile("history_schema_full.json"), .{ .allocate = .alloc_always });
    if (wire.validateCandidate(&state, limits) != null) return error.InvalidFixture;
    return state;
}

pub const Batch = struct {
    allocator: std.mem.Allocator,
    mutations: std.ArrayList(sql.Mutation) = .empty,
    pending_table: []const u8 = "",
    pending_sql: std.ArrayList(u8) = .empty,
    params: std.ArrayList(sql.Value) = .empty,

    fn add(self: *@This(), comptime table: []const u8, values: anytype) !void {
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

pub fn batchFor(allocator: std.mem.Allocator, state: wire.StateWire) !Batch {
    if (wire.validateCandidate(&state, limits) != null) return error.Invalid;
    var batch = Batch{ .allocator = allocator };
    try writeState(&batch, state);
    for (state.failures, 0..) |value, ordinal| try writeFailure(&batch, value, ordinal);
    for (state.workspaces, 0..) |value, ordinal| try writeWorkspace(&batch, value, ordinal);
    for (state.tasks, 0..) |task, ordinal| try writeTask(&batch, task, ordinal);
    for (state.tasks) |task| for (task.runs, 0..) |run, ordinal| {
        try writeRun(&batch, run, task.id, ordinal);
    };
    for (state.tasks) |task| for (task.runs) |run| for (run.tools, 0..) |tool, ordinal| {
        try writeTool(&batch, tool, task.id, run.id, ordinal);
    };
    for (state.tasks) |task| for (task.runs) |run| if (run.file_changes) |changes| {
        for (changes, 0..) |change, ordinal| try writeChange(&batch, change, task.id, run.id, ordinal);
    };
    for (state.tasks) |task| for (task.compacts, 0..) |value, ordinal| {
        try writeCompact(&batch, value, task.id, ordinal);
    };
    for (state.tasks) |task| for (task.ui_history, 0..) |value, ordinal| {
        try writeUi(&batch, value, task.id, ordinal);
    };
    for (state.tasks) |task| if (task.checkpoint) |value| {
        try writeCheckpoint(&batch, value, task.id);
    };
    try batch.flush();
    return batch;
}

/// All calls below run against an isolated test database with no concurrent writer.
/// This is not an implementation of a cross-query production snapshot.
pub fn load(allocator: std.mem.Allocator, database: sql.Database) !wire.StateWire {
    const roots = try query(allocator, database, "SELECT * FROM history_state", &.{});
    if (roots.values.items.len == 0) {
        const existing = try query(allocator, database, "SELECT (SELECT COUNT(*) FROM history_failures)+(SELECT COUNT(*) FROM workspaces)+(SELECT COUNT(*) FROM tasks)+(SELECT COUNT(*) FROM runs)+(SELECT COUNT(*) FROM run_tools)+(SELECT COUNT(*) FROM run_file_changes)+(SELECT COUNT(*) FROM task_compacts)+(SELECT COUNT(*) FROM task_ui_history)+(SELECT COUNT(*) FROM task_checkpoints) AS total", &.{});
        if (try existing.row(0).i("total") != 0) return error.MissingState;
        return error.EmptyHistory;
    }
    if (roots.values.items.len != 1) return error.Invalid;
    var state = try readState(roots.row(0));
    const workspaces = try query(allocator, database, "SELECT * FROM workspaces ORDER BY ordinal", &.{});
    state.workspaces = try allocator.alloc(wire.WorkspaceWire, workspaces.values.items.len);
    for (state.workspaces, 0..) |*value, index| value.* = try readWorkspace(workspaces.row(index));
    const failures = try query(allocator, database, "SELECT * FROM history_failures ORDER BY ordinal", &.{});
    state.failures = try allocator.alloc(wire.TaskFailureWire, failures.values.items.len);
    for (state.failures, 0..) |*value, index| value.* = try readFailure(failures.row(index));
    const tasks = try query(allocator, database, "SELECT * FROM tasks ORDER BY ordinal", &.{});
    state.tasks = try allocator.alloc(wire.TaskWire, tasks.values.items.len);
    var bindings = Batch{ .allocator = allocator };
    for (state.tasks, 0..) |*task, index| {
        task.* = try readTask(tasks.row(index));
        const task_params = &.{try bindings.u(task.id)};
        const runs = try query(allocator, database, "SELECT * FROM runs WHERE task_id=?1 ORDER BY ordinal", task_params);
        task.runs = try allocator.alloc(wire.RunWire, runs.values.items.len);
        for (task.runs, 0..) |*run, run_index| {
            run.* = try readRun(runs.row(run_index));
            const run_params = &.{ try bindings.u(task.id), try bindings.u(run.id) };
            const tools = try query(allocator, database, "SELECT * FROM run_tools WHERE task_id=?1 AND run_id=?2 ORDER BY ordinal", run_params);
            run.tools = try allocator.alloc(wire.ToolWire, tools.values.items.len);
            for (run.tools, 0..) |*value, child| value.* = try readTool(tools.row(child));
            const changes = try query(allocator, database, "SELECT * FROM run_file_changes WHERE task_id=?1 AND run_id=?2 ORDER BY ordinal", run_params);
            if (run.file_change_observation != null) {
                const values = try allocator.alloc(wire.FileChangeWire, changes.values.items.len);
                for (values, 0..) |*value, child| value.* = try readChange(changes.row(child));
                run.file_changes = values;
            } else if (changes.values.items.len != 0) return error.Invalid;
        }
        const compacts = try query(allocator, database, "SELECT * FROM task_compacts WHERE task_id=?1 ORDER BY ordinal", task_params);
        task.compacts = try allocator.alloc(wire.CompactWire, compacts.values.items.len);
        for (task.compacts, 0..) |*value, child| value.* = try readCompact(compacts.row(child));
        const ui = try query(allocator, database, "SELECT * FROM task_ui_history WHERE task_id=?1 ORDER BY ordinal", task_params);
        task.ui_history = try allocator.alloc(wire.UiRecordWire, ui.values.items.len);
        for (task.ui_history, 0..) |*value, child| value.* = try readUi(ui.row(child));
        const checkpoints = try query(allocator, database, "SELECT * FROM task_checkpoints WHERE task_id=?1", task_params);
        if (checkpoints.values.items.len > 1) return error.Invalid;
        if (checkpoints.values.items.len == 1) task.checkpoint = try readCheckpoint(checkpoints.row(0));
    }
    if (wire.validateCandidate(&state, limits) != null) return error.Invalid;
    return state;
}

fn writeState(batch: *Batch, v: wire.StateWire) !void {
    try batch.add("history_state", .{
        .singleton = try integer(1),
        .default_permission_profile = t(v.default_permission_profile),
        .next_workspace_id = try batch.u(v.next_workspace_id),
        .next_workspace_recent_order = try batch.u(v.next_workspace_recent_order),
        .next_task_id = try batch.u(v.next_task_id),
        .next_task_recent_order = try batch.u(v.next_task_recent_order),
    });
}

fn readState(row: Record) !wire.StateWire {
    var v: wire.StateWire = undefined;
    v.default_permission_profile = try row.t("default_permission_profile");
    v.next_workspace_id = try row.u("next_workspace_id");
    v.next_workspace_recent_order = try row.u("next_workspace_recent_order");
    v.next_task_id = try row.u("next_task_id");
    v.next_task_recent_order = try row.u("next_task_recent_order");
    v.workspaces = &.{};
    v.tasks = &.{};
    v.failures = &.{};
    return v;
}

fn writeFailure(batch: *Batch, v: wire.TaskFailureWire, ordinal: usize) !void {
    try batch.add("history_failures", .{
        .ordinal = try integer(ordinal),
        .task_id = try batch.u(v.task_id),
        .recent_order = try batch.u(v.recent_order),
        .reason = b(v.reason),
    });
}

fn readFailure(row: Record) !wire.TaskFailureWire {
    var v: wire.TaskFailureWire = undefined;
    v.task_id = try row.u("task_id");
    v.recent_order = try row.u("recent_order");
    v.reason = try row.b("reason");
    return v;
}

fn writeWorkspace(batch: *Batch, v: wire.WorkspaceWire, ordinal: usize) !void {
    try batch.add("workspaces", .{
        .ordinal = try integer(ordinal),
        .id = try batch.u(v.id),
        .epoch = try batch.u(v.epoch),
        .kind = t(v.kind),
        .canonical_root = b(v.canonical_root),
        .display_name = b(v.display_name),
        .visible = boolean(v.visible),
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
    v.recent_order = try row.u("recent_order");
    return v;
}

fn writeTask(batch: *Batch, v: wire.TaskWire, ordinal: usize) !void {
    try batch.add("tasks", .{
        .ordinal = try integer(ordinal),
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
        .binding_epoch = try batch.u(v.binding.epoch),
        .execution_generation = try batch.u(v.binding.execution_generation),
        .protocol = t(v.binding.protocol),
        .model = b(v.binding.model),
        .next_run_generation = try batch.u(v.next_run_generation),
        .checkpoint_anchor = t(v.checkpoint_anchor),
        .checkpoint_attempt = t(v.checkpoint_attempt),
        .active_operation_kind = ot(if (v.active_operation) |op| op.kind else null),
        .active_operation_id = try batch.ou(if (v.active_operation) |op| op.id else null),
    });
}

fn readTask(row: Record) !wire.TaskWire {
    try row.optionalGroup(.{ "active_operation_kind", "active_operation_id" });
    var v: wire.TaskWire = undefined;
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
    v.binding.epoch = try row.u("binding_epoch");
    v.binding.execution_generation = try row.u("execution_generation");
    v.binding.protocol = try row.t("protocol");
    v.binding.model = try row.b("model");
    v.next_run_generation = try row.u("next_run_generation");
    v.checkpoint_anchor = try row.t("checkpoint_anchor");
    v.checkpoint_attempt = try row.t("checkpoint_attempt");
    v.active_operation = if (try row.ot("active_operation_kind")) |kind| .{ .kind = kind, .id = try row.u("active_operation_id") } else null;
    v.runs = &.{};
    v.compacts = &.{};
    v.ui_history = &.{};
    v.checkpoint = null;
    return v;
}

fn writeRun(batch: *Batch, v: wire.RunWire, task_id: u64, ordinal: usize) !void {
    try batch.add("runs", .{
        .task_id = try batch.u(task_id),
        .ordinal = try integer(ordinal),
        .id = try batch.u(v.id),
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
        .submitted_at_unix_ms = try oi(v.submitted_at_unix_ms),
        .finished_at_unix_ms = try oi(v.finished_at_unix_ms),
        .phase = t(v.phase),
        .outcome = ot(v.outcome),
        .cause = ot(v.cause),
        .input_json = try batch.json(v.input),
        .commentary_ends_json = try batch.json(v.commentary_ends),
        .file_change_observation = ot(v.file_change_observation),
        .diagnostic = b(v.diagnostic),
        .diagnostic_truncated = boolean(v.diagnostic_truncated),
        .diagnostic_redacted = boolean(v.diagnostic_redacted),
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
    v.submitted_at_unix_ms = try row.oi("submitted_at_unix_ms");
    v.finished_at_unix_ms = try row.oi("finished_at_unix_ms");
    v.phase = try row.t("phase");
    v.outcome = try row.ot("outcome");
    v.cause = try row.ot("cause");
    v.input = try row.json(wire.RunInputWire, "input_json");
    v.commentary_ends = try row.json([]const u64, "commentary_ends_json");
    v.file_change_observation = try row.ot("file_change_observation");
    v.diagnostic = try row.b("diagnostic");
    v.diagnostic_truncated = try row.boolean("diagnostic_truncated");
    v.diagnostic_redacted = try row.boolean("diagnostic_redacted");
    v.event_projection_failure = try row.ot("event_projection_failure");
    v.next_activity_order = try row.u("next_activity_order");
    v.usage.input_tokens = try row.u("input_tokens");
    v.usage.output_tokens = try row.u("output_tokens");
    v.usage.cache_read_input_tokens = try row.u("cache_read_input_tokens");
    v.usage.cache_creation_input_tokens = try row.u("cache_creation_input_tokens");
    v.tools = &.{};
    v.file_changes = if (v.file_change_observation == null) null else &.{};
    return v;
}

fn writeTool(batch: *Batch, v: wire.ToolWire, task_id: u64, run_id: u64, ordinal: usize) !void {
    try batch.add("run_tools", .{
        .task_id = try batch.u(task_id),
        .run_id = try batch.u(run_id),
        .ordinal = try integer(ordinal),
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

fn writeChange(batch: *Batch, v: wire.FileChangeWire, task_id: u64, run_id: u64, ordinal: usize) !void {
    try batch.add("run_file_changes", .{
        .task_id = try batch.u(task_id),
        .run_id = try batch.u(run_id),
        .ordinal = try integer(ordinal),
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

fn writeCompact(batch: *Batch, v: wire.CompactWire, task_id: u64, ordinal: usize) !void {
    try batch.add("task_compacts", .{
        .task_id = try batch.u(task_id),
        .ordinal = try integer(ordinal),
        .id = try batch.u(v.id),
        .after_run_id = try batch.u(v.after_run_id),
        .phase = t(v.phase),
        .cause = ot(v.cause),
        .before_context_tokens = try batch.u(v.before_context_tokens),
        .after_context_tokens = try batch.u(v.after_context_tokens),
        .diagnostic = b(v.diagnostic),
        .diagnostic_truncated = boolean(v.diagnostic_truncated),
        .diagnostic_redacted = boolean(v.diagnostic_redacted),
        .input_tokens = try batch.u(v.usage.input_tokens),
        .output_tokens = try batch.u(v.usage.output_tokens),
        .cache_read_input_tokens = try batch.u(v.usage.cache_read_input_tokens),
        .cache_creation_input_tokens = try batch.u(v.usage.cache_creation_input_tokens),
    });
}

fn readCompact(row: Record) !wire.CompactWire {
    var v: wire.CompactWire = undefined;
    v.id = try row.u("id");
    v.after_run_id = try row.u("after_run_id");
    v.phase = try row.t("phase");
    v.cause = try row.ot("cause");
    v.before_context_tokens = try row.u("before_context_tokens");
    v.after_context_tokens = try row.u("after_context_tokens");
    v.diagnostic = try row.b("diagnostic");
    v.diagnostic_truncated = try row.boolean("diagnostic_truncated");
    v.diagnostic_redacted = try row.boolean("diagnostic_redacted");
    v.usage.input_tokens = try row.u("input_tokens");
    v.usage.output_tokens = try row.u("output_tokens");
    v.usage.cache_read_input_tokens = try row.u("cache_read_input_tokens");
    v.usage.cache_creation_input_tokens = try row.u("cache_creation_input_tokens");
    return v;
}

fn writeUi(batch: *Batch, v: wire.UiRecordWire, task_id: u64, ordinal: usize) !void {
    try batch.add("task_ui_history", .{
        .task_id = try batch.u(task_id),
        .ordinal = try integer(ordinal),
        .activity_order = try batch.u(v.order),
        .request_id = try batch.u(v.request_id),
        .run_id = try batch.u(v.run_id),
        .kind = t(v.kind),
        .state = t(v.state),
        .detail = b(v.detail),
        .item_count = try integer(v.item_count),
        .detail_truncated = boolean(v.detail_truncated),
        .redacted = boolean(v.redacted),
        .agent_request_id = b(v.agent_request_id),
        .permission_json = try batch.ojson(v.permission),
    });
}

fn readUi(row: Record) !wire.UiRecordWire {
    var v: wire.UiRecordWire = undefined;
    v.order = try row.u("activity_order");
    v.request_id = try row.u("request_id");
    v.run_id = try row.u("run_id");
    v.kind = try row.t("kind");
    v.state = try row.t("state");
    v.detail = try row.b("detail");
    v.item_count = std.math.cast(u32, try row.i("item_count")) orelse return error.Invalid;
    v.detail_truncated = try row.boolean("detail_truncated");
    v.redacted = try row.boolean("redacted");
    v.agent_request_id = try row.b("agent_request_id");
    v.permission = try row.ojson(wire.PermissionSummaryWire, "permission_json");
    return v;
}

fn writeCheckpoint(batch: *Batch, v: wire.CheckpointWire, task_id: u64) !void {
    try batch.add("task_checkpoints", .{
        .task_id = try batch.u(task_id),
        .generation = try batch.u(v.blob.generation),
        .byte_size = try batch.u(v.blob.byte_size),
        .digest = try batch.digest(v.blob.digest),
        .logical_session_id = b(v.session.logical_session_id),
        .last_run_id = try batch.u(v.session.last_run_id),
        .last_compact_id = try batch.u(v.session.last_compact_id),
        .model = b(v.session.model),
        .terminal_kind = t(v.anchor.terminal.kind),
        .terminal_id = try batch.u(v.anchor.terminal.id),
        .binding_epoch = try batch.u(v.anchor.binding_epoch),
    });
}

fn readCheckpoint(row: Record) !wire.CheckpointWire {
    var v: wire.CheckpointWire = undefined;
    v.blob.generation = try row.u("generation");
    v.blob.byte_size = try row.u("byte_size");
    v.blob.digest = try row.digest("digest");
    v.session.logical_session_id = try row.b("logical_session_id");
    v.session.last_run_id = try row.u("last_run_id");
    v.session.last_compact_id = try row.u("last_compact_id");
    v.session.model = try row.b("model");
    v.anchor.terminal.kind = try row.t("terminal_kind");
    v.anchor.terminal.id = try row.u("terminal_id");
    v.anchor.binding_epoch = try row.u("binding_epoch");
    return v;
}

comptime {
    if (std.meta.fields(wire.StateWire).len != 8) @compileError("Review every history SQL field mapping after StateWire changes");
    if (std.meta.fields(wire.TaskFailureWire).len != 3) @compileError("Review every history SQL field mapping after TaskFailureWire changes");
    if (std.meta.fields(wire.WorkspaceWire).len != 7) @compileError("Review every history SQL field mapping after WorkspaceWire changes");
    if (std.meta.fields(wire.TaskWire).len != 20) @compileError("Review every history SQL field mapping after TaskWire changes");
    if (std.meta.fields(wire.RunWire).len != 27) @compileError("Review every history SQL field mapping after RunWire changes");
    if (std.meta.fields(wire.ToolWire).len != 14) @compileError("Review every history SQL field mapping after ToolWire changes");
    if (std.meta.fields(wire.FileChangeWire).len != 11) @compileError("Review every history SQL field mapping after FileChangeWire changes");
    if (std.meta.fields(wire.CompactWire).len != 10) @compileError("Review every history SQL field mapping after CompactWire changes");
    if (std.meta.fields(wire.UiRecordWire).len != 11) @compileError("Review every history SQL field mapping after UiRecordWire changes");
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
    if (std.meta.fields(wire.FileReferenceWire).len != 7) @compileError("Review history fixture coverage after FileReferenceWire changes");
    if (std.meta.fields(wire.FileChangeArtifactWire).len != 4) @compileError("Review history fixture coverage after FileChangeArtifactWire changes");
    if (std.meta.fields(wire.UsageWire).len != 4) @compileError("Review history fixture coverage after UsageWire changes");
    if (std.meta.fields(wire.PermissionSummaryWire).len != 10) @compileError("Review history fixture coverage after PermissionSummaryWire changes");
}
