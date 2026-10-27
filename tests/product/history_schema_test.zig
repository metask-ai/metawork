const std = @import("std");
const schema = @import("product_control_history_schema");
const sql = @import("metawork_storage_sql");
const storage = @import("storage");
const fixture_support = @import("history_schema_fixture");
const history = struct {
    pub const wire = fixture_support.wire;
    pub const limits = fixture_support.limits;
    pub const fixture = @import("history_schema_fixture").fixture;
    pub const Batch = schema.codec.Batch;
    pub fn batchFor(allocator: std.mem.Allocator, state: wire.StateWire) !Batch {
        return schema.codec.batchFor(allocator, state, limits);
    }
    pub fn load(allocator: std.mem.Allocator, database: sql.Database) !wire.StateWire {
        return schema.codec.load(allocator, database, limits);
    }
};

fn save(allocator: std.mem.Allocator, database: sql.Database, state: history.wire.StateWire) !history.Batch {
    const buffer = try allocator.alloc(u8, history.wire.max_store_bytes);
    _ = try history.wire.encode(buffer, state, history.limits);
    const batch = try history.batchFor(allocator, state);
    try std.testing.expectEqual(sql.MutationOutcome.committed, database.mutate(batch.mutations.items));
    return batch;
}

fn expectSame(allocator: std.mem.Allocator, database: sql.Database, expected: history.wire.StateWire) !void {
    const actual = try history.load(allocator, database);
    const expected_buffer = try std.testing.allocator.alloc(u8, history.wire.max_store_bytes);
    defer std.testing.allocator.free(expected_buffer);
    const actual_buffer = try std.testing.allocator.alloc(u8, history.wire.max_store_bytes);
    defer std.testing.allocator.free(actual_buffer);
    try std.testing.expectEqualSlices(u8, try history.wire.encode(expected_buffer, expected, history.limits), try history.wire.encode(actual_buffer, actual, history.limits));
}

fn temporaryPath(allocator: std.mem.Allocator, dir: std.Io.Dir) ![]const u8 {
    var bytes: [std.fs.max_path_bytes]u8 = undefined;
    const len = try dir.realPath(std.testing.io, &bytes);
    return std.fs.path.join(allocator, &.{ bytes[0..len], "history.db" });
}

test "history schema preserves optional source-qualified Task model intent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const state = try history.fixture(allocator);
    for ([_]?history.wire.ModelIntentWire{
        null,
        .{ .source_id = "metask", .model_id = "next-model", .revision = 7 },
        .{ .source_id = "custom-provider-00000000000000000000000000000001", .model_id = "模型-世", .revision = std.math.maxInt(u64) },
    }) |intent| {
        const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .memory, schema.migrations);
        defer database.destroy() catch unreachable;
        state.tasks[0].model_intent = intent;
        _ = try save(allocator, database.capability(), state);
        try expectSame(allocator, database.capability(), state);
    }
}

test "history input JSON preserves reading anchors beyond surviving output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const state = try history.fixture(allocator);
    state.tasks[0].runs[0].additional_inputs = try allocator.dupe(history.wire.AdditionalInputWire, &.{.{
        .id = 1,
        .after_output_count = 2,
        .operation_id = "input-1",
        .text = "follow up",
        .redacted = false,
        .sequence = 1,
        .adopted_turn = null,
        .order = null,
        .state = "unadopted",
    }});
    const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .memory, schema.migrations);
    defer database.destroy() catch unreachable;
    _ = try save(allocator, database.capability(), state);
    try expectSame(allocator, database.capability(), state);
}

test "history schema preserves null empty and nonterminal history variants" {
    for (0..4) |variant| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const state = try history.fixture(allocator);
        const task = &state.tasks[0];
        const run = &task.runs[0];
        task.archived = false;
        task.completion_seen_run_id = 0;
        task.checkpoint = null;
        task.checkpoint_anchor = "none";
        task.checkpoint_attempt = "none";
        switch (variant) {
            0 => {
                task.completion_seen_run_id = null;
                run.input = .{ .kind = "text", .text = "text\x00世", .skill_id = null, .catalog_revision = null, .invocation_name = null, .display_name = null, .argument_values = null, .redacted = false };
                run.submitted_at_unix_ms = null;
                run.finished_at_unix_ms = null;
                run.assistant = "";
                run.commentary_ends = &.{};
                run.assistant_output_kind = null;
                run.assistant_output_start = null;
                run.file_change_observation = null;
                run.file_changes = null;
                run.tools[0].file_refs = null;
                task.ui_history[0].permission = null;
                task.ui_history[0].agent_request_id = "";
            },
            1 => {
                const attachments = try allocator.dupe(history.wire.AttachmentWire, &.{
                    .{ .kind = "image", .format = "png", .display_name = "image 世", .size_bytes = 123, .redacted = true },
                    .{ .kind = "file", .format = null, .display_name = "text\x00file", .size_bytes = std.math.maxInt(u64), .redacted = false },
                });
                run.input = .{ .kind = "multimodal", .text = null, .skill_id = null, .catalog_revision = null, .invocation_name = null, .display_name = null, .argument_values = null, .attachments = attachments, .redacted = false };
                run.file_change_observation = "complete";
                run.file_changes = &.{};
                run.tools[0].file_refs = &.{};
                run.phase = "failed";
                run.outcome = "dependency_contract_failure";
                run.cause = "agent_failure";
                run.event_projection_failure = "consumer_rejected";
            },
            2 => {
                run.coverage = "pending";
                run.phase = "waiting_ui";
                run.outcome = null;
                run.cause = null;
                run.finished_at_unix_ms = null;
                run.file_change_observation = "collecting";
                run.file_changes.?[0].artifact = null;
                run.tools[0].state = "running";
                run.tools[0].file_refs.?[0].range = null;
                task.compacts = &.{};
                task.active_operation = .{ .kind = "run", .id = run.id };
            },
            3 => {
                task.compacts[0].coverage = "pending";
                task.compacts[0].phase = "compacting";
                task.compacts[0].cause = null;
                task.active_operation = .{ .kind = "compact", .id = task.compacts[0].id };
                run.tools[0].state = "failed";
                run.tools[0].is_error = true;
                run.file_changes.?[0].kind = "modified";
                run.file_changes.?[0].from_display_path = null;
                run.file_changes.?[0].artifact = null;
            },
            else => unreachable,
        }
        const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .memory, schema.migrations);
        defer database.destroy() catch unreachable;
        _ = try save(allocator, database.capability(), state);
        try expectSame(allocator, database.capability(), state);
    }
}

