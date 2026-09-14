//! Live Product Workspace aggregate.
//! The Runtime owns the bounded Workspace registry, identity, authorization,
//! trust, projection storage and local lifecycle transitions. Product Control
//! remains the sole owner of shared Workspace+Task history commits and every
//! cross-aggregate effect.

const std = @import("std");
const builtin = @import("builtin");
const automatic_root = @import("product_workspace_automatic_root");

pub const AutomaticRoot = automatic_root.Root;

pub const Kind = enum { manual, automatic };
pub const Authorization = enum { available, removing, reauthorization_required };
pub const RemovalFailure = enum { none, task_close_failed };
pub const RemovalState = enum { close_failed, pending, ready };

pub const Signals = struct {
    running: u32 = 0,
    attention: u32 = 0,
    failed_or_interrupted: u32 = 0,
};

pub const TrustInput = union(enum) {
    explicitly_trusted,
    temporary: []const u8,
};

pub const TrustFact = union(enum) {
    explicitly_trusted,
    temporary: []const u8,
};

pub const Facts = struct {
    id: u64,
    kind: Kind,
    automatic_task_id: u64,
    epoch: u64,
    canonical_root: []const u8,
    projected_root: []const u8,
    display_name: []const u8,
    projection_redacted: bool,
    trust: TrustFact,
    authorization: Authorization,
    last_removal_failure: RemovalFailure,
    visible: bool,
    recent_order: u64,
};

pub const Binding = struct {
    id: u64,
    epoch: u64,
    canonical_root: []const u8,
};

pub const TaskAuthority = struct {
    id: u64,
    epoch: u64,
    kind: Kind,
    canonical_root: []const u8,
    trust: TrustFact,
};

pub const RecoveryAuthority = struct {
    canonical_root: []const u8 = "",
    kind: Kind = .manual,
    identity_exact: bool = false,
    automatic_owner_exact: bool = false,
    exists: bool = false,
};

pub const HistoryFact = struct {
    id: u64,
    epoch: u64,
    kind: Kind,
    canonical_root: []const u8,
    display_name: []const u8,
    visible: bool,
    recent_order: u64,
};

pub const RestoreFact = HistoryFact;

pub const ProjectedText = struct {
    value: []u8,
    redacted: bool,
};

pub const StorageError = std.mem.Allocator.Error || error{ProjectionCapacity};

/// Callback-scoped access to Product Control's single projection budget and
/// credential-aware text projector. Runtime never retains this capability.
pub const Storage = struct {
    context: *anyopaque,
    copy_fn: *const fn (*anyopaque, []const u8, usize) StorageError![]u8,
    project_fn: *const fn (*anyopaque, []const u8, usize, []const u8) StorageError!ProjectedText,
    free_fn: *const fn (*anyopaque, []u8) void,
    redact_fn: *const fn (*anyopaque, []u8, *usize, []const u8) bool,

    pub fn copy(self: Storage, value: []const u8, max: usize) StorageError![]u8 {
        return self.copy_fn(self.context, value, max);
    }

    pub fn project(
        self: Storage,
        value: []const u8,
        max: usize,
        sensitive: []const u8,
    ) StorageError!ProjectedText {
        return self.project_fn(self.context, value, max, sensitive);
    }

    pub fn free(self: Storage, value: []u8) void {
        self.free_fn(self.context, value);
    }
};

pub const Error = StorageError || error{
    InvalidWorkspace,
    WorkspaceNotTrusted,
    WorkspaceCapacity,
    WorkspaceIdentityExhausted,
    WorkspaceOrderExhausted,
    WorkspaceEpochExhausted,
    WorkspaceRemovalInProgress,
    WorkspaceEpochMismatch,
    WorkspaceUnavailable,
    UnknownWorkspace,
};

/// Linear preparation for one automatic Workspace record and its private
/// directory allocation. The concrete allocator remains owned by Runtime.
pub const PreparedAutomaticWorkspace = struct {
    index: usize,
    workspace_id: u64,
    active: bool = true,

    pub fn id(self: *const PreparedAutomaticWorkspace) u64 {
        std.debug.assert(self.active);
        return self.workspace_id;
    }

    pub fn isActive(self: *const PreparedAutomaticWorkspace) bool {
        return self.active;
    }
};

const Trust = union(enum) {
    explicitly_trusted,
    temporary: []u8,
};

const Record = struct {
    id: u64,
    kind: Kind = .manual,
    automatic_task_id: u64 = 0,
    epoch: u64 = 1,
    canonical_root: []u8,
    projected_root_storage: []u8,
    projected_root_len: usize,
    display_name_storage: []u8,
    display_name_len: usize,
    projection_redacted: bool = false,
    trust: Trust,
    authorization: Authorization = .available,
    last_removal_failure: RemovalFailure = .none,
    visible: bool = true,
    recent_order: u64,
};

const ExistingState = struct {
    trust: Trust,
    authorization: Authorization,
    visible: bool,
    epoch: u64,
    recent_order: u64,
};

pub const OpenPreparation = struct {
    index: usize,
    recent_order: u64,
    previous: union(enum) {
        existing: ExistingState,
        created: struct {
            next_workspace_id: u64,
            replaced: ?Record,
        },
    },
    active: bool = true,

    pub fn isActive(self: *const OpenPreparation) bool {
        return self.active;
    }
};

pub const OpenAuthority = struct {
    context: *const anyopaque,
    automatic_contains_fn: *const fn (*const anyopaque, []const u8) bool,
    reusable_fn: *const fn (*const anyopaque, u64) bool,

    fn automaticContains(self: OpenAuthority, path: []const u8) bool {
        return self.automatic_contains_fn(self.context, path);
    }

    fn reusable(self: OpenAuthority, id: u64) bool {
        return self.reusable_fn(self.context, id);
    }
};

pub const RemovalPreparation = struct {
    index: usize,
    epoch: u64,
    previous_epoch: u64,
    previous_authorization: Authorization,
    previous_failure: RemovalFailure,
    active: bool = true,

    pub fn isActive(self: *const RemovalPreparation) bool {
        return self.active;
    }
};

