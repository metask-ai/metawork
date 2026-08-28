const std = @import("std");
const agent = @import("metawork_agent");
const control_ports = @import("metawork_product_control_ports");

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
        consumer: control_ports.AgentEventConsumer,
    ) void {
        self.wake_pending.store(false, .release);
        consumer.drainAgentEvents() catch {};
    }
};
