//! The user's own instruction files: where they are, how each is observed and
//! read before a Run, and what a Run reports it carried.
//!
//! Two sources. The global file is `<home>/.metawork/AGENTS.md`; the project
//! file is `AGENTS.md` at the root of the Task's actual working directory, and
//! only a manual, explicitly trusted Workspace has one. Nothing searches
//! upward or into subdirectories, and the Task's project membership plays no
//! part, as for directory Skills.
//!
//! A turn opens each file once and learns everything from the handle: what it
//! is, its size and modification time, and for a project file where it really
//! lives. Its text is read through that same handle, and only when what was
//! found differs from what the Session already carries. A file that cannot be
//! read is reported and left out: it never stops a Run.
const std = @import("std");
const agent = @import("metawork_agent_contract");
const handle = @import("handle.zig");
const builtin = @import("builtin");

pub const file_name = "AGENTS.md";
pub const global_directory = ".metawork";
pub const max_text_bytes: usize = agent.max_instruction_text_bytes;
pub const max_path_bytes: usize = agent.max_instruction_path_bytes;

pub const Unreadable = enum {
    access_denied,
    not_regular_file,
    /// A project file that resolves outside its working directory.
    outside_workspace,
    /// Not UTF-8 text, or text with a NUL byte.
    not_utf8,
    /// A path the Agent cannot name as a source: a control character, not
    /// UTF-8, or longer than it accepts. Checked before anything is opened.
    invalid_path,
    io_error,
};

/// One file as a turn's start found it. `failed` is also what a read that
/// failed after a successful open leaves behind, so the next turn, finding
/// the file again, tries once more.
pub const Observation = union(enum) {
    absent,
    file: struct { size: u64, mtime_ns: i96 },
    failed: Unreadable,

    pub fn eql(self: Observation, other: Observation) bool {
        return std.meta.eql(self, other);
    }
};

/// Both sources together. `null` is a source with no path: no home for the
/// global file, or a working directory that admits no project file.
pub const Fingerprint = struct {
    global: ?Observation,
    project: ?Observation,

    pub fn eql(self: Fingerprint, other: Fingerprint) bool {
        return std.meta.eql(self, other);
    }
};

/// What one source contributed to a Run.
pub const State = enum {
    /// Its text is in the Run's system prompt.
    applied,
    absent,
    /// Present but only whitespace: nothing to carry.
    empty,
    unreadable,
    /// Read, but Core would not take it; the other source was unaffected.
    rejected,
    /// The Session could not be updated; the Run carries what the previous
    /// one did.
    update_failed,
    /// No home directory, so there is no global file to read.
    unavailable,
};

pub const Use = struct {
    state: State,
    truncated: bool = false,
    reason: ?Unreadable = null,
};

/// What a Run reports. `project` is null where the working directory admits
/// no project file.
pub const InstructionsUse = struct {
    global: Use,
    project: ?Use,
};

/// The process-local fact a live attachment keeps: what its Session's profile
/// carries now, and the observation that produced it.
pub const Installed = struct {
    fingerprint: Fingerprint,
    use: InstructionsUse,
    /// Whether the profile carries any instruction section. A Session without
    /// one needs no call to stay without one.
    sections: bool,
};

pub const Document = struct {
    path: []u8,
    text: []u8,
    truncated: bool,
};

pub const Outcome = union(enum) {
    document: Document,
    absent,
    empty,
    unreadable: Unreadable,
};

/// Both sources read for one turn. Owns every document.
pub const Candidate = struct {
    allocator: std.mem.Allocator,
    fingerprint: Fingerprint,
    global: ?Outcome,
    project: ?Outcome,

    pub fn deinit(self: *Candidate) void {
        for ([_]?Outcome{ self.global, self.project }) |entry| {
            const outcome = entry orelse continue;
            switch (outcome) {
                .document => |document| {
                    self.allocator.free(document.path);
                    self.allocator.free(document.text);
                },
                else => {},
            }
        }
        self.* = undefined;
    }

    /// Borrowed views, valid while the Candidate lives.
    pub fn instructions(self: *const Candidate) agent.Instructions {
        return .{ .global = view(self.global), .project = view(self.project) };
    }

    pub fn hasDocuments(self: *const Candidate) bool {
        const value = self.instructions();
        return value.global != null or value.project != null;
    }

    /// `applied` is what Core took; null when the Session could not be
    /// updated at all, so every source with a path reports `update_failed`.
    pub fn use(self: *const Candidate, applied: ?agent.InstructionsApplied) InstructionsUse {
        return .{
            .global = if (self.global) |outcome| sourceUse(outcome, if (applied) |value| value.global else null) else .{ .state = .unavailable },
            .project = if (self.project) |outcome| sourceUse(outcome, if (applied) |value| value.project else null) else null,
        };
    }
};

