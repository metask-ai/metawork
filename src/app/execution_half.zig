//! What the execution half owns, assembled in one place.
//!
//! `execution_mode.zig` is the transport: it states an identity, serves frames
//! and exits. This is the layer above it -- what a process that may die
//! without warning has to have in place *before* it starts answering, and what
//! it answers *with*.
//!
//! It takes what it needs rather than resolving it. The application's
//! composition root resolves the data root and holds the build identity, and a
//! test fixture holds its own; neither fact is something this file should go
//! looking for, and a data root it accepted from a command line would be a
//! path redirect in the half that writes crash evidence.
//!
//! Why the fault record is here and not in `execution_mode.run`: this is the
//! half the isolation exists to survive. A crash whose record nobody wrote is
//! a crash nobody can attribute, which is most of what splitting the process
//! is supposed to buy -- and until this file existed, `fault.install` ran
//! after the fork in `app.run`, so the execution half had no handler at all.
//!
//! ## Why requests are answered on two kinds of thread
//!
//! `method.caller` marks four methods `.worker`, and `run.execute` is the
//! reason: it blocks until the Run reaches a terminal. Answering it on the
//! thread that reads frames would stop the link from reading for the length
//! of a Run -- so a Stop, which is registered on the control transport
//! precisely so it can overtake queued fragments, could never arrive.
//!
//! A single pool is not enough either, and the arithmetic is what says so.
//! Product runs `host_worker_count` workers -- sixteen -- and every one of
//! them can be inside `execute`. A pool of four would be fully occupied by
//! four Runs, and then a Stop or a permission answer, which are ordinary
//! requests on this side, would queue *behind* the Runs they are meant to
//! end: four Runs waiting on a permission answer that cannot be delivered is
//! a deadlock, not a slow link.
//!
//! So the split follows the registry rather than a number. A `.worker`
//! request -- the four that can block until something they started finishes
//! -- gets a thread of its own, bounded by how many the caller can have in
//! flight, which is bounded in turn by the caller's own threads: each one
//! waits for its answer. Everything else is answered by a small pool that
//! never runs a blocking method, so a Stop and a UI answer always have a free
//! thread.
//!
//! The pool's queue is bounded and the reader blocks when it is full. That is
//! deliberate: blocking the reader is backpressure on a pipe, which the peer
//! feels as a slow link rather than as a refusal, and a refusal is not
//! something a request frame can carry.

const std = @import("std");

const agent = @import("metawork_agent");
const agent_link = @import("metawork_agent_link");
const execution_events = @import("app_execution_events");
const execution_mode = @import("app_execution_mode");
const fault = @import("app_fault");

const adapters = agent_link.adapters;
const call_frame = agent_link.call_frame;
const channel = agent_link.channel;
const dispatch = agent_link.dispatch;
const envelope = agent_link.envelope;
const error_code = agent_link.error_code;

pub const Exit = execution_mode.Exit;

/// Where this half records a process-level fault.
///
/// Both fields come from the caller because both are facts about the build and
/// the installation, which this half is a participant in rather than the owner
/// of. `role` is not among them: it is always `.exec` here, and letting a
/// caller pass it would let the two halves claim the same record file.
pub const FaultRecording = struct {
    identity: fault.Identity,
    /// Canonical data root. The record lands in `<data_root>/faults/`.
    data_root: []const u8,
};

/// How the one Agent Runtime is made.
///
/// A factory rather than a Runtime, because the Runtime has to be built with
/// the notifier this half installs -- the notifier is how a Core callback
/// thread says there are events to carry -- and that notifier does not exist
/// until this half does. A factory also keeps "which AgentCore answers" with
/// the composition root: the application discovers the real one, a fixture
/// passes its own.
pub const RuntimeFactory = struct {
    context: ?*anyopaque,
    create_fn: *const fn (?*anyopaque, agent.EventReadyNotifier) ?*agent.Runtime,
    destroy_fn: *const fn (?*anyopaque, *agent.Runtime) void,
};

