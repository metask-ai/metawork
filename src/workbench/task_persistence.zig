const std = @import("std");
const builtin = @import("builtin");

pub const schema_version: u8 = 1;
pub const max_store_bytes: usize = 16 * 1024 * 1024;
pub const file_name = "workbench-history.json";
const lock_file_name = ".workbench-history.lock";

pub const Error = error{
    TaskStoreEmpty,
    TaskStoreTooLarge,
    TaskStoreCorrupt,
    TaskStoreEncodeFailed,
};

pub const FileStoreError = std.mem.Allocator.Error || error{
    DirectoryUnavailable,
    WriterAlreadyActive,
    ReadFailed,
    WriteFailed,
    PersistenceOutcomeUnknown,
};

/// Owns the data-root writer lock from before restore until Host shutdown.
/// The lock file contains no PID or lease data; only the OS lock is authority.
pub const FileStore = struct {
    io: std.Io,
    dir: std.Io.Dir,
    lock_file: std.Io.File,

    pub fn init(io: std.Io, absolute_directory: []const u8) FileStoreError!FileStore {
        if (!std.fs.path.isAbsolute(absolute_directory))
            return error.DirectoryUnavailable;
        const dir = std.Io.Dir.cwd().createDirPathOpen(
            io,
            absolute_directory,
            .{
                .open_options = .{ .follow_symlinks = false },
                .permissions = directoryPermissions(),
            },
        ) catch return error.DirectoryUnavailable;
        errdefer dir.close(io);
        const lock_file = openOrCreateLock(io, dir) catch |err| switch (err) {
            error.WouldBlock => return error.WriterAlreadyActive,
            else => return error.DirectoryUnavailable,
        };
        return .{ .io = io, .dir = dir, .lock_file = lock_file };
    }

    pub fn deinit(self: *FileStore) void {
        self.lock_file.close(self.io);
        self.dir.close(self.io);
        self.* = undefined;
    }

    pub fn loadAlloc(self: *FileStore, allocator: std.mem.Allocator) FileStoreError!?[]u8 {
        var file = self.dir.openFile(
            self.io,
            file_name,
            .{ .follow_symlinks = false, .resolve_beneath = true },
        ) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return error.ReadFailed,
        };
        if (builtin.os.tag == .windows) file.flags.nonblocking = true;
        defer file.close(self.io);
        const length = file.length(self.io) catch return error.ReadFailed;
        if (length == 0 or length > max_store_bytes) return error.ReadFailed;
        const bytes = try allocator.alloc(u8, @intCast(length));
        errdefer allocator.free(bytes);
        const read = file.readPositionalAll(self.io, bytes, 0) catch
            return error.ReadFailed;
        if (read != length) return error.ReadFailed;
        return bytes;
    }

    pub fn commit(self: *FileStore, bytes: []const u8) FileStoreError!void {
        if (bytes.len == 0 or bytes.len > max_store_bytes)
            return error.WriteFailed;
        var random: [8]u8 = undefined;
        std.Io.randomSecure(self.io, &random) catch return error.WriteFailed;
        const random_hex = std.fmt.bytesToHex(random, .lower);
        var temp_name_storage: [64]u8 = undefined;
        var name_writer = std.Io.Writer.fixed(&temp_name_storage);
        name_writer.print(".workbench-history.{s}.tmp", .{random_hex}) catch
            return error.WriteFailed;
        const temp_name = name_writer.buffered();
        const file = self.dir.createFile(
            self.io,
            temp_name,
            .{
                .exclusive = true,
                .permissions = privateFilePermissions(),
                .resolve_beneath = true,
            },
        ) catch return error.WriteFailed;
        var file_open = true;
        var temp_exists = true;
        defer {
            if (file_open) file.close(self.io);
            if (temp_exists) self.dir.deleteFile(self.io, temp_name) catch {};
        }
        file.writeStreamingAll(self.io, bytes) catch return error.WriteFailed;
        file.sync(self.io) catch return error.WriteFailed;
        file.close(self.io);
        file_open = false;
        self.dir.rename(temp_name, self.dir, file_name, self.io) catch
            return error.WriteFailed;
        temp_exists = false;
        if (!self.syncCommit()) return error.PersistenceOutcomeUnknown;
    }

    fn syncCommit(self: *FileStore) bool {
        if (builtin.os.tag == .windows) {
            const file = self.dir.openFile(
                self.io,
                file_name,
                .{
                    .mode = .read_write,
                    .allow_directory = false,
                    .follow_symlinks = false,
                    .resolve_beneath = true,
                },
            ) catch return false;
            defer file.close(self.io);
            file.sync(self.io) catch return false;
            return true;
        }
        const directory_file: std.Io.File = .{
            .handle = self.dir.handle,
            .flags = .{ .nonblocking = false },
        };
        directory_file.sync(self.io) catch return false;
        return true;
    }
};

