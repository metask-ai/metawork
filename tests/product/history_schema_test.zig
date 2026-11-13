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
        return schema.codec.load(allocator, std.testing.allocator, database, limits);
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
    // Top-level identity sets have a canonical order; nested arrays do not.
    var canonical = expected;
    canonical.workspaces = try allocator.dupe(history.wire.WorkspaceWire, expected.workspaces);
    canonical.tasks = try allocator.dupe(history.wire.TaskWire, expected.tasks);
    std.mem.sort(history.wire.WorkspaceWire, canonical.workspaces, {}, struct {
        fn less(_: void, a: history.wire.WorkspaceWire, b: history.wire.WorkspaceWire) bool {
            return a.id < b.id;
        }
    }.less);
    std.mem.sort(history.wire.TaskWire, canonical.tasks, {}, struct {
        fn less(_: void, a: history.wire.TaskWire, b: history.wire.TaskWire) bool {
            return a.id < b.id;
        }
    }.less);
    const expected_buffer = try std.testing.allocator.alloc(u8, history.wire.max_store_bytes);
    defer std.testing.allocator.free(expected_buffer);
    const actual_buffer = try std.testing.allocator.alloc(u8, history.wire.max_store_bytes);
    defer std.testing.allocator.free(actual_buffer);
    try std.testing.expectEqualSlices(u8, try history.wire.encode(expected_buffer, canonical, history.limits), try history.wire.encode(actual_buffer, actual, history.limits));
}

fn temporaryPath(allocator: std.mem.Allocator, dir: std.Io.Dir) ![]const u8 {
    var bytes: [std.fs.max_path_bytes]u8 = undefined;
    const len = try dir.realPath(std.testing.io, &bytes);
    return std.fs.path.join(allocator, &.{ bytes[0..len], "history.db" });
}

fn modelErrorFixture() history.wire.ModelErrorWire {
    return .{
        .run_id = std.math.maxInt(u64),
        .category = .authentication,
        .message = "服务拒绝 late-credential",
        .code = "future-code late-credential",
        .type = "late-credential",
        .request_id = "request late-credential",
        .http_status = 200,
        .retry = .unknown,
        .retry_after_ms = std.math.maxInt(u64),
        .attempts = 2,
        .truncated = true,
        .host_redacted = false,
        .host_truncated = true,
        .source = .metask,
    };
}

test "model error migration upgrades published v1 records to null and rejects the old schema afterward" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try temporaryPath(a, temporary.dir);
    const state = try history.fixture(a);
    {
        const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .{ .file = path }, schema.migrations[0..1]);
        defer database.destroy() catch unreachable;
        const rows = try schema.codec.rowsFor(a, state, .{}, history.limits);
        var mutations: std.ArrayList(sql.Mutation) = .empty;
        for (rows) |row| {
            var columns: std.ArrayList(u8) = .empty;
            var markers: std.ArrayList(u8) = .empty;
            var params: std.ArrayList(sql.Value) = .empty;
            for (row.columns, row.values) |column, value| {
                if (std.mem.eql(u8, column, "model_error_json") or std.mem.eql(u8, column, "project_removed")) continue;
                if (params.items.len != 0) {
                    try columns.append(a, ',');
                    try markers.append(a, ',');
                }
                try columns.appendSlice(a, column);
                try params.append(a, value);
                try markers.appendSlice(a, try std.fmt.allocPrint(a, "?{d}", .{params.items.len}));
            }
            try mutations.append(a, .{ .statement = .{
                .sql = try std.fmt.allocPrint(a, "INSERT INTO {s}({s}) VALUES({s})", .{ row.table, columns.items, markers.items }),
                .params = params.items,
            } });
        }
        try std.testing.expectEqual(sql.MutationOutcome.committed, database.capability().mutate(mutations.items));
    }
    {
        const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .{ .file = path }, schema.migrations);
        defer database.destroy() catch unreachable;
        try expectSame(a, database.capability(), state);
        const loaded = try history.load(a, database.capability());
        try std.testing.expect(loaded.tasks[0].runs[0].model_error == null);
    }
    try std.testing.expectError(error.VersionUnknown, storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .{ .file = path }, schema.migrations[0..1]));
}

test "Project removal survives SQL restart without changing Workspace or Task authority" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try temporaryPath(a, temporary.dir);
    const state = try history.fixture(a);
    state.workspaces[0].project_removed = true;
    {
        const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .{ .file = path }, schema.migrations);
        defer database.destroy() catch unreachable;
        _ = try save(a, database.capability(), state);
    }
    const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .{ .file = path }, schema.migrations);
    defer database.destroy() catch unreachable;
    try expectSame(a, database.capability(), state);
    for ([_][]const u8{
        "UPDATE workspaces SET project_removed=2",
        "UPDATE workspaces SET project_removed='invalid'",
        "UPDATE workspaces SET project_removed=NULL",
    }) |statement| {
        try std.testing.expectEqual(sql.MutationOutcome.constraint, database.capability().mutate(&.{.{ .statement = .{ .sql = statement } }}));
    }
    try expectSame(a, database.capability(), state);
}

test "model error history survives restart and credential sanitization with exact integer facts" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try temporaryPath(a, temporary.dir);
    const state = try history.fixture(a);
    state.tasks[0].runs[0].model_error = modelErrorFixture();
    {
        const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .{ .file = path }, schema.migrations);
        defer database.destroy() catch unreachable;
        _ = try save(a, database.capability(), state);
    }
    const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .{ .file = path }, schema.migrations);
    defer database.destroy() catch unreachable;
    try expectSame(a, database.capability(), state);
    var repository = schema.repository.Repository.init(std.testing.allocator, database.capability(), history.limits);
    defer repository.deinit();
    try repository.seed(state, .{});
    try repository.sanitize("late-credential", @splat(3));
    const loaded = try history.load(a, database.capability());
    try std.testing.expect(!try history.wire.security.contains(a, loaded, "late-credential"));
    const detail = loaded.tasks[0].runs[0].model_error.?;
    try std.testing.expect(detail.host_redacted);
    try std.testing.expectEqual(std.math.maxInt(u64), detail.run_id);
    try std.testing.expectEqual(@as(?u64, std.math.maxInt(u64)), detail.retry_after_ms);
    try std.testing.expectEqual(.authentication, detail.category);
    try std.testing.expectEqual(.metask, detail.source.?);
    // Enum names are structure even when a credential has the same bytes.
    try std.testing.expect(!try history.wire.security.contains(a, detail, "authentication"));
    inline for (.{ "[]", "{}", "null", "invalid" }) |raw| {
        const outcome = database.capability().mutate(&.{.{ .statement = .{ .sql = "UPDATE runs SET model_error_json=?1", .params = &.{.{ .text = raw }} } }});
        if (std.mem.eql(u8, raw, "{}")) {
            try std.testing.expectEqual(sql.MutationOutcome.committed, outcome);
            if (history.load(a, database.capability())) |_| return error.InvalidModelErrorAccepted else |_| {}
        } else try std.testing.expectEqual(sql.MutationOutcome.constraint, outcome);
    }
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