/// The default deadline on this half's exit, for a caller composing its
/// options that wants to say "the usual one" beside a case that does not.
pub const default_exit_deadline_ms = execution_mode.exit_deadline_default_ms;

pub const Options = struct {
    identity: agent_link.Identity,
    message_limits: agent_link.MessageLimits,
    queue_limits: agent_link.QueueLimits = .{},
    /// `null` records nothing, which is for a caller that has no data root to
    /// write into. It is never the production choice.
    fault: ?FaultRecording = null,
    /// `null` answers nothing: the link comes up, states its identity and
    /// drops what arrives. That is what a caller with no Runtime composed can
    /// honestly do, and it is what the identity tests need.
    runtime: ?RuntimeFactory = null,
    tables: adapters.Tables.Capacity = .{},
    /// Where checkpoint bytes go and come from. The empty store refuses to
    /// open anything, which is the fail-closed answer rather than accepting
    /// bytes nobody will find again.
    store: call_frame.BlobStore = call_frame.BlobStore.empty,
    /// Threads for the methods that cannot block. Small on purpose: what they
    /// answer is short, and the only requirement is that one is always free
    /// so a Stop or a UI answer is never behind a Run.
    workers: usize = 4,
    /// Requests the reader may queue for those threads before it blocks.
    queue_depth: usize = 16,
    /// Whether events also flow on a thread of their own.
    ///
    /// True everywhere but one test. The flush before every response is what
    /// *orders* events against the terminal that follows them; the drain
    /// thread is what makes them flow while a Run is still going. With both
    /// running, the drain thread wins the race in practice and the ordering
    /// rule is held by luck as far as any test can see -- so one test turns
    /// the thread off, and then only the flush can deliver anything. That is
    /// the only way the rule is observable rather than asserted.
    drain_events: bool = true,
    /// Blocking requests that can be in flight at once -- a thread each.
    ///
    /// The real bound is the caller's: a `.worker` request blocks the thread
    /// that made it until its answer arrives, so the caller cannot have more
    /// outstanding than it has threads. This is the ceiling above that, and
    /// hitting it means the caller is not the half this was built for.
    blocking_slots: usize = 64,
    /// Passed through to `execution_mode.Options.exit_deadline_ms`, which is
    /// where the bound on this half's whole exit path lives.
    exit_deadline_ms: u64 = execution_mode.exit_deadline_default_ms,
};

/// Composes this half and serves the link until it ends.
///
/// A failed fault install warns rather than refusing to start. That matches
/// what the UI half does for the same condition, and a process that would not
/// start because it could not create a diagnostic file turns a reporting gap
/// into an outage.
pub fn run(io: std.Io, allocator: std.mem.Allocator, options: Options) Exit {
    if (options.fault) |recording| fault.install(io, .{
        .role = .exec,
        .data_root = recording.data_root,
        .identity = recording.identity,
    }) catch |failure|
        std.log.warn("execution half fault capture unavailable: {s}", .{@errorName(failure)});

    const factory = options.runtime orelse return execution_mode.run(io, allocator, .{
        .identity = options.identity,
        .message_limits = options.message_limits,
        .queue_limits = options.queue_limits,
        .exit_deadline_ms = options.exit_deadline_ms,
    });

    var answering: Answering = undefined;
    answering.init(io, allocator, factory, options) catch |failure| {
        std.log.err("execution half cannot compose: {s}", .{@errorName(failure)});
        return .resource_unavailable;
    };
    defer answering.deinit();

    return execution_mode.run(io, allocator, .{
        .identity = options.identity,
        .message_limits = options.message_limits,
        .queue_limits = options.queue_limits,
        .exit_deadline_ms = options.exit_deadline_ms,
        .answering = .{
            .context = &answering,
            .begin_fn = Answering.begin,
            .end_fn = Answering.end,
        },
    });
}

/// One queued request, owning its bytes until a worker has answered it.
const Queued = struct {
    correlation: u64,
    payload: []u8,
};

