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
const control = contract.control;
const call_frame = @import("call_frame.zig");
const run_tools = @import("run_tools.zig");
const shapes = @import("shapes.zig");
const catalog = @import("agent_catalog");
const mcp_catalog = @import("agent_mcp_catalog");
const checkpoint = @import("agent_checkpoint");

/// What the execution half keeps for one begun Run.
///
/// Deliberately not a `port.RunPort`. Of that type's six fields, the context
/// and the vtable *are* this half -- it does not need a port pointing at its
/// own implementation -- the Run's identity travels as ordinary arguments on
/// the calls that need it, and `executed` is the caller's bookkeeping about
/// the caller's own value: its stub holds that flag and asserts on it, and no
/// part of it crosses. If anything ever has to ask the other half whether a
/// Run was executed, that is a local invariant turned into a distributed one.
///
/// Holding the whole port would have been worse than redundant.
/// `RunPort.deinit` releases the base lease, and the caller's own `deinit`
/// already forwards a release of its own; running both decrements one
/// reference twice, and `SessionControlBlock.lifetime` is a real count that
/// asserts against exactly that.
///
/// So what is held is the one thing that is not bookkeeping: the references
/// that keep the Session alive while the Run runs, and a tally of how many
/// are outstanding.
///
/// ## Why the tally is not avoidable
///
/// In process the Run's base lease is just another reference -- the control
/// block counts, it does not distinguish. Across the link the same holds: a
/// release request decrements some reference, and since they are fungible,
/// decrementing "some" is decrementing "the base one".
///
/// What that costs is the ability to tell, from a release request alone,
/// whether the caller has finished with the Run. So closure cannot simply
/// release the base lease: it would be releasing a reference some earlier
/// request may already have taken. The tally answers it exactly -- one for
/// the Run itself, one more for each retain granted, one fewer for each
/// release performed -- and closure releases what is left. Guessing instead
/// is a double release or a Session that never closes, and both are silent.
pub const BegunRun = struct {
    /// The Session the port named, as this half named it.
    context: ?*anyopaque,
    /// The Run's vtable, kept as a vtable rather than as its one function
    /// pointer so that every owner is reached by the same `@field(vtable,
    /// name)` and the dispatcher needs no case for this one.
    run_vtable: *const port.RunPort.VTable,
    run_id: u64,
    generation: u64,
    /// The control handle every retain and release goes through.
    control_handle: port.RunControl,
    /// References this half holds on the Session for this Run. Starts at one:
    /// the Run's own. Atomic because the requests that move it need not
    /// arrive on one thread, and a lost increment here is a Session released
    /// while a call is still inside it.
    outstanding: std.atomic.Value(u32) = .init(1),

    /// Takes the port apart. `port_impl.runPort` takes the Run's base lease
    /// with it, so the value handed in must not be used afterwards -- which
    /// is why this consumes it rather than borrowing.
    pub fn fromPort(value: port.RunPort) BegunRun {
        return .{
            .context = value.context,
            .run_vtable = value.vtable,
            .run_id = value.run_id,
            .generation = value.generation,
            .control_handle = value.base_lease.control,
        };
    }

    /// A retain the caller asked for. The tally moves only when the retain
    /// actually happened, so a refused one cannot leave a reference behind.
    pub fn retain(self: *BegunRun) bool {
        if (!self.control_handle.vtable.?.try_retain(self.control_handle.context)) return false;
        _ = self.outstanding.fetchAdd(1, .acq_rel);
        return true;
    }

    /// A release the caller asked for.
    pub fn release(self: *BegunRun) void {
        const previous = self.outstanding.fetchSub(1, .acq_rel);
        std.debug.assert(previous > 0);
        self.control_handle.vtable.?.release(self.control_handle.context);
    }

    /// Everything the caller never released, because it can no longer ask.
    /// Called once, by closure draining this Run's entry.
    pub fn releaseOutstanding(self: *BegunRun) u32 {
        const remaining = self.outstanding.swap(0, .acq_rel);
        var index: u32 = 0;
        while (index < remaining) : (index += 1) {
            self.control_handle.vtable.?.release(self.control_handle.context);
        }
        return remaining;
    }

    /// Whether a request names this Run. The identity travels as arguments,
    /// so it is checked here rather than trusted: a request naming another
    /// Run must not be executed as this one.
    pub fn names(self: *const BegunRun, run_id: u64, generation: u64) bool {
        return self.run_id == run_id and self.generation == generation;
    }
};

/// The execution half's own state, which is what makes an argument whole
/// again. A wire value plus these is a port value; a wire value alone is not.
pub const Bindings = struct {
    /// The execution half's allocator. A caller's allocator never crosses, so
    /// a method that takes one is called with this instead -- the response is
    /// encoded before the call returns, so nothing allocated here outlives
    /// the dispatch.
    allocator: std.mem.Allocator,
    /// The one Runtime. A `runtime` method names no receiver because there is
    /// nothing to choose between, so this is where its calls land.
    runtime: port.RuntimePort,
    /// Where checkpoint blob bytes go and come from. The link holds no store;
    /// `call_frame.BlobStore` says why this half carries the bytes at all.
    store: call_frame.BlobStore,
    /// Sessions this half holds for the other half to name, each with the
    /// tool capabilities of its current prepared Run. Those are not
    /// call-scoped, and `run_tools.zig` says why they live here.
    sessions: *handle_table.Table(run_tools.HeldSession),
    /// Runs, which also answer their control handle: in process both are the
    /// Session's control block, so `envelope.Receiver.run` names one entry.
    runs: *handle_table.Table(BegunRun),
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
            return held.port;
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
    /// The execution half performs the effect *during the call*, so its
    /// backing lives exactly as long as the call and nothing may keep it
    /// afterwards: a per-call allocation the far side still points at is a
    /// cross-process use-after-free, the worst failure available here.
    /// `dispatch.Frame` is for these, and the no-retention rule is checked
    /// there rather than promised here.
    ///
    /// The two checkpoint effects are the ones: Core writes the blob through
    /// the sink, and reads it through the source, before the call returns.
    call_scoped_effect,
    /// The execution half performs the effect, but the Session keeps the
    /// capability for its current prepared Run rather than using it during
    /// the call that handed it over.
    ///
    /// An earlier version of this file said no backing may outlive its call,
    /// full stop. That is false for these four and it was the dangerous kind
    /// of false: retiring their frame when `prepare_run_with_tools` returned
    /// would leave the Session holding a capability that answers only its
    /// failure value, so the tool would be permanently unavailable without
    /// anything crashing or going red.
    ///
    /// `session.zig` stores them (`run_delivery`, `run_mcp_installation`,
    /// `run_image`, `run_video`), uses them while the Run executes, and
    /// clears them in `clearRunToolsLocked`. There is at most one set per
    /// Session, asserted there before each store, so the backing is one set
    /// on the Session's own entry -- not a table keyed by prepared Run, which
    /// would make "many at once" representable when it is not.
    run_scoped_capability,
    /// The caller performs the effect, so it is a reverse call and lives in
    /// `reverse.zig` under its rules. Being the caller's says nothing about
    /// how long the execution half must hold the means of asking: the
    /// delivery inspection is asked during the Run, so its bridge is
    /// Run-scoped as well.
    reverse_call,
    /// Deferred to the MCP step with the rest of the MCP handle surface.
    mcp_step,
};

