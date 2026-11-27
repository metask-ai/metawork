const std = @import("std");
const builtin = @import("builtin");
const image_container = @import("image_container");
const file_target = @import("product_control_file_target");

pub const max_in_flight: usize = 8;
pub const worker_count: usize = 2;
pub const max_image_source_bytes = 10 * 1024 * 1024;
pub const max_image_slots: usize = 2;
pub const max_image_held_bytes: usize = max_image_slots * max_image_source_bytes;
pub const max_image_pixels: u64 = 4096 * 4096;
pub const max_image_side: u32 = 8192;
pub const min_video_bytes: u64 = 16;
pub const max_video_bytes: u64 = 64 * 1024 * 1024;
pub const media_chunk_bytes: usize = 262143;
pub const max_media_slots: usize = max_image_slots + 1;
pub const ImageInfo = image_container.Info;
/// What a read is of. A Workspace file carries the identity the Renderer
/// addressed it with, which the owner resolves again before it delivers
/// anything. `draft_attachment` and `task_attachment` are both Product-owned
/// store reads: no Workspace is involved, so their authority is the
/// attachment's own identity, not a Workspace id/epoch/root. They differ in
/// which identity that is -- a staged draft, or a message a Task accepted.
pub const Subject = union(enum) {
    file: file_target.Target,
    directory: file_target.Target.Workspace,
    draft_attachment: u64,
    task_attachment: u64,

    /// Whether this reads the Product-owned attachment store rather than a
    /// Workspace, which decides both path handling and that the bytes must
    /// still be the image staging classified.
    fn storeOwned(self: Subject) bool {
        return self == .draft_attachment or self == .task_attachment;
    }

    /// Only an identity the reply plays in place is read as a video. A path
    /// in the file tree or a plain link shows one the way it shows any file it
    /// cannot show.
    fn video(self: Subject, location: file_target.Location) VideoRule {
        return switch (self) {
            .file => |target| if (location.generated_video) .generated else if (target == .output) .recognized else .none,
            .directory, .draft_attachment, .task_attachment => .none,
        };
    }

    fn clone(self: Subject, allocator: std.mem.Allocator) std.mem.Allocator.Error!Subject {
        return switch (self) {
            .file => |target| .{ .file = try target.clone(allocator) },
            .directory => |value| .{ .directory = try value.clone(allocator) },
            .draft_attachment, .task_attachment => self,
        };
    }

    fn free(self: Subject, allocator: std.mem.Allocator) void {
        switch (self) {
            .file => |target| target.free(allocator),
            .directory => |value| value.free(allocator),
            .draft_attachment, .task_attachment => {},
        }
    }
};
pub const max_directory_entries = 512;
pub const DirectoryEntry = struct { name: []const u8, kind: enum { file, directory } };

