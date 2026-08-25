//! Live Product Skill owner.
//! Owns scoped catalog state and asynchronous catalog job lifecycle while
//! consuming only narrow external effect ports.

const std = @import("std");
const builtin = @import("builtin");
const agent = @import("metawork_agent");
const catalog = @import("product_skill_catalog");
const enablement = @import("product_skill_enablement");
const management = @import("product_skill_management");
const policy = @import("product_skill_policy");
const ports = @import("product_skill_ports");
const state = @import("product_skill_state");

pub const Error = std.mem.Allocator.Error || error{
    CatalogLoading,
    CatalogUnavailable,
    CatalogRequestGenerationExhausted,
    ExecutorShuttingDown,
    QueueFull,
    UnknownWorkspace,
    WorkspaceEpochMismatch,
};

pub const EnablementError = enablement.Error || enablement.FileStoreError || catalog.Error || error{
    CatalogUnavailable,
    PersistenceFailed,
    StaleCatalog,
    SkillNotFound,
    UnknownWorkspace,
    WorkspaceEpochMismatch,
};

pub const Scope = union(enum) {
    personal,
    workspace: struct {
        id: u64,
        epoch: u64,
    },

    pub fn managementScope(self: Scope) management.Scope {
        return switch (self) {
            .personal => .personal,
            .workspace => |workspace| .{ .project = .{
                .workspace_id = workspace.id,
                .workspace_epoch = workspace.epoch,
            } },
        };
    }
};

pub const WorkspaceBinding = struct {
    id: u64,
    epoch: u64,
    /// Ownership transfers to Runtime on entry.
    canonical_root: []u8,
};

pub const ProjectionBudget = struct {
    context: *anyopaque,
    available_fn: *const fn (*anyopaque, usize) usize,
    replace_fn: *const fn (*anyopaque, usize, usize) void,

    fn available(self: ProjectionBudget, reclaimable: usize) usize {
        return self.available_fn(self.context, reclaimable);
    }

    fn replace(self: ProjectionBudget, old: usize, new: usize) void {
        self.replace_fn(self.context, old, new);
    }
};

pub const CatalogObserver = struct {
    context: *anyopaque,
    changed_fn: *const fn (*anyopaque, management.Scope, ?*const catalog.Snapshot) void,

    fn changed(
        self: CatalogObserver,
        scope: management.Scope,
        snapshot: ?*const catalog.Snapshot,
    ) void {
        self.changed_fn(self.context, scope, snapshot);
    }
};

pub const EnablementWorkspaces = struct {
    context: *const anyopaque,
    slot_count: usize,
    get_fn: *const fn (*const anyopaque, usize) ?enablement.WorkspaceIdentity,

    fn get(self: EnablementWorkspaces, index: usize) ?enablement.WorkspaceIdentity {
        std.debug.assert(index < self.slot_count);
        return self.get_fn(self.context, index);
    }
};

const JobState = enum(u8) { queued, running, completed, cancelled };
const JobOutcome = union(enum) { success: agent.CatalogAcquisition, failure };

const CatalogJob = struct {
    allocator: std.mem.Allocator,
    catalog_port: ports.Catalog,
    notifier: ports.Notifier,
    scope: Scope,
    request_generation: u64,
    canonical_root: []u8,
    canonical_user_home: []u8,
    epoch_token: []u8,
    state: std.atomic.Value(JobState) = .init(.queued),
    outcome: JobOutcome = .failure,

    fn execute(context: *anyopaque) void {
        const self: *CatalogJob = @ptrCast(@alignCast(context));
        const claimed = self.state.cmpxchgStrong(
            .queued,
            .running,
            .acq_rel,
            .acquire,
        );
        std.debug.assert(claimed == null);
        self.outcome = if (self.catalog_port.query(.{
            .workspace_root = self.canonical_root,
            .canonical_user_home = self.canonical_user_home,
            .workspace_epoch = self.epoch_token,
        })) |acquisition|
            .{ .success = acquisition }
        else |_|
            .failure;
        self.state.store(.completed, .release);
        _ = self.notifier.notify();
    }

    fn cancel(context: *anyopaque) void {
        const self: *CatalogJob = @ptrCast(@alignCast(context));
        const prior = self.state.cmpxchgStrong(
            .queued,
            .cancelled,
            .acq_rel,
            .acquire,
        );
        std.debug.assert(prior == null);
        _ = self.notifier.notify();
    }

    fn deinit(self: *CatalogJob) void {
        self.allocator.free(self.epoch_token);
        self.allocator.free(self.canonical_user_home);
        self.allocator.free(self.canonical_root);
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }
};

