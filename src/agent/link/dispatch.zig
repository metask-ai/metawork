//! The execution half's answer to one request, and the lifetime rule the
//! effects it performs are held to.
//!
//! Four of the parameters the link still owes are effects this half performs
//! rather than values it receives: the two checkpoint ones, and the image and
//! video bindings. `adapters.zig` records that, and says the obligation they
//! carry has to be checked here rather than promised there. This is that
//! check.
//!
//! The obligation is narrow and it is the worst failure available in this
//! change. A capability is a context pointer and a function pointer. The
//! context has to be built for one call, because what it stands for -- a
//! destination, a reader, a credential source -- is a fact about that call.
//! If anything keeps the pointer after the call returns, it is pointing at
//! memory this half has reused: a cross-process use-after-free that reads as
//! plausible data, which is the failure class this whole change exists to
//! remove rather than relocate.
//!
//! Nothing can stop a callee from storing a pointer it was handed. What can
//! be arranged is that storing one is useless. So a per-call context is a
//! `Frame`, every use of it goes through `borrow`, and the dispatcher retires
//! the frame when the call returns. A retained frame then answers "no" --
//! each capability's own fail-closed value -- instead of reading whatever
//! occupies that stack slot by then. That is a property with a test that
//! fails if it breaks, which is what this had to be instead of a comment.

const std = @import("std");
const contract = @import("agent_contract");
const adapters = @import("adapters.zig");
const envelope = @import("envelope.zig");
const error_code = @import("error_code.zig");
const handle_table = @import("handle_table.zig");
const method = @import("method.zig");
const payload = @import("payload.zig");
const call_frame = @import("call_frame.zig");
const run_tools = @import("run_tools.zig");
const shapes = @import("shapes.zig");
const wire_types = @import("wire_types.zig");

const checkpoint = @import("agent_checkpoint");
const port = contract.port;

pub const DecodeError = envelope.DecodeError || payload.DecodeError;

/// What a request named, once its method and receiver are known.
pub const Request = struct {
    entry: method.Entry,
    receiver: handle_table.Id,
    arguments: []const u8,
};

/// Reads a request far enough to know what it is for, and refuses anything
/// this build does not register.
pub fn classify(bytes: []const u8) DecodeError!Request {
    const decoded = try envelope.decodeRequest(bytes);
    return .{
        .entry = decoded.entry,
        .receiver = decoded.receiver,
        .arguments = decoded.arguments,
    };
}

/// The receiver a request named, resolved to the object the method is called
/// on. Separate from `classify` because resolving is where a stale id becomes
/// a refusal, and that is worth being able to test on its own.
pub fn resolveReceiver(
    bindings: adapters.Bindings,
    request: Request,
) adapters.ResolveError!?Receiver {
    const kind = envelope.receiverOf(request.entry.owner) orelse return null;
    return switch (kind) {
        .session => .{
            .session = bindings.sessions.resolve(request.receiver) orelse
                return error.UnknownHandle,
        },
        .run => .{
            .run = bindings.runs.resolve(request.receiver) orelse
                return error.UnknownHandle,
        },
    };
}

pub const Receiver = union(enum) {
    /// The entry, not the port: a Session method is called through
    /// `held.port`, and the entry also carries the tool capabilities of its
    /// current prepared Run.
    session: *run_tools.HeldSession,
    run: *adapters.BegunRun,
};

// ---------------------------------------------------------------------------
// Answering a request
// ---------------------------------------------------------------------------

pub const InvokeError = error{
    /// A method number this build does not register. `classify` refuses these
    /// first; this exists because `invoke` is reachable on its own.
    UnknownMethod,
    /// A stream method is not a call. The exec half pushes event frames and
    /// the caller's pump answers from what arrived, so a request for one is a
    /// protocol violation rather than something to perform.
    NotACall,
    /// This build cannot yet rebuild one of the method's arguments or encode
    /// its result. Not a refusal of the request -- a statement about this
    /// build, enumerated by `adapters.owedParameters` and
    /// `adapters.owedResults` rather than discovered here.
    NotDispatchable,
} || DecodeError || adapters.ResolveError || adapters.ResultError ||
    std.mem.Allocator.Error;

/// Whether this build can answer a method end to end.
pub fn dispatchable(comptime owner: method.Owner, comptime name: []const u8) bool {
    comptime {
        // A method with a prong does not go through the generic argument
        // chain at all: the prong is what builds its capability, and
        // `invokeOne` reaches it before the generic path. Asking
        // `argumentsRebuildable` about it would report "no" about a method
        // this half answers, which is the kind of understatement that makes
        // a count useless in the other direction.
        if (!hasProng(name) and !adapters.argumentsRebuildable(owner, name)) return false;
        const Fn = @typeInfo(@FieldType(owner.VTable(), name)).pointer.child;
        const Returned = wire_types.Payload(@typeInfo(Fn).@"fn".return_type.?);
        if (Returned == void) return true;
        return adapters.resultAdapter(Returned) != null;
    }
}

/// Answers one request: decode the arguments, call the method on the object
/// the request named, encode what it returned.
///
/// Everything is allocated in `arena`, including the response, so the caller
/// resets it once the bytes are written. Nothing allocated for one request
/// outlives it -- which is the same rule the per-call frames keep, for the
/// same reason.
///
/// The method's own failure is not this function's failure. A `surface.Error`
/// comes back as a response carrying that error's registered number, because
/// it is an answer; the errors above are about the request or this build.
pub fn invoke(
    arena: std.mem.Allocator,
    bindings: adapters.Bindings,
    request: Request,
) InvokeError![]u8 {
    inline for (method.entries) |entry| {
        if (entry.code == request.entry.code) return invokeOne(entry, arena, bindings, request);
    }
    return error.UnknownMethod;
}

