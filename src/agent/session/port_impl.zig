//! The in-process implementation of the Agent ports.
//!
//! Every function here forwards one call to the live Runtime, Session or
//! control block and changes nothing else: same arguments, same error set,
//! same ownership. This file is the only place that casts a port context back
//! to an implementation pointer, so it is also the whole list of what a
//! different implementation -- one that forwards to another process -- would
//! have to supply.

const std = @import("std");
const root = @import("../session.zig");
const binding = @import("binding.zig");
const contract = @import("agent_contract");
const port = contract.port;
const surface = contract.surface;
const session_control = contract.control;
const catalog = @import("agent_catalog");
const mcp_catalog = @import("agent_mcp_catalog");
const checkpoint = @import("agent_checkpoint");
const event_pump = @import("event_pump");
const delivery = @import("agent_file_delivery");
const sdk = @import("metask_agentcore");
const generate_video = contract.generate_video;
const mcp_install = contract.mcp_install;

fn sessionOf(context: ?*anyopaque) *root.Session {
    return @ptrCast(@alignCast(context.?));
}

fn runtimeOf(context: ?*anyopaque) *root.Runtime {
    return @ptrCast(@alignCast(context.?));
}

fn blockOf(context: ?*anyopaque) *binding.SessionControlBlock {
    return @ptrCast(@alignCast(context.?));
}

pub fn sessionPort(session: *root.Session) port.SessionPort {
    return .{ .context = session, .vtable = &session_vtable };
}

/// The Session behind an in-process port. Only the implementation knows this
/// representation; it is exposed for callers that legitimately hold the
/// implementation already, such as an Agent test inspecting the ABI handle of
/// a Session that Product opened.
pub fn sessionBehind(value: port.SessionPort) *root.Session {
    return sessionOf(value.context);
}

pub fn runtimePort(runtime: *root.Runtime) port.RuntimePort {
    return .{ .context = runtime, .vtable = &runtime_vtable };
}

fn controlPort(block: *binding.SessionControlBlock, run_id: u64, generation: u64) port.RunControl {
    return .{
        .context = block,
        .vtable = &control_vtable,
        .run_id = run_id,
        .generation = generation,
    };
}

/// Takes the Run's base lease with it. The caller must not use the value it
/// passed in afterwards.
fn runPort(value: root.Run) port.RunPort {
    return .{
        .context = value.session,
        .vtable = &run_vtable,
        .run_id = value.run_id,
        .generation = value.generation,
        .base_lease = .{
            .control = controlPort(value.base_lease.block, value.run_id, value.generation),
            .released = value.base_lease.released,
        },
        .executed = value.executed,
    };
}

fn restoreInputsPort(runtime: *root.Runtime, value: root.SessionRestoreInputs) port.SessionRestoreInputs {
    return .{
        .agent = runtimePort(runtime),
        .skill = if (value.skill) |skill| @ptrCast(skill) else null,
        .mcp = value.mcp,
        .permission_mode = value.permission_mode,
        .shell_policy = value.shell_policy,
        .permission_interaction = value.permission_interaction,
    };
}

fn restoreInputsOwned(value: *const port.SessionRestoreInputs) root.SessionRestoreInputs {
    return .{
        .skill = if (value.skill) |skill| @ptrCast(skill) else null,
        .mcp = value.mcp,
        .permission_mode = value.permission_mode,
        .shell_policy = value.shell_policy,
        .permission_interaction = value.permission_interaction,
    };
}

const run_vtable: port.RunPort.VTable = .{
    .execute = struct {
        fn call(context: ?*anyopaque, run_id: u64, generation: u64) session_control.TerminalResult {
            return sessionOf(context).executeBegunRun(run_id, generation);
        }
    }.call,
};

const control_vtable: port.RunControl.VTable = .{
    .try_retain = struct {
        fn call(context: ?*anyopaque) bool {
            return blockOf(context).tryRetain();
        }
    }.call,
    .release = struct {
        fn call(context: ?*anyopaque) void {
            blockOf(context).release();
        }
    }.call,
    .submit_input = struct {
        fn call(context: ?*anyopaque, run_id: u64, generation: u64, input_id: u64, text: []const u8) session_control.InputSubmission {
            return blockOf(context).session.submitControlledInput(run_id, generation, input_id, text);
        }
    }.call,
    .input_observation = struct {
        // In process the observation is always made; the optional exists for
        // the half that may not be there.
        fn call(context: ?*anyopaque, run_id: u64, generation: u64) ?session_control.InputObservation {
            return blockOf(context).session.controlledInputObservation(run_id, generation);
        }
    }.call,
    .request_termination = struct {
        fn call(context: ?*anyopaque, run_id: u64, generation: u64, signal: session_control.TerminationSignal) session_control.TerminationRequestResult {
            return blockOf(context).session.requestControlledTermination(run_id, generation, signal);
        }
    }.call,
};