pub fn validWorkspacePath(path: []const u8, allow_root: bool) bool {
    if (path.len == 0) return allow_root;
    if (path.len > file_target.max_path_bytes or !std.unicode.utf8ValidateSlice(path)) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    var depth: usize = 0;
    while (parts.next()) |part| {
        depth += 1;
        if (depth > 64 or part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
        for (part) |byte| if (byte < 0x20 or byte == 0x7f or byte == '\\' or byte == ':') return false;
    }
    return true;
}

pub fn openWorkspaceDirectory(io: std.Io, root: std.Io.Dir, path: []const u8) !std.Io.Dir {
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

/// Delivering a preview and describing the same file are one read and one
/// judgement. Describing keeps what was found and none of the bytes.
pub const Mode = enum { deliver, describe };

/// What a file is, by the content it holds right now. `previewable` is whether
/// a Workspace preview of it would show anything; an image always does, and a
/// video is played where it is.
pub const Description = struct {
    size_bytes: u64,
    kind: union(enum) {
        image: struct { width: u32, height: u32 },
        video,
        file: struct { previewable: bool },
    },
};

pub const Input = struct {
    mode: Mode = .deliver,
    subject: Subject,
    /// Frozen at admission. A store-owned subject has no Workspace id or epoch.
    location: file_target.Location,
    completion_id: u64,
    max_bytes: usize,
    max_lines: usize,
    max_line_bytes: usize,
};

pub const Completion = struct {
    mode: Mode = .deliver,
    subject: Subject,
    location: file_target.Location,
    /// Of a `describe` whose state is ready, and only of that.
    description: ?Description = null,
    /// The content is an MP4 to be played, not an image or text.
    video: bool = false,
    entries: []const DirectoryEntry = &.{},
    completion_id: u64,
    state: State,
    content: []const u8,
    image_info: ?ImageInfo = null,
    truncated: bool,
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

/// How an MP4 is recognized for a subject. `generated` is the Host's own
/// record that it wrote one; it is the only subject that has no other reading.
const VideoRule = enum { none, recognized, generated };

/// The major brands of an MP4 a video element plays. HEIC, AVIF, QuickTime and
/// M4A open with the same box, so the box alone says nothing.
const video_brands = [_]*const [4]u8{ "isom", "iso2", "iso4", "iso5", "iso6", "mp41", "mp42", "avc1", "M4V ", "dash", "MSNV" };

const HeaderKind = enum { image, image_limit, animated_image, video, unsupported, text };

/// The one decision about which way a file is read, from its first bytes and
/// its size. What those bytes promise is checked when the whole file is read.
fn classifyHeader(header: []const u8, size: u64, video: VideoRule) HeaderKind {
    const boxed = header.len >= min_video_bytes and size <= max_video_bytes and std.mem.eql(u8, header[4..8], "ftyp");
    switch (video) {
        .none => {},
        .generated => return if (boxed) .video else .unsupported,
        .recognized => if (boxed) for (video_brands) |brand| {
            if (std.mem.eql(u8, header[8..12], brand)) return .video;
        },
    }
    if (header.len >= 21 and std.mem.eql(u8, header[0..4], "RIFF") and std.mem.eql(u8, header[8..16], "WEBPVP8X") and header[20] & 2 != 0)
        return .animated_image;
    if (isImage(header)) return if (size > max_image_source_bytes) .image_limit else .image;
    return .text;
}

fn isImage(bytes: []const u8) bool {
    return std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n") or std.mem.startsWith(u8, bytes, "\xff\xd8\xff") or
        (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP"));
}

const Job = struct {
    mode: Mode,
    subject: Subject,
    location: file_target.Location,
    entries: [max_directory_entries]DirectoryEntry = undefined,
    entry_count: usize = 0,
    lane: *Lane,
    completion_id: u64,
    max_bytes: usize,
    max_lines: usize,
    max_line_bytes: usize,
    image_info: ?ImageInfo = null,
    reserved_image_bytes: usize = 0,
    reserved_video: bool = false,
    video: bool = false,
    size_bytes: u64 = 0,
    description: ?Description = null,
    cancelled: std.atomic.Value(bool) = .init(false),
    created_at: std.Io.Timestamp,
    state: State = .failed,
    buffer: []u8 = &.{},
    content: []const u8 = &.{},
    truncated: bool = false,

    fn execute(context: *anyopaque) void {
        const self: *Job = @ptrCast(@alignCast(context));
        self.readWithRetry();
        if (self.mode == .describe) self.describe();
        if (self.cancelled.load(.acquire)) {
            self.clearContent();
            self.description = null;
            self.state = .failed;
        }
        self.lane.publish(self);
    }

    /// Turns the outcome of the read every preview makes into what was found,
    /// and gives up its bytes and its slot on the worker.
    fn describe(self: *Job) void {
        self.description = switch (self.state) {
            .ready => .{ .size_bytes = self.size_bytes, .kind = if (self.video)
                .video
            else if (self.image_info) |info|
                .{ .image = .{ .width = info.width, .height = info.height } }
            else
                .{ .file = .{ .previewable = true } } },
            .unsupported, .image_limit, .animated_image => .{ .size_bytes = self.size_bytes, .kind = .{ .file = .{ .previewable = false } } },
            .busy, .stale_security, .missing, .restricted, .changing, .failed => null,
        };
        if (self.description != null) self.state = .ready;
        self.clearContent();
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
        var root = std.Io.Dir.openDirAbsolute(self.lane.io, self.location.root, .{
            .access_sub_paths = true,
            .follow_symlinks = false,
        }) catch {
            self.state = .restricted;
            return .completed;
        };
        defer root.close(self.lane.io);
        if (self.subject == .directory) return self.readDirectory(root);
        // Every file is reached one component at a time, so no link in the
        // middle leads elsewhere.
        const path = self.location.relative;
        if (!validWorkspacePath(path, false)) {
            self.state = .restricted;
            return .completed;
        }
        const split = std.mem.lastIndexOfScalar(u8, path, '/');
        var parent = openWorkspaceDirectory(self.lane.io, root, if (split) |index| path[0..index] else "") catch |err| {
            self.state = openFailure(err);
            return .completed;
        };
        defer parent.close(self.lane.io);
        const name = path[if (split) |index| index + 1 else 0..];
        // Opening a pipe waits for whoever writes to it and would hold this
        // worker. No Windows directory holds one.
        if (builtin.os.tag != .windows) {
            const named = parent.statFile(self.lane.io, name, .{ .follow_symlinks = false }) catch |err| {
                self.state = openFailure(err);
                return .completed;
            };
            switch (named.kind) {
                .file => {},
                .directory, .sym_link => {
                    self.state = .restricted;
                    return .completed;
                },
                else => return self.notRegular(),
            }
        }
        var file = parent.openFile(self.lane.io, name, .{
            .allow_directory = false,
            .follow_symlinks = false,
            .resolve_beneath = true,
        }) catch |err| {
            self.state = openFailure(err);
            return .completed;
        };
        defer file.close(self.lane.io);
        if (builtin.os.tag == .windows) file.flags.nonblocking = true;

        const before = file.stat(self.lane.io) catch {
            self.state = .failed;
            return .completed;
        };
        if (before.kind != .file) return self.notRegular();
        self.size_bytes = before.size;
        var header: [30]u8 = undefined;
        const header_len: usize = @intCast(@min(before.size, header.len));
        const header_read = file.readPositionalAll(self.lane.io, header[0..header_len], 0) catch {
            self.state = .failed;
            return .completed;
        };
        const kind = classifyHeader(header[0..header_read], before.size, self.subject.video(self.location));
        switch (kind) {
            .image => {},
            .text => if (self.subject.storeOwned()) {
                // An attachment original was classified as an image when it was
                // staged. If it no longer looks like one it has changed
                // underneath us, and this source must never fall through to
                // the text body path.
                self.state = .unsupported;
                return .completed;
            },
            .video => {
                self.video = true;
                // The header is all there is to say about a video without
                // playing it, so describing one takes no slot and reads none.
                if (self.mode == .describe) {
                    self.state = .ready;
                    return .completed;
                }
                if (!self.lane.reserveVideo()) {
                    self.state = .busy;
                    return .completed;
                }
                self.reserved_video = true;
            },
            .unsupported => {
                self.state = .unsupported;
                return .completed;
            },
            .animated_image => {
                self.state = .animated_image;
                return .completed;
            },
            .image_limit => {
                self.state = .image_limit;
                return .completed;
            },
        }
        const image = kind == .image;
        const wanted: usize = @intCast(if (image or self.video) before.size else @min(before.size, self.max_bytes));
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

        if (self.video) {
            if (!std.mem.eql(u8, bytes[4..8], "ftyp")) return .changed;
            self.state = .ready;
            return .completed;
        }
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

    fn openFailure(err: anyerror) State {
        return switch (err) {
            error.FileNotFound, error.NotDir => .missing,
            else => .restricted,
        };
    }

    /// It has no size and no content to describe.
    fn notRegular(self: *Job) ReadOutcome {
        self.state = if (self.mode == .describe) .restricted else .unsupported;
        return .completed;
    }

    fn readDirectory(self: *Job, root: std.Io.Dir) ReadOutcome {
        var directory = openWorkspaceDirectory(self.lane.io, root, self.location.relative) catch |err| {
            self.state = openFailure(err);
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
        self.video = false;
        if (self.reserved_image_bytes != 0) self.lane.releaseImage(self.reserved_image_bytes);
        self.reserved_image_bytes = 0;
        if (self.reserved_video) self.lane.releaseVideo();
        self.reserved_video = false;
    }

    fn deinit(self: *Job) void {
        self.clearContent();
        self.location.free(self.lane.allocator);
        self.subject.free(self.lane.allocator);
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
    video_reserved: bool = false,

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
        const subject = try input.subject.clone(self.allocator);
        errdefer subject.free(self.allocator);
        const location = try input.location.clone(self.allocator);
        errdefer location.free(self.allocator);
        job.* = .{
            .mode = input.mode,
            .subject = subject,
            .location = location,
            .lane = self,
            .completion_id = input.completion_id,
            .created_at = .now(self.io, .awake),
            .max_bytes = input.max_bytes,
            .max_lines = input.max_lines,
            .max_line_bytes = input.max_line_bytes,
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
        std.debug.assert(self.image_count == 0 and self.image_bytes == 0);
        std.debug.assert(!self.video_reserved);
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
                .mode = job.mode,
                .subject = job.subject,
                .location = job.location,
                .description = job.description,
                .video = job.video,
                .entries = job.entries[0..job.entry_count],
                .completion_id = job.completion_id,
                .state = job.state,
                .content = job.content,
                .image_info = job.image_info,
                .truncated = job.truncated,
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

    fn reserveVideo(self: *Lane) bool {
        self.lock();
        defer self.unlock();
        if (!self.accepting or self.video_reserved) return false;
        self.video_reserved = true;
        return true;
    }

    fn releaseVideo(self: *Lane) void {
        self.lock();
        defer self.unlock();
        std.debug.assert(self.video_reserved);
        self.video_reserved = false;
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

const test_reference: Subject = .{ .file = .{ .reference = .{ .task_id = 1, .run_id = 1, .id = "ref" } } };

fn testInput(subject: Subject, root: []const u8, relative: []const u8) Input {
    return .{
        .subject = subject,
        .location = .{ .workspace_id = 1, .workspace_epoch = 1, .root = root, .relative = relative },
        .completion_id = 1,
        .max_bytes = 1024,
        .max_lines = 100,
        .max_line_bytes = 1024,
    };
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
    try lane.begin(testInput(.{ .directory = .{ .task_id = 1, .workspace_id = 1, .workspace_epoch = 1, .path = "" } }, root, ""));
    const listing = lane.take().?;
    try std.testing.expectEqual(State.ready, listing.completion.state);
    try std.testing.expectEqual(@as(usize, 1), listing.completion.entries.len);
    try std.testing.expectEqualStrings("docs", listing.completion.entries[0].name);
    try std.testing.expectEqual(.directory, listing.completion.entries[0].kind);
    lane.release(listing);
    try lane.begin(testInput(.{ .file = .{ .workspace = .{ .task_id = 1, .workspace_id = 1, .workspace_epoch = 1, .path = "docs/unreferenced.txt" } } }, root, "docs/unreferenced.txt"));
    const file = lane.take().?;
    try std.testing.expectEqual(State.ready, file.completion.state);
    try std.testing.expectEqualStrings("workspace content", file.completion.content);
    lane.release(file);
    try lane.begin(testInput(.{ .directory = .{ .task_id = 1, .workspace_id = 1, .workspace_epoch = 1, .path = "../outside" } }, root, "../outside"));
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
    }) |entry| {
        var input = testInput(test_reference, root_storage[0..root_len], entry[1]);
        input.completion_id = entry[0];
        input.max_bytes = entry[2];
        try lane.begin(input);
    }

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
        var input = testInput(test_reference, root, path);
        input.completion_id = index + 1;
        input.max_bytes = 2;
        try lane.begin(input);
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
        var input = testInput(test_reference, root, if (index == 3) "text.txt" else "image.jpg");
        input.completion_id = index + 1;
        try lane.begin(input);
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
    var input = testInput(test_reference, "not-a-real-root", "not-opened.jpg");
    input.completion_id = 17;
    try lane.begin(input);
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

const TestLane = struct {
    lane: *Lane,

    fn wake(_: ?*anyopaque) bool {
        return true;
    }
    fn enqueue(_: *anyopaque, job: ExecutorJob) error{ ExecutorShuttingDown, QueueFull }!void {
        job.execute_fn(job.context);
    }
    var context: u8 = 0;

    fn init() !TestLane {
        return .{ .lane = try Lane.create(std.testing.io, std.testing.allocator, .{ .wake_fn = wake }, .{ .context = &context, .enqueue_fn = enqueue }) };
    }
    fn deinit(self: TestLane) void {
        self.lane.stopAdmission();
        self.lane.deinit();
    }

    const Outcome = struct { state: State, image: bool, video: bool, description: ?Description, content_len: usize };

    fn read(self: TestLane, mode: Mode, target: file_target.Target, root: []const u8, relative: []const u8) !Outcome {
        var input = testInput(.{ .file = target }, root, relative);
        input.mode = mode;
        input.max_bytes = 256 * 1024;
        input.max_lines = 10_000;
        input.max_line_bytes = 256 * 1024;
        try self.lane.begin(input);
        const taken = self.lane.take().?;
        defer self.lane.release(taken);
        return .{
            .state = taken.completion.state,
            .image = taken.completion.image_info != null,
            .video = taken.completion.video,
            .description = taken.completion.description,
            .content_len = taken.completion.content.len,
        };
    }
};

const test_output: file_target.Target = .{ .output = .{ .task_id = 1, .run_id = 1, .id = @splat(1) } };
const test_workspace: file_target.Target = .{ .workspace = .{ .task_id = 1, .workspace_id = 1, .workspace_epoch = 1, .path = "sample" } };
const test_jpeg = "\xff\xd8\xff\xc0\x00\x0b\x08\x00\x02\x00\x03\x01\x01\x11\x00" ++ "\xff\xda\x00\x08\x01\x01\x00\x00\x3f\x00\x01\xff\xd9";
const test_webp = "RIFF\x12\x00\x00\x00WEBPVP8L\x05\x00\x00\x00\x2f\x02\x40\x00\x00\x00";

fn testJpeg(comptime height: u16, comptime width: u16) *const [test_jpeg.len]u8 {
    return comptime jpeg: {
        var bytes = test_jpeg.*;
        std.mem.writeInt(u16, bytes[7..9], height, .big);
        std.mem.writeInt(u16, bytes[9..11], width, .big);
        const frozen = bytes;
        break :jpeg &frozen;
    };
}

fn testPng(allocator: std.mem.Allocator, animated: bool) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    try bytes.appendSlice(allocator, "\x89PNG\r\n\x1a\n");
    const Chunk = struct { kind: *const [4]u8, data: []const u8 };
    const header = "\x00\x00\x00\x02\x00\x00\x00\x01\x08\x06\x00\x00\x00";
    const chunks = [_]Chunk{ .{ .kind = "IHDR", .data = header }, .{ .kind = "acTL", .data = "\x00\x00\x00\x02\x00\x00\x00\x00" }, .{ .kind = "IDAT", .data = "data" }, .{ .kind = "IEND", .data = "" } };
    for (chunks) |chunk| {
        if (!animated and std.mem.eql(u8, chunk.kind, "acTL")) continue;
        var word: [4]u8 = undefined;
        std.mem.writeInt(u32, &word, @intCast(chunk.data.len), .big);
        try bytes.appendSlice(allocator, &word);
        const start = bytes.items.len;
        try bytes.appendSlice(allocator, chunk.kind);
        try bytes.appendSlice(allocator, chunk.data);
        std.mem.writeInt(u32, &word, std.hash.Crc32.hash(bytes.items[start..]), .big);
        try bytes.appendSlice(allocator, &word);
    }
    return bytes.toOwnedSlice(allocator);
}

test "file preview describes every file as previewing it would turn out" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const lane = try TestLane.init();
    defer lane.deinit();

    const png = try testPng(allocator, false);
    defer allocator.free(png);
    const apng = try testPng(allocator, true);
    defer allocator.free(apng);
    // 256 KiB of text whose last character is cut by the read limit, and the
    // same with a byte no text has just past it.
    const cut = try allocator.alloc(u8, 256 * 1024 + 2);
    defer allocator.free(cut);
    @memset(cut, 'a');
    @memcpy(cut[256 * 1024 - 1 ..][0..3], "中");
    const beyond = try allocator.alloc(u8, 256 * 1024 + 4);
    defer allocator.free(beyond);
    @memset(beyond, 'a');
    beyond[beyond.len - 1] = 0;

    const Kind = enum { image, video, text, opaque_file };
    const Sample = struct { name: []const u8, bytes: []const u8, size: u64 = 0, kind: Kind };
    const brand = struct {
        fn box(comptime name: *const [4]u8) []const u8 {
            return "\x00\x00\x00\x18ftyp" ++ name ++ "\x00\x00\x02\x00isomiso2 rest of the file";
        }
    };
    const samples = [_]Sample{
        .{ .name = "a.png", .bytes = png, .kind = .image },
        .{ .name = "a.jpg", .bytes = test_jpeg ++ "trailing motion data", .kind = .image },
        .{ .name = "a.webp", .bytes = test_webp, .kind = .image },
        .{ .name = "apng.png", .bytes = apng, .kind = .opaque_file },
        .{ .name = "moving.webp", .bytes = "RIFF\x16\x00\x00\x00WEBPVP8X\x0a\x00\x00\x00\x02\x00\x00\x00\x01\x00\x00\x00\x00\x00 and more", .kind = .opaque_file },
        .{ .name = "bytes.png", .bytes = "\x89PNG\r\n\x1a\n", .size = max_image_source_bytes + 1, .kind = .opaque_file },
        .{ .name = "pixels.jpg", .bytes = testJpeg(8000, 3000), .kind = .opaque_file },
        .{ .name = "side.jpg", .bytes = testJpeg(2, 8193), .kind = .opaque_file },
        .{ .name = "cut.png", .bytes = png[0 .. png.len - 4], .kind = .opaque_file },
        .{ .name = "a.gif", .bytes = "GIF89a\x01\x00\x01\x00\x80\x00\x00\x00\x00\x00", .kind = .opaque_file },
        .{ .name = "isom.mp4", .bytes = brand.box("isom"), .kind = .video },
        .{ .name = "iso2.mp4", .bytes = brand.box("iso2"), .kind = .video },
        .{ .name = "iso4.mp4", .bytes = brand.box("iso4"), .kind = .video },
        .{ .name = "iso5.mp4", .bytes = brand.box("iso5"), .kind = .video },
        .{ .name = "iso6.mp4", .bytes = brand.box("iso6"), .kind = .video },
        .{ .name = "mp41.mp4", .bytes = brand.box("mp41"), .kind = .video },
        .{ .name = "mp42.mp4", .bytes = brand.box("mp42"), .kind = .video },
        .{ .name = "avc1.mp4", .bytes = brand.box("avc1"), .kind = .video },
        .{ .name = "m4v.m4v", .bytes = brand.box("M4V "), .kind = .video },
        .{ .name = "dash.mp4", .bytes = brand.box("dash"), .kind = .video },
        .{ .name = "msnv.mp4", .bytes = brand.box("MSNV"), .kind = .video },
        .{ .name = "named.txt", .bytes = brand.box("isom"), .kind = .video },
        .{ .name = "a.heic", .bytes = brand.box("heic"), .kind = .opaque_file },
        .{ .name = "a.avif", .bytes = brand.box("avif"), .kind = .opaque_file },
        .{ .name = "a.mov", .bytes = brand.box("qt  "), .kind = .opaque_file },
        .{ .name = "a.m4a", .bytes = brand.box("M4A "), .kind = .opaque_file },
        .{ .name = "short.mp4", .bytes = "\x00\x00\x00\x10ftypisom\x00\x00\x02", .kind = .opaque_file },
        .{ .name = "large.mp4", .bytes = brand.box("isom"), .size = max_video_bytes + 1, .kind = .opaque_file },
        .{ .name = "empty.txt", .bytes = "", .kind = .text },
        .{ .name = "a.md", .bytes = "# 标题\n\ttext\r\n", .kind = .text },
        .{ .name = "cut.txt", .bytes = cut, .kind = .text },
        .{ .name = "beyond.txt", .bytes = beyond, .kind = .text },
        .{ .name = "nul.txt", .bytes = "text\x00more", .kind = .opaque_file },
        .{ .name = "gbk.txt", .bytes = "\xd6\xd0\xce\xc4", .kind = .opaque_file },
        .{ .name = "utf16.txt", .bytes = "\xff\xfea\x00b\x00", .kind = .opaque_file },
        .{ .name = "a.docx", .bytes = "PK\x03\x04\x14\x00\x00\x00", .kind = .opaque_file },
        .{ .name = "a.pdf", .bytes = "%PDF-1.7\n%\xe2\xe3\xcf\xd3\n", .kind = .opaque_file },
        .{ .name = "image.txt", .bytes = png, .kind = .image },
        .{ .name = "text.png", .bytes = "not an image", .kind = .text },
    };
    for (samples) |sample| {
        errdefer std.debug.print("sample {s}\n", .{sample.name});
        const file = try tmp.dir.createFile(io, sample.name, .{});
        try file.writeStreamingAll(io, sample.bytes);
        if (sample.size != 0) try file.setLength(io, sample.size);
        file.close(io);
        const size = if (sample.size != 0) sample.size else sample.bytes.len;

        // The identity a reply shows: what is described is what is delivered.
        const previewed = try lane.read(.deliver, test_output, root, sample.name);
        const described = try lane.read(.describe, test_output, root, sample.name);
        try std.testing.expectEqual(State.ready, described.state);
        try std.testing.expectEqual(@as(usize, 0), described.content_len);
        const description = described.description.?;
        try std.testing.expectEqual(size, description.size_bytes);
        const delivered: Kind = if (previewed.state != .ready) .opaque_file else if (previewed.image) .image else if (previewed.video) .video else .text;
        try std.testing.expectEqual(sample.kind, delivered);
        try std.testing.expectEqual(sample.kind, @as(Kind, switch (description.kind) {
            .image => .image,
            .video => .video,
            .file => |value| if (value.previewable) .text else .opaque_file,
        }));

        // A card that is not played or shown in place opens the Workspace tab
        // of the same file. Whether it may be clicked is whether that tab
        // would show anything.
        const tab = try lane.read(.deliver, test_workspace, root, sample.name);
        if (description.kind == .file)
            try std.testing.expectEqual(tab.state == .ready, description.kind.file.previewable);
        try std.testing.expectEqual(tab.state == .ready, sample.kind == .image or sample.kind == .text);
        // Only an identity played in place is read as a video at all.
        try std.testing.expect(!tab.video);
        const listed = try lane.read(.describe, test_workspace, root, sample.name);
        const shown: bool = switch (listed.description.?.kind) {
            .image => true,
            .video => return error.TestUnexpectedResult,
            .file => |value| value.previewable,
        };
        try std.testing.expectEqual(tab.state == .ready, shown);
    }
    try std.testing.expectEqual(@as(usize, 0), lane.lane.image_count);
    try std.testing.expect(!lane.lane.video_reserved);
}

test "file preview descriptions say nothing of a file that was not reached" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "folder", .default_dir);
    const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const lane = try TestLane.init();
    defer lane.deinit();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "text" });
    for ([_]struct { []const u8, State }{
        .{ "missing.txt", .missing },
        // A parent that is gone, or is a file by now, is a file that is gone.
        .{ "gone/a.txt", .missing },
        .{ "a.txt/b.txt", .missing },
        .{ "folder", .restricted },
        .{ "../outside.txt", .restricted },
    }) |case| for ([_]file_target.Target{ test_output, test_reference.file }) |target| {
        const described = try lane.read(.describe, target, root, case[0]);
        try std.testing.expectEqual(case[1], described.state);
        try std.testing.expect(described.description == null);
    };
}

test "file preview never opens a pipe" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.joinZ(std.testing.allocator, &.{ root, "pipe.txt" });
    defer std.testing.allocator.free(path);
    const create = struct {
        extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;
    };
    if (create.mkfifo(path, 0o600) != 0) return error.SkipZigTest;
    const lane = try TestLane.init();
    defer lane.deinit();
    // Nothing writes to it: opening it would never return.
    const described = try lane.read(.describe, test_reference.file, root, "pipe.txt");
    try std.testing.expectEqual(State.restricted, described.state);
    const delivered = try lane.read(.deliver, test_reference.file, root, "pipe.txt");
    try std.testing.expectEqual(State.unsupported, delivered.state);
}

test "file preview descriptions return their slots and never hold the video slot" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.jpg", .data = test_jpeg });
    try tmp.dir.writeFile(io, .{ .sub_path = "a.mp4", .data = "\x00\x00\x00\x18ftypisom\x00\x00\x02\x00isomiso2" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const lane = try TestLane.init();
    defer lane.deinit();
    // Both image slots are held by deliveries, and so is the video slot.
    var held: [3]Taken = undefined;
    for (&held, 0..) |*slot, index| {
        var input = testInput(.{ .file = test_output }, root, if (index == 2) "a.mp4" else "a.jpg");
        input.completion_id = index + 1;
        try lane.lane.begin(input);
        slot.* = lane.lane.take().?;
        try std.testing.expectEqual(State.ready, slot.completion.state);
    }
    const busy = try lane.read(.describe, test_output, root, "a.jpg");
    try std.testing.expectEqual(State.busy, busy.state);
    try std.testing.expect(busy.description == null);
    // A video is described without its slot.
    const video = try lane.read(.describe, test_output, root, "a.mp4");
    try std.testing.expectEqual(State.ready, video.state);
    try std.testing.expect(video.description.?.kind == .video);
    for (held) |taken| lane.lane.release(taken);
    for (0..3) |_| {
        const image = try lane.read(.describe, test_output, root, "a.jpg");
        try std.testing.expectEqual(Description{ .size_bytes = test_jpeg.len, .kind = .{ .image = .{ .width = 3, .height = 2 } } }, image.description.?);
    }
    try std.testing.expectEqual(@as(usize, 0), lane.lane.image_count);
    try std.testing.expectEqual(@as(usize, 0), lane.lane.image_bytes);
}
