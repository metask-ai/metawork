const std = @import("std");
const builtin = @import("builtin");

pub const key_bytes: usize = 8;
pub const key_hex_bytes: usize = key_bytes * 2;
pub const allocation_attempts: usize = 8;

pub const Error = std.mem.Allocator.Error || error{
    RootUnavailable,
    AllocationUnavailable,
    InvalidAutomaticRoot,
};

/// App-created, opened capability for the reserved automatic Workspace root.
/// `Allocator.init` consumes it even when the surrounding Workbench init later
/// fails, so the App can unconditionally call `deinit` on its moved-from Root.
pub const Root = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    canonical_path: [:0]u8,
    owned: bool = true,

    pub fn open(
        io: std.Io,
        allocator: std.mem.Allocator,
        absolute_path: []const u8,
    ) Error!Root {
        if (absolute_path.len == 0 or
            !std.fs.path.isAbsolute(absolute_path) or
            !std.unicode.utf8ValidateSlice(absolute_path))
            return error.InvalidAutomaticRoot;
        const dir = std.Io.Dir.cwd().createDirPathOpen(
            io,
            absolute_path,
            .{
                .open_options = .{ .follow_symlinks = false },
                .permissions = directoryPermissions(),
            },
        ) catch return error.RootUnavailable;
        errdefer dir.close(io);
        var canonical_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const canonical_len = dir.realPath(io, &canonical_storage) catch
            return error.RootUnavailable;
        const canonical = canonical_storage[0..canonical_len];
        if (!std.fs.path.isAbsolute(canonical) or
            !std.unicode.utf8ValidateSlice(canonical))
            return error.InvalidAutomaticRoot;
        return .{
            .allocator = allocator,
            .io = io,
            .dir = dir,
            .canonical_path = try allocator.dupeZ(u8, canonical),
        };
    }

    fn take(self: *Root) Root {
        std.debug.assert(self.owned);
        self.owned = false;
        return .{
            .allocator = self.allocator,
            .io = self.io,
            .dir = self.dir,
            .canonical_path = self.canonical_path,
        };
    }

    pub fn deinit(self: *Root) void {
        if (!self.owned) return;
        self.dir.close(self.io);
        self.allocator.free(self.canonical_path);
        self.owned = false;
    }
};

pub const Allocation = struct {
    allocator: std.mem.Allocator,
    key: [key_hex_bytes]u8,
    canonical_path: [:0]u8,
    owned: bool = true,

    pub fn keySlice(self: *const Allocation) []const u8 {
        return &self.key;
    }

    pub fn path(self: *const Allocation) []const u8 {
        return self.canonical_path;
    }

    pub fn deinit(self: *Allocation) void {
        if (!self.owned) return;
        self.allocator.free(self.canonical_path);
        self.owned = false;
    }
};

/// Workbench-owned allocator for one-directory-per-automatic-Task roots.
/// It intentionally has no recovery scan or recursive deletion operation.
pub const Allocator = struct {
    root: Root,

    pub fn init(root: *Root) Allocator {
        return .{ .root = root.take() };
    }

    pub fn deinit(self: *Allocator) void {
        self.root.deinit();
        self.* = undefined;
    }

    pub fn canonicalRoot(self: *const Allocator) []const u8 {
        return self.root.canonical_path;
    }

    pub fn containsCanonicalPath(
        self: *const Allocator,
        canonical_path: []const u8,
    ) bool {
        return pathWithin(self.root.canonical_path, canonical_path);
    }

    pub fn allocate(self: *Allocator) Error!Allocation {
        var attempt: usize = 0;
        while (attempt < allocation_attempts) : (attempt += 1) {
            var random: [key_bytes]u8 = undefined;
            std.Io.randomSecure(self.root.io, &random) catch
                return error.AllocationUnavailable;
            const key = std.fmt.bytesToHex(random, .lower);
            self.root.dir.createDir(
                self.root.io,
                &key,
                directoryPermissions(),
            ) catch |err| switch (err) {
                error.PathAlreadyExists => continue,
                else => return error.AllocationUnavailable,
            };
            var directory_exists = true;
            errdefer if (directory_exists)
                self.root.dir.deleteDir(self.root.io, &key) catch {};

            const child = self.root.dir.openDir(
                self.root.io,
                &key,
                .{ .follow_symlinks = false },
            ) catch return error.AllocationUnavailable;
            defer child.close(self.root.io);
            var canonical_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const canonical_len = child.realPath(
                self.root.io,
                &canonical_storage,
            ) catch return error.AllocationUnavailable;
            const canonical = canonical_storage[0..canonical_len];
            if (!strictPathWithin(self.root.canonical_path, canonical) or
                !std.mem.eql(u8, std.fs.path.basename(canonical), &key) or
                !std.unicode.utf8ValidateSlice(canonical))
                return error.InvalidAutomaticRoot;
            const owned_path = try self.root.allocator.dupeZ(u8, canonical);
            directory_exists = false;
            return .{
                .allocator = self.root.allocator,
                .key = key,
                .canonical_path = owned_path,
            };
        }
        return error.AllocationUnavailable;
    }

    /// Deletes only the exact newly allocated directory and only while it is
    /// still empty. A failure leaves the directory in place and is observable.
    pub fn rollback(self: *Allocator, allocation: *Allocation) bool {
        std.debug.assert(allocation.owned);
        const deleted = blk: {
            self.root.dir.deleteDir(
                self.root.io,
                allocation.keySlice(),
            ) catch break :blk false;
            break :blk true;
        };
        allocation.deinit();
        return deleted;
    }
};