test "history SQL preserves manual and cancelled review summaries without reviewer attribution" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    for ([_]bool{ false, true }) |cancelled| {
        const state = try history.fixture(allocator);
        const record = &state.tasks[0].ui_history[0];
        record.state = if (cancelled) "cancelled" else "allowed_once";
        record.answered_by = if (cancelled) null else "user";
        record.review_reason = null;
        record.review = .{ .outcome = "deny", .cause = "rejection_limit", .reason = "当前拒绝达到阈值 late-credential" };
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        const path = try temporaryPath(allocator, temporary.dir);
        const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .{ .file = path }, schema.migrations);
        defer database.destroy() catch unreachable;
        _ = try save(allocator, database.capability(), state);
        try expectSame(allocator, database.capability(), state);
        var repository = schema.repository.Repository.init(std.testing.allocator, database.capability(), history.limits);
        defer repository.deinit();
        try repository.seed(state, .{});
        try repository.sanitize("late-credential", @splat(3));
        const restored = try history.load(allocator, database.capability());
        const actual = restored.tasks[0].ui_history[0];
        try std.testing.expectEqualStrings(record.answered_by orelse "", actual.answered_by orelse "");
        try std.testing.expect(actual.review_reason == null);
        try std.testing.expectEqualStrings("deny", actual.review.?.outcome);
        try std.testing.expectEqualStrings("rejection_limit", actual.review.?.cause.?);
        try std.testing.expect(std.mem.indexOf(u8, actual.review.?.reason.?, "late-credential") == null);
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
    const canonical = try history.load(allocator, database.capability());
    try std.testing.expectEqual(@as(u64, 2), canonical.workspaces[0].id);
    try std.testing.expectEqual(@as(u64, 6), canonical.tasks[0].id);
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
        "UPDATE tasks SET id=NULL",
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
        "UPDATE history_state SET failures_json='{}'",
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

fn recoveringAllocationCase(allocator: std.mem.Allocator, bytes: []const u8) !void {
    var recovered = try history.wire.decodeRecovering(allocator, bytes, history.limits);
    defer recovered.deinit();
    // Resource failure is an error, never a successful partial import.
    try std.testing.expect(!recovered.degraded);
    try std.testing.expectEqual(@as(usize, 1), recovered.value.tasks.len);
    try std.testing.expectEqual(@as(usize, 0), recovered.preserved.retained.len);
}

test "framed recovery never converts allocation failure into successful data loss" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var state = try history.fixture(a);
    state.failures = &.{};
    const bytes = try history.wire.encodeAlloc(a, state, .{}, history.limits);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, recoveringAllocationCase, .{bytes});
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
        const label = [_]u8{@intCast('0' + index)};
        try std.testing.expectEqual(sql.MutationOutcome.committed, database.capability().mutate(&.{.{ .statement = .{
            .sql = "INSERT INTO workspaces(id,epoch,kind,canonical_root,display_name,visible,recent_order) VALUES(?1,?1,'automatic',?1,?3,0,?2)",
            .params = &.{ .{ .blob = &ids[index] }, .{ .blob = &encoded[index] }, .{ .blob = &label } },
        } }}));
    }
    var sequence: Sequence = .{};
    try std.testing.expectEqual(sql.QueryOutcome.ok, database.capability().query("SELECT CAST(display_name AS INTEGER) FROM workspaces ORDER BY recent_order", &.{}, sequence.receiver()));
    try std.testing.expect(!sequence.overflow);
    try std.testing.expectEqualSlices(i64, &.{ 0, 1, 2, 3 }, sequence.values[0..sequence.len]);
    sequence = .{};
    try std.testing.expectEqual(sql.QueryOutcome.ok, database.capability().query("SELECT CAST(display_name AS INTEGER) FROM workspaces WHERE recent_order>=?1 ORDER BY recent_order", &.{.{ .blob = &encoded[2] }}, sequence.receiver()));
    try std.testing.expect(!sequence.overflow);
    try std.testing.expectEqualSlices(i64, &.{ 2, 3 }, sequence.values[0..sequence.len]);
    for (encoded, 0..) |bytes, index| {
        var count: Count = .{};
        try std.testing.expectEqual(sql.QueryOutcome.ok, database.capability().query("SELECT COUNT(*) FROM workspaces WHERE recent_order=?1 AND id=?2", &.{ .{ .blob = &bytes }, .{ .blob = &ids[index] } }, count.receiver()));
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
    // Every terminal kind now uses the same complete relational columns.
    // Referenced terminal existence is checked by Product, not a fake FK.
    try expectSame(allocator, database.capability(), state);
    for ([_][]const u8{
        "UPDATE tasks SET approval_revision=1",
        "UPDATE tasks SET approval_revision=X'01'",
        "UPDATE tasks SET checkpoint_terminal_id=X'0000000000000000'",
        "UPDATE tasks SET checkpoint_terminal_id=NULL",
        "UPDATE tasks SET checkpoint_digest=NULL",
        "UPDATE tasks SET checkpoint_terminal_kind='unknown'",
        "UPDATE tasks SET permission_review_delegated=2",
        "UPDATE tasks SET model_intent_json='{'",
        "UPDATE history_state SET failures_json='['",
        "UPDATE runs SET input_json='{'",
        "UPDATE runs SET commentary_ends_json='{'",
        "UPDATE tasks SET presentation_format=1,next_presentation_order=X'0000000000000000'",
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
    // Deferred NO ACTION rejects an incomplete delete at COMMIT, preserving
    // every child. Physical deletion is explicit and ordered by the owner.
    try std.testing.expectEqual(sql.MutationOutcome.constraint, database.capability().mutate(&.{.{ .statement = .{ .sql = "DELETE FROM runs" } }}));
    try std.testing.expectEqual(sql.MutationOutcome.committed, database.capability().mutate(&.{
        .{ .statement = .{ .sql = "DELETE FROM run_tools" } },
        .{ .statement = .{ .sql = "DELETE FROM run_file_changes" } },
        .{ .statement = .{ .sql = "DELETE FROM runs" } },
    }));
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
    const insert = "INSERT INTO workspaces(id,epoch,kind,canonical_root,display_name,visible,recent_order) VALUES(?1,?2,'manual',?3,?4,1,?2)";
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

test "history schema deferred parent rebuild preserves every child and value" {
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
    const tables = [_][]const u8{ "history_state", "workspaces", "tasks", "runs", "run_tools", "run_file_changes", "task_compacts", "task_ui_history", "task_input_submissions", "run_additional_inputs", "retained_records" };
    var script: std.ArrayList(u8) = .empty;
    for (tables) |table| try script.appendSlice(allocator, try std.fmt.allocPrint(allocator, "CREATE TABLE copy_{s} AS SELECT * FROM {s};", .{ table, table }));
    const ddl = schema.migrations[0].sql;
    const start = std.mem.indexOf(u8, ddl, "CREATE TABLE tasks (").?;
    const end = std.mem.indexOfPos(u8, ddl, start, "\n);").? + 3;
    try script.appendSlice(allocator, "DROP TABLE tasks;");
    try script.appendSlice(allocator, ddl[start..end]);
    try script.appendSlice(allocator, "INSERT INTO tasks SELECT * FROM copy_tasks;");
    var lines = std.mem.splitScalar(u8, ddl, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "CREATE ") and std.mem.indexOf(u8, line, " ON tasks(") != null)
            try script.appendSlice(allocator, line);
    }
    const migrations = schema.migrations[0..schema.migrations.len].* ++ [_]sql.Migration{.{ .version = schema.migrations.len + 1, .name = "rebuild_parent", .sql = script.items }};
    const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .{ .file = path }, &migrations);
    defer database.destroy() catch unreachable;
    for (tables) |table| {
        var count: Count = .{};
        const query = try std.fmt.allocPrint(allocator, "SELECT (SELECT COUNT(*) FROM (SELECT * FROM {s} EXCEPT SELECT * FROM copy_{s}))+(SELECT COUNT(*) FROM (SELECT * FROM copy_{s} EXCEPT SELECT * FROM {s}))", .{ table, table, table, table });
        try std.testing.expectEqual(sql.QueryOutcome.ok, database.capability().query(query, &.{}, count.receiver()));
        try std.testing.expectEqual(@as(?i64, 0), count.value);
    }
    try expectSame(allocator, database.capability(), state);
}