/// The disposition of each parameter type still owed, closed both ways: a type
/// the chain cannot rebuild must appear here, and a type that gains an adapter
/// must leave. A list that outlives its reason teaches the wrong rule.
const dispositions = [_]struct { name: []const u8, disposition: Disposition }{
    .{ .name = @typeName(checkpoint.Sink), .disposition = .call_scoped_effect },
    .{
        .name = @typeName(surface.SessionRestoreOptions),
        .disposition = .call_scoped_effect,
    },
    .{
        .name = @typeName(?surface.ImageGenerationRunInput),
        .disposition = .run_scoped_capability,
    },
    .{ .name = @typeName(?contract.FileDeliveryInput), .disposition = .reverse_call },
    .{ .name = @typeName(?contract.McpInstallationInput), .disposition = .reverse_call },
    .{
        .name = @typeName(?contract.VideoGenerationRunInput),
        .disposition = .run_scoped_capability,
    },
    .{ .name = @typeName(*const mcp_catalog.Activation), .disposition = .mcp_step },
    .{ .name = @typeName(*const mcp_catalog.RestoreSelection), .disposition = .mcp_step },
};

/// The disposition recorded for a type, by type rather than by its printed
/// name, so a caller does not have to spell it.
pub fn dispositionOfType(comptime T: type) ?Disposition {
    return dispositionOf(@typeName(T));
}

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
    var sessions = try handle_table.Table(run_tools.HeldSession).init(testing.allocator, 1);
    defer sessions.deinit();
    var runs = try handle_table.Table(BegunRun).init(testing.allocator, 1);
    defer runs.deinit();
    var leases = try handle_table.Table(catalog.Lease).init(testing.allocator, 1);
    defer leases.deinit();
    var skill_restore = try handle_table.Table(port.SkillRestoreInputs).init(testing.allocator, 1);
    defer skill_restore.deinit();
    var session_restore = try handle_table.Table(port.SessionRestoreInputs).init(testing.allocator, 1);
    defer session_restore.deinit();
    var selections = try handle_table.Table(mcp_catalog.Selection).init(testing.allocator, 1);
    defer selections.deinit();

    var first = run_tools.HeldSession.init(.{ .context = null, .vtable = undefined });
    var second = run_tools.HeldSession.init(.{ .context = null, .vtable = undefined });
    const bindings: Bindings = .{
        .allocator = testing.allocator,
        .runtime = port.RuntimePort.quiet,
        .store = call_frame.BlobStore.empty,
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
    var call_scoped: usize = 0;
    var run_scoped: usize = 0;
    var mcp: usize = 0;
    for (owed) |entry| switch (entry.disposition) {
        .reverse_call => reverse += 1,
        .call_scoped_effect => call_scoped += 1,
        .run_scoped_capability => run_scoped += 1,
        .mcp_step => mcp += 1,
    };
    // The delivery inspection and the MCP installation are the caller's. Of
    // this half's own, the two checkpoint effects are used during their call
    // and the image and video bindings are kept for the Run -- which is the
    // distinction a single "execution side effect" was hiding.
    try testing.expectEqual(@as(usize, 2), reverse);
    try testing.expectEqual(@as(usize, 2), call_scoped);
    try testing.expectEqual(@as(usize, 2), run_scoped);
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
        .runtime = port.RuntimePort.quiet,
        .store = call_frame.BlobStore.empty,
        .sessions = undefined,
        .runs = undefined,
        .leases = undefined,
        .skill_restore = undefined,
        .session_restore = undefined,
        .selections = undefined,
    };
}

