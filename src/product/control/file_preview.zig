const std = @import("std");
const image_container = @import("image_container");

pub const max_in_flight: usize = 8;
pub const worker_count: usize = 2;
pub const max_image_source_bytes = 10 * 1024 * 1024;
pub const max_image_slots: usize = 2;
pub const max_image_held_bytes: usize = max_image_slots * max_image_source_bytes;
pub const max_image_pixels: u64 = 4096 * 4096;
pub const max_image_side: u32 = 8192;
pub const image_chunk_bytes: usize = 262143;
pub const ImageInfo = image_container.Info;
/// `attachment_draft` carries Host-prepared bytes for an unsent draft image;
/// it never opens a path. `attachment_original` reads one exact retained Task
/// image original, which the main thread replaces with a bounded preview.
pub const Source = enum { reference, workspace, directory, attachment_draft, attachment_original };
pub const max_directory_entries = 512;
pub const DirectoryEntry = struct { name: []const u8, kind: enum { file, directory } };

pub fn validWorkspacePath(path: []const u8, allow_root: bool) bool {
    if (path.len == 0) return allow_root;
    if (path.len > 4096 or !std.unicode.utf8ValidateSlice(path)) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    var depth: usize = 0;
    while (parts.next()) |part| {
        depth += 1;
        if (depth > 64 or part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
        for (part) |byte| if (byte < 0x20 or byte == 0x7f or byte == '\\' or byte == ':') return false;
    }
    return true;
}

fn openWorkspaceDirectory(io: std.Io, root: std.Io.Dir, path: []const u8) !std.Io.Dir {
    if (!validWorkspacePath(path, true)) return error.AccessDenied;
    if ((try root.stat(io)).kind != .directory) return error.AccessDenied;
    var current = try root.openDir(io, ".", .{ .iterate = true, .follow_symlinks = false });
    errdefer current.close(io);
    if ((try current.stat(io)).kind != .directory) return error.AccessDenied;
    if (path.len != 0) {
        var parts = std.mem.splitScalar(u8, path, '/');
        while (parts.next()) |part| {
            const next = try current.openDir(io, part, .{ .iterate = true, .follow_symlinks = false });
            const stat = next.stat(io) catch |err| {
                next.close(io);
                return err;
            };
            if (stat.kind != .directory) {
                next.close(io);
                return error.AccessDenied;
            }
            current.close(io);
            current = next;
        }
    }
    return current;
}

pub const State = enum {
    ready,
    busy,
    stale_security,
    missing,
    restricted,
    unsupported,
    image_limit,
    animated_image,
    changing,
    failed,
};

pub const Input = struct {
    source: Source = .reference,
    completion_id: u64,
    task_id: u64,
    run_id: u64,
    workspace_id: u64,
    workspace_epoch: u64,
    reference_id: []const u8,
    workspace_root: []const u8,
    relative_path: []const u8,
    max_bytes: usize,
    max_lines: usize,
    max_line_bytes: usize,
    attachment_id: u64 = 0,
    attachment_index: u32 = 0,
    /// Copied by `begin`; only `attachment_draft` may supply bytes.
    supplied: []const u8 = &.{},
};

pub const Completion = struct {
    source: Source = .reference,
    entries: []const DirectoryEntry = &.{},
    completion_id: u64,
    task_id: u64,
    run_id: u64,
    workspace_id: u64,
    workspace_epoch: u64,
    reference_id: []const u8,
    workspace_root: []const u8,
    relative_path: []const u8,
    state: State,
    content: []const u8,
    image_info: ?ImageInfo = null,
    truncated: bool,
    attachment_id: u64 = 0,
    attachment_index: u32 = 0,
};

pub const Taken = struct {
    job: *anyopaque,
    completion: Completion,
};

pub const Notifier = struct {
    context: ?*anyopaque = null,
    wake_fn: *const fn (?*anyopaque) bool,
};

pub const Error = error{
    ShuttingDown,
    Capacity,
} || std.mem.Allocator.Error;

pub const ExecutorJob = struct {
    identity: *anyopaque,
    context: *anyopaque,
    execute_fn: *const fn (*anyopaque) void,
    cancel_fn: *const fn (*anyopaque) void,
};

/// Narrow queue capability. File Preview owns its jobs and completion lane,
/// but never receives the concrete Product Control executor.
pub const Executor = struct {
    context: *anyopaque,
    enqueue_fn: *const fn (*anyopaque, ExecutorJob) error{ ExecutorShuttingDown, QueueFull }!void,

    fn enqueue(self: Executor, job: ExecutorJob) error{ ExecutorShuttingDown, QueueFull }!void {
        return self.enqueue_fn(self.context, job);
    }
};

fn isImage(bytes: []const u8) bool {
    return std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n") or std.mem.startsWith(u8, bytes, "\xff\xd8\xff") or
        (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP"));
}

const Job = struct {
    source: Source,
    entries: [max_directory_entries]DirectoryEntry = undefined,
    entry_count: usize = 0,
    lane: *Lane,
    completion_id: u64,
    task_id: u64,
    run_id: u64,
    workspace_id: u64,
    workspace_epoch: u64,
    reference_id: []u8,
    workspace_root: []u8,
    relative_path: []u8,
    max_bytes: usize,
    max_lines: usize,
    max_line_bytes: usize,
    attachment_id: u64 = 0,
    attachment_index: u32 = 0,
    image_info: ?ImageInfo = null,
    reserved_image_bytes: usize = 0,
    reserved_original: bool = false,
    cancelled: std.atomic.Value(bool) = .init(false),
    created_at: std.Io.Timestamp,
    state: State = .failed,
    buffer: []u8 = &.{},
    content: []const u8 = &.{},
    truncated: bool = false,

    fn execute(context: *anyopaque) void {
        const self: *Job = @ptrCast(@alignCast(context));
        self.readWithRetry();
        if (self.cancelled.load(.acquire)) {
            self.clearContent();
            self.state = .failed;
        }
        self.lane.publish(self);
    }

    fn cancel(context: *anyopaque) void {
        const self: *Job = @ptrCast(@alignCast(context));
        self.cancelled.store(true, .release);
        self.state = .failed;
        self.lane.publish(self);
    }

    fn readWithRetry(self: *Job) void {
        var attempt: u8 = 0;
        while (attempt < 2) : (attempt += 1) {
            const outcome = self.readOnce();
            switch (outcome) {
                .completed => return,
                .changed => {
                    self.clearContent();
                    if (attempt == 1) {
                        self.state = .changing;
                        return;
                    }
                },
            }
        }
        unreachable;
    }

    const ReadOutcome = enum { completed, changed };

    fn readOnce(self: *Job) ReadOutcome {
        if (self.cancelled.load(.acquire)) {
            self.state = .failed;
            return .completed;
        }
        if (self.source == .attachment_draft) return self.adoptSupplied();
        var root = std.Io.Dir.openDirAbsolute(self.lane.io, self.workspace_root, .{
            .access_sub_paths = true,
            .follow_symlinks = false,
        }) catch {
            self.state = .restricted;
            return .completed;
        };
        defer root.close(self.lane.io);
        if (self.source == .directory) return self.readDirectory(root);
        if (self.source == .attachment_original) return self.readRetainedOriginal(root);
        if (self.source == .workspace and !validWorkspacePath(self.relative_path, false)) {
            self.state = .restricted;
            return .completed;
        }
        var parent: ?std.Io.Dir = null;
        defer if (parent) |*dir| dir.close(self.lane.io);
        var file_path: []const u8 = self.relative_path;
        if (self.source == .workspace) {
            const split = std.mem.lastIndexOfScalar(u8, file_path, '/');
            parent = openWorkspaceDirectory(self.lane.io, root, if (split) |index| file_path[0..index] else "") catch {
                self.state = .restricted;
                return .completed;
            };
            if (split) |index| file_path = file_path[index + 1 ..];
        }
        var file = (parent orelse root).openFile(self.lane.io, file_path, .{
            .allow_directory = false,
            .follow_symlinks = false,
            .resolve_beneath = true,
        }) catch |err| {
            self.state = switch (err) {
                error.FileNotFound, error.NotDir => .missing,
                else => .restricted,
            };
            return .completed;
        };
        defer file.close(self.lane.io);
        if (@import("builtin").os.tag == .windows) file.flags.nonblocking = true;

        const before = file.stat(self.lane.io) catch {
            self.state = .failed;
            return .completed;
        };
        if (before.kind != .file) {
            self.state = .unsupported;
            return .completed;
        }
        var header: [30]u8 = undefined;
        const header_len: usize = @intCast(@min(before.size, header.len));
        const header_read = file.readPositionalAll(self.lane.io, header[0..header_len], 0) catch {
            self.state = .failed;
            return .completed;
        };
        if (header_read >= 21 and std.mem.eql(u8, header[0..4], "RIFF") and std.mem.eql(u8, header[8..16], "WEBPVP8X") and header[20] & 2 != 0) {
            self.state = .animated_image;
            return .completed;
        }
        const image = isImage(header[0..header_read]);
        if (image and before.size > max_image_source_bytes) {
            self.state = .image_limit;
            return .completed;
        }
        const wanted: usize = @intCast(if (image) before.size else @min(before.size, self.max_bytes));
        if (image) {
            if (!self.lane.reserveImage(wanted)) {
                self.state = .busy;
                return .completed;
            }
            self.reserved_image_bytes = wanted;
        }
        if (wanted == 0) {
            const after = file.stat(self.lane.io) catch {
                self.state = .failed;
                return .completed;
            };
            if (metadataChanged(before, after)) return .changed;
            self.state = .ready;
            self.content = &.{};
            self.truncated = before.size > self.max_bytes;
            return .completed;
        }
        const bytes = self.lane.allocator.alloc(u8, wanted) catch {
            self.state = .failed;
            return .completed;
        };
        self.buffer = bytes;
        self.content = bytes;
        var read: usize = 0;
        while (read < wanted) {
            if (self.cancelled.load(.acquire)) {
                self.clearContent();
                self.state = .failed;
                return .completed;
            }
            const amount = @min(wanted - read, 64 * 1024);
            const count = file.readPositionalAll(self.lane.io, bytes[read..][0..amount], read) catch {
                self.clearContent();
                self.state = .failed;
                return .completed;
            };
            read += count;
            if (count != amount) break;
        }
        const after = file.stat(self.lane.io) catch {
            self.clearContent();
            self.state = .failed;
            return .completed;
        };
        if (read != wanted or metadataChanged(before, after)) return .changed;

        if (image) {
            const info = image_container.inspect(bytes) catch {
                self.clearContent();
                self.state = .unsupported;
                return .completed;
            };
            if (info.animated) {
                self.clearContent();
                self.state = .animated_image;
                return .completed;
            }
            if (info.width > max_image_side or info.height > max_image_side or info.pixels() > max_image_pixels) {
                self.clearContent();
                self.state = .image_limit;
                return .completed;
            }
            self.image_info = info;
            self.state = .ready;
            return .completed;
        }
        var visible = trimIncompleteUtf8Tail(bytes);
        if (!std.unicode.utf8ValidateSlice(visible) or containsUnsafeControl(visible)) {
            self.clearContent();
            self.state = .unsupported;
            return .completed;
        }
        const cutoff = boundedCutoff(visible, self.max_lines, self.max_line_bytes);
        if (cutoff < visible.len) visible = trimIncompleteUtf8Tail(visible[0..cutoff]);
        self.content = bytes[0..visible.len];
        self.truncated = before.size > self.max_bytes or visible.len < wanted;
        self.state = .ready;
        return .completed;
    }

    /// The recorded size is exact: a retained original never changes, so any
    /// other file is not the one the Run accepted. One original is held at a
    /// time; its bytes stay in the Job until the main thread prepares them.
    fn readRetainedOriginal(self: *Job, root: std.Io.Dir) ReadOutcome {
        var file = root.openFile(self.lane.io, self.relative_path, .{
            .allow_directory = false,
            .follow_symlinks = false,
            .resolve_beneath = true,
        }) catch |err| {
            self.state = switch (err) {
                error.FileNotFound, error.NotDir => .missing,
                else => .restricted,
            };
            return .completed;
        };
        defer file.close(self.lane.io);
        if (@import("builtin").os.tag == .windows) file.flags.nonblocking = true;
        const before = file.stat(self.lane.io) catch {
            self.state = .failed;
            return .completed;
        };
        if (before.kind != .file or before.size != self.max_bytes) {
            self.state = .missing;
            return .completed;
        }
        if (!self.lane.reserveOriginal()) {
            self.state = .busy;
            return .completed;
        }
        self.reserved_original = true;
        const bytes = self.lane.allocator.alloc(u8, self.max_bytes) catch {
            self.clearContent();
            self.state = .failed;
            return .completed;
        };
        self.buffer = bytes;
        var read: usize = 0;
        while (read < bytes.len) {
            if (self.cancelled.load(.acquire)) {
                self.clearContent();
                self.state = .failed;
                return .completed;
            }
            const amount = @min(bytes.len - read, 64 * 1024);
            const count = file.readPositionalAll(self.lane.io, bytes[read..][0..amount], read) catch {
                self.clearContent();
                self.state = .failed;
                return .completed;
            };
            read += count;
            if (count != amount) break;
        }
        const after = file.stat(self.lane.io) catch {
            self.clearContent();
            self.state = .failed;
            return .completed;
        };
        if (read != bytes.len or metadataChanged(before, after)) return .changed;
        if (!isImage(bytes)) {
            self.clearContent();
            self.state = .unsupported;
            return .completed;
        }
        self.content = bytes;
        self.state = .ready;
        return .completed;
    }

    /// Supplied image bytes still pass the same container, animation, size and
    /// held-image admission rules as a file read.
    fn adoptSupplied(self: *Job) ReadOutcome {
        const bytes = self.buffer;
        if (bytes.len == 0 or !isImage(bytes)) {
            self.clearContent();
            self.state = .unsupported;
            return .completed;
        }
        if (bytes.len > max_image_source_bytes) {
            self.clearContent();
            self.state = .image_limit;
            return .completed;
        }
        if (!self.lane.reserveImage(bytes.len)) {
            self.clearContent();
            self.state = .busy;
            return .completed;
        }
        self.reserved_image_bytes = bytes.len;
        const info = image_container.inspect(bytes) catch {
            self.clearContent();
            self.state = .unsupported;
            return .completed;
        };
        if (info.animated) {
            self.clearContent();
            self.state = .animated_image;
            return .completed;
        }
        if (info.width > max_image_side or info.height > max_image_side or info.pixels() > max_image_pixels) {
            self.clearContent();
            self.state = .image_limit;
            return .completed;
        }
        self.content = bytes;
        self.image_info = info;
        self.state = .ready;
        return .completed;
    }

    fn readDirectory(self: *Job, root: std.Io.Dir) ReadOutcome {
        var directory = openWorkspaceDirectory(self.lane.io, root, self.relative_path) catch |err| {
            self.state = if (err == error.FileNotFound or err == error.NotDir) .missing else .restricted;
            return .completed;
        };
        defer directory.close(self.lane.io);
        var iterator = directory.iterate();
        var visited: usize = 0;
        var bytes: usize = 0;
        while (iterator.next(self.lane.io) catch {
            self.state = .failed;
            return .completed;
        }) |entry| {
            if (self.cancelled.load(.acquire)) {
                self.state = .failed;
                return .completed;
            }
            visited += 1;
            if (visited > 4096 or self.entry_count == max_directory_entries or bytes + entry.name.len > 64 * 1024) {
                self.truncated = true;
                break;
            }
            if ((entry.kind != .file and entry.kind != .directory) or !validWorkspacePath(entry.name, false) or std.mem.indexOfScalar(u8, entry.name, '/') != null) continue;
            const name = self.lane.allocator.dupe(u8, entry.name) catch {
                self.state = .failed;
                return .completed;
            };
            self.entries[self.entry_count] = .{ .name = name, .kind = if (entry.kind == .directory) .directory else .file };
            self.entry_count += 1;
            bytes += name.len;
        }
        self.state = .ready;
        return .completed;
    }

    fn clearContent(self: *Job) void {
        for (self.entries[0..self.entry_count]) |entry| {
            const name: []u8 = @constCast(entry.name);
            std.crypto.secureZero(u8, name);
            self.lane.allocator.free(name);
        }
        self.entry_count = 0;
        if (self.buffer.len != 0) {
            std.crypto.secureZero(u8, self.buffer);
            self.lane.allocator.free(self.buffer);
        }
        self.buffer = &.{};
        self.content = &.{};
        self.truncated = false;
        self.image_info = null;
        if (self.reserved_image_bytes != 0) self.lane.releaseImage(self.reserved_image_bytes);
        self.reserved_image_bytes = 0;
        if (self.reserved_original) self.lane.releaseOriginal();
        self.reserved_original = false;
    }

    fn deinit(self: *Job) void {
        self.clearContent();
        std.crypto.secureZero(u8, self.relative_path);
        std.crypto.secureZero(u8, self.workspace_root);
        std.crypto.secureZero(u8, self.reference_id);
        self.lane.allocator.free(self.relative_path);
        self.lane.allocator.free(self.workspace_root);
        self.lane.allocator.free(self.reference_id);
        self.lane.allocator.destroy(self);
    }
};

pub const Lane = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    notifier: Notifier,
    executor: Executor,
    mutex: std.Io.Mutex = .init,
    completions: [max_in_flight]?*Job = @splat(null),
    completion_head: usize = 0,
    completion_tail: usize = 0,
    completion_count: usize = 0,
    active_count: usize = 0,
    accepting: bool = true,
    jobs: [max_in_flight]?*Job = @splat(null),
    image_count: usize = 0,
    image_bytes: usize = 0,
    original_held: bool = false,

    pub fn create(
        io: std.Io,
        allocator: std.mem.Allocator,
        notifier: Notifier,
        executor: Executor,
    ) std.mem.Allocator.Error!*Lane {
        const self = try allocator.create(Lane);
        errdefer allocator.destroy(self);
        self.* = .{
            .io = io,
            .allocator = allocator,
            .notifier = notifier,
            .executor = executor,
        };
        return self;
    }

    pub fn begin(self: *Lane, input: Input) Error!void {
        std.debug.assert((input.source == .attachment_draft) == (input.supplied.len != 0));
        self.lock();
        if (!self.accepting) {
            self.unlock();
            return error.ShuttingDown;
        }
        if (self.active_count == max_in_flight) {
            self.unlock();
            return error.Capacity;
        }
        self.active_count += 1;
        self.unlock();
        errdefer {
            self.lock();
            self.active_count -= 1;
            self.unlock();
        }

        const job = try self.allocator.create(Job);
        errdefer self.allocator.destroy(job);
        const reference_id = try self.allocator.dupe(u8, input.reference_id);
        errdefer self.allocator.free(reference_id);
        const workspace_root = try self.allocator.dupe(u8, input.workspace_root);
        errdefer self.allocator.free(workspace_root);
        const relative_path = try self.allocator.dupe(u8, input.relative_path);
        errdefer self.allocator.free(relative_path);
        const supplied = try self.allocator.dupe(u8, input.supplied);
        errdefer {
            std.crypto.secureZero(u8, supplied);
            self.allocator.free(supplied);
        }
        job.* = .{
            .source = input.source,
            .lane = self,
            .completion_id = input.completion_id,
            .created_at = .now(self.io, .awake),
            .task_id = input.task_id,
            .run_id = input.run_id,
            .workspace_id = input.workspace_id,
            .workspace_epoch = input.workspace_epoch,
            .reference_id = reference_id,
            .workspace_root = workspace_root,
            .relative_path = relative_path,
            .max_bytes = input.max_bytes,
            .max_lines = input.max_lines,
            .max_line_bytes = input.max_line_bytes,
            .attachment_id = input.attachment_id,
            .attachment_index = input.attachment_index,
            .buffer = supplied,
        };
        self.lock();
        const job_index = for (&self.jobs, 0..) |*slot, index| {
            if (slot.* == null) {
                slot.* = job;
                break index;
            }
        } else unreachable;
        self.unlock();
        errdefer {
            self.lock();
            self.jobs[job_index] = null;
            self.unlock();
        }
        self.executor.enqueue(.{
            .identity = job,
            .context = job,
            .execute_fn = Job.execute,
            .cancel_fn = Job.cancel,
        }) catch |err| switch (err) {
            error.ExecutorShuttingDown => return error.ShuttingDown,
            error.QueueFull => return error.Capacity,
        };
    }

    pub fn stopAdmission(self: *Lane) void {
        self.lock();
        self.accepting = false;
        for (self.jobs) |entry| if (entry) |job| job.cancelled.store(true, .release);
        self.unlock();
    }

    pub fn deinit(self: *Lane) void {
        std.debug.assert(!self.accepting);
        std.debug.assert(self.active_count == 0);
        std.debug.assert(self.completion_count == 0);
        std.debug.assert(self.image_count == 0 and self.image_bytes == 0 and !self.original_held);
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn take(self: *Lane) ?Taken {
        self.lock();
        if (self.completion_count == 0) {
            self.unlock();
            return null;
        }
        const job = self.completions[self.completion_head].?;
        self.completions[self.completion_head] = null;
        self.completion_head = (self.completion_head + 1) % self.completions.len;
        self.completion_count -= 1;
        self.unlock();
        return .{
            .job = job,
            .completion = .{
                .source = job.source,
                .entries = job.entries[0..job.entry_count],
                .completion_id = job.completion_id,
                .task_id = job.task_id,
                .run_id = job.run_id,
                .workspace_id = job.workspace_id,
                .workspace_epoch = job.workspace_epoch,
                .reference_id = job.reference_id,
                .workspace_root = job.workspace_root,
                .relative_path = job.relative_path,
                .state = job.state,
                .content = job.content,
                .image_info = job.image_info,
                .truncated = job.truncated,
                .attachment_id = job.attachment_id,
                .attachment_index = job.attachment_index,
            },
        };
    }

    pub fn release(self: *Lane, taken: Taken) void {
        const job: *Job = @ptrCast(@alignCast(taken.job));
        self.lock();
        for (&self.jobs) |*entry| if (entry.* == job) {
            entry.* = null;
            break;
        };
        std.debug.assert(self.active_count != 0);
        self.active_count -= 1;
        self.unlock();
        job.deinit();
    }

    pub fn hasActive(self: *Lane) bool {
        self.lock();
        defer self.unlock();
        return self.active_count != 0;
    }
    pub fn wasCancelled(_: *Lane, taken: Taken) bool {
        const job: *Job = @ptrCast(@alignCast(taken.job));
        return job.cancelled.load(.acquire);
    }
    pub fn expireRequests(self: *Lane) void {
        const timestamp: std.Io.Timestamp = .now(self.io, .awake);
        self.lock();
        defer self.unlock();
        for (self.jobs) |entry| if (entry) |job| {
            if (job.created_at.durationTo(timestamp).nanoseconds >= 30 * std.time.ns_per_s)
                job.cancelled.store(true, .release);
        };
    }
    pub fn cancelRequest(self: *Lane, completion_id: u64) bool {
        self.lock();
        defer self.unlock();
        for (self.jobs) |entry| if (entry) |job| {
            if (job.completion_id == completion_id) {
                job.cancelled.store(true, .release);
                return true;
            }
        };
        return false;
    }

    /// Main thread: swaps a ready retained original for its bounded preview,
    /// which then passes the ordinary held-image admission. Takes `prepared`.
    pub fn adoptPrepared(self: *Lane, taken: *Taken, prepared: []u8) State {
        _ = self;
        const job: *Job = @ptrCast(@alignCast(taken.job));
        std.debug.assert(job.source == .attachment_original and job.state == .ready);
        job.clearContent();
        job.buffer = prepared;
        _ = job.adoptSupplied();
        taken.completion.state = job.state;
        taken.completion.content = job.content;
        taken.completion.image_info = job.image_info;
        return job.state;
    }

    fn reserveOriginal(self: *Lane) bool {
        self.lock();
        defer self.unlock();
        if (!self.accepting or self.original_held) return false;
        self.original_held = true;
        return true;
    }
    fn releaseOriginal(self: *Lane) void {
        self.lock();
        defer self.unlock();
        std.debug.assert(self.original_held);
        self.original_held = false;
    }

    fn reserveImage(self: *Lane, bytes: usize) bool {
        self.lock();
        defer self.unlock();
        if (!self.accepting or self.image_count == max_image_slots or bytes > max_image_held_bytes - self.image_bytes) return false;
        self.image_count += 1;
        self.image_bytes += bytes;
        return true;
    }
    fn releaseImage(self: *Lane, bytes: usize) void {
        self.lock();
        defer self.unlock();
        std.debug.assert(self.image_count > 0 and self.image_bytes >= bytes);
        self.image_count -= 1;
        self.image_bytes -= bytes;
    }

    fn publish(self: *Lane, job: *Job) void {
        self.lock();
        std.debug.assert(self.completion_count < self.completions.len);
        self.completions[self.completion_tail] = job;
        self.completion_tail = (self.completion_tail + 1) % self.completions.len;
        self.completion_count += 1;
        self.unlock();
        _ = self.notifier.wake_fn(self.notifier.context);
    }

    fn lock(self: *Lane) void {
        self.mutex.lockUncancelable(self.io);
    }

    fn unlock(self: *Lane) void {
        self.mutex.unlock(self.io);
    }
};

fn metadataChanged(before: std.Io.File.Stat, after: std.Io.File.Stat) bool {
    return before.inode != after.inode or
        before.size != after.size or
        before.kind != after.kind or
        !std.meta.eql(before.mtime, after.mtime) or
        !std.meta.eql(before.ctime, after.ctime);
}

fn containsUnsafeControl(bytes: []const u8) bool {
    for (bytes) |byte| switch (byte) {
        0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => return true,
        else => {},
    };
    return false;
}

fn boundedCutoff(bytes: []const u8, max_lines: usize, max_line_bytes: usize) usize {
    var lines: usize = 1;
    var line_bytes: usize = 0;
    for (bytes, 0..) |byte, index| {
        if (byte == '\n') {
            lines += 1;
            line_bytes = 0;
            if (lines > max_lines) return index;
        } else {
            line_bytes += 1;
            if (line_bytes > max_line_bytes) return index;
        }
    }
    return bytes.len;
}

fn trimIncompleteUtf8Tail(bytes: []u8) []u8 {
    if (std.unicode.utf8ValidateSlice(bytes) or bytes.len == 0) return bytes;
    var suffix_start = bytes.len;
    var continuation_count: usize = 0;
    while (suffix_start > 0 and continuation_count < 3 and
        (bytes[suffix_start - 1] & 0xc0) == 0x80)
    {
        suffix_start -= 1;
        continuation_count += 1;
    }
    if (suffix_start == 0) return bytes;
    const lead_index = suffix_start - 1;
    const lead = bytes[lead_index];
    if (lead < 0xc2 or lead > 0xf4) return bytes;
    const sequence_len = std.unicode.utf8ByteSequenceLength(lead) catch return bytes;
    if (bytes.len - lead_index < sequence_len) return bytes[0..lead_index];
    return bytes;
}

test "file preview workspace paths reject traversal absolute paths controls and alternate streams" {
    inline for (.{ "../secret", "/secret", "a/../b", "a//b", "a/./b", "C:/secret", "a\\b", "file:stream", "a\x00b", "a\x7fb" }) |path| try std.testing.expect(!validWorkspacePath(path, false));
    try std.testing.expect(!validWorkspacePath("", false));
    try std.testing.expect(validWorkspacePath("", true));
    try std.testing.expect(validWorkspacePath("docs/中文.md", false));
}

test "file preview workspace directory reads children on demand and opens unreferenced files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "docs", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "docs/unreferenced.txt", .data = "workspace content" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const Harness = struct {
        fn wake(_: ?*anyopaque) bool {
            return true;
        }
        fn enqueue(_: *anyopaque, job: ExecutorJob) error{ ExecutorShuttingDown, QueueFull }!void {
            job.execute_fn(job.context);
        }
    };
    var context: u8 = 0;
    const lane = try Lane.create(std.testing.io, std.testing.allocator, .{ .wake_fn = Harness.wake }, .{ .context = &context, .enqueue_fn = Harness.enqueue });
    defer {
        lane.stopAdmission();
        lane.deinit();
    }
    var input: Input = .{ .source = .directory, .completion_id = 1, .task_id = 1, .run_id = 0, .workspace_id = 1, .workspace_epoch = 1, .reference_id = "", .workspace_root = root, .relative_path = "", .max_bytes = 1024, .max_lines = 20, .max_line_bytes = 1024 };
    try lane.begin(input);
    const listing = lane.take().?;
    try std.testing.expectEqual(State.ready, listing.completion.state);
    try std.testing.expectEqual(@as(usize, 1), listing.completion.entries.len);
    try std.testing.expectEqualStrings("docs", listing.completion.entries[0].name);
    try std.testing.expectEqual(.directory, listing.completion.entries[0].kind);
    lane.release(listing);
    input.source = .workspace;
    input.relative_path = "docs/unreferenced.txt";
    try lane.begin(input);
    const file = lane.take().?;
    try std.testing.expectEqual(State.ready, file.completion.state);
    try std.testing.expectEqualStrings("workspace content", file.completion.content);
    lane.release(file);
    input.source = .directory;
    input.relative_path = "../outside";
    try lane.begin(input);
    const denied = lane.take().?;
    try std.testing.expectEqual(State.restricted, denied.completion.state);
    lane.release(denied);
}

