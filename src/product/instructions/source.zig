//! The user's own instruction files: where they are, how each is observed and
//! read before a Run, and what a Run reports it carried.
//!
//! Two sources. The global file is `<home>/.metawork/AGENTS.md`; the project
//! file is `AGENTS.md` at the root of the Task's actual working directory, and
//! only a manual, explicitly trusted Workspace has one. Nothing searches
//! upward or into subdirectories, and the Task's project membership plays no
//! part, as for directory Skills.
//!
//! Observing a file costs one stat; its text is read only when what was
//! observed differs from what the Session already carries. A file that cannot
//! be read is reported and left out: it never stops a Run.
const std = @import("std");
const agent = @import("metawork_agent_contract");

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
    io_error,
};

/// One file as a turn's start found it, without reading it.
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

/// What a turn's start does: observe both files and, when that differs from
/// what the Session carries, read them.
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
/// working directory when it admits a project file.
pub fn resolvePaths(allocator: std.mem.Allocator, home: ?[]const u8, project_root: ?[]const u8) std.mem.Allocator.Error!Paths {
    const global = if (home) |root| try joinBounded(allocator, &.{ root, global_directory, file_name }) else null;
    errdefer if (global) |path| allocator.free(path);
    const project_path = if (project_root) |root| try joinBounded(allocator, &.{ root, file_name }) else null;
    return .{
        .global = global,
        .project = if (project_path) |path| .{ .path = path, .root = project_root.? } else null,
    };
}

/// A path longer than the Agent accepts stays out rather than being cut: it
/// would name some other file.
fn joinBounded(allocator: std.mem.Allocator, parts: []const []const u8) std.mem.Allocator.Error!?[]u8 {
    const path = try std.fs.path.join(allocator, parts);
    if (path.len > max_path_bytes or !std.unicode.utf8ValidateSlice(path)) {
        allocator.free(path);
        return null;
    }
    return path;
}

pub fn observeAll(io: std.Io, allocator: std.mem.Allocator, paths: Paths) Fingerprint {
    return .{
        .global = if (paths.global) |path| observe(io, allocator, path, null) else null,
        .project = if (paths.project) |project| observe(io, allocator, project.path, project.root) else null,
    };
}

/// One stat, plus a containment check for a project file. Never opens the
/// file: a FIFO would block the opener.
pub fn observe(io: std.Io, allocator: std.mem.Allocator, path: []const u8, root: ?[]const u8) Observation {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| return switch (err) {
        error.FileNotFound, error.NotDir => .absent,
        error.AccessDenied, error.PermissionDenied => .{ .failed = .access_denied },
        else => .{ .failed = .io_error },
    };
    if (stat.kind != .file) return .{ .failed = .not_regular_file };
    if (root) |workspace| {
        // A link may point anywhere; only a target inside the working
        // directory is the project's own file.
        const real = std.Io.Dir.realPathFileAbsoluteAlloc(io, path, allocator) catch |err| return switch (err) {
            error.FileNotFound => .absent,
            error.AccessDenied, error.PermissionDenied => .{ .failed = .access_denied },
            else => .{ .failed = .io_error },
        };
        defer allocator.free(real);
        if (!within(workspace, real)) return .{ .failed = .outside_workspace };
    }
    return .{ .file = .{ .size = stat.size, .mtime_ns = stat.mtime.nanoseconds } };
}

fn within(root: []const u8, path: []const u8) bool {
    if (path.len <= root.len or !std.mem.startsWith(u8, path, root)) return false;
    const trimmed = std.mem.trimEnd(u8, root, "/\\");
    if (trimmed.len != root.len) return true; // the root itself ends in a separator
    return std.fs.path.isSep(path[root.len]);
}

/// Reads every observed file. A source whose observation failed keeps that
/// failure; nothing here returns an error for a file the user wrote.
pub fn readAll(io: std.Io, allocator: std.mem.Allocator, paths: Paths, fingerprint: Fingerprint) std.mem.Allocator.Error!Candidate {
    var candidate: Candidate = .{ .allocator = allocator, .fingerprint = fingerprint, .global = null, .project = null };
    errdefer candidate.deinit();
    if (paths.global) |path| candidate.global = try readObserved(io, allocator, path, fingerprint.global.?);
    if (paths.project) |project| candidate.project = try readObserved(io, allocator, project.path, fingerprint.project.?);
    return candidate;
}

fn readObserved(io: std.Io, allocator: std.mem.Allocator, path: []const u8, observation: Observation) std.mem.Allocator.Error!Outcome {
    return switch (observation) {
        .absent => .absent,
        .failed => |reason| .{ .unreadable = reason },
        .file => |file| read(io, allocator, path, file.size),
    };
}