test "an options mirror is read back with its handle resolved and its absence kept" {
    var sessions = try handle_table.Table(run_tools.HeldSession).init(testing.allocator, 1);
    defer sessions.deinit();
    var runs = try handle_table.Table(BegunRun).init(testing.allocator, 1);
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
        .runtime = port.RuntimePort.quiet,
        .store = call_frame.BlobStore.empty,
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
        .task_id = 11,
        .binding_epoch = 3,
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

// ---------------------------------------------------------------------------
// The other direction
// ---------------------------------------------------------------------------
//
// A dispatcher has to encode what the method returned, and that is not the
// mirror image of decoding what it was called with. Rebuilding an argument
// reads a table; returning a value may have to *put something in one*, and an
// entry put in has an owner, a lifetime and a release. So the two directions
// are counted separately, and this one starts where the other one did: with
// what is already answered, and a list of what is not.

pub const ResultError = ResolveError || handle_table.InsertError;

pub fn ResultAdapter(comptime T: type) type {
    return struct {
        apply: *const fn (Bindings, T) ResultError!wire_types.Wire(T),
    };
}

/// How one return type becomes its wire form, or `null` when nothing does it
/// yet.
pub fn resultAdapter(comptime T: type) ?ResultAdapter(T) {
    // Plain data again, and again it is most of them: a Run id, a count, a
    // bool, `void`. Nothing to own and nothing to decide.
    if (wire_types.Wire(T) == T) return .{ .apply = struct {
        fn apply(_: Bindings, value: T) ResultError!T {
            return value;
        }
    }.apply };

    // Mirrors that reshape rather than copy: each has its own `from`, and
    // what it does -- numbering an error, dropping a diagnostic the caller
    // must not read -- is not a field-by-field copy.
    if (T == surface.CloseOutcome) return .{ .apply = struct {
        fn apply(_: Bindings, value: T) ResultError!shapes.CloseOutcome {
            return shapes.CloseOutcome.from(value);
        }
    }.apply };
    if (T == surface.BeginRunFailure) return .{ .apply = struct {
        fn apply(_: Bindings, value: T) ResultError!shapes.BeginRunFailure {
            return shapes.BeginRunFailure.from(value);
        }
    }.apply };
    if (T == control.TerminalResult) return .{ .apply = struct {
        fn apply(_: Bindings, value: T) ResultError!shapes.TerminalResult {
            return shapes.TerminalResult.from(&value);
        }
    }.apply };
    if (T == control.CompactTerminalResult) return .{ .apply = struct {
        fn apply(_: Bindings, value: T) ResultError!shapes.CompactTerminalResult {
            return shapes.CompactTerminalResult.from(&value);
        }
    }.apply };
    if (T == surface.PendingUiRequest) return .{ .apply = struct {
        fn apply(_: Bindings, value: T) ResultError!shapes.PendingUiRequest {
            return shapes.PendingUiRequest.from(&value);
        }
    }.apply };
    if (T == catalog.Projection) return .{ .apply = struct {
        fn apply(_: Bindings, value: T) ResultError!shapes.CatalogProjection {
            return shapes.CatalogProjection.from(value);
        }
    }.apply };

    // Mirrors whose fields all correspond, copied by the generic reader
    // rather than by hand.
    if (T == checkpoint.Description) return resultMirror(T, shapes.CheckpointDescription);
    // `catalog.Acquisition` is not here: its lease has to be *put into* a
    // table, and `named_handles` classifies its method as irreversible, so it
    // waits for the path that carries a reservation into the result encoding.

    // A union, so the two sides are stated rather than looped over: the
    // success carries a description that is itself a mirror, and the failure
    // is already plain data.
    if (T == checkpoint.Outcome) return .{ .apply = struct {
        fn apply(bindings: Bindings, value: T) ResultError!shapes.CheckpointOutcome {
            return switch (value) {
                .success => |success| .{ .success = .{
                    .checkpoint = success.checkpoint,
                    // As the Session answered it. `dispatch.exportCheckpoint`
                    // is what replaces `caller_sink` with its own area,
                    // because it is the half that opened the blob -- this
                    // encoder only carries what it was given.
                    .placement = success.placement,
                    .description = try (comptime resultAdapter(checkpoint.Description).?)
                        .apply(bindings, success.description),
                } },
                .failure => |failure| .{ .failure = failure },
            };
        }
    }.apply };

    return null;
}

/// A port value copied into the mirror that carries it, field by field.
///
/// The inverse of `mirrorAdapter`, and generic for the same reason: a
/// hand-written copy is a second place for a shape to drift, and
/// `shapes.mirrors` only checks that a mirror field still names something.
/// Only for mirrors whose fields all correspond -- the ones `shapes.zig`
/// records with an empty reshaped list. A mirror that renames or recomputes
/// a field has its own `from`, because what it does is not a copy.
/// Whether a mirror field borrows what the original owns: the same bytes,
/// read-only. Ownership does not cross -- the original frees them after the
/// response is encoded -- so the mirror naming them `const` is the honest
/// shape rather than a different encoding.
fn borrowsFrom(comptime Mirrored: type, comptime Origin: type) bool {
    const mirrored = @typeInfo(Mirrored);
    const origin = @typeInfo(Origin);
    // An optional of each is the same question one level down.
    if (mirrored == .optional and origin == .optional)
        return borrowsFrom(mirrored.optional.child, origin.optional.child);
    if (mirrored != .pointer or origin != .pointer) return false;
    if (mirrored.pointer.size != .slice or origin.pointer.size != .slice) return false;
    return mirrored.pointer.child == origin.pointer.child and
        mirrored.pointer.is_const and !origin.pointer.is_const;
}

fn resultMirror(comptime T: type, comptime Mirror: type) ResultAdapter(T) {
    if (wire_types.Wire(T) != Mirror) @compileError(
        "the mirror for " ++ @typeName(T) ++ " is not its wire form",
    );
    return .{
        .apply = struct {
            fn apply(bindings: Bindings, value: T) ResultError!Mirror {
                var out: Mirror = undefined;
                inline for (@typeInfo(Mirror).@"struct".fields) |field| {
                    if (!@hasField(T, field.name)) @compileError(
                        @typeName(Mirror) ++ "." ++ field.name ++ " does not name a field of " ++
                            @typeName(T) ++ ", so this is a reshaping rather than a copy and " ++
                            "belongs in that mirror's own `from`",
                    );
                    const Origin = @FieldType(T, field.name);
                    if (Origin == field.type or comptime borrowsFrom(field.type, Origin)) {
                        @field(out, field.name) = @field(value, field.name);
                        continue;
                    }
                    const nested = comptime resultAdapter(Origin) orelse @compileError(
                        @typeName(T) ++ "." ++ field.name ++ " is carried as " ++
                            @typeName(field.type) ++ " and nothing turns " ++
                            @typeName(Origin) ++ " into it",
                    );
                    if (field.type != wire_types.Wire(Origin)) @compileError(
                        @typeName(Mirror) ++ "." ++ field.name ++ " is " ++
                            @typeName(field.type) ++ " but " ++ @typeName(Origin) ++
                            " crosses as " ++ @typeName(wire_types.Wire(Origin)) ++
                            "; one field cannot have two encodings",
                    );
                    @field(out, field.name) = try nested.apply(bindings, @field(value, field.name));
                }
                return out;
            }
        }.apply,
    };
}

/// One return type still owed, with the same discipline as the argument side:
/// never "nobody got to it yet".
pub const OwedResult = struct {
    owner: method.Owner,
    name: []const u8,
    result: []const u8,
};

pub fn owedResults() []const OwedResult {
    comptime {
        @setEvalBranchQuota(1_000_000);
        var list: []const OwedResult = &.{};
        for (method.entries) |entry| {
            if (entry.transport == .stream) continue;
            const blocked = switch (entry.owner) {
                inline else => |owner| blockingResult(owner, entry.name),
            };
            if (blocked) |name| list = list ++ [_]OwedResult{.{
                .owner = entry.owner,
                .name = entry.name,
                .result = name,
            }};
        }
        return list;
    }
}

fn blockingResult(comptime owner: method.Owner, comptime name: []const u8) ?[]const u8 {
    comptime {
        const Fn = @typeInfo(@FieldType(owner.VTable(), name)).pointer.child;
        const Returned = wire_types.Payload(@typeInfo(Fn).@"fn".return_type.?);
        if (Returned == void) return null;
        if (resultAdapter(Returned) != null) return null;
        return @typeName(Returned);
    }
}

test "the return direction is counted on its own, because it is not the mirror image" {
    const owed = comptime owedResults();
    const callable = comptime callableCount();

    // Most returns are plain data and need nothing, which is the same reason
    // most arguments needed nothing.
    try testing.expectEqual(@as(usize, 50), callable);
    try testing.expectEqual(@as(usize, 11), owed.len);

    for (owed) |entry| {
        try testing.expect(entry.name.len > 0);
        try testing.expect(entry.result.len > 0);
    }

    // The one written mirror, to show the mechanism carries a real contract
    // type rather than only compiling.
    const closed = resultAdapter(surface.CloseOutcome).?;
    const bindings = testBindings();
    const encoded = try closed.apply(bindings, .closed);
    try testing.expect(encoded == .closed);
}

test "a return that puts something in a table is owed, not assumed trivial" {
    // The asymmetry this direction exists for: reading a handle out of a
    // table is settled, but putting one in decides who owns the entry and
    // when it leaves. Until that is decided these stay owed, because a
    // half-decided owner is how a handle leaks or is released twice.
    try testing.expect(resultAdapter(port.SessionRoute) == null);
    try testing.expect(resultAdapter(port.BeginRunOutcome) == null);
    try testing.expect(resultAdapter(port.SkillRestoreBorrow) == null);
}

// ---------------------------------------------------------------------------
// Who reclaims an entry whose owner never comes back
// ---------------------------------------------------------------------------
//
// "Putting a handle in a table decides who owns the entry and when it leaves"
// has a third question, and it is the one with no symptom: when that owner
// never returns, who clears it. `insert` fails once a table is full, so a leak
// shows up as calls suddenly being refused, with the link looking healthy
// until that moment. Nothing here is harder to find.
//
// The answer is the same shape as the rest of this change: an entry's life is
// bound to something that already ends, and exactly two things end one.
//
// - Its own registered release, asked for by the owner while the link is up.
// - The link ending. Closure drains every table, because an entry whose owner
//   is unreachable is not waiting for anything.
//
// There is deliberately no third. No scavenging, no timeout, no releasing the
// oldest: each of those retires an entry a live owner still names, which is
// the stale-handle failure a generation in an id exists to catch, brought
// back as a policy.
//
// The inventory below is checked against `Bindings` both ways, so a table
// added later cannot be left out of closure, and an entry here cannot outlive
// the table it describes.

pub const Reclaim = struct {
    /// The `Bindings` field holding the table.
    field: []const u8,
    /// The registered method an owner releases one entry through. Empty where
    /// the entry belongs to this half rather than to the caller.
    release_method: []const u8,
    /// What the entry's life is bound to, which is what closure drains with.
    bound_to: enum {
        /// Ends when the Session closes, or when the link does.
        session,
        /// Ends when this Run's life ends by any means, or when the link
        /// does.
        ///
        /// Deliberately not "reaches its terminal", which is what this said
        /// before and is narrower than the truth. A Run prepared and never
        /// executed ends too: `session.zig` clears a prepared Run's tools
        /// from five places -- a begin that refused, a cancel, the Session
        /// closing, an identity contract failure, and the terminal itself.
        /// Binding to the terminal would leave the other four holding
        /// capacity for something that never happened, which is the shape
        /// this change has already hit twice.
        run,
        /// Held by the caller between two of its own calls. Nothing but its
        /// release or the link bounds it, which is why these are the entries
        /// a capacity failure will name first.
        caller_hold,
    },
};

pub const reclamation = [_]Reclaim{
    .{ .field = "sessions", .release_method = "release_closed_session", .bound_to = .session },
    .{ .field = "runs", .release_method = "release", .bound_to = .run },
    .{ .field = "leases", .release_method = "release_skill_catalog", .bound_to = .caller_hold },
    .{
        .field = "skill_restore",
        .release_method = "release_skill_restore_inputs",
        .bound_to = .caller_hold,
    },
    .{
        .field = "session_restore",
        .release_method = "release_restore_inputs",
        .bound_to = .caller_hold,
    },
    .{ .field = "selections", .release_method = "", .bound_to = .session },
};

fn isHandleTable(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .pointer) return false;
    const Child = info.pointer.child;
    return switch (@typeInfo(Child)) {
        .@"struct" => @hasDecl(Child, "is_handle_table"),
        else => false,
    };
}

