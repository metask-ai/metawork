const std = @import("std");
const builtin = @import("builtin");

pub const Limits = struct {
    max_files: usize = 512,
    max_total_bytes: u64 = 64 * 1024 * 1024,
    max_file_bytes: u64 = 16 * 1024 * 1024,
    max_path_bytes: usize = 512,
    max_component_bytes: usize = 128,
    max_archive_bytes: u64 = 32 * 1024 * 1024,
};

const default_max_files = 512;
const default_max_path_bytes = 512;
const default_max_component_bytes = 128;

pub const Error = std.mem.Allocator.Error || error{
    SourceUnavailable,
    DestinationUnavailable,
    InvalidPath,
    DuplicatePath,
    UnsupportedEntry,
    UnsupportedCompression,
    FileLimitExceeded,
    FileTooLarge,
    TotalSizeExceeded,
    ArchiveTooLarge,
    ArchiveCorrupt,
    SkillDefinitionMissing,
    MultipleSkillDefinitions,
    InvalidArchiveRoot,
    ReadFailed,
    WriteFailed,
    DefinitionTooLarge,
    InvalidDefinition,
};

pub const max_preview_definition_bytes: usize = 256 * 1024;

/// Installed text is shared with other Skill consumers. Only AgentCore expands
/// this token; other readers must keep using their own definition location.
pub const resource_context =
    \\Skill resource directory: ${CLAUDE_SKILL_DIR}
    \\If this value is an expanded absolute path, resolve this Skill's relative
    \\resource paths against it. If it is still a template token, do not use it as
    \\a path or shell environment variable. Instead use the directory containing
    \\this SKILL.md, as identified by the invoking tool's Skill-location context.
    \\If neither location is available, report that resources cannot be located;
    \\do not guess a filesystem root.
    \\Use the existing tools and permission policy to access resources.
    \\Use the invoking tool's activation or reload mechanism to obtain current
    \\resource paths when continuing work.
    \\
    \\
;

/// Deterministic installed definition. Source bytes and metadata are preserved;
/// only our exact leading body block is recognized on export/reimport.
pub fn managedDefinition(allocator: std.mem.Allocator, definition: []const u8) Error![]u8 {
    if (definition.len > max_preview_definition_bytes) return error.DefinitionTooLarge;
    if (!std.unicode.utf8ValidateSlice(definition)) return error.InvalidDefinition;
    const metadata = parseDefinitionMetadata(definition) orelse return error.InvalidDefinition;
    const body = definition[metadata.body_offset..];
    if (std.mem.startsWith(u8, body, resource_context)) return allocator.dupe(u8, definition);
    const separator: usize = if (metadata.body_offset > 0 and definition[metadata.body_offset - 1] != '\n') 1 else 0;
    const added = resource_context.len + separator;
    if (added > max_preview_definition_bytes - definition.len) return error.DefinitionTooLarge;
    const result = try allocator.alloc(u8, definition.len + added);
    @memcpy(result[0..metadata.body_offset], definition[0..metadata.body_offset]);
    if (separator != 0) result[metadata.body_offset] = '\n';
    const start = metadata.body_offset + separator;
    @memcpy(result[start..][0..resource_context.len], resource_context);
    @memcpy(result[start + resource_context.len ..], body);
    return result;
}

pub const Preview = struct {
    allocator: std.mem.Allocator,
    definition: []u8,
    invocation_name: []const u8,
    display_name: []const u8,
    description: []const u8,
    file_count: usize,
    total_bytes: u64,
    content_hash: [std.crypto.hash.sha2.Sha256.digest_length]u8,

    pub fn deinit(self: *Preview) void {
        self.allocator.free(self.definition);
        self.* = undefined;
    }
};

pub const FileEntry = struct {
    path: []u8,
    size: u64,

    fn deinit(self: *FileEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.* = undefined;
    }
};

pub const Manifest = struct {
    allocator: std.mem.Allocator,
    files: []FileEntry,
    total_bytes: u64,
    content_hash: [std.crypto.hash.sha2.Sha256.digest_length]u8,

    pub fn deinit(self: *Manifest) void {
        for (self.files) |*entry| entry.deinit(self.allocator);
        self.allocator.free(self.files);
        self.* = undefined;
    }
};