fn view(entry: ?Outcome) ?agent.InstructionDocument {
    const outcome = entry orelse return null;
    return switch (outcome) {
        .document => |document| .{ .path = document.path, .text = document.text, .truncated = document.truncated },
        else => null,
    };
}

fn sourceUse(outcome: Outcome, applied: ?bool) Use {
    const taken = applied orelse return .{
        .state = .update_failed,
        .truncated = outcome == .document and outcome.document.truncated,
    };
    return switch (outcome) {
        .document => |document| .{ .state = if (taken) .applied else .rejected, .truncated = document.truncated },
        .absent => .{ .state = .absent },
        .empty => .{ .state = .empty },
        .unreadable => |reason| .{ .state = .unreadable, .reason = reason },
    };
}

/// What a turn's start produced: nothing to change, or both sources read.
pub const Preparation = union(enum) {
    unchanged,
    changed: Candidate,

    pub fn deinit(self: *Preparation) void {
        switch (self.*) {
            .unchanged => {},
            .changed => |*candidate| candidate.deinit(),
        }
        self.* = undefined;
    }
};

/// Where a turn's two sources live. A project path exists only with the
/// working directory it must stay inside.
pub const Paths = struct {
    global: ?[]const u8,
    project: ?struct { path: []const u8, root: []const u8 },

    pub fn deinit(self: *Paths, allocator: std.mem.Allocator) void {
        if (self.global) |path| allocator.free(path);
        if (self.project) |project| allocator.free(project.path);
        self.* = undefined;
    }
};

/// `home` is the canonical user home, if any; `project_root` the canonical
/// working directory when it admits a project file. A path the Agent would
/// refuse is kept as it is, never cut: opening it reports `invalid_path`.
pub fn resolvePaths(allocator: std.mem.Allocator, home: ?[]const u8, project_root: ?[]const u8) std.mem.Allocator.Error!Paths {
    const global = if (home) |root| try std.fs.path.join(allocator, &.{ root, global_directory, file_name }) else null;
    errdefer if (global) |path| allocator.free(path);
    const project_path = if (project_root) |root| try std.fs.path.join(allocator, &.{ root, file_name }) else null;
    return .{
        .global = global,
        .project = if (project_path) |path| .{ .path = path, .root = project_root.? } else null,
    };
}

/// One source as a turn found it. A regular file's handle stays open until
/// the turn has read it, so the text comes from the file that was checked.
pub const Opened = struct {
    observation: Observation,
    file: ?std.Io.File = null,

    pub fn close(self: *Opened, io: std.Io) void {
        if (self.file) |file| file.close(io);
        self.file = null;
    }
};

/// Opens `path` without waiting and checks it through the handle: a regular
/// file, and for a project file (`root` set) one that resolves inside the
/// working directory. A link may point anywhere; only a target inside is the
/// project's own file, so `AGENTS.md -> CLAUDE.md` is read and a link out of
/// the directory is not.
pub fn open(io: std.Io, allocator: std.mem.Allocator, path: []const u8, root: ?[]const u8) std.mem.Allocator.Error!Opened {
    // The Agent's own rule, asked for this document alone, so a path it
    // would refuse costs only this source.
    if (!agent.validInstructionPath(path)) return .{ .observation = .{ .failed = .invalid_path } };
    const opened = handle.openRegular(io, path) catch |err| return .{ .observation = switch (err) {
        error.FileNotFound => .absent,
        error.AccessDenied => .{ .failed = .access_denied },
        error.NotRegularFile => .{ .failed = .not_regular_file },
        error.InputOutput => .{ .failed = .io_error },
    } };
    var result: Opened = .{
        .observation = .{ .file = .{ .size = opened.stat.size, .mtime_ns = opened.stat.mtime.nanoseconds } },
        .file = opened.file,
    };
    errdefer result.close(io);
    if (root) |workspace| {
        if (try resolvedOutside(io, allocator, opened.file, workspace)) |failure| {
            result.close(io);
            result.observation = failure;
        }
    }
    return result;
}