const WorkspaceCatalog = struct {
    id: u64,
    epoch: u64,
    canonical_root: []u8,
    control: state.CatalogControl = .{},
    job: ?*CatalogJob = null,
    reschedule_pending: bool = false,

    fn deinit(
        self: *WorkspaceCatalog,
        allocator: std.mem.Allocator,
        catalog_port: *const ports.Catalog,
    ) void {
        std.debug.assert(self.job == null);
        self.control.slot.deinit(catalogReleaser(catalog_port));
        allocator.free(self.canonical_root);
        self.* = undefined;
    }
};

const EnablementAuthorityCandidate = struct {
    control: *state.CatalogControl,
    snapshot: catalog.Snapshot,
};

pub const Configuration = struct {
    state: state.Configuration,
    max_workspaces: usize,
    canonical_user_home: ?[]const u8,
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    ports: ports.Ports,
    state: state.State,
    canonical_user_home: ?[]u8,
    workspaces: []?WorkspaceCatalog,
    personal_job: ?*CatalogJob = null,
    shutting_down: bool = false,

    pub fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        effect_ports: ports.Ports,
        configuration: Configuration,
        limits: state.Limits,
    ) state.InitError!Runtime {
        var product_state = try state.State.init(io, allocator, configuration.state, limits);
        errdefer product_state.deinit(allocator, catalogReleaser(&effect_ports.catalog));
        const home = if (configuration.canonical_user_home) |value|
            try allocator.dupe(u8, value)
        else
            null;
        errdefer if (home) |value| allocator.free(value);
        const workspaces = try allocator.alloc(?WorkspaceCatalog, configuration.max_workspaces);
        @memset(workspaces, null);
        return .{
            .allocator = allocator,
            .ports = effect_ports,
            .state = product_state,
            .canonical_user_home = home,
            .workspaces = workspaces,
        };
    }

    pub fn deinit(self: *Runtime) void {
        std.debug.assert(self.personal_job == null);
        for (self.workspaces) |*entry| if (entry.*) |*workspace|
            workspace.deinit(self.allocator, &self.ports.catalog);
        self.allocator.free(self.workspaces);
        if (self.canonical_user_home) |home| self.allocator.free(home);
        self.state.deinit(self.allocator, catalogReleaser(&self.ports.catalog));
        self.* = undefined;
    }

    pub fn registerWorkspaceOwned(
        self: *Runtime,
        binding: WorkspaceBinding,
        budget: ProjectionBudget,
    ) void {
        std.debug.assert(binding.id != 0 and binding.epoch != 0);
        if (self.findWorkspace(binding.id)) |workspace| {
            if (workspace.epoch == binding.epoch and
                std.mem.eql(u8, workspace.canonical_root, binding.canonical_root))
            {
                self.allocator.free(binding.canonical_root);
                return;
            }
            self.allocator.free(workspace.canonical_root);
            workspace.canonical_root = binding.canonical_root;
            workspace.epoch = binding.epoch;
            self.invalidateControlWithBudget(&workspace.control, budget);
            workspace.control.slot = .uninitialized;
            workspace.reschedule_pending = workspace.job != null;
            return;
        }
        const index = for (self.workspaces, 0..) |entry, index| {
            if (entry == null) break index;
        } else unreachable;
        self.workspaces[index] = .{
            .id = binding.id,
            .epoch = binding.epoch,
            .canonical_root = binding.canonical_root,
        };
    }

    pub fn unregisterWorkspace(self: *Runtime, id: u64, budget: ProjectionBudget) bool {
        for (self.workspaces) |*entry| {
            const workspace = &(entry.* orelse continue);
            if (workspace.id != id) continue;
            if (workspace.job != null) return false;
            const old_bytes = if (workspace.control.slot.snapshotConst()) |snapshot|
                snapshot.projected_bytes
            else
                0;
            workspace.deinit(self.allocator, &self.ports.catalog);
            budget.replace(old_bytes, 0);
            entry.* = null;
            return true;
        }
        return true;
    }

    pub fn hasWorkspaceJob(self: *const Runtime, id: u64) bool {
        const workspace = self.findWorkspaceConst(id) orelse return false;
        return workspace.job != null;
    }

    pub fn personalJobActive(self: *const Runtime) bool {
        return self.personal_job != null;
    }

    pub fn personalControl(self: *Runtime) *state.CatalogControl {
        return &self.state.catalog;
    }

    pub fn personalControlConst(self: *const Runtime) *const state.CatalogControl {
        return &self.state.catalog;
    }

    pub fn workspaceControl(self: *Runtime, id: u64, epoch: u64) Error!*state.CatalogControl {
        const workspace = self.findWorkspace(id) orelse return error.UnknownWorkspace;
        if (workspace.epoch != epoch) return error.WorkspaceEpochMismatch;
        return &workspace.control;
    }

    pub fn workspaceControlConst(
        self: *const Runtime,
        id: u64,
        epoch: u64,
    ) Error!*const state.CatalogControl {
        const workspace = self.findWorkspaceConst(id) orelse return error.UnknownWorkspace;
        if (workspace.epoch != epoch) return error.WorkspaceEpochMismatch;
        return &workspace.control;
    }

    pub fn refreshPersonal(self: *Runtime) Error!void {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        if (self.personal_job != null) return error.CatalogLoading;
        const home = self.canonical_user_home orelse {
            self.invalidateControl(&self.state.catalog);
            return error.CatalogUnavailable;
        };
        const generation = nextGeneration(self.state.catalog.request_generation) orelse
            return error.CatalogRequestGenerationExhausted;
        const job = try self.createJob(.personal, generation, home, home, "");
        errdefer job.deinit();
        try self.enqueue(job);
        self.state.catalog.request_generation = generation;
        self.personal_job = job;
    }

    pub fn refreshWorkspace(self: *Runtime, id: u64, epoch: u64) Error!void {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        const workspace = self.findWorkspace(id) orelse return error.UnknownWorkspace;
        if (workspace.epoch != epoch) return error.WorkspaceEpochMismatch;
        if (workspace.job != null) return error.CatalogLoading;
        const home = self.canonical_user_home orelse {
            self.invalidateControl(&workspace.control);
            return error.CatalogUnavailable;
        };
        const generation = nextGeneration(workspace.control.request_generation) orelse
            return error.CatalogRequestGenerationExhausted;
        const epoch_token = try std.fmt.allocPrint(self.allocator, "{d}", .{epoch});
        defer self.allocator.free(epoch_token);
        const job = try self.createJob(
            .{ .workspace = .{ .id = id, .epoch = epoch } },
            generation,
            workspace.canonical_root,
            home,
            epoch_token,
        );
        errdefer job.deinit();
        try self.enqueue(job);
        workspace.control.request_generation = generation;
        workspace.job = job;
        workspace.reschedule_pending = false;
    }

    pub fn requestWorkspaceReschedule(self: *Runtime, id: u64, epoch: u64) Error!void {
        const workspace = self.findWorkspace(id) orelse return error.UnknownWorkspace;
        if (workspace.epoch != epoch) return error.WorkspaceEpochMismatch;
        if (workspace.job != null) {
            workspace.reschedule_pending = true;
            return;
        }
        return self.refreshWorkspace(id, epoch);
    }

    pub fn sync(
        self: *Runtime,
        budget: ProjectionBudget,
        observer: CatalogObserver,
        snapshot_limits: catalog.Limits,
    ) bool {
        var changed = false;
        if (self.personal_job) |job| if (jobFinished(job)) {
            self.personal_job = null;
            self.finishJob(job, &self.state.catalog, .personal, budget, observer, snapshot_limits);
            changed = true;
        };
        for (self.workspaces) |*entry| {
            const workspace = &(entry.* orelse continue);
            const job = workspace.job orelse continue;
            if (!jobFinished(job)) continue;
            workspace.job = null;
            const current = switch (job.scope) {
                .workspace => |identity| identity.id == workspace.id and
                    identity.epoch == workspace.epoch and
                    job.request_generation == workspace.control.request_generation,
                .personal => false,
            };
            if (current and !self.shutting_down)
                self.finishJob(job, &workspace.control, job.scope, budget, observer, snapshot_limits)
            else {
                discardOutcome(self.ports.catalog, &job.outcome);
                job.deinit();
            }
            const reschedule = workspace.reschedule_pending and !self.shutting_down;
            workspace.reschedule_pending = false;
            if (reschedule)
                self.refreshWorkspace(workspace.id, workspace.epoch) catch
                    self.invalidateControl(&workspace.control);
            changed = true;
        }
        return changed;
    }

    pub fn beginShutdown(self: *Runtime) void {
        if (self.shutting_down) return;
        self.shutting_down = true;
        if (self.personal_job) |job| _ = self.ports.executor.cancel(job);
        for (self.workspaces) |*entry| {
            const workspace = &(entry.* orelse continue);
            if (workspace.job) |job| _ = self.ports.executor.cancel(job);
            workspace.reschedule_pending = false;
        }
    }

    pub fn finishShutdownAfterExecutorJoin(
        self: *Runtime,
        budget: ProjectionBudget,
        observer: CatalogObserver,
        snapshot_limits: catalog.Limits,
    ) void {
        std.debug.assert(self.shutting_down);
        _ = self.sync(budget, observer, snapshot_limits);
        self.invalidateControlWithBudget(&self.state.catalog, budget);
        for (self.workspaces) |*entry| if (entry.*) |*workspace|
            self.invalidateControlWithBudget(&workspace.control, budget);
    }

    pub fn invalidatePersonal(self: *Runtime, budget: ProjectionBudget) void {
        self.invalidateControlWithBudget(&self.state.catalog, budget);
    }

    pub fn invalidateWorkspace(self: *Runtime, id: u64, budget: ProjectionBudget) void {
        const workspace = self.findWorkspace(id) orelse return;
        self.invalidateControlWithBudget(&workspace.control, budget);
    }

    pub fn enablementHealth(self: *const Runtime) state.EnablementHealth {
        return self.state.enablement_health;
    }

    pub fn isSkillEnabled(
        self: *const Runtime,
        scope: management.Scope,
        skill_policy_key: []const u8,
    ) bool {
        return switch (scope) {
            .personal => self.state.enablement_store.isUserEnabled(skill_policy_key),
            .project => |project| self.state.enablement_store.isEnabled(.{
                .workspace_id = project.workspace_id,
                .workspace_epoch = project.workspace_epoch,
            }, skill_policy_key),
        };
    }

    pub fn enablementRevision(
        self: *const Runtime,
        scope: management.Scope,
    ) u64 {
        return switch (scope) {
            .personal => self.state.enablement_store.userRevision(),
            .project => |project| self.state.enablement_store.revision(.{
                .workspace_id = project.workspace_id,
                .workspace_epoch = project.workspace_epoch,
            }),
        };
    }

    pub fn setEnabled(
        self: *Runtime,
        mutation: state.EnablementMutation,
        budget: ProjectionBudget,
        snapshot_limits: catalog.Limits,
    ) EnablementError!u64 {
        if (self.state.enablement_health != .ready or
            self.state.enablement_file_store == null)
            return error.PersistenceFailed;
        const control: *state.CatalogControl = switch (mutation.scope) {
            .personal => personal: {
                if (mutation.state == .inherit) return error.InvalidPolicyKey;
                break :personal &self.state.catalog;
            },
            .project => |project| project_control: {
                const workspace = self.findWorkspace(project.workspace_id) orelse
                    return error.UnknownWorkspace;
                if (project.expected_workspace_epoch == 0 or
                    workspace.epoch != project.expected_workspace_epoch)
                    return error.WorkspaceEpochMismatch;
                break :project_control &workspace.control;
            },
        };
        const current = control.slot.snapshot() orelse
            return error.CatalogUnavailable;
        if (!std.mem.eql(u8, mutation.expected_catalog_revision, current.revision) or
            mutation.expected_selection_revision != current.selection_revision)
            return error.StaleCatalog;
        _ = current.findSkillByPolicyKey(mutation.skill_policy_key) orelse
            return error.SkillNotFound;

        var store_candidate = try self.state.enablement_store.clone();
        var store_candidate_owned = true;
        defer if (store_candidate_owned) store_candidate.deinit();
        const next_revision = switch (mutation.scope) {
            .personal => blk: {
                const enabled = mutation.state == .enabled;
                if (store_candidate.isUserEnabled(mutation.skill_policy_key) == enabled)
                    return mutation.expected_selection_revision;
                break :blk try store_candidate.applyUser(.{
                    .skill_policy_key = mutation.skill_policy_key,
                    .enabled = enabled,
                    .expected_revision = mutation.expected_selection_revision,
                });
            },
            .project => |project| blk: {
                const identity: enablement.WorkspaceIdentity = .{
                    .workspace_id = project.workspace_id,
                    .workspace_epoch = project.expected_workspace_epoch,
                };
                if (store_candidate.workspaceOverride(identity, mutation.skill_policy_key) == mutation.state)
                    return mutation.expected_selection_revision;
                break :blk try store_candidate.applyWorkspace(.{
                    .identity = identity,
                    .skill_policy_key = mutation.skill_policy_key,
                    .state = mutation.state,
                    .expected_revision = mutation.expected_selection_revision,
                });
            },
        };

        var authority_candidates: std.ArrayList(EnablementAuthorityCandidate) = .empty;
        defer authority_candidates.deinit(self.allocator);
        var authority_candidates_owned = true;
        defer if (authority_candidates_owned)
            for (authority_candidates.items) |*item| item.snapshot.deinit();
        switch (mutation.scope) {
            .personal => {
                try self.appendEnablementAuthorityCandidate(
                    &authority_candidates,
                    &self.state.catalog,
                    &store_candidate,
                    .personal,
                    snapshot_limits,
                );
                for (self.workspaces) |*entry| {
                    const workspace = &(entry.* orelse continue);
                    if (workspace.control.slot.snapshotConst() == null) continue;
                    try self.appendEnablementAuthorityCandidate(
                        &authority_candidates,
                        &workspace.control,
                        &store_candidate,
                        .{ .project = .{
                            .workspace_id = workspace.id,
                            .workspace_epoch = workspace.epoch,
                        } },
                        snapshot_limits,
                    );
                }
            },
            .project => |project| try self.appendEnablementAuthorityCandidate(
                &authority_candidates,
                control,
                &store_candidate,
                .{ .project = .{
                    .workspace_id = project.workspace_id,
                    .workspace_epoch = project.expected_workspace_epoch,
                } },
                snapshot_limits,
            ),
        }

        self.commitEnablementCandidate(&store_candidate) catch |err| {
            self.noteEnablementPersistenceFailure(err, budget);
            return err;
        };
        store_candidate_owned = false;
        for (authority_candidates.items) |*item| {
            const authority = &item.control.slot.committed;
            const old_bytes = authority.snapshot.projected_bytes;
            authority.snapshot.deinit();
            authority.snapshot = item.snapshot;
            budget.replace(old_bytes, authority.snapshot.projected_bytes);
        }
        authority_candidates_owned = false;
        return next_revision;
    }

    pub fn reconcileEnablementNoFail(
        self: *Runtime,
        workspaces: EnablementWorkspaces,
        budget: ProjectionBudget,
    ) void {
        if (self.state.enablement_health != .ready or
            self.state.enablement_file_store == null)
            return;
        var active_workspaces: std.ArrayList(enablement.WorkspaceIdentity) = .empty;
        defer active_workspaces.deinit(self.allocator);
        for (0..workspaces.slot_count) |index|
            if (workspaces.get(index)) |identity|
                active_workspaces.append(self.allocator, identity) catch {
                    self.state.enablement_health = .write_failed;
                    return;
                };
        var candidate = self.state.enablement_store.clone() catch {
            self.state.enablement_health = .write_failed;
            return;
        };
        var candidate_owned = true;
        defer if (candidate_owned) candidate.deinit();
        if (!candidate.reconcile(active_workspaces.items)) return;
        self.commitEnablementCandidate(&candidate) catch |err| {
            self.noteEnablementPersistenceFailure(err, budget);
            return;
        };
        candidate_owned = false;
    }

    pub fn testSetEnablementPersistence(
        self: *Runtime,
        file_store: *enablement.FileStore,
    ) void {
        comptime std.debug.assert(builtin.is_test);
        self.state.enablement_file_store = file_store;
        self.state.enablement_health = .ready;
    }

    pub fn testNoteEnablementPersistenceFailure(
        self: *Runtime,
        err: anyerror,
        budget: ProjectionBudget,
    ) void {
        comptime std.debug.assert(builtin.is_test);
        self.noteEnablementPersistenceFailure(err, budget);
    }

    fn finishJob(
        self: *Runtime,
        job: *CatalogJob,
        control: *state.CatalogControl,
        scope: Scope,
        budget: ProjectionBudget,
        observer: CatalogObserver,
        snapshot_limits: catalog.Limits,
    ) void {
        defer job.deinit();
        const current = job.request_generation == control.request_generation and
            !self.shutting_down;
        switch (job.state.load(.acquire)) {
            .completed => switch (job.outcome) {
                .success => |*acquisition| if (current) {
                    const old_bytes = if (control.slot.snapshotConst()) |old|
                        old.projected_bytes
                    else
                        0;
                    const snapshot = policy.compileCatalogSnapshot(
                        self.allocator,
                        acquisition.projection,
                        &self.state.enablement_store,
                        self.state.enablement_health,
                        scope.managementScope(),
                        snapshot_limits,
                        budget.available(old_bytes),
                    ) catch {
                        acquisition.projection.deinit();
                        self.ports.catalog.release(acquisition.lease);
                        if (control.slot.snapshotConst() == null) control.slot = .unavailable;
                        observer.changed(scope.managementScope(), null);
                        job.outcome = .failure;
                        return;
                    };
                    acquisition.projection.deinit();
                    var old_slot = control.slot;
                    control.slot = .{ .committed = .{
                        .lease = .init(acquisition.lease),
                        .snapshot = snapshot,
                    } };
                    budget.replace(old_bytes, snapshot.projected_bytes);
                    observer.changed(scope.managementScope(), control.slot.snapshotConst());
                    if (old_slot == .committed)
                        old_slot.committed.deinit(catalogReleaser(&self.ports.catalog));
                    job.outcome = .failure;
                } else {
                    acquisition.projection.deinit();
                    self.ports.catalog.release(acquisition.lease);
                    job.outcome = .failure;
                },
                .failure => if (current) {
                    if (control.slot.snapshotConst() == null) control.slot = .unavailable;
                    observer.changed(scope.managementScope(), null);
                },
            },
            .cancelled => {
                if (current and control.slot.snapshotConst() == null)
                    control.slot = .unavailable;
            },
            .queued, .running => unreachable,
        }
    }

    fn appendEnablementAuthorityCandidate(
        self: *Runtime,
        candidates: *std.ArrayList(EnablementAuthorityCandidate),
        control: *state.CatalogControl,
        store_candidate: *const enablement.Store,
        scope: management.Scope,
        snapshot_limits: catalog.Limits,
    ) (catalog.Error || std.mem.Allocator.Error)!void {
        const current = control.slot.snapshotConst() orelse return;
        var replacement = try policy.recompileCatalogSnapshot(
            self.allocator,
            current,
            store_candidate,
            scope,
            snapshot_limits,
            current.projected_bytes,
        );
        errdefer replacement.deinit();
        try candidates.append(self.allocator, .{
            .control = control,
            .snapshot = replacement,
        });
    }

    fn commitEnablementCandidate(
        self: *Runtime,
        candidate: *enablement.Store,
    ) (enablement.Error || enablement.FileStoreError)!void {
        const file_store = self.state.enablement_file_store orelse
            return error.WriteFailed;
        const output = try self.allocator.alloc(u8, enablement.max_store_bytes);
        defer self.allocator.free(output);
        const bytes = try enablement.encode(output, candidate);
        try file_store.commit(bytes);
        self.state.enablement_store.deinit();
        self.state.enablement_store = candidate.*;
        candidate.* = undefined;
    }

    fn noteEnablementPersistenceFailure(
        self: *Runtime,
        err: anyerror,
        budget: ProjectionBudget,
    ) void {
        const decision = policy.enablementPersistenceFailure(err);
        self.state.enablement_health = decision.health;
        if (!decision.invalidate_authorities) return;
        self.invalidateControlWithBudget(&self.state.catalog, budget);
        for (self.workspaces) |*entry| if (entry.*) |*workspace|
            self.invalidateControlWithBudget(&workspace.control, budget);
    }

    fn createJob(
        self: *Runtime,
        scope: Scope,
        generation: u64,
        root: []const u8,
        home: []const u8,
        epoch: []const u8,
    ) std.mem.Allocator.Error!*CatalogJob {
        const owned_root = try self.allocator.dupe(u8, root);
        errdefer self.allocator.free(owned_root);
        const owned_home = try self.allocator.dupe(u8, home);
        errdefer self.allocator.free(owned_home);
        const owned_epoch = try self.allocator.dupe(u8, epoch);
        errdefer self.allocator.free(owned_epoch);
        const job = try self.allocator.create(CatalogJob);
        job.* = .{
            .allocator = self.allocator,
            .catalog_port = self.ports.catalog,
            .notifier = self.ports.notifier,
            .scope = scope,
            .request_generation = generation,
            .canonical_root = owned_root,
            .canonical_user_home = owned_home,
            .epoch_token = owned_epoch,
        };
        return job;
    }

    fn enqueue(self: *Runtime, job: *CatalogJob) error{ ExecutorShuttingDown, QueueFull }!void {
        try self.ports.executor.enqueue(.{
            .identity = job,
            .context = job,
            .execute_fn = CatalogJob.execute,
            .cancel_fn = CatalogJob.cancel,
        });
    }

    fn invalidateControl(self: *Runtime, control: *state.CatalogControl) void {
        control.slot.deinit(catalogReleaser(&self.ports.catalog));
    }

    fn invalidateControlWithBudget(
        self: *Runtime,
        control: *state.CatalogControl,
        budget: ProjectionBudget,
    ) void {
        const old_bytes = if (control.slot.snapshotConst()) |snapshot|
            snapshot.projected_bytes
        else
            0;
        self.invalidateControl(control);
        budget.replace(old_bytes, 0);
    }

    fn findWorkspace(self: *Runtime, id: u64) ?*WorkspaceCatalog {
        for (self.workspaces) |*entry| {
            const workspace = &(entry.* orelse continue);
            if (workspace.id == id) return workspace;
        }
        return null;
    }

    fn findWorkspaceConst(self: *const Runtime, id: u64) ?*const WorkspaceCatalog {
        for (self.workspaces) |*entry| {
            const workspace = &(entry.* orelse continue);
            if (workspace.id == id) return workspace;
        }
        return null;
    }
};

