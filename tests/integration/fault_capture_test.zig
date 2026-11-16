//! Parent side of the fault-capture regression: what only a child process can
//! prove.
//!
//! Everything here is read back through the real decoder, from a record only
//! the child's handler could have written, and every assertion is written to
//! fail rather than pass when the child misbehaves:
//!
//! * a child that exits cleanly, or never starts, fails -- the fixture path
//!   comes from the environment and a missing variable is an error, not a skip,
//!   and a missing record is `error.MissingFaultRecord`;
//! * a record left by any earlier process cannot be mistaken for this one's,
//!   because the parent mints a nonce per spawn and the child carries it in
//!   the record's version field;
//! * a child that faults somewhere other than where the scenario says is
//!   caught by the claim count and the breadcrumb set, which together pin how
//!   far it got.

const builtin = @import("builtin");
const std = @import("std");
const fault = @import("app_fault");
const fixture = @import("fault_capture_fixture");

const plan = fixture.plan;
const fixture_variable = "METAWORK_FAULT_CAPTURE_FIXTURE";

var nonce_counter: u64 = 0;

/// One per spawn: the child writes it into the record's version field, so a
/// record left by any earlier process is not this one's. Returned by value,
/// because a nonce has to outlive the next mint.
fn mintNonce() [plan.version_nonce_digits]u8 {
    nonce_counter += 1;
    const wall = std.Io.Timestamp.now(std.testing.io, .real);
    var storage: [plan.version_nonce_digits]u8 = undefined;
    const printed = std.fmt.bufPrint(&storage, "{x:0>16}", .{
        nonce_counter ^ @as(u64, @truncate(@as(u96, @bitCast(wall.nanoseconds)))),
    }) catch unreachable;
    std.debug.assert(printed.len == storage.len);
    return storage;
}

fn runFixture(root: []const u8, class: plan.Class, nonce: []const u8) !std.process.Child.Term {
    // A missing fixture is a misconfigured build entry, never a reason to pass.
    const path = try std.process.Environ.getAlloc(
        std.testing.environ,
        std.testing.allocator,
        fixture_variable,
    );
    defer std.testing.allocator.free(path);
    var environment = try std.process.Environ.createMap(
        std.testing.environ,
        std.testing.allocator,
    );
    defer environment.deinit();
    try environment.put(plan.root_variable, root);
    try environment.put(plan.nonce_variable, nonce);
    try environment.put(plan.class_variable, @tagName(class));
    const arguments = [_][]const u8{path};
    var child = try std.process.spawn(std.testing.io, .{
        .argv = &arguments,
        .stdin = .ignore,
        .stdout = .ignore,
        // A deliberate fault prints the standard library's own crash text on
        // the way out. Keep it out of the test log: the record is the evidence.
        .stderr = .ignore,
        .environ_map = &environment,
        .create_no_window = true,
    });
    return child.wait(std.testing.io);
}

fn expectFaulted(termination: std.process.Child.Term) !void {
    switch (termination) {
        .exited => |code| if (code == 0) return error.FixtureExitedWithoutFaulting,
        else => {},
    }
}

fn readRecord(root: []const u8, storage: *[fault.record_bytes]u8) !fault.Record {
    return fault.readRecord(std.testing.io, root, storage) orelse error.MissingFaultRecord;
}

fn expectFixtureIdentity(record: fault.Record, nonce: []const u8) !void {
    var version_storage: [64]u8 = undefined;
    try std.testing.expectEqualStrings(plan.version(&version_storage, nonce), record.version());
    try std.testing.expectEqual(fault.Role.ui, record.role);
    try std.testing.expectEqual(plan.artifact_kind, record.artifact_kind);
    try std.testing.expectEqual(plan.core_abi_revision, record.core_abi_revision);
    try std.testing.expectEqualSlices(
        u8,
        &plan.core_manifest_sha256,
        &record.core_manifest_sha256,
    );
    try std.testing.expectEqual(
        @as(fault.OsTag, if (builtin.os.tag == .windows) .windows else .macos),
        record.os_tag,
    );
    try std.testing.expectEqual(
        @as(fault.Arch, if (builtin.cpu.arch == .aarch64) .aarch64 else .x86_64),
        record.arch,
    );
    // The image identity is what makes the addresses resolvable offline.
    try std.testing.expect(record.module_base != 0);
    try std.testing.expect(record.module_bytes != 0);
    try std.testing.expect(record.debug_id_kind != .none);
    try std.testing.expect(!std.mem.allEqual(u8, &record.debug_id, 0));
}

