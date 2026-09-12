//! Fixed Skill source values and bounded file mechanics.
//! No Runtime, scheduling, authority, recovery policy, or production entry point
//! lives here. Application will own FileStore; Skill Runtime will own settings.

const std = @import("std");
const builtin = @import("builtin");
const agent = @import("metawork_agent");

pub const file_name = "skill-sources.json";
pub const max_store_bytes = 4096;
pub const Id = enum { claude_user, claude_workspace, codex_user, codex_workspace };
pub const Brand = enum { claude, codex };
pub const Ecosystem = enum {
    agents,
    claude,
    codex,

    fn directory(self: Ecosystem) []const u8 {
        return switch (self) {
            .agents => ".agents",
            .claude => ".claude",
            .codex => ".codex",
        };
    }
};

pub const Definition = struct {
    id: Id,
    source_instance_id: []const u8,
    ecosystem: Ecosystem,
    scope: agent.CatalogSourceScope,
};

pub const definitions = [_]Definition{
    .{ .id = .claude_user, .source_instance_id = "compat.claude.user", .ecosystem = .claude, .scope = .user },
    .{ .id = .claude_workspace, .source_instance_id = "compat.claude.workspace", .ecosystem = .claude, .scope = .workspace },
    .{ .id = .codex_user, .source_instance_id = "compat.codex.user", .ecosystem = .codex, .scope = .user },
    .{ .id = .codex_workspace, .source_instance_id = "compat.codex.workspace", .ecosystem = .codex, .scope = .workspace },
};

pub fn definition(id: Id) Definition {
    return definitions[@intFromEnum(id)];
}

pub fn findId(value: []const u8) ?Id {
    for (definitions) |item|
        if (std.mem.eql(u8, value, item.source_instance_id)) return item.id;
    return null;
}

pub const Selection = struct {
    values: [definitions.len]bool = @splat(false),

    pub fn enabled(self: Selection, id: Id) bool {
        return self.values[@intFromEnum(id)];
    }

    /// Personal discovery does not depend on the two Workspace switches.
    pub fn relevant(self: Selection, scope: agent.CatalogSourceScope) Selection {
        var result = self;
        if (scope == .user) for (definitions) |item| {
            if (item.scope == .workspace) result.values[@intFromEnum(item.id)] = false;
        };
        return result;
    }

    pub fn eql(self: Selection, other: Selection) bool {
        return std.mem.eql(bool, &self.values, &other.values);
    }
};

pub const Settings = struct {
    revision: u64 = 1,
    selection: Selection = .{},

    /// Prepares a value only. Persistence and no-fail installation belong to
    /// Skill Runtime; constructing this candidate does not change authority.
    pub fn replacing(self: Settings, brand: Brand, enabled: bool, expected_revision: u64) error{ InvalidSettings, StaleRevision, RevisionExhausted }!Settings {
        if (self.revision == 0) return error.InvalidSettings;
        if (self.revision != expected_revision) return error.StaleRevision;
        const ecosystem: Ecosystem = switch (brand) {
            .claude => .claude,
            .codex => .codex,
        };
        var result = self;
        for (definitions) |item| {
            if (item.ecosystem == ecosystem) result.selection.values[@intFromEnum(item.id)] = enabled;
        }
        if (result.selection.eql(self.selection)) return self;
        if (self.revision == std.math.maxInt(u64)) return error.RevisionExhausted;
        result.revision += 1;
        return result;
    }
};

pub const DecodeError = std.mem.Allocator.Error || error{ InvalidSettings, UnsupportedSchema, SettingsTooLarge };

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) DecodeError!Settings {
    if (bytes.len > max_store_bytes) return error.SettingsTooLarge;
    if (bytes.len == 0) return error.InvalidSettings;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
        .duplicate_field_behavior = .@"error",
        .parse_numbers = false,
    }) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidSettings;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidSettings;
    const object = parsed.value.object;
    const schema = try positiveInteger(object.get("schema") orelse return error.InvalidSettings);
    if (schema != 1) return error.UnsupportedSchema;
    if (object.count() != 3) return error.InvalidSettings;
    const revision = try positiveInteger(object.get("revision") orelse return error.InvalidSettings);
    const sources = object.get("sources") orelse return error.InvalidSettings;
    if (sources != .object or sources.object.count() != definitions.len) return error.InvalidSettings;
    var result: Settings = .{ .revision = revision };
    for (definitions) |item| {
        const value = sources.object.get(item.source_instance_id) orelse return error.InvalidSettings;
        if (value != .bool) return error.InvalidSettings;
        result.selection.values[@intFromEnum(item.id)] = value.bool;
    }
    return result;
}