pub const ArchiveInspection = struct {
    file_count: usize,
    total_bytes: u64,
    wrapper: ?[default_max_component_bytes]u8 = null,
    wrapper_len: usize = 0,

    pub fn wrapperName(self: *const ArchiveInspection) ?[]const u8 {
        if (self.wrapper) |*bytes| return bytes[0..self.wrapper_len];
        return null;
    }
};

/// Scans a selected directory without following links and returns a stable,
/// content-addressed list of regular files. The selected directory itself is
/// the Skill root, so SKILL.md must be a direct child.
pub fn inspectDirectory(
    io: std.Io,
    allocator: std.mem.Allocator,
    source: std.Io.Dir,
    limits: Limits,
) Error!Manifest {
    var files: std.ArrayList(FileEntry) = .empty;
    errdefer {
        for (files.items) |*entry| entry.deinit(allocator);
        files.deinit(allocator);
    }
    var total: u64 = 0;
    var saw_definition = false;
    var walker = source.walk(allocator) catch return error.SourceUnavailable;
    defer walker.deinit();
    while (walker.next(io) catch return error.SourceUnavailable) |entry| {
        const normalized = try normalizeNativePath(allocator, entry.path);
        defer allocator.free(normalized);
        if (ignoredPath(normalized, entry.kind == .directory)) {
            if (entry.kind == .directory) walker.leave(io);
            continue;
        }
        try validateRelativePath(normalized, limits);
        switch (entry.kind) {
            .directory => continue,
            .file => {},
            else => return error.UnsupportedEntry,
        }
        if (files.items.len == limits.max_files) return error.FileLimitExceeded;
        const file = try openRegularFile(io, entry.dir, entry.basename);
        defer file.close(io);
        const stat = file.stat(io) catch return error.SourceUnavailable;
        if (stat.kind != .file) return error.UnsupportedEntry;
        if (stat.size > limits.max_file_bytes) return error.FileTooLarge;
        total = std.math.add(u64, total, stat.size) catch
            return error.TotalSizeExceeded;
        if (total > limits.max_total_bytes) return error.TotalSizeExceeded;
        if (std.mem.eql(u8, normalized, "SKILL.md")) saw_definition = true;
        try files.append(allocator, .{
            .path = try allocator.dupe(u8, normalized),
            .size = stat.size,
        });
    }
    if (!saw_definition) return error.SkillDefinitionMissing;
    std.mem.sort(FileEntry, files.items, {}, lessThanFileEntry);
    const hash = try hashFiles(io, source, files.items);
    return .{
        .allocator = allocator,
        .files = try files.toOwnedSlice(allocator),
        .total_bytes = total,
        .content_hash = hash,
    };
}

/// Copies an already-inspected directory into an empty candidate directory.
/// Only the regular bytes named by the manifest are copied.
pub fn stageDirectory(
    io: std.Io,
    source: std.Io.Dir,
    destination: std.Io.Dir,
    manifest: *const Manifest,
) Error!void {
    for (manifest.files) |entry| {
        const dirname = std.fs.path.dirname(entry.path);
        if (dirname) |path| destination.createDirPath(io, path) catch
            return error.DestinationUnavailable;
        source.copyFile(
            entry.path,
            destination,
            entry.path,
            io,
            .{
                .permissions = privateFilePermissions(),
                .replace = false,
            },
        ) catch return error.WriteFailed;
    }
}