pub const OrderPreparation = struct {
    index: usize,
    recent_order: u64,
    previous_order: u64,
    active: bool = true,

    pub fn inactive() OrderPreparation {
        return .{
            .index = 0,
            .recent_order = 0,
            .previous_order = 0,
            .active = false,
        };
    }

    pub fn isActive(self: *const OrderPreparation) bool {
        return self.active;
    }

    pub fn recentOrder(self: *const OrderPreparation) u64 {
        return self.recent_order;
    }
};

pub const RemovedAutomatic = struct {
    index: usize,
    record: Record,
    active: bool = true,
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    records: []?Record,
    pending_automatic: []?automatic_root.Allocation,
    max_manual: usize,
    max_automatic: usize,
    max_workspace_bytes: usize,
    automatic_allocator: ?automatic_root.Allocator,
    next_id: u64 = 1,
    next_recent_order: u64 = 1,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        max_manual: usize,
        max_automatic: usize,
        max_workspace_bytes: usize,
        automatic_root_capability: ?*AutomaticRoot,
    ) Error!Runtime {
        const capacity = std.math.add(usize, max_manual, max_automatic) catch
            return error.ProjectionCapacity;
        const records = try allocator.alloc(?Record, capacity);
        errdefer allocator.free(records);
        @memset(records, null);
        const pending_automatic = try allocator.alloc(?automatic_root.Allocation, capacity);
        @memset(pending_automatic, null);
        return .{
            .allocator = allocator,
            .io = io,
            .records = records,
            .pending_automatic = pending_automatic,
            .max_manual = max_manual,
            .max_automatic = max_automatic,
            .max_workspace_bytes = max_workspace_bytes,
            .automatic_allocator = if (automatic_root_capability) |root|
                automatic_root.Allocator.init(root)
            else
                null,
        };
    }

    pub fn deinit(self: *Runtime, storage: Storage) void {
        for (self.records, self.pending_automatic) |*entry, *pending| {
            if (pending.*) |*allocation| allocation.deinit();
            pending.* = null;
            var record = entry.* orelse continue;
            deinitRecord(&record, storage);
            entry.* = null;
        }
        self.allocator.free(self.pending_automatic);
        self.allocator.free(self.records);
        if (self.automatic_allocator) |*allocator| allocator.deinit();
        self.* = undefined;
    }

    pub fn deinitEmpty(self: *Runtime) void {
        std.debug.assert(self.historyCount() == 0);
        for (self.pending_automatic) |entry| std.debug.assert(entry == null);
        self.allocator.free(self.pending_automatic);
        self.allocator.free(self.records);
        if (self.automatic_allocator) |*allocator| allocator.deinit();
        self.* = undefined;
    }

    pub fn automaticRootAvailable(self: *const Runtime) bool {
        return self.automatic_allocator != null;
    }

    pub fn automaticRootPath(self: *const Runtime) ?[]const u8 {
        const allocator = if (self.automatic_allocator) |*value| value else return null;
        return allocator.canonicalRoot();
    }

    pub fn automaticRootContains(self: *const Runtime, path: []const u8) bool {
        const allocator = if (self.automatic_allocator) |*value| value else return false;
        return allocator.containsCanonicalPath(path);
    }

    pub fn slotCount(self: *const Runtime) usize {
        return self.records.len;
    }

    pub fn count(self: *const Runtime, kind: Kind) usize {
        var result: usize = 0;
        for (self.records) |entry| if (entry) |record|
            if (record.kind == kind) {
                result += 1;
            };
        return result;
    }

    pub fn automaticCapacityAvailable(self: *const Runtime) bool {
        return self.count(.automatic) < self.max_automatic;
    }

    pub fn historyCount(self: *const Runtime) usize {
        var result: usize = 0;
        for (self.records) |entry| if (entry != null) {
            result += 1;
        };
        return result;
    }

    pub fn facts(self: *const Runtime, id: u64) ?Facts {
        const index = self.findIndex(id) orelse return null;
        return factsFromRecord(&self.records[index].?);
    }

    pub fn factsAt(self: *const Runtime, index: usize) ?Facts {
        if (index >= self.records.len) return null;
        const record = &(self.records[index] orelse return null);
        return factsFromRecord(record);
    }

    pub fn findByRoot(self: *const Runtime, root: []const u8) ?Facts {
        const index = self.findIndexByRoot(root) orelse return null;
        return factsFromRecord(&self.records[index].?);
    }

    pub fn historyAt(self: *const Runtime, index: usize) ?HistoryFact {
        if (index >= self.records.len) return null;
        const record = self.records[index] orelse return null;
        return .{
            .id = record.id,
            .epoch = record.epoch,
            .kind = record.kind,
            .canonical_root = record.canonical_root,
            .display_name = record.display_name_storage[0..record.display_name_len],
            .visible = record.visible,
            .recent_order = record.recent_order,
        };
    }

    pub fn bindingAt(self: *const Runtime, index: usize) ?struct {
        id: u64,
        epoch: u64,
        canonical_root: []const u8,
    } {
        const fact = self.factsAt(index) orelse return null;
        return .{ .id = fact.id, .epoch = fact.epoch, .canonical_root = fact.canonical_root };
    }

    pub fn binding(self: *const Runtime, id: u64) ?Binding {
        const fact = self.facts(id) orelse return null;
        return .{
            .id = fact.id,
            .epoch = fact.epoch,
            .canonical_root = fact.canonical_root,
        };
    }

    pub fn availableManualBindingAt(self: *const Runtime, index: usize) ?Binding {
        const fact = self.factsAt(index) orelse return null;
        if (fact.kind != .manual or !fact.visible or
            fact.authorization != .available) return null;
        return .{
            .id = fact.id,
            .epoch = fact.epoch,
            .canonical_root = fact.canonical_root,
        };
    }

    pub fn visibleManualBindingAt(self: *const Runtime, index: usize) ?Binding {
        const fact = self.factsAt(index) orelse return null;
        if (fact.kind != .manual or !fact.visible) return null;
        return .{
            .id = fact.id,
            .epoch = fact.epoch,
            .canonical_root = fact.canonical_root,
        };
    }

    pub fn automaticBindingAt(self: *const Runtime, index: usize) ?Binding {
        const fact = self.factsAt(index) orelse return null;
        if (fact.kind != .automatic) return null;
        return .{
            .id = fact.id,
            .epoch = fact.epoch,
            .canonical_root = fact.canonical_root,
        };
    }

    pub fn filePreviewAuthorized(
        self: *const Runtime,
        id: u64,
        epoch: u64,
        canonical_root: []const u8,
    ) bool {
        const fact = self.facts(id) orelse return false;
        return fact.epoch == epoch and fact.authorization == .available and
            std.mem.eql(u8, fact.canonical_root, canonical_root);
    }

    pub fn taskCreateAuthority(
        self: *const Runtime,
        id: u64,
        expected_epoch: u64,
        allow_unowned_automatic: bool,
    ) Error!TaskAuthority {
        const fact = self.facts(id) orelse return error.UnknownWorkspace;
        if (expected_epoch == 0 or expected_epoch != fact.epoch)
            return error.WorkspaceEpochMismatch;
        if (fact.kind == .automatic and
            (!allow_unowned_automatic or fact.automatic_task_id != 0))
            return error.WorkspaceUnavailable;
        if (fact.kind == .manual and !fact.visible)
            return error.WorkspaceUnavailable;
        if (fact.authorization == .removing)
            return error.WorkspaceRemovalInProgress;
        if (fact.authorization != .available)
            return error.WorkspaceUnavailable;
        return taskAuthorityFromFacts(fact);
    }

    pub fn taskRunAuthority(
        self: *const Runtime,
        id: u64,
        expected_epoch: u64,
    ) Error!TaskAuthority {
        const fact = self.facts(id) orelse return error.WorkspaceUnavailable;
        if (fact.kind == .manual and !fact.visible)
            return error.WorkspaceUnavailable;
        if (fact.authorization == .removing)
            return error.WorkspaceRemovalInProgress;
        if (fact.authorization != .available)
            return error.WorkspaceUnavailable;
        if (fact.epoch != expected_epoch) return error.WorkspaceEpochMismatch;
        return taskAuthorityFromFacts(fact);
    }

    pub fn recoveryBinding(self: *const Runtime, id: u64) ?TaskAuthority {
        const fact = self.facts(id) orelse return null;
        return taskAuthorityFromFacts(fact);
    }

    pub fn recoveryAuthority(
        self: *const Runtime,
        id: u64,
        expected_epoch: u64,
        expected_root: ?[]const u8,
        task_id: u64,
    ) RecoveryAuthority {
        const fact = self.facts(id) orelse return .{};
        return .{
            .canonical_root = fact.canonical_root,
            .kind = fact.kind,
            .identity_exact = fact.authorization == .available and
                fact.epoch == expected_epoch and
                (expected_root == null or
                    std.mem.eql(u8, fact.canonical_root, expected_root.?)),
            .automatic_owner_exact = fact.kind != .automatic or
                fact.automatic_task_id == task_id,
            .exists = true,
        };
    }

    pub fn prepareOpen(
        self: *Runtime,
        workspace_root: []const u8,
        trust_input: TrustInput,
        sensitive: []const u8,
        storage: Storage,
        authority: OpenAuthority,
    ) Error!OpenPreparation {
        // Preserve Product Control's existing identity discipline: an open
        // attempt consumes an order before validating its candidate. Only a
        // prepared candidate can roll that order back after durable failure.
        const recent_order = try self.takeRecentOrder();
        if (!std.fs.path.isAbsolute(workspace_root)) return error.InvalidWorkspace;
        const canonical = std.Io.Dir.realPathFileAbsoluteAlloc(
            self.io,
            workspace_root,
            self.allocator,
        ) catch return error.InvalidWorkspace;
        defer self.allocator.free(canonical);
        if (canonical.len > self.max_workspace_bytes) return error.ProjectionCapacity;
        const workspace_stat = std.Io.Dir.cwd().statFile(self.io, canonical, .{}) catch
            return error.InvalidWorkspace;
        if (workspace_stat.kind != .directory or authority.automaticContains(canonical))
            return error.InvalidWorkspace;

        var canonical_temporary: ?[:0]u8 = null;
        defer if (canonical_temporary) |root| self.allocator.free(root);
        switch (trust_input) {
            .explicitly_trusted => {},
            .temporary => |root| {
                if (!std.fs.path.isAbsolute(root)) return error.InvalidWorkspace;
                const temporary = std.Io.Dir.realPathFileAbsoluteAlloc(
                    self.io,
                    root,
                    self.allocator,
                ) catch return error.InvalidWorkspace;
                canonical_temporary = temporary;
                if (temporary.len > self.max_workspace_bytes)
                    return error.ProjectionCapacity;
                const stat = std.Io.Dir.cwd().statFile(self.io, temporary, .{}) catch
                    return error.InvalidWorkspace;
                if (stat.kind != .directory) return error.InvalidWorkspace;
                if (!pathWithin(temporary, canonical)) return error.WorkspaceNotTrusted;
            },
        }

        if (self.findIndexByRoot(canonical)) |index| {
            const record = &self.records[index].?;
            if (record.authorization == .removing)
                return error.WorkspaceRemovalInProgress;
            const reopening_removed = !record.visible;
            if (reopening_removed and record.epoch == std.math.maxInt(u64))
                return error.WorkspaceEpochExhausted;
            const next_temporary = if (canonical_temporary) |root|
                try storage.copy(root, self.max_workspace_bytes)
            else
                null;
            const previous = ExistingState{
                .trust = record.trust,
                .authorization = record.authorization,
                .visible = record.visible,
                .epoch = record.epoch,
                .recent_order = record.recent_order,
            };
            record.trust = if (next_temporary) |root|
                .{ .temporary = root }
            else
                .explicitly_trusted;
            record.authorization = .available;
            record.visible = true;
            record.recent_order = recent_order;
            if (reopening_removed) record.epoch += 1;
            return .{
                .index = index,
                .recent_order = recent_order,
                .previous = .{ .existing = previous },
            };
        }

        var slot: ?usize = null;
        var replaced: ?Record = null;
        for (self.records, 0..) |*entry, index| {
            const record = &(entry.* orelse continue);
            if (record.kind != .manual or record.visible or !authority.reusable(record.id))
                continue;
            replaced = record.*;
            entry.* = null;
            slot = index;
            break;
        }
        var restore_replaced = true;
        errdefer {
            if (restore_replaced) {
                if (slot) |index| self.records[index] = replaced;
            }
        }
        if (slot == null and self.count(.manual) >= self.max_manual)
            return error.WorkspaceCapacity;
        if (slot == null) slot = findEmpty(self.records);
        const target = slot orelse return error.WorkspaceCapacity;
        if (self.next_id == 0 or self.next_id == std.math.maxInt(u64))
            return error.WorkspaceIdentityExhausted;

        const owned_root = try storage.copy(canonical, self.max_workspace_bytes);
        errdefer storage.free(owned_root);
        const projected_root = try storage.project(canonical, self.max_workspace_bytes, sensitive);
        errdefer storage.free(projected_root.value);
        const base_name = std.fs.path.basename(canonical);
        const display_name = try storage.project(
            if (base_name.len == 0) canonical else base_name,
            self.max_workspace_bytes,
            sensitive,
        );
        errdefer storage.free(display_name.value);
        const owned_temporary = if (canonical_temporary) |root|
            try storage.copy(root, self.max_workspace_bytes)
        else
            null;
        errdefer if (owned_temporary) |root| storage.free(root);

        const previous_next_id = self.next_id;
        self.next_id += 1;
        self.records[target] = .{
            .id = previous_next_id,
            .canonical_root = owned_root,
            .projected_root_storage = projected_root.value,
            .projected_root_len = projected_root.value.len,
            .display_name_storage = display_name.value,
            .display_name_len = display_name.value.len,
            .projection_redacted = projected_root.redacted or display_name.redacted,
            .trust = if (owned_temporary) |root| .{ .temporary = root } else .explicitly_trusted,
            .recent_order = recent_order,
        };
        restore_replaced = false;
        return .{
            .index = target,
            .recent_order = recent_order,
            .previous = .{ .created = .{
                .next_workspace_id = previous_next_id,
                .replaced = replaced,
            } },
        };
    }

    pub fn preparedFacts(self: *const Runtime, preparation: *const OpenPreparation) Facts {
        std.debug.assert(preparation.active);
        return factsFromRecord(&self.records[preparation.index].?);
    }

    pub fn rollbackOpen(self: *Runtime, preparation: *OpenPreparation, storage: Storage) void {
        std.debug.assert(preparation.active);
        self.next_recent_order = preparation.recent_order;
        switch (preparation.previous) {
            .existing => |previous| {
                const record = &self.records[preparation.index].?;
                if (record.trust == .temporary) storage.free(record.trust.temporary);
                record.trust = previous.trust;
                record.authorization = previous.authorization;
                record.visible = previous.visible;
                record.epoch = previous.epoch;
                record.recent_order = previous.recent_order;
            },
            .created => |previous| {
                var record = self.records[preparation.index].?;
                self.records[preparation.index] = null;
                deinitRecord(&record, storage);
                self.records[preparation.index] = previous.replaced;
                self.next_id = previous.next_workspace_id;
            },
        }
        preparation.active = false;
    }

    /// Returns the id of a displaced hidden binding, if any.
    pub fn commitOpen(
        self: *Runtime,
        preparation: *OpenPreparation,
        storage: Storage,
    ) ?u64 {
        _ = self;
        std.debug.assert(preparation.active);
        const displaced = switch (preparation.previous) {
            .existing => |previous| blk: {
                if (previous.trust == .temporary) storage.free(previous.trust.temporary);
                break :blk null;
            },
            .created => |previous| if (previous.replaced) |value| blk: {
                var replaced = value;
                const id = replaced.id;
                deinitRecord(&replaced, storage);
                break :blk id;
            } else null,
        };
        preparation.active = false;
        return displaced;
    }

    pub fn prepareRemoval(
        self: *Runtime,
        id: u64,
        expected_epoch: u64,
    ) Error!RemovalPreparation {
        const index = self.findIndex(id) orelse return error.UnknownWorkspace;
        const record = &self.records[index].?;
        if (record.kind != .manual or !record.visible) return error.UnknownWorkspace;
        if (expected_epoch == 0 or record.epoch != expected_epoch)
            return error.WorkspaceEpochMismatch;
        if (record.authorization == .removing) return error.WorkspaceRemovalInProgress;
        if (record.epoch == std.math.maxInt(u64)) return error.WorkspaceEpochExhausted;
        const preparation: RemovalPreparation = .{
            .index = index,
            .epoch = record.epoch + 1,
            .previous_epoch = record.epoch,
            .previous_authorization = record.authorization,
            .previous_failure = record.last_removal_failure,
        };
        record.epoch = preparation.epoch;
        record.authorization = .removing;
        record.last_removal_failure = .none;
        return preparation;
    }

    pub fn preparedRemovalFacts(
        self: *const Runtime,
        preparation: *const RemovalPreparation,
    ) Facts {
        std.debug.assert(preparation.active);
        return factsFromRecord(&self.records[preparation.index].?);
    }

    pub fn rollbackRemoval(self: *Runtime, preparation: *RemovalPreparation) void {
        std.debug.assert(preparation.active);
        const record = &self.records[preparation.index].?;
        record.epoch = preparation.previous_epoch;
        record.authorization = preparation.previous_authorization;
        record.last_removal_failure = preparation.previous_failure;
        preparation.active = false;
    }

    pub fn commitRemoval(_: *Runtime, preparation: *RemovalPreparation) void {
        std.debug.assert(preparation.active);
        preparation.active = false;
    }

    pub fn failRemovalStart(self: *Runtime, id: u64) void {
        const index = self.findIndex(id) orelse unreachable;
        const record = &self.records[index].?;
        std.debug.assert(record.authorization == .removing);
        record.authorization = .available;
        record.last_removal_failure = .task_close_failed;
    }

    pub fn applyRemovalState(self: *Runtime, id: u64, state: RemovalState) bool {
        const index = self.findIndex(id) orelse return false;
        const record = &self.records[index].?;
        if (!record.visible or record.authorization != .removing) return false;
        switch (state) {
            .pending => return false,
            .close_failed => {
                record.authorization = .available;
                record.last_removal_failure = .task_close_failed;
            },
            .ready => {
                record.authorization = .reauthorization_required;
                record.visible = false;
            },
        }
        return true;
    }

    pub fn prepareOrder(self: *Runtime, id: u64) Error!OrderPreparation {
        const index = self.findIndex(id) orelse return error.UnknownWorkspace;
        const record = &self.records[index].?;
        const recent_order = try self.takeRecentOrder();
        return .{
            .index = index,
            .recent_order = recent_order,
            .previous_order = record.recent_order,
        };
    }

    pub fn applyOrder(self: *Runtime, preparation: *OrderPreparation) void {
        std.debug.assert(preparation.active);
        self.records[preparation.index].?.recent_order = preparation.recent_order;
    }

    pub fn commitOrder(_: *Runtime, preparation: *OrderPreparation) void {
        std.debug.assert(preparation.active);
        preparation.active = false;
    }

    pub fn rollbackOrder(self: *Runtime, preparation: *OrderPreparation) void {
        std.debug.assert(preparation.active);
        self.records[preparation.index].?.recent_order = preparation.previous_order;
        self.next_recent_order = preparation.recent_order;
        preparation.active = false;
    }

    pub fn prepareAutomatic(
        self: *Runtime,
        sensitive: []const u8,
        storage: Storage,
    ) Error!PreparedAutomaticWorkspace {
        const allocator = if (self.automatic_allocator) |*value| value else return error.WorkspaceUnavailable;
        if (self.count(.automatic) >= self.max_automatic) return error.WorkspaceCapacity;
        const target = findEmpty(self.records) orelse return error.WorkspaceCapacity;
        std.debug.assert(self.pending_automatic[target] == null);
        var allocation = allocator.allocate() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidAutomaticRoot => return error.InvalidWorkspace,
            error.RootUnavailable, error.AllocationUnavailable => return error.WorkspaceUnavailable,
        };
        errdefer _ = allocator.rollback(&allocation);
        const canonical_root = allocation.path();
        if (!std.fs.path.isAbsolute(canonical_root) or
            canonical_root.len > self.max_workspace_bytes or
            !std.unicode.utf8ValidateSlice(canonical_root) or
            self.findIndexByRoot(canonical_root) != null)
            return error.InvalidWorkspace;
        if (self.next_id == 0 or self.next_id == std.math.maxInt(u64))
            return error.WorkspaceIdentityExhausted;
        const owned_root = try storage.copy(canonical_root, self.max_workspace_bytes);
        errdefer storage.free(owned_root);
        const projected_root = try storage.project(
            canonical_root,
            self.max_workspace_bytes,
            sensitive,
        );
        errdefer storage.free(projected_root.value);
        const display_name = try storage.project(
            "Automatic workspace",
            self.max_workspace_bytes,
            sensitive,
        );
        errdefer storage.free(display_name.value);
        const temporary = try storage.copy(canonical_root, self.max_workspace_bytes);
        errdefer storage.free(temporary);
        const id = self.next_id;
        self.next_id += 1;
        self.records[target] = .{
            .id = id,
            .kind = .automatic,
            .canonical_root = owned_root,
            .projected_root_storage = projected_root.value,
            .projected_root_len = projected_root.value.len,
            .display_name_storage = display_name.value,
            .display_name_len = display_name.value.len,
            .projection_redacted = projected_root.redacted or display_name.redacted,
            .trust = .{ .temporary = temporary },
            .visible = false,
            .recent_order = 0,
        };
        self.pending_automatic[target] = allocation;
        return .{ .index = target, .workspace_id = id };
    }

    pub fn preparedAutomaticFacts(
        self: *const Runtime,
        preparation: *const PreparedAutomaticWorkspace,
    ) Facts {
        std.debug.assert(preparation.active and preparation.index < self.records.len);
        const record = &self.records[preparation.index].?;
        std.debug.assert(record.id == preparation.workspace_id and record.kind == .automatic);
        std.debug.assert(self.pending_automatic[preparation.index] != null);
        return factsFromRecord(record);
    }

    pub fn completeAutomatic(self: *Runtime, preparation: *PreparedAutomaticWorkspace) void {
        std.debug.assert(preparation.active and preparation.index < self.records.len);
        const record = &self.records[preparation.index].?;
        std.debug.assert(record.id == preparation.workspace_id and record.kind == .automatic);
        var allocation = self.pending_automatic[preparation.index].?;
        self.pending_automatic[preparation.index] = null;
        allocation.deinit();
        preparation.active = false;
    }

    pub fn rollbackPreparedAutomatic(
        self: *Runtime,
        preparation: *PreparedAutomaticWorkspace,
        storage: Storage,
    ) bool {
        std.debug.assert(preparation.active and preparation.index < self.records.len);
        var record = self.records[preparation.index].?;
        std.debug.assert(record.id == preparation.workspace_id and record.kind == .automatic);
        var allocation = self.pending_automatic[preparation.index].?;
        self.records[preparation.index] = null;
        self.pending_automatic[preparation.index] = null;
        deinitRecord(&record, storage);
        const allocator = if (self.automatic_allocator) |*value| value else unreachable;
        const deleted = allocator.rollback(&allocation);
        preparation.active = false;
        return deleted;
    }

    pub fn abandonPreparedAutomatic(
        self: *Runtime,
        preparation: *PreparedAutomaticWorkspace,
        storage: Storage,
    ) void {
        std.debug.assert(preparation.active and preparation.index < self.records.len);
        var record = self.records[preparation.index].?;
        std.debug.assert(record.id == preparation.workspace_id and record.kind == .automatic);
        var allocation = self.pending_automatic[preparation.index].?;
        self.records[preparation.index] = null;
        self.pending_automatic[preparation.index] = null;
        deinitRecord(&record, storage);
        allocation.deinit();
        preparation.active = false;
    }

    pub fn setAutomaticOwner(self: *Runtime, id: u64, task_id: u64) void {
        const index = self.findIndex(id) orelse unreachable;
        const record = &self.records[index].?;
        std.debug.assert(record.kind == .automatic and record.automatic_task_id == 0);
        record.automatic_task_id = task_id;
    }

    pub fn releaseAutomatic(self: *Runtime, id: u64, storage: Storage) void {
        const index = self.findIndex(id) orelse unreachable;
        std.debug.assert(self.pending_automatic[index] == null);
        var record = self.records[index].?;
        std.debug.assert(record.kind == .automatic);
        self.records[index] = null;
        deinitRecord(&record, storage);
    }

    pub fn takeAutomatic(self: *Runtime, id: u64) ?RemovedAutomatic {
        const index = self.findIndex(id) orelse return null;
        std.debug.assert(self.pending_automatic[index] == null);
        const record = self.records[index].?;
        if (record.kind != .automatic) return null;
        self.records[index] = null;
        return .{ .index = index, .record = record };
    }

    pub fn rollbackAutomatic(self: *Runtime, removed: *RemovedAutomatic) void {
        std.debug.assert(removed.active and self.records[removed.index] == null);
        self.records[removed.index] = removed.record;
        removed.active = false;
    }

    pub fn commitAutomaticRemoval(
        _: *Runtime,
        removed: *RemovedAutomatic,
        storage: Storage,
    ) void {
        std.debug.assert(removed.active);
        deinitRecord(&removed.record, storage);
        removed.active = false;
    }

    pub fn restore(
        self: *Runtime,
        fact: RestoreFact,
        storage: Storage,
    ) Error!void {
        const target = findEmpty(self.records) orelse return error.WorkspaceCapacity;
        const canonical_root = try storage.copy(fact.canonical_root, self.max_workspace_bytes);
        errdefer storage.free(canonical_root);
        const projected_root = try storage.copy(fact.canonical_root, self.max_workspace_bytes);
        errdefer storage.free(projected_root);
        const display_name = try storage.copy(fact.display_name, self.max_workspace_bytes);
        errdefer storage.free(display_name);
        const temporary = try storage.copy(fact.canonical_root, self.max_workspace_bytes);
        errdefer storage.free(temporary);
        self.records[target] = .{
            .id = fact.id,
            .kind = fact.kind,
            .epoch = fact.epoch,
            .canonical_root = canonical_root,
            .projected_root_storage = projected_root,
            .projected_root_len = projected_root.len,
            .display_name_storage = display_name,
            .display_name_len = display_name.len,
            .trust = .{ .temporary = temporary },
            .authorization = if (fact.kind == .automatic) .available else .reauthorization_required,
            .visible = fact.visible,
            .recent_order = fact.recent_order,
        };
    }

    pub fn restoreIdentity(self: *Runtime, next_id: u64, next_recent_order: u64) void {
        self.next_id = next_id;
        self.next_recent_order = next_recent_order;
    }

    /// Raises the identity allocator above ids still referenced by other
    /// owners' durable records, so a lost or older history cannot hand a new
    /// Workspace an id that older Skill records already claim.
    pub fn reserveIdentity(self: *Runtime, highest_referenced_id: u64) void {
        // An exhausted reference makes every later allocation fail closed
        // through the existing identity check instead of wrapping around.
        self.next_id = if (highest_referenced_id == std.math.maxInt(u64))
            std.math.maxInt(u64)
        else
            @max(self.next_id, highest_referenced_id + 1);
    }

    pub fn identity(self: *const Runtime) struct {
        next_id: u64,
        next_recent_order: u64,
    } {
        return .{
            .next_id = self.next_id,
            .next_recent_order = self.next_recent_order,
        };
    }

    pub fn reset(self: *Runtime, storage: Storage) void {
        for (self.records, self.pending_automatic) |*entry, *pending| {
            if (pending.*) |*allocation| allocation.deinit();
            pending.* = null;
            var record = entry.* orelse continue;
            deinitRecord(&record, storage);
            entry.* = null;
        }
        self.next_id = 1;
        self.next_recent_order = 1;
    }

    pub fn redactNoFail(self: *Runtime, credential: []const u8, storage: Storage) void {
        if (credential.len == 0) return;
        for (self.records) |*entry| {
            const record = &(entry.* orelse continue);
            const root_redacted = storage.redact_fn(
                storage.context,
                record.projected_root_storage,
                &record.projected_root_len,
                credential,
            );
            const name_redacted = storage.redact_fn(
                storage.context,
                record.display_name_storage,
                &record.display_name_len,
                credential,
            );
            record.projection_redacted = root_redacted or name_redacted or
                record.projection_redacted;
        }
    }

    pub fn setAutomaticOwnerFromRestore(self: *Runtime, workspace_id: u64, task_id: u64) void {
        const index = self.findIndex(workspace_id) orelse return;
        const record = &self.records[index].?;
        if (record.kind == .automatic) record.automatic_task_id = task_id;
    }

    pub fn removeAt(self: *Runtime, index: usize, storage: Storage) void {
        std.debug.assert(self.pending_automatic[index] == null);
        var record = self.records[index] orelse return;
        self.records[index] = null;
        deinitRecord(&record, storage);
    }

    fn takeRecentOrder(self: *Runtime) Error!u64 {
        if (self.next_recent_order == 0 or
            self.next_recent_order == std.math.maxInt(u64))
            return error.WorkspaceOrderExhausted;
        const result = self.next_recent_order;
        self.next_recent_order += 1;
        return result;
    }

    fn findIndex(self: *const Runtime, id: u64) ?usize {
        if (id == 0) return null;
        for (self.records, 0..) |entry, index| if (entry) |record|
            if (record.id == id) return index;
        return null;
    }

    fn findIndexByRoot(self: *const Runtime, root: []const u8) ?usize {
        for (self.records, 0..) |entry, index| if (entry) |record|
            if (std.mem.eql(u8, record.canonical_root, root)) return index;
        return null;
    }
};

