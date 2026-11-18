//! Calls that run from the execution half into the caller.
//!
//! They are registered here rather than left as a shape each case grows for
//! itself. The rules below were written while there was one, which is why
//! they are uniform; the second one arrived afterwards and had to satisfy
//! them unchanged, which is the only test a rule like this gets.
//!
//! Two, and each is here because the effect belongs to the caller:
//!
//! - The MCP installation tool hands an install request to the caller and
//!   reads the answer, because it has to tell the model whether the request
//!   was accepted.
//! - File delivery inspection asks the caller to check a finished file's
//!   bytes. `deliver_file.zig` states why in its own first line: file effects
//!   and Product commit are separate owners, and a model-provided path never
//!   constitutes a receipt. The receipt's whole value is that the half which
//!   did not run the model looked at the bytes. An execution-side inspection
//!   would be the half that may be crashing vouching for itself, which turns
//!   a guarantee into its opposite while the code still compiles.
//!
//! Everything else either composes locally or was ruled out from crossing.
//! Image and video generation in particular are execution-side by
//! `architecture.md` section 5: a binding crosses, not a capability, so they
//! are not reverse calls and must not become them.
//!
//! Two rules, and the second is the one that looked free in process.
//!
//! **A reverse call is answered by a caller-side thread that never blocks on a
//! forward call.** Otherwise a reachable deadlock: a driver blocked in
//! `execute` waits for a terminal, the execution half asks the caller to admit
//! an install, and the answer has to come from a caller thread -- if the only
//! thread that could produce it is itself blocked in a forward call, nothing
//! moves. A correlation-keyed response table fixes who may *receive* an
//! answer; it does not conjure a thread to *produce* one.
//!
//! **The execution half holds no lock across a reverse call.** In process the
//! installation tool takes the Session lock, re-validates the Run, submits and
//! releases -- holding the lock over a local call is nearly free, and makes the
//! check and the submit atomic. Across a process that becomes a lock held over
//! a round trip: the Session's lock duration becomes the caller's response
//! time, and every other operation needing that Session queues behind it.
//!
//! So the atomicity is reshaped rather than carried. The check travels with
//! the request -- the Run id and generation the execution half validated
//! against go in the payload, and the caller admits or refuses against its own
//! record, which is the side that owns the Run anyway. `requestCarriesGuard`
//! below is what keeps that from being dropped later.
//!
//! The answer vocabulary needs nothing new: the tool's result already has
//! `unavailable`, which is the fail-closed answer when the caller is not
//! there, and `busy`, which is "try later". That is the same split as the
//! pending table's two exhaustion failures. The inspection's vocabulary has
//! `failed: .unavailable` for the same reason.
//!
//! ## What the second one added
//!
//! Both rules held for it unchanged, and one of them was already paid: in
//! process `session.zig` releases the Session lock *before* calling the
//! inspection and re-takes it after, so delivery never held a lock across the
//! callback even before the split. The guard still travels, because the
//! caller must admit the request against its own record of a Run that may
//! have moved on while the request was in flight.
//!
//! Two things it did add.
//!
//! **The first rule is narrower here than it is in general.** `output_file`
//! refuses a file effect on the main thread -- `MainThreadFileEffect`, which
//! the Host maps to `restricted` -- so the thread that answers this call must
//! not be the main thread either. Rule one says "a thread that never blocks
//! on a forward call"; for this call it is also "not the main thread", and
//! those two together are a real constraint on where the answering loop
//! lives, not a free choice.
//!
//! **A cancel flag cannot cross, and does not need to.** In process the
//! execution half hands the inspector a pointer to a stack-local atomic and
//! registers it, so a cancelling thread can cut a long read short. A pointer
//! into the other half's stack is exactly what this link exists to stop. It
//! is not needed for correctness: `session.zig` re-reads its own flag and its
//! termination signal *after* the inspection returns and answers `cancelled`
//! from there, so a Run cancelled during an inspection still ends as
//! cancelled. What is lost is only the early abort -- a cancellation during a
//! large file's read waits for that read to finish. That is a cost, and it is
//! written here rather than left for someone to find in a profile.