fn positiveInteger(value: std.json.Value) error{InvalidSettings}!u64 {
    if (value != .number_string or value.number_string.len == 0) return error.InvalidSettings;
    for (value.number_string) |byte| if (byte < '0' or byte > '9') return error.InvalidSettings;
    const number = std.fmt.parseInt(u64, value.number_string, 10) catch return error.InvalidSettings;
    if (number == 0) return error.InvalidSettings;
    return number;
}

pub fn encode(settings: Settings, buffer: []u8) error{ InvalidSettings, BufferTooSmall }![]const u8 {
    if (settings.revision == 0) return error.InvalidSettings;
    var writer = std.Io.Writer.fixed(buffer);
    writer.print("{{\"schema\":1,\"revision\":{d},\"sources\":{{", .{settings.revision}) catch return error.BufferTooSmall;
    for (definitions, 0..) |item, index| {
        if (index != 0) writer.writeByte(',') catch return error.BufferTooSmall;
        writer.print("\"{s}\":{}", .{ item.source_instance_id, settings.selection.enabled(item.id) }) catch return error.BufferTooSmall;
    }
    writer.writeAll("}}\n") catch return error.BufferTooSmall;
    return writer.buffered();
}

pub const Load = union(enum) { absent, ready: Settings, invalid, unsupported_schema, too_large };
pub const FileStoreError = std.mem.Allocator.Error || error{
    DirectoryUnavailable,
    ReadFailed,
    UnsupportedEntry,
    WriteFailed,
    PersistenceOutcomeUnknown,
    InvalidSettings,
};

pub const FileStore = struct {
    io: std.Io,
    dir: std.Io.Dir,
    commit_fault: if (builtin.is_test) enum { none, after_rename } else void = if (builtin.is_test) .none else {},

    /// Opens an existing Application-owned settings directory; never creates
    /// source directories or initializes/resets the settings implicitly.
    pub fn init(io: std.Io, absolute_directory: []const u8) FileStoreError!FileStore {
        // POSIX durability requires a syncable directory descriptor, not an
        // O_PATH handle. This permits opening it for sync; no scan is performed.
        const dir = openCanonicalBase(io, absolute_directory, true) catch return error.DirectoryUnavailable;
        return .{ .io = io, .dir = dir };
    }

    pub fn deinit(self: *FileStore) void {
        self.dir.close(self.io);
        self.* = undefined;
    }

    pub fn load(self: *FileStore, allocator: std.mem.Allocator) FileStoreError!Load {
        const before = self.dir.statFile(self.io, file_name, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return .absent,
            else => return error.ReadFailed,
        };
        if (before.kind != .file) return error.UnsupportedEntry;
        var file = self.dir.openFile(self.io, file_name, .{
            .follow_symlinks = false,
            .resolve_beneath = true,
        }) catch return error.ReadFailed;
        if (builtin.os.tag == .windows) file.flags.nonblocking = true;
        defer file.close(self.io);
        const opened = file.stat(self.io) catch return error.ReadFailed;
        if (opened.kind != .file) return error.UnsupportedEntry;
        if (opened.size > max_store_bytes) return .too_large;
        var bytes: [max_store_bytes]u8 = undefined;
        const length: usize = @intCast(opened.size);
        const read = file.readPositionalAll(self.io, bytes[0..length], 0) catch return error.ReadFailed;
        const after = file.stat(self.io) catch return error.ReadFailed;
        if (read != length or after.size != opened.size or after.mtime.nanoseconds != opened.mtime.nanoseconds)
            return error.ReadFailed;
        const settings = decode(allocator, bytes[0..length]) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidSettings => .invalid,
            error.UnsupportedSchema => .unsupported_schema,
            error.SettingsTooLarge => .too_large,
        };
        return .{ .ready = settings };
    }

    /// Mechanical durable replacement only; callers must first authorize the
    /// mutation/recovery and reserve its in-memory no-fail commit.
    pub fn commit(self: *FileStore, settings: Settings) FileStoreError!void {
        var storage: [max_store_bytes]u8 = undefined;
        const bytes = encode(settings, &storage) catch return error.InvalidSettings;
        var random: [8]u8 = undefined;
        std.Io.randomSecure(self.io, &random) catch return error.WriteFailed;
        var name_storage: [64]u8 = undefined;
        const name = std.fmt.bufPrint(&name_storage, ".skill-sources.{s}.tmp", .{std.fmt.bytesToHex(random, .lower)}) catch unreachable;
        const file = self.dir.createFile(self.io, name, .{
            .exclusive = true,
            .permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(0o600),
            .resolve_beneath = true,
        }) catch return error.WriteFailed;
        var file_open = true;
        var temp_exists = true;
        defer {
            if (file_open) file.close(self.io);
            if (temp_exists) self.dir.deleteFile(self.io, name) catch {};
        }
        file.writeStreamingAll(self.io, bytes) catch return error.WriteFailed;
        file.sync(self.io) catch return error.WriteFailed;
        file.close(self.io);
        file_open = false;
        self.dir.rename(name, self.dir, file_name, self.io) catch return error.WriteFailed;
        temp_exists = false;
        if (builtin.is_test) if (self.commit_fault == .after_rename) return error.PersistenceOutcomeUnknown;
        // The canonical rename has happened. Any durability failure after this
        // point is uncertain, never reported as a known non-commit.
        if (builtin.os.tag == .windows) {
            const current = self.dir.openFile(self.io, file_name, .{
                .mode = .read_write,
                .follow_symlinks = false,
                .resolve_beneath = true,
            }) catch return error.PersistenceOutcomeUnknown;
            defer current.close(self.io);
            current.sync(self.io) catch return error.PersistenceOutcomeUnknown;
        } else {
            const directory_file: std.Io.File = .{ .handle = self.dir.handle, .flags = .{ .nonblocking = false } };
            directory_file.sync(self.io) catch return error.PersistenceOutcomeUnknown;
        }
    }
};