fn factsFromRecord(record: *const Record) Facts {
    return .{
        .id = record.id,
        .kind = record.kind,
        .automatic_task_id = record.automatic_task_id,
        .epoch = record.epoch,
        .canonical_root = record.canonical_root,
        .projected_root = record.projected_root_storage[0..record.projected_root_len],
        .display_name = record.display_name_storage[0..record.display_name_len],
        .projection_redacted = record.projection_redacted,
        .trust = switch (record.trust) {
            .explicitly_trusted => .explicitly_trusted,
            .temporary => |root| .{ .temporary = root },
        },
        .authorization = record.authorization,
        .last_removal_failure = record.last_removal_failure,
        .visible = record.visible,
        .recent_order = record.recent_order,
    };
}

fn taskAuthorityFromFacts(fact: Facts) TaskAuthority {
    return .{
        .id = fact.id,
        .epoch = fact.epoch,
        .kind = fact.kind,
        .canonical_root = fact.canonical_root,
        .trust = fact.trust,
    };
}

fn deinitRecord(record: *Record, storage: Storage) void {
    storage.free(record.canonical_root);
    storage.free(record.projected_root_storage);
    storage.free(record.display_name_storage);
    if (record.trust == .temporary) storage.free(record.trust.temporary);
    record.* = undefined;
}

