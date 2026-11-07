//! Scheduled Task codec and concrete product-data store.

const std = @import("std");
const builtin = @import("builtin");
const scheduled = @import("product_schedule_state");

pub const schema_version: u8 = 1;
pub const max_store_bytes: usize = 256 * 1024;

pub const Error = scheduled.Error || error{
    ScheduledTaskStoreEmpty,
    ScheduledTaskStoreTooLarge,
    ScheduledTaskStoreCorrupt,
    ScheduledTaskStoreEncodeFailed,
};

pub const file_name = "scheduled-tasks.json";
const recovery_prefix = ".scheduled-tasks.recovery.";
const recovery_id_hex_bytes = 16;
const max_recovery_artifacts = 1024;

/// Only retired versions or known retired binding fields authorize the hard
/// cut. Unknown/current corruption belongs to ordinary explicit recovery.
pub fn isRetiredStore(allocator: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error!bool {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const version = parsed.value.object.get("schema_version") orelse return false;
    if (version != .integer) return false;
    if (version.integer == 2) return true;
    if (version.integer != 1) return false;
    const items = parsed.value.object.get("items") orelse return false;
    if (items != .array) return false;
    for (items.array.items) |item| {
        if (item != .object) continue;
        if (item.object.contains("execution_generation")) return true;
        const binding = item.object.get("binding") orelse continue;
        if (binding == .object and (binding.object.contains("selection_revision") or binding.object.contains("legacy_execution"))) return true;
    }
    return false;
}

pub const FileStoreError = std.mem.Allocator.Error || error{
    DirectoryUnavailable,
    ReadFailed,
    WriteFailed,
    PersistenceOutcomeUnknown,
};

pub const RecoveryFault = enum {
    none,
    stage_failed,
    install_failed,
    restore_failed,
    interrupted_after_quarantine,
    interrupted_after_install,
};

pub const FileStore = struct {
    io: std.Io,
    dir: std.Io.Dir,
    recovery_fault: RecoveryFault = .none,

    pub fn init(
        io: std.Io,
        absolute_directory: []const u8,
    ) FileStoreError!FileStore {
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
        return .{ .io = io, .dir = dir };
    }

    pub fn deinit(self: *FileStore) void {
        self.dir.close(self.io);
        self.* = undefined;
    }

    pub fn loadAlloc(
        self: *FileStore,
        allocator: std.mem.Allocator,
    ) FileStoreError!?[]u8 {
        if (self.hasIncompleteRecoveryArtifact()) return error.ReadFailed;
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
        if (length == 0 or length > max_store_bytes)
            return error.ReadFailed;
        const bytes = try allocator.alloc(u8, @intCast(length));
        errdefer allocator.free(bytes);
        const read = file.readPositionalAll(
            self.io,
            bytes,
            0,
        ) catch return error.ReadFailed;
        if (read != length) return error.ReadFailed;
        return bytes;
    }

    pub fn commit(
        self: *FileStore,
        bytes: []const u8,
    ) FileStoreError!void {
        if (bytes.len == 0 or bytes.len > max_store_bytes)
            return error.WriteFailed;
        var random: [8]u8 = undefined;
        std.Io.randomSecure(self.io, &random) catch return error.WriteFailed;
        const random_hex = std.fmt.bytesToHex(random, .lower);
        var temp_name_storage: [64]u8 = undefined;
        var name_writer = std.Io.Writer.fixed(&temp_name_storage);
        name_writer.print(
            ".scheduled-tasks.{s}.tmp",
            .{random_hex},
        ) catch return error.WriteFailed;
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
            if (temp_exists) self.dir.deleteFile(
                self.io,
                temp_name,
            ) catch {};
        }
        file.writeStreamingAll(self.io, bytes) catch
            return error.WriteFailed;
        file.sync(self.io) catch return error.WriteFailed;
        file.close(self.io);
        file_open = false;
        self.dir.rename(
            temp_name,
            self.dir,
            file_name,
            self.io,
        ) catch return error.WriteFailed;
        temp_exists = false;
        if (!self.syncCommit()) return error.PersistenceOutcomeUnknown;
    }

    /// Fully stages and syncs the replacement before moving the current
    /// canonical into quarantine. A definite install failure restores the
    /// canonical; an interrupted or indeterminate window leaves recovery
    /// artifacts that make the next load fail closed.
    pub fn recover(
        self: *FileStore,
        bytes: []const u8,
    ) FileStoreError!void {
        if (bytes.len == 0 or bytes.len > max_store_bytes)
            return error.WriteFailed;
        if (self.recovery_fault == .stage_failed) return error.WriteFailed;
        var random: [8]u8 = undefined;
        std.Io.randomSecure(self.io, &random) catch return error.WriteFailed;
        const random_hex = std.fmt.bytesToHex(random, .lower);
        var temp_name_storage: [80]u8 = undefined;
        var temp_name_writer = std.Io.Writer.fixed(&temp_name_storage);
        temp_name_writer.print(
            ".scheduled-tasks.recovery.{s}.tmp",
            .{random_hex},
        ) catch return error.WriteFailed;
        const temp_name = temp_name_writer.buffered();
        var quarantine_name_storage: [80]u8 = undefined;
        var quarantine_name_writer = std.Io.Writer.fixed(&quarantine_name_storage);
        quarantine_name_writer.print(
            ".scheduled-tasks.recovery.{s}.bak",
            .{random_hex},
        ) catch return error.WriteFailed;
        const quarantine_name = quarantine_name_writer.buffered();
        var final_quarantine_name_storage: [88]u8 = undefined;
        var final_quarantine_name_writer = std.Io.Writer.fixed(
            &final_quarantine_name_storage,
        );
        final_quarantine_name_writer.print(
            ".scheduled-tasks.recovery.{s}.quarantine",
            .{random_hex},
        ) catch return error.WriteFailed;
        const final_quarantine_name = final_quarantine_name_writer.buffered();
        var pending_name_storage: [84]u8 = undefined;
        var pending_name_writer = std.Io.Writer.fixed(&pending_name_storage);
        pending_name_writer.print(
            ".scheduled-tasks.recovery.{s}.pending",
            .{random_hex},
        ) catch return error.WriteFailed;
        const pending_name = pending_name_writer.buffered();

        const replacement = self.dir.createFile(
            self.io,
            temp_name,
            .{
                .exclusive = true,
                .permissions = privateFilePermissions(),
                .resolve_beneath = true,
            },
        ) catch return error.WriteFailed;
        var replacement_open = true;
        var temp_exists = true;
        defer {
            if (replacement_open) replacement.close(self.io);
            if (temp_exists) self.dir.deleteFile(self.io, temp_name) catch {};
        }
        replacement.writeStreamingAll(self.io, bytes) catch
            return error.WriteFailed;
        replacement.sync(self.io) catch return error.WriteFailed;
        replacement.close(self.io);
        replacement_open = false;
        if (!self.syncPath(temp_name)) return error.WriteFailed;

        const pending = self.dir.createFile(
            self.io,
            pending_name,
            .{
                .exclusive = true,
                .permissions = privateFilePermissions(),
                .resolve_beneath = true,
            },
        ) catch return error.WriteFailed;
        var pending_open = true;
        var clean_pending = true;
        defer {
            if (pending_open) pending.close(self.io);
            if (clean_pending)
                self.dir.deleteFile(self.io, pending_name) catch {};
        }
        pending.sync(self.io) catch return error.WriteFailed;
        pending.close(self.io);
        pending_open = false;
        if (!self.syncPath(pending_name)) return error.WriteFailed;
        // A new durable marker must protect the store before older recovery
        // evidence is settled. Any later failure remains visible on restart.
        clean_pending = false;
        try self.settleIncompleteRecoveries(&random_hex);

        var quarantined = true;
        self.dir.rename(
            file_name,
            self.dir,
            quarantine_name,
            self.io,
        ) catch |err| switch (err) {
            error.FileNotFound => quarantined = false,
            else => return error.WriteFailed,
        };
        if (quarantined and !self.syncPath(quarantine_name)) {
            if (!self.restoreCanonical(quarantine_name))
                return error.PersistenceOutcomeUnknown;
            clean_pending = true;
            return error.WriteFailed;
        }

        if (self.recovery_fault == .interrupted_after_quarantine) {
            temp_exists = false;
            clean_pending = false;
            return error.PersistenceOutcomeUnknown;
        }
        if (self.recovery_fault == .install_failed or self.recovery_fault == .restore_failed) {
            if (quarantined) {
                if (!self.restoreCanonical(quarantine_name))
                    return error.PersistenceOutcomeUnknown;
                clean_pending = true;
            }
            return error.WriteFailed;
        }
        self.dir.rename(
            temp_name,
            self.dir,
            file_name,
            self.io,
        ) catch {
            if (quarantined) {
                if (!self.restoreCanonical(quarantine_name))
                    return error.PersistenceOutcomeUnknown;
                clean_pending = true;
            }
            return error.WriteFailed;
        };
        temp_exists = false;
        if (!self.syncPath(file_name)) {
            clean_pending = false;
            return error.PersistenceOutcomeUnknown;
        }
        if (self.recovery_fault == .interrupted_after_install) {
            clean_pending = false;
            return error.PersistenceOutcomeUnknown;
        }
        if (quarantined) {
            self.dir.rename(
                quarantine_name,
                self.dir,
                final_quarantine_name,
                self.io,
            ) catch {
                clean_pending = false;
                return error.PersistenceOutcomeUnknown;
            };
            if (!self.syncPath(final_quarantine_name)) {
                clean_pending = false;
                return error.PersistenceOutcomeUnknown;
            }
        }
        self.dir.deleteFile(self.io, pending_name) catch {
            clean_pending = false;
            return error.PersistenceOutcomeUnknown;
        };
        clean_pending = false;
        if (!self.syncDirectory()) return error.PersistenceOutcomeUnknown;
    }

    fn restoreCanonical(self: *FileStore, quarantine_name: []const u8) bool {
        if (self.recovery_fault == .restore_failed) return false;
        self.dir.rename(
            quarantine_name,
            self.dir,
            file_name,
            self.io,
        ) catch return false;
        return self.syncPath(file_name);
    }

    /// Explicit recovery is the authority to finish older interrupted
    /// recovery transactions. Preserve every displaced canonical as a final
    /// quarantine, remove uninstalled candidates, and clear pending markers
    /// last so a crash during settlement remains fail closed.
    fn settleIncompleteRecoveries(self: *FileStore, current_id: []const u8) FileStoreError!void {
        var operations: usize = 0;
        var name_storage: [96]u8 = undefined;
        while (try self.findRecoveryArtifact(".bak", &name_storage, current_id)) |name| {
            operations += 1;
            if (operations > max_recovery_artifacts)
                return error.PersistenceOutcomeUnknown;
            const transaction_id = recoveryTransactionId(name, ".bak") orelse
                return error.PersistenceOutcomeUnknown;
            var quarantine_storage: [96]u8 = undefined;
            var writer = std.Io.Writer.fixed(&quarantine_storage);
            writer.print(
                recovery_prefix ++ "{s}.quarantine",
                .{transaction_id},
            ) catch return error.PersistenceOutcomeUnknown;
            const quarantine_name = writer.buffered();
            self.dir.rename(
                name,
                self.dir,
                quarantine_name,
                self.io,
            ) catch return error.PersistenceOutcomeUnknown;
            if (!self.syncPath(quarantine_name))
                return error.PersistenceOutcomeUnknown;
        }
        var removed_temp = false;
        while (try self.findRecoveryArtifact(".tmp", &name_storage, current_id)) |name| {
            operations += 1;
            if (operations > max_recovery_artifacts)
                return error.PersistenceOutcomeUnknown;
            self.dir.deleteFile(self.io, name) catch
                return error.PersistenceOutcomeUnknown;
            removed_temp = true;
        }
        if (removed_temp and !self.syncDirectory())
            return error.PersistenceOutcomeUnknown;
        var removed_pending = false;
        while (try self.findRecoveryArtifact(".pending", &name_storage, current_id)) |name| {
            operations += 1;
            if (operations > max_recovery_artifacts)
                return error.PersistenceOutcomeUnknown;
            self.dir.deleteFile(self.io, name) catch
                return error.PersistenceOutcomeUnknown;
            removed_pending = true;
        }
        if (removed_pending and !self.syncDirectory())
            return error.PersistenceOutcomeUnknown;
    }

    fn findRecoveryArtifact(
        self: *FileStore,
        suffix: []const u8,
        output: []u8,
        excluded_id: ?[]const u8,
    ) FileStoreError!?[]const u8 {
        var iterable = self.dir.openDir(
            self.io,
            ".",
            .{ .iterate = true, .follow_symlinks = false },
        ) catch return error.ReadFailed;
        defer iterable.close(self.io);
        var iterator = iterable.iterate();
        while (iterator.next(self.io) catch return error.ReadFailed) |entry| {
            if (entry.kind != .file) continue;
            const id = recoveryTransactionId(entry.name, suffix) orelse continue;
            if (excluded_id) |excluded|
                if (std.mem.eql(u8, id, excluded)) continue;
            if (entry.name.len > output.len)
                return error.PersistenceOutcomeUnknown;
            @memcpy(output[0..entry.name.len], entry.name);
            return output[0..entry.name.len];
        }
        return null;
    }

    fn hasIncompleteRecoveryArtifact(self: *FileStore) bool {
        var iterable = self.dir.openDir(
            self.io,
            ".",
            .{ .iterate = true, .follow_symlinks = false },
        ) catch return true;
        defer iterable.close(self.io);
        var iterator = iterable.iterate();
        while (iterator.next(self.io) catch return true) |entry| {
            if (entry.kind != .file) continue;
            if (recoveryTransactionId(entry.name, ".pending") != null)
                return true;
        }
        return false;
    }

    fn syncPath(self: *FileStore, name: []const u8) bool {
        if (builtin.os.tag == .windows) {
            const file = self.dir.openFile(
                self.io,
                name,
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
        return self.syncDirectory();
    }

    fn syncDirectory(self: *FileStore) bool {
        if (builtin.os.tag == .windows) return true;
        const directory_file: std.Io.File = .{
            .handle = self.dir.handle,
            .flags = .{ .nonblocking = false },
        };
        directory_file.sync(self.io) catch return false;
        return true;
    }

    fn syncCommit(self: *FileStore) bool {
        return self.syncPath(file_name);
    }
};

fn recoveryTransactionId(name: []const u8, suffix: []const u8) ?[]const u8 {
    const expected_len = recovery_prefix.len + recovery_id_hex_bytes + suffix.len;
    if (name.len != expected_len or
        !std.mem.startsWith(u8, name, recovery_prefix) or
        !std.mem.endsWith(u8, name, suffix)) return null;
    const transaction_id = name[recovery_prefix.len .. recovery_prefix.len + recovery_id_hex_bytes];
    for (transaction_id) |byte| {
        if (!std.ascii.isHex(byte)) return null;
    }
    return transaction_id;
}

fn directoryPermissions() std.Io.File.Permissions {
    return if (builtin.os.tag == .windows)
        .default_dir
    else
        .fromMode(0o700);
}

fn privateFilePermissions() std.Io.File.Permissions {
    return if (builtin.os.tag == .windows)
        .default_file
    else
        .fromMode(0o600);
}

const StoreWire = struct {
    schema_version: u8,
    next_id: u64,
    items: []ItemWire,
};

const ItemWire = struct {
    id: u64,
    epoch: u64,
    title: []const u8,
    binding: BindingWire,
    permission_profile: []const u8,
    input: InputWire,
    recurrence: RecurrenceWire,
    enabled: bool,
    health: []const u8,
    failure_reason: ?[]const u8,
    next_run_at_unix_seconds: ?u64,
    occurrences: []OccurrenceWire,
    last_timer_planned_at_unix_seconds: ?u64 = null,
};

const BindingWire = struct {
    model_ref: ModelRefWire,
    source_generation: u64,
    protocol: []const u8,
};

const ModelRefWire = struct {
    source_id: []const u8,
    model_id: []const u8,
};

const InputWire = struct {
    kind: []const u8,
    text: ?[]const u8 = null,
};

const RecurrenceWire = struct {
    kind: []const u8,
    at_unix_seconds: ?u64 = null,
    start_at_unix_seconds: ?u64 = null,
    every_seconds: ?u64 = null,
};

const OccurrenceWire = struct {
    planned_at_unix_seconds: u64,
    triggered_at_unix_seconds: u64,
    source: []const u8,
    result: []const u8,
    task_id: u64,
    reason: ?[]const u8,
    task_outcome: ?[]const u8,
    notification_sent: bool,
};

pub fn encode(
    output: []u8,
    store: *const scheduled.Store,
) Error![]const u8 {
    if (output.len == 0) return error.ScheduledTaskStoreEncodeFailed;
    var writer = std.Io.Writer.fixed(output);
    writer.print(
        "{{\"schema_version\":{d},\"next_id\":{d},\"items\":[",
        .{ schema_version, store.next_id },
    ) catch return error.ScheduledTaskStoreEncodeFailed;
    var first = true;
    for (store.items) |entry| {
        const item = entry orelse continue;
        if (!first) writer.writeByte(',') catch
            return error.ScheduledTaskStoreEncodeFailed;
        first = false;
        encodeItem(&writer, &item) catch
            return error.ScheduledTaskStoreEncodeFailed;
    }
    writer.writeAll("]}") catch return error.ScheduledTaskStoreEncodeFailed;
    const encoded = writer.buffered();
    if (encoded.len > max_store_bytes)
        return error.ScheduledTaskStoreTooLarge;
    return encoded;
}

pub fn decode(
    allocator: std.mem.Allocator,
    input: []const u8,
    limits: scheduled.Limits,
) Error!scheduled.Store {
    try validateStoreBytes(input);
    return decodeCurrent(allocator, input, limits);
}

fn validateStoreBytes(input: []const u8) Error!void {
    if (input.len == 0) return error.ScheduledTaskStoreEmpty;
    if (input.len > max_store_bytes)
        return error.ScheduledTaskStoreTooLarge;
}

fn decodeCurrent(
    allocator: std.mem.Allocator,
    input: []const u8,
    limits: scheduled.Limits,
) Error!scheduled.Store {
    var parsed = std.json.parseFromSlice(
        StoreWire,
        allocator,
        input,
        .{ .ignore_unknown_fields = false },
    ) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.ScheduledTaskStoreCorrupt;
    defer parsed.deinit();
    if (parsed.value.schema_version != schema_version or
        parsed.value.next_id == 0 or
        parsed.value.items.len > limits.max_items)
        return error.ScheduledTaskStoreCorrupt;

    var store = try scheduled.Store.init(allocator, limits);
    errdefer store.deinit();
    for (parsed.value.items) |wire| {
        var occurrences: [scheduled.max_occurrence_history]scheduled.Occurrence = undefined;
        if (wire.occurrences.len > occurrences.len)
            return error.ScheduledTaskStoreCorrupt;
        for (wire.occurrences, 0..) |occurrence, index|
            occurrences[index] = try decodeOccurrence(occurrence);
        const recurrence = try decodeRecurrence(wire.recurrence);
        const input_value = try decodeInput(wire.input);
        if (!validText(wire.title))
            return error.ScheduledTaskStoreCorrupt;
        store.restoreItem(.{
            .id = wire.id,
            .epoch = wire.epoch,
            .definition = .{
                .title = wire.title,
                .binding = try decodeBinding(wire.binding),
                .permission_profile = parseEnum(
                    scheduled.PermissionProfile,
                    wire.permission_profile,
                ) orelse return error.ScheduledTaskStoreCorrupt,
                .input = input_value,
                .recurrence = recurrence,
            },
            .enabled = wire.enabled,
            .health = parseEnum(scheduled.Health, wire.health) orelse
                return error.ScheduledTaskStoreCorrupt,
            .failure_reason = if (wire.failure_reason) |reason|
                parseEnum(scheduled.FailureReason, reason) orelse
                    return error.ScheduledTaskStoreCorrupt
            else
                null,
            .next_run_at_unix_seconds = wire.next_run_at_unix_seconds,
            .last_timer_planned_at_unix_seconds = wire.last_timer_planned_at_unix_seconds,
            .occurrences = occurrences[0..wire.occurrences.len],
        }) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.ScheduledTaskStoreCorrupt;
    }
    store.restoreNextId(parsed.value.next_id) catch
        return error.ScheduledTaskStoreCorrupt;
    return store;
}

fn decodeBinding(wire: BindingWire) Error!scheduled.Binding {
    return .{
        .model_ref = .{
            .source_id = wire.model_ref.source_id,
            .model_id = wire.model_ref.model_id,
        },
        .source_generation = wire.source_generation,
        .protocol = parseEnum(scheduled.Protocol, wire.protocol) orelse
            return error.ScheduledTaskStoreCorrupt,
    };
}

fn encodeItem(writer: *std.Io.Writer, item: *const scheduled.Item) !void {
    try writer.print(
        "{{\"id\":{d},\"epoch\":{d},\"title\":",
        .{ item.id, item.epoch },
    );
    try jsonString(writer, item.title);
    try writer.writeAll(",\"binding\":");
    try encodeBinding(writer, item.bindingView());
    try writer.writeAll(",\"permission_profile\":");
    try jsonString(writer, @tagName(item.permission_profile));
    try writer.writeAll(",\"input\":");
    try encodeInput(writer, item.input.borrowed());
    try writer.writeAll(",\"recurrence\":");
    try encodeRecurrence(writer, item.recurrence);
    if (item.last_timer_planned_at_unix_seconds) |last|
        try writer.print(",\"last_timer_planned_at_unix_seconds\":{d}", .{last});
    try writer.print(
        ",\"enabled\":{s},\"health\":",
        .{if (item.enabled) "true" else "false"},
    );
    try jsonString(writer, @tagName(item.health));
    try writer.writeAll(",\"failure_reason\":");
    if (item.failure_reason) |reason|
        try jsonString(writer, @tagName(reason))
    else
        try writer.writeAll("null");
    try writer.writeAll(",\"next_run_at_unix_seconds\":");
    if (item.next_run_at_unix_seconds) |next|
        try writer.print("{d}", .{next})
    else
        try writer.writeAll("null");
    try writer.writeAll(",\"occurrences\":[");
    for (item.occurrences(), 0..) |occurrence, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.print(
            "{{\"planned_at_unix_seconds\":{d},\"triggered_at_unix_seconds\":{d},\"source\":",
            .{ occurrence.planned_at_unix_seconds, occurrence.triggered_at_unix_seconds },
        );
        try jsonString(writer, @tagName(occurrence.source));
        try writer.writeAll(",\"result\":");
        try jsonString(writer, @tagName(occurrence.result));
        try writer.print(",\"task_id\":{d},\"reason\":", .{occurrence.task_id});
        if (occurrence.reason) |reason|
            try jsonString(writer, @tagName(reason))
        else
            try writer.writeAll("null");
        try writer.writeAll(",\"task_outcome\":");
        if (occurrence.task_outcome) |outcome|
            try jsonString(writer, @tagName(outcome))
        else
            try writer.writeAll("null");
        try writer.print(",\"notification_sent\":{s}}}", .{
            if (occurrence.notification_sent) "true" else "false",
        });
    }
    try writer.writeAll("]}");
}

fn encodeBinding(writer: *std.Io.Writer, binding: scheduled.Binding) !void {
    try writer.writeAll("{\"model_ref\":{\"source_id\":");
    try jsonString(writer, binding.model_ref.source_id);
    try writer.writeAll(",\"model_id\":");
    try jsonString(writer, binding.model_ref.model_id);
    try writer.print("}},\"source_generation\":{d},\"protocol\":", .{
        binding.source_generation,
    });
    try jsonString(writer, @tagName(binding.protocol));
    try writer.writeByte('}');
}

fn encodeInput(writer: *std.Io.Writer, input: []const u8) !void {
    try writer.writeAll("{\"kind\":\"text\",\"text\":");
    try jsonString(writer, input);
    try writer.writeByte('}');
}

fn encodeRecurrence(writer: *std.Io.Writer, recurrence: scheduled.Recurrence) !void {
    switch (recurrence) {
        .once => |once| try writer.print(
            "{{\"kind\":\"once\",\"at_unix_seconds\":{d}}}",
            .{once.at_unix_seconds},
        ),
        .interval => |interval| try writer.print(
            "{{\"kind\":\"interval\",\"start_at_unix_seconds\":{d},\"every_seconds\":{d}}}",
            .{ interval.start_at_unix_seconds, interval.every_seconds },
        ),
    }
}

fn decodeInput(wire: InputWire) Error![]const u8 {
    if (!std.mem.eql(u8, wire.kind, "text"))
        return error.ScheduledTaskStoreCorrupt;
    const text = wire.text orelse return error.ScheduledTaskStoreCorrupt;
    if (!validText(text)) return error.ScheduledTaskStoreCorrupt;
    return text;
}

fn decodeRecurrence(wire: RecurrenceWire) Error!scheduled.Recurrence {
    if (std.mem.eql(u8, wire.kind, "once")) {
        if (wire.start_at_unix_seconds != null or wire.every_seconds != null)
            return error.ScheduledTaskStoreCorrupt;
        const result: scheduled.Recurrence = .{ .once = .{
            .at_unix_seconds = wire.at_unix_seconds orelse
                return error.ScheduledTaskStoreCorrupt,
        } };
        result.validate() catch return error.ScheduledTaskStoreCorrupt;
        return result;
    }
    if (!std.mem.eql(u8, wire.kind, "interval") or
        wire.at_unix_seconds != null)
        return error.ScheduledTaskStoreCorrupt;
    const result: scheduled.Recurrence = .{ .interval = .{
        .start_at_unix_seconds = wire.start_at_unix_seconds orelse
            return error.ScheduledTaskStoreCorrupt,
        .every_seconds = wire.every_seconds orelse
            return error.ScheduledTaskStoreCorrupt,
    } };
    result.validate() catch return error.ScheduledTaskStoreCorrupt;
    return result;
}

fn decodeOccurrence(wire: OccurrenceWire) Error!scheduled.Occurrence {
    return .{
        .planned_at_unix_seconds = wire.planned_at_unix_seconds,
        .triggered_at_unix_seconds = wire.triggered_at_unix_seconds,
        .source = parseEnum(scheduled.OccurrenceSource, wire.source) orelse
            return error.ScheduledTaskStoreCorrupt,
        .result = parseEnum(scheduled.OccurrenceResult, wire.result) orelse
            return error.ScheduledTaskStoreCorrupt,
        .task_id = wire.task_id,
        .reason = if (wire.reason) |reason|
            parseEnum(scheduled.FailureReason, reason) orelse
                return error.ScheduledTaskStoreCorrupt
        else
            null,
        .task_outcome = if (wire.task_outcome) |outcome|
            parseEnum(scheduled.OccurrenceTaskOutcome, outcome) orelse
                return error.ScheduledTaskStoreCorrupt
        else
            null,
        .notification_sent = wire.notification_sent,
    };
}

fn jsonString(writer: *std.Io.Writer, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, writer);
}

