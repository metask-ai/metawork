const std = @import("std");
const builtin = @import("builtin");
const scheduled = @import("workbench_scheduled_tasks");

pub const schema_version: u8 = 1;
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
    target: TargetWire,
    execution_generation: u64,
    execution_provider: []const u8,
    execution_model: []const u8,
    input: InputWire,
    recurrence: RecurrenceWire,
    enabled: bool,
    health: []const u8,
    failure_reason: ?[]const u8,
    next_run_at_unix_seconds: ?u64,
    occurrences: []OccurrenceWire,
};

const TargetWire = struct {
    kind: []const u8,
    workspace_id: ?u64 = null,
    workspace_epoch: ?u64 = null,
};

const InputWire = struct {
    kind: []const u8,
    text: ?[]const u8 = null,
    skill_id: ?[]const u8 = null,
    catalog_revision: ?[]const u8 = null,
    argument_values: ?[][]const u8 = null,
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
    if (input.len == 0) return error.ScheduledTaskStoreEmpty;
    if (input.len > max_store_bytes)
        return error.ScheduledTaskStoreTooLarge;
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
        const target = try decodeTarget(wire.target);
        if (!validText(wire.title) or !validText(wire.execution_model))
            return error.ScheduledTaskStoreCorrupt;
        store.restoreItem(.{
            .id = wire.id,
            .epoch = wire.epoch,
            .definition = .{
                .title = wire.title,
                .target = target,
                .execution_generation = wire.execution_generation,
                .execution_provider = parseEnum(
                    scheduled.Provider,
                    wire.execution_provider,
                ) orelse return error.ScheduledTaskStoreCorrupt,
                .execution_model = wire.execution_model,
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

fn encodeItem(writer: *std.Io.Writer, item: *const scheduled.Item) !void {
    try writer.print(
        "{{\"id\":{d},\"epoch\":{d},\"title\":",
        .{ item.id, item.epoch },
    );
    try jsonString(writer, item.title);
    try writer.writeAll(",\"target\":");
    try encodeTarget(writer, item.target);
    try writer.print(
        ",\"execution_generation\":{d},\"execution_provider\":",
        .{item.execution_generation},
    );
    try jsonString(writer, @tagName(item.execution_provider));
    try writer.writeAll(",\"execution_model\":");
    try jsonString(writer, item.execution_model);
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

fn encodeTarget(writer: *std.Io.Writer, target: scheduled.Target) !void {
    switch (target) {
        .default => try writer.writeAll("{\"kind\":\"default\"}"),
        .explicit => |explicit| try writer.print(
            "{{\"kind\":\"explicit\",\"workspace_id\":{d},\"workspace_epoch\":{d}}}",
            .{ explicit.workspace_id, explicit.workspace_epoch },
        ),
    }
}

fn decodeTarget(wire: TargetWire) Error!scheduled.Target {
    if (std.mem.eql(u8, wire.kind, "default")) {
        if (wire.workspace_id != null or wire.workspace_epoch != null)
            return error.ScheduledTaskStoreCorrupt;
        return .default;
    }
    if (!std.mem.eql(u8, wire.kind, "explicit"))
        return error.ScheduledTaskStoreCorrupt;
    const workspace_id = wire.workspace_id orelse
        return error.ScheduledTaskStoreCorrupt;
    const workspace_epoch = wire.workspace_epoch orelse
        return error.ScheduledTaskStoreCorrupt;
    if (workspace_id == 0 or workspace_epoch == 0)
        return error.ScheduledTaskStoreCorrupt;
    return .{ .explicit = .{
        .workspace_id = workspace_id,
        .workspace_epoch = workspace_epoch,
    } };
}

fn encodeInput(writer: *std.Io.Writer, input: scheduled.Input) !void {
    switch (input) {
        .text => |text| {
            try writer.writeAll("{\"kind\":\"text\",\"text\":");
            try jsonString(writer, text);
            try writer.writeByte('}');
        },
        .skill => |skill| {
            try writer.writeAll("{\"kind\":\"skill\",\"skill_id\":");
            try jsonString(writer, skill.skill_id);
            try writer.writeAll(",\"catalog_revision\":");
            try jsonString(writer, skill.catalog_revision);
            try writer.writeAll(",\"argument_values\":[");
            for (skill.argument_values, 0..) |value, index| {
                if (index != 0) try writer.writeByte(',');
                try jsonString(writer, value);
            }
            try writer.writeAll("]}");
        },
    }
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

fn decodeInput(wire: InputWire) Error!scheduled.Input {
    if (std.mem.eql(u8, wire.kind, "text")) {
        if (wire.skill_id != null or wire.catalog_revision != null or
            wire.argument_values != null)
            return error.ScheduledTaskStoreCorrupt;
        const text = wire.text orelse return error.ScheduledTaskStoreCorrupt;
        if (!validText(text)) return error.ScheduledTaskStoreCorrupt;
        return .{ .text = text };
    }
    if (!std.mem.eql(u8, wire.kind, "skill") or wire.text != null)
        return error.ScheduledTaskStoreCorrupt;
    const skill_id = wire.skill_id orelse
        return error.ScheduledTaskStoreCorrupt;
    const revision = wire.catalog_revision orelse
        return error.ScheduledTaskStoreCorrupt;
    const arguments = wire.argument_values orelse
        return error.ScheduledTaskStoreCorrupt;
    if (!validText(skill_id) or !validText(revision))
        return error.ScheduledTaskStoreCorrupt;
    for (arguments) |value| if (!std.unicode.utf8ValidateSlice(value))
        return error.ScheduledTaskStoreCorrupt;
    return .{ .skill = .{
        .skill_id = skill_id,
        .catalog_revision = revision,
        .argument_values = arguments,
    } };
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

test "scheduled task store round trips bounded occurrence history" {
    var store = try scheduled.Store.init(std.testing.allocator, .{
        .max_items = 4,
        .max_projection_bytes = 16 * 1024,
    });
    defer store.deinit();
    const id = try store.create(.{
        .title = "Daily brief",
        .target = .{ .explicit = .{
            .workspace_id = 7,
            .workspace_epoch = 3,
        } },
        .execution_generation = 9,
        .execution_provider = .openai,
        .execution_model = "gpt-test",
        .input = .{ .text = "Summarize today's work" },
        .recurrence = .{ .interval = .{
            .start_at_unix_seconds = 2_000,
            .every_seconds = 3_600,
        } },
    }, 1_000);
    const item = store.find(id).?;
    try store.markSubmitted(item, 2_000, 2_001, .timer, 42);
    try store.finalizeOccurrenceTask(item, 2_000, .timer, .completed);
    const default_id = try store.create(.{
        .title = "Independent brief",
        .target = .default,
        .execution_generation = 9,
        .execution_provider = .openai,
        .execution_model = "gpt-test",
        .input = .{ .text = "Summarize current work" },
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
    try std.testing.expectEqualDeep(
        scheduled.Target{ .explicit = .{
            .workspace_id = 7,
            .workspace_epoch = 3,
        } },
        restored_item.target,
    );
    switch (restored.find(default_id).?.target) {
        .default => {},
        .explicit => return error.TestUnexpectedResult,
    }
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
            "{\"schema_version\":2,\"next_id\":1,\"items\":[]}",
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
            "{\"schema_version\":1,\"next_id\":2,\"items\":[{\"id\":1,\"epoch\":1,\"title\":\"legacy\",\"workspace_id\":7,\"workspace_epoch\":3,\"execution_generation\":1,\"execution_provider\":\"openai\",\"execution_model\":\"gpt-test\",\"input\":{\"kind\":\"text\",\"text\":\"legacy\"},\"recurrence\":{\"kind\":\"once\",\"at_unix_seconds\":2},\"enabled\":true,\"health\":\"ready\",\"failure_reason\":null,\"next_run_at_unix_seconds\":2,\"occurrences\":[]}]}",
            limits,
        ),
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
