//! What the execution half owns, assembled in one place.
//!
//! `execution_mode.zig` is the link entry point and nothing else: it states an
//! identity, serves frames and exits. This is the layer above it -- the things
//! a process that may die without warning has to have in place *before* it
//! starts answering, and the things it answers *with*.
//!
//! It takes what it needs rather than resolving it. The application's
//! composition root resolves the data root and holds the build identity, and a
//! test fixture holds its own; neither fact is something this file should go
//! looking for, and a data root it accepted from a command line would be a
//! path redirect in the half that writes crash evidence.
//!
//! Why the fault record is here and not in `execution_mode.run`: this is the
//! half the isolation exists to survive. A crash whose record nobody wrote is
//! a crash nobody can attribute, which is most of what splitting the process
//! is supposed to buy -- and until this file existed, `fault.install` ran
//! after the fork in `app.run`, so the execution half had no handler at all.

const std = @import("std");

const agent_link = @import("metawork_agent_link");
const execution_mode = @import("app_execution_mode");
const fault = @import("app_fault");

pub const Exit = execution_mode.Exit;

/// Where this half records a process-level fault.
///
/// Both fields come from the caller because both are facts about the build and
/// the installation, which this half is a participant in rather than the owner
/// of. `role` is not among them: it is always `.exec` here, and letting a
/// caller pass it would let the two halves claim the same record file.
pub const FaultRecording = struct {
    identity: fault.Identity,
    /// Canonical data root. The record lands in `<data_root>/faults/`.
    data_root: []const u8,
};

pub const Options = struct {
    identity: agent_link.Identity,
    message_limits: agent_link.MessageLimits,
    queue_limits: agent_link.QueueLimits = .{},
    /// `null` records nothing, which is for a caller that has no data root to
    /// write into. It is never the production choice.
    fault: ?FaultRecording = null,
};

/// Composes this half and serves the link until it ends.
///
/// A failed fault install warns rather than refusing to start. That matches
/// what the UI half does for the same condition, and a process that would not
/// start because it could not create a diagnostic file turns a reporting gap
/// into an outage.
pub fn run(io: std.Io, allocator: std.mem.Allocator, options: Options) Exit {
    if (options.fault) |recording| fault.install(io, .{
        .role = .exec,
        .data_root = recording.data_root,
        .identity = recording.identity,
    }) catch |failure|
        std.log.warn("execution half fault capture unavailable: {s}", .{@errorName(failure)});

    return execution_mode.run(io, allocator, .{
        .identity = options.identity,
        .message_limits = options.message_limits,
        .queue_limits = options.queue_limits,
    });
}

test "the role this half records under is not the caller's to choose" {
    // `FaultRecording` carries the identity and the root and nothing else, so
    // a caller cannot ask for `.ui` and overwrite the record the other half
    // left. The two file names differ, which is what makes that matter.
    try std.testing.expect(!@hasField(FaultRecording, "role"));
    try std.testing.expect(!std.mem.eql(
        u8,
        fault.recordFileName(.ui),
        fault.recordFileName(.exec),
    ));
}
