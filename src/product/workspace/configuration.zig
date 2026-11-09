//! Workspace-owned Automatic Workspace root configuration and file store.

const std = @import("std");
const builtin = @import("builtin");
const automatic_root = @import("product_workspace_automatic_root");

pub const schema_version: u8 = 1;
pub const file_name = "automatic-workspace-root.store";
pub const max_root_bytes: usize = std.Io.Dir.max_path_bytes - automatic_root.key_hex_bytes - 1;
// A legal POSIX path may require six JSON bytes for one source byte.
pub const max_store_bytes: usize = max_root_bytes * 6 + 256;

const recovery_prefix = ".automatic-workspace-root.recovery.";
const recovery_id_hex_bytes = 16;
const max_recovery_artifacts = 1024;

pub const Mode = enum {
    system_default,
    custom,
};

pub const Health = enum {
    ready,
    path_unavailable,
    persistence_unavailable,
    read_failed,
    corrupt,
    write_failed,
    outcome_unknown,
};

pub const Error = std.mem.Allocator.Error || error{
    StoreEmpty,
    StoreTooLarge,
    StoreCorrupt,
    StoreEncodeFailed,
};

pub const PersistenceError = FileStoreError;

pub const Persistence = struct {
    context: *anyopaque,
    load_fn: *const fn (*anyopaque, std.mem.Allocator) PersistenceError!?[]u8,
    commit_fn: *const fn (*anyopaque, []const u8) PersistenceError!void,
    recover_fn: *const fn (*anyopaque, []const u8) PersistenceError!void,

    fn loadAlloc(self: Persistence, allocator: std.mem.Allocator) PersistenceError!?[]u8 {
        return self.load_fn(self.context, allocator);
    }

    pub fn commit(self: Persistence, bytes: []const u8) PersistenceError!void {
        return self.commit_fn(self.context, bytes);
    }

    pub fn recover(self: Persistence, bytes: []const u8) PersistenceError!void {
        return self.recover_fn(self.context, bytes);
    }
};

pub const Configuration = struct {
    allocator: std.mem.Allocator,
    mode: Mode,
    custom_root: ?[]u8,

    pub fn systemDefault(allocator: std.mem.Allocator) Configuration {
        return .{
            .allocator = allocator,
            .mode = .system_default,
            .custom_root = null,
        };
    }

    pub fn custom(
        allocator: std.mem.Allocator,
        canonical_root: []const u8,
    ) Error!Configuration {
        if (!validCustomRoot(canonical_root)) return error.StoreCorrupt;
        return .{
            .allocator = allocator,
            .mode = .custom,
            .custom_root = try allocator.dupe(u8, canonical_root),
        };
    }

    pub fn clone(self: *const Configuration) Error!Configuration {
        return switch (self.mode) {
            .system_default => .systemDefault(self.allocator),
            .custom => try .custom(self.allocator, self.custom_root.?),
        };
    }

    pub fn root(
        self: *const Configuration,
        system_default: ?[]const u8,
    ) ?[]const u8 {
        return switch (self.mode) {
            .system_default => system_default,
            .custom => self.custom_root.?,
        };
    }

    pub fn deinit(self: *Configuration) void {
        if (self.custom_root) |custom_root| self.allocator.free(custom_root);
        self.* = undefined;
    }
};

