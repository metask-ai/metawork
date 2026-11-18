//! Application-only registration of blocking Select arms. Every arm needs a
//! concurrency guarantee; async may run inline before its peers are registered.
const std = @import("std");

pub fn start(selection: anytype, arms: anytype) std.Io.ConcurrentError!void {
    return startWithCleanup(selection, arms, discard, .{selection});
}

/// Cleanup runs only on partial/failed registration, before returning the error.
/// Callers that own resources in results or require an actuator before joining
/// provide their existing cleanup here. Result arbitration stays with the caller.
pub fn startWithCleanup(
    selection: anytype,
    arms: anytype,
    comptime cleanup: anytype,
    cleanup_args: anytype,
) std.Io.ConcurrentError!void {
    errdefer @call(.auto, cleanup, cleanup_args);
    inline for (arms) |arm| try selection.concurrent(arm[0], arm[1], arm[2]);
}

fn discard(selection: anytype) void {
    selection.cancelDiscard();
}

test "registration failure joins started arms and disposes completed resources" {
    const Fixture = struct {
        const Outcome = union(enum) { resource: usize, waiting: void, deadline: void };
        var registered: usize = 0;
        var fail_at: usize = 0;
        var produced: std.Io.Event = .unset;
        var disposed: usize = 0;
        var exited: std.atomic.Value(bool) = .init(false);

        fn concurrent(userdata: ?*anyopaque, group: *std.Io.Group, context: []const u8, alignment: std.mem.Alignment, run: *const fn (*const anyopaque) void) std.Io.ConcurrentError!void {
            const index = registered;
            registered += 1;
            if (index == fail_at) {
                if (index > 0) produced.waitUncancelable(std.testing.io);
                return error.ConcurrencyUnavailable;
            }
            return std.testing.io.vtable.groupConcurrent(userdata, group, context, alignment, run);
        }

        fn resource() usize {
            produced.set(std.testing.io);
            return 42;
        }

        fn wait() void {
            defer exited.store(true, .release);
            std.Io.sleep(std.testing.io, .fromSeconds(60), .awake) catch {};
        }

        fn cleanup(selection: *std.Io.Select(Outcome)) void {
            while (selection.cancel()) |outcome| switch (outcome) {
                .resource => |value| disposed += value,
                else => {},
            };
        }
    };
    for (0..3) |fail_at| {
        Fixture.registered = 0;
        Fixture.fail_at = fail_at;
        Fixture.produced = .unset;
        Fixture.disposed = 0;
        Fixture.exited.store(false, .release);
        var vtable = std.testing.io.vtable.*;
        vtable.groupConcurrent = Fixture.concurrent;
        const io: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
        var outcomes: [3]Fixture.Outcome = undefined;
        var selection = std.Io.Select(Fixture.Outcome).init(io, &outcomes);
        try std.testing.expectError(error.ConcurrencyUnavailable, startWithCleanup(&selection, .{
            .{ .resource, Fixture.resource, .{} },
            .{ .waiting, Fixture.wait, .{} },
            .{ .deadline, Fixture.wait, .{} },
        }, Fixture.cleanup, .{&selection}));
        try std.testing.expectEqual(fail_at + 1, Fixture.registered);
        try std.testing.expectEqual(@as(usize, if (fail_at > 0) 42 else 0), Fixture.disposed);
        if (fail_at == 2) try std.testing.expect(Fixture.exited.load(.acquire));
    }
}
