//! The ports a caller drives an Agent Runtime and its Sessions through.
//!
//! Every value that retains a live Runtime or Session crosses here as a
//! context pointer plus a vtable, so a caller names the capability without
//! naming the implementation -- and therefore without the AgentCore archive
//! (`contract.zig` states that rule). The implementation in `agent_session`
//! fills these in; `session/port_impl.zig` is the only place that does.
//!
//! The method set is deliberately the one the caller already had: the same
//! names, the same arguments, the same error sets. This is a boundary, not a
//! redesign. Replacing the in-process implementation with one that forwards to
//! another process is then a matter of supplying different vtables.

const std = @import("std");
const session_control = @import("control.zig");
const surface = @import("surface.zig");
const multimodal = @import("multimodal.zig");
const catalog = @import("agent_catalog");
const mcp_catalog = @import("agent_mcp_catalog");
const checkpoint = @import("agent_checkpoint");
const checkpoint_restore = @import("agent_checkpoint_restore");
const event_pump = @import("event_pump");
const delivery = @import("agent_file_delivery");
const sdk = @import("metask_agentcore");
const generate_video = @import("../generate_video.zig");
const mcp_install = @import("../mcp_install.zig");

const Error = surface.Error;
const Allocating = Error || std.mem.Allocator.Error;

/// Agent-side restore capability the caller only retains and hands back. Its
/// lifetime ends through `RuntimePort.releaseSkillRestoreInputs`; the
/// implementation owns what it points at.
pub const SkillRestoreInputs = opaque {};

/// What a captured skill capability grants, read back without taking it.
pub const SkillRestoreBorrow = struct {
    catalog: *catalog.Lease,
    policy: surface.SkillPolicyInput,
};

/// Handles issued by one Agent Runtime. The value names the port it came
/// from because its parts can only be released there, and the holder is not
/// always somewhere a port is otherwise in reach. This belongs here rather
/// than in `surface.zig`: it is a capability reference, not plain data.
pub const SessionRestoreInputs = struct {
    agent: RuntimePort,
    skill: ?*SkillRestoreInputs,
    mcp: ?*mcp_catalog.RestoreSelection,
    permission_mode: session_control.PermissionMode,
    shell_policy: session_control.ShellPolicy,
    permission_interaction: surface.PermissionInteraction,

    /// Releases every part. The value is consumed.
    pub fn release(self: *SessionRestoreInputs) Error!void {
        return self.agent.releaseRestoreInputs(self);
    }
};

pub const SessionRoute = struct {
    id: u64,
    session: SessionPort,
};

pub const SessionRestoreRoute = struct {
    id: u64,
    session: SessionPort,
    report: checkpoint_restore.Report,
};

pub const BeginRunOutcome = union(enum) {
    run: RunPort,
    failure: surface.BeginRunFailure,

    /// A Run that could not be begun because the link is gone is a failure.
    /// Handing back a `run` would give the caller a Run nothing is executing.
    pub const link_unreachable: std.meta.Tag(@This()) = .failure;

    /// A Run that could not be begun for want of room is a failure too, and
    /// in the same arm: the `err` inside it is what says whether asking
    /// again is worth anything.
    pub const link_busy: std.meta.Tag(@This()) = .failure;
};

/// A Run handed to its executor. `execute` blocks until the Run reaches a
/// terminal, which is why the executing thread has to live beside the
/// implementation rather than beside the caller.
///
/// The Run's own identity stays inline, exactly as it did when this was a
/// plain struct holding a Session pointer: nothing here is allocated, and
/// `deinit` still releases the base lease and nothing else.
pub const RunPort = struct {
    context: ?*anyopaque,
    vtable: *const VTable,
    run_id: u64,
    generation: u64,
    base_lease: RunControlLease,
    executed: bool = false,

    pub const VTable = struct {
        execute: *const fn (?*anyopaque, u64, u64) session_control.TerminalResult,
    };

    pub fn control(self: *const RunPort) RunControl {
        return self.base_lease.control;
    }

    pub fn execute(self: *RunPort) session_control.TerminalResult {
        std.debug.assert(!self.executed);
        self.executed = true;
        return self.vtable.execute(self.context, self.run_id, self.generation);
    }

    pub fn deinit(self: *RunPort) void {
        std.debug.assert(self.executed);
        self.base_lease.deinit();
        self.* = undefined;
    }
};