fn openOrCreateLock(io: std.Io, dir: std.Io.Dir) !std.Io.File {
    const existing = dir.openFile(
        io,
        lock_file_name,
        .{
            .mode = .read_write,
            .lock = .exclusive,
            .lock_nonblocking = true,
            .follow_symlinks = false,
            .resolve_beneath = true,
        },
    ) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (existing) |file| return file;
    return dir.createFile(
        io,
        lock_file_name,
        .{
            .read = true,
            .truncate = false,
            .exclusive = true,
            .lock = .exclusive,
            .lock_nonblocking = true,
            .permissions = privateFilePermissions(),
            .resolve_beneath = true,
        },
    ) catch |err| switch (err) {
        error.PathAlreadyExists => return dir.openFile(
            io,
            lock_file_name,
            .{
                .mode = .read_write,
                .lock = .exclusive,
                .lock_nonblocking = true,
                .follow_symlinks = false,
                .resolve_beneath = true,
            },
        ),
        else => return err,
    };
}

fn directoryPermissions() std.Io.File.Permissions {
    return if (builtin.os.tag == .windows) .default_dir else .fromMode(0o700);
}

fn privateFilePermissions() std.Io.File.Permissions {
    return if (builtin.os.tag == .windows) .default_file else .fromMode(0o600);
}

pub const Limits = struct {
    max_workspaces: usize,
    max_tasks: usize,
    max_runs_per_task: usize,
    max_compacts_per_task: usize,
    max_tools_per_run: usize,
    max_ui_history_per_task: usize,
    max_workspace_bytes: usize,
    max_task_title_bytes: usize,
    max_user_message_bytes: usize,
    max_assistant_message_bytes: usize,
    max_tool_field_bytes: usize,
    max_terminal_diagnostic_bytes: usize,
};

pub const StateWire = struct {
    schema_version: u8,
    next_workspace_id: u64,
    next_workspace_recent_order: u64,
    next_task_id: u64,
    next_task_recent_order: u64,
    workspaces: []WorkspaceWire,
    tasks: []TaskWire,
};

pub const WorkspaceWire = struct {
    id: u64,
    epoch: u64,
    kind: []const u8,
    canonical_root: []const u8,
    display_name: []const u8,
    visible: bool,
    recent_order: u64,
};

pub const TaskWire = struct {
    id: u64,
    recent_order: u64,
    workspace_id: u64,
    workspace_epoch: u64,
    workspace_root: []const u8,
    title: []const u8,
    title_redacted: bool,
    archived: bool,
    closed: bool,
    binding: BindingWire,
    next_run_generation: u64,
    active_operation: ?OperationWire,
    runs: []RunWire,
    compacts: []CompactWire,
    ui_history: []UiRecordWire,
    checkpoint: ?CheckpointWire = null,
    checkpoint_health: []const u8 = "none",
};

pub const CheckpointWire = struct {
    blob: CheckpointBlobWire,
    session: CheckpointSessionWire,
    anchor: CheckpointAnchorWire,
};

pub const CheckpointBlobWire = struct {
    generation: u64,
    byte_size: u64,
    digest: []const u8,
};

pub const CheckpointSessionWire = struct {
    logical_session_id: []const u8,
    last_run_id: u64,
    last_compact_id: u64,
    model: []const u8,
};

pub const CheckpointAnchorWire = struct {
    terminal: CheckpointTerminalWire,
    binding_epoch: u64,
};

pub const CheckpointTerminalWire = struct {
    kind: []const u8,
    id: u64,
};

test "checkpoint wire contains only blob, session binding, and commit anchor" {
    const record_fields = std.meta.fields(CheckpointWire);
    try std.testing.expectEqual(@as(usize, 3), record_fields.len);
    try std.testing.expectEqualStrings("blob", record_fields[0].name);
    try std.testing.expectEqualStrings("session", record_fields[1].name);
    try std.testing.expectEqualStrings("anchor", record_fields[2].name);

    const session_fields = std.meta.fields(CheckpointSessionWire);
    try std.testing.expectEqual(@as(usize, 4), session_fields.len);
    inline for (
        session_fields,
        .{ "logical_session_id", "last_run_id", "last_compact_id", "model" },
    ) |field, expected| try std.testing.expectEqualStrings(expected, field.name);
}