pub fn previewDirectory(
    io: std.Io,
    allocator: std.mem.Allocator,
    source: std.Io.Dir,
    limits: Limits,
) Error!Preview {
    var manifest = try inspectDirectory(io, allocator, source, limits);
    defer manifest.deinit();
    const definition_entry = for (manifest.files) |entry| {
        if (std.mem.eql(u8, entry.path, "SKILL.md")) break entry;
    } else return error.SkillDefinitionMissing;
    if (definition_entry.size > max_preview_definition_bytes)
        return error.DefinitionTooLarge;
    const definition = try allocator.alloc(u8, @intCast(definition_entry.size));
    errdefer allocator.free(definition);
    const file = try openRegularFile(io, source, "SKILL.md");
    defer file.close(io);
    const read = file.readPositionalAll(io, definition, 0) catch
        return error.ReadFailed;
    if (read != definition.len or !std.unicode.utf8ValidateSlice(definition))
        return error.InvalidDefinition;
    const metadata = parseDefinitionMetadata(definition) orelse
        return error.InvalidDefinition;
    return .{
        .allocator = allocator,
        .definition = definition,
        .invocation_name = metadata.name,
        .display_name = metadata.name,
        .description = metadata.description,
        .file_count = manifest.files.len,
        .total_bytes = manifest.total_bytes,
        .content_hash = manifest.content_hash,
    };
}

/// Preflights a ZIP-compatible `.skill`/`.zip` before any extraction. This
/// closes the gaps in std.zip: special Unix entries, duplicate normalized
/// names, wrapper layout, and bounded expanded sizes are checked here.
pub fn inspectArchive(
    io: std.Io,
    allocator: std.mem.Allocator,
    archive: std.Io.File,
    limits: Limits,
) Error!ArchiveInspection {
    const length = archive.length(io) catch return error.ReadFailed;
    if (length == 0) return error.ArchiveCorrupt;
    if (length > limits.max_archive_bytes) return error.ArchiveTooLarge;
    var buffer: [4096]u8 = undefined;
    var reader = archive.reader(io, &buffer);
    var iterator = std.zip.Iterator.init(&reader) catch return error.ArchiveCorrupt;
    var names: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = names.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        names.deinit(allocator);
    }
    var file_count: usize = 0;
    var total: u64 = 0;
    var definition_path: ?[]const u8 = null;
    if (limits.max_path_bytes > default_max_path_bytes or
        limits.max_component_bytes > default_max_component_bytes)
        return error.InvalidPath;
    var filename_storage: [default_max_path_bytes + 1]u8 = undefined;
    while (iterator.next() catch return error.ArchiveCorrupt) |entry| {
        if (entry.filename_len == 0 or entry.filename_len > limits.max_path_bytes + 1)
            return error.InvalidPath;
        reader.seekTo(entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader)) catch
            return error.ArchiveCorrupt;
        const filename = filename_storage[0..entry.filename_len];
        reader.interface.readSliceAll(filename) catch return error.ArchiveCorrupt;
        if (std.mem.findScalar(u8, filename, '\\') != null) return error.InvalidPath;
        const is_directory = filename[filename.len - 1] == '/';
        const normalized = if (is_directory) filename[0 .. filename.len - 1] else filename;
        try validateRelativePath(normalized, limits);
        try validateArchiveKind(&reader, entry, is_directory);
        switch (entry.compression_method) {
            .store, .deflate => {},
            else => return error.UnsupportedCompression,
        }
        const owned_name = try allocator.dupe(u8, normalized);
        const result = try names.getOrPut(allocator, owned_name);
        if (result.found_existing) {
            allocator.free(owned_name);
            return error.DuplicatePath;
        }
        if (is_directory) {
            if (entry.uncompressed_size != 0) return error.ArchiveCorrupt;
            continue;
        }
        if (file_count == limits.max_files) return error.FileLimitExceeded;
        if (entry.uncompressed_size > limits.max_file_bytes) return error.FileTooLarge;
        total = std.math.add(u64, total, entry.uncompressed_size) catch
            return error.TotalSizeExceeded;
        if (total > limits.max_total_bytes) return error.TotalSizeExceeded;
        file_count += 1;
        if (std.mem.eql(u8, std.fs.path.basename(normalized), "SKILL.md")) {
            if (definition_path != null) return error.MultipleSkillDefinitions;
            definition_path = result.key_ptr.*;
        }
    }
    const definition = definition_path orelse return error.SkillDefinitionMissing;
    var inspection: ArchiveInspection = .{
        .file_count = file_count,
        .total_bytes = total,
    };
    if (!std.mem.eql(u8, definition, "SKILL.md")) {
        const slash = std.mem.findScalar(u8, definition, '/') orelse
            return error.InvalidArchiveRoot;
        if (!std.mem.eql(u8, definition[slash + 1 ..], "SKILL.md") or slash == 0)
            return error.InvalidArchiveRoot;
        const wrapper = definition[0..slash];
        if (wrapper.len > default_max_component_bytes) return error.InvalidArchiveRoot;
        var it = names.keyIterator();
        while (it.next()) |name| {
            if (!pathInsideWrapper(name.*, wrapper)) return error.InvalidArchiveRoot;
        }
        var storage: [default_max_component_bytes]u8 = undefined;
        @memcpy(storage[0..wrapper.len], wrapper);
        inspection.wrapper = storage;
        inspection.wrapper_len = wrapper.len;
    } else {
        var it = names.keyIterator();
        while (it.next()) |name| {
            if (std.mem.indexOfScalar(u8, name.*, '/')) |slash| {
                if (slash == 0) return error.InvalidArchiveRoot;
            }
        }
    }
    return inspection;
}