/// Null when the open file lives inside `workspace`, otherwise what to
/// report instead of it.
fn resolvedOutside(io: std.Io, allocator: std.mem.Allocator, file: std.Io.File, workspace: []const u8) std.mem.Allocator.Error!?Observation {
    const buffer = try allocator.alloc(u8, std.fs.max_path_bytes);
    defer allocator.free(buffer);
    const length = file.realPath(io, buffer) catch |err| return switch (err) {
        error.FileNotFound => .absent,
        error.AccessDenied, error.PermissionDenied => .{ .failed = .access_denied },
        else => .{ .failed = .io_error },
    };
    return if (within(workspace, buffer[0..length])) null else .{ .failed = .outside_workspace };
}

fn within(root: []const u8, path: []const u8) bool {
    if (path.len <= root.len or !std.mem.startsWith(u8, path, root)) return false;
    const trimmed = std.mem.trimEnd(u8, root, "/\\");
    if (trimmed.len != root.len) return true; // the root itself ends in a separator
    return std.fs.path.isSep(path[root.len]);
}

/// What a turn's start does. Opens both files and compares what it finds
/// with `installed`, what the Session already carries; only a difference
/// reads them, through the handles just checked. Every handle is closed
/// before this returns, and nothing here fails for a file the user wrote.
pub fn prepare(io: std.Io, allocator: std.mem.Allocator, paths: Paths, installed: ?Fingerprint) std.mem.Allocator.Error!Preparation {
    var global: ?Opened = if (paths.global) |path| try open(io, allocator, path, null) else null;
    defer if (global) |*opened| opened.close(io);
    var project: ?Opened = if (paths.project) |entry| try open(io, allocator, entry.path, entry.root) else null;
    defer if (project) |*opened| opened.close(io);
    const found: Fingerprint = .{
        .global = if (global) |opened| opened.observation else null,
        .project = if (project) |opened| opened.observation else null,
    };
    if (installed) |carried| if (carried.eql(found)) return .unchanged;
    var candidate: Candidate = .{ .allocator = allocator, .fingerprint = found, .global = null, .project = null };
    errdefer candidate.deinit();
    if (global) |*opened| candidate.global = try readOpened(io, allocator, paths.global.?, opened, &candidate.fingerprint.global.?);
    if (project) |*opened| candidate.project = try readOpened(io, allocator, paths.project.?.path, opened, &candidate.fingerprint.project.?);
    return .{ .changed = candidate };
}

/// `recorded` is this source's entry in the fingerprint the Session will
/// keep. A read that fails after the open replaces it with the failure: the
/// file as found was never read, and keeping its size and time would make
/// the next turn, finding the same file, skip it for good.
fn readOpened(io: std.Io, allocator: std.mem.Allocator, path: []const u8, opened: *const Opened, recorded: *Observation) std.mem.Allocator.Error!Outcome {
    return switch (opened.observation) {
        .absent => .absent,
        .failed => |reason| .{ .unreadable = reason },
        .file => |found| read(io, allocator, opened.file.?, path, found.size) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            error.AccessDenied => {
                recorded.* = .{ .failed = .access_denied };
                return .{ .unreadable = .access_denied };
            },
            error.ReadFailed => {
                recorded.* = .{ .failed = .io_error };
                return .{ .unreadable = .io_error };
            },
        },
    };
}

const bom = "\xef\xbb\xbf";

pub const ReadError = std.mem.Allocator.Error || error{ AccessDenied, ReadFailed };