const std = @import("std");
const contract = @import("agent_contract");
const payload = @import("payload.zig");
const wire_types = @import("wire_types.zig");
const channel = @import("channel.zig");
const pending = @import("pending.zig");

pub const Call = enum {
    /// Hand an install request to the caller and read whether it was admitted.
    mcp_installation,
    /// Ask the caller to check a finished file's bytes and say what it found.
    file_delivery_inspection,
};

/// What crosses from the execution half to the caller for one reverse call.
///
/// The guard fields are not decoration: they are the atomicity that used to be
/// a held lock. The caller admits against its own Run record using them, so
/// the execution half can validate, release its lock, and then call.
pub const McpInstallationRequest = struct {
    task_id: u64,
    /// The Run the execution half validated against before releasing its
    /// lock. The caller refuses a request whose Run has moved on.
    run_id: u64,
    /// Its generation, so a reused Run id cannot admit a stale request.
    generation: u64,
    /// The install request's own bytes. The original owns them through an
    /// allocator; only the bytes travel.
    request_json: []const u8,
};

pub const McpInstallationResponse = contract.McpInstallationResult;

/// What crosses for one file delivery inspection.
///
/// The path is the model's, and it is not trusted by either half: the
/// execution half validates its shape with `deliver_file.validatePath` before
/// sending, and the caller resolves it beneath the root *it* holds. The root
/// does not travel at all -- the caller composed the capability against its
/// own copy, exactly as it does in process -- so there is no asserted root
/// here for anyone to have to revalidate.
pub const FileDeliveryInspectionRequest = struct {
    task_id: u64,
    /// The Run the file is being delivered for, and its generation. The
    /// caller admits the request against its own record of that Run.
    run_id: u64,
    generation: u64,
    /// Workspace-relative, forward slashes, already shape-validated.
    path: []const u8,
};

pub const FileDeliveryInspectionResponse = contract.FileDeliveryInspection;

pub fn Request(comptime call: Call) type {
    return switch (call) {
        .mcp_installation => McpInstallationRequest,
        .file_delivery_inspection => FileDeliveryInspectionRequest,
    };
}

pub fn Response(comptime call: Call) type {
    return switch (call) {
        .mcp_installation => McpInstallationResponse,
        .file_delivery_inspection => FileDeliveryInspectionResponse,
    };
}

/// Whether a reverse call's request carries the guard that replaces the held
/// lock. A reverse call without one would have to be answered while something
/// stays locked, which is the shape this file exists to prevent.
pub fn requestCarriesGuard(comptime call: Call) bool {
    const T = Request(call);
    return @hasField(T, "run_id") and @hasField(T, "generation");
}

comptime {
    @setEvalBranchQuota(100_000);
    for (std.enums.values(Call)) |call| switch (call) {
        inline else => |tag| {
            // Both directions must be carriable by the same codec as a forward
            // call: a reverse call is not a second protocol.
            payload.requireStructural(Request(tag));
            payload.requireStructural(wire_types.Wire(Response(tag)));
            if (!requestCarriesGuard(tag)) @compileError(
                "the reverse call " ++ @tagName(tag) ++ " does not carry the Run id and " ++
                    "generation its answer must be admitted against. Without them the " ++
                    "execution half would have to keep a lock held across the round trip; " ++
                    "see src/agent/link/reverse.zig",
            );
        },
    };
}

// ---------------------------------------------------------------------------
// Direction
// ---------------------------------------------------------------------------

/// Everything a forward call needs: a correlation to open, somewhere to send
/// under it, and somewhere the answer lands. Named as one type so that "can
/// this code make a forward call" becomes a question about types.
pub const Caller = struct {
    outbound: *channel.Outbound,
    pending: *pending.Table,
};