fn reclaimFor(comptime field: []const u8) ?Reclaim {
    comptime {
        for (reclamation) |entry| {
            if (std.mem.eql(u8, entry.field, field)) return entry;
        }
        return null;
    }
}

comptime {
    @setEvalBranchQuota(200_000);
    // Every table this half holds says how its entries are reclaimed.
    for (@typeInfo(Bindings).@"struct".fields) |field| {
        if (!isHandleTable(field.type)) continue;
        if (reclaimFor(field.name) == null) @compileError(
            "Bindings." ++ field.name ++ " is a handle table and nothing says what reclaims " ++
                "its entries. Add it to `reclamation` in src/agent/link/adapters.zig: a " ++
                "table nobody drains leaks until it is full, and then every call needing one " ++
                "is refused with no earlier symptom",
        );
    }
    // And every entry still describes a table that exists.
    for (reclamation) |entry| {
        if (!@hasField(Bindings, entry.field)) @compileError(
            "`reclamation` names Bindings." ++ entry.field ++ ", which is not a field",
        );
    }
}

pub const TableCount = struct {
    field: []const u8,
    live: usize,
    capacity: usize,
};

/// How many entries each table holds, for the diagnostic a capacity failure
/// has to carry. A refusal that does not name the table it came from leaves
/// out the one fact worth having.
pub fn liveCounts(bindings: Bindings) [reclamation.len]TableCount {
    var out: [reclamation.len]TableCount = undefined;
    inline for (reclamation, 0..) |entry, index| {
        const table = @field(bindings, entry.field);
        out[index] = .{
            .field = entry.field,
            .live = table.liveCount(),
            .capacity = table.capacity(),
        };
    }
    return out;
}