test "history schema reopens the same identity and rejects changed or older migration inputs" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const path = try temporaryPath(allocator, temporary.dir);
    const state = try history.fixture(allocator);
    {
        const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .{ .file = path }, schema.migrations);
        defer database.destroy() catch unreachable;
        _ = try save(allocator, database.capability(), state);
    }
    const changed = [_]sql.Migration{.{ .version = 1, .name = schema.migrations[0].name, .sql = schema.migrations[0].sql ++ "\n" }};
    try std.testing.expectError(error.MigrationMismatch, storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .{ .file = path }, &changed));
    try std.testing.expectError(error.VersionUnknown, storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .{ .file = path }, &.{}));
    {
        const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .{ .file = path }, schema.migrations);
        defer database.destroy() catch unreachable;
        try expectSame(allocator, database.capability(), state);
    }
}

const upgrade = sql.Migration{
    .version = schema.migrations.len + 1,
    .name = "test_only_add_note",
    .sql = "ALTER TABLE tasks ADD COLUMN test_note BLOB; CREATE INDEX test_runs_phase ON runs(phase); UPDATE tasks SET test_note=X'6f6b';",
};

test "history schema preserves permission review delegation and reviewer audit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var state = try history.fixture(allocator);
    const task = &state.tasks[0];
    state.default_permission_profile = "approval_required";
    state.default_approval_mode = "auto_review";
    task.permission_profile = "approval_required";
    task.permission_review_delegated = true;
    for (task.runs) |*run| run.permission_profile = "approval_required";
    task.ui_history[0].state = "allowed_once";
    task.ui_history[0].answered_by = "reviewer";
    task.ui_history[0].review_reason = "Bounded *** operation.";
    const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .memory, schema.migrations);
    defer database.destroy() catch unreachable;
    _ = try save(allocator, database.capability(), state);
    try expectSame(allocator, database.capability(), state);
}

test "history schema rejects structural counterexamples and rolls back the preceding write" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var state = try history.fixture(allocator);
    var spare_workspace = state.workspaces[0];
    spare_workspace.id = 2;
    spare_workspace.canonical_root = "/other";
    spare_workspace.recent_order = 8;
    state.workspaces = try allocator.dupe(history.wire.WorkspaceWire, &.{ state.workspaces[0], spare_workspace });
    var spare_task = state.tasks[0];
    spare_task.id = 6;
    spare_task.workspace_id = 2;
    spare_task.workspace_root = "/other";
    spare_task.recent_order = 42;
    spare_task.completion_seen_run_id = null;
    spare_task.runs = &.{};
    spare_task.compacts = &.{};
    spare_task.ui_history = &.{};
    spare_task.checkpoint = null;
    spare_task.checkpoint_anchor = "none";
    spare_task.next_run_generation = 0;
    state.tasks = try allocator.dupe(history.wire.TaskWire, &.{ state.tasks[0], spare_task });
    state.next_task_recent_order = 43;
    var second_run = state.tasks[0].runs[0];
    second_run.id = 14;
    second_run.generation = 15;
    second_run.tools = &.{};
    second_run.file_changes = null;
    second_run.file_change_observation = null;
    state.tasks[0].runs = try allocator.dupe(history.wire.RunWire, &.{ state.tasks[0].runs[0], second_run });
    state.tasks[0].next_run_generation = 16;
    const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .memory, schema.migrations);
    defer database.destroy() catch unreachable;
    _ = try save(allocator, database.capability(), state);
    // Workspace and Task array order intentionally differs from identity order.
    try expectSame(allocator, database.capability(), state);
    for ([_][]const u8{
        "UPDATE runs SET task_id=NULL",
        "UPDATE runs SET generation=X'00'",
        "UPDATE runs SET generation=13",
        "UPDATE runs SET ordinal=0.5",
        "UPDATE tasks SET archived=2",
        "UPDATE tasks SET checkpoint_anchor='unknown'",
        "UPDATE tasks SET checkpoint_attempt='unknown'",
        "UPDATE tasks SET checkpoint_digest=NULL",
        "UPDATE tasks SET checkpoint_byte_size=X'0000000000000000'",
        "UPDATE tasks SET checkpoint_terminal_kind='unknown'",
        "UPDATE task_ui_history SET payload=NULL",
        "UPDATE task_compacts SET payload=X'5b5d'",
        "UPDATE history_state SET failures_json=NULL",
        "UPDATE tasks SET active_operation_id=X'000000000000000b'",
        "UPDATE runs SET assistant_output_start=NULL",
        "UPDATE run_file_changes SET artifact_digest=NULL",
        "UPDATE run_file_changes SET from_display_path=NULL",
        "UPDATE run_tools SET is_error=1",
        "UPDATE run_tools SET task_id=X'0000000000000006'",
        "UPDATE tasks SET workspace_id=X'00000000000000ff'",
        "UPDATE tasks SET ordinal=0 WHERE id=X'0000000000000006'",
        "UPDATE runs SET generation=X'000000000000000d' WHERE id=X'000000000000000e'",
        "UPDATE workspaces SET canonical_root=(SELECT canonical_root FROM workspaces WHERE id=X'0000000000000003') WHERE id=X'0000000000000002'",
        "UPDATE runs SET submitted_at_unix_ms=-1",
    }) |invalid| {
        try std.testing.expectEqual(sql.MutationOutcome.constraint, database.capability().mutate(&.{
            .{ .statement = .{ .sql = "UPDATE tasks SET title=X'6368616e676564'" } },
            .{ .statement = .{ .sql = invalid } },
        }));
        try expectSame(allocator, database.capability(), state);
    }
}