pub const BindingWire = struct {
    epoch: u64,
    execution_generation: u64,
    provider: []const u8,
    model: []const u8,
};

pub const OperationWire = struct { kind: []const u8, id: u64 };

pub const RunWire = struct {
    id: u64,
    generation: u64,
    execution_generation: u64,
    execution_provider: []const u8,
    execution_model: []const u8,
    input: RunInputWire,
    assistant: []const u8,
    assistant_redacted: bool,
    phase: []const u8,
    outcome: ?[]const u8,
    cause: ?[]const u8,
    status: []const u8,
    usage: UsageWire,
    tools: []ToolWire,
    diagnostic: []const u8,
    diagnostic_truncated: bool,
    diagnostic_redacted: bool,
    event_projection_failure: bool,
    next_activity_order: u64,
};

pub const RunInputWire = struct {
    kind: []const u8,
    text: ?[]const u8,
    skill_id: ?[]const u8,
    catalog_revision: ?[]const u8,
    invocation_name: ?[]const u8,
    display_name: ?[]const u8,
    argument_values: ?[][]const u8,
    redacted: bool,
};

pub const ToolWire = struct {
    id: []const u8,
    order: u64,
    name: []const u8,
    input: []const u8,
    progress: []const u8,
    content: []const u8,
    state: []const u8,
    is_error: bool,
    elapsed_ms: u64,
    input_truncated: bool,
    progress_truncated: bool,
    content_truncated: bool,
    redacted: bool,
};

pub const UsageWire = struct {
    input_tokens: u64,
    output_tokens: u64,
    cache_read_input_tokens: u64,
    cache_creation_input_tokens: u64,
};

pub const CompactWire = struct {
    id: u64,
    after_run_id: u64,
    phase: []const u8,
    cause: ?[]const u8,
    before_context_tokens: u64,
    after_context_tokens: u64,
    usage: UsageWire,
    diagnostic: []const u8,
    diagnostic_truncated: bool,
    diagnostic_redacted: bool,
};

pub const UiRecordWire = struct {
    request_id: u64,
    run_id: u64,
    order: u64,
    kind: []const u8,
    state: []const u8,
    detail: []const u8,
    item_count: u32,
    detail_truncated: bool,
    redacted: bool,
    agent_request_id: []const u8 = "",
    permission: ?PermissionSummaryWire = null,
};

pub const PermissionSummaryWire = struct {
    request_id: []const u8,
    matched_rule_id: []const u8,
    tool_namespace: []const u8,
    tool_name: []const u8,
    tool_binding: []const u8,
    decision: []const u8,
    source: []const u8,
    policy_generation: u64,
    used_session_rule: bool,
    callback_outcome: ?[]const u8,
};

pub fn encode(output: []u8, state: StateWire) Error![]const u8 {
    if (output.len == 0) return error.TaskStoreEncodeFailed;
    var writer = std.Io.Writer.fixed(output);
    std.json.Stringify.value(state, .{}, &writer) catch
        return error.TaskStoreEncodeFailed;
    const encoded = writer.buffered();
    if (encoded.len > max_store_bytes) return error.TaskStoreTooLarge;
    return encoded;
}

pub fn decode(
    allocator: std.mem.Allocator,
    input: []const u8,
    limits: Limits,
) Error!std.json.Parsed(StateWire) {
    if (input.len == 0) return error.TaskStoreEmpty;
    if (input.len > max_store_bytes) return error.TaskStoreTooLarge;
    var parsed = std.json.parseFromSlice(
        StateWire,
        allocator,
        input,
        .{ .ignore_unknown_fields = false },
    ) catch return error.TaskStoreCorrupt;
    errdefer parsed.deinit();
    validate(&parsed.value, limits) catch return error.TaskStoreCorrupt;
    return parsed;
}