/// What an entry's end means when the caller is gone.
///
/// One method per table kind, chosen by the type the table holds rather than
/// by a name: a `HeldSession` carries the Run tool capabilities its Session's
/// Runs were given, and a `BegunRun` carries references this half took on
/// that Session. Both have to be given up before the objects they point at
/// are, and both are this half's memory, which `adapters.reclamation` is the
/// record of.
///
/// Everything else in those tables is a pointer the Runtime owns and only
/// lent out, so dropping the name is the whole of what is owed: the Runtime
/// is destroyed immediately after this and takes them with it.
const Releaser = struct {
    half: *Answering,

    pub fn release(self: Releaser, comptime Held: type, value: *Held) void {
        if (Held == adapters.BegunRun) {
            // Every reference the caller never gave back. The count is the
            // one `BegunRun` keeps, which is why it has to be kept.
            _ = value.releaseOutstanding();
            self.half.allocator.destroy(value);
            return;
        }
        if (Held == agent_link.run_tools.HeldSession) {
            // Every reference the caller took on this Session through the
            // link and can no longer give back. `Session.close` waits these
            // out, so one left outstanding is a close that waits for a half
            // that is gone -- which is exactly how the first Product Run
            // over a real link ended: the process stayed alive after the
            // link died, holding the pipe it had inherited.
            _ = value.releaseReferences();
            value.retireAll();
            self.half.allocator.destroy(value);
            return;
        }
    }
};

/// One blocking request and the thread answering it.
///
/// The slot outlives the thread so the thread can be joined later: a thread
/// handle has to be joined by someone, and the someone cannot be itself.
/// `done` is what lets the reader reuse a slot without waiting -- it joins a
/// finished thread on its way past, which is the only point where joining
/// costs nothing.
const Blocking = struct {
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    half: *Answering = undefined,
    queued: Queued = undefined,

    fn main(self: *Blocking) void {
        defer self.done.store(true, .release);
        defer self.half.allocator.free(self.queued.payload);
        self.half.answer(self.queued);
    }
};