test "history schema named nullable checks and unique indexes evolve through Storage" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const path = try temporaryPath(allocator, temporary.dir);
    const state = try history.fixture(allocator);
    state.tasks[0].runs[0].assistant_output_kind = null;
    state.tasks[0].runs[0].assistant_output_start = null;
    state.tasks[0].runs[0].assistant = "";
    state.tasks[0].runs[0].commentary_ends = &.{};
    {
        const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .{ .file = path }, schema.migrations);
        defer database.destroy() catch unreachable;
        _ = try save(allocator, database.capability(), state);
    }
    const migrations = schema.migrations[0..schema.migrations.len].* ++ [_]sql.Migration{
        .{ .version = schema.migrations.len + 1, .name = "named_constraints", .sql =
        \\ALTER TABLE runs DROP CONSTRAINT runs_assistant_output_kind_domain;
        \\ALTER TABLE runs ADD CONSTRAINT runs_assistant_output_kind_domain CHECK(assistant_output_kind IS NULL OR assistant_output_kind IN ('final','partial','future'));
        \\DROP INDEX workspaces_canonical_root_unique;
        \\CREATE UNIQUE INDEX workspaces_canonical_root_unique ON workspaces(canonical_root);
        },
    };
    const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .{ .file = path }, &migrations);
    defer database.destroy() catch unreachable;
    try expectSame(allocator, database.capability(), state);
    try std.testing.expectEqual(sql.MutationOutcome.constraint, database.capability().mutate(&.{.{ .statement = .{ .sql = "UPDATE runs SET assistant_output_kind='unknown',assistant_output_start=X'0000000000000000'" } }}));
    try std.testing.expectEqual(sql.MutationOutcome.committed, database.capability().mutate(&.{.{ .statement = .{ .sql = "UPDATE runs SET assistant_output_kind='future',assistant_output_start=X'0000000000000000'" } }}));
    if (history.load(allocator, database.capability())) |_| return error.FutureTagAccepted else |_| {}
}

fn setPhase(task: *history.wire.TaskWire, phase: []const u8) void {
    const run = &task.runs[0];
    run.phase = phase;
    run.cause = null;
    const active = std.mem.eql(u8, phase, "queued") or std.mem.eql(u8, phase, "running") or std.mem.eql(u8, phase, "waiting_ui") or std.mem.eql(u8, phase, "stopping");
    if (active) {
        run.outcome = null;
        run.coverage = "pending";
        run.elapsed_ms = null;
        run.finished_at_unix_ms = null;
        run.file_change_observation = "collecting";
        task.active_operation = .{ .kind = "run", .id = run.id };
    } else {
        run.outcome = phase;
        task.active_operation = null;
    }
}

test "history schema accepts every owner relational enum in a valid Product aggregate" {
    inline for (history.wire.testing.relational_enums) |binding| {
        for (std.meta.tags(binding[2])) |tag| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const allocator = arena.allocator();
            var state = try history.fixture(allocator);
            const task = &state.tasks[0];
            const run = &task.runs[0];
            task.archived = false;
            task.completion_seen_run_id = 0;
            task.compacts = &.{};
            task.checkpoint = null;
            task.checkpoint_anchor = "none";
            const value = @tagName(tag);
            if (comptime std.mem.eql(u8, binding[1], "protocol")) {
                task.binding.protocol = value;
                run.execution_protocol = value;
            } else if (comptime std.mem.eql(u8, binding[1], "permission_profile")) {
                task.permission_profile = value;
            } else if (comptime std.mem.eql(u8, binding[1], "permission_interaction")) {
                task.permission_interaction = value;
                run.permission_interaction = value;
            } else if (comptime std.mem.eql(u8, binding[1], "default_approval_mode")) {
                state.default_approval_mode = value;
                state.default_permission_profile = @tagName(tag.profile());
            } else if (comptime std.mem.eql(u8, binding[1], "checkpoint_anchor")) {
                task.checkpoint_anchor = value;
                if (!std.mem.eql(u8, value, "none")) {
                    const baseline = try history.fixture(allocator);
                    task.checkpoint = baseline.tasks[0].checkpoint;
                    task.checkpoint.?.anchor.terminal = .{ .kind = "run", .id = run.id };
                    task.checkpoint.?.session.last_compact_id = 0;
                }
            } else if (comptime std.mem.eql(u8, binding[1], "checkpoint_attempt")) {
                task.checkpoint_attempt = value;
            } else if (comptime std.mem.eql(u8, binding[1], "phase")) {
                setPhase(task, value);
            } else if (comptime std.mem.eql(u8, binding[1], "outcome")) {
                setPhase(task, if (tag == .dependency_contract_failure) "failed" else value);
                run.outcome = value;
            } else if (comptime std.mem.eql(u8, binding[1], "cause")) {
                setPhase(task, "failed");
                run.cause = value;
            } else if (comptime std.mem.eql(u8, binding[1], "coverage")) {
                run.coverage = value;
            } else if (comptime std.mem.eql(u8, binding[1], "assistant_output_kind")) {
                run.assistant_output_kind = value;
            } else if (comptime std.mem.eql(u8, binding[1], "file_change_observation")) {
                if (tag == .collecting) setPhase(task, "running");
                run.file_change_observation = value;
            } else if (comptime std.mem.eql(u8, binding[1], "event_projection_failure")) {
                run.event_projection_failure = value;
            } else if (comptime std.mem.eql(u8, binding[1], "state")) {
                run.tools[0].state = value;
                run.tools[0].is_error = tag == .failed;
            } else if (comptime std.mem.eql(u8, binding[1], "kind")) {
                run.file_changes.?[0].kind = value;
                run.file_changes.?[0].from_display_path = if (tag == .moved) "old.zig" else null;
            } else if (comptime std.mem.eql(u8, binding[1], "status")) {
                run.file_changes.?[0].status = value;
            } else @compileError("New enum binding needs a valid aggregate fixture");
            const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .memory, schema.migrations);
            defer database.destroy() catch unreachable;
            _ = try save(allocator, database.capability(), state);
            try expectSame(allocator, database.capability(), state);
            const invalid = try std.fmt.allocPrint(allocator, "UPDATE {s} SET {s}='unknown'", .{ binding[0], binding[1] });
            try std.testing.expectEqual(sql.MutationOutcome.constraint, database.capability().mutate(&.{.{ .statement = .{ .sql = invalid } }}));
        }
    }
}