/// Whether a type can reach a `Caller`, directly or through its fields.
///
/// An opaque pointer counts as reaching one, because it might be one and
/// nothing can prove otherwise. That is deliberate: it is what stops a handler
/// from smuggling the forward capability through a type-erased context, which
/// is exactly how a rule like this normally gets around.
/// Type-erased capabilities that are not the link and cannot become it.
///
/// An opaque pointer otherwise counts as reaching a caller, because it might
/// be one and nothing can prove otherwise -- that is what stops a handler
/// smuggling the forward capability through a type-erased context. But the
/// platform's own erased capabilities would then poison every context that
/// holds one, and a handler legitimately needs them. They are exempt because
/// reaching the link requires the link's own types, which neither of these
/// can produce. Adding to this list is a decision, not a convenience.
const erased_exemptions = [_]type{ std.Io, std.mem.Allocator };

fn exempt(comptime T: type) bool {
    inline for (erased_exemptions) |Allowed| {
        if (T == Allowed) return true;
    }
    return false;
}

pub fn reachesForwardCaller(comptime T: type) bool {
    if (T == Caller) return true;
    if (exempt(T)) return false;
    return switch (@typeInfo(T)) {
        .optional => |info| reachesForwardCaller(info.child),
        .array => |info| reachesForwardCaller(info.child),
        .vector => |info| reachesForwardCaller(info.child),
        .pointer => |info| info.child == anyopaque or reachesForwardCaller(info.child),
        .@"struct" => |info| blk: {
            inline for (info.fields) |field| {
                if (reachesForwardCaller(field.type)) break :blk true;
            }
            break :blk false;
        },
        .@"union" => |info| blk: {
            inline for (info.fields) |field| {
                if (reachesForwardCaller(field.type)) break :blk true;
            }
            break :blk false;
        },
        // An opaque type's contents are unknown, so it could hold one.
        .@"opaque" => true,
        else => false,
    };
}

/// The handler for one reverse call, over a context the link can inspect.
///
/// The third rule, and the one that closes the loop. A forward call's handler
/// may nest a reverse call and wait: the installation tool does exactly that,
/// and it is safe because of the first rule -- the caller answers on a thread
/// that never blocks on a forward call. The reverse of that is not safe. If a
/// reverse handler started a forward call and waited, the chain would close:
/// the execution half waiting for an answer to its reverse call, the caller
/// waiting for an answer to its forward call, and both sides' exhaustion codes
/// saying the peer owes answers, with nothing naming the cycle.
///
/// So a reverse handler cannot be given the means. Its context must be a type
/// this module can look inside, and it must not reach a `Caller`. Stating it
/// now costs nothing, because no reverse handler exists yet; once some do,
/// enforcing it would mean auditing what each one calls.
pub fn Handler(comptime call: Call, comptime Context: type) type {
    comptime {
        if (reachesForwardCaller(Context)) @compileError(
            "a reverse call's handler cannot reach a forward caller: " ++ @typeName(Context) ++
                ". A handler that could call forward and wait closes a cross-process cycle " ++
                "that neither side's capacity failure would name. An opaque context counts, " ++
                "because it could hold one -- give the handler a type the link can inspect.",
        );
        return *const fn (*Context, Request(call)) Response(call);
    }
}

/// Whether answering a call is a file effect, which the Host refuses to
/// perform on its main thread.
///
/// Exhaustive, because the answer is a property of the effect and a call added
/// later must state it rather than inherit "anywhere is fine".
pub fn requiresOffMainThread(comptime call: Call) bool {
    return switch (call) {
        // `output_file` returns `MainThreadFileEffect` outright
        // (src/app/output_file.zig), so answering this on the main thread
        // turns every delivery into `restricted`.
        .file_delivery_inspection => true,
        // An install request is admitted against Product's own records and
        // performs no file effect, so it has no thread of its own to insist
        // on beyond the first rule above.
        .mcp_installation => false,
    };
}

/// Proof that the holder is not running on the Host's main thread.
///
/// A witness rather than a convention. `answer` below cannot be called for a
/// call that needs one without producing it first, and it cannot be produced
/// on the main thread -- so "we know not to answer this there" stops being
/// something to remember. The runtime check is kept as well, because a
/// witness can outlive the thread that made it if someone passes it along.
pub const OffMainThread = struct {
    main_thread_id: std.Thread.Id,

    pub fn capture(main_thread_id: std.Thread.Id) ?OffMainThread {
        if (std.Thread.getCurrentId() == main_thread_id) return null;
        return .{ .main_thread_id = main_thread_id };
    }

    pub fn holds(self: OffMainThread) bool {
        return std.Thread.getCurrentId() != self.main_thread_id;
    }
};

