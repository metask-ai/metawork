//! Scheduled Task codec and concrete product-data store.

const std = @import("std");
const builtin = @import("builtin");
const scheduled = @import("product_schedule_state");

pub const schema_version: u8 = 2;
pub const legacy_schema_version: u8 = 1;
pub const max_store_bytes: usize = 256 * 1024;

pub const Error = scheduled.Error || error{
    ScheduledTaskStoreEmpty,
    ScheduledTaskStoreTooLarge,
    ScheduledTaskStoreCorrupt,
    ScheduledTaskStoreEncodeFailed,
};

pub const file_name = "scheduled-tasks.json";

pub const FileStoreError = std.mem.Allocator.Error || error{
    DirectoryUnavailable,
    ReadFailed,
    WriteFailed,
    PersistenceOutcomeUnknown,
};

pub const FileStore = struct {
    io: std.Io,
    dir: std.Io.Dir,

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

    pub fn matchesCanonical(
        self: *FileStore,
        expected: []const u8,
    ) bool {
        if (expected.len == 0 or expected.len > max_store_bytes) return false;
        var file = self.dir.openFile(
            self.io,
            file_name,
            .{ .follow_symlinks = false, .resolve_beneath = true },
        ) catch return false;
        if (builtin.os.tag == .windows) file.flags.nonblocking = true;
        defer file.close(self.io);
        const length = file.length(self.io) catch return false;
        if (length != expected.len) return false;
        var buffer: [4096]u8 = undefined;
        var offset: usize = 0;
        while (offset < expected.len) {
            const count = @min(buffer.len, expected.len - offset);
            const read = file.readPositionalAll(
                self.io,
                buffer[0..count],
                offset,
            ) catch return false;
            if (read != count or
                !std.mem.eql(u8, buffer[0..count], expected[offset .. offset + count]))
                return false;
            offset += count;
        }
        return true;
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

    /// Hard-resets the current canonical store and installs Product-owned
    /// canonical bytes. Retired formats are deliberately not retained.
    pub fn recover(
        self: *FileStore,
        bytes: []const u8,
    ) FileStoreError!void {
        if (bytes.len == 0 or bytes.len > max_store_bytes)
            return error.WriteFailed;
        self.dir.deleteFile(self.io, file_name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return error.WriteFailed,
        };
        return self.commit(bytes);
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
};

const BindingWire = struct {
    kind: []const u8,
    model_ref: ?ModelRefWire,
    source_generation: ?u64,
    selection_revision: ?u64,
    protocol: ?[]const u8,
    legacy_execution: ?LegacyExecutionWire,
};

const ModelRefWire = struct {
    source_id: []const u8,
    model_id: []const u8,
};

const LegacyExecutionWire = struct {
    generation: u64,
    protocol: []const u8,
    model: []const u8,
};

const LegacyStoreWire = struct {
    schema_version: u8,
    next_id: u64,
    items: []LegacyItemWire,
};

const LegacyItemWire = struct {
    id: u64,
    epoch: u64,
    title: []const u8,
    execution_generation: u64,
    execution_protocol: []const u8,
    execution_model: []const u8,
    permission_profile: []const u8,
    input: InputWire,
    recurrence: RecurrenceWire,
    enabled: bool,
    health: []const u8,
    failure_reason: ?[]const u8,
    next_run_at_unix_seconds: ?u64,
    occurrences: []OccurrenceWire,
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

pub const BootstrapDecode = union(enum) {
    current: scheduled.Store,
    migrated: scheduled.Store,
};

pub fn decodeForBootstrap(
    allocator: std.mem.Allocator,
    input: []const u8,
    limits: scheduled.Limits,
) Error!BootstrapDecode {
    try validateStoreBytes(input);
    if (decodeCurrent(allocator, input, limits)) |store|
        return .{ .current = store }
    else |_| {}
    return .{ .migrated = try decodeLegacyForMigration(allocator, input, limits) };
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
    ) catch return error.ScheduledTaskStoreCorrupt;
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
            .occurrences = occurrences[0..wire.occurrences.len],
        }) catch return error.ScheduledTaskStoreCorrupt;
    }
    store.restoreNextId(parsed.value.next_id) catch
        return error.ScheduledTaskStoreCorrupt;
    return store;
}