/// Whether any of a method's parameters is a capability this half builds
/// rather than a value it decodes. Derived from the dispositions, so a
/// parameter that gains one is a method that needs a prong.
pub fn buildsCapability(comptime owner: method.Owner, comptime name: []const u8) bool {
    comptime {
        const Fn = @typeInfo(@FieldType(owner.VTable(), name)).pointer.child;
        for (@typeInfo(Fn).@"fn".params, 0..) |param, position| {
            if (position == 0) continue;
            if (adapters.dispositionOfType(param.type.?) != null) return true;
        }
        return false;
    }
}

/// The methods with a prong written for them below.
const capability_prongs = [_][]const u8{"export_checkpoint"};

fn hasProng(comptime name: []const u8) bool {
    comptime {
        for (capability_prongs) |listed| {
            if (std.mem.eql(u8, listed, name)) return true;
        }
        return false;
    }
}

// A method that builds a capability must have a prong, and a prong must be
// for a method that builds one. Checked both ways so neither side can drift
// -- a method whose parameter gains a disposition is named here by the
// compiler rather than failing at its first request.
comptime {
    @setEvalBranchQuota(1_000_000);
    for (method.entries) |entry| {
        if (entry.transport == .stream) continue;
        const builds = switch (entry.owner) {
            inline else => |owner| buildsCapability(owner, entry.name),
        };
        if (!builds and hasProng(entry.name)) @compileError(
            "src/agent/link/dispatch.zig has a capability prong for " ++ entry.name ++
                ", whose parameters no longer include one; remove it",
        );
    }
    for (capability_prongs) |name| {
        var found = false;
        for (method.entries) |entry| {
            if (std.mem.eql(u8, entry.name, name)) found = true;
        }
        if (!found) @compileError("the prong for " ++ name ++ " names no registered method");
    }
}

fn invokeOne(
    comptime entry: method.Entry,
    arena: std.mem.Allocator,
    bindings: adapters.Bindings,
    request: Request,
) InvokeError![]u8 {
    if (comptime entry.transport == .stream) return error.NotACall;
    if (comptime hasProng(entry.name)) return exportCheckpoint(arena, bindings, request);
    if (comptime !dispatchable(entry.owner, entry.name)) return error.NotDispatchable;

    const VTable = comptime entry.owner.VTable();
    const Fn = comptime @typeInfo(@FieldType(VTable, entry.name)).pointer.child;
    const Arguments = comptime wire_types.Request(Fn);
    const Returned = comptime wire_types.Payload(@typeInfo(Fn).@"fn".return_type.?);

    // Decoded before anything is resolved, because a malformed payload must
    // not be answered by a call: the cheapest refusals come first and leave
    // nothing behind.
    const wired = try payload.decodeExact(Arguments, arena, request.arguments);

    const receiver = try resolveReceiver(bindings, request);
    const context = contextOf(entry.owner, bindings, receiver);
    const vtable = vtableOf(entry.owner, bindings, receiver);

    var arguments: std.meta.ArgsTuple(Fn) = undefined;
    arguments[0] = context;
    comptime var carried: usize = 0;
    inline for (@typeInfo(Fn).@"fn".params[1..], 1..) |param, position| {
        const Parameter = param.type.?;
        const adapter = comptime adapters.parameterAdapter(Parameter).?;
        if (comptime wire_types.Wire(Parameter) == void) {
            // Nothing was sent for it: the execution half supplies it, as it
            // does the allocator.
            arguments[position] = try adapter.apply(bindings, {});
        } else {
            arguments[position] = try adapter.apply(bindings, wired[carried]);
            comptime carried += 1;
        }
    }

    const returned = @call(.auto, @field(vtable, entry.name), arguments);
    const value = if (comptime isErrorUnion(Fn)) returned catch |err| {
        return failureResponse(arena, err);
    } else returned;

    if (comptime Returned == void) return successResponse(arena, void, {});
    const encoded = try (comptime adapters.resultAdapter(Returned).?).apply(bindings, value);
    return successResponse(arena, @TypeOf(encoded), encoded);
}