/// What answering one reverse call needs from its answerer: the witness, for
/// the calls whose effect refuses the main thread, and nothing for the rest.
///
/// A type rather than a comment, so the obligation is in the signature.
pub fn Answerer(comptime call: Call, comptime Context: type) type {
    comptime {
        if (reachesForwardCaller(Context)) @compileError(
            "a reverse call's handler cannot reach a forward caller: " ++ @typeName(Context),
        );
        return if (requiresOffMainThread(call))
            *const fn (*Context, OffMainThread, Request(call)) Response(call)
        else
            *const fn (*Context, Request(call)) Response(call);
    }
}

/// The answer when the caller cannot be reached at all. A reverse call must
/// have one, or the execution half would have to wait for a peer that is gone.
pub fn unreachableAnswer(comptime call: Call) Response(call) {
    return switch (call) {
        .mcp_installation => .unavailable,
        // The inspection vocabulary already has it, and it is the fail-closed
        // side: nothing was checked, so nothing is verified.
        .file_delivery_inspection => .{ .failed = .unavailable },
    };
}

// ---------------------------------------------------------------------------
// Performing one
// ---------------------------------------------------------------------------

/// A reverse request opens with its call's registered number, for the same
/// reason a forward request opens with its method's: the frame header is the
/// transport and the call is the contract. The numbers are the enum's own
/// order, which is fixed by the count assertion above -- a call cannot be
/// inserted in the middle without that assertion changing too.
pub const header_bytes: usize = 2;

pub const DecodeError = error{
    Truncated,
    /// A call number this build does not register. The peer is our own
    /// binary, so an unknown number means the link is talking to something
    /// else.
    UnknownCall,
};

pub fn numberOf(comptime call: Call) u16 {
    return @intFromEnum(call);
}

pub fn encodeHeader(output: *[header_bytes]u8, comptime call: Call) void {
    std.mem.writeInt(u16, output, numberOf(call), .little);
}

pub fn decodeHeader(bytes: []const u8) DecodeError!struct {
    call: Call,
    arguments: []const u8,
} {
    if (bytes.len < header_bytes) return error.Truncated;
    const number = std.mem.readInt(u16, bytes[0..header_bytes], .little);
    const call = std.enums.fromInt(Call, number) orelse return error.UnknownCall;
    return .{ .call = call, .arguments = bytes[header_bytes..] };
}

/// The answer when the caller is there but cannot take another request right
/// now. Distinct from `unreachableAnswer`, because "try later" and "there is
/// nobody" are the two different exhaustions the pending table already tells
/// apart, and a diagnostic that merged them would name the wrong cause.
pub fn busyAnswer(comptime call: Call) Response(call) {
    return switch (call) {
        .mcp_installation => .busy,
        // The inspection has no "later": a Run's tool call cannot be parked
        // and resumed, so the capacity refusal it already has is the answer.
        .file_delivery_inspection => .{ .failed = .capacity },
    };
}

