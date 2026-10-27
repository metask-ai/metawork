//! Stage A: actual current history restoration, isolated synthetic memory samples.
//! Each configuration runs in a fresh process; no Agent Session or user store is opened.
const std = @import("std");
const builtin = @import("builtin");
const history = @import("product_task_persistence");
const task_runtime = @import("product_task_runtime");
const state = @import("product_task_state");
const storage = @import("storage");
const sql = @import("metawork_storage_sql");

const Config = struct { tasks: usize = 20, runs: usize = 16, body_bytes: usize = 4096, tools: usize = 0, escaped: bool = false, budget_bytes: usize = 1536 * 1024, samples: usize = 5, approvals: usize = 8, compacts: usize = 16 };
const usage: history.UsageWire = .{ .input_tokens = 1, .output_tokens = 1, .cache_read_input_tokens = 0, .cache_creation_input_tokens = 0 };

fn limits(c: Config, expanded: bool) history.Limits {
    return .{ .max_workspaces = 16, .max_tasks = if (expanded) @max(50, c.tasks) else 50, .max_runs_per_task = if (expanded) @max(16, c.runs) else 16, .max_compacts_per_task = @max(16, c.compacts), .max_tools_per_run = 32, .max_commentary_segments_per_run = 256, .max_file_refs_per_tool = 32, .max_file_changes_per_run = 256, .max_ui_history_per_task = @max(8, c.approvals), .max_workspace_bytes = 16 * 1024, .max_task_title_bytes = 512, .max_user_message_bytes = 256 * 1024, .max_assistant_message_bytes = 256 * 1024, .max_tool_field_bytes = 256 * 1024, .max_file_ref_field_bytes = 8192, .max_execution_model_bytes = 512, .max_terminal_diagnostic_bytes = 512 };
}

const Counter = struct {
    current: usize = 0,
    peak: usize = 0,
    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn from(p: *anyopaque) *@This() {
        return @ptrCast(@alignCast(p));
    }
    fn change(self: *@This(), old: usize, new: usize) void {
        self.current = self.current - old + new;
        self.peak = @max(self.peak, self.current);
    }
    fn alloc(p: *anyopaque, n: usize, a: std.mem.Alignment, r: usize) ?[*]u8 {
        const result = std.heap.c_allocator.rawAlloc(n, a, r) orelse return null;
        from(p).change(0, n);
        return result;
    }
    fn resize(p: *anyopaque, b: []u8, a: std.mem.Alignment, n: usize, r: usize) bool {
        if (!std.heap.c_allocator.rawResize(b, a, n, r)) return false;
        from(p).change(b.len, n);
        return true;
    }
    fn remap(p: *anyopaque, b: []u8, a: std.mem.Alignment, n: usize, r: usize) ?[*]u8 {
        const result = std.heap.c_allocator.rawRemap(b, a, n, r) orelse return null;
        from(p).change(b.len, n);
        return result;
    }
    fn free(p: *anyopaque, b: []u8, a: std.mem.Alignment, r: usize) void {
        std.heap.c_allocator.rawFree(b, a, r);
        from(p).change(b.len, 0);
    }
};

const Memory = struct { working_set: usize = 0, private_bytes: usize = 0, peak_working_set: usize = 0, peak_private_bytes: usize = 0 };
fn memory() Memory {
    if (builtin.os.tag != .windows) return .{};
    const Win = struct {
        const Counters = extern struct { cb: u32 = @sizeOf(@This()), faults: u32 = 0, peak_ws: usize = 0, ws: usize = 0, peak_paged: usize = 0, paged: usize = 0, peak_nonpaged: usize = 0, nonpaged: usize = 0, pagefile: usize = 0, peak_pagefile: usize = 0, private: usize = 0 };
        extern "kernel32" fn K32GetProcessMemoryInfo(std.os.windows.HANDLE, *Counters, u32) callconv(.winapi) i32;
    };
    var c: Win.Counters = .{};
    std.debug.assert(Win.K32GetProcessMemoryInfo(std.os.windows.GetCurrentProcess(), &c, @sizeOf(Win.Counters)) != 0);
    return .{ .working_set = c.ws, .private_bytes = c.private, .peak_working_set = c.peak_ws, .peak_private_bytes = c.peak_pagefile };
}