test "history typed JSON accepts owner enums without losing their Product semantics" {
    inline for (history.wire.testing.json_enums) |binding| {
        for (std.meta.tags(binding[1])) |tag| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const state = try history.fixture(a);
            const task = &state.tasks[0];
            const run = &task.runs[0];
            task.archived = false;
            task.completion_seen_run_id = 0;
            task.checkpoint = null;
            task.checkpoint_anchor = "none";
            const value = @tagName(tag);
            if (comptime std.mem.eql(u8, binding[0], "compact_phase")) {
                task.compacts[0].phase = value;
                task.compacts[0].cause = null;
                if (tag == .queued or tag == .compacting or tag == .stopping) {
                    task.compacts[0].coverage = "pending";
                    task.active_operation = .{ .kind = "compact", .id = task.compacts[0].id };
                } else if (tag == .aborted or tag == .failed) task.compacts[0].cause = "agent_failure";
            } else if (comptime std.mem.eql(u8, binding[0], "compact_cause")) {
                task.compacts[0].phase = "failed";
                task.compacts[0].cause = value;
            } else if (comptime std.mem.eql(u8, binding[0], "additional_state")) {
                const input = &run.additional_inputs[0];
                input.state = value;
                if (tag == .transferred) {
                    var target = run.*;
                    target.id = 14;
                    target.generation = 14;
                    target.additional_inputs = &.{};
                    target.tools = &.{};
                    target.file_change_observation = null;
                    target.file_changes = null;
                    target.outputs = &.{};
                    target.submission = null;
                    input.transferred_to_run_id = 14;
                    task.runs = try a.dupe(history.wire.RunWire, &.{ run.*, target });
                    task.next_run_generation = 14;
                }
            } else if (comptime std.mem.eql(u8, binding[0], "attachment_kind") or std.mem.eql(u8, binding[0], "attachment_format")) {
                const image = if (comptime std.mem.eql(u8, binding[0], "attachment_format")) true else tag == .image;
                const format = if (comptime std.mem.eql(u8, binding[0], "attachment_format")) value else "png";
                run.input = .{ .kind = "multimodal", .text = null, .skill_id = null, .catalog_revision = null, .invocation_name = null, .display_name = null, .argument_values = null, .redacted = false, .attachments = try a.dupe(history.wire.AttachmentWire, &.{.{ .kind = if (image) "image" else "file", .format = if (image) format else null, .display_name = "attachment", .size_bytes = 1, .redacted = false }}) };
            } else if (comptime std.mem.eql(u8, binding[0], "locator_kind")) {
                run.tools[0].file_refs.?[0].locator_kind = value;
            } else if (comptime std.mem.eql(u8, binding[0], "ui_kind")) {
                task.ui_history[0].kind = value;
            } else if (comptime std.mem.eql(u8, binding[0], "ui_state")) {
                task.ui_history[0].state = value;
                task.ui_history[0].answered_by = null;
                task.ui_history[0].review_reason = null;
            } else if (comptime std.mem.eql(u8, binding[0], "submission_state")) {
                task.input_submissions[0].state = value;
            } else if (comptime std.mem.eql(u8, binding[0], "permission_decision")) {
                task.ui_history[0].permission.?.decision = value;
            } else if (comptime std.mem.eql(u8, binding[0], "permission_source")) {
                task.ui_history[0].permission.?.source = value;
            } else if (comptime std.mem.eql(u8, binding[0], "permission_callback")) {
                task.ui_history[0].permission.?.callback_outcome = value;
            } else if (comptime std.mem.eql(u8, binding[0], "permission_namespace")) {
                task.ui_history[0].permission.?.tool_namespace = value;
            } else @compileError("New JSON enum requires a valid fixture");
            const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .memory, schema.migrations);
            defer database.destroy() catch unreachable;
            _ = try save(a, database.capability(), state);
            try expectSame(a, database.capability(), state);
            const statement, const payload = if (comptime std.mem.eql(u8, binding[0], "compact_phase") or std.mem.eql(u8, binding[0], "compact_cause")) blk: {
                if (comptime std.mem.eql(u8, binding[0], "compact_phase")) task.compacts[0].phase = "unknown" else task.compacts[0].cause = "unknown";
                break :blk .{ "UPDATE task_compacts SET payload=?1", try std.json.Stringify.valueAlloc(a, task.compacts[0], .{}) };
            } else if (comptime std.mem.eql(u8, binding[0], "additional_state")) blk: {
                task.runs[0].additional_inputs[0].state = "future";
                break :blk .{ "UPDATE run_additional_inputs SET payload=?1", try std.json.Stringify.valueAlloc(a, task.runs[0].additional_inputs[0], .{}) };
            } else if (comptime std.mem.eql(u8, binding[0], "attachment_kind") or std.mem.eql(u8, binding[0], "attachment_format")) blk: {
                if (comptime std.mem.eql(u8, binding[0], "attachment_kind")) run.input.attachments.?[0].kind = "unknown" else run.input.attachments.?[0].format = "unknown";
                break :blk .{ "UPDATE runs SET input_json=?1", try std.json.Stringify.valueAlloc(a, run.input, .{}) };
            } else if (comptime std.mem.eql(u8, binding[0], "locator_kind")) blk: {
                run.tools[0].file_refs.?[0].locator_kind = "unknown";
                break :blk .{ "UPDATE run_tools SET file_refs_json=?1", try std.json.Stringify.valueAlloc(a, run.tools[0].file_refs, .{}) };
            } else if (comptime std.mem.eql(u8, binding[0], "submission_state")) blk: {
                task.input_submissions[0].state = "unknown";
                break :blk .{ "UPDATE task_input_submissions SET payload=?1", try std.json.Stringify.valueAlloc(a, task.input_submissions[0], .{}) };
            } else blk: {
                if (comptime std.mem.eql(u8, binding[0], "ui_kind")) task.ui_history[0].kind = "unknown";
                if (comptime std.mem.eql(u8, binding[0], "ui_state")) task.ui_history[0].state = "unknown";
                if (comptime std.mem.eql(u8, binding[0], "permission_decision")) task.ui_history[0].permission.?.decision = "unknown";
                if (comptime std.mem.eql(u8, binding[0], "permission_source")) task.ui_history[0].permission.?.source = "unknown";
                if (comptime std.mem.eql(u8, binding[0], "permission_callback")) task.ui_history[0].permission.?.callback_outcome = "unknown";
                if (comptime std.mem.eql(u8, binding[0], "permission_namespace")) task.ui_history[0].permission.?.tool_namespace = "unknown";
                break :blk .{ "UPDATE task_ui_history SET payload=?1", try std.json.Stringify.valueAlloc(a, task.ui_history[0], .{}) };
            };
            try std.testing.expect(history.wire.validateCandidate(&state, history.limits) != null);
            // JSON syntax remains valid; nested domain meaning belongs to Product.
            try std.testing.expectEqual(sql.MutationOutcome.committed, database.capability().mutate(&.{.{ .statement = .{ .sql = statement, .params = &.{.{ .text = payload }} }, .expected_changes = .{ .exactly = 1 } }}));
            if (history.load(a, database.capability())) |_| return error.UnknownJsonEnumAccepted else |_| {}
        }
    }
}