fn parseEnum(comptime T: type, value: []const u8) ?T {
    return std.meta.stringToEnum(T, value);
}

fn validText(value: []const u8) bool {
    return value.len > 0 and std.unicode.utf8ValidateSlice(value);
}

pub const testing = if (builtin.is_test) struct {
    pub fn setRecoveryFault(store: *FileStore, fault: RecoveryFault) void {
        store.recovery_fault = fault;
    }
} else struct {};

test "scheduled task store round trips bounded occurrence history" {
    var store = try scheduled.Store.init(std.testing.allocator, .{
        .max_items = 4,
        .max_projection_bytes = 16 * 1024,
    });
    defer store.deinit();
    const id = try store.create(.{
        .title = "Daily brief",
        .binding = .{
            .model_ref = .{ .source_id = "metask:test", .model_id = "gpt-test" },
            .source_generation = 9,
            .protocol = .openai_chat_completions,
        },
        .permission_profile = .full_access,
        .input = "Summarize today's work",
        .recurrence = .{ .interval = .{
            .start_at_unix_seconds = 2_000,
            .every_seconds = 3_600,
        } },
    }, 1_000);
    const item = store.find(id).?;
    try store.markSubmitted(item, 2_000, 2_001, .timer, 42);
    try store.finalizeOccurrenceTask(item, 2_000, .timer, 42, .completed, null);
    try store.markSkipped(item, 5_600, 5_601, 42);
    try store.markSkipped(item, 9_200, 9_201, 0);
    const default_id = try store.create(.{
        .title = "Independent brief",
        .binding = .{
            .model_ref = .{ .source_id = "metask:test", .model_id = "gpt-test" },
            .source_generation = 9,
            .protocol = .openai_chat_completions,
        },
        .permission_profile = .approval_required,
        .input = "Summarize current work",
        .recurrence = .{ .once = .{ .at_unix_seconds = 3_000 } },
    }, 1_000);
    const default_item = store.find(default_id).?;
    try store.claim(default_item, 3_000, 3_001, .manual);
    try store.finalizeClaimRejected(
        default_item,
        3_000,
        .manual,
        .capacity_reached,
        84,
    );

    var output: [max_store_bytes]u8 = undefined;
    const bytes = try encode(&output, &store);
    try std.testing.expect(std.mem.startsWith(
        u8,
        bytes,
        "{\"schema_version\":1,",
    ));
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"kind\":\"current\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"model_ref\":") != null);
    var restored = try decode(std.testing.allocator, bytes, .{
        .max_items = 4,
        .max_projection_bytes = 16 * 1024,
    });
    defer restored.deinit();
    const restored_item = restored.find(id).?;
    try std.testing.expectEqual(@as(usize, 3), restored_item.occurrences().len);
    try std.testing.expectEqual(@as(u64, 42), restored_item.occurrences()[1].task_id);
    try std.testing.expectEqual(@as(u64, 0), restored_item.occurrences()[2].task_id);
    try std.testing.expectEqual(@as(u64, 42), restored_item.occurrences()[0].task_id);
    try std.testing.expectEqual(
        scheduled.OccurrenceTaskOutcome.completed,
        restored_item.occurrences()[0].task_outcome.?,
    );
    try std.testing.expect(restored_item.occurrences()[0].notification_sent);
    try std.testing.expectEqualStrings("Daily brief", restored_item.title);
    try std.testing.expectEqual(
        scheduled.PermissionProfile.full_access,
        restored_item.permission_profile,
    );
    try std.testing.expectEqual(
        @as(u64, 84),
        restored.find(default_id).?.occurrences()[0].task_id,
    );
    try std.testing.expectEqual(store.next_id, restored.next_id);
}

