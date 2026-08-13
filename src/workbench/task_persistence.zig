const std = @import("std");
const builtin = @import("builtin");

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
};

const MetaWire = struct {
    next_workspace_id: u64,
    next_workspace_recent_order: u64,
    next_task_id: u64,
    next_task_recent_order: u64,
};

pub fn encode(output: []u8, state: StateWire) Error![]const u8 {
    if (output.len == 0) return error.TaskStoreEncodeFailed;
    var offset: usize = 0;
    appendRecord(output, &offset, record_meta, 0, 0, MetaWire{
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
    var max_workspace_id: u64 = 0;
    var max_workspace_recent_order: u64 = 0;
    var max_task_id: u64 = 0;
    var max_task_recent_order: u64 = 0;
    var dropped_workspaces: usize = 0;
    var dropped_tasks: usize = 0;
    var dropped_failures: usize = 0;
    var degraded = false;
    var metadata_seen = false;
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
    if (!saw_frame) return error.TaskStoreCorrupt;
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
        !oneOf(task.binding.provider, &.{ "anthropic", "openai" }) or
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
    if (state.next_workspace_id == 0 or state.next_workspace_recent_order == 0 or state.next_task_id == 0 or
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

test "task store hard cut rejects retired JSON envelopes" {
    const retired =
        \\{"schema_version":1,"next_workspace_id":1,"next_workspace_recent_order":1,"next_task_id":1,"next_task_recent_order":1,"workspaces":[],"tasks":[]}
    ;
    try std.testing.expectError(error.TaskStoreCorrupt, decode(std.testing.allocator, retired, testLimits()));
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
        .closed = false,
        .binding = .{ .epoch = 1, .execution_generation = 1, .provider = "openai", .model = "m" },
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
        .closed = false,
        .binding = .{ .epoch = 1, .execution_generation = 1, .provider = "openai", .model = "m" },
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
        .closed = false,
        .binding = .{ .epoch = 1, .execution_generation = 1, .provider = "openai", .model = "m" },
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
            .closed = false,
            .binding = .{ .epoch = 1, .execution_generation = 1, .provider = "openai", .model = "m" },
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
            .closed = false,
            .binding = .{ .epoch = 1, .execution_generation = 1, .provider = "openai", .model = "m" },
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
        .closed = false,
        .binding = .{ .epoch = 1, .execution_generation = 1, .provider = "openai", .model = "m" },
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
        .next_workspace_id = 2,
        .next_workspace_recent_order = 2,
        .next_task_id = 2,
        .next_task_recent_order = 2,
        .workspaces = &workspaces,
        .tasks = &tasks,
    };
    try validate(&state, testLimits());

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
