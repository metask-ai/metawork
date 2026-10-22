//! Bounded Office-only subprocess calls for Application install selftest and
//! document previews. User Shell execution keeps the standalone entry owner.
const std = @import("std");
const builtin = @import("builtin");
const windows = @import("office_process_windows");

pub const Cancellation = struct {
    requested: std.atomic.Value(bool) = .init(false),
};

pub fn hostScope() ![24]u8 {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
    return windows.hostScope();
}

pub const Context = struct {
    parent_environment: *const std.process.Environ.Map,
    scratch_root: []const u8,
};

pub const Command = union(enum) {
    selftest,
    render: struct { input: []const u8, output: []const u8, width: u16 = 1280 },
    text: struct { input: []const u8, output: []const u8 },
};

pub const Output = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: *Output, allocator: std.mem.Allocator) void {
        std.crypto.secureZero(u8, self.stdout);
        std.crypto.secureZero(u8, self.stderr);
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.* = undefined;
    }
};

/// Worker-only. Caller must keep the selected component version pinned through
/// this call, and may delete output/staging resources only after it returns.
/// Any cleanup uncertainty is explicit and must prevent publication/deletion.
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    component_root: []const u8,
    command: Command,
    context: Context,
    timeout_ms: u32,
    cancellation: *const Cancellation,
) !Output {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
    if (!validPath(component_root) or !validPath(context.scratch_root) or timeout_ms == 0 or timeout_ms > 300_000) return error.InvalidOfficeRequest;
    if (cancellation.requested.load(.acquire)) return error.Cancelled;
    const started: std.Io.Timestamp = .now(io, .awake);
    const scratch = try std.Io.Dir.cwd().openDir(io, context.scratch_root, .{ .follow_symlinks = false });
    scratch.close(io);
    var environment: std.process.Environ.Map = .init(allocator);
    defer environment.deinit();
    // These fixed Host commands do not need Task/provider credentials or user
    // interpreter options. Preserve only OS context and use owned scratch.
    for ([_][]const u8{ "SystemRoot", "WINDIR", "COMSPEC", "PATH", "PATHEXT", "USERPROFILE", "APPDATA", "LOCALAPPDATA", "HOMEDRIVE", "HOMEPATH", "USERNAME", "USERDOMAIN", "LANG", "LC_ALL", "NUMBER_OF_PROCESSORS", "PROCESSOR_ARCHITECTURE", "ProgramFiles", "ProgramFiles(x86)", "ProgramW6432" }) |key| {
        if (context.parent_environment.get(key)) |value| try environment.put(key, value);
    }
    try environment.put("TMP", context.scratch_root);
    try environment.put("TEMP", context.scratch_root);
    try environment.put("TMPDIR", context.scratch_root);
    var job = try windows.Job.init(io);
    defer job.deinit();
    const entry = try std.fs.path.join(allocator, &.{ component_root, "bin", "office.exe" });
    defer allocator.free(entry);
    // Fixed-size argument slots; no input is interpreted as a command string.
    var arguments: [10][]const u8 = undefined;
    arguments[0..3].* = .{ entry, "--host-job", job.name() };
    var width_buffer: [8]u8 = undefined;
    const count: usize = switch (command) {
        .selftest => value: {
            arguments[3] = "selftest";
            break :value 4;
        },
        .text => |paths| value: {
            if (!validPath(paths.input) or !validPath(paths.output)) return error.InvalidOfficeRequest;
            arguments[3..6].* = .{ "text", paths.input, paths.output };
            break :value 6;
        },
        .render => |paths| value: {
            if (!validPath(paths.input) or !validPath(paths.output) or paths.width < 128 or paths.width > 2048)
                return error.InvalidOfficeRequest;
            arguments[3..8].* = .{ "render", paths.input, paths.output, "--width", try std.fmt.bufPrint(&width_buffer, "{d}", .{paths.width}) };
            break :value 8;
        },
    };
    var child = try std.process.spawn(io, .{
        .argv = arguments[0..count],
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .create_no_window = true,
        .cwd = .{ .path = context.scratch_root },
        .environ_map = &environment,
    });
    defer child.kill(io);
    const stdout = child.stdout.?;
    const stderr = child.stderr.?;
    child.stdout = null;
    child.stderr = null;
    defer stdout.close(io);
    defer stderr.close(io);
    var out: Capture = .{ .io = io, .file = stdout };
    var err: Capture = .{ .io = io, .file = stderr };
    defer std.crypto.secureZero(u8, &out.bytes);
    defer std.crypto.secureZero(u8, &err.bytes);
    const out_thread = std.Thread.spawn(.{}, Capture.read, .{&out}) catch |failure| {
        try stop(io, &child, &job, null, null);
        return failure;
    };
    const err_thread = std.Thread.spawn(.{}, Capture.read, .{&err}) catch |failure| {
        try stop(io, &child, &job, out_thread, null);
        return failure;
    };
    const term = monitor(io, &child, &job, &out, &err, started, timeout_ms, cancellation) catch |failure| {
        try stop(io, &child, &job, out_thread, err_thread);
        return failure;
    };
    out_thread.join();
    err_thread.join();
    const out_bytes = try allocator.dupe(u8, out.bytes[0..out.len]);
    errdefer {
        std.crypto.secureZero(u8, out_bytes);
        allocator.free(out_bytes);
    }
    return .{ .term = term, .stdout = out_bytes, .stderr = try allocator.dupe(u8, err.bytes[0..err.len]) };
}

