//! Product Task history capability, wire projection, strict codec, and restore.
//! Workspace-frame assembly, global projection accounting, durable commit
//! orchestration, revision publication, and snapshot encoding remain outside.

const std = @import("std");
const builtin = @import("builtin");
const agent = @import("metawork_agent");
const checkpoint_record = @import("product_task_checkpoint_record");
const checkpoint_store = @import("product_task_checkpoint_store");
const task_state = @import("product_task_state");

/// Callback-scoped text buffer used while reconstructing Task history. The
/// persistence leaf owns this wire-to-memory contract; callers never retain
/// or inspect the enclosing live Task aggregate through it.
pub const RestoreText = task_state.TrackedText;

// Hard-cut persistence format. This deliberately has no migration/version
// contract: the fixed frame layout and magic identify the sole active format.
pub const max_store_bytes: usize = 16 * 1024 * 1024;
pub const max_failure_records: usize = 1024;
pub const max_failure_reason_bytes: usize = 256;
pub const file_name = "workbench-history.store";
const lock_file_name = ".workbench-history.lock";
const frame_magic = "MWTF";
const frame_header_bytes: usize = 36;
const record_meta: u8 = 1;
const record_workspace: u8 = 2;
const record_task: u8 = 3;
const record_task_failure: u8 = 4;

pub const Error = error{
    TaskStoreEmpty,
    TaskStoreTooLarge,
    TaskStoreCorrupt,
    TaskStoreEncodeFailed,
    TaskIdentityExhausted,
};

pub const RecoveryError = Error || std.mem.Allocator.Error;

pub const FileStoreError = std.mem.Allocator.Error || error{
    DirectoryUnavailable,
    WriterAlreadyActive,
    ReadFailed,
    WriteFailed,
    PersistenceOutcomeUnknown,
};

pub const Commit = enum {
    committed,
    failed,
    outcome_unknown,
};

/// Application-bound durable effect and startup restore facts. The Product
/// Task persistence kernel owns the requirement; the concrete file resource
/// and commit execution remain outside this module.
pub const Capability = struct {
    context: ?*anyopaque = null,
    enabled: bool = false,
    restored_bytes: ?[]const u8 = null,
    restore_failed: bool = false,
    commit_fn: *const fn (
        context: ?*anyopaque,
        bytes: []const u8,
    ) Commit = unsupportedCommit,
    recover_fn: *const fn (
        context: ?*anyopaque,
        bytes: []const u8,
    ) Commit = unsupportedCommit,

    pub fn commit(self: Capability, bytes: []const u8) Commit {
        if (!self.enabled) return .failed;
        return self.commit_fn(self.context, bytes);
    }

    pub fn recover(self: Capability, bytes: []const u8) Commit {
        if (!self.enabled) return .failed;
        return self.recover_fn(self.context, bytes);
    }

    fn unsupportedCommit(_: ?*anyopaque, _: []const u8) Commit {
        return .failed;
    }
};

pub const Health = enum {
    unavailable,
    ready,
    degraded,
    read_failed,
    corrupt,
    write_failed,
    outcome_unknown,

    pub fn operational(self: Health) bool {
        return self == .ready or self == .degraded;
    }
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

    /// Preserves the current canonical bytes under a unique quarantine name
    /// before installing the Product-provided replacement. No recovery path
    /// decodes, migrates, overwrites, or deletes the quarantined artifact.
    pub fn recover(self: *FileStore, bytes: []const u8) FileStoreError!void {
        if (bytes.len == 0 or bytes.len > max_store_bytes)
            return error.WriteFailed;
        try self.quarantineCanonical();
        return self.commit(bytes);
    }

    fn quarantineCanonical(self: *FileStore) FileStoreError!void {
        var random: [8]u8 = undefined;
        std.Io.randomSecure(self.io, &random) catch return error.WriteFailed;
        const random_hex = std.fmt.bytesToHex(random, .lower);
        var quarantine_name_storage: [80]u8 = undefined;
        var name_writer = std.Io.Writer.fixed(&quarantine_name_storage);
        name_writer.print(
            ".workbench-history.recovery.{s}.bak",
            .{random_hex},
        ) catch return error.WriteFailed;
        self.dir.rename(
            file_name,
            self.dir,
            name_writer.buffered(),
            self.io,
        ) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return error.WriteFailed,
        };
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
    max_commentary_segments_per_run: usize,
    max_file_refs_per_tool: usize,
    max_file_changes_per_run: usize = 256,
    max_ui_history_per_task: usize,
    max_workspace_bytes: usize,
    max_task_title_bytes: usize,
    max_user_message_bytes: usize,
    max_assistant_message_bytes: usize,
    max_tool_field_bytes: usize,
    max_file_ref_field_bytes: usize,
    max_file_change_field_bytes: usize = 4096,
    max_file_change_diff_bytes: usize = 256 * 1024,
    max_execution_model_bytes: usize,
    max_terminal_diagnostic_bytes: usize,
};

pub const StateWire = struct {
    default_permission_profile: []const u8 = "approval_required",
    next_workspace_id: u64,
    next_workspace_recent_order: u64,
    next_task_id: u64,
    next_task_recent_order: u64,
    workspaces: []WorkspaceWire,
    tasks: []TaskWire,
    failures: []TaskFailureWire = &.{},
};

pub const TaskFailureWire = struct {
    task_id: u64,
    recent_order: u64,
    reason: []const u8,
};

pub const RecoveredState = struct {
    arena: *std.heap.ArenaAllocator,
    value: StateWire,
    dropped_workspaces: usize = 0,
    dropped_tasks: usize = 0,
    degraded: bool = false,

    pub fn deinit(self: *@This()) void {
        const allocator = self.arena.child_allocator;
        self.arena.deinit();
        allocator.destroy(self.arena);
        self.* = undefined;
    }
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
    permission_profile: []const u8,
    permission_interaction: []const u8,
    binding: BindingWire,
    next_run_generation: u64,
    active_operation: ?OperationWire,
    runs: []RunWire,
    compacts: []CompactWire,
    ui_history: []UiRecordWire,
    checkpoint: ?CheckpointWire = null,
    checkpoint_anchor: []const u8 = "none",
    checkpoint_attempt: []const u8 = "none",
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
    protocol: []const u8,
    model: []const u8,
};

pub const OperationWire = struct { kind: []const u8, id: u64 };

pub const RunWire = struct {
    id: u64,
    generation: u64,
    execution_generation: u64,
    execution_protocol: []const u8,
    execution_model: []const u8,
    permission_profile: []const u8,
    permission_interaction: []const u8,
    input: RunInputWire,
    assistant: []const u8,
    assistant_redacted: bool,
    commentary_ends: []const u64,
    assistant_output_kind: ?[]const u8,
    assistant_output_start: ?u64,
    phase: []const u8,
    outcome: ?[]const u8,
    cause: ?[]const u8,
    usage: UsageWire,
    tools: []ToolWire,
    file_change_observation: ?[]const u8 = null,
    file_changes: ?[]FileChangeWire = null,
    diagnostic: []const u8,
    diagnostic_truncated: bool,
    diagnostic_redacted: bool,
    event_projection_failure: ?[]const u8,
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
    file_refs: ?[]FileReferenceWire = null,
};

pub const FileReferencePositionWire = struct {
    line: u32,
    column: u32,
};

pub const FileReferenceRangeWire = struct {
    start: FileReferencePositionWire,
    end: FileReferencePositionWire,
};

pub const FileReferenceWire = struct {
    id: []const u8,
    title: []const u8,
    display_path: []const u8,
    kind: []const u8,
    locator_kind: []const u8,
    locator: []const u8,
    range: ?FileReferenceRangeWire = null,
};

pub const FileChangeArtifactWire = struct {
    run_generation: u64,
    change_order: u64,
    digest: []const u8,
    byte_size: u64,
};