pub const RootFailure = enum { unreadable, unsupported_entry, changed };
pub const RootCheck = union(enum) { disabled, missing, checked, blocked: RootFailure };

/// Check only the two fixed root components, never enumerate Skill candidates.
/// This is a point-in-time observation, not a durable filesystem capability.
pub fn checkRoot(io: std.Io, base: std.Io.Dir, ecosystem: Ecosystem) RootCheck {
    var parent = switch (openComponent(io, base, ecosystem.directory())) {
        .opened => |dir| dir,
        .missing => return .missing,
        .blocked => |reason| return .{ .blocked = reason },
    };
    defer parent.close(io);
    var skills = switch (openComponent(io, parent, "skills")) {
        .opened => |dir| dir,
        .missing => return .missing,
        .blocked => |reason| return .{ .blocked = reason },
    };
    defer skills.close(io);
    return .checked;
}

const OpenComponent = union(enum) { opened: std.Io.Dir, missing, blocked: RootFailure };

fn openComponent(io: std.Io, base: std.Io.Dir, name: []const u8) OpenComponent {
    const before = base.statFile(io, name, .{ .follow_symlinks = false }) catch |err| return switch (err) {
        error.FileNotFound => .missing,
        else => .{ .blocked = .unreadable },
    };
    if (before.kind != .directory) return .{ .blocked = .unsupported_entry };
    const dir = base.openDir(io, name, .{ .follow_symlinks = false }) catch |err| return switch (err) {
        error.FileNotFound, error.NotDir, error.SymLinkLoop => .{ .blocked = .changed },
        else => .{ .blocked = .unreadable },
    };
    const after = dir.stat(io) catch {
        dir.close(io);
        return .{ .blocked = .unreadable };
    };
    if (after.kind != .directory or after.inode != before.inode) {
        dir.close(io);
        return .{ .blocked = if (after.kind != .directory) .unsupported_entry else .changed };
    }
    return .{ .opened = dir };
}

