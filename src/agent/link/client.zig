//! The caller's half of a call: send the request, wait, read the answer back
//! into the port's own types.
//!
//! This is the fourth direction. The execution half rebuilds arguments it was
//! sent (`adapters.parameterAdapter`) and encodes what the method returned
//! (`adapters.resultAdapter`); this side encodes the arguments it is called
//! with and reads the answer back (`inbound.zig`). The four are not
//! symmetric, which is why each is counted on its own.
//!
//! ## Who owns what comes back
//!
//! One rule, and it is the port's own: whatever the port type says the caller
//! owns, this half owns a copy of, allocated from its own allocator and freed
//! by that type's existing `deinit`. `control.TerminalResult` is the one that
//! settles it -- its `deinit` frees `diagnostic_storage` through its own
//! `allocator` field, so this half allocates and Product frees exactly as it
//! does in process. Nothing about ownership changes shape, and no contract
//! moves.
//!
//! Where the port type borrows, the response bytes are borrowed for the
//! length of the call and nothing is allocated.
//!
//! ## What a gone link answers
//!
//! `unreachability.zig` says every port answer can say the link is gone, and
//! each stub answers with what that file names: the declared value for a type
//! that declares one, and `DependencyUnreachable` for an error union -- added
//! because no existing member means it and reusing one would assert something
//! false.

const std = @import("std");
const contract = @import("agent_contract");
const channel = @import("channel.zig");
const envelope = @import("envelope.zig");
const error_code = @import("error_code.zig");
const handle_repr = @import("handle_repr.zig");
const handle_table = @import("handle_table.zig");
const method = @import("method.zig");
const payload = @import("payload.zig");
const pending = @import("pending.zig");
const wire_types = @import("wire_types.zig");

const port = contract.port;

/// The boxes this half names far objects by, typed to this half.
pub const Boxes = handle_repr.Boxes(Client);

/// One box: the whole of both handle representations. A `boxed` handle's
/// pointer is this record's address; an `in_context` handle's port value
/// carries that address in its own `context`.
pub const Box = Boxes.Slot;

/// The vtables this half installs in the port values it hands out.
///
/// Held as data rather than reached by import, because the stubs are what
/// fill them and the stubs are what reads the answers back: a direct import
/// either way round would be a cycle. Passing them in also means a test can
/// bind a vtable of its own without the stub module in the way.
pub const Vtables = struct {
    session: *const port.SessionPort.VTable,
    run: *const port.RunPort.VTable,
    run_control: *const port.RunControl.VTable,
    runtime: *const port.RuntimePort.VTable,
};

/// Why this half considers the link no longer usable.
///
/// Every one of these produces the same answer to Product -- the link did not
/// carry the call, so the method's restricting value is what it gets. What
/// differs is what the *supervisor* should do, and it cannot read a return
/// value, so the condition is recorded here where it happens.
///
/// A single failure model is what makes this an enum rather than a boolean:
/// the action is always to end the execution process, but the reason belongs
/// in the fault record that explains why a user's Run stopped.
pub const LinkFault = enum(u8) {
    none = 0,
    /// The outbound queue refused the send, or the correlation table was full
    /// of calls someone is still waiting on. The peer is answering; this half
    /// could not hand it anything more.
    send_refused = 1,
    /// The correlation table was full of calls the peer owes answers for.
    /// Waiting does not help: what is missing is the peer's answers.
    peer_unsettled = 2,
    /// Correlations ran out. Not wrapped, by `pending.zig`'s own rule, so the
    /// link ends rather than matching a stale answer to a live call.
    correlations_exhausted = 3,
    /// A frame arrived that this build cannot decode, which means the peer is
    /// not this build.
    unreadable = 4,
    /// Events arrived faster than this half's consumer drained them. Not a
    /// refusal to carry one: an event dropped here shortens a conversation
    /// Product then commits as complete, which nothing downstream can tell
    /// from a finished one.
    events_overflowed = 5,
};

/// Where this half's answers to the four `stream` methods come from.
///
/// They are not calls. The execution half pushes `event` frames and this half
/// answers from what has already arrived, which is what the registry's
/// `stream` classification means -- and the licence that makes it honest is
/// narrow: the buffer holds nothing except what the far side sent, so the
/// answer is still the far side's fact.
///
/// The signatures are read off the vtable rather than written out, so a
/// method whose shape changes changes here too. What fills them is not the
/// link's: parsing a Core event is the Agent's own decoder, and this module
/// deliberately links no AgentCore archive.
pub const EventSource = struct {
    context: ?*anyopaque,
    take_fn: @FieldType(port.RuntimePort.VTable, "take_event"),
    has_pending_fn: @FieldType(port.RuntimePort.VTable, "has_pending_events"),
    pending_count_fn: @FieldType(port.RuntimePort.VTable, "pending_event_count"),
    notify_fn: @FieldType(port.RuntimePort.VTable, "notify_event_consumer"),
};