/// Process-local configuration state. `generation` is intentionally not
/// durable: every Renderer connection receives a fresh snapshot boundary.
pub const Runtime = struct {
    allocator: std.mem.Allocator,
    configuration: ?Configuration,
    generation: u64 = 1,
    health: Health,
    recovery_required: bool = false,

    pub fn bootstrap(
        allocator: std.mem.Allocator,
        store: ?Persistence,
    ) std.mem.Allocator.Error!Runtime {
        const persistence = store orelse return .{
            .allocator = allocator,
            .configuration = null,
            .health = .persistence_unavailable,
        };
        const loaded = persistence.loadAlloc(allocator) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{
                .allocator = allocator,
                .configuration = null,
                .health = .read_failed,
                .recovery_required = true,
            },
        };
        if (loaded) |bytes| {
            defer allocator.free(bytes);
            const configuration = decode(allocator, bytes) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return .{
                    .allocator = allocator,
                    .configuration = null,
                    .health = .corrupt,
                    .recovery_required = true,
                },
            };
            return .{
                .allocator = allocator,
                .configuration = configuration,
                .health = .ready,
            };
        }

        var configuration = Configuration.systemDefault(allocator);
        var storage: [max_store_bytes]u8 = undefined;
        const encoded = encode(&storage, &configuration) catch unreachable;
        persistence.commit(encoded) catch |err| {
            configuration.deinit();
            return .{
                .allocator = allocator,
                .configuration = null,
                .health = switch (err) {
                    error.PersistenceOutcomeUnknown => .outcome_unknown,
                    else => .write_failed,
                },
                .recovery_required = err == error.PersistenceOutcomeUnknown,
            };
        };
        return .{
            .allocator = allocator,
            .configuration = configuration,
            .health = .ready,
        };
    }

    pub fn deinit(self: *Runtime) void {
        if (self.configuration) |*configuration| configuration.deinit();
        self.* = undefined;
    }

    pub fn effectiveRoot(
        self: *const Runtime,
        system_default: ?[]const u8,
    ) ?[]const u8 {
        return switch (self.health) {
            .ready, .write_failed => self.committedRoot(system_default),
            .path_unavailable,
            .persistence_unavailable,
            .read_failed,
            .corrupt,
            .outcome_unknown,
            => null,
        };
    }

    pub fn committedRoot(
        self: *const Runtime,
        system_default: ?[]const u8,
    ) ?[]const u8 {
        return if (self.configuration) |*configuration|
            configuration.root(system_default)
        else
            null;
    }

    pub fn advanceGeneration(self: *Runtime) void {
        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
    }
};

const Wire = struct {
    schema_version: u8,
    mode: []const u8,
    custom_root: ?[]const u8,
};

pub fn encode(output: []u8, configuration: *const Configuration) Error![]const u8 {
    if (output.len == 0) return error.StoreEncodeFailed;
    var writer = std.Io.Writer.fixed(output);
    writer.print(
        "{{\"schema_version\":{d},\"mode\":",
        .{schema_version},
    ) catch return error.StoreEncodeFailed;
    std.json.Stringify.value(@tagName(configuration.mode), .{}, &writer) catch
        return error.StoreEncodeFailed;
    writer.writeAll(",\"custom_root\":") catch
        return error.StoreEncodeFailed;
    switch (configuration.mode) {
        .system_default => {
            if (configuration.custom_root != null)
                return error.StoreEncodeFailed;
            writer.writeAll("null") catch return error.StoreEncodeFailed;
        },
        .custom => {
            const root = configuration.custom_root orelse
                return error.StoreEncodeFailed;
            if (!validCustomRoot(root)) return error.StoreEncodeFailed;
            std.json.Stringify.value(root, .{}, &writer) catch
                return error.StoreEncodeFailed;
        },
    }
    writer.writeByte('}') catch return error.StoreEncodeFailed;
    const encoded = writer.buffered();
    if (encoded.len > max_store_bytes) return error.StoreTooLarge;
    return encoded;
}

pub fn decode(allocator: std.mem.Allocator, input: []const u8) Error!Configuration {
    if (input.len == 0) return error.StoreEmpty;
    if (input.len > max_store_bytes) return error.StoreTooLarge;
    var parsed = std.json.parseFromSlice(
        Wire,
        allocator,
        input,
        .{ .ignore_unknown_fields = false },
    ) catch return error.StoreCorrupt;
    defer parsed.deinit();
    if (parsed.value.schema_version != schema_version)
        return error.StoreCorrupt;
    const mode = std.meta.stringToEnum(Mode, parsed.value.mode) orelse
        return error.StoreCorrupt;
    return switch (mode) {
        .system_default => if (parsed.value.custom_root == null)
            .systemDefault(allocator)
        else
            error.StoreCorrupt,
        .custom => if (parsed.value.custom_root) |root|
            Configuration.custom(allocator, root)
        else
            error.StoreCorrupt,
    };
}

fn validCustomRoot(root: []const u8) bool {
    return root.len > 0 and
        root.len <= max_root_bytes and
        std.fs.path.isAbsolute(root) and
        std.unicode.utf8ValidateSlice(root) and
        std.mem.indexOfScalar(u8, root, 0) == null;
}