/// The Runtime, the tables it is named through, and the pool that answers.
const Answering = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    factory: RuntimeFactory,
    runtime: *agent.Runtime,
    tables: adapters.Tables,
    store: call_frame.BlobStore,
    outbound: ?*channel.Outbound = null,

    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    queue: []?Queued,
    head: usize = 0,
    count: usize = 0,
    /// Read by the drain thread under `signal_mutex` and by the pool under
    /// `mutex`, so it is atomic rather than guarded: two locks around one
    /// flag is two answers to the same question.
    stopping: std.atomic.Value(bool) = .init(false),
    workers: []std.Thread,
    started: usize = 0,
    /// A thread each, for the methods that can block until something they
    /// started finishes.
    blocking: []Blocking,

    /// The wake bit a Core callback thread sets, and the thread that acts on
    /// it. Its own mutex, held for nothing but the flag: a callback thread
    /// may be holding the Session when it arrives here, so this must never
    /// be the lock a drain is performed under.
    signal_mutex: std.Io.Mutex = .init,
    signal: std.Io.Condition = .init,
    events_ready: bool = false,
    /// Serialises draining, so the events of one Run cannot interleave with
    /// another drain and arrive out of order.
    drain_mutex: std.Io.Mutex = .init,
    drain: ?std.Thread = null,
    drain_events: bool = true,

    const InitError = std.mem.Allocator.Error || error{RuntimeUnavailable};

    fn init(
        self: *Answering,
        io: std.Io,
        allocator: std.mem.Allocator,
        factory: RuntimeFactory,
        options: Options,
    ) InitError!void {
        std.debug.assert(options.workers > 0 and options.queue_depth > 0);
        std.debug.assert(options.blocking_slots > 0);
        const queue = try allocator.alloc(?Queued, options.queue_depth);
        errdefer allocator.free(queue);
        @memset(queue, null);
        const workers = try allocator.alloc(std.Thread, options.workers);
        errdefer allocator.free(workers);
        const blocking = try allocator.alloc(Blocking, options.blocking_slots);
        errdefer allocator.free(blocking);
        @memset(blocking, .{});

        self.* = .{
            .io = io,
            .allocator = allocator,
            .factory = factory,
            .runtime = undefined,
            .tables = undefined,
            .store = options.store,
            .queue = queue,
            .workers = workers,
            .blocking = blocking,
            .drain_events = options.drain_events,
        };
        try self.tables.init(io, allocator, options.tables);
        errdefer self.tables.deinit();
        // The notifier is this half's, so the Runtime cannot be built before
        // it exists -- which is why the caller passes a factory rather than a
        // Runtime.
        self.runtime = factory.create_fn(factory.context, self.notifier()) orelse
            return error.RuntimeUnavailable;
    }

    fn deinit(self: *Answering) void {
        // Every thread this half started is joined first, whatever path got
        // here: `begin` can fail with the pool already running, and freeing
        // the queue those threads are waiting on would be a use-after-free
        // with a race in front of it.
        Answering.end(self);
        // Then every entry the caller never released, because it can no
        // longer ask. `handle_table.Table.deinit` asserts an empty table, so
        // without this a link that ended with a Session still open -- a UI
        // that exited mid-Run, which is the case the isolation is *for* --
        // panicked this half on its way out instead of exiting.
        //
        // `adapters.drainEverything` is what decides what that means per
        // table, and this is its first caller outside a test.
        _ = adapters.drainEverything(self.bindings(), Releaser{ .half = self });
        self.factory.destroy_fn(self.factory.context, self.runtime);
        self.tables.deinit();
        self.allocator.free(self.workers);
        self.allocator.free(self.blocking);
        for (self.queue) |entry| if (entry) |queued| self.allocator.free(queued.payload);
        self.allocator.free(self.queue);
        self.* = undefined;
    }

    fn notifier(self: *Answering) agent.EventReadyNotifier {
        return .{ .context = self, .notify_fn = notifyEventsReady };
    }

    /// A Core callback thread saying there are events to carry.
    ///
    /// It sets a bit and returns. Nothing else is allowed here: the caller may
    /// be holding the Session, and the drain this wakes takes the event pump's
    /// lock, which the same thread was holding moments ago.
    ///
    /// `.already_pending` rather than `.scheduled` when the bit was already
    /// set, because that is what the in-process notifier answers and what
    /// collapses a burst of events into one wake.
    fn notifyEventsReady(context: ?*anyopaque) agent.EventReadyNotification {
        const self: *Answering = @ptrCast(@alignCast(context orelse return .unavailable));
        self.signal_mutex.lockUncancelable(self.io);
        defer self.signal_mutex.unlock(self.io);
        if (self.stopping.load(.acquire)) return .unavailable;
        const already = self.events_ready;
        self.events_ready = true;
        self.signal.broadcast(self.io);
        return if (already) .already_pending else .scheduled;
    }

    fn drainMain(self: *Answering) void {
        while (true) {
            self.signal_mutex.lockUncancelable(self.io);
            while (!self.events_ready and !self.stopping.load(.acquire))
                self.signal.waitUncancelable(self.io, &self.signal_mutex);
            const ending = self.stopping.load(.acquire);
            self.events_ready = false;
            self.signal_mutex.unlock(self.io);

            // Flushed before the check, so an event enqueued while this half
            // was being told to stop still crosses: the UI is still reading
            // until its own stop closes the pipe.
            if (self.flushEvents() > 0) self.submitReady();
            if (ending) return;
        }
    }

    /// Sends every event the Runtime's pump holds, and says how many.
    ///
    /// Called from the drain thread and from every response: a Run's terminal
    /// rides the same ordered queue as its events, so the events enqueued
    /// before it has to be *submitted* before it. `method.zig` pins that
    /// ordering, and it is what lets the caller read "my buffer holds nothing
    /// for this route" as "every event of that terminal's Run has arrived".
    fn flushEvents(self: *Answering) usize {
        const outbound = self.outbound orelse return 0;
        self.drain_mutex.lockUncancelable(self.io);
        defer self.drain_mutex.unlock(self.io);
        var sent: usize = 0;
        while (self.runtime.takeEvent()) |taken| {
            var event = taken;
            defer event.deinit();
            // An event that cannot be encoded is an event that is gone, and a
            // conversation missing an event is one Product would commit as
            // complete. Nothing downstream can tell those apart, so this half
            // ends instead of carrying on one event short.
            const bytes = execution_events.encode(self.allocator, &event) catch
                eventLost(error.OutOfMemory);
            defer self.allocator.free(bytes);
            _ = outbound.submitWaiting(.event, 0, bytes) catch |failure|
                eventLost(failure);
            sent += 1;
        }
        return sent;
    }

    fn submitReady(self: *Answering) void {
        const outbound = self.outbound orelse return;
        _ = outbound.submitWaiting(.event_ready, 0, &.{}) catch |failure|
            std.log.err("execution half lost an event wake: {s}", .{@errorName(failure)});
    }

    fn bindings(self: *Answering) adapters.Bindings {
        return self.tables.bindings(
            self.allocator,
            self.runtime.runtimePort(),
            self.store,
        );
    }

    fn begin(
        context: ?*anyopaque,
        io: std.Io,
        outbound: *channel.Outbound,
    ) ?channel.Sink {
        const self: *Answering = @ptrCast(@alignCast(context.?));
        self.io = io;
        self.outbound = outbound;
        for (self.workers) |*thread| {
            thread.* = std.Thread.spawn(.{}, workerMain, .{self}) catch break;
            self.started += 1;
        }
        // Its own thread, because events have to flow while a Run is running
        // rather than only when something else is answered. A response flushes
        // too, for ordering; this is what makes the stream live.
        if (self.drain_events)
            self.drain = std.Thread.spawn(.{}, drainMain, .{self}) catch null;
        // A half that cannot answer must not pretend to: refusing here is
        // what makes the process exit with `resource_unavailable` instead of
        // serving a link that drops everything. `end` is what stops whatever
        // did start, and `deinit` calls it on every path.
        if (self.started == 0 or (self.drain_events and self.drain == null)) return null;
        return .{ .context = self, .deliver_fn = deliver };
    }

    /// Stops accepting and waits for the answers already in flight.
    ///
    /// The waiting is unbounded here on purpose, and bounded from one place
    /// outside: `execution_mode.run` arms `exit_deadline` the moment the link
    /// ends, which is before this is called. So this is free to wait for a
    /// worker inside `execute` -- which only its own Run can release -- and a
    /// Run that never reaches a terminal costs the process its deadline
    /// rather than its exit.
    ///
    /// It used to say the bound was the UI half's kill. That bound exists
    /// only while the UI is alive to use it, and the case this half is *for*
    /// is a UI that is not.
    fn end(context: ?*anyopaque) void {
        const self: *Answering = @ptrCast(@alignCast(context.?));
        self.stopping.store(true, .release);
        self.mutex.lockUncancelable(self.io);
        self.condition.broadcast(self.io);
        self.mutex.unlock(self.io);
        self.signal_mutex.lockUncancelable(self.io);
        self.signal.broadcast(self.io);
        self.signal_mutex.unlock(self.io);
        for (self.workers[0..self.started]) |thread| thread.join();
        self.started = 0;
        if (self.drain) |thread| {
            thread.join();
            self.drain = null;
        }
        // A blocking request cannot be interrupted -- a worker inside
        // `execute` returns when its Run reaches a terminal and not before.
        // This waits for it anyway, inside the deadline the link's end armed;
        // see this function's own note on where that bound lives now.
        for (self.blocking) |*slot| if (slot.thread) |thread| {
            thread.join();
            slot.thread = null;
        };
    }

    fn deliver(
        context: ?*anyopaque,
        kind: agent_link.Kind,
        correlation: u64,
        payload: []const u8,
    ) channel.Flow {
        const self: *Answering = @ptrCast(@alignCast(context.?));
        switch (kind) {
            // A call, a control-transport call, and the answer to a parked UI
            // request. All three are method invocations; the kind says which
            // queue they travelled on and what they may overtake, not what
            // they are.
            .request, .control, .ui_response => {},
            // Everything else is this half's own output arriving back at it,
            // which means the peer is not the other half of this link.
            .hello, .event, .event_ready, .response, .ui_request, .goodbye => {
                std.log.err("execution half received {s}, which only it sends", .{@tagName(kind)});
                return .stop;
            },
        }
        const owned = self.allocator.dupe(u8, payload) catch return .stop;
        var kept = false;
        defer if (!kept) self.allocator.free(owned);
        if (self.stopping.load(.acquire)) return .stop;

        // A method that can block gets a thread of its own. Which methods
        // those are is the registry's answer, not a list here: `.worker` is
        // the column that says "this one may wait for something it started".
        if (blockingRequest(payload)) {
            const slot = self.freeBlockingSlot() orelse {
                // Above the ceiling, which means the caller has more
                // outstanding than it has threads to wait on them with. No
                // thread to answer on, and this one must not block: the
                // reader is what a Stop arrives through.
                self.refuse(correlation, error.OutOfMemory);
                return .ok;
            };
            slot.* = .{
                .half = self,
                .queued = .{ .correlation = correlation, .payload = owned },
            };
            slot.thread = std.Thread.spawn(.{}, Blocking.main, .{slot}) catch {
                slot.* = .{};
                self.refuse(correlation, error.OutOfMemory);
                return .ok;
            };
            kept = true;
            return .ok;
        }

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (self.count == self.queue.len and !self.stopping.load(.acquire))
            self.condition.waitUncancelable(self.io, &self.mutex);
        if (self.stopping.load(.acquire)) return .stop;
        self.queue[(self.head + self.count) % self.queue.len] = .{
            .correlation = correlation,
            .payload = owned,
        };
        self.count += 1;
        kept = true;
        self.condition.broadcast(self.io);
        return .ok;
    }

    /// A slot with no thread in it, joining one that has finished on the way.
    ///
    /// Joining here is what makes the slots reusable without a thread that
    /// outlives the link: a finished thread is cheap to join, and this is the
    /// only place that passes one.
    fn freeBlockingSlot(self: *Answering) ?*Blocking {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.blocking) |*slot| {
            if (slot.thread) |thread| {
                if (!slot.done.load(.acquire)) continue;
                thread.join();
                slot.* = .{};
            }
            return slot;
        }
        return null;
    }

    /// Answers a request this half will not perform, on the reader's thread.
    ///
    /// Only for the conditions that have no thread to answer on. It is two
    /// bytes, so the wait it can meet is the writer draining rather than a
    /// consumer that may never come back.
    fn refuse(self: *Answering, correlation: u64, failure: error_code.LinkError) void {
        var header: [envelope.header_bytes]u8 = undefined;
        envelope.encodeResponseHeader(&header, error_code.encode(failure));
        self.submit(correlation, &header);
    }

    fn take(self: *Answering) ?Queued {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (true) {
            if (self.count > 0) {
                const queued = self.queue[self.head].?;
                self.queue[self.head] = null;
                self.head = (self.head + 1) % self.queue.len;
                self.count -= 1;
                self.condition.broadcast(self.io);
                return queued;
            }
            if (self.stopping.load(.acquire)) return null;
            self.condition.waitUncancelable(self.io, &self.mutex);
        }
    }

    fn workerMain(self: *Answering) void {
        while (self.take()) |queued| {
            defer self.allocator.free(queued.payload);
            self.answer(queued);
        }
    }

    fn answer(self: *Answering, queued: Queued) void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const bytes = self.perform(arena.allocator(), queued.payload) catch |failure| {
            const code = responseCode(failure) orelse unanswerable(failure);
            var header: [envelope.header_bytes]u8 = undefined;
            envelope.encodeResponseHeader(&header, code);
            self.submit(queued.correlation, &header);
            return;
        };
        self.submit(queued.correlation, bytes);
    }

    fn perform(
        self: *Answering,
        arena: std.mem.Allocator,
        request: []const u8,
    ) dispatch.InvokeError![]u8 {
        return dispatch.invoke(arena, self.bindings(), try dispatch.classify(request));
    }

    fn submit(self: *Answering, correlation: u64, bytes: []const u8) void {
        const outbound = self.outbound.?;
        // Before the response, never after: a Run's terminal travels on the
        // same ordered queue as its events, and an event queued behind its own
        // terminal would reach a caller that had already read the stream as
        // complete.
        _ = self.flushEvents();
        // Waiting rather than refusing: a response is owed, and a caller
        // blocked on a correlation nobody will settle is the one failure a
        // refusal here would cause.
        _ = outbound.submitWaiting(.response, correlation, bytes) catch |failure|
            std.log.err("execution half lost a response: {s}", .{@errorName(failure)});
    }
};