/// Reads at most the limit (plus a byte-order mark) from an open file and
/// decides what it contributes. `size` is the handle's size, which says
/// whether the file holds more than was kept; `path` is the document's
/// source line. What the bytes are (text, empty, not UTF-8) is an outcome;
/// only a read that could not happen is an error.
pub fn read(io: std.Io, allocator: std.mem.Allocator, file: std.Io.File, path: []const u8, size: u64) ReadError!Outcome {
    const capacity: usize = @intCast(@min(size, max_text_bytes + bom.len));
    const buffer = try allocator.alloc(u8, capacity);
    defer allocator.free(buffer);
    const count = file.readPositionalAll(io, buffer, 0) catch |err| return switch (err) {
        error.AccessDenied => error.AccessDenied,
        else => error.ReadFailed,
    };
    switch (decide(buffer[0..count], size > capacity)) {
        .text => |text| {
            const owned_path = try allocator.dupe(u8, path);
            errdefer allocator.free(owned_path);
            return .{ .document = .{
                .path = owned_path,
                .text = try allocator.dupe(u8, text.bytes),
                .truncated = text.truncated,
            } };
        },
        .empty => return .empty,
        .not_utf8 => return .{ .unreadable = .not_utf8 },
    }
}

pub const Decision = union(enum) {
    text: struct { bytes: []const u8, truncated: bool },
    empty,
    not_utf8,
};

/// What a file's leading bytes contribute. `more` says the file held bytes
/// past these. The kept text ends at a code point boundary at or below the
/// limit, so a character cut by the read is dropped whole.
pub fn decide(bytes: []const u8, more: bool) Decision {
    const body = if (std.mem.startsWith(u8, bytes, bom)) bytes[bom.len..] else bytes;
    var end: usize = @min(body.len, max_text_bytes);
    const truncated = more or body.len > max_text_bytes;
    if (truncated) end = codePointBoundary(body[0..end]);
    const text = body[0..end];
    if (!std.unicode.utf8ValidateSlice(text) or std.mem.indexOfScalar(u8, text, 0) != null) return .not_utf8;
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return .empty;
    return .{ .text = .{ .bytes = text, .truncated = truncated } };
}