test "every handle table says what reclaims its entries, and only in two ways" {
    // The comptime block above fails the build otherwise; this records the
    // division, because which entries a capacity failure names first is worth
    // seeing in the suite.
    comptime var tables: usize = 0;
    inline for (@typeInfo(Bindings).@"struct".fields) |field| {
        if (comptime isHandleTable(field.type)) tables += 1;
    }
    try testing.expectEqual(reclamation.len, tables);
    try testing.expectEqual(@as(usize, 6), tables);

    var caller_held: usize = 0;
    for (reclamation) |entry| {
        if (entry.bound_to == .caller_hold) caller_held += 1;
        // A release method named here must be a registered method; an entry
        // belonging to this half names none.
        if (entry.release_method.len != 0) {
            var found = false;
            for (method.entries) |registered| {
                if (std.mem.eql(u8, registered.name, entry.release_method)) found = true;
            }
            try testing.expect(found);
        }
    }
    try testing.expectEqual(@as(usize, 3), caller_held);
}

test "a capacity refusal can name the table it came from" {
    var sessions = try handle_table.Table(run_tools.HeldSession).init(testing.allocator, 1);
    defer sessions.deinit();
    var runs = try handle_table.Table(BegunRun).init(testing.allocator, 2);
    defer runs.deinit();
    var leases = try handle_table.Table(catalog.Lease).init(testing.allocator, 3);
    defer leases.deinit();
    var skill_restore = try handle_table.Table(port.SkillRestoreInputs).init(testing.allocator, 4);
    defer skill_restore.deinit();
    var session_restore = try handle_table.Table(port.SessionRestoreInputs).init(testing.allocator, 5);
    defer session_restore.deinit();
    var selections = try handle_table.Table(mcp_catalog.Selection).init(testing.allocator, 6);
    defer selections.deinit();
    const bindings: Bindings = .{
        .allocator = testing.allocator,
        .runtime = port.RuntimePort.quiet,
        .store = call_frame.BlobStore.empty,
        .sessions = &sessions,
        .runs = &runs,
        .leases = &leases,
        .skill_restore = &skill_restore,
        .session_restore = &session_restore,
        .selections = &selections,
    };

    var held = run_tools.HeldSession.init(.{ .context = null, .vtable = undefined });
    const id = try sessions.insert(&held);

    const counts = liveCounts(bindings);
    try testing.expectEqual(reclamation.len, counts.len);
    for (counts) |entry| {
        if (std.mem.eql(u8, entry.field, "sessions")) {
            try testing.expectEqual(@as(usize, 1), entry.live);
            try testing.expectEqual(@as(usize, 1), entry.capacity);
        } else {
            try testing.expectEqual(@as(usize, 0), entry.live);
        }
    }

    // Full, and the refusal is a typed failure rather than a growth.
    var second = run_tools.HeldSession.init(.{ .context = null, .vtable = undefined });
    try testing.expectError(error.HandleCapacity, sessions.insert(&second));
    _ = sessions.take(id);
}

/// What ends a set of entries. The same values `Reclaim.bound_to` names, so
/// asking "what does this ending drain" is a lookup in that table rather than
/// a list someone kept beside it.
pub const Bound = @FieldType(Reclaim, "bound_to");

/// Drains every table whose entries are bound to `bound`, handing each object
/// to `releaser.release(T, pointer)`.
///
/// Driven by `reclamation` rather than by a written-out list of tables. That
/// is the difference between `bound_to` being a fact and being a note: a
/// table added to `Bindings` has to appear in that inventory already, so it
/// is drained here without anyone remembering to add it -- and if its ending
/// were wrong, the test below would show entries surviving an ending that
/// should have taken them.
///
/// No allocation: `drain` fills whatever buffer it is given and says how
/// much, so this loops until a pass comes back empty.
pub fn drainBound(bindings: Bindings, bound: Bound, releaser: anytype) usize {
    var drained: usize = 0;
    inline for (reclamation) |entry| {
        if (entry.bound_to == bound) {
            const table = @field(bindings, entry.field);
            const Held = @TypeOf(table.*).Held;
            var buffer: [16]*Held = undefined;
            while (true) {
                const taken = table.drain(&buffer);
                if (taken.len == 0) break;
                for (taken) |value| {
                    releaser.release(Held, value);
                    drained += 1;
                }
            }
        }
    }
    return drained;
}

/// The link ended, so every entry ends with it: an object the other half can
/// no longer name is not waiting for anything.
pub fn drainEverything(bindings: Bindings, releaser: anytype) usize {
    var drained: usize = 0;
    inline for (comptime std.enums.values(Bound)) |bound| {
        drained += drainBound(bindings, bound, releaser);
    }
    return drained;
}

/// Counts what each ending is responsible for, so "something really empties
/// this table" is a number rather than a claim.
pub fn tablesBoundTo(comptime bound: Bound) usize {
    var count: usize = 0;
    inline for (reclamation) |entry| {
        if (entry.bound_to == bound) count += 1;
    }
    return count;
}

const ReleaseLog = struct {
    sessions: usize = 0,
    runs: usize = 0,
    leases: usize = 0,
    skill_restore: usize = 0,
    session_restore: usize = 0,
    selections: usize = 0,

    fn release(self: *ReleaseLog, comptime T: type, value: *T) void {
        _ = value;
        if (T == run_tools.HeldSession) self.sessions += 1;
        if (T == BegunRun) self.runs += 1;
        if (T == catalog.Lease) self.leases += 1;
        if (T == port.SkillRestoreInputs) self.skill_restore += 1;
        if (T == port.SessionRestoreInputs) self.session_restore += 1;
        if (T == mcp_catalog.Selection) self.selections += 1;
    }

    fn total(self: ReleaseLog) usize {
        return self.sessions + self.runs + self.leases +
            self.skill_restore + self.session_restore + self.selections;
    }
};