test "history loader refuses invalid domain data instead of silently producing empty history" {
    for ([_][]const u8{
        "UPDATE tasks SET title=X'ff'",
        "UPDATE runs SET file_change_observation=NULL",
        "UPDATE runs SET input_json='{}'",
        "UPDATE runs SET submitted_at_unix_ms=8640000000000001",
        "UPDATE tasks SET checkpoint_binding_epoch=X'0000000000000014'",
        "UPDATE tasks SET checkpoint_terminal_id=X'00000000000000ff'",
        "UPDATE tasks SET checkpoint_anchor='none'",
        "UPDATE task_ui_history SET payload='null'",
        "UPDATE task_compacts SET payload='{}'",
        "UPDATE history_state SET failures_json='['",
        "DELETE FROM history_state",
    }) |invalid| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const state = try history.fixture(allocator);
        const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .memory, schema.migrations);
        defer database.destroy() catch unreachable;
        try std.testing.expectError(error.EmptyHistory, history.load(allocator, database.capability()));
        _ = try save(allocator, database.capability(), state);
        try std.testing.expectEqual(sql.MutationOutcome.committed, database.capability().mutate(&.{.{ .statement = .{ .sql = invalid } }}));
        if (history.load(allocator, database.capability())) |_| {
            return error.InvalidHistoryAccepted;
        } else |_| {}
    }
}

test "merged history payloads retain Product validation after removing child constraints" {
    const Case = enum {
        compact_run,
        compact_duplicate,
        compact_count,
        compact_phase,
        compact_diagnostic,
        ui_run,
        ui_duplicate,
        ui_count,
        ui_order,
        ui_state,
        ui_detail,
        ui_permission,
        failure_id,
        failure_order,
        failure_reason,
        failure_count,
    };
    inline for (std.meta.tags(Case)) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var state = try history.fixture(allocator);
        const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .memory, schema.migrations);
        defer database.destroy() catch unreachable;
        _ = try save(allocator, database.capability(), state);
        const task = &state.tasks[0];
        switch (case) {
            .compact_run => task.compacts[0].after_run_id = 999,
            .compact_duplicate => task.compacts = try allocator.dupe(history.wire.CompactWire, &.{ task.compacts[0], task.compacts[0] }),
            .compact_count => {
                const template = task.compacts[0];
                task.compacts = try allocator.alloc(history.wire.CompactWire, history.limits.max_compacts_per_task + 1);
                for (task.compacts, 0..) |*compact, index| {
                    compact.* = template;
                    compact.id = index + 100;
                }
            },
            .compact_phase => task.compacts[0].phase = "unknown",
            .compact_diagnostic => task.compacts[0].diagnostic = "x" ** (history.limits.max_terminal_diagnostic_bytes + 1),
            .ui_run => task.ui_history[0].run_id = 999,
            .ui_duplicate => task.ui_history = try allocator.dupe(history.wire.UiRecordWire, &.{ task.ui_history[0], task.ui_history[0] }),
            .ui_count => {
                const template = task.ui_history[0];
                task.ui_history = try allocator.alloc(history.wire.UiRecordWire, history.limits.max_ui_history_per_task + 1);
                for (task.ui_history, 0..) |*ui, index| {
                    ui.* = template;
                    ui.request_id = index + 100;
                    ui.order = index + 100;
                }
                task.runs[0].next_activity_order = 200;
            },
            .ui_order => task.ui_history[0].order = task.runs[0].tools[0].order,
            .ui_state => task.ui_history[0].state = "unknown",
            .ui_detail => task.ui_history[0].detail = "x" ** 513,
            .ui_permission => task.ui_history[0].permission.?.request_id = "different-request",
            .failure_id => state.failures[0].task_id = 0,
            .failure_order => state.failures[0].recent_order = 0,
            .failure_reason => state.failures[0].reason = "x" ** (history.wire.max_failure_reason_bytes + 1),
            .failure_count => {
                const template = state.failures[0];
                state.failures = try allocator.alloc(history.wire.TaskFailureWire, history.wire.max_failure_records + 1);
                @memset(state.failures, template);
            },
        }
        var corruptions: std.ArrayList(sql.Mutation) = .empty;
        const compact_case = switch (case) {
            .compact_run, .compact_duplicate, .compact_count, .compact_phase, .compact_diagnostic => true,
            else => false,
        };
        const ui_case = switch (case) {
            .ui_run, .ui_duplicate, .ui_count, .ui_order, .ui_state, .ui_detail, .ui_permission => true,
            else => false,
        };
        if (compact_case or ui_case) {
            const table = if (compact_case) "task_compacts" else "task_ui_history";
            try corruptions.append(allocator, .{ .statement = .{ .sql = try std.fmt.allocPrint(allocator, "DELETE FROM {s}", .{table}) } });
            const count = if (compact_case) task.compacts.len else task.ui_history.len;
            for (0..count) |i| {
                const identity = try allocator.create([8]u8);
                const duplicate_case = case == .compact_duplicate or case == .ui_duplicate;
                std.mem.writeInt(u64, identity, if (duplicate_case) i + 100 else if (compact_case) task.compacts[i].id else task.ui_history[i].request_id, .big);
                const task_identity = try allocator.create([8]u8);
                std.mem.writeInt(u64, task_identity, task.id, .big);
                const payload = if (compact_case) try std.json.Stringify.valueAlloc(allocator, task.compacts[i], .{}) else try std.json.Stringify.valueAlloc(allocator, task.ui_history[i], .{});
                try corruptions.append(allocator, .{ .statement = .{ .sql = try std.fmt.allocPrint(allocator, "INSERT INTO {s}(task_id,{s},ordinal,payload) VALUES(?1,?2,?3,?4)", .{ table, if (compact_case) "id" else "request_id" }), .params = try allocator.dupe(sql.Value, &.{ .{ .blob = task_identity }, .{ .blob = identity }, .{ .integer = @intCast(i) }, .{ .text = payload } }) } });
            }
        } else {
            try corruptions.append(allocator, .{ .statement = .{ .sql = "UPDATE history_state SET failures_json=?1", .params = &.{.{ .text = try std.json.Stringify.valueAlloc(allocator, state.failures, .{}) }} } });
        }
        try std.testing.expectEqual(sql.MutationOutcome.committed, database.capability().mutate(corruptions.items));
        if (history.load(allocator, database.capability())) |_| return error.InvalidHistoryAccepted else |_| {}
    }
}