fn catalogRelease(context: ?*anyopaque, lease: *agent.CatalogLease) void {
    const catalog_port: *const ports.Catalog = @ptrCast(@alignCast(context orelse unreachable));
    catalog_port.release(lease);
}

fn catalogReleaser(catalog_port: *const ports.Catalog) state.CatalogLeaseRelease {
    return .{
        .context = @constCast(catalog_port),
        .release_fn = catalogRelease,
    };
}

fn nextGeneration(current: u64) ?u64 {
    if (current == std.math.maxInt(u64)) return null;
    return current + 1;
}

fn jobFinished(job: *const CatalogJob) bool {
    return switch (job.state.load(.acquire)) {
        .completed, .cancelled => true,
        .queued, .running => false,
    };
}

fn discardOutcome(catalog_port: ports.Catalog, outcome: *JobOutcome) void {
    switch (outcome.*) {
        .success => |*acquisition| {
            acquisition.projection.deinit();
            catalog_port.release(acquisition.lease);
            outcome.* = .failure;
        },
        .failure => {},
    }
}

const TestHarness = struct {
    queued: ?ports.Job = null,
    query_count: usize = 0,
    cancel_count: usize = 0,
    notify_count: usize = 0,
    observer_count: usize = 0,
    projected_bytes: usize = 0,
    last_root: [128]u8 = undefined,
    last_root_len: usize = 0,
    last_epoch: [32]u8 = undefined,
    last_epoch_len: usize = 0,

    fn effectPorts(self: *TestHarness) ports.Ports {
        return .{
            .executor = .{
                .context = self,
                .enqueue_fn = enqueue,
                .cancel_fn = cancel,
            },
            .catalog = .{
                .context = self,
                .query_fn = query,
                .release_fn = release,
            },
            .notifier = .{
                .context = self,
                .notify_fn = notify,
            },
        };
    }

    fn budget(self: *TestHarness) ProjectionBudget {
        return .{
            .context = self,
            .available_fn = available,
            .replace_fn = replace,
        };
    }

    fn observer(self: *TestHarness) CatalogObserver {
        return .{
            .context = self,
            .changed_fn = changed,
        };
    }

    fn runQueued(self: *TestHarness) void {
        const job = self.queued orelse unreachable;
        self.queued = null;
        job.execute_fn(job.context);
    }

    fn enqueue(context: *anyopaque, job: ports.Job) error{ ExecutorShuttingDown, QueueFull }!void {
        const self: *TestHarness = @ptrCast(@alignCast(context));
        if (self.queued != null) return error.QueueFull;
        self.queued = job;
    }

    fn cancel(context: *anyopaque, identity: *anyopaque) bool {
        const self: *TestHarness = @ptrCast(@alignCast(context));
        const job = self.queued orelse return false;
        if (job.identity != identity) return false;
        self.queued = null;
        self.cancel_count += 1;
        job.cancel_fn(job.context);
        return true;
    }

    fn query(
        context: *anyopaque,
        input: agent.CatalogQuery,
    ) anyerror!agent.CatalogAcquisition {
        const self: *TestHarness = @ptrCast(@alignCast(context));
        self.query_count += 1;
        std.debug.assert(input.workspace_root.len <= self.last_root.len);
        std.debug.assert(input.workspace_epoch.len <= self.last_epoch.len);
        @memcpy(self.last_root[0..input.workspace_root.len], input.workspace_root);
        self.last_root_len = input.workspace_root.len;
        @memcpy(self.last_epoch[0..input.workspace_epoch.len], input.workspace_epoch);
        self.last_epoch_len = input.workspace_epoch.len;
        return error.QueryFailed;
    }

    fn release(_: *anyopaque, _: *agent.CatalogLease) void {
        unreachable;
    }

    fn notify(context: ?*anyopaque) bool {
        const self: *TestHarness = @ptrCast(@alignCast(context orelse unreachable));
        self.notify_count += 1;
        return true;
    }

    fn available(context: *anyopaque, reclaimable: usize) usize {
        const self: *TestHarness = @ptrCast(@alignCast(context));
        std.debug.assert(reclaimable <= self.projected_bytes);
        return 64 * 1024 - self.projected_bytes + reclaimable;
    }

    fn replace(context: *anyopaque, old: usize, new: usize) void {
        const self: *TestHarness = @ptrCast(@alignCast(context));
        std.debug.assert(old <= self.projected_bytes);
        self.projected_bytes = self.projected_bytes - old + new;
    }

    fn changed(
        context: *anyopaque,
        _: management.Scope,
        _: ?*const catalog.Snapshot,
    ) void {
        const self: *TestHarness = @ptrCast(@alignCast(context));
        self.observer_count += 1;
    }
};

