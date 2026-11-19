//! The UI half of the execution link, as one object Product can be given.
//!
//! `execution_host.zig` starts the process and agrees on identity.
//! `src/agent/link/` frames the calls. This is what holds those two together
//! for the length of a link: the correlation table, the caller's half, the
//! thread that reads what comes back, and the routing that decides which of
//! the three places an arriving message belongs to.
//!
//! What it hands out is a `RuntimePort`. That is the whole point of the shape:
//! Product keeps calling the port it already calls, and the composition root
//! decides whether the implementation behind it is the in-process Runtime or
//! this. Nothing in Product knows which.
//!
//! ## What the reader thread may not do
//!
//! It may not answer a call. Every response it reads is deposited against its
//! correlation and the waiting caller wakes up; if the reader itself ever
//! blocked on a forward call, a reverse call arriving mid-Run would deadlock
//! the link -- `reverse.zig` states that rule for the execution half, and it
//! holds here for the same reason in the other direction.
//!
//! It may not decide what an unanswered call means, either. When the link
//! ends, the table is closed and every waiter is told the link closed; what
//! *that* means for a Run is Product's, and `stubs.zig` turns it into each
//! method's own restricting answer.

const std = @import("std");

const agent = @import("metawork_agent");
const agent_link = @import("metawork_agent_link");
const execution_events = @import("app_execution_events");
const execution_host = @import("app_execution_host");

const channel = agent_link.channel;
const client = agent_link.client;
const pending = agent_link.pending;

pub const StartFailure = execution_host.StartFailure;
pub const Stopped = execution_host.Stopped;

pub const Options = struct {
    identity: agent_link.Identity,
    message_limits: agent_link.MessageLimits,
    queue_limits: agent_link.QueueLimits = .{},
    /// What to start. Production always starts this same executable; a test
    /// needs a stand-in, because the application executable carries the
    /// Renderer bundle and a fixture does not.
    spawn: execution_host.Host.Spawn = .self,
    /// Handles this half can name at once. A bound rather than a growth: the
    /// reservation that keeps a created Session nameable is only possible
    /// against a bound.
    boxes: usize = 64,
    /// Calls that can be unanswered at once. Sized by correlations the peer
    /// has not settled rather than by callers waiting, which is the larger of
    /// the two -- `pending.zig` says why.
    correlations: usize = 64,
    /// How many arrived events this half may hold. The default is the
    /// in-process pump's own bound, so the condition arrives at the same depth
    /// it does today.
    events: execution_events.Pump.Limits = .{},
    /// How this half's own event consumer is woken. Product asks for a wake
    /// through the port, and the execution half asks for one with an
    /// `event_ready` frame; both end here.
    wake: agent.EventReadyNotifier,
};

