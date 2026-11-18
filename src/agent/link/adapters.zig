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
const surface = contract.surface;
const shapes = @import("shapes.zig");
const catalog = @import("agent_catalog");
const mcp_catalog = @import("agent_mcp_catalog");
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
    /// Captured skill capabilities. A separate table from the leases because
    /// they are separate objects with separate lifetimes: one is borrowed
    /// from the other by its own registered method.
    skill_restore: *handle_table.Table(port.SkillRestoreInputs),
    /// Captured Session restore inputs.
    session_restore: *handle_table.Table(port.SessionRestoreInputs),
    /// MCP selections. The methods that *create* one belong to the MCP step;
    /// this table exists because an options struct can name one, and a
    /// Session cannot be opened without reading that field.
    selections: *handle_table.Table(mcp_catalog.Selection),
};

pub const ResolveError = error{
    /// The id named nothing: never issued, already taken back, or issued for
    /// an earlier occupant of its slot. A protocol violation rather than a
    /// call on whatever is there now.
    UnknownHandle,
};

/// One parameter type's rebuild, with its signature nailed to the type.
///
/// `apply` is declared here rather than in each entry, so every entry is
/// checked against `Wire(T)` as it is written. That is not decoration: the
/// first version of this file had an adapter taking `?handle_table.Id` for a
/// type whose wire form is a bare id, which would have decoded one field
/// short and blamed the payload.
pub fn Adapter(comptime T: type) type {
    return struct {
        apply: *const fn (Bindings, wire_types.Wire(T)) ResolveError!T,
    };
}

/// How one parameter type is rebuilt, or `null` when nothing rebuilds it yet.
pub fn parameterAdapter(comptime T: type) ?Adapter(T) {
    // Plain data is itself. No adapter, nothing to own, nothing to decide:
    // `Wire(T) == T` is the statement that the value crossed unchanged.
    if (wire_types.Wire(T) == T) return .{ .apply = struct {
        fn apply(_: Bindings, value: T) ResolveError!T {
            return value;
        }
    }.apply };

    // The caller's allocator does not cross; the execution half calls with
    // its own. `Wire` maps it to `void`, so there is no wire value at all.
    if (T == std.mem.Allocator) return .{ .apply = struct {
        fn apply(bindings: Bindings, _: void) ResolveError!T {
            return bindings.allocator;
        }
    }.apply };

    // A Session named by id. The table is generation-bearing, so a stale id
    // resolves to nothing rather than to the slot's next occupant.
    if (T == port.SessionPort) return .{ .apply = struct {
        fn apply(bindings: Bindings, id: handle_table.Id) ResolveError!T {
            const held = bindings.sessions.resolve(id) orelse return error.UnknownHandle;
            return held.*;
        }
    }.apply };

    // A skill catalog lease, borrowed for the call and released by its own
    // registered method, never by the dispatcher.
    if (T == *catalog.Lease) return .{ .apply = struct {
        fn apply(bindings: Bindings, id: handle_table.Id) ResolveError!T {
            return bindings.leases.resolve(id) orelse error.UnknownHandle;
        }
    }.apply };
    // An optional handle crosses as a bare id, because a zero id is already
    // invalid by construction. An `?Id` would be a second way to say absent,
    // and the one thing worse than no rule is two.
    if (T == ?*catalog.Lease) return .{ .apply = struct {
        fn apply(bindings: Bindings, id: handle_table.Id) ResolveError!T {
            if (!id.valid()) return null;
            return bindings.leases.resolve(id) orelse error.UnknownHandle;
        }
    }.apply };
    if (T == ?*const mcp_catalog.Selection) return .{ .apply = struct {
        fn apply(bindings: Bindings, id: handle_table.Id) ResolveError!T {
            if (!id.valid()) return null;
            return bindings.selections.resolve(id) orelse error.UnknownHandle;
        }
    }.apply };

    // Captured capabilities, named by id for exactly as long as the other
    // half holds one.
    //
    // Resolving borrows and never takes, including for the release methods.
    // A release that fails must leave its handle resolvable -- the object is
    // still there and the caller may ask again -- so retiring the entry
    // belongs to the dispatcher, after the call returns without error. An
    // adapter that took the entry up front would turn a refused release into
    // a leak with no name left to refer to it by.
    if (T == *port.SkillRestoreInputs) return .{ .apply = struct {
        fn apply(bindings: Bindings, id: handle_table.Id) ResolveError!T {
            return bindings.skill_restore.resolve(id) orelse error.UnknownHandle;
        }
    }.apply };
    if (T == *const port.SkillRestoreInputs) return .{ .apply = struct {
        fn apply(bindings: Bindings, id: handle_table.Id) ResolveError!T {
            return bindings.skill_restore.resolve(id) orelse error.UnknownHandle;
        }
    }.apply };
    if (T == *port.SessionRestoreInputs) return .{ .apply = struct {
        fn apply(bindings: Bindings, id: handle_table.Id) ResolveError!T {
            return bindings.session_restore.resolve(id) orelse error.UnknownHandle;
        }
    }.apply };

    // Mirrors, read back field by field rather than by hand. A field whose
    // mirror type differs goes through this same chain, so a handle inside an
    // options struct is resolved by the entry above rather than by a second
    // copy of it.
    if (T == surface.SessionOpenOptions) return mirrorAdapter(T, shapes.SessionOpenOptions);
    if (T == catalog.Query) return mirrorAdapter(T, shapes.CatalogQuery);

    // Everything else is owed. The list of what that is comes from
    // `owedMethods` rather than from a sentence here.
    return null;
}