test "history unsigned values retain byte ordering and exact boundary equality" {
    const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .memory, schema.migrations);
    defer database.destroy() catch unreachable;
    const numbers = [_]u64{ 0, std.math.maxInt(i64), @as(u64, std.math.maxInt(i64)) + 1, std.math.maxInt(u64) };
    var encoded: [4][8]u8 = undefined;
    var ids: [4][8]u8 = undefined;
    for (numbers, 0..) |number, index| {
        std.mem.writeInt(u64, &encoded[index], number, .big);
        std.mem.writeInt(u64, &ids[index], index + 1, .big);
        try std.testing.expectEqual(sql.MutationOutcome.committed, database.capability().mutate(&.{.{ .statement = .{
            .sql = "INSERT INTO workspaces(ordinal,id,epoch,kind,canonical_root,display_name,visible,recent_order) VALUES(?1,?2,?2,'automatic',?2,X'61',0,?3)",
            .params = &.{ .{ .integer = @intCast(index) }, .{ .blob = &ids[index] }, .{ .blob = &encoded[index] } },
        } }}));
    }
    var sequence: Sequence = .{};
    try std.testing.expectEqual(sql.QueryOutcome.ok, database.capability().query("SELECT ordinal FROM workspaces ORDER BY recent_order", &.{}, sequence.receiver()));
    try std.testing.expect(!sequence.overflow);
    try std.testing.expectEqualSlices(i64, &.{ 0, 1, 2, 3 }, sequence.values[0..sequence.len]);
    sequence = .{};
    try std.testing.expectEqual(sql.QueryOutcome.ok, database.capability().query("SELECT ordinal FROM workspaces WHERE recent_order>=?1 ORDER BY recent_order", &.{.{ .blob = &encoded[2] }}, sequence.receiver()));
    try std.testing.expect(!sequence.overflow);
    try std.testing.expectEqualSlices(i64, &.{ 2, 3 }, sequence.values[0..sequence.len]);
    for (encoded, 0..) |bytes, index| {
        var count: Count = .{};
        try std.testing.expectEqual(sql.QueryOutcome.ok, database.capability().query("SELECT COUNT(*) FROM workspaces WHERE recent_order=?1 AND ordinal=?2", &.{ .{ .blob = &bytes }, .{ .integer = @intCast(index) } }, count.receiver()));
        try std.testing.expectEqual(@as(?i64, 1), count.value);
    }
}

const Sequence = struct {
    values: [4]i64 = undefined,
    len: usize = 0,
    overflow: bool = false,
    fn receive(context: *anyopaque, row: sql.Row) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (self.len >= self.values.len) {
            self.overflow = true;
            return;
        }
        self.values[self.len] = row.value(0).integer;
        self.len += 1;
    }
    fn receiver(self: *@This()) sql.RowReceiver {
        return .{ .context = self, .receive_fn = receive };
    }
};

test "history schema preserves approval revisions and the approval checkpoint union case" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const state = try history.fixture(allocator);
    state.tasks[0].approval_revision = std.math.maxInt(u64);
    state.tasks[0].checkpoint.?.anchor.terminal = .{ .kind = "approval", .id = std.math.maxInt(u64) };
    const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .memory, schema.migrations);
    defer database.destroy() catch unreachable;
    _ = try save(allocator, database.capability(), state);
    try expectSame(allocator, database.capability(), state);
    try std.testing.expectEqual(sql.MutationOutcome.constraint, database.capability().mutate(&.{.{ .statement = .{
        .sql = "UPDATE tasks SET approval_revision=X'0000000000000000'",
    } }}));
    try std.testing.expectEqual(sql.MutationOutcome.constraint, database.capability().mutate(&.{.{ .statement = .{
        .sql = "UPDATE tasks SET approval_revision=X'0000000000000001'",
    } }}));
    try std.testing.expectEqual(sql.MutationOutcome.constraint, database.capability().mutate(&.{.{ .statement = .{
        .sql = "UPDATE tasks SET checkpoint_terminal_kind='run',checkpoint_terminal_id=X'0000000000000001'",
    } }}));
    try expectSame(allocator, database.capability(), state);
    for ([_][]const u8{
        "UPDATE tasks SET approval_revision=1",
        "UPDATE tasks SET approval_revision=X'01'",
        "UPDATE tasks SET checkpoint_approval_revision=X'0000000000000000'",
        "UPDATE tasks SET checkpoint_approval_revision=NULL",
        "UPDATE tasks SET checkpoint_approval_json=NULL",
        "UPDATE tasks SET checkpoint_approval_json=X'7b7d'",
        "UPDATE tasks SET checkpoint_approval_json='{'",
    }) |statement| {
        try std.testing.expectEqual(sql.MutationOutcome.constraint, database.capability().mutate(&.{.{ .statement = .{ .sql = statement } }}));
        try expectSame(allocator, database.capability(), state);
    }
}

