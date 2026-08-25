//! Product Task immutable checkpoint blob store.
//!
//! Application owns this value's process lifetime so the exclusive writer
//! lock spans restore through shutdown. AgentCore bytes enter only through a
//! bounded streaming Writer; descriptors never contain physical paths.

const std = @import("std");
const builtin = @import("builtin");

pub const digest_bytes = 32;
pub const max_task_directories: usize = 4096;
pub const max_blobs_per_task: usize = 64;
const lock_file_name = ".checkpoint-store.lock";

pub const Health = enum(u8) {
    ready,
    unavailable,
    outcome_unknown,
};

pub const Error = error{
    OutOfMemory,
    DirectoryUnavailable,
    WriterAlreadyActive,
    InvalidIdentity,
    ResourceLimit,
    WriteFailed,
    PersistenceOutcomeUnknown,
    BlobAlreadyExists,
    BlobMissing,
    BlobMismatch,
    Cancelled,
};

pub const Identity = struct {
    task_id: u64,
    generation: u64,
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

    pub fn begin(self: *FileStore, task_id: u64, hard_bytes: u64) Error!Writer {
        if (task_id == 0 or hard_bytes == 0) return error.InvalidIdentity;
        var task_name_storage: [32]u8 = undefined;
        const task_name = std.fmt.bufPrint(&task_name_storage, "{d}", .{task_id}) catch
            return error.InvalidIdentity;
        const task_dir = self.root.createDirPathOpen(
            self.io,
            task_name,
            .{
                .open_options = .{
                    .follow_symlinks = false,
                },
                .permissions = directoryPermissions(),
            },
        ) catch return error.DirectoryUnavailable;
        errdefer task_dir.close(self.io);
        // The task directory is itself durable store state. POSIX can flush
        // the parent directory entry directly; Windows relies on the same
        // best-effort boundary used by the existing single-file stores.
        if (!syncDirectory(self.io, self.root, null))
            return error.PersistenceOutcomeUnknown;
        var random: [8]u8 = undefined;
        std.Io.randomSecure(self.io, &random) catch return error.WriteFailed;
        const random_hex = std.fmt.bytesToHex(random, .lower);
        var temp_name_storage: [64]u8 = undefined;
        const temp_name = std.fmt.bufPrint(
            &temp_name_storage,
            ".checkpoint.{s}.tmp",
            .{random_hex},
        ) catch return error.WriteFailed;
        const file = task_dir.createFile(
            self.io,
            temp_name,
            .{
                .exclusive = true,
                .permissions = privateFilePermissions(),
                .resolve_beneath = true,
            },
        ) catch return error.WriteFailed;
        return .{
            .store = self,
            .task_id = task_id,
            .task_dir = task_dir,
            .file = file,
            .temp_name_storage = temp_name_storage,
            .temp_name_len = temp_name.len,
            .hard_bytes = hard_bytes,
        };
    }

    pub fn verify(self: *FileStore, identity: Identity) Error!void {
        var source = try self.openVerified(identity, null);
        source.deinit();
    }

    pub fn openVerified(
        self: *FileStore,
        identity: Identity,
        cancellation: ?*const std.atomic.Value(bool),
    ) Error!VerifiedSource {
        try validateIdentity(identity);
        var task_name_storage: [32]u8 = undefined;
        const task_name = try taskDirectoryName(identity.task_id, &task_name_storage);
        var task_dir = self.root.openDir(
            self.io,
            task_name,
            .{ .follow_symlinks = false },
        ) catch |err| switch (err) {
            error.FileNotFound => return error.BlobMissing,
            else => return error.DirectoryUnavailable,
        };
        defer task_dir.close(self.io);
        var blob_name_storage: [128]u8 = undefined;
        const blob_name = try blobName(identity.generation, identity.digest, &blob_name_storage);
        var file = task_dir.openFile(
            self.io,
            blob_name,
            .{ .follow_symlinks = false },
        ) catch |err| switch (err) {
            error.FileNotFound => return error.BlobMissing,
            else => return error.WriteFailed,
        };
        if (builtin.os.tag == .windows) file.flags.nonblocking = true;
        errdefer file.close(self.io);
        const length = file.length(self.io) catch return error.WriteFailed;
        if (length != identity.byte_size) return error.BlobMismatch;
        var digest = std.crypto.hash.sha2.Sha256.init(.{});
        var offset: u64 = 0;
        var buffer: [256 * 1024]u8 = undefined;
        while (offset < length) {
            if (cancellation) |value| if (value.load(.acquire))
                return error.Cancelled;
            const remaining: usize = @intCast(@min(length - offset, buffer.len));
            const read = file.readPositionalAll(
                self.io,
                buffer[0..remaining],
                offset,
            ) catch return error.WriteFailed;
            if (read != remaining) return error.WriteFailed;
            digest.update(buffer[0..remaining]);
            offset += read;
        }
        var actual: [digest_bytes]u8 = undefined;
        digest.final(&actual);
        if (!std.mem.eql(u8, &actual, &identity.digest)) return error.BlobMismatch;
        return .{
            .io = self.io,
            .file = file,
            .byte_size = length,
            .cancellation = cancellation,
        };
    }

    pub fn delete(self: *FileStore, identity: Identity) void {
        validateIdentity(identity) catch return;
        var task_name_storage: [32]u8 = undefined;
        const task_name = taskDirectoryName(identity.task_id, &task_name_storage) catch return;
        var task_dir = self.root.openDir(
            self.io,
            task_name,
            .{ .follow_symlinks = false },
        ) catch return;
        defer task_dir.close(self.io);
        var blob_name_storage: [128]u8 = undefined;
        const name = blobName(identity.generation, identity.digest, &blob_name_storage) catch return;
        task_dir.deleteFile(self.io, name) catch return;
        _ = syncDirectory(self.io, task_dir, null);
    }

    pub fn deleteTask(self: *FileStore, task_id: u64) void {
        var task_name_storage: [32]u8 = undefined;
        const task_name = taskDirectoryName(task_id, &task_name_storage) catch return;
        self.root.deleteTree(self.io, task_name) catch return;
        _ = syncDirectory(self.io, self.root, null);
    }

    pub fn cleanupOrphans(
        self: *FileStore,
        allocator: std.mem.Allocator,
        referenced: []const Identity,
    ) Error!void {
        const capacity = max_task_directories * max_blobs_per_task;
        var entries: std.ArrayList(StoredEntry) = .empty;
        defer entries.deinit(allocator);
        var task_ids: std.ArrayList(u64) = .empty;
        defer task_ids.deinit(allocator);
        var root_iterable = self.root.openDir(
            self.io,
            ".",
            .{ .iterate = true, .follow_symlinks = false },
        ) catch return error.DirectoryUnavailable;
        defer root_iterable.close(self.io);
        var root_iterator = root_iterable.iterate();
        var task_count: usize = 0;
        while (root_iterator.next(self.io) catch return error.DirectoryUnavailable) |entry| {
            if (entry.kind == .file and std.mem.eql(u8, entry.name, lock_file_name)) continue;
            if (entry.kind != .directory or task_count == max_task_directories)
                return error.ResourceLimit;
            const task_id = parseTaskDirectory(entry.name) orelse return error.InvalidIdentity;
            task_count += 1;
            try task_ids.append(allocator, task_id);
            var task_dir = self.root.openDir(
                self.io,
                entry.name,
                .{ .iterate = true, .follow_symlinks = false },
            ) catch return error.DirectoryUnavailable;
            defer task_dir.close(self.io);
            var iterator = task_dir.iterate();
            var task_entries: usize = 0;
            while (iterator.next(self.io) catch return error.DirectoryUnavailable) |blob_entry| {
                if (blob_entry.kind != .file or
                    task_entries == max_blobs_per_task or
                    entries.items.len == capacity)
                    return error.ResourceLimit;
                task_entries += 1;
                try entries.append(allocator, try parseStoredEntry(
                    self.io,
                    task_dir,
                    task_id,
                    blob_entry.name,
                ));
            }
        }
        for (entries.items) |stored| {
            if (!stored.temporary and identityReferenced(stored.identity, referenced)) continue;
            var task_name_storage: [32]u8 = undefined;
            const task_name = try taskDirectoryName(stored.identity.task_id, &task_name_storage);
            var task_dir = self.root.openDir(
                self.io,
                task_name,
                .{ .follow_symlinks = false },
            ) catch return error.DirectoryUnavailable;
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
        var task_dir = self.root.openDir(
            self.io,
            task_name,
            .{ .iterate = true, .follow_symlinks = false },
        ) catch return error.DirectoryUnavailable;
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

pub const SourceReadResult = union(enum) {
    bytes: usize,
    eof,
    cancelled,
    io_failed,
};

pub const VerifiedSource = struct {
    io: std.Io,
    file: std.Io.File,
    byte_size: u64,
    offset: u64 = 0,
    cancellation: ?*const std.atomic.Value(bool),

    pub fn read(self: *VerifiedSource, destination: []u8) SourceReadResult {
        if (self.cancellation) |value| if (value.load(.acquire))
            return .cancelled;
        if (self.offset == self.byte_size) return .eof;
        if (destination.len == 0 or self.offset > self.byte_size)
            return .io_failed;
        const count: usize = @intCast(@min(
            @min(self.byte_size - self.offset, destination.len),
            256 * 1024,
        ));
        const bytes_read = self.file.readPositionalAll(
            self.io,
            destination[0..count],
            self.offset,
        ) catch return .io_failed;
        if (bytes_read != count) return .io_failed;
        self.offset += bytes_read;
        return .{ .bytes = bytes_read };
    }

    pub fn deinit(self: *VerifiedSource) void {
        self.file.close(self.io);
        self.* = undefined;
    }
};

const StoredEntry = struct {
    identity: Identity,
    file_name: [128]u8,
    file_name_len: usize,
    temporary: bool,

    fn name(self: *const StoredEntry) []const u8 {
        return self.file_name[0..self.file_name_len];
    }
};

pub const Writer = struct {
    store: *FileStore,
    task_id: u64,
    task_dir: std.Io.Dir,
    file: std.Io.File,
    temp_name_storage: [64]u8,
    temp_name_len: usize,
    hard_bytes: u64,
    bytes_written: u64 = 0,
    file_open: bool = true,
    temp_exists: bool = true,

    pub fn deinit(self: *Writer) void {
        if (self.file_open) self.file.close(self.store.io);
        if (self.temp_exists)
            self.task_dir.deleteFile(self.store.io, self.tempName()) catch {};
        self.task_dir.close(self.store.io);
        self.* = undefined;
    }

    pub fn write(self: *Writer, bytes: []const u8) error{ ResourceLimit, WriteFailed }!void {
        const count = std.math.cast(u64, bytes.len) orelse return error.ResourceLimit;
        if (count > self.hard_bytes or self.bytes_written > self.hard_bytes - count)
            return error.ResourceLimit;
        self.file.writeStreamingAll(self.store.io, bytes) catch return error.WriteFailed;
        self.bytes_written += count;
    }

    pub fn commit(
        self: *Writer,
        generation: u64,
        digest: [digest_bytes]u8,
        expected_bytes: u64,
    ) Error!Identity {
        if (!self.file_open or !self.temp_exists or expected_bytes != self.bytes_written)
            return error.InvalidIdentity;
        var name_storage: [128]u8 = undefined;
        const name = try blobName(generation, digest, &name_storage);
        if (self.task_dir.openFile(
            self.store.io,
            name,
            .{ .follow_symlinks = false, .resolve_beneath = true },
        )) |existing| {
            existing.close(self.store.io);
            return error.BlobAlreadyExists;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return error.WriteFailed,
        }
        self.file.sync(self.store.io) catch return error.WriteFailed;
        self.file.close(self.store.io);
        self.file_open = false;
        self.task_dir.rename(
            self.tempName(),
            self.task_dir,
            name,
            self.store.io,
        ) catch return error.WriteFailed;
        self.temp_exists = false;
        if (!syncDirectory(self.store.io, self.task_dir, name))
            return error.PersistenceOutcomeUnknown;
        return .{
            .task_id = self.task_id,
            .generation = generation,
            .digest = digest,
            .byte_size = expected_bytes,
        };
    }

    fn tempName(self: *const Writer) []const u8 {
        return self.temp_name_storage[0..self.temp_name_len];
    }
};

fn validateIdentity(identity: Identity) Error!void {
    if (identity.task_id == 0) return error.InvalidIdentity;
}

fn taskDirectoryName(task_id: u64, storage: []u8) Error![]const u8 {
    if (task_id == 0) return error.InvalidIdentity;
    return std.fmt.bufPrint(storage, "{d}", .{task_id}) catch error.InvalidIdentity;
}

fn blobName(generation: u64, digest: [digest_bytes]u8, storage: []u8) Error![]const u8 {
    const digest_hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.bufPrint(storage, "{d}-{s}.ckpt", .{ generation, digest_hex }) catch
        error.InvalidIdentity;
}

fn parseTaskDirectory(name: []const u8) ?u64 {
    const task_id = std.fmt.parseInt(u64, name, 10) catch return null;
    if (task_id == 0) return null;
    var canonical_storage: [32]u8 = undefined;
    const canonical = taskDirectoryName(task_id, &canonical_storage) catch return null;
    return if (std.mem.eql(u8, canonical, name)) task_id else null;
}

fn parseStoredEntry(
    io: std.Io,
    task_dir: std.Io.Dir,
    task_id: u64,
    name: []const u8,
) Error!StoredEntry {
    if (name.len > 128) return error.InvalidIdentity;
    var file_name = [_]u8{0} ** 128;
    @memcpy(file_name[0..name.len], name);
    if (std.mem.startsWith(u8, name, ".checkpoint.") and
        std.mem.endsWith(u8, name, ".tmp") and
        name.len == ".checkpoint.".len + 16 + ".tmp".len and
        isLowerHex(name[".checkpoint.".len .. name.len - ".tmp".len]))
        return .{
            .identity = .{
                .task_id = task_id,
                .generation = 0,
                .digest = [_]u8{0} ** digest_bytes,
                .byte_size = 0,
            },
            .file_name = file_name,
            .file_name_len = name.len,
            .temporary = true,
        };
    if (!std.mem.endsWith(u8, name, ".ckpt")) return error.InvalidIdentity;
    const stem = name[0 .. name.len - ".ckpt".len];
    const separator = std.mem.indexOfScalar(u8, stem, '-') orelse return error.InvalidIdentity;
    if (separator == 0 or stem.len - separator - 1 != digest_bytes * 2)
        return error.InvalidIdentity;
    const generation_text = stem[0..separator];
    const generation = std.fmt.parseInt(u64, generation_text, 10) catch
        return error.InvalidIdentity;
    var digest: [digest_bytes]u8 = undefined;
    _ = std.fmt.hexToBytes(&digest, stem[separator + 1 ..]) catch
        return error.InvalidIdentity;
    var canonical_storage: [128]u8 = undefined;
    const canonical = try blobName(generation, digest, &canonical_storage);
    if (!std.mem.eql(u8, canonical, name)) return error.InvalidIdentity;
    var file = task_dir.openFile(
        io,
        name,
        .{ .follow_symlinks = false, .resolve_beneath = true },
    ) catch return error.DirectoryUnavailable;
    defer file.close(io);
    const length = file.length(io) catch return error.DirectoryUnavailable;
    return .{
        .identity = .{
            .task_id = task_id,
            .generation = generation,
            .digest = digest,
            .byte_size = length,
        },
        .file_name = file_name,
        .file_name_len = name.len,
        .temporary = false,
    };
}

fn isLowerHex(value: []const u8) bool {
    for (value) |byte| if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f'))
        return false;
    return true;
}

fn identityReferenced(identity: Identity, referenced: []const Identity) bool {
    for (referenced) |candidate| {
        if (candidate.task_id == identity.task_id and
            candidate.generation == identity.generation and
            candidate.byte_size == identity.byte_size and
            std.mem.eql(u8, &candidate.digest, &identity.digest))
            return true;
    }
    return false;
}

fn openOrCreateLock(io: std.Io, dir: std.Io.Dir) !std.Io.File {
    const existing = dir.openFile(
        io,
        lock_file_name,
        .{
            .mode = .read_write,
            .lock = .exclusive,
            .lock_nonblocking = true,
            .follow_symlinks = false,
            .resolve_beneath = true,
        },
    ) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (existing) |file| return file;
    return dir.createFile(
        io,
        lock_file_name,
        .{
            .read = true,
            .truncate = false,
            .exclusive = true,
            .lock = .exclusive,
            .lock_nonblocking = true,
            .permissions = privateFilePermissions(),
            .resolve_beneath = true,
        },
    ) catch |err| switch (err) {
        error.PathAlreadyExists => return dir.openFile(
            io,
            lock_file_name,
            .{
                .mode = .read_write,
                .lock = .exclusive,
                .lock_nonblocking = true,
                .follow_symlinks = false,
                .resolve_beneath = true,
            },
        ),
        else => return err,
    };
}

fn syncDirectory(io: std.Io, dir: std.Io.Dir, target_name: ?[]const u8) bool {
    if (builtin.os.tag == .windows) {
        const name = target_name orelse return true;
        const file = dir.openFile(
            io,
            name,
            .{
                .mode = .read_write,
                .allow_directory = false,
                .follow_symlinks = false,
                .resolve_beneath = true,
            },
        ) catch return false;
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

test "checkpoint store is immutable, exclusive, and cleans only unreferenced blobs" {
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

    var first_digest: [digest_bytes]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("first", &first_digest, .{});
    var first_writer = try store.begin(7, 1024);
    defer first_writer.deinit();
    try first_writer.write("first");
    const first = try first_writer.commit(0, first_digest, 5);
    try store.verify(first);
    var source = try store.openVerified(first, null);
    defer source.deinit();
    var restored: [5]u8 = undefined;
    switch (source.read(restored[0..2])) {
        .bytes => |count| try std.testing.expectEqual(@as(usize, 2), count),
        else => return error.TestUnexpectedResult,
    }
    switch (source.read(restored[2..])) {
        .bytes => |count| try std.testing.expectEqual(@as(usize, 3), count),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqualStrings("first", &restored);
    try std.testing.expectEqual(SourceReadResult.eof, source.read(&restored));

    var cancelled = std.atomic.Value(bool).init(true);
    try std.testing.expectError(error.Cancelled, store.openVerified(first, &cancelled));

    var duplicate_writer = try store.begin(7, 1024);
    defer duplicate_writer.deinit();
    try duplicate_writer.write("first");
    try std.testing.expectError(
        error.BlobAlreadyExists,
        duplicate_writer.commit(0, first_digest, 5),
    );

    var orphan_digest: [digest_bytes]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("orphan", &orphan_digest, .{});
    var orphan_writer = try store.begin(7, 1024);
    defer orphan_writer.deinit();
    try orphan_writer.write("orphan");
    const orphan = try orphan_writer.commit(1, orphan_digest, 6);
    try store.cleanupOrphans(std.testing.allocator, &.{first});
    try store.verify(first);
    try std.testing.expectError(error.BlobMissing, store.verify(orphan));
}
