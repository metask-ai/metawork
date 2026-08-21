//! Workbench-owned durable user defaults and Manual Workspace Skill overrides.

const std = @import("std");
const builtin = @import("builtin");

pub const schema_version: u8 = 1;
pub const file_name = "skill-enablement.json";
pub const max_store_bytes: usize = 512 * 1024;

pub const Limits = struct {
    max_workspaces: usize,
    max_policy_keys: usize,
    max_policy_key_bytes: usize,
};

pub const Error = std.mem.Allocator.Error || error{
    InvalidLimits,
    InvalidWorkspace,
    InvalidPolicyKey,
    DuplicateWorkspace,
    DuplicatePolicyKey,
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

pub const OverrideState = enum {
    inherit,
    enabled,
    disabled,
};

pub const UserMutation = struct {
    skill_policy_key: []const u8,
    enabled: bool,
    expected_revision: u64,
};

pub const WorkspaceMutation = struct {
    identity: WorkspaceIdentity,
    skill_policy_key: []const u8,
    state: OverrideState,
    expected_revision: u64,
};

pub const UserPolicy = struct {
    policy_revision: u64 = 1,
    disabled_skill_policy_keys: std.ArrayList([]u8) = .empty,

    fn deinit(self: *UserPolicy, allocator: std.mem.Allocator) void {
        deinitPolicyKeys(allocator, &self.disabled_skill_policy_keys);
        self.* = undefined;
    }
};

pub const WorkspacePolicy = struct {
    identity: WorkspaceIdentity,
    policy_revision: u64,
    enabled_override_skill_policy_keys: std.ArrayList([]u8) = .empty,
    disabled_override_skill_policy_keys: std.ArrayList([]u8) = .empty,

    fn deinit(self: *WorkspacePolicy, allocator: std.mem.Allocator) void {
        deinitPolicyKeys(allocator, &self.enabled_override_skill_policy_keys);
        deinitPolicyKeys(allocator, &self.disabled_override_skill_policy_keys);
        self.* = undefined;
    }
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    limits: Limits,
    last_revision: u64 = 1,
    user: UserPolicy = .{},
    policies: std.ArrayList(WorkspacePolicy) = .empty,

    pub fn init(allocator: std.mem.Allocator, limits: Limits) Error!Store {
        if (!validLimits(limits)) return error.InvalidLimits;
        return .{ .allocator = allocator, .limits = limits };
    }

    pub fn deinit(self: *Store) void {
        self.user.deinit(self.allocator);
        for (self.policies.items) |*policy| policy.deinit(self.allocator);
        self.policies.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn clone(self: *const Store) Error!Store {
        var result = try Store.init(self.allocator, self.limits);
        errdefer result.deinit();
        result.last_revision = self.last_revision;
        result.user.policy_revision = self.user.policy_revision;
        try clonePolicyKeys(
            self.allocator,
            &result.user.disabled_skill_policy_keys,
            self.user.disabled_skill_policy_keys.items,
        );
        for (self.policies.items) |policy| {
            try result.policies.append(self.allocator, .{
                .identity = policy.identity,
                .policy_revision = policy.policy_revision,
            });
            const copy = &result.policies.items[result.policies.items.len - 1];
            errdefer {
                copy.deinit(self.allocator);
                _ = result.policies.pop();
            }
            try clonePolicyKeys(
                self.allocator,
                &copy.enabled_override_skill_policy_keys,
                policy.enabled_override_skill_policy_keys.items,
            );
            try clonePolicyKeys(
                self.allocator,
                &copy.disabled_override_skill_policy_keys,
                policy.disabled_override_skill_policy_keys.items,
            );
        }
        return result;
    }

    pub fn userRevision(self: *const Store) u64 {
        return self.user.policy_revision;
    }

    pub fn revision(self: *const Store, identity: WorkspaceIdentity) u64 {
        const policy = self.findConst(identity) orelse
            return self.user.policy_revision;
        return policy.policy_revision;
    }

    pub fn isUserEnabled(self: *const Store, skill_policy_key: []const u8) bool {
        return findPolicyKey(self.user.disabled_skill_policy_keys.items, skill_policy_key) == null;
    }

    pub fn workspaceOverride(
        self: *const Store,
        identity: WorkspaceIdentity,
        skill_policy_key: []const u8,
    ) OverrideState {
        const policy = self.findConst(identity) orelse return .inherit;
        if (findPolicyKey(policy.enabled_override_skill_policy_keys.items, skill_policy_key) != null)
            return .enabled;
        if (findPolicyKey(policy.disabled_override_skill_policy_keys.items, skill_policy_key) != null)
            return .disabled;
        return .inherit;
    }

    pub fn isEnabled(
        self: *const Store,
        identity: WorkspaceIdentity,
        skill_policy_key: []const u8,
    ) bool {
        return switch (self.workspaceOverride(identity, skill_policy_key)) {
            .enabled => true,
            .disabled => false,
            .inherit => self.isUserEnabled(skill_policy_key),
        };
    }

    pub fn applyUser(self: *Store, mutation: UserMutation) Error!u64 {
        if (!validPolicyKey(mutation.skill_policy_key, self.limits.max_policy_key_bytes))
            return error.InvalidPolicyKey;
        if (mutation.expected_revision != self.user.policy_revision)
            return error.RevisionMismatch;
        const currently_enabled = self.isUserEnabled(mutation.skill_policy_key);
        if (currently_enabled == mutation.enabled)
            return self.user.policy_revision;
        const next_revision = try self.nextRevision();
        if (mutation.enabled) {
            const index = findPolicyKey(
                self.user.disabled_skill_policy_keys.items,
                mutation.skill_policy_key,
            ) orelse unreachable;
            self.allocator.free(self.user.disabled_skill_policy_keys.items[index]);
            _ = self.user.disabled_skill_policy_keys.orderedRemove(index);
        } else {
            if (self.user.disabled_skill_policy_keys.items.len == self.limits.max_policy_keys)
                return error.SkillCapacity;
            const copy = try self.allocator.dupe(u8, mutation.skill_policy_key);
            errdefer self.allocator.free(copy);
            try self.user.disabled_skill_policy_keys.append(self.allocator, copy);
            sortPolicyKeys(self.user.disabled_skill_policy_keys.items);
        }
        self.last_revision = next_revision;
        self.user.policy_revision = next_revision;
        for (self.policies.items) |*policy|
            policy.policy_revision = next_revision;
        return next_revision;
    }

    pub fn applyWorkspace(
        self: *Store,
        mutation: WorkspaceMutation,
    ) Error!u64 {
        if (!validIdentity(mutation.identity)) return error.InvalidWorkspace;
        if (!validPolicyKey(mutation.skill_policy_key, self.limits.max_policy_key_bytes))
            return error.InvalidPolicyKey;
        const current_revision = self.revision(mutation.identity);
        if (mutation.expected_revision != current_revision)
            return error.RevisionMismatch;
        if (self.workspaceOverride(mutation.identity, mutation.skill_policy_key) == mutation.state)
            return current_revision;
        const next_revision = try self.nextRevision();
        const policy = try self.ensureWorkspace(mutation.identity);
        try setOverride(
            self.allocator,
            policy,
            mutation.skill_policy_key,
            mutation.state,
            self.limits.max_policy_keys,
        );
        self.last_revision = next_revision;
        policy.policy_revision = next_revision;
        return next_revision;
    }

    pub fn ensureWorkspace(
        self: *Store,
        identity: WorkspaceIdentity,
    ) Error!*WorkspacePolicy {
        if (!validIdentity(identity)) return error.InvalidWorkspace;
        if (self.find(identity)) |policy| return policy;
        if (self.policies.items.len == self.limits.max_workspaces)
            return error.WorkspaceCapacity;
        try self.policies.append(self.allocator, .{
            .identity = identity,
            .policy_revision = self.user.policy_revision,
        });
        return &self.policies.items[self.policies.items.len - 1];
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

    fn nextRevision(self: *const Store) Error!u64 {
        if (self.last_revision == std.math.maxInt(u64))
            return error.RevisionExhausted;
        return self.last_revision + 1;
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
    last_revision: u64,
    user: UserWire,
    workspaces: []WorkspaceWire,
};

const UserWire = struct {
    policy_revision: u64,
    disabled_skill_policy_keys: []const []const u8,
};

const WorkspaceWire = struct {
    workspace_id: u64,
    workspace_epoch: u64,
    policy_revision: u64,
    enabled_override_skill_policy_keys: []const []const u8,
    disabled_override_skill_policy_keys: []const []const u8,
};

pub fn encode(output: []u8, store: *const Store) Error![]const u8 {
    if (output.len == 0) return error.StoreEncodeFailed;
    var writer = std.Io.Writer.fixed(output);
    writer.print(
        "{{\"schema\":{d},\"last_revision\":{d},\"user\":{{\"policy_revision\":{d},\"disabled_skill_policy_keys\":[",
        .{ schema_version, store.last_revision, store.user.policy_revision },
    ) catch
        return error.StoreEncodeFailed;
    for (store.user.disabled_skill_policy_keys.items, 0..) |key, index| {
        if (index != 0) writer.writeByte(',') catch return error.StoreEncodeFailed;
        jsonString(&writer, key) catch return error.StoreEncodeFailed;
    }
    writer.writeAll("]},\"workspaces\":[") catch return error.StoreEncodeFailed;
    for (store.policies.items, 0..) |policy, index| {
        if (index != 0) writer.writeByte(',') catch return error.StoreEncodeFailed;
        writer.print(
            "{{\"workspace_id\":{d},\"workspace_epoch\":{d},\"policy_revision\":{d},\"enabled_override_skill_policy_keys\":[",
            .{
                policy.identity.workspace_id,
                policy.identity.workspace_epoch,
                policy.policy_revision,
            },
        ) catch return error.StoreEncodeFailed;
        for (policy.enabled_override_skill_policy_keys.items, 0..) |key, skill_index| {
            if (skill_index != 0) writer.writeByte(',') catch
                return error.StoreEncodeFailed;
            jsonString(&writer, key) catch return error.StoreEncodeFailed;
        }
        writer.writeAll("],\"disabled_override_skill_policy_keys\":[") catch
            return error.StoreEncodeFailed;
        for (policy.disabled_override_skill_policy_keys.items, 0..) |key, skill_index| {
            if (skill_index != 0) writer.writeByte(',') catch
                return error.StoreEncodeFailed;
            jsonString(&writer, key) catch return error.StoreEncodeFailed;
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
        parsed.value.last_revision == 0 or
        parsed.value.user.policy_revision == 0 or
        parsed.value.user.policy_revision > parsed.value.last_revision or
        parsed.value.user.disabled_skill_policy_keys.len > limits.max_policy_keys or
        parsed.value.workspaces.len > limits.max_workspaces)
        return error.StoreCorrupt;
    var result = try Store.init(allocator, limits);
    errdefer result.deinit();
    result.last_revision = parsed.value.last_revision;
    result.user.policy_revision = parsed.value.user.policy_revision;
    try decodePolicyKeys(
        allocator,
        &result.user.disabled_skill_policy_keys,
        parsed.value.user.disabled_skill_policy_keys,
        limits,
    );
    for (parsed.value.workspaces) |wire| {
        const identity: WorkspaceIdentity = .{
            .workspace_id = wire.workspace_id,
            .workspace_epoch = wire.workspace_epoch,
        };
        if (!validIdentity(identity) or wire.policy_revision == 0 or
            wire.policy_revision > parsed.value.last_revision or
            wire.enabled_override_skill_policy_keys.len > limits.max_policy_keys or
            wire.disabled_override_skill_policy_keys.len > limits.max_policy_keys or
            result.findConst(identity) != null)
            return error.StoreCorrupt;
        try result.policies.append(allocator, .{
            .identity = identity,
            .policy_revision = wire.policy_revision,
        });
        const policy = &result.policies.items[result.policies.items.len - 1];
        try decodePolicyKeys(
            allocator,
            &policy.enabled_override_skill_policy_keys,
            wire.enabled_override_skill_policy_keys,
            limits,
        );
        try decodePolicyKeys(
            allocator,
            &policy.disabled_override_skill_policy_keys,
            wire.disabled_override_skill_policy_keys,
            limits,
        );
        for (policy.enabled_override_skill_policy_keys.items) |key|
            if (findPolicyKey(policy.disabled_override_skill_policy_keys.items, key) != null)
                return error.StoreCorrupt;
    }
    return result;
}

fn setOverride(
    allocator: std.mem.Allocator,
    policy: *WorkspacePolicy,
    skill_policy_key: []const u8,
    state: OverrideState,
    max_policy_keys: usize,
) Error!void {
    const enabled_index = findPolicyKey(policy.enabled_override_skill_policy_keys.items, skill_policy_key);
    const disabled_index = findPolicyKey(policy.disabled_override_skill_policy_keys.items, skill_policy_key);
    const target: ?*std.ArrayList([]u8) = switch (state) {
        .inherit => null,
        .enabled => &policy.enabled_override_skill_policy_keys,
        .disabled => &policy.disabled_override_skill_policy_keys,
    };
    if (target) |list| {
        if (list.items.len == max_policy_keys) return error.SkillCapacity;
        try list.ensureUnusedCapacity(allocator, 1);
        const copy = try allocator.dupe(u8, skill_policy_key);
        errdefer allocator.free(copy);
        removePolicyKey(allocator, &policy.enabled_override_skill_policy_keys, enabled_index);
        removePolicyKey(allocator, &policy.disabled_override_skill_policy_keys, disabled_index);
        list.appendAssumeCapacity(copy);
        sortPolicyKeys(list.items);
    } else {
        removePolicyKey(allocator, &policy.enabled_override_skill_policy_keys, enabled_index);
        removePolicyKey(allocator, &policy.disabled_override_skill_policy_keys, disabled_index);
    }
}

fn removePolicyKey(
    allocator: std.mem.Allocator,
    items: *std.ArrayList([]u8),
    index: ?usize,
) void {
    const found = index orelse return;
    allocator.free(items.items[found]);
    _ = items.orderedRemove(found);
}

fn clonePolicyKeys(
    allocator: std.mem.Allocator,
    target: *std.ArrayList([]u8),
    source: []const []u8,
) std.mem.Allocator.Error!void {
    try target.ensureTotalCapacity(allocator, source.len);
    for (source) |key|
        target.appendAssumeCapacity(try allocator.dupe(u8, key));
}

fn decodePolicyKeys(
    allocator: std.mem.Allocator,
    target: *std.ArrayList([]u8),
    source: []const []const u8,
    limits: Limits,
) Error!void {
    for (source) |key| {
        if (!validPolicyKey(key, limits.max_policy_key_bytes) or
            findPolicyKey(target.items, key) != null)
            return error.StoreCorrupt;
        const copy = try allocator.dupe(u8, key);
        errdefer allocator.free(copy);
        try target.append(allocator, copy);
    }
    sortPolicyKeys(target.items);
}

fn deinitPolicyKeys(
    allocator: std.mem.Allocator,
    items: *std.ArrayList([]u8),
) void {
    for (items.items) |key| allocator.free(key);
    items.deinit(allocator);
}

fn validLimits(limits: Limits) bool {
    return limits.max_workspaces > 0 and
        limits.max_policy_keys > 0 and
        limits.max_policy_key_bytes > 0;
}

fn validIdentity(identity: WorkspaceIdentity) bool {
    return identity.workspace_id != 0 and identity.workspace_epoch != 0;
}

fn validPolicyKey(value: []const u8, max: usize) bool {
    return value.len != 0 and value.len <= max and
        std.unicode.utf8ValidateSlice(value);
}

fn findPolicyKey(items: []const []u8, skill_policy_key: []const u8) ?usize {
    for (items, 0..) |item, index|
        if (std.mem.eql(u8, item, skill_policy_key)) return index;
    return null;
}

fn sortPolicyKeys(items: [][]u8) void {
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

test "User defaults stamp every Workspace with one global revision" {
    var store = try Store.init(std.testing.allocator, .{
        .max_workspaces = 4,
        .max_policy_keys = 8,
        .max_policy_key_bytes = 64,
    });
    defer store.deinit();
    const identity: WorkspaceIdentity = .{ .workspace_id = 7, .workspace_epoch = 3 };
    const other_identity: WorkspaceIdentity = .{ .workspace_id = 8, .workspace_epoch = 1 };
    _ = try store.ensureWorkspace(identity);
    _ = try store.ensureWorkspace(other_identity);
    try std.testing.expectEqual(@as(u64, 1), store.revision(identity));
    try std.testing.expectEqual(@as(u64, 2), try store.applyUser(.{
        .skill_policy_key = "review",
        .enabled = false,
        .expected_revision = 1,
    }));
    try std.testing.expectEqual(@as(u64, 2), store.userRevision());
    try std.testing.expectEqual(@as(u64, 2), store.revision(identity));
    try std.testing.expectEqual(@as(u64, 2), store.revision(other_identity));
    try std.testing.expectEqual(@as(u64, 2), store.last_revision);
    try std.testing.expectEqual(@as(u64, 2), try store.applyUser(.{
        .skill_policy_key = "review",
        .enabled = false,
        .expected_revision = 2,
    }));
    try std.testing.expectEqual(@as(u64, 2), store.last_revision);
    try std.testing.expect(!store.isEnabled(identity, "review"));
    try std.testing.expectEqual(@as(u64, 3), try store.applyWorkspace(.{
        .identity = identity,
        .skill_policy_key = "review",
        .state = .enabled,
        .expected_revision = 2,
    }));
    try std.testing.expect(store.isEnabled(identity, "review"));
    try std.testing.expectEqual(OverrideState.enabled, store.workspaceOverride(
        identity,
        "review",
    ));
    try std.testing.expectEqual(@as(u64, 4), try store.applyWorkspace(.{
        .identity = identity,
        .skill_policy_key = "review",
        .state = .inherit,
        .expected_revision = 3,
    }));
    try std.testing.expect(!store.isEnabled(identity, "review"));
    try std.testing.expectEqual(@as(usize, 2), store.items().len);
    try std.testing.expectEqual(@as(usize, 0), store.items()[0].enabled_override_skill_policy_keys.items.len);
    try std.testing.expectEqual(@as(usize, 0), store.items()[0].disabled_override_skill_policy_keys.items.len);
}

test "Skill enablement codec is strict and reconciliation removes stale epochs" {
    const limits: Limits = .{
        .max_workspaces = 4,
        .max_policy_keys = 8,
        .max_policy_key_bytes = 64,
    };
    var store = try Store.init(std.testing.allocator, limits);
    defer store.deinit();
    _ = try store.applyUser(.{
        .skill_policy_key = "review",
        .enabled = false,
        .expected_revision = 1,
    });
    _ = try store.applyWorkspace(.{
        .identity = .{ .workspace_id = 7, .workspace_epoch = 3 },
        .skill_policy_key = "review",
        .state = .enabled,
        .expected_revision = 2,
    });
    var output: [max_store_bytes]u8 = undefined;
    const encoded = try encode(&output, &store);
    var restored = try decode(std.testing.allocator, encoded, limits);
    defer restored.deinit();
    try std.testing.expect(!restored.isUserEnabled("review"));
    try std.testing.expect(restored.isEnabled(
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
        "{\"schema\":1,\"last_revision\":1,\"user\":{\"selection_revision\":1,\"disabled_skill_ids\":[]},\"workspaces\":[],\"extra\":true}",
        limits,
    ));
    try std.testing.expectError(error.StoreCorrupt, decode(
        std.testing.allocator,
        "{\"schema\":1,\"workspaces\":[]}",
        limits,
    ));
}

test "Skill enablement clone isolates failed candidates" {
    var store = try Store.init(std.testing.allocator, .{
        .max_workspaces = 2,
        .max_policy_keys = 2,
        .max_policy_key_bytes = 64,
    });
    defer store.deinit();
    var candidate = try store.clone();
    defer candidate.deinit();
    _ = try candidate.applyWorkspace(.{
        .identity = .{ .workspace_id = 1, .workspace_epoch = 1 },
        .skill_policy_key = "review",
        .state = .disabled,
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
        "{\"schema\":1,\"last_revision\":2,\"user\":{\"policy_revision\":2,\"disabled_skill_policy_keys\":[\"review\"]},\"workspaces\":[{\"workspace_id\":7,\"workspace_epoch\":3,\"policy_revision\":2,\"enabled_override_skill_policy_keys\":[],\"disabled_override_skill_policy_keys\":[]}]}";
    try file_store.commit(expected);
    const restored = (try file_store.loadAlloc(std.testing.allocator)) orelse
        return error.TestExpectedEqual;
    defer std.testing.allocator.free(restored);
    try std.testing.expectEqualStrings(expected, restored);
}
