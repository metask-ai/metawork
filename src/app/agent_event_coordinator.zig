const std = @import("std");
const agent = @import("metawork_agent");
const workbench_api = @import("metawork_workbench");

pub const Wake = struct {
    context: ?*anyopaque,
    notify_fn: *const fn (?*anyopaque) bool,
};

pub const Coordinator = struct {
    wake: ?Wake = null,
    wake_pending: std.atomic.Value(bool) = .init(false),

    pub fn bindWake(self: *Coordinator, wake: Wake) void {
        self.wake = wake;
    }

    pub fn notifier(self: *Coordinator) agent.EventReadyNotifier {
        return .{ .context = self, .notify_fn = notify };
    }

    fn notify(context: ?*anyopaque) agent.EventReadyNotification {
        const self: *Coordinator = @ptrCast(@alignCast(context orelse return .unavailable));
        if (self.wake_pending.swap(true, .acq_rel)) return .already_pending;
        const wake = self.wake orelse {
            self.wake_pending.store(false, .release);
            return .unavailable;
        };
        if (wake.notify_fn(wake.context)) return .scheduled;
        self.wake_pending.store(false, .release);
        return .unavailable;
    }

    pub fn drain(
        self: *Coordinator,
        runtime: *agent.Runtime,
        workbench: *workbench_api.Workbench,
    ) void {
        self.wake_pending.store(false, .release);
        drainPass(runtime, workbench);
        // Terminal publication happens after the synchronous AgentCore Run
        // returns, so its acquire observes all callback event enqueues. Drain
        // once more after that observation before exposing product terminal
        // state and the final assistant suffix; otherwise a queued callback
        // could lose the race to lifecycle publication or a snapshot.
        workbench.markTerminalRunsBeforeEventDrain();
        drainPass(runtime, workbench);
        workbench.finalizeMarkedTerminalRunsAfterEventDrain();
    }
};

fn drainPass(
    runtime: *agent.Runtime,
    workbench: *workbench_api.Workbench,
) void {
    while (runtime.takeEvent()) |value| {
        var envelope = value;
        defer envelope.deinit();
        workbench.applyEvent(&envelope) catch {
            workbench.recordEventProjectionFailure(
                envelope.session_id,
                envelope.run_id,
            );
            runtime.requestRunTermination(
                envelope.session_id,
                envelope.run_id,
                .{ .event_pump_failure = .consumer_rejected },
            ) catch {};
        };
    }
}