test "scheduled task store rejects unknown fields and revisions" {
    const limits: scheduled.Limits = .{
        .max_items = 2,
        .max_projection_bytes = 4096,
    };
    try std.testing.expectError(
        error.ScheduledTaskStoreCorrupt,
        decode(
            std.testing.allocator,
            "{\"schema_version\":3,\"next_id\":1,\"items\":[]}",
            limits,
        ),
    );
    try std.testing.expectError(
        error.ScheduledTaskStoreCorrupt,
        decode(
            std.testing.allocator,
            "{\"schema_version\":2,\"next_id\":2,\"items\":[{\"id\":1,\"epoch\":1,\"title\":\"Retired current binding\",\"binding\":{\"kind\":\"current\",\"model_ref\":{\"source_id\":\"metask:test\",\"model_id\":\"gpt-test\"},\"source_generation\":1,\"selection_revision\":1,\"protocol\":\"openai_chat_completions\",\"legacy_execution\":null},\"permission_profile\":\"approval_required\",\"input\":{\"kind\":\"text\",\"text\":\"inspect\"},\"recurrence\":{\"kind\":\"once\",\"at_unix_seconds\":2},\"enabled\":true,\"health\":\"ready\",\"failure_reason\":null,\"next_run_at_unix_seconds\":2,\"occurrences\":[]}]}",
            limits,
        ),
    );
    try std.testing.expectError(
        error.ScheduledTaskStoreCorrupt,
        decode(
            std.testing.allocator,
            "{\"schema_version\":1,\"next_id\":1,\"items\":[],\"extra\":true}",
            limits,
        ),
    );
    try std.testing.expectError(
        error.ScheduledTaskStoreCorrupt,
        decode(
            std.testing.allocator,
            "{\"schema_version\":1,\"next_id\":2,\"items\":[{\"id\":1,\"epoch\":1,\"title\":\"retired provider\",\"execution_generation\":1,\"execution_provider\":\"openai\",\"execution_model\":\"gpt-test\",\"permission_profile\":\"approval_required\",\"input\":{\"kind\":\"text\",\"text\":\"inspect\"},\"recurrence\":{\"kind\":\"once\",\"at_unix_seconds\":2},\"enabled\":true,\"health\":\"ready\",\"failure_reason\":null,\"next_run_at_unix_seconds\":2,\"occurrences\":[]}]}",
            limits,
        ),
    );
    try std.testing.expectError(
        error.ScheduledTaskStoreCorrupt,
        decode(
            std.testing.allocator,
            "{\"schema_version\":1,\"next_id\":2,\"items\":[{\"id\":1,\"epoch\":1,\"title\":\"missing profile\",\"execution_generation\":1,\"execution_protocol\":\"openai_chat_completions\",\"execution_model\":\"gpt-test\",\"input\":{\"kind\":\"text\",\"text\":\"inspect\"},\"recurrence\":{\"kind\":\"once\",\"at_unix_seconds\":2},\"enabled\":true,\"health\":\"ready\",\"failure_reason\":null,\"next_run_at_unix_seconds\":2,\"occurrences\":[]}]}",
            limits,
        ),
    );
    try std.testing.expectError(
        error.ScheduledTaskStoreCorrupt,
        decode(
            std.testing.allocator,
            "{\"schema_version\":1,\"next_id\":2,\"items\":[{\"id\":1,\"epoch\":1,\"title\":\"legacy\",\"workspace_id\":7,\"workspace_epoch\":3,\"execution_generation\":1,\"execution_protocol\":\"openai_chat_completions\",\"execution_model\":\"gpt-test\",\"input\":{\"kind\":\"text\",\"text\":\"legacy\"},\"recurrence\":{\"kind\":\"once\",\"at_unix_seconds\":2},\"enabled\":true,\"health\":\"ready\",\"failure_reason\":null,\"next_run_at_unix_seconds\":2,\"occurrences\":[]}]}",
            limits,
        ),
    );
    try std.testing.expectError(
        error.ScheduledTaskStoreCorrupt,
        decode(
            std.testing.allocator,
            "{\"schema_version\":1,\"next_id\":2,\"items\":[{\"id\":1,\"epoch\":1,\"title\":\"configured target\",\"target\":{\"kind\":\"default\"},\"execution_generation\":1,\"execution_protocol\":\"openai_chat_completions\",\"execution_model\":\"gpt-test\",\"input\":{\"kind\":\"text\",\"text\":\"inspect\"},\"recurrence\":{\"kind\":\"once\",\"at_unix_seconds\":2},\"enabled\":true,\"health\":\"ready\",\"failure_reason\":null,\"next_run_at_unix_seconds\":2,\"occurrences\":[]}]}",
            limits,
        ),
    );
    try std.testing.expectError(
        error.ScheduledTaskStoreCorrupt,
        decode(
            std.testing.allocator,
            "{\"schema_version\":1,\"next_id\":2,\"items\":[{\"id\":1,\"epoch\":1,\"title\":\"configured skill\",\"execution_generation\":1,\"execution_protocol\":\"openai_chat_completions\",\"execution_model\":\"gpt-test\",\"input\":{\"kind\":\"skill\",\"skill_id\":\"builtin.summary\",\"catalog_revision\":\"4\",\"argument_values\":[]},\"recurrence\":{\"kind\":\"once\",\"at_unix_seconds\":2},\"enabled\":true,\"health\":\"ready\",\"failure_reason\":null,\"next_run_at_unix_seconds\":2,\"occurrences\":[]}]}",
            limits,
        ),
    );
}