const Tables = struct {
    sessions: handle_table.Table(run_tools.HeldSession),
    runs: handle_table.Table(BegunRun),
    leases: handle_table.Table(catalog.Lease),
    skill_restore: handle_table.Table(port.SkillRestoreInputs),
    session_restore: handle_table.Table(port.SessionRestoreInputs),
    selections: handle_table.Table(mcp_catalog.Selection),

    fn init() !Tables {
        return .{
            .sessions = try handle_table.Table(run_tools.HeldSession).init(testing.allocator, 4),
            .runs = try handle_table.Table(BegunRun).init(testing.allocator, 4),
            .leases = try handle_table.Table(catalog.Lease).init(testing.allocator, 4),
            .skill_restore = try handle_table.Table(port.SkillRestoreInputs)
                .init(testing.allocator, 4),
            .session_restore = try handle_table.Table(port.SessionRestoreInputs)
                .init(testing.allocator, 4),
            .selections = try handle_table.Table(mcp_catalog.Selection).init(testing.allocator, 4),
        };
    }

    fn deinit(self: *Tables) void {
        self.sessions.deinit();
        self.runs.deinit();
        self.leases.deinit();
        self.skill_restore.deinit();
        self.session_restore.deinit();
        self.selections.deinit();
    }

    fn bindings(self: *Tables) Bindings {
        return .{
            .allocator = testing.allocator,
            .runtime = port.RuntimePort.quiet,
            .store = call_frame.BlobStore.empty,
            .sessions = &self.sessions,
            .runs = &self.runs,
            .leases = &self.leases,
            .skill_restore = &self.skill_restore,
            .session_restore = &self.session_restore,
            .selections = &self.selections,
        };
    }

    /// One entry in every table, so a drain that misses one is visible.
    fn fill(self: *Tables, storage: *Storage) !void {
        _ = try self.sessions.insert(&storage.session);
        _ = try self.runs.insert(&storage.run);
        _ = try self.leases.insert(@ptrCast(&storage.lease));
        _ = try self.skill_restore.insert(@ptrCast(&storage.skill));
        _ = try self.session_restore.insert(&storage.session_inputs);
        _ = try self.selections.insert(@ptrCast(&storage.selection));
    }

    fn live(self: *const Tables) usize {
        return self.sessions.live + self.runs.live + self.leases.live +
            self.skill_restore.live + self.session_restore.live + self.selections.live;
    }
};

const Storage = struct {
    session: run_tools.HeldSession = run_tools.HeldSession.init(.{ .context = null, .vtable = undefined }),
    run: BegunRun = undefined,
    lease: [8]u8 align(8) = @splat(0),
    skill: [8]u8 align(8) = @splat(0),
    session_inputs: port.SessionRestoreInputs = undefined,
    selection: [8]u8 align(8) = @splat(0),
};

test "an ending drains exactly the tables bound to it, and the link drains all" {
    var tables = try Tables.init();
    defer tables.deinit();
    var storage: Storage = .{};
    try tables.fill(&storage);
    try testing.expectEqual(@as(usize, 6), tables.live());

    var log: ReleaseLog = .{};
    // A Session closing takes the Session and the MCP selection it bound, and
    // nothing else: the caller still holds the three it holds.
    try testing.expectEqual(@as(usize, 2), tablesBoundTo(.session));
    try testing.expectEqual(@as(usize, 2), drainBound(tables.bindings(), .session, &log));
    try testing.expectEqual(@as(usize, 1), log.sessions);
    try testing.expectEqual(@as(usize, 1), log.selections);
    try testing.expectEqual(@as(usize, 0), log.leases);
    try testing.expectEqual(@as(usize, 4), tables.live());

    // A Run reaching its terminal takes its own entry and no one else's.
    try testing.expectEqual(@as(usize, 1), drainBound(tables.bindings(), .run, &log));
    try testing.expectEqual(@as(usize, 1), log.runs);
    try testing.expectEqual(@as(usize, 3), tables.live());

    // And the three the caller holds are exactly what is left, which is why
    // they are the ones a capacity refusal names first.
    try testing.expectEqual(@as(usize, 3), tablesBoundTo(.caller_hold));
    try testing.expectEqual(@as(usize, 3), drainBound(tables.bindings(), .caller_hold, &log));
    try testing.expectEqual(@as(usize, 0), tables.live());
    try testing.expectEqual(@as(usize, 6), log.total());
}

test "the link ending leaves no table holding anything" {
    // The property the inventory exists for: closure is driven by
    // `reclamation`, so this covers a table added later without anyone
    // editing this test. A table whose ending never arrives would show up
    // here as an entry that survived.
    var tables = try Tables.init();
    defer tables.deinit();
    var storage: Storage = .{};
    try tables.fill(&storage);

    var log: ReleaseLog = .{};
    try testing.expectEqual(@as(usize, 6), drainEverything(tables.bindings(), &log));
    try testing.expectEqual(@as(usize, 0), tables.live());
    try testing.expectEqual(@as(usize, 6), log.total());

    // Every ending together covers the whole inventory, so no entry is bound
    // to something that never happens.
    var covered: usize = 0;
    inline for (comptime std.enums.values(Bound)) |bound| covered += tablesBoundTo(bound);
    try testing.expectEqual(reclamation.len, covered);

    // Draining twice releases nothing twice: every id was retired by the
    // first pass.
    var second: ReleaseLog = .{};
    try testing.expectEqual(@as(usize, 0), drainEverything(tables.bindings(), &second));
}