fn populated(allocator: std.mem.Allocator, tool_count: usize, change_count: usize, ui_count: usize) !history.wire.StateWire {
    const state = try history.fixture(allocator);
    const task = &state.tasks[0];
    const run = &task.runs[0];
    const tool_template = run.tools[0];
    run.tools = try allocator.alloc(history.wire.ToolWire, tool_count);
    for (run.tools, 0..) |*tool, index| {
        tool.* = tool_template;
        tool.id = try std.fmt.allocPrint(allocator, "tool-{d}", .{index});
        tool.order = index + 1;
    }
    const change_template = run.file_changes.?[0];
    const changes = try allocator.alloc(history.wire.FileChangeWire, change_count);
    for (changes, 0..) |*change, index| {
        change.* = change_template;
        change.order = tool_count + index + 1;
        change.id = try std.fmt.allocPrint(allocator, "change-{d}-{d}-{d}", .{ task.id, run.generation, change.order });
        change.artifact.?.change_order = change.order;
    }
    run.file_changes = changes;
    const ui_template = task.ui_history[0];
    task.ui_history = try allocator.alloc(history.wire.UiRecordWire, ui_count);
    for (task.ui_history, 0..) |*record, index| {
        record.* = ui_template;
        record.request_id = 100 + index;
        record.order = tool_count + change_count + index + 1;
    }
    run.next_activity_order = tool_count + change_count + ui_count + 1;
    return state;
}

fn parameterBytes(batch: history.Batch) usize {
    return fixture_support.parameterBytes(batch.mutations.items);
}

test "history populated round fits one real mutation and survives full field recovery" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const state = try populated(allocator, 32, 32, 8);
    const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .memory, schema.migrations);
    defer database.destroy() catch unreachable;
    const batch = try save(allocator, database.capability(), state);
    try std.testing.expect(batch.mutations.items.len <= sql.Limits.exec_statements);
    try std.testing.expect(sql.validMutations(batch.mutations.items));
    try expectSame(allocator, database.capability(), state);
}

test "merged history arrays preserve maximum counts escaped bytes order and unsigned values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var state = try populated(allocator, 32, 32, history.limits.max_ui_history_per_task);
    const task = &state.tasks[0];
    const compact_template = task.compacts[0];
    task.compacts = try allocator.alloc(history.wire.CompactWire, history.limits.max_compacts_per_task);
    for (task.compacts, 0..) |*compact, index| {
        compact.* = compact_template;
        compact.id = std.math.maxInt(u64) - index;
        compact.before_context_tokens = std.math.maxInt(u64);
        compact.after_context_tokens = std.math.maxInt(u64) - 1;
        compact.usage.output_tokens = std.math.maxInt(u64);
        compact.diagnostic = "\x00" ** history.limits.max_terminal_diagnostic_bytes;
    }
    task.checkpoint.?.session.last_compact_id = task.compacts[0].id;
    task.checkpoint.?.anchor.terminal.id = task.compacts[0].id;
    for (task.ui_history, 0..) |*record, index| {
        record.request_id = std.math.maxInt(u64) - index;
        record.item_count = std.math.maxInt(u32);
        record.detail = "\x00" ** 512;
        record.agent_request_id = "\x00" ** 128;
        record.permission.?.request_id = record.agent_request_id;
        record.permission.?.matched_rule_id = "\x00" ** 128;
        record.permission.?.tool_name = "\x00" ** 128;
        record.permission.?.tool_binding = "\x00" ** 128;
        record.permission.?.canonical_arguments_digest = "\x00" ** 128;
        record.permission.?.policy_generation = std.math.maxInt(u64);
    }
    state.failures = try allocator.alloc(history.wire.TaskFailureWire, history.wire.max_failure_records);
    for (state.failures, 0..) |*failure, index| failure.* = .{
        .task_id = std.math.maxInt(u64) - index,
        .recent_order = std.math.maxInt(u64) - index,
        .reason = "\x00" ** history.wire.max_failure_reason_bytes,
    };
    // Escaping can multiply JSON byte size. This checks one Task's bounded
    // arrays plus the entire failure list, not a full live Runtime snapshot.
    const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .memory, schema.migrations);
    defer database.destroy() catch unreachable;
    const batch = try save(allocator, database.capability(), state);
    try std.testing.expect(sql.validMutations(batch.mutations.items));
    try std.testing.expect(parameterBytes(batch) <= sql.Limits.exec_parameter_bytes);
    try expectSame(allocator, database.capability(), state);
}

test "history updates child decisions and compacts atomically with checkpoint facts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const original = try history.fixture(allocator);
    var expected = try history.fixture(allocator);
    expected.tasks[0].ui_history = &.{};
    expected.tasks[0].compacts[0].phase = "no_change";
    expected.tasks[0].compacts[0].diagnostic = "new compact result\x00世";
    expected.failures = &.{};
    var task_id: [8]u8 = undefined;
    std.mem.writeInt(u64, &task_id, expected.tasks[0].id, .big);
    const updates = [_]sql.Mutation{
        .{ .statement = .{ .sql = "DELETE FROM task_ui_history WHERE task_id=?1", .params = &.{.{ .blob = &task_id }} }, .expected_changes = .{ .exactly = 1 } },
        .{ .statement = .{ .sql = "UPDATE task_compacts SET payload=?1 WHERE task_id=?2", .params = &.{ .{ .text = try std.json.Stringify.valueAlloc(allocator, expected.tasks[0].compacts[0], .{}) }, .{ .blob = &task_id } } }, .expected_changes = .{ .exactly = 1 } },
        .{ .statement = .{
            .sql = "UPDATE history_state SET failures_json=?1 WHERE singleton=1",
            .params = &.{.{ .text = try std.json.Stringify.valueAlloc(allocator, expected.failures, .{}) }},
        }, .expected_changes = .{ .exactly = 1 } },
    };
    const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .memory, schema.migrations);
    defer database.destroy() catch unreachable;
    _ = try save(allocator, database.capability(), original);
    try std.testing.expectEqual(sql.MutationOutcome.constraint, database.capability().mutate(&(updates ++ [_]sql.Mutation{.{ .statement = .{
        .sql = "UPDATE tasks SET checkpoint_digest=NULL",
    } }})));
    try expectSame(allocator, database.capability(), original);
    try std.testing.expectEqual(sql.MutationOutcome.committed, database.capability().mutate(&updates));
    try expectSame(allocator, database.capability(), expected);
}

