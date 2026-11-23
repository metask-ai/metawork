//! The global instructions file as the Settings editor sees it: loaded whole
//! for editing, saved atomically, and never written over a change made
//! outside MetaWork that the editor has not seen.
//!
//! Neither the directory nor the file exists until the first save. Loading
//! creates nothing; saving creates `~/.metawork` only when it is missing.
const std = @import("std");
const builtin = @import("builtin");
const source = @import("source.zig");

pub const max_text_bytes = source.max_text_bytes;

/// The most the editor loads. Enough to show, and let the user cut, a file
/// that grew past the instruction limit outside MetaWork.
pub const max_load_bytes: usize = 128 * 1024;

/// A file's identity for the editor: the SHA-256 of its bytes, or absent.
pub const Revision = struct {
    present: bool,
    digest: [32]u8,

    pub const absent: Revision = .{ .present = false, .digest = @splat(0) };
    /// The wire form of `absent`. Any other wire value is 64 lowercase hex.
    pub const absent_text = "absent";

    pub fn of(bytes: []const u8) Revision {
        var value: Revision = .{ .present = true, .digest = undefined };
        std.crypto.hash.sha2.Sha256.hash(bytes, &value.digest, .{});
        return value;
    }

    pub fn eql(self: Revision, other: Revision) bool {
        return self.present == other.present and std.mem.eql(u8, &self.digest, &other.digest);
    }

    pub fn text(self: Revision) [64]u8 {
        var out: [64]u8 = @splat(0);
        if (!self.present) {
            @memcpy(out[0..absent_text.len], absent_text);
            return out;
        }
        out = std.fmt.bytesToHex(self.digest, .lower);
        return out;
    }

    /// The wire text of this revision, borrowed from `storage`.
    pub fn slice(self: Revision, storage: *[64]u8) []const u8 {
        storage.* = self.text();
        return if (self.present) storage[0..64] else storage[0..absent_text.len];
    }

    pub fn parse(value: []const u8) ?Revision {
        if (std.mem.eql(u8, value, absent_text)) return absent;
        if (value.len != 64) return null;
        var result: Revision = .{ .present = true, .digest = undefined };
        for (value) |byte| switch (byte) {
            '0'...'9', 'a'...'f' => {},
            else => return null,
        };
        _ = std.fmt.hexToBytes(&result.digest, value) catch return null;
        return result;
    }
};

/// Whether some text holds a credential the Host keeps. Such text is never
/// handed to the Renderer and never saved from it.
pub const CredentialCheck = struct {
    context: *anyopaque,
    contains_fn: *const fn (*anyopaque, []const u8) bool,

    pub fn contains(self: CredentialCheck, text: []const u8) bool {
        return self.contains_fn(self.context, text);
    }
};

pub const LoadState = enum {
    ready,
    absent,
    /// Larger than `max_load_bytes`: shown as a path and a size only.
    too_large,
    unreadable,
    /// Holds a credential the Host keeps, so its text stays in the Host.
    contains_credential,
};