/// A control handle that counts, so the accounting can be asserted rather
/// than reasoned about.
const CountingControl = struct {
    retains: u32 = 0,
    releases: u32 = 0,
    refuse: bool = false,

    fn tryRetain(context: ?*anyopaque) bool {
        const self: *CountingControl = @ptrCast(@alignCast(context.?));
        if (self.refuse) return false;
        self.retains += 1;
        return true;
    }

    fn release(context: ?*anyopaque) void {
        const self: *CountingControl = @ptrCast(@alignCast(context.?));
        self.releases += 1;
    }

    fn submitInput(
        _: ?*anyopaque,
        _: u64,
        _: u64,
        _: u64,
        _: []const u8,
    ) control.InputSubmission {
        return @unionInit(
            control.InputSubmission,
            @tagName(control.InputSubmission.link_unreachable),
            {},
        );
    }

    fn inputObservation(_: ?*anyopaque, _: u64, _: u64) ?control.InputObservation {
        return null;
    }

    fn requestTermination(
        _: ?*anyopaque,
        _: u64,
        _: u64,
        _: control.TerminationSignal,
    ) control.TerminationRequestResult {
        return control.TerminationRequestResult.link_unreachable;
    }

    const vtable: port.RunControl.VTable = .{
        .try_retain = tryRetain,
        .release = release,
        .submit_input = submitInput,
        .input_observation = inputObservation,
        .request_termination = requestTermination,
    };

    fn executed(_: ?*anyopaque, _: u64, _: u64) control.TerminalResult {
        unreachable;
    }

    fn begunRun(self: *CountingControl) BegunRun {
        // Built the way `fromPort` builds it, through a port value, so the
        // test exercises the taking-apart rather than hand-filling the parts.
        const handle: port.RunControl = .{
            .context = self,
            .vtable = &vtable,
            .run_id = 11,
            .generation = 4,
        };
        return BegunRun.fromPort(.{
            .context = self,
            .vtable = &run_vtable,
            .run_id = 11,
            .generation = 4,
            .base_lease = .{ .control = handle },
        });
    }

    const run_vtable: port.RunPort.VTable = .{ .execute = executed };
};

test "every reference this half holds for a Run is released exactly once" {
    var counting: CountingControl = .{};
    var run = counting.begunRun();

    // The Run's own reference is held without a retain crossing: it exists
    // because the Run does.
    try testing.expectEqual(@as(u32, 1), run.outstanding.load(.acquire));
    try testing.expectEqual(@as(u32, 0), counting.retains);

    // Two retains the caller asked for, one release it asked for.
    try testing.expect(run.retain());
    try testing.expect(run.retain());
    try testing.expectEqual(@as(u32, 3), run.outstanding.load(.acquire));
    run.release();
    try testing.expectEqual(@as(u32, 2), run.outstanding.load(.acquire));

    // The link ends. What is left is released, and the totals balance: three
    // references held (one for the Run, two retained), three released.
    try testing.expectEqual(@as(u32, 2), run.releaseOutstanding());
    try testing.expectEqual(@as(u32, 2), counting.retains);
    try testing.expectEqual(@as(u32, 3), counting.releases);
    try testing.expectEqual(counting.retains + 1, counting.releases);

    // Draining twice releases nothing twice, which is the failure a guess
    // would produce here.
    try testing.expectEqual(@as(u32, 0), run.releaseOutstanding());
    try testing.expectEqual(@as(u32, 3), counting.releases);
}

test "a refused retain leaves no reference behind" {
    var counting: CountingControl = .{ .refuse = true };
    var run = counting.begunRun();

    try testing.expect(!run.retain());
    // The tally did not move, so closure will not release a reference the
    // Session never gave out.
    try testing.expectEqual(@as(u32, 1), run.outstanding.load(.acquire));
    try testing.expectEqual(@as(u32, 1), run.releaseOutstanding());
    try testing.expectEqual(@as(u32, 1), counting.releases);
}

test "a request naming another Run is not executed as this one" {
    var counting: CountingControl = .{};
    var run = counting.begunRun();
    defer _ = run.releaseOutstanding();

    // The identity travels as ordinary arguments, so it is checked against
    // the entry rather than trusted. `execute` here would panic if reached,
    // which is the point: a mismatch must not get that far.
    try testing.expect(run.names(11, 4));
    try testing.expect(!run.names(11, 5));
    try testing.expect(!run.names(12, 4));
}