fn openCanonicalBase(io: std.Io, path: []const u8, iterate: bool) error{InvalidBase}!std.Io.Dir {
    if (!std.fs.path.isAbsolute(path) or !std.unicode.utf8ValidateSlice(path) or
        std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidBase;
    const dir = std.Io.Dir.openDirAbsolute(io, path, .{ .follow_symlinks = false, .iterate = iterate }) catch return error.InvalidBase;
    errdefer dir.close(io);
    const stat = dir.stat(io) catch return error.InvalidBase;
    if (stat.kind != .directory) return error.InvalidBase;
    var canonical: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = dir.realPath(io, &canonical) catch return error.InvalidBase;
    if (!std.mem.eql(u8, canonical[0..length], path)) return error.InvalidBase;
    return dir;
}

pub const RootChecks = struct {
    default_user: RootCheck,
    default_workspace: RootCheck,
    checks: [definitions.len]RootCheck,
};

pub const Discovery = struct {
    allocator: std.mem.Allocator,
    default_user: RootCheck,
    default_workspace: RootCheck,
    checks: [definitions.len]RootCheck = @splat(.disabled),
    owned_sources: [definitions.len]agent.CatalogSource = undefined,
    count: usize = 0,

    pub fn rootChecks(self: *const Discovery) RootChecks {
        return .{ .default_user = self.default_user, .default_workspace = self.default_workspace, .checks = self.checks };
    }

    pub fn deinit(self: *Discovery) void {
        for (self.owned_sources[0..self.count]) |source| self.allocator.free(source.canonical_root);
        self.* = undefined;
    }

    /// Refuse a partial usable list if any enabled/default root was blocked.
    pub fn additionalSources(self: *const Discovery) error{SourceUnavailable}![]const agent.CatalogSource {
        if (self.default_user == .blocked or self.default_workspace == .blocked) return error.SourceUnavailable;
        for (self.checks) |check| if (check == .blocked) return error.SourceUnavailable;
        return self.owned_sources[0..self.count];
    }
};

/// Pure input preparation plus bounded root I/O, not a catalog acquisition.
/// A null workspace prepares only user roots for the Agent management query.
pub fn discover(
    io: std.Io,
    allocator: std.mem.Allocator,
    canonical_home: []const u8,
    canonical_workspace: ?[]const u8,
    selection: Selection,
) (std.mem.Allocator.Error || error{InvalidBase})!Discovery {
    const home = try openCanonicalBase(io, canonical_home, false);
    defer home.close(io);
    const workspace = if (canonical_workspace) |path| try openCanonicalBase(io, path, false) else null;
    defer if (workspace) |dir| dir.close(io);
    var result: Discovery = .{
        .allocator = allocator,
        .default_user = checkRoot(io, home, .agents),
        .default_workspace = if (workspace) |dir| checkRoot(io, dir, .agents) else .disabled,
    };
    errdefer result.deinit();
    for (definitions) |item| {
        if (!selection.enabled(item.id) or (item.scope == .workspace and workspace == null)) continue;
        const check = checkRoot(io, if (item.scope == .user) home else workspace.?, item.ecosystem);
        result.checks[@intFromEnum(item.id)] = check;
        if (check != .checked) continue;
        const base = if (item.scope == .user) canonical_home else canonical_workspace.?;
        const path = try std.fs.path.join(allocator, &.{ base, item.ecosystem.directory(), "skills" });
        // With a shared home/Workspace root, retain one physical root. The
        // Workspace rule wins only when its own switch was selected.
        var duplicate: ?usize = null;
        for (result.owned_sources[0..result.count], 0..) |existing, index| {
            if (std.mem.eql(u8, existing.canonical_root, path)) {
                duplicate = index;
                break;
            }
        }
        if (duplicate) |index| {
            allocator.free(path);
            if (item.scope == .workspace) {
                result.owned_sources[index].scope = item.scope;
                result.owned_sources[index].source_instance_id = item.source_instance_id;
            }
        } else {
            result.owned_sources[result.count] = .{
                .canonical_root = path,
                .scope = item.scope,
                .source_instance_id = item.source_instance_id,
            };
            result.count += 1;
        }
    }
    return result;
}

test "fixed source settings round trip every selection and scope dependency" {
    for (0..16) |bits| {
        var settings: Settings = .{ .revision = std.math.maxInt(u64) };
        for (definitions, 0..) |item, index| {
            settings.selection.values[index] = bits & (@as(usize, 1) << @intCast(index)) != 0;
            try std.testing.expectEqual(item.id, findId(item.source_instance_id).?);
        }
        var buffer: [max_store_bytes]u8 = undefined;
        const bytes = try encode(settings, &buffer);
        try std.testing.expectEqualDeep(settings, try decode(std.testing.allocator, bytes));
        const personal = settings.selection.relevant(.user);
        try std.testing.expect(!personal.enabled(.claude_workspace) and !personal.enabled(.codex_workspace));
        try std.testing.expectEqual(settings.selection.enabled(.claude_user), personal.enabled(.claude_user));
        try std.testing.expect(settings.selection.eql(settings.selection.relevant(.workspace)));
    }
    try std.testing.expectEqual(@as(?Id, null), findId("../skills"));
    try std.testing.expectEqual(@as(?Id, null), findId("agents.user.default"));
}

test "settings candidate checks CAS no-op and overflow without mutating input" {
    const original: Settings = .{};
    const candidate = try original.replacing(.claude, true, 1);
    try std.testing.expectEqual(@as(u64, 2), candidate.revision);
    try std.testing.expect(!original.selection.enabled(.claude_user));
    try std.testing.expectEqualDeep(candidate, try candidate.replacing(.claude, true, 2));
    try std.testing.expectError(error.StaleRevision, candidate.replacing(.claude, true, 1));
    const exhausted: Settings = .{ .revision = std.math.maxInt(u64) };
    try std.testing.expectEqualDeep(exhausted, try exhausted.replacing(.claude, false, exhausted.revision));
    try std.testing.expectError(error.RevisionExhausted, exhausted.replacing(.claude, true, exhausted.revision));
}

test "brand candidate changes both scopes once and preserves the other brand in all persisted combinations" {
    for (0..16) |bits| {
        var original: Settings = .{ .revision = 7 };
        for (&original.selection.values, 0..) |*value, index| value.* = bits & (@as(usize, 1) << @intCast(index)) != 0;
        inline for (.{ Brand.claude, Brand.codex }) |brand| {
            inline for (.{ false, true }) |enabled| {
                const candidate = try original.replacing(brand, enabled, 7);
                for (definitions) |item| {
                    const selected = item.ecosystem == (switch (brand) {
                        .claude => Ecosystem.claude,
                        .codex => Ecosystem.codex,
                    });
                    try std.testing.expectEqual(if (selected) enabled else original.selection.enabled(item.id), candidate.selection.enabled(item.id));
                }
                try std.testing.expectEqual(@as(u64, if (candidate.selection.eql(original.selection)) 7 else 8), candidate.revision);
                var buffer: [max_store_bytes]u8 = undefined;
                try std.testing.expectEqualDeep(candidate, try decode(std.testing.allocator, try encode(candidate, &buffer)));
            }
        }
    }
}

test "settings decoder rejects malformed unknown duplicate and coercible fields" {
    const fields = "\"compat.claude.user\":false,\"compat.claude.workspace\":false,\"compat.codex.user\":false,\"compat.codex.workspace\":false";
    inline for (.{
        "",                                                                                                                                                             "{}",                                                                        "[]",                                                                                       "{\"schema\":1,\"revision\":1,\"sources\":{}}",
        "{\"schema\":1,\"revision\":1,\"sources\":{" ++ fields ++ "},\"extra\":0}",                                                                                     "{\"schema\":1,\"schema\":1,\"revision\":1,\"sources\":{" ++ fields ++ "}}", "{\"schema\":1,\"revision\":1,\"sources\":{" ++ fields ++ ",\"compat.claude.user\":true}}", "{\"schema\":1,\"revision\":\"1\",\"sources\":{" ++ fields ++ "}}",
        "{\"schema\":1,\"revision\":1.0,\"sources\":{" ++ fields ++ "}}",                                                                                               "{\"schema\":1,\"revision\":0,\"sources\":{" ++ fields ++ "}}",              "{\"schema\":1,\"revision\":18446744073709551616,\"sources\":{" ++ fields ++ "}}",          "{\"schema\":1,\"revision\":1,\"sources\":{\"compat.claude.user\":0,\"compat.claude.workspace\":false,\"compat.codex.user\":false,\"compat.codex.workspace\":false}}",
        "{\"schema\":1,\"revision\":1,\"sources\":{\"unknown\":false,\"compat.claude.workspace\":false,\"compat.codex.user\":false,\"compat.codex.workspace\":false}}",
    }) |bytes| try std.testing.expectError(error.InvalidSettings, decode(std.testing.allocator, bytes));
    try std.testing.expectError(error.UnsupportedSchema, decode(std.testing.allocator, "{\"schema\":2,\"newShape\":true}"));
    var oversized: [max_store_bytes + 1]u8 = undefined;
    try std.testing.expectError(error.SettingsTooLarge, decode(std.testing.allocator, &oversized));
    var tiny: [1]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, encode(.{}, &tiny));
}