const session_vtable: port.SessionPort.VTable = .{
    .retain_reference = struct {
        fn call(context: ?*anyopaque) bool {
            return sessionOf(context).retainReference();
        }
    }.call,
    .release_reference = struct {
        fn call(context: ?*anyopaque) void {
            sessionOf(context).releaseReference();
        }
    }.call,
    .stop_event_delivery = struct {
        fn call(context: ?*anyopaque) void {
            sessionOf(context).stopEventDelivery();
        }
    }.call,
    .close_outcome = struct {
        fn call(context: ?*anyopaque, interruption: session_control.ExternalInterruption) surface.CloseOutcome {
            return sessionOf(context).closeOutcome(interruption);
        }
    }.call,
    .refresh_skill_catalog = struct {
        fn call(context: ?*anyopaque, lease: *catalog.Lease, skill_policy: surface.SkillPolicyInput) (surface.Error || std.mem.Allocator.Error)!void {
            return sessionOf(context).refreshSkillCatalog(lease, skill_policy);
        }
    }.call,
    .set_model = struct {
        fn call(context: ?*anyopaque, model: []const u8) surface.Error!void {
            return sessionOf(context).setModel(model);
        }
    }.call,
    .clear_skill_policy = struct {
        fn call(context: ?*anyopaque) (surface.Error || std.mem.Allocator.Error)!void {
            return sessionOf(context).clearSkillPolicy();
        }
    }.call,
    .skill_policy_matches = struct {
        fn call(context: ?*anyopaque, lease: *catalog.Lease, policy: surface.SkillPolicyInput) bool {
            return sessionOf(context).skillPolicyMatches(lease, policy);
        }
    }.call,
    .capture_restore_inputs = struct {
        fn call(context: ?*anyopaque) (surface.Error || std.mem.Allocator.Error)!port.SessionRestoreInputs {
            const session = sessionOf(context);
            return restoreInputsPort(session.agent_runtime, try session.captureRestoreInputs());
        }
    }.call,
    .snapshot = struct {
        fn call(context: ?*anyopaque) surface.SessionSnapshot {
            return sessionOf(context).snapshot();
        }
    }.call,
    .update_permission_mode = struct {
        fn call(context: ?*anyopaque, expected: session_control.PermissionMode, target: session_control.PermissionMode) surface.Error!surface.PermissionModeUpdate {
            return sessionOf(context).updatePermissionMode(expected, target);
        }
    }.call,
    .conversation_bounds = struct {
        fn call(context: ?*anyopaque) surface.Error!surface.ConversationBounds {
            return sessionOf(context).conversationBounds();
        }
    }.call,
    .rewind_to_user_message = struct {
        fn call(context: ?*anyopaque, position: u64) surface.Error!surface.RewindOutcome {
            return sessionOf(context).rewindToUserMessage(position);
        }
    }.call,
    .update_credential = struct {
        fn call(context: ?*anyopaque, credential: []const u8) surface.Error!void {
            return sessionOf(context).updateCredential(credential);
        }
    }.call,
    .request_termination = struct {
        fn call(context: ?*anyopaque, run_id: u64, signal: session_control.TerminationSignal) surface.Error!void {
            return sessionOf(context).requestTermination(run_id, signal);
        }
    }.call,
    .prepare_run = struct {
        fn call(context: ?*anyopaque, input: surface.RunInput) (surface.Error || std.mem.Allocator.Error)!u64 {
            return sessionOf(context).prepareRun(input);
        }
    }.call,
    .prepare_run_with_tools = struct {
        fn call(
            context: ?*anyopaque,
            input: surface.RunInput,
            image_input: ?surface.ImageGenerationRunInput,
            delivery_input: ?delivery.Input,
            mcp_input: ?mcp_install.Input,
            video_input: ?generate_video.Input,
        ) (surface.Error || std.mem.Allocator.Error)!u64 {
            return sessionOf(context).prepareRunWithTools(input, image_input, delivery_input, mcp_input, video_input);
        }
    }.call,
    .begin_run_outcome = struct {
        fn call(context: ?*anyopaque, run_id: u64) port.BeginRunOutcome {
            return switch (sessionOf(context).beginRunOutcome(run_id)) {
                .run => |value| .{ .run = runPort(value) },
                .failure => |failure| .{ .failure = failure },
            };
        }
    }.call,
    .cancel_prepared_run = struct {
        fn call(context: ?*anyopaque, run_id: u64) surface.Error!void {
            return sessionOf(context).cancelPreparedRun(run_id);
        }
    }.call,
    .prepare_compact = struct {
        fn call(context: ?*anyopaque) (surface.Error || std.mem.Allocator.Error)!u64 {
            return sessionOf(context).prepareCompact();
        }
    }.call,
    .cancel_prepared_compact = struct {
        fn call(context: ?*anyopaque, operation_id: u64) surface.Error!void {
            return sessionOf(context).cancelPreparedCompact(operation_id);
        }
    }.call,
    .execute_prepared_compact = struct {
        fn call(context: ?*anyopaque, operation_id: u64) surface.Error!session_control.CompactTerminalResult {
            return sessionOf(context).executePreparedCompact(operation_id);
        }
    }.call,
    .request_compact_cancellation = struct {
        fn call(context: ?*anyopaque, operation_id: u64, interruption: session_control.ExternalInterruption) port.CompactCancellation!void {
            return sessionOf(context).requestCompactCancellation(operation_id, interruption);
        }
    }.call,
    .respond_permission = struct {
        fn call(context: ?*anyopaque, run_id: u64, request_id: u64, choice: sdk.protocol.PermissionChoice) (surface.Error || std.mem.Allocator.Error)!void {
            return sessionOf(context).respondPermission(run_id, request_id, choice);
        }
    }.call,
    .fail_ui_request_identity_contract = struct {
        fn call(context: ?*anyopaque, run_id: u64) surface.Error!void {
            return sessionOf(context).failUiRequestIdentityContract(run_id);
        }
    }.call,
    .pending_ui_observation = struct {
        fn call(context: ?*anyopaque) ?port.SessionPort.PendingUiObservation {
            const observation = sessionOf(context).pendingUiObservation() orelse return null;
            return .{
                .run_id = observation.run_id,
                .request_id = observation.request_id,
                .input_adopted_count = observation.input_adopted_count,
            };
        }
    }.call,
    .permission_stop_request = struct {
        fn call(context: ?*anyopaque) ?u64 {
            return sessionOf(context).permissionStopRequest();
        }
    }.call,
    .copy_pending_ui_request = struct {
        fn call(context: ?*anyopaque, allocator: std.mem.Allocator) (surface.Error || std.mem.Allocator.Error)!surface.PendingUiRequest {
            return sessionOf(context).copyPendingUiRequest(allocator);
        }
    }.call,
    .export_checkpoint = struct {
        fn call(
            context: ?*anyopaque,
            limits: checkpoint.Limits,
            sink: checkpoint.Sink,
            expected_last_run_id: u64,
            expected_last_compact_id: u64,
            expected_model: []const u8,
        ) surface.Error!checkpoint.Outcome {
            return sessionOf(context).exportCheckpoint(
                limits,
                sink,
                expected_last_run_id,
                expected_last_compact_id,
                expected_model,
            );
        }
    }.call,
};