fn decodeLegacyForMigration(
    allocator: std.mem.Allocator,
    input: []const u8,
    limits: scheduled.Limits,
) Error!scheduled.Store {
    var parsed = std.json.parseFromSlice(
        LegacyStoreWire,
        allocator,
        input,
        .{ .ignore_unknown_fields = false },
    ) catch return error.ScheduledTaskStoreCorrupt;
    defer parsed.deinit();
    if (parsed.value.schema_version != legacy_schema_version or
        parsed.value.next_id == 0 or
        parsed.value.items.len > limits.max_items)
        return error.ScheduledTaskStoreCorrupt;

    var store = try scheduled.Store.init(allocator, limits);
    errdefer store.deinit();
    for (parsed.value.items) |wire| {
        var occurrences: [scheduled.max_occurrence_history]scheduled.Occurrence = undefined;
        if (wire.occurrences.len > occurrences.len)
            return error.ScheduledTaskStoreCorrupt;
        for (wire.occurrences, 0..) |occurrence, index| {
            occurrences[index] = try decodeOccurrence(occurrence);
            if (occurrences[index].reason == .binding_migration_required)
                return error.ScheduledTaskStoreCorrupt;
        }
        const protocol = parseEnum(
            scheduled.Protocol,
            wire.execution_protocol,
        ) orelse return error.ScheduledTaskStoreCorrupt;
        const permission_profile = parseEnum(
            scheduled.PermissionProfile,
            wire.permission_profile,
        ) orelse return error.ScheduledTaskStoreCorrupt;
        const prior_health = parseEnum(scheduled.Health, wire.health) orelse
            return error.ScheduledTaskStoreCorrupt;
        const prior_reason = if (wire.failure_reason) |reason|
            parseEnum(scheduled.FailureReason, reason) orelse
                return error.ScheduledTaskStoreCorrupt
        else
            null;
        if (prior_reason == .binding_migration_required or
            !validLegacyState(
                wire.enabled,
                prior_health,
                prior_reason,
                wire.next_run_at_unix_seconds,
            ) or
            !validText(wire.title) or !validText(wire.execution_model) or
            wire.execution_generation == 0)
            return error.ScheduledTaskStoreCorrupt;
        store.restoreItem(.{
            .id = wire.id,
            .epoch = wire.epoch,
            .definition = .{
                .title = wire.title,
                .binding = .{ .migration_required = .{
                    .execution_generation = wire.execution_generation,
                    .protocol = protocol,
                    .model = wire.execution_model,
                } },
                .permission_profile = permission_profile,
                .input = try decodeInput(wire.input),
                .recurrence = try decodeRecurrence(wire.recurrence),
            },
            .enabled = false,
            .health = .needs_attention,
            .failure_reason = .binding_migration_required,
            .next_run_at_unix_seconds = null,
            .occurrences = occurrences[0..wire.occurrences.len],
        }) catch return error.ScheduledTaskStoreCorrupt;
    }
    store.restoreNextId(parsed.value.next_id) catch
        return error.ScheduledTaskStoreCorrupt;
    return store;
}