/// Extracts a preflighted archive into an empty scratch directory. Callers
/// subsequently inspect and copy either the scratch root or the one wrapper.
pub fn extractArchive(
    io: std.Io,
    archive: std.Io.File,
    scratch: std.Io.Dir,
) Error!void {
    var buffer: [4096]u8 = undefined;
    var reader = archive.reader(io, &buffer);
    std.zip.extract(scratch, &reader, .{}) catch return error.ArchiveCorrupt;
}

/// Writes a deterministic, store-only canonical `.skill` ZIP. File names are
/// sorted, timestamps are zeroed, and no provenance or platform metadata is
/// included.
pub fn exportArchive(
    io: std.Io,
    source: std.Io.Dir,
    destination: std.Io.File,
    manifest: *const Manifest,
) Error!void {
    if (manifest.files.len > std.math.maxInt(u16)) return error.FileLimitExceeded;
    var output_buffer: [8192]u8 = undefined;
    var writer = destination.writer(io, &output_buffer);
    if (manifest.files.len > default_max_files) return error.FileLimitExceeded;
    var central: [default_max_files]CentralRecord = undefined;
    var offset: u64 = 0;
    for (manifest.files, 0..) |entry, index| {
        if (entry.size > std.math.maxInt(u32) or offset > std.math.maxInt(u32))
            return error.FileTooLarge;
        const file = try openRegularFile(io, source, entry.path);
        defer file.close(io);
        const bytes = readFileBounded(io, file, entry.size) catch |err| return err;
        defer std.heap.page_allocator.free(bytes);
        const crc = std.hash.Crc32.hash(bytes);
        central[index] = .{
            .path = entry.path,
            .size = @intCast(entry.size),
            .crc32 = crc,
            .local_offset = @intCast(offset),
        };
        try writeLocalHeader(&writer.interface, entry.path, @intCast(entry.size), crc);
        writer.interface.writeAll(bytes) catch return error.WriteFailed;
        offset += @sizeOf(std.zip.LocalFileHeader) + entry.path.len + entry.size;
    }
    const central_offset = offset;
    for (central[0..manifest.files.len]) |record| {
        try writeCentralHeader(&writer.interface, record);
        offset += @sizeOf(std.zip.CentralDirectoryFileHeader) + record.path.len;
    }
    const central_size = offset - central_offset;
    if (central_offset > std.math.maxInt(u32) or central_size > std.math.maxInt(u32))
        return error.ArchiveTooLarge;
    try writeEndRecord(
        &writer.interface,
        @intCast(manifest.files.len),
        @intCast(central_size),
        @intCast(central_offset),
    );
    writer.interface.flush() catch return error.WriteFailed;
}