// Matches Control's restore allocation/accounting rules, including the 1 KiB
// minimum assistant capacity. Configurable budget belongs only to this probe.
const Restore = struct {
    allocator: std.mem.Allocator,
    budget: usize,
    charged: usize = 0,
    fn from(p: *anyopaque) *@This() {
        return @ptrCast(@alignCast(p));
    }
    fn reserve(p: *anyopaque, n: usize) error{ProjectionCapacity}!void {
        const s = from(p);
        if (n > s.budget - s.charged) return error.ProjectionCapacity;
        s.charged += n;
    }
    fn release(p: *anyopaque, n: usize) void {
        from(p).charged -= n;
    }
    fn copy(p: *anyopaque, text: []const u8, max: usize) history.ProjectionError![]u8 {
        if (text.len > max) return error.ProjectionCapacity;
        return allocateCopy(p, text);
    }
    fn allocateCopy(p: *anyopaque, text: []const u8) history.ProjectionError![]u8 {
        try reserve(p, text.len);
        errdefer release(p, text.len);
        return from(p).allocator.dupe(u8, text);
    }
    fn alloc(p: *anyopaque, n: usize) history.ProjectionError![]u8 {
        try reserve(p, n);
        errdefer release(p, n);
        return from(p).allocator.alloc(u8, n);
    }
    fn append(p: *anyopaque, target: *history.RestoreText, suffix: []const u8, max: usize) history.ProjectionError!void {
        if (suffix.len > max - target.list.items.len) return error.ProjectionCapacity;
        const needed = target.list.items.len + suffix.len;
        if (needed > target.list.capacity) {
            const desired = @min(max, @max(needed, target.list.capacity + @max(@as(usize, 1024), target.list.capacity / 2)));
            const added = desired - target.list.capacity;
            try reserve(p, added);
            errdefer release(p, added);
            try target.list.ensureTotalCapacityPrecise(from(p).allocator, desired);
        }
        target.list.appendSliceAssumeCapacity(suffix);
    }
    fn free(p: *anyopaque, text: []u8) void {
        release(p, text.len);
        from(p).allocator.free(text);
    }
    fn freeText(p: *anyopaque, text: *history.RestoreText) void {
        release(p, text.list.capacity);
        text.list.deinit(from(p).allocator);
        text.* = .{};
    }
    fn redact(_: *anyopaque, _: []const u8) void {}
    fn projection(s: *@This(), l: history.Limits) history.RestoreProjection {
        return .{ .context = s, .allocator = s.allocator, .limits = l, .copy_fn = copy, .alloc_fn = alloc, .append_text_fn = append, .free_fn = free, .free_text_fn = freeText, .reserve_bytes_fn = reserve, .release_bytes_fn = release };
    }
};

fn fixture(a: std.mem.Allocator, c: Config) !history.StateWire {
    const text = try a.alloc(u8, c.body_bytes);
    @memset(text, if (c.escaped) '\n' else 'a');
    const tools = try a.alloc(history.ToolWire, c.tools);
    for (tools, 0..) |*tool, i| tool.* = .{ .id = try std.fmt.allocPrint(a, "tool-{d}", .{i + 1}), .order = i + 1, .name = "Bash", .input = "{}", .progress = "", .content = text, .state = "completed", .is_error = false, .elapsed_ms = 1, .input_truncated = false, .progress_truncated = false, .content_truncated = false, .redacted = false };
    const tasks = try a.alloc(history.TaskWire, c.tasks);
    for (tasks, 0..) |*task, t| {
        const runs = try a.alloc(history.RunWire, c.runs);
        for (runs, 0..) |*run, r| run.* = .{ .id = r + 1, .coverage = "excluded", .generation = r + 1, .execution_generation = 1, .execution_protocol = "openai_responses", .execution_model = "capacity-model", .permission_profile = "full_access", .permission_interaction = "interactive", .input = .{ .kind = "text", .text = "synthetic capacity input", .skill_id = null, .catalog_revision = null, .invocation_name = null, .display_name = null, .argument_values = null, .redacted = false }, .assistant = text, .assistant_redacted = false, .commentary_ends = &.{}, .assistant_output_kind = "final", .assistant_output_start = 0, .phase = "completed", .outcome = "completed", .cause = null, .usage = usage, .tools = tools, .diagnostic = "", .diagnostic_truncated = false, .diagnostic_redacted = false, .event_projection_failure = null, .next_activity_order = c.tools + 1 };
        task.* = .{ .id = t + 1, .recent_order = t + 1, .completion_seen_run_id = c.runs, .workspace_id = 1, .workspace_epoch = 1, .workspace_root = "/capacity", .title = "synthetic capacity task", .title_redacted = false, .archived = t % 2 == 0, .permission_profile = "full_access", .permission_interaction = "interactive", .binding = .{ .epoch = 1, .execution_generation = 1, .protocol = "openai_responses", .model = "capacity-model" }, .next_run_generation = c.runs, .active_operation = null, .runs = runs, .compacts = &.{}, .ui_history = &.{} };
    }
    const workspaces = try a.alloc(history.WorkspaceWire, 1);
    workspaces[0] = .{ .id = 1, .epoch = 1, .kind = "manual", .canonical_root = "/capacity", .display_name = "capacity", .visible = true, .recent_order = 1 };
    return .{ .next_workspace_id = 2, .next_workspace_recent_order = 2, .next_task_id = c.tasks + 1, .next_task_recent_order = c.tasks + 1, .workspaces = workspaces, .tasks = tasks };
}