pub const FileChangeWire = struct {
    id: []const u8,
    order: u64,
    kind: []const u8,
    status: []const u8,
    display_path: []const u8,
    from_display_path: ?[]const u8,
    before_bytes: u64,
    after_bytes: u64,
    artifact: ?FileChangeArtifactWire,
    diff_complete: bool,
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

pub const CheckpointPersistenceOverride = struct {
    task_id: u64,
    record: *const checkpoint_record.Record,
    anchor: task_state.CheckpointAnchor,
};

/// Owns every temporary allocation needed to encode one canonical history
/// snapshot. Root Workspace frames are assembled by the composition owner and
/// transferred into this scratch together with Product Task projections.
pub const TaskStateWireScratch = struct {
    allocator: std.mem.Allocator,
    state: StateWire,
    allocated_workspaces: []WorkspaceWire,
    allocated_tasks: []TaskWire,
    allocated_failures: []TaskFailureWire,

    pub fn deinit(self: *TaskStateWireScratch) void {
        deinitTaskWires(self.allocator, self.state.tasks);
        self.allocator.free(self.allocated_tasks);
        self.allocator.free(self.allocated_workspaces);
        self.allocator.free(self.allocated_failures);
        self.* = undefined;
    }
};

pub fn deinitTaskWires(allocator: std.mem.Allocator, tasks: []TaskWire) void {
    for (tasks) |task| {
        for (task.runs) |run| {
            if (run.input.argument_values) |values| allocator.free(values);
            for (run.tools) |tool|
                if (tool.file_refs) |references| allocator.free(references);
            allocator.free(run.tools);
            if (run.file_changes) |changes| {
                for (changes) |change| if (change.artifact) |artifact|
                    allocator.free(@constCast(artifact.digest));
                allocator.free(changes);
            }
        }
        allocator.free(task.runs);
        allocator.free(task.compacts);
        allocator.free(task.ui_history);
        if (task.checkpoint) |checkpoint|
            allocator.free(@constCast(checkpoint.blob.digest));
    }
}

pub fn projectTask(
    allocator: std.mem.Allocator,
    task: *task_state.Task,
    checkpoint_override: ?CheckpointPersistenceOverride,
) std.mem.Allocator.Error!TaskWire {
    const checkpoint: ?*const checkpoint_record.Record = if (checkpoint_override) |override|
        if (override.task_id == task.durable.id)
            override.record
        else if (task.durable.checkpoint) |*value| value else null
    else if (task.durable.checkpoint) |*value| value else null;
    const override_applies = if (checkpoint_override) |override|
        override.task_id == task.durable.id
    else
        false;
    const checkpoint_anchor = if (override_applies)
        checkpoint_override.?.anchor
    else
        task.durable.checkpoint_anchor;
    const checkpoint_attempt = if (override_applies)
        task_state.CheckpointAttempt.none
    else
        task.durable.checkpoint_attempt;
    const checkpoint_digest = if (checkpoint) |value| blk: {
        const digest = try allocator.alloc(u8, checkpoint_store.digest_bytes * 2);
        const encoded = std.fmt.bytesToHex(value.blob.digest, .lower);
        @memcpy(digest, &encoded);
        break :blk digest;
    } else null;
    errdefer if (checkpoint_digest) |digest| allocator.free(digest);

    const run_count = countPresent(task_state.RunRecord, task.durable.runs);
    const runs = try allocator.alloc(RunWire, run_count);
    errdefer allocator.free(runs);
    var run_index: usize = 0;
    errdefer for (runs[0..run_index]) |run| {
        if (run.input.argument_values) |values| allocator.free(values);
        for (run.tools) |tool|
            if (tool.file_refs) |references| allocator.free(references);
        allocator.free(run.tools);
        if (run.file_changes) |changes| {
            for (changes) |change| if (change.artifact) |artifact|
                allocator.free(@constCast(artifact.digest));
            allocator.free(changes);
        }
    };
    for (task.durable.runs) |*entry| {
        const run = &(entry.* orelse continue);
        runs[run_index] = try projectRun(allocator, run);
        run_index += 1;
    }

    const compact_count = countPresent(task_state.CompactRecord, task.durable.compacts);
    const compacts = try allocator.alloc(CompactWire, compact_count);
    errdefer allocator.free(compacts);
    var compact_index: usize = 0;
    for (task.durable.compacts) |*entry| {
        const compact = &(entry.* orelse continue);
        const terminal = task_state.compactTerminalPayload(compact);
        const phase = if (terminal) |payload|
            payload.phase
        else
            task_state.activeCompactPhase(compact);
        const diagnostic = if (terminal) |payload|
            compact.terminal_diagnostic[0..payload.diagnostic_len]
        else
            "";
        compacts[compact_index] = .{
            .id = compact.id,
            .after_run_id = compact.after_run_id,
            .phase = @tagName(phase),
            .cause = if (terminal) |payload|
                if (payload.cause) |cause| @tagName(cause) else null
            else
                null,
            .before_context_tokens = if (terminal) |payload| payload.before_context_tokens else 0,
            .after_context_tokens = if (terminal) |payload| payload.after_context_tokens else 0,
            .usage = usageWire(if (terminal) |payload| payload.usage else .{}),
            .diagnostic = diagnostic,
            .diagnostic_truncated = if (terminal) |payload| payload.diagnostic_truncated else false,
            .diagnostic_redacted = if (terminal) |payload| payload.diagnostic_redacted else false,
        };
        compact_index += 1;
    }

    const ui_history = try allocator.alloc(UiRecordWire, task.durable.ui_history_count);
    errdefer allocator.free(ui_history);
    const ui_start = if (task.durable.ui_history_count == task.durable.ui_history.len)
        task.durable.ui_history_next
    else
        0;
    for (ui_history, 0..) |*target, offset| {
        const index = (ui_start + offset) % task.durable.ui_history.len;
        const record = &(task.durable.ui_history[index] orelse unreachable);
        target.* = .{
            .request_id = record.request_id,
            .run_id = record.run_id,
            .order = record.order,
            .kind = @tagName(record.kind),
            .state = @tagName(record.state),
            .detail = record.detailSlice(),
            .item_count = record.item_count,
            .detail_truncated = record.detail_truncated,
            .redacted = record.redacted,
            .agent_request_id = record.agent_request_id[0..record.agent_request_id_len],
            .permission = if (record.permission) |*permission|
                permissionSummaryWire(permission)
            else
                null,
        };
    }

    return .{
        .id = task.durable.id,
        .recent_order = task.durable.recent_order,
        .workspace_id = task.durable.workspace_id,
        .workspace_epoch = task.durable.workspace_epoch,
        .workspace_root = task.durable.workspace_root,
        .title = task.durable.title,
        .title_redacted = task.durable.title_redacted,
        .archived = task.durable.archived,
        .permission_profile = @tagName(task.durable.permission_profile),
        .permission_interaction = @tagName(task.durable.permission_interaction),
        .binding = .{
            .epoch = task.durable.binding_epoch,
            .execution_generation = task.durable.execution_generation,
            .protocol = @tagName(task.durable.execution_protocol),
            .model = task.durable.execution_model,
        },
        .next_run_generation = task.durable.next_run_generation,
        .active_operation = switch (task.runtime.active_operation) {
            .none => null,
            .run => |id| .{ .kind = "run", .id = id },
            .compact => |id| .{ .kind = "compact", .id = id },
            .restore => null,
        },
        .runs = runs,
        .compacts = compacts,
        .ui_history = ui_history,
        .checkpoint = if (checkpoint) |value| .{
            .blob = .{
                .generation = value.blob.generation,
                .byte_size = value.blob.byte_size,
                .digest = checkpoint_digest.?,
            },
            .session = .{
                .logical_session_id = value.session.logical_session_id,
                .last_run_id = value.session.last_run_id,
                .last_compact_id = value.session.last_compact_id,
                .model = value.session.model,
            },
            .anchor = .{
                .terminal = .{
                    .kind = @tagName(value.anchor.terminal),
                    .id = value.anchor.terminal.id(),
                },
                .binding_epoch = value.anchor.binding_epoch,
            },
        } else null,
        .checkpoint_anchor = @tagName(checkpoint_anchor),
        .checkpoint_attempt = @tagName(checkpoint_attempt),
    };
}

fn projectRun(
    allocator: std.mem.Allocator,
    run: *task_state.RunRecord,
) std.mem.Allocator.Error!RunWire {
    const tool_count = countPresent(task_state.ToolView, run.tools);
    const tools = try allocator.alloc(ToolWire, tool_count);
    errdefer allocator.free(tools);
    var tool_index: usize = 0;
    errdefer for (tools[0..tool_index]) |tool|
        if (tool.file_refs) |references| allocator.free(references);
    for (run.tools) |entry| {
        const tool = entry orelse continue;
        const file_ref_count = if (tool.file_refs) |references|
            countPresent(task_state.FileReferenceView, references)
        else
            0;
        const file_refs = if (file_ref_count != 0)
            try allocator.alloc(FileReferenceWire, file_ref_count)
        else
            null;
        errdefer if (file_refs) |references| allocator.free(references);
        if (file_refs) |references| {
            var file_ref_index: usize = 0;
            for (tool.file_refs.?) |reference_entry| {
                const reference = reference_entry orelse continue;
                references[file_ref_index] = .{
                    .id = reference.id,
                    .title = reference.title,
                    .display_path = reference.display_path,
                    .kind = reference.kind,
                    .locator_kind = @tagName(reference.locator_kind),
                    .locator = reference.locator,
                    .range = if (reference.range) |range| .{
                        .start = .{ .line = range.start.line, .column = range.start.column },
                        .end = .{ .line = range.end.line, .column = range.end.column },
                    } else null,
                };
                file_ref_index += 1;
            }
        }
        tools[tool_index] = .{
            .id = tool.id,
            .order = tool.order,
            .name = tool.name,
            .input = tool.input,
            .progress = tool.progress,
            .content = tool.content,
            .state = @tagName(tool.state),
            .is_error = tool.is_error,
            .elapsed_ms = tool.elapsed_ms,
            .input_truncated = tool.input_truncated,
            .progress_truncated = tool.progress_truncated,
            .content_truncated = tool.content_truncated,
            .redacted = tool.redacted,
            .file_refs = file_refs,
        };
        tool_index += 1;
    }

    const file_changes = if (run.file_change_observation != null) blk: {
        const count = countPresent(task_state.FileChangeView, run.file_changes);
        const changes = try allocator.alloc(FileChangeWire, count);
        errdefer allocator.free(changes);
        var change_index: usize = 0;
        errdefer for (changes[0..change_index]) |change| if (change.artifact) |artifact|
            allocator.free(@constCast(artifact.digest));
        for (run.file_changes) |entry| {
            const change = entry orelse continue;
            const artifact = if (change.artifact) |value| artifact: {
                const digest = try allocator.alloc(u8, value.digest.len * 2);
                const encoded = std.fmt.bytesToHex(value.digest, .lower);
                @memcpy(digest, &encoded);
                break :artifact FileChangeArtifactWire{
                    .run_generation = value.run_generation,
                    .change_order = value.change_order,
                    .digest = digest,
                    .byte_size = value.byte_size,
                };
            } else null;
            changes[change_index] = .{
                .id = change.id,
                .order = change.order,
                .kind = @tagName(change.kind),
                .status = @tagName(change.status),
                .display_path = change.display_path,
                .from_display_path = change.from_display_path,
                .before_bytes = change.before_bytes,
                .after_bytes = change.after_bytes,
                .artifact = artifact,
                .diff_complete = change.diff_complete,
                .redacted = change.redacted,
            };
            change_index += 1;
        }
        break :blk changes;
    } else null;
    errdefer if (file_changes) |changes| {
        for (changes) |change| if (change.artifact) |artifact|
            allocator.free(@constCast(artifact.digest));
        allocator.free(changes);
    };

    var argument_values: ?[][]const u8 = null;
    errdefer if (argument_values) |values| allocator.free(values);
    const input: RunInputWire = switch (run.input) {
        .text => |text| .{
            .kind = "text",
            .text = text.value,
            .skill_id = null,
            .catalog_revision = null,
            .invocation_name = null,
            .display_name = null,
            .argument_values = null,
            .redacted = text.redacted,
        },
        .skill => |skill| input: {
            const values = try allocator.alloc([]const u8, skill.argument_values.len);
            for (values, skill.argument_values) |*target, value| target.* = value;
            argument_values = values;
            break :input .{
                .kind = "skill",
                .text = null,
                .skill_id = skill.skill_id,
                .catalog_revision = skill.catalog_revision,
                .invocation_name = skill.invocation_name,
                .display_name = skill.display_name,
                .argument_values = values,
                .redacted = skill.redacted,
            };
        },
    };
    const projection = task_state.runProjectionFacts(run);
    const terminal = projection.terminal;
    const terminal_payload = if (terminal != null) task_state.terminalPayload(run) else null;
    const file_change_observation = if (run.file_change_observation) |value|
        if (terminal != null and value == .collecting)
            task_state.FileChangeObservation.incomplete
        else
            value
    else
        null;
    return .{
        .id = run.id,
        .generation = run.generation,
        .execution_generation = run.execution_generation,
        .execution_protocol = @tagName(run.execution_protocol),
        .execution_model = run.execution_model,
        .permission_profile = @tagName(run.permission_profile),
        .permission_interaction = @tagName(run.permission_interaction),
        .input = input,
        .assistant = run.assistant.list.items[0..run.assistant.committed_len],
        .assistant_redacted = run.assistant_redacted,
        .commentary_ends = run.commentary_ends[0..run.commentary_count],
        .assistant_output_kind = if (run.assistant_output_kind) |kind| @tagName(kind) else null,
        .assistant_output_start = if (run.assistant_output_start) |start| @intCast(start) else null,
        .phase = @tagName(projection.phase),
        .outcome = if (terminal) |value| @tagName(value.outcome) else null,
        .cause = if (terminal) |value|
            if (value.cause) |cause| @tagName(cause) else null
        else
            null,
        .usage = usageWire(run.usage),
        .tools = tools,
        .file_change_observation = if (file_change_observation) |value|
            @tagName(value)
        else
            null,
        .file_changes = file_changes,
        .diagnostic = if (terminal_payload) |payload|
            run.terminal_diagnostic[0..payload.diagnostic_len]
        else
            "",
        .diagnostic_truncated = if (terminal_payload) |payload| payload.diagnostic_truncated else false,
        .diagnostic_redacted = if (terminal_payload) |payload| payload.diagnostic_redacted else false,
        .event_projection_failure = if (run.event_projection_failure) |failure| @tagName(failure) else null,
        .next_activity_order = run.next_activity_order,
    };
}

fn permissionSummaryWire(permission: *const task_state.PermissionSummary) PermissionSummaryWire {
    return .{
        .request_id = permission.requestId(),
        .matched_rule_id = permission.matchedRuleId(),
        .tool_namespace = @tagName(permission.tool_namespace),
        .tool_name = permission.toolName(),
        .tool_binding = permission.toolBinding(),
        .decision = @tagName(permission.decision),
        .source = @tagName(permission.source),
        .policy_generation = permission.policy_generation,
        .used_session_rule = permission.used_session_rule,
        .callback_outcome = if (permission.callback_outcome) |outcome| @tagName(outcome) else null,
    };
}

fn usageWire(usage: task_state.UsageView) UsageWire {
    return .{
        .input_tokens = usage.input_tokens,
        .output_tokens = usage.output_tokens,
        .cache_read_input_tokens = usage.cache_read_input_tokens,
        .cache_creation_input_tokens = usage.cache_creation_input_tokens,
    };
}

fn countPresent(comptime T: type, entries: []const ?T) usize {
    var count: usize = 0;
    for (entries) |entry| {
        if (entry != null) count += 1;
    }
    return count;
}

pub const ProjectionError = std.mem.Allocator.Error || error{ProjectionCapacity};
pub const RestoreError = Error || ProjectionError;

/// Callback-scoped access to the composition-owned bounded projection arena.
/// Persistence owns Task reconstruction semantics, while the caller retains
/// the global byte budget and all allocation accounting.
pub const RestoreProjection = struct {
    context: *anyopaque,
    allocator: std.mem.Allocator,
    limits: Limits,
    copy_fn: *const fn (
        context: *anyopaque,
        value: []const u8,
        max: usize,
    ) ProjectionError![]u8,
    alloc_fn: *const fn (
        context: *anyopaque,
        capacity: usize,
    ) ProjectionError![]u8,
    append_text_fn: *const fn (
        context: *anyopaque,
        target: *task_state.TrackedText,
        suffix: []const u8,
        max: usize,
    ) ProjectionError!void,
    free_fn: *const fn (context: *anyopaque, value: []u8) void,
    free_text_fn: *const fn (
        context: *anyopaque,
        target: *task_state.TrackedText,
    ) void,

    fn copy(self: RestoreProjection, value: []const u8, max: usize) ProjectionError![]u8 {
        return self.copy_fn(self.context, value, max);
    }

    fn alloc(self: RestoreProjection, capacity: usize) ProjectionError![]u8 {
        return self.alloc_fn(self.context, capacity);
    }

    fn appendText(
        self: RestoreProjection,
        target: *task_state.TrackedText,
        suffix: []const u8,
        max: usize,
    ) ProjectionError!void {
        return self.append_text_fn(self.context, target, suffix, max);
    }

    fn free(self: RestoreProjection, value: []u8) void {
        self.free_fn(self.context, value);
    }

    fn freeText(self: RestoreProjection, target: *task_state.TrackedText) void {
        self.free_text_fn(self.context, target);
    }
};

pub fn restoreTask(
    projection: RestoreProjection,
    wire: TaskWire,
) RestoreError!task_state.Task {
    const checkpoint_anchor = parseEnum(task_state.CheckpointAnchor, wire.checkpoint_anchor) orelse
        return error.TaskStoreCorrupt;
    const checkpoint_attempt = parseEnum(task_state.CheckpointAttempt, wire.checkpoint_attempt) orelse
        return error.TaskStoreCorrupt;
    var checkpoint = if (wire.checkpoint) |value|
        try restoreCheckpointRecord(projection.allocator, wire.id, value, projection.limits)
    else
        null;
    errdefer if (checkpoint) |*value| value.deinit(projection.allocator);
    if ((checkpoint == null and checkpoint_anchor == .available) or
        (checkpoint != null and checkpoint_anchor == .none))
        return error.TaskStoreCorrupt;
    if (checkpoint) |value| {
        value.validateBinding(wire.id, wire.binding.epoch) catch
            return error.TaskStoreCorrupt;
        const terminal_found = switch (value.anchor.terminal) {
            .run => |terminal_id| blk: {
                for (wire.runs) |run| {
                    if (run.id != terminal_id) continue;
                    break :blk persistedTerminalRunPhase(run.phase) and
                        std.mem.eql(u8, run.execution_model, value.session.model);
                }
                break :blk false;
            },
            .compact => |terminal_id| blk: {
                for (wire.compacts) |compact| if (compact.id == terminal_id)
                    break :blk persistedTerminalCompactPhase(compact.phase);
                break :blk false;
            },
        };
        if (!terminal_found) return error.TaskStoreCorrupt;
    }

    const execution_protocol = parseEnum(task_state.Protocol, wire.binding.protocol) orelse
        return error.TaskStoreCorrupt;
    const permission_profile = parseEnum(
        task_state.PermissionProfile,
        wire.permission_profile,
    ) orelse return error.TaskStoreCorrupt;
    const permission_interaction = parseEnum(
        task_state.PermissionInteraction,
        wire.permission_interaction,
    ) orelse return error.TaskStoreCorrupt;
    const execution_model = try projection.copy(
        wire.binding.model,
        projection.limits.max_execution_model_bytes,
    );
    errdefer projection.free(execution_model);
    const workspace_root = try projection.copy(
        wire.workspace_root,
        projection.limits.max_workspace_bytes,
    );
    errdefer projection.free(workspace_root);
    const title = try projection.copy(wire.title, projection.limits.max_task_title_bytes);
    errdefer projection.free(title);

    const runs = try projection.allocator.alloc(
        ?task_state.RunRecord,
        projection.limits.max_runs_per_task,
    );
    errdefer projection.allocator.free(runs);
    @memset(runs, null);
    var restored_runs: usize = 0;
    errdefer for (runs[0..restored_runs]) |*entry| {
        const run = &(entry.* orelse continue);
        deinitRestoredRun(projection, run);
    };
    for (wire.runs, 0..) |run, index| {
        runs[index] = try restoreRun(projection, run);
        restored_runs += 1;
    }

    const compacts = try projection.allocator.alloc(
        ?task_state.CompactRecord,
        projection.limits.max_compacts_per_task,
    );
    errdefer projection.allocator.free(compacts);
    @memset(compacts, null);
    var restored_compacts: usize = 0;
    errdefer for (compacts[0..restored_compacts]) |*entry| {
        const compact = &(entry.* orelse continue);
        deinitRestoredCompact(projection, compact);
    };
    for (wire.compacts, 0..) |compact, index| {
        compacts[index] = try restoreCompact(projection, compact);
        restored_compacts += 1;
    }

    const ui_history = try projection.allocator.alloc(
        ?task_state.UiRecord,
        projection.limits.max_ui_history_per_task,
    );
    errdefer projection.allocator.free(ui_history);
    @memset(ui_history, null);
    for (wire.ui_history, 0..) |record, index|
        ui_history[index] = restoreUiRecord(record);
    return .{
        .durable = .{
            .id = wire.id,
            .recent_order = wire.recent_order,
            .execution_generation = wire.binding.execution_generation,
            .execution_protocol = execution_protocol,
            .execution_model = execution_model,
            .permission_profile = permission_profile,
            .permission_interaction = permission_interaction,
            .binding_epoch = wire.binding.epoch,
            .workspace_id = wire.workspace_id,
            .workspace_epoch = wire.workspace_epoch,
            .workspace_root = workspace_root,
            .title = title,
            .title_redacted = wire.title_redacted,
            .archived = wire.archived,
            .runs = runs,
            .compacts = compacts,
            .next_run_generation = wire.next_run_generation,
            .ui_history = ui_history,
            .ui_history_count = wire.ui_history.len,
            .ui_history_next = wire.ui_history.len % ui_history.len,
            .checkpoint = checkpoint,
            .checkpoint_anchor = checkpoint_anchor,
            .checkpoint_attempt = checkpoint_attempt,
        },
        .runtime = .{},
    };
}

fn restoreCheckpointRecord(
    allocator: std.mem.Allocator,
    task_id: u64,
    wire: CheckpointWire,
    limits: Limits,
) RestoreError!checkpoint_record.Record {
    var digest: [checkpoint_store.digest_bytes]u8 = undefined;
    if (wire.blob.digest.len != digest.len * 2) return error.TaskStoreCorrupt;
    _ = std.fmt.hexToBytes(&digest, wire.blob.digest) catch return error.TaskStoreCorrupt;
    const canonical_digest = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &canonical_digest, wire.blob.digest))
        return error.TaskStoreCorrupt;
    if (wire.blob.byte_size == 0 or
        wire.session.logical_session_id.len == 0 or
        wire.session.logical_session_id.len > 4096 or
        wire.session.model.len == 0 or
        wire.session.model.len > limits.max_execution_model_bytes or
        wire.anchor.binding_epoch == 0 or
        wire.anchor.terminal.id == 0)
        return error.TaskStoreCorrupt;
    const logical_session_id = try allocator.dupe(u8, wire.session.logical_session_id);
    errdefer allocator.free(logical_session_id);
    const model = try allocator.dupe(u8, wire.session.model);
    errdefer allocator.free(model);
    const terminal: checkpoint_record.Terminal = if (std.mem.eql(
        u8,
        wire.anchor.terminal.kind,
        "run",
    ))
        .{ .run = wire.anchor.terminal.id }
    else if (std.mem.eql(u8, wire.anchor.terminal.kind, "compact"))
        .{ .compact = wire.anchor.terminal.id }
    else
        return error.TaskStoreCorrupt;
    return .{
        .blob = .{
            .task_id = task_id,
            .generation = wire.blob.generation,
            .byte_size = wire.blob.byte_size,
            .digest = digest,
        },
        .session = .{
            .logical_session_id = logical_session_id,
            .last_run_id = wire.session.last_run_id,
            .last_compact_id = wire.session.last_compact_id,
            .model = model,
        },
        .anchor = .{
            .terminal = terminal,
            .binding_epoch = wire.anchor.binding_epoch,
        },
    };
}