test "file preview lane classifies bounded text empty and unsafe files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "text.txt",
        .data = "hello world",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "unsafe.txt",
        .data = "bad\x01data",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "empty.txt",
        .data = "",
    });
    var root_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_storage);

    const Wake = struct {
        count: std.atomic.Value(usize) = .init(0),

        fn notify(context: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            _ = self.count.fetchAdd(1, .release);
            return true;
        }
    };
    var wake = Wake{};
    const TestExecutor = struct {
        fn enqueue(_: *anyopaque, job: ExecutorJob) error{ ExecutorShuttingDown, QueueFull }!void {
            job.execute_fn(job.context);
        }
    };
    var executor_context: u8 = 0;
    const lane = try Lane.create(std.testing.io, std.testing.allocator, .{
        .context = &wake,
        .wake_fn = Wake.notify,
    }, .{
        .context = &executor_context,
        .enqueue_fn = TestExecutor.enqueue,
    });
    defer {
        lane.stopAdmission();
        lane.deinit();
    }

    inline for (.{
        .{ @as(u64, 1), "text.txt", @as(usize, 5) },
        .{ @as(u64, 2), "unsafe.txt", @as(usize, 64) },
        .{ @as(u64, 3), "empty.txt", @as(usize, 64) },
    }) |entry| try lane.begin(.{
        .completion_id = entry[0],
        .task_id = 11,
        .run_id = 12,
        .workspace_id = 13,
        .workspace_epoch = 14,
        .reference_id = "ref",
        .workspace_root = root_storage[0..root_len],
        .relative_path = entry[1],
        .max_bytes = entry[2],
        .max_lines = 100,
        .max_line_bytes = 100,
    });

    try std.testing.expectEqual(@as(usize, 3), wake.count.load(.acquire));
    var seen: [3]bool = @splat(false);
    while (lane.take()) |taken| {
        defer lane.release(taken);
        switch (taken.completion.completion_id) {
            1 => {
                try std.testing.expectEqual(State.ready, taken.completion.state);
                try std.testing.expectEqualStrings("hello", taken.completion.content);
                try std.testing.expect(taken.completion.truncated);
                seen[0] = true;
            },
            2 => {
                try std.testing.expectEqual(State.unsupported, taken.completion.state);
                try std.testing.expectEqualStrings("", taken.completion.content);
                try std.testing.expect(!taken.completion.truncated);
                seen[1] = true;
            },
            3 => {
                try std.testing.expectEqual(State.ready, taken.completion.state);
                try std.testing.expectEqualStrings("", taken.completion.content);
                try std.testing.expect(!taken.completion.truncated);
                seen[2] = true;
            },
            else => return error.TestUnexpectedResult,
        }
    }
    try std.testing.expectEqual([3]bool{ true, true, true }, seen);
}