pub const FileStoreError = std.mem.Allocator.Error || error{
    DirectoryUnavailable,
    ReadFailed,
    WriteFailed,
    PersistenceOutcomeUnknown,
};

pub const CommitFault = enum {
    none,
    write_failed,
    outcome_unknown_after_install,
};

pub const RecoveryFault = enum {
    none,
    install_failed,
    install_and_restore_failed,
    interrupted_after_quarantine,
    interrupted_after_install,
};

pub const FileStore = struct {
    io: std.Io,
    dir: std.Io.Dir,
    commit_fault: CommitFault = .none,
    recovery_fault: RecoveryFault = .none,

    pub fn persistence(self: *FileStore) Persistence {
        return .{ .context = self, .load_fn = loadEffect, .commit_fn = commitEffect, .recover_fn = recoverEffect };
    }

    fn loadEffect(context: *anyopaque, allocator: std.mem.Allocator) PersistenceError!?[]u8 {
        const self: *FileStore = @ptrCast(@alignCast(context));
        return self.loadAlloc(allocator);
    }

    fn commitEffect(context: *anyopaque, bytes: []const u8) PersistenceError!void {
        const self: *FileStore = @ptrCast(@alignCast(context));
        return self.commit(bytes);
    }

    fn recoverEffect(context: *anyopaque, bytes: []const u8) PersistenceError!void {
        const self: *FileStore = @ptrCast(@alignCast(context));
        return self.recover(bytes);
    }

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
        if (self.hasIncompleteRecoveryArtifact()) return error.ReadFailed;
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
        if (length == 0 or length > max_store_bytes) return error.ReadFailed;
        const bytes = try allocator.alloc(u8, @intCast(length));
        errdefer allocator.free(bytes);
        const read = file.readPositionalAll(self.io, bytes, 0) catch
            return error.ReadFailed;
        if (read != length) return error.ReadFailed;
        return bytes;
    }

    pub fn commit(self: *FileStore, bytes: []const u8) FileStoreError!void {
        if (bytes.len == 0 or bytes.len > max_store_bytes)
            return error.WriteFailed;
        if (self.commit_fault == .write_failed) return error.WriteFailed;
        var random: [8]u8 = undefined;
        std.Io.randomSecure(self.io, &random) catch return error.WriteFailed;
        const random_hex = std.fmt.bytesToHex(random, .lower);
        var temp_name_storage: [72]u8 = undefined;
        var name_writer = std.Io.Writer.fixed(&temp_name_storage);
        name_writer.print(
            ".automatic-workspace-root.{s}.tmp",
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
            if (temp_exists) self.dir.deleteFile(self.io, temp_name) catch {};
        }
        file.writeStreamingAll(self.io, bytes) catch return error.WriteFailed;
        file.sync(self.io) catch return error.WriteFailed;
        file.close(self.io);
        file_open = false;
        self.dir.rename(temp_name, self.dir, file_name, self.io) catch
            return error.WriteFailed;
        temp_exists = false;
        if (self.commit_fault == .outcome_unknown_after_install)
            return error.PersistenceOutcomeUnknown;
        if (!self.syncPath(file_name)) return error.PersistenceOutcomeUnknown;
    }

    /// Explicit recovery preserves the previous canonical bytes as a unique
    /// quarantine before installing the caller-provided current schema.
    pub fn recover(self: *FileStore, bytes: []const u8) FileStoreError!void {
        if (bytes.len == 0 or bytes.len > max_store_bytes)
            return error.WriteFailed;
        try self.settleIncompleteRecoveries();
        var random: [8]u8 = undefined;
        std.Io.randomSecure(self.io, &random) catch return error.WriteFailed;
        const random_hex = std.fmt.bytesToHex(random, .lower);
        var temp_storage: [96]u8 = undefined;
        var temp_writer = std.Io.Writer.fixed(&temp_storage);
        temp_writer.print(recovery_prefix ++ "{s}.tmp", .{random_hex}) catch
            return error.WriteFailed;
        const temp_name = temp_writer.buffered();
        var backup_storage: [96]u8 = undefined;
        var backup_writer = std.Io.Writer.fixed(&backup_storage);
        backup_writer.print(recovery_prefix ++ "{s}.bak", .{random_hex}) catch
            return error.WriteFailed;
        const backup_name = backup_writer.buffered();
        var quarantine_storage: [104]u8 = undefined;
        var quarantine_writer = std.Io.Writer.fixed(&quarantine_storage);
        quarantine_writer.print(
            recovery_prefix ++ "{s}.quarantine",
            .{random_hex},
        ) catch return error.WriteFailed;
        const quarantine_name = quarantine_writer.buffered();
        var pending_storage: [100]u8 = undefined;
        var pending_writer = std.Io.Writer.fixed(&pending_storage);
        pending_writer.print(recovery_prefix ++ "{s}.pending", .{random_hex}) catch
            return error.WriteFailed;
        const pending_name = pending_writer.buffered();

        const replacement = self.dir.createFile(
            self.io,
            temp_name,
            .{
                .exclusive = true,
                .permissions = privateFilePermissions(),
                .resolve_beneath = true,
            },
        ) catch return error.WriteFailed;
        var replacement_open = true;
        var temp_exists = true;
        defer {
            if (replacement_open) replacement.close(self.io);
            if (temp_exists) self.dir.deleteFile(self.io, temp_name) catch {};
        }
        replacement.writeStreamingAll(self.io, bytes) catch
            return error.WriteFailed;
        replacement.sync(self.io) catch return error.WriteFailed;
        replacement.close(self.io);
        replacement_open = false;
        if (!self.syncPath(temp_name)) return error.WriteFailed;

        const pending = self.dir.createFile(
            self.io,
            pending_name,
            .{
                .exclusive = true,
                .permissions = privateFilePermissions(),
                .resolve_beneath = true,
            },
        ) catch return error.WriteFailed;
        var pending_open = true;
        var clean_pending = true;
        defer {
            if (pending_open) pending.close(self.io);
            if (clean_pending) self.dir.deleteFile(self.io, pending_name) catch {};
        }
        pending.sync(self.io) catch return error.WriteFailed;
        pending.close(self.io);
        pending_open = false;
        if (!self.syncPath(pending_name)) return error.WriteFailed;

        var quarantined = true;
        self.dir.rename(file_name, self.dir, backup_name, self.io) catch |err| switch (err) {
            error.FileNotFound => quarantined = false,
            else => return error.WriteFailed,
        };
        if (quarantined and !self.syncPath(backup_name)) {
            if (!self.restoreCanonical(backup_name)) {
                clean_pending = false;
                return error.PersistenceOutcomeUnknown;
            }
            return error.WriteFailed;
        }
        if (self.recovery_fault == .interrupted_after_quarantine) {
            temp_exists = false;
            clean_pending = false;
            return error.PersistenceOutcomeUnknown;
        }
        if (self.recovery_fault == .install_failed or
            self.recovery_fault == .install_and_restore_failed)
        {
            if (quarantined and !self.restoreCanonical(backup_name)) {
                clean_pending = false;
                return error.PersistenceOutcomeUnknown;
            }
            return error.WriteFailed;
        }
        self.dir.rename(temp_name, self.dir, file_name, self.io) catch {
            if (quarantined and !self.restoreCanonical(backup_name)) {
                clean_pending = false;
                return error.PersistenceOutcomeUnknown;
            }
            return error.WriteFailed;
        };
        temp_exists = false;
        if (!self.syncPath(file_name)) {
            clean_pending = false;
            return error.PersistenceOutcomeUnknown;
        }
        if (self.recovery_fault == .interrupted_after_install) {
            clean_pending = false;
            return error.PersistenceOutcomeUnknown;
        }
        if (quarantined) {
            self.dir.rename(backup_name, self.dir, quarantine_name, self.io) catch {
                clean_pending = false;
                return error.PersistenceOutcomeUnknown;
            };
            if (!self.syncPath(quarantine_name)) {
                clean_pending = false;
                return error.PersistenceOutcomeUnknown;
            }
        }
        self.dir.deleteFile(self.io, pending_name) catch {
            clean_pending = false;
            return error.PersistenceOutcomeUnknown;
        };
        clean_pending = false;
        if (!self.syncDirectory()) return error.PersistenceOutcomeUnknown;
    }

    fn restoreCanonical(self: *FileStore, backup_name: []const u8) bool {
        if (self.recovery_fault == .install_and_restore_failed) return false;
        self.dir.rename(backup_name, self.dir, file_name, self.io) catch
            return false;
        return self.syncPath(file_name);
    }

    fn settleIncompleteRecoveries(self: *FileStore) FileStoreError!void {
        var operations: usize = 0;
        var name_storage: [120]u8 = undefined;
        while (try self.findRecoveryArtifact(".bak", &name_storage)) |name| {
            operations += 1;
            if (operations > max_recovery_artifacts)
                return error.PersistenceOutcomeUnknown;
            const transaction_id = recoveryTransactionId(name, ".bak") orelse
                return error.PersistenceOutcomeUnknown;
            var quarantine_storage: [120]u8 = undefined;
            var writer = std.Io.Writer.fixed(&quarantine_storage);
            writer.print(
                recovery_prefix ++ "{s}.quarantine",
                .{transaction_id},
            ) catch return error.PersistenceOutcomeUnknown;
            const quarantine_name = writer.buffered();
            self.dir.rename(name, self.dir, quarantine_name, self.io) catch
                return error.PersistenceOutcomeUnknown;
            if (!self.syncPath(quarantine_name))
                return error.PersistenceOutcomeUnknown;
        }
        var removed_temp = false;
        while (try self.findRecoveryArtifact(".tmp", &name_storage)) |name| {
            operations += 1;
            if (operations > max_recovery_artifacts)
                return error.PersistenceOutcomeUnknown;
            self.dir.deleteFile(self.io, name) catch
                return error.PersistenceOutcomeUnknown;
            removed_temp = true;
        }
        if (removed_temp and !self.syncDirectory())
            return error.PersistenceOutcomeUnknown;
        var removed_pending = false;
        while (try self.findRecoveryArtifact(".pending", &name_storage)) |name| {
            operations += 1;
            if (operations > max_recovery_artifacts)
                return error.PersistenceOutcomeUnknown;
            self.dir.deleteFile(self.io, name) catch
                return error.PersistenceOutcomeUnknown;
            removed_pending = true;
        }
        if (removed_pending and !self.syncDirectory())
            return error.PersistenceOutcomeUnknown;
    }

    fn findRecoveryArtifact(
        self: *FileStore,
        suffix: []const u8,
        output: []u8,
    ) FileStoreError!?[]const u8 {
        var iterable = self.dir.openDir(
            self.io,
            ".",
            .{ .iterate = true, .follow_symlinks = false },
        ) catch return error.ReadFailed;
        defer iterable.close(self.io);
        var iterator = iterable.iterate();
        while (iterator.next(self.io) catch return error.ReadFailed) |entry| {
            if (entry.kind != .file or
                recoveryTransactionId(entry.name, suffix) == null) continue;
            if (entry.name.len > output.len)
                return error.PersistenceOutcomeUnknown;
            @memcpy(output[0..entry.name.len], entry.name);
            return output[0..entry.name.len];
        }
        return null;
    }

    fn hasIncompleteRecoveryArtifact(self: *FileStore) bool {
        var iterable = self.dir.openDir(
            self.io,
            ".",
            .{ .iterate = true, .follow_symlinks = false },
        ) catch return true;
        defer iterable.close(self.io);
        var iterator = iterable.iterate();
        while (iterator.next(self.io) catch return true) |entry| {
            if (entry.kind == .file and
                (recoveryTransactionId(entry.name, ".pending") != null or
                    recoveryTransactionId(entry.name, ".bak") != null))
                return true;
        }
        return false;
    }

    fn syncPath(self: *FileStore, name: []const u8) bool {
        if (builtin.os.tag == .windows) {
            const file = self.dir.openFile(
                self.io,
                name,
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
        return self.syncDirectory();
    }

    fn syncDirectory(self: *FileStore) bool {
        if (builtin.os.tag == .windows) return true;
        const directory_file: std.Io.File = .{
            .handle = self.dir.handle,
            .flags = .{ .nonblocking = false },
        };
        directory_file.sync(self.io) catch return false;
        return true;
    }
};

fn recoveryTransactionId(name: []const u8, suffix: []const u8) ?[]const u8 {
    const expected_len = recovery_prefix.len + recovery_id_hex_bytes + suffix.len;
    if (name.len != expected_len or
        !std.mem.startsWith(u8, name, recovery_prefix) or
        !std.mem.endsWith(u8, name, suffix)) return null;
    const transaction_id = name[recovery_prefix.len .. recovery_prefix.len + recovery_id_hex_bytes];
    for (transaction_id) |byte| {
        if (!std.ascii.isHex(byte)) return null;
    }
    return transaction_id;
}

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

pub const testing = if (builtin.is_test) struct {
    pub fn setCommitFault(store: *FileStore, fault: CommitFault) void {
        store.commit_fault = fault;
    }

    pub fn setRecoveryFault(store: *FileStore, fault: RecoveryFault) void {
        store.recovery_fault = fault;
    }
} else struct {};

test "automatic root configuration strictly round trips current schema" {
    var system_default = Configuration.systemDefault(std.testing.allocator);
    defer system_default.deinit();
    var storage: [max_store_bytes]u8 = undefined;
    const default_bytes = try encode(&storage, &system_default);
    try std.testing.expectEqualStrings(
        "{\"schema_version\":1,\"mode\":\"system_default\",\"custom_root\":null}",
        default_bytes,
    );
    var decoded_default = try decode(std.testing.allocator, default_bytes);
    defer decoded_default.deinit();
    try std.testing.expectEqual(Mode.system_default, decoded_default.mode);

    const root = if (builtin.os.tag == .windows) "C:\\MetaWork" else "/tmp/metawork";
    var custom = try Configuration.custom(std.testing.allocator, root);
    defer custom.deinit();
    const custom_bytes = try encode(&storage, &custom);
    var decoded_custom = try decode(std.testing.allocator, custom_bytes);
    defer decoded_custom.deinit();
    try std.testing.expectEqual(Mode.custom, decoded_custom.mode);
    try std.testing.expectEqualStrings(root, decoded_custom.custom_root.?);
}

test "automatic root configuration rejects legacy ambiguous and oversized values" {
    inline for (.{
        "{\"schema_version\":2,\"mode\":\"system_default\",\"custom_root\":null}",
        "{\"schema_version\":1,\"mode\":\"system_default\",\"custom_root\":\"/tmp\"}",
        "{\"schema_version\":1,\"mode\":\"custom\",\"custom_root\":null}",
        "{\"schema_version\":1,\"mode\":\"default\",\"custom_root\":null}",
        "{\"schema_version\":1,\"mode\":\"system_default\",\"custom_root\":null,\"revision\":1}",
    }) |input| try std.testing.expectError(
        error.StoreCorrupt,
        decode(std.testing.allocator, input),
    );
    const relative = "{\"schema_version\":1,\"mode\":\"custom\",\"custom_root\":\"relative\"}";
    try std.testing.expectError(
        error.StoreCorrupt,
        decode(std.testing.allocator, relative),
    );
    const oversized = try std.testing.allocator.alloc(u8, max_store_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'x');
    try std.testing.expectError(
        error.StoreTooLarge,
        decode(std.testing.allocator, oversized),
    );

    const invalid_internal: Configuration = .{
        .allocator = std.testing.allocator,
        .mode = .custom,
        .custom_root = null,
    };
    var storage: [max_store_bytes]u8 = undefined;
    try std.testing.expectError(
        error.StoreEncodeFailed,
        encode(&storage, &invalid_internal),
    );
}

test "automatic root bootstrap initializes only a missing canonical store" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store: FileStore = .{ .io = std.testing.io, .dir = tmp.dir };
    var runtime = try Runtime.bootstrap(std.testing.allocator, store.persistence());
    defer runtime.deinit();
    try std.testing.expectEqual(Health.ready, runtime.health);
    try std.testing.expectEqual(@as(u64, 1), runtime.generation);
    try std.testing.expectEqual(Mode.system_default, runtime.configuration.?.mode);
    const restored = (try store.loadAlloc(std.testing.allocator)).?;
    defer std.testing.allocator.free(restored);
    try std.testing.expectEqualStrings(
        "{\"schema_version\":1,\"mode\":\"system_default\",\"custom_root\":null}",
        restored,
    );
}

