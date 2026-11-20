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

const io = std.testing.io;
const allocator = std.testing.allocator;

const matching_identity: agent_link.Identity = .{
    .version = "fixture-0",
    .core_manifest_sha256 = @splat('1'),
    .core_abi_revision = 28,
};

const fixture_variable = "METAWORK_EXECUTION_LINK_FIXTURE";

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

/// Reads one whole frame the execution half sent. Only for the calls these
/// tests send by hand, which fit in one fragment.
fn readFrame(host: *execution_host.Host, buffer: []u8) !struct {
    kind: agent_link.Kind,
    correlation: u64,
    payload: []u8,
} {
    var header_bytes: [agent_link.frame.header_bytes]u8 = undefined;
    try host.reader.interface.readSliceAll(&header_bytes);
    const header = try agent_link.frame.decode(&header_bytes);
    if (!header.final or header.payload_len > buffer.len) return error.UnexpectedFrame;
    try host.reader.interface.readSliceAll(buffer[0..header.payload_len]);
    return .{ .kind = header.kind, .correlation = header.correlation, .payload = buffer[0..header.payload_len] };
}

test "the execution half answers a call from its own Runtime" {
    const fixture = try fixturePath();
    defer allocator.free(fixture);

    var host: execution_host.Host = undefined;
    const failure = try host.start(io, allocator, matching_identity, .{}, .{
        .explicit = &.{ fixture, "--with-runtime" },
    });
    if (failure) |value| {
        std.debug.print("start failed: {any}\n", .{value});
        return error.StartFailed;
    }
    defer host.deinit();

    const request = try agent_link.rpc.encodeRequest(.restore_admission, allocator, 0, .{ .releasing_route_id = null });
    defer allocator.free(request);
    try std.testing.expectEqual(agent_link.channel.Submission.queued, try host.outbound.submitWaiting(.request, 7, request));

    var buffer: [64]u8 = undefined;
    const received = try readFrame(&host, &buffer);
    try std.testing.expectEqual(agent_link.Kind.response, received.kind);
    try std.testing.expectEqual(@as(u64, 7), received.correlation);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const answer = try agent_link.rpc.decodeResponse(.restore_admission, arena.allocator(), received.payload);
    try std.testing.expectEqual(@TypeOf(answer.ok).available, answer.ok);

    // An orderly end: the Runtime shuts down and the process leaves on its
    // own, with the code that says so.
    try std.testing.expectEqual(
        execution_host.Stopped{ .exited = @intFromEnum(execution_mode.Exit.link_closed) },
        host.stop(),
    );
}

test "tidying up that does not finish costs the execution half its deadline, not its exit" {
    // Nothing the UI half holds can keep this process alive once the link
    // has ended: a Runtime whose shutdown never returns is the stand-in for
    // every way that could happen. The deadline is shorter than the UI's
    // grace period, so a process that left on its own reports the deadline's
    // code; one that had to be ended reports `.killed`.
    const fixture = try fixturePath();
    defer allocator.free(fixture);

    var host: execution_host.Host = undefined;
    const failure = try host.start(io, allocator, matching_identity, .{}, .{
        .explicit = &.{ fixture, "--with-runtime", "--hang-shutdown" },
    });
    if (failure) |value| {
        std.debug.print("start failed: {any}\n", .{value});
        return error.StartFailed;
    }
    defer host.deinit();

    try std.testing.expectEqual(
        execution_host.Stopped{ .exited = @intFromEnum(execution_mode.Exit.exit_deadline) },
        host.stop(),
    );
}

test "a child that ignores end of stream is ended, and the stop returns" {
    // The reaper waits on the child for its whole life, so ending the child
    // must not wait on it a second time. On POSIX `std.process.Child.kill`
    // did exactly that and the loser of the two `wait4` calls panicked with
    // ECHILD in Debug; `terminate` only sends the signal and the reaper
    // collects what it ends. Bounded by the grace period, so a regression
    // that leaves the child running fails on the assertion below.
    const fixture = try fixturePath();
    defer allocator.free(fixture);

    var host: execution_host.Host = undefined;
    const failure = try host.start(
        io,
        allocator,
        matching_identity,
        .{},
        .{ .explicit = &.{ fixture, "--ignore-eof" } },
    );
    if (failure) |value| {
        std.debug.print("start failed: {any}\n", .{value});
        return error.StartFailed;
    }
    defer host.deinit();

    try std.testing.expectEqual(execution_host.Stopped.killed, host.stop());
    // The reaper has collected it: the stop joined the thread that waits.
    try std.testing.expect(host.term != null);
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