fn validate(state: *const StateWire, limits: Limits) !void {
    if (state.schema_version != schema_version or state.next_workspace_id == 0 or
        state.next_workspace_recent_order == 0 or state.next_task_id == 0 or
        state.next_task_recent_order == 0 or state.workspaces.len > limits.max_workspaces or
        state.tasks.len > limits.max_tasks)
        return error.Invalid;
    var max_workspace_id: u64 = 0;
    var max_workspace_order: u64 = 0;
    for (state.workspaces, 0..) |workspace, index| {
        if (workspace.id == 0 or workspace.epoch == 0 or
            !oneOf(workspace.kind, &.{ "manual", "automatic" }) or
            (std.mem.eql(u8, workspace.kind, "manual") and workspace.recent_order == 0) or
            !validText(workspace.canonical_root, limits.max_workspace_bytes, false) or
            !std.fs.path.isAbsolute(workspace.canonical_root) or
            !validText(workspace.display_name, limits.max_workspace_bytes, false))
            return error.Invalid;
        for (state.workspaces[0..index]) |previous|
            if (previous.id == workspace.id or
                std.mem.eql(u8, previous.canonical_root, workspace.canonical_root))
                return error.Invalid;
        max_workspace_id = @max(max_workspace_id, workspace.id);
        max_workspace_order = @max(max_workspace_order, workspace.recent_order);
    }
    if (state.next_workspace_id <= max_workspace_id or
        state.next_workspace_recent_order <= max_workspace_order)
        return error.Invalid;
    var max_task_id: u64 = 0;
    var max_task_order: u64 = 0;
    for (state.tasks, 0..) |task, index| {
        if (task.id == 0 or task.recent_order == 0 or task.workspace_id == 0 or task.workspace_epoch == 0 or
            !validText(task.workspace_root, limits.max_workspace_bytes, false) or
            !validText(task.title, limits.max_task_title_bytes, true) or
            task.binding.epoch == 0 or task.binding.execution_generation == 0 or
            !oneOf(task.binding.provider, &.{ "anthropic", "openai" }) or
            !validBinding(task.binding, limits.max_tool_field_bytes) or
            task.runs.len > limits.max_runs_per_task or
            task.compacts.len > limits.max_compacts_per_task or
            task.ui_history.len > limits.max_ui_history_per_task)
            return error.Invalid;
        const workspace = findWorkspace(state.workspaces, task.workspace_id) orelse
            return error.Invalid;
        if (task.workspace_epoch > workspace.epoch or
            !std.mem.eql(u8, workspace.canonical_root, task.workspace_root))
            return error.Invalid;
        for (state.tasks[0..index]) |previous|
            if (previous.id == task.id) return error.Invalid;
        try validateTask(task, limits);
        max_task_id = @max(max_task_id, task.id);
        max_task_order = @max(max_task_order, task.recent_order);
    }
    if (state.next_task_id <= max_task_id or state.next_task_recent_order <= max_task_order)
        return error.Invalid;
    for (state.workspaces) |workspace| {
        if (!std.mem.eql(u8, workspace.kind, "automatic")) continue;
        if (workspace.visible or workspace.recent_order != 0)
            return error.Invalid;
        var task_count: usize = 0;
        for (state.tasks) |task|
            if (task.workspace_id == workspace.id) {
                task_count += 1;
            };
        if (task_count != 1) return error.Invalid;
    }
}