const bom = "\xef\xbb\xbf";

/// Reads at most the limit (plus a byte-order mark) and decides what the
/// file contributes. `size` is the observed size, which says whether the
/// file holds more than was kept.
pub fn read(io: std.Io, allocator: std.mem.Allocator, path: []const u8, size: u64) std.mem.Allocator.Error!Outcome {
    const file = std.Io.Dir.openFileAbsolute(io, path, .{ .allow_directory = false }) catch |err| return switch (err) {
        error.FileNotFound, error.NotDir => .absent,
        error.AccessDenied, error.PermissionDenied => .{ .unreadable = .access_denied },
        error.IsDir => .{ .unreadable = .not_regular_file },
        else => .{ .unreadable = .io_error },
    };
    defer file.close(io);
    const capacity: usize = @intCast(@min(size, max_text_bytes + bom.len));
    const buffer = try allocator.alloc(u8, capacity);
    defer allocator.free(buffer);
    const count = file.readPositionalAll(io, buffer, 0) catch return .{ .unreadable = .io_error };
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
    // A path the Agent would refuse is no path at all.
    const long = try testing.allocator.alloc(u8, max_path_bytes);
    defer testing.allocator.free(long);
    @memset(long, 'd');
    long[0] = sep[0];
    var too_long = try resolvePaths(testing.allocator, long, null);
    defer too_long.deinit(testing.allocator);
    try testing.expect(too_long.global == null);
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

test "observing reports absence, a directory and a file, and reading follows the observation" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    var paths = try resolvePaths(testing.allocator, root, root);
    defer paths.deinit(testing.allocator);

    // Nothing there yet: no `.metawork`, no project file, and nothing created.
    const nothing = observeAll(testing.io, testing.allocator, paths);
    try testing.expectEqual(Observation.absent, nothing.global.?);
    try testing.expectEqual(Observation.absent, nothing.project.?);
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, ".metawork", .{}));

    try tmp.dir.createDirPath(testing.io, ".metawork" ++ std.fs.path.sep_str ++ "AGENTS.md");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "AGENTS.md", .data = "Project rules." });
    const observed = observeAll(testing.io, testing.allocator, paths);
    try testing.expectEqual(Observation{ .failed = .not_regular_file }, observed.global.?);
    try testing.expectEqual(@as(u64, "Project rules.".len), observed.project.?.file.size);
    try testing.expect(observed.eql(observeAll(testing.io, testing.allocator, paths)));

    var candidate = try readAll(testing.io, testing.allocator, paths, observed);
    defer candidate.deinit();
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

    // A change of size is a different observation.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "AGENTS.md", .data = "Project rules, revised." });
    try testing.expect(!observed.eql(observeAll(testing.io, testing.allocator, paths)));
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
    const large_path = try tmpPath(tmp, "large.md");
    defer testing.allocator.free(large_path);
    const truncated = try read(testing.io, testing.allocator, large_path, large.len);
    defer switch (truncated) {
        .document => |document| {
            testing.allocator.free(document.path);
            testing.allocator.free(document.text);
        },
        else => {},
    };
    try testing.expectEqual(max_text_bytes, truncated.document.text.len);
    try testing.expect(truncated.document.truncated);
    const binary_path = try tmpPath(tmp, "binary.md");
    defer testing.allocator.free(binary_path);
    try testing.expectEqual(Outcome{ .unreadable = .not_utf8 }, try read(testing.io, testing.allocator, binary_path, 6));
    const blank_path = try tmpPath(tmp, "blank.md");
    defer testing.allocator.free(blank_path);
    try testing.expectEqual(Outcome.empty, try read(testing.io, testing.allocator, blank_path, 2));
    const missing_path = try tmpPath(tmp, "missing.md");
    defer testing.allocator.free(missing_path);
    try testing.expectEqual(Outcome.absent, try read(testing.io, testing.allocator, missing_path, 0));
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
    try testing.expectEqual(Observation{ .failed = .outside_workspace }, observeAll(testing.io, testing.allocator, paths).project.?);
    // A link that stays inside, the common AGENTS.md -> CLAUDE.md, is read.
    try workspace_dir.deleteFile(testing.io, "AGENTS.md");
    try workspace_dir.symLink(testing.io, "CLAUDE.md", "AGENTS.md", .{});
    try testing.expectEqual(@as(u64, "inside".len), observeAll(testing.io, testing.allocator, paths).project.?.file.size);
}