/// Performs one reverse call and waits for the answer.
///
/// Blocking here is safe because of the first rule: the answer is produced by
/// a caller-side thread that never blocks on a forward call. The second rule
/// is why the guard is in the request rather than a lock being held across
/// this.
///
/// Every way this can fail has an answer in the call's own vocabulary, so the
/// execution half never waits on a peer that is gone and never reports a
/// refusal as an acceptance.
pub fn perform(
    comptime call: Call,
    caller: *Caller,
    arena: std.mem.Allocator,
    request: Request(call),
) std.mem.Allocator.Error!Response(call) {
    const body = try payload.encodeAlloc(Request(call), arena, request);
    const framed = try arena.alloc(u8, header_bytes + body.len);
    encodeHeader(framed[0..header_bytes], call);
    @memcpy(framed[header_bytes..], body);

    const correlation = caller.pending.open() catch return busyAnswer(call);
    switch (try caller.outbound.trySubmit(.ui_request, correlation, framed)) {
        .queued => {},
        // Nothing was sent, so nothing is owed: the slot goes back now
        // rather than being held for an answer that cannot come. Abandoning
        // would keep it, which is right after a send and wrong here -- a
        // caller refused repeatedly would exhaust the table on requests it
        // never made.
        .busy => {
            caller.pending.discardUnsent(correlation);
            return busyAnswer(call);
        },
        .closed => {
            caller.pending.discardUnsent(correlation);
            return unreachableAnswer(call);
        },
    }

    switch (caller.pending.claim(correlation)) {
        .response => |bytes| {
            defer caller.pending.allocator.free(bytes);
            const Wire = wire_types.Wire(Response(call));
            const decoded = payload.decodeExact(Wire, arena, bytes) catch
                return unreachableAnswer(call);
            return decoded;
        },
        // Not an answer, and never reported as one.
        .link_closed => return unreachableAnswer(call),
    }
}

const testing = std.testing;

test "a reverse call cannot appear without this file changing" {
    // The count is asserted so one cannot be added without passing through
    // the rules above. The second one did: it failed this assertion first,
    // which is what the assertion is for.
    try testing.expectEqual(@as(usize, 2), std.enums.values(Call).len);
}

test "every reverse call can answer that the caller is unreachable" {
    // The fail-closed answer has to exist in the vocabulary the tool already
    // has, or the execution half is left waiting on a peer that is gone. It
    // does, which is why this path needs no new result type.
    inline for (comptime std.enums.values(Call)) |call| {
        const answer = unreachableAnswer(call);
        switch (call) {
            .mcp_installation => try testing.expectEqual(
                contract.McpInstallationResult.unavailable,
                answer,
            ),
            .file_delivery_inspection => try testing.expectEqual(
                contract.FileDeliveryFailure.unavailable,
                answer.failed,
            ),
        }
    }
}

test "every reverse call carries the guard that replaces the held lock" {
    inline for (comptime std.enums.values(Call)) |call| {
        try testing.expect(requestCarriesGuard(call));
    }
}

test "a cancel flag does not cross, and the answer's shape says what replaces it" {
    // The in-process capability takes a pointer to the execution half's own
    // stack-local atomic. Nothing shaped like that is in the request, and the
    // reason it is safe to leave out is that the execution half re-checks its
    // own cancellation after the answer arrives.
    try testing.expect(!@hasField(FileDeliveryInspectionRequest, "cancelled"));
    try testing.expect(!@hasField(FileDeliveryInspectionRequest, "cancellation"));
    inline for (@typeInfo(FileDeliveryInspectionRequest).@"struct".fields) |field| {
        try testing.expect(field.type != *const std.atomic.Value(bool));
        try testing.expect(field.type != *std.atomic.Value(bool));
    }
    // And the root does not cross either: the caller composed the capability
    // against its own copy, so an asserted root would have no reader.
    try testing.expect(!@hasField(FileDeliveryInspectionRequest, "root"));
    try testing.expect(!@hasField(FileDeliveryInspectionRequest, "workspace_root"));
}

test "the request carries the bytes but not their ownership" {
    // The original owns its JSON through an allocator; the wire carries the
    // bytes and the receiving side owns its own copy, as everywhere else.
    try testing.expectEqual([]const u8, @FieldType(McpInstallationRequest, "request_json"));
    try testing.expect(!@hasField(McpInstallationRequest, "allocator"));
}

