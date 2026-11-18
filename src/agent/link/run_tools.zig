//! The capabilities a Session keeps for its current prepared Run.
//!
//! These are not call-scoped. `prepare_run_with_tools` hands them over and
//! returns; the Session stores them, uses them while the Run executes, and
//! clears them in `clearRunToolsLocked`. Retiring their backing when that
//! call returned would leave the Session holding a capability that answers
//! only its failure value -- the tool permanently unavailable, with nothing
//! crashing and nothing going red. `call_frame.zig` is for the other kind.
//!
//! ## One set, two slots
//!
//! `session.zig` asserts `run_delivery == null` before storing, so a Session
//! has at most one set at a time. The backing is therefore one set on the
//! Session's own entry rather than a table keyed by prepared Run, which would
//! make "many at once" representable when it is not.
//!
//! There are two slots all the same, and the reason is the direction of
//! danger. Retiring **too late** costs nothing: the Session has cleared its
//! own copy so it will not call again, and if it did, the bridge carries the
//! Run id and generation that the caller admits against, so a Run that has
//! moved on is refused. Retiring **too early** is the bug above. So the
//! previous set is retired only after a call that took the new one, and that
//! is arranged by position -- `overStaged` retires after `try`, where a
//! failure cannot reach it -- rather than by a condition someone could invert.
//!
//! Two slots are what make that possible without moving memory: the Session
//! is handed a pointer into the staged slot, and committing flips an index
//! rather than relocating anything it now holds.

const std = @import("std");
const contract = @import("agent_contract");
const call_frame = @import("call_frame.zig");
const channel = @import("channel.zig");
const pending = @import("pending.zig");
const reverse = @import("reverse.zig");

const port = contract.port;

/// Asks the caller to check a finished file's bytes.
///
/// The inspection belongs to the caller: `deliver_file.zig` opens by saying
/// file effects and Product commit are separate owners and that a
/// model-provided path never constitutes a receipt, and `src/app.zig`
/// composes the capability with the Host's own copy of the workspace root.
/// This is the execution half's means of asking, nothing more.
pub const DeliveryBridge = struct {
    caller: *reverse.Caller,
    /// Frees what one reverse call allocates. Not an arena: a Run can deliver
    /// several files, so each call releases its own temporaries.
    allocator: std.mem.Allocator,
    task_id: u64,
    run_id: u64,
    generation: u64,

    pub const Backing = call_frame.Frame(DeliveryBridge);
    const call: reverse.Call = .file_delivery_inspection;

    pub fn input(backing: *Backing) contract.FileDeliveryInput {
        return .{ .context = @ptrCast(backing), .inspect_fn = inspect };
    }

    fn inspect(
        context: *anyopaque,
        path: []const u8,
        cancelled: *const std.atomic.Value(bool),
    ) contract.FileDeliveryInspection {
        // The cancel flag does not cross, and nothing here pretends it does.
        //
        // In process the Session hands the inspector a pointer to its own
        // stack-local atomic so a long read can be cut short. A pointer into
        // the other half's stack is exactly what this link exists to stop.
        // Correctness does not need it: `session.zig` re-reads its own flag
        // and its termination signal *after* the inspection returns and
        // answers `cancelled` from there, so a Run cancelled during one still
        // ends cancelled. What is lost is the early abort of a large file's
        // read. That is a cost, recorded as one -- not something to cover
        // with a flag that would mean nothing on the far side.
        _ = cancelled;

        const backing = Backing.fromContext(context) orelse
            return reverse.unreachableAnswer(call);
        const bridge = backing.borrow() orelse return reverse.unreachableAnswer(call);
        return reverse.perform(call, bridge.caller, bridge.allocator, .{
            .task_id = bridge.task_id,
            .run_id = bridge.run_id,
            .generation = bridge.generation,
            .path = path,
        }) catch reverse.busyAnswer(call);
    }
};

/// One Run's worth of tool capabilities.
pub const RunTools = struct {
    delivery: ?DeliveryBridge.Backing = null,

    /// Retires every backing in the set, so a pointer the Session may still
    /// hold answers its capability's failure value rather than reading memory
    /// this half has moved on from.
    pub fn retire(self: *RunTools) void {
        if (self.delivery) |*backing| backing.retire();
        self.* = .{};
    }

    pub fn empty(self: *const RunTools) bool {
        return self.delivery == null;
    }
};