/// The caller's half of one link.
pub const Client = struct {
    /// Owns what comes back, per the rule above.
    allocator: std.mem.Allocator,
    outbound: *channel.Outbound,
    pending: *pending.Table,
    boxes: Boxes,
    vtables: Vtables,
    /// First writer wins, because the first fault is the one that explains
    /// the rest: a peer that stopped answering fills the table, and every
    /// later call then reports a refused send. Plain atomics rather than a
    /// callback: this is read by a supervisor on another thread, and calling
    /// into one from inside a stub would re-enter the link from a thread that
    /// may be holding the Session.
    fault: std.atomic.Value(u8) = .init(@intFromEnum(LinkFault.none)),
    /// Where the four `stream` methods are answered from. `null` is a
    /// composition that installed no buffer, which is a wiring mistake rather
    /// than a condition -- the stubs panic, because answering "no events"
    /// would read as a drained stream.
    events: ?EventSource = null,

    /// Two-phase, because the boxes carry the way back to the link they
    /// belong to and that is this value's own address.
    pub fn init(
        self: *Client,
        io: std.Io,
        allocator: std.mem.Allocator,
        outbound: *channel.Outbound,
        slots: *pending.Table,
        vtables: Vtables,
        box_count: usize,
    ) std.mem.Allocator.Error!void {
        self.* = .{
            .allocator = allocator,
            .outbound = outbound,
            .pending = slots,
            .boxes = undefined,
            .vtables = vtables,
        };
        self.boxes = try Boxes.init(io, allocator, box_count, self);
    }

    pub fn deinit(self: *Client) void {
        self.boxes.deinit();
    }

    /// Records a fault, keeping the first one, and ends the link in the same
    /// step.
    ///
    /// Recording alone was not enough and the gap was behaviour, not
    /// bookkeeping: a stub that answered "the dependency is unreachable"
    /// while the link was still carrying calls would hand Product a poisoned
    /// Session and then let the next call reach that same Session. No caller
    /// may read a gone answer from a link that is still working, so the
    /// correlation table closes here -- every waiter is released and every
    /// later call answers without sending.
    ///
    /// Never `.none`: clearing a fault would be a second kind of event, and
    /// nothing in a single failure model recovers a link in place. Whoever
    /// owns the process reads `faulted` and ends it; this only stops the link
    /// from carrying anything further in the meantime.
    pub fn recordFault(self: *Client, reason: LinkFault) void {
        std.debug.assert(reason != .none);
        _ = self.fault.cmpxchgStrong(
            @intFromEnum(LinkFault.none),
            @intFromEnum(reason),
            .release,
            .acquire,
        );
        self.pending.close();
    }

    /// What this half has concluded about the link, for the supervisor.
    /// `.none` means no call has been stopped by the link yet -- not that the
    /// peer is alive, which only the peer's own exit can tell anyone.
    pub fn faulted(self: *const Client) LinkFault {
        return @enumFromInt(self.fault.load(.acquire));
    }

    /// Installs the buffer the `stream` methods answer from. Separate from
    /// `init` because the buffer belongs to the composition above this one:
    /// it holds parsed Core events, and this module parses none.
    pub fn bindEvents(self: *Client, source: EventSource) void {
        self.events = source;
    }

    /// The link a port value belongs to, from the context it carries.
    ///
    /// The cast is on trust, and it is worth being exact about what that does
    /// and does not mean. A stub reached through an `in_context` port value
    /// receives nothing but the context pointer: there is no second field to
    /// anchor on, so a pointer this half never issued cannot be detected
    /// here. That is not a gap the link introduces -- in process the same
    /// context is an implementation pointer and a wrong one is already
    /// undefined behaviour, so Product handing back a value it was not given
    /// is the same bug with the same consequence either way.
    ///
    /// What the box *does* buy is the case that is not a Product bug: a
    /// handle released and then used again. The box is still a box, so the
    /// read is a read of live memory, and its id has been cleared -- so the
    /// next step refuses it. One allocation per handle would have made that a
    /// use-after-free instead.
    pub fn linkFrom(context: ?*anyopaque) *Client {
        const box: *Box = @ptrCast(@alignCast(context.?));
        return box.link;
    }

    /// The id a port value's context names, checked against this half's own
    /// table rather than read straight out of the box.
    pub fn receiverFrom(context: ?*anyopaque) Boxes.Error!handle_table.Id {
        const box: *Box = @ptrCast(@alignCast(context.?));
        return box.link.boxes.borrow(box);
    }
};