/// A Run's control handle. Acquiring a lease is what keeps the Session alive
/// across the call, so the retain/release pair stays with the implementation
/// and only the five operations cross.
pub const RunControl = struct {
    context: ?*anyopaque = null,
    vtable: ?*const VTable = null,
    run_id: u64 = 0,
    generation: u64 = 0,

    pub const VTable = struct {
        try_retain: *const fn (?*anyopaque) bool,
        release: *const fn (?*anyopaque) void,
        submit_input: *const fn (?*anyopaque, u64, u64, u64, []const u8) session_control.InputSubmission,
        input_observation: *const fn (?*anyopaque, u64, u64) ?session_control.InputObservation,
        request_termination: *const fn (?*anyopaque, u64, u64, session_control.TerminationSignal) session_control.TerminationRequestResult,
    };

    pub fn tryAcquireLease(self: RunControl) ?RunControlLease {
        const vtable = self.vtable orelse return null;
        if (!vtable.try_retain(self.context)) return null;
        return .{ .control = self };
    }

    /// A control handle whose far side cannot be reached, so that the branch
    /// each caller writes for that case actually runs.
    ///
    /// Its answers are the declared ones rather than hand-picked: the
    /// termination result is `TerminationRequestResult.link_unreachable` and
    /// the submission is `InputSubmission`'s, so this fixture cannot drift
    /// apart from what the link answers.
    pub fn testUnreachable(run_id: u64, generation: u64) RunControl {
        std.debug.assert(@import("builtin").is_test);
        return .{
            .context = null,
            .vtable = &unreachable_vtable,
            .run_id = run_id,
            .generation = generation,
        };
    }

    const unreachable_vtable: VTable = .{
        // Retaining succeeds. A caller that could not take the lease stops one
        // line earlier and never reaches the answers below, and those answers
        // are the point of this fixture.
        .try_retain = struct {
            fn call(_: ?*anyopaque) bool {
                return true;
            }
        }.call,
        .release = struct {
            fn call(_: ?*anyopaque) void {}
        }.call,
        .submit_input = struct {
            fn call(_: ?*anyopaque, _: u64, _: u64, _: u64, _: []const u8) session_control.InputSubmission {
                return @unionInit(
                    session_control.InputSubmission,
                    @tagName(session_control.InputSubmission.link_unreachable),
                    {},
                );
            }
        }.call,
        .input_observation = struct {
            fn call(_: ?*anyopaque, _: u64, _: u64) ?session_control.InputObservation {
                return null;
            }
        }.call,
        .request_termination = struct {
            fn call(
                _: ?*anyopaque,
                _: u64,
                _: u64,
                _: session_control.TerminationSignal,
            ) session_control.TerminationRequestResult {
                return session_control.TerminationRequestResult.link_unreachable;
            }
        }.call,
    };
};