test "source FileStore distinguishes absence corruption unsupported format and I/O failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var store = try FileStore.init(std.testing.io, root);
    defer store.deinit();
    try std.testing.expectEqualDeep(Load.absent, try store.load(std.testing.allocator));
    const settings = try (Settings{}).replacing(.claude, true, 1);
    try store.commit(settings);
    try std.testing.expectEqualDeep(Load{ .ready = settings }, try store.load(std.testing.allocator));
    try store.commit(try settings.replacing(.codex, true, 2));
    try std.testing.expectEqual(@as(u64, 3), (try store.load(std.testing.allocator)).ready.revision);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = file_name, .data = "{}" });
    try std.testing.expectEqualDeep(Load.invalid, try store.load(std.testing.allocator));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = file_name, .data = "{\"schema\":2}" });
    try std.testing.expectEqualDeep(Load.unsupported_schema, try store.load(std.testing.allocator));
    try tmp.dir.deleteFile(std.testing.io, file_name);
    try tmp.dir.createDir(std.testing.io, file_name, .default_dir);
    try std.testing.expectError(error.UnsupportedEntry, store.load(std.testing.allocator));
    try std.testing.expectError(error.WriteFailed, store.commit(settings));
    try std.testing.expectEqual(std.Io.File.Kind.directory, (try tmp.dir.statFile(std.testing.io, file_name, .{})).kind);
}