/// Why a call did not produce an answer, split by whether the request had
/// already been handed to the peer. Never returned to Product as such: each
/// stub turns it into what its own return type can say.
///
/// The split is the whole reason these are two sets. Before the handover the
/// request is still this half's to throw away: nothing was performed, the far
/// side's state is unchanged, and "it did not happen, ask again" is a true
/// thing to say. After the handover the request is the peer's and may already
/// have been carried out, so a failure here is not a refusal of the call --
/// it is the loss of its answer. Telling the caller it did not happen would
/// be a wrong answer shaped exactly like a right one: an input submitted
/// twice, a Session reported reusable after it was closed.
///
/// So `AfterHandover` has no `OutOfMemory` and no `Busy`, and that absence is
/// the mechanism rather than a note. `collect` below is declared to return
/// only this set, so an allocation inside it cannot be `try`-ed out: the
/// compiler demands it be named as `AnswerLost` instead. A stub reading
/// `AnswerLost` therefore knows, from the type and not from a convention,
/// that it must not answer "no room, ask again".
pub const BeforeHandover = error{
    /// Nothing is there, or nothing will be.
    Unreachable,
    /// There is someone, but not room right now.
    Busy,
} || std.mem.Allocator.Error;

pub const AfterHandover = error{
    /// The link closed with the answer still outstanding. The request may
    /// have been performed first; this says only that no answer is coming.
    Unreachable,
    /// An answer arrived that this build does not encode, which means the
    /// peer is not this build.
    Unreadable,
    /// An answer arrived and this half could not keep it.
    ///
    /// The peer has already done the work. What failed is an allocation on
    /// the way to reading its answer, so the honest fact is that the answer
    /// is gone, not that the call was refused -- and not that this half ran
    /// out of memory *doing* it, which is what the method's own `OutOfMemory`
    /// would say.
    AnswerLost,
};

pub const CallError = BeforeHandover || AfterHandover;

/// The error names a stub reads as "this call was not performed".
///
/// `stubs.stoppedBy` classifies each of these as `.no_room` or
/// `.out_of_memory`, and both of those answer the caller that the far side's
/// state is unchanged and it may ask again. That is true only before the
/// handover, so this is the list every post-handover set is checked against --
/// `AfterHandover` here and `inbound.AfterAnswer` there, against one list
/// rather than two spellings of it. `stubs.zig` asserts the other direction:
/// that nothing it reads that way is missing from here.
///
/// Naming the classification rather than the members is the point. The first
/// version of the guard below named `OutOfMemory` and `Busy`, which is the
/// same hand-written list the rest of this work keeps replacing -- and it let
/// `BoxCapacity` through for exactly as long as nobody looked.
pub const not_performed = [_][]const u8{ "Busy", "BoxCapacity", "OutOfMemory" };

pub fn meansNotPerformed(name: []const u8) bool {
    for (not_performed) |member| {
        if (std.mem.eql(u8, member, name)) return true;
    }
    return false;
}

/// Checks one post-handover set against `not_performed`.
///
/// Shared so that the rule is stated once and applied in both files: a set
/// for failures that happen once the request is the peer's may not contain a
/// member that answers "it did not happen".
pub fn refuseNotPerformed(comptime Set: type, comptime named: []const u8) void {
    for (@typeInfo(Set).error_set.?) |member| {
        if (meansNotPerformed(member.name)) @compileError(
            named ++ " must not contain " ++ member.name ++ ": it is a set for " ++
                "failures that happen once the request is the peer's, and " ++
                "`stubs.stoppedBy` reads that member as \"nothing was performed, ask " ++
                "again\". Map it to the member that says the answer was lost instead",
        );
    }
}

comptime {
    refuseNotPerformed(AfterHandover, "client.AfterHandover");
}