/// The longest prefix that does not end inside a multi-byte sequence.
fn codePointBoundary(bytes: []const u8) usize {
    var start = bytes.len;
    var steps: usize = 0;
    while (start > 0 and steps < 4) : (steps += 1) {
        start -= 1;
        if (bytes[start] & 0xc0 != 0x80) break;
    }
    if (start == bytes.len) return bytes.len;
    const needed = std.unicode.utf8ByteSequenceLength(bytes[start]) catch return bytes.len;
    return if (bytes.len - start < needed) start else bytes.len;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "the kept text ends at a code point boundary at or below the limit" {
    for ([_][]const u8{ "\xc3\xa9", "\xe4\xb8\xad", "\xf0\x9f\x98\x80" }) |character| {
        // A character straddles the limit: everything before it is kept.
        const bytes = try testing.allocator.alloc(u8, max_text_bytes + character.len);
        defer testing.allocator.free(bytes);
        @memset(bytes, 'a');
        const at = max_text_bytes - 1;
        @memcpy(bytes[at..][0..character.len], character);
        const decided = decide(bytes, false);
        try testing.expectEqual(at, decided.text.bytes.len);
        try testing.expect(decided.text.truncated);
        // A character that ends exactly at the limit is kept whole.
        const exact = bytes[0 .. max_text_bytes + character.len - 1];
        @memset(exact, 'a');
        @memcpy(exact[max_text_bytes - character.len ..][0..character.len], character);
        const kept = decide(exact, true);
        try testing.expectEqual(max_text_bytes, kept.text.bytes.len);
        try testing.expect(std.mem.endsWith(u8, kept.text.bytes, character));
    }
}

test "a file at the limit is whole, and one byte more is truncated" {
    const bytes = try testing.allocator.alloc(u8, max_text_bytes + 1);
    defer testing.allocator.free(bytes);
    @memset(bytes, 'x');
    const whole = decide(bytes[0..max_text_bytes], false);
    try testing.expectEqual(max_text_bytes, whole.text.bytes.len);
    try testing.expect(!whole.text.truncated);
    const over = decide(bytes, false);
    try testing.expectEqual(max_text_bytes, over.text.bytes.len);
    try testing.expect(over.text.truncated);
}

test "a byte-order mark is dropped, whitespace is empty, and non-text is unreadable" {
    const marked = decide(bom ++ "Use tabs.", false);
    try testing.expectEqualStrings("Use tabs.", marked.text.bytes);
    try testing.expect(!marked.text.truncated);
    try testing.expectEqual(Decision.empty, decide("", false));
    try testing.expectEqual(Decision.empty, decide(bom, false));
    try testing.expectEqual(Decision.empty, decide(" \r\n\t\n", false));
    try testing.expectEqual(Decision.not_utf8, decide("caf\xe9", false));
    try testing.expectEqual(Decision.not_utf8, decide("nul\x00byte", false));
    // CRLF line ends are the user's text and stay as written.
    try testing.expectEqualStrings("one\r\ntwo", decide("one\r\ntwo", false).text.bytes);
}

test "every text a file contributes passes the Agent's own check" {
    const path = if (std.fs.path.sep == '\\') "C:\\repo\\AGENTS.md" else "/repo/AGENTS.md";
    const large = try testing.allocator.alloc(u8, max_text_bytes + 8);
    defer testing.allocator.free(large);
    @memset(large, 'a');
    @memcpy(large[max_text_bytes - 1 ..][0..3], "\xe4\xb8\xad");
    for ([_]struct { bytes: []const u8, more: bool }{
        .{ .bytes = "Use tabs.", .more = false },
        .{ .bytes = bom ++ " x ", .more = false },
        .{ .bytes = large, .more = true },
    }) |case| {
        const text = decide(case.bytes, case.more).text;
        try agent.validateInstructions(.{ .global = .{ .path = path, .text = text.bytes, .truncated = text.truncated } });
    }
}

test "only a home gives a global path, and only a project root gives a project path" {
    const sep = std.fs.path.sep_str;
    const root = if (sep[0] == '\\') "C:\\repo" else "/repo";
    const home = if (sep[0] == '\\') "C:\\Users\\user" else "/home/user";
    var both = try resolvePaths(testing.allocator, home, root);
    defer both.deinit(testing.allocator);
    try testing.expectEqualStrings(home ++ sep ++ ".metawork" ++ sep ++ "AGENTS.md", both.global.?);
    try testing.expectEqualStrings(root ++ sep ++ "AGENTS.md", both.project.?.path);
    try testing.expectEqualStrings(root, both.project.?.root);
    var neither = try resolvePaths(testing.allocator, null, null);
    defer neither.deinit(testing.allocator);
    try testing.expect(neither.global == null and neither.project == null);
    // A path the Agent would refuse is kept whole, never cut to name some
    // other file, and opening it reports why it is left out.
    const long = try testing.allocator.alloc(u8, max_path_bytes);
    defer testing.allocator.free(long);
    @memset(long, 'd');
    long[0] = sep[0];
    var too_long = try resolvePaths(testing.allocator, long, null);
    defer too_long.deinit(testing.allocator);
    try testing.expect(std.mem.startsWith(u8, too_long.global.?, long));
    var opened = try open(testing.io, testing.allocator, too_long.global.?, null);
    defer opened.close(testing.io);
    try testing.expectEqual(Observation{ .failed = .invalid_path }, opened.observation);
    try testing.expect(opened.file == null);
}

test "containment needs a separator after the root" {
    try testing.expect(within("/repo", "/repo/AGENTS.md"));
    try testing.expect(!within("/repo", "/repository/AGENTS.md"));
    try testing.expect(!within("/repo", "/repo"));
    try testing.expect(!within("/repo", "/other/AGENTS.md"));
    try testing.expect(within("C:\\", "C:\\AGENTS.md"));
}

fn tmpPath(dir: std.testing.TmpDir, name: []const u8) ![]u8 {
    const root = try dir.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    return std.fs.path.join(testing.allocator, &.{ root, name });
}

test "a turn reports absence, a directory and a file, and reads only when that changed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    var paths = try resolvePaths(testing.allocator, root, root);
    defer paths.deinit(testing.allocator);

    // Nothing there yet: no `.metawork`, no project file, and nothing created.
    var nothing = try prepare(testing.io, testing.allocator, paths, null);
    defer nothing.deinit();
    try testing.expectEqual(Observation.absent, nothing.changed.fingerprint.global.?);
    try testing.expectEqual(Observation.absent, nothing.changed.fingerprint.project.?);
    try testing.expect(!nothing.changed.hasDocuments());
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, ".metawork", .{}));
    var still = try prepare(testing.io, testing.allocator, paths, nothing.changed.fingerprint);
    defer still.deinit();
    try testing.expect(still == .unchanged);

    try tmp.dir.createDirPath(testing.io, ".metawork" ++ std.fs.path.sep_str ++ "AGENTS.md");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "AGENTS.md", .data = "Project rules." });
    var first = try prepare(testing.io, testing.allocator, paths, nothing.changed.fingerprint);
    defer first.deinit();
    const candidate = &first.changed;
    try testing.expectEqual(Observation{ .failed = .not_regular_file }, candidate.fingerprint.global.?);
    try testing.expectEqual(@as(u64, "Project rules.".len), candidate.fingerprint.project.?.file.size);
    try testing.expectEqual(Unreadable.not_regular_file, candidate.global.?.unreadable);
    try testing.expectEqualStrings("Project rules.", candidate.project.?.document.text);
    try testing.expectEqualStrings(paths.project.?.path, candidate.project.?.document.path);
    const documents = candidate.instructions();
    try testing.expect(documents.global == null);
    try testing.expectEqualStrings("Project rules.", documents.project.?.text);
    // Core taking the project file, and Core being unreachable.
    const used = candidate.use(.{ .project = true });
    try testing.expectEqual(State.unreadable, used.global.state);
    try testing.expectEqual(Unreadable.not_regular_file, used.global.reason.?);
    try testing.expectEqual(State.applied, used.project.?.state);
    const failed = candidate.use(null);
    try testing.expectEqual(State.update_failed, failed.global.state);
    try testing.expectEqual(State.update_failed, failed.project.?.state);
    try testing.expectEqual(State.rejected, candidate.use(.{}).project.?.state);

    // Finding the same files again reads nothing; a change of size is read.
    var again = try prepare(testing.io, testing.allocator, paths, candidate.fingerprint);
    defer again.deinit();
    try testing.expect(again == .unchanged);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "AGENTS.md", .data = "Project rules, revised." });
    var revised = try prepare(testing.io, testing.allocator, paths, candidate.fingerprint);
    defer revised.deinit();
    try testing.expectEqualStrings("Project rules, revised.", revised.changed.project.?.document.text);
}