/// A mirror read back into the port type it mirrors.
///
/// Field by field rather than by hand, because a hand-written copy of twelve
/// fields is a second place for the shape to drift -- and `shapes.mirrors`
/// only checks that a mirror field still names something, not that anyone
/// copied it.
///
/// Three cases, and each is a rule rather than a convenience:
///
/// - The types match: the value crossed unchanged, so it is copied.
/// - They differ: the port field's own adapter is applied, which is how a
///   handle inside an options struct is resolved by the handle entry above
///   instead of by a second copy of it. The mirror's field type must then be
///   that port type's wire form, or the build says both, because two
///   encodings of one field is how a decoder reads the wrong bytes.
/// - The mirror has no such field: the wire dropped it, so the port field
///   must have a default and that default is what the execution half passes.
///   `catalog.Query.source_lifetime` is the one that matters -- its contract
///   requires nonblocking reference accounting, which a cross-process call
///   cannot provide, so it does not cross at all. Its default is `null`, and
///   the caller retaining before the call is what replaces it.
fn mirrorAdapter(comptime T: type, comptime Mirror: type) Adapter(T) {
    if (wire_types.Wire(T) != Mirror) @compileError(
        "the mirror for " ++ @typeName(T) ++ " is not its wire form",
    );
    return .{
        .apply = struct {
            fn apply(bindings: Bindings, value: Mirror) ResolveError!T {
                var out: T = undefined;
                inline for (@typeInfo(T).@"struct".fields) |field| {
                    if (!@hasField(Mirror, field.name)) {
                        const default = field.defaultValue() orelse @compileError(
                            @typeName(T) ++ "." ++ field.name ++ " does not cross and has " ++
                                "no default, so nothing says what the execution half " ++
                                "should pass for it",
                        );
                        @field(out, field.name) = default;
                        continue;
                    }
                    const Mirrored = @FieldType(Mirror, field.name);
                    if (Mirrored == field.type) {
                        @field(out, field.name) = @field(value, field.name);
                        continue;
                    }
                    // Forced comptime: the `orelse` arm is a compile error, and
                    // an arm like that is analysed unless the condition is
                    // already known.
                    const nested = comptime parameterAdapter(field.type) orelse @compileError(
                        @typeName(T) ++ "." ++ field.name ++ " is reshaped as " ++
                            @typeName(Mirrored) ++ " and nothing rebuilds " ++
                            @typeName(field.type) ++ " from it",
                    );
                    if (Mirrored != wire_types.Wire(field.type)) @compileError(
                        @typeName(Mirror) ++ "." ++ field.name ++ " is " ++ @typeName(Mirrored) ++
                            " but " ++ @typeName(field.type) ++ " crosses as " ++
                            @typeName(wire_types.Wire(field.type)) ++
                            "; one field cannot have two encodings",
                    );
                    @field(out, field.name) = try nested.apply(bindings, @field(value, field.name));
                }
                return out;
            }
        }.apply,
    };
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
    /// Which half performs the effect behind this parameter. Decided here so
    /// the dispatcher inherits it instead of deciding again, one call at a
    /// time, with a reason that sounded fine at the time.
    disposition: Disposition,
};

