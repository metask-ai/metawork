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
//! peer built from different sources. `METAWORK_EXEC_LINK_FAULT_ROOT` gives it
//! a data root to record a process-level fault under; the application resolves
//! that root from the environment instead, which is a fact about the
//! installation rather than something this half should go looking for.

const std = @import("std");

const execution_half = @import("app_execution_half");
const agent_link = @import("metawork_agent_link");

pub fn main(init: std.process.Init) !void {
    const version = init.environ_map.get("METAWORK_EXEC_LINK_VERSION") orelse "fixture-0";
    const digest_text = init.environ_map.get("METAWORK_EXEC_LINK_DIGEST") orelse "11";
    var digest: [32]u8 = @splat(0);
    @memset(&digest, digest_text[0]);

    const exit = execution_half.run(init.io, init.gpa, .{
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
        .fault = if (init.environ_map.get("METAWORK_EXEC_LINK_FAULT_ROOT")) |root| .{
            .identity = .{
                .version = version,
                .artifact_kind = .development,
                .core_manifest_sha256 = digest,
                .core_abi_revision = 28,
            },
            .data_root = root,
        } else null,
    });
    std.process.exit(@intFromEnum(exit));
}

comptime {
    // The fixture must not drift from the entry it stands in for.
    std.debug.assert(@TypeOf(execution_half.run) == fn (
        std.Io,
        std.mem.Allocator,
        execution_half.Options,
    ) execution_half.Exit);
    std.debug.assert(agent_link.revision > 0);
}
