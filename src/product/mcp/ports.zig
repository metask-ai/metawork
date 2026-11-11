//! Narrow effects consumed by the Product MCP aggregate and refresh worker.
//! Capability values grant no Workbench, concrete Executor, or Agent Runtime identity.

const agent = @import("metawork_agent");
const std = @import("std");

pub const CatalogError = agent.Error || std.mem.Allocator.Error;

pub const Job = struct {
    identity: *anyopaque,
    context: *anyopaque,
    execute_fn: *const fn (*anyopaque) void,
    cancel_fn: *const fn (*anyopaque) void,
};

pub const Executor = struct {
    context: *anyopaque,
    enqueue_fn: *const fn (*anyopaque, Job) error{ ExecutorShuttingDown, QueueFull }!void,
    cancel_fn: *const fn (*anyopaque, *anyopaque) bool,

    pub fn enqueue(self: Executor, job: Job) error{ ExecutorShuttingDown, QueueFull }!void {
        return self.enqueue_fn(self.context, job);
    }

    pub fn cancel(self: Executor, identity: *anyopaque) bool {
        return self.cancel_fn(self.context, identity);
    }
};

pub const Catalog = struct {
    context: *anyopaque,
    activate_fn: *const fn (*anyopaque) CatalogError!agent.McpActivationOutcome,
    create_admission_selection_fn: *const fn (
        *anyopaque,
        *const agent.McpActivation,
        []const agent.McpServerAllowlist,
    ) CatalogError!?*agent.McpSelection,
    prepare_restore_selection_fn: *const fn (
        *anyopaque,
        *const agent.McpRestoreSelection,
        *const agent.McpActivation,
        []const agent.McpActivationTool,
    ) CatalogError!*agent.McpSelection,

    pub fn activate(self: Catalog) CatalogError!agent.McpActivationOutcome {
        return self.activate_fn(self.context);
    }

    pub fn createAdmissionSelection(
        self: Catalog,
        activation: *const agent.McpActivation,
        allowlists: []const agent.McpServerAllowlist,
    ) CatalogError!?*agent.McpSelection {
        return self.create_admission_selection_fn(
            self.context,
            activation,
            allowlists,
        );
    }

    pub fn prepareRestoreSelection(self: Catalog, original: *const agent.McpRestoreSelection, activation: *const agent.McpActivation, ceiling: []const agent.McpActivationTool) CatalogError!*agent.McpSelection {
        return self.prepare_restore_selection_fn(self.context, original, activation, ceiling);
    }
};

pub const Timer = struct {
    enabled: bool,
    context: ?*anyopaque,
    now_fn: *const fn (?*anyopaque) ?u64,
    arm_at_fn: *const fn (?*anyopaque, u64) bool,
    cancel_fn: *const fn (?*anyopaque) void,

    pub fn now(self: Timer) ?u64 {
        if (!self.enabled) return null;
        return self.now_fn(self.context);
    }

    pub fn armAt(self: Timer, deadline_ms: u64) bool {
        return self.enabled and self.arm_at_fn(self.context, deadline_ms);
    }

    pub fn cancel(self: Timer) void {
        if (self.enabled) self.cancel_fn(self.context);
    }
};

pub const Notifier = struct {
    context: ?*anyopaque,
    notify_fn: *const fn (?*anyopaque) bool,

    pub fn notify(self: Notifier) bool {
        return self.notify_fn(self.context);
    }
};

pub const Ports = struct {
    executor: Executor,
    catalog: Catalog,
    timer: Timer,
    notifier: Notifier,
    unix_clock: UnixClock = .{},
};

/// Read capability only; OAuth scheduling does not borrow another timer owner.
pub const UnixClock = struct {
    enabled: bool = false,
    context: ?*anyopaque = null,
    now_ms_fn: ?*const fn (?*anyopaque) ?u64 = null,

    pub fn nowMs(self: UnixClock) ?u64 {
        if (!self.enabled) return null;
        const read = self.now_ms_fn orelse return null;
        const milliseconds = read(self.context) orelse return null;
        return if (milliseconds != 0) milliseconds else null;
    }
};