fn findEmpty(records: []?Record) ?usize {
    for (records, 0..) |entry, index| if (entry == null) return index;
    return null;
}

fn pathWithin(parent: []const u8, child: []const u8) bool {
    if (std.mem.eql(u8, parent, child)) return true;
    if (!std.mem.startsWith(u8, child, parent)) return false;
    if (parent.len != 0 and std.fs.path.isSep(parent[parent.len - 1])) return true;
    return child.len > parent.len and std.fs.path.isSep(child[parent.len]);
}

pub const testing = if (builtin.is_test) struct {
    pub fn installAutomaticRoot(runtime: *Runtime, root: *AutomaticRoot) void {
        std.debug.assert(runtime.automatic_allocator == null);
        runtime.automatic_allocator = automatic_root.Allocator.init(root);
    }

    pub const OwnedRecord = struct {
        id: u64,
        kind: Kind = .manual,
        automatic_task_id: u64 = 0,
        epoch: u64 = 1,
        canonical_root: []u8,
        projected_root_storage: []u8,
        projected_root_len: usize,
        display_name_storage: []u8,
        display_name_len: usize,
        temporary_root: ?[]u8 = null,
        authorization: Authorization = .available,
        last_removal_failure: RemovalFailure = .none,
        visible: bool = true,
        recent_order: u64,
        projection_redacted: bool = false,
    };

    pub fn installOwned(runtime: *Runtime, index: usize, input: OwnedRecord) void {
        std.debug.assert(index < runtime.records.len and runtime.records[index] == null);
        runtime.records[index] = .{
            .id = input.id,
            .kind = input.kind,
            .automatic_task_id = input.automatic_task_id,
            .epoch = input.epoch,
            .canonical_root = input.canonical_root,
            .projected_root_storage = input.projected_root_storage,
            .projected_root_len = input.projected_root_len,
            .display_name_storage = input.display_name_storage,
            .display_name_len = input.display_name_len,
            .projection_redacted = input.projection_redacted,
            .trust = if (input.temporary_root) |root|
                .{ .temporary = root }
            else
                .explicitly_trusted,
            .authorization = input.authorization,
            .last_removal_failure = input.last_removal_failure,
            .visible = input.visible,
            .recent_order = input.recent_order,
        };
    }

    pub fn setIdentity(runtime: *Runtime, next_id: u64, next_recent_order: u64) void {
        runtime.restoreIdentity(next_id, next_recent_order);
    }

    pub fn setManualLimit(runtime: *Runtime, value: usize) void {
        std.debug.assert(value <= runtime.records.len);
        runtime.max_manual = value;
    }

    pub fn setAuthorization(runtime: *Runtime, id: u64, value: Authorization) void {
        const index = runtime.findIndex(id) orelse unreachable;
        runtime.records[index].?.authorization = value;
    }

    pub fn makeAutomatic(runtime: *Runtime, id: u64, task_id: u64) void {
        const index = runtime.findIndex(id) orelse unreachable;
        const record = &runtime.records[index].?;
        record.kind = .automatic;
        record.automatic_task_id = task_id;
        record.visible = false;
        record.recent_order = 0;
    }

    pub fn overwriteProjectedRoot(runtime: *Runtime, id: u64, value: []const u8) void {
        const index = runtime.findIndex(id) orelse unreachable;
        const record = &runtime.records[index].?;
        std.debug.assert(value.len <= record.projected_root_storage.len);
        @memcpy(record.projected_root_storage[0..value.len], value);
        record.projected_root_len = value.len;
        record.projection_redacted = false;
    }

    pub fn projectedRoot(runtime: *const Runtime, id: u64) struct {
        value: []const u8,
        redacted: bool,
    } {
        const index = runtime.findIndex(id) orelse unreachable;
        const record = &runtime.records[index].?;
        return .{
            .value = record.projected_root_storage[0..record.projected_root_len],
            .redacted = record.projection_redacted,
        };
    }
} else struct {};