/// `export_checkpoint`, whose sink this half opens from the store.
///
/// Written out rather than folded into the generic loop, because what it does
/// is not decoding: it opens a blob, wraps it so the sink handed over belongs
/// to this call, retires that wrapper when the call returns and gives the
/// store's sink back -- in that order, on defers, so a refusal anywhere in
/// between leaves neither behind.
fn exportCheckpoint(
    arena: std.mem.Allocator,
    bindings: adapters.Bindings,
    request: Request,
) InvokeError![]u8 {
    const entry = comptime try method.find(method.codeOf(.session, "export_checkpoint"));
    const Fn = comptime @typeInfo(
        @FieldType(port.SessionPort.VTable, "export_checkpoint"),
    ).pointer.child;
    const Arguments = comptime wire_types.Request(Fn);

    const wired = try payload.decodeExact(Arguments, arena, request.arguments);
    const receiver = (try resolveReceiver(bindings, request)) orelse return error.UnknownHandle;
    const session = receiver.session.port;

    // Composed here, not decoded: the sink has no wire form. The Task comes
    // from the Session this call names and the bound from the call's own
    // limits, which is the whole of what opening a blob needs.
    //
    // An identity that was never filled in refuses the export rather than
    // opening a blob under Task 0, and it is filled in by the route creation
    // that puts a Session in this table -- which `not_forwarded` records as
    // still owed, so today this path refuses and says why.
    // Not an export failure and not `CheckpointIncompatible`, which would say
    // something about the checkpoint: the checkpoint is fine and this build
    // cannot name the Task. `NotDispatchable` is what "this build cannot
    // answer this" already means, and the gap itself is recorded where it
    // belongs -- `create_session_route` is the route creation that would fill
    // the identity in, and it is in `not_forwarded`.
    const identity = receiver.session.identity;
    if (!identity.valid()) return error.NotDispatchable;
    const destination: call_frame.BlobDestination = .{
        .task_id = identity.task_id,
        .hard_bytes = wired[0].hard_bytes,
    };
    const inner = bindings.store.open_sink_fn(bindings.store.context, destination) orelse {
        // The export path's own vocabulary says this, so it is an outcome
        // rather than a transport error: nothing was written, the Session is
        // untouched and reusable, and `io_failed` at the export stage is what
        // "the blob could not be opened" is. Reporting it as a link failure
        // would make the caller treat a Session it can still use as suspect.
        const refused: shapes.CheckpointOutcome = .{ .failure = .{
            .stage = .checkpoint_export,
            .reason = .io_failed,
            .disposition = .reusable,
        } };
        return successResponse(arena, @TypeOf(refused), refused);
    };
    // Given back on every path that does not end in a commit. A commit is
    // the one way the bytes are kept, so "not committed" is the default and
    // has to be undone deliberately.
    var committed = false;
    defer if (!committed) bindings.store.abandon_sink_fn(bindings.store.context, inner);

    var backing = call_frame.ExportSink.Backing.init(.{
        .inner = inner,
        .destination = destination,
    });
    var retired = false;
    // Retired before the store's sink is given back, so the wrapper can never
    // outlive what it writes through.
    defer if (!retired) backing.retire();

    // The sink dropped out of the request, so what used to be fields 2..4 are
    // fields 1..3: limits, then the two ids and the model.
    var outcome = session.vtable.export_checkpoint(
        session.context,
        wired[0],
        call_frame.ExportSink.sink(&backing),
        wired[1],
        wired[2],
        wired[3],
    ) catch |err| return failureResponse(arena, err);
    defer outcome.deinit();

    if (outcome == .success) {
        // Read before the frame dies, because this is the number the store
        // compares against what the export claims and against what reached
        // its own storage. A frame that is somehow already retired cannot
        // say how many bytes passed through it, and a commit that guessed
        // zero would be a record pointing at nothing.
        const observed = if (backing.borrow()) |frame| frame.written else {
            return successResponse(arena, shapes.CheckpointOutcome, .{ .failure = .{
                .stage = .checkpoint_export,
                .reason = .dependency_contract,
                .disposition = .reusable,
            } });
        };

        // The wrapper dies first: a sink the callee kept must not be able to
        // write into a blob that is already named and finished.
        backing.retire();
        retired = true;

        // The Session answered `caller_sink`, which is all it can see. This
        // half opened the blob, and the *store* wrote it -- so the store is
        // what names it. Replacing the arm here, with a name that came back
        // from the commit, is what keeps each answer with the half that can
        // establish it.
        const staged = bindings.store.commit_sink_fn(bindings.store.context, inner, .{
            .destination = destination,
            .exported = outcome.success.checkpoint,
            .observed_bytes = observed,
        }) catch |err| {
            // The export itself ran: the Session did the work and is still
            // usable. What failed is keeping the bytes, so the answer is a
            // failure in the export's own vocabulary rather than a link
            // error, and the two reasons stay apart -- `io_failed` is the
            // machine, `dependency_contract` is the byte counts disagreeing.
            const refused: shapes.CheckpointOutcome = .{ .failure = .{
                .stage = .checkpoint_export,
                .reason = switch (err) {
                    error.CommitFailed => .io_failed,
                    error.ExportMismatch => .dependency_contract,
                },
                .disposition = .reusable,
            } };
            return successResponse(arena, @TypeOf(refused), refused);
        };
        committed = true;
        outcome.success.placement = .{ .own_area = staged };
    }

    const encoded = try (comptime adapters.resultAdapter(contract.CheckpointOutcome).?)
        .apply(bindings, outcome);
    _ = entry;
    return successResponse(arena, @TypeOf(encoded), encoded);
}

fn isErrorUnion(comptime Fn: type) bool {
    return @typeInfo(@typeInfo(Fn).@"fn".return_type.?) == .error_union;
}

fn contextOf(
    comptime owner: method.Owner,
    bindings: adapters.Bindings,
    receiver: ?Receiver,
) ?*anyopaque {
    return switch (owner) {
        .runtime => bindings.runtime.context,
        .session => receiver.?.session.port.context,
        .run => receiver.?.run.context,
        // The control block, which is what a Run's control handle names.
        .run_control => receiver.?.run.control_handle.context,
    };
}

