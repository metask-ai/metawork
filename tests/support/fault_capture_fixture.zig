//! Child process for the fault-capture regression.
//!
//! `install` and its handlers cannot be exercised in a test binary: the
//! handlers are process-wide, so they would take the test runner's own faults,
//! and a test that crashes cannot report a result. The capability is therefore
//! verified the only way it can be -- a child that installs the handlers,
//! arranges a known set of Runs and then faults on purpose, with the parent
//! reading the record it left through the real decoder.
//!
//! The fixture is also the only place that proves the breadcrumb ring keeps a
//! long-lived Run with a real handler in the loop: it churns well past the
//! ring's capacity before faulting.

const std = @import("std");
const fault = @import("app_fault");

/// The scenario, shared with the parent so neither side can drift from it.
pub const plan = struct {
    /// Two Runs that are still executing when the fault lands, on two threads.
    pub const long_task: u64 = 101;
    pub const long_run: u64 = 7;
    pub const second_task: u64 = 202;
    pub const second_run: u64 = 9;
    /// One Run that finished before the fault.
    pub const retired_task: u64 = 303;
    pub const retired_run: u64 = 1;
    /// Short Runs started and finished while the two long ones stay live.
    /// Well past `breadcrumb_capacity`, which is the point: the ring may only
    /// reuse the slots those short Runs retire.
    pub const churn_runs: u64 = fault.breadcrumb_capacity * 2 + 5;
    pub const churn_task_base: u64 = 900;
    /// Claims this process attempts before it faults. The parent compares it
    /// against the record's cursor, which is how it knows the child reached
    /// the fault instead of dying somewhere earlier.
    pub const expected_claims: u64 = 3 + churn_runs;

    pub const artifact_kind: fault.ArtifactKind = .development;
    pub const core_abi_revision: u16 = 4242;
    pub const core_manifest_sha256 = fault.digestFromHex(
        "5a5b5c5d5e5f60616263646566676869" ++ "6a6b6c6d6e6f70717273747576777879",
    );
    /// The version string carries a nonce the parent generates per spawn, so a
    /// record left by any earlier process cannot be mistaken for this one's.
    pub const version_prefix = "fixture-";
    pub const version_nonce_digits = 16;

    pub const root_variable = "METAWORK_FAULT_FIXTURE_ROOT";
    pub const nonce_variable = "METAWORK_FAULT_FIXTURE_NONCE";
    pub const class_variable = "METAWORK_FAULT_FIXTURE_CLASS";
    pub const lock_file_name = ".metawork-instance.lock";

    /// What the child does once the Runs are in place.
    pub const Class = enum {
        /// `@trap()`: an undefined instruction, the class that reaches the
        /// Windows vectored handler and a POSIX signal with no predecessor.
        trap,
        /// The C runtime's `abort()`, the only caller that raises SIGABRT.
        abort,
        /// Exit cleanly, which must clear the marker.
        clean,
    };

    pub fn version(storage: *[64]u8, nonce: []const u8) []const u8 {
        return std.fmt.bufPrint(storage, version_prefix ++ "{s}", .{nonce}) catch unreachable;
    }
};

extern "c" fn abort() noreturn;

var second_claimed: std.atomic.Value(bool) = .init(false);

fn holdSecondRun(_: void) void {
    _ = fault.beginRun(plan.second_task, plan.second_run);
    second_claimed.store(true, .release);
    // The process dies under this thread's feet; nothing here may finish the
    // Run, because the record has to show it still executing.
    while (true) std.Thread.yield() catch {};
}

pub fn main(init: std.process.Init) !void {
    const root = init.environ_map.get(plan.root_variable) orelse return error.MissingDataRoot;
    const nonce = init.environ_map.get(plan.nonce_variable) orelse return error.MissingNonce;
    const class_name = init.environ_map.get(plan.class_variable) orelse return error.MissingClass;
    const class = std.meta.stringToEnum(plan.Class, class_name) orelse return error.UnknownClass;
    var version_storage: [64]u8 = undefined;

    try fault.install(init.io, .{
        .role = .ui,
        .data_root = root,
        .identity = .{
            .version = plan.version(&version_storage, nonce),
            .artifact_kind = plan.artifact_kind,
            .core_manifest_sha256 = plan.core_manifest_sha256,
            .core_abi_revision = plan.core_abi_revision,
        },
    });

    // The lease is taken the way `app_single_instance.openOrCreateLock` takes
    // it, including `follow_symlinks = false`, because that is the handle
    // shape the marker is written through on every launch after the first.
    const dir = try std.Io.Dir.openDirAbsolute(init.io, root, .{ .follow_symlinks = false });
    defer dir.close(init.io);
    const lease = lease: {
        if (dir.openFile(init.io, plan.lock_file_name, .{
            .mode = .read_write,
            .lock = .exclusive,
            .lock_nonblocking = true,
            .follow_symlinks = false,
            .resolve_beneath = true,
        })) |file| break :lease file else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        break :lease try dir.createFile(init.io, plan.lock_file_name, .{
            .read = true,
            .truncate = false,
            .exclusive = true,
            .lock = .exclusive,
            .lock_nonblocking = true,
            .resolve_beneath = true,
        });
    };
    defer lease.close(init.io);

    var record_storage: [fault.record_bytes]u8 = undefined;
    const previous: fault.PreviousRun = .{
        .record = fault.readRecord(init.io, root, &record_storage),
        .marker = fault.adoptInstanceMarker(lease, .{
            .role = .ui,
            .data_root = root,
            .identity = .{
                .version = plan.version(&version_storage, nonce),
                .artifact_kind = plan.artifact_kind,
                .core_manifest_sha256 = plan.core_manifest_sha256,
                .core_abi_revision = plan.core_abi_revision,
            },
        }),
    };
    var summary_storage: [8 * 1024]u8 = undefined;
    _ = fault.reportPreviousRun(init.io, root, previous, &summary_storage);

    const retired = fault.beginRun(plan.retired_task, plan.retired_run);
    fault.finishRun(retired, plan.retired_task, plan.retired_run);
    _ = fault.beginRun(plan.long_task, plan.long_run);
    const thread = try std.Thread.spawn(.{}, holdSecondRun, .{{}});
    thread.detach();
    while (!second_claimed.load(.acquire)) std.Thread.yield() catch {};

    // Churn past the ring: every one of these retires, so the ring has slots
    // to reuse, and it must reuse those rather than the two live Runs.
    var churned: u64 = 0;
    while (churned < plan.churn_runs) : (churned += 1) {
        const task_id = plan.churn_task_base + churned;
        const slot = fault.beginRun(task_id, 1);
        fault.finishRun(slot, task_id, 1);
    }

    switch (class) {
        .trap => @trap(),
        .abort => abort(),
        .clean => {
            fault.clearInstanceMarker(lease);
            return;
        },
    }
}