/// Sends one request and reads the answer.
///
/// The three failures stay apart for the same reason they do on the reverse
/// path: "nobody is there" and "not right now" are different facts, and a
/// diagnostic that merged them would name the wrong cause.
///
/// The answer is decoded against a copy of the response bytes taken into
/// `arena`, not against the transport's own buffer. `payload.decode` borrows
/// `[]const u8` from the bytes it reads and allocates every other slice in
/// the allocator it is given, so decoding in place would hand back a value
/// pointing into a buffer this function frees on the way out -- a value that
/// reads correctly for as long as nothing else has used that memory, which is
/// the failure mode this whole change exists to remove. One copy per call
/// buys a lifetime that is simply the arena's.
pub fn call(
    comptime owner: method.Owner,
    comptime name: []const u8,
    client: *Client,
    arena: std.mem.Allocator,
    receiver: handle_table.Id,
    arguments: Arguments(owner, name),
    /// Where this call's byte stream goes, for the one method whose result is
    /// one. `null` everywhere else, which is every other method: the wire
    /// form of a result is a value, and a value arrives in the response.
    chunks: ?pending.Chunks,
) CallError!Answer(owner, name) {
    // A link this half has already concluded is unusable carries nothing
    // further. Checked before anything is encoded, because the point is that
    // the far side is not asked: a caller that read a gone answer from an
    // earlier call must not be able to reach the same Session with the next
    // one, and the peer must not act on a request whose answer this half will
    // not wait for.
    if (client.faulted() != .none) return error.Unreachable;

    const entry = comptime method.find(method.codeOf(owner, name)) catch unreachable;
    // The frame kind comes from the registration, not from this function. A
    // `control` entry is on that transport because its call must overtake
    // queued fragments -- `request_run_termination` and the three other Stop
    // methods are registered that way, and sending them as `request` put
    // them behind whatever fragment was mid-flight. The registry said one
    // thing and the send did another, which is the same fault as a count
    // that describes work the build does not do.
    const kind = comptime entry.transport.kind() orelse @compileError(
        @tagName(owner) ++ "." ++ name ++ " is not a call: a `stream` method is answered " ++
            "from the caller's own pump, so there is no request to send",
    );
    const header = comptime envelope.requestHeaderBytes(owner);

    const framed = try client.allocator.alloc(
        u8,
        header + payload.encodedSize(@TypeOf(arguments), arguments),
    );
    defer client.allocator.free(framed);
    envelope.encodeRequestHeader(framed[0..header], entry, receiver);
    _ = payload.encode(@TypeOf(arguments), arguments, framed[header..]);

    const correlation = client.pending.open() catch |err| {
        // The stub answers the same thing for all three, so the distinction
        // the pending table went to the trouble of making has to be kept
        // here or lost. `TooManyUnsettled` is the one the supervisor acts on
        // differently: the table is full of correlations the peer owes
        // answers for, so waiting cannot help and the execution process is
        // what has to end.
        client.recordFault(switch (err) {
            error.TooManyUnsettled => .peer_unsettled,
            error.TooManyInFlight => .send_refused,
            error.CorrelationExhausted => .correlations_exhausted,
        });
        return error.Busy;
    };
    // Before the submit, because the first chunk can be in the pipe while
    // this thread is still inside it. `pending` releases it with the slot, so
    // there is nothing to undo on the paths below.
    if (chunks) |destination| client.pending.attachChunks(correlation, destination);
    // An allocation failure inside the submit is also "nothing was sent", and
    // it was the one way out of here that kept the slot: the `.busy` and
    // `.closed` arms below give it back, and `try` walked past them.
    switch (client.outbound.trySubmit(kind, correlation, framed) catch |err| {
        client.pending.discardUnsent(correlation);
        return err;
    }) {
        // The handover. Everything above this line failed with the request
        // still in hand; everything below is `collect`'s, whose set cannot
        // say that nothing happened.
        .queued => {},
        // Nothing was sent, so nothing is owed: the slot goes back now rather
        // than being held for an answer that cannot come.
        .busy => {
            client.pending.discardUnsent(correlation);
            client.recordFault(.send_refused);
            return error.Busy;
        },
        .closed => {
            client.pending.discardUnsent(correlation);
            return error.Unreachable;
        },
    }

    return collect(owner, name, client, arena, correlation);
}