fn validateTask(task: TaskWire, limits: Limits) !void {
    var max_generation: u64 = 0;
    var active_count: usize = 0;
    for (task.runs, 0..) |run, index| {
        if (run.id == 0 or run.generation == 0 or run.execution_generation == 0 or
            !oneOf(run.execution_provider, &.{ "anthropic", "openai" }) or
            !validText(run.execution_model, limits.max_tool_field_bytes, false) or
            run.execution_generation != task.binding.execution_generation or
            !std.mem.eql(u8, run.execution_provider, task.binding.provider) or
            !std.mem.eql(u8, run.execution_model, task.binding.model) or
            !validText(run.assistant, limits.max_assistant_message_bytes, true) or
            !validText(run.status, limits.max_tool_field_bytes, true) or
            !validText(run.diagnostic, limits.max_terminal_diagnostic_bytes, true) or
            run.tools.len > limits.max_tools_per_run or run.next_activity_order == 0)
            return error.Invalid;
        for (task.runs[0..index]) |previous|
            if (previous.id == run.id or previous.generation == run.generation)
                return error.Invalid;
        try validateRunInput(run.input, limits);
        for (run.tools, 0..) |tool, tool_index| {
            if (!validText(tool.id, limits.max_tool_field_bytes, false) or
                tool.order == 0 or
                !validText(tool.name, limits.max_tool_field_bytes, false) or
                !validText(tool.input, limits.max_tool_field_bytes, true) or
                !validText(tool.progress, limits.max_tool_field_bytes, true) or
                !validText(tool.content, limits.max_tool_field_bytes, true) or
                !oneOf(tool.state, &.{ "running", "completed", "failed" }) or
                (std.mem.eql(u8, tool.state, "failed") != tool.is_error))
                return error.Invalid;
            for (run.tools[0..tool_index]) |previous|
                if (std.mem.eql(u8, previous.id, tool.id) or previous.order == tool.order)
                    return error.Invalid;
        }
        const terminal = terminalRunPhase(run.phase);
        if (terminal) {
            if (!validRunTerminalState(run.phase, run.outcome))
                return error.Invalid;
        } else {
            if (!oneOf(run.phase, &.{ "queued", "running", "waiting_ui", "stopping" }) or
                run.outcome != null or run.cause != null)
                return error.Invalid;
            active_count += 1;
        }
        if (run.cause) |cause| if (!oneOf(cause, &.{
            "user_cancel",
            "timeout",
            "session_close",
            "app_shutdown",
            "event_pipeline_failure",
            "queue_capacity_failure",
            "ui_pipeline_failure",
            "dependency_contract_failure",
            "stale_catalog",
            "skill_not_found",
            "invalid_skill_arguments",
            "skill_policy_violation",
            "skill_unavailable",
            "resource_limit",
        })) return error.Invalid;
        max_generation = @max(max_generation, run.generation);
    }
    if (task.next_run_generation < max_generation) return error.Invalid;
    for (task.compacts, 0..) |compact, index| {
        if (compact.id == 0 or compact.after_run_id == 0 or
            !validText(compact.diagnostic, limits.max_terminal_diagnostic_bytes, true))
            return error.Invalid;
        for (task.compacts[0..index]) |previous|
            if (previous.id == compact.id) return error.Invalid;
        const after_run = findRun(task.runs, compact.after_run_id) orelse
            return error.Invalid;
        if (!terminalRunPhase(after_run.phase)) return error.Invalid;
        if (!terminalCompactPhase(compact.phase)) {
            if (!oneOf(compact.phase, &.{ "queued", "compacting", "stopping" }))
                return error.Invalid;
            if (compact.cause != null) return error.Invalid;
            active_count += 1;
        } else {
            const failed = std.mem.eql(u8, compact.phase, "aborted") or
                std.mem.eql(u8, compact.phase, "failed");
            if (failed != (compact.cause != null)) return error.Invalid;
            if (compact.cause) |cause|
                if (!oneOf(cause, &.{ "user_cancel", "session_close", "app_shutdown", "resource_limit", "agent_failure", "dependency_contract_failure" }))
                    return error.Invalid;
        }
    }
    if (active_count > 1 or ((task.active_operation == null) != (active_count == 0)) or
        ((task.closed or task.archived) and active_count != 0))
        return error.Invalid;
    if (task.active_operation) |operation| {
        if (operation.id == 0 or !oneOf(operation.kind, &.{ "run", "compact" }))
            return error.Invalid;
        if (std.mem.eql(u8, operation.kind, "run")) {
            const run = findRun(task.runs, operation.id) orelse return error.Invalid;
            if (terminalRunPhase(run.phase)) return error.Invalid;
        } else {
            const compact = findCompact(task.compacts, operation.id) orelse
                return error.Invalid;
            if (terminalCompactPhase(compact.phase)) return error.Invalid;
        }
    }
    for (task.ui_history, 0..) |record, index| {
        if (record.request_id == 0 or record.run_id == 0 or record.order == 0 or
            !oneOf(record.kind, &.{ "ask_question", "permission" }) or
            !oneOf(record.state, &.{ "answered", "allowed_once", "allowed_always", "denied", "denied_session", "cancelled" }) or
            !validText(record.detail, 512, true) or findRun(task.runs, record.run_id) == null)
            return error.Invalid;
        if (!validText(record.agent_request_id, 128, true)) return error.Invalid;
        if (std.mem.eql(u8, record.kind, "ask_question") and record.permission != null)
            return error.Invalid;
        if (record.permission) |permission| {
            if (!std.mem.eql(u8, record.kind, "permission") or
                !std.mem.eql(u8, record.agent_request_id, permission.request_id) or
                !validText(permission.request_id, 128, false) or
                !validText(permission.matched_rule_id, 128, true) or
                !validText(permission.tool_namespace, 32, false) or
                !validText(permission.tool_name, 128, false) or
                !validText(permission.tool_binding, 128, false) or
                !validText(permission.decision, 16, false) or
                !validText(permission.source, 64, false) or
                !oneOf(permission.tool_namespace, &.{ "builtin", "host", "mcp" }) or
                !oneOf(permission.decision, &.{ "allow", "ask", "deny" }) or
                !oneOf(permission.source, &.{ "core_safety", "active_skill", "explicit_deny", "session_deny", "explicit_ask", "explicit_allow", "session_allow", "builtin_classification", "mode_fallback", "callback" }))
                return error.Invalid;
            if (permission.callback_outcome) |outcome|
                if (!oneOf(outcome, &.{ "answered", "user_cancelled", "unavailable", "contract_failure" }))
                    return error.Invalid;
        }
        for (task.ui_history[0..index]) |previous|
            if (previous.request_id == record.request_id or
                (previous.run_id == record.run_id and previous.order == record.order))
                return error.Invalid;
        const run = findRun(task.runs, record.run_id) orelse unreachable;
        for (run.tools) |tool| if (tool.order == record.order)
            return error.Invalid;
    }
    for (task.runs) |run| {
        var max_activity_order: u64 = 0;
        for (run.tools) |tool| max_activity_order = @max(max_activity_order, tool.order);
        for (task.ui_history) |record| {
            if (record.run_id == run.id)
                max_activity_order = @max(max_activity_order, record.order);
        }
        if (run.next_activity_order <= max_activity_order) return error.Invalid;
    }
}