test "scheduled task store rejects retired schema 1 shape" {
    const retired =
        "{\"schema_version\":1,\"next_id\":8,\"items\":[{\"id\":7,\"epoch\":3,\"title\":\"Legacy schedule\",\"execution_generation\":19,\"execution_protocol\":\"anthropic_messages\",\"execution_model\":\"legacy-model\",\"permission_profile\":\"full_access\",\"input\":{\"kind\":\"text\",\"text\":\"inspect\"},\"recurrence\":{\"kind\":\"once\",\"at_unix_seconds\":200},\"enabled\":true,\"health\":\"ready\",\"failure_reason\":null,\"next_run_at_unix_seconds\":200,\"occurrences\":[]}]}";
    const limits: scheduled.Limits = .{
        .max_items = 2,
        .max_projection_bytes = 4096,
    };
    try std.testing.expectError(
        error.ScheduledTaskStoreCorrupt,
        decode(std.testing.allocator, retired, limits),
    );
}

test "scheduled task file store atomically replaces and restores bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file_store: FileStore = .{
        .io = std.testing.io,
        .dir = tmp.dir,
    };
    try file_store.commit(
        "{\"schema_version\":1,\"next_id\":1,\"items\":[]}",
    );
    try file_store.commit(
        "{\"schema_version\":1,\"next_id\":2,\"items\":[]}",
    );
    const restored = (try file_store.loadAlloc(std.testing.allocator)).?;
    defer std.testing.allocator.free(restored);
    try std.testing.expectEqualStrings(
        "{\"schema_version\":1,\"next_id\":2,\"items\":[]}",
        restored,
    );
}