pub fn validateRelativePath(path: []const u8, limits: Limits) Error!void {
    if (path.len == 0 or path.len > limits.max_path_bytes or
        !std.unicode.utf8ValidateSlice(path) or path[0] == '/' or
        std.mem.indexOfScalar(u8, path, 0) != null or
        std.mem.findScalar(u8, path, '\\') != null or
        std.fs.path.isAbsolute(path))
        return error.InvalidPath;
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (component.len == 0 or component.len > limits.max_component_bytes or
            std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..") or
            component[component.len - 1] == '.' or component[component.len - 1] == ' ' or
            windowsReservedName(component))
            return error.InvalidPath;
        if (component.len >= 2 and std.ascii.isAlphabetic(component[0]) and component[1] == ':')
            return error.InvalidPath;
    }
}

const CentralRecord = struct {
    path: []const u8,
    size: u32,
    crc32: u32,
    local_offset: u32,
};

fn writeLocalHeader(writer: *std.Io.Writer, path: []const u8, size: u32, crc: u32) Error!void {
    writer.writeAll(&std.zip.local_file_header_sig) catch return error.WriteFailed;
    writer.writeInt(u16, 20, .little) catch return error.WriteFailed;
    writer.writeInt(u16, 0, .little) catch return error.WriteFailed;
    writer.writeInt(u16, 0, .little) catch return error.WriteFailed;
    writer.writeInt(u16, 0, .little) catch return error.WriteFailed;
    writer.writeInt(u16, 0, .little) catch return error.WriteFailed;
    writer.writeInt(u32, crc, .little) catch return error.WriteFailed;
    writer.writeInt(u32, size, .little) catch return error.WriteFailed;
    writer.writeInt(u32, size, .little) catch return error.WriteFailed;
    writer.writeInt(u16, @intCast(path.len), .little) catch return error.WriteFailed;
    writer.writeInt(u16, 0, .little) catch return error.WriteFailed;
    writer.writeAll(path) catch return error.WriteFailed;
}

fn writeCentralHeader(writer: *std.Io.Writer, record: CentralRecord) Error!void {
    writer.writeAll(&std.zip.central_file_header_sig) catch return error.WriteFailed;
    writer.writeInt(u16, (3 << 8) | 20, .little) catch return error.WriteFailed;
    writer.writeInt(u16, 20, .little) catch return error.WriteFailed;
    writer.writeInt(u16, 0, .little) catch return error.WriteFailed;
    writer.writeInt(u16, 0, .little) catch return error.WriteFailed;
    writer.writeInt(u16, 0, .little) catch return error.WriteFailed;
    writer.writeInt(u16, 0, .little) catch return error.WriteFailed;
    writer.writeInt(u32, record.crc32, .little) catch return error.WriteFailed;
    writer.writeInt(u32, record.size, .little) catch return error.WriteFailed;
    writer.writeInt(u32, record.size, .little) catch return error.WriteFailed;
    writer.writeInt(u16, @intCast(record.path.len), .little) catch return error.WriteFailed;
    writer.writeInt(u16, 0, .little) catch return error.WriteFailed;
    writer.writeInt(u16, 0, .little) catch return error.WriteFailed;
    writer.writeInt(u16, 0, .little) catch return error.WriteFailed;
    writer.writeInt(u16, 0, .little) catch return error.WriteFailed;
    writer.writeInt(u32, 0o100644 << 16, .little) catch return error.WriteFailed;
    writer.writeInt(u32, record.local_offset, .little) catch return error.WriteFailed;
    writer.writeAll(record.path) catch return error.WriteFailed;
}

fn writeEndRecord(writer: *std.Io.Writer, count: u16, central_size: u32, central_offset: u32) Error!void {
    writer.writeAll(&std.zip.end_record_sig) catch return error.WriteFailed;
    writer.writeInt(u16, 0, .little) catch return error.WriteFailed;
    writer.writeInt(u16, 0, .little) catch return error.WriteFailed;
    writer.writeInt(u16, count, .little) catch return error.WriteFailed;
    writer.writeInt(u16, count, .little) catch return error.WriteFailed;
    writer.writeInt(u32, central_size, .little) catch return error.WriteFailed;
    writer.writeInt(u32, central_offset, .little) catch return error.WriteFailed;
    writer.writeInt(u16, 0, .little) catch return error.WriteFailed;
}