fn validRunTerminalState(phase: []const u8, outcome: ?[]const u8) bool {
    const value = outcome orelse return false;
    if (std.mem.eql(u8, phase, "failed"))
        return oneOf(value, &.{ "failed", "dependency_contract_failure" });
    return std.mem.eql(u8, phase, value) and oneOf(phase, &.{
        "completed", "stopped", "cancelled", "interrupted",
    });
}

fn validateRunInput(input: RunInputWire, limits: Limits) !void {
    if (std.mem.eql(u8, input.kind, "text")) {
        if (input.skill_id != null or input.catalog_revision != null or
            input.invocation_name != null or input.display_name != null or
            input.argument_values != null)
            return error.Invalid;
        if (!validText(input.text orelse return error.Invalid, limits.max_user_message_bytes, false))
            return error.Invalid;
        return;
    }
    if (!std.mem.eql(u8, input.kind, "skill") or input.text != null)
        return error.Invalid;
    if (!validText(input.skill_id orelse return error.Invalid, limits.max_tool_field_bytes, false) or
        !validText(input.catalog_revision orelse return error.Invalid, limits.max_tool_field_bytes, false) or
        !validText(input.invocation_name orelse return error.Invalid, limits.max_tool_field_bytes, false) or
        !validText(input.display_name orelse return error.Invalid, limits.max_tool_field_bytes, false))
        return error.Invalid;
    const values = input.argument_values orelse return error.Invalid;
    if (values.len > 64) return error.Invalid;
    for (values) |value|
        if (!validText(value, limits.max_user_message_bytes, true))
            return error.Invalid;
}

fn validBinding(binding: BindingWire, max: usize) bool {
    return validText(binding.model, max, false);
}

fn validText(value: []const u8, max: usize, allow_empty: bool) bool {
    return (allow_empty or value.len != 0) and value.len <= max and
        std.unicode.utf8ValidateSlice(value);
}

fn oneOf(value: []const u8, options: []const []const u8) bool {
    for (options) |option| if (std.mem.eql(u8, value, option)) return true;
    return false;
}

fn terminalRunPhase(phase: []const u8) bool {
    return oneOf(phase, &.{ "completed", "stopped", "cancelled", "interrupted", "failed" });
}

fn terminalCompactPhase(phase: []const u8) bool {
    return oneOf(phase, &.{ "compacted", "no_change", "degraded", "aborted", "interrupted", "failed" });
}

fn findWorkspace(items: []const WorkspaceWire, id: u64) ?WorkspaceWire {
    for (items) |item| if (item.id == id) return item;
    return null;
}

fn findRun(items: []const RunWire, id: u64) ?RunWire {
    for (items) |item| if (item.id == id) return item;
    return null;
}

fn findCompact(items: []const CompactWire, id: u64) ?CompactWire {
    for (items) |item| if (item.id == id) return item;
    return null;
}