const test_snapshot_limits: catalog.Limits = .{
    .max_catalog_skills = 4,
    .max_catalog_issues = 4,
    .max_skill_arguments = 4,
    .max_catalog_projection_bytes = 4096,
};

fn testRuntime(harness: *TestHarness) !Runtime {
    return Runtime.init(
        std.testing.io,
        std.testing.allocator,
        harness.effectPorts(),
        .{
            .state = .{},
            .max_workspaces = 3,
            .canonical_user_home = "/home/tester",
        },
        .{
            .max_assets = 4,
            .max_workspaces = 2,
            .max_policy_keys = 4,
            .max_policy_key_bytes = 64,
        },
    );
}

test "catalog job failure is committed by the Product Skill owner" {
    var harness: TestHarness = .{};
    var runtime = try testRuntime(&harness);
    defer runtime.deinit();
    runtime.registerWorkspaceOwned(.{
        .id = 7,
        .epoch = 3,
        .canonical_root = try std.testing.allocator.dupe(u8, "/workspace/a"),
    }, harness.budget());

    try runtime.refreshWorkspace(7, 3);
    try std.testing.expect(runtime.hasWorkspaceJob(7));
    try std.testing.expectEqual(
        catalog.CatalogAvailability.loading,
        (try runtime.workspaceControlConst(7, 3)).slot.availability(true),
    );
    harness.runQueued();
    try std.testing.expect(runtime.sync(
        harness.budget(),
        harness.observer(),
        test_snapshot_limits,
    ));

    try std.testing.expect(!runtime.hasWorkspaceJob(7));
    try std.testing.expectEqual(@as(usize, 1), harness.query_count);
    try std.testing.expectEqual(@as(usize, 1), harness.notify_count);
    try std.testing.expectEqual(@as(usize, 1), harness.observer_count);
    try std.testing.expectEqualStrings("/workspace/a", harness.last_root[0..harness.last_root_len]);
    try std.testing.expectEqualStrings("3", harness.last_epoch[0..harness.last_epoch_len]);
    try std.testing.expect((try runtime.workspaceControlConst(7, 3)).slot == .unavailable);
}