fn now() std.Io.Timestamp {
    return .now(std.testing.io, .awake);
}
fn elapsed(t: std.Io.Timestamp) i96 {
    return t.durationTo(now()).nanoseconds;
}

test "stage A actual history memory" {
    if (std.c.getenv("METAWORK_SQLITE_A_BUDGET") != null) return;
    const raw = std.c.getenv("METAWORK_SQLITE_A_CONFIG") orelse return error.MissingConfig;
    const parsed = try std.json.parseFromSlice(Config, std.testing.allocator, std.mem.span(raw), .{});
    defer parsed.deinit();
    const c = parsed.value;
    var fixture_arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer fixture_arena.deinit();
    const a = fixture_arena.allocator();
    const wire = try fixture(a, c);
    for (wire.tasks) |*task| {
        task.ui_history = try a.alloc(history.UiRecordWire, c.approvals);
        for (task.ui_history, 0..) |*ui, i| ui.* = .{ .request_id = i + 1, .run_id = 1, .order = c.tools + i + 1, .kind = "permission", .state = "denied", .detail = "synthetic approval decision", .item_count = 1, .detail_truncated = false, .redacted = false };
        task.runs[0].next_activity_order = c.tools + c.approvals + 1;
        task.compacts = try a.alloc(history.CompactWire, c.compacts);
        for (task.compacts, 0..) |*compact, i| compact.* = .{ .id = i + 1, .coverage = "excluded", .after_run_id = 1, .phase = "compacted", .cause = null, .before_context_tokens = 100, .after_context_tokens = 50, .usage = usage, .diagnostic = "", .diagnostic_truncated = false, .diagnostic_redacted = false };
    }
    const l = limits(c, true);
    if (history.validateCandidate(&wire, l)) |failure| {
        std.debug.print("invalid scope={s} code={s}\n", .{ @tagName(failure.scope), @tagName(failure.code) });
        return error.InvalidSyntheticFixture;
    }
    var counter: Counter = .{};
    var restore: Restore = .{ .allocator = counter.allocator(), .budget = c.budget_bytes };
    var runtime = try task_runtime.Runtime.init(counter.allocator(), c.tasks);
    defer {
        runtime.deinitTasks(.{ .context = &restore, .redact_all_fn = Restore.redact, .release_projection_bytes_fn = Restore.release });
        runtime.deinitStorage();
        std.debug.assert(counter.current == 0 and restore.charged == 0);
    }
    const before = memory();
    const start = now();
    var restored: usize = 0;
    var restore_error: ?[]const u8 = null;
    for (wire.tasks, 0..) |task, i| {
        runtime.tasks[i] = history.restoreTask(restore.projection(l), task) catch |err| {
            restore_error = @errorName(err);
            break;
        };
        restored += 1;
    }
    const restore_ns = elapsed(start);
    var execution_count: usize = 0;
    for (runtime.tasks) |maybe_task| if (maybe_task) |task| {
        for (task.durable.runs) |maybe_run| if (maybe_run) |run| {
            if (run.execution != null) execution_count += 1;
        };
    };
    try std.testing.expectEqual(@as(usize, 0), execution_count);
    const after_restore = memory();
    const resident = counter.current;
    // Controlled overlap sample, not the future Product freeze/builder: hold one
    // 7MiB frozen value while the real backend binds/copies it into SQLite.
    const frozen = try counter.allocator().alloc(u8, 7 * 1024 * 1024);
    defer counter.allocator().free(frozen);
    @memset(frozen, 'f');
    const db = try storage.sqlite.Database.create(std.testing.io, counter.allocator(), .memory, &.{.{ .version = 1, .name = "peak_sample", .sql = "CREATE TABLE sample(b BLOB)" }});
    defer db.destroy() catch unreachable;
    try std.testing.expectEqual(sql.MutationOutcome.committed, db.capability().mutate(&.{.{ .statement = .{ .sql = "INSERT INTO sample VALUES(?)", .params = &.{.{ .blob = frozen }} } }}));
    const overlap_memory = memory();
    const result = .{ .config = c, .restored_tasks = restored, .restore_error = restore_error, .projection_charged_bytes = restore.charged, .runtime_requested_bytes = resident, .runtime_peak_requested_bytes = counter.peak, .restore_ns = restore_ns, .execution_count = execution_count, .memory_before = before, .memory_after = after_restore, .overlap_frozen_bytes = frozen.len, .memory_overlap = overlap_memory, .sizeof_run = @sizeOf(state.RunRecord), .sizeof_execution = @sizeOf(state.RunExecution), .sizeof_compact = @sizeOf(state.CompactRecord), .sizeof_tool = @sizeOf(state.ToolView), .sizeof_file_reference = @sizeOf(state.FileReferenceView), .sizeof_task = @sizeOf(state.Task) };
    const json = try std.json.Stringify.valueAlloc(std.testing.allocator, result, .{});
    defer std.testing.allocator.free(json);
    std.debug.print("A_MEMORY {s}\n", .{json});
}