test "task store rejects unknown schema fields and dangling workspace references" {
    const limits = testLimits();
    const unknown =
        \\{"schema_version":1,"next_workspace_id":1,"next_workspace_recent_order":1,"next_task_id":1,"next_task_recent_order":1,"workspaces":[],"tasks":[],"extra":true}
    ;
    try std.testing.expectError(
        error.TaskStoreCorrupt,
        decode(std.testing.allocator, unknown, limits),
    );
    const retired_identity_binding =
        \\{"schema_version":1,"next_workspace_id":2,"next_workspace_recent_order":2,"next_task_id":2,"next_task_recent_order":2,"workspaces":[{"id":1,"epoch":1,"kind":"manual","canonical_root":"/tmp/repo","display_name":"repo","visible":true,"recent_order":1}],"tasks":[{"id":1,"recent_order":1,"workspace_id":1,"workspace_epoch":1,"workspace_root":"/tmp/repo","title":"","title_redacted":false,"archived":false,"closed":false,"binding":{"epoch":1,"execution_generation":1,"provider":"openai","model":"m","account_id":"retired"},"next_run_generation":0,"active_operation":null,"runs":[],"compacts":[],"ui_history":[]}]}
    ;
    try std.testing.expectError(
        error.TaskStoreCorrupt,
        decode(std.testing.allocator, retired_identity_binding, limits),
    );
    const dangling =
        \\{"schema_version":1,"next_workspace_id":1,"next_workspace_recent_order":1,"next_task_id":2,"next_task_recent_order":2,"workspaces":[],"tasks":[{"id":1,"recent_order":1,"workspace_id":1,"workspace_epoch":1,"workspace_root":"C:\\\\repo","title":"","title_redacted":false,"archived":false,"closed":false,"binding":{"epoch":1,"execution_generation":1,"provider":"openai","model":"m"},"next_run_generation":0,"active_operation":null,"runs":[],"compacts":[],"ui_history":[]}]}
    ;
    try std.testing.expectError(
        error.TaskStoreCorrupt,
        decode(std.testing.allocator, dangling, limits),
    );
}

test "task store preserves history bound to an older Workspace epoch" {
    const state =
        \\{"schema_version":1,"next_workspace_id":2,"next_workspace_recent_order":2,"next_task_id":2,"next_task_recent_order":2,"workspaces":[{"id":1,"epoch":2,"kind":"manual","canonical_root":"/tmp/repo","display_name":"repo","visible":true,"recent_order":1}],"tasks":[{"id":1,"recent_order":1,"workspace_id":1,"workspace_epoch":1,"workspace_root":"/tmp/repo","title":"","title_redacted":false,"archived":false,"closed":false,"binding":{"epoch":1,"execution_generation":1,"provider":"openai","model":"m"},"next_run_generation":0,"active_operation":null,"runs":[],"compacts":[],"ui_history":[]}]}
    ;
    var parsed = try decode(std.testing.allocator, state, testLimits());
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u64, 2), parsed.value.workspaces[0].epoch);
    try std.testing.expectEqual(@as(u64, 1), parsed.value.tasks[0].workspace_epoch);
}

