//! The execution process, started for real.
//!
//! Everything here needs a second process, so none of it belongs in a unit
//! test: a spawn that fails, an identity exchange over inherited pipes, a
//! child that exits on end-of-stream, and a refusal that must leave no running
//! peer behind. A missing fixture fails the run rather than skipping it, for
//! the same reason the fault-capture fixture does: a silently skipped
//! cross-process test is indistinguishable from a passing one.

const std = @import("std");

const execution_host = @import("app_execution_host");
const execution_mode = @import("app_execution_mode");
const agent_link = @import("metawork_agent_link");
const fault = @import("app_fault");

const io = std.testing.io;
const allocator = std.testing.allocator;

const matching_identity: agent_link.Identity = .{
    .version = "fixture-0",
    .core_manifest_sha256 = @splat('1'),
    .core_abi_revision = 28,
};

const fixture_variable = "METAWORK_EXECUTION_LINK_FIXTURE";
const fault_root_variable = "METAWORK_EXEC_LINK_FAULT_ROOT";

/// A missing fixture is a misconfigured build entry, never a reason to pass.
fn fixturePath() ![]u8 {
    return std.process.Environ.getAlloc(std.testing.environ, allocator, fixture_variable);
}

test "the execution half starts, agrees on identity and exits on end of stream" {
    const fixture = try fixturePath();
    defer allocator.free(fixture);

    var host: execution_host.Host = undefined;
    const failure = try host.start(
        io,
        allocator,
        matching_identity,
        .{},
        .{ .explicit = &.{fixture} },
    );
    if (failure) |value| {
        std.debug.print("start failed: {any}\n", .{value});
        return error.StartFailed;
    }
    defer host.deinit();

    // The peer states the same four facts, and the role it claims is the one
    // the UI half expects rather than whatever it says it is.
    try std.testing.expectEqual(agent_link.Role.exec, host.peer.role);
    try std.testing.expectEqual(agent_link.revision, host.peer.revision);
    try std.testing.expectEqual(@as(u16, 28), host.peer.core_abi_revision);
    try std.testing.expectEqualStrings("fixture-0", host.peer.version());

    // Closing our end is the child's exit signal, so a clean stop needs no
    // kill and the child's own status comes back.
    const stopped = host.stop();
    try std.testing.expectEqual(
        execution_host.Stopped{ .exited = @intFromEnum(execution_mode.Exit.link_closed) },
        stopped,
    );
}

test "the execution half installs its own fault record, under its own name" {
    // The half the isolation exists to survive is the one whose crash record
    // matters, and until this ran `fault.install` happened after the fork in
    // `app.run` -- so the execution half had no handler at all. A unit test
    // can check the file names; only a real child can show that the install
    // succeeded in the process that has no window and no data root of its own.
    const fixture = try fixturePath();
    defer allocator.free(fixture);
    const root = try std.process.Environ.getAlloc(std.testing.environ, allocator, fault_root_variable);
    defer allocator.free(root);

    // The root outlives one run of the suite, so both names start absent --
    // otherwise the assertion below would be about what an earlier run left
    // rather than about what this child wrote.
    var exec_storage: [4096]u8 = undefined;
    const exec_record = try recordPath(&exec_storage, root, fault.recordFileName(.exec));
    var ui_storage: [4096]u8 = undefined;
    const ui_record = try recordPath(&ui_storage, root, fault.recordFileName(.ui));
    std.Io.Dir.deleteFileAbsolute(io, exec_record) catch {};
    std.Io.Dir.deleteFileAbsolute(io, ui_record) catch {};

    var host: execution_host.Host = undefined;
    const failure = try host.start(
        io,
        allocator,
        matching_identity,
        .{},
        .{ .explicit = &.{fixture} },
    );
    if (failure) |value| {
        std.debug.print("start failed: {any}\n", .{value});
        return error.StartFailed;
    }
    defer host.deinit();
    try std.testing.expectEqual(agent_link.Role.exec, host.peer.role);
    _ = host.stop();

    // The record file the execution role writes is there, and the one the UI
    // role writes is not: the role picks the file, so one half's later fault
    // cannot erase the other's evidence.
    const written = try std.Io.Dir.openFileAbsolute(io, exec_record, .{});
    written.close(io);
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.openFileAbsolute(io, ui_record, .{}),
    );
}

fn recordPath(storage: []u8, root: []const u8, name: []const u8) ![]const u8 {
    return std.fmt.bufPrint(storage, "{s}{c}{s}{c}{s}", .{
        root,
        std.fs.path.sep,
        fault.directory_name,
        std.fs.path.sep,
        name,
    });
}

test "a peer built from other sources is refused, and does not keep running" {
    const fixture = try fixturePath();
    defer allocator.free(fixture);

    var host: execution_host.Host = undefined;
    var skewed = matching_identity;
    skewed.version = "0.0.0-other";
    const failure = try host.start(
        io,
        allocator,
        skewed,
        .{},
        .{ .explicit = &.{fixture} },
    );
    const value = failure orelse {
        _ = host.stop();
        host.deinit();
        return error.ExpectedRefusal;
    };
    // The field that differs is named, and nothing is negotiated around it.
    try std.testing.expectEqual(
        execution_host.StartFailure{ .refused = .{ .refused = .product_version } },
        value,
    );
    // `start` kills the child on a refused identity, so there is nothing left
    // holding the pipes. A second refusal in a row must behave identically.
    const again = try host.start(
        io,
        allocator,
        skewed,
        .{},
        .{ .explicit = &.{fixture} },
    );
    try std.testing.expect(again != null);
}

test "an executable that is not there is a start failure, not a hang" {
    var host: execution_host.Host = undefined;
    const failure = try host.start(
        io,
        allocator,
        matching_identity,
        .{},
        .{ .explicit = &.{"metawork-no-such-execution-half"} },
    );
    try std.testing.expectEqual(
        execution_host.StartFailure.spawn_failed,
        failure orelse return error.ExpectedFailure,
    );
}

test "the child refuses us too, rather than serving a peer it cannot match" {
    // The same skew seen from the other side: the fixture states a version the
    // UI half does not have, so the fixture's own comparison fails and it
    // exits with its identity-refused code instead of serving frames.
    const fixture = try fixturePath();
    defer allocator.free(fixture);

    var child = try std.process.spawn(io, .{
        .argv = &.{fixture},
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
    });
    const to_child = child.stdin.?;
    const from_child = child.stdout.?;
    child.stdin = null;
    child.stdout = null;
    defer from_child.close(io);

    const read_buffer = try allocator.alloc(u8, 4096);
    defer allocator.free(read_buffer);
    var reader = from_child.readerStreaming(io, read_buffer);

    var skewed = matching_identity;
    skewed.version = "0.0.0-other";
    const outcome = try agent_link.exchangeIdentityDetailed(
        io,
        to_child,
        &reader.interface,
        .ui,
        skewed,
    );
    // Our side refuses the fixture's version.
    try std.testing.expectEqual(
        agent_link.Failure{ .refused = .product_version },
        outcome.failure,
    );
    to_child.close(io);
    const term = try child.wait(io);
    try std.testing.expectEqual(std.process.Child.Term{
        .exited = @intFromEnum(execution_mode.Exit.identity_refused),
    }, term);
}