test "file preview text bounds stop before an over-limit line or codepoint" {
    try std.testing.expectEqual(@as(usize, 3), boundedCutoff("abcde", 10, 3));
    try std.testing.expectEqual(@as(usize, 3), boundedCutoff("a\nb\nc", 2, 10));
    var incomplete = [_]u8{ 'a', 0xe4, 0xbd };
    try std.testing.expectEqualStrings("a", trimIncompleteUtf8Tail(&incomplete));
    try std.testing.expect(!containsUnsafeControl("a\tb\nc\r"));
    try std.testing.expect(containsUnsafeControl("a\x00b"));
}

test "file preview image source is bounded and malformed containers are not ready" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "small.jpg", .data = "\xff\xd8\xffbinary-image" });
    const large = try tmp.dir.createFile(std.testing.io, "large.png", .{});
    try large.writeStreamingAll(std.testing.io, "\x89PNG\r\n\x1a\n");
    try large.setLength(std.testing.io, max_image_source_bytes + 1);
    large.close(std.testing.io);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "animated.webp", .data = "RIFF0000WEBPVP8X0000\x02rest" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const TestExecutor = struct {
        fn enqueue(_: *anyopaque, job: ExecutorJob) error{ ExecutorShuttingDown, QueueFull }!void {
            job.execute_fn(job.context);
        }
        fn wake(_: ?*anyopaque) bool {
            return true;
        }
    };
    var context: u8 = 0;
    const lane = try Lane.create(std.testing.io, std.testing.allocator, .{ .wake_fn = TestExecutor.wake }, .{ .context = &context, .enqueue_fn = TestExecutor.enqueue });
    defer {
        lane.stopAdmission();
        lane.deinit();
    }
    for ([_][]const u8{ "small.jpg", "large.png", "animated.webp" }, 0..) |path, index| {
        try lane.begin(.{ .completion_id = index + 1, .task_id = 1, .run_id = 1, .workspace_id = 1, .workspace_epoch = 1, .reference_id = "ref", .workspace_root = root, .relative_path = path, .max_bytes = 2, .max_lines = 10, .max_line_bytes = 10 });
        const taken = lane.take().?;
        defer lane.release(taken);
        if (index == 0) {
            try std.testing.expectEqual(State.unsupported, taken.completion.state);
            try std.testing.expect(taken.completion.image_info == null);
            try std.testing.expectEqual(@as(usize, 0), taken.completion.content.len);
            try std.testing.expect(!taken.completion.truncated);
        } else {
            try std.testing.expectEqual(if (index == 1) State.image_limit else State.animated_image, taken.completion.state);
            try std.testing.expectEqual(@as(usize, 0), taken.completion.content.len);
        }
    }
}

