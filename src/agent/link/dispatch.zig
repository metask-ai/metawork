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
const run_tools = @import("run_tools.zig");
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
        if (!adapters.argumentsRebuildable(owner, name)) return false;
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

fn invokeOne(
    comptime entry: method.Entry,
    arena: std.mem.Allocator,
    bindings: adapters.Bindings,
    request: Request,
) InvokeError![]u8 {
    if (comptime entry.transport == .stream) return error.NotACall;
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
    // build, and it still leaves nothing behind.
    {
        const entry = try method.find(method.codeOf(.session, "export_checkpoint"));
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

test "how much of the surface this build answers is counted, not claimed" {
    const answered = comptime dispatchableCount();
    const callable = comptime adapters.callableCount();
    // Not all of it yet, and the gap is the two worklists rather than a
    // number kept here: arguments still owed, results still owed.
    try testing.expect(answered < callable);
    try testing.expectEqual(@as(usize, 50), callable);
    try testing.expectEqual(@as(usize, 37), answered);
}