test "merged recovery failures survive without a surviving Task" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var state = try history.fixture(allocator);
    state.tasks = &.{};
    state.workspaces = &.{};
    const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .memory, schema.migrations);
    defer database.destroy() catch unreachable;
    _ = try save(allocator, database.capability(), state);
    try expectSame(allocator, database.capability(), state);
}

test "one complete maximum-count Run fits the bounded SQL transaction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const state = try populated(allocator, 32, 256, 8);
    const batch = try history.batchFor(allocator, state);
    try std.testing.expect(sql.validMutations(batch.mutations.items));
    try std.testing.expect(batch.mutations.items.len <= sql.Limits.exec_statements);
    try std.testing.expect(parameterBytes(batch) <= sql.Limits.exec_parameter_bytes);
    const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .memory, schema.migrations);
    defer database.destroy() catch unreachable;
    try std.testing.expectEqual(sql.MutationOutcome.committed, database.capability().mutate(batch.mutations.items));
    try expectSame(allocator, database.capability(), state);
}

test "bounded history loader reads a legal table larger than a query result budget" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const state = try populated(allocator, 32, 1, 1);
    const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .memory, schema.migrations);
    defer database.destroy() catch unreachable;
    _ = try save(allocator, database.capability(), state);
    const bytes = try allocator.alloc(u8, history.limits.max_tool_field_bytes);
    @memset(bytes, 'x');
    // Seed a large existing database using a shared value. This is a query
    // budget fixture, not an atomic save of independent large Tool payloads.
    try std.testing.expectEqual(sql.MutationOutcome.committed, database.capability().mutate(&.{.{ .statement = .{
        .sql = "UPDATE run_tools SET content=?1,input=?1,progress=?1,name=?1",
        .params = &.{.{ .blob = bytes }},
    } }}));
    var count: Count = .{};
    try std.testing.expectEqual(sql.QueryOutcome.resource_exhausted, database.capability().query("SELECT * FROM run_tools ORDER BY ordinal", &.{}, count.receiver()));
    const loaded = try history.load(allocator, database.capability());
    try std.testing.expectEqual(@as(usize, 32), loaded.tasks[0].runs[0].tools.len);
    try std.testing.expectEqual(sql.QueryOutcome.ok, database.capability().query("SELECT COUNT(*) FROM run_tools", &.{}, count.receiver()));
    try std.testing.expectEqual(@as(?i64, 32), count.value);
}

test "history schema upgrades populated data and old readers reject the newer version" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const path = try temporaryPath(allocator, temporary.dir);
    const state = try history.fixture(allocator);
    {
        const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .{ .file = path }, schema.migrations);
        defer database.destroy() catch unreachable;
        _ = try save(allocator, database.capability(), state);
    }
    const migrations = schema.migrations[0..schema.migrations.len].* ++ [_]sql.Migration{upgrade};
    {
        const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .{ .file = path }, &migrations);
        defer database.destroy() catch unreachable;
        try std.testing.expectEqual(upgrade.version, database.schemaVersion());
        var count: Count = .{};
        try std.testing.expectEqual(sql.QueryOutcome.ok, database.capability().query("SELECT COUNT(*) FROM tasks WHERE test_note=X'6f6b'", &.{}, count.receiver()));
        try std.testing.expectEqual(@as(?i64, 1), count.value);
        try expectSame(allocator, database.capability(), state);
    }
    try std.testing.expectError(error.VersionUnknown, storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .{ .file = path }, schema.migrations));
}

test "history schema rolls back every pending migration including schema and backfill" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const path = try temporaryPath(allocator, temporary.dir);
    const state = try history.fixture(allocator);
    {
        const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .{ .file = path }, schema.migrations);
        defer database.destroy() catch unreachable;
        _ = try save(allocator, database.capability(), state);
    }
    const migrations = schema.migrations[0..schema.migrations.len].* ++ [_]sql.Migration{ upgrade, .{
        .version = schema.migrations.len + 2,
        .name = "test_only_failure",
        .sql = "CREATE TABLE test_marker(id INTEGER); UPDATE tasks SET title=X'6368616e676564'; UPDATE runs SET generation=NULL;",
    } };
    try std.testing.expectError(error.MigrationFailed, storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .{ .file = path }, &migrations));
    const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .{ .file = path }, schema.migrations);
    defer database.destroy() catch unreachable;
    try std.testing.expectEqual(@as(u32, schema.migrations.len), database.schemaVersion());
    try expectSame(allocator, database.capability(), state);
    var count: Count = .{};
    try std.testing.expectEqual(sql.QueryOutcome.rejected, database.capability().query("SELECT test_note FROM tasks", &.{}, count.receiver()));
    try std.testing.expectEqual(sql.QueryOutcome.rejected, database.capability().query("SELECT COUNT(*) FROM test_marker", &.{}, count.receiver()));
}

test "history schema round-trips every persisted field through the original codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const original = try history.fixture(allocator);
    const encoded = try allocator.alloc(u8, history.wire.max_store_bytes);
    const original_bytes = try history.wire.encode(encoded, original, history.limits);
    const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .memory, schema.migrations);
    defer database.destroy() catch unreachable;
    const batch = try history.batchFor(allocator, original);
    try std.testing.expectEqual(sql.MutationOutcome.committed, database.capability().mutate(batch.mutations.items));
    const restored = try history.load(allocator, database.capability());
    const restored_buffer = try allocator.alloc(u8, history.wire.max_store_bytes);
    const restored_bytes = try history.wire.encode(restored_buffer, restored, history.limits);
    try std.testing.expectEqualSlices(u8, original_bytes, restored_bytes);
}

