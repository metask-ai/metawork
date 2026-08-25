//! Product Skill aggregate state and Agent-catalog authority facts.
//! Executor jobs, Agent Runtime effects, Workspace ownership, and publication
//! remain outside this module.

const std = @import("std");
const builtin = @import("builtin");
const agent = @import("metawork_agent");
const catalog = @import("product_skill_catalog");
const enablement = @import("product_skill_enablement");
const management = @import("product_skill_management");

pub const ManagementHealth = enum {
    unavailable,
    ready,
    read_failed,
    corrupt,
    write_failed,
    outcome_unknown,
};

pub const ManagementConfiguration = struct {
    file_store: ?*management.FileStore = null,
    staging_root: ?[]const u8 = null,
    restored_bytes: ?[]const u8 = null,
    restore_failed: bool = false,
};

pub const EnablementHealth = enum {
    unavailable,
    ready,
    read_failed,
    corrupt,
    write_failed,
    outcome_unknown,
};

pub const EnablementConfiguration = struct {
    file_store: ?*enablement.FileStore = null,
    restored_bytes: ?[]const u8 = null,
    restore_failed: bool = false,
};

pub const Configuration = struct {
    management: ManagementConfiguration = .{},
    enablement: EnablementConfiguration = .{},
};

pub const Limits = struct {
    max_assets: usize,
    max_workspaces: usize,
    max_policy_keys: usize,
    max_policy_key_bytes: usize,
};

pub const EnablementScope = union(enum) {
    personal,
    project: struct {
        workspace_id: u64,
        expected_workspace_epoch: u64,
    },
};

pub const EnablementState = enablement.OverrideState;

pub const EnablementMutation = struct {
    scope: EnablementScope,
    skill_policy_key: []const u8,
    state: EnablementState,
    expected_catalog_revision: []const u8,
    expected_selection_revision: u64,
};

pub const InstallInput = struct {
    source_kind: management.SourceKind,
    scope: management.Scope,
    expected_invocation_name: []const u8,
    expected_content_hash: management.ContentHash,
    allow_replace: bool = false,
};

pub const MutationResult = struct {
    install_id: management.InstallId,
    verification_pending: bool,
};

pub const ExportResult = struct {
    file_name: [management.max_target_entry_bytes + 6]u8,
    file_name_len: usize,

    pub fn fileName(self: *const ExportResult) []const u8 {
        return self.file_name[0..self.file_name_len];
    }
};

pub const Reconciliation = struct {
    install_id: management.InstallId,
    scope: management.Scope,
    invocation_name: [management.max_target_entry_bytes]u8,
    invocation_name_len: usize,
    operation: management.Operation,

    pub fn invocationName(self: *const Reconciliation) []const u8 {
        return self.invocation_name[0..self.invocation_name_len];
    }
};

pub const CatalogLeaseRelease = struct {
    context: ?*anyopaque,
    release_fn: *const fn (?*anyopaque, *agent.CatalogLease) void,

    pub fn release(self: CatalogLeaseRelease, lease: *agent.CatalogLease) void {
        self.release_fn(self.context, lease);
    }
};

pub const CatalogLeaseOwner = struct {
    agent_lease: if (builtin.is_test) ?*agent.CatalogLease else *agent.CatalogLease,

    pub fn init(lease: *agent.CatalogLease) CatalogLeaseOwner {
        return .{ .agent_lease = lease };
    }

    pub fn fixture() CatalogLeaseOwner {
        comptime std.debug.assert(builtin.is_test);
        return .{ .agent_lease = null };
    }

    pub fn borrow(self: CatalogLeaseOwner) ?*agent.CatalogLease {
        return self.agent_lease;
    }

    pub fn release(self: CatalogLeaseOwner, releaser: CatalogLeaseRelease) void {
        const lease = self.borrow() orelse return;
        releaser.release(lease);
    }
};

pub const CommittedAuthority = struct {
    lease: CatalogLeaseOwner,
    snapshot: catalog.Snapshot,

    pub fn deinit(self: *CommittedAuthority, releaser: CatalogLeaseRelease) void {
        self.snapshot.deinit();
        self.lease.release(releaser);
        self.* = undefined;
    }
};

pub const CatalogSlot = union(enum) {
    uninitialized,
    unavailable,
    committed: CommittedAuthority,

    pub fn availability(
        self: *const CatalogSlot,
        refreshing: bool,
    ) catalog.CatalogAvailability {
        return switch (self.*) {
            .committed => |authority| switch (authority.snapshot.health) {
                .healthy => .ready,
                .degraded => .degraded,
            },
            .uninitialized => if (refreshing) .loading else .uninitialized,
            .unavailable => if (refreshing) .loading else .unavailable,
        };
    }

    pub fn snapshot(self: *CatalogSlot) ?*catalog.Snapshot {
        return switch (self.*) {
            .committed => |*authority| &authority.snapshot,
            .uninitialized, .unavailable => null,
        };
    }

    pub fn snapshotConst(self: *const CatalogSlot) ?*const catalog.Snapshot {
        return switch (self.*) {
            .committed => |*authority| &authority.snapshot,
            .uninitialized, .unavailable => null,
        };
    }

    pub fn lease(self: *const CatalogSlot) ?*agent.CatalogLease {
        return switch (self.*) {
            .committed => |authority| authority.lease.borrow(),
            .uninitialized, .unavailable => null,
        };
    }

    pub fn deinit(self: *CatalogSlot, releaser: CatalogLeaseRelease) void {
        if (self.* == .committed) self.committed.deinit(releaser);
        self.* = .unavailable;
    }
};

