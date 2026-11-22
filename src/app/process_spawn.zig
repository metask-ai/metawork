//! The one boundary every process the window creates goes through.
//!
//! A spawn creates the child's ends of its pipes in the window first, and
//! for a moment they are ends any other process the window starts at the
//! same time would take with it:
//!
//!   * On Windows `std.process.spawn` creates them inheritable and calls
//!     `CreateProcessW` with handle inheritance on and no handle list, so the
//!     new process inherits every inheritable handle the window holds.
//!   * On POSIX std creates them close-on-exec, which is only safe if the
//!     flag is there from the start. Darwin has no `pipe2`, so std makes the
//!     pipe and then sets close-on-exec with a second call; a fork on another
//!     thread between the two keeps both ends in its child.
//!
//! A child that holds another process's pipe end keeps that pipe open after
//! its owner dies: the reader of the execution link never sees end of
//! stream, and a write to a terminated child never fails.
//!
//! Every such window opens and closes inside `std.process.spawn` -- the
//! child-side ends are made at its start and closed before it returns -- so
//! one lock around the whole call closes it, on every platform. The lock
//! covers nothing else: no activation, I/O or waiting on the child.
//!
//! It is one boundary only if every spawn the window makes takes it, which is
//! why this is a module of its own: the MCP stdio transport and the execution
//! host both import this one instance. It does not reach process creation the
//! window does not make itself -- the Native SDK's web view runtime, or
//! AgentCore, which runs in the execution process.

const builtin = @import("builtin");
const std = @import("std");

var mutex: std.Io.Mutex = .init;

pub fn spawn(io: std.Io, options: std.process.SpawnOptions) std.process.SpawnError!std.process.Child {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    if (builtin.is_test) if (testing.observer) |hook| hook.call_fn(hook.context);
    return std.process.spawn(io, options);
}

pub const testing = struct {
    pub const Hook = struct {
        context: ?*anyopaque,
        call_fn: *const fn (?*anyopaque) void,
    };

    /// Tests only: called inside the boundary, before each spawn. A spawn
    /// site that bypasses this module never calls it.
    pub var observer: ?Hook = null;

    /// Whether the boundary is held right now.
    pub fn held() bool {
        if (mutex.tryLock()) {
            mutex.unlock(std.testing.io);
            return false;
        }
        return true;
    }
};

test "a spawn runs inside the boundary" {
    const Observer = struct {
        calls: u32 = 0,
        held: bool = false,

        fn call(context: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            self.held = testing.held();
        }
    };
    var observer: Observer = .{};
    testing.observer = .{ .context = &observer, .call_fn = Observer.call };
    defer testing.observer = null;

    // The executable does not exist: the spawn fails, and still went through
    // the boundary first.
    if (spawn(std.testing.io, .{
        .argv = &.{"metawork-process-spawn-missing-7c1d"},
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    })) |child| {
        var started = child;
        started.kill(std.testing.io);
        return error.TestUnexpectedResult;
    } else |_| {}
    try std.testing.expectEqual(@as(u32, 1), observer.calls);
    try std.testing.expect(observer.held);
    // And it is released afterwards.
    try std.testing.expect(!testing.held());
}
