//! Stands in for the execution half of a split process.
//!
//! The real execution half is the application executable started with its mode
//! flag, and that executable carries the Renderer bundle. A test must not need
//! the bundle to check that the process starts, agrees on identity and stops,
//! so this fixture runs the same `execution_mode.run` the application forks
//! into, over the same inherited pipes.
//!
//! `METAWORK_EXEC_LINK_VERSION` overrides the version this half states, which
//! is how the test produces the skew that actually happens in the field: a
//! peer built from different sources.
//!
//! `--ignore-eof` makes it a child that does not leave when its link ends --
//! the wedged child a stop's grace period exists for.

const std = @import("std");

const execution_mode = @import("app_execution_mode");
const agent_link = @import("metawork_agent_link");

pub const ignore_eof_flag = "--ignore-eof";

fn hasFlag(init: std.process.Init, flag: []const u8) bool {
    var iterator = std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa) catch return false;
    defer iterator.deinit();
    _ = iterator.next();
    while (iterator.next()) |argument| if (std.mem.eql(u8, argument, flag)) return true;
    return false;
}

pub fn main(init: std.process.Init) !void {
    const ignore_eof = hasFlag(init, ignore_eof_flag);
    const version = init.environ_map.get("METAWORK_EXEC_LINK_VERSION") orelse "fixture-0";
    const digest_text = init.environ_map.get("METAWORK_EXEC_LINK_DIGEST") orelse "11";
    var digest: [32]u8 = @splat(0);
    @memset(&digest, digest_text[0]);

    const exit = execution_mode.run(init.io, init.gpa, .{
        .identity = .{
            .version = version,
            .core_manifest_sha256 = digest,
            .core_abi_revision = 28,
        },
        .message_limits = .{
            .event = 1 << 20,
            .request = 1 << 20,
            .response = 1 << 20,
            .ui_request = 1 << 16,
            .ui_response = 1 << 16,
        },
        .queue_limits = .{},
    });
    if (ignore_eof) while (true) {
        std.Io.sleep(init.io, .fromSeconds(1), .awake) catch {};
    };
    std.process.exit(@intFromEnum(exit));
}

comptime {
    // The fixture must not drift from the entry it stands in for.
    std.debug.assert(@TypeOf(execution_mode.run) == fn (
        std.Io,
        std.mem.Allocator,
        execution_mode.Options,
    ) execution_mode.Exit);
    std.debug.assert(agent_link.revision > 0);
}