test "stage A per-field legal SQL representation counterexample" {
    if (std.c.getenv("METAWORK_SQLITE_A_BUDGET") == null) return;
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c: Config = .{ .tasks = 1, .runs = 1, .tools = 32, .body_bytes = 256 * 1024, .budget_bytes = 256 * 1024 * 1024 };
    const wire = try fixture(a, c);
    const field = try a.alloc(u8, 256 * 1024);
    @memset(field, 1); // Valid UTF-8; expands to six bytes in JSON.
    const refs = try a.alloc(history.FileReferenceWire, 32);
    for (refs) |*ref| ref.* = .{ .id = field[0..8192], .title = field[0..8192], .display_path = field[0..8192], .kind = field[0..8192], .locator_kind = "workspace_path", .locator = field[0..8192], .range = null };
    for (wire.tasks[0].runs[0].tools) |*tool| {
        tool.name = field;
        tool.input = field;
        tool.progress = field;
        tool.content = field;
        tool.file_refs = refs;
    }
    const run = &wire.tasks[0].runs[0];
    run.file_change_observation = "complete";
    run.file_changes = try a.alloc(history.FileChangeWire, 256);
    for (run.file_changes.?, 0..) |*change, i| change.* = .{ .id = try std.fmt.allocPrint(a, "change-1-1-{d}", .{33 + i}), .order = 33 + i, .kind = "moved", .status = "applied", .display_path = field[0..4096], .from_display_path = field[0..4096], .before_bytes = 1, .after_bytes = 1, .artifact = null, .diff_complete = true, .redacted = false };
    run.next_activity_order = 289;
    const l = limits(c, true);
    try std.testing.expect(history.validateCandidate(&wire, l) == null);
    var counter: Counter = .{};
    var restore: Restore = .{ .allocator = counter.allocator(), .budget = c.budget_bytes };
    var runtime = try task_runtime.Runtime.init(counter.allocator(), 1);
    defer {
        runtime.deinitTasks(.{ .context = &restore, .redact_all_fn = Restore.redact, .release_projection_bytes_fn = Restore.release });
        runtime.deinitStorage();
        std.debug.assert(counter.current == 0 and restore.charged == 0);
    }
    runtime.tasks[0] = try history.restoreTask(restore.projection(l), wire.tasks[0]);
    const refs_json = try std.json.Stringify.valueAlloc(a, refs, .{});
    const changes_json = try std.json.Stringify.valueAlloc(a, run.file_changes.?, .{});
    const result = .{ .kind = "field_legal_counterexample", .wire_validation = true, .actual_restore_success = true, .projection_charged_bytes = restore.charged, .runtime_requested_bytes = counter.current, .file_refs_json_bytes = refs_json.len, .one_tool_bound_text_bytes_lower_bound = refs_json.len + 4 * field.len, .all_32_tools_bound_bytes_lower_bound = 32 * (refs_json.len + 4 * field.len), .file_changes_json_bytes = changes_json.len, .naive_row_statements_lower_bound = 32 + 256, .sizeof_ui_record = @sizeOf(state.UiRecord), .ui_record_bytes_at_one_per_run = 100 * 256 * @sizeOf(state.UiRecord), .ui_record_bytes_at_ten_per_run = 100 * 256 * 10 * @sizeOf(state.UiRecord), .note = "wire/restore legal under candidate 256MiB, not current 1.5MiB live admission; total is a closure estimate, not an assertion that all dirty units form one business group" };
    const json = try std.json.Stringify.valueAlloc(a, result, .{});
    std.debug.print("A_BUDGET {s}\n", .{json});
}