/// Waits for the answer to a request the peer already has, and reads it.
///
/// Split out from `call` so that its error set is a declaration rather than a
/// comment: `AfterHandover` has no `OutOfMemory`, so the allocation below
/// cannot be `try`-ed and the compiler is what keeps a lost answer from being
/// reported as a call that did not happen.
fn collect(
    comptime owner: method.Owner,
    comptime name: []const u8,
    client: *Client,
    arena: std.mem.Allocator,
    correlation: pending.Correlation,
) AfterHandover!Answer(owner, name) {
    switch (client.pending.claim(correlation)) {
        .link_closed => return error.Unreachable,
        .response => |bytes| {
            defer client.pending.allocator.free(bytes);
            const held = arena.dupe(u8, bytes) catch return error.AnswerLost;
            const outcome = envelope.decodeResponse(held) catch {
                client.recordFault(.unreadable);
                return error.Unreadable;
            };
            return switch (outcome) {
                .failure => |err| .{ .failed = err },
                .value => |value| blk: {
                    const Wired = comptime wire_types.Response(Signature(owner, name));
                    if (comptime Wired == void) {
                        if (value.len != 0) {
                            client.recordFault(.unreadable);
                            return error.Unreadable;
                        }
                        break :blk .{ .returned = {} };
                    }
                    // `decodeExact` allocates, and its allocation failure
                    // arrives here as `Unreadable` along with every other way
                    // it can refuse. That is an existing conflation and it
                    // lands on the same side as `AnswerLost` would -- both are
                    // answers this half could not use -- so nothing is wrong
                    // today; it is named here because the two facts being one
                    // value is worth finding deliberately rather than by
                    // accident.
                    const decoded = payload.decodeExact(Wired, arena, value) catch {
                        client.recordFault(.unreadable);
                        return error.Unreadable;
                    };
                    break :blk .{ .returned = decoded };
                },
            };
        },
    }
}

pub fn Signature(comptime owner: method.Owner, comptime name: []const u8) type {
    return @typeInfo(@FieldType(owner.VTable(), name)).pointer.child;
}

pub fn Arguments(comptime owner: method.Owner, comptime name: []const u8) type {
    return wire_types.Request(Signature(owner, name));
}

/// What one call came back with: the method's own failure, or its wire value.
///
/// The method's failure is not this layer's failure, which is the same split
/// the dispatcher keeps on the other side: a `surface.Error` is an answer.
pub fn Answer(comptime owner: method.Owner, comptime name: []const u8) type {
    const Wired = wire_types.Response(Signature(owner, name));
    return union(enum) {
        returned: Wired,
        failed: error_code.LinkError,
    };
}

const testing = std.testing;

test "a request carries its method, its receiver and its arguments" {
    // Built here rather than driven, because what is under test is the bytes
    // a stub puts on the wire: a dispatcher reading them back is the other
    // side's test.
    const entry = try method.find(method.codeOf(.session, "set_model"));
    const header = envelope.requestHeaderBytes(.session);
    const arguments: Arguments(.session, "set_model") = .{"a-model"};

    const framed = try testing.allocator.alloc(
        u8,
        header + payload.encodedSize(@TypeOf(arguments), arguments),
    );
    defer testing.allocator.free(framed);
    envelope.encodeRequestHeader(framed[0..header], entry, .{ .slot = 2, .generation = 3 });
    _ = payload.encode(@TypeOf(arguments), arguments, framed[header..]);

    const decoded = try envelope.decodeRequest(framed);
    try testing.expectEqualStrings("set_model", decoded.entry.name);
    try testing.expectEqual(@as(u32, 2), decoded.receiver.slot);
    const read = try payload.decodeExact(
        Arguments(.session, "set_model"),
        testing.allocator,
        decoded.arguments,
    );
    try testing.expectEqualStrings("a-model", read[0]);
}

test "the method's failure and the call's failure are different things" {
    // A `surface.Error` is an answer: the far side was reached and said no.
    // The members of `CallError` are about not having been answered at all,
    // and no stub may report one as the other.
    const Session = Answer(.session, "set_model");
    try testing.expectEqual(void, @FieldType(Session, "returned"));
    try testing.expectEqual(error_code.LinkError, @FieldType(Session, "failed"));

    // And they stay apart by construction: no member of `CallError` is a
    // member of the contract's set, so a stub cannot hand one to Product by
    // accident -- it has to translate, which is where the decision belongs.
    inline for (@typeInfo(CallError).error_set.?) |member| {
        for (error_code.entries) |entry| {
            try testing.expect(!std.mem.eql(u8, entry.name, member.name));
        }
    }
}