fn decodeBinding(wire: BindingWire) Error!scheduled.Binding {
    if (std.mem.eql(u8, wire.kind, "current")) {
        if (wire.legacy_execution != null) return error.ScheduledTaskStoreCorrupt;
        const model_ref = wire.model_ref orelse return error.ScheduledTaskStoreCorrupt;
        return .{ .current = .{
            .model_ref = .{
                .source_id = model_ref.source_id,
                .model_id = model_ref.model_id,
            },
            .source_generation = wire.source_generation orelse
                return error.ScheduledTaskStoreCorrupt,
            .selection_revision = wire.selection_revision orelse
                return error.ScheduledTaskStoreCorrupt,
            .protocol = parseEnum(
                scheduled.Protocol,
                wire.protocol orelse return error.ScheduledTaskStoreCorrupt,
            ) orelse return error.ScheduledTaskStoreCorrupt,
        } };
    }
    if (!std.mem.eql(u8, wire.kind, "migration_required") or
        wire.model_ref != null or wire.source_generation != null or
        wire.selection_revision != null or wire.protocol != null)
        return error.ScheduledTaskStoreCorrupt;
    const legacy = wire.legacy_execution orelse
        return error.ScheduledTaskStoreCorrupt;
    return .{ .migration_required = .{
        .execution_generation = legacy.generation,
        .protocol = parseEnum(scheduled.Protocol, legacy.protocol) orelse
            return error.ScheduledTaskStoreCorrupt,
        .model = legacy.model,
    } };
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
    switch (binding) {
        .current => |current| {
            try writer.writeAll("{\"kind\":\"current\",\"model_ref\":{\"source_id\":");
            try jsonString(writer, current.model_ref.source_id);
            try writer.writeAll(",\"model_id\":");
            try jsonString(writer, current.model_ref.model_id);
            try writer.print("}},\"source_generation\":{d},\"selection_revision\":{d},\"protocol\":", .{
                current.source_generation,
                current.selection_revision,
            });
            try jsonString(writer, @tagName(current.protocol));
            try writer.writeAll(",\"legacy_execution\":null}");
        },
        .migration_required => |legacy| {
            try writer.writeAll("{\"kind\":\"migration_required\",\"model_ref\":null,\"source_generation\":null,\"selection_revision\":null,\"protocol\":null,\"legacy_execution\":{");
            try writer.print("\"generation\":{d},\"protocol\":", .{legacy.execution_generation});
            try jsonString(writer, @tagName(legacy.protocol));
            try writer.writeAll(",\"model\":");
            try jsonString(writer, legacy.model);
            try writer.writeAll("}}");
        },
    }
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

fn validLegacyState(
    enabled: bool,
    health: scheduled.Health,
    reason: ?scheduled.FailureReason,
    next_run_at_unix_seconds: ?u64,
) bool {
    if (enabled)
        return health == .ready and reason == null and
            next_run_at_unix_seconds != null;
    return switch (health) {
        .paused => reason == null and next_run_at_unix_seconds == null,
        .needs_attention => reason != null and next_run_at_unix_seconds == null,
        .completed => reason == null and next_run_at_unix_seconds == null,
        .ready => false,
    };
}

test "scheduled task store round trips bounded occurrence history" {
    var store = try scheduled.Store.init(std.testing.allocator, .{
        .max_items = 4,
        .max_projection_bytes = 16 * 1024,
    });
    defer store.deinit();
    const id = try store.create(.{
        .title = "Daily brief",
        .binding = .{ .current = .{
            .model_ref = .{ .source_id = "metask:test", .model_id = "gpt-test" },
            .source_generation = 9,
            .selection_revision = 11,
            .protocol = .openai_chat_completions,
        } },
        .permission_profile = .full_access,
        .input = "Summarize today's work",
        .recurrence = .{ .interval = .{
            .start_at_unix_seconds = 2_000,
            .every_seconds = 3_600,
        } },
    }, 1_000);
    const item = store.find(id).?;
    try store.markSubmitted(item, 2_000, 2_001, .timer, 42);
    try store.finalizeOccurrenceTask(item, 2_000, .timer, .completed, null);
    const default_id = try store.create(.{
        .title = "Independent brief",
        .binding = .{ .current = .{
            .model_ref = .{ .source_id = "metask:test", .model_id = "gpt-test" },
            .source_generation = 9,
            .selection_revision = 11,
            .protocol = .openai_chat_completions,
        } },
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
    var restored = try decode(std.testing.allocator, bytes, .{
        .max_items = 4,
        .max_projection_bytes = 16 * 1024,
    });
    defer restored.deinit();
    const restored_item = restored.find(id).?;
    try std.testing.expectEqual(@as(usize, 1), restored_item.occurrences().len);
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

test "schema 1 migration preserves legacy facts and writes strict schema 2" {
    const legacy =
        "{\"schema_version\":1,\"next_id\":8,\"items\":[{\"id\":7,\"epoch\":3,\"title\":\"Legacy schedule\",\"execution_generation\":19,\"execution_protocol\":\"anthropic_messages\",\"execution_model\":\"legacy-model\",\"permission_profile\":\"full_access\",\"input\":{\"kind\":\"text\",\"text\":\"inspect\"},\"recurrence\":{\"kind\":\"once\",\"at_unix_seconds\":200},\"enabled\":true,\"health\":\"ready\",\"failure_reason\":null,\"next_run_at_unix_seconds\":200,\"occurrences\":[]}]}";
    const limits: scheduled.Limits = .{
        .max_items = 2,
        .max_projection_bytes = 4096,
    };
    try std.testing.expectError(
        error.ScheduledTaskStoreCorrupt,
        decode(std.testing.allocator, legacy, limits),
    );
    var migrated = switch (try decodeForBootstrap(
        std.testing.allocator,
        legacy,
        limits,
    )) {
        .migrated => |store| store,
        .current => return error.TestUnexpectedResult,
    };
    defer migrated.deinit();
    const item = migrated.find(7).?;
    try std.testing.expect(!item.enabled);
    try std.testing.expectEqual(scheduled.Health.needs_attention, item.health);
    try std.testing.expectEqual(
        scheduled.FailureReason.binding_migration_required,
        item.failure_reason.?,
    );
    switch (item.bindingView()) {
        .migration_required => |binding| {
            try std.testing.expectEqual(@as(u64, 19), binding.execution_generation);
            try std.testing.expectEqualStrings("legacy-model", binding.model);
            try std.testing.expectEqual(scheduled.Protocol.anthropic_messages, binding.protocol);
        },
        .current => return error.TestUnexpectedResult,
    }

    var output: [max_store_bytes]u8 = undefined;
    const bytes = try encode(&output, &migrated);
    try std.testing.expect(std.mem.startsWith(u8, bytes, "{\"schema_version\":2,"));
    var round_trip = try decode(std.testing.allocator, bytes, limits);
    defer round_trip.deinit();
    try std.testing.expectEqual(
        scheduled.FailureReason.binding_migration_required,
        round_trip.find(7).?.failure_reason.?,
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

test "scheduled task file store recovery hard-resets the previous canonical bytes" {
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
    var files: usize = 0;
    while (try iterator.next(std.testing.io)) |entry| {
        if (entry.kind != .file) continue;
        files += 1;
        try std.testing.expectEqualStrings(file_name, entry.name);
    }
    try std.testing.expectEqual(@as(usize, 1), files);
}