test "a reverse handler cannot be handed the forward caller, however it is wrapped" {
    // The predicate the rule is built on, checked in both directions so the
    // rule is a property rather than a promise.
    const Plain = struct { task_id: u64, name: []const u8 };
    try testing.expect(!reachesForwardCaller(Plain));
    try testing.expect(!reachesForwardCaller(u64));
    try testing.expect(!reachesForwardCaller(McpInstallationRequest));

    // Directly.
    try testing.expect(reachesForwardCaller(Caller));
    try testing.expect(reachesForwardCaller(*Caller));
    try testing.expect(reachesForwardCaller(?*Caller));

    // One field down, and two.
    const Nested = struct { link: *Caller };
    const Deeper = struct { inner: Nested, count: u32 };
    try testing.expect(reachesForwardCaller(Nested));
    try testing.expect(reachesForwardCaller(Deeper));

    // Through a union, which is where a hand-audit would most likely miss it.
    const Either = union(enum) { nothing, link: Caller };
    try testing.expect(reachesForwardCaller(Either));

    // And type-erased, which is how a rule like this normally gets around.
    const Erased = struct { context: ?*anyopaque };
    try testing.expect(reachesForwardCaller(Erased));
}

test "a call whose effect refuses the main thread cannot be answered without the witness" {
    const Context = struct { task_id: u64 };

    // The obligation is in the signature: the delivery inspection's answerer
    // takes a witness, the installation's does not. Nothing has to remember.
    try testing.expectEqual(
        *const fn (*Context, OffMainThread, FileDeliveryInspectionRequest) FileDeliveryInspectionResponse,
        Answerer(.file_delivery_inspection, Context),
    );
    try testing.expectEqual(
        *const fn (*Context, McpInstallationRequest) McpInstallationResponse,
        Answerer(.mcp_installation, Context),
    );

    // And the witness cannot be made on the main thread, which is the half
    // of this a type cannot carry.
    const main = std.Thread.getCurrentId();
    try testing.expect(OffMainThread.capture(main) == null);

    const Elsewhere = struct {
        fn run(main_thread_id: std.Thread.Id, out: *?OffMainThread, held: *bool) void {
            out.* = OffMainThread.capture(main_thread_id);
            held.* = if (out.*) |witness| witness.holds() else false;
        }
    };
    var captured: ?OffMainThread = null;
    var held_there = false;
    var thread = try std.Thread.spawn(.{}, Elsewhere.run, .{ main, &captured, &held_there });
    thread.join();
    try testing.expect(captured != null);
    try testing.expect(held_there);

    // And this is why the runtime check is kept: the witness is a value, so
    // it can be carried back to the thread it was proving something about,
    // where it no longer holds.
    try testing.expect(!captured.?.holds());
}

test "the one registered reverse call has an inspectable handler" {
    // Compiles only because the context is a type the link can look inside
    // and it reaches no caller; a context that did would fail the build with
    // the reason, which is the point of putting the check in `Handler`.
    const Context = struct { task_id: u64 };
    const Expected = *const fn (*Context, McpInstallationRequest) McpInstallationResponse;
    try testing.expectEqual(Expected, Handler(.mcp_installation, Context));
}

test "the platform's own erased capabilities do not poison a handler context" {
    // Without the exemption, any context holding an `std.Io` would be refused,
    // because `Io` carries an opaque userdata pointer. A handler needs one, and
    // neither it nor an allocator can reach the link: doing that takes the
    // link's own types.
    const WithIo = struct { io: std.Io, task_id: u64 };
    const WithAllocator = struct { allocator: std.mem.Allocator };
    try testing.expect(!reachesForwardCaller(WithIo));
    try testing.expect(!reachesForwardCaller(WithAllocator));
    // The exemption is narrow: an arbitrary erased pointer is still refused.
    const WithErased = struct { io: std.Io, smuggled: *anyopaque };
    try testing.expect(reachesForwardCaller(WithErased));
}

test "a reverse request names its call, and an unregistered number is refused" {
    var bytes: [header_bytes + 2]u8 = undefined;
    encodeHeader(bytes[0..header_bytes], .file_delivery_inspection);
    @memcpy(bytes[header_bytes..], "hi");
    const decoded = try decodeHeader(&bytes);
    try testing.expectEqual(Call.file_delivery_inspection, decoded.call);
    try testing.expectEqualStrings("hi", decoded.arguments);

    var unknown: [header_bytes]u8 = undefined;
    std.mem.writeInt(u16, &unknown, 0x4242, .little);
    try testing.expectError(error.UnknownCall, decodeHeader(&unknown));
    try testing.expectError(error.Truncated, decodeHeader(&.{1}));
}

