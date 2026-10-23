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

/// Office's installed-version or pending-operation kernel lifetime. Catalog bookkeeping owns the sole
/// long-lived handle; the component joins and closes its temporary handle before
/// creating children. A sealed deletion reservation rejects new executions.
pub const ResourceScope = struct {
    job: if (builtin.os.tag == .windows) windows.Job else void,
    sealed: bool = false,

    pub fn initVersion(identity: [16]u8) !ResourceScope {
        if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
        return .{ .job = try windows.Job.version(identity, false) };
    }

    pub fn initOperation(identity: [16]u8) !ResourceScope {
        if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
        return .{ .job = try windows.Job.operation(identity, false) };
    }

    /// Non-waiting collection: an existing Job belongs to a live owner and
    /// cannot be adopted, even when it currently has no child process.
    pub fn tryReserveOperationDeletion(identity: [16]u8) !ResourceScope {
        if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
        return .{ .job = try windows.Job.operation(identity, true), .sealed = true };
    }

    pub fn reserveVersionDeletion(io: std.Io, identity: [16]u8, cancellation: *const Cancellation) !ResourceScope {
        return reserve(io, identity, cancellation, false);
    }

    pub fn reserveOperationDeletion(io: std.Io, identity: [16]u8, cancellation: *const Cancellation) !ResourceScope {
        return reserve(io, identity, cancellation, true);
    }

    fn reserve(io: std.Io, identity: [16]u8, cancellation: *const Cancellation, operation: bool) !ResourceScope {
        if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
        const start: std.Io.Timestamp = .now(io, .awake);
        while (true) {
            if (cancellation.requested.load(.acquire)) return error.Cancelled;
            const job = (if (operation) windows.Job.operation(identity, true) else windows.Job.version(identity, true)) catch |failure| {
                if (failure != error.JobInUse) return failure;
                if (start.durationTo(.now(io, .awake)).toMilliseconds() >= 5000) return error.ComponentProcessesOutstanding;
                try std.Io.Timeout.sleep(.{ .duration = .{ .raw = .fromMilliseconds(5), .clock = .awake } }, io);
                continue;
            };
            return .{ .job = job, .sealed = true };
        }
    }

    pub fn settle(self: *ResourceScope, io: std.Io) !void {
        if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
        try self.job.seal();
        self.sealed = true;
        try self.job.terminateAndWait(io);
    }

    pub fn deinit(self: *ResourceScope) void {
        if (builtin.os.tag == .windows) self.job.deinit();
    }
};

pub const Operation = union(enum) { create: [16]u8, borrow: *ResourceScope };

pub const Context = struct {
    parent_environment: *const std.process.Environ.Map,
    scratch_root: []const u8,
    operation: ?Operation = null,
};

const PagePaths = struct { input: []const u8, output: []const u8, width: u16 = 1280 };
pub const Command = union(enum) {
    selftest,
    /// Only the caller-authenticated install stage and fixed bootstrap script.
    /// No arbitrary executable, script, download URL or command line is accepted.
    bootstrap: struct { component_manifest_sha256: [32]u8, seed_manifest_sha256: [32]u8 },
    render: PagePaths,
    preview: PagePaths,
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

/// A failure cause cannot prove that the process tree has stopped. Callers
/// must preserve owned files and version leases when quiescent is false,
/// including for unfamiliar observation or termination errors.
pub const Failure = struct { cause: anyerror, quiescent: bool };
pub const Outcome = union(enum) { completed: Output, failed: Failure };

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
) Outcome {
    var quiescent = true;
    const output = runOwned(allocator, io, component_root, command, context, timeout_ms, cancellation, &quiescent) catch |cause|
        return .{ .failed = .{ .cause = cause, .quiescent = quiescent } };
    std.debug.assert(quiescent);
    return .{ .completed = output };
}