test "history SQL round trips the full failed input reason domain and rejects other tags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const state = try history.fixture(allocator);
    const task = &state.tasks[0];
    const template = task.input_submissions[0];
    const reasons = std.meta.tags(history.wire.InputFailureReason);
    task.input_submissions = try allocator.alloc(history.wire.InputSubmissionWire, reasons.len);
    for (task.input_submissions, reasons) |*input, reason| {
        input.* = template;
        input.submission.operation_id = @tagName(reason);
        input.state = "failed";
        input.failure_reason = reason;
        input.blocking_task_id = if (reason == .session_close_failed) task.id else null;
    }
    const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .memory, schema.migrations);
    defer database.destroy() catch unreachable;
    _ = try save(allocator, database.capability(), state);
    try expectSame(allocator, database.capability(), state);

    for ([_][]const u8{ "unknown", "models_catalog_loading", "run_changed", "task_busy", "too_late" }) |tag| {
        try std.testing.expectEqual(sql.MutationOutcome.committed, database.capability().mutate(&.{.{
            .statement = .{
                .sql = "UPDATE task_input_submissions SET payload=json_set(payload, '$.failure_reason', ?1) WHERE ordinal=0",
                .params = &.{.{ .text = tag }},
            },
            .expected_changes = .{ .exactly = 1 },
        }}));
        try std.testing.expectError(error.InvalidEnumTag, history.load(allocator, database.capability()));
    }
}

test "history SQL upgrade keeps valid failed input reasons and removes old runtime-only tags" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const state = try history.fixture(allocator);
    const task = &state.tasks[0];
    var template = task.input_submissions[0];
    template.state = "failed";
    var submissions = [_]history.wire.InputSubmissionWire{ template, template };
    submissions[0].failure_reason = .session_close_failed;
    submissions[0].blocking_task_id = task.id;
    submissions[1].submission.operation_id = "previous-runtime-reason";
    task.input_submissions = &submissions;
    const path = try temporaryPath(allocator, temporary.dir);
    const previous_migrations = schema.migrations[0..6];
    {
        const previous = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .{ .file = path }, previous_migrations);
        defer previous.destroy() catch unreachable;
        _ = try save(allocator, previous.capability(), state);
        try std.testing.expectEqual(sql.MutationOutcome.committed, previous.capability().mutate(&.{.{
            .statement = .{ .sql = "UPDATE task_input_submissions SET payload=json_set(payload, '$.failure_reason', 'models_catalog_loading') WHERE ordinal=1" },
            .expected_changes = .{ .exactly = 1 },
        }}));
    }
    const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .{ .file = path }, schema.migrations);
    defer database.destroy() catch unreachable;
    try expectSame(allocator, database.capability(), state);
    try std.testing.expectError(error.VersionUnknown, storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .{ .file = path }, previous_migrations));
}

test "history file reference JSON preserves Host image provenance and defaults old records to false" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    // The checked-in legacy fixture deliberately has no generated_image field.
    const state = try history.fixture(allocator);
    const reference = &state.tasks[0].runs[0].tools[0].file_refs.?[0];
    try std.testing.expect(!reference.generated_image);
    try std.testing.expect(!reference.isGeneratedVideo());
    for ([_]bool{ false, true }) |generated| {
        reference.generated_image = generated;
        const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .memory, schema.migrations);
        defer database.destroy() catch unreachable;
        _ = try save(allocator, database.capability(), state);
        try expectSame(allocator, database.capability(), state);
        const loaded = try history.load(allocator, database.capability());
        try std.testing.expectEqual(generated, loaded.tasks[0].runs[0].tools[0].file_refs.?[0].generated_image);
        try std.testing.expect(!loaded.tasks[0].runs[0].tools[0].file_refs.?[0].isGeneratedVideo());
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