test "automatic root bootstrap fails closed for unavailable corrupt and uncertain stores" {
    var unavailable = try Runtime.bootstrap(std.testing.allocator, null);
    defer unavailable.deinit();
    try std.testing.expectEqual(Health.persistence_unavailable, unavailable.health);
    try std.testing.expect(unavailable.effectiveRoot("/default") == null);

    var corrupt_tmp = std.testing.tmpDir(.{});
    defer corrupt_tmp.cleanup();
    var corrupt_store: FileStore = .{ .io = std.testing.io, .dir = corrupt_tmp.dir };
    try corrupt_store.commit("{\"schema_version\":2}");
    var corrupt = try Runtime.bootstrap(std.testing.allocator, corrupt_store.persistence());
    defer corrupt.deinit();
    try std.testing.expectEqual(Health.corrupt, corrupt.health);
    try std.testing.expect(corrupt.configuration == null);

    var uncertain_tmp = std.testing.tmpDir(.{});
    defer uncertain_tmp.cleanup();
    var uncertain_store: FileStore = .{ .io = std.testing.io, .dir = uncertain_tmp.dir };
    testing.setCommitFault(&uncertain_store, .outcome_unknown_after_install);
    var uncertain = try Runtime.bootstrap(std.testing.allocator, uncertain_store.persistence());
    defer uncertain.deinit();
    try std.testing.expectEqual(Health.outcome_unknown, uncertain.health);
    try std.testing.expect(uncertain.configuration == null);
}