/// Whether a wire type names a handle anywhere inside it, which is how a
/// result ends up putting something in a table.
pub fn namesHandle(comptime T: type) bool {
    if (T == handle_table.Id) return true;
    return switch (@typeInfo(T)) {
        .optional => |info| namesHandle(info.child),
        .array => |info| namesHandle(info.child),
        .pointer => |info| info.size == .slice and namesHandle(info.child),
        .@"struct" => |info| blk: {
            inline for (info.fields) |field| {
                if (namesHandle(field.type)) break :blk true;
            }
            break :blk false;
        },
        .@"union" => |info| blk: {
            inline for (info.fields) |field| {
                if (namesHandle(field.type)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

/// How the thing a result names came to exist, which decides whether its slot
/// has to be promised before the call or can be filled after it.
///
/// Derived from the question nobody can answer from a signature: if naming
/// the result fails, can what the call created be undone? For a begun Run the
/// answer is no at all -- its own contract says it must execute and
/// deinitialize exactly once -- and for the rest the undo is a call that can
/// itself fail. Only where nothing new was created is "insert afterwards"
/// safe.
pub const Creation = enum {
    /// Success cannot be taken back, or can only be taken back by a call that
    /// may fail. The slot is promised before this runs, so a refusal happens
    /// while there is still nothing to deliver.
    irreversible,
    /// The result names something that already exists, so there is nothing to
    /// insert and nothing to promise.
    names_existing,
    /// Deferred to the MCP step with the rest of that surface.
    mcp_step,
};

pub const Named = struct {
    name: []const u8,
    creation: Creation,
    reason: []const u8,
};

/// Every method whose wire result names a handle, with how that handle came
/// to exist. Closed against the derivation below, so a method that starts
/// naming one cannot slip in unclassified -- and a classification cannot
/// outlive the result it describes.
pub const named_handles = [_]Named{
    .{
        .name = "create_session_route",
        .creation = .irreversible,
        .reason = "undoing it means closing the Session and then releasing it, and the close " ++
            "can fail, so a naming failure afterwards could leave a Session open with no " ++
            "name to reach it by",
    },
    .{
        .name = "restore_session_route",
        .creation = .irreversible,
        .reason = "as create_session_route, and it has read a checkpoint besides",
    },
    .{
        .name = "activate_mcp",
        .creation = .mcp_step,
        .reason = "deferred with the rest of the MCP handle surface, which brings its own " ++
            "tables and its own release methods, so classifying this one alone would " ++
            "decide half of a question",
    },
    .{
        .name = "create_mcp_admission_selection",
        .creation = .mcp_step,
        .reason = "deferred with the rest of the MCP handle surface, which brings its own " ++
            "tables and its own release methods, so classifying this one alone would " ++
            "decide half of a question",
    },
    .{
        .name = "prepare_mcp_restore_selection",
        .creation = .mcp_step,
        .reason = "deferred with the rest of the MCP handle surface, which brings its own " ++
            "tables and its own release methods, so classifying this one alone would " ++
            "decide half of a question",
    },
    .{
        .name = "query_skill_catalog",
        .creation = .irreversible,
        .reason = "the acquisition holds a catalog lease, and release_skill_catalog returns " ++
            "an error union, so the undo is a call that can fail",
    },
    .{
        .name = "narrow_skill_restore_inputs",
        .creation = .irreversible,
        .reason = "allocates new inputs whose release returns an error union",
    },
    .{
        .name = "clone_skill_restore_inputs",
        .creation = .irreversible,
        .reason = "allocates new inputs whose release returns an error union",
    },
    .{
        .name = "borrow_skill_restore_inputs",
        .creation = .names_existing,
        .reason = "reads a lease the caller already holds rather than creating one, so there " ++
            "is nothing to promise. It needs the id that lease was already issued, which " ++
            "the table cannot answer yet: it maps an id to an object and not the other way " ++
            "round. Inserting again would give one lease two names and two releases",
    },
    .{
        .name = "capture_restore_inputs",
        .creation = .irreversible,
        .reason = "captures new inputs whose release returns an error union",
    },
    .{
        .name = "begin_run_outcome",
        .creation = .irreversible,
        .reason = "the strongest case and the one that found this rule: a begun Run is a " ++
            "linear value that must execute and deinitialize exactly once, and RunPort.deinit " ++
            "asserts it executed. A Run begun and then not namable is neither deliverable " ++
            "nor droppable",
    },
};

fn namedHandle(comptime name: []const u8) ?Named {
    comptime {
        for (named_handles) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry;
        }
        return null;
    }
}

fn WireResult(comptime owner: method.Owner, comptime name: []const u8) type {
    comptime {
        const Fn = @typeInfo(@FieldType(owner.VTable(), name)).pointer.child;
        const Returned = wire_types.Payload(@typeInfo(Fn).@"fn".return_type.?);
        return wire_types.Wire(Returned);
    }
}

comptime {
    @setEvalBranchQuota(1_000_000);
    // Every result that names a handle says how that handle came to exist,
    // and nothing else claims to.
    for (method.entries) |entry| {
        if (entry.transport == .stream) continue;
        const Wired = switch (entry.owner) {
            inline else => |owner| WireResult(owner, entry.name),
        };
        const names = Wired != void and namesHandle(Wired);
        const listed = namedHandle(entry.name) != null;
        if (names and !listed) @compileError(
            "the result of " ++ entry.name ++ " names a handle and nothing says how that " ++
                "handle came to exist. Add it to `named_handles` in " ++
                "src/agent/link/adapters.zig: if the call cannot be undone, its slot has to " ++
                "be promised before the call rather than filled after it",
        );
        if (!names and listed) @compileError(
            "`named_handles` classifies " ++ entry.name ++ ", whose result no longer names a " ++
                "handle; remove it so the table cannot outlive its reason",
        );
    }
}

test "every result that names a handle says how the handle came to exist" {
    // The comptime block fails the build otherwise; this records the division,
    // because which of these must promise a slot first is the whole content of
    // the rule.
    var irreversible: usize = 0;
    var existing: usize = 0;
    var mcp: usize = 0;
    for (named_handles) |entry| {
        try testing.expect(entry.reason.len > 40);
        switch (entry.creation) {
            .irreversible => irreversible += 1,
            .names_existing => existing += 1,
            .mcp_step => mcp += 1,
        }
    }
    try testing.expectEqual(@as(usize, 11), named_handles.len);
    try testing.expectEqual(@as(usize, 7), irreversible);
    try testing.expectEqual(@as(usize, 1), existing);
    try testing.expectEqual(@as(usize, 3), mcp);
}

test "naming a handle is detected through the shapes that carry one" {
    // The derivation, not the list: a handle inside a union inside a struct
    // still counts, which is how `begin_run_outcome` was found.
    try testing.expect(namesHandle(handle_table.Id));
    try testing.expect(namesHandle(shapes.SessionRoute));
    try testing.expect(namesHandle(shapes.BeginRunOutcome));
    try testing.expect(namesHandle(?shapes.RunRoute));
    try testing.expect(namesHandle([]const shapes.SkillRestoreBorrow));
    try testing.expect(!namesHandle(u64));
    try testing.expect(!namesHandle(void));
    try testing.expect(!namesHandle(shapes.CloseOutcome));
}

test "a reshaping mirror numbers its error, and a copying one borrows the bytes" {
    const bindings = testBindings();

    // Reshaping: the error becomes the number the registry assigns it, which
    // is the whole reason this one is not a copy.
    const failure = try (resultAdapter(surface.BeginRunFailure).?).apply(bindings, .{
        .err = error.SessionPoisoned,
        .session_disposition = .poisoned,
    });
    try testing.expectEqual(
        @import("error_code.zig").encode(error.SessionPoisoned),
        failure.error_code,
    );
    try testing.expectEqual(control.SessionDisposition.poisoned, failure.session_disposition);

    // Copying: a mirror field may borrow what the original owns, because
    // ownership does not cross -- the original frees the bytes after the
    // response is encoded. Only that direction, and only the same bytes.
    try testing.expect(borrowsFrom([]const u8, []u8));
    try testing.expect(borrowsFrom(?[]const u8, ?[]u8));
    try testing.expect(!borrowsFrom([]u8, []const u8));
    try testing.expect(!borrowsFrom([]const u16, []u8));
    try testing.expect(!borrowsFrom([]const u8, []const u8));
    try testing.expect(!borrowsFrom(u64, u64));

    // The checkpoint description's copier is instantiated by the outcome
    // adapter above it, so every one of its fields has found a rule at
    // comptime. That is not the same as having been run, and it is recorded
    // here as the weaker fact it is: the description's own round trip waits
    // for a dispatcher test that produces a real one.
    try testing.expect(resultAdapter(checkpoint.Description) != null);
    try testing.expect(resultAdapter(checkpoint.Outcome) != null);
}
