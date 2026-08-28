//! Narrow Application compatibility seam for app-instance coordination.
//!
//! Native SDK 0.9.2 has no single-instance or second-launch activation API.
//! This seam owns only the data-root lease, local transport, peer boundary,
//! and fixed pre-Runtime failure prompt. Application owns request semantics,
//! queuing, main-thread wake, and window effects.

const builtin = @import("builtin");
const std = @import("std");

const Platform = switch (builtin.os.tag) {
    .windows => @import("app_single_instance/windows.zig"),
    .macos => @import("app_single_instance/macos.zig"),
    else => struct {
        pub const Server = struct {
            pub fn init(
                _: std.mem.Allocator,
                _: []const u8,
                _: Handler,
            ) !@This() {
                return error.Unavailable;
            }
            pub fn stop(_: *@This()) void {}
            pub fn deinit(_: *@This()) void {}
        };
        pub fn forward(
            _: std.mem.Allocator,
            _: []const u8,
            _: []const u8,
            _: []u8,
        ) !usize {
            return error.Unavailable;
        }
        pub fn reportFailure(_: Failure) void {}
    },
};

pub const lock_file_name = ".metawork-instance.lock";
pub const max_transport_request_bytes: usize = 64 * 1024;
pub const max_transport_response_bytes: usize = 64;

pub const ForwardError = std.mem.Allocator.Error || error{
    InvalidFrame,
    EndpointUnavailable,
    TransferFailed,
    ResponseTimeout,
    SecurityUnavailable,
    EndpointNameTooLong,
    NoSpaceLeft,
    InvalidUtf8,
    Unavailable,
};

pub const Failure = enum {
    startup_failed,
    incompatible,
    primary_unresponsive,
    rejected,
};

pub const failure_messages = struct {
    pub const startup_failed =
        "MetaWork could not start. Try again. If the problem continues, check the application log.";
    pub const incompatible =
        "Another MetaWork version is already running. Quit it before opening this version.";
    pub const primary_unresponsive =
        "MetaWork is already running but could not be activated. Return to the running app or quit it and try again.";
    pub const rejected =
        "MetaWork is already running and rejected this launch request.";
};

pub fn failureMessage(failure: Failure) [:0]const u8 {
    return switch (failure) {
        .startup_failed => failure_messages.startup_failed,
        .incompatible => failure_messages.incompatible,
        .primary_unresponsive => failure_messages.primary_unresponsive,
        .rejected => failure_messages.rejected,
    };
}

pub const Handler = struct {
    state: *anyopaque,
    handle_fn: *const fn (*anyopaque, []const u8, []u8) usize,

    pub fn handle(self: Handler, request: []const u8, response: []u8) usize {
        return self.handle_fn(self.state, request, response);
    }
};

pub const LeaseResult = union(enum) {
    acquired: Lease,
    occupied,
};

pub const Lease = struct {
    io: std.Io,
    dir: std.Io.Dir,
    file: std.Io.File,

    pub fn deinit(self: *Lease) void {
        self.file.close(self.io);
        self.dir.close(self.io);
        self.* = undefined;
    }
};

pub fn tryAcquireLease(io: std.Io, canonical_data_root: []const u8) !LeaseResult {
    if (!std.fs.path.isAbsolute(canonical_data_root)) return error.InvalidDataRoot;
    const dir = std.Io.Dir.openDirAbsolute(io, canonical_data_root, .{
        .follow_symlinks = false,
    }) catch return error.DataRootUnavailable;
    errdefer dir.close(io);
    const file = openOrCreateLock(io, dir) catch |err| switch (err) {
        error.WouldBlock => return .occupied,
        else => return error.LeaseUnavailable,
    };
    return .{ .acquired = .{ .io = io, .dir = dir, .file = file } };
}

pub const Server = Platform.Server;

pub fn forward(
    allocator: std.mem.Allocator,
    canonical_data_root: []const u8,
    request: []const u8,
    response: []u8,
) ForwardError!usize {
    if (request.len == 0 or request.len > max_transport_request_bytes or
        response.len < max_transport_response_bytes)
        return error.InvalidFrame;
    return Platform.forward(
        allocator,
        canonical_data_root,
        request,
        response[0..max_transport_response_bytes],
    );
}

pub fn reportFailure(failure: Failure) void {
    Platform.reportFailure(failure);
}

fn openOrCreateLock(io: std.Io, dir: std.Io.Dir) !std.Io.File {
    const existing = dir.openFile(io, lock_file_name, .{
        .mode = .read_write,
        .lock = .exclusive,
        .lock_nonblocking = true,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (existing) |file| return file;
    return dir.createFile(io, lock_file_name, .{
        .read = true,
        .truncate = false,
        .exclusive = true,
        .lock = .exclusive,
        .lock_nonblocking = true,
        .permissions = privateFilePermissions(),
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.PathAlreadyExists => return dir.openFile(io, lock_file_name, .{
            .mode = .read_write,
            .lock = .exclusive,
            .lock_nonblocking = true,
            .follow_symlinks = false,
            .resolve_beneath = true,
        }),
        else => return err,
    };
}

fn privateFilePermissions() std.Io.File.Permissions {
    return if (builtin.os.tag == .windows) .default_file else .fromMode(0o600);
}

test "fixed failure categories distinguish startup from an existing primary" {
    try std.testing.expectEqualStrings(
        failure_messages.startup_failed,
        failureMessage(.startup_failed),
    );
    try std.testing.expectEqualStrings(
        failure_messages.primary_unresponsive,
        failureMessage(.primary_unresponsive),
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        failureMessage(.startup_failed),
        "already running",
    ) == null);
}

test "data-root lease rejects a second writer and recovers after close" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    var first = switch (try tryAcquireLease(std.testing.io, root)) {
        .acquired => |lease| lease,
        .occupied => return error.UnexpectedOccupiedLease,
    };
    try std.testing.expect((try tryAcquireLease(std.testing.io, root)) == .occupied);
    first.deinit();
    var second = switch (try tryAcquireLease(std.testing.io, root)) {
        .acquired => |lease| lease,
        .occupied => return error.UnexpectedOccupiedLease,
    };
    second.deinit();
}

test "selected platform transport surface is semantically complete" {
    std.testing.refAllDecls(Platform);
}

fn echoRequest(_: *anyopaque, request: []const u8, response: []u8) usize {
    if (response.len < request.len) return 0;
    @memcpy(response[0..request.len], request);
    return request.len;
}

test "local transport forwards one bounded frame to the primary" {
    if (builtin.os.tag != .windows and builtin.os.tag != .macos) return;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var marker: u8 = 0;
    var server = try Server.init(std.testing.allocator, root, .{
        .state = &marker,
        .handle_fn = echoRequest,
    });
    defer server.deinit();
    var response: [max_transport_response_bytes]u8 = undefined;
    const request = "activation-frame";
    const response_len = try forward(
        std.testing.allocator,
        root,
        request,
        &response,
    );
    try std.testing.expectEqualStrings(request, response[0..response_len]);
}

test "Windows listener stop always wakes an idle synchronous accept" {
    if (builtin.os.tag != .windows) return;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var marker: u8 = 0;
    for (0..64) |_| {
        var server = try Server.init(std.testing.allocator, root, .{
            .state = &marker,
            .handle_fn = echoRequest,
        });
        server.deinit();
    }
}