/// Why a parameter is still owed, which is never "nobody got to it yet".
pub const Disposition = enum {
    /// The execution half performs the effect. The dispatcher builds the
    /// capability from the descriptor when it invokes the method, and nothing
    /// may keep its backing object past the call -- a per-call allocation the
    /// far side still points at is a cross-process use-after-free, the worst
    /// failure available here. That has to be checked where the dispatcher
    /// is, not promised here.
    execution_side_effect,
    /// The caller performs the effect, so it is a reverse call and lives in
    /// `reverse.zig` under its rules.
    reverse_call,
    /// Deferred to the MCP step with the rest of the MCP handle surface.
    mcp_step,
};

/// The disposition of each parameter type still owed, closed both ways: a type
/// the chain cannot rebuild must appear here, and a type that gains an adapter
/// must leave. A list that outlives its reason teaches the wrong rule.
const dispositions = [_]struct { name: []const u8, disposition: Disposition }{
    .{ .name = @typeName(checkpoint.Sink), .disposition = .execution_side_effect },
    .{
        .name = @typeName(surface.SessionRestoreOptions),
        .disposition = .execution_side_effect,
    },
    .{
        .name = @typeName(?surface.ImageGenerationRunInput),
        .disposition = .execution_side_effect,
    },
    .{ .name = @typeName(?contract.FileDeliveryInput), .disposition = .reverse_call },
    .{ .name = @typeName(?contract.McpInstallationInput), .disposition = .reverse_call },
    .{ .name = @typeName(?contract.VideoGenerationRunInput), .disposition = .execution_side_effect },
    .{ .name = @typeName(*const mcp_catalog.Activation), .disposition = .mcp_step },
    .{ .name = @typeName(*const mcp_catalog.RestoreSelection), .disposition = .mcp_step },
};

fn dispositionOf(comptime name: []const u8) ?Disposition {
    comptime {
        for (dispositions) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.disposition;
        }
        return null;
    }
}

/// Every parameter still owed an adapter, one entry each, in registry order.
///
/// Per parameter rather than per method, because the work is a type and
/// because a method can be blocked by more than one: `prepare_run_with_tools`
/// takes four capabilities and they do not all belong to the same half.
/// Reporting only the first would have hidden the one that turned out to be
/// the caller's.
pub fn owedParameters() []const Owed {
    comptime {
        @setEvalBranchQuota(1_000_000);
        var list: []const Owed = &.{};
        for (method.entries) |entry| {
            if (entry.transport == .stream) continue;
            const blocked = switch (entry.owner) {
                inline else => |owner| blocking(owner, entry.name),
            };
            for (blocked) |parameter| list = list ++ [_]Owed{.{
                .owner = entry.owner,
                .name = entry.name,
                .parameter = parameter,
                .disposition = dispositionOf(parameter) orelse @compileError(
                    "nothing says which half performs the effect behind " ++ parameter ++
                        ", which blocks " ++ entry.name ++ ". Add it to `dispositions` in " ++
                        "src/agent/link/adapters.zig, or give the type an adapter; a " ++
                        "parameter nobody has decided about is how a capability ends up " ++
                        "rebuilt on the wrong side of the link",
                ),
            }};
        }
        return list;
    }
}

/// Methods with at least one parameter still owed.
pub fn blockedMethodCount() usize {
    comptime {
        @setEvalBranchQuota(1_000_000);
        var count: usize = 0;
        for (method.entries) |entry| {
            if (entry.transport == .stream) continue;
            const blocked = switch (entry.owner) {
                inline else => |owner| blocking(owner, entry.name),
            };
            if (blocked.len != 0) count += 1;
        }
        return count;
    }
}

