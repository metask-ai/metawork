const std = @import("std");
const builtin = @import("builtin");

pub const key_bytes: usize = 8;
pub const key_hex_bytes: usize = key_bytes * 2;
pub const allocation_attempts: usize = 8;

pub const PathSemantics = enum { posix, windows };

pub fn nativePathSemantics() PathSemantics {
    return if (builtin.os.tag == .windows) .windows else .posix;
}

pub fn pathEqualFor(
    semantics: PathSemantics,
    left: []const u8,
    right: []const u8,
) bool {
    return switch (semantics) {
        .windows => std.ascii.eqlIgnoreCase(left, right),
        .posix => std.mem.eql(u8, left, right),
    };
}

pub fn pathWithinFor(
    semantics: PathSemantics,
    parent: []const u8,
    child: []const u8,
) bool {
    if (pathEqualFor(semantics, parent, child)) return true;
    if (child.len <= parent.len or !pathPrefixFor(semantics, parent, child))
        return false;
    if (parent.len != 0 and isSeparatorFor(semantics, parent[parent.len - 1]))
        return true;
    return isSeparatorFor(semantics, child[parent.len]);
}

pub fn strictPathWithinFor(
    semantics: PathSemantics,
    parent: []const u8,
    child: []const u8,
) bool {
    return !pathEqualFor(semantics, parent, child) and
        pathWithinFor(semantics, parent, child);
}

pub fn pathEqual(left: []const u8, right: []const u8) bool {
    return pathEqualFor(nativePathSemantics(), left, right);
}

pub fn pathWithin(parent: []const u8, child: []const u8) bool {
    return pathWithinFor(nativePathSemantics(), parent, child);
}

pub fn strictPathWithin(parent: []const u8, child: []const u8) bool {
    return strictPathWithinFor(nativePathSemantics(), parent, child);
}

pub const Error = std.mem.Allocator.Error || error{
    RootUnavailable,
    AllocationUnavailable,
    InvalidAutomaticRoot,
};

/// Product-created, opened capability for the reserved automatic Workspace root.
/// `Allocator.init` consumes it even when the surrounding Product Control init later
/// fails, so the caller can unconditionally call `deinit` on its moved-from Root.
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
        return openInternal(io, allocator, absolute_path, true);
    }

    pub fn openExisting(
        io: std.Io,
        allocator: std.mem.Allocator,
        absolute_path: []const u8,
    ) Error!Root {
        return openInternal(io, allocator, absolute_path, false);
    }

    fn openInternal(
        io: std.Io,
        allocator: std.mem.Allocator,
        absolute_path: []const u8,
        create: bool,
    ) Error!Root {
        if (absolute_path.len == 0 or
            !std.fs.path.isAbsolute(absolute_path) or
            !std.unicode.utf8ValidateSlice(absolute_path))
            return error.InvalidAutomaticRoot;
        const dir = if (create)
            std.Io.Dir.cwd().createDirPathOpen(
                io,
                absolute_path,
                .{
                    .open_options = .{ .follow_symlinks = false },
                    .permissions = directoryPermissions(),
                },
            ) catch return error.RootUnavailable
        else
            std.Io.Dir.cwd().openDir(
                io,
                absolute_path,
                .{ .follow_symlinks = false },
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

    pub fn canonicalPath(self: *const Root) []const u8 {
        return self.canonical_path;
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

/// Product Control-owned allocator for one-directory-per-automatic-Task roots.
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

fn pathPrefixFor(
    semantics: PathSemantics,
    parent: []const u8,
    child: []const u8,
) bool {
    if (parent.len > child.len) return false;
    return switch (semantics) {
        .windows => std.ascii.eqlIgnoreCase(parent, child[0..parent.len]),
        .posix => std.mem.startsWith(u8, child, parent),
    };
}

fn isSeparatorFor(semantics: PathSemantics, byte: u8) bool {
    return switch (semantics) {
        .windows => byte == '\\' or byte == '/',
        .posix => byte == '/',
    };
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

test "automatic root pure path semantics model Windows without a Windows runner" {
    try std.testing.expect(pathEqualFor(
        .windows,
        "C:\\MetaWork\\workspaces",
        "c:\\metawork\\WORKSPACES",
    ));
    try std.testing.expect(pathWithinFor(
        .windows,
        "C:\\MetaWork\\workspaces",
        "c:\\metawork\\WORKSPACES\\0000000000000001",
    ));
    try std.testing.expect(!pathWithinFor(
        .windows,
        "C:\\MetaWork\\workspaces",
        "C:\\MetaWork\\workspaces-old",
    ));
    try std.testing.expect(!pathEqualFor(.posix, "/MetaWork", "/metawork"));
}