test "history schema accepts one complete relational set atomically" {
    // This fixture isolates DDL relationships. Product-valid aggregates are
    // separately checked against the original codec in the round-trip tests.
    const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .memory, schema.migrations);
    defer database.destroy() catch unreachable;
    var mutations: [6]sql.Mutation = undefined;
    var statements = std.mem.splitScalar(u8, @embedFile("history_schema_minimal.sql"), ';');
    var len: usize = 0;
    while (statements.next()) |raw| {
        const statement = std.mem.trim(u8, raw, " \r\n\t");
        if (statement.len == 0) continue;
        mutations[len] = .{ .statement = .{ .sql = statement }, .expected_changes = .{ .exactly = 1 } };
        len += 1;
    }
    try std.testing.expectEqual(@as(usize, 6), len);
    try std.testing.expectEqual(sql.MutationOutcome.committed, database.capability().mutate(&mutations));
    var count: Count = .{};
    try std.testing.expectEqual(sql.QueryOutcome.ok, database.capability().query(
        "SELECT COUNT(*) FROM tasks t JOIN runs r ON r.task_id=t.id JOIN run_tools tool ON tool.task_id=r.task_id AND tool.run_id=r.id JOIN run_file_changes f ON f.task_id=r.task_id AND f.run_id=r.id JOIN workspaces w ON w.id=t.workspace_id",
        &.{},
        count.receiver(),
    ));
    try std.testing.expectEqual(@as(?i64, 1), count.value);
    try std.testing.expectEqual(sql.MutationOutcome.constraint, database.capability().mutate(&.{
        .{ .statement = .{ .sql = "DELETE FROM runs" } },
        .{ .statement = .{ .sql = "UPDATE tasks SET archived=7" } },
    }));
    try std.testing.expectEqual(sql.QueryOutcome.ok, database.capability().query("SELECT COUNT(*) FROM run_tools", &.{}, count.receiver()));
    try std.testing.expectEqual(@as(?i64, 1), count.value);
    try std.testing.expectEqual(sql.MutationOutcome.committed, database.capability().mutate(&.{.{ .statement = .{ .sql = "DELETE FROM runs" } }}));
    try std.testing.expectEqual(sql.QueryOutcome.ok, database.capability().query("SELECT (SELECT COUNT(*) FROM runs)+(SELECT COUNT(*) FROM run_tools)+(SELECT COUNT(*) FROM run_file_changes)", &.{}, count.receiver()));
    try std.testing.expectEqual(@as(?i64, 0), count.value);
}

test "history schema creates every business table without bootstrapping business state" {
    // A single module identity is required at the capability boundary.
    comptime if (sql.Database != storage.sql.Database or sql.Migration != storage.sql.Migration)
        @compileError("Storage and Product must share one SQL contract module");
    const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .memory, schema.migrations);
    defer database.destroy() catch unreachable;
    try std.testing.expectEqual(schema.migrations.len, database.schemaVersion());
    for ([_][]const u8{
        "history_state", "workspaces", "tasks", "runs", "run_tools", "run_file_changes", "task_compacts", "task_ui_history", "task_input_submissions", "run_additional_inputs", "retained_records",
    }) |name| {
        const query = try std.fmt.allocPrint(std.testing.allocator, "SELECT COUNT(*) FROM {s}", .{name});
        defer std.testing.allocator.free(query);
        var count: Count = .{};
        try std.testing.expectEqual(sql.QueryOutcome.ok, database.capability().query(query, &.{}, count.receiver()));
        try std.testing.expectEqual(@as(?i64, 0), count.value);
    }
    for ([_][]const u8{ "history_failures", "task_checkpoints" }) |name| {
        const query = try std.fmt.allocPrint(std.testing.allocator, "SELECT COUNT(*) FROM {s}", .{name});
        defer std.testing.allocator.free(query);
        var count: Count = .{};
        try std.testing.expectEqual(sql.QueryOutcome.rejected, database.capability().query(query, &.{}, count.receiver()));
    }
}

test "history schema preserves unsigned identity and NUL bytes through the public capability" {
    const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .memory, schema.migrations);
    defer database.destroy() catch unreachable;
    const high_id = sql.Value{ .blob = &.{ 0x80, 0, 0, 0, 0, 0, 0, 1 } };
    const one = sql.Value{ .blob = &.{ 0, 0, 0, 0, 0, 0, 0, 1 } };
    const root = sql.Value{ .blob = "C:/history\x00bytes" };
    const insert = "INSERT INTO workspaces(ordinal,id,epoch,kind,canonical_root,display_name,visible,recent_order) VALUES(0,?1,?2,'manual',?3,?4,1,?2)";
    const capability = database.capability();
    try std.testing.expectEqual(sql.MutationOutcome.committed, capability.mutate(&.{.{
        .statement = .{ .sql = insert, .params = &.{ high_id, one, root, .{ .blob = "Workspace" } } },
    }}));
    var count: Count = .{};
    try std.testing.expectEqual(sql.QueryOutcome.ok, capability.query("SELECT COUNT(*) FROM workspaces WHERE id=?1 AND canonical_root=?2", &.{ high_id, root }, count.receiver()));
    try std.testing.expectEqual(@as(?i64, 1), count.value);
    try std.testing.expectEqual(sql.MutationOutcome.constraint, capability.mutate(&.{.{
        .statement = .{ .sql = insert, .params = &.{ .null_value, one, root, .{ .blob = "Invalid" } } },
    }}));
    try std.testing.expectEqual(sql.QueryOutcome.rejected, capability.query("SELECT name FROM sqlite_schema", &.{}, count.receiver()));
}

const Count = struct {
    value: ?i64 = null,
    fn receive(context: *anyopaque, row: sql.Row) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.value = switch (row.value(0)) {
            .integer => |value| value,
            else => null,
        };
    }
    fn receiver(self: *@This()) sql.RowReceiver {
        return .{ .context = self, .receive_fn = receive };
    }
};