fn blocking(comptime owner: method.Owner, comptime name: []const u8) []const []const u8 {
    comptime {
        const Fn = @typeInfo(@FieldType(owner.VTable(), name)).pointer.child;
        var list: []const []const u8 = &.{};
        for (@typeInfo(Fn).@"fn".params, 0..) |param, position| {
            if (position == 0) continue;
            if (parameterAdapter(param.type.?) == null)
                list = list ++ [_][]const u8{@typeName(param.type.?)};
        }
        return list;
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
            if (blocked.len == 0) count += 1;
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

    const resolver = parameterAdapter([]const u8).?;
    const bindings = testBindings();
    try testing.expectEqualStrings("model", try resolver.apply(bindings, "model"));
}

test "an allocator is supplied locally rather than carried" {
    const resolver = parameterAdapter(std.mem.Allocator).?;
    const bindings = testBindings();
    // The wire value is `void`: there is nothing to send, and the execution
    // half answers with its own allocator.
    const resolved = try resolver.apply(bindings, {});
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
    var skill_restore = try handle_table.Table(port.SkillRestoreInputs).init(testing.allocator, 1);
    defer skill_restore.deinit();
    var session_restore = try handle_table.Table(port.SessionRestoreInputs).init(testing.allocator, 1);
    defer session_restore.deinit();
    var selections = try handle_table.Table(mcp_catalog.Selection).init(testing.allocator, 1);
    defer selections.deinit();

    var first: port.SessionPort = .{ .context = null, .vtable = undefined };
    var second: port.SessionPort = .{ .context = null, .vtable = undefined };
    const bindings: Bindings = .{
        .allocator = testing.allocator,
        .sessions = &sessions,
        .runs = &runs,
        .leases = &leases,
        .skill_restore = &skill_restore,
        .session_restore = &session_restore,
        .selections = &selections,
    };

    const resolver = parameterAdapter(port.SessionPort).?;
    const stale = try sessions.insert(&first);
    _ = try resolver.apply(bindings, stale);
    _ = sessions.take(stale);

    const fresh = try sessions.insert(&second);
    try testing.expect(fresh.bits() != stale.bits());
    _ = try resolver.apply(bindings, fresh);
    try testing.expectError(error.UnknownHandle, resolver.apply(bindings, stale));
    try testing.expectError(error.UnknownHandle, resolver.apply(bindings, .none));
    _ = sessions.take(fresh);
}

test "the worklist is what the step still owes, counted by the compiler" {
    const owed = comptime owedParameters();
    const rebuildable = comptime rebuildableCount();
    const blocked = comptime blockedMethodCount();
    const callable = comptime callableCount();

    // Every call either has its arguments or is blocked, with no third state
    // and none counted twice. The parameter list is longer than the blocked
    // count, which is the point of counting both: one method is blocked by
    // three separate capabilities.
    try testing.expectEqual(callable, rebuildable + blocked);
    try testing.expect(owed.len >= blocked);

    // The numbers, so that a method moving between them is visible here
    // rather than only in a build that happened to succeed. They are a
    // worklist, not an invariant: the end state is `owed.len == 0`.
    try testing.expectEqual(@as(usize, 50), callable);
    try testing.expectEqual(@as(usize, 45), rebuildable);
    try testing.expectEqual(@as(usize, 5), blocked);
    try testing.expectEqual(@as(usize, 9), owed.len);

    // Named one by one, because this is the work and a count is not a
    // worklist. Two belong to the MCP step and three rebuild a capability
    // from its descriptor -- `restore_session_route` among them, because its
    // options carry a checkpoint source, which makes it a capability case
    // rather than the mirror case it looked like from the method list.
    const expected = [_][]const u8{
        "restore_session_route",
        "create_mcp_admission_selection",
        "prepare_mcp_restore_selection",
        "prepare_mcp_restore_selection",
        "prepare_run_with_tools",
        "prepare_run_with_tools",
        "prepare_run_with_tools",
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

    // And each is owed for a decided reason. Two are the caller's effects and
    // live in `reverse.zig`; the rest are this half's own, where the question
    // is not where to put a capability but that nothing keeps its backing
    // object past the call.
    var reverse: usize = 0;
    var ours: usize = 0;
    var mcp: usize = 0;
    for (owed) |entry| switch (entry.disposition) {
        .reverse_call => reverse += 1,
        .execution_side_effect => ours += 1,
        .mcp_step => mcp += 1,
    };
    // The delivery inspection and the MCP installation are the caller's; the
    // checkpoint pair and the image and video bindings are this half's.
    try testing.expectEqual(@as(usize, 2), reverse);
    try testing.expectEqual(@as(usize, 4), ours);
    try testing.expectEqual(@as(usize, 3), mcp);
}

test "a type absent from the chain is owed, not assumed trivial" {
    // The property the worklist rests on. A chain that fell through to the
    // identity would hand a method a borrowed pointer rebuilt from nothing,
    // which is the one outcome worse than not compiling.
    try testing.expect(parameterAdapter(checkpoint.Sink) == null);
    try testing.expect(parameterAdapter(surface.SessionRestoreOptions) == null);
    // And the sentinel this file would otherwise never prove: the count moved
    // when an adapter was written. `port.SessionPort` has one, so the Session
    // release that takes one is rebuildable; the restore-inputs releases, which
    // take a handle with no table yet, are not.
    try testing.expect(comptime argumentsRebuildable(.runtime, "release_closed_session"));
    try testing.expect(comptime argumentsRebuildable(.runtime, "release_restore_inputs"));
    try testing.expect(comptime argumentsRebuildable(.runtime, "create_session_route"));
    // Still owed, and not for want of a table: a checkpoint source is a
    // capability the execution half has to perform, not a value it can hold.
    try testing.expect(comptime !argumentsRebuildable(.runtime, "restore_session_route"));
}

fn testBindings() Bindings {
    return .{
        .allocator = testing.allocator,
        .sessions = undefined,
        .runs = undefined,
        .leases = undefined,
        .skill_restore = undefined,
        .session_restore = undefined,
        .selections = undefined,
    };
}

test "an options mirror is read back with its handle resolved and its absence kept" {
    var sessions = try handle_table.Table(port.SessionPort).init(testing.allocator, 1);
    defer sessions.deinit();
    var runs = try handle_table.Table(port.RunPort).init(testing.allocator, 1);
    defer runs.deinit();
    var leases = try handle_table.Table(catalog.Lease).init(testing.allocator, 2);
    defer leases.deinit();
    var skill_restore = try handle_table.Table(port.SkillRestoreInputs).init(testing.allocator, 1);
    defer skill_restore.deinit();
    var session_restore = try handle_table.Table(port.SessionRestoreInputs).init(testing.allocator, 1);
    defer session_restore.deinit();
    var selections = try handle_table.Table(mcp_catalog.Selection).init(testing.allocator, 1);
    defer selections.deinit();
    const bindings: Bindings = .{
        .allocator = testing.allocator,
        .sessions = &sessions,
        .runs = &runs,
        .leases = &leases,
        .skill_restore = &skill_restore,
        .session_restore = &session_restore,
        .selections = &selections,
    };

    var lease_storage: [8]u8 align(8) = @splat(0);
    const lease: *catalog.Lease = @ptrCast(&lease_storage);
    const lease_id = try leases.insert(lease);

    const mirror: shapes.SessionOpenOptions = .{
        .model_binding = .{
            .image_capabilities = &.{},
            .target = .{
                .provider_id = "provider",
                .protocol = .anthropic_messages,
                .base_url = "https://example.invalid",
                .model = "model",
            },
            .credential = "secret",
        },
        .permission_mode = .default,
        .shell_policy = .unrestricted,
        .permission_interaction = .interactive,
        .workspace = .{ .canonical_root = "root", .trust = .explicitly_trusted },
        .canonical_user_home = "home",
        .workspace_epoch = "epoch",
        .skill_catalog = lease_id,
        .skill_policy = null,
        // The absence this encoding has exactly one spelling for.
        .mcp_selection = .none,
        .operation_id_floor = .{},
    };

    const resolver = parameterAdapter(surface.SessionOpenOptions).?;
    const options = try resolver.apply(bindings, mirror);

    // The handle found its object, through the same entry a bare lease
    // parameter uses rather than a second copy of it.
    try testing.expectEqual(lease, options.skill_catalog.?);
    try testing.expect(options.mcp_selection == null);
    // And the plain fields came across as themselves, borrowed from the
    // request for the length of the call, which is all the Session needs:
    // the implementation dupes everything it keeps.
    try testing.expectEqualStrings("epoch", options.workspace_epoch);
    try testing.expectEqualStrings("home", options.canonical_user_home);
    try testing.expectEqualStrings("model", options.model_binding.target.model);
    try testing.expectEqual(surface.PermissionInteraction.interactive, options.permission_interaction);

    // A retired id is refused, so a Session cannot be opened against a
    // catalog lease the other half no longer holds.
    _ = leases.take(lease_id);
    try testing.expectError(error.UnknownHandle, resolver.apply(bindings, mirror));
}

test "a field the wire drops arrives as its default, and the default is the decision" {
    const bindings = testBindings();
    const resolver = parameterAdapter(catalog.Query).?;
    const query = try resolver.apply(bindings, .{
        .canonical_user_home = "home",
        .target = .management,
        .additional_sources = &.{},
        .default_source_priority = 3,
    });

    try testing.expectEqualStrings("home", query.canonical_user_home);
    try testing.expectEqual(@as(i32, 3), query.default_source_priority);
    // `source_lifetime` is not on the mirror at all: its contract requires
    // nonblocking reference accounting and a cross-process call blocks, so it
    // cannot cross. `null` is its default, and the caller retaining before
    // the call is what replaces it.
    try testing.expect(query.source_lifetime == null);
}