test "scheduled task file store recovery quarantines the previous canonical bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file_store: FileStore = .{
        .io = std.testing.io,
        .dir = tmp.dir,
    };
    const previous = "{\"schema_version\":7,\"next_id\":1,\"items\":[]}";
    const replacement = "{\"schema_version\":1,\"next_id\":1,\"items\":[]}";
    try file_store.commit(previous);
    try file_store.recover(replacement);

    const restored = (try file_store.loadAlloc(std.testing.allocator)).?;
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
            ".scheduled-tasks.recovery.",
        )) {
            try std.testing.expect(quarantine_name == null);
            quarantine_name = try std.testing.allocator.dupe(u8, entry.name);
        }
    }
    const name = quarantine_name orelse return error.TestExpectedEqual;
    try std.testing.expect(std.mem.endsWith(u8, name, ".quarantine"));
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

test "scheduled task recovery restores canonical after definite install failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file_store: FileStore = .{
        .io = std.testing.io,
        .dir = tmp.dir,
    };
    const previous = "{\"schema_version\":2,\"next_id\":1,\"items\":[]}";
    try file_store.commit(previous);
    testing.setRecoveryFault(&file_store, .install_failed);
    try std.testing.expectError(
        error.WriteFailed,
        file_store.recover("{\"schema_version\":1,\"next_id\":1,\"items\":[]}"),
    );
    const restored = (try file_store.loadAlloc(std.testing.allocator)).?;
    defer std.testing.allocator.free(restored);
    try std.testing.expectEqualStrings(previous, restored);
}