fn testStorageCopy(_: *anyopaque, value: []const u8, max: usize) StorageError![]u8 {
    if (value.len > max) return error.ProjectionCapacity;
    return std.testing.allocator.dupe(u8, value);
}

fn testStorageProject(
    _: *anyopaque,
    value: []const u8,
    max: usize,
    _: []const u8,
) StorageError!ProjectedText {
    if (value.len > max) return error.ProjectionCapacity;
    return .{
        .value = try std.testing.allocator.dupe(u8, value),
        .redacted = false,
    };
}

fn testStorageFree(_: *anyopaque, value: []u8) void {
    std.testing.allocator.free(value);
}

fn testStorageRedact(_: *anyopaque, _: []u8, _: *usize, _: []const u8) bool {
    return false;
}

test "automatic Workspace preparation owns capacity and settles its private allocation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var canonical_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const canonical_len = try tmp.dir.realPath(std.testing.io, &canonical_storage);
    var root = try AutomaticRoot.open(
        std.testing.io,
        std.testing.allocator,
        canonical_storage[0..canonical_len],
    );
    defer root.deinit();
    var context: u8 = 0;
    const storage: Storage = .{
        .context = &context,
        .copy_fn = testStorageCopy,
        .project_fn = testStorageProject,
        .free_fn = testStorageFree,
        .redact_fn = testStorageRedact,
    };
    var runtime = try Runtime.init(
        std.testing.allocator,
        std.testing.io,
        0,
        1,
        std.Io.Dir.max_path_bytes,
        &root,
    );
    defer runtime.deinit(storage);

    var rolled_back = try runtime.prepareAutomatic("", storage);
    const rolled_back_facts = runtime.preparedAutomaticFacts(&rolled_back);
    const rolled_back_key = try std.testing.allocator.dupe(
        u8,
        std.fs.path.basename(rolled_back_facts.canonical_root),
    );
    defer std.testing.allocator.free(rolled_back_key);
    try std.testing.expect(!runtime.automaticCapacityAvailable());
    try std.testing.expectError(
        error.WorkspaceCapacity,
        runtime.prepareAutomatic("", storage),
    );
    try std.testing.expect(runtime.rollbackPreparedAutomatic(&rolled_back, storage));
    try std.testing.expect(runtime.automaticCapacityAvailable());
    try std.testing.expectError(
        error.FileNotFound,
        runtime.automatic_allocator.?.root.dir.openDir(
            std.testing.io,
            rolled_back_key,
            .{},
        ),
    );

    var abandoned = try runtime.prepareAutomatic("", storage);
    const abandoned_facts = runtime.preparedAutomaticFacts(&abandoned);
    const abandoned_key = try std.testing.allocator.dupe(
        u8,
        std.fs.path.basename(abandoned_facts.canonical_root),
    );
    defer std.testing.allocator.free(abandoned_key);
    runtime.abandonPreparedAutomatic(&abandoned, storage);
    const abandoned_dir = try runtime.automatic_allocator.?.root.dir.openDir(
        std.testing.io,
        abandoned_key,
        .{},
    );
    abandoned_dir.close(std.testing.io);

    var completed = try runtime.prepareAutomatic("", storage);
    const completed_id = completed.id();
    runtime.completeAutomatic(&completed);
    try std.testing.expect(!runtime.automaticCapacityAvailable());
    runtime.releaseAutomatic(completed_id, storage);
    try std.testing.expect(runtime.automaticCapacityAvailable());
}