test "history schema upgrades legacy video references and fences out the previous reader" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const state = try history.fixture(allocator);
    const task = &state.tasks[0];
    task.presentation_format = 1;
    task.next_presentation_order = 2;
    for (task.input_submissions) |*input| input.submission.presentation_state = "legacy";
    for (task.runs) |*run| {
        if (run.submission) |*submission| submission.presentation_state = "legacy";
        for (run.additional_inputs) |*input| {
            if (input.submission) |*submission| submission.presentation_state = "legacy";
        }
    }
    const reference = &task.runs[0].tools[0].file_refs.?[0];
    reference.locator = "generated-videos/clip.mp4";
    reference.locator_kind = "workspace_path";
    reference.kind = "video";
    reference.presentation_state = "legacy";
    const path = try temporaryPath(allocator, temporary.dir);
    const previous_migrations = schema.migrations[0..3];
    var legacy = reference.*;
    legacy.presentation_state = "generated_video";
    legacy.presentation_anchor = .{ .after_output_count = 0, .presentation_order = 1 };
    const update = "UPDATE run_tools SET file_refs_json=?1 WHERE file_refs_json IS NOT NULL";
    {
        const previous = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .{ .file = path }, previous_migrations);
        defer previous.destroy() catch unreachable;
        _ = try save(allocator, previous.capability(), state);
        const json = try std.json.Stringify.valueAlloc(allocator, &.{legacy}, .{ .emit_null_optional_fields = false });
        try std.testing.expectEqual(sql.MutationOutcome.committed, previous.capability().mutate(&.{.{
            .statement = .{ .sql = update, .params = &.{.{ .text = json }} },
            .expected_changes = .{ .exactly = 1 },
        }}));
    }

    reference.generated_video = true;
    reference.presentation_state = "anchored";
    reference.presentation_anchor = legacy.presentation_anchor;
    const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .{ .file = path }, schema.migrations);
    defer database.destroy() catch unreachable;
    try expectSame(allocator, database.capability(), state);
    try std.testing.expectError(error.VersionUnknown, storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .{ .file = path }, previous_migrations));
    const loaded = try history.load(allocator, database.capability());
    const restored = loaded.tasks[0].runs[0].tools[0].file_refs.?[0];
    try std.testing.expect(restored.isGeneratedVideo());
    try std.testing.expectEqual(@as(u64, 1), restored.presentation_anchor.?.presentation_order);

    const rewritten = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .memory, schema.migrations);
    defer rewritten.destroy() catch unreachable;
    _ = try save(allocator, rewritten.capability(), loaded);
    try expectSame(allocator, rewritten.capability(), state);

    legacy.presentation_anchor = null;
    const invalid_json = try std.json.Stringify.valueAlloc(allocator, &.{legacy}, .{ .emit_null_optional_fields = false });
    try std.testing.expectEqual(sql.MutationOutcome.committed, database.capability().mutate(&.{.{
        .statement = .{ .sql = update, .params = &.{.{ .text = invalid_json }} },
        .expected_changes = .{ .exactly = 1 },
    }}));
    try std.testing.expectError(error.Invalid, history.load(allocator, database.capability()));
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
    const restored = try schema.codec.loadPreserving(allocator, std.testing.allocator, database.capability(), history.limits);
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
    try std.testing.expectEqual(sql.MutationOutcome.committed, database.capability().mutate(&.{.{ .statement = .{ .sql = "INSERT INTO retained_records(kind,id,occurrence,recent_order,payload) VALUES('task',X'0000000000000001',0,X'0000000000000001',X'ff')" } }}));
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

test "repository commits only changed rows and keeps witness atomic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .memory, schema.migrations);
    defer database.destroy() catch unreachable;
    var repository = schema.repository.Repository.init(std.testing.allocator, database.capability(), history.limits);
    defer repository.deinit();
    var state = try history.fixture(a);
    var first = try repository.prepare(state, .{}, @splat(1));
    defer first.deinit();
    try std.testing.expect(first.changed_rows > 1);
    try std.testing.expectEqual(sql.MutationOutcome.committed, repository.commit(&first));
    try expectSame(a, database.capability(), state);
    var same = try repository.prepare(state, .{}, @splat(2));
    defer same.deinit();
    try std.testing.expectEqual(@as(usize, 0), same.changed_rows);
    try std.testing.expectEqual(@as(usize, 1), same.mutations.len);
    try std.testing.expectEqual(sql.MutationOutcome.committed, repository.commit(&same));
    state.tasks[0].title = "changed title";
    var changed = try repository.prepare(state, .{}, @splat(3));
    defer changed.deinit();
    try std.testing.expectEqual(@as(usize, 1), changed.changed_rows);
    database.test_hooks.fail_before_commit = true;
    try std.testing.expectEqual(sql.MutationOutcome.definite_io_failure, repository.commit(&changed));
    try std.testing.expectEqual(@as(u64, 2), (try schema.repository.readWitness(database.capability())).generation);
    try std.testing.expectEqual(sql.MutationOutcome.committed, repository.commit(&changed));
    try expectSame(a, database.capability(), state);
}

test "history preserves descending Run tool and file arrays without inferring order" {
    inline for (.{ "runs", "tools", "file_changes" }) |kind| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const state = try history.fixture(a);
        const task = &state.tasks[0];
        task.checkpoint = null;
        task.checkpoint_anchor = "none";
        task.compacts = &.{};
        const run = &task.runs[0];
        run.coverage = "excluded";
        if (comptime std.mem.eql(u8, kind, "runs")) {
            var second = run.*;
            second.id = 14;
            second.generation = 1;
            second.tools = &.{};
            second.additional_inputs = &.{};
            second.file_change_observation = null;
            second.file_changes = null;
            second.outputs = &.{};
            second.submission = null;
            task.runs = try a.dupe(history.wire.RunWire, &.{ run.*, second });
        } else if (comptime std.mem.eql(u8, kind, "tools")) {
            var second = run.tools[0];
            second.id = "tool-second";
            second.order = 1;
            second.file_refs = null;
            run.tools = try a.dupe(history.wire.ToolWire, &.{ run.tools[0], second });
        } else {
            var second = run.file_changes.?[0];
            second.id = "change-7-13-1";
            second.order = 1;
            second.artifact = null;
            run.file_changes = try a.dupe(history.wire.FileChangeWire, &.{ run.file_changes.?[0], second });
        }
        const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .memory, schema.migrations);
        defer database.destroy() catch unreachable;
        _ = try save(a, database.capability(), state);
        try expectSame(a, database.capability(), state);
    }
}