test "source size boundaries preserve unsupported and unexamined formats" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var store = try FileStore.init(std.testing.io, root);
    defer store.deinit();
    var encoded: [max_store_bytes]u8 = undefined;
    const current = try encode(.{}, &encoded);
    for ([_][]const u8{ current, "{\"schema\":2}", "{invalid}" }, 0..) |prefix, index| {
        var bytes: [max_store_bytes + 1]u8 = @splat(' ');
        @memcpy(bytes[0..prefix.len], prefix);
        const bounded = bytes[0..max_store_bytes];
        switch (index) {
            0 => try std.testing.expectEqualDeep(Settings{}, try decode(std.testing.allocator, bounded)),
            1 => try std.testing.expectError(error.UnsupportedSchema, decode(std.testing.allocator, bounded)),
            else => try std.testing.expectError(error.InvalidSettings, decode(std.testing.allocator, bounded)),
        }
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = file_name, .data = bounded });
        try std.testing.expectEqualDeep(switch (index) {
            0 => Load{ .ready = .{} },
            1 => Load.unsupported_schema,
            else => Load.invalid,
        }, try store.load(std.testing.allocator));
        try std.testing.expectError(error.SettingsTooLarge, decode(std.testing.allocator, &bytes));
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = file_name, .data = &bytes });
        try std.testing.expectEqualDeep(Load.too_large, try store.load(std.testing.allocator));
    }
}

test "source reads reject a changed empty or nonempty file before classifying its format" {
    const Fault = struct {
        var calls: usize = 0;
        fn stat(userdata: ?*anyopaque, file: std.Io.File) std.Io.File.StatError!std.Io.File.Stat {
            var observed = try std.testing.io.vtable.fileStat(userdata, file);
            calls += 1;
            if (calls == 2) observed.size += 1;
            return observed;
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var vtable = std.testing.io.vtable.*;
    vtable.fileStat = Fault.stat;
    var io = std.testing.io;
    io.vtable = &vtable;
    var store: FileStore = .{ .io = io, .dir = tmp.dir };
    for ([_][]const u8{ "", "{}" }) |bytes| {
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = file_name, .data = bytes });
        Fault.calls = 0;
        try std.testing.expectError(error.ReadFailed, store.load(std.testing.allocator));
        // A stable empty/invalid file may be reset, but the racing read above
        // is not evidence of corruption and must not grant that capability.
        store.io = std.testing.io;
        try std.testing.expectEqualDeep(Load.invalid, try store.load(std.testing.allocator));
        store.io = io;
    }
}

test "fixed root discovery handles all switches and shared base without creating directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var absent = try discover(std.testing.io, std.testing.allocator, root, root, .{ .values = @splat(true) });
    defer absent.deinit();
    try std.testing.expectEqual(@as(usize, 0), (try absent.additionalSources()).len);
    for (absent.checks) |check| try std.testing.expectEqualDeep(RootCheck.missing, check);
    for ([_][]const u8{ ".claude/skills", ".codex/skills" }) |path| try tmp.dir.createDirPath(std.testing.io, path);
    for (0..16) |bits| {
        var selected: Selection = .{};
        for (&selected.values, 0..) |*value, index| value.* = bits & (@as(usize, 1) << @intCast(index)) != 0;
        var result = try discover(std.testing.io, std.testing.allocator, root, root, selected);
        defer result.deinit();
        const sources = try result.additionalSources();
        const count = @as(usize, @intFromBool(selected.enabled(.claude_user) or selected.enabled(.claude_workspace))) +
            @as(usize, @intFromBool(selected.enabled(.codex_user) or selected.enabled(.codex_workspace)));
        try std.testing.expectEqual(count, sources.len);
        for (sources) |source| {
            const item = definition(findId(source.source_instance_id).?);
            const project_on = selected.enabled(if (item.ecosystem == .claude) .claude_workspace else .codex_workspace);
            try std.testing.expectEqual(if (project_on) agent.CatalogSourceScope.workspace else .user, source.scope);
        }
        var personal = try discover(std.testing.io, std.testing.allocator, root, null, selected);
        defer personal.deinit();
        for (try personal.additionalSources()) |source| try std.testing.expectEqual(agent.CatalogSourceScope.user, source.scope);
    }
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, ".agents", .{}));
}

