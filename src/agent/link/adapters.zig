//! Turning a wire value back into the port value a method is called with.
//!
//! `wire_types.Wire` is the other direction and it is already checked: every
//! registered method's payload can be carried. That check says nothing about
//! whether the execution half can reconstruct the argument it has to pass, and
//! the two are not symmetric. An id has to find its object in a table. A
//! descriptor has to become a capability the far side performs itself. A
//! mirror has to be read back field by field, into memory that lives at least
//! as long as the call. Each of those is a decision about ownership, and none
//! of them follows from the shape alone.
//!
//! So this file is the worklist for the rest of the move, and the worklist is
//! derived rather than kept. There is one chain -- `parameterAdapter` -- and a
//! type it does not answer for is a type whose argument cannot yet be
//! rebuilt; `owedMethods` reads that back out per method. A separate list of
//! what is left would be a second place to forget something, which is how
//! "about fifty-nine" became sixty-eight once before.
//!
//! What the chain deliberately does not do is guess. A type that is not
//! listed is owed, not assumed trivial: an adapter that silently did the
//! wrong thing with a borrowed pointer is exactly the failure this whole
//! change exists to make impossible.

const std = @import("std");
const contract = @import("agent_contract");
const handle_table = @import("handle_table.zig");
const method = @import("method.zig");
const wire_types = @import("wire_types.zig");

const port = contract.port;
const catalog = @import("agent_catalog");
const checkpoint = @import("agent_checkpoint");

/// The execution half's own state, which is what makes an argument whole
/// again. A wire value plus these is a port value; a wire value alone is not.
pub const Bindings = struct {
    /// The execution half's allocator. A caller's allocator never crosses, so
    /// a method that takes one is called with this instead -- the response is
    /// encoded before the call returns, so nothing allocated here outlives
    /// the dispatch.
    allocator: std.mem.Allocator,
    /// Sessions this half holds for the other half to name.
    sessions: *handle_table.Table(port.SessionPort),
    /// Runs, which also answer their control handle: in process both are the
    /// Session's control block, so `envelope.Receiver.run` names one entry.
    runs: *handle_table.Table(port.RunPort),
    /// Skill catalog leases.
    leases: *handle_table.Table(catalog.Lease),
};

pub const ResolveError = error{
    /// The id named nothing: never issued, already taken back, or issued for
    /// an earlier occupant of its slot. A protocol violation rather than a
    /// call on whatever is there now.
    UnknownHandle,
};

/// How one parameter type is rebuilt, or `null` when nothing rebuilds it yet.
///
/// The returned type carries `apply`, so a dispatcher never sees the shape of
/// an adapter -- only that one exists.
pub fn parameterAdapter(comptime T: type) ?type {
    // Plain data is itself. No adapter, nothing to own, nothing to decide:
    // `Wire(T) == T` is the statement that the value crossed unchanged.
    if (wire_types.Wire(T) == T) return struct {
        pub fn apply(_: Bindings, value: T) ResolveError!T {
            return value;
        }
    };

    // The caller's allocator does not cross; the execution half calls with
    // its own. `Wire` maps it to `void`, so there is no wire value at all.
    if (T == std.mem.Allocator) return struct {
        pub fn apply(bindings: Bindings, _: void) ResolveError!T {
            return bindings.allocator;
        }
    };

    // A Session named by id. The table is generation-bearing, so a stale id
    // resolves to nothing rather than to the slot's next occupant.
    if (T == port.SessionPort) return struct {
        pub fn apply(bindings: Bindings, id: handle_table.Id) ResolveError!T {
            const held = bindings.sessions.resolve(id) orelse return error.UnknownHandle;
            return held.*;
        }
    };

    // A skill catalog lease, borrowed for the call and released by its own
    // registered method, never by the dispatcher.
    if (T == *catalog.Lease) return struct {
        pub fn apply(bindings: Bindings, id: handle_table.Id) ResolveError!T {
            return bindings.leases.resolve(id) orelse error.UnknownHandle;
        }
    };
    if (T == ?*catalog.Lease) return struct {
        pub fn apply(bindings: Bindings, id: ?handle_table.Id) ResolveError!T {
            const value = id orelse return null;
            return bindings.leases.resolve(value) orelse error.UnknownHandle;
        }
    };

    // Everything else is owed. The list of what that is comes from
    // `owedMethods` rather than from a sentence here.
    return null;
}