/// The scenario, as the record has to show it: two Runs still executing, the
/// faulting thread identified as the one that was inside the first of them,
/// the newest churned Run still present and the oldest reused.
fn expectPlanBreadcrumbs(record: fault.Record) !void {
    const facts = record.fault orelse return error.MissingFaultFacts;
    // How far the child got. A fault anywhere earlier than the end of the
    // churn cannot produce this number.
    try std.testing.expectEqual(plan.expected_claims, record.breadcrumb_cursor);

    var interrupted_storage: [fault.breadcrumb_capacity]fault.Breadcrumb = undefined;
    const interrupted = record.interruptedRuns(&interrupted_storage);
    try std.testing.expectEqual(@as(usize, 2), interrupted.len);
    var long: ?fault.Breadcrumb = null;
    var second: ?fault.Breadcrumb = null;
    for (interrupted) |entry| {
        try std.testing.expect(entry.thread_id != 0);
        try std.testing.expect(entry.started_at_unix_ms > 1_700_000_000_000);
        if (entry.task_id == plan.long_task and entry.run_id == plan.long_run) long = entry;
        if (entry.task_id == plan.second_task and entry.run_id == plan.second_run) second = entry;
    }
    const live = long orelse return error.LongRunMissingFromRecord;
    const held = second orelse return error.SecondRunMissingFromRecord;
    // The correlation the whole feature exists for: the faulting thread names
    // the Run that was on it, and the Run held by another thread is not it.
    try std.testing.expectEqual(facts.thread_id, live.thread_id);
    try std.testing.expect(held.thread_id != facts.thread_id);

    var finished: usize = 0;
    var newest_churn = false;
    var oldest_churn = false;
    var retired = false;
    for (record.breadcrumbs) |entry| {
        switch (entry.phaseValue()) {
            .finished => finished += 1,
            .running => continue,
            // Nothing may be left mid-claim or stale once the child has
            // finished churning.
            else => return error.UnexpectedBreadcrumbPhase,
        }
        if (entry.task_id == plan.churn_task_base + plan.churn_runs - 1) newest_churn = true;
        if (entry.task_id == plan.churn_task_base) oldest_churn = true;
        if (entry.task_id == plan.retired_task) retired = true;
    }
    // Two slots belong to the live Runs for the whole churn, so the rest are
    // what the churn rotated through.
    try std.testing.expectEqual(fault.breadcrumb_capacity - 2, finished);
    try std.testing.expect(newest_churn);
    // The churn is three times the ring, so the first of its Runs and the Run
    // retired before it must both have been reused by now -- without which
    // this scenario would not be testing reuse at all.
    try std.testing.expect(!oldest_churn);
    try std.testing.expect(!retired);
}

test "a trapped child records its fault and the Runs it interrupted" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const nonce_storage = mintNonce();
    const nonce: []const u8 = &nonce_storage;

    try expectFaulted(try runFixture(root, .trap, nonce));

    var storage: [fault.record_bytes]u8 = undefined;
    const record = try readRecord(root, &storage);
    try expectFixtureIdentity(record, nonce);
    const facts = record.fault orelse return error.MissingFaultFacts;
    try std.testing.expectEqual(
        @as(fault.CaptureKind, if (builtin.os.tag == .windows)
            .windows_vectored_exception
        else
            .posix_signal),
        facts.kind,
    );
    try std.testing.expectEqual(
        @as(u32, if (builtin.os.tag == .windows) 0xc000001d else 5),
        facts.code,
    );
    // An undefined instruction faults in the image that executed it.
    try std.testing.expect(facts.ip >= record.module_base);
    try std.testing.expect(facts.ip < record.module_base + record.module_bytes);
    try std.testing.expect(facts.at_unix_ms >= record.process_started_at_unix_ms);
    try std.testing.expectEqual(@as(u8, 1), facts.attempts);
    try expectPlanBreadcrumbs(record);
}

test "an aborting child reaches the signal handler the vectored one never sees" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const nonce_storage = mintNonce();
    const nonce: []const u8 = &nonce_storage;

    try expectFaulted(try runFixture(root, .abort, nonce));

    var storage: [fault.record_bytes]u8 = undefined;
    const record = try readRecord(root, &storage);
    try expectFixtureIdentity(record, nonce);
    const facts = record.fault orelse return error.MissingFaultFacts;
    try std.testing.expectEqual(fault.CaptureKind.abort_signal, facts.kind);
    // SIGABRT: 22 in the Windows C runtime, 6 everywhere else.
    try std.testing.expectEqual(
        @as(u32, if (builtin.os.tag == .windows) 22 else 6),
        facts.code,
    );
    try expectPlanBreadcrumbs(record);
}

test "the instance marker reports one unclean exit and then stops" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const report_path = try std.fs.path.join(std.testing.allocator, &.{
        root,
        fault.directory_name,
        fault.report_file_name,
    });
    defer std.testing.allocator.free(report_path);

    // A first clean start has nothing to report.
    const first = mintNonce();
    try std.testing.expectEqual(
        std.process.Child.Term{ .exited = 0 },
        try runFixture(root, .clean, &first),
    );
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().statFile(std.testing.io, report_path, .{}),
    );

    // The crash leaves the marker behind, because only a clean exit clears it.
    const crashed_nonce = mintNonce();
    try expectFaulted(try runFixture(root, .trap, &crashed_nonce));

    // The next start finds it, and says which Task died with it.
    const reporting = mintNonce();
    try std.testing.expectEqual(
        std.process.Child.Term{ .exited = 0 },
        try runFixture(root, .clean, &reporting),
    );
    const report = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        report_path,
        std.testing.allocator,
        .limited(16 * 1024),
    );
    defer std.testing.allocator.free(report);
    try std.testing.expect(std.mem.indexOf(u8, report, "did not exit cleanly") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "(the faulting thread)") != null);
    var expected_run: [64]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, report, try std.fmt.bufPrint(
        &expected_run,
        "Task {d} Run {d}",
        .{ plan.long_task, plan.long_run },
    )) != null);
    var expected_version: [64]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(
        u8,
        report,
        plan.version(&expected_version, &crashed_nonce),
    ) != null);

    // And that start exited cleanly, so the start after it reports nothing.
    try std.Io.Dir.cwd().deleteFile(std.testing.io, report_path);
    const last = mintNonce();
    try std.testing.expectEqual(
        std.process.Child.Term{ .exited = 0 },
        try runFixture(root, .clean, &last),
    );
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().statFile(std.testing.io, report_path, .{}),
    );
}