fn restoreRun(projection: RestoreProjection, wire: RunWire) RestoreError!task_state.RunRecord {
    var input = try restoreRunInput(projection, wire.input);
    errdefer deinitRestoredRunInput(projection, &input);
    var assistant: task_state.TrackedText = .{};
    errdefer if (assistant.list.capacity != 0) projection.freeText(&assistant);
    try projection.appendText(
        &assistant,
        wire.assistant,
        projection.limits.max_assistant_message_bytes,
    );
    assistant.committed_len = assistant.list.items.len;
    const assistant_output_kind = if (wire.assistant_output_kind) |kind|
        parseEnum(task_state.AssistantOutputKind, kind) orelse return error.TaskStoreCorrupt
    else
        null;
    const assistant_output_start = if (wire.assistant_output_start) |start|
        std.math.cast(usize, start) orelse return error.TaskStoreCorrupt
    else
        null;
    if ((assistant_output_kind == null) != (assistant_output_start == null))
        return error.TaskStoreCorrupt;
    if (assistant_output_start) |start| {
        if (start > assistant.committed_len or
            !std.unicode.utf8ValidateSlice(assistant.list.items[0..start]))
            return error.TaskStoreCorrupt;
    }
    if (wire.commentary_ends.len > projection.limits.max_commentary_segments_per_run or
        !validCommentaryEnds(
            wire.assistant,
            wire.commentary_ends,
            assistant_output_start orelse assistant.committed_len,
        ))
        return error.TaskStoreCorrupt;
    const commentary_ends = try projection.allocator.alloc(
        u64,
        projection.limits.max_commentary_segments_per_run,
    );
    errdefer projection.allocator.free(commentary_ends);
    @memcpy(commentary_ends[0..wire.commentary_ends.len], wire.commentary_ends);
    const interrupted = !persistedTerminalRunPhase(wire.phase);
    const diagnostic = try projection.alloc(projection.limits.max_terminal_diagnostic_bytes);
    errdefer projection.free(diagnostic);
    @memcpy(diagnostic[0..wire.diagnostic.len], wire.diagnostic);
    const tools = try projection.allocator.alloc(
        ?task_state.ToolView,
        projection.limits.max_tools_per_run,
    );
    errdefer projection.allocator.free(tools);
    @memset(tools, null);
    var restored_tools: usize = 0;
    errdefer for (tools[0..restored_tools]) |*entry| {
        const tool = &(entry.* orelse continue);
        deinitRestoredTool(projection, tool);
    };
    for (wire.tools) |tool| {
        if (std.mem.eql(u8, tool.state, "running")) continue;
        tools[restored_tools] = try restoreTool(projection, tool);
        restored_tools += 1;
    }
    const file_changes = try projection.allocator.alloc(
        ?task_state.FileChangeView,
        projection.limits.max_file_changes_per_run,
    );
    errdefer projection.allocator.free(file_changes);
    @memset(file_changes, null);
    var restored_file_changes: usize = 0;
    errdefer for (file_changes[0..restored_file_changes]) |*entry| {
        const change = &(entry.* orelse continue);
        deinitRestoredFileChange(projection, change);
    };
    if ((wire.file_change_observation == null) != (wire.file_changes == null))
        return error.TaskStoreCorrupt;
    if (wire.file_changes) |changes| {
        if (changes.len > projection.limits.max_file_changes_per_run)
            return error.TaskStoreCorrupt;
        for (changes) |change| {
            file_changes[restored_file_changes] = try restoreFileChange(
                projection,
                wire.generation,
                change,
            );
            restored_file_changes += 1;
        }
    }
    const phase: task_state.RunPhase = if (interrupted)
        .interrupted
    else
        parseEnum(task_state.RunPhase, wire.phase) orelse return error.TaskStoreCorrupt;
    const outcome: task_state.RunOutcome = if (interrupted)
        .interrupted
    else
        parseEnum(
            task_state.RunOutcome,
            wire.outcome orelse return error.TaskStoreCorrupt,
        ) orelse return error.TaskStoreCorrupt;
    const cause: ?task_state.RunCause = if (interrupted or wire.cause == null)
        null
    else
        parseEnum(task_state.RunCause, wire.cause.?) orelse return error.TaskStoreCorrupt;
    const execution_model = try projection.copy(
        wire.execution_model,
        projection.limits.max_execution_model_bytes,
    );
    errdefer projection.free(execution_model);
    return .{
        .id = wire.id,
        .generation = wire.generation,
        .execution_generation = wire.execution_generation,
        .execution_protocol = parseEnum(task_state.Protocol, wire.execution_protocol) orelse
            return error.TaskStoreCorrupt,
        .execution_model = execution_model,
        .execution_model_owned = true,
        .permission_profile = parseEnum(
            task_state.PermissionProfile,
            wire.permission_profile,
        ) orelse return error.TaskStoreCorrupt,
        .permission_interaction = parseEnum(
            task_state.PermissionInteraction,
            wire.permission_interaction,
        ) orelse return error.TaskStoreCorrupt,
        .input = input,
        .assistant = assistant,
        .assistant_redacted = wire.assistant_redacted,
        .commentary_ends = commentary_ends,
        .commentary_count = wire.commentary_ends.len,
        .assistant_output_kind = assistant_output_kind,
        .assistant_output_start = assistant_output_start,
        .active_phase = .queued,
        .tools = tools,
        .file_change_observation = if (wire.file_change_observation) |value|
            if (interrupted)
                .incomplete
            else
                parseEnum(task_state.FileChangeObservation, value) orelse
                    return error.TaskStoreCorrupt
        else
            null,
        .file_changes = file_changes,
        .file_changes_known_loss = interrupted or
            (wire.file_change_observation != null and
                std.mem.eql(u8, wire.file_change_observation.?, "incomplete")),
        .usage = usageFromWire(wire.usage),
        .terminal_publication = .init(.published),
        .terminal_payload = .{
            .phase = phase,
            .outcome = outcome,
            .cause = cause,
            .session_disposition_at_completion = .reusable,
            .diagnostic_len = wire.diagnostic.len,
            .diagnostic_truncated = wire.diagnostic_truncated,
            .diagnostic_redacted = wire.diagnostic_redacted,
        },
        .terminal_observed = true,
        .event_stream_finalized = true,
        .event_projection_failure = if (wire.event_projection_failure) |failure|
            parseEnum(task_state.EventProjectionFailure, failure) orelse
                return error.TaskStoreCorrupt
        else
            null,
        .terminal_diagnostic = diagnostic,
        .next_activity_order = wire.next_activity_order,
    };
}