/// Whether this request names a method that can block until something it
/// started finishes.
///
/// Read off the registry's `caller` column rather than from a list here: that
/// column exists to say which thread may start a method, and `.worker` is
/// exactly "this one may block as long as it likes, because blocking is what
/// that thread already does". A request this half cannot classify is not one
/// of them -- it is refused by the pool, which is where a refusal belongs.
fn blockingRequest(payload: []const u8) bool {
    const request = dispatch.classify(payload) catch return false;
    return request.entry.caller == .worker;
}

/// The wire code for a dispatch failure, or `null` when there is none.
///
/// Absence lands on the restrictive side on purpose: a failure with no honest
/// code ends the process rather than being answered with a near-miss, because
/// a near-miss is a fact about the Session that nobody established.
fn responseCode(failure: dispatch.InvokeError) ?u16 {
    return switch (failure) {
        error.OutOfMemory => error_code.encode(error.OutOfMemory),
        // A full table is this half at its bound for another object of that
        // kind, which is what the surface already calls `SessionCapacity` --
        // and what Product already has a path for.
        error.HandleCapacity,
        error.GenerationExhausted,
        => error_code.encode(error.SessionCapacity),
        // An id this half no longer holds. It was ending the process, on the
        // argument that the caller's own box table refuses a stale handle
        // before sending, so arriving here means a defect. That argument
        // holds as far as I can construct it -- every stale case I can follow
        // is refused locally -- but the consequence if it is wrong is one
        // Task's stale handle ending every other Task's Run, and the cost of
        // not relying on it is one response.
        //
        // `DependencyUnreachable` rather than a near-miss: the object the
        // request named is gone, which is what each stub turns into its own
        // restricting answer. Nothing is retried and nothing is claimed about
        // the far side's state, so the single failure model is intact.
        error.UnknownHandle => error_code.encode(error.DependencyUnreachable),
        else => null,
    };
}