pub const Supervisor = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    host: execution_host.Host,
    slots: pending.Table,
    half: client.Client,
    pump: execution_events.Pump,
    inbound: channel.Inbound,
    reader: ?std.Thread = null,
    ended: ?channel.Stopped = null,
    composed: bool = false,

    /// Starts the execution process and brings the link up.
    ///
    /// A returned failure leaves nothing running and nothing allocated, the
    /// way `Host.start` does, because the caller's next move is to try again
    /// or to fall back to the in-process Runtime.
    pub fn start(
        self: *Supervisor,
        io: std.Io,
        allocator: std.mem.Allocator,
        options: Options,
    ) std.mem.Allocator.Error!?StartFailure {
        self.* = .{
            .io = io,
            .allocator = allocator,
            .host = undefined,
            .slots = undefined,
            .half = undefined,
            .pump = undefined,
            .inbound = undefined,
        };
        if (try self.host.start(
            io,
            allocator,
            options.identity,
            options.queue_limits,
            options.spawn,
        )) |failure| return failure;
        errdefer _ = self.host.stop(null);

        try self.slots.init(io, allocator, options.correlations);
        errdefer self.slots.deinit();
        try self.half.init(
            allocator,
            &self.host.outbound,
            &self.slots,
            agent_link.stubs.vtables,
            options.boxes,
        );
        errdefer self.half.deinit();
        try self.pump.init(allocator, io, options.events, options.wake);
        errdefer self.pump.deinit();
        // The four `stream` methods are answered from here. Installed after
        // the half exists, because the buffer holds parsed Core events and the
        // link module parses none.
        self.half.bindEvents(self.pump.source());
        self.inbound.init(
            io,
            allocator,
            &self.host.reader.interface,
            options.message_limits,
            .{ .context = self, .deliver_fn = deliver },
        ) catch |failure| switch (failure) {
            error.OutOfMemory => return error.OutOfMemory,
            // The limits are the composition root's own constants, so an
            // invalid set is a wiring mistake rather than a condition.
            error.InvalidLimits => return .resource_unavailable,
        };
        errdefer self.inbound.deinit();
        self.reader = std.Thread.spawn(.{}, readerMain, .{self}) catch
            return .resource_unavailable;
        self.composed = true;
        return null;
    }

    /// The port Product is given. Its context is this half, which is what
    /// `stubs.zig` casts a `runtime` method's context to.
    pub fn runtimePort(self: *Supervisor) agent.RuntimePort {
        std.debug.assert(self.composed);
        return .{ .context = &self.half, .vtable = &agent_link.stubs.runtimePort };
    }

    /// What this half concluded about the link, for whoever owns the process.
    /// `.none` is not a claim that the peer is alive -- only the peer's own
    /// exit says that.
    pub fn fault(self: *const Supervisor) client.LinkFault {
        return self.half.faulted();
    }

    /// Ends the link and the process, and releases every waiter.
    ///
    /// The table is closed before the child is told to stop, so a caller
    /// blocked on a correlation is answered rather than waiting out the grace
    /// period with it. The reader thread is joined inside `Host.stop`, in the
    /// one window where that is safe: `Quiesce` says why.
    pub fn stop(self: *Supervisor) Stopped {
        self.slots.close();
        return self.host.stop(.{ .context = self, .settle_fn = joinReader });
    }

    fn joinReader(context: ?*anyopaque) void {
        const self: *Supervisor = @ptrCast(@alignCast(context.?));
        const thread = self.reader orelse return;
        self.reader = null;
        thread.join();
    }

    pub fn deinit(self: *Supervisor) void {
        if (self.reader != null) _ = self.stop();
        if (self.composed) {
            self.inbound.deinit();
            self.pump.deinit();
            self.half.deinit();
            self.slots.deinit();
        }
        self.host.deinit();
        self.* = undefined;
    }

    fn readerMain(self: *Supervisor) void {
        const stopped = self.inbound.run();
        self.ended = stopped;
        // Nothing further will arrive, so every unanswered call is unanswered
        // for good. Closing the table is what turns that from a wait into an
        // answer.
        self.slots.close();
    }

    fn deliver(
        context: ?*anyopaque,
        kind: agent_link.Kind,
        correlation: u64,
        payload: []const u8,
    ) channel.Flow {
        const self: *Supervisor = @ptrCast(@alignCast(context.?));
        switch (kind) {
            .response => {
                const owned = self.slots.allocator.dupe(u8, payload) catch return .stop;
                // Takes the bytes either way: a response for a correlation
                // nobody awaits is still the table's to release.
                self.slots.deposit(correlation, owned);
            },
            // The event's bytes, rebuilt into the value Product's consumer
            // takes. Parsed here rather than queued raw, because a byte
            // string that does not decode means the peer is not this build,
            // and this is the thread that can say so.
            .event => {
                var event = execution_events.decode(self.allocator, payload) catch |failure| {
                    std.log.err("execution link cannot read an event: {s}", .{@errorName(failure)});
                    self.half.recordFault(.unreadable);
                    return .stop;
                };
                if (!self.pump.push(event)) {
                    // At its bound. Dropping the event is the one answer that
                    // cannot be given: a conversation missing an event is one
                    // Product commits as complete, and nothing downstream can
                    // tell those apart. In process the same depth already
                    // ends the Run it belongs to; from here only the link can
                    // be ended.
                    std.log.err("execution link is at its event bound", .{});
                    event.deinit();
                    self.half.recordFault(.events_overflowed);
                    return .stop;
                }
            },
            // The execution half saying there is something to drain. Product's
            // own consumer runs on the main loop, so this is a wake rather
            // than a delivery.
            .event_ready => _ = self.pump.wake.notify(),
            // A reverse call with nobody composed to answer it. Ending the
            // link is the restrictive answer: the alternative is an execution
            // half parked on a request this build will never answer, holding
            // the Core callback thread its Run needs.
            .ui_request => {
                std.log.err("execution link cannot answer a reverse call yet", .{});
                return .stop;
            },
            // This half's own output arriving back at it, or a frame the read
            // loop handles before the sink sees it.
            .hello, .request, .control, .ui_response, .goodbye => {
                std.log.err("execution link received {s}, which only it sends", .{@tagName(kind)});
                return .stop;
            },
        }
        return .ok;
    }
};

test "the runtime port's context is the caller's half itself" {
    // `stubs.zig` casts a `runtime` method's context straight to
    // `*client.Client`, because across the link the Runtime *is* the link. So
    // the context handed out has to be that exact field. A wrapper around it
    // would not fail the cast -- it would read the wrong bytes as a Client,
    // which is the failure class this whole change exists to remove rather
    // than relocate.
    var supervisor: Supervisor = undefined;
    supervisor.composed = true;
    const given = supervisor.runtimePort();
    try std.testing.expectEqual(
        @as(?*anyopaque, @ptrCast(&supervisor.half)),
        given.context,
    );
    try std.testing.expectEqual(&agent_link.stubs.runtimePort, given.vtable);
}