fn restoreRunInput(
    projection: RestoreProjection,
    wire: RunInputWire,
) RestoreError!task_state.RunInputRecord {
    if (std.mem.eql(u8, wire.kind, "text")) return .{ .text = .{
        .value = try projection.copy(
            wire.text orelse return error.TaskStoreCorrupt,
            projection.limits.max_user_message_bytes,
        ),
        .redacted = wire.redacted,
    } };
    const values_wire = wire.argument_values orelse return error.TaskStoreCorrupt;
    const values = try projection.allocator.alloc([]u8, values_wire.len);
    errdefer projection.allocator.free(values);
    var initialized: usize = 0;
    errdefer for (values[0..initialized]) |value| projection.free(value);
    for (values_wire, values) |value, *target| {
        target.* = try projection.copy(value, projection.limits.max_user_message_bytes);
        initialized += 1;
    }
    const skill_id = try projection.copy(
        wire.skill_id orelse return error.TaskStoreCorrupt,
        projection.limits.max_tool_field_bytes,
    );
    errdefer projection.free(skill_id);
    const catalog_revision = try projection.copy(
        wire.catalog_revision orelse return error.TaskStoreCorrupt,
        projection.limits.max_tool_field_bytes,
    );
    errdefer projection.free(catalog_revision);
    const invocation_name = try projection.copy(
        wire.invocation_name orelse return error.TaskStoreCorrupt,
        projection.limits.max_tool_field_bytes,
    );
    errdefer projection.free(invocation_name);
    const display_name = try projection.copy(
        wire.display_name orelse return error.TaskStoreCorrupt,
        projection.limits.max_tool_field_bytes,
    );
    errdefer projection.free(display_name);
    return .{ .skill = .{
        .skill_id = skill_id,
        .catalog_revision = catalog_revision,
        .invocation_name = invocation_name,
        .display_name = display_name,
        .argument_values = values,
        .redacted = wire.redacted,
    } };
}

fn restoreTool(projection: RestoreProjection, wire: ToolWire) RestoreError!task_state.ToolView {
    const id = try projection.copy(wire.id, projection.limits.max_tool_field_bytes);
    errdefer projection.free(id);
    const name = try projection.copy(wire.name, projection.limits.max_tool_field_bytes);
    errdefer projection.free(name);
    const input = try projection.copy(wire.input, projection.limits.max_tool_field_bytes);
    errdefer projection.free(input);
    const progress = try projection.copy(wire.progress, projection.limits.max_tool_field_bytes);
    errdefer projection.free(progress);
    const content = try projection.copy(wire.content, projection.limits.max_tool_field_bytes);
    errdefer projection.free(content);
    const state = parseEnum(task_state.ToolState, wire.state) orelse
        return error.TaskStoreCorrupt;
    const file_refs = try projection.allocator.alloc(
        ?task_state.FileReferenceView,
        projection.limits.max_file_refs_per_tool,
    );
    errdefer {
        for (file_refs) |*entry|
            if (entry.*) |*reference| deinitRestoredFileReference(projection, reference);
        projection.allocator.free(file_refs);
    }
    @memset(file_refs, null);
    if (wire.file_refs) |references| {
        if (references.len > projection.limits.max_file_refs_per_tool)
            return error.TaskStoreCorrupt;
        for (references, 0..) |reference, index|
            file_refs[index] = try restoreFileReference(projection, reference);
    }
    return .{
        .route_digest = [_]u8{0} ** task_state.tool_route_digest_bytes,
        .id = id,
        .order = wire.order,
        .name = name,
        .input = input,
        .progress = progress,
        .content = content,
        .file_refs = file_refs,
        .state = state,
        .is_error = wire.is_error,
        .elapsed_ms = wire.elapsed_ms,
        .input_truncated = wire.input_truncated,
        .progress_truncated = wire.progress_truncated,
        .content_truncated = wire.content_truncated,
        .redacted = wire.redacted,
    };
}

fn restoreFileReference(
    projection: RestoreProjection,
    wire: FileReferenceWire,
) RestoreError!task_state.FileReferenceView {
    const locator_kind = parseEnum(task_state.FileReferenceLocatorKind, wire.locator_kind) orelse
        return error.TaskStoreCorrupt;
    var reference = task_state.FileReferenceView{
        .id = undefined,
        .title = undefined,
        .display_path = undefined,
        .kind = undefined,
        .locator_kind = locator_kind,
        .locator = undefined,
        .range = if (wire.range) |range| .{
            .start = .{ .line = range.start.line, .column = range.start.column },
            .end = .{ .line = range.end.line, .column = range.end.column },
        } else null,
    };
    reference.id = try projection.copy(wire.id, projection.limits.max_file_ref_field_bytes);
    errdefer projection.free(reference.id);
    reference.title = try projection.copy(wire.title, projection.limits.max_file_ref_field_bytes);
    errdefer projection.free(reference.title);
    reference.display_path = try projection.copy(
        wire.display_path,
        projection.limits.max_file_ref_field_bytes,
    );
    errdefer projection.free(reference.display_path);
    reference.kind = try projection.copy(wire.kind, projection.limits.max_file_ref_field_bytes);
    errdefer projection.free(reference.kind);
    reference.locator = try projection.copy(
        wire.locator,
        projection.limits.max_file_ref_field_bytes,
    );
    return reference;
}

fn restoreFileChange(
    projection: RestoreProjection,
    run_generation: u64,
    wire: FileChangeWire,
) RestoreError!task_state.FileChangeView {
    const id = try projection.copy(wire.id, projection.limits.max_file_change_field_bytes);
    errdefer projection.free(id);
    const display_path = try projection.copy(
        wire.display_path,
        projection.limits.max_file_change_field_bytes,
    );
    errdefer projection.free(display_path);
    const from_display_path = if (wire.from_display_path) |path|
        try projection.copy(path, projection.limits.max_file_change_field_bytes)
    else
        null;
    errdefer if (from_display_path) |path| projection.free(path);
    const artifact: ?task_state.FileChangeArtifact = if (wire.artifact) |value| artifact: {
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        if (value.digest.len != digest.len * 2 or value.byte_size == 0 or
            value.run_generation != run_generation or value.change_order != wire.order)
            return error.TaskStoreCorrupt;
        _ = std.fmt.hexToBytes(&digest, value.digest) catch return error.TaskStoreCorrupt;
        const canonical = std.fmt.bytesToHex(digest, .lower);
        if (!std.mem.eql(u8, &canonical, value.digest)) return error.TaskStoreCorrupt;
        break :artifact .{
            .run_generation = value.run_generation,
            .change_order = value.change_order,
            .digest = digest,
            .byte_size = value.byte_size,
        };
    } else null;
    return .{
        .route_digest = [_]u8{0} ** task_state.file_change_route_digest_bytes,
        .id = id,
        .order = wire.order,
        .kind = parseEnum(task_state.FileChangeKind, wire.kind) orelse
            return error.TaskStoreCorrupt,
        .status = parseEnum(task_state.FileChangeStatus, wire.status) orelse
            return error.TaskStoreCorrupt,
        .display_path = display_path,
        .from_display_path = from_display_path,
        .before_bytes = wire.before_bytes,
        .after_bytes = wire.after_bytes,
        .artifact = artifact,
        .diff_complete = wire.diff_complete,
        .redacted = wire.redacted,
    };
}

fn restoreCompact(
    projection: RestoreProjection,
    wire: CompactWire,
) RestoreError!task_state.CompactRecord {
    const interrupted = !persistedTerminalCompactPhase(wire.phase);
    const diagnostic = try projection.alloc(projection.limits.max_terminal_diagnostic_bytes);
    errdefer projection.free(diagnostic);
    @memcpy(diagnostic[0..wire.diagnostic.len], wire.diagnostic);
    return .{
        .id = wire.id,
        .after_run_id = wire.after_run_id,
        .terminal_publication = .init(.published),
        .terminal_payload = .{
            .phase = if (interrupted)
                .interrupted
            else
                parseEnum(task_state.CompactPhase, wire.phase) orelse
                    return error.TaskStoreCorrupt,
            .cause = if (interrupted or wire.cause == null)
                null
            else
                parseEnum(task_state.CompactCause, wire.cause.?) orelse
                    return error.TaskStoreCorrupt,
            .before_context_tokens = wire.before_context_tokens,
            .after_context_tokens = wire.after_context_tokens,
            .usage = usageFromWire(wire.usage),
            .session_disposition_at_completion = .reusable,
            .diagnostic_len = wire.diagnostic.len,
            .diagnostic_truncated = wire.diagnostic_truncated,
            .diagnostic_redacted = wire.diagnostic_redacted,
        },
        .terminal_observed = true,
        .terminal_diagnostic = diagnostic,
    };
}

fn restoreUiRecord(wire: UiRecordWire) task_state.UiRecord {
    var result: task_state.UiRecord = .{
        .request_id = wire.request_id,
        .run_id = wire.run_id,
        .order = wire.order,
        .kind = parseEnum(task_state.UiRecordKind, wire.kind) orelse unreachable,
        .state = parseEnum(task_state.UiRecordState, wire.state) orelse unreachable,
        .item_count = wire.item_count,
        .detail_truncated = wire.detail_truncated,
        .redacted = wire.redacted,
    };
    @memcpy(result.agent_request_id[0..wire.agent_request_id.len], wire.agent_request_id);
    result.agent_request_id_len = wire.agent_request_id.len;
    if (wire.permission) |permission| {
        var summary = task_state.PermissionSummary{
            .decision = parseEnum(agent.PermissionDecision, permission.decision) orelse unreachable,
            .source = parseEnum(agent.PermissionDecisionSource, permission.source) orelse unreachable,
            .policy_generation = permission.policy_generation,
            .used_session_rule = permission.used_session_rule,
            .callback_outcome = if (permission.callback_outcome) |outcome|
                parseEnum(agent.PermissionCallbackOutcome, outcome) orelse unreachable
            else
                null,
            .tool_namespace = parseEnum(agent.PermissionToolNamespace, permission.tool_namespace) orelse unreachable,
        };
        @memcpy(summary.request_id[0..permission.request_id.len], permission.request_id);
        summary.request_id_len = permission.request_id.len;
        @memcpy(summary.matched_rule_id[0..permission.matched_rule_id.len], permission.matched_rule_id);
        summary.matched_rule_id_len = permission.matched_rule_id.len;
        @memcpy(summary.tool_name[0..permission.tool_name.len], permission.tool_name);
        summary.tool_name_len = permission.tool_name.len;
        @memcpy(summary.tool_binding[0..permission.tool_binding.len], permission.tool_binding);
        summary.tool_binding_len = permission.tool_binding.len;
        result.permission = summary;
    }
    @memcpy(result.detail[0..wire.detail.len], wire.detail);
    result.detail_len = wire.detail.len;
    return result;
}

fn usageFromWire(usage: UsageWire) task_state.UsageView {
    return .{
        .input_tokens = usage.input_tokens,
        .output_tokens = usage.output_tokens,
        .cache_read_input_tokens = usage.cache_read_input_tokens,
        .cache_creation_input_tokens = usage.cache_creation_input_tokens,
    };
}

pub fn parseEnum(comptime T: type, value: []const u8) ?T {
    return std.meta.stringToEnum(T, value);
}

fn persistedTerminalRunPhase(value: []const u8) bool {
    const phase = parseEnum(task_state.RunPhase, value) orelse return false;
    return task_state.isTerminalPhase(phase);
}

fn persistedTerminalCompactPhase(value: []const u8) bool {
    const phase = parseEnum(task_state.CompactPhase, value) orelse return false;
    return task_state.isTerminalCompactPhase(phase);
}

fn deinitRestoredFileReference(
    projection: RestoreProjection,
    reference: *task_state.FileReferenceView,
) void {
    projection.free(reference.id);
    projection.free(reference.title);
    projection.free(reference.display_path);
    projection.free(reference.kind);
    projection.free(reference.locator);
    reference.* = undefined;
}

fn deinitRestoredFileChange(
    projection: RestoreProjection,
    change: *task_state.FileChangeView,
) void {
    projection.free(change.id);
    projection.free(change.display_path);
    if (change.from_display_path) |path| projection.free(path);
    change.* = undefined;
}

fn deinitRestoredTool(projection: RestoreProjection, tool: *task_state.ToolView) void {
    projection.free(tool.id);
    projection.free(tool.name);
    projection.free(tool.input);
    projection.free(tool.progress);
    projection.free(tool.content);
    if (tool.file_refs) |references| {
        for (references) |*entry|
            if (entry.*) |*reference| deinitRestoredFileReference(projection, reference);
        projection.allocator.free(references);
    }
    tool.* = undefined;
}

fn deinitRestoredRunInput(
    projection: RestoreProjection,
    input: *task_state.RunInputRecord,
) void {
    switch (input.*) {
        .text => |text| projection.free(text.value),
        .skill => |skill| {
            projection.free(skill.skill_id);
            projection.free(skill.catalog_revision);
            projection.free(skill.invocation_name);
            projection.free(skill.display_name);
            for (skill.argument_values) |value| projection.free(value);
            projection.allocator.free(skill.argument_values);
        },
    }
    input.* = undefined;
}