/// A request this half cannot answer at all.
///
/// Ending the process is the single failure model applied to the one case
/// where answering is impossible. The alternative is a caller blocked forever
/// on a correlation nobody will settle, which is worse than the crash this
/// whole change exists to contain: the UI survives a dead execution process
/// and does not survive a Task that never finishes.
///
/// Every failure that reaches here is a statement about the peer or about this
/// build -- an unregistered method, a payload that does not decode, a handle
/// this half never issued -- and the identity exchange has already ruled out a
/// peer built from other sources, so reaching it means a defect rather than a
/// skew.
fn unanswerable(failure: dispatch.InvokeError) noreturn {
    std.log.err(
        "execution half cannot answer a request ({s}); ending the process",
        .{@errorName(failure)},
    );
    std.process.exit(@intFromEnum(Exit.protocol_violation));
}

/// An event this half could not carry.
///
/// The same reasoning as `unanswerable` and a worse consequence if it were
/// tolerated: an unanswered call blocks a caller, and a lost event silently
/// shortens a conversation that Product then commits as complete. Nothing
/// downstream can tell a short conversation from a finished one, which is why
/// this ends the process rather than logging and continuing.
fn eventLost(failure: anyerror) noreturn {
    std.log.err(
        "execution half cannot carry an event ({s}); ending the process",
        .{@errorName(failure)},
    );
    std.process.exit(@intFromEnum(Exit.transport_failed));
}