const Harness = struct {
    io: std.Io,
    pending_table: pending.Table,
    outbound: channel.Outbound,
    tmp: std.testing.TmpDir,
    file: std.Io.File,

    fn init(slots: usize, limits: channel.Limits) !*Harness {
        const io = testing.io;
        const self = try testing.allocator.create(Harness);
        self.* = .{
            .io = io,
            .pending_table = undefined,
            .outbound = undefined,
            .tmp = std.testing.tmpDir(.{}),
            .file = undefined,
        };
        self.file = try self.tmp.dir.createFile(io, "link", .{ .truncate = true });
        try self.pending_table.init(io, testing.allocator, slots);
        try self.outbound.start(io, testing.allocator, self.file, limits);
        return self;
    }

    fn deinit(self: *Harness) void {
        self.outbound.stop();
        self.pending_table.close();
        self.pending_table.deinit();
        self.file.close(self.io);
        self.tmp.cleanup();
        testing.allocator.destroy(self);
    }

    fn caller(self: *Harness) Caller {
        return .{ .outbound = &self.outbound, .pending = &self.pending_table };
    }
};

const sample: FileDeliveryInspectionRequest = .{
    .task_id = 3,
    .run_id = 9,
    .generation = 1,
    .path = "out/report.pdf",
};

test "a caller that cannot take the request is answered busy, and keeps no slot" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // One correlation, already spent, so the table refuses before anything is
    // sent.
    var harness = try Harness.init(1, .{});
    defer harness.deinit();
    const held = try harness.pending_table.open();
    var link = harness.caller();

    const answer = try perform(.file_delivery_inspection, &link, arena, sample);
    try testing.expectEqual(contract.FileDeliveryFailure.capacity, answer.failed);
    // The held slot is the only one, and the refused call took none.
    try testing.expectEqual(@as(usize, 1), harness.pending_table.liveCount());
    harness.pending_table.discardUnsent(held);
    try testing.expectEqual(@as(usize, 0), harness.pending_table.liveCount());
}

test "a queue at its bound answers busy without holding a slot for an answer that cannot come" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A queue that admits nothing, so the submit is refused rather than the
    // table.
    var harness = try Harness.init(4, .{ .data_bytes = 1 });
    defer harness.deinit();
    var link = harness.caller();

    const answer = try perform(.file_delivery_inspection, &link, arena, sample);
    try testing.expectEqual(contract.FileDeliveryFailure.capacity, answer.failed);

    // This is the one that would leak: the slot was opened before the submit
    // was refused, and nothing will ever answer it. Abandoning would have
    // kept it live until the link ended.
    try testing.expectEqual(@as(usize, 0), harness.pending_table.liveCount());
    try testing.expectEqual(@as(usize, 0), harness.pending_table.unsettledCount());

    // Repeating it cannot exhaust the table, which is the point of counting.
    var index: usize = 0;
    while (index < 16) : (index += 1) {
        _ = try perform(.file_delivery_inspection, &link, arena, sample);
    }
    try testing.expectEqual(@as(usize, 0), harness.pending_table.liveCount());
}

test "a closed link is unreachable, not busy" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var harness = try Harness.init(4, .{});
    defer harness.deinit();
    // Stopped, so nothing further is written and `trySubmit` says so.
    harness.outbound.stop();
    var link = harness.caller();

    // The two exhaustions stay apart all the way out to the answer: "try
    // later" and "there is nobody" are different facts, and the delivery
    // vocabulary has a value for each.
    const answer = try perform(.file_delivery_inspection, &link, arena, sample);
    try testing.expectEqual(contract.FileDeliveryFailure.unavailable, answer.failed);
    try testing.expectEqual(@as(usize, 0), harness.pending_table.liveCount());

    const install = try perform(.mcp_installation, &link, arena, .{
        .task_id = 1,
        .run_id = 2,
        .generation = 3,
        .request_json = "{}",
    });
    try testing.expectEqual(contract.McpInstallationResult.unavailable, install);
}