fn validateArchiveKind(reader: *std.Io.File.Reader, entry: std.zip.Iterator.Entry, is_directory: bool) Error!void {
    reader.seekTo(entry.header_zip_offset) catch return error.ArchiveCorrupt;
    const header = reader.interface.takeStruct(std.zip.CentralDirectoryFileHeader, .little) catch
        return error.ArchiveCorrupt;
    const host = header.version_made_by >> 8;
    if (host == 3 or host == 19) {
        const file_type = (header.external_file_attributes >> 16) & 0xf000;
        if (file_type != 0 and file_type != 0x8000 and file_type != 0x4000)
            return error.UnsupportedEntry;
        if (file_type == 0x4000 and !is_directory) return error.UnsupportedEntry;
        if (file_type == 0x8000 and is_directory) return error.UnsupportedEntry;
    } else if ((header.external_file_attributes & 0x10 != 0) != is_directory) {
        return error.UnsupportedEntry;
    }
}

fn normalizeNativePath(allocator: std.mem.Allocator, path: []const u8) Error![]u8 {
    const result = try allocator.dupe(u8, path);
    if (builtin.os.tag == .windows) std.mem.replaceScalar(u8, result, '\\', '/');
    return result;
}

fn ignoredPath(path: []const u8, is_directory: bool) bool {
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, ".git") or std.mem.eql(u8, part, "__MACOSX"))
            return true;
    }
    const base = std.fs.path.basename(path);
    return !is_directory and (std.mem.eql(u8, base, ".DS_Store") or
        std.ascii.eqlIgnoreCase(base, "Thumbs.db"));
}

fn windowsReservedName(component: []const u8) bool {
    const end = std.mem.findScalar(u8, component, '.') orelse component.len;
    const stem = component[0..end];
    if (std.ascii.eqlIgnoreCase(stem, "CON") or
        std.ascii.eqlIgnoreCase(stem, "PRN") or
        std.ascii.eqlIgnoreCase(stem, "AUX") or
        std.ascii.eqlIgnoreCase(stem, "NUL")) return true;
    if (stem.len == 4 and stem[3] >= '1' and stem[3] <= '9') {
        return std.ascii.eqlIgnoreCase(stem[0..3], "COM") or
            std.ascii.eqlIgnoreCase(stem[0..3], "LPT");
    }
    return false;
}

fn pathInsideWrapper(path: []const u8, wrapper: []const u8) bool {
    return std.mem.eql(u8, path, wrapper) or
        (path.len > wrapper.len and path[wrapper.len] == '/' and
            std.mem.eql(u8, path[0..wrapper.len], wrapper));
}

fn lessThanFileEntry(_: void, left: FileEntry, right: FileEntry) bool {
    return std.mem.lessThan(u8, left.path, right.path);
}