/// A request header for one method, which is all `blockingRequest` reads.
fn headerFor(
    storage: []u8,
    comptime owner: agent_link.method.Owner,
    comptime name: []const u8,
) []const u8 {
    const entry = agent_link.method.find(agent_link.method.codeOf(owner, name)) catch
        unreachable;
    const bytes = agent_link.envelope.requestHeaderBytes(owner);
    const receiver: agent_link.handle_table.Id = if (agent_link.envelope.receiverOf(owner) == null)
        .none
    else
        .{ .slot = 1, .generation = 1 };
    agent_link.envelope.encodeRequestHeader(storage[0..bytes], entry, receiver);
    return storage[0..bytes];
}

test "the methods that get a thread of their own are the ones the registry calls worker" {
    // The split this pins prevents a deadlock, not a slowdown. A Stop travels
    // on the control transport so it can overtake queued fragments, and a
    // permission answer releases a Core callback thread a Run is waiting on
    // -- so if either could queue behind `execute`, four Runs would be enough
    // to make the answer they are waiting for undeliverable.
    var storage: [64]u8 = undefined;

    // Blocks until its Run reaches a terminal, and the same for a compact.
    try std.testing.expect(blockingRequest(headerFor(&storage, .run, "execute")));
    try std.testing.expect(blockingRequest(
        headerFor(&storage, .session, "execute_prepared_compact"),
    ));

    // The two that must never wait behind one.
    try std.testing.expect(!blockingRequest(
        headerFor(&storage, .runtime, "request_run_termination"),
    ));
    try std.testing.expect(!blockingRequest(
        headerFor(&storage, .session, "respond_permission"),
    ));
    // And an ordinary short call.
    try std.testing.expect(!blockingRequest(headerFor(&storage, .session, "set_model")));

    // Bytes that name no method are not blocking either: the pool answers
    // them, which is where a refusal belongs.
    try std.testing.expect(!blockingRequest(&[_]u8{ 0xff, 0xff }));
    try std.testing.expect(!blockingRequest(&.{}));
}