pub const CatalogControl = struct {
    slot: CatalogSlot = .uninitialized,
    request_generation: u64 = 0,
};

pub const InitError = management.Error || enablement.Error;

pub const State = struct {
    inventory: ?management.Inventory,
    transactions: ?management.Transactions,
    management_health: ManagementHealth,
    enablement_store: enablement.Store,
    enablement_file_store: ?*enablement.FileStore,
    enablement_health: EnablementHealth,
    staging_root: ?[]u8,
    reconciliation: ?Reconciliation = null,
    catalog: CatalogControl = .{},

    pub fn inventoryConst(self: *const State) *const management.Inventory {
        if (self.transactions) |*transactions| return &transactions.inventory;
        return &(self.inventory orelse unreachable);
    }

    pub fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        configuration: Configuration,
        limits: Limits,
    ) InitError!State {
        var management_health: ManagementHealth =
            if (configuration.management.file_store != null and
            configuration.management.staging_root != null)
                .ready
            else
                .unavailable;
        if (configuration.management.restore_failed)
            management_health = .read_failed;
        var inventory = if (management_health == .ready and
            configuration.management.restored_bytes != null)
            management.decode(
                allocator,
                configuration.management.restored_bytes.?,
                .{ .max_assets = limits.max_assets },
            ) catch restore: {
                management_health = .corrupt;
                break :restore management.Inventory.init(
                    allocator,
                    .{ .max_assets = limits.max_assets },
                );
            }
        else
            management.Inventory.init(
                allocator,
                .{ .max_assets = limits.max_assets },
            );
        var inventory_owned = true;
        errdefer if (inventory_owned) inventory.deinit();
        var transactions: ?management.Transactions =
            if (configuration.management.file_store) |file_store|
                management.Transactions.init(
                    io,
                    allocator,
                    inventory,
                    file_store,
                )
            else
                null;
        if (transactions != null) inventory_owned = false;
        errdefer if (transactions) |*value| value.deinit();
        const staging_root = if (management_health == .ready) root: {
            const configured = configuration.management.staging_root.?;
            if (!std.fs.path.isAbsolute(configured) or
                !std.unicode.utf8ValidateSlice(configured))
            {
                management_health = .read_failed;
                break :root null;
            }
            const dir = std.Io.Dir.cwd().createDirPathOpen(
                io,
                configured,
                .{ .open_options = .{ .follow_symlinks = false } },
            ) catch {
                management_health = .read_failed;
                break :root null;
            };
            defer dir.close(io);
            var canonical_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const canonical_len = dir.realPath(io, &canonical_storage) catch {
                management_health = .read_failed;
                break :root null;
            };
            break :root try allocator.dupe(u8, canonical_storage[0..canonical_len]);
        } else null;
        errdefer if (staging_root) |root| allocator.free(root);
        const enablement_limits: enablement.Limits = .{
            .max_workspaces = limits.max_workspaces,
            .max_policy_keys = limits.max_policy_keys,
            .max_policy_key_bytes = limits.max_policy_key_bytes,
        };
        var enablement_health: EnablementHealth =
            if (configuration.enablement.file_store != null)
                .ready
            else
                .unavailable;
        if (configuration.enablement.restore_failed)
            enablement_health = .read_failed;
        var enablement_store = if (enablement_health == .ready and
            configuration.enablement.restored_bytes != null)
            enablement.decode(
                allocator,
                configuration.enablement.restored_bytes.?,
                enablement_limits,
            ) catch restore: {
                enablement_health = .corrupt;
                break :restore try enablement.Store.init(
                    allocator,
                    enablement_limits,
                );
            }
        else
            try enablement.Store.init(allocator, enablement_limits);
        errdefer enablement_store.deinit();
        return .{
            .inventory = if (transactions == null) inventory else null,
            .transactions = transactions,
            .management_health = management_health,
            .enablement_store = enablement_store,
            .enablement_file_store = configuration.enablement.file_store,
            .enablement_health = enablement_health,
            .staging_root = staging_root,
        };
    }

    pub fn deinit(
        self: *State,
        allocator: std.mem.Allocator,
        releaser: CatalogLeaseRelease,
    ) void {
        self.catalog.slot.deinit(releaser);
        if (self.transactions) |*transactions| transactions.deinit();
        if (self.inventory) |*inventory| inventory.deinit();
        self.enablement_store.deinit();
        if (self.staging_root) |root| allocator.free(root);
        self.* = undefined;
    }
};

test "catalog slot keeps product availability separate from release effect" {
    const slot: CatalogSlot = .unavailable;
    try std.testing.expectEqual(
        catalog.CatalogAvailability.unavailable,
        slot.availability(false),
    );
    try std.testing.expectEqual(
        catalog.CatalogAvailability.loading,
        slot.availability(true),
    );
}