fn openRegularFile(io: std.Io, dir: std.Io.Dir, path: []const u8) Error!std.Io.File {
    var file = dir.openFile(io, path, .{
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch return error.SourceUnavailable;
    // Zig 0.16 opens a no-follow Windows handle asynchronously but reports it
    // as blocking. Match the File flag to the handle before any positional I/O.
    if (builtin.os.tag == .windows) file.flags.nonblocking = true;
    return file;
}

fn hashFiles(io: std.Io, source: std.Io.Dir, files: []const FileEntry) Error![32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [8192]u8 = undefined;
    for (files) |entry| {
        var length_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &length_bytes, entry.path.len, .little);
        hasher.update(&length_bytes);
        hasher.update(entry.path);
        const file = try openRegularFile(io, source, entry.path);
        defer file.close(io);
        var offset: u64 = 0;
        while (offset < entry.size) {
            const wanted: usize = @intCast(@min(entry.size - offset, buffer.len));
            const read = file.readPositionalAll(io, buffer[0..wanted], offset) catch
                return error.ReadFailed;
            if (read != wanted) return error.ReadFailed;
            hasher.update(buffer[0..wanted]);
            offset += wanted;
        }
        const stat = file.stat(io) catch return error.ReadFailed;
        if (stat.size != entry.size) return error.ReadFailed;
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

fn readFileBounded(io: std.Io, file: std.Io.File, expected: u64) Error![]u8 {
    const bytes = std.heap.page_allocator.alloc(u8, @intCast(expected)) catch
        return error.OutOfMemory;
    errdefer std.heap.page_allocator.free(bytes);
    const read = file.readPositionalAll(io, bytes, 0) catch return error.ReadFailed;
    if (read != expected) return error.ReadFailed;
    const stat = file.stat(io) catch return error.ReadFailed;
    if (stat.size != expected) return error.ReadFailed;
    return bytes;
}

fn privateFilePermissions() std.Io.File.Permissions {
    return if (builtin.os.tag == .windows)
        .default_file
    else
        .fromMode(0o600);
}

const DefinitionMetadata = struct {
    name: []const u8,
    description: []const u8,
    body_offset: usize,
};

fn parseDefinitionMetadata(definition: []const u8) ?DefinitionMetadata {
    var lines = std.mem.splitScalar(u8, definition, '\n');
    if (!std.mem.eql(u8, std.mem.trimEnd(u8, lines.next() orelse return null, "\r"), "---"))
        return null;
    var name: ?[]const u8 = null;
    var description: ?[]const u8 = null;
    var closed = false;
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (std.mem.eql(u8, line, "---")) {
            closed = true;
            break;
        }
        if (line.len == 0 or line[0] == ' ' or line[0] == '\t') continue;
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        const value = trimYamlScalar(std.mem.trim(u8, line[colon + 1 ..], " \t"));
        if (std.mem.eql(u8, key, "name")) {
            if (name != null or !validInvocationName(value)) return null;
            name = value;
        } else if (std.mem.eql(u8, key, "description")) {
            if (description != null or value.len > 4096) return null;
            description = value;
        }
    }
    if (!closed) return null;
    return .{
        .name = name orelse return null,
        .description = description orelse "",
        .body_offset = lines.index orelse definition.len,
    };
}

fn trimYamlScalar(value: []const u8) []const u8 {
    if (value.len >= 2 and
        ((value[0] == '"' and value[value.len - 1] == '"') or
            (value[0] == '\'' and value[value.len - 1] == '\'')))
        return value[1 .. value.len - 1];
    return value;
}

fn validInvocationName(value: []const u8) bool {
    if (value.len == 0 or value.len > 128 or value[0] == '-' or value[value.len - 1] == '-')
        return false;
    for (value) |byte| if (!std.ascii.isLower(byte) and
        !std.ascii.isDigit(byte) and byte != '-') return false;
    return true;
}

test "relative Skill paths reject traversal aliases and Windows hazards" {
    const bad = [_][]const u8{
        "",            "/SKILL.md",   "../SKILL.md", "a/../SKILL.md", "a//SKILL.md",
        "a\\SKILL.md", "C:/SKILL.md", "CON",         "aux.txt",       "name. ",
        "name.",
    };
    for (bad) |path| try std.testing.expectError(
        error.InvalidPath,
        validateRelativePath(path, .{}),
    );
    try validateRelativePath("references/guide.md", .{});
}

test "directory inspection is stable and excludes platform metadata" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "SKILL.md", .data = "# Demo" });
    try tmp.dir.createDir(std.testing.io, "references", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "references/guide.md", .data = "Guide" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".DS_Store", .data = "ignored" });
    var manifest = try inspectDirectory(std.testing.io, std.testing.allocator, tmp.dir, .{});
    defer manifest.deinit();
    try std.testing.expectEqual(@as(usize, 2), manifest.files.len);
    try std.testing.expectEqualStrings("SKILL.md", manifest.files[0].path);
    try std.testing.expectEqualStrings("references/guide.md", manifest.files[1].path);
    try std.testing.expectEqual(@as(u64, 11), manifest.total_bytes);
}