pub const Loaded = struct {
    state: LoadState,
    /// Owned; set only when `ready`. A leading byte-order mark is dropped.
    text: ?[]u8 = null,
    revision: Revision = .absent,
    byte_length: ?u64 = null,
    reason: ?source.Unreadable = null,

    pub fn deinit(self: *Loaded, allocator: std.mem.Allocator) void {
        if (self.text) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub fn load(io: std.Io, allocator: std.mem.Allocator, path: []const u8, credentials: CredentialCheck) std.mem.Allocator.Error!Loaded {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| return switch (err) {
        error.FileNotFound, error.NotDir => .{ .state = .absent },
        error.AccessDenied, error.PermissionDenied => .{ .state = .unreadable, .reason = .access_denied },
        else => .{ .state = .unreadable, .reason = .io_error },
    };
    if (stat.kind != .file) return .{ .state = .unreadable, .reason = .not_regular_file };
    if (stat.size > max_load_bytes) return .{ .state = .too_large, .byte_length = stat.size };
    const bytes = readWhole(io, allocator, path, @intCast(stat.size)) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.AccessDenied => .{ .state = .unreadable, .reason = .access_denied },
        error.ReadFailed => .{ .state = .unreadable, .reason = .io_error },
        error.FileTooLarge => .{ .state = .too_large, .byte_length = stat.size },
    };
    defer allocator.free(bytes);
    const revision = Revision.of(bytes);
    const body = if (std.mem.startsWith(u8, bytes, bom)) bytes[bom.len..] else bytes;
    if (!std.unicode.utf8ValidateSlice(body) or std.mem.indexOfScalar(u8, body, 0) != null)
        return .{ .state = .unreadable, .reason = .not_utf8, .revision = revision, .byte_length = bytes.len };
    if (credentials.contains(body))
        return .{ .state = .contains_credential, .revision = revision, .byte_length = bytes.len };
    return .{ .state = .ready, .text = try allocator.dupe(u8, body), .revision = revision, .byte_length = bytes.len };
}

const bom = "\xef\xbb\xbf";

fn readWhole(io: std.Io, allocator: std.mem.Allocator, path: []const u8, size: usize) (std.mem.Allocator.Error || error{ AccessDenied, ReadFailed, FileTooLarge })![]u8 {
    const file = std.Io.Dir.openFileAbsolute(io, path, .{ .allow_directory = false }) catch |err| return switch (err) {
        error.AccessDenied, error.PermissionDenied => error.AccessDenied,
        else => error.ReadFailed,
    };
    defer file.close(io);
    // One byte past the observed size says whether the file grew meanwhile.
    const buffer = try allocator.alloc(u8, @min(size, max_load_bytes) + 1);
    errdefer allocator.free(buffer);
    const count = file.readPositionalAll(io, buffer, 0) catch return error.ReadFailed;
    if (count > max_load_bytes) return error.FileTooLarge;
    return allocator.realloc(buffer, count);
}

/// The revision of whatever is at `path` now, read in bounded chunks so a
/// file of any size can still be told apart from what the editor loaded.
fn currentRevision(io: std.Io, path: []const u8) error{ReadFailed}!Revision {
    const file = std.Io.Dir.openFileAbsolute(io, path, .{ .allow_directory = false }) catch |err| return switch (err) {
        error.FileNotFound => .absent,
        else => error.ReadFailed,
    };
    defer file.close(io);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var chunk: [16 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const count = file.readPositionalAll(io, &chunk, offset) catch return error.ReadFailed;
        hasher.update(chunk[0..count]);
        offset += count;
        if (count < chunk.len) break;
    }
    var value: Revision = .{ .present = true, .digest = undefined };
    hasher.final(&value.digest);
    return value;
}

pub const SaveOutcome = union(enum) {
    saved: Revision,
    /// The file changed since the editor loaded it; nothing was written.
    conflict: Revision,
    too_large,
    /// Not UTF-8, or holds a NUL byte.
    invalid_text,
    contains_credential,
    /// Nothing was installed; the previous file, if any, is unchanged.
    write_failed,
};

/// Replaces the file with `text` when it still has the `expected` revision.
/// An empty text is saved as an empty file: no instructions.
pub fn save(io: std.Io, path: []const u8, expected: Revision, text: []const u8, credentials: CredentialCheck) SaveOutcome {
    if (text.len > max_text_bytes) return .too_large;
    if (!std.unicode.utf8ValidateSlice(text) or std.mem.indexOfScalar(u8, text, 0) != null) return .invalid_text;
    if (credentials.contains(text)) return .contains_credential;
    const current = currentRevision(io, path) catch return .write_failed;
    if (!current.eql(expected)) return .{ .conflict = current };
    const directory_path = std.fs.path.dirname(path) orelse return .write_failed;
    // The first save is the only one that finds no directory.
    var directory = std.Io.Dir.cwd().createDirPathOpen(io, directory_path, .{
        .permissions = directoryPermissions(),
    }) catch return .write_failed;
    defer directory.close(io);
    const name = std.fs.path.basename(path);
    var random: [8]u8 = undefined;
    std.Io.randomSecure(io, &random) catch return .write_failed;
    var temp_storage: [64]u8 = undefined;
    const temp_name = std.fmt.bufPrint(&temp_storage, ".{s}.{s}.tmp", .{ name, std.fmt.bytesToHex(random, .lower) }) catch
        return .write_failed;
    const file = directory.createFile(io, temp_name, .{ .exclusive = true }) catch return .write_failed;
    var file_open = true;
    var temp_exists = true;
    defer {
        if (file_open) file.close(io);
        if (temp_exists) directory.deleteFile(io, temp_name) catch {};
    }
    file.writeStreamingAll(io, text) catch return .write_failed;
    file.sync(io) catch return .write_failed;
    file.close(io);
    file_open = false;
    directory.rename(temp_name, directory, name, io) catch return .write_failed;
    temp_exists = false;
    // The rename is in place; a directory sync that fails leaves it so.
    syncDirectory(io, directory);
    return .{ .saved = Revision.of(text) };
}

fn directoryPermissions() std.Io.File.Permissions {
    return if (builtin.os.tag == .windows) .default_dir else .fromMode(0o700);
}

fn syncDirectory(io: std.Io, directory: std.Io.Dir) void {
    if (builtin.os.tag == .windows) return;
    const handle: std.Io.File = .{ .handle = directory.handle, .flags = .{ .nonblocking = false } };
    handle.sync(io) catch {};
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const NoCredentials = struct {
    marker: ?[]const u8 = null,

    fn contains(context: *anyopaque, text: []const u8) bool {
        const self: *NoCredentials = @ptrCast(@alignCast(context));
        const marker = self.marker orelse return false;
        return std.mem.indexOf(u8, text, marker) != null;
    }

    fn check(self: *NoCredentials) CredentialCheck {
        return .{ .context = self, .contains_fn = contains };
    }
};

fn globalPath(tmp: std.testing.TmpDir) ![]u8 {
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    return std.fs.path.join(testing.allocator, &.{ root, source.global_directory, source.file_name });
}

test "loading creates nothing, and the first save creates the directory and the file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try globalPath(tmp);
    defer testing.allocator.free(path);
    var credentials: NoCredentials = .{};
    var nothing = try load(testing.io, testing.allocator, path, credentials.check());
    defer nothing.deinit(testing.allocator);
    try testing.expectEqual(LoadState.absent, nothing.state);
    try testing.expect(nothing.revision.eql(.absent));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, source.global_directory, .{}));

    const saved = save(testing.io, path, .absent, "Answer in English.", credentials.check());
    try testing.expect(saved.saved.eql(Revision.of("Answer in English.")));
    var loaded = try load(testing.io, testing.allocator, path, credentials.check());
    defer loaded.deinit(testing.allocator);
    try testing.expectEqual(LoadState.ready, loaded.state);
    try testing.expectEqualStrings("Answer in English.", loaded.text.?);
    try testing.expect(loaded.revision.eql(saved.saved));

    // A second save against the loaded revision replaces the file; no
    // temporary file is left beside it.
    const again = save(testing.io, path, loaded.revision, "Answer in Chinese.", credentials.check());
    try testing.expect(again == .saved);
    var directory = try tmp.dir.openDir(testing.io, source.global_directory, .{ .iterate = true });
    defer directory.close(testing.io);
    var entries = directory.iterate();
    var count: usize = 0;
    while (try entries.next(testing.io)) |entry| {
        try testing.expectEqualStrings(source.file_name, entry.name);
        count += 1;
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "a change made outside the editor is a conflict, and the file stays as it was" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try globalPath(tmp);
    defer testing.allocator.free(path);
    var credentials: NoCredentials = .{};
    const first = save(testing.io, path, .absent, "first", credentials.check()).saved;
    // Someone else writes the file after the editor loaded `first`.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = source.global_directory ++ std.fs.path.sep_str ++ source.file_name, .data = "outside" });
    const outcome = save(testing.io, path, first, "mine", credentials.check());
    try testing.expect(outcome.conflict.eql(Revision.of("outside")));
    var loaded = try load(testing.io, testing.allocator, path, credentials.check());
    defer loaded.deinit(testing.allocator);
    try testing.expectEqualStrings("outside", loaded.text.?);
    // Saving over it once the user has seen it is allowed.
    try testing.expect(save(testing.io, path, outcome.conflict, "mine", credentials.check()) == .saved);
    // A file created outside after the editor found none conflicts too.
    var tmp_other = testing.tmpDir(.{});
    defer tmp_other.cleanup();
    const other_path = try globalPath(tmp_other);
    defer testing.allocator.free(other_path);
    try tmp_other.dir.createDirPath(testing.io, source.global_directory);
    try tmp_other.dir.writeFile(testing.io, .{ .sub_path = source.global_directory ++ std.fs.path.sep_str ++ source.file_name, .data = "created outside" });
    try testing.expect(save(testing.io, other_path, .absent, "mine", credentials.check()) == .conflict);
}