test "task store rejects states that would violate the Renderer contract" {
    var workspaces = [_]WorkspaceWire{.{
        .id = 1,
        .epoch = 1,
        .kind = "manual",
        .canonical_root = "/tmp/repo",
        .display_name = "repo",
        .visible = true,
        .recent_order = 1,
    }};
    var tools = [_]ToolWire{.{
        .id = "tool-1",
        .order = 1,
        .name = "Read",
        .input = "",
        .progress = "",
        .content = "done",
        .state = "completed",
        .is_error = false,
        .elapsed_ms = 1,
        .input_truncated = false,
        .progress_truncated = false,
        .content_truncated = false,
        .redacted = false,
    }};
    var runs = [_]RunWire{.{
        .id = 1,
        .generation = 1,
        .execution_generation = 1,
        .execution_provider = "openai",
        .execution_model = "model",
        .input = .{
            .kind = "text",
            .text = "inspect",
            .skill_id = null,
            .catalog_revision = null,
            .invocation_name = null,
            .display_name = null,
            .argument_values = null,
            .redacted = false,
        },
        .assistant = "done",
        .assistant_redacted = false,
        .phase = "completed",
        .outcome = "completed",
        .cause = null,
        .status = "Completed",
        .usage = .{
            .input_tokens = 1,
            .output_tokens = 1,
            .cache_read_input_tokens = 0,
            .cache_creation_input_tokens = 0,
        },
        .tools = &tools,
        .diagnostic = "",
        .diagnostic_truncated = false,
        .diagnostic_redacted = false,
        .event_projection_failure = false,
        .next_activity_order = 3,
    }};
    var compacts = [_]CompactWire{.{
        .id = 2,
        .after_run_id = 1,
        .phase = "compacted",
        .cause = null,
        .before_context_tokens = 10,
        .after_context_tokens = 5,
        .usage = .{
            .input_tokens = 0,
            .output_tokens = 0,
            .cache_read_input_tokens = 0,
            .cache_creation_input_tokens = 0,
        },
        .diagnostic = "",
        .diagnostic_truncated = false,
        .diagnostic_redacted = false,
    }};
    var ui_history = [_]UiRecordWire{.{
        .request_id = 1,
        .run_id = 1,
        .order = 2,
        .kind = "permission",
        .state = "allowed_once",
        .detail = "Read",
        .item_count = 0,
        .detail_truncated = false,
        .redacted = false,
    }};
    var tasks = [_]TaskWire{.{
        .id = 1,
        .recent_order = 1,
        .workspace_id = 1,
        .workspace_epoch = 1,
        .workspace_root = "/tmp/repo",
        .title = "task",
        .title_redacted = false,
        .archived = false,
        .closed = false,
        .binding = .{
            .epoch = 1,
            .execution_generation = 1,
            .provider = "openai",
            .model = "model",
        },
        .next_run_generation = 1,
        .active_operation = null,
        .runs = &runs,
        .compacts = &compacts,
        .ui_history = &ui_history,
    }};
    var state: StateWire = .{
        .schema_version = schema_version,
        .next_workspace_id = 2,
        .next_workspace_recent_order = 2,
        .next_task_id = 2,
        .next_task_recent_order = 2,
        .workspaces = &workspaces,
        .tasks = &tasks,
    };
    try validate(&state, testLimits());

    workspaces[0].recent_order = 0;
    try std.testing.expectError(error.Invalid, validate(&state, testLimits()));
    workspaces[0].recent_order = 1;

    tasks[0].recent_order = 0;
    try std.testing.expectError(error.Invalid, validate(&state, testLimits()));
    tasks[0].recent_order = 1;

    runs[0].outcome = "failed";
    try std.testing.expectError(error.Invalid, validate(&state, testLimits()));
    runs[0].outcome = "completed";

    tools[0].state = "failed";
    try std.testing.expectError(error.Invalid, validate(&state, testLimits()));
    tools[0].state = "completed";

    compacts[0].after_run_id = 99;
    try std.testing.expectError(error.Invalid, validate(&state, testLimits()));
    compacts[0].after_run_id = 1;

    compacts[0].cause = "user_cancel";
    try std.testing.expectError(error.Invalid, validate(&state, testLimits()));
    compacts[0].cause = null;

    ui_history[0].order = 1;
    try std.testing.expectError(error.Invalid, validate(&state, testLimits()));
}

test "task file store holds one writer and atomically replaces bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var absolute_storage: [std.fs.max_path_bytes]u8 = undefined;
    const absolute_len = try tmp.dir.realPath(std.testing.io, &absolute_storage);
    const absolute = absolute_storage[0..absolute_len];
    var first = try FileStore.init(std.testing.io, absolute);
    defer first.deinit();
    try std.testing.expectError(
        error.WriterAlreadyActive,
        FileStore.init(std.testing.io, absolute),
    );
    try first.commit("{\"schema_version\":1}");
    try first.commit("{\"schema_version\":2}");
    const restored = (try first.loadAlloc(std.testing.allocator)).?;
    defer std.testing.allocator.free(restored);
    try std.testing.expectEqualStrings("{\"schema_version\":2}", restored);
}

test "task file store ignores the retired pre-release file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "workbench-state.json",
        .data = "retired",
    });
    var absolute_storage: [std.fs.max_path_bytes]u8 = undefined;
    const absolute_len = try tmp.dir.realPath(std.testing.io, &absolute_storage);
    var store = try FileStore.init(
        std.testing.io,
        absolute_storage[0..absolute_len],
    );
    defer store.deinit();

    try std.testing.expectEqual(null, try store.loadAlloc(std.testing.allocator));
}

fn testLimits() Limits {
    return .{
        .max_workspaces = 4,
        .max_tasks = 4,
        .max_runs_per_task = 4,
        .max_compacts_per_task = 4,
        .max_tools_per_run = 4,
        .max_ui_history_per_task = 4,
        .max_workspace_bytes = 1024,
        .max_task_title_bytes = 512,
        .max_user_message_bytes = 4096,
        .max_assistant_message_bytes = 4096,
        .max_tool_field_bytes = 4096,
        .max_terminal_diagnostic_bytes = 512,
    };
}