/// A retained Agent control reference. This is a linear value: callers must
/// not copy it and must call `deinit` exactly once.
pub const RunControlLease = struct {
    control: RunControl,
    released: bool = false,

    pub fn submitInput(self: *const RunControlLease, input_id: u64, text: []const u8) session_control.InputSubmission {
        std.debug.assert(!self.released);
        return self.control.vtable.?.submit_input(
            self.control.context,
            self.control.run_id,
            self.control.generation,
            input_id,
            text,
        );
    }

    /// `null` when no observation could be made at all, because the far side
    /// is unreachable.
    ///
    /// Deliberately not an empty observation. Its fields point opposite ways:
    /// a caller reading `ready` treats a zeroed value as not ready, which
    /// restricts, while a caller reading `blocksAutomaticAllow` reads the same
    /// zeroed value as nothing blocking, which releases automatic approval. No
    /// default value is safe for both, and no added field makes one safe, so
    /// the absence is handed to the caller and each one says which side it
    /// chose.
    pub fn inputObservation(self: *const RunControlLease) ?session_control.InputObservation {
        std.debug.assert(!self.released);
        return self.control.vtable.?.input_observation(
            self.control.context,
            self.control.run_id,
            self.control.generation,
        );
    }

    pub fn requestTermination(
        self: *const RunControlLease,
        signal: session_control.TerminationSignal,
    ) session_control.TerminationRequestResult {
        std.debug.assert(!self.released);
        return self.control.vtable.?.request_termination(
            self.control.context,
            self.control.run_id,
            self.control.generation,
            signal,
        );
    }

    pub fn deinit(self: *RunControlLease) void {
        std.debug.assert(!self.released);
        self.released = true;
        self.control.vtable.?.release(self.control.context);
    }
};
/// What cancelling a compact can refuse with.
///
/// The two Session-side members are the implementation's own. The last two
/// are the link's, and they are here rather than reused from `surface.Error`
/// because this method's set is deliberately narrow:
/// `src/product/task/runtime.zig` switches on it exhaustively, which is the
/// whole value of a narrow set, and a method that can be called across a
/// process boundary has to be able to say that the boundary is gone -- and,
/// separately, that the call was not performed and can be made again. Neither
/// member means either one -- `NoSuchCompact` would claim the compact was
/// already over, `SessionClosing` that the Session is winding down -- and the
/// exhaustive switch is what makes the caller say which side it chooses
/// instead of inheriting one. The two link members must stay apart here most
/// of all: this is the method whose `DependencyUnreachable` makes Product
/// stop following the compact, so answering it for a full queue would
/// abandon a compact that is still running.
pub const CompactCancellation = error{
    NoSuchCompact,
    SessionClosing,
    DependencyUnreachable,
    LinkBusy,
};

