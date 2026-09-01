//! Product Task immutable, credential-redacted unified-diff store.
//!
//! Application owns the store lifetime and writer lock. Product history owns
//! only logical identities; physical paths never cross the Product boundary.

const std = @import("std");
const builtin = @import("builtin");

pub const digest_bytes = std.crypto.hash.sha2.Sha256.digest_length;
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

fn blobName(identity: Identity, storage: []u8) Error![]const u8 {
    const digest = std.fmt.bytesToHex(identity.digest, .lower);
    return std.fmt.bufPrint(storage, "{d}-{d}-{s}.diff", .{
        identity.run_generation,
        identity.change_order,
        digest,
    }) catch error.InvalidIdentity;
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
