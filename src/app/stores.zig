const std = @import("std");
const workbench_api = @import("metawork_workbench");
const mcp_configuration = @import("metawork_product_mcp").configuration;
const product_task = @import("metawork_product_task");
const app_paths = @import("paths.zig");

pub const Stores = struct {
    allocator: std.mem.Allocator = undefined,
    automatic_workspace_root: ?workbench_api.AutomaticWorkspaceRoot = null,
    mcp_configuration: ?mcp_configuration.FileStore = null,
    task: ?product_task.persistence.FileStore = null,
    task_restore_failed: bool = true,
    task_restored_bytes: ?[]u8 = null,
    checkpoint: ?product_task.checkpoint_store.FileStore = null,
    checkpoint_open_failed: bool = true,
    scheduled_task: ?workbench_api.ScheduledTaskFileStore = null,
    scheduled_task_restore_failed: bool = true,
    scheduled_task_restored_bytes: ?[]u8 = null,
    skill_management: ?workbench_api.SkillManagementFileStore = null,
    skill_management_restore_failed: bool = true,
    skill_management_restored_bytes: ?[]u8 = null,
    skill_enablement: ?workbench_api.SkillEnablementFileStore = null,
    skill_enablement_restore_failed: bool = true,
    skill_enablement_restored_bytes: ?[]u8 = null,

    pub fn init(
        self: *Stores,
        io: std.Io,
        allocator: std.mem.Allocator,
        paths: *const app_paths.Paths,
    ) void {
        self.* = .{ .allocator = allocator };

        if (paths.automaticWorkspaceDir()) |directory| {
            self.automatic_workspace_root = workbench_api.AutomaticWorkspaceRoot.open(
                io,
                allocator,
                directory,
            ) catch null;
        }
        self.mcp_configuration = mcp_configuration.FileStore.init(
            io,
            paths.mcpDir(),
        ) catch null;

        self.task = product_task.persistence.FileStore.init(io, paths.workbenchDir()) catch null;
        self.task_restore_failed = self.task == null;
        self.task_restored_bytes = if (self.task) |*store|
            store.loadAlloc(allocator) catch failed: {
                self.task_restore_failed = true;
                break :failed null;
            }
        else
            null;

        // Lock order is Task history first, checkpoint store second.
        self.checkpoint = product_task.checkpoint_store.FileStore.init(
            io,
            paths.checkpointsDir(),
        ) catch null;
        self.checkpoint_open_failed = self.checkpoint == null;

        self.scheduled_task = workbench_api.ScheduledTaskFileStore.init(
            io,
            paths.workbenchDir(),
        ) catch null;
        self.scheduled_task_restore_failed = self.scheduled_task == null;
        self.scheduled_task_restored_bytes = if (self.scheduled_task) |*store|
            store.loadAlloc(allocator) catch failed: {
                self.scheduled_task_restore_failed = true;
                break :failed null;
            }
        else
            null;

        self.skill_management = workbench_api.SkillManagementFileStore.init(
            io,
            paths.workbenchDir(),
        ) catch null;
        self.skill_management_restore_failed = self.skill_management == null;
        self.skill_management_restored_bytes = if (self.skill_management) |*store|
            store.loadAlloc(allocator) catch failed: {
                self.skill_management_restore_failed = true;
                break :failed null;
            }
        else
            null;

        self.skill_enablement = workbench_api.SkillEnablementFileStore.init(
            io,
            paths.workbenchDir(),
        ) catch null;
        self.skill_enablement_restore_failed = self.skill_enablement == null;
        self.skill_enablement_restored_bytes = if (self.skill_enablement) |*store|
            store.loadAlloc(allocator) catch failed: {
                self.skill_enablement_restore_failed = true;
                break :failed null;
            }
        else
            null;
    }

    pub fn deinit(self: *Stores) void {
        const allocator = self.allocator;
        if (self.skill_enablement_restored_bytes) |bytes| self.allocator.free(bytes);
        if (self.skill_enablement) |*store| store.deinit();
        if (self.skill_management_restored_bytes) |bytes| self.allocator.free(bytes);
        if (self.skill_management) |*store| store.deinit();
        if (self.scheduled_task_restored_bytes) |bytes| self.allocator.free(bytes);
        if (self.scheduled_task) |*store| store.deinit();
        if (self.task_restored_bytes) |bytes| self.allocator.free(bytes);
        if (self.checkpoint) |*store| store.deinit();
        if (self.task) |*store| store.deinit();
        if (self.mcp_configuration) |*store| store.deinit();
        if (self.automatic_workspace_root) |*root| root.deinit();
        self.* = .{ .allocator = allocator };
    }
};

pub fn commitScheduledTaskStore(
    context: ?*anyopaque,
    bytes: []const u8,
) workbench_api.SchedulePersistenceCommit {
    const store: *workbench_api.ScheduledTaskFileStore = @ptrCast(
        @alignCast(context orelse return .failed),
    );
    store.commit(bytes) catch |err| return switch (err) {
        error.PersistenceOutcomeUnknown => .outcome_unknown,
        else => .failed,
    };
    return .committed;
}

pub fn commitTaskStore(
    context: ?*anyopaque,
    bytes: []const u8,
) workbench_api.TaskPersistenceCommit {
    const store: *product_task.persistence.FileStore = @ptrCast(
        @alignCast(context orelse return .failed),
    );
    store.commit(bytes) catch |err| return switch (err) {
        error.PersistenceOutcomeUnknown => .outcome_unknown,
        else => .failed,
    };
    return .committed;
}