pub const SessionPort = struct {
    context: ?*anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        retain_reference: *const fn (?*anyopaque) bool,
        release_reference: *const fn (?*anyopaque) void,
        stop_event_delivery: *const fn (?*anyopaque) void,
        close_outcome: *const fn (?*anyopaque, session_control.ExternalInterruption) surface.CloseOutcome,
        refresh_skill_catalog: *const fn (?*anyopaque, *catalog.Lease, surface.SkillPolicyInput) Allocating!void,
        set_model: *const fn (?*anyopaque, []const u8) Error!void,
        clear_skill_policy: *const fn (?*anyopaque) Allocating!void,
        skill_policy_matches: *const fn (?*anyopaque, *catalog.Lease, surface.SkillPolicyInput) bool,
        capture_restore_inputs: *const fn (?*anyopaque) Allocating!SessionRestoreInputs,
        snapshot: *const fn (?*anyopaque) surface.SessionSnapshot,
        update_permission_mode: *const fn (?*anyopaque, session_control.PermissionMode, session_control.PermissionMode) Error!surface.PermissionModeUpdate,
        conversation_bounds: *const fn (?*anyopaque) Error!surface.ConversationBounds,
        rewind_to_user_message: *const fn (?*anyopaque, u64) Error!surface.RewindOutcome,
        update_credential: *const fn (?*anyopaque, []const u8) Error!void,
        request_termination: *const fn (?*anyopaque, u64, session_control.TerminationSignal) Error!void,
        prepare_run: *const fn (?*anyopaque, surface.RunInput) Allocating!u64,
        prepare_run_with_tools: *const fn (
            ?*anyopaque,
            surface.RunInput,
            ?surface.ImageGenerationRunInput,
            ?delivery.Input,
            ?mcp_install.Input,
            ?generate_video.Input,
        ) Allocating!u64,
        begin_run_outcome: *const fn (?*anyopaque, u64) BeginRunOutcome,
        cancel_prepared_run: *const fn (?*anyopaque, u64) Error!void,
        prepare_compact: *const fn (?*anyopaque) Allocating!u64,
        cancel_prepared_compact: *const fn (?*anyopaque, u64) Error!void,
        execute_prepared_compact: *const fn (?*anyopaque, u64) Error!session_control.CompactTerminalResult,
        request_compact_cancellation: *const fn (?*anyopaque, u64, session_control.ExternalInterruption) CompactCancellation!void,
        respond_permission: *const fn (?*anyopaque, u64, u64, sdk.protocol.PermissionChoice) Allocating!void,
        fail_ui_request_identity_contract: *const fn (?*anyopaque, u64) Error!void,
        pending_ui_observation: *const fn (?*anyopaque) ?PendingUiObservation,
        permission_stop_request: *const fn (?*anyopaque) ?u64,
        copy_pending_ui_request: *const fn (?*anyopaque, std.mem.Allocator) Allocating!surface.PendingUiRequest,
        export_checkpoint: *const fn (?*anyopaque, checkpoint.Limits, checkpoint.Sink, u64, u64, []const u8) Error!checkpoint.Outcome,
    };

    /// Bounded execution observation that exposes neither Session lifecycle
    /// nor external owner identity.
    pub const PendingUiObservation = struct {
        run_id: u64,
        request_id: u64,
        input_adopted_count: u32 = 0,
    };

    pub fn retainReference(self: SessionPort) bool {
        return self.vtable.retain_reference(self.context);
    }

    pub fn releaseReference(self: SessionPort) void {
        self.vtable.release_reference(self.context);
    }

    pub fn stopEventDelivery(self: SessionPort) void {
        self.vtable.stop_event_delivery(self.context);
    }

    pub fn closeOutcome(self: SessionPort, interruption: session_control.ExternalInterruption) surface.CloseOutcome {
        return self.vtable.close_outcome(self.context, interruption);
    }

    pub fn refreshSkillCatalog(self: SessionPort, lease: *catalog.Lease, skill_policy: surface.SkillPolicyInput) Allocating!void {
        return self.vtable.refresh_skill_catalog(self.context, lease, skill_policy);
    }

    pub fn setModel(self: SessionPort, model: []const u8) Error!void {
        return self.vtable.set_model(self.context, model);
    }

    pub fn clearSkillPolicy(self: SessionPort) Allocating!void {
        return self.vtable.clear_skill_policy(self.context);
    }

    pub fn skillPolicyMatches(self: SessionPort, lease: *catalog.Lease, policy: surface.SkillPolicyInput) bool {
        return self.vtable.skill_policy_matches(self.context, lease, policy);
    }

    pub fn captureRestoreInputs(self: SessionPort) Allocating!SessionRestoreInputs {
        return self.vtable.capture_restore_inputs(self.context);
    }

    pub fn snapshot(self: SessionPort) surface.SessionSnapshot {
        return self.vtable.snapshot(self.context);
    }

    pub fn updatePermissionMode(
        self: SessionPort,
        expected: session_control.PermissionMode,
        target: session_control.PermissionMode,
    ) Error!surface.PermissionModeUpdate {
        return self.vtable.update_permission_mode(self.context, expected, target);
    }

    /// The Conversation numbering a rewind position is expressed in. A caller
    /// submitting a Run input records that input's position as
    /// `message_count + 1`; see `surface.ConversationBounds`.
    pub fn conversationBounds(self: SessionPort) Error!surface.ConversationBounds {
        return self.vtable.conversation_bounds(self.context);
    }

    /// Drops the user message at `position` and everything after it. Only the
    /// Conversation changes: files and other effects of the dropped turns
    /// stay.
    ///
    /// Core keeps no record that this happened and starts no generation, so
    /// the caller's own history is the only place a rewind is ever written
    /// down. The refusals stay typed for the same reason: see
    /// `surface.RewindRefusal`.
    pub fn rewindToUserMessage(self: SessionPort, position: u64) Error!surface.RewindOutcome {
        return self.vtable.rewind_to_user_message(self.context, position);
    }

    pub fn updateCredential(self: SessionPort, credential: []const u8) Error!void {
        return self.vtable.update_credential(self.context, credential);
    }

    pub fn requestTermination(self: SessionPort, run_id: u64, signal: session_control.TerminationSignal) Error!void {
        return self.vtable.request_termination(self.context, run_id, signal);
    }

    pub fn prepareRun(self: SessionPort, input: surface.RunInput) Allocating!u64 {
        return self.vtable.prepare_run(self.context, input);
    }

    pub fn prepareRunWithTools(
        self: SessionPort,
        input: surface.RunInput,
        image_input: ?surface.ImageGenerationRunInput,
        delivery_input: ?delivery.Input,
        mcp_input: ?mcp_install.Input,
        video_input: ?generate_video.Input,
    ) Allocating!u64 {
        return self.vtable.prepare_run_with_tools(
            self.context,
            input,
            image_input,
            delivery_input,
            mcp_input,
            video_input,
        );
    }

    pub fn beginRunOutcome(self: SessionPort, run_id: u64) BeginRunOutcome {
        return self.vtable.begin_run_outcome(self.context, run_id);
    }

    pub fn cancelPreparedRun(self: SessionPort, run_id: u64) Error!void {
        return self.vtable.cancel_prepared_run(self.context, run_id);
    }

    pub fn prepareCompact(self: SessionPort) Allocating!u64 {
        return self.vtable.prepare_compact(self.context);
    }

    pub fn cancelPreparedCompact(self: SessionPort, operation_id: u64) Error!void {
        return self.vtable.cancel_prepared_compact(self.context, operation_id);
    }

    pub fn executePreparedCompact(self: SessionPort, operation_id: u64) Error!session_control.CompactTerminalResult {
        return self.vtable.execute_prepared_compact(self.context, operation_id);
    }

    pub fn requestCompactCancellation(
        self: SessionPort,
        operation_id: u64,
        interruption: session_control.ExternalInterruption,
    ) CompactCancellation!void {
        return self.vtable.request_compact_cancellation(self.context, operation_id, interruption);
    }

    pub fn respondPermission(
        self: SessionPort,
        run_id: u64,
        request_id: u64,
        choice: sdk.protocol.PermissionChoice,
    ) Allocating!void {
        return self.vtable.respond_permission(self.context, run_id, request_id, choice);
    }

    pub fn failUiRequestIdentityContract(self: SessionPort, run_id: u64) Error!void {
        return self.vtable.fail_ui_request_identity_contract(self.context, run_id);
    }

    pub fn pendingUiObservation(self: SessionPort) ?PendingUiObservation {
        return self.vtable.pending_ui_observation(self.context);
    }

    pub fn permissionStopRequest(self: SessionPort) ?u64 {
        return self.vtable.permission_stop_request(self.context);
    }

    pub fn copyPendingUiRequest(self: SessionPort, allocator: std.mem.Allocator) Allocating!surface.PendingUiRequest {
        return self.vtable.copy_pending_ui_request(self.context, allocator);
    }

    pub fn exportCheckpoint(
        self: SessionPort,
        limits: checkpoint.Limits,
        sink: checkpoint.Sink,
        expected_last_run_id: u64,
        expected_last_compact_id: u64,
        expected_model: []const u8,
    ) Error!checkpoint.Outcome {
        return self.vtable.export_checkpoint(
            self.context,
            limits,
            sink,
            expected_last_run_id,
            expected_last_compact_id,
            expected_model,
        );
    }
};