test "blocked fixed roots cannot yield a partial source list" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".claude/skills");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".codex", .data = "not a directory" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var result = try discover(std.testing.io, std.testing.allocator, root, null, .{ .values = @splat(true) });
    defer result.deinit();
    try std.testing.expectEqualDeep(RootCheck{ .blocked = .unsupported_entry }, result.checks[@intFromEnum(Id.codex_user)]);
    try std.testing.expectError(error.SourceUnavailable, result.additionalSources());
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".agents", .data = "not a directory" });
    var defaults = try discover(std.testing.io, std.testing.allocator, root, null, .{});
    defer defaults.deinit();
    try std.testing.expectError(error.SourceUnavailable, defaults.additionalSources());
}

test "distinct bases preserve four source identities and scope dependencies" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "home/.claude/skills", "home/.codex/skills", "workspace/.claude/skills", "workspace/.codex/skills" }) |path|
        try tmp.dir.createDirPath(std.testing.io, path);
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, "home", std.testing.allocator);
    defer std.testing.allocator.free(home);
    const workspace = try tmp.dir.realPathFileAlloc(std.testing.io, "workspace", std.testing.allocator);
    defer std.testing.allocator.free(workspace);
    var result = try discover(std.testing.io, std.testing.allocator, home, workspace, .{ .values = @splat(true) });
    defer result.deinit();
    const list = try result.additionalSources();
    try std.testing.expectEqual(@as(usize, 4), list.len);
    for (definitions, list) |item, found| {
        try std.testing.expectEqualStrings(item.source_instance_id, found.source_instance_id);
        try std.testing.expectEqual(item.scope, found.scope);
        const expected = try std.fs.path.join(std.testing.allocator, &.{ if (item.scope == .user) home else workspace, item.ecosystem.directory(), "skills" });
        defer std.testing.allocator.free(expected);
        try std.testing.expectEqualStrings(expected, found.canonical_root);
    }
    const all: Selection = .{ .values = @splat(true) };
    var project_off = all;
    project_off.values[@intFromEnum(Id.claude_workspace)] = false;
    try std.testing.expect(all.relevant(.user).eql(project_off.relevant(.user)));
    try std.testing.expect(!all.relevant(.workspace).eql(project_off.relevant(.workspace)));
}

test "unreadable entries remain failures and disabled sources are not inspected" {
    const Fault = struct {
        fn stat(userdata: ?*anyopaque, dir: std.Io.Dir, path: []const u8, options: std.Io.Dir.StatFileOptions) std.Io.Dir.StatFileError!std.Io.File.Stat {
            if (std.mem.eql(u8, path, ".claude") or std.mem.eql(u8, path, file_name)) return error.AccessDenied;
            return std.testing.io.vtable.dirStatFile(userdata, dir, path, options);
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var vtable = std.testing.io.vtable.*;
    vtable.dirStatFile = Fault.stat;
    var fault_io = std.testing.io;
    fault_io.vtable = &vtable;
    var enabled = try discover(fault_io, std.testing.allocator, root, null, .{ .values = @splat(true) });
    defer enabled.deinit();
    try std.testing.expectEqualDeep(RootCheck{ .blocked = .unreadable }, enabled.checks[@intFromEnum(Id.claude_user)]);
    try std.testing.expectError(error.SourceUnavailable, enabled.additionalSources());
    var disabled = try discover(fault_io, std.testing.allocator, root, null, .{});
    defer disabled.deinit();
    try std.testing.expectEqual(@as(usize, 0), (try disabled.additionalSources()).len);
    var store = try FileStore.init(fault_io, root);
    defer store.deinit();
    try std.testing.expectError(error.ReadFailed, store.load(std.testing.allocator));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, file_name, .{}));
}