fn pathWithin(parent: []const u8, child: []const u8) bool {
    if (pathEqual(parent, child)) return true;
    if (child.len <= parent.len or !pathPrefix(parent, child)) return false;
    if (parent.len != 0 and std.fs.path.isSep(parent[parent.len - 1]))
        return true;
    return std.fs.path.isSep(child[parent.len]);
}

fn strictPathWithin(parent: []const u8, child: []const u8) bool {
    return !pathEqual(parent, child) and pathWithin(parent, child);
}

fn pathEqual(left: []const u8, right: []const u8) bool {
    return if (builtin.os.tag == .windows)
        std.ascii.eqlIgnoreCase(left, right)
    else
        std.mem.eql(u8, left, right);
}

fn pathPrefix(parent: []const u8, child: []const u8) bool {
    if (parent.len > child.len) return false;
    return if (builtin.os.tag == .windows)
        std.ascii.eqlIgnoreCase(parent, child[0..parent.len])
    else
        std.mem.startsWith(u8, child, parent);
}

fn directoryPermissions() std.Io.File.Permissions {
    return if (builtin.os.tag == .windows)
        .default_dir
    else
        .fromMode(0o700);
}

test "automatic Workspace allocator allocates private independent child roots" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const duplicate = try tmp.dir.openDir(std.testing.io, ".", .{});
    var canonical_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const canonical_len = try duplicate.realPath(
        std.testing.io,
        &canonical_storage,
    );
    duplicate.close(std.testing.io);
    var root = try Root.open(
        std.testing.io,
        std.testing.allocator,
        canonical_storage[0..canonical_len],
    );
    defer root.deinit();
    var store = Allocator.init(&root);
    defer store.deinit();

    var first = try store.allocate();
    defer first.deinit();
    var second = try store.allocate();
    defer second.deinit();
    try std.testing.expectEqual(key_hex_bytes, first.keySlice().len);
    try std.testing.expect(!std.mem.eql(u8, first.keySlice(), second.keySlice()));
    try std.testing.expect(store.containsCanonicalPath(first.path()));
    try std.testing.expect(store.containsCanonicalPath(second.path()));
    for (first.keySlice()) |byte|
        try std.testing.expect(std.ascii.isDigit(byte) or (byte >= 'a' and byte <= 'f'));
    if (builtin.os.tag != .windows) {
        const child = try store.root.dir.openDir(
            std.testing.io,
            first.keySlice(),
            .{ .follow_symlinks = false },
        );
        defer child.close(std.testing.io);
        const stat = try child.stat(std.testing.io);
        try std.testing.expectEqual(
            @as(std.posix.mode_t, 0o700),
            stat.permissions.toMode() & 0o777,
        );
    }
}

test "automatic Workspace rollback removes only an empty allocation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var canonical_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const canonical_len = try tmp.dir.realPath(
        std.testing.io,
        &canonical_storage,
    );
    var root = try Root.open(
        std.testing.io,
        std.testing.allocator,
        canonical_storage[0..canonical_len],
    );
    var store = Allocator.init(&root);
    defer store.deinit();

    var allocation = try store.allocate();
    var key: [key_hex_bytes]u8 = undefined;
    @memcpy(&key, allocation.keySlice());
    try std.testing.expect(store.rollback(&allocation));
    try std.testing.expectError(
        error.FileNotFound,
        store.root.dir.openDir(std.testing.io, &key, .{}),
    );
}

test "automatic root rejects relative input and path prefix confusion" {
    try std.testing.expectError(
        error.InvalidAutomaticRoot,
        Root.open(std.testing.io, std.testing.allocator, "relative"),
    );
    const root = if (builtin.os.tag == .windows) "C:\\MetaWork\\workspaces" else "/metawork/workspaces";
    const sibling = if (builtin.os.tag == .windows) "C:\\MetaWork\\workspaces-old" else "/metawork/workspaces-old";
    const child = if (builtin.os.tag == .windows) "C:\\MetaWork\\workspaces\\0000000000000001" else "/metawork/workspaces/0000000000000001";
    try std.testing.expect(!pathWithin(root, sibling));
    try std.testing.expect(pathWithin(root, child));
    try std.testing.expect(!strictPathWithin(root, root));
}
