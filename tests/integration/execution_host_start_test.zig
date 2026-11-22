//! A start that fails after the link's pipe ends have become the host's own.
//!
//! This counts the process's open handles before and after, so it runs in a
//! test binary of its own: in the shared execution-link binary, threads other
//! tests leave behind -- a callback finishing, a reader seeing the end of a
//! stream -- open and close handles at moments this test cannot order
//! against, and a count taken there could move for reasons that have nothing
//! to do with the start under test.

const std = @import("std");
const builtin = @import("builtin");

const execution_host = @import("app_execution_host");
const agent_link = @import("metawork_agent_link");

const io = std.testing.io;
const allocator = std.testing.allocator;

const matching_identity: agent_link.Identity = .{
    .version = "fixture-0",
    .core_manifest_sha256 = @splat('1'),
    .core_abi_revision = 28,
};

const handshake_deadline_ms: u64 = 10_000;

fn fixturePath() ![]u8 {
    return std.process.Environ.getAlloc(std.testing.environ, allocator, "METAWORK_EXECUTION_LINK_FIXTURE");
}

extern "kernel32" fn GetProcessHandleCount(
    process: std.os.windows.HANDLE,
    count: *std.os.windows.DWORD,
) callconv(.winapi) std.os.windows.BOOL;

/// Handles (Windows) or file descriptors (POSIX) this process has open.
fn openHandles() !usize {
    if (builtin.os.tag == .windows) {
        var count: std.os.windows.DWORD = 0;
        if (GetProcessHandleCount(std.os.windows.GetCurrentProcess(), &count) == .FALSE)
            return error.HandleCountUnavailable;
        return count;
    }
    // The directory itself is one of the entries, in every count alike.
    var directory = try std.Io.Dir.openDirAbsolute(io, "/dev/fd", .{ .iterate = true });
    defer directory.close(io);
    var iterator = directory.iterate();
    var count: usize = 0;
    while (try iterator.next(io)) |_| count += 1;
    return count;
}

test "a start that cannot allocate after the pipes are its own leaves no handle open" {
    const fixture = try fixturePath();
    defer allocator.free(fixture);

    // One full start and stop first, so whatever the runtime opens once and
    // keeps is already open when the count is taken.
    {
        var host: execution_host.Host = undefined;
        const failure = try host.start(io, allocator, matching_identity, .{}, .{ .explicit = &.{fixture} }, handshake_deadline_ms);
        if (failure) |value| {
            std.debug.print("start failed: {any}\n", .{value});
            return error.StartFailed;
        }
        _ = host.stop();
        host.deinit();
    }

    const before = try openHandles();
    // The first allocation `start` makes from this allocator is the read
    // buffer, which comes after the child is spawned and the pipe ends taken.
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var host: execution_host.Host = undefined;
    try std.testing.expectError(error.OutOfMemory, host.start(
        io,
        failing.allocator(),
        matching_identity,
        .{},
        .{ .explicit = &.{fixture} },
        handshake_deadline_ms,
    ));
    try std.testing.expect(failing.has_induced_failure);
    const after = try openHandles();
    try std.testing.expectEqual(before, after);
}