fn runOwned(
    allocator: std.mem.Allocator,
    io: std.Io,
    component_root: []const u8,
    command: Command,
    context: Context,
    timeout_ms: u32,
    cancellation: *const Cancellation,
    quiescent: *bool,
) !Output {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
    const bootstrap = command == .bootstrap;
    if (!validPath(component_root) or !validPath(context.scratch_root) or timeout_ms == 0 or timeout_ms > @as(u32, if (bootstrap) 900_000 else 300_000)) return error.InvalidOfficeRequest;
    if (bootstrap and (context.operation == null or std.mem.allEqual(u8, &command.bootstrap.component_manifest_sha256, 0) or
        std.mem.allEqual(u8, &command.bootstrap.seed_manifest_sha256, 0))) return error.InvalidOfficeRequest;
    if (cancellation.requested.load(.acquire)) return error.Cancelled;
    const started: std.Io.Timestamp = .now(io, .awake);
    const scratch = try std.Io.Dir.cwd().openDir(io, context.scratch_root, .{ .follow_symlinks = false });
    scratch.close(io);
    var environment: std.process.Environ.Map = .init(allocator);
    defer environment.deinit();
    // These fixed Host commands do not need Task/provider credentials or user
    // interpreter options. Preserve only OS context and use owned scratch.
    for ([_][]const u8{ "SystemRoot", "WINDIR", "COMSPEC", "PATH", "PATHEXT", "USERPROFILE", "APPDATA", "LOCALAPPDATA", "HOMEDRIVE", "HOMEPATH", "USERNAME", "USERDOMAIN", "LANG", "LC_ALL", "NUMBER_OF_PROCESSORS", "PROCESSOR_ARCHITECTURE", "ProgramFiles", "ProgramFiles(x86)", "ProgramW6432" }) |key| {
        if (bootstrap and !(std.mem.eql(u8, key, "SystemRoot") or std.mem.eql(u8, key, "WINDIR") or std.mem.eql(u8, key, "COMSPEC"))) continue;
        if (context.parent_environment.get(key)) |value| try environment.put(key, value);
    }
    try environment.put("TMP", context.scratch_root);
    try environment.put("TEMP", context.scratch_root);
    try environment.put("TMPDIR", context.scratch_root);
    var owned_job: ?windows.Job = null;
    defer if (owned_job) |*owned| owned.deinit();
    const job: *windows.Job = job: {
        if (context.operation) |operation| switch (operation) {
            .borrow => |scope| {
                if (scope.sealed or scope.job.handle == null) return error.InvalidOperationScope;
                break :job &scope.job;
            },
            .create => |identity| owned_job = windows.Job.operation(identity, false) catch |failure| {
                if (failure == error.JobInUse) quiescent.* = false;
                return failure;
            },
        } else owned_job = try windows.Job.init(io);
        break :job &owned_job.?;
    };
    if (bootstrap and !std.mem.startsWith(u8, job.name(), "Local\\MetaWork.Office.Op.")) return error.InvalidOperationScope;
    var argument_memory = std.heap.ArenaAllocator.init(allocator);
    defer argument_memory.deinit();
    const argument_allocator = argument_memory.allocator();
    const entry = if (bootstrap) try std.fs.path.join(argument_allocator, &.{ component_root, "bootstrap", "python.exe" }) else try std.fs.path.join(argument_allocator, &.{ component_root, "bin", "office.exe" });
    // Fixed-size argument slots; no input is interpreted as a command string.
    var arguments: [14][]const u8 = undefined;
    arguments[0..3].* = .{ entry, "--host-job", job.name() };
    var width_buffer: [8]u8 = undefined;
    var component_digest: [64]u8 = undefined;
    var seed_digest: [64]u8 = undefined;
    const count: usize = switch (command) {
        .bootstrap => |pins| value: {
            component_digest = std.fmt.bytesToHex(pins.component_manifest_sha256, .lower);
            seed_digest = std.fmt.bytesToHex(pins.seed_manifest_sha256, .lower);
            const script = try std.fs.path.join(argument_allocator, &.{ component_root, "seed", "bootstrap", "assemble.py" });
            const seed = try std.fs.path.join(argument_allocator, &.{ component_root, "seed" });
            const downloads = try std.fs.path.join(argument_allocator, &.{ component_root, "downloads" });
            const destination = try std.fs.path.join(argument_allocator, &.{ component_root, "component" });
            arguments = .{ entry, "-I", "-S", "-B", "-X", "utf8", script, seed, downloads, destination, &component_digest, &seed_digest, "--host-job", job.name() };
            break :value arguments.len;
        },
        .selftest => value: {
            arguments[3] = "selftest";
            break :value 4;
        },
        .text => |paths| value: {
            if (!validPath(paths.input) or !validPath(paths.output)) return error.InvalidOfficeRequest;
            arguments[3..6].* = .{ "text", paths.input, paths.output };
            break :value 6;
        },
        .render, .preview => |paths| value: {
            if (!validPath(paths.input) or !validPath(paths.output) or paths.width < 128 or paths.width > 2048)
                return error.InvalidOfficeRequest;
            arguments[3..8].* = .{ @tagName(command), paths.input, paths.output, "--width", try std.fmt.bufPrint(&width_buffer, "{d}", .{paths.width}) };
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
    quiescent.* = false;
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
        try stop(io, &child, job, null, null, &out, &err, quiescent);
        return failure;
    };
    const err_thread = std.Thread.spawn(.{}, Capture.read, .{&err}) catch |failure| {
        try stop(io, &child, job, out_thread, null, &out, &err, quiescent);
        return failure;
    };
    const term = monitor(io, &child, job, &out, &err, started, timeout_ms, cancellation) catch |failure| {
        try stop(io, &child, job, out_thread, err_thread, &out, &err, quiescent);
        return failure;
    };
    out_thread.join();
    err_thread.join();
    quiescent.* = true;
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
fn stop(io: std.Io, child: *std.process.Child, job: *windows.Job, out: ?std.Thread, err: ?std.Thread, out_capture: *Capture, err_capture: *Capture, quiescent: *bool) !void {
    child.kill(io);
    const cleanup = job.terminateAndWait(io);
    cleanup catch job.deinit(); // closing the sole handle also kills descendants
    // Pipe EOF also depends on unrelated inheriting processes. Our readers are
    // bounded by this operation's lifetime, not those processes' lifetimes.
    out_capture.stopping.store(true, .release);
    err_capture.stopping.store(true, .release);
    if (out) |thread| thread.join();
    if (err) |thread| thread.join();
    try cleanup;
    quiescent.* = true;
}

const Capture = struct {
    io: std.Io,
    file: std.Io.File,
    bytes: [16 * 1024 + 1]u8 = undefined,
    len: usize = 0,
    problem: ?anyerror = null,
    done: std.atomic.Value(bool) = .init(false),
    stopping: std.atomic.Value(bool) = .init(false),

    fn read(self: *Capture) void {
        defer self.done.store(true, .release);
        while (self.len < self.bytes.len) {
            const available = windows.pipeAvailable(self.file.handle) catch |failure| {
                self.problem = failure;
                return;
            } orelse return;
            if (available == 0) {
                if (self.stopping.load(.acquire)) return;
                sleep(self.io) catch |failure| {
                    self.problem = failure;
                    return;
                };
                continue;
            }
            const end = self.len + @min(available, self.bytes.len - self.len);
            const count = self.file.readStreaming(self.io, &.{self.bytes[self.len..end]}) catch |failure| {
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

fn monitor(io: std.Io, child: *std.process.Child, job: *windows.Job, out: *Capture, err: *Capture, started: std.Io.Timestamp, timeout_ms: u32, cancellation: *const Cancellation) !std.process.Child.Term {
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
    out.stopping.store(true, .release);
    err.stopping.store(true, .release);
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
    const invalid = run(std.testing.allocator, std.testing.io, "relative", .selftest, context, 1000, &cancellation).failed;
    try std.testing.expect(invalid.cause == error.InvalidOfficeRequest);
    try std.testing.expect(invalid.quiescent);
    const cancelled = run(std.testing.allocator, std.testing.io, "C:\\missing-component", .selftest, context, 1000, &cancellation).failed;
    try std.testing.expect(cancelled.cause == error.Cancelled);
    try std.testing.expect(cancelled.quiescent);
}

test "Office capture stops while another process still owns its pipe writer" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var child = try std.process.spawn(io, .{
        .argv = &.{ "powershell.exe", "-NoProfile", "-NonInteractive", "-Command", "Start-Sleep -Seconds 30" },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
        .create_no_window = true,
    });
    defer child.kill(io);
    const file = child.stdout.?;
    child.stdout = null;
    defer file.close(io);
    var capture: Capture = .{ .io = io, .file = file };
    const thread = try std.Thread.spawn(.{}, Capture.read, .{&capture});
    capture.stopping.store(true, .release);
    thread.join(); // writer remains open: EOF-based readers hang here
    try std.testing.expect(capture.done.load(.acquire));
    try std.testing.expect(capture.resultFailure() == null);
    try std.testing.expectEqual(@as(usize, 0), capture.len);
}

test "bootstrap requires pending operation and manifest pins before any spawn" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var environment: std.process.Environ.Map = .init(std.testing.allocator);
    defer environment.deinit();
    const cancellation: Cancellation = .{ .requested = .init(true) };
    var context: Context = .{ .parent_environment = &environment, .scratch_root = "C:\\missing-scratch" };
    const command: Command = .{ .bootstrap = .{ .component_manifest_sha256 = @splat(1), .seed_manifest_sha256 = @splat(2) } };
    try std.testing.expectEqual(error.InvalidOfficeRequest, run(std.testing.allocator, std.testing.io, "C:\\stage", command, context, 1000, &cancellation).failed.cause);
    context.operation = .{ .create = @splat(3) };
    try std.testing.expectEqual(error.Cancelled, run(std.testing.allocator, std.testing.io, "C:\\stage", command, context, 900_000, &cancellation).failed.cause);
    try std.testing.expectEqual(error.InvalidOfficeRequest, run(std.testing.allocator, std.testing.io, "C:\\stage", command, context, 900_001, &cancellation).failed.cause);
    try std.testing.expectEqual(error.InvalidOfficeRequest, run(std.testing.allocator, std.testing.io, "C:\\stage", .{ .bootstrap = .{ .component_manifest_sha256 = @splat(0), .seed_manifest_sha256 = @splat(2) } }, context, 1000, &cancellation).failed.cause);
    try std.testing.expectEqual(error.InvalidOfficeRequest, run(std.testing.allocator, std.testing.io, "C:\\component", .selftest, context, 300_001, &cancellation).failed.cause);
}

test {
    if (builtin.os.tag == .windows) std.testing.refAllDecls(windows);
}