fn readNamed(tmp: std.testing.TmpDir, name: []const u8) !Outcome {
    const path = try tmpPath(tmp, name);
    defer testing.allocator.free(path);
    const opened = try handle.openRegular(testing.io, path);
    defer opened.file.close(testing.io);
    return read(testing.io, testing.allocator, opened.file, path, opened.stat.size);
}

test "a read keeps the limit, reports truncation and rejects non-text" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const large = try testing.allocator.alloc(u8, max_text_bytes + 100);
    defer testing.allocator.free(large);
    @memset(large, 'z');
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "large.md", .data = large });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "binary.md", .data = "\x89PNG\x00\x01" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "blank.md", .data = "\n\n" });
    const truncated = try readNamed(tmp, "large.md");
    defer switch (truncated) {
        .document => |document| {
            testing.allocator.free(document.path);
            testing.allocator.free(document.text);
        },
        else => {},
    };
    try testing.expectEqual(max_text_bytes, truncated.document.text.len);
    try testing.expect(truncated.document.truncated);
    try testing.expectEqual(Outcome{ .unreadable = .not_utf8 }, try readNamed(tmp, "binary.md"));
    try testing.expectEqual(Outcome.empty, try readNamed(tmp, "blank.md"));
    const missing_path = try tmpPath(tmp, "missing.md");
    defer testing.allocator.free(missing_path);
    var missing = try open(testing.io, testing.allocator, missing_path, null);
    defer missing.close(testing.io);
    try testing.expectEqual(Observation.absent, missing.observation);
}