test "base inputs must be canonical existing directories" {
    for ([_][]const u8{ "", "relative", "bad\x00base", "\xff" }) |path|
        try std.testing.expectError(error.InvalidBase, discover(std.testing.io, std.testing.allocator, path, null, .{}));
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const missing = try std.fs.path.join(std.testing.allocator, &.{ root, "missing" });
    defer std.testing.allocator.free(missing);
    try std.testing.expectError(error.InvalidBase, discover(std.testing.io, std.testing.allocator, root, missing, .{}));
    try std.testing.expectError(error.DirectoryUnavailable, FileStore.init(std.testing.io, missing));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "missing", .{}));
}

test "root checks reject links at either fixed component and do not inspect disabled sources" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "real/skills");
    try tmp.dir.createDirPath(std.testing.io, ".codex");
    const real = try tmp.dir.realPathFileAlloc(std.testing.io, "real", std.testing.allocator);
    defer std.testing.allocator.free(real);
    tmp.dir.symLink(std.testing.io, real, ".claude", .{ .is_directory = true }) catch |err| {
        if (builtin.os.tag == .windows and (err == error.AccessDenied or err == error.PermissionDenied))
            return error.SkipZigTest;
        return err;
    };
    const skills = try tmp.dir.realPathFileAlloc(std.testing.io, "real/skills", std.testing.allocator);
    defer std.testing.allocator.free(skills);
    try tmp.dir.symLink(std.testing.io, skills, ".codex/skills", .{ .is_directory = true });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var blocked = try discover(std.testing.io, std.testing.allocator, root, null, .{ .values = @splat(true) });
    defer blocked.deinit();
    try std.testing.expectEqualDeep(RootCheck{ .blocked = .unsupported_entry }, blocked.checks[@intFromEnum(Id.claude_user)]);
    try std.testing.expectEqualDeep(RootCheck{ .blocked = .unsupported_entry }, blocked.checks[@intFromEnum(Id.codex_user)]);
    try std.testing.expectError(error.SourceUnavailable, blocked.additionalSources());
    var disabled = try discover(std.testing.io, std.testing.allocator, root, null, .{});
    defer disabled.deinit();
    try std.testing.expectEqual(@as(usize, 0), (try disabled.additionalSources()).len);
}

test "store sync failure distinguishes failed publication from uncertain durability" {
    const Fault = struct {
        var calls: usize = 0;
        var fail_on: usize = 0;

        fn sync(userdata: ?*anyopaque, file: std.Io.File) std.Io.File.SyncError!void {
            calls += 1;
            if (calls == fail_on) return error.InputOutput;
            return std.testing.io.vtable.fileSync(userdata, file);
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var vtable = std.testing.io.vtable.*;
    vtable.fileSync = Fault.sync;
    var fault_io = std.testing.io;
    fault_io.vtable = &vtable;
    var store = try FileStore.init(fault_io, root);
    defer store.deinit();
    Fault.calls = 0;
    Fault.fail_on = 0;
    const original: Settings = .{};
    try store.commit(original);
    const candidate = try original.replacing(.claude, true, 1);
    Fault.calls = 0;
    Fault.fail_on = 1;
    try std.testing.expectError(error.WriteFailed, store.commit(candidate));
    try std.testing.expectEqualDeep(Load{ .ready = original }, try store.load(std.testing.allocator));
    Fault.calls = 0;
    Fault.fail_on = 2;
    try std.testing.expectError(error.PersistenceOutcomeUnknown, store.commit(candidate));
    try std.testing.expectEqualDeep(Load{ .ready = candidate }, try store.load(std.testing.allocator));
    Fault.calls = 0;
    Fault.fail_on = 0;
    try store.commit(candidate);
}

test "settings decode OOM is not classified as corrupt and root allocations are released" {
    const Checks = struct {
        fn decodeAll(allocator: std.mem.Allocator, bytes: []const u8) !void {
            _ = try decode(allocator, bytes);
        }

        fn discoverAll(allocator: std.mem.Allocator, root: []const u8) !void {
            var discovery = try discover(std.testing.io, allocator, root, root, .{ .values = @splat(true) });
            defer discovery.deinit();
            try std.testing.expectEqual(@as(usize, 2), (try discovery.additionalSources()).len);
        }
    };
    var encoded: [max_store_bytes]u8 = undefined;
    const bytes = try encode(.{}, &encoded);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Checks.decodeAll, .{bytes});
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".claude/skills");
    try tmp.dir.createDirPath(std.testing.io, ".codex/skills");
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Checks.discoverAll, .{root});
}
