//! Workbench-owned durable Skill enablement policy for exact Manual Workspaces.

const std = @import("std");
const builtin = @import("builtin");

pub const schema_version: u8 = 1;
pub const file_name = "skill-enablement.json";
pub const max_store_bytes: usize = 512 * 1024;

pub const Limits = struct {
    max_workspaces: usize,
    max_disabled_skill_ids: usize,
    max_skill_id_bytes: usize,
};

pub const Error = std.mem.Allocator.Error || error{
    InvalidLimits,
    InvalidWorkspace,
    InvalidSkillId,
    DuplicateWorkspace,
    DuplicateSkillId,
    WorkspaceCapacity,
    SkillCapacity,
    RevisionMismatch,
    RevisionExhausted,
    StoreEmpty,
    StoreTooLarge,
    StoreCorrupt,
    StoreEncodeFailed,
};

pub const FileStoreError = std.mem.Allocator.Error || error{
    DirectoryUnavailable,
    ReadFailed,
    WriteFailed,
    PersistenceOutcomeUnknown,
};

pub const WorkspaceIdentity = struct {
    workspace_id: u64,
    workspace_epoch: u64,

    pub fn eql(left: WorkspaceIdentity, right: WorkspaceIdentity) bool {
        return left.workspace_id == right.workspace_id and
            left.workspace_epoch == right.workspace_epoch;
    }
};

pub const Mutation = struct {
    identity: WorkspaceIdentity,
    skill_id: []const u8,
    enabled: bool,
    expected_revision: u64,
};