/// Whether every argument of one method can be rebuilt.
///
/// The return value is deliberately not part of this question. A result
/// travels the other way and its mirrors live in `shapes.zig`, which already
/// owns that direction; mixing the two would make one answer stand for two
/// unrelated pieces of work.
pub fn argumentsRebuildable(comptime owner: method.Owner, comptime name: []const u8) bool {
    comptime {
        const Fn = @typeInfo(@FieldType(owner.VTable(), name)).pointer.child;
        for (@typeInfo(Fn).@"fn".params, 0..) |param, position| {
            if (position == 0) continue; // the context pointer, now the receiver id
            if (parameterAdapter(param.type.?) == null) return false;
        }
        return true;
    }
}

/// One method whose arguments cannot all be rebuilt yet, and the first
/// parameter type that is why.
pub const Owed = struct {
    owner: method.Owner,
    name: []const u8,
    parameter: []const u8,
};

/// Every method still owed an argument adapter, in registry order.
///
/// This is the forwarding step's remaining work, counted by the compiler. It
/// reaches empty when the execution half can rebuild every argument, which is
/// the only honest definition of the dispatcher being finished.
pub fn owedMethods() []const Owed {
    comptime {
        @setEvalBranchQuota(1_000_000);
        var list: []const Owed = &.{};
        for (method.entries) |entry| {
            if (entry.transport == .stream) continue;
            const blocked = switch (entry.owner) {
                inline else => |owner| blocking(owner, entry.name),
            };
            if (blocked) |parameter| list = list ++ [_]Owed{.{
                .owner = entry.owner,
                .name = entry.name,
                .parameter = parameter,
            }};
        }
        return list;
    }
}

fn blocking(comptime owner: method.Owner, comptime name: []const u8) ?[]const u8 {
    comptime {
        const Fn = @typeInfo(@FieldType(owner.VTable(), name)).pointer.child;
        for (@typeInfo(Fn).@"fn".params, 0..) |param, position| {
            if (position == 0) continue;
            if (parameterAdapter(param.type.?) == null) return @typeName(param.type.?);
        }
        return null;
    }
}

/// Methods a dispatcher can already answer, counted the same way.
pub fn rebuildableCount() usize {
    comptime {
        @setEvalBranchQuota(1_000_000);
        var count: usize = 0;
        for (method.entries) |entry| {
            if (entry.transport == .stream) continue;
            const blocked = switch (entry.owner) {
                inline else => |owner| blocking(owner, entry.name),
            };
            if (blocked == null) count += 1;
        }
        return count;
    }
}

pub fn callableCount() usize {
    comptime {
        var count: usize = 0;
        for (method.entries) |entry| {
            if (entry.transport != .stream) count += 1;
        }
        return count;
    }
}

const testing = std.testing;

test "plain data needs no adapter, and that is what Wire being the identity means" {
    // The largest payloads cross unchanged, which is why the bulk of the
    // surface needs nothing written for it.
    const SetModel = @typeInfo(@FieldType(port.SessionPort.VTable, "set_model")).pointer.child;
    const params = @typeInfo(SetModel).@"fn".params;
    try testing.expectEqual([]const u8, params[1].type.?);
    try testing.expect(parameterAdapter([]const u8) != null);
    try testing.expect(parameterAdapter(u64) != null);

    const Adapter = parameterAdapter([]const u8).?;
    const bindings = testBindings();
    try testing.expectEqualStrings("model", try Adapter.apply(bindings, "model"));
}

test "an allocator is supplied locally rather than carried" {
    const Adapter = parameterAdapter(std.mem.Allocator).?;
    const bindings = testBindings();
    // The wire value is `void`: there is nothing to send, and the execution
    // half answers with its own allocator.
    const resolved = try Adapter.apply(bindings, {});
    try testing.expectEqual(bindings.allocator.ptr, resolved.ptr);
    try testing.expectEqual(void, wire_types.Wire(std.mem.Allocator));
}