test "the limit, non-text and credentials are refused before anything is written" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try globalPath(tmp);
    defer testing.allocator.free(path);
    var credentials: NoCredentials = .{ .marker = "sk-secret" };
    const over = try testing.allocator.alloc(u8, max_text_bytes + 1);
    defer testing.allocator.free(over);
    @memset(over, 'a');
    try testing.expect(save(testing.io, path, .absent, over, credentials.check()) == .too_large);
    try testing.expect(save(testing.io, path, .absent, over[0..max_text_bytes], credentials.check()) == .saved);
    var loaded = try load(testing.io, testing.allocator, path, credentials.check());
    defer loaded.deinit(testing.allocator);
    try testing.expect(save(testing.io, path, loaded.revision, "bad\xff", credentials.check()) == .invalid_text);
    try testing.expect(save(testing.io, path, loaded.revision, "nul\x00", credentials.check()) == .invalid_text);
    try testing.expect(save(testing.io, path, loaded.revision, "key sk-secret here", credentials.check()) == .contains_credential);
    // Every refusal left the saved file alone.
    var again = try load(testing.io, testing.allocator, path, credentials.check());
    defer again.deinit(testing.allocator);
    try testing.expect(again.revision.eql(loaded.revision));

    // A file holding a credential is never handed over for editing.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = source.global_directory ++ std.fs.path.sep_str ++ source.file_name, .data = "token sk-secret" });
    var guarded = try load(testing.io, testing.allocator, path, credentials.check());
    defer guarded.deinit(testing.allocator);
    try testing.expectEqual(LoadState.contains_credential, guarded.state);
    try testing.expect(guarded.text == null);
}