pub const WorkspacePolicy = struct {
    identity: WorkspaceIdentity,
    selection_revision: u64,
    disabled_skill_ids: std.ArrayList([]u8) = .empty,

    fn deinit(self: *WorkspacePolicy, allocator: std.mem.Allocator) void {
        for (self.disabled_skill_ids.items) |skill_id| allocator.free(skill_id);
        self.disabled_skill_ids.deinit(allocator);
        self.* = undefined;
    }
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    limits: Limits,
    policies: std.ArrayList(WorkspacePolicy) = .empty,

    pub fn init(allocator: std.mem.Allocator, limits: Limits) Error!Store {
        if (!validLimits(limits)) return error.InvalidLimits;
        return .{ .allocator = allocator, .limits = limits };
    }

    pub fn deinit(self: *Store) void {
        for (self.policies.items) |*policy| policy.deinit(self.allocator);
        self.policies.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn clone(self: *const Store) Error!Store {
        var result = try Store.init(self.allocator, self.limits);
        errdefer result.deinit();
        for (self.policies.items) |policy| {
            try result.policies.append(self.allocator, .{
                .identity = policy.identity,
                .selection_revision = policy.selection_revision,
            });
            const copy = &result.policies.items[result.policies.items.len - 1];
            errdefer {
                copy.deinit(self.allocator);
                _ = result.policies.pop();
            }
            for (policy.disabled_skill_ids.items) |skill_id|
                try copy.disabled_skill_ids.append(
                    self.allocator,
                    try self.allocator.dupe(u8, skill_id),
                );
        }
        return result;
    }

    pub fn revision(self: *const Store, identity: WorkspaceIdentity) u64 {
        const policy = self.findConst(identity) orelse return 1;
        return policy.selection_revision;
    }

    pub fn isEnabled(
        self: *const Store,
        identity: WorkspaceIdentity,
        skill_id: []const u8,
    ) bool {
        const policy = self.findConst(identity) orelse return true;
        return findSkill(policy.disabled_skill_ids.items, skill_id) == null;
    }

    pub fn disabledSkillIds(
        self: *const Store,
        identity: WorkspaceIdentity,
    ) []const []u8 {
        const policy = self.findConst(identity) orelse return &.{};
        return policy.disabled_skill_ids.items;
    }

    pub fn apply(self: *Store, mutation: Mutation) Error!u64 {
        if (!validIdentity(mutation.identity)) return error.InvalidWorkspace;
        if (!validSkillId(mutation.skill_id, self.limits.max_skill_id_bytes))
            return error.InvalidSkillId;
        const current_revision = self.revision(mutation.identity);
        if (mutation.expected_revision != current_revision)
            return error.RevisionMismatch;
        var policy = self.find(mutation.identity);
        const currently_enabled = if (policy) |value|
            findSkill(value.disabled_skill_ids.items, mutation.skill_id) == null
        else
            true;
        if (currently_enabled == mutation.enabled) return current_revision;
        if (current_revision == std.math.maxInt(u64)) return error.RevisionExhausted;
        if (policy == null) {
            if (self.policies.items.len == self.limits.max_workspaces)
                return error.WorkspaceCapacity;
            try self.policies.append(self.allocator, .{
                .identity = mutation.identity,
                .selection_revision = current_revision,
            });
            policy = &self.policies.items[self.policies.items.len - 1];
        }
        if (mutation.enabled) {
            const index = findSkill(
                policy.?.disabled_skill_ids.items,
                mutation.skill_id,
            ) orelse unreachable;
            self.allocator.free(policy.?.disabled_skill_ids.items[index]);
            _ = policy.?.disabled_skill_ids.orderedRemove(index);
        } else {
            if (policy.?.disabled_skill_ids.items.len == self.limits.max_disabled_skill_ids)
                return error.SkillCapacity;
            try policy.?.disabled_skill_ids.append(
                self.allocator,
                try self.allocator.dupe(u8, mutation.skill_id),
            );
            sortSkillIds(policy.?.disabled_skill_ids.items);
        }
        policy.?.selection_revision = current_revision + 1;
        return policy.?.selection_revision;
    }

    /// Removes policies that cannot belong to a currently registered Manual
    /// Workspace. Empty policies remain so their revision cannot be replayed.
    pub fn reconcile(
        self: *Store,
        active: []const WorkspaceIdentity,
    ) bool {
        var changed = false;
        var index = self.policies.items.len;
        while (index > 0) {
            index -= 1;
            const policy = &self.policies.items[index];
            var found = false;
            for (active) |identity| {
                if (policy.identity.eql(identity)) {
                    found = true;
                    break;
                }
            }
            if (found) continue;
            policy.deinit(self.allocator);
            _ = self.policies.orderedRemove(index);
            changed = true;
        }
        return changed;
    }

    pub fn items(self: *const Store) []const WorkspacePolicy {
        return self.policies.items;
    }

    fn find(self: *Store, identity: WorkspaceIdentity) ?*WorkspacePolicy {
        for (self.policies.items) |*policy|
            if (policy.identity.eql(identity)) return policy;
        return null;
    }

    fn findConst(self: *const Store, identity: WorkspaceIdentity) ?*const WorkspacePolicy {
        for (self.policies.items) |*policy|
            if (policy.identity.eql(identity)) return policy;
        return null;
    }
};

pub const FileStore = struct {
    io: std.Io,
    dir: std.Io.Dir,

    pub fn init(io: std.Io, absolute_directory: []const u8) FileStoreError!FileStore {
        if (!std.fs.path.isAbsolute(absolute_directory)) return error.DirectoryUnavailable;
        const dir = std.Io.Dir.cwd().createDirPathOpen(io, absolute_directory, .{
            .open_options = .{ .follow_symlinks = false },
            .permissions = directoryPermissions(),
        }) catch return error.DirectoryUnavailable;
        return .{ .io = io, .dir = dir };
    }

    pub fn deinit(self: *FileStore) void {
        self.dir.close(self.io);
        self.* = undefined;
    }

    pub fn loadAlloc(self: *FileStore, allocator: std.mem.Allocator) FileStoreError!?[]u8 {
        var file = self.dir.openFile(self.io, file_name, .{
            .follow_symlinks = false,
            .resolve_beneath = true,
        }) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return error.ReadFailed,
        };
        if (builtin.os.tag == .windows) file.flags.nonblocking = true;
        defer file.close(self.io);
        const length = file.length(self.io) catch return error.ReadFailed;
        if (length == 0 or length > max_store_bytes) return error.ReadFailed;
        const bytes = try allocator.alloc(u8, @intCast(length));
        errdefer allocator.free(bytes);
        const read = file.readPositionalAll(self.io, bytes, 0) catch return error.ReadFailed;
        if (read != length) return error.ReadFailed;
        return bytes;
    }

    pub fn commit(self: *FileStore, bytes: []const u8) FileStoreError!void {
        if (bytes.len == 0 or bytes.len > max_store_bytes) return error.WriteFailed;
        var random: [8]u8 = undefined;
        std.Io.randomSecure(self.io, &random) catch return error.WriteFailed;
        const random_hex = std.fmt.bytesToHex(random, .lower);
        var temp_name_storage: [64]u8 = undefined;
        var writer = std.Io.Writer.fixed(&temp_name_storage);
        writer.print(".skill-enablement.{s}.tmp", .{random_hex}) catch
            return error.WriteFailed;
        const temp_name = writer.buffered();
        const file = self.dir.createFile(self.io, temp_name, .{
            .exclusive = true,
            .permissions = privateFilePermissions(),
            .resolve_beneath = true,
        }) catch return error.WriteFailed;
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
            const file = self.dir.openFile(self.io, file_name, .{
                .mode = .read_write,
                .allow_directory = false,
                .follow_symlinks = false,
                .resolve_beneath = true,
            }) catch return false;
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

const StoreWire = struct {
    schema: u8,
    workspaces: []WorkspaceWire,
};

const WorkspaceWire = struct {
    workspace_id: u64,
    workspace_epoch: u64,
    selection_revision: u64,
    disabled_skill_ids: []const []const u8,
};

pub fn encode(output: []u8, store: *const Store) Error![]const u8 {
    if (output.len == 0) return error.StoreEncodeFailed;
    var writer = std.Io.Writer.fixed(output);
    writer.print("{{\"schema\":{d},\"workspaces\":[", .{schema_version}) catch
        return error.StoreEncodeFailed;
    for (store.policies.items, 0..) |policy, index| {
        if (index != 0) writer.writeByte(',') catch return error.StoreEncodeFailed;
        writer.print(
            "{{\"workspace_id\":{d},\"workspace_epoch\":{d},\"selection_revision\":{d},\"disabled_skill_ids\":[",
            .{
                policy.identity.workspace_id,
                policy.identity.workspace_epoch,
                policy.selection_revision,
            },
        ) catch return error.StoreEncodeFailed;
        for (policy.disabled_skill_ids.items, 0..) |skill_id, skill_index| {
            if (skill_index != 0) writer.writeByte(',') catch
                return error.StoreEncodeFailed;
            jsonString(&writer, skill_id) catch return error.StoreEncodeFailed;
        }
        writer.writeAll("]}") catch return error.StoreEncodeFailed;
    }
    writer.writeAll("]}") catch return error.StoreEncodeFailed;
    const bytes = writer.buffered();
    if (bytes.len > max_store_bytes) return error.StoreTooLarge;
    return bytes;
}

pub fn decode(
    allocator: std.mem.Allocator,
    input: []const u8,
    limits: Limits,
) Error!Store {
    if (!validLimits(limits)) return error.InvalidLimits;
    if (input.len == 0) return error.StoreEmpty;
    if (input.len > max_store_bytes) return error.StoreTooLarge;
    var parsed = std.json.parseFromSlice(StoreWire, allocator, input, .{
        .ignore_unknown_fields = false,
    }) catch return error.StoreCorrupt;
    defer parsed.deinit();
    if (parsed.value.schema != schema_version or
        parsed.value.workspaces.len > limits.max_workspaces)
        return error.StoreCorrupt;
    var result = try Store.init(allocator, limits);
    errdefer result.deinit();
    for (parsed.value.workspaces) |wire| {
        const identity: WorkspaceIdentity = .{
            .workspace_id = wire.workspace_id,
            .workspace_epoch = wire.workspace_epoch,
        };
        if (!validIdentity(identity) or wire.selection_revision == 0 or
            wire.disabled_skill_ids.len > limits.max_disabled_skill_ids or
            result.findConst(identity) != null)
            return error.StoreCorrupt;
        try result.policies.append(allocator, .{
            .identity = identity,
            .selection_revision = wire.selection_revision,
        });
        const policy = &result.policies.items[result.policies.items.len - 1];
        for (wire.disabled_skill_ids) |skill_id| {
            if (!validSkillId(skill_id, limits.max_skill_id_bytes) or
                findSkill(policy.disabled_skill_ids.items, skill_id) != null)
                return error.StoreCorrupt;
            try policy.disabled_skill_ids.append(
                allocator,
                try allocator.dupe(u8, skill_id),
            );
        }
        sortSkillIds(policy.disabled_skill_ids.items);
    }
    return result;
}

fn validLimits(limits: Limits) bool {
    return limits.max_workspaces > 0 and
        limits.max_disabled_skill_ids > 0 and
        limits.max_skill_id_bytes > 0;
}

fn validIdentity(identity: WorkspaceIdentity) bool {
    return identity.workspace_id != 0 and identity.workspace_epoch != 0;
}

fn validSkillId(value: []const u8, max: usize) bool {
    return value.len != 0 and value.len <= max and
        std.unicode.utf8ValidateSlice(value);
}

fn findSkill(items: []const []u8, skill_id: []const u8) ?usize {
    for (items, 0..) |item, index|
        if (std.mem.eql(u8, item, skill_id)) return index;
    return null;
}

fn sortSkillIds(items: [][]u8) void {
    std.mem.sort([]u8, items, {}, struct {
        fn lessThan(_: void, left: []u8, right: []u8) bool {
            return std.mem.order(u8, left, right) == .lt;
        }
    }.lessThan);
}

fn jsonString(writer: *std.Io.Writer, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, writer);
}

fn directoryPermissions() std.Io.File.Permissions {
    return if (builtin.os.tag == .windows) .default_dir else .fromMode(0o700);
}

fn privateFilePermissions() std.Io.File.Permissions {
    return if (builtin.os.tag == .windows) .default_file else .fromMode(0o600);
}

test "Skill enablement keeps empty exceptions with a monotonic revision" {
    var store = try Store.init(std.testing.allocator, .{
        .max_workspaces = 4,
        .max_disabled_skill_ids = 8,
        .max_skill_id_bytes = 64,
    });
    defer store.deinit();
    const identity: WorkspaceIdentity = .{ .workspace_id = 7, .workspace_epoch = 3 };
    try std.testing.expectEqual(@as(u64, 1), store.revision(identity));
    try std.testing.expectEqual(@as(u64, 2), try store.apply(.{
        .identity = identity,
        .skill_id = "review",
        .enabled = false,
        .expected_revision = 1,
    }));
    try std.testing.expect(!store.isEnabled(identity, "review"));
    try std.testing.expectEqual(@as(u64, 3), try store.apply(.{
        .identity = identity,
        .skill_id = "review",
        .enabled = true,
        .expected_revision = 2,
    }));
    try std.testing.expect(store.isEnabled(identity, "review"));
    try std.testing.expectEqual(@as(usize, 1), store.items().len);
    try std.testing.expectEqual(@as(usize, 0), store.items()[0].disabled_skill_ids.items.len);
}

test "Skill enablement codec is strict and reconciliation removes stale epochs" {
    const limits: Limits = .{
        .max_workspaces = 4,
        .max_disabled_skill_ids = 8,
        .max_skill_id_bytes = 64,
    };
    var store = try Store.init(std.testing.allocator, limits);
    defer store.deinit();
    _ = try store.apply(.{
        .identity = .{ .workspace_id = 7, .workspace_epoch = 3 },
        .skill_id = "review",
        .enabled = false,
        .expected_revision = 1,
    });
    var output: [max_store_bytes]u8 = undefined;
    const encoded = try encode(&output, &store);
    var restored = try decode(std.testing.allocator, encoded, limits);
    defer restored.deinit();
    try std.testing.expect(!restored.isEnabled(
        .{ .workspace_id = 7, .workspace_epoch = 3 },
        "review",
    ));
    try std.testing.expect(restored.reconcile(&.{.{
        .workspace_id = 7,
        .workspace_epoch = 4,
    }}));
    try std.testing.expectEqual(@as(usize, 0), restored.items().len);
    try std.testing.expectError(error.StoreCorrupt, decode(
        std.testing.allocator,
        "{\"schema\":1,\"workspaces\":[],\"extra\":true}",
        limits,
    ));
}

test "Skill enablement clone isolates failed candidates" {
    var store = try Store.init(std.testing.allocator, .{
        .max_workspaces = 2,
        .max_disabled_skill_ids = 2,
        .max_skill_id_bytes = 64,
    });
    defer store.deinit();
    var candidate = try store.clone();
    defer candidate.deinit();
    _ = try candidate.apply(.{
        .identity = .{ .workspace_id = 1, .workspace_epoch = 1 },
        .skill_id = "review",
        .enabled = false,
        .expected_revision = 1,
    });
    try std.testing.expect(store.isEnabled(
        .{ .workspace_id = 1, .workspace_epoch = 1 },
        "review",
    ));
    try std.testing.expect(!candidate.isEnabled(
        .{ .workspace_id = 1, .workspace_epoch = 1 },
        "review",
    ));
}

test "Skill enablement file store atomically restores committed bytes" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const absolute = try temp.dir.realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(absolute);
    var file_store = try FileStore.init(std.testing.io, absolute);
    defer file_store.deinit();
    const expected =
        "{\"schema\":1,\"workspaces\":[{\"workspace_id\":7,\"workspace_epoch\":3,\"selection_revision\":2,\"disabled_skill_ids\":[\"review\"]}]}";
    try file_store.commit(expected);
    const restored = (try file_store.loadAlloc(std.testing.allocator)) orelse
        return error.TestExpectedEqual;
    defer std.testing.allocator.free(restored);
    try std.testing.expectEqualStrings(expected, restored);
}