test "repository skips body-only position writes and vacates all swapped batches atomically" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const state = try populated(a, 8, 3, 1);
    const run = &state.tasks[0].runs[0];
    const body = try a.alloc(u8, history.limits.max_tool_field_bytes);
    @memset(body, 'x');
    for (run.tools) |*tool| {
        tool.input = body;
        tool.progress = body;
        tool.content = body;
    }
    const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .memory, schema.migrations);
    defer database.destroy() catch unreachable;
    var repository = schema.repository.Repository.init(std.testing.allocator, database.capability(), history.limits);
    defer repository.deinit();
    var first = try repository.prepare(state, .{}, @splat(1));
    defer first.deinit();
    for (first.mutations) |m| try std.testing.expect(std.mem.indexOf(u8, m.statement.sql, "ordinal=ordinal+") == null);
    try std.testing.expectEqual(sql.MutationOutcome.committed, repository.commit(&first));
    run.usage.input_tokens += 1;
    var counter = try repository.prepare(state, .{}, @splat(2));
    defer counter.deinit();
    try std.testing.expectEqual(@as(usize, 1), counter.changed_rows);
    try std.testing.expectEqual(@as(usize, 2), counter.mutations.len);
    for (counter.mutations) |m| {
        try std.testing.expect(std.mem.indexOf(u8, m.statement.sql, "ordinal=ordinal+") == null);
        try std.testing.expect(std.mem.indexOf(u8, m.statement.sql, "id=excluded.id") == null);
        try std.testing.expect(std.mem.indexOf(u8, m.statement.sql, "task_id=excluded.task_id") == null);
    }
    try std.testing.expectEqual(sql.MutationOutcome.committed, repository.commit(&counter));
    const previous_first = run.tools[0].id;
    std.mem.reverse(history.wire.ToolWire, run.tools);
    var swapped = try repository.prepare(state, .{}, @splat(3));
    defer swapped.deinit();
    var vacates: usize = 0;
    var started_inserting = false;
    for (swapped.mutations) |m| {
        if (std.mem.startsWith(u8, m.statement.sql, "INSERT INTO run_tools")) started_inserting = true;
        if (std.mem.startsWith(u8, m.statement.sql, "UPDATE run_tools SET ordinal=")) {
            try std.testing.expect(!started_inserting);
            try expectIndexed(a, database.capability(), m);
            vacates += 1;
        }
    }
    try std.testing.expect(vacates >= 2);
    database.test_hooks.fail_before_commit = true;
    try std.testing.expectEqual(sql.MutationOutcome.definite_io_failure, repository.commit(&swapped));
    const old = try history.load(a, database.capability());
    try std.testing.expectEqualStrings(previous_first, old.tasks[0].runs[0].tools[0].id);
    try std.testing.expectEqual(sql.MutationOutcome.committed, repository.commit(&swapped));
    try expectSame(a, database.capability(), state);
    run.tools = run.tools[1..];
    var deletion = try repository.prepare(state, .{}, @splat(4));
    defer deletion.deinit();
    try std.testing.expectEqual(sql.MutationOutcome.committed, repository.commit(&deletion));
    try expectSame(a, database.capability(), state);
}

test "history loader rejects committed temporary positions and gaps" {
    for ([_][]const u8{ "UPDATE runs SET ordinal=2147483648", "UPDATE runs SET ordinal=1" }) |invalid| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const state = try history.fixture(a);
        const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .memory, schema.migrations);
        defer database.destroy() catch unreachable;
        _ = try save(a, database.capability(), state);
        try std.testing.expectEqual(sql.MutationOutcome.committed, database.capability().mutate(&.{.{ .statement = .{ .sql = invalid } }}));
        try std.testing.expectError(error.Invalid, history.load(a, database.capability()));
    }
}

test "history first keyset page rejects invalid keys instead of hiding them behind a sentinel" {
    for ([_]bool{ false, true }) |identity| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const path = try temporaryPath(a, temporary.dir);
        const state = try history.fixture(a);
        if (identity) {
            const task = &state.tasks[0];
            task.runs = &.{};
            task.compacts = &.{};
            task.ui_history = &.{};
            task.input_submissions = &.{};
            task.checkpoint = null;
            task.checkpoint_anchor = "none";
            task.completion_seen_run_id = 0;
        }
        {
            const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .{ .file = path }, schema.migrations);
            defer database.destroy() catch unreachable;
            _ = try save(a, database.capability(), state);
        }
        // Isolated migration injects a broken row; production DDL is unchanged.
        const corrupt = if (identity)
            "ALTER TABLE tasks DROP CONSTRAINT tasks_id_domain;UPDATE tasks SET id=X'0000000000000000';"
        else
            "ALTER TABLE runs DROP CONSTRAINT runs_ordinal_domain;UPDATE runs SET ordinal=-1;";
        const migrations = schema.migrations[0..schema.migrations.len].* ++ [_]sql.Migration{.{ .version = schema.migrations.len + 1, .name = "broken_first_key", .sql = corrupt }};
        const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .{ .file = path }, &migrations);
        defer database.destroy() catch unreachable;
        if (history.load(a, database.capability())) |_| return error.InvalidFirstKeyHidden else |_| {}
    }
}

const IndexedPlan = struct {
    searches: usize = 0,
    correlated: bool = false,
    fn receive(raw: *anyopaque, row: sql.Row) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        const detail = row.value(3).text;
        if (std.mem.indexOf(u8, detail, "SEARCH ") != null) self.searches += 1;
        if (std.mem.indexOf(u8, detail, "CORRELATED") != null) self.correlated = true;
    }
};

fn expectIndexed(a: std.mem.Allocator, db: sql.Database, mutation: sql.Mutation) !void {
    var plan: IndexedPlan = .{};
    // Query authority intentionally rejects even EXPLAIN of a mutation.
    // Observe the identical key predicate through a read-only SELECT instead.
    const statement = mutation.statement.sql;
    const from = if (std.mem.startsWith(u8, statement, "DELETE FROM ")) "DELETE FROM ".len else "UPDATE ".len;
    const end = std.mem.indexOfScalarPos(u8, statement, from, ' ').?;
    const where = std.mem.indexOf(u8, statement, " WHERE ").?;
    const explain = try std.fmt.allocPrint(a, "EXPLAIN QUERY PLAN SELECT 1 FROM {s}{s}", .{ statement[from..end], statement[where..] });
    try std.testing.expectEqual(sql.QueryOutcome.ok, db.query(explain, mutation.statement.params, .{ .context = &plan, .receive_fn = IndexedPlan.receive }));
    try std.testing.expect(plan.searches > 0);
    try std.testing.expect(!plan.correlated);
}