test "history file reference JSON preserves Host image provenance and defaults old records to false" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    // The checked-in legacy fixture deliberately has no generated_image field.
    const state = try history.fixture(allocator);
    const reference = &state.tasks[0].runs[0].tools[0].file_refs.?[0];
    try std.testing.expect(!reference.generated_image);
    for ([_]bool{ false, true }) |generated| {
        reference.generated_image = generated;
        const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .memory, schema.migrations);
        defer database.destroy() catch unreachable;
        _ = try save(allocator, database.capability(), state);
        try expectSame(allocator, database.capability(), state);
        const loaded = try history.load(allocator, database.capability());
        try std.testing.expectEqual(generated, loaded.tasks[0].runs[0].tools[0].file_refs.?[0].generated_image);
    }
}

test "production SQL history preserves Outputs metadata without file contents" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const state = try history.fixture(arena.allocator());
    var outputs = [_]history.wire.OutputWire{.{ .id = "01" ** 16, .locator = "report.docx", .size_bytes = 42, .sha256 = "ab" ** 32, .redacted = false }};
    state.tasks[0].runs[0].outputs = &outputs;
    const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .memory, schema.migrations);
    defer database.destroy() catch unreachable;
    _ = try save(arena.allocator(), database.capability(), state);
    try expectSame(arena.allocator(), database.capability(), state);
}

test "largest legal Tool value exceeds the old SQL cap and round-trips" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const state = try history.fixture(allocator);
    const field = try allocator.alloc(u8, 256 * 1024);
    @memset(field, 1);
    const refs = try allocator.alloc(history.wire.FileReferenceWire, 32);
    for (refs) |*ref| ref.* = .{ .id = field[0..8192], .title = field[0..8192], .display_path = field[0..8192], .kind = field[0..8192], .locator_kind = "workspace_path", .locator = field[0..8192], .range = null };
    const tool = &state.tasks[0].runs[0].tools[0];
    tool.name = field;
    tool.input = field;
    tool.progress = field;
    tool.content = field;
    tool.file_refs = refs;
    const batch = try history.batchFor(allocator, state);
    try std.testing.expect(parameterBytes(batch) > 8 * 1024 * 1024);
    try std.testing.expect(parameterBytes(batch) <= sql.Limits.exec_parameter_bytes);
    const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .memory, schema.migrations);
    defer database.destroy() catch unreachable;
    try std.testing.expectEqual(sql.MutationOutcome.committed, database.capability().mutate(batch.mutations.items));
    try expectSame(allocator, database.capability(), state);
}

test "SQL history preserves opaque and read-only legacy bytes exactly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var state = try history.fixture(allocator);
    state.next_task_id = 100;
    state.next_task_recent_order = 100;
    const payload = try allocator.alloc(u8, history.wire.max_store_bytes);
    @memset(payload, 0xc0);
    const known = try std.json.Stringify.valueAlloc(allocator, state.tasks[0], .{});
    const readonly = try std.fmt.allocPrint(allocator, "{{\"future_field\":true,{s}", .{known[1..]});
    const preserved: history.wire.PreservedFrames = .{ .retained = &.{.{ .kind = .task, .id = 98, .order = 99, .payload = payload }}, .read_only_tasks = &.{.{ .task_id = state.tasks[0].id, .recent_order = state.tasks[0].recent_order, .payload = readonly }} };
    const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .memory, schema.migrations);
    defer database.destroy() catch unreachable;
    const batch = try schema.codec.batchForPreserving(allocator, state, preserved, history.limits);
    try std.testing.expectEqual(sql.MutationOutcome.committed, database.capability().mutate(batch.mutations.items));
    const restored = try schema.codec.loadPreserving(allocator, database.capability(), history.limits);
    try std.testing.expectEqual(@as(usize, 1), restored.preserved.retained.len);
    try std.testing.expectEqualSlices(u8, payload, restored.preserved.retained[0].payload);
    try std.testing.expectEqualSlices(u8, readonly, restored.preserved.read_only_tasks[0].payload);
    try expectSame(allocator, database.capability(), state);
}

test "retained rows without a root are untrusted rather than empty history" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .memory, schema.migrations);
    defer database.destroy() catch unreachable;
    try std.testing.expectEqual(sql.MutationOutcome.committed, database.capability().mutate(&.{.{ .statement = .{ .sql = "INSERT INTO retained_records VALUES('task',X'0000000000000001',X'0000000000000001',X'ff')" } }}));
    try std.testing.expectError(error.MissingState, history.load(arena.allocator(), database.capability()));
}

test "a failed page cannot publish a partial history aggregate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .memory, schema.migrations);
    defer database.destroy() catch unreachable;
    const state = try history.fixture(arena.allocator());
    _ = try save(arena.allocator(), database.capability(), state);
    const Fault = struct {
        inner: sql.Database,
        delivered: usize = 0,
        fn query(ctx: *anyopaque, text: []const u8, params: []const sql.Value, receiver: sql.RowReceiver) sql.QueryOutcome {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const result = self.inner.query(text, params, receiver);
            if (std.mem.indexOf(u8, text, "FROM run_tools") != null and result == .ok) {
                self.delivered += 1;
                return .resource_exhausted;
            }
            return result;
        }
        fn mutate(ctx: *anyopaque, items: []const sql.Mutation) sql.MutationOutcome {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.inner.mutate(items);
        }
        fn maintain(ctx: *anyopaque, op: sql.Maintenance) sql.QueryOutcome {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.inner.maintain(op);
        }
    };
    var fault: Fault = .{ .inner = database.capability() };
    try std.testing.expectError(error.QueryFailed, history.load(arena.allocator(), .{ .context = &fault, .query_fn = Fault.query, .mutate_fn = Fault.mutate, .maintain_fn = Fault.maintain }));
    try std.testing.expect(fault.delivered != 0);
    try expectSame(arena.allocator(), database.capability(), state);
}
