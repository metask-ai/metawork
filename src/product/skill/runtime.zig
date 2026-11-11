//! Live Product Skill owner.
//! Owns scoped catalog state and asynchronous catalog job lifecycle while
//! consuming only narrow external effect ports.

const std = @import("std");
const builtin = @import("builtin");
const agent = @import("metawork_agent");
const catalog = @import("product_skill_catalog");
const enablement = @import("product_skill_enablement");
const management = @import("product_skill_management");
const management_runtime = @import("product_skill_management_runtime");
const package = @import("product_skill_package");
const policy = @import("product_skill_policy");
const ports = @import("product_skill_ports");
const state = @import("product_skill_state");
const sources = @import("product_skill_sources");
const view = @import("product_skill_view");

pub const ManagementHealth = state.ManagementHealth;
pub const ManagementConfiguration = state.ManagementConfiguration;
pub const EnablementHealth = state.EnablementHealth;
pub const EnablementConfiguration = state.EnablementConfiguration;
pub const EnablementScope = state.EnablementScope;
pub const EnablementState = state.EnablementState;
pub const EnablementMutation = state.EnablementMutation;
pub const EnablementFileStore = enablement.FileStore;
pub const EnablementFileStoreError = enablement.FileStoreError;
pub const EnablementWorkspaceIdentity = enablement.WorkspaceIdentity;
pub const InstallInput = state.InstallInput;
pub const MutationResult = state.MutationResult;
pub const ExportResult = state.ExportResult;
pub const ManagementScope = management.Scope;
pub const SourceKind = management.SourceKind;
pub const InstallId = management.InstallId;
pub const ContentHash = management.ContentHash;
pub const Preview = package.Preview;
pub const ImportTarget = state.ImportTarget;
pub const ImportEffect = state.ImportEffect;
pub const ImportReason = state.ImportReason;
pub const importReason = state.importReason;
pub const ImportOperation = state.ImportOperation;

pub const ImportPreparation = struct {
    id: u64,
    revision: u64,
    source_kind: management.SourceKind,
    scope: management.Scope,
    effect: ImportEffect,
    install_id: ?management.InstallId,
    invocation_name: []const u8,
    description: []const u8,
    definition: []const u8,
    file_count: usize,
    total_bytes: u64,
    blocker: ?ImportReason,
};

const PreparedImport = struct {
    id: u64,
    revision: u64,
    source_kind: management.SourceKind,
    path: []u8,
    preview: package.Preview,
    scope: management.Scope,
    target: ImportTarget,
    expectation: state.ImportExpectation,

    fn deinit(self: *PreparedImport, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.preview.deinit();
        self.* = undefined;
    }
};
pub const TextProjection = view.TextProjection;
pub const ScopedCatalog = view.ScopedCatalog;
pub const WorkspaceCatalogs = view.WorkspaceCatalogs;
pub const ViewError = view.Error;

/// Borrowed verified Application source. The caller keeps its current-version
/// reference until a later replacement; each dispatched job retains its own.
pub const BuiltinSource = struct {
    root: ?[]const u8,
    lifetime: ?agent.CatalogSourceLifetime = null,
};

pub const testing = if (builtin.is_test) struct {
    pub const ManagementInventory = management.Inventory;
    pub const ManagementFileStore = management.FileStore;
    pub const encodeManagement = management.encode;
} else struct {};

pub const BorrowedCatalogAuthority = struct {
    snapshot: *const catalog.Snapshot,
    lease: *agent.CatalogLease,
};

pub const CatalogAuthority = union(enum) {
    uninitialized,
    loading,
    ready: BorrowedCatalogAuthority,
    degraded: BorrowedCatalogAuthority,
    unavailable,
};

pub const Error = std.mem.Allocator.Error || error{
    CatalogLoading,
    CatalogUnavailable,
    CatalogRequestGenerationExhausted,
    ExecutorShuttingDown,
    QueueFull,
    UnknownWorkspace,
    WorkspaceEpochMismatch,
};

/// Freshness of one request, independent of the retained last-good view.
pub const CatalogPreparation = union(enum) {
    pending,
    stale,
    ready: BorrowedCatalogAuthority,
    unavailable,
};

pub const EnablementError = enablement.Error || enablement.FileStoreError || catalog.Error || error{
    CatalogUnavailable,
    PersistenceFailed,
    StaleCatalog,
    SkillNotFound,
    UnknownWorkspace,
    WorkspaceEpochMismatch,
};

pub const PackageError = management_runtime.Error;

pub const AssetError = PackageError || Error;

pub const MutationError = AssetError || error{TaskBusy};

