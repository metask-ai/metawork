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
pub const TextProjection = view.TextProjection;
pub const ScopedCatalog = view.ScopedCatalog;
pub const WorkspaceCatalogs = view.WorkspaceCatalogs;
pub const ViewError = view.Error;
pub const SourceConfiguration = state.SourceConfiguration;
pub const SourceRestore = state.SourceRestore;
pub const SourceSettingsResult = state.SourceSettingsResult;
pub const SourceSettingsView = state.SourceSettingsView;
pub const SourceRecoveryAction = enum { reread, reset };

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
    io: std.Io,
    source_roots: ports.SourceRoots,
    selection: sources.Selection,
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
            if (self.scope == .personal) null else self.canonical_root,
            self.selection,
        ) catch return;
        defer discovery.deinit();
        self.root_checks = discovery.rootChecks();
        const additional = discovery.additionalSources() catch return;
        self.outcome = if (self.catalog_port.query(.{
            .canonical_user_home = self.canonical_user_home,
            .additional_sources = additional,
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
        var result: Runtime = .{
            .allocator = allocator,
            .io = io,
            .ports = effect_ports,
            .state = product_state,
            .canonical_user_home = home,
            .workspaces = workspaces,
        };
        result.initializeSources(configuration.state.sources.restored);
        return result;
    }

    fn initializeSources(self: *Runtime, restored: SourceRestore) void {
        const loaded = switch (restored) {
            .unavailable => return,
            .read_failed => {
                self.state.source_health = .read_failed;
                return;
            },
            .loaded => |value| value,
        };
        switch (loaded) {
            .ready => |settings| {
                self.state.source_settings = settings;
                self.state.source_revision_high_water = settings.revision;
                self.state.source_health = .ready;
            },
            .absent => {
                const file_store = self.state.source_file_store orelse return;
                file_store.commit(.{}) catch |err| {
                    self.state.source_health = if (err == error.PersistenceOutcomeUnknown) .outcome_unknown else .write_failed;
                    if (err == error.PersistenceOutcomeUnknown) self.state.source_revision_high_water = 1;
                    return;
                };
                self.state.source_settings = .{};
                self.state.source_revision_high_water = 1;
                self.state.source_health = .ready;
            },
            .invalid => self.state.source_health = .corrupt,
            .unsupported_schema => self.state.source_health = .unsupported_schema,
            .too_large => self.state.source_health = .too_large,
        }
    }

    pub fn sourceSettings(self: *const Runtime) SourceSettingsView {
        const available = self.state.source_file_store != null and !self.shutting_down and
            self.state.reconciliation == null and self.state.source_recovery_generation != std.math.maxInt(u64) and
            self.state.source_revision_high_water != std.math.maxInt(u64);
        const can_reread = available and self.state.source_settings == null;
        return .{
            .settings = self.state.source_settings,
            .health = self.state.source_health,
            .can_set_enabled = available and self.state.source_settings != null,
            .can_reread = can_reread,
            .can_reset = can_reread and (self.state.source_health == .corrupt or self.state.source_health == .missing),
            .recovery_token = if (can_reread) self.state.source_recovery_generation else null,
        };
    }

    pub const SourceDiscoveryView = state.SourceDiscoveryView;

    pub fn personalSourceDiscovery(self: *const Runtime) ?SourceDiscoveryView {
        const settings = self.state.source_settings orelse return null;
        if (self.canonical_user_home == null) return null;
        return .{ .selection = settings.selection.relevant(.user), .checks = self.state.catalog.source_checks, .checking = self.personal_job != null or self.personal_reschedule_pending };
    }

    pub fn workspaceSourceDiscovery(self: *const Runtime, id: u64, epoch: u64) ?SourceDiscoveryView {
        const settings = self.state.source_settings orelse return null;
        const workspace = self.findWorkspaceConst(id) orelse return null;
        if (workspace.epoch != epoch or !workspace.authorized or self.canonical_user_home == null) return null;
        return .{ .selection = settings.selection, .checks = workspace.control.source_checks, .checking = workspace.job != null or workspace.reschedule_pending };
    }

    pub fn setSourceEnabled(
        self: *Runtime,
        brand: sources.Brand,
        enabled: bool,
        expected_revision: u64,
        budget: ProjectionBudget,
    ) SourceSettingsResult {
        if (self.shutting_down) return .{ .reason = .shutting_down };
        if (self.state.reconciliation != null) return .{ .reason = .busy };
        if (self.state.source_file_store == null) return .{ .reason = .source_settings_unavailable };
        const current = self.state.source_settings orelse return .{ .reason = .source_settings_unavailable };
        const candidate = current.replacing(brand, enabled, expected_revision) catch |err|
            return .{ .reason = if (err == error.StaleRevision) .stale_revision else .revision_exhausted };
        if (candidate.revision == current.revision)
            return .{ .applied = true, .revision = current.revision };
        const personal_changed = !current.selection.relevant(.user).eql(candidate.selection.relevant(.user));
        if (!self.sourceGenerationsAvailable(personal_changed)) return .{ .reason = .revision_exhausted };
        return self.commitSourceSettings(candidate, budget);
    }

    pub fn recoverSourceSettings(
        self: *Runtime,
        action: SourceRecoveryAction,
        expected_recovery_token: u64,
        budget: ProjectionBudget,
    ) SourceSettingsResult {
        if (self.shutting_down) return .{ .reason = .shutting_down };
        if (expected_recovery_token != self.state.source_recovery_generation)
            return .{ .reason = .stale_recovery_token };
        if (self.state.reconciliation != null) return .{ .reason = .busy };
        const recovery = self.sourceSettings();
        if (!recovery.can_reread or (action == .reset and !recovery.can_reset))
            return .{ .reason = .recovery_not_allowed };
        if (!self.sourceGenerationsAvailable(true)) return .{ .reason = .revision_exhausted };
        const loaded = self.state.source_file_store.?.load(self.allocator) catch {
            self.markSourcesUnavailable(.read_failed, budget);
            return .{ .reason = .read_failed, .changed = true };
        };
        var candidate: sources.Settings = switch (loaded) {
            .ready => |settings| settings,
            .absent, .invalid => if (action == .reset) .{} else {
                self.markSourcesUnavailable(if (loaded == .absent) .missing else .corrupt, budget);
                return .{ .reason = .source_settings_unavailable, .changed = true };
            },
            .unsupported_schema, .too_large => {
                self.markSourcesUnavailable(if (loaded == .too_large) .too_large else .unsupported_schema, budget);
                return .{ .reason = .source_settings_unavailable, .changed = true };
            },
        };
        self.state.source_revision_high_water = @max(self.state.source_revision_high_water, candidate.revision);
        candidate.revision = nextGeneration(self.state.source_revision_high_water) orelse
            return .{ .reason = .revision_exhausted, .changed = true };
        // Even a valid reread is durably reconfirmed. Old revisions cannot be
        // reused after recovery, including a file restored from an older copy.
        return self.commitSourceSettings(candidate, budget);
    }

    fn sourceGenerationsAvailable(self: *const Runtime, personal_changed: bool) bool {
        if (self.state.source_recovery_generation == std.math.maxInt(u64) or
            (personal_changed and self.state.catalog.request_generation == std.math.maxInt(u64))) return false;
        for (self.workspaces) |entry| if (entry) |workspace| {
            if (workspace.authorized and workspace.control.request_generation == std.math.maxInt(u64)) return false;
        };
        return true;
    }

    fn commitSourceSettings(self: *Runtime, candidate: sources.Settings, budget: ProjectionBudget) SourceSettingsResult {
        const previous = self.state.source_settings;
        self.state.source_file_store.?.commit(candidate) catch |err| {
            if (err == error.PersistenceOutcomeUnknown) {
                self.state.source_revision_high_water = @max(self.state.source_revision_high_water, candidate.revision);
                self.markSourcesUnavailable(.outcome_unknown, budget);
                return .{ .reason = .persistence_outcome_unknown, .changed = true };
            }
            const changed = self.state.source_health != .write_failed;
            self.state.source_health = .write_failed;
            return .{ .reason = .write_failed, .changed = changed };
        };
        self.state.source_settings = candidate;
        self.state.source_health = .ready;
        self.state.source_revision_high_water = @max(self.state.source_revision_high_water, candidate.revision);
        self.state.source_recovery_generation += 1;
        const personal_changed = if (previous) |old|
            !old.selection.relevant(.user).eql(candidate.selection.relevant(.user))
        else
            true;
        if (personal_changed) {
            self.invalidateSourceControl(&self.state.catalog, budget);
            self.personal_reschedule_pending = true;
        }
        for (self.workspaces) |*entry| if (entry.*) |*workspace| {
            if (!workspace.authorized) continue;
            self.invalidateSourceControl(&workspace.control, budget);
            workspace.reschedule_pending = true;
        };
        return .{ .applied = true, .revision = candidate.revision, .changed = true };
    }

    fn invalidateSourceControl(self: *Runtime, control: *state.CatalogControl, budget: ProjectionBudget) void {
        control.request_generation = nextGeneration(control.request_generation) orelse std.math.maxInt(u64);
        control.source_checks = null;
        self.invalidateControlWithBudget(control, budget);
    }

    fn markSourcesUnavailable(self: *Runtime, health: state.SourceHealth, budget: ProjectionBudget) void {
        self.state.source_settings = null;
        self.state.source_health = health;
        self.state.source_recovery_generation = nextGeneration(self.state.source_recovery_generation) orelse std.math.maxInt(u64);
        self.personal_reschedule_pending = false;
        self.invalidateSourceControl(&self.state.catalog, budget);
        for (self.workspaces) |*entry| if (entry.*) |*workspace| {
            workspace.reschedule_pending = false;
            self.invalidateSourceControl(&workspace.control, budget);
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
                self.setWorkspaceCatalogAuthorized(binding.id, binding.epoch, binding.catalog_authorized, budget) catch unreachable;
                return;
            }
            self.allocator.free(workspace.canonical_root);
            workspace.canonical_root = binding.canonical_root;
            workspace.epoch = binding.epoch;
            workspace.authorized = binding.catalog_authorized;
            self.invalidateSourceControl(&workspace.control, budget);
            workspace.control.slot = .uninitialized;
            workspace.reschedule_pending = binding.catalog_authorized and self.state.source_settings != null;
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
        if (self.state.source_settings == null or !workspace.authorized) return .unavailable;
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
        if (self.state.source_settings == null or !workspace.authorized) return;
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
        if (self.state.source_settings == null) return error.CatalogUnavailable;
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
        if (self.state.source_settings == null) return error.CatalogUnavailable;
        const workspace = self.findWorkspace(id) orelse return error.UnknownWorkspace;
        if (workspace.epoch != epoch) return error.WorkspaceEpochMismatch;
        if (!workspace.authorized) return error.CatalogUnavailable;
        if (workspace.job != null) return error.CatalogLoading;
        const generation = nextGeneration(workspace.control.request_generation) orelse
            return error.CatalogRequestGenerationExhausted;
        try self.startWorkspace(workspace, generation, null);
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
        return changed;
    }

    /// Completion of any executor work wakes Product sync. Queue pressure is
    /// the only automatically retried failure; one latest intent per scope is
    /// retained and each sync visits scopes once in round-robin order.
    fn dispatchPending(self: *Runtime, budget: ProjectionBudget) bool {
        if (self.shutting_down or self.state.source_settings == null) return false;
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
        workspace.reschedule_pending = authorized and self.state.source_settings != null;
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

    pub fn managementHealth(self: *const Runtime) state.ManagementHealth {
        return self.state.management_health;
    }

    pub fn reconciliationPending(self: *const Runtime) bool {
        return self.state.reconciliation != null;
    }

    pub fn personalCatalogProjection(self: *const Runtime) catalog.CatalogProjection {
        return view.catalogProjection(
            if (self.state.source_settings == null) .unavailable else self.state.catalog.slot.availability(self.personal_job != null or self.personal_reschedule_pending),
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
            if (self.state.source_settings == null or !workspace.authorized) .unavailable else workspace.control.slot.availability(workspace.job != null or workspace.reschedule_pending),
            workspace.control.slot.snapshotConst(),
        );
    }

    pub fn scopedWorkspaceCatalog(
        self: *const Runtime,
        id: u64,
        epoch: u64,
    ) ?view.ScopedCatalog {
        const workspace = self.findWorkspaceConst(id) orelse return null;
        if (workspace.epoch != epoch or !workspace.authorized or self.state.source_settings == null) return null;
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
        return self.state.source_settings != null and workspace.authorized and workspace.epoch == epoch and workspace.job == null and !workspace.reschedule_pending and
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
    ) view.Error!void {
        return view.writeManagementProjection(writer, .{
            .state = &self.state,
            .workspaces = workspaces,
            .text = text,
            .source_settings = self.sourceSettings(),
            .personal_source_discovery = self.personalSourceDiscovery(),
        });
    }

    pub fn writeWorkspaceSourceDiscovery(self: *const Runtime, writer: *std.Io.Writer, id: u64, epoch: u64) view.Error!void {
        return view.writeSourceDiscovery(writer, .workspace, self.workspaceSourceDiscovery(id, epoch));
    }

    pub fn assetScope(
        self: *const Runtime,
        install_id: management.InstallId,
    ) AssetError!management.Scope {
        const current = self.state.inventoryConst().findConst(install_id) orelse
            return error.AssetNotFound;
        return current.scope;
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
    ) MutationError!state.MutationResult {
        const scope = try self.assetScope(install_id);
        try self.requireMutationAvailable(scope);
        const result = try management_runtime.retryVerification(
            self.managementContext(),
            install_id,
        );
        self.scheduleReconciliation(scope) catch |err| {
            self.state.reconciliation = null;
            return err;
        };
        return result;
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

    pub fn testSetManagementHealth(
        self: *Runtime,
        health: ManagementHealth,
    ) void {
        comptime std.debug.assert(builtin.is_test);
        self.state.management_health = health;
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
            !self.shutting_down and self.state.source_settings != null and
            job.selection.eql(self.state.source_settings.?.selection.relevant(if (scope == .personal) .user else .workspace));
        if (current) control.source_checks = job.root_checks;
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
                        self.reconcileCatalogResultNoFail(
                            job,
                            null,
                            now_unix_seconds,
                        );
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
        self: *Runtime,
        scope: management.Scope,
    ) MutationError!void {
        if (self.shutting_down) return error.ExecutorShuttingDown;
        if (self.state.management_health != .ready or
            self.state.transactions == null)
            return error.PersistenceFailed;
        if (self.state.reconciliation != null) return error.TaskBusy;
        if (self.state.source_settings == null) return error.CatalogUnavailable;
        switch (scope) {
            .personal => if (self.personal_job != null or self.personal_reschedule_pending) return error.CatalogLoading,
            .project => |project| {
                const workspace = self.findWorkspace(project.workspace_id) orelse
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
        const base = self.canonicalBase(scope) catch {
            self.state.management_health = .read_failed;
            return;
        };
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
            .io = self.io,
            .source_roots = self.ports.source_roots,
            .selection = self.state.source_settings.?.selection.relevant(if (scope == .personal) .user else .workspace),
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
    last_source_ids: [sources.definitions.len]sources.Id = undefined,
    last_source_scopes: [sources.definitions.len]agent.CatalogSourceScope = undefined,

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

    fn discoverRoots(_: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, _: []const u8, workspace: ?[]const u8, selection: sources.Selection) anyerror!sources.Discovery {
        var result: sources.Discovery = .{
            .allocator = allocator,
            .default_user = .missing,
            .default_workspace = if (workspace != null) .missing else .disabled,
        };
        for (sources.definitions) |item| {
            if (selection.enabled(item.id)) result.checks[@intFromEnum(item.id)] = .missing;
        }
        return result;
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
        self.last_source_count = input.additional_sources.len;
        for (input.additional_sources, 0..) |source, index| {
            self.last_source_ids[index] = sources.findId(source.source_instance_id).?;
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
            .state = .{ .sources = .{ .restored = .{ .loaded = .{ .ready = .{} } } } },
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
            .state = .{ .sources = .{ .restored = .{ .loaded = .{ .ready = .{} } } }, .management = .{
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

test "management outcome unknown freezes subsequent Skill mutations" {
    try exerciseManagementCommitFailure(
        .outcome_unknown,
        error.PersistenceOutcomeUnknown,
        .outcome_unknown,
    );
}

test "management definite write failure is observable and blocks retry" {
    try exerciseManagementCommitFailure(
        .write_failed,
        error.PersistenceFailed,
        .write_failed,
    );
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
            .state = .{ .sources = .{ .restored = .{ .loaded = .{ .ready = .{} } } }, .management = .{
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
            .state = .{ .sources = .{ .restored = .{ .loaded = .{ .ready = .{} } } }, .management = .{
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

test "source commit CAS no-op and A B A invalidate old work before queue admission" {
    var harness: TestHarness = .{};
    var runtime = try testRuntime(&harness);
    defer runtime.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store: sources.FileStore = .{ .io = std.testing.io, .dir = tmp.dir };
    try store.commit(.{});
    runtime.state.source_file_store = &store;
    runtime.registerWorkspaceOwned(.{
        .id = 1,
        .epoch = 1,
        .catalog_authorized = true,
        .canonical_root = try std.testing.allocator.dupe(u8, "/workspace/a"),
    }, harness.budget());
    try runtime.refreshPersonal();
    const old_job = runtime.personal_job.?;
    const old_generation = old_job.request_generation;
    const before = runtime.state.catalog.request_generation;
    const noop = runtime.setSourceEnabled(.claude, false, 1, harness.budget());
    try std.testing.expect(noop.applied and !noop.changed);
    try std.testing.expectEqual(before, runtime.state.catalog.request_generation);
    try std.testing.expectEqual(state.SourceSettingsReason.stale_revision, runtime.setSourceEnabled(.claude, true, 9, harness.budget()).reason.?);
    try std.testing.expect(runtime.setSourceEnabled(.claude, true, 1, harness.budget()).applied);
    try std.testing.expect(runtime.setSourceEnabled(.claude, false, 2, harness.budget()).applied);
    try std.testing.expect(runtime.personal_reschedule_pending);
    try std.testing.expect(runtime.state.catalog.request_generation > old_generation);
    try std.testing.expect(!old_job.selection.enabled(.claude_user));
    harness.runQueued();
    harness.queue_blocked = true; // A non-Skill job now occupies the executor.
    _ = runtime.sync(harness.budget(), test_snapshot_limits, null);
    try std.testing.expect(runtime.personal_job == null and runtime.personal_reschedule_pending);
    try std.testing.expect(runtime.state.catalog.source_checks == null);
    try std.testing.expectEqual(catalog.CatalogAvailability.loading, runtime.personalCatalogProjection().availability);
    harness.queue_blocked = false; // Its ordinary completion wake drives sync.
    for (0..4) |_| {
        _ = runtime.sync(harness.budget(), test_snapshot_limits, null);
        if (harness.queued != null) harness.runQueued();
    }
    _ = runtime.sync(harness.budget(), test_snapshot_limits, null);
    try std.testing.expect(!runtime.personal_reschedule_pending and !runtime.findWorkspace(1).?.reschedule_pending);
    try std.testing.expectEqual(@as(usize, 3), harness.query_count);
    try std.testing.expectEqual(@as(u64, 3), (try store.load(std.testing.allocator)).ready.revision);
}

test "normalizing a partial brand preserves unchanged personal query and unknown sources deny new authority" {
    var harness: TestHarness = .{};
    var runtime = try testRuntime(&harness);
    defer runtime.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store: sources.FileStore = .{ .io = std.testing.io, .dir = tmp.dir };
    runtime.state.source_file_store = &store;
    runtime.state.source_settings = .{ .selection = .{ .values = .{ false, false, true, false } } };
    try store.commit(runtime.state.source_settings.?);
    try runtime.refreshPersonal();
    const generation = runtime.state.catalog.request_generation;
    try std.testing.expect(runtime.setSourceEnabled(.codex, true, 1, harness.budget()).applied);
    const saved = (try store.load(std.testing.allocator)).ready;
    try std.testing.expectEqual(@as(u64, 2), saved.revision);
    try std.testing.expectEqualDeep([_]bool{ false, false, true, true }, saved.selection.values);
    try std.testing.expectEqual(generation, runtime.state.catalog.request_generation);
    try std.testing.expect(!runtime.personal_reschedule_pending);
    harness.runQueued();
    _ = runtime.sync(harness.budget(), test_snapshot_limits, null);
    try std.testing.expect(runtime.state.catalog.source_checks != null);
    runtime.markSourcesUnavailable(.outcome_unknown, harness.budget());
    try std.testing.expectError(error.CatalogUnavailable, runtime.refreshPersonal());
    try std.testing.expectEqual(catalog.CatalogAvailability.unavailable, runtime.personalCatalogProjection().availability);
    try std.testing.expect(!runtime.sourceSettings().can_reset);
}

test "source recovery reobserves changed files and never resets oversized or unknown formats" {
    var harness: TestHarness = .{};
    var runtime = try testRuntime(&harness);
    defer runtime.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store: sources.FileStore = .{ .io = std.testing.io, .dir = tmp.dir };
    runtime.state.source_file_store = &store;
    runtime.markSourcesUnavailable(.corrupt, harness.budget());
    const old_token = runtime.sourceSettings().recovery_token.?;
    const huge = [_]u8{' '} ** (sources.max_store_bytes + 1);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = sources.file_name, .data = &huge });
    const rejected = runtime.recoverSourceSettings(.reset, old_token, harness.budget());
    try std.testing.expect(!rejected.applied and rejected.changed);
    try std.testing.expectEqual(state.SourceHealth.too_large, runtime.sourceSettings().health);
    try std.testing.expect(!runtime.sourceSettings().can_reset);
    try std.testing.expectEqualDeep(sources.Load.too_large, try store.load(std.testing.allocator));
    try std.testing.expectEqual(state.SourceSettingsReason.stale_recovery_token, runtime.recoverSourceSettings(.reread, old_token, harness.budget()).reason.?);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = sources.file_name, .data = "{\"schema\":2}" });
    _ = runtime.recoverSourceSettings(.reread, runtime.sourceSettings().recovery_token.?, harness.budget());
    try std.testing.expectEqual(state.SourceHealth.unsupported_schema, runtime.sourceSettings().health);
    try std.testing.expectEqual(state.SourceSettingsReason.recovery_not_allowed, runtime.recoverSourceSettings(.reset, runtime.sourceSettings().recovery_token.?, harness.budget()).reason.?);
    try store.commit(.{ .revision = 17, .selection = .{ .values = .{ true, false, true, false } } });
    const recovered = runtime.recoverSourceSettings(.reread, runtime.sourceSettings().recovery_token.?, harness.budget());
    try std.testing.expect(recovered.applied);
    try std.testing.expectEqual(@as(?u64, 18), recovered.revision);
    try std.testing.expect(runtime.state.source_settings.?.selection.enabled(.claude_user));
    try std.testing.expectEqual(@as(u64, 18), (try store.load(std.testing.allocator)).ready.revision);
    runtime.beginShutdown();
    runtime.finishShutdownAfterExecutorJoin(harness.budget(), test_snapshot_limits);
}

test "source write failure keeps trusted values and reset of missing settings advances revision" {
    var harness: TestHarness = .{};
    var runtime = try testRuntime(&harness);
    defer runtime.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store: sources.FileStore = .{ .io = std.testing.io, .dir = tmp.dir };
    runtime.state.source_file_store = &store;
    try tmp.dir.createDir(std.testing.io, sources.file_name, .default_dir);
    const failure = runtime.setSourceEnabled(.claude, true, 1, harness.budget());
    try std.testing.expectEqual(state.SourceSettingsReason.write_failed, failure.reason.?);
    try std.testing.expect(!runtime.state.source_settings.?.selection.enabled(.claude_user));
    try std.testing.expect(!runtime.state.source_settings.?.selection.enabled(.claude_workspace));
    try std.testing.expectEqual(@as(u64, 1), runtime.state.source_settings.?.revision);
    try tmp.dir.deleteDir(std.testing.io, sources.file_name);
    runtime.markSourcesUnavailable(.missing, harness.budget());
    const reset = runtime.recoverSourceSettings(.reset, runtime.sourceSettings().recovery_token.?, harness.budget());
    try std.testing.expect(reset.applied);
    try std.testing.expectEqual(@as(?u64, 2), reset.revision);
    runtime.beginShutdown();
    runtime.finishShutdownAfterExecutorJoin(harness.budget(), test_snapshot_limits);
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

test "source durable outcome unknown freezes new work until valid reread is reconfirmed" {
    var harness: TestHarness = .{};
    var runtime = try testRuntime(&harness);
    defer runtime.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store: sources.FileStore = .{ .io = std.testing.io, .dir = tmp.dir };
    runtime.state.source_file_store = &store;
    try store.commit(.{});
    store.commit_fault = .after_rename;
    const uncertain = runtime.setSourceEnabled(.codex, true, 1, harness.budget());
    try std.testing.expectEqual(state.SourceSettingsReason.persistence_outcome_unknown, uncertain.reason.?);
    try std.testing.expect(uncertain.changed and !uncertain.applied);
    try std.testing.expect(runtime.sourceSettings().settings == null);
    try std.testing.expect(!runtime.sourceSettings().can_reset);
    try std.testing.expectError(error.CatalogUnavailable, runtime.refreshPersonal());
    try std.testing.expect((try store.load(std.testing.allocator)).ready.selection.enabled(.codex_user));
    store.commit_fault = .none;
    const recovered = runtime.recoverSourceSettings(.reread, runtime.sourceSettings().recovery_token.?, harness.budget());
    try std.testing.expectEqual(@as(?u64, 3), recovered.revision);
    try std.testing.expect(recovered.applied and runtime.state.source_settings.?.selection.enabled(.codex_user));
    runtime.beginShutdown();
    runtime.finishShutdownAfterExecutorJoin(harness.budget(), test_snapshot_limits);
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
        .state = .{ .sources = .{ .restored = .{ .loaded = .{ .ready = .{ .selection = .{ .values = .{ true, false, false, false } } } } } } },
        .max_workspaces = 1,
        .canonical_user_home = home,
    }, .{ .max_assets = 2, .max_workspaces = 1, .max_policy_keys = 2, .max_policy_key_bytes = 64 });
    defer runtime.deinit();
    try runtime.refreshPersonal();
    harness.runQueued();
    _ = runtime.sync(harness.budget(), test_snapshot_limits, null);
    try std.testing.expectEqual(@as(usize, 1), harness.last_source_count);
    try std.testing.expectEqual(sources.Id.claude_user, harness.last_source_ids[0]);
    try std.testing.expectEqual(agent.CatalogSourceScope.user, harness.last_source_scopes[0]);
    try std.testing.expectEqual(sources.RootCheck.checked, runtime.state.catalog.source_checks.?.checks[0]);
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