test "automatic root bootstrap distinguishes read and definite write failures" {
    var read_tmp = std.testing.tmpDir(.{});
    defer read_tmp.cleanup();
    var empty = try read_tmp.dir.createFile(
        std.testing.io,
        file_name,
        .{ .exclusive = true },
    );
    empty.close(std.testing.io);
    var read_store: FileStore = .{ .io = std.testing.io, .dir = read_tmp.dir };
    var read_failed = try Runtime.bootstrap(std.testing.allocator, read_store.persistence());
    defer read_failed.deinit();
    try std.testing.expectEqual(Health.read_failed, read_failed.health);

    var write_tmp = std.testing.tmpDir(.{});
    defer write_tmp.cleanup();
    var write_store: FileStore = .{ .io = std.testing.io, .dir = write_tmp.dir };
    testing.setCommitFault(&write_store, .write_failed);
    var write_failed = try Runtime.bootstrap(std.testing.allocator, write_store.persistence());
    defer write_failed.deinit();
    try std.testing.expectEqual(Health.write_failed, write_failed.health);
    try std.testing.expect(write_failed.configuration == null);
}

test "automatic root file recovery quarantines exact prior canonical bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store: FileStore = .{ .io = std.testing.io, .dir = tmp.dir };
    const previous = "{\"schema_version\":7}";
    const replacement = "{\"schema_version\":1,\"mode\":\"system_default\",\"custom_root\":null}";
    try store.commit(previous);
    try store.recover(replacement);

    const restored = (try store.loadAlloc(std.testing.allocator)).?;
    defer std.testing.allocator.free(restored);
    try std.testing.expectEqualStrings(replacement, restored);

    var iterable = try tmp.dir.openDir(
        std.testing.io,
        ".",
        .{ .iterate = true, .follow_symlinks = false },
    );
    defer iterable.close(std.testing.io);
    var iterator = iterable.iterate();
    var quarantine_name: ?[]u8 = null;
    defer if (quarantine_name) |name| std.testing.allocator.free(name);
    while (try iterator.next(std.testing.io)) |entry| {
        if (entry.kind == .file and
            std.mem.startsWith(u8, entry.name, recovery_prefix) and
            std.mem.endsWith(u8, entry.name, ".quarantine"))
        {
            try std.testing.expect(quarantine_name == null);
            quarantine_name = try std.testing.allocator.dupe(u8, entry.name);
        }
    }
    const name = quarantine_name orelse return error.TestExpectedEqual;
    var quarantine = try tmp.dir.openFile(
        std.testing.io,
        name,
        .{ .follow_symlinks = false },
    );
    if (builtin.os.tag == .windows) quarantine.flags.nonblocking = true;
    defer quarantine.close(std.testing.io);
    var bytes: [previous.len]u8 = undefined;
    try std.testing.expectEqual(
        @as(usize, previous.len),
        try quarantine.readPositionalAll(std.testing.io, &bytes, 0),
    );
    try std.testing.expectEqualStrings(previous, &bytes);
}