/// What the execution half keeps for one Session.
pub const HeldSession = struct {
    port: port.SessionPort,
    tools: [2]RunTools = .{ .{}, .{} },
    live: u1 = 0,

    pub fn init(value: port.SessionPort) HeldSession {
        return .{ .port = value };
    }

    /// The set the Session is using now, if any.
    pub fn current(self: *HeldSession) *RunTools {
        return &self.tools[self.live];
    }

    /// The set being built for a prepare that has not happened yet. Separate
    /// from the current one so that the Session can be handed a pointer into
    /// it before the call, and committing moves no memory.
    pub fn staged(self: *HeldSession) *RunTools {
        return &self.tools[self.live ^ 1];
    }

    /// Everything, for the closure that releases what the other half can no
    /// longer ask about.
    pub fn retireAll(self: *HeldSession) void {
        for (&self.tools) |*set| set.retire();
    }
};

/// Hands the staged tools to a call and keeps them only if the call took them.
///
/// The previous set is retired *after* `body` succeeds, by position: a
/// failure returns through the `errdefer` and never reaches it. That ordering
/// is the safety condition, not a comment about one. `session.zig` asserts
/// there is no previous set before it stores, so reaching the store at all
/// means the Session has already cleared the old one; retiring before the
/// call, or on a failure, would retire a set the Session may still hold.
pub fn overStaged(
    held: *HeldSession,
    comptime Result: type,
    context: anytype,
    comptime body: fn (@TypeOf(context), *RunTools) Result,
) Result {
    const staging = held.staged();
    errdefer staging.retire();
    const result = try body(context, staging);
    held.current().retire();
    held.live ^= 1;
    return result;
}

const testing = std.testing;

test "a prepare that failed leaves the Session's current tools alone" {
    var held = HeldSession.init(.{ .context = null, .vtable = undefined });
    var caller: reverse.Caller = undefined;

    // A set already in place, standing for the Run the Session is running.
    held.current().* = .{ .delivery = DeliveryBridge.Backing.init(.{
        .caller = &caller,
        .allocator = testing.allocator,
        .task_id = 1,
        .run_id = 7,
        .generation = 1,
    }) };
    const in_place = &held.current().delivery.?;
    try testing.expect(in_place.live());

    const Work = struct {
        fn refuses(_: void, staging: *RunTools) anyerror!u64 {
            staging.delivery = DeliveryBridge.Backing.init(.{
                .caller = undefined,
                .allocator = testing.allocator,
                .task_id = 1,
                .run_id = 8,
                .generation = 1,
            });
            return error.Unexpected;
        }
    };

    try testing.expectError(
        error.Unexpected,
        overStaged(&held, anyerror!u64, {}, Work.refuses),
    );

    // The staged set is gone and the one the Session is holding is untouched.
    // Retiring it here is the early-retirement bug: the Session still has
    // that capability and would get only its failure value from then on.
    try testing.expect(held.staged().empty());
    try testing.expect(in_place.live());
    held.retireAll();
}

test "a prepare that succeeded retires the set it replaced" {
    var held = HeldSession.init(.{ .context = null, .vtable = undefined });
    var caller: reverse.Caller = undefined;
    held.current().* = .{ .delivery = DeliveryBridge.Backing.init(.{
        .caller = &caller,
        .allocator = testing.allocator,
        .task_id = 1,
        .run_id = 7,
        .generation = 1,
    }) };
    const replaced = &held.current().delivery.?;

    const Work = struct {
        fn takes(_: void, staging: *RunTools) anyerror!u64 {
            staging.delivery = DeliveryBridge.Backing.init(.{
                .caller = undefined,
                .allocator = testing.allocator,
                .task_id = 1,
                .run_id = 9,
                .generation = 1,
            });
            return 9;
        }
    };

    try testing.expectEqual(
        @as(u64, 9),
        try overStaged(&held, anyerror!u64, {}, Work.takes),
    );

    // The new set is the live one, and the one it replaced is retired -- so a
    // pointer the Session kept from the old Run answers a failure rather than
    // reading a slot now describing a different Run.
    try testing.expect(!replaced.live());
    try testing.expectEqual(@as(u64, 9), held.current().delivery.?.borrow().?.run_id);
    held.retireAll();
}

test "a retired bridge answers the capability's own failure, not stale memory" {
    var held = HeldSession.init(.{ .context = null, .vtable = undefined });
    var caller: reverse.Caller = undefined;
    held.current().* = .{ .delivery = DeliveryBridge.Backing.init(.{
        .caller = &caller,
        .allocator = testing.allocator,
        .task_id = 4,
        .run_id = 2,
        .generation = 3,
    }) };
    const capability = DeliveryBridge.input(&held.current().delivery.?);

    held.current().retire();

    // The Session will not call it after clearing its own copy; if it did,
    // this is what it gets. `unavailable` and not a verification, which is
    // the fail-closed side of a receipt.
    const answer = capability.inspect_fn(capability.context, "out/a.pdf", &dead_flag);
    try testing.expectEqual(contract.FileDeliveryFailure.unavailable, answer.failed);
}