test "a gone link has an answer in the contract's own set" {
    // `unreachability.zig` deferred which error names it; this is the answer,
    // and it is numbered like any other so a diagnostic can name it.
    const numbered = error_code.encode(error.DependencyUnreachable);
    try testing.expect(numbered != envelope.ok);
    try testing.expectEqual(
        @as(anyerror, error.DependencyUnreachable),
        error_code.decode(numbered).?,
    );
}

/// A client with no channel: enough to own boxes and be found through one.
fn boxedClient(count: usize) !*Client {
    const self = try testing.allocator.create(Client);
    try self.init(
        testing.io,
        testing.allocator,
        undefined,
        undefined,
        .{
            .session = undefined,
            .run = undefined,
            .run_control = undefined,
            .runtime = undefined,
        },
        count,
    );
    return self;
}

fn releaseClient(self: *Client) void {
    self.deinit();
    testing.allocator.destroy(self);
}

test "a port value's context is a box, and the box is the way back to the link" {
    const client = try boxedClient(2);
    defer releaseClient(client);

    const box = try client.boxes.open(.{ .slot = 4, .generation = 1 });
    const session: port.SessionPort = .{ .context = box, .vtable = client.vtables.session };

    // The pointer is a real pointer to a record of ours, so every check on it
    // means what it says -- and the id rides there rather than in the
    // contract, which did not have to grow a field.
    try testing.expectEqual(client, Client.linkFrom(session.context));
    try testing.expectEqual(@as(u32, 4), (try Client.receiverFrom(session.context)).slot);
    try testing.expectEqual(
        handle_repr.Representation.in_context,
        handle_repr.representationOf(port.SessionPort).?,
    );
}

test "a released handle used again is refused, not read" {
    const client = try boxedClient(1);
    defer releaseClient(client);

    const box = try client.boxes.open(.{ .slot = 7, .generation = 3 });
    const session: port.SessionPort = .{ .context = box, .vtable = client.vtables.session };

    const Releasing = struct {
        fn ok(_: void, _: handle_table.Id) anyerror!void {}
    };
    try client.boxes.releaseThrough(box, anyerror!void, {}, Releasing.ok);

    // This is what the box buys over one allocation per handle: the read is
    // still a read of live memory, so the refusal is a refusal rather than a
    // use-after-free.
    try testing.expectEqual(client, Client.linkFrom(session.context));
    try testing.expectError(error.UnknownBox, Client.receiverFrom(session.context));
}

test "a submit that cannot allocate gives the slot back" {
    const io = testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "link", .{ .truncate = true });
    defer file.close(io);

    var queue: channel.Outbound = undefined;
    try queue.start(io, testing.allocator, file, .{});
    defer queue.stop();
    var slots: pending.Table = undefined;
    try slots.init(io, testing.allocator, 4);
    defer slots.deinit();
    const half = try testing.allocator.create(Client);
    defer testing.allocator.destroy(half);
    try half.init(testing.io, testing.allocator, &queue, &slots, .{
        .session = undefined,
        .run = undefined,
        .run_control = undefined,
        .runtime = undefined,
    }, 2);
    defer half.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    // Only the queue's own allocator fails, which is the one the submit
    // duplicates the frame with. Swapping it rather than counting a failure
    // index keeps the test from depending on how many allocations starting a
    // channel happens to make.
    queue.allocator = std.testing.failing_allocator;
    try testing.expectError(error.OutOfMemory, call(
        .session,
        "set_model",
        half,
        arena_state.allocator(),
        .{ .slot = 1, .generation = 1 },
        .{"a-model"},
        null,
    ));
    queue.allocator = testing.allocator;

    // The slot was opened before the submit. `.busy` and `.closed` both give
    // it back; this path walked past them through `try` and kept it live for
    // an answer that was never asked for.
    try testing.expectEqual(@as(usize, 0), slots.liveCount());
    try testing.expectEqual(@as(usize, 0), slots.unsettledCount());

    // Repeating it cannot exhaust a four-slot table, which is what counting
    // is for.
    var index: usize = 0;
    while (index < 16) : (index += 1) {
        queue.allocator = std.testing.failing_allocator;
        try testing.expectError(error.OutOfMemory, call(
            .session,
            "set_model",
            half,
            arena_state.allocator(),
            .{ .slot = 1, .generation = 1 },
            .{"a-model"},
            null,
        ));
        queue.allocator = testing.allocator;
    }
    try testing.expectEqual(@as(usize, 0), slots.liveCount());
}