test "a file larger than the editor loads is shown by size, and non-text as unreadable" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try globalPath(tmp);
    defer testing.allocator.free(path);
    var credentials: NoCredentials = .{};
    try tmp.dir.createDirPath(testing.io, source.global_directory);
    const huge = try testing.allocator.alloc(u8, max_load_bytes + 1);
    defer testing.allocator.free(huge);
    @memset(huge, 'h');
    const relative = source.global_directory ++ std.fs.path.sep_str ++ source.file_name;
    try tmp.dir.writeFile(testing.io, .{ .sub_path = relative, .data = huge });
    var large = try load(testing.io, testing.allocator, path, credentials.check());
    defer large.deinit(testing.allocator);
    try testing.expectEqual(LoadState.too_large, large.state);
    try testing.expectEqual(@as(u64, max_load_bytes + 1), large.byte_length.?);
    // Its revision is still known to a save, which conflicts.
    try testing.expect(save(testing.io, path, .absent, "replace", credentials.check()) == .conflict);
    // Between the instruction limit and the load limit the editor shows it.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = relative, .data = huge[0 .. max_text_bytes + 10] });
    var over = try load(testing.io, testing.allocator, path, credentials.check());
    defer over.deinit(testing.allocator);
    try testing.expectEqual(LoadState.ready, over.state);
    try testing.expectEqual(max_text_bytes + 10, over.text.?.len);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = relative, .data = bom ++ "caf\xe9" });
    var binary = try load(testing.io, testing.allocator, path, credentials.check());
    defer binary.deinit(testing.allocator);
    try testing.expectEqual(LoadState.unreadable, binary.state);
    try testing.expectEqual(source.Unreadable.not_utf8, binary.reason.?);
}

test "revisions cross the wire as hex or absent, and nothing else parses" {
    const revision = Revision.of("text");
    var storage: [64]u8 = undefined;
    const wire = revision.slice(&storage);
    try testing.expectEqual(@as(usize, 64), wire.len);
    try testing.expect(Revision.parse(wire).?.eql(revision));
    try testing.expect(Revision.parse("absent").?.eql(.absent));
    try testing.expectEqualStrings("absent", Revision.absent.slice(&storage));
    try testing.expect(Revision.parse("") == null);
    try testing.expect(Revision.parse("ABSENT") == null);
    var upper = revision.text();
    upper[0] = 'A';
    try testing.expect(Revision.parse(&upper) == null);
}