fn vtableOf(
    comptime owner: method.Owner,
    bindings: adapters.Bindings,
    receiver: ?Receiver,
) *const owner.VTable() {
    return switch (owner) {
        .runtime => bindings.runtime.vtable,
        .session => receiver.?.session.port.vtable,
        .run => receiver.?.run.run_vtable,
        .run_control => receiver.?.run.control_handle.vtable.?,
    };
}

fn successResponse(
    arena: std.mem.Allocator,
    comptime T: type,
    value: T,
) std.mem.Allocator.Error![]u8 {
    const body = if (T == void) 0 else payload.encodedSize(T, value);
    const out = try arena.alloc(u8, envelope.header_bytes + body);
    envelope.encodeResponseHeader(out[0..envelope.header_bytes], envelope.ok);
    if (T != void) {
        const written = payload.encode(T, value, out[envelope.header_bytes..]);
        std.debug.assert(written == body);
    }
    return out;
}

fn failureResponse(
    arena: std.mem.Allocator,
    err: error_code.LinkError,
) std.mem.Allocator.Error![]u8 {
    // A failure carries no payload, which `envelope.decodeResponse` enforces
    // from the other side as well.
    const out = try arena.alloc(u8, envelope.header_bytes);
    envelope.encodeResponseHeader(out[0..envelope.header_bytes], error_code.encode(err));
    return out;
}

/// How much of the surface this build answers end to end, counted rather than
/// claimed. It reaches `method.entries.len` minus the stream methods when
/// both worklists are empty.
pub fn dispatchableCount() usize {
    comptime {
        @setEvalBranchQuota(1_000_000);
        var count: usize = 0;
        for (method.entries) |entry| {
            if (entry.transport == .stream) continue;
            const ok = switch (entry.owner) {
                inline else => |owner| dispatchable(owner, entry.name),
            };
            if (ok) count += 1;
        }
        return count;
    }
}

const testing = std.testing;

test "a request is classified by the registry, and an unregistered one is refused" {
    const entry = try method.find(method.codeOf(.runtime, "has_pending_events"));
    var bytes: [envelope.header_bytes]u8 = undefined;
    envelope.encodeRequestHeader(&bytes, entry, .none);

    const classified = try classify(&bytes);
    try testing.expectEqualStrings("has_pending_events", classified.entry.name);
    try testing.expect(!classified.receiver.valid());
    try testing.expectEqual(@as(usize, 0), classified.arguments.len);

    var unknown: [envelope.header_bytes]u8 = undefined;
    std.mem.writeInt(u16, &unknown, 0x7777, .little);
    try testing.expectError(error.UnknownMethod, classify(&unknown));
}

