//! Bounded checks for canonical Skill roots and the bundled Skill source.
const std = @import("std");
const builtin = @import("builtin");
const agent = @import("metawork_agent");

pub const builtin_source_instance_id = "metawork.builtin";
pub const default_source_priority: i32 = 999;
pub const Ecosystem = enum { agents, claude, codex };

pub const RootFailure = enum { unreadable, unsupported_entry, changed };
pub const RootCheck = union(enum) { disabled, missing, checked, blocked: RootFailure };

/// Check only the two fixed root components, never enumerate Skill candidates.
/// This is a point-in-time observation, not a durable filesystem capability.
pub fn checkRoot(io: std.Io, base: std.Io.Dir) RootCheck {
    var parent = switch (openComponent(io, base, ".agents")) {
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
    builtin: RootCheck = .disabled,
    default_user: RootCheck,
    default_workspace: RootCheck,
};

pub const Discovery = struct {
    allocator: std.mem.Allocator,
    builtin: RootCheck = .disabled,
    default_user: RootCheck,
    default_workspace: RootCheck,
    owned_sources: [1]agent.CatalogSource = undefined,
    count: usize = 0,

    pub fn rootChecks(self: *const Discovery) RootChecks {
        return .{ .builtin = self.builtin, .default_user = self.default_user, .default_workspace = self.default_workspace };
    }

    pub fn appendBuiltin(self: *Discovery, io: std.Io, canonical_root: []const u8) std.mem.Allocator.Error!void {
        const dir = openCanonicalBase(io, canonical_root, false) catch {
            self.builtin = .{ .blocked = .unreadable };
            return;
        };
        defer dir.close(io);
        std.debug.assert(self.count < self.owned_sources.len);
        self.owned_sources[self.count] = .{
            .canonical_root = try self.allocator.dupe(u8, canonical_root),
            .scope = .user,
            .source_instance_id = builtin_source_instance_id,
            .priority = 0,
        };
        self.count += 1;
        self.builtin = .checked;
    }

    pub fn deinit(self: *Discovery) void {
        for (self.owned_sources[0..self.count]) |source| self.allocator.free(source.canonical_root);
        self.* = undefined;
    }

    /// Refuse a partial usable list if any enabled/default root was blocked.
    pub fn additionalSources(self: *const Discovery) error{SourceUnavailable}![]const agent.CatalogSource {
        if (self.builtin == .blocked) return error.SourceUnavailable;
        if (self.default_user == .blocked or self.default_workspace == .blocked) return error.SourceUnavailable;
        return self.owned_sources[0..self.count];
    }
};

/// Validate default roots before passing them to AgentCore.
pub fn discover(
    io: std.Io,
    allocator: std.mem.Allocator,
    canonical_home: []const u8,
    canonical_workspace: ?[]const u8,
) (std.mem.Allocator.Error || error{InvalidBase})!Discovery {
    const home = try openCanonicalBase(io, canonical_home, false);
    defer home.close(io);
    const workspace = if (canonical_workspace) |path| try openCanonicalBase(io, path, false) else null;
    defer if (workspace) |dir| dir.close(io);
    return .{
        .allocator = allocator,
        .default_user = checkRoot(io, home),
        .default_workspace = if (workspace) |dir| checkRoot(io, dir) else .disabled,
    };
}

test "builtin root joins the canonical query and missing root rejects the entire source list" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home");
    try tmp.dir.createDirPath(std.testing.io, "builtin/docx");
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, "home", std.testing.allocator);
    defer std.testing.allocator.free(home);
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, "builtin", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var discovery = try discover(std.testing.io, std.testing.allocator, home, null);
    defer discovery.deinit();
    try discovery.appendBuiltin(std.testing.io, root);
    const selected = try discovery.additionalSources();
    try std.testing.expectEqual(@as(usize, 1), selected.len);
    try std.testing.expectEqualStrings(root, selected[0].canonical_root);
    try std.testing.expectEqualStrings(builtin_source_instance_id, selected[0].source_instance_id);
    try std.testing.expectEqual(agent.CatalogSourceScope.user, selected[0].scope);
    try std.testing.expectEqualDeep(RootCheck.checked, discovery.rootChecks().builtin);

    var missing = try discover(std.testing.io, std.testing.allocator, home, null);
    defer missing.deinit();
    const missing_path = try std.fs.path.join(std.testing.allocator, &.{ root, "missing" });
    defer std.testing.allocator.free(missing_path);
    try missing.appendBuiltin(std.testing.io, missing_path);
    try std.testing.expectError(error.SourceUnavailable, missing.additionalSources());
}

test "only canonical agents roots participate in discovery" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".claude/skills/demo");
    try tmp.dir.createDirPath(std.testing.io, ".codex/skills/demo");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "skill-sources.json", .data = "{invalid legacy settings}" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var discovery = try discover(std.testing.io, std.testing.allocator, root, root);
    defer discovery.deinit();
    try std.testing.expectEqualDeep(RootCheck.missing, discovery.default_user);
    try std.testing.expectEqualDeep(RootCheck.missing, discovery.default_workspace);
    try std.testing.expectEqual(@as(usize, 0), (try discovery.additionalSources()).len);
    try tmp.dir.createDirPath(std.testing.io, ".agents/skills/demo");
    var available = try discover(std.testing.io, std.testing.allocator, root, root);
    defer available.deinit();
    try std.testing.expectEqualDeep(RootCheck.checked, available.default_user);
    try std.testing.expectEqualDeep(RootCheck.checked, available.default_workspace);
}

test "default root checks reject links at either component" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "real/skills");
    const real = try tmp.dir.realPathFileAlloc(std.testing.io, "real", std.testing.allocator);
    defer std.testing.allocator.free(real);
    tmp.dir.symLink(std.testing.io, real, ".agents", .{ .is_directory = true }) catch |err| {
        if (builtin.os.tag == .windows and (err == error.AccessDenied or err == error.PermissionDenied))
            return error.SkipZigTest;
        return err;
    };
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var blocked = try discover(std.testing.io, std.testing.allocator, root, null);
    defer blocked.deinit();
    try std.testing.expectError(error.SourceUnavailable, blocked.additionalSources());
    try tmp.dir.deleteFile(std.testing.io, ".agents");
    try tmp.dir.createDirPath(std.testing.io, ".agents");
    const skills = try tmp.dir.realPathFileAlloc(std.testing.io, "real/skills", std.testing.allocator);
    defer std.testing.allocator.free(skills);
    try tmp.dir.symLink(std.testing.io, skills, ".agents/skills", .{ .is_directory = true });
    var nested = try discover(std.testing.io, std.testing.allocator, root, null);
    defer nested.deinit();
    try std.testing.expectError(error.SourceUnavailable, nested.additionalSources());
}

test "default bases must be canonical existing directories" {
    for ([_][]const u8{ "", "relative", "bad\x00base", "\xff" }) |path|
        try std.testing.expectError(error.InvalidBase, discover(std.testing.io, std.testing.allocator, path, null));
}