var dead_flag = std.atomic.Value(bool).init(false);

// ---------------------------------------------------------------------------
// What the bridge leaves behind
// ---------------------------------------------------------------------------
//
// The dispatcher's refusals already each have a test asserting the tables are
// as they were. This is the same discipline on the reverse path, which is
// where it matters for a different reason: a correlation held for an answer
// that cannot come is capacity spent on something that never happened, and
// that shows up only when the table fills.

const Link = struct {
    io: std.Io,
    slots: pending.Table = undefined,
    outbound: channel.Outbound = undefined,
    tmp: std.testing.TmpDir,
    file: std.Io.File,

    fn init(limits: channel.Limits) !*Link {
        const io = testing.io;
        const self = try testing.allocator.create(Link);
        self.* = .{ .io = io, .tmp = std.testing.tmpDir(.{}), .file = undefined };
        self.file = try self.tmp.dir.createFile(io, "link", .{ .truncate = true });
        try self.slots.init(io, testing.allocator, 4);
        try self.outbound.start(io, testing.allocator, self.file, limits);
        return self;
    }

    fn deinit(self: *Link) void {
        self.outbound.stop();
        self.slots.close();
        self.slots.deinit();
        self.file.close(self.io);
        self.tmp.cleanup();
        testing.allocator.destroy(self);
    }

    fn caller(self: *Link) reverse.Caller {
        return .{ .outbound = &self.outbound, .pending = &self.slots };
    }

    fn quiet(self: *Link) bool {
        return self.slots.liveCount() == 0 and self.slots.unsettledCount() == 0;
    }
};

fn bridgeOver(link: *Link, caller: *reverse.Caller) DeliveryBridge.Backing {
    caller.* = link.caller();
    return DeliveryBridge.Backing.init(.{
        .caller = caller,
        .allocator = testing.allocator,
        .task_id = 5,
        .run_id = 6,
        .generation = 7,
    });
}

test "a caller that cannot take the request leaves the bridge holding nothing" {
    // A byte budget nothing fits in, so the submit is refused after the slot
    // was opened -- the shape that would leak one per attempt.
    var link = try Link.init(.{ .data_bytes = 1 });
    defer link.deinit();
    var caller: reverse.Caller = undefined;
    var backing = bridgeOver(link, &caller);
    const capability = DeliveryBridge.input(&backing);

    const answer = capability.inspect_fn(capability.context, "out/a.pdf", &dead_flag);
    try testing.expectEqual(contract.FileDeliveryFailure.capacity, answer.failed);
    try testing.expect(link.quiet());

    // And repeating it cannot exhaust the four slots.
    var index: usize = 0;
    while (index < 16) : (index += 1) {
        _ = capability.inspect_fn(capability.context, "out/a.pdf", &dead_flag);
    }
    try testing.expect(link.quiet());
    backing.retire();
}

test "a link that is gone answers unavailable and leaves the bridge holding nothing" {
    var link = try Link.init(.{});
    defer link.deinit();
    link.outbound.stop();
    var caller: reverse.Caller = undefined;
    var backing = bridgeOver(link, &caller);
    const capability = DeliveryBridge.input(&backing);

    // Not `capacity`: "there is nobody" and "try later" stay apart all the
    // way out to the receipt.
    const answer = capability.inspect_fn(capability.context, "out/a.pdf", &dead_flag);
    try testing.expectEqual(contract.FileDeliveryFailure.unavailable, answer.failed);
    try testing.expect(link.quiet());
    backing.retire();
}

test "an answer this build cannot read is not a verification" {
    var link = try Link.init(.{});
    defer link.deinit();
    var caller: reverse.Caller = undefined;
    var backing = bridgeOver(link, &caller);
    const capability = DeliveryBridge.input(&backing);

    const Answering = struct {
        fn run(slots: *pending.Table, ready: *std.atomic.Value(bool)) void {
            // Wait for the request's slot, then answer it with bytes no
            // version of this build encodes. Correlations start at one.
            while (slots.liveCount() == 0) {}
            const bytes = slots.allocator.alloc(u8, 3) catch return;
            @memset(bytes, 0xAA);
            slots.deposit(1, bytes);
            ready.store(true, .release);
        }
    };
    var ready = std.atomic.Value(bool).init(false);
    var thread = try std.Thread.spawn(.{}, Answering.run, .{ &link.slots, &ready });
    defer thread.join();

    const answer = capability.inspect_fn(capability.context, "out/a.pdf", &dead_flag);
    // A malformed answer is the far side not speaking this protocol, so it is
    // the fail-closed side rather than a receipt nobody can account for.
    try testing.expectEqual(contract.FileDeliveryFailure.unavailable, answer.failed);
    try testing.expect(link.quiet());
    backing.retire();
}