test "interrupted scheduled task recovery never appears as first launch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file_store: FileStore = .{
        .io = std.testing.io,
        .dir = tmp.dir,
    };
    const replacement = "{\"schema_version\":1,\"next_id\":1,\"items\":[]}";
    try file_store.commit("{\"schema_version\":2,\"next_id\":1,\"items\":[]}");
    testing.setRecoveryFault(&file_store, .interrupted_after_quarantine);
    try std.testing.expectError(
        error.PersistenceOutcomeUnknown,
        file_store.recover(replacement),
    );
    try std.testing.expectError(
        error.ReadFailed,
        file_store.loadAlloc(std.testing.allocator),
    );

    testing.setRecoveryFault(&file_store, .none);
    try file_store.recover(replacement);
    const restored = (try file_store.loadAlloc(std.testing.allocator)).?;
    defer std.testing.allocator.free(restored);
    try std.testing.expectEqualStrings(replacement, restored);
}

test "indeterminate recovery install remains fail closed with a canonical file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file_store: FileStore = .{
        .io = std.testing.io,
        .dir = tmp.dir,
    };
    const replacement = "{\"schema_version\":1,\"next_id\":1,\"items\":[]}";
    try file_store.commit("{\"schema_version\":2,\"next_id\":1,\"items\":[]}");
    testing.setRecoveryFault(&file_store, .interrupted_after_install);
    try std.testing.expectError(
        error.PersistenceOutcomeUnknown,
        file_store.recover(replacement),
    );
    try std.testing.expectError(
        error.ReadFailed,
        file_store.loadAlloc(std.testing.allocator),
    );

    testing.setRecoveryFault(&file_store, .none);
    try file_store.recover(replacement);
    const restored = (try file_store.loadAlloc(std.testing.allocator)).?;
    defer std.testing.allocator.free(restored);
    try std.testing.expectEqualStrings(replacement, restored);
}

