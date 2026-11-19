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
//! ## Why requests are answered on workers
//!
//! `method.caller` marks four methods `.worker`, and `run.execute` is the
//! reason: it blocks until the Run reaches a terminal. Answering it on the
//! thread that reads frames would stop the link from reading for the length
//! of a Run -- so a Stop, which is registered on the control transport
//! precisely so it can overtake queued fragments, could never arrive. The
//! reader therefore only queues, and a small pool answers.
//!
//! The queue is bounded and the reader blocks when it is full. That is
//! deliberate: blocking the reader is backpressure on a pipe, which the peer
//! feels as a slow link rather than as a refusal, and a refusal is not
//! something a request frame can carry.

const std = @import("std");

const agent = @import("metawork_agent");
const agent_link = @import("metawork_agent_link");
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
    /// How many requests can be answered at once. One is enough to answer
    /// anything; more than one is what keeps a blocking `execute` from
    /// holding up every other call.
    workers: usize = 4,
    /// Requests the reader may queue before it blocks.
    queue_depth: usize = 16,
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
    stopping: bool = false,
    workers: []std.Thread,
    started: usize = 0,

    const InitError = std.mem.Allocator.Error || error{RuntimeUnavailable};

    fn init(
        self: *Answering,
        io: std.Io,
        allocator: std.mem.Allocator,
        factory: RuntimeFactory,
        options: Options,
    ) InitError!void {
        std.debug.assert(options.workers > 0 and options.queue_depth > 0);
        const queue = try allocator.alloc(?Queued, options.queue_depth);
        errdefer allocator.free(queue);
        @memset(queue, null);
        const workers = try allocator.alloc(std.Thread, options.workers);
        errdefer allocator.free(workers);

        self.* = .{
            .io = io,
            .allocator = allocator,
            .factory = factory,
            .runtime = undefined,
            .tables = undefined,
            .store = options.store,
            .queue = queue,
            .workers = workers,
        };
        try self.tables.init(allocator, options.tables);
        errdefer self.tables.deinit();
        // The notifier is this half's, so the Runtime cannot be built before
        // it exists -- which is why the caller passes a factory rather than a
        // Runtime.
        self.runtime = factory.create_fn(factory.context, self.notifier()) orelse
            return error.RuntimeUnavailable;
    }

    fn deinit(self: *Answering) void {
        self.factory.destroy_fn(self.factory.context, self.runtime);
        self.tables.deinit();
        self.allocator.free(self.workers);
        for (self.queue) |entry| if (entry) |queued| self.allocator.free(queued.payload);
        self.allocator.free(self.queue);
        self.* = undefined;
    }

    fn notifier(self: *Answering) agent.EventReadyNotifier {
        return .{ .context = self, .notify_fn = notifyEventsReady };
    }

    /// Carrying events is its own step. Until it lands, `.unavailable` is the
    /// honest answer and it is one the Session already handles: it stops event
    /// delivery rather than believing a consumer is there.
    fn notifyEventsReady(_: ?*anyopaque) agent.EventReadyNotification {
        return .unavailable;
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
        if (self.started == 0) return null;
        return .{ .context = self, .deliver_fn = deliver };
    }

    /// Stops accepting and waits for the answers already in flight.
    ///
    /// Waiting is the right bound even though a worker inside `execute` cannot
    /// be interrupted: the UI half's stop closes the pipe, gives this process a
    /// grace period and then kills it, so the unbounded case is already
    /// bounded from the other side.
    fn end(context: ?*anyopaque) void {
        const self: *Answering = @ptrCast(@alignCast(context.?));
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        self.condition.broadcast(self.io);
        self.mutex.unlock(self.io);
        for (self.workers[0..self.started]) |thread| thread.join();
        self.started = 0;
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
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (self.count == self.queue.len and !self.stopping)
            self.condition.waitUncancelable(self.io, &self.mutex);
        if (self.stopping) {
            self.allocator.free(owned);
            return .stop;
        }
        self.queue[(self.head + self.count) % self.queue.len] = .{
            .correlation = correlation,
            .payload = owned,
        };
        self.count += 1;
        self.condition.broadcast(self.io);
        return .ok;
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
            if (self.stopping) return null;
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
        // Waiting rather than refusing: a response is owed, and a caller
        // blocked on a correlation nobody will settle is the one failure a
        // refusal here would cause.
        _ = outbound.submitWaiting(.response, correlation, bytes) catch |failure|
            std.log.err("execution half lost a response: {s}", .{@errorName(failure)});
    }
};

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
    try std.testing.expect(responseCode(error.UnknownHandle) == null);

    // And the codes are the surface's own, not numbers invented here.
    try std.testing.expectEqual(
        error_code.encode(error.SessionCapacity),
        responseCode(error.HandleCapacity).?,
    );
}