const Scope = union(enum) {
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
    /// Control grants catalog access independently of registry membership.
    catalog_authorized: bool,
    /// Automatic data workspaces use personal policy and exclude local sources.
    personal_only: bool = false,
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

const JobState = enum(u8) { queued, running, completed, cancelled };
const JobOutcome = union(enum) { success: agent.CatalogAcquisition, failure };

const CatalogJob = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    source_roots: ports.SourceRoots,
    personal_only: bool = false,
    root_checks: ?sources.RootChecks = null,
    verification: ?state.Reconciliation = null,
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
        self.executeQuery();
        self.state.store(.completed, .release);
        _ = self.notifier.notify();
    }

    fn executeQuery(self: *CatalogJob) void {
        var discovery = self.source_roots.discover_fn(
            self.source_roots.context,
            self.io,
            self.allocator,
            self.canonical_user_home,
            if (self.scope == .personal or self.personal_only) null else self.canonical_root,
        ) catch return;
        defer discovery.deinit();
        if (self.source_roots.builtin_root) |root| discovery.appendBuiltin(self.io, root) catch return;
        self.root_checks = discovery.rootChecks();
        const additional = discovery.additionalSources() catch return;
        self.outcome = if (self.catalog_port.query(.{
            .canonical_user_home = self.canonical_user_home,
            .additional_sources = additional,
            .default_source_priority = sources.default_source_priority,
            .source_lifetime = self.source_roots.builtin_lifetime,
            .target = switch (self.scope) {
                .personal => .management,
                .workspace => .{ .workspace = .{
                    .canonical_root = self.canonical_root,
                    .epoch = self.epoch_token,
                } },
            },
        })) |acquisition|
            .{ .success = acquisition }
        else |_|
            .failure;
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
        if (self.source_roots.builtin_lifetime) |lifetime| lifetime.release();
        if (self.source_roots.builtin_root) |root| self.allocator.free(root);
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
    authorized: bool,
    personal_only: bool = false,

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
    io: std.Io,
    ports: ports.Ports,
    state: state.State,
    canonical_user_home: ?[]u8,
    workspaces: []?WorkspaceCatalog,
    personal_job: ?*CatalogJob = null,
    personal_reschedule_pending: bool = false,
    reschedule_cursor: usize = 0,
    shutting_down: bool = false,
    prepared_import: ?PreparedImport = null,
    next_preparation_id: u64 = 1,

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
            .io = io,
            .ports = effect_ports,
            .state = product_state,
            .canonical_user_home = home,
            .workspaces = workspaces,
        };
    }

    pub const SourceDiscoveryView = state.SourceDiscoveryView;

    pub fn personalSourceDiscovery(self: *const Runtime) ?SourceDiscoveryView {
        if (self.canonical_user_home == null) return null;
        return .{ .checks = self.state.catalog.source_checks, .checking = self.personal_job != null or self.personal_reschedule_pending };
    }

    pub fn workspaceSourceDiscovery(self: *const Runtime, id: u64, epoch: u64) ?SourceDiscoveryView {
        const workspace = self.findWorkspaceConst(id) orelse return null;
        if (workspace.epoch != epoch or !workspace.authorized or workspace.personal_only or self.canonical_user_home == null) return null;
        return .{ .checks = workspace.control.source_checks, .checking = workspace.job != null or workspace.reschedule_pending };
    }

    /// Owner-thread handoff only. It never touches the filesystem or changes a
    /// Task's pinned authority. In-flight jobs keep their captured root/pin and
    /// become stale before the new source can publish a catalog.
    pub fn replaceBuiltinSource(self: *Runtime, source: BuiltinSource, budget: ProjectionBudget) Error!bool {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        if (source.root) |root| {
            if (root.len == 0 or !std.fs.path.isAbsolute(root)) return error.CatalogUnavailable;
        } else if (source.lifetime != null) return error.CatalogUnavailable;
        const old = self.ports.source_roots;
        const same_root = if (source.root) |root| if (old.builtin_root) |previous| std.mem.eql(u8, root, previous) else false else old.builtin_root == null;
        const same_pin = if (source.lifetime) |pin| if (old.builtin_lifetime) |previous| pin.context == previous.context and pin.retain_fn == previous.retain_fn and pin.release_fn == previous.release_fn else false else old.builtin_lifetime == null;
        if (same_root and same_pin) return false;
        // A source switch must not silently complete an asset transaction that
        // was prepared against another query authority.
        if (self.state.reconciliation != null) return error.CatalogLoading;
        if (!self.sourceGenerationsAvailable()) return error.CatalogRequestGenerationExhausted;
        self.ports.source_roots.builtin_root = source.root;
        self.ports.source_roots.builtin_lifetime = source.lifetime;
        self.invalidateSourceControl(&self.state.catalog, budget);
        self.personal_reschedule_pending = true;
        for (self.workspaces) |*entry| if (entry.*) |*workspace| {
            if (!workspace.authorized) continue;
            self.invalidateSourceControl(&workspace.control, budget);
            workspace.reschedule_pending = true;
        };
        return true;
    }

    fn invalidateSourceControl(self: *Runtime, control: *state.CatalogControl, budget: ProjectionBudget) void {
        control.request_generation = nextGeneration(control.request_generation) orelse std.math.maxInt(u64);
        control.source_checks = null;
        self.invalidateControlWithBudget(control, budget);
    }

    fn sourceGenerationsAvailable(self: *const Runtime) bool {
        if (self.state.catalog.request_generation == std.math.maxInt(u64)) return false;
        for (self.workspaces) |entry| if (entry) |workspace| {
            if (workspace.authorized and workspace.control.request_generation == std.math.maxInt(u64)) return false;
        };
        return true;
    }

    pub fn deinit(self: *Runtime) void {
        std.debug.assert(self.personal_job == null);
        self.discardPreparedImport(null);
        for (self.workspaces) |*entry| if (entry.*) |*workspace|
            workspace.deinit(self.allocator, &self.ports.catalog);
        self.allocator.free(self.workspaces);
        if (self.canonical_user_home) |home| self.allocator.free(home);
        self.state.deinit(self.allocator, catalogReleaser(&self.ports.catalog));
        self.* = undefined;
    }

    /// Reserve before publishing Workspace authority; registration stays no-fail.
    pub fn reserveWorkspaceCapacity(self: *Runtime, count: usize) std.mem.Allocator.Error!void {
        if (count <= self.workspaces.len) return;
        const old = self.workspaces.len;
        self.workspaces = try self.allocator.realloc(self.workspaces, @max(count, @max(4, old * 2)));
        @memset(self.workspaces[old..], null);
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
                std.debug.assert(workspace.personal_only == binding.personal_only);
                self.allocator.free(binding.canonical_root);
                self.setWorkspaceCatalogAuthorized(binding.id, binding.epoch, binding.catalog_authorized, budget) catch unreachable;
                return;
            }
            self.allocator.free(workspace.canonical_root);
            workspace.canonical_root = binding.canonical_root;
            workspace.epoch = binding.epoch;
            workspace.authorized = binding.catalog_authorized;
            workspace.personal_only = binding.personal_only;
            self.invalidateSourceControl(&workspace.control, budget);
            workspace.control.slot = .uninitialized;
            workspace.reschedule_pending = binding.catalog_authorized;
            return;
        }
        const index = for (self.workspaces, 0..) |entry, index| {
            if (entry == null) break index;
        } else unreachable;
        self.workspaces[index] = .{
            .id = binding.id,
            .epoch = binding.epoch,
            .canonical_root = binding.canonical_root,
            .authorized = binding.catalog_authorized,
            .personal_only = binding.personal_only,
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

    pub fn workspaceCatalogAuthority(
        self: *const Runtime,
        id: u64,
        epoch: u64,
    ) Error!CatalogAuthority {
        const workspace = self.findWorkspaceConst(id) orelse return error.UnknownWorkspace;
        if (workspace.epoch != epoch) return error.WorkspaceEpochMismatch;
        if (!workspace.authorized) return .unavailable;
        return catalogAuthority(&workspace.control, workspace.job != null or workspace.reschedule_pending);
    }

    pub fn ensureWorkspaceCatalog(
        self: *Runtime,
        id: u64,
        epoch: u64,
        budget: ProjectionBudget,
    ) Error!void {
        const workspace = self.findWorkspace(id) orelse return error.UnknownWorkspace;
        if (workspace.epoch != epoch) return error.WorkspaceEpochMismatch;
        if (!workspace.authorized) return;
        if (workspace.control.slot != .uninitialized) return;
        self.requestWorkspaceReschedule(id, epoch) catch |err| {
            if (err == error.QueueFull) {
                workspace.reschedule_pending = true;
                return;
            }
            workspace.reschedule_pending = false;
            self.invalidateControlWithBudget(&workspace.control, budget);
        };
    }

    pub fn refreshPersonal(self: *Runtime) Error!void {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        if (self.personal_job != null) return error.CatalogLoading;
        const generation = nextGeneration(self.state.catalog.request_generation) orelse
            return error.CatalogRequestGenerationExhausted;
        try self.startPersonal(generation, null);
    }

    fn startPersonal(self: *Runtime, generation: u64, verification: ?state.Reconciliation) Error!void {
        const home = self.canonical_user_home orelse {
            self.invalidateControl(&self.state.catalog);
            return error.CatalogUnavailable;
        };
        const job = try self.createJob(.personal, generation, home, home, "", verification);
        errdefer job.deinit();
        try self.enqueue(job);
        self.state.catalog.request_generation = generation;
        self.personal_job = job;
        self.personal_reschedule_pending = false;
        self.state.catalog.source_checks = null;
    }

    pub fn ensurePersonalCatalog(self: *Runtime, budget: ProjectionBudget) void {
        if (self.personal_job != null or self.personal_reschedule_pending) return;
        self.refreshPersonal() catch |err| {
            if (err == error.QueueFull) {
                self.personal_reschedule_pending = true;
                return;
            }
            self.invalidateControlWithBudget(&self.state.catalog, budget);
        };
    }

    pub fn refreshWorkspace(self: *Runtime, id: u64, epoch: u64) Error!void {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        const workspace = self.findWorkspace(id) orelse return error.UnknownWorkspace;
        if (workspace.epoch != epoch) return error.WorkspaceEpochMismatch;
        if (!workspace.authorized) return error.CatalogUnavailable;
        if (workspace.job != null) return error.CatalogLoading;
        const generation = nextGeneration(workspace.control.request_generation) orelse
            return error.CatalogRequestGenerationExhausted;
        try self.startWorkspace(workspace, generation, null);
    }

    /// A new Run requests once. Concurrent consumers share the current query.
    /// Queue pressure keeps one intent, driven by executor completion wakes.
    pub fn prepareWorkspaceCatalog(self: *Runtime, id: u64, epoch: u64) Error!u64 {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        const workspace = self.findWorkspace(id) orelse return error.UnknownWorkspace;
        if (workspace.epoch != epoch) return error.WorkspaceEpochMismatch;
        if (!workspace.authorized)
            return error.CatalogUnavailable;
        if (workspace.job != null or workspace.reschedule_pending)
            return workspace.control.request_generation;
        const generation = nextGeneration(workspace.control.request_generation) orelse
            return error.CatalogRequestGenerationExhausted;
        workspace.control.request_generation = generation;
        workspace.reschedule_pending = true;
        self.startWorkspace(workspace, generation, null) catch |err| {
            if (err != error.QueueFull) {
                workspace.reschedule_pending = false;
                workspace.control.completed_generation = generation;
                workspace.control.query_succeeded = false;
                return err;
            }
        };
        return generation;
    }

    pub fn workspacePreparation(self: *const Runtime, id: u64, epoch: u64, generation: u64) Error!CatalogPreparation {
        const workspace = self.findWorkspaceConst(id) orelse return error.UnknownWorkspace;
        if (workspace.epoch != epoch) return error.WorkspaceEpochMismatch;
        if (!workspace.authorized or self.shutting_down)
            return .unavailable;
        if (workspace.job != null or workspace.reschedule_pending or
            workspace.control.completed_generation < generation)
            return .pending;
        if (workspace.control.needs_query or workspace.control.completed_generation != workspace.control.request_generation)
            return .stale;
        if (!workspace.control.query_succeeded)
            return .unavailable;
        const authority = &workspace.control.slot;
        return if (authority.snapshotConst()) |snapshot|
            .{ .ready = .{ .snapshot = snapshot, .lease = authority.lease() orelse return .unavailable } }
        else
            .unavailable;
    }

    fn startWorkspace(self: *Runtime, workspace: *WorkspaceCatalog, generation: u64, verification: ?state.Reconciliation) Error!void {
        const home = self.canonical_user_home orelse {
            self.invalidateControl(&workspace.control);
            return error.CatalogUnavailable;
        };
        const epoch_token = try std.fmt.allocPrint(self.allocator, "{d}", .{workspace.epoch});
        defer self.allocator.free(epoch_token);
        const job = try self.createJob(
            .{ .workspace = .{ .id = workspace.id, .epoch = workspace.epoch } },
            generation,
            workspace.canonical_root,
            home,
            epoch_token,
            verification,
        );
        errdefer job.deinit();
        try self.enqueue(job);
        workspace.control.request_generation = generation;
        workspace.job = job;
        workspace.reschedule_pending = false;
        workspace.control.source_checks = null;
    }

    fn requestWorkspaceReschedule(self: *Runtime, id: u64, epoch: u64) Error!void {
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
        snapshot_limits: catalog.Limits,
        now_unix_seconds: ?u64,
    ) bool {
        var changed = false;
        if (self.personal_job) |job| if (jobFinished(job)) {
            self.personal_job = null;
            self.finishJob(
                job,
                &self.state.catalog,
                .personal,
                budget,
                snapshot_limits,
                now_unix_seconds,
            );
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
            if (current and workspace.authorized and !self.shutting_down)
                self.finishJob(
                    job,
                    &workspace.control,
                    job.scope,
                    budget,
                    snapshot_limits,
                    now_unix_seconds,
                )
            else {
                self.clearJobVerification(job);
                discardOutcome(self.ports.catalog, &job.outcome);
                job.deinit();
            }
            changed = true;
        }
        changed = self.dispatchPending(budget) or changed;
        changed = self.refreshImportOutcome() or changed;
        changed = self.takeManagementChanged() or changed;
        return changed;
    }

    /// Completion of any executor work wakes Product sync. Queue pressure is
    /// the only automatically retried failure; one latest intent per scope is
    /// retained and each sync visits scopes once in round-robin order.
    fn dispatchPending(self: *Runtime, budget: ProjectionBudget) bool {
        if (self.shutting_down) return false;
        var changed = false;
        const count = self.workspaces.len + 1;
        for (0..count) |_| {
            const index = self.reschedule_cursor;
            self.reschedule_cursor = (index + 1) % count;
            if (index == 0) {
                if (!self.personal_reschedule_pending or self.personal_job != null) continue;
                self.startPersonal(self.state.catalog.request_generation, null) catch |err| {
                    if (err == error.QueueFull) return changed;
                    self.personal_reschedule_pending = false;
                    self.invalidateControlWithBudget(&self.state.catalog, budget);
                };
            } else {
                const workspace = &(self.workspaces[index - 1] orelse continue);
                if (!workspace.authorized or !workspace.reschedule_pending or workspace.job != null) continue;
                self.startWorkspace(workspace, workspace.control.request_generation, null) catch |err| {
                    if (err == error.QueueFull) return changed;
                    workspace.reschedule_pending = false;
                    self.invalidateControlWithBudget(&workspace.control, budget);
                };
            }
            changed = true;
        }
        return changed;
    }

    pub fn beginShutdown(self: *Runtime) void {
        if (self.shutting_down) return;
        self.shutting_down = true;
        self.personal_reschedule_pending = false;
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
        snapshot_limits: catalog.Limits,
    ) void {
        std.debug.assert(self.shutting_down);
        _ = self.sync(budget, snapshot_limits, null);
        self.invalidateControlWithBudget(&self.state.catalog, budget);
        for (self.workspaces) |*entry| if (entry.*) |*workspace|
            self.invalidateControlWithBudget(&workspace.control, budget);
    }

    /// Allocation-free authority transition. Revocation invalidates old jobs;
    /// reauthorization schedules only the latest identity after they drain.
    pub fn setWorkspaceCatalogAuthorized(self: *Runtime, id: u64, epoch: u64, authorized: bool, budget: ProjectionBudget) Error!void {
        const workspace = self.findWorkspace(id) orelse return error.UnknownWorkspace;
        if (workspace.epoch != epoch) return error.WorkspaceEpochMismatch;
        if (workspace.authorized == authorized) return;
        workspace.authorized = authorized;
        self.invalidateSourceControl(&workspace.control, budget);
        if (authorized) workspace.control.slot = .uninitialized;
        workspace.reschedule_pending = authorized;
    }

    pub fn redactCatalogsNoFail(
        self: *Runtime,
        credential: []const u8,
        budget: ProjectionBudget,
    ) void {
        if (credential.len == 0) return;
        redactControlNoFail(
            self,
            &self.state.catalog,
            credential,
            budget,
        );
        for (self.workspaces) |*entry| {
            const workspace = &(entry.* orelse continue);
            const snapshot = workspace.control.slot.snapshot() orelse continue;
            if (snapshot.identityContainsCredential(credential)) {
                workspace.reschedule_pending = false;
                self.invalidateControlWithBudget(&workspace.control, budget);
            } else {
                snapshot.redactPresentationNoFail(credential);
            }
        }
    }

    pub fn enablementHealth(self: *const Runtime) state.EnablementHealth {
        return self.state.enablement_health;
    }

    pub fn enablementTrusted(self: *const Runtime) bool {
        return policy.enablementTrusted(self.state.enablement_health);
    }

    pub fn managementHealth(self: *const Runtime) state.ManagementHealth {
        return self.state.management_health;
    }

    pub fn reconciliationPending(self: *const Runtime) bool {
        return self.state.reconciliation != null;
    }

    pub fn personalCatalogProjection(self: *const Runtime) catalog.CatalogProjection {
        return view.catalogProjection(
            self.state.catalog.slot.availability(self.personal_job != null or self.personal_reschedule_pending),
            self.state.catalog.slot.snapshotConst(),
        );
    }

    pub fn workspaceCatalogProjection(
        self: *const Runtime,
        id: u64,
        epoch: u64,
    ) Error!catalog.CatalogProjection {
        const workspace = self.findWorkspaceConst(id) orelse return error.UnknownWorkspace;
        if (workspace.epoch != epoch) return error.WorkspaceEpochMismatch;
        return view.catalogProjection(
            if (!workspace.authorized) .unavailable else workspace.control.slot.availability(workspace.job != null or workspace.reschedule_pending),
            workspace.control.slot.snapshotConst(),
        );
    }

    pub fn scopedWorkspaceCatalog(
        self: *const Runtime,
        id: u64,
        epoch: u64,
    ) ?view.ScopedCatalog {
        const workspace = self.findWorkspaceConst(id) orelse return null;
        if (workspace.epoch != epoch or !workspace.authorized) return null;
        return .{
            .scope = .{ .project = .{
                .workspace_id = id,
                .workspace_epoch = epoch,
            } },
            .snapshot = workspace.control.slot.snapshotConst() orelse return null,
        };
    }

    pub fn workspaceAuthorityStable(self: *const Runtime, id: u64, epoch: u64) bool {
        const workspace = self.findWorkspaceConst(id) orelse return false;
        return workspace.authorized and workspace.epoch == epoch and workspace.job == null and !workspace.reschedule_pending and
            workspace.control.slot.snapshotConst() != null;
    }

    pub fn snapshotStructureBounds() view.SnapshotStructureBounds {
        return .{};
    }

    pub fn writeCatalogProjection(
        writer: *std.Io.Writer,
        text: view.TextProjection,
        projection: catalog.CatalogProjection,
    ) view.Error!void {
        return view.writeCatalogProjection(writer, text, projection);
    }

    pub fn writeManagementProjection(
        self: *const Runtime,
        writer: *std.Io.Writer,
        text: view.TextProjection,
        workspaces: view.WorkspaceCatalogs,
        retry: view.RetryAvailability,
    ) view.Error!void {
        var blocker: ?ImportReason = null;
        if (self.prepared_import) |prepared| {
            blocker = (self.preparedImport(prepared.id, prepared.revision) catch unreachable).blocker;
            if (retry.import_blocker_fn) |check| blocker = check(retry.context, prepared.scope) orelse blocker;
        }
        return view.writeManagementProjection(writer, .{
            .import_prepared = self.prepared_import != null,
            .import_blocker = blocker,
            .state = &self.state,
            .workspaces = workspaces,
            .retry = retry,
            .owner = .{ .context = self, .resolve_fn = viewOwnerResolve },
            .text = text,
            .personal_source_discovery = self.personalSourceDiscovery(),
        });
    }

    pub fn writeWorkspaceSourceDiscovery(self: *const Runtime, writer: *std.Io.Writer, id: u64, epoch: u64) view.Error!void {
        return view.writeSourceDiscovery(writer, .workspace, self.workspaceSourceDiscovery(id, epoch));
    }

    /// Resolves an asset's persistent owner to the owning Workspace's current
    /// authority scope. Ownership follows the Workspace id alone; the
    /// registry, not any stored epoch, decides which record that id is.
    pub fn assetScope(
        self: *const Runtime,
        install_id: management.InstallId,
    ) AssetError!management.Scope {
        const current = self.state.inventoryConst().findConst(install_id) orelse
            return error.AssetNotFound;
        return self.resolveOwnerScope(current.owner) orelse error.UnknownWorkspace;
    }

    /// True when both Skill stores were strictly loaded, so every Workspace id
    /// they reference is known. An unreadable or corrupt store hides ids that
    /// a fresh allocation could collide with.
    pub fn identitySourceTrusted(self: *const Runtime) bool {
        const management_trusted = switch (self.state.management_health) {
            .ready, .unavailable, .write_failed => true,
            .read_failed, .corrupt, .outcome_unknown => false,
        };
        const enablement_trusted = switch (self.state.enablement_health) {
            .ready, .unavailable, .write_failed => true,
            .read_failed, .corrupt, .outcome_unknown => false,
        };
        return management_trusted and enablement_trusted;
    }

    /// True when no durable transaction still references the Workspace id and
    /// the inventory is trustworthy enough to prove it.
    pub fn workspaceRetirementAllowed(self: *const Runtime, workspace_id: u64) bool {
        switch (self.state.management_health) {
            .ready, .unavailable => {},
            .read_failed, .corrupt, .write_failed, .outcome_unknown => return false,
        }
        switch (self.state.enablement_health) {
            .ready, .unavailable => {},
            .read_failed, .corrupt, .write_failed, .outcome_unknown => return false,
        }
        return !self.state.inventoryConst().hasRecoveryFor(workspace_id);
    }

    /// Drops policy and provenance of a Workspace id that left the registry.
    /// Files are never touched. Each store commits independently; a failed
    /// commit keeps that store's records for a later attempt.
    pub fn retireWorkspace(self: *Runtime, workspace_id: u64, budget: ProjectionBudget) bool {
        std.debug.assert(self.workspaceRetirementAllowed(workspace_id));
        var changed = false;
        if (self.enablementTrusted() and self.state.enablement_file_store != null) enablement_store: {
            var candidate = self.state.enablement_store.clone() catch break :enablement_store;
            var candidate_owned = true;
            defer if (candidate_owned) candidate.deinit();
            if (!candidate.retire(workspace_id)) break :enablement_store;
            self.commitEnablementCandidate(&candidate) catch |err| {
                self.noteEnablementPersistenceFailure(err, budget);
                break :enablement_store;
            };
            candidate_owned = false;
            changed = true;
        }
        if (self.state.management_health == .ready) {
            if (self.state.transactions) |*transactions| {
                const retired = transactions.retire(workspace_id) catch |err| blk: {
                    if (err == error.PersistenceFailed or err == error.PersistenceOutcomeUnknown)
                        self.state.management_health = policy.managementHealthAfterPersistenceFailure(err);
                    break :blk true;
                };
                changed = retired or changed;
            }
        }
        return changed;
    }

    /// Maps a persistent owner to the owning Workspace's current authority
    /// scope, or null when no registered record carries that id.
    pub fn resolveOwnerScope(self: *const Runtime, owner: management.Owner) ?management.Scope {
        return switch (owner) {
            .personal => .personal,
            .project => |id| blk: {
                const workspace = self.findWorkspaceConst(id) orelse return null;
                break :blk .{ .project = .{
                    .workspace_id = workspace.id,
                    .workspace_epoch = workspace.epoch,
                } };
            },
        };
    }

    fn viewOwnerResolve(context: *const anyopaque, owner: management.Owner) ?management.Scope {
        const self: *const Runtime = @ptrCast(@alignCast(context));
        return self.resolveOwnerScope(owner);
    }

    /// Highest Workspace id referenced by any persistent Skill record.
    pub fn maxWorkspaceId(self: *const Runtime) u64 {
        var result = self.state.inventoryConst().maxWorkspaceId();
        for (self.state.enablement_store.items()) |workspace_policy|
            result = @max(result, workspace_policy.workspace_id);
        return result;
    }

    pub fn discardPreparedImport(self: *Runtime, expected_id: ?u64) void {
        const current = if (self.prepared_import) |*value| value else return;
        if (expected_id) |id| if (current.id != id) return;
        if (self.state.import_operation) |*operation| {
            if (operation.id == current.id and operation.phase == .prepared) operation.phase = .cancelled;
        }
        current.deinit(self.allocator);
        self.prepared_import = null;
    }

    fn importSourcePreview(self: *Runtime, path: []const u8, kind: management.SourceKind) PackageError!package.Preview {
        return switch (kind) {
            .local_directory => self.previewDirectory(path),
            .local_package => self.previewArchive(path),
            .external => error.InvalidAsset,
        };
    }

    fn importTargetScope(self: *const Runtime, target: ImportTarget) AssetError!management.Scope {
        return switch (target) {
            .scope => |scope| scope,
            .reimport => |id| self.assetScope(id),
        };
    }

    fn importTargetExpectation(self: *Runtime, scope: management.Scope, target: ImportTarget, invocation: []const u8) AssetError!state.ImportExpectation {
        return management_runtime.inspectImportTarget(self.managementContext(), try self.canonicalBase(scope), scope, invocation, switch (target) {
            .scope => null,
            .reimport => |id| id,
        });
    }

    pub fn prepareImport(self: *Runtime, path: []const u8, kind: management.SourceKind, target: ImportTarget) AssetError!ImportPreparation {
        try self.requireManagementReady();
        self.discardPreparedImport(null);
        if (self.next_preparation_id == std.math.maxInt(u64)) return error.PreparationExhausted;
        const scope = try self.importTargetScope(target);
        var preview = try self.importSourcePreview(path, kind);
        errdefer preview.deinit();
        const expectation = try self.importTargetExpectation(scope, target, preview.invocation_name);
        const owned_path = try self.allocator.dupe(u8, path);
        self.prepared_import = .{ .id = self.next_preparation_id, .revision = 1, .source_kind = kind, .path = owned_path, .preview = preview, .scope = scope, .target = target, .expectation = expectation };
        self.next_preparation_id += 1;
        self.recordPreparedImport();
        return self.preparedImport(self.prepared_import.?.id, 1);
    }

    pub fn preparedImport(self: *const Runtime, id: u64, revision: u64) AssetError!ImportPreparation {
        const current = self.prepared_import orelse return error.InvalidPreparation;
        if (current.id != id or current.revision != revision) return error.InvalidPreparation;
        var blocker: ?ImportReason = null;
        self.requireMutationAvailable(current.scope) catch |err| {
            blocker = state.importReason(err);
        };
        return .{
            .id = current.id,
            .revision = current.revision,
            .source_kind = current.source_kind,
            .scope = current.scope,
            .effect = current.expectation.effect,
            .install_id = current.expectation.install_id,
            .invocation_name = current.preview.invocation_name,
            .description = current.preview.description,
            .definition = current.preview.definition,
            .file_count = current.preview.file_count,
            .total_bytes = current.preview.total_bytes,
            .blocker = blocker,
        };
    }

    fn verifyImportSource(self: *Runtime, current: *const PreparedImport) AssetError!void {
        var observed = self.importSourcePreview(current.path, current.source_kind) catch |err| return if (err == error.OutOfMemory) err else error.SourceChanged;
        defer observed.deinit();
        if (!std.mem.eql(u8, &observed.content_hash, &current.preview.content_hash) or
            !std.mem.eql(u8, observed.source_root orelse "", current.preview.source_root orelse "")) return error.SourceChanged;
    }

    pub fn retargetImport(self: *Runtime, id: u64, revision: u64, target: ImportTarget) AssetError!ImportPreparation {
        errdefer |err| if (err == error.SourceChanged or err == error.TargetChanged) {
            self.discardPreparedImport(id);
            if (self.state.import_operation) |*operation| if (operation.id == id) {
                operation.phase = .rejected;
                operation.reason = state.importReason(err);
            };
        };
        _ = try self.preparedImport(id, revision);
        const current = &self.prepared_import.?;
        if (current.target == .reimport and (target != .reimport or !std.mem.eql(u8, &current.target.reimport, &target.reimport))) return error.InvalidConfirmation;
        if (current.revision == std.math.maxInt(u64)) return error.PreparationExhausted;
        try self.verifyImportSource(current);
        const scope = try self.importTargetScope(target);
        const expectation = try self.importTargetExpectation(scope, target, current.preview.invocation_name);
        current.scope = scope;
        current.target = target;
        current.expectation = expectation;
        current.revision += 1;
        self.recordPreparedImport();
        return self.preparedImport(id, current.revision);
    }

    /// Read-only pre-admission validation; no grant, files or transaction is consumed.
    pub fn validatePreparedImport(self: *Runtime, id: u64, revision: u64, confirmation: ImportEffect) MutationError!management.Scope {
        errdefer |err| if (err == error.SourceChanged or err == error.TargetChanged) {
            self.discardPreparedImport(id);
            if (self.state.import_operation) |*operation| if (operation.id == id) {
                operation.phase = .rejected;
                operation.reason = state.importReason(err);
            };
        };
        const preparation = try self.preparedImport(id, revision);
        if (preparation.effect != confirmation) return error.InvalidConfirmation;
        try self.requireMutationAvailable(preparation.scope);
        const current = &self.prepared_import.?;
        try self.verifyImportSource(current);
        const observed = self.importTargetExpectation(current.scope, current.target, current.preview.invocation_name) catch |err| return if (err == error.OutOfMemory or err == error.TaskBusy) err else error.TargetChanged;
        if (!std.meta.eql(observed, current.expectation)) return error.TargetChanged;
        return current.scope;
    }

    pub fn commitPreparedImport(self: *Runtime, id: u64, revision: u64, confirmation: ImportEffect, now: ?u64) MutationError!state.MutationResult {
        _ = try self.validatePreparedImport(id, revision, confirmation);
        var current = self.prepared_import.?;
        self.prepared_import = null;
        defer current.deinit(self.allocator);
        const result = switch (current.expectation.effect) {
            .create, .replace_directory => switch (current.source_kind) {
                .local_directory => self.installDirectory(current.path, .{ .source_kind = current.source_kind, .scope = current.scope, .expected_invocation_name = current.preview.invocation_name, .expected_content_hash = current.preview.content_hash, .allow_replace = current.expectation.effect == .replace_directory }, now),
                .local_package => self.installArchive(current.path, .{ .source_kind = current.source_kind, .scope = current.scope, .expected_invocation_name = current.preview.invocation_name, .expected_content_hash = current.preview.content_hash, .allow_replace = current.expectation.effect == .replace_directory }, now),
                .external => error.InvalidAsset,
            },
            .update => switch (current.source_kind) {
                .local_directory => self.reimportDirectory(current.expectation.install_id.?, current.path, current.preview.invocation_name, current.preview.content_hash),
                .local_package => self.reimportArchive(current.expectation.install_id.?, current.path, current.preview.invocation_name, current.preview.content_hash),
                .external => error.InvalidAsset,
            },
        } catch |err| {
            if (self.state.import_operation) |*operation| {
                operation.phase = .rejected;
                if (self.state.inventoryConst().findTarget(current.scope, current.preview.invocation_name)) |asset| {
                    operation.install_id = asset.install_id;
                    if (asset.recovery) |recovery| {
                        operation.published_hash = recovery.candidate_hash;
                        operation.phase = if (asset.requiresRecovery()) .recovery_required else .pending_verification;
                    }
                }
                if (err == error.PersistenceOutcomeUnknown or self.state.management_health == .outcome_unknown) operation.phase = .outcome_unknown;
                operation.reason = state.importReason(err);
            }
            return err;
        };
        const operation = &self.state.import_operation.?;
        operation.install_id = result.install_id;
        if (self.state.inventoryConst().findConst(result.install_id)) |asset| {
            operation.published_hash = if (asset.recovery) |recovery| recovery.candidate_hash orelse asset.content_hash else asset.content_hash;
        }
        operation.phase = if (result.verification_pending) .pending_verification else .ready;
        return result;
    }

    fn recordPreparedImport(self: *Runtime) void {
        const current = &self.prepared_import.?;
        var operation: ImportOperation = .{ .id = current.id, .revision = current.revision, .scope = current.scope, .effect = current.expectation.effect, .install_id = current.expectation.install_id, .phase = .prepared, .invocation_name = undefined, .invocation_name_len = current.preview.invocation_name.len };
        @memcpy(operation.invocation_name[0..operation.invocation_name_len], current.preview.invocation_name);
        self.state.import_operation = operation;
    }

    fn refreshImportOutcome(self: *Runtime) bool {
        const operation = if (self.state.import_operation) |*value| value else return false;
        if (operation.phase != .pending_verification and operation.phase != .recovery_required) return false;
        const id = operation.install_id orelse return false;
        const asset = self.state.inventoryConst().findConst(id);
        const phase: state.ImportPhase = if (self.state.management_health == .outcome_unknown) .outcome_unknown else if (asset) |value|
            if (value.recovery == null) (if (operation.published_hash == null or std.mem.eql(u8, &value.content_hash, &operation.published_hash.?)) .ready else .rolled_back) else if (value.requiresRecovery()) .recovery_required else .pending_verification
        else
            .rolled_back;
        if (phase == operation.phase) return false;
        operation.phase = phase;
        operation.reason = if (phase == .outcome_unknown) .outcome_unknown else null;
        return true;
    }

    pub fn previewDirectory(
        self: *Runtime,
        absolute_path: []const u8,
    ) PackageError!package.Preview {
        try self.requireManagementReady();
        return management_runtime.previewDirectory(self.managementContext(), absolute_path);
    }

    pub fn previewArchive(
        self: *Runtime,
        absolute_path: []const u8,
    ) PackageError!package.Preview {
        try self.requireManagementReady();
        return management_runtime.previewArchive(self.managementContext(), absolute_path);
    }

    pub fn readDefinition(
        self: *Runtime,
        install_id: management.InstallId,
    ) AssetError!package.Preview {
        try self.requireManagementReady();
        const scope = try self.assetScope(install_id);
        return management_runtime.readDefinition(
            self.managementContext(),
            scope,
            install_id,
            try self.canonicalBase(scope),
        );
    }

    pub fn exportPackage(
        self: *Runtime,
        install_id: management.InstallId,
        absolute_destination: []const u8,
    ) AssetError!state.ExportResult {
        try self.requireManagementReady();
        const scope = try self.assetScope(install_id);
        return management_runtime.exportPackage(
            self.managementContext(),
            scope,
            install_id,
            try self.canonicalBase(scope),
            absolute_destination,
        );
    }

    pub fn installDirectory(
        self: *Runtime,
        absolute_path: []const u8,
        input: state.InstallInput,
        now_unix_seconds: ?u64,
    ) MutationError!state.MutationResult {
        try self.requireMutationAvailable(input.scope);
        const result = try management_runtime.installDirectory(
            self.managementContext(),
            try self.canonicalBase(input.scope),
            absolute_path,
            input,
            now_unix_seconds,
        );
        self.scheduleReconciliation(input.scope) catch {
            self.state.reconciliation = null;
        };
        return result;
    }

    pub fn installArchive(
        self: *Runtime,
        absolute_path: []const u8,
        input: state.InstallInput,
        now_unix_seconds: ?u64,
    ) MutationError!state.MutationResult {
        try self.requireMutationAvailable(input.scope);
        const result = try management_runtime.installArchive(
            self.managementContext(),
            try self.canonicalBase(input.scope),
            absolute_path,
            input,
            now_unix_seconds,
        );
        self.scheduleReconciliation(input.scope) catch {
            self.state.reconciliation = null;
        };
        return result;
    }

    pub fn reimportDirectory(
        self: *Runtime,
        install_id: management.InstallId,
        absolute_path: []const u8,
        expected_invocation_name: []const u8,
        expected_content_hash: management.ContentHash,
    ) MutationError!state.MutationResult {
        const scope = try self.assetScope(install_id);
        try self.requireMutationAvailable(scope);
        const result = try management_runtime.reimportDirectory(
            self.managementContext(),
            scope,
            try self.canonicalBase(scope),
            install_id,
            absolute_path,
            expected_invocation_name,
            expected_content_hash,
        );
        self.scheduleReconciliation(scope) catch {
            self.state.reconciliation = null;
        };
        return result;
    }

    pub fn reimportArchive(
        self: *Runtime,
        install_id: management.InstallId,
        absolute_path: []const u8,
        expected_invocation_name: []const u8,
        expected_content_hash: management.ContentHash,
    ) MutationError!state.MutationResult {
        const scope = try self.assetScope(install_id);
        try self.requireMutationAvailable(scope);
        const result = try management_runtime.reimportArchive(
            self.managementContext(),
            scope,
            try self.canonicalBase(scope),
            install_id,
            absolute_path,
            expected_invocation_name,
            expected_content_hash,
        );
        self.scheduleReconciliation(scope) catch {
            self.state.reconciliation = null;
        };
        return result;
    }

    pub fn uninstall(
        self: *Runtime,
        install_id: management.InstallId,
        now_unix_seconds: ?u64,
    ) MutationError!state.MutationResult {
        const scope = try self.assetScope(install_id);
        try self.requireMutationAvailable(scope);
        const result = try management_runtime.uninstall(
            self.managementContext(),
            scope,
            try self.canonicalBase(scope),
            install_id,
            now_unix_seconds,
        );
        self.scheduleReconciliation(scope) catch {
            self.state.reconciliation = null;
        };
        return result;
    }

    pub fn retryVerification(
        self: *Runtime,
        install_id: management.InstallId,
        now_unix_seconds: ?u64,
    ) MutationError!state.MutationResult {
        const scope = try self.assetScope(install_id);
        try self.requireRecoveryAvailable(scope);
        const current = self.state.inventoryConst().findConst(install_id).?;
        if (current.recovery == null) return error.InvalidAsset;
        const result = try management_runtime.retryVerification(
            self.managementContext(),
            scope,
            install_id,
            try self.canonicalBase(scope),
            now_unix_seconds,
        );
        if (self.state.reconciliation != null) self.scheduleReconciliation(scope) catch |err| {
            self.state.reconciliation = null;
            return err;
        };
        return result;
    }

    pub fn retryAvailable(self: *const Runtime, install_id: management.InstallId) bool {
        const current = self.state.inventoryConst().findConst(install_id) orelse return false;
        if (current.recovery == null) return false;
        const scope = self.assetScope(install_id) catch return false;
        self.requireRecoveryAvailable(scope) catch return false;
        _ = self.canonicalBase(scope) catch return false;
        return true;
    }

    pub fn takeManagementChanged(self: *Runtime) bool {
        if (self.state.transactions) |*transactions| return transactions.inventory.takeChanged();
        if (self.state.inventory) |*inventory| return inventory.takeChanged();
        return false;
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

    /// The caller owns the returned array; its ID bytes borrow the original
    /// pinned projection until Agent's synchronous narrow call copies them.
    pub fn restoreCeiling(self: *const Runtime, id: u64, epoch: u64, pinned: catalog.CatalogProjection) Error![][]const u8 {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        const workspace = self.findWorkspaceConst(id) orelse return error.UnknownWorkspace;
        if (workspace.epoch != epoch) return error.WorkspaceEpochMismatch;
        if (!workspace.authorized or !self.enablementTrusted() or pinned.redacted or
            (pinned.availability != .ready and pinned.availability != .degraded)) return error.CatalogUnavailable;
        const scope: management.Scope = if (workspace.personal_only) .personal else .{ .project = .{ .workspace_id = id, .workspace_epoch = epoch } };
        var ids: std.ArrayList([]const u8) = .empty;
        errdefer ids.deinit(self.allocator);
        for (pinned.skills) |skill| {
            if (skill.enabled and self.isSkillEnabled(scope, skill.skill_policy_key) and
                policy.restoreSourceAllowed(skill, workspace.personal_only))
                try ids.append(self.allocator, skill.skill_id);
        }
        return ids.toOwnedSlice(self.allocator);
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
        if (!self.enablementTrusted() or
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

    pub fn testSetEnablementPersistence(
        self: *Runtime,
        file_store: *enablement.FileStore,
    ) void {
        comptime std.debug.assert(builtin.is_test);
        self.state.enablement_file_store = file_store;
        self.state.enablement_health = .ready;
    }

    pub fn testSetManagementHealth(
        self: *Runtime,
        health: ManagementHealth,
    ) void {
        comptime std.debug.assert(builtin.is_test);
        self.state.management_health = health;
    }

    pub fn testAddRecoveryAsset(self: *Runtime) !void {
        comptime std.debug.assert(builtin.is_test);
        const inventory = if (self.state.transactions) |*transactions| &transactions.inventory else &self.state.inventory.?;
        const id: management.InstallId = @splat(7);
        _ = try inventory.add(.{ .install_id = id, .source_kind = .local_directory, .scope = .personal, .target_entry = "review", .content_hash = @splat('a'), .installed_at_unix_seconds = 1 });
        try inventory.beginTransaction(id, .{ .operation = .install, .candidate_hash = @splat('a'), .candidate_entry = ".candidate" });
    }

    pub fn testNoteEnablementPersistenceFailure(
        self: *Runtime,
        err: anyerror,
        budget: ProjectionBudget,
    ) void {
        comptime std.debug.assert(builtin.is_test);
        self.noteEnablementPersistenceFailure(err, budget);
    }

    pub fn testInstallPersonalSnapshot(
        self: *Runtime,
        snapshot: catalog.Snapshot,
        budget: ProjectionBudget,
    ) void {
        comptime std.debug.assert(builtin.is_test);
        self.testInstallSnapshot(&self.state.catalog, snapshot, budget);
    }

    pub fn testInstallWorkspaceSnapshot(
        self: *Runtime,
        id: u64,
        epoch: u64,
        snapshot: catalog.Snapshot,
        budget: ProjectionBudget,
    ) Error!void {
        comptime std.debug.assert(builtin.is_test);
        const workspace = self.findWorkspace(id) orelse return error.UnknownWorkspace;
        if (workspace.epoch != epoch) return error.WorkspaceEpochMismatch;
        self.testInstallSnapshot(&workspace.control, snapshot, budget);
    }

    fn testInstallSnapshot(
        self: *Runtime,
        control: *state.CatalogControl,
        snapshot: catalog.Snapshot,
        budget: ProjectionBudget,
    ) void {
        comptime std.debug.assert(builtin.is_test);
        const old_bytes = if (control.slot.snapshotConst()) |old|
            old.projected_bytes
        else
            0;
        control.slot.deinit(catalogReleaser(&self.ports.catalog));
        budget.replace(old_bytes, snapshot.projected_bytes);
        control.slot = .{ .committed = .{
            .lease = .fixture(),
            .snapshot = snapshot,
        } };
    }

    fn finishJob(
        self: *Runtime,
        job: *CatalogJob,
        control: *state.CatalogControl,
        scope: Scope,
        budget: ProjectionBudget,
        snapshot_limits: catalog.Limits,
        now_unix_seconds: ?u64,
    ) void {
        defer job.deinit();
        defer self.clearJobVerification(job);
        const current = job.request_generation == control.request_generation and
            !self.shutting_down;
        if (current) {
            control.source_checks = job.root_checks;
            control.completed_generation = job.request_generation;
            control.query_succeeded = false;
            control.needs_query = false;
        }
        switch (job.state.load(.acquire)) {
            .completed => switch (job.outcome) {
                .success => |*acquisition| if (current) {
                    const old_bytes = if (control.slot.snapshotConst()) |old|
                        old.projected_bytes
                    else
                        0;
                    var snapshot = policy.compileCatalogSnapshot(
                        self.allocator,
                        acquisition.projection,
                        &self.state.enablement_store,
                        self.state.enablement_health,
                        if (job.personal_only) .personal else scope.managementScope(),
                        snapshot_limits,
                        budget.available(old_bytes),
                    ) catch {
                        acquisition.projection.deinit();
                        self.ports.catalog.release(acquisition.lease);
                        if (control.slot.snapshotConst() == null) control.slot = .unavailable;
                        self.reconcileCatalogResultNoFail(
                            job,
                            null,
                            now_unix_seconds,
                        );
                        job.outcome = .failure;
                        return;
                    };
                    if (job.personal_only) policy.restrictToPersonalSources(&snapshot);
                    acquisition.projection.deinit();
                    control.query_succeeded = true;
                    control.needs_query = false;
                    if (control.slot.snapshotConst()) |previous| {
                        if (std.mem.eql(u8, previous.revision, snapshot.revision) and
                            previous.selection_revision == snapshot.selection_revision)
                        {
                            snapshot.deinit();
                            self.ports.catalog.release(acquisition.lease);
                            self.reconcileCatalogResultNoFail(job, previous, now_unix_seconds);
                            job.outcome = .failure;
                            return;
                        }
                    }
                    var old_slot = control.slot;
                    control.slot = .{ .committed = .{
                        .lease = .init(acquisition.lease),
                        .snapshot = snapshot,
                    } };
                    budget.replace(old_bytes, snapshot.projected_bytes);
                    self.reconcileCatalogResultNoFail(
                        job,
                        control.slot.snapshotConst(),
                        now_unix_seconds,
                    );
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
                    self.reconcileCatalogResultNoFail(
                        job,
                        null,
                        now_unix_seconds,
                    );
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
            if (scope == .project and self.personalOnly(.{ .workspace = .{ .id = scope.project.workspace_id, .epoch = scope.project.workspace_epoch } })) .personal else scope,
            snapshot_limits,
            current.projected_bytes,
        );
        errdefer replacement.deinit();
        if (scope == .project and self.personalOnly(.{ .workspace = .{ .id = scope.project.workspace_id, .epoch = scope.project.workspace_epoch } })) policy.restrictToPersonalSources(&replacement);
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
        self.state.enablement_health = .ready;
    }

    fn managementContext(self: *Runtime) management_runtime.Context {
        return .{
            .allocator = self.allocator,
            .io = self.io,
            .state = &self.state,
        };
    }

    fn requireManagementReady(self: *const Runtime) PackageError!void {
        if (self.state.management_health != .ready or self.shutting_down)
            return error.PersistenceFailed;
    }

    fn requireMutationAvailable(
        self: *const Runtime,
        scope: management.Scope,
    ) MutationError!void {
        try self.requireRecoveryAvailable(scope);
    }

    fn requireRecoveryAvailable(self: *const Runtime, scope: management.Scope) MutationError!void {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        if (self.state.management_health != .ready or
            self.state.transactions == null)
            return error.PersistenceFailed;
        if (self.state.reconciliation != null) return error.TaskBusy;
        switch (scope) {
            .personal => if (self.personal_job != null or self.personal_reschedule_pending) return error.CatalogLoading,
            .project => |project| {
                const workspace = self.findWorkspaceConst(project.workspace_id) orelse
                    return error.UnknownWorkspace;
                if (workspace.epoch != project.workspace_epoch)
                    return error.WorkspaceEpochMismatch;
                if (!workspace.authorized) return error.CatalogUnavailable;
                if (workspace.job != null or workspace.reschedule_pending) return error.CatalogLoading;
            },
        }
    }

    fn canonicalBase(
        self: *const Runtime,
        scope: management.Scope,
    ) AssetError![]const u8 {
        return switch (scope) {
            .personal => self.canonical_user_home orelse error.CatalogUnavailable,
            .project => |project| root: {
                const workspace = self.findWorkspaceConst(project.workspace_id) orelse
                    return error.UnknownWorkspace;
                if (workspace.epoch != project.workspace_epoch)
                    return error.WorkspaceEpochMismatch;
                break :root workspace.canonical_root;
            },
        };
    }

    fn scheduleReconciliation(
        self: *Runtime,
        scope: management.Scope,
    ) MutationError!void {
        // Personal management verification cannot stand in for a Workspace
        // query. Dependent scopes refresh lazily at selection/Run preparation.
        for (self.workspaces) |*entry| {
            const workspace = &(entry.* orelse continue);
            if (scope == .project and scope.project.workspace_id != workspace.id) continue;
            workspace.control.needs_query = true;
            workspace.control.request_generation = nextGeneration(workspace.control.request_generation) orelse std.math.maxInt(u64);
            if (workspace.job != null) workspace.reschedule_pending = true;
        }
        var verification = self.state.reconciliation orelse return switch (scope) {
            .personal => self.refreshPersonal(),
            .project => |project| self.refreshWorkspace(project.workspace_id, project.workspace_epoch),
        };
        const control = switch (scope) {
            .personal => &self.state.catalog,
            .project => |project| &((self.findWorkspace(project.workspace_id) orelse return error.UnknownWorkspace).control),
        };
        const generation = nextGeneration(control.request_generation) orelse return error.CatalogRequestGenerationExhausted;
        verification.request_generation = generation;
        switch (scope) {
            .personal => try self.startPersonal(generation, verification),
            .project => |project| try self.startWorkspace(
                self.findWorkspace(project.workspace_id).?,
                generation,
                verification,
            ),
        }
        self.state.reconciliation = verification;
    }

    pub fn recoverTransactionsForScopeNoFail(
        self: *Runtime,
        scope: management.Scope,
        now_unix_seconds: ?u64,
    ) void {
        if (self.state.management_health != .ready or
            self.state.transactions == null)
            return;
        self.requireRecoveryAvailable(scope) catch return;
        const base = self.canonicalBase(scope) catch return;
        management_runtime.recoverNoFail(
            self.managementContext(),
            scope,
            base,
            now_unix_seconds,
        );
    }

    fn reconcileCatalogResultNoFail(
        self: *Runtime,
        job: *const CatalogJob,
        snapshot: ?*const catalog.Snapshot,
        now_unix_seconds: ?u64,
    ) void {
        if (!self.matchesJobVerification(job)) return;
        const scope = job.scope.managementScope();
        const base = self.canonicalBase(scope) catch {
            self.state.reconciliation = null;
            return;
        };
        management_runtime.reconcileNoFail(
            self.managementContext(),
            scope,
            base,
            snapshot,
            now_unix_seconds,
        );
    }

    fn matchesJobVerification(self: *const Runtime, job: *const CatalogJob) bool {
        const expected = job.verification orelse return false;
        const active = self.state.reconciliation orelse return false;
        return active.request_generation == job.request_generation and
            expected.request_generation == active.request_generation and
            std.mem.eql(u8, &active.install_id, &expected.install_id) and active.scope.eql(expected.scope) and
            active.operation == expected.operation;
    }

    fn clearJobVerification(self: *Runtime, job: *const CatalogJob) void {
        // Durable pending verification remains in Transactions. Only the
        // matching in-flight attempt loses its active owner on cancellation.
        if (self.matchesJobVerification(job)) self.state.reconciliation = null;
    }
    fn noteEnablementPersistenceFailure(
        self: *Runtime,
        err: anyerror,
        budget: ProjectionBudget,
    ) void {
        // Allocation/encoding can fail before FileStore.commit is attempted.
        // Those errors say nothing about canonical persistence health.
        if (err != error.WriteFailed and err != error.PersistenceOutcomeUnknown) return;
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
        verification: ?state.Reconciliation,
    ) Error!*CatalogJob {
        const owned_root = try self.allocator.dupe(u8, root);
        errdefer self.allocator.free(owned_root);
        const owned_home = try self.allocator.dupe(u8, home);
        errdefer self.allocator.free(owned_home);
        const owned_epoch = try self.allocator.dupe(u8, epoch);
        errdefer self.allocator.free(owned_epoch);
        const builtin_root = if (self.ports.source_roots.builtin_root) |value|
            try self.allocator.dupe(u8, value)
        else
            null;
        errdefer if (builtin_root) |value| self.allocator.free(value);
        const lifetime = self.ports.source_roots.builtin_lifetime;
        if (lifetime != null and builtin_root == null) return error.CatalogUnavailable;
        if (lifetime) |value| value.retain() catch return error.CatalogUnavailable;
        errdefer if (lifetime) |value| value.release();
        var owned_source_roots = self.ports.source_roots;
        owned_source_roots.builtin_root = builtin_root;
        const job = try self.allocator.create(CatalogJob);
        job.* = .{
            .allocator = self.allocator,
            .io = self.io,
            .source_roots = owned_source_roots,
            .personal_only = self.personalOnly(scope),
            .verification = verification,
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

    fn personalOnly(self: *const Runtime, scope: Scope) bool {
        return switch (scope) {
            .personal => false,
            .workspace => |identity| if (self.findWorkspaceConst(identity.id)) |workspace| workspace.personal_only else false,
        };
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
        control.query_succeeded = false;
        control.completed_generation = control.request_generation;
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

fn catalogAuthority(
    control: *const state.CatalogControl,
    refreshing: bool,
) CatalogAuthority {
    return switch (control.slot.availability(refreshing)) {
        .uninitialized => .uninitialized,
        .loading => .loading,
        .unavailable => .unavailable,
        .ready => .{ .ready = .{
            .snapshot = control.slot.snapshotConst() orelse unreachable,
            .lease = control.slot.lease() orelse unreachable,
        } },
        .degraded => .{ .degraded = .{
            .snapshot = control.slot.snapshotConst() orelse unreachable,
            .lease = control.slot.lease() orelse unreachable,
        } },
    };
}

fn redactControlNoFail(
    self: *Runtime,
    control: *state.CatalogControl,
    credential: []const u8,
    budget: ProjectionBudget,
) void {
    const snapshot = control.slot.snapshot() orelse return;
    if (snapshot.identityContainsCredential(credential))
        self.invalidateControlWithBudget(control, budget)
    else
        snapshot.redactPresentationNoFail(credential);
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
    queue_blocked: bool = false,
    query_count: usize = 0,
    cancel_count: usize = 0,
    notify_count: usize = 0,
    projected_bytes: usize = 0,
    last_root: [128]u8 = undefined,
    last_root_len: usize = 0,
    last_epoch: [32]u8 = undefined,
    last_epoch_len: usize = 0,
    last_source_count: usize = 0,
    last_default_source_priority: i32 = 0,
    last_source_scopes: [1]agent.CatalogSourceScope = undefined,

    last_builtin_root: [4096]u8 = undefined,
    last_builtin_root_len: usize = 0,
    last_source_lifetime: ?agent.CatalogSourceLifetime = null,

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
            .source_roots = .{ .discover_fn = discoverRoots },
        };
    }

    fn discoverRoots(_: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, _: []const u8, workspace: ?[]const u8) anyerror!sources.Discovery {
        return .{ .allocator = allocator, .default_user = .missing, .default_workspace = if (workspace != null) .missing else .disabled };
    }

    fn budget(self: *TestHarness) ProjectionBudget {
        return .{
            .context = self,
            .available_fn = available,
            .replace_fn = replace,
        };
    }

    fn runQueued(self: *TestHarness) void {
        const job = self.queued orelse unreachable;
        self.queued = null;
        job.execute_fn(job.context);
    }

    fn enqueue(context: *anyopaque, job: ports.Job) error{ ExecutorShuttingDown, QueueFull }!void {
        const self: *TestHarness = @ptrCast(@alignCast(context));
        if (self.queue_blocked or self.queued != null) return error.QueueFull;
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
        self.last_source_lifetime = input.source_lifetime;
        self.last_source_count = input.additional_sources.len;
        self.last_default_source_priority = input.default_source_priority;
        for (input.additional_sources, 0..) |source, index| {
            if (std.mem.eql(u8, source.source_instance_id, sources.builtin_source_instance_id)) {
                @memcpy(self.last_builtin_root[0..source.canonical_root.len], source.canonical_root);
                self.last_builtin_root_len = source.canonical_root.len;
            } else {
                return error.UnexpectedSource;
            }
            self.last_source_scopes[index] = source.scope;
        }
        std.debug.assert(input.workspaceRoot().len <= self.last_root.len);
        std.debug.assert(input.workspaceEpoch().len <= self.last_epoch.len);
        @memcpy(self.last_root[0..input.workspaceRoot().len], input.workspaceRoot());
        self.last_root_len = input.workspaceRoot().len;
        @memcpy(self.last_epoch[0..input.workspaceEpoch().len], input.workspaceEpoch());
        self.last_epoch_len = input.workspaceEpoch().len;
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

test "Run preparation shares a query and rejects last-good as fresh after failure" {
    var harness: TestHarness = .{};
    var runtime = try testRuntime(&harness);
    defer runtime.deinit();
    runtime.registerWorkspaceOwned(.{
        .id = 9,
        .epoch = 1,
        .catalog_authorized = true,
        .canonical_root = try std.testing.allocator.dupe(u8, "/workspace"),
    }, harness.budget());
    var previous = try catalog.Snapshot.init(std.testing.allocator, .{
        .revision = "last-good",
        .health = .healthy,
        .skills = &.{},
        .issues = &.{},
        .storage = undefined,
    }, 1, &.{}, test_snapshot_limits, 4096);
    try runtime.testInstallWorkspaceSnapshot(9, 1, previous, harness.budget());
    previous = undefined;
    const generation = try runtime.prepareWorkspaceCatalog(9, 1);
    try std.testing.expectEqual(generation, try runtime.prepareWorkspaceCatalog(9, 1));
    try std.testing.expect(try runtime.workspacePreparation(9, 1, generation) == .pending);
    harness.runQueued();
    _ = runtime.sync(harness.budget(), test_snapshot_limits, null);
    try std.testing.expectEqual(@as(usize, 1), harness.query_count);
    try std.testing.expect(try runtime.workspacePreparation(9, 1, generation) == .unavailable);
    try std.testing.expectEqualStrings("last-good", (try runtime.workspaceCatalogProjection(9, 1)).revision);
    const next = try runtime.prepareWorkspaceCatalog(9, 1);
    try std.testing.expect(next > generation);
    harness.runQueued();
    _ = runtime.sync(harness.budget(), test_snapshot_limits, null);
}

test "Run preparation retains a single ticket through executor queue pressure" {
    var harness: TestHarness = .{ .queue_blocked = true };
    var runtime = try testRuntime(&harness);
    defer runtime.deinit();
    runtime.registerWorkspaceOwned(.{
        .id = 9,
        .epoch = 1,
        .catalog_authorized = true,
        .canonical_root = try std.testing.allocator.dupe(u8, "/workspace"),
    }, harness.budget());
    const generation = try runtime.prepareWorkspaceCatalog(9, 1);
    try std.testing.expectEqual(generation, try runtime.prepareWorkspaceCatalog(9, 1));
    try std.testing.expect(try runtime.workspacePreparation(9, 1, generation) == .pending);
    harness.queue_blocked = false;
    _ = runtime.sync(harness.budget(), test_snapshot_limits, null);
    harness.runQueued();
    _ = runtime.sync(harness.budget(), test_snapshot_limits, null);
    try std.testing.expect(try runtime.workspacePreparation(9, 1, generation) == .unavailable);
    try std.testing.expectError(error.WorkspaceEpochMismatch, runtime.workspacePreparation(9, 2, generation));
}

test "Skill restore ceiling retains pinned IDs under current source and Workspace grants" {
    const Check = struct {
        fn ids(runtime: *const Runtime, workspace_id: u64, pinned: catalog.CatalogProjection, expected: []const []const u8) !void {
            const actual = try runtime.restoreCeiling(workspace_id, 1, pinned);
            defer runtime.allocator.free(actual);
            try std.testing.expectEqual(expected.len, actual.len);
            for (actual, expected) |got, wanted| try std.testing.expectEqualStrings(wanted, got);
        }
    };
    var harness: TestHarness = .{};
    var runtime = try testRuntime(&harness);
    defer runtime.deinit();
    runtime.state.enablement_health = .ready;
    runtime.registerWorkspaceOwned(.{
        .id = 9,
        .epoch = 1,
        .catalog_authorized = true,
        .canonical_root = try std.testing.allocator.dupe(u8, "/manual"),
    }, harness.budget());
    runtime.registerWorkspaceOwned(.{
        .id = 10,
        .epoch = 1,
        .catalog_authorized = true,
        .personal_only = true,
        .canonical_root = try std.testing.allocator.dupe(u8, "/automatic"),
    }, harness.budget());
    const template: catalog.SkillProjection = .{
        .skill_id = "pinned-review",
        .skill_policy_key = "review",
        .invocation_name = "review",
        .provider_id = "agents.directory",
        .source_scope = .user,
        .source_instance_id = "agents.user.default",
        .contribution_id = "original-contribution",
        .content_revision = "original-content",
        .display_name = "Review",
        .description = "",
        .argument_names = &.{},
        .max_values = 1,
    };
    var skills = [_]catalog.SkillProjection{template} ** 7;
    skills[1].skill_id = "pinned-project";
    skills[1].skill_policy_key = "project";
    skills[1].source_instance_id = "agents.workspace.default";
    skills[1].source_scope = .workspace;
    skills[2].skill_id = "pinned-codex";
    skills[2].skill_policy_key = "codex";
    skills[2].source_instance_id = "compat.codex.user";
    skills[3].enabled = false;
    skills[4].source_instance_id = "unknown-source";
    skills[5].provider_id = "unknown-provider";
    skills[6].source_instance_id = "compat.codex.user";
    skills[6].source_scope = .workspace;
    var pinned: catalog.CatalogProjection = .{ .availability = .ready, .revision = "original-catalog", .skills = &skills };
    // No latest catalog is needed: the original query lease owns the content.
    try Check.ids(&runtime, 9, pinned, &.{ "pinned-review", "pinned-project" });
    try Check.ids(&runtime, 10, pinned, &.{"pinned-review"});
    try std.testing.expectEqual(@as(usize, 0), harness.query_count);
    _ = try runtime.state.enablement_store.applyUser(.{ .skill_policy_key = "review", .enabled = false, .expected_revision = runtime.state.enablement_store.userRevision() });
    try Check.ids(&runtime, 9, pinned, &.{"pinned-project"});
    _ = try runtime.state.enablement_store.applyWorkspace(.{ .identity = .{ .workspace_id = 9, .workspace_epoch = 1 }, .skill_policy_key = "review", .state = .enabled, .expected_revision = runtime.state.enablement_store.revision(.{ .workspace_id = 9, .workspace_epoch = 1 }) });
    try Check.ids(&runtime, 9, pinned, &.{ "pinned-review", "pinned-project" });
    // Automatic Tasks ignore another Workspace's overrides and local sources.
    try Check.ids(&runtime, 10, pinned, &.{});
    try std.testing.expectEqualStrings("pinned-review", skills[0].skill_id);
    try std.testing.expect(skills[0].enabled);
    try std.testing.expectEqualStrings("original-content", skills[0].content_revision);
    try std.testing.expectError(error.UnknownWorkspace, runtime.restoreCeiling(11, 1, pinned));
    try std.testing.expectError(error.WorkspaceEpochMismatch, runtime.restoreCeiling(9, 2, pinned));
    pinned.redacted = true;
    try std.testing.expectError(error.CatalogUnavailable, runtime.restoreCeiling(9, 1, pinned));
    pinned.redacted = false;
    for ([_]state.EnablementHealth{ .unavailable, .read_failed, .corrupt, .outcome_unknown }) |health| {
        runtime.state.enablement_health = health;
        try std.testing.expectError(error.CatalogUnavailable, runtime.restoreCeiling(9, 1, pinned));
    }
    runtime.state.enablement_health = .write_failed;
    try Check.ids(&runtime, 9, pinned, &.{ "pinned-review", "pinned-project" });
    runtime.findWorkspace(9).?.authorized = false;
    try std.testing.expectError(error.CatalogUnavailable, runtime.restoreCeiling(9, 1, pinned));
    runtime.findWorkspace(9).?.authorized = true;
    try Check.ids(&runtime, 9, pinned, &.{ "pinned-review", "pinned-project" });
    runtime.shutting_down = true;
    try std.testing.expectError(error.ExecutorShuttingDown, runtime.restoreCeiling(9, 1, pinned));
}

fn exerciseManagementCommitFailure(
    fault: management.TestSupport.FileStoreCommitFault,
    expected_error: anyerror,
    expected_health: ManagementHealth,
) !void {
    var harness: TestHarness = .{};
    var home = std.testing.tmpDir(.{});
    defer home.cleanup();
    var source = std.testing.tmpDir(.{ .iterate = true });
    defer source.cleanup();
    try source.dir.writeFile(std.testing.io, .{
        .sub_path = "SKILL.md",
        .data = "---\nname: demo\ndescription: Demo\n---\n",
    });
    var staging = std.testing.tmpDir(.{});
    defer staging.cleanup();
    var persistence_dir = std.testing.tmpDir(.{});
    defer persistence_dir.cleanup();
    var persistence: management.FileStore = .{
        .io = std.testing.io,
        .dir = persistence_dir.dir,
    };
    var home_path_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home_path_len = try home.dir.realPath(std.testing.io, &home_path_storage);
    var source_path_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const source_path_len = try source.dir.realPath(std.testing.io, &source_path_storage);
    var staging_path_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const staging_path_len = try staging.dir.realPath(std.testing.io, &staging_path_storage);
    var preview = try package.previewDirectory(
        std.testing.io,
        std.testing.allocator,
        source.dir,
        .{},
    );
    defer preview.deinit();
    var runtime = try Runtime.init(
        std.testing.io,
        std.testing.allocator,
        harness.effectPorts(),
        .{
            .state = .{ .management = .{
                .file_store = &persistence,
                .staging_root = staging_path_storage[0..staging_path_len],
            } },
            .max_workspaces = 1,
            .canonical_user_home = home_path_storage[0..home_path_len],
        },
        .{
            .max_assets = 4,
            .max_workspaces = 1,
            .max_policy_keys = 4,
            .max_policy_key_bytes = 64,
        },
    );
    defer runtime.deinit();
    management.TestSupport.setFileStoreCommitFault(&persistence, fault);

    const install_input: InstallInput = .{
        .source_kind = .local_directory,
        .scope = .personal,
        .expected_invocation_name = preview.invocation_name,
        .expected_content_hash = preview.content_hash,
    };
    if (runtime.installDirectory(
        source_path_storage[0..source_path_len],
        install_input,
        100,
    )) |_| {
        return error.TestUnexpectedResult;
    } else |err| {
        try std.testing.expectEqual(expected_error, err);
    }
    try std.testing.expectEqual(expected_health, runtime.managementHealth());
    try std.testing.expectError(
        error.PersistenceFailed,
        runtime.installDirectory(
            source_path_storage[0..source_path_len],
            install_input,
            101,
        ),
    );
}

test "asset ownership follows the registered Workspace id across fencing epochs" {
    var harness: TestHarness = .{};
    var runtime = try testRuntime(&harness);
    defer runtime.deinit();
    runtime.registerWorkspaceOwned(.{
        .id = 9,
        .epoch = 1,
        .catalog_authorized = true,
        .canonical_root = try std.testing.allocator.dupe(u8, "/workspace/a"),
    }, harness.budget());
    const inventory = &runtime.state.inventory.?;
    const created: management.InstallId = @splat(1);
    _ = try inventory.add(.{ .install_id = created, .source_kind = .local_directory, .scope = .{ .project = .{ .workspace_id = 9, .workspace_epoch = 1 } }, .target_entry = "review", .content_hash = @splat('a'), .installed_at_unix_seconds = 1 });
    _ = try runtime.state.enablement_store.applyWorkspace(.{
        .identity = .{ .workspace_id = 9, .workspace_epoch = 1 },
        .skill_policy_key = "review",
        .state = .disabled,
        .expected_revision = 1,
    });
    try std.testing.expect((try runtime.assetScope(created)).eql(.{ .project = .{ .workspace_id = 9, .workspace_epoch = 1 } }));
    // A failed removal leaves the same registry record at a higher epoch.
    runtime.registerWorkspaceOwned(.{
        .id = 9,
        .epoch = 2,
        .catalog_authorized = true,
        .canonical_root = try std.testing.allocator.dupe(u8, "/workspace/a"),
    }, harness.budget());
    const current: management.Scope = .{ .project = .{ .workspace_id = 9, .workspace_epoch = 2 } };
    try std.testing.expect((try runtime.assetScope(created)).eql(current));
    try std.testing.expect(runtime.resolveOwnerScope(.{ .project = 9 }).?.eql(current));
    try std.testing.expect(!runtime.isSkillEnabled(current, "review"));
    try std.testing.expectEqual(@as(u64, 2), runtime.enablementRevision(current));
    try std.testing.expect(runtime.workspaceRetirementAllowed(9));
    // A record naming an unregistered id has no owner and cannot be managed.
    const unknown: management.InstallId = @splat(3);
    _ = try inventory.add(.{ .install_id = unknown, .source_kind = .local_directory, .scope = .{ .project = .{ .workspace_id = 11, .workspace_epoch = 1 } }, .target_entry = "gone", .content_hash = @splat('a'), .installed_at_unix_seconds = 1 });
    try std.testing.expectError(error.UnknownWorkspace, runtime.assetScope(unknown));
    try std.testing.expect(runtime.resolveOwnerScope(.{ .project = 11 }) == null);
    try std.testing.expectEqual(@as(u64, 11), runtime.maxWorkspaceId());
    try inventory.beginTransaction(unknown, .{ .operation = .install, .candidate_entry = ".gone.candidate" });
    try std.testing.expect(!runtime.workspaceRetirementAllowed(11));
    try std.testing.expect(inventory.find(unknown) != null);
    // Identity is trusted only while both stores were strictly loaded.
    try std.testing.expect(runtime.identitySourceTrusted());
    runtime.state.management_health = .read_failed;
    try std.testing.expect(!runtime.identitySourceTrusted());
    runtime.state.management_health = .unavailable;
    runtime.state.enablement_health = .corrupt;
    try std.testing.expect(!runtime.identitySourceTrusted());
    runtime.state.enablement_health = .write_failed;
    try std.testing.expect(runtime.identitySourceTrusted());
    try std.testing.expect(!runtime.workspaceRetirementAllowed(9));
    runtime.state.enablement_health = .ready;
    try std.testing.expect(runtime.identitySourceTrusted());
    try std.testing.expect(runtime.workspaceRetirementAllowed(9));
    runtime.state.management_health = .write_failed;
    try std.testing.expect(runtime.identitySourceTrusted());
    try std.testing.expect(!runtime.workspaceRetirementAllowed(9));
}

test "retiring a Workspace id drops policy and provenance in both stores and keeps durable transactions" {
    var harness: TestHarness = .{};
    var staging = std.testing.tmpDir(.{});
    defer staging.cleanup();
    var staging_path_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const staging_path_len = try staging.dir.realPath(std.testing.io, &staging_path_storage);
    var storage = std.testing.tmpDir(.{});
    defer storage.cleanup();
    var enablement_dir = std.testing.tmpDir(.{});
    defer enablement_dir.cleanup();
    var persistence: management.FileStore = .{ .io = std.testing.io, .dir = storage.dir };
    var runtime = try Runtime.init(std.testing.io, std.testing.allocator, harness.effectPorts(), .{
        .state = .{
            .management = .{ .file_store = &persistence, .staging_root = staging_path_storage[0..staging_path_len] },
        },
        .max_workspaces = 2,
        .canonical_user_home = "/home/tester",
    }, .{ .max_assets = 8, .max_workspaces = 2, .max_policy_keys = 4, .max_policy_key_bytes = 64 });
    defer runtime.deinit();
    var enablement_file: enablement.FileStore = .{ .io = std.testing.io, .dir = enablement_dir.dir };
    runtime.testSetEnablementPersistence(&enablement_file);
    const transactions = &runtime.state.transactions.?;
    for ([_]u64{ 9, 11 }) |workspace_id| {
        _ = try transactions.inventory.add(.{ .install_id = @splat(@intCast(workspace_id)), .source_kind = .local_directory, .scope = .{ .project = .{ .workspace_id = workspace_id, .workspace_epoch = 1 } }, .target_entry = "review", .content_hash = @splat('a'), .installed_at_unix_seconds = 1 });
        _ = try runtime.state.enablement_store.applyWorkspace(.{
            .identity = .{ .workspace_id = workspace_id, .workspace_epoch = 1 },
            .skill_policy_key = "review",
            .state = .disabled,
            .expected_revision = runtime.state.enablement_store.revision(.{ .workspace_id = workspace_id, .workspace_epoch = 1 }),
        });
    }
    const pending: management.InstallId = @splat(20);
    _ = try transactions.inventory.add(.{ .install_id = pending, .source_kind = .local_directory, .scope = .{ .project = .{ .workspace_id = 9, .workspace_epoch = 1 } }, .target_entry = "pending", .content_hash = @splat('a'), .installed_at_unix_seconds = 1 });
    try transactions.inventory.beginTransaction(pending, .{ .operation = .install, .candidate_entry = ".pending.candidate" });
    _ = runtime.takeManagementChanged();
    try std.testing.expect(!runtime.workspaceRetirementAllowed(9));
    try std.testing.expect(runtime.workspaceRetirementAllowed(11));
    // Retirement happens when the registry slot of a hidden id is reused.
    try std.testing.expect(runtime.retireWorkspace(11, harness.budget()));
    try std.testing.expect(runtime.takeManagementChanged());
    try std.testing.expectEqual(@as(usize, 2), transactions.inventory.items().len);
    try std.testing.expect(transactions.inventory.findConst(@splat(11)) == null);
    try std.testing.expect(transactions.inventory.findConst(pending) != null);
    try std.testing.expectEqual(@as(usize, 1), runtime.state.enablement_store.items().len);
    try std.testing.expectEqual(@as(u64, 9), runtime.state.enablement_store.items()[0].workspace_id);
    try std.testing.expectEqual(ManagementHealth.ready, runtime.managementHealth());
    try std.testing.expectEqual(state.EnablementHealth.ready, runtime.enablementHealth());
    const bytes = (try persistence.loadAlloc(std.testing.allocator)).?;
    defer std.testing.allocator.free(bytes);
    var restored = try management.decode(std.testing.allocator, bytes, .{ .max_assets = 8 });
    defer restored.deinit();
    try std.testing.expectEqual(@as(usize, 2), restored.items().len);
    const policy_bytes = (try enablement_file.loadAlloc(std.testing.allocator)).?;
    defer std.testing.allocator.free(policy_bytes);
    try std.testing.expect(std.mem.indexOf(u8, policy_bytes, "\"workspace_id\":11") == null);
    // Resolving the transaction makes the id retirable; a definite write
    // failure keeps the store frozen rather than pretending success.
    try transactions.inventory.clearTransaction(pending);
    try std.testing.expect(runtime.workspaceRetirementAllowed(9));
    management.TestSupport.setFileStoreCommitFault(&persistence, .write_failed);
    try std.testing.expect(runtime.retireWorkspace(9, harness.budget()));
    try std.testing.expectEqual(ManagementHealth.write_failed, runtime.managementHealth());
    try std.testing.expect(!runtime.workspaceRetirementAllowed(9));
    try std.testing.expectEqual(@as(usize, 0), runtime.state.enablement_store.items().len);
}

test "management outcome unknown freezes subsequent Skill mutations" {
    try exerciseManagementCommitFailure(
        .outcome_unknown,
        error.PersistenceOutcomeUnknown,
        .outcome_unknown,
    );
}

test "rename failures recover only their asset and explicit retry preserves admission" {
    const Operation = enum { install, replace, reimport, uninstall };
    const definition = "---\nname: demo\ndescription: Demo\n---\n";
    for (std.enums.values(Operation)) |operation| {
        for ([_]bool{ false, true }) |fail_recovery| {
            var harness: TestHarness = .{};
            var home = std.testing.tmpDir(.{ .iterate = true });
            defer home.cleanup();
            var source = std.testing.tmpDir(.{ .iterate = true });
            defer source.cleanup();
            var storage = std.testing.tmpDir(.{});
            defer storage.cleanup();
            try source.dir.writeFile(std.testing.io, .{ .sub_path = "SKILL.md", .data = definition });
            var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const home_path = home_buffer[0..try home.dir.realPath(std.testing.io, &home_buffer)];
            var source_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const source_path = source_buffer[0..try source.dir.realPath(std.testing.io, &source_buffer)];
            var persistence: management.FileStore = .{ .io = std.testing.io, .dir = storage.dir };
            var runtime = try Runtime.init(std.testing.io, std.testing.allocator, harness.effectPorts(), .{
                .state = .{
                    .management = .{ .file_store = &persistence, .staging_root = source_path },
                },
                .max_workspaces = 1,
                .canonical_user_home = home_path,
            }, .{ .max_assets = 4, .max_workspaces = 1, .max_policy_keys = 4, .max_policy_key_bytes = 64 });
            defer runtime.deinit();
            var preview = try package.previewDirectory(std.testing.io, std.testing.allocator, source.dir, .{});
            defer preview.deinit();
            const owned = operation == .reimport or operation == .uninstall;
            const id: management.InstallId = @splat(5);
            if (operation != .install) {
                try home.dir.createDirPath(std.testing.io, ".agents/skills/demo");
                try home.dir.writeFile(std.testing.io, .{ .sub_path = ".agents/skills/demo/SKILL.md", .data = definition });
            }
            const transactions = &runtime.state.transactions.?;
            if (owned) _ = try transactions.inventory.add(.{
                .install_id = id,
                .source_kind = .local_directory,
                .scope = .personal,
                .target_entry = "demo",
                .content_hash = preview.content_hash,
                .installed_at_unix_seconds = 99,
            });
            const unrelated_id: management.InstallId = @splat(9);
            _ = try transactions.inventory.add(.{ .install_id = unrelated_id, .source_kind = .local_directory, .scope = .personal, .target_entry = "unrelated", .content_hash = preview.content_hash, .installed_at_unix_seconds = 99 });
            try transactions.inventory.beginTransaction(unrelated_id, .{ .operation = .install, .remove_asset_on_rollback = true, .candidate_hash = preview.content_hash, .candidate_entry = ".unrelated-candidate" });
            _ = runtime.takeManagementChanged();
            management.TestSupport.setRenameFault(transactions, if (operation == .uninstall) .target_to_backup else .candidate_to_target);
            if (fail_recovery) management.TestSupport.setRecoveryFault(transactions, .before_recovery);
            const result = switch (operation) {
                .install, .replace => runtime.installDirectory(source_path, .{
                    .source_kind = .local_directory,
                    .scope = .personal,
                    .expected_invocation_name = preview.invocation_name,
                    .expected_content_hash = preview.content_hash,
                    .allow_replace = operation == .replace,
                }, 100),
                .reimport => runtime.reimportDirectory(id, source_path, preview.invocation_name, preview.content_hash),
                .uninstall => runtime.uninstall(id, 100),
            };
            try std.testing.expectError(error.FileTransactionFailed, result);
            try std.testing.expectEqual(ManagementHealth.ready, runtime.managementHealth());
            try std.testing.expect(runtime.takeManagementChanged());
            try std.testing.expect(!runtime.takeManagementChanged());
            try std.testing.expect(runtime.personal_job == null and runtime.state.reconciliation == null);
            if (fail_recovery) {
                const recovery_id = if (owned) id else transactions.inventory.items()[transactions.inventory.items().len - 1].install_id;
                try std.testing.expect(transactions.inventory.findConst(recovery_id).?.recovery != null);
                try std.testing.expect(runtime.retryAvailable(recovery_id));
                runtime.personal_reschedule_pending = true;
                try std.testing.expect(!runtime.retryAvailable(recovery_id));
                try std.testing.expectError(error.CatalogLoading, runtime.retryVerification(recovery_id, 101));
                runtime.personal_reschedule_pending = false;
                try std.testing.expectError(error.FileTransactionFailed, runtime.retryVerification(recovery_id, 101));
                try std.testing.expect(!runtime.takeManagementChanged());
                var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
                {
                    runtime.allocator = failing.allocator();
                    defer runtime.allocator = std.testing.allocator;
                    runtime.recoverTransactionsForScopeNoFail(.personal, 101);
                }
                try std.testing.expect(failing.has_induced_failure);
                try std.testing.expectEqual(ManagementHealth.ready, runtime.managementHealth());
                try std.testing.expect(!runtime.takeManagementChanged());
                management.TestSupport.setRecoveryFault(transactions, .none);
                var inaccessible = std.testing.tmpDir(.{});
                defer inaccessible.cleanup();
                try inaccessible.dir.writeFile(std.testing.io, .{ .sub_path = ".agents", .data = "not a directory" });
                var inaccessible_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
                const inaccessible_path = inaccessible_buffer[0..try inaccessible.dir.realPath(std.testing.io, &inaccessible_buffer)];
                {
                    const original_home = runtime.canonical_user_home;
                    runtime.canonical_user_home = inaccessible_path;
                    defer runtime.canonical_user_home = original_home;
                    try std.testing.expectError(error.RootUnavailable, runtime.retryVerification(recovery_id, 101));
                    try std.testing.expectEqual(ManagementHealth.ready, runtime.managementHealth());
                    try std.testing.expect(!runtime.takeManagementChanged());
                }
                // Physical recovery is independent of catalog readiness.
                try std.testing.expect(runtime.retryAvailable(recovery_id));
                const recovered = try runtime.retryVerification(recovery_id, null);
                try std.testing.expect(!recovered.verification_pending);
                try std.testing.expect(runtime.takeManagementChanged());
                try std.testing.expect(runtime.personal_job == null and runtime.state.reconciliation == null);
            }
            try std.testing.expect(transactions.inventory.findConst(unrelated_id).?.recovery.?.phase == .prepared);
            try std.testing.expectEqual(@as(usize, if (owned) 2 else 1), transactions.inventory.items().len);
            if (owned) try std.testing.expect(transactions.inventory.findConst(id).?.recovery == null);
            if (operation == .install) {
                try std.testing.expectError(error.FileNotFound, home.dir.statFile(std.testing.io, ".agents/skills/demo", .{}));
            } else {
                const bytes = try home.dir.readFileAlloc(std.testing.io, ".agents/skills/demo/SKILL.md", std.testing.allocator, .limited(4096));
                defer std.testing.allocator.free(bytes);
                try std.testing.expectEqualStrings(definition, bytes);
            }
            const bytes = (try persistence.loadAlloc(std.testing.allocator)).?;
            defer std.testing.allocator.free(bytes);
            var restored = try management.decode(std.testing.allocator, bytes, .{ .max_assets = 4 });
            defer restored.deinit();
            try std.testing.expectEqual(transactions.inventory.items().len, restored.items().len);
            for (restored.items()) |asset| try std.testing.expect((asset.recovery != null) == std.mem.eql(u8, &asset.install_id, &unrelated_id));
            if (owned) {
                // Final cleanup can fail after the durable phase advanced,
                // while the legacy asset state still says pending_verification.
                management.TestSupport.setRenameFault(transactions, .none);
                const root_path = try std.fs.path.join(std.testing.allocator, &.{ home_path, ".agents", "skills" });
                defer std.testing.allocator.free(root_path);
                var root = try management.CanonicalRoot.open(std.testing.io, std.testing.allocator, .personal, root_path);
                defer root.deinit();
                var manifest = try package.inspectDirectory(std.testing.io, std.testing.allocator, source.dir, .{});
                defer manifest.deinit();
                try transactions.reimport(&root, id, source.dir, &manifest);
                try transactions.markReconciliationUnavailable(id);
                management.TestSupport.setRecoveryFault(transactions, .backup_cleanup);
                try std.testing.expectError(error.FileTransactionFailed, transactions.commitReconciliation(&root, id, null, 102));
                try std.testing.expect(transactions.inventory.findConst(id).?.state == .pending_verification);
                try std.testing.expect(transactions.inventory.findConst(id).?.requiresRecovery());
                const committed_bytes = (try persistence.loadAlloc(std.testing.allocator)).?;
                defer std.testing.allocator.free(committed_bytes);
                var restart_inventory = try management.decode(std.testing.allocator, committed_bytes, .{ .max_assets = 4 });
                defer restart_inventory.deinit();
                try std.testing.expect(restart_inventory.findConst(id).?.requiresRecovery());
                management.TestSupport.setRecoveryFault(transactions, .none);
                try std.testing.expect(runtime.retryAvailable(id));
                try std.testing.expectError(error.RecoveryUnavailable, runtime.retryVerification(id, null));
                try std.testing.expectEqual(ManagementHealth.ready, runtime.managementHealth());
                try std.testing.expect(!(try runtime.retryVerification(id, 103)).verification_pending);
                try std.testing.expect(transactions.inventory.findConst(id).?.recovery == null);
                if (operation == .uninstall and fail_recovery) {
                    try transactions.uninstall(&root, id);
                    try std.testing.expect(runtime.retryAvailable(id));
                    try std.testing.expect((try runtime.retryVerification(id, 106)).verification_pending);
                    try std.testing.expect(runtime.state.reconciliation.?.request_generation != 0);
                    try std.testing.expect(runtime.personal_job != null and !runtime.retryAvailable(id));
                    try std.testing.expectError(error.TaskBusy, runtime.retryVerification(id, 107));
                    harness.runQueued();
                    _ = runtime.sync(harness.budget(), test_snapshot_limits, 108);
                }
                if (builtin.os.tag == .windows and operation == .uninstall and !fail_recovery) {
                    const windows = std.os.windows;
                    var name = windows.UNICODE_STRING.init(std.unicode.utf8ToUtf16LeStringLiteral("demo"));
                    const attributes: windows.OBJECT.ATTRIBUTES = .{ .RootDirectory = root.dir.handle, .ObjectName = &name };
                    var locked: windows.HANDLE = undefined;
                    var status: windows.IO_STATUS_BLOCK = undefined;
                    // Real OS sharing violation, not a transaction fault hook.
                    try std.testing.expectEqual(windows.NTSTATUS.SUCCESS, windows.ntdll.NtCreateFile(
                        &locked,
                        .{ .GENERIC = .{ .READ = true }, .STANDARD = .{ .SYNCHRONIZE = true } },
                        &attributes,
                        &status,
                        null,
                        .{},
                        .{ .READ = true, .WRITE = true, .DELETE = false },
                        .OPEN,
                        .{ .DIRECTORY_FILE = true, .IO = .SYNCHRONOUS_NONALERT },
                        null,
                        0,
                    ));
                    defer _ = windows.ntdll.NtClose(locked);
                    runtime.state.enablement_health = .ready;
                    try std.testing.expectError(error.FileTransactionFailed, runtime.uninstall(id, 104));
                    try std.testing.expectEqual(ManagementHealth.ready, runtime.managementHealth());
                    try std.testing.expect(transactions.inventory.findConst(id).?.recovery == null);
                    _ = try root.dir.statFile(std.testing.io, "demo/SKILL.md", .{});
                }
            }
        }
    }
}

test "management definite write failure is observable and blocks retry" {
    try exerciseManagementCommitFailure(
        .write_failed,
        error.PersistenceFailed,
        .write_failed,
    );
}

test "recovery persistence failure freezes ahead memory and restarts from strict canonical inventory" {
    for ([_]management.TestSupport.FileStoreCommitFault{ .write_failed, .outcome_unknown }) |fault| {
        var home = std.testing.tmpDir(.{});
        defer home.cleanup();
        var source = std.testing.tmpDir(.{ .iterate = true });
        defer source.cleanup();
        var storage = std.testing.tmpDir(.{});
        defer storage.cleanup();
        try source.dir.writeFile(std.testing.io, .{ .sub_path = "SKILL.md", .data = "---\nname: demo\ndescription: Demo\n---\n" });
        var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const home_path = home_buffer[0..try home.dir.realPath(std.testing.io, &home_buffer)];
        var source_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const source_path = source_buffer[0..try source.dir.realPath(std.testing.io, &source_buffer)];
        var persistence: management.FileStore = .{ .io = std.testing.io, .dir = storage.dir };
        var configuration: Configuration = .{
            .state = .{
                .management = .{ .file_store = &persistence, .staging_root = source_path },
            },
            .max_workspaces = 1,
            .canonical_user_home = home_path,
        };
        const limits: state.Limits = .{ .max_assets = 4, .max_workspaces = 1, .max_policy_keys = 4, .max_policy_key_bytes = 64 };
        var id: management.InstallId = undefined;
        {
            var harness: TestHarness = .{};
            var runtime = try Runtime.init(std.testing.io, std.testing.allocator, harness.effectPorts(), configuration, limits);
            defer runtime.deinit();
            var preview = try runtime.previewDirectory(source_path);
            defer preview.deinit();
            management.TestSupport.setRenameFault(&runtime.state.transactions.?, .candidate_to_target);
            management.TestSupport.setRecoveryFault(&runtime.state.transactions.?, .before_recovery);
            try std.testing.expectError(error.FileTransactionFailed, runtime.installDirectory(source_path, .{
                .source_kind = .local_directory,
                .scope = .personal,
                .expected_invocation_name = preview.invocation_name,
                .expected_content_hash = preview.content_hash,
            }, 100));
            id = runtime.state.inventoryConst().items()[0].install_id;
            _ = runtime.takeManagementChanged();
            management.TestSupport.setRecoveryFault(&runtime.state.transactions.?, .none);
            management.TestSupport.setFileStoreCommitFault(&persistence, fault);
            const expected_error = if (fault == .write_failed) error.PersistenceFailed else error.PersistenceOutcomeUnknown;
            try std.testing.expectError(expected_error, runtime.retryVerification(id, 101));
            try std.testing.expectEqual(if (fault == .write_failed) ManagementHealth.write_failed else ManagementHealth.outcome_unknown, runtime.managementHealth());
            try std.testing.expect(runtime.takeManagementChanged());
            try std.testing.expect(runtime.state.inventoryConst().findConst(id) == null);
            try std.testing.expectError(error.PersistenceFailed, runtime.requireRecoveryAvailable(.personal));
        }
        // All process-local transaction state has been destroyed. Only the
        // actual canonical file is supplied to the next Runtime constructor.
        management.TestSupport.setFileStoreCommitFault(&persistence, .none);
        const bytes = (try persistence.loadAlloc(std.testing.allocator)).?;
        defer std.testing.allocator.free(bytes);
        configuration.state.management.restored_bytes = bytes;
        var restarted_harness: TestHarness = .{};
        var restarted = try Runtime.init(std.testing.io, std.testing.allocator, restarted_harness.effectPorts(), configuration, limits);
        defer restarted.deinit();
        try std.testing.expectEqual(ManagementHealth.ready, restarted.managementHealth());
        try std.testing.expect(restarted.state.inventoryConst().findConst(id).?.requiresRecovery());
        try std.testing.expect(!(try restarted.retryVerification(id, 102)).verification_pending);
        try std.testing.expect(restarted.state.inventoryConst().findConst(id) == null);
        try std.testing.expectError(error.FileNotFound, home.dir.statFile(std.testing.io, ".agents/skills/demo", .{}));
    }
}

test "management mutation and failed catalog reconciliation stay inside Runtime" {
    var harness: TestHarness = .{};
    var home = std.testing.tmpDir(.{});
    defer home.cleanup();
    var source = std.testing.tmpDir(.{ .iterate = true });
    defer source.cleanup();
    try source.dir.writeFile(std.testing.io, .{
        .sub_path = "SKILL.md",
        .data = "---\nname: demo\ndescription: Demo\n---\n",
    });
    var staging = std.testing.tmpDir(.{});
    defer staging.cleanup();
    var persistence_dir = std.testing.tmpDir(.{});
    defer persistence_dir.cleanup();
    var persistence: management.FileStore = .{
        .io = std.testing.io,
        .dir = persistence_dir.dir,
    };
    var home_path_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home_path_len = try home.dir.realPath(std.testing.io, &home_path_storage);
    const home_path = home_path_storage[0..home_path_len];
    var source_path_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const source_path_len = try source.dir.realPath(std.testing.io, &source_path_storage);
    const source_path = source_path_storage[0..source_path_len];
    var staging_path_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const staging_path_len = try staging.dir.realPath(std.testing.io, &staging_path_storage);
    const staging_path = staging_path_storage[0..staging_path_len];
    var preview = try package.previewDirectory(
        std.testing.io,
        std.testing.allocator,
        source.dir,
        .{},
    );
    defer preview.deinit();
    var runtime = try Runtime.init(
        std.testing.io,
        std.testing.allocator,
        harness.effectPorts(),
        .{
            .state = .{ .management = .{
                .file_store = &persistence,
                .staging_root = staging_path,
            } },
            .max_workspaces = 1,
            .canonical_user_home = home_path,
        },
        .{
            .max_assets = 4,
            .max_workspaces = 1,
            .max_policy_keys = 4,
            .max_policy_key_bytes = 64,
        },
    );
    defer runtime.deinit();

    const installed = try runtime.installDirectory(
        source_path,
        .{
            .source_kind = .local_directory,
            .scope = .personal,
            .expected_invocation_name = preview.invocation_name,
            .expected_content_hash = preview.content_hash,
        },
        100,
    );
    try std.testing.expect(installed.verification_pending);
    try std.testing.expect(runtime.state.reconciliation != null);
    const verification = runtime.state.reconciliation.?;
    try std.testing.expect(runtime.personal_job != null);
    try std.testing.expect(runtime.state.inventoryConst().findConst(installed.install_id) != null);

    harness.runQueued();
    try std.testing.expect(runtime.sync(
        harness.budget(),
        test_snapshot_limits,
        101,
    ));
    try std.testing.expect(runtime.state.reconciliation == null);
    try std.testing.expect(runtime.state.inventoryConst().findConst(installed.install_id).?.recovery != null);

    const external = [_]agent.CatalogSkill{.{
        .skill_id = "demo",
        .skill_policy_key = "demo",
        .invocation_name = "demo",
        .provider_id = "agents.directory",
        .source_scope = .workspace,
        .source_instance_id = "compat.claude.user",
        .contribution_id = "external",
        .content_revision = "opaque",
        .display_name = "External demo",
        .description = "External",
        .argument_names = &.{},
        .max_values = 0,
    }};
    var current = try catalog.Snapshot.init(std.testing.allocator, .{
        .revision = "test-catalog",
        .health = .healthy,
        .skills = &external,
        .issues = &.{},
        .storage = undefined,
    }, 1, &.{}, test_snapshot_limits, 4096);
    defer current.deinit();
    runtime.state.reconciliation = verification;
    management_runtime.reconcileNoFail(runtime.managementContext(), .personal, home_path, &current, 101);
    try std.testing.expect(runtime.state.inventoryConst().findConst(installed.install_id).?.recovery != null);
    // A same-name winner from another source neither verifies nor rolls back
    // our published candidate. Nor can exact provenance accept changed bytes.
    current.skills[0].source_instance_id = "agents.workspace.default";
    const changed_definition = ".agents/skills/demo/SKILL.md";
    try home.dir.writeFile(std.testing.io, .{ .sub_path = changed_definition, .data = "changed after publish" });
    runtime.state.reconciliation = verification;
    management_runtime.reconcileNoFail(runtime.managementContext(), .personal, home_path, &current, 101);
    try std.testing.expect(runtime.state.inventoryConst().findConst(installed.install_id).?.recovery != null);
    try home.dir.writeFile(std.testing.io, .{ .sub_path = changed_definition, .data = "---\nname: demo\ndescription: Demo\n---\n" });

    runtime.recoverTransactionsForScopeNoFail(.personal, 102);
    const removed = try runtime.uninstall(installed.install_id, 103);
    try std.testing.expect(!removed.verification_pending);
    try std.testing.expect(runtime.state.inventoryConst().findConst(installed.install_id) == null);
    harness.runQueued();
    _ = runtime.sync(harness.budget(), test_snapshot_limits, 104);

    const reinstalled = try runtime.installDirectory(source_path, .{
        .source_kind = .local_directory,
        .scope = .personal,
        .expected_invocation_name = preview.invocation_name,
        .expected_content_hash = preview.content_hash,
    }, 105);
    management_runtime.reconcileNoFail(runtime.managementContext(), .personal, home_path, &current, 106);
    try std.testing.expectEqual(management.ManagementState.ready, runtime.state.inventoryConst().findConst(reinstalled.install_id).?.state);
    harness.runQueued();
    _ = runtime.sync(harness.budget(), test_snapshot_limits, 106);
    _ = try runtime.uninstall(reinstalled.install_id, 107);
    current.skills[0].source_instance_id = "compat.claude.user";
    var conflict = [_]catalog.CatalogIssueProjection{.{
        .kind = .conflict,
        .code = .source_conflict,
        .reason = null,
        .skill_policy_key = "demo",
        .provider_id = "agents.directory",
        .source_scope = .workspace,
        .source_instance_id = "compat.claude.user",
    }};
    current.issues = &conflict;
    management_runtime.reconcileNoFail(runtime.managementContext(), .personal, home_path, &current, 108);
    try std.testing.expect(runtime.state.inventoryConst().findConst(reinstalled.install_id) == null);
    harness.runQueued();
    _ = runtime.sync(harness.budget(), test_snapshot_limits, 108);

    const rejected = try runtime.installDirectory(source_path, .{
        .source_kind = .local_directory,
        .scope = .personal,
        .expected_invocation_name = preview.invocation_name,
        .expected_content_hash = preview.content_hash,
    }, 109);
    current.skills = &.{};
    // Other-source problems stay pending; a provable own-source conflict
    // rejects the unchanged candidate through the existing rollback owner.
    const rejection_attempt = runtime.state.reconciliation.?;
    management_runtime.reconcileNoFail(runtime.managementContext(), .personal, home_path, &current, 110);
    try std.testing.expect(runtime.state.inventoryConst().findConst(rejected.install_id) != null);
    conflict[0].source_instance_id = "agents.workspace.default";
    runtime.state.reconciliation = rejection_attempt;
    management_runtime.reconcileNoFail(runtime.managementContext(), .personal, home_path, &current, 110);
    try std.testing.expect(runtime.state.inventoryConst().findConst(rejected.install_id) == null);
    harness.runQueued();
    _ = runtime.sync(harness.budget(), test_snapshot_limits, 110);
}

test "installed definition read and export resolve managed root inside Runtime" {
    var harness: TestHarness = .{};
    var home = std.testing.tmpDir(.{});
    defer home.cleanup();
    try home.dir.createDir(std.testing.io, ".agents", .default_dir);
    const agents = try home.dir.openDir(std.testing.io, ".agents", .{});
    defer agents.close(std.testing.io);
    try agents.createDir(std.testing.io, "skills", .default_dir);
    const skills = try agents.openDir(std.testing.io, "skills", .{});
    defer skills.close(std.testing.io);
    try skills.createDir(std.testing.io, "demo", .default_dir);
    try skills.writeFile(std.testing.io, .{
        .sub_path = "demo/SKILL.md",
        .data = "---\nname: demo\ndescription: Demo\n---\n",
    });

    const install_id: management.InstallId = @splat(0x2a);
    var inventory = management.Inventory.init(
        std.testing.allocator,
        .{ .max_assets = 4 },
    );
    defer inventory.deinit();
    _ = try inventory.add(.{
        .install_id = install_id,
        .source_kind = .external,
        .scope = .personal,
        .target_entry = "demo",
        .content_hash = @splat(0x17),
        .installed_at_unix_seconds = 100,
    });
    const restored_storage = try std.testing.allocator.alloc(
        u8,
        management.max_store_bytes,
    );
    defer std.testing.allocator.free(restored_storage);
    const restored = try management.encode(restored_storage, &inventory);

    var persistence_dir = std.testing.tmpDir(.{});
    defer persistence_dir.cleanup();
    var persistence: management.FileStore = .{
        .io = std.testing.io,
        .dir = persistence_dir.dir,
    };
    var staging = std.testing.tmpDir(.{});
    defer staging.cleanup();
    var export_dir = std.testing.tmpDir(.{});
    defer export_dir.cleanup();
    var home_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home_len = try home.dir.realPath(std.testing.io, &home_storage);
    var staging_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const staging_len = try staging.dir.realPath(std.testing.io, &staging_storage);
    var export_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const export_len = try export_dir.dir.realPath(std.testing.io, &export_storage);

    var runtime = try Runtime.init(
        std.testing.io,
        std.testing.allocator,
        harness.effectPorts(),
        .{
            .state = .{ .management = .{
                .file_store = &persistence,
                .staging_root = staging_storage[0..staging_len],
                .restored_bytes = restored,
            } },
            .max_workspaces = 1,
            .canonical_user_home = home_storage[0..home_len],
        },
        .{
            .max_assets = 4,
            .max_workspaces = 1,
            .max_policy_keys = 4,
            .max_policy_key_bytes = 64,
        },
    );
    defer runtime.deinit();

    var preview = try runtime.readDefinition(install_id);
    defer preview.deinit();
    try std.testing.expectEqualStrings("demo", preview.invocation_name);
    const exported = try runtime.exportPackage(
        install_id,
        export_storage[0..export_len],
    );
    try std.testing.expectEqualStrings("demo.skill", exported.fileName());
    const exported_stat = try export_dir.dir.statFile(
        std.testing.io,
        exported.fileName(),
        .{ .follow_symlinks = false },
    );
    try std.testing.expectEqual(std.Io.File.Kind.file, exported_stat.kind);
}

test "catalog job failure is committed by the Product Skill owner" {
    var harness: TestHarness = .{};
    var runtime = try testRuntime(&harness);
    defer runtime.deinit();
    runtime.registerWorkspaceOwned(.{
        .id = 7,
        .epoch = 3,
        .catalog_authorized = true,
        .canonical_root = try std.testing.allocator.dupe(u8, "/workspace/a"),
    }, harness.budget());

    try runtime.refreshWorkspace(7, 3);
    try std.testing.expect(runtime.hasWorkspaceJob(7));
    try std.testing.expectEqual(
        catalog.CatalogAvailability.loading,
        (try runtime.workspaceCatalogProjection(7, 3)).availability,
    );
    harness.runQueued();
    try std.testing.expect(runtime.sync(
        harness.budget(),
        test_snapshot_limits,
        null,
    ));

    try std.testing.expect(!runtime.hasWorkspaceJob(7));
    try std.testing.expectEqual(@as(usize, 1), harness.query_count);
    try std.testing.expectEqual(@as(usize, 1), harness.notify_count);
    try std.testing.expectEqualStrings("/workspace/a", harness.last_root[0..harness.last_root_len]);
    try std.testing.expectEqualStrings("3", harness.last_epoch[0..harness.last_epoch_len]);
    try std.testing.expectEqual(
        catalog.CatalogAvailability.unavailable,
        (try runtime.workspaceCatalogProjection(7, 3)).availability,
    );
}

test "workspace identity replacement discards stale completion and reschedules" {
    var harness: TestHarness = .{};
    var runtime = try testRuntime(&harness);
    defer runtime.deinit();
    runtime.registerWorkspaceOwned(.{
        .id = 9,
        .epoch = 1,
        .catalog_authorized = true,
        .canonical_root = try std.testing.allocator.dupe(u8, "/workspace/old"),
    }, harness.budget());
    try runtime.refreshWorkspace(9, 1);

    runtime.registerWorkspaceOwned(.{
        .id = 9,
        .epoch = 2,
        .catalog_authorized = true,
        .canonical_root = try std.testing.allocator.dupe(u8, "/workspace/new"),
    }, harness.budget());
    harness.runQueued();
    try std.testing.expect(runtime.sync(
        harness.budget(),
        test_snapshot_limits,
        null,
    ));
    try std.testing.expect(runtime.hasWorkspaceJob(9));

    harness.runQueued();
    try std.testing.expect(runtime.sync(
        harness.budget(),
        test_snapshot_limits,
        null,
    ));
    try std.testing.expectEqual(@as(usize, 2), harness.query_count);
    try std.testing.expectEqualStrings("/workspace/new", harness.last_root[0..harness.last_root_len]);
    try std.testing.expectEqualStrings("2", harness.last_epoch[0..harness.last_epoch_len]);
    try std.testing.expectEqual(
        catalog.CatalogAvailability.unavailable,
        (try runtime.workspaceCatalogProjection(9, 2)).availability,
    );
}

test "Workspace invalidation cancels replacement reschedule after stale completion" {
    var harness: TestHarness = .{};
    var runtime = try testRuntime(&harness);
    defer runtime.deinit();
    runtime.registerWorkspaceOwned(.{
        .id = 9,
        .epoch = 1,
        .catalog_authorized = true,
        .canonical_root = try std.testing.allocator.dupe(u8, "/workspace/old"),
    }, harness.budget());
    try runtime.refreshWorkspace(9, 1);

    runtime.registerWorkspaceOwned(.{
        .id = 9,
        .epoch = 2,
        .catalog_authorized = true,
        .canonical_root = try std.testing.allocator.dupe(u8, "/workspace/removed"),
    }, harness.budget());
    try runtime.setWorkspaceCatalogAuthorized(9, 2, false, harness.budget());
    harness.runQueued();
    try std.testing.expect(runtime.sync(
        harness.budget(),
        test_snapshot_limits,
        null,
    ));

    try std.testing.expectEqual(@as(usize, 1), harness.query_count);
    try std.testing.expect(harness.queued == null);
    try std.testing.expect(!runtime.hasWorkspaceJob(9));
    try std.testing.expectEqual(
        catalog.CatalogAvailability.unavailable,
        (try runtime.workspaceCatalogProjection(9, 2)).availability,
    );
}

test "Workspace catalog authorization changes discard old work and coalesce reauthorization" {
    var harness: TestHarness = .{};
    var runtime = try testRuntime(&harness);
    defer runtime.deinit();
    runtime.registerWorkspaceOwned(.{
        .id = 9,
        .epoch = 1,
        .catalog_authorized = true,
        .canonical_root = try std.testing.allocator.dupe(u8, "/workspace/a"),
    }, harness.budget());
    try runtime.refreshWorkspace(9, 1);
    const old_generation = runtime.findWorkspace(9).?.control.request_generation;
    // Registration must apply revocation even when identity/root did not change.
    runtime.registerWorkspaceOwned(.{
        .id = 9,
        .epoch = 1,
        .catalog_authorized = false,
        .canonical_root = try std.testing.allocator.dupe(u8, "/workspace/a"),
    }, harness.budget());
    try std.testing.expect(runtime.workspaceSourceDiscovery(9, 1) == null);
    try std.testing.expectError(error.CatalogUnavailable, runtime.refreshWorkspace(9, 1));
    try std.testing.expectError(error.UnknownWorkspace, runtime.setWorkspaceCatalogAuthorized(8, 1, true, harness.budget()));
    try std.testing.expectError(error.WorkspaceEpochMismatch, runtime.setWorkspaceCatalogAuthorized(9, 2, true, harness.budget()));
    try std.testing.expect(!runtime.findWorkspace(9).?.authorized);
    try runtime.setWorkspaceCatalogAuthorized(9, 1, true, harness.budget());
    const latest_generation = runtime.findWorkspace(9).?.control.request_generation;
    try std.testing.expect(latest_generation > old_generation);
    runtime.registerWorkspaceOwned(.{
        .id = 9,
        .epoch = 1,
        .catalog_authorized = true,
        .canonical_root = try std.testing.allocator.dupe(u8, "/workspace/a"),
    }, harness.budget());
    try std.testing.expectEqual(latest_generation, runtime.findWorkspace(9).?.control.request_generation);
    harness.queue_blocked = true;
    harness.runQueued();
    _ = runtime.sync(harness.budget(), test_snapshot_limits, null);
    const workspace = runtime.findWorkspace(9).?;
    try std.testing.expect(workspace.control.source_checks == null);
    try std.testing.expect(workspace.reschedule_pending and workspace.job == null);
    try std.testing.expectEqual(@as(usize, 1), harness.query_count);
    harness.queue_blocked = false;
    _ = runtime.sync(harness.budget(), test_snapshot_limits, null);
    harness.runQueued();
    _ = runtime.sync(harness.budget(), test_snapshot_limits, null);
    try std.testing.expect(workspace.control.source_checks != null);
    try std.testing.expect(!workspace.reschedule_pending and workspace.job == null);
    try runtime.setWorkspaceCatalogAuthorized(9, 1, true, harness.budget());
    _ = runtime.sync(harness.budget(), test_snapshot_limits, null);
    try std.testing.expectEqual(@as(usize, 2), harness.query_count);
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
        test_snapshot_limits,
    );

    try std.testing.expect(runtime.personal_job == null);
    try std.testing.expectEqual(
        catalog.CatalogAvailability.unavailable,
        runtime.personalCatalogProjection().availability,
    );
    try std.testing.expectError(error.ExecutorShuttingDown, runtime.refreshPersonal());
}

test "ordinary or stale jobs cannot complete or clear another transaction verification" {
    var harness: TestHarness = .{};
    var runtime = try testRuntime(&harness);
    defer runtime.deinit();
    var active: state.Reconciliation = .{
        .install_id = @splat(7),
        .scope = .personal,
        .operation = .install,
        .invocation_name = undefined,
        .invocation_name_len = 4,
        .request_generation = 3,
    };
    @memcpy(active.invocation_name[0..4], "demo");
    runtime.state.reconciliation = active;
    const normal = try runtime.createJob(.personal, 3, "/home/tester", "/home/tester", "", null);
    defer normal.deinit();
    runtime.reconcileCatalogResultNoFail(normal, null, null);
    runtime.clearJobVerification(normal);
    try std.testing.expect(runtime.state.reconciliation != null);
    const stale = try runtime.createJob(.personal, 2, "/home/tester", "/home/tester", "", active);
    defer stale.deinit();
    runtime.clearJobVerification(stale);
    try std.testing.expect(runtime.state.reconciliation != null);
    const exact = try runtime.createJob(.personal, 3, "/home/tester", "/home/tester", "", active);
    defer exact.deinit();
    runtime.clearJobVerification(exact);
    try std.testing.expect(runtime.state.reconciliation == null);
}

test "source worker resolves real fixed roots and refuses partial catalog on blocked default root" {
    var harness: TestHarness = .{};
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".claude/skills");
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);
    var effect_ports = harness.effectPorts();
    effect_ports.source_roots = .{};
    var runtime = try Runtime.init(std.testing.io, std.testing.allocator, effect_ports, .{
        .state = .{},
        .max_workspaces = 1,
        .canonical_user_home = home,
    }, .{ .max_assets = 2, .max_workspaces = 1, .max_policy_keys = 2, .max_policy_key_bytes = 64 });
    defer runtime.deinit();
    try runtime.refreshPersonal();
    harness.runQueued();
    _ = runtime.sync(harness.budget(), test_snapshot_limits, null);
    try std.testing.expectEqual(sources.default_source_priority, harness.last_default_source_priority);
    try std.testing.expectEqual(@as(usize, 0), harness.last_source_count);
    try std.testing.expectEqual(sources.RootCheck.missing, runtime.state.catalog.source_checks.?.default_user);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".agents", .data = "not a directory" });
    try runtime.refreshPersonal();
    harness.runQueued();
    _ = runtime.sync(harness.budget(), test_snapshot_limits, null);
    try std.testing.expectEqual(@as(usize, 1), harness.query_count);
    try std.testing.expectEqual(sources.RootFailure.unsupported_entry, runtime.state.catalog.source_checks.?.default_user.blocked);
    try std.testing.expectEqual(catalog.CatalogAvailability.unavailable, runtime.personalCatalogProjection().availability);
}

test "source pending dispatch allocation failure is explicit and not automatically retried" {
    var harness: TestHarness = .{};
    var runtime = try testRuntime(&harness);
    defer runtime.deinit();
    runtime.personal_reschedule_pending = true;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    runtime.allocator = failing.allocator();
    try std.testing.expect(runtime.sync(harness.budget(), test_snapshot_limits, null));
    runtime.allocator = std.testing.allocator;
    try std.testing.expect(!runtime.personal_reschedule_pending and runtime.personal_job == null);
    try std.testing.expectEqual(catalog.CatalogAvailability.unavailable, runtime.personalCatalogProjection().availability);
    try std.testing.expect(!runtime.sync(harness.budget(), test_snapshot_limits, null));
    try std.testing.expectEqual(@as(usize, 0), harness.query_count);
}

test "builtin source path is frozen before worker dispatch and missing root blocks Core query" {
    var harness: TestHarness = .{};
    var runtime = try testRuntime(&harness);
    defer runtime.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const borrowed = try std.testing.allocator.dupe(u8, root);
    defer std.testing.allocator.free(borrowed);
    runtime.ports.source_roots.builtin_root = borrowed;
    try runtime.refreshPersonal();
    @memset(borrowed, 'x');
    harness.runQueued();
    _ = runtime.sync(harness.budget(), test_snapshot_limits, null);
    try std.testing.expectEqual(@as(usize, 1), harness.query_count);
    try std.testing.expectEqual(@as(usize, 1), harness.last_source_count);
    try std.testing.expectEqualStrings(root, harness.last_builtin_root[0..harness.last_builtin_root_len]);
    try std.testing.expectEqual(agent.CatalogSourceScope.user, harness.last_source_scopes[0]);
    try std.testing.expectEqual(sources.RootCheck.checked, runtime.state.catalog.source_checks.?.builtin);
    runtime.ports.source_roots.builtin_root = borrowed;
    try runtime.refreshPersonal();
    harness.runQueued();
    _ = runtime.sync(harness.budget(), test_snapshot_limits, null);
    try std.testing.expectEqual(@as(usize, 1), harness.query_count);
    try std.testing.expectEqual(sources.RootFailure.unreadable, runtime.state.catalog.source_checks.?.builtin.blocked);
    try std.testing.expectEqual(catalog.CatalogAvailability.unavailable, runtime.personalCatalogProjection().availability);
}

const TestSourceLifetime = struct {
    references: usize = 1,
    deny: bool = false,

    fn port(self: *@This()) agent.CatalogSourceLifetime {
        return .{ .context = self, .retain_fn = retain, .release_fn = release };
    }
    fn retain(context: *anyopaque) bool {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (self.deny) return false;
        self.references += 1;
        return true;
    }
    fn release(context: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        std.debug.assert(self.references > 1);
        self.references -= 1;
    }
};

test "builtin job freezes its source pin and query failure releases that exact version" {
    var first: TestSourceLifetime = .{};
    var second: TestSourceLifetime = .{};
    var harness: TestHarness = .{};
    var runtime = try testRuntime(&harness);
    defer runtime.deinit();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    runtime.ports.source_roots.builtin_root = root;
    runtime.ports.source_roots.builtin_lifetime = first.port();
    try runtime.refreshPersonal();
    try std.testing.expectEqual(@as(usize, 2), first.references);
    runtime.ports.source_roots.builtin_lifetime = second.port();
    harness.runQueued();
    try std.testing.expectEqual(first.port().context, harness.last_source_lifetime.?.context);
    try std.testing.expectEqual(@as(usize, 2), first.references);
    _ = runtime.sync(harness.budget(), test_snapshot_limits, null);
    try std.testing.expectEqual(@as(usize, 1), first.references);
    try runtime.refreshPersonal();
    try std.testing.expectEqual(@as(usize, 2), second.references);
    runtime.beginShutdown();
    runtime.finishShutdownAfterExecutorJoin(harness.budget(), test_snapshot_limits);
    try std.testing.expectEqual(@as(usize, 1), second.references);
}

test "builtin job cannot leak a source pin on queue rejection, missing root or refusal" {
    var source: TestSourceLifetime = .{};
    var harness: TestHarness = .{};
    var runtime = try testRuntime(&harness);
    defer runtime.deinit();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    runtime.ports.source_roots.builtin_root = root;
    runtime.ports.source_roots.builtin_lifetime = source.port();
    harness.queue_blocked = true;
    try std.testing.expectError(error.QueueFull, runtime.refreshPersonal());
    try std.testing.expectEqual(@as(usize, 1), source.references);
    harness.queue_blocked = false;
    source.deny = true;
    try std.testing.expectError(error.CatalogUnavailable, runtime.refreshPersonal());
    try std.testing.expectEqual(@as(usize, 1), source.references);
    source.deny = false;
    runtime.ports.source_roots.builtin_root = "not-an-absolute-existing-root";
    try runtime.refreshPersonal();
    harness.runQueued();
    _ = runtime.sync(harness.budget(), test_snapshot_limits, null);
    try std.testing.expectEqual(@as(usize, 0), harness.query_count);
    try std.testing.expectEqual(@as(usize, 1), source.references);
}

test "builtin replacement makes captured jobs stale while keeping the exact old source pin" {
    var first: TestSourceLifetime = .{};
    var second: TestSourceLifetime = .{};
    var harness: TestHarness = .{};
    var runtime = try testRuntime(&harness);
    defer runtime.deinit();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    // Keep a workspace query active too: both scopes must reject old results.
    runtime.registerWorkspaceOwned(.{ .id = 9, .epoch = 1, .catalog_authorized = true, .canonical_root = try std.testing.allocator.dupe(u8, root) }, harness.budget());
    runtime.ports.source_roots.builtin_root = root;
    runtime.ports.source_roots.builtin_lifetime = first.port();
    try runtime.refreshPersonal();
    harness.runQueued(); // one-slot fixture executor; leave completion uncommitted
    try runtime.refreshWorkspace(9, 1);
    const old_generation = runtime.state.catalog.request_generation;
    try std.testing.expectEqual(@as(usize, 3), first.references);
    try std.testing.expect(try runtime.replaceBuiltinSource(.{ .root = root, .lifetime = second.port() }, harness.budget()));
    try std.testing.expect(runtime.state.catalog.request_generation > old_generation);
    try std.testing.expect(!try runtime.replaceBuiltinSource(.{ .root = root, .lifetime = second.port() }, harness.budget()));
    harness.queue_blocked = true;
    harness.runQueued();
    try std.testing.expectEqual(first.port().context, harness.last_source_lifetime.?.context);
    _ = runtime.sync(harness.budget(), test_snapshot_limits, null);
    try std.testing.expectEqual(@as(usize, 1), first.references);
    try std.testing.expect(runtime.state.catalog.source_checks == null);
    try std.testing.expect(runtime.findWorkspace(9).?.control.source_checks == null);
    try std.testing.expect(runtime.personal_reschedule_pending);
    try std.testing.expect(runtime.findWorkspace(9).?.reschedule_pending);
    harness.queue_blocked = false;
    for (0..4) |_| {
        _ = runtime.sync(harness.budget(), test_snapshot_limits, null);
        if (harness.queued != null) harness.runQueued();
    }
    try std.testing.expectEqual(second.port().context, harness.last_source_lifetime.?.context);
    _ = runtime.sync(harness.budget(), test_snapshot_limits, null);
    try std.testing.expectEqual(@as(usize, 1), second.references);
    try std.testing.expect(runtime.state.catalog.source_checks != null);
    try std.testing.expect(runtime.findWorkspace(9).?.control.source_checks != null);
}

test "builtin replacement refuses malformed exhausted or closing authority without mutation" {
    var harness: TestHarness = .{};
    var runtime = try testRuntime(&harness);
    defer runtime.deinit();
    var pin: TestSourceLifetime = .{};
    try std.testing.expectError(error.CatalogUnavailable, runtime.replaceBuiltinSource(.{ .root = null, .lifetime = pin.port() }, harness.budget()));
    try std.testing.expectError(error.CatalogUnavailable, runtime.replaceBuiltinSource(.{ .root = "relative" }, harness.budget()));
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    runtime.state.catalog.request_generation = std.math.maxInt(u64);
    try std.testing.expectError(error.CatalogRequestGenerationExhausted, runtime.replaceBuiltinSource(.{ .root = root }, harness.budget()));
    try std.testing.expect(runtime.ports.source_roots.builtin_root == null);
    runtime.beginShutdown();
    try std.testing.expectError(error.ExecutorShuttingDown, runtime.replaceBuiltinSource(.{ .root = root }, harness.budget()));
}

test "import preparation binds revision source and target while managed updates preserve identity" {
    var harness: TestHarness = .{};
    var home = std.testing.tmpDir(.{ .iterate = true });
    defer home.cleanup();
    var source = std.testing.tmpDir(.{ .iterate = true });
    defer source.cleanup();
    var staging = std.testing.tmpDir(.{});
    defer staging.cleanup();
    var persistence_dir = std.testing.tmpDir(.{});
    defer persistence_dir.cleanup();
    var persistence: management.FileStore = .{ .io = std.testing.io, .dir = persistence_dir.dir };
    const home_path = try home.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home_path);
    const source_path = try source.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(source_path);
    const staging_path = try staging.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(staging_path);
    try source.dir.writeFile(std.testing.io, .{ .sub_path = "SKILL.md", .data = "---\nname: demo\ndescription: Demo\n---\nRead note.txt.\n" });
    try source.dir.writeFile(std.testing.io, .{ .sub_path = "note.txt", .data = "one" });
    var runtime = try Runtime.init(std.testing.io, std.testing.allocator, harness.effectPorts(), .{
        .state = .{ .management = .{ .file_store = &persistence, .staging_root = staging_path } },
        .max_workspaces = 1,
        .canonical_user_home = home_path,
    }, .{ .max_assets = 4, .max_workspaces = 1, .max_policy_keys = 4, .max_policy_key_bytes = 64 });
    defer runtime.deinit();
    const initial = try runtime.prepareImport(source_path, .local_directory, .{ .scope = .personal });
    try std.testing.expectEqual(ImportEffect.create, initial.effect);
    try std.testing.expectError(error.FileNotFound, home.dir.statFile(std.testing.io, ".agents", .{ .follow_symlinks = false }));
    const revised = try runtime.retargetImport(initial.id, initial.revision, .{ .scope = .personal });
    try std.testing.expectEqual(initial.revision + 1, revised.revision);
    try std.testing.expectError(error.InvalidPreparation, runtime.preparedImport(initial.id, initial.revision));
    try std.testing.expectError(error.InvalidConfirmation, runtime.validatePreparedImport(revised.id, revised.revision, .update));
    try source.dir.writeFile(std.testing.io, .{ .sub_path = "note.txt", .data = "changed" });
    try std.testing.expectError(error.SourceChanged, runtime.validatePreparedImport(revised.id, revised.revision, .create));
    try std.testing.expectError(error.InvalidPreparation, runtime.preparedImport(revised.id, revised.revision));
    const before_target = try runtime.prepareImport(source_path, .local_directory, .{ .scope = .personal });
    try home.dir.createDirPath(std.testing.io, ".agents/skills/demo");
    try home.dir.writeFile(std.testing.io, .{ .sub_path = ".agents/skills/demo/SKILL.md", .data = "external original" });
    try std.testing.expectError(error.TargetChanged, runtime.validatePreparedImport(before_target.id, before_target.revision, .create));
    const bound_directory = try runtime.prepareImport(source_path, .local_directory, .{ .scope = .personal });
    try home.dir.rename(".agents/skills/demo", home.dir, ".agents/skills/old-demo", std.testing.io);
    try home.dir.createDirPath(std.testing.io, ".agents/skills/demo");
    try home.dir.writeFile(std.testing.io, .{ .sub_path = ".agents/skills/demo/SKILL.md", .data = "external original" });
    try std.testing.expectError(error.TargetChanged, runtime.validatePreparedImport(bound_directory.id, bound_directory.revision, .replace_directory));
    const replace = try runtime.prepareImport(source_path, .local_directory, .{ .scope = .personal });
    try std.testing.expectEqual(ImportEffect.replace_directory, replace.effect);
    try std.testing.expectError(error.InvalidConfirmation, runtime.validatePreparedImport(replace.id, replace.revision, .update));
    const installed = try runtime.commitPreparedImport(replace.id, replace.revision, .replace_directory, 100);
    try std.testing.expectError(error.InvalidPreparation, runtime.commitPreparedImport(replace.id, replace.revision, .replace_directory, 100));
    harness.runQueued();
    _ = runtime.sync(harness.budget(), test_snapshot_limits, 101);
    const managed_path = try std.fs.path.join(std.testing.allocator, &.{ home_path, ".agents", "skills" });
    defer std.testing.allocator.free(managed_path);
    var root = try management.CanonicalRoot.open(std.testing.io, std.testing.allocator, .personal, managed_path);
    defer root.deinit();
    try runtime.state.transactions.?.commitReconciliation(&root, installed.install_id, null, 101);
    runtime.state.reconciliation = null;
    try std.testing.expect(runtime.refreshImportOutcome());
    try std.testing.expectEqual(state.ImportPhase.ready, runtime.state.import_operation.?.phase);
    try source.dir.writeFile(std.testing.io, .{ .sub_path = "note.txt", .data = "new update" });
    const bound_update = try runtime.prepareImport(source_path, .local_directory, .{ .reimport = installed.install_id });
    try std.testing.expectError(error.InvalidConfirmation, runtime.retargetImport(bound_update.id, bound_update.revision, .{ .scope = .personal }));
    runtime.discardPreparedImport(bound_update.id);
    const update = try runtime.prepareImport(source_path, .local_directory, .{ .scope = .personal });
    try std.testing.expectEqual(ImportEffect.update, update.effect);
    try std.testing.expectEqualSlices(u8, &installed.install_id, &update.install_id.?);
    try std.testing.expectError(error.InvalidConfirmation, runtime.validatePreparedImport(update.id, update.revision, .replace_directory));
    const updated = try runtime.commitPreparedImport(update.id, update.revision, .update, 102);
    try std.testing.expectEqualSlices(u8, &installed.install_id, &updated.install_id);
    harness.runQueued();
    _ = runtime.sync(harness.budget(), test_snapshot_limits, 103);
    try runtime.state.transactions.?.rollbackReconciliation(&root, updated.install_id);
    runtime.state.reconciliation = null;
    try std.testing.expect(runtime.refreshImportOutcome());
    try std.testing.expectEqual(state.ImportPhase.rolled_back, runtime.state.import_operation.?.phase);
}

test "managed imports bind source grants and publish effective bytes through export and reimport" {
    var harness: TestHarness = .{};
    var home = std.testing.tmpDir(.{});
    defer home.cleanup();
    var source = std.testing.tmpDir(.{ .iterate = true });
    defer source.cleanup();
    var staging = std.testing.tmpDir(.{ .iterate = true });
    defer staging.cleanup();
    var output = std.testing.tmpDir(.{});
    defer output.cleanup();
    var persistence_dir = std.testing.tmpDir(.{});
    defer persistence_dir.cleanup();
    var persistence: management.FileStore = .{ .io = std.testing.io, .dir = persistence_dir.dir };
    const home_path = try home.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home_path);
    const source_path = try source.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(source_path);
    const staging_path = try staging.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(staging_path);
    const output_path = try output.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(output_path);
    const original = "---\nname: demo\ndescription: Demo\n---\nRead qa-reference.txt.\n";
    try source.dir.createDir(std.testing.io, "wrapper", .default_dir);
    try source.dir.writeFile(std.testing.io, .{ .sub_path = "wrapper/SKILL.md", .data = original });
    try source.dir.writeFile(std.testing.io, .{ .sub_path = "wrapper/qa-reference.txt", .data = "resource marker" });
    var runtime = try Runtime.init(std.testing.io, std.testing.allocator, harness.effectPorts(), .{
        .state = .{ .management = .{ .file_store = &persistence, .staging_root = staging_path } },
        .max_workspaces = 1,
        .canonical_user_home = home_path,
    }, .{ .max_assets = 4, .max_workspaces = 1, .max_policy_keys = 4, .max_policy_key_bytes = 64 });
    defer runtime.deinit();
    var preview = try runtime.previewDirectory(source_path);
    defer preview.deinit();
    const installed = try runtime.installDirectory(source_path, .{
        .source_kind = .local_directory,
        .scope = .personal,
        .expected_invocation_name = preview.invocation_name,
        .expected_content_hash = preview.content_hash,
    }, 100);
    const id = installed.install_id;
    const asset = runtime.state.inventoryConst().findConst(id).?;
    try std.testing.expect(!std.mem.eql(u8, &preview.content_hash, &asset.content_hash));
    try std.testing.expectEqualSlices(u8, &asset.content_hash, &asset.recovery.?.candidate_hash.?);
    const expected = try package.managedDefinition(std.testing.allocator, original);
    defer std.testing.allocator.free(expected);
    const source_bytes = try source.dir.readFileAlloc(std.testing.io, "wrapper/SKILL.md", std.testing.allocator, .limited(package.max_preview_definition_bytes));
    defer std.testing.allocator.free(source_bytes);
    try std.testing.expectEqualStrings(original, source_bytes);
    const managed_path = try std.fs.path.join(std.testing.allocator, &.{ home_path, ".agents", "skills" });
    defer std.testing.allocator.free(managed_path);
    var root = try management.CanonicalRoot.open(std.testing.io, std.testing.allocator, .personal, managed_path);
    defer root.deinit();
    const published = try root.dir.openDir(std.testing.io, "demo", .{ .iterate = true });
    defer published.close(std.testing.io);
    var actual = try package.previewDirectory(std.testing.io, std.testing.allocator, published, .{});
    defer actual.deinit();
    try std.testing.expectEqualStrings(expected, actual.definition);
    try std.testing.expectEqualSlices(u8, &asset.content_hash, &actual.content_hash);
    const marker = try published.readFileAlloc(std.testing.io, "qa-reference.txt", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(marker);
    try std.testing.expectEqualStrings("resource marker", marker);
    // Catalog behavior is separately qualified through real Core. This test
    // isolates the file transaction and its source/effective hash invariants.
    harness.runQueued();
    _ = runtime.sync(harness.budget(), test_snapshot_limits, 101);
    try runtime.state.transactions.?.commitReconciliation(&root, id, null, 101);
    runtime.state.reconciliation = null;
    const exported = try runtime.exportPackage(id, output_path);
    const archive_path = try std.fs.path.join(std.testing.allocator, &.{ output_path, exported.fileName() });
    defer std.testing.allocator.free(archive_path);
    var exported_preview = try runtime.previewArchive(archive_path);
    defer exported_preview.deinit();
    try std.testing.expectEqualStrings(expected, exported_preview.definition);
    try std.testing.expectEqualSlices(u8, &actual.content_hash, &exported_preview.content_hash);
    try source.dir.writeFile(std.testing.io, .{ .sub_path = "wrapper/qa-reference.txt", .data = "changed after preview" });
    try std.testing.expectError(error.InvalidAsset, runtime.reimportDirectory(id, source_path, preview.invocation_name, preview.content_hash));
    var unchanged = try package.previewDirectory(std.testing.io, std.testing.allocator, published, .{});
    defer unchanged.deinit();
    try std.testing.expectEqualSlices(u8, &actual.content_hash, &unchanged.content_hash);
    _ = try runtime.reimportArchive(id, archive_path, exported_preview.invocation_name, exported_preview.content_hash);
    const after = runtime.state.inventoryConst().findConst(id).?;
    try std.testing.expectEqualSlices(u8, &actual.content_hash, &after.recovery.?.candidate_hash.?);
    const reimported = try root.dir.openDir(std.testing.io, "demo", .{ .iterate = true });
    defer reimported.close(std.testing.io);
    var round_trip = try package.previewDirectory(std.testing.io, std.testing.allocator, reimported, .{});
    defer round_trip.deinit();
    try std.testing.expectEqualStrings(expected, round_trip.definition);
    try std.testing.expectEqualSlices(u8, &actual.content_hash, &round_trip.content_hash);
    var walker = try staging.dir.walk(std.testing.allocator);
    defer walker.deinit();
    try std.testing.expect((try walker.next(std.testing.io)) == null);
    harness.runQueued();
    _ = runtime.sync(harness.budget(), test_snapshot_limits, 102);

    // A fresh target exercises installArchive as well as preview/reimport.
    var archive_home = std.testing.tmpDir(.{});
    defer archive_home.cleanup();
    const archive_home_path = try archive_home.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(archive_home_path);
    var archive_store: management.FileStore = .{ .io = std.testing.io, .dir = archive_home.dir };
    var archive_harness: TestHarness = .{};
    var archive_runtime = try Runtime.init(std.testing.io, std.testing.allocator, archive_harness.effectPorts(), .{
        .state = .{ .management = .{ .file_store = &archive_store, .staging_root = staging_path } },
        .max_workspaces = 1,
        .canonical_user_home = archive_home_path,
    }, .{ .max_assets = 4, .max_workspaces = 1, .max_policy_keys = 4, .max_policy_key_bytes = 64 });
    defer {
        archive_runtime.beginShutdown();
        archive_runtime.finishShutdownAfterExecutorJoin(archive_harness.budget(), test_snapshot_limits);
        archive_runtime.deinit();
    }
    const preparation = try archive_runtime.prepareImport(archive_path, .local_package, .{ .scope = .personal });
    try std.testing.expectEqual(ImportEffect.create, preparation.effect);
    const archive_installed = try archive_runtime.commitPreparedImport(preparation.id, preparation.revision, .create, 103);
    const archive_asset = archive_runtime.state.inventoryConst().findConst(archive_installed.install_id).?;
    try std.testing.expectEqual(management.SourceKind.local_package, archive_asset.source_kind);
    try std.testing.expectEqualSlices(u8, &actual.content_hash, &archive_asset.content_hash);
    const installed_definition = try archive_home.dir.readFileAlloc(std.testing.io, ".agents/skills/demo/SKILL.md", std.testing.allocator, .limited(package.max_preview_definition_bytes));
    defer std.testing.allocator.free(installed_definition);
    try std.testing.expectEqualStrings(expected, installed_definition);
    const installed_marker = try archive_home.dir.readFileAlloc(std.testing.io, ".agents/skills/demo/qa-reference.txt", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(installed_marker);
    try std.testing.expectEqualStrings("resource marker", installed_marker);
    archive_harness.runQueued();
    _ = archive_runtime.sync(archive_harness.budget(), test_snapshot_limits, 104);
}