test "a receiver is resolved through its table, and a stale id is refused" {
    var sessions = try handle_table.Table(run_tools.HeldSession).init(testing.allocator, 1);
    defer sessions.deinit();
    var runs = try handle_table.Table(adapters.BegunRun).init(testing.allocator, 1);
    defer runs.deinit();
    var leases = try handle_table.Table(@import("agent_catalog").Lease).init(testing.allocator, 1);
    defer leases.deinit();
    var skill_restore = try handle_table.Table(port.SkillRestoreInputs).init(testing.allocator, 1);
    defer skill_restore.deinit();
    var session_restore = try handle_table.Table(port.SessionRestoreInputs).init(testing.allocator, 1);
    defer session_restore.deinit();
    var selections = try handle_table.Table(@import("agent_mcp_catalog").Selection).init(testing.allocator, 1);
    defer selections.deinit();
    const bindings: adapters.Bindings = .{
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
    const entry = try method.find(method.codeOf(.session, "set_model"));

    var bytes: [envelope.header_bytes + envelope.receiver_bytes]u8 = undefined;
    envelope.encodeRequestHeader(&bytes, entry, id);
    const request = try classify(&bytes);
    const receiver = try resolveReceiver(bindings, request);
    try testing.expect(receiver.? == .session);

    // A runtime method names no receiver, and resolving one answers nothing
    // rather than reaching into a table.
    const runtime_entry = try method.find(method.codeOf(.runtime, "has_pending_events"));
    var runtime_bytes: [envelope.header_bytes]u8 = undefined;
    envelope.encodeRequestHeader(&runtime_bytes, runtime_entry, .none);
    try testing.expect(try resolveReceiver(bindings, try classify(&runtime_bytes)) == null);

    _ = sessions.take(id);
    try testing.expectError(error.UnknownHandle, resolveReceiver(bindings, request));
}

test "every registered method's receiver resolves through a table this half has" {
    // The pairing is a property of the owner, so it is checked over the whole
    // registry rather than per call site: a method whose receiver had no table
    // would fail at its first request instead of here.
    inline for (method.entries) |entry| {
        const kind = envelope.receiverOf(entry.owner);
        switch (entry.owner) {
            .runtime => try testing.expect(kind == null),
            .session => try testing.expectEqual(envelope.Receiver.session, kind.?),
            .run, .run_control => try testing.expectEqual(envelope.Receiver.run, kind.?),
        }
    }
    _ = wire_types;
}

/// A Session whose one driven method records what it was given. The rest of
/// the vtable is left undefined on purpose: a test that called one of those
/// would crash rather than quietly pass, which is the behaviour wanted from a
/// fixture that is deliberately partial.
const FakeSession = struct {
    model: []const u8 = "",
    fail: bool = false,

    fn setModel(context: ?*anyopaque, model: []const u8) contract.surface.Error!void {
        const self: *FakeSession = @ptrCast(@alignCast(context.?));
        if (self.fail) return error.SessionPoisoned;
        self.model = model;
    }

    fn port(self: *FakeSession, vtable: *port_namespace.SessionPort.VTable) port_namespace.SessionPort {
        vtable.set_model = setModel;
        return .{ .context = self, .vtable = vtable };
    }
};

const port_namespace = port;

const Harness = struct {
    sessions: handle_table.Table(run_tools.HeldSession),
    runs: handle_table.Table(adapters.BegunRun),
    leases: handle_table.Table(@import("agent_catalog").Lease),
    skill_restore: handle_table.Table(port.SkillRestoreInputs),
    session_restore: handle_table.Table(port.SessionRestoreInputs),
    selections: handle_table.Table(@import("agent_mcp_catalog").Selection),

    fn init() !Harness {
        return .{
            .sessions = try handle_table.Table(run_tools.HeldSession).init(testing.allocator, 2),
            .runs = try handle_table.Table(adapters.BegunRun).init(testing.allocator, 2),
            .leases = try handle_table.Table(@import("agent_catalog").Lease)
                .init(testing.allocator, 2),
            .skill_restore = try handle_table.Table(port.SkillRestoreInputs)
                .init(testing.allocator, 2),
            .session_restore = try handle_table.Table(port.SessionRestoreInputs)
                .init(testing.allocator, 2),
            .selections = try handle_table.Table(@import("agent_mcp_catalog").Selection)
                .init(testing.allocator, 2),
        };
    }

    fn deinit(self: *Harness) void {
        self.sessions.deinit();
        self.runs.deinit();
        self.leases.deinit();
        self.skill_restore.deinit();
        self.session_restore.deinit();
        self.selections.deinit();
    }

    fn bindings(self: *Harness) adapters.Bindings {
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

    fn live(self: *Harness) usize {
        var total: usize = 0;
        for (adapters.liveCounts(self.bindings())) |entry| total += entry.live;
        return total;
    }
};

/// One `set_model` request, built the way the caller's stub will build it.
fn setModelRequest(
    arena: std.mem.Allocator,
    receiver: handle_table.Id,
    model: []const u8,
    truncate: bool,
) ![]u8 {
    const entry = try method.find(method.codeOf(.session, "set_model"));
    const Fn = @typeInfo(@FieldType(port.SessionPort.VTable, "set_model")).pointer.child;
    const Arguments = wire_types.Request(Fn);
    const arguments: Arguments = .{model};

    const header = envelope.requestHeaderBytes(entry.owner);
    const body = payload.encodedSize(Arguments, arguments);
    const out = try arena.alloc(u8, header + body);
    envelope.encodeRequestHeader(out[0..header], entry, receiver);
    _ = payload.encode(Arguments, arguments, out[header..]);
    return if (truncate) out[0 .. out.len - 1] else out;
}

test "a request is answered by the object it named" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var harness = try Harness.init();
    defer harness.deinit();
    var fake: FakeSession = .{};
    var vtable: port.SessionPort.VTable = undefined;
    var held = run_tools.HeldSession.init(fake.port(&vtable));
    const id = try harness.sessions.insert(&held);

    const bytes = try setModelRequest(arena, id, "a-model", false);
    const response = try invoke(arena, harness.bindings(), try classify(bytes));

    // Success, and a method returning `Error!void` carries no payload.
    switch (try envelope.decodeResponse(response)) {
        .value => |value| try testing.expectEqual(@as(usize, 0), value.len),
        .failure => return error.ExpectedValue,
    }
    try testing.expectEqualStrings("a-model", fake.model);

    _ = harness.sessions.take(id);
}

test "the method's own failure is an answer, not the dispatcher's failure" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var harness = try Harness.init();
    defer harness.deinit();
    var fake: FakeSession = .{ .fail = true };
    var vtable: port.SessionPort.VTable = undefined;
    var held = run_tools.HeldSession.init(fake.port(&vtable));
    const id = try harness.sessions.insert(&held);

    const bytes = try setModelRequest(arena, id, "a-model", false);
    const response = try invoke(arena, harness.bindings(), try classify(bytes));
    switch (try envelope.decodeResponse(response)) {
        .value => return error.ExpectedFailure,
        .failure => |err| try testing.expectEqual(
            @as(anyerror, error.SessionPoisoned),
            err,
        ),
    }
    // The table is untouched: a refused call releases nothing.
    try testing.expectEqual(@as(usize, 1), harness.live());
    _ = harness.sessions.take(id);
}