// std.process.run cancels its pipe batch before killing the child; a live
// Windows writer can keep that cancellation blocked. Keep one root owner and
// bounded readers instead: terminate/join the root and Job before joining I/O.
fn stop(io: std.Io, child: *std.process.Child, job: *windows.Job, out: ?std.Thread, err: ?std.Thread) !void {
    child.kill(io);
    const cleanup = job.terminateAndWait(io);
    cleanup catch job.deinit(); // closing the sole handle also kills descendants
    if (out) |thread| thread.join();
    if (err) |thread| thread.join();
    try cleanup;
}

const Capture = struct {
    io: std.Io,
    file: std.Io.File,
    bytes: [16 * 1024 + 1]u8 = undefined,
    len: usize = 0,
    problem: ?anyerror = null,
    done: std.atomic.Value(bool) = .init(false),

    fn read(self: *Capture) void {
        defer self.done.store(true, .release);
        while (self.len < self.bytes.len) {
            const count = self.file.readStreaming(self.io, &.{self.bytes[self.len..]}) catch |failure| {
                if (failure != error.EndOfStream) self.problem = failure;
                return;
            };
            if (count == 0) return;
            self.len += count;
        }
        self.problem = error.StreamTooLong;
    }

    fn resultFailure(self: *const Capture) ?anyerror {
        return if (self.done.load(.acquire)) self.problem else null;
    }
};

fn check(io: std.Io, started: std.Io.Timestamp, timeout_ms: u32, cancellation: *const Cancellation, out: *const Capture, err: *const Capture) !void {
    if (cancellation.requested.load(.acquire)) return error.Cancelled;
    if (started.durationTo(.now(io, .awake)).toMilliseconds() >= timeout_ms) return error.OfficeTimedOut;
    if (out.resultFailure()) |failure| return failure;
    if (err.resultFailure()) |failure| return failure;
}

fn sleep(io: std.Io) !void {
    try std.Io.Timeout.sleep(.{ .duration = .{ .raw = .fromMilliseconds(5), .clock = .awake } }, io);
}

fn monitor(io: std.Io, child: *std.process.Child, job: *windows.Job, out: *const Capture, err: *const Capture, started: std.Io.Timestamp, timeout_ms: u32, cancellation: *const Cancellation) !std.process.Child.Term {
    while (!try job.rootExited(child)) {
        try check(io, started, timeout_ms, cancellation, out, err);
        try sleep(io);
    }
    const term = try child.wait(io);
    const root_exited: std.Io.Timestamp = .now(io, .awake);
    while (try job.active() != 0) {
        try check(io, started, timeout_ms, cancellation, out, err);
        if (root_exited.durationTo(.now(io, .awake)).toMilliseconds() >= 2000) return error.OfficeDescendantsOutstanding;
        try sleep(io);
    }
    while (!out.done.load(.acquire) or !err.done.load(.acquire)) {
        try check(io, started, timeout_ms, cancellation, out, err);
        try sleep(io);
    }
    try check(io, started, timeout_ms, cancellation, out, err);
    return term;
}

fn validPath(path: []const u8) bool {
    if (path.len == 0 or path.len > 4096 or !std.fs.path.isAbsolute(path) or !std.unicode.utf8ValidateSlice(path)) return false;
    for (path) |character| if (std.ascii.isControl(character)) return false;
    return true;
}

test "Office Application requests are absolute and cancellation precedes any spawn" {
    const cancellation: Cancellation = .{ .requested = .init(true) };
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var environment: std.process.Environ.Map = .init(std.testing.allocator);
    defer environment.deinit();
    const context: Context = .{ .parent_environment = &environment, .scratch_root = "C:\\scratch" };
    try std.testing.expectError(error.InvalidOfficeRequest, run(std.testing.allocator, std.testing.io, "relative", .selftest, context, 1000, &cancellation));
    try std.testing.expectError(error.Cancelled, run(std.testing.allocator, std.testing.io, "C:\\missing-component", .selftest, context, 1000, &cancellation));
}

test {
    if (builtin.os.tag == .windows) std.testing.refAllDecls(windows);
}