test "two retained image buffers do not take text capacity and busy retains no bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const jpeg = "\xff\xd8\xff\xc0\x00\x0b\x08\x00\x02\x00\x03\x01\x01\x11\x00" ++
        "\xff\xda\x00\x08\x01\x01\x00\x00\x3f\x00\x01\xff\xd9tail";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "image.jpg", .data = jpeg });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "text.txt", .data = "text remains available" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const Sync = struct {
        fn enqueue(_: *anyopaque, job: ExecutorJob) error{ ExecutorShuttingDown, QueueFull }!void {
            job.execute_fn(job.context);
        }
        fn wake(_: ?*anyopaque) bool {
            return true;
        }
    };
    var context: u8 = 0;
    const lane = try Lane.create(std.testing.io, std.testing.allocator, .{ .wake_fn = Sync.wake }, .{ .context = &context, .enqueue_fn = Sync.enqueue });
    defer {
        lane.stopAdmission();
        lane.deinit();
    }
    var held: [2]Taken = undefined;
    for (0..4) |index| {
        try lane.begin(.{ .completion_id = index + 1, .task_id = 1, .run_id = 1, .workspace_id = 1, .workspace_epoch = 1, .reference_id = "ref", .workspace_root = root, .relative_path = if (index == 3) "text.txt" else "image.jpg", .max_bytes = 64, .max_lines = 10, .max_line_bytes = 64 });
        const taken = lane.take().?;
        if (index < 2) {
            try std.testing.expectEqual(State.ready, taken.completion.state);
            try std.testing.expect(taken.completion.image_info != null);
            try std.testing.expectEqualSlices(u8, jpeg, taken.completion.content);
            held[index] = taken;
        } else {
            try std.testing.expectEqual(if (index == 2) State.busy else State.ready, taken.completion.state);
            try std.testing.expectEqualStrings(if (index == 2) "" else "text remains available", taken.completion.content);
            lane.release(taken);
        }
    }
    try std.testing.expectEqual(@as(usize, 2), lane.image_count);
    try std.testing.expectEqual(@as(usize, jpeg.len * 2), lane.image_bytes);
    for (held) |taken| lane.release(taken);
    try std.testing.expectEqual(@as(usize, 0), lane.image_count);
    try std.testing.expectEqual(@as(usize, 0), lane.image_bytes);
}