test "typed authorities invalidate stale Workspace consumers" {
    var context: u8 = 0;
    const storage: Storage = .{
        .context = &context,
        .copy_fn = testStorageCopy,
        .project_fn = testStorageProject,
        .free_fn = testStorageFree,
        .redact_fn = testStorageRedact,
    };
    var runtime = try Runtime.init(
        std.testing.allocator,
        std.testing.io,
        1,
        1,
        1024,
        null,
    );
    defer runtime.deinit(storage);
    testing.installOwned(&runtime, 0, .{
        .id = 1,
        .canonical_root = try storage.copy("/workspace", 1024),
        .projected_root_storage = try storage.copy("/workspace", 1024),
        .projected_root_len = "/workspace".len,
        .display_name_storage = try storage.copy("workspace", 1024),
        .display_name_len = "workspace".len,
        .recent_order = 1,
    });
    testing.installOwned(&runtime, 1, .{
        .id = 2,
        .kind = .automatic,
        .automatic_task_id = 7,
        .canonical_root = try storage.copy("/automatic", 1024),
        .projected_root_storage = try storage.copy("/automatic", 1024),
        .projected_root_len = "/automatic".len,
        .display_name_storage = try storage.copy("automatic", 1024),
        .display_name_len = "automatic".len,
        .visible = false,
        .recent_order = 0,
    });

    try std.testing.expect(runtime.filePreviewAuthorized(1, 1, "/workspace"));
    try std.testing.expect(!runtime.filePreviewAuthorized(1, 2, "/workspace"));
    try std.testing.expectError(
        error.WorkspaceEpochMismatch,
        runtime.taskCreateAuthority(1, 2, false),
    );
    const exact = runtime.recoveryAuthority(1, 1, "/workspace", 9);
    try std.testing.expect(exact.identity_exact and exact.automatic_owner_exact);
    try std.testing.expect(runtime.recoveryAuthority(2, 1, null, 7).automatic_owner_exact);
    try std.testing.expect(!runtime.recoveryAuthority(2, 1, null, 8).automatic_owner_exact);

    testing.setAuthorization(&runtime, 1, .removing);
    try std.testing.expect(!runtime.filePreviewAuthorized(1, 1, "/workspace"));
    try std.testing.expectError(
        error.WorkspaceRemovalInProgress,
        runtime.taskRunAuthority(1, 1),
    );
}