test "orphan recovery files without an exact pending marker do not block load" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file_store: FileStore = .{
        .io = std.testing.io,
        .dir = tmp.dir,
    };
    const canonical = "{\"schema_version\":1,\"next_id\":1,\"items\":[]}";
    try file_store.commit(canonical);
    inline for (.{
        ".scheduled-tasks.recovery.0123456789abcdef.tmp",
        ".scheduled-tasks.recovery.0123456789abcdef.bak",
        ".scheduled-tasks.recovery.not-owned.pending",
    }) |name| {
        var artifact = try tmp.dir.createFile(
            std.testing.io,
            name,
            .{ .exclusive = true },
        );
        artifact.close(std.testing.io);
    }

    const restored = (try file_store.loadAlloc(std.testing.allocator)).?;
    defer std.testing.allocator.free(restored);
    try std.testing.expectEqualStrings(canonical, restored);
}

test "recovery rollback failure keeps restart fail closed and preserves original bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file_store: FileStore = .{ .io = std.testing.io, .dir = tmp.dir };
    const previous = "original interrupted canonical";
    const replacement = "{\"schema_version\":1,\"next_id\":1,\"items\":[]}";
    try file_store.commit(previous);
    testing.setRecoveryFault(&file_store, .restore_failed);
    try std.testing.expectError(error.PersistenceOutcomeUnknown, file_store.recover(replacement));
    try std.testing.expectError(error.ReadFailed, file_store.loadAlloc(std.testing.allocator));
    testing.setRecoveryFault(&file_store, .none);
    try file_store.recover(replacement);
    const restored = (try file_store.loadAlloc(std.testing.allocator)).?;
    defer std.testing.allocator.free(restored);
    try std.testing.expectEqualStrings(replacement, restored);
    var storage: [96]u8 = undefined;
    const quarantine_name = (try file_store.findRecoveryArtifact(".quarantine", &storage, null)).?;
    const original = try tmp.dir.readFileAlloc(std.testing.io, quarantine_name, std.testing.allocator, .limited(max_store_bytes));
    defer std.testing.allocator.free(original);
    try std.testing.expectEqualStrings(previous, original);
}

test "a failed recovery retry cannot erase the last interrupted recovery marker" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file_store: FileStore = .{ .io = std.testing.io, .dir = tmp.dir };
    const replacement = "{\"schema_version\":1,\"next_id\":1,\"items\":[]}";
    try file_store.commit("interrupted original");
    testing.setRecoveryFault(&file_store, .interrupted_after_quarantine);
    try std.testing.expectError(error.PersistenceOutcomeUnknown, file_store.recover(replacement));
    testing.setRecoveryFault(&file_store, .stage_failed);
    try std.testing.expectError(error.WriteFailed, file_store.recover(replacement));
    try std.testing.expectError(error.ReadFailed, file_store.loadAlloc(std.testing.allocator));
    testing.setRecoveryFault(&file_store, .none);
    try file_store.recover(replacement);
    const restored = (try file_store.loadAlloc(std.testing.allocator)).?;
    defer std.testing.allocator.free(restored);
    try std.testing.expectEqualStrings(replacement, restored);
}

