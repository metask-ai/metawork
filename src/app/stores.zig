const std = @import("std");
const product_control = @import("metawork_product_control");
const schedule_persistence = @import("product_schedule_persistence");
const mcp_configuration = @import("metawork_product_mcp").contract;
const skill_enablement = @import("metawork_product_skill").enablement;
const skill_management = @import("metawork_product_skill").management;
const skill_sources = @import("metawork_product_skill").sources;
const SourceRestore = @import("metawork_product_skill").runtime.SourceRestore;
const product_task = @import("metawork_product_task");
const history_store = @import("history_store.zig");
const app_paths = @import("paths.zig");

pub const Stores = struct {
    allocator: std.mem.Allocator = undefined,
    automatic_workspace_configuration: ?product_control.AutomaticWorkspaceRootConfigurationFileStore = null,
    mcp_configuration: ?mcp_configuration.FileStore = null,
    task: ?history_store.Store = null,
    task_restore_failed: bool = true,
    task_restored_bytes: ?[]u8 = null,
    checkpoint: ?product_task.checkpoint_store.FileStore = null,
    checkpoint_open_failed: bool = true,
    attachments: ?product_control.AttachmentFileStore = null,
    file_change: ?product_task.file_change_store.FileStore = null,
    scheduled_task: ?schedule_persistence.FileStore = null,
    scheduled_task_restore_failed: bool = true,
    scheduled_task_restored_bytes: ?[]u8 = null,
    skill_management: ?skill_management.FileStore = null,
    skill_management_restore_failed: bool = true,
    skill_management_restored_bytes: ?[]u8 = null,
    skill_enablement: ?skill_enablement.FileStore = null,
    skill_enablement_restore_failed: bool = true,
    skill_enablement_restored_bytes: ?[]u8 = null,
    skill_sources: ?skill_sources.FileStore = null,
    skill_sources_restored: SourceRestore = .unavailable,

    pub fn init(
        self: *Stores,
        io: std.Io,
        allocator: std.mem.Allocator,
        paths: *const app_paths.Paths,
    ) void {
        self.* = .{ .allocator = allocator };

        self.automatic_workspace_configuration =
            product_control.AutomaticWorkspaceRootConfigurationFileStore.init(
                io,
                paths.workbenchDir(),
            ) catch null;
        self.mcp_configuration = mcp_configuration.FileStore.init(
            io,
            paths.mcpDir(),
        ) catch null;

        self.task = history_store.Store.init(io, allocator, paths.workbenchDir()) catch null;
        self.task_restore_failed = self.task == null;
        self.task_restored_bytes = if (self.task) |*store|
            store.loadAlloc(allocator) catch failed: {
                self.task_restore_failed = true;
                break :failed null;
            }
        else
            null;

        // Lock order: Task history, checkpoints, attachments, then file changes.
        self.checkpoint = product_task.checkpoint_store.FileStore.init(
            io,
            paths.checkpointsDir(),
        ) catch null;
        self.checkpoint_open_failed = self.checkpoint == null;

        self.attachments = product_control.AttachmentFileStore.init(io, allocator, paths.attachmentsDir()) catch null;

        self.file_change = product_task.file_change_store.FileStore.init(
            io,
            paths.fileChangeBlobsDir(),
        ) catch null;

        self.scheduled_task = schedule_persistence.FileStore.init(
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

        self.skill_management = skill_management.FileStore.init(
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

        self.skill_enablement = skill_enablement.FileStore.init(
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

        self.skill_sources = skill_sources.FileStore.init(io, paths.workbenchDir()) catch null;
        self.skill_sources_restored = if (self.skill_sources) |*store|
            if (store.load(allocator)) |loaded| .{ .loaded = loaded } else |_| .read_failed
        else
            .unavailable;
    }

    pub fn deinit(self: *Stores) void {
        const allocator = self.allocator;
        if (self.skill_sources) |*store| store.deinit();
        if (self.skill_enablement_restored_bytes) |bytes| self.allocator.free(bytes);
        if (self.skill_enablement) |*store| store.deinit();
        if (self.skill_management_restored_bytes) |bytes| self.allocator.free(bytes);
        if (self.skill_management) |*store| store.deinit();
        if (self.scheduled_task_restored_bytes) |bytes| self.allocator.free(bytes);
        if (self.scheduled_task) |*store| store.deinit();
        if (self.task_restored_bytes) |bytes| self.allocator.free(bytes);
        if (self.file_change) |*store| store.deinit();
        if (self.attachments) |*store| store.deinit();
        if (self.checkpoint) |*store| store.deinit();
        if (self.task) |*store| store.deinit();
        if (self.mcp_configuration) |*store| store.deinit();
        if (self.automatic_workspace_configuration) |*store| store.deinit();
        self.* = .{ .allocator = allocator };
    }

    pub fn releaseTaskRestore(self: *Stores) void {
        if (self.task_restored_bytes) |bytes| {
            std.crypto.secureZero(u8, bytes);
            self.allocator.free(bytes);
            self.task_restored_bytes = null;
        }
    }
};

pub fn commitScheduledTaskStore(
    context: ?*anyopaque,
    bytes: []const u8,
) product_control.SchedulePersistenceCommit {
    const store: *schedule_persistence.FileStore = @ptrCast(
        @alignCast(context orelse return .failed),
    );
    store.commit(bytes) catch |err| return switch (err) {
        error.PersistenceOutcomeUnknown => .outcome_unknown,
        else => .failed,
    };
    return .committed;
}

pub fn recoverScheduledTaskStore(
    context: ?*anyopaque,
    bytes: []const u8,
) product_control.SchedulePersistenceCommit {
    const store: *schedule_persistence.FileStore = @ptrCast(
        @alignCast(context orelse return .failed),
    );
    store.recover(bytes) catch |err| return switch (err) {
        error.PersistenceOutcomeUnknown => .outcome_unknown,
        else => .failed,
    };
    return .committed;
}

pub fn taskStoreCredentials(context: ?*anyopaque, values: []const []const u8, complete: bool, scrub: product_task.history.CredentialScrub) product_task.history.CredentialStatus {
    const store: *history_store.Store = @ptrCast(@alignCast(context orelse return .{ .epoch = 0, .ready = false }));
    return store.syncCredentials(values, complete, scrub);
}

pub fn commitTaskStoreGeneration(context: ?*anyopaque, bytes: []const u8, epoch: u64, confirmed: bool) product_task.history.Commit {
    const store: *history_store.Store = @ptrCast(@alignCast(context orelse return .failed));
    return store.commitGeneration(bytes, epoch, confirmed);
}

pub fn resolveTaskStoreCommit(context: ?*anyopaque, bytes: []const u8) product_task.history.Commit {
    const store: *history_store.Store = @ptrCast(@alignCast(context orelse return .outcome_unknown));
    return store.resolve(bytes);
}

pub fn recoverTaskStore(
    context: ?*anyopaque,
    bytes: []const u8,
) product_task.history.Commit {
    const store: *history_store.Store = @ptrCast(
        @alignCast(context orelse return .failed),
    );
    return store.recover(bytes);
}