test "interrupted automatic root recovery remains fail closed until explicit retry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store: FileStore = .{ .io = std.testing.io, .dir = tmp.dir };
    const replacement = "{\"schema_version\":1,\"mode\":\"system_default\",\"custom_root\":null}";
    try store.commit("{\"schema_version\":2}");
    testing.setRecoveryFault(&store, .interrupted_after_quarantine);
    try std.testing.expectError(
        error.PersistenceOutcomeUnknown,
        store.recover(replacement),
    );
    try std.testing.expectError(
        error.ReadFailed,
        store.loadAlloc(std.testing.allocator),
    );
    testing.setRecoveryFault(&store, .none);
    try store.recover(replacement);
    const restored = (try store.loadAlloc(std.testing.allocator)).?;
    defer std.testing.allocator.free(restored);
    try std.testing.expectEqualStrings(replacement, restored);
}

test "definite automatic root recovery failure restores the prior canonical" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store: FileStore = .{ .io = std.testing.io, .dir = tmp.dir };
    const previous = "{\"schema_version\":2}";
    const replacement = "{\"schema_version\":1,\"mode\":\"system_default\",\"custom_root\":null}";
    try store.commit(previous);
    testing.setRecoveryFault(&store, .install_failed);
    try std.testing.expectError(error.WriteFailed, store.recover(replacement));
    const restored = (try store.loadAlloc(std.testing.allocator)).?;
    defer std.testing.allocator.free(restored);
    try std.testing.expectEqualStrings(previous, restored);
}