test "each refusal leaves nothing behind" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var harness = try Harness.init();
    defer harness.deinit();
    var fake: FakeSession = .{};
    var vtable: port.SessionPort.VTable = undefined;
    var held = run_tools.HeldSession.init(fake.port(&vtable));
    const id = try harness.sessions.insert(&held);
    const baseline = harness.live();

    // A payload that stops short. Refused before anything is resolved, which
    // is the order: the cheapest refusals first.
    {
        const bytes = try setModelRequest(arena, id, "a-model", true);
        try testing.expectError(
            error.Truncated,
            invoke(arena, harness.bindings(), try classify(bytes)),
        );
        try testing.expectEqual(baseline, harness.live());
        try testing.expectEqualStrings("", fake.model);
    }

    // A receiver that no longer exists. The call is not attempted.
    {
        const stale = handle_table.Id{ .slot = id.slot, .generation = id.generation + 4 };
        const bytes = try setModelRequest(arena, stale, "a-model", false);
        try testing.expectError(
            error.UnknownHandle,
            invoke(arena, harness.bindings(), try classify(bytes)),
        );
        try testing.expectEqual(baseline, harness.live());
        try testing.expectEqualStrings("", fake.model);
    }

    // A method this build cannot answer end to end. A statement about the
    // build, and it still leaves nothing behind. `prepare_run_with_tools`
    // takes capabilities with no prong yet, and the prong check runs before
    // the generic path, so this is the refusal it gets.
    {
        const entry = try method.find(method.codeOf(.session, "prepare_run_with_tools"));
        const header = envelope.requestHeaderBytes(entry.owner);
        const bytes = try arena.alloc(u8, header);
        envelope.encodeRequestHeader(bytes, entry, id);
        try testing.expectError(
            error.NotDispatchable,
            invoke(arena, harness.bindings(), try classify(bytes)),
        );
        try testing.expectEqual(baseline, harness.live());
    }

    // A stream method is not a call at all.
    {
        const entry = try method.find(method.codeOf(.runtime, "take_event"));
        const header = envelope.requestHeaderBytes(entry.owner);
        const bytes = try arena.alloc(u8, header);
        envelope.encodeRequestHeader(bytes, entry, .none);
        try testing.expectError(
            error.NotACall,
            invoke(arena, harness.bindings(), try classify(bytes)),
        );
        try testing.expectEqual(baseline, harness.live());
    }

    // And a number this build does not register never becomes a request.
    {
        var unknown: [envelope.header_bytes]u8 = undefined;
        std.mem.writeInt(u16, &unknown, 0x7abc, .little);
        try testing.expectError(error.UnknownMethod, classify(&unknown));
        try testing.expectEqual(baseline, harness.live());
    }

    _ = harness.sessions.take(id);
}

/// A store that records what was written and can refuse to open.
///
/// It also names the blobs it commits, which is the point of the shape: the
/// name is a store's to choose, and the dispatcher used to format one here.
const Blobs = struct {
    buffer: [64]u8 = undefined,
    written: usize = 0,
    opened: usize = 0,
    committed: usize = 0,
    abandoned: usize = 0,
    /// Set to make a commit fail the way a rename or a sync would.
    refuse_commit: bool = false,

    fn store(self: *Blobs) call_frame.BlobStore {
        var value = call_frame.BlobStore.empty;
        value.context = self;
        value.open_sink_fn = openSink;
        value.commit_sink_fn = commitSink;
        value.abandon_sink_fn = abandonSink;
        return value;
    }

    fn openSink(context: ?*anyopaque, _: call_frame.BlobDestination) ?checkpoint.Sink {
        const self: *Blobs = @ptrCast(@alignCast(context.?));
        self.opened += 1;
        return .{ .context = self, .write_fn = write };
    }

    fn commitSink(
        context: ?*anyopaque,
        _: checkpoint.Sink,
        record: call_frame.BlobCommit,
    ) call_frame.CommitError!checkpoint.StagedBlob {
        const self: *Blobs = @ptrCast(@alignCast(context.?));
        if (self.refuse_commit) return error.CommitFailed;
        // The net: three numbers that must agree -- what the export claims,
        // what passed through the call's wrapper, and what reached storage.
        if (record.exported.total_bytes != record.observed_bytes) return error.ExportMismatch;
        if (record.observed_bytes != self.written) return error.ExportMismatch;
        self.committed += 1;
        var storage: [checkpoint.StagedBlob.max_name_bytes]u8 = undefined;
        const text = std.fmt.bufPrint(&storage, "{d}/{d}.ckpt", .{
            record.destination.task_id,
            record.exported.generation,
        }) catch return error.CommitFailed;
        return checkpoint.StagedBlob.from(text) catch error.CommitFailed;
    }

    fn abandonSink(context: ?*anyopaque, _: checkpoint.Sink) void {
        const self: *Blobs = @ptrCast(@alignCast(context.?));
        self.abandoned += 1;
    }

    fn write(context: ?*anyopaque, bytes: []const u8) checkpoint.SinkWriteResult {
        const self: *Blobs = @ptrCast(@alignCast(context.?));
        if (self.written + bytes.len > self.buffer.len) return .io_failed;
        @memcpy(self.buffer[self.written..][0..bytes.len], bytes);
        self.written += bytes.len;
        return .ok;
    }
};

/// A Session that writes through the sink it was handed and then refuses.
const Exporter = struct {
    bytes: []const u8,

    fn exportCheckpointImpl(
        context: ?*anyopaque,
        _: contract.CheckpointLimits,
        sink: checkpoint.Sink,
        _: u64,
        _: u64,
        _: []const u8,
    ) contract.surface.Error!checkpoint.Outcome {
        const self: *Exporter = @ptrCast(@alignCast(context.?));
        _ = sink.write_fn(sink.context, self.bytes);
        // The failure arm, so the test needs no twenty-field description to
        // build. The success arm's encoding is the generic mirror, which is
        // instantiated at comptime by the outcome adapter.
        return .{ .failure = .{
            .stage = .checkpoint_export,
            .reason = .core_error,
            .disposition = .reusable,
        } };
    }

    fn port(self: *Exporter, vtable: *port_namespace.SessionPort.VTable) port_namespace.SessionPort {
        vtable.export_checkpoint = exportCheckpointImpl;
        return .{ .context = self, .vtable = vtable };
    }
};

