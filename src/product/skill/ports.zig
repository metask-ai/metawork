//! Narrow effect ports consumed by the live Product Skill owner.
//! These callbacks grant no Workbench, Executor, or Agent Runtime identity.

const agent = @import("metawork_agent");
const std = @import("std");
const sources = @import("product_skill_sources");

/// Bounded filesystem observation, independently injectable from Core queries.
pub const SourceRoots = struct {
    context: ?*anyopaque = null,
    discover_fn: *const fn (?*anyopaque, std.Io, std.mem.Allocator, []const u8, ?[]const u8, sources.Selection) anyerror!sources.Discovery = discover,

    fn discover(_: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, home: []const u8, workspace: ?[]const u8, selection: sources.Selection) anyerror!sources.Discovery {
        return sources.discover(io, allocator, home, workspace, selection);
    }
};

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
    query_fn: *const fn (*anyopaque, agent.CatalogQuery) anyerror!agent.CatalogAcquisition,
    release_fn: *const fn (*anyopaque, *agent.CatalogLease) void,

    pub fn query(self: Catalog, input: agent.CatalogQuery) anyerror!agent.CatalogAcquisition {
        return self.query_fn(self.context, input);
    }

    pub fn release(self: Catalog, lease: *agent.CatalogLease) void {
        self.release_fn(self.context, lease);
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
    notifier: Notifier,
    source_roots: SourceRoots = .{},
};
