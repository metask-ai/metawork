//! Product Task immutable, credential-redacted unified-diff store.
//!
//! Application owns the store lifetime and writer lock. Product history owns
//! only logical identities; physical paths never cross the Product boundary.

const std = @import("std");
const builtin = @import("builtin");

pub const digest_bytes = std.crypto.hash.sha2.Sha256.digest_length;
pub const max_task_directories: usize = 4096;
pub const max_blobs_per_task: usize = 16 * 1024;
const lock_file_name = ".file-change-store.lock";

pub const Error = error{
    DirectoryUnavailable,
    WriterAlreadyActive,
    InvalidIdentity,
    ResourceLimit,
    WriteFailed,
    PersistenceOutcomeUnknown,
    BlobMissing,
    BlobMismatch,
    UnsupportedContent,
} || std.mem.Allocator.Error;

pub const Identity = struct {
    task_id: u64,
    run_generation: u64,
    change_order: u64,
    digest: [digest_bytes]u8,
    byte_size: u64,
};

pub const FileStore = struct {
    io: std.Io,
    root: std.Io.Dir,
    lock_file: std.Io.File,

    pub fn init(io: std.Io, absolute_directory: []const u8) Error!FileStore {
        if (!std.fs.path.isAbsolute(absolute_directory))
            return error.DirectoryUnavailable;
        const root = std.Io.Dir.cwd().createDirPathOpen(
            io,
            absolute_directory,
            .{
                .open_options = .{ .follow_symlinks = false },
                .permissions = directoryPermissions(),
            },
        ) catch return error.DirectoryUnavailable;
        errdefer root.close(io);
        const lock_file = openOrCreateLock(io, root) catch |err| switch (err) {
            error.WouldBlock => return error.WriterAlreadyActive,
            else => return error.DirectoryUnavailable,
        };
        return .{ .io = io, .root = root, .lock_file = lock_file };
    }

    pub fn deinit(self: *FileStore) void {
        self.lock_file.close(self.io);
        self.root.close(self.io);
        self.* = undefined;
    }

    pub fn put(
        self: *FileStore,
        task_id: u64,
        run_generation: u64,
        change_order: u64,
        content: []const u8,
        max_bytes: usize,
    ) Error!Identity {
        if (task_id == 0 or run_generation == 0 or change_order == 0 or
            content.len == 0 or content.len > max_bytes or
            !std.unicode.utf8ValidateSlice(content))
            return error.InvalidIdentity;
        var digest: [digest_bytes]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(content, &digest, .{});
        const identity: Identity = .{
            .task_id = task_id,
            .run_generation = run_generation,
            .change_order = change_order,
            .digest = digest,
            .byte_size = content.len,
        };
        var task_name_storage: [32]u8 = undefined;
        const task_name = try taskDirectoryName(task_id, &task_name_storage);
        var task_dir = self.root.createDirPathOpen(
            self.io,
            task_name,
            .{
                .open_options = .{ .follow_symlinks = false },
                .permissions = directoryPermissions(),
            },
        ) catch return error.DirectoryUnavailable;
        defer task_dir.close(self.io);
        if (!syncDirectory(self.io, self.root, null))
            return error.PersistenceOutcomeUnknown;
        var blob_name_storage: [160]u8 = undefined;
        const blob_name = try blobName(identity, &blob_name_storage);
        if (task_dir.openFile(self.io, blob_name, .{
            .follow_symlinks = false,
            .resolve_beneath = true,
        })) |existing| {
            existing.close(self.io);
            try self.verify(identity, max_bytes);
            return identity;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return error.WriteFailed,
        }
        var random: [8]u8 = undefined;
        std.Io.randomSecure(self.io, &random) catch return error.WriteFailed;
        const random_hex = std.fmt.bytesToHex(random, .lower);
        var temp_name_storage: [64]u8 = undefined;
        const temp_name = std.fmt.bufPrint(
            &temp_name_storage,
            ".file-change.{s}.tmp",
            .{random_hex},
        ) catch return error.WriteFailed;
        const file = task_dir.createFile(self.io, temp_name, .{
            .exclusive = true,
            .permissions = privateFilePermissions(),
            .resolve_beneath = true,
        }) catch return error.WriteFailed;
        var open = true;
        var temporary = true;
        defer {
            if (open) file.close(self.io);
            if (temporary) task_dir.deleteFile(self.io, temp_name) catch {};
        }
        file.writeStreamingAll(self.io, content) catch return error.WriteFailed;
        file.sync(self.io) catch return error.WriteFailed;
        file.close(self.io);
        open = false;
        task_dir.rename(temp_name, task_dir, blob_name, self.io) catch
            return error.WriteFailed;
        temporary = false;
        if (!syncDirectory(self.io, task_dir, blob_name))
            return error.PersistenceOutcomeUnknown;
        return identity;
    }

    pub fn readAlloc(
        self: *FileStore,
        allocator: std.mem.Allocator,
        identity: Identity,
        max_bytes: usize,
    ) Error![]u8 {
        try validateIdentity(identity, max_bytes);
        var task_name_storage: [32]u8 = undefined;
        const task_name = try taskDirectoryName(identity.task_id, &task_name_storage);
        var task_dir = self.root.openDir(self.io, task_name, .{
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.FileNotFound => return error.BlobMissing,
            else => return error.DirectoryUnavailable,
        };
        defer task_dir.close(self.io);
        var name_storage: [160]u8 = undefined;
        const name = try blobName(identity, &name_storage);
        var file = task_dir.openFile(self.io, name, .{
            .follow_symlinks = false,
            .resolve_beneath = true,
        }) catch |err| switch (err) {
            error.FileNotFound => return error.BlobMissing,
            else => return error.WriteFailed,
        };
        if (builtin.os.tag == .windows) file.flags.nonblocking = true;
        defer file.close(self.io);
        const length = file.length(self.io) catch return error.WriteFailed;
        if (length != identity.byte_size) return error.BlobMismatch;
        const bytes = try allocator.alloc(u8, @intCast(length));
        errdefer allocator.free(bytes);
        if ((file.readPositionalAll(self.io, bytes, 0) catch return error.WriteFailed) != length)
            return error.WriteFailed;
        var digest: [digest_bytes]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        if (!std.mem.eql(u8, &digest, &identity.digest)) return error.BlobMismatch;
        if (!std.unicode.utf8ValidateSlice(bytes)) return error.UnsupportedContent;
        return bytes;
    }

    pub fn verify(self: *FileStore, identity: Identity, max_bytes: usize) Error!void {
        const bytes = try self.readAlloc(std.heap.page_allocator, identity, max_bytes);
        defer std.heap.page_allocator.free(bytes);
    }

    pub fn delete(self: *FileStore, identity: Identity, max_bytes: usize) void {
        validateIdentity(identity, max_bytes) catch return;
        var task_storage: [32]u8 = undefined;
        const task_name = taskDirectoryName(identity.task_id, &task_storage) catch return;
        var task_dir = self.root.openDir(self.io, task_name, .{
            .follow_symlinks = false,
        }) catch return;
        defer task_dir.close(self.io);
        var name_storage: [160]u8 = undefined;
        const name = blobName(identity, &name_storage) catch return;
        task_dir.deleteFile(self.io, name) catch return;
        _ = syncDirectory(self.io, task_dir, null);
    }

    pub fn deleteTask(self: *FileStore, task_id: u64) void {
        var storage: [32]u8 = undefined;
        const name = taskDirectoryName(task_id, &storage) catch return;
        self.root.deleteTree(self.io, name) catch return;
        _ = syncDirectory(self.io, self.root, null);
    }

    pub fn cleanupOrphans(
        self: *FileStore,
        allocator: std.mem.Allocator,
        referenced: []const Identity,
        max_bytes: usize,
    ) Error!void {
        const capacity = max_task_directories * max_blobs_per_task;
        var entries: std.ArrayList(StoredEntry) = .empty;
        defer entries.deinit(allocator);
        var task_ids: std.ArrayList(u64) = .empty;
        defer task_ids.deinit(allocator);
        var root_iterable = self.root.openDir(self.io, ".", .{
            .iterate = true,
            .follow_symlinks = false,
        }) catch return error.DirectoryUnavailable;
        defer root_iterable.close(self.io);
        var root_iterator = root_iterable.iterate();
        var task_count: usize = 0;
        while (root_iterator.next(self.io) catch return error.DirectoryUnavailable) |entry| {
            if (entry.kind == .file and std.mem.eql(u8, entry.name, lock_file_name))
                continue;
            if (entry.kind != .directory) continue;
            const task_id = parseTaskDirectory(entry.name) orelse continue;
            if (task_count == max_task_directories) return error.ResourceLimit;
            task_count += 1;
            try task_ids.append(allocator, task_id);
            var task_dir = self.root.openDir(self.io, entry.name, .{
                .iterate = true,
                .follow_symlinks = false,
            }) catch return error.DirectoryUnavailable;
            defer task_dir.close(self.io);
            var iterator = task_dir.iterate();
            var task_entries: usize = 0;
            while (iterator.next(self.io) catch return error.DirectoryUnavailable) |blob_entry| {
                if (blob_entry.kind != .file) continue;
                const stored = parseStoredEntry(
                    self.io,
                    task_dir,
                    task_id,
                    blob_entry.name,
                    max_bytes,
                ) catch |err| switch (err) {
                    error.InvalidIdentity, error.ResourceLimit => continue,
                    else => return err,
                };
                if (task_entries == max_blobs_per_task or
                    entries.items.len == capacity) return error.ResourceLimit;
                task_entries += 1;
                try entries.append(allocator, stored);
            }
        }
        for (entries.items) |stored| {
            if (!stored.temporary and identityReferenced(stored.identity, referenced))
                continue;
            var task_name_storage: [32]u8 = undefined;
            const task_name = try taskDirectoryName(
                stored.identity.task_id,
                &task_name_storage,
            );
            var task_dir = self.root.openDir(self.io, task_name, .{
                .follow_symlinks = false,
            }) catch return error.DirectoryUnavailable;
            defer task_dir.close(self.io);
            task_dir.deleteFile(self.io, stored.name()) catch return error.WriteFailed;
            if (!syncDirectory(self.io, task_dir, null))
                return error.PersistenceOutcomeUnknown;
        }
        for (task_ids.items) |task_id| try self.deleteTaskDirectoryIfEmpty(task_id);
    }

    fn deleteTaskDirectoryIfEmpty(self: *FileStore, task_id: u64) Error!void {
        var task_name_storage: [32]u8 = undefined;
        const task_name = try taskDirectoryName(task_id, &task_name_storage);
        var task_dir = self.root.openDir(self.io, task_name, .{
            .iterate = true,
            .follow_symlinks = false,
        }) catch return error.DirectoryUnavailable;
        var iterator = task_dir.iterate();
        const empty = (iterator.next(self.io) catch {
            task_dir.close(self.io);
            return error.DirectoryUnavailable;
        }) == null;
        task_dir.close(self.io);
        if (!empty) return;
        self.root.deleteDir(self.io, task_name) catch return error.WriteFailed;
        if (!syncDirectory(self.io, self.root, null))
            return error.PersistenceOutcomeUnknown;
    }
};

const StoredEntry = struct {
    identity: Identity,
    file_name: [160]u8,
    file_name_len: usize,
    temporary: bool,

    fn name(self: *const StoredEntry) []const u8 {
        return self.file_name[0..self.file_name_len];
    }
};

fn validateIdentity(identity: Identity, max_bytes: usize) Error!void {
    if (identity.task_id == 0 or identity.run_generation == 0 or
        identity.change_order == 0 or identity.byte_size == 0 or
        identity.byte_size > max_bytes)
        return error.InvalidIdentity;
}

fn taskDirectoryName(task_id: u64, storage: []u8) Error![]const u8 {
    if (task_id == 0) return error.InvalidIdentity;
    return std.fmt.bufPrint(storage, "{d}", .{task_id}) catch
        error.InvalidIdentity;
}

fn parseTaskDirectory(name: []const u8) ?u64 {
    const task_id = std.fmt.parseInt(u64, name, 10) catch return null;
    if (task_id == 0) return null;
    var canonical_storage: [32]u8 = undefined;
    const canonical = taskDirectoryName(task_id, &canonical_storage) catch return null;
    return if (std.mem.eql(u8, canonical, name)) task_id else null;
}

fn blobName(identity: Identity, storage: []u8) Error![]const u8 {
    const digest = std.fmt.bytesToHex(identity.digest, .lower);
    return std.fmt.bufPrint(storage, "{d}-{d}-{s}.diff", .{
        identity.run_generation,
        identity.change_order,
        digest,
    }) catch error.InvalidIdentity;
}

fn parseStoredEntry(
    io: std.Io,
    task_dir: std.Io.Dir,
    task_id: u64,
    name: []const u8,
    max_bytes: usize,
) Error!StoredEntry {
    if (name.len > 160) return error.InvalidIdentity;
    var file_name = [_]u8{0} ** 160;
    @memcpy(file_name[0..name.len], name);
    if (std.mem.startsWith(u8, name, ".file-change.") and
        std.mem.endsWith(u8, name, ".tmp") and
        name.len == ".file-change.".len + 16 + ".tmp".len and
        isLowerHex(name[".file-change.".len .. name.len - ".tmp".len]))
        return .{
            .identity = .{
                .task_id = task_id,
                .run_generation = 0,
                .change_order = 0,
                .digest = [_]u8{0} ** digest_bytes,
                .byte_size = 0,
            },
            .file_name = file_name,
            .file_name_len = name.len,
            .temporary = true,
        };
    if (!std.mem.endsWith(u8, name, ".diff")) return error.InvalidIdentity;
    const stem = name[0 .. name.len - ".diff".len];
    const first = std.mem.indexOfScalar(u8, stem, '-') orelse
        return error.InvalidIdentity;
    const second_relative = std.mem.indexOfScalar(u8, stem[first + 1 ..], '-') orelse
        return error.InvalidIdentity;
    const second = first + 1 + second_relative;
    if (first == 0 or second == first + 1 or stem.len - second - 1 != digest_bytes * 2)
        return error.InvalidIdentity;
    const run_generation = std.fmt.parseInt(u64, stem[0..first], 10) catch
        return error.InvalidIdentity;
    const change_order = std.fmt.parseInt(u64, stem[first + 1 .. second], 10) catch
        return error.InvalidIdentity;
    var digest: [digest_bytes]u8 = undefined;
    _ = std.fmt.hexToBytes(&digest, stem[second + 1 ..]) catch
        return error.InvalidIdentity;
    var file = task_dir.openFile(io, name, .{
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch return error.DirectoryUnavailable;
    defer file.close(io);
    const length = file.length(io) catch return error.DirectoryUnavailable;
    const identity: Identity = .{
        .task_id = task_id,
        .run_generation = run_generation,
        .change_order = change_order,
        .digest = digest,
        .byte_size = length,
    };
    try validateIdentity(identity, max_bytes);
    var canonical_storage: [160]u8 = undefined;
    const canonical = try blobName(identity, &canonical_storage);
    if (!std.mem.eql(u8, canonical, name)) return error.InvalidIdentity;
    return .{
        .identity = identity,
        .file_name = file_name,
        .file_name_len = name.len,
        .temporary = false,
    };
}

fn identityReferenced(identity: Identity, referenced: []const Identity) bool {
    for (referenced) |candidate| {
        if (candidate.task_id == identity.task_id and
            candidate.run_generation == identity.run_generation and
            candidate.change_order == identity.change_order and
            candidate.byte_size == identity.byte_size and
            std.mem.eql(u8, &candidate.digest, &identity.digest))
            return true;
    }
    return false;
}

fn isLowerHex(value: []const u8) bool {
    for (value) |byte| if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f'))
        return false;
    return true;
}

fn openOrCreateLock(io: std.Io, dir: std.Io.Dir) !std.Io.File {
    const existing = dir.openFile(io, lock_file_name, .{
        .mode = .read_write,
        .lock = .exclusive,
        .lock_nonblocking = true,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (existing) |file| return file;
    return dir.createFile(io, lock_file_name, .{
        .read = true,
        .truncate = false,
        .exclusive = true,
        .lock = .exclusive,
        .lock_nonblocking = true,
        .permissions = privateFilePermissions(),
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.PathAlreadyExists => return dir.openFile(io, lock_file_name, .{
            .mode = .read_write,
            .lock = .exclusive,
            .lock_nonblocking = true,
            .follow_symlinks = false,
            .resolve_beneath = true,
        }),
        else => return err,
    };
}

fn syncDirectory(io: std.Io, dir: std.Io.Dir, target_name: ?[]const u8) bool {
    if (builtin.os.tag == .windows) {
        const name = target_name orelse return true;
        const file = dir.openFile(io, name, .{
            .mode = .read_write,
            .allow_directory = false,
            .follow_symlinks = false,
            .resolve_beneath = true,
        }) catch return false;
        defer file.close(io);
        file.sync(io) catch return false;
        return true;
    }
    const directory_file: std.Io.File = .{
        .handle = dir.handle,
        .flags = .{ .nonblocking = false },
    };
    directory_file.sync(io) catch return false;
    return true;
}

fn directoryPermissions() std.Io.File.Permissions {
    return if (builtin.os.tag == .windows) .default_dir else .fromMode(0o700);
}

fn privateFilePermissions() std.Io.File.Permissions {
    return if (builtin.os.tag == .windows) .default_file else .fromMode(0o600);
}

test "file change store writes immutable verified diffs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_storage);
    var store = try FileStore.init(std.testing.io, root_storage[0..root_len]);
    defer store.deinit();
    try std.testing.expectError(
        error.WriterAlreadyActive,
        FileStore.init(std.testing.io, root_storage[0..root_len]),
    );
    const identity = try store.put(7, 2, 3, "@@ -1 +1 @@\n-old\n+new\n", 1024);
    const restored = try store.readAlloc(std.testing.allocator, identity, 1024);
    defer std.testing.allocator.free(restored);
    try std.testing.expectEqualStrings("@@ -1 +1 @@\n-old\n+new\n", restored);
    store.delete(identity, 1024);
    try std.testing.expectError(
        error.BlobMissing,
        store.readAlloc(std.testing.allocator, identity, 1024),
    );
}

test "file change store cleans only unreferenced blobs and empty task directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_storage);
    var store = try FileStore.init(std.testing.io, root_storage[0..root_len]);
    defer store.deinit();

    const retained = try store.put(7, 2, 3, "retained", 1024);
    const orphan = try store.put(7, 2, 4, "orphan", 1024);
    const other_task = try store.put(8, 1, 1, "other", 1024);
    try store.root.writeFile(std.testing.io, .{
        .sub_path = "foreign-root.txt",
        .data = "leave me",
    });
    var foreign_dir = try store.root.createDirPathOpen(
        std.testing.io,
        "foreign-directory",
        .{},
    );
    foreign_dir.close(std.testing.io);
    var task_dir = try store.root.openDir(std.testing.io, "7", .{});
    try task_dir.writeFile(std.testing.io, .{
        .sub_path = "foreign-artifact.txt",
        .data = "leave me too",
    });
    task_dir.close(std.testing.io);
    try store.cleanupOrphans(std.testing.allocator, &.{retained}, 1024);

    const restored = try store.readAlloc(std.testing.allocator, retained, 1024);
    defer std.testing.allocator.free(restored);
    try std.testing.expectEqualStrings("retained", restored);
    try std.testing.expectError(
        error.BlobMissing,
        store.readAlloc(std.testing.allocator, orphan, 1024),
    );
    try std.testing.expectError(
        error.BlobMissing,
        store.readAlloc(std.testing.allocator, other_task, 1024),
    );
    var foreign_root = try store.root.openFile(
        std.testing.io,
        "foreign-root.txt",
        .{ .follow_symlinks = false },
    );
    foreign_root.close(std.testing.io);
    var foreign_artifact_dir = try store.root.openDir(std.testing.io, "7", .{});
    var foreign_artifact = try foreign_artifact_dir.openFile(
        std.testing.io,
        "foreign-artifact.txt",
        .{ .follow_symlinks = false },
    );
    foreign_artifact.close(std.testing.io);
    foreign_artifact_dir.close(std.testing.io);
}