fn deinitRestoredRun(projection: RestoreProjection, run: *task_state.RunRecord) void {
    std.debug.assert(run.automatic_title.state.load(.acquire) != .running);
    for (run.tools) |*entry| {
        const tool = &(entry.* orelse continue);
        deinitRestoredTool(projection, tool);
    }
    projection.allocator.free(run.tools);
    for (run.file_changes) |*entry| {
        const change = &(entry.* orelse continue);
        deinitRestoredFileChange(projection, change);
    }
    projection.allocator.free(run.file_changes);
    projection.allocator.free(run.commentary_ends);
    deinitRestoredRunInput(projection, &run.input);
    if (run.assistant.list.capacity != 0) projection.freeText(&run.assistant);
    if (run.execution_model_owned)
        projection.free(@constCast(run.execution_model));
    projection.free(run.terminal_diagnostic);
    run.* = undefined;
}

fn deinitRestoredCompact(
    projection: RestoreProjection,
    compact: *task_state.CompactRecord,
) void {
    std.debug.assert(!compact.worker_reference_held.load(.acquire));
    projection.free(compact.terminal_diagnostic);
    compact.* = undefined;
}

const MetaWire = struct {
    default_permission_profile: []const u8,
    next_workspace_id: u64,
    next_workspace_recent_order: u64,
    next_task_id: u64,
    next_task_recent_order: u64,
};

pub fn encode(output: []u8, state: StateWire) Error![]const u8 {
    if (output.len == 0) return error.TaskStoreEncodeFailed;
    var offset: usize = 0;
    appendRecord(output, &offset, record_meta, 0, 0, MetaWire{
        .default_permission_profile = state.default_permission_profile,
        .next_workspace_id = state.next_workspace_id,
        .next_workspace_recent_order = state.next_workspace_recent_order,
        .next_task_id = state.next_task_id,
        .next_task_recent_order = state.next_task_recent_order,
    }) catch |err| return err;
    for (state.workspaces) |workspace|
        appendRecord(output, &offset, record_workspace, workspace.id, workspace.recent_order, workspace) catch |err|
            return err;
    for (state.tasks) |task|
        appendRecord(output, &offset, record_task, task.id, task.recent_order, task) catch |err|
            return err;
    if (state.failures.len > max_failure_records) return error.TaskStoreTooLarge;
    for (state.failures) |failure| {
        if (failure.task_id == 0 or failure.recent_order == 0 or
            !validText(failure.reason, max_failure_reason_bytes, false))
            return error.TaskStoreEncodeFailed;
        appendRecord(output, &offset, record_task_failure, failure.task_id, failure.recent_order, failure) catch |err|
            return err;
    }
    if (offset > max_store_bytes) return error.TaskStoreTooLarge;
    return output[0..offset];
}

pub fn decode(
    allocator: std.mem.Allocator,
    input: []const u8,
    limits: Limits,
) RecoveryError!RecoveredState {
    var recovered = decodeRecovering(allocator, input, limits) catch |err| return err;
    if (recovered.degraded or recovered.dropped_workspaces != 0 or recovered.dropped_tasks != 0) {
        recovered.deinit();
        return error.TaskStoreCorrupt;
    }
    validate(&recovered.value, limits) catch {
        recovered.deinit();
        return error.TaskStoreCorrupt;
    };
    return recovered;
}

pub fn decodeRecovering(
    allocator: std.mem.Allocator,
    input: []const u8,
    limits: Limits,
) RecoveryError!RecoveredState {
    if (input.len == 0) return error.TaskStoreEmpty;
    if (input.len > max_store_bytes) return error.TaskStoreTooLarge;

    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }
    const arena_allocator = arena.allocator();
    var workspace_values: std.ArrayList(WorkspaceWire) = .empty;
    var task_values: std.ArrayList(TaskWire) = .empty;
    var failure_values: std.ArrayList(TaskFailureWire) = .empty;
    var next_workspace_id: u64 = 1;
    var next_workspace_recent_order: u64 = 1;
    var next_task_id: u64 = 1;
    var next_task_recent_order: u64 = 1;
    var default_permission_profile: []const u8 = "approval_required";
    var max_workspace_id: u64 = 0;
    var max_workspace_recent_order: u64 = 0;
    var max_task_id: u64 = 0;
    var max_task_recent_order: u64 = 0;
    var dropped_workspaces: usize = 0;
    var dropped_tasks: usize = 0;
    var dropped_failures: usize = 0;
    var degraded = false;
    var metadata_seen = false;
    var metadata_incompatible = false;
    var saw_frame = false;
    var offset: usize = 0;
    while (offset < input.len) {
        const has_magic = input.len - offset >= frame_magic.len and
            std.mem.eql(u8, input[offset .. offset + frame_magic.len], frame_magic);
        if (!has_magic) {
            degraded = true;
            offset = findNextFrame(input, offset + 1) orelse break;
            continue;
        }
        // A recognizable current-format frame is enough to establish that
        // this is a salvageable store, even when its header or payload is
        // damaged. Unknown/retired formats still fail closed below.
        saw_frame = true;
        if (input.len - offset < frame_header_bytes) {
            degraded = true;
            break;
        }
        const header = input[offset .. offset + frame_header_bytes];
        const kind = header[5];
        const id = std.mem.readInt(u64, header[8..16], .little);
        const order = std.mem.readInt(u64, header[16..24], .little);
        const payload_len = std.mem.readInt(u32, header[24..28], .little);
        const header_checksum = std.mem.readInt(u32, header[28..32], .little);
        const payload_checksum = std.mem.readInt(u32, header[32..36], .little);
        if (std.hash.Crc32.hash(header[0..28]) != header_checksum) {
            degraded = true;
            offset = findNextFrame(input, offset + 1) orelse break;
            continue;
        }
        switch (kind) {
            record_workspace => {
                max_workspace_id = @max(max_workspace_id, id);
                max_workspace_recent_order = @max(max_workspace_recent_order, order);
            },
            record_task => {
                max_task_id = @max(max_task_id, id);
                max_task_recent_order = @max(max_task_recent_order, order);
            },
            else => {},
        }
        const payload_start = offset + frame_header_bytes;
        const payload_end = std.math.add(usize, payload_start, payload_len) catch {
            degraded = true;
            offset = findNextFrame(input, offset + 1) orelse break;
            continue;
        };
        if (header[4] != 0 or payload_len > max_store_bytes or payload_end > input.len) {
            degraded = true;
            if (payload_end <= input.len) offset = payload_end else offset = findNextFrame(input, offset + 1) orelse break;
            continue;
        }
        const payload = input[payload_start..payload_end];
        if (std.hash.Crc32.hash(payload) != payload_checksum) {
            degraded = true;
            switch (kind) {
                record_workspace => dropped_workspaces += 1,
                record_task => {
                    dropped_tasks += 1;
                    try appendTaskFailure(
                        arena_allocator,
                        &failure_values,
                        &dropped_failures,
                        id,
                        order,
                        "payload_checksum",
                    );
                },
                else => {},
            }
            offset = payload_end;
            continue;
        }
        switch (kind) {
            record_meta => {
                const meta = std.json.parseFromSliceLeaky(
                    MetaWire,
                    arena_allocator,
                    payload,
                    .{ .ignore_unknown_fields = false },
                ) catch {
                    metadata_incompatible = true;
                    degraded = true;
                    offset = payload_end;
                    continue;
                };
                if (metadata_seen or
                    meta.next_workspace_id == 0 or meta.next_workspace_recent_order == 0 or
                    meta.next_task_id == 0 or meta.next_task_recent_order == 0)
                {
                    degraded = true;
                    offset = payload_end;
                    continue;
                }
                metadata_seen = true;
                default_permission_profile = meta.default_permission_profile;
                next_workspace_id = meta.next_workspace_id;
                next_workspace_recent_order = meta.next_workspace_recent_order;
                next_task_id = meta.next_task_id;
                next_task_recent_order = meta.next_task_recent_order;
            },
            record_workspace => {
                const workspace = std.json.parseFromSliceLeaky(
                    WorkspaceWire,
                    arena_allocator,
                    payload,
                    .{ .ignore_unknown_fields = false },
                ) catch {
                    dropped_workspaces += 1;
                    degraded = true;
                    offset = payload_end;
                    continue;
                };
                try workspace_values.append(arena_allocator, workspace);
            },
            record_task => {
                const task = std.json.parseFromSliceLeaky(
                    TaskWire,
                    arena_allocator,
                    payload,
                    .{ .ignore_unknown_fields = false },
                ) catch {
                    dropped_tasks += 1;
                    degraded = true;
                    try appendTaskFailure(
                        arena_allocator,
                        &failure_values,
                        &dropped_failures,
                        id,
                        order,
                        "task_payload_decode",
                    );
                    offset = payload_end;
                    continue;
                };
                if (task.id != id or task.recent_order != order) {
                    dropped_tasks += 1;
                    degraded = true;
                    try appendTaskFailure(
                        arena_allocator,
                        &failure_values,
                        &dropped_failures,
                        id,
                        order,
                        "task_identity_mismatch",
                    );
                    offset = payload_end;
                    continue;
                }
                try task_values.append(arena_allocator, task);
            },
            record_task_failure => {
                if (failure_values.items.len >= max_failure_records) {
                    dropped_failures += 1;
                    degraded = true;
                    offset = payload_end;
                    continue;
                }
                const failure = std.json.parseFromSliceLeaky(
                    TaskFailureWire,
                    arena_allocator,
                    payload,
                    .{ .ignore_unknown_fields = false },
                ) catch {
                    dropped_failures += 1;
                    degraded = true;
                    offset = payload_end;
                    continue;
                };
                if (failure.task_id == 0 or failure.task_id != id or
                    failure.recent_order != order or
                    !validText(failure.reason, max_failure_reason_bytes, false))
                {
                    dropped_failures += 1;
                    degraded = true;
                    offset = payload_end;
                    continue;
                }
                try failure_values.append(arena_allocator, failure);
            },
            else => degraded = true,
        }
        offset = payload_end;
    }

    // Metadata is an optimization for the next-id counters, not the
    // authority for the recovered projection. Derive counters from valid
    // record high-water marks when metadata is missing or damaged. A store
    // with no recognizable current-format frame remains an unknown/retired
    // format and is rejected rather than silently treated as empty.
    if (!saw_frame or metadata_incompatible) return error.TaskStoreCorrupt;
    const workspace_storage = workspace_values.items;
    const task_storage = task_values.items;
    var workspace_len: usize = 0;
    for (workspace_storage) |workspace| {
        if (workspace_len >= limits.max_workspaces) {
            dropped_workspaces += 1;
            degraded = true;
            continue;
        }
        validateRecoveredWorkspace(workspace, limits, workspace_storage[0..workspace_len]) catch {
            dropped_workspaces += 1;
            degraded = true;
            continue;
        };
        workspace_storage[workspace_len] = workspace;
        workspace_len += 1;
    }
    var task_len: usize = 0;
    for (task_storage) |task| {
        if (task_len >= limits.max_tasks) {
            dropped_tasks += 1;
            degraded = true;
            continue;
        }
        validateRecoveredTask(task, limits, workspace_storage[0..workspace_len], task_storage[0..task_len]) catch {
            dropped_tasks += 1;
            degraded = true;
            // A validation failure can itself carry an unusable identity. In
            // that case there is no safe Task to quarantine; retain only the
            // degraded store state instead of turning the recovery into a
            // global failure while manufacturing an id-less failure record.
            if (task.id != 0 and task.recent_order != 0) {
                if (failure_values.items.len < max_failure_records)
                    try failure_values.append(arena_allocator, .{
                        .task_id = task.id,
                        .recent_order = task.recent_order,
                        .reason = "task_validation",
                    })
                else
                    dropped_failures += 1;
            }
            continue;
        };
        task_storage[task_len] = task;
        task_len += 1;
    }

    // Automatic Workspaces are valid only with exactly one surviving Task.
    // Remove the whole automatic scope when its owner Task was the damaged
    // record; this preserves the existing Workspace/Task ownership invariant.
    var filtered_workspace_len: usize = 0;
    for (workspace_storage[0..workspace_len]) |workspace| {
        if (std.mem.eql(u8, workspace.kind, "automatic")) {
            var count: usize = 0;
            for (task_storage[0..task_len]) |task| {
                if (task.workspace_id == workspace.id) count += 1;
            }
            if (count != 1) {
                dropped_workspaces += 1;
                for (task_storage[0..task_len]) |task| {
                    if (task.workspace_id == workspace.id) dropped_tasks += 1;
                }
                continue;
            }
        }
        workspace_storage[filtered_workspace_len] = workspace;
        filtered_workspace_len += 1;
    }
    workspace_len = filtered_workspace_len;

    var filtered_task_len: usize = 0;
    for (task_storage[0..task_len]) |task| {
        if (findRecoveredWorkspace(workspace_storage[0..workspace_len], task.workspace_id) == null) {
            dropped_tasks += 1;
            continue;
        }
        task_storage[filtered_task_len] = task;
        filtered_task_len += 1;
    }
    task_len = filtered_task_len;

    const state = StateWire{
        .default_permission_profile = default_permission_profile,
        .next_workspace_id = try nextFromHighWater(next_workspace_id, max_workspace_id),
        .next_workspace_recent_order = try nextFromHighWater(next_workspace_recent_order, max_workspace_recent_order),
        .next_task_id = try nextFromHighWater(next_task_id, max_task_id),
        .next_task_recent_order = try nextFromHighWater(next_task_recent_order, max_task_recent_order),
        .workspaces = workspace_storage[0..workspace_len],
        .tasks = task_storage[0..task_len],
        .failures = failure_values.items,
    };
    return .{
        .arena = arena,
        .value = state,
        .dropped_workspaces = dropped_workspaces,
        .dropped_tasks = dropped_tasks,
        .degraded = degraded or dropped_failures != 0 or failure_values.items.len != 0,
    };
}