test "Schedule decoder rejects cursors outside the saved recurrence" {
    var store = try scheduled.Store.init(std.testing.allocator, .{ .max_items = 1, .max_projection_bytes = 8192 });
    defer store.deinit();
    const id = try store.create(.{
        .title = "cursor",
        .binding = .{ .model_ref = .{ .source_id = "metask:test", .model_id = "model" }, .source_generation = 1, .protocol = .anthropic_messages },
        .permission_profile = .approval_required,
        .input = "inspect",
        .recurrence = .{ .once = .{ .at_unix_seconds = 200 } },
    }, 100);
    const item = store.find(id).?;
    var output: [max_store_bytes]u8 = undefined;
    item.next_run_at_unix_seconds = 100;
    try std.testing.expectError(error.ScheduledTaskStoreCorrupt, decode(std.testing.allocator, try encode(&output, &store), .{ .max_items = 1, .max_projection_bytes = 8192 }));
    item.recurrence = .{ .interval = .{ .start_at_unix_seconds = 200, .every_seconds = 60 } };
    for ([_]u64{ 0, 100, 201, 259 }) |cursor| {
        item.next_run_at_unix_seconds = cursor;
        try std.testing.expectError(error.ScheduledTaskStoreCorrupt, decode(std.testing.allocator, try encode(&output, &store), .{ .max_items = 1, .max_projection_bytes = 8192 }));
    }
    item.next_run_at_unix_seconds = 260;
    const bytes = try encode(&output, &store);
    const Decode = struct {
        fn check(allocator: std.mem.Allocator, input: []const u8) !void {
            var restored = try decode(allocator, input, .{ .max_items = 1, .max_projection_bytes = 8192 });
            defer restored.deinit();
            try std.testing.expectEqual(@as(?u64, 260), restored.find(1).?.next_run_at_unix_seconds);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Decode.check, .{bytes});
}

test "timer consumption survives history eviction and a paused-store restart" {
    for ([_]scheduled.Recurrence{
        .{ .interval = .{ .start_at_unix_seconds = 200, .every_seconds = 60 } },
    }) |recurrence| {
        var store = try scheduled.Store.init(std.testing.allocator, .{ .max_items = 1, .max_projection_bytes = 8192 });
        defer store.deinit();
        const id = try store.create(.{
            .title = "boundary",
            .binding = .{ .model_ref = .{ .source_id = "metask:test", .model_id = "model" }, .source_generation = 1, .protocol = .anthropic_messages },
            .permission_profile = .approval_required,
            .input = "inspect",
            .recurrence = recurrence,
        }, 100);
        const item = store.find(id).?;
        try store.markSubmitted(item, 200, 200, .timer, 42);
        try store.finalizeOccurrenceTask(item, 200, .timer, 42, .completed, null);
        for (0..scheduled.max_occurrence_history) |index| {
            const planned = 201 + index;
            const task_id = 100 + index;
            try store.markSubmitted(item, planned, planned, .manual, task_id);
            try store.finalizeOccurrenceTask(item, planned, .manual, task_id, .completed, null);
        }
        for (item.occurrences()) |occurrence| try std.testing.expectEqual(scheduled.OccurrenceSource.manual, occurrence.source);
        try store.setEnabled(id, 1, false, 300);
        var output: [max_store_bytes]u8 = undefined;
        var restored = try decode(std.testing.allocator, try encode(&output, &store), .{ .max_items = 1, .max_projection_bytes = 8192 });
        defer restored.deinit();
        try std.testing.expectEqual(@as(?u64, 200), restored.find(id).?.last_timer_planned_at_unix_seconds);
        try restored.setEnabled(id, 2, true, 100);
        try std.testing.expectEqual(try recurrence.firstStrictlyAfter(200), restored.find(id).?.next_run_at_unix_seconds);
    }
}

test "legacy timer facts repair a rewound cursor without discarding definitions" {
    for ([_]scheduled.Recurrence{
        .{ .once = .{ .at_unix_seconds = 200 } },
        .{ .interval = .{ .start_at_unix_seconds = 200, .every_seconds = 60 } },
    }) |recurrence| {
        var store = try scheduled.Store.init(std.testing.allocator, .{ .max_items = 1, .max_projection_bytes = 8192 });
        defer store.deinit();
        const id = try store.create(.{
            .title = "legacy",
            .binding = .{ .model_ref = .{ .source_id = "metask:test", .model_id = "model" }, .source_generation = 1, .protocol = .anthropic_messages },
            .permission_profile = .approval_required,
            .input = "inspect",
            .recurrence = recurrence,
        }, 100);
        const item = store.find(id).?;
        try store.markSubmitted(item, 200, 200, .timer, 42);
        try store.finalizeOccurrenceTask(item, 200, .timer, 42, .completed, null);
        // A schema-1 record written by the previous edit/resume path.
        item.last_timer_planned_at_unix_seconds = null;
        item.enabled = true;
        item.health = .ready;
        item.next_run_at_unix_seconds = 200;
        var output: [max_store_bytes]u8 = undefined;
        var restored = try decode(std.testing.allocator, try encode(&output, &store), .{ .max_items = 1, .max_projection_bytes = 8192 });
        defer restored.deinit();
        const copy = restored.find(id).?;
        try std.testing.expectEqual(@as(?u64, 200), copy.last_timer_planned_at_unix_seconds);
        try std.testing.expectEqual(try recurrence.firstStrictlyAfter(200), copy.next_run_at_unix_seconds);
        try std.testing.expectEqualStrings("legacy", copy.title);
        try std.testing.expectEqual(@as(usize, 1), copy.occurrence_count);
        // Explicit new-format boundaries must not contradict saved state.
        item.last_timer_planned_at_unix_seconds = 200;
        try std.testing.expectError(error.ScheduledTaskStoreCorrupt, decode(std.testing.allocator, try encode(&output, &store), .{ .max_items = 1, .max_projection_bytes = 8192 }));
        item.last_timer_planned_at_unix_seconds = 199;
        item.next_run_at_unix_seconds = null;
        item.enabled = false;
        item.health = .paused;
        try std.testing.expectError(error.ScheduledTaskStoreCorrupt, decode(std.testing.allocator, try encode(&output, &store), .{ .max_items = 1, .max_projection_bytes = 8192 }));
    }
}