test "a stale handle resolves to a refusal, never to the slot's next occupant" {
    var sessions = try handle_table.Table(port.SessionPort).init(testing.allocator, 1);
    defer sessions.deinit();
    var runs = try handle_table.Table(port.RunPort).init(testing.allocator, 1);
    defer runs.deinit();
    var leases = try handle_table.Table(catalog.Lease).init(testing.allocator, 1);
    defer leases.deinit();

    var first: port.SessionPort = .{ .context = null, .vtable = undefined };
    var second: port.SessionPort = .{ .context = null, .vtable = undefined };
    const bindings: Bindings = .{
        .allocator = testing.allocator,
        .sessions = &sessions,
        .runs = &runs,
        .leases = &leases,
    };

    const Adapter = parameterAdapter(port.SessionPort).?;
    const stale = try sessions.insert(&first);
    _ = try Adapter.apply(bindings, stale);
    _ = sessions.take(stale);

    const fresh = try sessions.insert(&second);
    try testing.expect(fresh.bits() != stale.bits());
    _ = try Adapter.apply(bindings, fresh);
    try testing.expectError(error.UnknownHandle, Adapter.apply(bindings, stale));
    try testing.expectError(error.UnknownHandle, Adapter.apply(bindings, .none));
    _ = sessions.take(fresh);
}

test "the worklist is what the step still owes, counted by the compiler" {
    const owed = comptime owedMethods();
    const rebuildable = comptime rebuildableCount();
    const callable = comptime callableCount();

    // Every call either has its arguments or appears in the list, with no
    // third state and no method counted twice.
    try testing.expectEqual(callable, rebuildable + owed.len);

    // The numbers, so that a method moving between them is visible here
    // rather than only in a build that happened to succeed. They are a
    // worklist, not an invariant: the end state is `owed.len == 0`.
    try testing.expectEqual(@as(usize, 50), callable);
    try testing.expectEqual(@as(usize, 38), rebuildable);
    try testing.expectEqual(@as(usize, 12), owed.len);

    // Named one by one, because this is the work and a count is not a
    // worklist. Five want a handle table they do not have yet, two belong
    // to the MCP step, three read a mirror back, and two rebuild a
    // capability from its descriptor.
    const expected = [_][]const u8{
        "create_session_route",
        "restore_session_route",
        "create_mcp_admission_selection",
        "prepare_mcp_restore_selection",
        "query_skill_catalog",
        "narrow_skill_restore_inputs",
        "clone_skill_restore_inputs",
        "borrow_skill_restore_inputs",
        "release_skill_restore_inputs",
        "release_restore_inputs",
        "prepare_run_with_tools",
        "export_checkpoint",
    };
    try testing.expectEqual(expected.len, owed.len);
    for (owed, expected) |entry, name| try testing.expectEqualStrings(name, entry.name);

    // Each entry names the parameter that blocks it, because "this method is
    // not done" is not a work item and "this type has no adapter" is.
    for (owed) |entry| {
        try testing.expect(entry.name.len > 0);
        try testing.expect(entry.parameter.len > 0);
    }
}

test "a type absent from the chain is owed, not assumed trivial" {
    // The property the worklist rests on. A chain that fell through to the
    // identity would hand a method a borrowed pointer rebuilt from nothing,
    // which is the one outcome worse than not compiling.
    try testing.expect(parameterAdapter(checkpoint.Sink) == null);
    try testing.expect(parameterAdapter(contract.surface.SessionOpenOptions) == null);
    // And the sentinel this file would otherwise never prove: the count moved
    // when an adapter was written. `port.SessionPort` has one, so the Session
    // release that takes one is rebuildable; the restore-inputs releases, which
    // take a handle with no table yet, are not.
    try testing.expect(comptime argumentsRebuildable(.runtime, "release_closed_session"));
    try testing.expect(comptime !argumentsRebuildable(.runtime, "release_restore_inputs"));
}

fn testBindings() Bindings {
    return .{
        .allocator = testing.allocator,
        .sessions = undefined,
        .runs = undefined,
        .leases = undefined,
    };
}