test "a file that could not be read is read again once it can be, at the same size and time" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    var paths = try resolvePaths(testing.allocator, root, null);
    defer paths.deinit(testing.allocator);
    const sub_path = ".metawork" ++ std.fs.path.sep_str ++ "AGENTS.md";
    try tmp.dir.createDirPath(testing.io, ".metawork");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = sub_path, .data = "Be brief." });
    const before = try tmp.dir.statFile(testing.io, sub_path, .{});

    var refused = refused: {
        if (builtin.os.tag == .windows) {
            // Another handle's lock lets the file open but refuses the read:
            // the failure comes after the size and time were found.
            const lock = try tmp.dir.openFile(testing.io, sub_path, .{ .lock = .exclusive });
            defer lock.close(testing.io);
            break :refused try prepare(testing.io, testing.allocator, paths, null);
        }
        // Without read permission the open itself is refused.
        try tmp.dir.setFilePermissions(testing.io, sub_path, .fromMode(0), .{});
        defer tmp.dir.setFilePermissions(testing.io, sub_path, .fromMode(0o600), .{}) catch {};
        break :refused try prepare(testing.io, testing.allocator, paths, null);
    };
    defer refused.deinit();
    // A process that may read anything proves nothing here.
    if (refused.changed.global.? != .unreadable) return error.SkipZigTest;
    try testing.expect(refused.changed.fingerprint.global.? == .failed);
    try testing.expectEqual(State.unreadable, refused.changed.use(.{}).global.state);

    // Nothing about the file changed, and the next turn still reads it.
    const after = try tmp.dir.statFile(testing.io, sub_path, .{});
    try testing.expectEqual(before.size, after.size);
    try testing.expectEqual(before.mtime.nanoseconds, after.mtime.nanoseconds);
    var recovered = try prepare(testing.io, testing.allocator, paths, refused.changed.fingerprint);
    defer recovered.deinit();
    try testing.expectEqualStrings("Be brief.", recovered.changed.global.?.document.text);
    try testing.expectEqual(
        Observation{ .file = .{ .size = after.size, .mtime_ns = after.mtime.nanoseconds } },
        recovered.changed.fingerprint.global.?,
    );
}

test "a path the Agent would refuse is reported and costs only its own source" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "AGENTS.md", .data = "Project rules." });
    // A home whose name holds a line break cannot be a source line.
    const home = try std.fs.path.join(testing.allocator, &.{ root, "line\nbreak" });
    defer testing.allocator.free(home);
    var paths = try resolvePaths(testing.allocator, home, root);
    defer paths.deinit(testing.allocator);
    var prepared = try prepare(testing.io, testing.allocator, paths, null);
    defer prepared.deinit();
    try testing.expectEqual(Observation{ .failed = .invalid_path }, prepared.changed.fingerprint.global.?);
    try testing.expectEqual(Unreadable.invalid_path, prepared.changed.global.?.unreadable);
    try testing.expectEqualStrings("Project rules.", prepared.changed.project.?.document.text);
    try agent.validateInstructions(prepared.changed.instructions());
}

test "a project file linked outside its working directory is not read" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "workspace");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "secret.txt", .data = "outside" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "workspace" ++ std.fs.path.sep_str ++ "CLAUDE.md", .data = "inside" });
    const workspace = try tmpPath(tmp, "workspace");
    defer testing.allocator.free(workspace);
    const secret = try tmpPath(tmp, "secret.txt");
    defer testing.allocator.free(secret);
    var workspace_dir = try tmp.dir.openDir(testing.io, "workspace", .{});
    defer workspace_dir.close(testing.io);
    // Creating a link needs a privilege some Windows accounts lack; without
    // one there is nothing to observe, so that platform proves nothing here.
    workspace_dir.symLink(testing.io, secret, "AGENTS.md", .{}) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    var paths = try resolvePaths(testing.allocator, null, workspace);
    defer paths.deinit(testing.allocator);
    var outside = try open(testing.io, testing.allocator, paths.project.?.path, paths.project.?.root);
    defer outside.close(testing.io);
    try testing.expectEqual(Observation{ .failed = .outside_workspace }, outside.observation);
    try testing.expect(outside.file == null);
    // A link that stays inside, the common AGENTS.md -> CLAUDE.md, is read.
    try workspace_dir.deleteFile(testing.io, "AGENTS.md");
    try workspace_dir.symLink(testing.io, "CLAUDE.md", "AGENTS.md", .{});
    var prepared = try prepare(testing.io, testing.allocator, paths, null);
    defer prepared.deinit();
    try testing.expectEqual(@as(u64, "inside".len), prepared.changed.fingerprint.project.?.file.size);
    try testing.expectEqualStrings("inside", prepared.changed.project.?.document.text);
}