/// A Session whose export succeeds, so the commit path runs.
///
/// `claimed_bytes` is separate from what it writes on purpose: the two
/// disagreeing is the case the store's net is for, and a double that could
/// only ever agree would never reach it.
const SucceedingExporter = struct {
    bytes: []const u8,
    claimed_bytes: ?u64 = null,
    generation: u64 = 12,

    fn exportCheckpointImpl(
        context: ?*anyopaque,
        _: contract.CheckpointLimits,
        sink: checkpoint.Sink,
        _: u64,
        _: u64,
        _: []const u8,
    ) contract.surface.Error!checkpoint.Outcome {
        const self: *SucceedingExporter = @ptrCast(@alignCast(context.?));
        if (sink.write_fn(sink.context, self.bytes) != .ok) return error.CoreCallFailed;
        const allocator = testing.allocator;
        return .{
            .success = .{
                .checkpoint = .{
                    .generation = self.generation,
                    .total_bytes = self.claimed_bytes orelse self.bytes.len,
                    .chunk_count = 1,
                    .digest = @splat(0xab),
                },
                // What the Session can see, and no more: it wrote through the
                // sink it was handed and knows nothing about what that sink was.
                .placement = .caller_sink,
                .description = .{
                    .allocator = allocator,
                    .session_id = allocator.dupe(u8, "session") catch return error.CoreCallFailed,
                    .origin = .fresh,
                    .lifecycle = .idle,
                    .registered = true,
                    .last_run_id = 7,
                    .last_compact_id = 0,
                    .checkpoint_generation = self.generation,
                    .permission_mode = .default,
                    .policy_generation = 1,
                    .catalog_generation = 1,
                    .model = allocator.dupe(u8, "model") catch return error.CoreCallFailed,
                    .message_count = 2,
                    .compact_boundary = 0,
                    .skill_catalog_revision = null,
                    .mcp_selection_fingerprint = allocator.dupe(u8, "fingerprint") catch return error.CoreCallFailed,
                    .budget_hard_bytes = 32,
                    .budget_soft_bytes = 16,
                    .durable_usage_bytes = 8,
                    .available_bytes = 24,
                    .compaction_recommended = false,
                    .budget_outcome = .none,
                    .required_bytes = 0,
                    .restore_health = .complete,
                    .invalidated_skill_authority = 0,
                    .invalidated_permission_rules = 0,
                    .invalidated_mcp_bindings = 0,
                },
            },
        };
    }

    fn port(self: *SucceedingExporter, vtable: *port_namespace.SessionPort.VTable) port_namespace.SessionPort {
        vtable.export_checkpoint = exportCheckpointImpl;
        return .{ .context = self, .vtable = vtable };
    }
};

/// Drives one successful export against `blobs` and returns the decoded
/// outcome. Written once because three tests differ only in what they set on
/// the two doubles.
fn exportThrough(
    arena: std.mem.Allocator,
    harness: *Harness,
    blobs: *Blobs,
    exporter: *SucceedingExporter,
) !shapes.CheckpointOutcome {
    var vtable: port_namespace.SessionPort.VTable = undefined;
    var held = run_tools.HeldSession.initFor(
        exporter.port(&vtable),
        .{ .task_id = 3, .binding_epoch = 1 },
    );
    const id = try harness.sessions.insert(&held);
    defer _ = harness.sessions.take(id);

    var bindings = harness.bindings();
    bindings.store = blobs.store();
    const response = try invoke(arena, bindings, try classify(try exportRequest(arena, id)));
    return switch (try envelope.decodeResponse(response)) {
        .failure => error.ExpectedValue,
        .value => |bytes| try payload.decodeExact(shapes.CheckpointOutcome, arena, bytes),
    };
}

test "a committed export is named by the store that wrote it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var harness = try Harness.init();
    defer harness.deinit();
    var blobs: Blobs = .{};
    var exporter: SucceedingExporter = .{ .bytes = "sixteen-bytes-ok" };

    const decoded = try exportThrough(arena, &harness, &blobs, &exporter);

    try testing.expectEqual(@as(usize, 1), blobs.committed);
    try testing.expectEqual(@as(usize, 0), blobs.abandoned);
    // The name came back from the commit. The dispatcher formatted this
    // itself until now, which put one naming rule in two places -- and the
    // half that holds the bytes was not one of them.
    try testing.expectEqualStrings("3/12.ckpt", decoded.success.placement.own_area.name());
}

test "a commit that fails is an export failure and keeps nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var harness = try Harness.init();
    defer harness.deinit();
    var blobs: Blobs = .{ .refuse_commit = true };
    var exporter: SucceedingExporter = .{ .bytes = "sixteen-bytes-ok" };

    const decoded = try exportThrough(arena, &harness, &blobs, &exporter);

    // A `void` close could not report this at all: the export succeeded and
    // the bytes were lost, and the caller would have been told it has a
    // checkpoint.
    try testing.expectEqual(@as(usize, 0), blobs.committed);
    try testing.expectEqual(@as(usize, 1), blobs.abandoned);
    try testing.expectEqual(checkpoint.FailureReason.io_failed, decoded.failure.reason);
    try testing.expectEqual(
        checkpoint.OperationDisposition.reusable,
        decoded.failure.disposition,
    );
}