const runtime_vtable: port.RuntimePort.VTable = .{
    .create_session_route = struct {
        fn call(context: ?*anyopaque, options: surface.SessionOpenOptions) (surface.Error || std.mem.Allocator.Error)!port.SessionRoute {
            const route = try runtimeOf(context).createSessionRoute(options);
            return .{ .id = route.id, .session = sessionPort(route.session) };
        }
    }.call,
    .restore_session_route = struct {
        fn call(context: ?*anyopaque, options: surface.SessionRestoreOptions) (surface.Error || std.mem.Allocator.Error)!port.SessionRestoreRoute {
            const route = try runtimeOf(context).restoreSessionRoute(options);
            return .{ .id = route.id, .session = sessionPort(route.session), .report = route.report };
        }
    }.call,
    .release_closed_session = struct {
        fn call(context: ?*anyopaque, session: port.SessionPort) surface.Error!void {
            return runtimeOf(context).releaseClosedSession(sessionOf(session.context));
        }
    }.call,
    .take_event = struct {
        fn call(context: ?*anyopaque) ?event_pump.OwnedCoreEvent {
            return runtimeOf(context).takeEvent();
        }
    }.call,
    .has_pending_events = struct {
        fn call(context: ?*anyopaque) bool {
            return runtimeOf(context).hasPendingEvents();
        }
    }.call,
    .pending_event_count = struct {
        fn call(context: ?*anyopaque, session_id: u64) usize {
            return runtimeOf(context).pendingEventCount(session_id);
        }
    }.call,
    .notify_event_consumer = struct {
        fn call(context: ?*anyopaque) session_control.EventReadyNotification {
            return runtimeOf(context).notifyEventConsumer();
        }
    }.call,
    .request_run_termination = struct {
        fn call(context: ?*anyopaque, session_id: u64, run_id: u64, signal: session_control.TerminationSignal) surface.Error!void {
            return runtimeOf(context).requestRunTermination(session_id, run_id, signal);
        }
    }.call,
    .restore_admission = struct {
        fn call(context: ?*anyopaque, releasing_route_id: ?u64) port.RuntimePort.RestoreAdmission {
            return switch (runtimeOf(context).restoreAdmission(releasing_route_id)) {
                .available => .available,
                .capacity_reached => .capacity_reached,
                .mcp_busy => .mcp_busy,
                .unavailable => .unavailable,
            };
        }
    }.call,
    .activate_mcp = struct {
        fn call(context: ?*anyopaque) (surface.Error || std.mem.Allocator.Error)!surface.McpActivationOutcome {
            return runtimeOf(context).activateMcp();
        }
    }.call,
    .create_mcp_admission_selection = struct {
        fn call(
            context: ?*anyopaque,
            activation: *const mcp_catalog.Activation,
            allowlists: []const mcp_catalog.ServerAllowlist,
        ) (surface.Error || std.mem.Allocator.Error)!?*mcp_catalog.Selection {
            return runtimeOf(context).createMcpAdmissionSelection(activation, allowlists);
        }
    }.call,
    .prepare_mcp_restore_selection = struct {
        fn call(
            context: ?*anyopaque,
            original: *const mcp_catalog.RestoreSelection,
            activation: *const mcp_catalog.Activation,
            ceiling: []const mcp_catalog.ActivationTool,
        ) (surface.Error || std.mem.Allocator.Error)!*mcp_catalog.Selection {
            return runtimeOf(context).prepareMcpRestoreSelection(original, activation, ceiling);
        }
    }.call,
    .query_skill_catalog = struct {
        fn call(context: ?*anyopaque, input: catalog.Query) (surface.Error || std.mem.Allocator.Error)!catalog.Acquisition {
            return runtimeOf(context).querySkillCatalog(input);
        }
    }.call,
    .release_skill_catalog = struct {
        fn call(context: ?*anyopaque, lease: *catalog.Lease) surface.Error!void {
            return runtimeOf(context).releaseSkillCatalog(lease);
        }
    }.call,
    .narrow_skill_restore_inputs = struct {
        fn call(
            context: ?*anyopaque,
            inputs: *port.SkillRestoreInputs,
            policy: surface.SkillPolicyInput,
        ) (surface.Error || std.mem.Allocator.Error)!*port.SkillRestoreInputs {
            _ = context;
            const owned: *const root.SkillRestoreInputs = @ptrCast(inputs);
            return @ptrCast(try owned.narrow(policy));
        }
    }.call,
    .clone_skill_restore_inputs = struct {
        fn call(context: ?*anyopaque, inputs: *port.SkillRestoreInputs) (surface.Error || std.mem.Allocator.Error)!*port.SkillRestoreInputs {
            _ = context;
            const owned: *const root.SkillRestoreInputs = @ptrCast(inputs);
            return @ptrCast(try owned.clone());
        }
    }.call,
    .borrow_skill_restore_inputs = struct {
        // In process the inputs are right here; the optional is for the half
        // that may not be.
        fn call(context: ?*anyopaque, inputs: *const port.SkillRestoreInputs) ?port.SkillRestoreBorrow {
            _ = context;
            const owned: *const root.SkillRestoreInputs = @ptrCast(inputs);
            const borrowed = owned.borrow();
            return .{ .catalog = borrowed.catalog, .policy = borrowed.policy };
        }
    }.call,
    .release_skill_restore_inputs = struct {
        fn call(context: ?*anyopaque, inputs: *port.SkillRestoreInputs) surface.Error!void {
            _ = context;
            const owned: *root.SkillRestoreInputs = @ptrCast(inputs);
            return owned.deinit();
        }
    }.call,
    .release_restore_inputs = struct {
        fn call(context: ?*anyopaque, inputs: *port.SessionRestoreInputs) surface.Error!void {
            _ = context;
            var owned = restoreInputsOwned(inputs);
            defer inputs.* = undefined;
            return owned.deinit();
        }
    }.call,
};