test "the role this half records under is not the caller's to choose" {
    // `FaultRecording` carries the identity and the root and nothing else, so
    // a caller cannot ask for `.ui` and overwrite the record the other half
    // left. The two file names differ, which is what makes that matter.
    try std.testing.expect(!@hasField(FaultRecording, "role"));
    try std.testing.expect(!std.mem.eql(
        u8,
        fault.recordFileName(.ui),
        fault.recordFileName(.exec),
    ));
}

test "a failure with no honest code is not answered with a near-miss" {
    // The two that are answered are the two that are true of the call: this
    // half could not allocate, and this half is at its bound for another
    // object of that kind. Everything else says something about the peer or
    // about this build, and answering it as a Session fact would send Product
    // down a path for a condition nobody established.
    try std.testing.expect(responseCode(error.OutOfMemory) != null);
    try std.testing.expect(responseCode(error.HandleCapacity) != null);
    try std.testing.expect(responseCode(error.GenerationExhausted) != null);
    try std.testing.expect(responseCode(error.UnknownMethod) == null);
    try std.testing.expect(responseCode(error.NotACall) == null);
    try std.testing.expect(responseCode(error.NotDispatchable) == null);

    // A stale handle is answered rather than fatal, and this is the
    // assertion that keeps it that way: the alternative costs one Task's
    // stale handle every other Task's Run.
    try std.testing.expectEqual(
        error_code.encode(error.DependencyUnreachable),
        responseCode(error.UnknownHandle).?,
    );

    // And the codes are the surface's own, not numbers invented here.
    try std.testing.expectEqual(
        error_code.encode(error.SessionCapacity),
        responseCode(error.HandleCapacity).?,
    );
}
