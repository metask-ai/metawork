//! Prepare only the Task headers affected by one verified external task.
//! Owned replacements can wait for an uncertain commit without changing
//! what the workbench shows for existing sessions.
const std = @import("std");
const task = @import("metawork_product_task");

pub const Action = enum { observe, link, prefer, unlink };

pub const Plan = struct {
    ids: std.ArrayList(u64) = .empty,
    links: std.ArrayList(?task.HandoffLink) = .empty,

    pub fn deinit(self: *Plan, a: std.mem.Allocator) void {
        for (self.links.items) |link| if (link) |owned| owned.deinit(a);
        self.links.deinit(a);
        self.ids.deinit(a);
    }

    fn replace(self: *Plan, a: std.mem.Allocator, id: u64, next: ?task.HandoffLink) !void {
        const owned = if (next) |link| try link.clone(a) else null;
        errdefer if (owned) |link| link.deinit(a);
        try self.ids.append(a, id);
        try self.links.append(a, owned);
    }

    pub fn apply(self: *Plan, runtime: *task.Runtime) void {
        for (self.ids.items, self.links.items) |id, *link| {
            runtime.adoptHandoff(id, link.*);
            link.* = null;
        }
    }

    pub fn project(self: *const Plan, records: []task.history.TaskWire) void {
        for (self.ids.items, self.links.items) |id, link| {
            for (records) |*record| {
                if (record.id != id) continue;
                record.handoff = link;
                break;
            }
        }
    }
};

fn appendId(a: std.mem.Allocator, ids: *std.ArrayList([]const u8), id: []const u8) !void {
    for (ids.items) |seen| if (std.mem.eql(u8, seen, id)) return;
    if (ids.items.len >= 256) return error.ProjectionCapacity;
    try ids.append(a, id);
}

pub fn prepare(runtime: *task.Runtime, a: std.mem.Allocator, account: []const u8, requested: []const u8, current: []const u8, action: Action, target: ?u64) !Plan {
    var plan: Plan = .{};
    errdefer plan.deinit(a);
    const existing = try runtime.linkedTasks(a, account, requested, current);
    defer a.free(existing);
    const existingTarget = for (existing) |item| {
        if (item.task_id == target) break true;
    } else false;
    if (target) |id| {
        const previous = try runtime.checkHandoffTarget(id, action == .unlink);
        if (!existingTarget and (action != .link or previous != null)) return error.HandoffConflict;
    } else if (action != .observe) return error.HandoffConflict;

    var ids: std.ArrayList([]const u8) = .empty;
    defer ids.deinit(a);
    try appendId(a, &ids, current);
    try appendId(a, &ids, requested);
    var defaults: usize = 0;
    for (existing) |item| {
        for (item.link.ids) |id| try appendId(a, &ids, id);
        if (item.link.preferred) defaults += 1;
    }
    for (existing) |item| {
        if (action == .unlink and item.task_id == target) {
            try plan.replace(a, item.task_id, null);
            continue;
        }
        const preferred = if (action == .prefer) item.task_id == target else defaults == 1 and item.link.preferred;
        if (item.link.preferred == preferred and item.link.ids.len == ids.items.len and std.mem.eql(u8, item.link.ids[0], current)) continue;
        _ = try runtime.checkHandoffTarget(item.task_id, true);
        try plan.replace(a, item.task_id, .{ .account = account, .ids = ids.items, .preferred = preferred });
    }
    if (action == .link and !existingTarget) {
        try plan.replace(a, target.?, .{ .account = account, .ids = ids.items, .preferred = existing.len == 0 });
    }
    return plan;
}

pub fn receipt(account: []const u8, operation: []const u8) [32]u8 {
    var digest = std.crypto.hash.sha2.Sha256.init(.{});
    digest.update(account);
    digest.update(operation);
    return digest.finalResult();
}