test "draft attachment previews adopt an owned copy under the shared image admission" {
    const Sync = struct {
        fn enqueue(_: *anyopaque, job: ExecutorJob) error{ ExecutorShuttingDown, QueueFull }!void {
            job.execute_fn(job.context);
        }
        fn wake(_: ?*anyopaque) bool {
            return true;
        }
    };
    var context: u8 = 0;
    const lane = try Lane.create(std.testing.io, std.testing.allocator, .{ .wake_fn = Sync.wake }, .{ .context = &context, .enqueue_fn = Sync.enqueue });
    defer {
        lane.stopAdmission();
        lane.deinit();
    }
    const jpeg = "\xff\xd8\xff\xc0\x00\x0b\x08\x00\x02\x00\x03\x01\x01\x11\x00" ++
        "\xff\xda\x00\x08\x01\x01\x00\x00\x3f\x00\x01\xff\xd9";
    var source = jpeg.*;
    const draft: Input = .{ .source = .attachment_draft, .completion_id = 1, .task_id = 0, .run_id = 0, .workspace_id = 0, .workspace_epoch = 0, .reference_id = "", .workspace_root = "", .relative_path = "", .max_bytes = 0, .max_lines = 0, .max_line_bytes = 0, .attachment_id = 9, .supplied = &source };
    var held: [2]Taken = undefined;
    for (0..3) |index| {
        var input = draft;
        input.completion_id = index + 1;
        try lane.begin(input);
        // The caller's borrowed bytes may change once begin has returned.
        @memset(&source, 0);
        defer source = jpeg.*;
        const taken = lane.take().?;
        try std.testing.expectEqual(@as(u64, 9), taken.completion.attachment_id);
        if (index < 2) {
            try std.testing.expectEqual(State.ready, taken.completion.state);
            try std.testing.expectEqualSlices(u8, jpeg, taken.completion.content);
            try std.testing.expectEqual(@as(u32, 3), taken.completion.image_info.?.width);
            held[index] = taken;
        } else {
            try std.testing.expectEqual(State.busy, taken.completion.state);
            try std.testing.expectEqual(@as(usize, 0), taken.completion.content.len);
            lane.release(taken);
        }
    }
    for (held) |taken| lane.release(taken);
    try std.testing.expectEqual(@as(usize, 0), lane.image_count);
    var text = "not an image".*;
    var invalid = draft;
    invalid.supplied = &text;
    try lane.begin(invalid);
    const rejected = lane.take().?;
    defer lane.release(rejected);
    try std.testing.expectEqual(State.unsupported, rejected.completion.state);
    try std.testing.expectEqual(@as(usize, 0), lane.image_count);
}