test "workspace identity replacement discards stale completion and reschedules" {
    var harness: TestHarness = .{};
    var runtime = try testRuntime(&harness);
    defer runtime.deinit();
    runtime.registerWorkspaceOwned(.{
        .id = 9,
        .epoch = 1,
        .canonical_root = try std.testing.allocator.dupe(u8, "/workspace/old"),
    }, harness.budget());
    try runtime.refreshWorkspace(9, 1);

    runtime.registerWorkspaceOwned(.{
        .id = 9,
        .epoch = 2,
        .canonical_root = try std.testing.allocator.dupe(u8, "/workspace/new"),
    }, harness.budget());
    harness.runQueued();
    try std.testing.expect(runtime.sync(
        harness.budget(),
        harness.observer(),
        test_snapshot_limits,
    ));
    try std.testing.expect(runtime.hasWorkspaceJob(9));
    try std.testing.expectEqual(@as(usize, 0), harness.observer_count);

    harness.runQueued();
    try std.testing.expect(runtime.sync(
        harness.budget(),
        harness.observer(),
        test_snapshot_limits,
    ));
    try std.testing.expectEqual(@as(usize, 2), harness.query_count);
    try std.testing.expectEqualStrings("/workspace/new", harness.last_root[0..harness.last_root_len]);
    try std.testing.expectEqualStrings("2", harness.last_epoch[0..harness.last_epoch_len]);
    try std.testing.expect((try runtime.workspaceControlConst(9, 2)).slot == .unavailable);
}

test "shutdown cancels queued catalog ownership before Runtime teardown" {
    var harness: TestHarness = .{};
    var runtime = try testRuntime(&harness);
    defer runtime.deinit();

    try runtime.refreshPersonal();
    runtime.beginShutdown();
    try std.testing.expectEqual(@as(usize, 1), harness.cancel_count);
    try std.testing.expectEqual(@as(usize, 1), harness.notify_count);
    runtime.finishShutdownAfterExecutorJoin(
        harness.budget(),
        harness.observer(),
        test_snapshot_limits,
    );

    try std.testing.expect(!runtime.personalJobActive());
    try std.testing.expect(runtime.personalControlConst().slot == .unavailable);
    try std.testing.expectError(error.ExecutorShuttingDown, runtime.refreshPersonal());
}