test "repository Task deletion and insertion do not renumber unrelated identities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var state = try history.fixture(a);
    var other = state.tasks[0];
    other.id = 6;
    other.recent_order = 42;
    other.runs = &.{};
    other.compacts = &.{};
    other.ui_history = &.{};
    other.input_submissions = &.{};
    other.checkpoint = null;
    other.checkpoint_anchor = "none";
    other.completion_seen_run_id = 0;
    other.next_run_generation = 0;
    state.tasks = try a.dupe(history.wire.TaskWire, &.{ state.tasks[0], other });
    state.next_task_recent_order = 43;
    const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .memory, schema.migrations);
    defer database.destroy() catch unreachable;
    var repository = schema.repository.Repository.init(std.testing.allocator, database.capability(), history.limits);
    defer repository.deinit();
    var first = try repository.prepare(state, .{}, @splat(1));
    defer first.deinit();
    try std.testing.expectEqual(sql.MutationOutcome.committed, repository.commit(&first));
    state.tasks = state.tasks[1..];
    var deleted = try repository.prepare(state, .{}, @splat(2));
    defer deleted.deinit();
    try std.testing.expectEqual(@as(usize, 0), deleted.changed_rows);
    for (deleted.mutations) |m| {
        try std.testing.expect(!std.mem.startsWith(u8, m.statement.sql, "INSERT"));
        if (std.mem.startsWith(u8, m.statement.sql, "DELETE")) try expectIndexed(a, database.capability(), m);
    }
    try std.testing.expectEqual(sql.MutationOutcome.committed, repository.commit(&deleted));
    other.id = 8;
    other.recent_order = 43;
    state.tasks = try a.dupe(history.wire.TaskWire, &.{ other, state.tasks[0] });
    state.next_task_id = 9;
    state.next_task_recent_order = 44;
    var inserted = try repository.prepare(state, .{}, @splat(3));
    defer inserted.deinit();
    try std.testing.expectEqual(@as(usize, 2), inserted.changed_rows);
    for (inserted.mutations) |m| try std.testing.expect(std.mem.indexOf(u8, m.statement.sql, "ordinal=ordinal+") == null);
    try std.testing.expectEqual(sql.MutationOutcome.committed, repository.commit(&inserted));
    const loaded = try schema.codec.loadPreserving(a, std.testing.allocator, database.capability(), history.limits);
    try repository.seed(loaded.value, loaded.preserved);
    var unchanged = try repository.prepare(state, .{}, @splat(4));
    defer unchanged.deinit();
    try std.testing.expectEqual(@as(usize, 0), unchanged.changed_rows);
    try std.testing.expectEqual(@as(usize, 1), unchanged.mutations.len);
}

test "repository deletes Task descendants and backfills a previously failed change" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .memory, schema.migrations);
    defer database.destroy() catch unreachable;
    var repository = schema.repository.Repository.init(std.testing.allocator, database.capability(), history.limits);
    defer repository.deinit();
    var state = try history.fixture(a);
    var first = try repository.prepare(state, .{}, @splat(1));
    defer first.deinit();
    try std.testing.expectEqual(sql.MutationOutcome.committed, repository.commit(&first));
    state.tasks[0].title = "not lost after disk failure";
    var failed = try repository.prepare(state, .{}, @splat(2));
    defer failed.deinit();
    database.test_hooks.fail_before_commit = true;
    try std.testing.expectEqual(sql.MutationOutcome.definite_io_failure, repository.commit(&failed));
    state.default_approval_mode = "full_access";
    var catchup = try repository.prepare(state, .{}, @splat(3));
    defer catchup.deinit();
    try std.testing.expectEqual(sql.MutationOutcome.committed, repository.commit(&catchup));
    try expectSame(a, database.capability(), state);
    state.tasks = &.{};
    var deletion = try repository.prepare(state, .{}, @splat(4));
    defer deletion.deinit();
    try std.testing.expect(deletion.deleted_rows > 0);
    try std.testing.expectEqual(sql.MutationOutcome.committed, repository.commit(&deletion));
    try expectSame(a, database.capability(), state);
}

test "repository preserves witness atomicity beyond 128 retained-record statements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .memory, schema.migrations);
    defer database.destroy() catch unreachable;
    var repository = schema.repository.Repository.init(std.testing.allocator, database.capability(), history.limits);
    defer repository.deinit();
    var state = try history.fixture(a);
    const retained = try a.alloc(history.wire.RetainedRecord, 140);
    for (retained, 0..) |*record, i| record.* = .{ .kind = .task, .id = 100 + i, .order = 100 + i, .payload = "{\"future\":true}" };
    state.next_task_id = 241;
    state.next_task_recent_order = 241;
    var prepared = try repository.prepare(state, .{ .retained = retained }, @splat(1));
    defer prepared.deinit();
    try std.testing.expect(prepared.mutations.len > sql.Limits.exec_statements);
    try std.testing.expect(prepared.chunks.len > 1);
    database.test_hooks.fail_before_commit = true;
    try std.testing.expectEqual(sql.MutationOutcome.definite_io_failure, repository.commit(&prepared));
    try std.testing.expectEqual(@as(u64, 0), (try schema.repository.readWitness(database.capability())).generation);
    try std.testing.expectEqual(sql.MutationOutcome.committed, repository.commit(&prepared));
    const loaded = try schema.codec.loadPreserving(a, std.testing.allocator, database.capability(), history.limits);
    try std.testing.expectEqual(@as(usize, 140), loaded.preserved.retained.len);
    var deletion = try repository.prepare(state, .{}, @splat(2));
    defer deletion.deinit();
    try std.testing.expectEqual(sql.MutationOutcome.committed, repository.commit(&deletion));
    try expectSame(a, database.capability(), state);
}

test "repository preserves multiple opaque frame occurrences with the same identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var state = try history.fixture(a);
    state.next_task_id = 101;
    state.next_task_recent_order = 103;
    const records = [_]history.wire.RetainedRecord{
        .{ .kind = .task, .id = 100, .order = 100, .payload = "{\"future\":1}" },
        .{ .kind = .task, .id = 100, .order = 101, .payload = "{\"future\":2}" },
        .{ .kind = .task, .id = 100, .order = 101, .payload = "{\"future\":2}" },
    };
    const database = try storage.sqlite.Database.create(std.testing.io, std.testing.allocator, .memory, schema.migrations);
    defer database.destroy() catch unreachable;
    var repository = schema.repository.Repository.init(std.testing.allocator, database.capability(), history.limits);
    defer repository.deinit();
    var prepared = try repository.prepare(state, .{ .retained = &records }, @splat(1));
    defer prepared.deinit();
    try std.testing.expectEqual(sql.MutationOutcome.committed, repository.commit(&prepared));
    const loaded = try schema.codec.loadPreserving(a, std.testing.allocator, database.capability(), history.limits);
    try std.testing.expectEqual(@as(usize, records.len), loaded.preserved.retained.len);
    for (records, loaded.preserved.retained) |expected, actual| {
        try std.testing.expectEqual(expected.order, actual.order);
        try std.testing.expectEqualSlices(u8, expected.payload, actual.payload);
    }
    const bytes = try history.wire.encodeAlloc(a, loaded.value, loaded.preserved, history.limits);
    var recovered = try history.wire.decodeRecovering(a, bytes, history.limits);
    defer recovered.deinit();
    try std.testing.expectEqual(@as(usize, records.len), recovered.preserved.retained.len);
    try repository.seed(loaded.value, loaded.preserved);
    var same = try repository.prepare(loaded.value, loaded.preserved, @splat(2));
    defer same.deinit();
    try std.testing.expectEqual(@as(usize, 0), same.changed_rows);
}