test "failed automatic root restore remains fail closed without a pending marker" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store: FileStore = .{ .io = std.testing.io, .dir = tmp.dir };
    const previous = "{\"schema_version\":2}";
    const replacement = "{\"schema_version\":1,\"mode\":\"system_default\",\"custom_root\":null}";
    try store.commit(previous);
    testing.setRecoveryFault(&store, .install_and_restore_failed);
    try std.testing.expectError(
        error.PersistenceOutcomeUnknown,
        store.recover(replacement),
    );
    try std.testing.expectError(
        error.ReadFailed,
        store.loadAlloc(std.testing.allocator),
    );

    var pending_storage: [120]u8 = undefined;
    const pending_name = (try store.findRecoveryArtifact(
        ".pending",
        &pending_storage,
    )).?;
    try tmp.dir.deleteFile(std.testing.io, pending_name);
    try std.testing.expectError(
        error.ReadFailed,
        store.loadAlloc(std.testing.allocator),
    );

    testing.setRecoveryFault(&store, .none);
    try store.recover(replacement);
    const restored = (try store.loadAlloc(std.testing.allocator)).?;
    defer std.testing.allocator.free(restored);
    try std.testing.expectEqualStrings(replacement, restored);

    var iterable = try tmp.dir.openDir(
        std.testing.io,
        ".",
        .{ .iterate = true, .follow_symlinks = false },
    );
    defer iterable.close(std.testing.io);
    var iterator = iterable.iterate();
    var quarantine_name: ?[]u8 = null;
    defer if (quarantine_name) |name| std.testing.allocator.free(name);
    while (try iterator.next(std.testing.io)) |entry| {
        if (entry.kind == .file and
            std.mem.startsWith(u8, entry.name, recovery_prefix) and
            std.mem.endsWith(u8, entry.name, ".quarantine"))
        {
            try std.testing.expect(quarantine_name == null);
            quarantine_name = try std.testing.allocator.dupe(u8, entry.name);
        }
    }
    const name = quarantine_name orelse return error.TestExpectedEqual;
    var quarantine = try tmp.dir.openFile(
        std.testing.io,
        name,
        .{ .follow_symlinks = false },
    );
    if (builtin.os.tag == .windows) quarantine.flags.nonblocking = true;
    defer quarantine.close(std.testing.io);
    var bytes: [previous.len]u8 = undefined;
    try std.testing.expectEqual(
        @as(usize, previous.len),
        try quarantine.readPositionalAll(std.testing.io, &bytes, 0),
    );
    try std.testing.expectEqualStrings(previous, &bytes);
}

test "automatic root process generation never publishes zero" {
    var runtime: Runtime = .{
        .allocator = std.testing.allocator,
        .configuration = null,
        .generation = std.math.maxInt(u64),
        .health = .persistence_unavailable,
    };
    runtime.advanceGeneration();
    try std.testing.expectEqual(@as(u64, 1), runtime.generation);
}