fn appendTaskFailure(
    allocator: std.mem.Allocator,
    failures: *std.ArrayList(TaskFailureWire),
    dropped_failures: *usize,
    task_id: u64,
    recent_order: u64,
    reason: []const u8,
) !void {
    // A failure record is itself a Task-scoped fact. If the damaged frame no
    // longer carries a trustworthy identity, retain only degraded health and
    // never manufacture an invalid record that could poison restore.
    if (task_id == 0 or recent_order == 0) return;
    if (failures.items.len < max_failure_records) {
        try failures.append(allocator, .{
            .task_id = task_id,
            .recent_order = recent_order,
            .reason = reason,
        });
    } else {
        dropped_failures.* += 1;
    }
}

fn appendRecord(
    output: []u8,
    offset: *usize,
    kind: u8,
    id: u64,
    order: u64,
    value: anytype,
) Error!void {
    if (output.len -| offset.* < frame_header_bytes) return error.TaskStoreTooLarge;
    const header_start = offset.*;
    offset.* += frame_header_bytes;
    var writer = std.Io.Writer.fixed(output[offset.*..]);
    std.json.Stringify.value(value, .{}, &writer) catch return error.TaskStoreEncodeFailed;
    const payload = writer.buffered();
    if (payload.len > max_store_bytes or payload.len > std.math.maxInt(u32))
        return error.TaskStoreTooLarge;
    const header = output[header_start .. header_start + frame_header_bytes];
    @memcpy(header[0..4], frame_magic);
    header[4] = 0;
    header[5] = kind;
    std.mem.writeInt(u16, header[6..8], 0, .little);
    std.mem.writeInt(u64, header[8..16], id, .little);
    std.mem.writeInt(u64, header[16..24], order, .little);
    std.mem.writeInt(u32, header[24..28], @intCast(payload.len), .little);
    std.mem.writeInt(u32, header[28..32], std.hash.Crc32.hash(header[0..28]), .little);
    std.mem.writeInt(u32, header[32..36], std.hash.Crc32.hash(payload), .little);
    offset.* += payload.len;
}

fn findNextFrame(input: []const u8, start: usize) ?usize {
    if (start >= input.len) return null;
    const relative = std.mem.indexOf(u8, input[start..], frame_magic) orelse return null;
    return start + relative;
}

fn nextFromHighWater(current: u64, max_seen: u64) Error!u64 {
    if (max_seen == std.math.maxInt(u64)) return error.TaskIdentityExhausted;
    if (current == 0) return if (max_seen == 0) 1 else max_seen + 1;
    return if (max_seen >= current) max_seen + 1 else current;
}

fn validateRecoveredWorkspace(
    workspace: WorkspaceWire,
    limits: Limits,
    previous: []const WorkspaceWire,
) !void {
    if (workspace.id == 0 or workspace.epoch == 0 or
        !oneOf(workspace.kind, &.{ "manual", "automatic" }) or
        (std.mem.eql(u8, workspace.kind, "manual") and workspace.recent_order == 0) or
        !validText(workspace.canonical_root, limits.max_workspace_bytes, false) or
        !std.fs.path.isAbsolute(workspace.canonical_root) or
        !validText(workspace.display_name, limits.max_workspace_bytes, false))
        return error.Invalid;
    for (previous) |value|
        if (value.id == workspace.id or
            std.mem.eql(u8, value.canonical_root, workspace.canonical_root))
            return error.Invalid;
}

fn validateRecoveredTask(
    task: TaskWire,
    limits: Limits,
    workspaces: []const WorkspaceWire,
    previous: []const TaskWire,
) !void {
    if (task.id == 0 or task.recent_order == 0 or task.workspace_id == 0 or
        task.workspace_epoch == 0 or
        !validText(task.workspace_root, limits.max_workspace_bytes, false) or
        !validText(task.title, limits.max_task_title_bytes, true) or
        task.binding.epoch == 0 or task.binding.execution_generation == 0 or
        !oneOf(task.binding.protocol, &.{ "openai_responses", "anthropic_messages", "openai_chat_completions", "gemini_native" }) or
        !validBinding(task.binding, limits.max_tool_field_bytes) or
        task.runs.len > limits.max_runs_per_task or
        task.compacts.len > limits.max_compacts_per_task or
        task.ui_history.len > limits.max_ui_history_per_task)
        return error.Invalid;
    const workspace = findRecoveredWorkspace(workspaces, task.workspace_id) orelse
        return error.Invalid;
    if (task.workspace_epoch > workspace.epoch or
        !std.mem.eql(u8, workspace.canonical_root, task.workspace_root))
        return error.Invalid;
    for (previous) |value| if (value.id == task.id) return error.Invalid;
    try validateTask(task, limits);
}

fn findRecoveredWorkspace(workspaces: []const WorkspaceWire, id: u64) ?WorkspaceWire {
    for (workspaces) |workspace| if (workspace.id == id) return workspace;
    return null;
}

fn nextAfter(current: u64, workspaces: []const WorkspaceWire, ids: bool) u64 {
    var result = current;
    for (workspaces) |workspace| {
        const value = if (ids) workspace.id else workspace.recent_order;
        if (value >= result) result = value +| 1;
    }
    return if (result == 0) 1 else result;
}

fn nextAfterTask(current: u64, tasks: []const TaskWire, ids: bool) u64 {
    var result = current;
    for (tasks) |task| {
        const value = if (ids) task.id else task.recent_order;
        if (value >= result) result = value +| 1;
    }
    return if (result == 0) 1 else result;
}

fn validate(state: *const StateWire, limits: Limits) !void {
    if (!validPermissionProfile(state.default_permission_profile) or
        state.next_workspace_id == 0 or state.next_workspace_recent_order == 0 or state.next_task_id == 0 or
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
            !validPermissionProfile(task.permission_profile) or
            !validPermissionInteraction(task.permission_interaction) or
            task.binding.epoch == 0 or task.binding.execution_generation == 0 or
            !oneOf(task.binding.protocol, &.{ "openai_responses", "anthropic_messages", "openai_chat_completions", "gemini_native" }) or
            !validBinding(task.binding, limits.max_execution_model_bytes) or
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
            !oneOf(run.execution_protocol, &.{ "openai_responses", "anthropic_messages", "openai_chat_completions", "gemini_native" }) or
            !validText(run.execution_model, limits.max_execution_model_bytes, false) or
            !validPermissionProfile(run.permission_profile) or
            !validPermissionInteraction(run.permission_interaction) or
            !std.mem.eql(u8, run.permission_profile, task.permission_profile) or
            !std.mem.eql(u8, run.permission_interaction, task.permission_interaction) or
            !std.mem.eql(u8, run.execution_protocol, task.binding.protocol) or
            !validText(run.assistant, limits.max_assistant_message_bytes, true) or
            !validText(run.diagnostic, limits.max_terminal_diagnostic_bytes, true) or
            run.tools.len > limits.max_tools_per_run or run.next_activity_order == 0)
            return error.Invalid;
        if ((run.assistant_output_kind == null) != (run.assistant_output_start == null))
            return error.Invalid;
        if (run.assistant_output_kind) |kind|
            if (!oneOf(kind, &.{ "final", "partial" })) return error.Invalid;
        if (run.assistant_output_start) |start_wire| {
            const start = std.math.cast(usize, start_wire) orelse return error.Invalid;
            if (start > run.assistant.len or
                !std.unicode.utf8ValidateSlice(run.assistant[0..start]))
                return error.Invalid;
        }
        const commentary_end = if (run.assistant_output_start) |start_wire|
            std.math.cast(usize, start_wire) orelse return error.Invalid
        else
            run.assistant.len;
        if (run.commentary_ends.len > limits.max_commentary_segments_per_run or
            !validCommentaryEnds(run.assistant, run.commentary_ends, commentary_end))
            return error.Invalid;
        if (run.event_projection_failure) |failure|
            if (!oneOf(failure, &.{ "consumer_rejected", "dependency_contract_failure" }))
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
            if (tool.file_refs) |references| {
                if (references.len > limits.max_file_refs_per_tool) return error.Invalid;
                for (references) |reference| {
                    if (!validText(reference.id, limits.max_file_ref_field_bytes, false) or
                        !validText(reference.title, limits.max_file_ref_field_bytes, true) or
                        !validText(reference.display_path, limits.max_file_ref_field_bytes, true) or
                        !validText(reference.kind, limits.max_file_ref_field_bytes, true) or
                        !oneOf(reference.locator_kind, &.{ "workspace_path", "absolute_path", "uri" }) or
                        !validText(reference.locator, limits.max_file_ref_field_bytes, false))
                        return error.Invalid;
                    if (reference.range) |range| {
                        if (range.start.line == 0 or range.start.column == 0 or
                            range.end.line == 0 or range.end.column == 0 or
                            range.end.line < range.start.line or
                            (range.end.line == range.start.line and range.end.column < range.start.column))
                            return error.Invalid;
                    }
                }
            }
            for (run.tools[0..tool_index]) |previous|
                if (std.mem.eql(u8, previous.id, tool.id) or previous.order == tool.order)
                    return error.Invalid;
        }
        if ((run.file_change_observation == null) != (run.file_changes == null))
            return error.Invalid;
        if (run.file_change_observation) |observation| {
            if (!oneOf(observation, &.{ "collecting", "complete", "incomplete" }) or
                run.file_changes.?.len > limits.max_file_changes_per_run)
                return error.Invalid;
            for (run.file_changes.?, 0..) |change, change_index| {
                if (!validFileChangeId(change.id, task.id, run.generation, change.order) or
                    change.order == 0 or change.order >= run.next_activity_order or
                    !oneOf(change.kind, &.{ "created", "modified", "deleted", "moved" }) or
                    !oneOf(change.status, &.{ "applied", "partial" }) or
                    !validText(change.display_path, limits.max_file_change_field_bytes, false) or
                    (change.from_display_path != null) != std.mem.eql(u8, change.kind, "moved"))
                    return error.Invalid;
                if (change.from_display_path) |from|
                    if (!validText(from, limits.max_file_change_field_bytes, false))
                        return error.Invalid;
                if (change.artifact) |artifact| {
                    if (artifact.run_generation != run.generation or
                        artifact.change_order != change.order or
                        artifact.byte_size == 0 or
                        artifact.byte_size > limits.max_file_change_diff_bytes or
                        artifact.digest.len != std.crypto.hash.sha2.Sha256.digest_length * 2 or
                        !isLowerHex(artifact.digest))
                        return error.Invalid;
                    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
                    _ = std.fmt.hexToBytes(&digest, artifact.digest) catch
                        return error.Invalid;
                    const canonical = std.fmt.bytesToHex(digest, .lower);
                    if (!std.mem.eql(u8, &canonical, artifact.digest))
                        return error.Invalid;
                }
                for (run.file_changes.?[0..change_index]) |previous|
                    if (std.mem.eql(u8, previous.id, change.id) or
                        previous.order == change.order)
                        return error.Invalid;
                for (run.tools) |tool|
                    if (tool.order == change.order) return error.Invalid;
            }
        }
        const terminal = terminalRunPhase(run.phase);
        if (terminal) {
            if (!validRunTerminalState(run.phase, run.outcome))
                return error.Invalid;
            if (run.file_change_observation) |observation|
                if (std.mem.eql(u8, observation, "collecting"))
                    return error.Invalid;
        } else {
            if (!oneOf(run.phase, &.{ "queued", "running", "waiting_ui", "stopping" }) or
                run.outcome != null or run.cause != null)
                return error.Invalid;
            if (run.file_change_observation) |observation|
                if (std.mem.eql(u8, observation, "complete"))
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
            "permission_required",
            "agent_failure",
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
        (task.archived and active_count != 0))
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
            !oneOf(record.kind, &.{"permission"}) or
            !oneOf(record.state, &.{ "allowed_once", "allowed_always", "denied", "denied_session", "cancelled" }) or
            !validText(record.detail, 512, true) or findRun(task.runs, record.run_id) == null)
            return error.Invalid;
        if (!validText(record.agent_request_id, 128, true)) return error.Invalid;
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