pub const RuntimePort = struct {
    context: ?*anyopaque,
    vtable: *const VTable,

    pub const RestoreAdmission = enum {
        available,
        capacity_reached,
        mcp_busy,
        unavailable,
        /// The question was not put to the runtime, and asking again is worth
        /// something.
        ///
        /// Not `capacity_reached`: that one is this runtime's own restore
        /// capacity, and Product turns it into `error.SessionCapacity` --
        /// a claim about the runtime that is false when the runtime is idle
        /// and the link's outbound queue is what filled.
        dependency_busy,

        /// Admitting a restore we cannot reach would hand the caller a
        /// Session that is not there, so the existing refusal is the answer.
        pub const link_unreachable: @This() = .unavailable;

        /// And a restore we could not even ask about is not admitted either,
        /// with the difference that this one is worth asking about again.
        pub const link_busy: @This() = .dependency_busy;
    };

    pub const VTable = struct {
        create_session_route: *const fn (?*anyopaque, surface.SessionOpenOptions) Allocating!SessionRoute,
        restore_session_route: *const fn (?*anyopaque, surface.SessionRestoreOptions) Allocating!SessionRestoreRoute,
        release_closed_session: *const fn (?*anyopaque, SessionPort) Error!void,
        take_event: *const fn (?*anyopaque) ?event_pump.OwnedCoreEvent,
        has_pending_events: *const fn (?*anyopaque) bool,
        pending_event_count: *const fn (?*anyopaque, u64) usize,
        notify_event_consumer: *const fn (?*anyopaque) session_control.EventReadyNotification,
        request_run_termination: *const fn (?*anyopaque, u64, u64, session_control.TerminationSignal) Error!void,
        restore_admission: *const fn (?*anyopaque, ?u64) RestoreAdmission,
        activate_mcp: *const fn (?*anyopaque) Allocating!surface.McpActivationOutcome,
        create_mcp_admission_selection: *const fn (
            ?*anyopaque,
            *const mcp_catalog.Activation,
            []const mcp_catalog.ServerAllowlist,
        ) Allocating!?*mcp_catalog.Selection,
        prepare_mcp_restore_selection: *const fn (
            ?*anyopaque,
            *const mcp_catalog.RestoreSelection,
            *const mcp_catalog.Activation,
            []const mcp_catalog.ActivationTool,
        ) Allocating!*mcp_catalog.Selection,
        query_skill_catalog: *const fn (?*anyopaque, catalog.Query) Allocating!catalog.Acquisition,
        release_skill_catalog: *const fn (?*anyopaque, *catalog.Lease) Error!void,
        /// Narrows a captured restore capability; the result is a new handle
        /// the caller owns.
        narrow_skill_restore_inputs: *const fn (?*anyopaque, *SkillRestoreInputs, surface.SkillPolicyInput) Allocating!*SkillRestoreInputs,
        clone_skill_restore_inputs: *const fn (?*anyopaque, *SkillRestoreInputs) Allocating!*SkillRestoreInputs,
        borrow_skill_restore_inputs: *const fn (?*anyopaque, *const SkillRestoreInputs) ?SkillRestoreBorrow,
        release_skill_restore_inputs: *const fn (?*anyopaque, *SkillRestoreInputs) Error!void,
        /// Releases what `SessionPort.captureRestoreInputs` handed out. The
        /// value is consumed; the caller must not release its parts itself.
        release_restore_inputs: *const fn (?*anyopaque, *SessionRestoreInputs) Error!void,
    };

    /// A Runtime with nothing in it: no events, nothing pending. Every other
    /// call is a programming error, and says so instead of reading an
    /// uninitialized implementation. Callers that genuinely have no Agent --
    /// a Control test that drives only projection, a Host that has not
    /// attached one yet -- bind this.
    pub const quiet: RuntimePort = .{ .context = null, .vtable = &quiet_vtable };

    /// `quiet`, except that the skill-restore borrow cannot be made, so that
    /// each caller's answer to an unreachable half actually runs.
    pub fn testUnreachableBorrow() RuntimePort {
        std.debug.assert(@import("builtin").is_test);
        return .{ .context = null, .vtable = &unreachable_borrow_vtable };
    }

    const unreachable_borrow_vtable: VTable = vtable: {
        var copy = quiet_vtable;
        copy.borrow_skill_restore_inputs = struct {
            fn call(_: ?*anyopaque, _: *const SkillRestoreInputs) ?SkillRestoreBorrow {
                return null;
            }
        }.call;
        break :vtable copy;
    };

    const quiet_vtable: VTable = .{
        .create_session_route = struct {
            fn call(_: ?*anyopaque, _: surface.SessionOpenOptions) Allocating!SessionRoute {
                // No slots, because there is no Runtime holding any.
                return error.SessionCapacity;
            }
        }.call,
        .restore_session_route = struct {
            fn call(_: ?*anyopaque, _: surface.SessionRestoreOptions) Allocating!SessionRestoreRoute {
                return error.SessionCapacity;
            }
        }.call,
        .release_closed_session = struct {
            fn call(_: ?*anyopaque, _: SessionPort) Error!void {
                @panic("Agent call on a Runtime port that has no Agent");
            }
        }.call,
        .take_event = struct {
            fn call(_: ?*anyopaque) ?event_pump.OwnedCoreEvent {
                return null;
            }
        }.call,
        .has_pending_events = struct {
            fn call(_: ?*anyopaque) bool {
                return false;
            }
        }.call,
        .pending_event_count = struct {
            fn call(_: ?*anyopaque, _: u64) usize {
                return 0;
            }
        }.call,
        .notify_event_consumer = struct {
            fn call(_: ?*anyopaque) session_control.EventReadyNotification {
                @panic("Agent call on a Runtime port that has no Agent");
            }
        }.call,
        .request_run_termination = struct {
            fn call(_: ?*anyopaque, _: u64, _: u64, _: session_control.TerminationSignal) Error!void {
                @panic("Agent call on a Runtime port that has no Agent");
            }
        }.call,
        .restore_admission = struct {
            fn call(_: ?*anyopaque, _: ?u64) RestoreAdmission {
                // Projection asks this on every Task read, so it has to
                // answer: with no Agent there is nothing to restore into.
                return .unavailable;
            }
        }.call,
        .activate_mcp = struct {
            fn call(_: ?*anyopaque) Allocating!surface.McpActivationOutcome {
                // Nothing is configured, so nothing activates.
                return .empty;
            }
        }.call,
        .create_mcp_admission_selection = struct {
            fn call(_: ?*anyopaque, _: *const mcp_catalog.Activation, _: []const mcp_catalog.ServerAllowlist) Allocating!?*mcp_catalog.Selection {
                @panic("Agent call on a Runtime port that has no Agent");
            }
        }.call,
        .prepare_mcp_restore_selection = struct {
            fn call(_: ?*anyopaque, _: *const mcp_catalog.RestoreSelection, _: *const mcp_catalog.Activation, _: []const mcp_catalog.ActivationTool) Allocating!*mcp_catalog.Selection {
                @panic("Agent call on a Runtime port that has no Agent");
            }
        }.call,
        .query_skill_catalog = struct {
            fn call(_: ?*anyopaque, _: catalog.Query) Allocating!catalog.Acquisition {
                @panic("Agent call on a Runtime port that has no Agent");
            }
        }.call,
        .release_skill_catalog = struct {
            fn call(_: ?*anyopaque, _: *catalog.Lease) Error!void {
                @panic("Agent call on a Runtime port that has no Agent");
            }
        }.call,
        .narrow_skill_restore_inputs = struct {
            fn call(_: ?*anyopaque, _: *SkillRestoreInputs, _: surface.SkillPolicyInput) Allocating!*SkillRestoreInputs {
                @panic("Agent call on a Runtime port that has no Agent");
            }
        }.call,
        .clone_skill_restore_inputs = struct {
            fn call(_: ?*anyopaque, _: *SkillRestoreInputs) Allocating!*SkillRestoreInputs {
                @panic("Agent call on a Runtime port that has no Agent");
            }
        }.call,
        .borrow_skill_restore_inputs = struct {
            fn call(_: ?*anyopaque, _: *const SkillRestoreInputs) ?SkillRestoreBorrow {
                @panic("Agent call on a Runtime port that has no Agent");
            }
        }.call,
        .release_skill_restore_inputs = struct {
            fn call(_: ?*anyopaque, _: *SkillRestoreInputs) Error!void {
                @panic("Agent call on a Runtime port that has no Agent");
            }
        }.call,
        .release_restore_inputs = struct {
            fn call(_: ?*anyopaque, _: *SessionRestoreInputs) Error!void {
                @panic("Agent call on a Runtime port that has no Agent");
            }
        }.call,
    };

    pub fn createSessionRoute(self: RuntimePort, options: surface.SessionOpenOptions) Allocating!SessionRoute {
        return self.vtable.create_session_route(self.context, options);
    }

    pub fn restoreSessionRoute(self: RuntimePort, options: surface.SessionRestoreOptions) Allocating!SessionRestoreRoute {
        return self.vtable.restore_session_route(self.context, options);
    }

    pub fn releaseClosedSession(self: RuntimePort, session: SessionPort) Error!void {
        return self.vtable.release_closed_session(self.context, session);
    }

    pub fn takeEvent(self: RuntimePort) ?event_pump.OwnedCoreEvent {
        return self.vtable.take_event(self.context);
    }

    pub fn hasPendingEvents(self: RuntimePort) bool {
        return self.vtable.has_pending_events(self.context);
    }

    pub fn pendingEventCount(self: RuntimePort, session_id: u64) usize {
        return self.vtable.pending_event_count(self.context, session_id);
    }

    pub fn notifyEventConsumer(self: RuntimePort) session_control.EventReadyNotification {
        return self.vtable.notify_event_consumer(self.context);
    }

    pub fn requestRunTermination(
        self: RuntimePort,
        session_id: u64,
        run_id: u64,
        signal: session_control.TerminationSignal,
    ) Error!void {
        return self.vtable.request_run_termination(self.context, session_id, run_id, signal);
    }

    pub fn restoreAdmission(self: RuntimePort, releasing_route_id: ?u64) RestoreAdmission {
        return self.vtable.restore_admission(self.context, releasing_route_id);
    }

    pub fn activateMcp(self: RuntimePort) Allocating!surface.McpActivationOutcome {
        return self.vtable.activate_mcp(self.context);
    }

    pub fn createMcpAdmissionSelection(
        self: RuntimePort,
        activation: *const mcp_catalog.Activation,
        allowlists: []const mcp_catalog.ServerAllowlist,
    ) Allocating!?*mcp_catalog.Selection {
        return self.vtable.create_mcp_admission_selection(self.context, activation, allowlists);
    }

    pub fn prepareMcpRestoreSelection(
        self: RuntimePort,
        original: *const mcp_catalog.RestoreSelection,
        activation: *const mcp_catalog.Activation,
        ceiling: []const mcp_catalog.ActivationTool,
    ) Allocating!*mcp_catalog.Selection {
        return self.vtable.prepare_mcp_restore_selection(self.context, original, activation, ceiling);
    }

    pub fn querySkillCatalog(self: RuntimePort, input: catalog.Query) Allocating!catalog.Acquisition {
        return self.vtable.query_skill_catalog(self.context, input);
    }

    pub fn releaseSkillCatalog(self: RuntimePort, lease: *catalog.Lease) Error!void {
        return self.vtable.release_skill_catalog(self.context, lease);
    }

    pub fn narrowSkillRestoreInputs(
        self: RuntimePort,
        inputs: *SkillRestoreInputs,
        policy: surface.SkillPolicyInput,
    ) Allocating!*SkillRestoreInputs {
        return self.vtable.narrow_skill_restore_inputs(self.context, inputs, policy);
    }

    pub fn cloneSkillRestoreInputs(self: RuntimePort, inputs: *SkillRestoreInputs) Allocating!*SkillRestoreInputs {
        return self.vtable.clone_skill_restore_inputs(self.context, inputs);
    }

    /// `null` when the borrow could not be made, because the half holding
    /// the inputs is unreachable.
    ///
    /// It is not an empty borrow. An empty grant list is a meaningful value
    /// here -- it denies every skill -- and in the one place that compares two
    /// of them it would read as "the filters did not change", which restores a
    /// Session as though its skills were intact. So the absence is the
    /// caller's to answer.
    pub fn borrowSkillRestoreInputs(self: RuntimePort, inputs: *const SkillRestoreInputs) ?SkillRestoreBorrow {
        return self.vtable.borrow_skill_restore_inputs(self.context, inputs);
    }

    pub fn releaseSkillRestoreInputs(self: RuntimePort, inputs: *SkillRestoreInputs) Error!void {
        return self.vtable.release_skill_restore_inputs(self.context, inputs);
    }

    pub fn releaseRestoreInputs(self: RuntimePort, inputs: *SessionRestoreInputs) Error!void {
        return self.vtable.release_restore_inputs(self.context, inputs);
    }
};