test "canonical archive round trips through bounded preflight" {
    var source = std.testing.tmpDir(.{ .iterate = true });
    defer source.cleanup();
    try source.dir.writeFile(std.testing.io, .{ .sub_path = "SKILL.md", .data = "# Demo" });
    try source.dir.writeFile(std.testing.io, .{ .sub_path = "notes.txt", .data = "notes" });
    var manifest = try inspectDirectory(std.testing.io, std.testing.allocator, source.dir, .{});
    defer manifest.deinit();
    var output = std.testing.tmpDir(.{});
    defer output.cleanup();
    const archive = try output.dir.createFile(std.testing.io, "demo.skill", .{ .read = true });
    defer archive.close(std.testing.io);
    try exportArchive(std.testing.io, source.dir, archive, &manifest);
    const inspection = try inspectArchive(std.testing.io, std.testing.allocator, archive, .{});
    try std.testing.expectEqual(@as(usize, 2), inspection.file_count);
    try std.testing.expectEqual(@as(u64, 11), inspection.total_bytes);
    try std.testing.expectEqual(@as(?[]const u8, null), inspection.wrapperName());
}

test "directory preview derives bounded metadata without owning runtime health" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "SKILL.md",
        .data = "---\nname: release-check\ndescription: Check a release before publishing.\n---\n# Release\n",
    });
    var preview = try previewDirectory(
        std.testing.io,
        std.testing.allocator,
        tmp.dir,
        .{},
    );
    defer preview.deinit();
    try std.testing.expectEqualStrings("release-check", preview.invocation_name);
    try std.testing.expectEqualStrings(
        "Check a release before publishing.",
        preview.description,
    );
    try std.testing.expectEqual(@as(usize, 1), preview.file_count);
}

test "managed definitions preserve author bytes and are idempotent across line endings" {
    for ([_][]const u8{ "---\nname: demo\ndescription: Demo\n---\n", "---\r\nname: demo\r\ndescription: Demo\r\n---\r\n" }) |front| {
        const body = "Read references/中文 guide.txt.\r\n${CLAUDE_SKILL_DIR}/existing\n";
        const original = try std.mem.concat(std.testing.allocator, u8, &.{ front, body });
        defer std.testing.allocator.free(original);
        const managed = try managedDefinition(std.testing.allocator, original);
        defer std.testing.allocator.free(managed);
        const expected = try std.mem.concat(std.testing.allocator, u8, &.{ front, resource_context, body });
        defer std.testing.allocator.free(expected);
        try std.testing.expectEqualStrings(expected, managed);
        const repeated = try managedDefinition(std.testing.allocator, managed);
        defer std.testing.allocator.free(repeated);
        try std.testing.expectEqualStrings(managed, repeated);
    }
    const no_newline = "---\nname: demo\n---";
    const managed = try managedDefinition(std.testing.allocator, no_newline);
    defer std.testing.allocator.free(managed);
    try std.testing.expectEqualStrings(no_newline ++ "\n" ++ resource_context, managed);
    const repeated = try managedDefinition(std.testing.allocator, managed);
    defer std.testing.allocator.free(repeated);
    try std.testing.expectEqualStrings(managed, repeated);
}

test "managed definitions reject invalid input and added bytes beyond the existing limit" {
    try std.testing.expectError(error.InvalidDefinition, managedDefinition(std.testing.allocator, "no front matter"));
    try std.testing.expectError(error.InvalidDefinition, managedDefinition(std.testing.allocator, "---\nname: demo\n---\n\xff"));
    const front = "---\nname: demo\n---\n";
    const original = try std.testing.allocator.alloc(u8, max_preview_definition_bytes - resource_context.len);
    defer std.testing.allocator.free(original);
    @memset(original, 'a');
    @memcpy(original[0..front.len], front);
    const managed = try managedDefinition(std.testing.allocator, original);
    defer std.testing.allocator.free(managed);
    try std.testing.expectEqual(max_preview_definition_bytes, managed.len);
    const repeated = try managedDefinition(std.testing.allocator, managed);
    defer std.testing.allocator.free(repeated);
    try std.testing.expectEqualStrings(managed, repeated);
    // A single additional source byte must fail; no truncation or larger budget.
    const oversized = try std.mem.concat(std.testing.allocator, u8, &.{ original, "a" });
    defer std.testing.allocator.free(oversized);
    try std.testing.expectError(error.DefinitionTooLarge, managedDefinition(std.testing.allocator, oversized));
}