fn validPermissionProfile(value: []const u8) bool {
    return oneOf(value, &.{ "approval_required", "full_access" });
}

fn validPermissionInteraction(value: []const u8) bool {
    return oneOf(value, &.{ "interactive", "noninteractive" });
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

fn validFileChangeId(
    value: []const u8,
    task_id: u64,
    run_generation: u64,
    order: u64,
) bool {
    var storage: [task_state.file_change_product_id_capacity]u8 = undefined;
    const expected = std.fmt.bufPrint(
        &storage,
        "change-{d}-{d}-{d}",
        .{ task_id, run_generation, order },
    ) catch return false;
    return std.mem.eql(u8, value, expected);
}

test "persisted file change identity must match its product route" {
    try std.testing.expect(validFileChangeId("change-7-3-19", 7, 3, 19));
    try std.testing.expect(!validFileChangeId("change-7-3-18", 7, 3, 19));
    try std.testing.expect(!validFileChangeId("opaque", 7, 3, 19));
}

fn validCommentaryEnds(
    assistant: []const u8,
    ends: []const u64,
    expected_end: usize,
) bool {
    var previous: usize = 0;
    for (ends) |end_wire| {
        const end = std.math.cast(usize, end_wire) orelse return false;
        if (end < previous or end > assistant.len or
            !std.unicode.utf8ValidateSlice(assistant[previous..end]))
            return false;
        previous = end;
    }
    return previous == expected_end;
}

fn oneOf(value: []const u8, options: []const []const u8) bool {
    for (options) |option| if (std.mem.eql(u8, value, option)) return true;
    return false;
}

fn isLowerHex(value: []const u8) bool {
    for (value) |byte| if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f'))
        return false;
    return true;
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

test "task store hard cut rejects retired JSON envelopes" {
    const retired =
        \\{"schema_version":1,"next_workspace_id":1,"next_workspace_recent_order":1,"next_task_id":1,"next_task_recent_order":1,"workspaces":[],"tasks":[]}
    ;
    try std.testing.expectError(error.TaskStoreCorrupt, decode(std.testing.allocator, retired, testLimits()));
}

test "task store hard cut rejects the retired provider binding" {
    var workspaces = [_]WorkspaceWire{.{
        .id = 1,
        .epoch = 1,
        .kind = "manual",
        .canonical_root = "/tmp/repo",
        .display_name = "repo",
        .visible = true,
        .recent_order = 1,
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
        .permission_profile = "approval_required",
        .permission_interaction = "interactive",
        .binding = .{
            .epoch = 1,
            .execution_generation = 1,
            .protocol = "openai_chat_completions",
            .model = "gpt-test",
        },
        .next_run_generation = 0,
        .active_operation = null,
        .runs = &.{},
        .compacts = &.{},
        .ui_history = &.{},
    }};
    var bytes: [64 * 1024]u8 = undefined;
    const encoded = try encode(&bytes, .{
        .next_workspace_id = 2,
        .next_workspace_recent_order = 2,
        .next_task_id = 2,
        .next_task_recent_order = 2,
        .workspaces = &workspaces,
        .tasks = &tasks,
    });
    const protocol_field = "\"protocol\"";
    const provider_field = "\"provider\"";
    const field_index = std.mem.indexOf(u8, encoded, protocol_field) orelse
        return error.TestUnexpectedResult;
    @memcpy(
        bytes[field_index .. field_index + protocol_field.len],
        provider_field,
    );

    var frame_offset: usize = 0;
    var task_frame_found = false;
    while (frame_offset + frame_header_bytes <= encoded.len) {
        const header: *[frame_header_bytes]u8 = @ptrCast(&bytes[frame_offset]);
        const payload_len = std.mem.readInt(u32, header[24..28], .little);
        const payload_start = frame_offset + frame_header_bytes;
        const payload_end = payload_start + payload_len;
        if (field_index >= payload_start and field_index < payload_end) {
            try std.testing.expectEqual(record_task, header[5]);
            std.mem.writeInt(
                u32,
                header[32..36],
                std.hash.Crc32.hash(bytes[payload_start..payload_end]),
                .little,
            );
            task_frame_found = true;
            break;
        }
        frame_offset = payload_end;
    }
    try std.testing.expect(task_frame_found);
    try std.testing.expectError(
        error.TaskStoreCorrupt,
        decode(std.testing.allocator, bytes[0..encoded.len], testLimits()),
    );
}

test "task store hard cut rejects metadata from before permission profiles" {
    const RetiredMetaWire = struct {
        next_workspace_id: u64,
        next_workspace_recent_order: u64,
        next_task_id: u64,
        next_task_recent_order: u64,
    };
    var output: [1024]u8 = undefined;
    var offset: usize = 0;
    try appendRecord(&output, &offset, record_meta, 0, 0, RetiredMetaWire{
        .next_workspace_id = 1,
        .next_workspace_recent_order = 1,
        .next_task_id = 1,
        .next_task_recent_order = 1,
    });
    try std.testing.expectError(
        error.TaskStoreCorrupt,
        decodeRecovering(std.testing.allocator, output[0..offset], testLimits()),
    );
}

test "task store preserves history bound to an older Workspace epoch" {
    var workspaces = [_]WorkspaceWire{.{
        .id = 1,
        .epoch = 2,
        .kind = "manual",
        .canonical_root = "/tmp/repo",
        .display_name = "repo",
        .visible = true,
        .recent_order = 1,
    }};
    var tasks = [_]TaskWire{.{
        .id = 1,
        .recent_order = 1,
        .workspace_id = 1,
        .workspace_epoch = 1,
        .workspace_root = "/tmp/repo",
        .title = "",
        .title_redacted = false,
        .archived = false,
        .permission_profile = "approval_required",
        .permission_interaction = "interactive",
        .binding = .{ .epoch = 1, .execution_generation = 1, .protocol = "openai_chat_completions", .model = "m" },
        .next_run_generation = 0,
        .active_operation = null,
        .runs = &.{},
        .compacts = &.{},
        .ui_history = &.{},
    }};
    var output: [64 * 1024]u8 = undefined;
    const state = try encode(&output, .{
        .next_workspace_id = 2,
        .next_workspace_recent_order = 2,
        .next_task_id = 2,
        .next_task_recent_order = 2,
        .workspaces = &workspaces,
        .tasks = &tasks,
    });
    var parsed = try decode(std.testing.allocator, state, testLimits());
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u64, 2), parsed.value.workspaces[0].epoch);
    try std.testing.expectEqual(@as(u64, 1), parsed.value.tasks[0].workspace_epoch);
}

test "damaged metadata does not block valid Task recovery" {
    var workspaces = [_]WorkspaceWire{.{
        .id = 1,
        .epoch = 1,
        .kind = "manual",
        .canonical_root = "/tmp/repo",
        .display_name = "repo",
        .visible = true,
        .recent_order = 1,
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
        .permission_profile = "approval_required",
        .permission_interaction = "interactive",
        .binding = .{ .epoch = 1, .execution_generation = 1, .protocol = "openai_chat_completions", .model = "m" },
        .next_run_generation = 0,
        .active_operation = null,
        .runs = &.{},
        .compacts = &.{},
        .ui_history = &.{},
    }};
    var bytes: [64 * 1024]u8 = undefined;
    const encoded = try encode(&bytes, .{
        .next_workspace_id = 2,
        .next_workspace_recent_order = 2,
        .next_task_id = 2,
        .next_task_recent_order = 2,
        .workspaces = &workspaces,
        .tasks = &tasks,
    });
    const metadata_payload_start = frame_header_bytes;
    bytes[metadata_payload_start] ^= 0xff;

    var recovered = try decodeRecovering(std.testing.allocator, bytes[0..encoded.len], testLimits());
    defer recovered.deinit();
    try std.testing.expectEqual(@as(usize, 1), recovered.value.workspaces.len);
    try std.testing.expectEqual(@as(usize, 1), recovered.value.tasks.len);
    try std.testing.expectEqual(@as(u64, 2), recovered.value.next_task_id);
    try std.testing.expect(recovered.degraded);
}

test "damaged current-format frames recover an empty projection" {
    var workspaces = [_]WorkspaceWire{.{
        .id = 1,
        .epoch = 1,
        .kind = "manual",
        .canonical_root = "/tmp/repo",
        .display_name = "repo",
        .visible = true,
        .recent_order = 1,
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
        .permission_profile = "approval_required",
        .permission_interaction = "interactive",
        .binding = .{ .epoch = 1, .execution_generation = 1, .protocol = "openai_chat_completions", .model = "m" },
        .next_run_generation = 0,
        .active_operation = null,
        .runs = &.{},
        .compacts = &.{},
        .ui_history = &.{},
    }};
    var bytes: [64 * 1024]u8 = undefined;
    const encoded = try encode(&bytes, .{
        .next_workspace_id = 2,
        .next_workspace_recent_order = 2,
        .next_task_id = 2,
        .next_task_recent_order = 2,
        .workspaces = &workspaces,
        .tasks = &tasks,
    });
    var cursor: usize = 0;
    while (cursor < encoded.len) {
        try std.testing.expectEqualStrings(frame_magic, encoded[cursor .. cursor + 4]);
        const payload_len = std.mem.readInt(
            u32,
            @as(*const [4]u8, @ptrCast(encoded[cursor + 24 .. cursor + 28].ptr)),
            .little,
        );
        bytes[cursor + frame_header_bytes] ^= 0xff;
        cursor += frame_header_bytes + payload_len;
    }

    var recovered = try decodeRecovering(std.testing.allocator, bytes[0..encoded.len], testLimits());
    defer recovered.deinit();
    try std.testing.expectEqual(@as(usize, 0), recovered.value.workspaces.len);
    try std.testing.expectEqual(@as(usize, 0), recovered.value.tasks.len);
    try std.testing.expectEqual(@as(u64, 2), recovered.value.next_task_id);
    try std.testing.expect(recovered.degraded);
    try std.testing.expectEqual(@as(usize, 1), recovered.dropped_workspaces);
    try std.testing.expectEqual(@as(usize, 1), recovered.dropped_tasks);
}

test "one damaged Task frame does not poison surviving history" {
    var workspaces = [_]WorkspaceWire{.{
        .id = 1,
        .epoch = 1,
        .kind = "manual",
        .canonical_root = "/tmp/repo",
        .display_name = "repo",
        .visible = true,
        .recent_order = 1,
    }};
    var tasks = [_]TaskWire{
        .{
            .id = 1,
            .recent_order = 1,
            .workspace_id = 1,
            .workspace_epoch = 1,
            .workspace_root = "/tmp/repo",
            .title = "first",
            .title_redacted = false,
            .archived = false,
            .permission_profile = "approval_required",
            .permission_interaction = "interactive",
            .binding = .{ .epoch = 1, .execution_generation = 1, .protocol = "openai_chat_completions", .model = "m" },
            .next_run_generation = 0,
            .active_operation = null,
            .runs = &.{},
            .compacts = &.{},
            .ui_history = &.{},
        },
        .{
            .id = 2,
            .recent_order = 2,
            .workspace_id = 1,
            .workspace_epoch = 1,
            .workspace_root = "/tmp/repo",
            .title = "second",
            .title_redacted = false,
            .archived = false,
            .permission_profile = "approval_required",
            .permission_interaction = "interactive",
            .binding = .{ .epoch = 1, .execution_generation = 1, .protocol = "openai_chat_completions", .model = "m" },
            .next_run_generation = 0,
            .active_operation = null,
            .runs = &.{},
            .compacts = &.{},
            .ui_history = &.{},
        },
    };
    var bytes: [64 * 1024]u8 = undefined;
    const encoded = try encode(&bytes, .{
        .next_workspace_id = 2,
        .next_workspace_recent_order = 2,
        .next_task_id = 3,
        .next_task_recent_order = 3,
        .workspaces = &workspaces,
        .tasks = &tasks,
    });
    var task_frame_count: usize = 0;
    var cursor: usize = 0;
    while (cursor < encoded.len) {
        try std.testing.expectEqualStrings(frame_magic, encoded[cursor .. cursor + 4]);
        const kind = encoded[cursor + 5];
        const payload_len = std.mem.readInt(
            u32,
            @as(*const [4]u8, @ptrCast(encoded[cursor + 24 .. cursor + 28].ptr)),
            .little,
        );
        if (kind == record_task) {
            task_frame_count += 1;
            if (task_frame_count == 2) {
                const payload_start = cursor + frame_header_bytes;
                bytes[payload_start] ^= 0xff;
                break;
            }
        }
        cursor += frame_header_bytes + payload_len;
    }
    try std.testing.expectEqual(@as(usize, 2), task_frame_count);
    var recovered = try decodeRecovering(std.testing.allocator, bytes[0..encoded.len], testLimits());
    defer recovered.deinit();
    try std.testing.expectEqual(@as(usize, 1), recovered.value.tasks.len);
    try std.testing.expectEqual(@as(u64, 1), recovered.value.tasks[0].id);
    try std.testing.expectEqual(@as(u64, 3), recovered.value.next_task_id);
    try std.testing.expect(recovered.degraded);
    try std.testing.expectEqual(@as(usize, 1), recovered.dropped_tasks);
    try std.testing.expectEqual(@as(usize, 1), recovered.value.failures.len);
    try std.testing.expectEqual(@as(u64, 2), recovered.value.failures[0].task_id);
    try std.testing.expectEqualStrings("payload_checksum", recovered.value.failures[0].reason);
}