test "an export whose byte count disagrees with what arrived is refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var harness = try Harness.init();
    defer harness.deinit();
    var blobs: Blobs = .{};
    // Claims more than it wrote. This is the net Product's `Writer.commit`
    // has on its side and the execution half had nothing of -- although
    // `ExportSink` was counting the bytes the whole time.
    var exporter: SucceedingExporter = .{ .bytes = "sixteen-bytes-ok", .claimed_bytes = 99 };

    const decoded = try exportThrough(arena, &harness, &blobs, &exporter);

    try testing.expectEqual(@as(usize, 0), blobs.committed);
    try testing.expectEqual(@as(usize, 1), blobs.abandoned);
    // Told apart from an I/O fault: this one is the contract, not the
    // machine.
    try testing.expectEqual(
        checkpoint.FailureReason.dependency_contract,
        decoded.failure.reason,
    );
}

fn exportRequest(arena: std.mem.Allocator, receiver: handle_table.Id) ![]u8 {
    const entry = try method.find(method.codeOf(.session, "export_checkpoint"));
    const Fn = @typeInfo(@FieldType(port.SessionPort.VTable, "export_checkpoint")).pointer.child;
    const Arguments = wire_types.Request(Fn);
    const arguments: Arguments = .{
        .{
            .hard_bytes = 32,
            .max_section_bytes = 32,
            .max_string_bytes = 32,
            .max_messages = 4,
            .max_blocks_per_message = 4,
            .chunk_bytes = 16,
        },
        7,
        8,
        "model",
    };
    const header = envelope.requestHeaderBytes(entry.owner);
    const body = payload.encodedSize(Arguments, arguments);
    const out = try arena.alloc(u8, header + body);
    envelope.encodeRequestHeader(out[0..header], entry, receiver);
    _ = payload.encode(Arguments, arguments, out[header..]);
    return out;
}

test "an export writes its bytes into the store and answers in its own vocabulary" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var harness = try Harness.init();
    defer harness.deinit();
    var blobs: Blobs = .{};
    var exporter: Exporter = .{ .bytes = "checkpoint-bytes" };
    var vtable: port.SessionPort.VTable = undefined;
    var held = run_tools.HeldSession.initFor(
        exporter.port(&vtable),
        .{ .task_id = 3, .binding_epoch = 1 },
    );
    const id = try harness.sessions.insert(&held);

    var bindings = harness.bindings();
    bindings.store = blobs.store();

    const response = try invoke(arena, bindings, try classify(try exportRequest(arena, id)));

    // The bytes went through this call's sink into the store, and because the
    // Session refused, nothing was committed: the blob was abandoned. The
    // single `void` close this replaces could not have told those apart.
    try testing.expectEqual(@as(usize, 1), blobs.opened);
    try testing.expectEqual(@as(usize, 0), blobs.committed);
    try testing.expectEqual(@as(usize, 1), blobs.abandoned);
    try testing.expectEqualStrings("checkpoint-bytes", blobs.buffer[0..blobs.written]);

    // The answer is the method's outcome, not a transport failure.
    switch (try envelope.decodeResponse(response)) {
        .failure => return error.ExpectedValue,
        .value => |bytes| {
            const decoded = try payload.decodeExact(shapes.CheckpointOutcome, arena, bytes);
            try testing.expectEqual(checkpoint.FailureReason.core_error, decoded.failure.reason);
            try testing.expectEqual(
                checkpoint.OperationDisposition.reusable,
                decoded.failure.disposition,
            );
        },
    }
    _ = harness.sessions.take(id);
}

test "a store that cannot open the blob is an export failure, not a link failure" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var harness = try Harness.init();
    defer harness.deinit();
    var exporter: Exporter = .{ .bytes = "unreached" };
    var vtable: port.SessionPort.VTable = undefined;
    var held = run_tools.HeldSession.initFor(
        exporter.port(&vtable),
        .{ .task_id = 3, .binding_epoch = 1 },
    );
    const id = try harness.sessions.insert(&held);

    // `empty` refuses to open. The Session is untouched and still usable, so
    // the answer says `reusable` -- reporting a link failure would make the
    // caller treat a Session it can still use as suspect.
    const response = try invoke(
        arena,
        harness.bindings(),
        try classify(try exportRequest(arena, id)),
    );
    switch (try envelope.decodeResponse(response)) {
        .failure => return error.ExpectedValue,
        .value => |bytes| {
            const decoded = try payload.decodeExact(shapes.CheckpointOutcome, arena, bytes);
            try testing.expectEqual(checkpoint.FailureReason.io_failed, decoded.failure.reason);
            try testing.expectEqual(
                checkpoint.OperationDisposition.reusable,
                decoded.failure.disposition,
            );
        },
    }
    _ = harness.sessions.take(id);
}

test "how much of the surface this build answers is counted, not claimed" {
    const answered = comptime dispatchableCount();
    const callable = comptime adapters.callableCount();
    // Not all of it yet, and the gap is the two worklists rather than a
    // number kept here: arguments still owed, results still owed.
    try testing.expect(answered < callable);
    try testing.expectEqual(@as(usize, 50), callable);
    try testing.expectEqual(@as(usize, 38), answered);

    // One of those is answered by a prong rather than by the generic chain,
    // and `dispatchable` says so: `export_checkpoint`'s capability is built
    // here, so asking `argumentsRebuildable` about it would report "no"
    // about a method this half does answer.
    try testing.expect(comptime !adapters.argumentsRebuildable(.session, "export_checkpoint"));
    try testing.expect(comptime dispatchable(.session, "export_checkpoint"));
}