test "cancelled queued reads publish once without opening or reserving an image" {
    const Deferred = struct {
        job: ?ExecutorJob = null,
        fn enqueue(context: *anyopaque, job: ExecutorJob) error{ ExecutorShuttingDown, QueueFull }!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.job = job;
        }
        fn wake(_: ?*anyopaque) bool {
            return true;
        }
    };
    var context: Deferred = .{};
    const lane = try Lane.create(std.testing.io, std.testing.allocator, .{ .wake_fn = Deferred.wake }, .{ .context = &context, .enqueue_fn = Deferred.enqueue });
    defer {
        lane.stopAdmission();
        lane.deinit();
    }
    try lane.begin(.{ .completion_id = 17, .task_id = 1, .run_id = 1, .workspace_id = 1, .workspace_epoch = 1, .reference_id = "ref", .workspace_root = "not-a-real-root", .relative_path = "not-opened.jpg", .max_bytes = 64, .max_lines = 10, .max_line_bytes = 64 });
    try std.testing.expect(lane.cancelRequest(17));
    const job = context.job.?;
    job.execute_fn(job.context);
    const taken = lane.take().?;
    try std.testing.expectEqual(State.failed, taken.completion.state);
    try std.testing.expectEqual(@as(usize, 0), taken.completion.content.len);
    lane.release(taken);
    try std.testing.expect(!lane.hasActive());
    try std.testing.expect(lane.take() == null);
}