test "corrupt Task identity cannot manufacture a global failure" {
    var workspaces = [_]WorkspaceWire{.{
        .id = 1,
        .epoch = 1,
        .kind = "manual",
        .canonical_root = "/tmp/repo",
        .display_name = "repo",
        .visible = true,
        .recent_order = 1,
    }};
    var tasks = [_]TaskWire{.{
        .id = 1,
        .recent_order = 1,
        .workspace_id = 1,
        .workspace_epoch = 1,
        .workspace_root = "/tmp/repo",
        .title = "first",
        .title_redacted = false,
        .archived = false,
        .permission_profile = "approval_required",
        .permission_interaction = "interactive",
        .binding = .{ .epoch = 1, .execution_generation = 1, .protocol = "openai_chat_completions", .model = "m" },
        .next_run_generation = 0,
        .active_operation = null,
        .runs = &.{},
        .compacts = &.{},
        .ui_history = &.{},
    }};
    var bytes: [64 * 1024]u8 = undefined;
    const encoded = try encode(&bytes, .{
        .next_workspace_id = 2,
        .next_workspace_recent_order = 2,
        .next_task_id = 2,
        .next_task_recent_order = 2,
        .workspaces = &workspaces,
        .tasks = &tasks,
    });
    var cursor: usize = 0;
    while (cursor < encoded.len) {
        const kind = encoded[cursor + 5];
        const payload_len = std.mem.readInt(
            u32,
            @as(*const [4]u8, @ptrCast(encoded[cursor + 24 .. cursor + 28].ptr)),
            .little,
        );
        if (kind == record_task) {
            std.mem.writeInt(
                u64,
                @as(*[8]u8, @ptrCast(bytes[cursor + 8 .. cursor + 16].ptr)),
                0,
                .little,
            );
            std.mem.writeInt(
                u32,
                @as(*[4]u8, @ptrCast(bytes[cursor + 28 .. cursor + 32].ptr)),
                std.hash.Crc32.hash(bytes[cursor .. cursor + 28]),
                .little,
            );
            break;
        }
        cursor += frame_header_bytes + payload_len;
    }
    var recovered = try decodeRecovering(std.testing.allocator, bytes[0..encoded.len], testLimits());
    defer recovered.deinit();
    try std.testing.expectEqual(@as(usize, 0), recovered.value.tasks.len);
    try std.testing.expectEqual(@as(u64, 2), recovered.value.next_task_id);
    try std.testing.expect(recovered.degraded);
    try std.testing.expectEqual(@as(usize, 1), recovered.dropped_tasks);
    try std.testing.expectEqual(@as(usize, 0), recovered.value.failures.len);
}

test "task store round-trips per-run execution generations across binding adoption" {
    var workspaces = [_]WorkspaceWire{.{
        .id = 1,
        .epoch = 1,
        .kind = "manual",
        .canonical_root = "/tmp/repo",
        .display_name = "repo",
        .visible = true,
        .recent_order = 1,
    }};
    var runs: [2]RunWire = undefined;
    runs[0] = .{
        .id = 1,
        .generation = 1,
        .execution_generation = 13,
        .execution_protocol = "openai_chat_completions",
        .execution_model = "model",
        .permission_profile = "approval_required",
        .permission_interaction = "interactive",
        .input = .{
            .kind = "text",
            .text = "before adoption",
            .skill_id = null,
            .catalog_revision = null,
            .invocation_name = null,
            .display_name = null,
            .argument_values = null,
            .redacted = false,
        },
        .assistant = "note done",
        .assistant_redacted = false,
        .commentary_ends = &.{5},
        .assistant_output_kind = "final",
        .assistant_output_start = 5,
        .phase = "completed",
        .outcome = "completed",
        .cause = null,
        .usage = .{
            .input_tokens = 1,
            .output_tokens = 1,
            .cache_read_input_tokens = 0,
            .cache_creation_input_tokens = 0,
        },
        .tools = &.{},
        .diagnostic = "",
        .diagnostic_truncated = false,
        .diagnostic_redacted = false,
        .event_projection_failure = null,
        .next_activity_order = 1,
    };
    runs[1] = runs[0];
    runs[1].id = 2;
    runs[1].generation = 2;
    runs[1].execution_generation = 17;
    runs[1].input.text = "after adoption";
    runs[1].event_projection_failure = "dependency_contract_failure";
    var tasks = [_]TaskWire{.{
        .id = 1,
        .recent_order = 1,
        .workspace_id = 1,
        .workspace_epoch = 1,
        .workspace_root = "/tmp/repo",
        .title = "task",
        .title_redacted = false,
        .archived = false,
        .permission_profile = "approval_required",
        .permission_interaction = "interactive",
        .binding = .{
            .epoch = 2,
            .execution_generation = 17,
            .protocol = "openai_chat_completions",
            .model = "model",
        },
        .next_run_generation = 2,
        .active_operation = null,
        .runs = &runs,
        .compacts = &.{},
        .ui_history = &.{},
    }};
    var output: [64 * 1024]u8 = undefined;
    const bytes = try encode(&output, .{
        .default_permission_profile = "full_access",
        .next_workspace_id = 2,
        .next_workspace_recent_order = 2,
        .next_task_id = 2,
        .next_task_recent_order = 2,
        .workspaces = &workspaces,
        .tasks = &tasks,
    });
    var decoded = try decode(std.testing.allocator, bytes, testLimits());
    defer decoded.deinit();
    try std.testing.expectEqualStrings(
        "full_access",
        decoded.value.default_permission_profile,
    );
    try std.testing.expectEqualStrings(
        "approval_required",
        decoded.value.tasks[0].permission_profile,
    );
    try std.testing.expectEqualStrings(
        "interactive",
        decoded.value.tasks[0].permission_interaction,
    );
    try std.testing.expectEqualStrings(
        "approval_required",
        decoded.value.tasks[0].runs[0].permission_profile,
    );
    try std.testing.expectEqualStrings(
        "interactive",
        decoded.value.tasks[0].runs[0].permission_interaction,
    );
    try std.testing.expectEqual(@as(u64, 17), decoded.value.tasks[0].binding.execution_generation);
    try std.testing.expectEqual(@as(u64, 13), decoded.value.tasks[0].runs[0].execution_generation);
    try std.testing.expectEqual(@as(u64, 17), decoded.value.tasks[0].runs[1].execution_generation);
    try std.testing.expectEqualStrings(
        "final",
        decoded.value.tasks[0].runs[0].assistant_output_kind.?,
    );
    try std.testing.expectEqual(@as(?u64, 5), decoded.value.tasks[0].runs[0].assistant_output_start);
    try std.testing.expectEqualSlices(
        u64,
        &.{5},
        decoded.value.tasks[0].runs[0].commentary_ends,
    );
    try std.testing.expectEqualStrings(
        "dependency_contract_failure",
        decoded.value.tasks[0].runs[1].event_projection_failure.?,
    );
}

test "task store rejects states that would violate the product contract" {
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
        .execution_protocol = "openai_chat_completions",
        .execution_model = "model",
        .permission_profile = "approval_required",
        .permission_interaction = "interactive",
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
        .commentary_ends = &.{},
        .assistant_output_kind = "final",
        .assistant_output_start = 0,
        .phase = "completed",
        .outcome = "completed",
        .cause = null,
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
        .event_projection_failure = null,
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
        .permission_profile = "approval_required",
        .permission_interaction = "interactive",
        .binding = .{
            .epoch = 1,
            .execution_generation = 1,
            .protocol = "openai_chat_completions",
            .model = "model",
        },
        .next_run_generation = 1,
        .active_operation = null,
        .runs = &runs,
        .compacts = &compacts,
        .ui_history = &ui_history,
    }};
    var state: StateWire = .{
        .next_workspace_id = 2,
        .next_workspace_recent_order = 2,
        .next_task_id = 2,
        .next_task_recent_order = 2,
        .workspaces = &workspaces,
        .tasks = &tasks,
    };
    try validate(&state, testLimits());

    runs[0].assistant = "note done";
    runs[0].assistant_output_start = 5;
    runs[0].commentary_ends = &.{5};
    try validate(&state, testLimits());
    runs[0].commentary_ends = &.{ 3, 3, 5 };
    try validate(&state, testLimits());
    runs[0].commentary_ends = &.{ 4, 3, 5 };
    try std.testing.expectError(error.Invalid, validate(&state, testLimits()));
    runs[0].commentary_ends = &.{4};
    try std.testing.expectError(error.Invalid, validate(&state, testLimits()));
    runs[0].assistant = "done";
    runs[0].assistant_output_start = 0;
    runs[0].commentary_ends = &.{};

    runs[0].assistant_output_start = 5;
    try std.testing.expectError(error.Invalid, validate(&state, testLimits()));
    runs[0].assistant_output_start = 0;

    runs[0].assistant_output_kind = null;
    try std.testing.expectError(error.Invalid, validate(&state, testLimits()));
    runs[0].assistant_output_kind = "final";

    runs[0].assistant = "好";
    runs[0].assistant_output_start = 1;
    try std.testing.expectError(error.Invalid, validate(&state, testLimits()));
    runs[0].assistant = "done";
    runs[0].assistant_output_start = 0;

    runs[0].assistant_output_kind = "commentary";
    try std.testing.expectError(error.Invalid, validate(&state, testLimits()));
    runs[0].assistant_output_kind = "final";

    runs[0].event_projection_failure = "unknown";
    try std.testing.expectError(error.Invalid, validate(&state, testLimits()));
    runs[0].event_projection_failure = null;

    var mixed_tasks = [_]TaskWire{ tasks[0], tasks[0] };
    mixed_tasks[1].id = 0;
    state.tasks = &mixed_tasks;
    var mixed_output: [64 * 1024]u8 = undefined;
    const mixed_bytes = try encode(&mixed_output, state);
    var recovered = try decodeRecovering(
        std.testing.allocator,
        mixed_bytes,
        testLimits(),
    );
    defer recovered.deinit();
    try std.testing.expectEqual(@as(usize, 1), recovered.value.tasks.len);
    try std.testing.expectEqual(@as(usize, 1), recovered.dropped_tasks);
    state.tasks = &tasks;

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

test "task file store recovery quarantines the previous canonical bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var absolute_storage: [std.fs.max_path_bytes]u8 = undefined;
    const absolute_len = try tmp.dir.realPath(std.testing.io, &absolute_storage);
    var store = try FileStore.init(
        std.testing.io,
        absolute_storage[0..absolute_len],
    );
    defer store.deinit();
    const previous = "{\"schema_version\":7}";
    const replacement = "{\"schema_version\":1}";
    try store.commit(previous);
    try store.recover(replacement);

    const restored = (try store.loadAlloc(std.testing.allocator)).?;
    defer std.testing.allocator.free(restored);
    try std.testing.expectEqualStrings(replacement, restored);

    var iterable = try tmp.dir.openDir(
        std.testing.io,
        ".",
        .{ .iterate = true, .follow_symlinks = false },
    );
    defer iterable.close(std.testing.io);
    var iterator = iterable.iterate();
    var quarantine_name: ?[]u8 = null;
    defer if (quarantine_name) |name| std.testing.allocator.free(name);
    while (try iterator.next(std.testing.io)) |entry| {
        if (entry.kind == .file and std.mem.startsWith(
            u8,
            entry.name,
            ".workbench-history.recovery.",
        )) {
            try std.testing.expect(quarantine_name == null);
            quarantine_name = try std.testing.allocator.dupe(u8, entry.name);
        }
    }
    const name = quarantine_name orelse return error.TestExpectedEqual;
    var quarantine = try tmp.dir.openFile(
        std.testing.io,
        name,
        .{ .follow_symlinks = false },
    );
    if (builtin.os.tag == .windows) quarantine.flags.nonblocking = true;
    defer quarantine.close(std.testing.io);
    var quarantine_bytes: [previous.len]u8 = undefined;
    try std.testing.expectEqual(
        @as(usize, previous.len),
        try quarantine.readPositionalAll(std.testing.io, &quarantine_bytes, 0),
    );
    try std.testing.expectEqualStrings(previous, &quarantine_bytes);
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
        .max_commentary_segments_per_run = 16,
        .max_file_refs_per_tool = 4,
        .max_ui_history_per_task = 4,
        .max_workspace_bytes = 1024,
        .max_task_title_bytes = 512,
        .max_user_message_bytes = 4096,
        .max_assistant_message_bytes = 4096,
        .max_tool_field_bytes = 4096,
        .max_file_ref_field_bytes = 1024,
        .max_execution_model_bytes = 512,
        .max_terminal_diagnostic_bytes = 512,
    };
}
