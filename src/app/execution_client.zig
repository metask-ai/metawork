//! The UI half of the execution link: the `RuntimePort` Product drives when
//! the development switch puts AgentCore in its own process.
//!
//! ## What a call is
//!
//! A request and the response matched to it. The calling thread encodes, the
//! link's writer sends, the reader deposits the answer, and the calling thread
//! decodes it. Nothing is answered for a link that is merely slow; the only
//! failure is the execution process being gone.
//!
//! ## The one failure, and what it answers
//!
//! Whoever notices the link has failed -- the reader at end of stream, a
//! caller whose send was refused, a frame that does not decode -- first sends
//! the process its termination signal, then closes the correlation table.
//! So by the time any caller sees "lost", the process holding its Session is
//! being or has been ended, and every Session, prepared Run and compact in it
//! no longer exists. That is why a lost link answers a close with `.closed`
//! and a release or a cancellation with success: those are the facts, not
//! answers chosen so that Product's never-fails paths keep not failing.
//!
//! ## Names
//!
//! A Session is a `RemoteSession`: the handle its process gave it, the
//! generation (process) it lives in, and the references Product holds on it.
//! A Run is its Session plus `(run_id, generation)`, as in process, so a
//! `RunPort` and a `RunControl` both point at the `RemoteSession`. A handle is
//! only ever resolved by the process that issued it, because each generation
//! has its own pipe.
//!
//! ## Events and credit
//!
//! Events arrive on the reader thread and go into a pump of the same type the
//! in-process Runtime uses, from which Product takes them. The reader must
//! never wait on that pump: the main thread consumes it and also waits for
//! answers that arrive behind events on the same pipe. So the execution half
//! sends an event only into room this side has granted, and the grant always
//! leaves the pump able to take everything granted. Backpressure therefore
//! lands on the execution half's own pump and its Core callbacks, which is
//! where it lands in process.

const std = @import("std");
const builtin = @import("builtin");

const agent = @import("metawork_agent");
const contract = @import("agent_contract");
const event_pump = @import("event_pump");
const checkpoint = @import("agent_checkpoint");
const checkpoint_restore = @import("agent_checkpoint_restore");
const agent_link = @import("metawork_agent_link");
const execution_host = @import("app_execution_host");

const rpc = agent_link.rpc;
const shapes = agent_link.shapes;
const payload = agent_link.payload;
const channel = agent_link.channel;
const error_code = agent_link.error_code;

const port = contract.port;
const surface = contract.surface;
const control = contract.control;

const Error = surface.Error;
const Allocating = Error || std.mem.Allocator.Error;

/// Each process's Session ids start at its generation times this, so ids a
/// dead process handed out are never handed out again.
pub const generation_span: u64 = 1 << 32;

/// The UI pump's limits: the in-process defaults, with each Session allowed
/// the whole pump, because the credit is granted for the pump as a whole.
fn pumpLimits(session_slots: usize) event_pump.Limits {
    var limits: event_pump.Limits = .{ .session_slots = session_slots };
    limits.per_session_count = limits.global_count;
    limits.per_session_bytes = limits.global_bytes;
    return limits;
}

/// What the pump can always take, whatever mix of data and control events
/// arrives: its capacity less the room it keeps for control events.
pub const credit_count: u64 = credit: {
    const limits: event_pump.Limits = .{ .session_slots = 1 };
    break :credit limits.global_count - limits.global_control_reserved_count;
};
pub const credit_bytes: u64 = credit: {
    const limits: event_pump.Limits = .{ .session_slots = 1 };
    break :credit limits.global_bytes - limits.global_control_reserved_bytes;
};

/// A credit frame goes out once this much room has been made since the
/// last, or when the pump runs dry.
const credit_batch_count: u64 = 64;
const credit_batch_bytes: u64 = 4 * 1024 * 1024;

pub const RouteRange = struct {
    first: u64,
    end: u64,
};

pub const Spawn = union(enum) {
    /// This executable with its mode flag, as the application starts it.
    self,
    /// A fixture, for tests.
    explicit: []const []const u8,
};

pub const Options = struct {
    identity: agent_link.Identity,
    message_limits: agent_link.MessageLimits,
    queue_limits: agent_link.QueueLimits,
    spawn: Spawn = .self,
    /// How Product's event consumer is woken; the same notifier an
    /// in-process Runtime would be given.
    wake: control.EventReadyNotifier,
    session_slots: usize = 100,
    pending_slots: usize = 128,
    /// Tests only: a smaller pump budget, so that holding events back is
    /// observable with a handful of them.
    credit_count_override: ?u64 = null,
};

// ---------------------------------------------------------------------------
// Owner
// ---------------------------------------------------------------------------

pub const Owner = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    options: Options,
    pump: event_pump.EventPump,

    /// Held across a spawn, so two callers do not start two processes.
    spawn_mutex: std.Io.Mutex = .init,
    /// Everything below.
    mutex: std.Io.Mutex = .init,
    current: ?*Generation = null,
    generations: std.ArrayList(*Generation) = .empty,
    started: u32 = 0,
    loss: ?RouteRange = null,
    shutting_down: bool = false,
    /// Every event the reader has put in the pump, for tests.
    events_received: std.atomic.Value(u64) = .init(0),

    pub fn init(self: *Owner, io: std.Io, allocator: std.mem.Allocator, options: Options) !void {
        self.* = .{
            .io = io,
            .allocator = allocator,
            .options = options,
            .pump = try event_pump.EventPump.init(io, allocator, pumpLimits(options.session_slots)),
        };
    }

    pub fn runtimePort(self: *Owner) port.RuntimePort {
        return .{ .context = self, .vtable = &runtime_vtable };
    }

    /// The route ids of a process that died since the last call, once.
    pub fn takeLoss(self: *Owner) ?RouteRange {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const loss = self.loss;
        self.loss = null;
        return loss;
    }

    /// The process currently running, if there is one. For tests and logs.
    pub fn currentProcessId(self: *Owner) ?std.process.Child.Id {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const generation = self.current orelse return null;
        return generation.host.child.id;
    }

    /// Frees every dead process's bookkeeping that nothing refers to any
    /// more, and sends any credit still owed. Main thread.
    pub fn sweep(self: *Owner) void {
        var finished: std.ArrayList(*Generation) = .empty;
        defer finished.deinit(self.allocator);
        self.mutex.lockUncancelable(self.io);
        var index: usize = 0;
        while (index < self.generations.items.len) {
            const generation = self.generations.items[index];
            if (generation != self.current and generation.collectable()) {
                finished.append(self.allocator, generation) catch break;
                _ = self.generations.swapRemove(index);
                continue;
            }
            index += 1;
        }
        if (self.current) |generation| self.sendCreditLocked(generation, true);
        self.mutex.unlock(self.io);
        for (finished.items) |generation| generation.destroy();
    }

    /// Ends the current process, if any, and starts no other. The link's own
    /// end is the process's signal to shut its Runtime down, and the host's
    /// grace period bounds a process that does not.
    pub fn shutdown(self: *Owner) void {
        self.spawn_mutex.lockUncancelable(self.io);
        defer self.spawn_mutex.unlock(self.io);
        self.mutex.lockUncancelable(self.io);
        self.shutting_down = true;
        const generation = self.current;
        self.current = null;
        self.mutex.unlock(self.io);
        if (generation) |value| value.stop();
    }

    /// After `shutdown` and after Product has let go of every Session.
    pub fn deinit(self: *Owner) void {
        self.shutdown();
        for (self.generations.items) |generation| {
            generation.stop();
            generation.destroy();
        }
        self.generations.deinit(self.allocator);
        self.pump.deinit();
        self.* = undefined;
    }

    /// The running process, started if there is none. `null` when one could
    /// not be started; the caller's answer is then the link's lost answer.
    fn ensure(self: *Owner) ?*Generation {
        self.spawn_mutex.lockUncancelable(self.io);
        defer self.spawn_mutex.unlock(self.io);
        self.mutex.lockUncancelable(self.io);
        if (self.shutting_down) {
            self.mutex.unlock(self.io);
            return null;
        }
        if (self.current) |generation| {
            _ = generation.in_flight.fetchAdd(1, .acq_rel);
            self.mutex.unlock(self.io);
            return generation;
        }
        self.started += 1;
        const number = self.started;
        self.mutex.unlock(self.io);

        const generation = Generation.start(self, number) orelse return null;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.generations.append(self.allocator, generation) catch {
            self.mutex.unlock(self.io);
            generation.stop();
            generation.destroy();
            self.mutex.lockUncancelable(self.io);
            return null;
        };
        self.current = generation;
        // Room for what the pump can take now: events a dead process left
        // behind are still in it, and consuming them grants this one more.
        const stats = self.pump.stats();
        generation.granted = .{
            .count = (self.options.credit_count_override orelse credit_count) -| stats.count,
            .bytes = credit_bytes -| stats.bytes,
        };
        self.sendCreditLocked(generation, true);
        _ = generation.in_flight.fetchAdd(1, .acq_rel);
        return generation;
    }

    /// The running process, without starting one.
    fn live(self: *Owner) ?*Generation {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const generation = self.current orelse return null;
        if (generation.lost.load(.acquire)) return null;
        _ = generation.in_flight.fetchAdd(1, .acq_rel);
        return generation;
    }

    fn sendCreditLocked(self: *Owner, generation: *Generation, force: bool) void {
        _ = self;
        if (generation.lost.load(.acquire)) return;
        const owed_count = generation.granted.count - generation.announced.count;
        const owed_bytes = generation.granted.bytes - generation.announced.bytes;
        if (owed_count == 0 and owed_bytes == 0) return;
        if (!force and owed_count < credit_batch_count and owed_bytes < credit_batch_bytes) return;
        var bytes: [16]u8 = undefined;
        const written = payload.encode(rpc.Credit, generation.granted, &bytes);
        // Never waits: this runs on the main thread. A frame that does not
        // fit now is made up by the next one, because it carries totals.
        const submitted = generation.host.outbound.trySubmit(.control, 0, bytes[0..written]) catch return;
        if (submitted == .queued) generation.announced = generation.granted;
    }
};

// ---------------------------------------------------------------------------
// One execution process
// ---------------------------------------------------------------------------

const Generation = struct {
    owner: *Owner,
    number: u32,
    floor: u64,
    host: execution_host.Host,
    pending: agent_link.pending.Table,
    reader: ?std.Thread = null,
    reader_done: std.atomic.Value(bool) = .init(false),
    lost: std.atomic.Value(bool) = .init(false),
    stopping: std.atomic.Value(bool) = .init(false),
    stopped: bool = false,
    /// Runtime calls still using this generation.
    in_flight: std.atomic.Value(u32) = .init(0),
    /// Sessions Product still holds, under `owner.mutex`.
    sessions: std.ArrayList(*RemoteSession) = .empty,
    /// Credit totals, under `owner.mutex`.
    granted: rpc.Credit = .{ .count = 0, .bytes = 0 },
    announced: rpc.Credit = .{ .count = 0, .bytes = 0 },

    fn start(owner: *Owner, number: u32) ?*Generation {
        const self = owner.allocator.create(Generation) catch return null;
        self.* = .{
            .owner = owner,
            .number = number,
            .floor = @as(u64, number - 1) * generation_span,
            .host = undefined,
            .pending = undefined,
        };
        self.pending.init(owner.io, owner.allocator, owner.options.pending_slots) catch {
            owner.allocator.destroy(self);
            return null;
        };

        var floor_text: [64]u8 = undefined;
        const floor_argument = std.fmt.bufPrint(&floor_text, "{s}{d}", .{
            execution_host.session_floor_flag,
            self.floor,
        }) catch unreachable;
        var argv_storage: [16][]const u8 = undefined;
        const spawn: execution_host.Host.Spawn = switch (owner.options.spawn) {
            .self => .{ .self_with = &.{floor_argument} },
            .explicit => |prefix| explicit: {
                std.debug.assert(prefix.len < argv_storage.len);
                @memcpy(argv_storage[0..prefix.len], prefix);
                argv_storage[prefix.len] = floor_argument;
                break :explicit .{ .explicit = argv_storage[0 .. prefix.len + 1] };
            },
        };
        const failure = self.host.start(
            owner.io,
            owner.allocator,
            owner.options.identity,
            owner.options.queue_limits,
            spawn,
        ) catch {
            self.pending.deinit();
            owner.allocator.destroy(self);
            return null;
        };
        if (failure) |value| {
            std.log.warn("execution process did not start: {any}", .{value});
            self.pending.deinit();
            owner.allocator.destroy(self);
            return null;
        }
        self.host.settle = .{ .context = self, .settle_fn = settleReader };
        self.reader = std.Thread.spawn(
            .{ .stack_size = channel.io_thread_stack_bytes },
            readerMain,
            .{self},
        ) catch {
            self.stopping.store(true, .release);
            _ = self.host.stop();
            self.host.deinit();
            self.pending.deinit();
            owner.allocator.destroy(self);
            return null;
        };
        return self;
    }

    /// The process is gone, or is about to be: say so once.
    fn lose(self: *Generation) void {
        if (self.lost.swap(true, .acq_rel)) return;
        const stopping = self.stopping.load(.acquire);
        // The signal before anything else answers, so that every answer
        // given for this process is true of a process that is ending.
        if (!stopping) self.host.terminate();
        self.pending.close();
        const owner = self.owner;
        owner.mutex.lockUncancelable(owner.io);
        if (owner.current == self) owner.current = null;
        if (!stopping) {
            const range: RouteRange = .{ .first = self.floor, .end = self.floor + generation_span };
            owner.loss = if (owner.loss) |earlier| .{
                .first = @min(earlier.first, range.first),
                .end = @max(earlier.end, range.end),
            } else range;
        }
        owner.mutex.unlock(owner.io);
        _ = owner.options.wake.notify();
    }

    fn stop(self: *Generation) void {
        if (self.stopped) return;
        self.stopped = true;
        self.stopping.store(true, .release);
        _ = self.host.stop();
        // The settle hook joined the reader; anything left waiting is told
        // the link is gone.
        self.lose();
    }

    fn collectable(self: *Generation) bool {
        return self.lost.load(.acquire) and
            self.reader_done.load(.acquire) and
            self.in_flight.load(.acquire) == 0 and
            self.sessions.items.len == 0;
    }

    fn destroy(self: *Generation) void {
        const allocator = self.owner.allocator;
        if (!self.stopped) self.stop();
        if (self.reader) |thread| thread.join();
        self.reader = null;
        self.host.deinit();
        self.pending.deinit();
        for (self.sessions.items) |remote| remote.destroy(allocator);
        self.sessions.deinit(allocator);
        allocator.destroy(self);
    }

    fn settleReader(context: ?*anyopaque) void {
        const self: *Generation = @ptrCast(@alignCast(context.?));
        if (self.reader) |thread| thread.join();
        self.reader = null;
    }

    fn release(self: *Generation) void {
        _ = self.in_flight.fetchSub(1, .acq_rel);
    }
};

fn readerMain(self: *Generation) void {
    defer {
        self.reader_done.store(true, .release);
        _ = self.owner.options.wake.notify();
    }
    var inbound: channel.Inbound = undefined;
    inbound.init(
        self.owner.io,
        self.owner.allocator,
        &self.host.reader.interface,
        self.owner.options.message_limits,
        .{ .context = self, .deliver_fn = deliverFrame },
    ) catch return self.lose();
    _ = inbound.run();
    inbound.deinit();
    self.lose();
}

fn deliverFrame(context: ?*anyopaque, kind: agent_link.Kind, correlation: u64, bytes: []const u8) channel.Flow {
    const self: *Generation = @ptrCast(@alignCast(context.?));
    const owner = self.owner;
    switch (kind) {
        .response => {
            const owned = owner.allocator.dupe(u8, bytes) catch return .stop;
            self.pending.deposit(correlation, owned);
            return .ok;
        },
        .event => {
            var empty: [0]u8 = .{};
            var no_arena = std.heap.FixedBufferAllocator.init(&empty);
            const value = payload.decodeExact(rpc.Event, no_arena.allocator(), bytes) catch return .stop;
            var event = buildEvent(owner.allocator, value) catch return .stop;
            // Never waits: the grant guarantees room. A refusal means the far
            // side sent past its grant, which ends the link.
            owner.pump.enqueue(event) catch {
                event.deinit();
                return .stop;
            };
            _ = owner.events_received.fetchAdd(1, .acq_rel);
            _ = owner.options.wake.notify();
            return .ok;
        },
        else => return .stop,
    }
}

fn buildEvent(allocator: std.mem.Allocator, value: rpc.Event) !contract.OwnedCoreEvent {
    const json = try allocator.dupe(u8, value.json);
    errdefer allocator.free(json);
    return .{
        .session_id = value.session_id,
        .run_id = value.run_id,
        .encoded_bytes = @intCast(value.encoded_bytes),
        .json = json,
        // The Agent's own decoder, which is also the check that these are
        // the bytes they claim to be.
        .event = try agent.decodeCoreEvent(allocator, json),
        .allocator = allocator,
    };
}

// ---------------------------------------------------------------------------
// Calls
// ---------------------------------------------------------------------------

fn Reply(comptime method: rpc.Method) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        bytes: []u8,
        answer: rpc.Answer(method),
        allocator: std.mem.Allocator,

        fn deinit(self: *@This()) void {
            self.arena.deinit();
            std.crypto.secureZero(u8, self.bytes);
            self.allocator.free(self.bytes);
        }
    };
}

/// One call, answered or lost. `null` is lost.
fn call(
    generation: *Generation,
    comptime method: rpc.Method,
    handle: u64,
    request: rpc.Request(method),
) ?Reply(method) {
    if (generation.lost.load(.acquire)) return null;
    const allocator = generation.owner.allocator;
    const bytes = rpc.encodeRequest(method, allocator, handle, request) catch {
        generation.lose();
        return null;
    };
    defer {
        std.crypto.secureZero(u8, bytes);
        allocator.free(bytes);
    }
    const correlation = generation.pending.openWaiting() catch {
        generation.lose();
        return null;
    };
    const submitted = generation.host.outbound.submitWaiting(.request, correlation, bytes) catch {
        generation.pending.discardUnsent(correlation);
        generation.lose();
        return null;
    };
    if (submitted != .queued) {
        generation.pending.discardUnsent(correlation);
        generation.lose();
        return null;
    }
    switch (generation.pending.claim(correlation)) {
        .link_closed => return null,
        .response => |response| {
            var reply: Reply(method) = .{
                .arena = .init(allocator),
                .bytes = response,
                .answer = undefined,
                .allocator = allocator,
            };
            reply.answer = rpc.decodeResponse(method, reply.arena.allocator(), response) catch {
                reply.deinit();
                generation.lose();
                return null;
            };
            return reply;
        },
    }
}

/// The far side's error, in the caller's own set. A number outside it is a
/// peer that is not this build, which the gone answer covers.
fn narrow(comptime Set: type, err: error_code.LinkError) Set {
    inline for (@typeInfo(Set).error_set.?) |member| {
        if (err == @field(anyerror, member.name)) return @field(Set, member.name);
    }
    return error.DependencyUnreachable;
}

// ---------------------------------------------------------------------------
// Sessions
// ---------------------------------------------------------------------------

const RemoteSession = struct {
    generation: *Generation,
    handle: u64,
    route_id: u64,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    /// Product's Access references and Run control leases together: in
    /// process a close waits for both before it returns.
    refs: u32 = 0,
    closing: bool = false,
    workspace_root: ?[]u8 = null,

    fn io(self: *RemoteSession) std.Io {
        return self.generation.owner.io;
    }

    fn retain(self: *RemoteSession) bool {
        self.mutex.lockUncancelable(self.io());
        defer self.mutex.unlock(self.io());
        if (self.closing) return false;
        self.refs += 1;
        return true;
    }

    fn release(self: *RemoteSession) void {
        self.mutex.lockUncancelable(self.io());
        defer self.mutex.unlock(self.io());
        std.debug.assert(self.refs > 0);
        self.refs -= 1;
        self.condition.broadcast(self.io());
    }

    fn sessionPort(self: *RemoteSession) port.SessionPort {
        return .{ .context = self, .vtable = &session_vtable };
    }

    fn runControl(self: *RemoteSession, run_id: u64, generation: u64) port.RunControl {
        return .{ .context = self, .vtable = &control_vtable, .run_id = run_id, .generation = generation };
    }

    fn lost(self: *RemoteSession) bool {
        return self.generation.lost.load(.acquire);
    }

    fn destroy(self: *RemoteSession, allocator: std.mem.Allocator) void {
        if (self.workspace_root) |value| allocator.free(value);
        allocator.destroy(self);
    }
};

fn remoteOf(context: ?*anyopaque) *RemoteSession {
    return @ptrCast(@alignCast(context.?));
}

fn ownerOf(context: ?*anyopaque) *Owner {
    return @ptrCast(@alignCast(context.?));
}

fn adopt(generation: *Generation, route_id: u64, handle: u64) ?*RemoteSession {
    const owner = generation.owner;
    const remote = owner.allocator.create(RemoteSession) catch return null;
    remote.* = .{ .generation = generation, .handle = handle, .route_id = route_id };
    owner.mutex.lockUncancelable(owner.io);
    defer owner.mutex.unlock(owner.io);
    generation.sessions.append(owner.allocator, remote) catch {
        owner.allocator.destroy(remote);
        return null;
    };
    return remote;
}

/// A Session this half cannot name is closed and released on the far side,
/// best effort; if the link is gone, so is the Session.
fn discardUnnamed(generation: *Generation, handle: u64) void {
    if (call(generation, .close, handle, .{ .interruption = .session_close })) |reply| {
        var value = reply;
        value.deinit();
    }
    if (call(generation, .release_closed_session, handle, .{})) |reply| {
        var value = reply;
        value.deinit();
    }
}

fn forget(remote: *RemoteSession) void {
    const generation = remote.generation;
    const owner = generation.owner;
    owner.mutex.lockUncancelable(owner.io);
    for (generation.sessions.items, 0..) |item, index| if (item == remote) {
        _ = generation.sessions.swapRemove(index);
        break;
    };
    owner.mutex.unlock(owner.io);
    remote.destroy(owner.allocator);
    _ = owner.options.wake.notify();
}

// ---------------------------------------------------------------------------
// RuntimePort
// ---------------------------------------------------------------------------

fn runtimeCreateSessionRoute(context: ?*anyopaque, options: surface.SessionOpenOptions) Allocating!port.SessionRoute {
    const owner = ownerOf(context);
    const wire_options = rpc.openOptionsToWire(options) catch return error.DependencyUnreachable;
    const generation = owner.ensure() orelse return error.DependencyUnreachable;
    defer generation.release();
    var reply = call(generation, .create_session, 0, wire_options) orelse return error.DependencyUnreachable;
    defer reply.deinit();
    const route = switch (reply.answer) {
        .err => |err| return narrow(Allocating, err),
        .ok => |value| value,
    };
    const remote = adopt(generation, route.route_id, route.handle) orelse {
        discardUnnamed(generation, route.handle);
        return error.OutOfMemory;
    };
    return .{ .id = route.route_id, .session = remote.sessionPort() };
}

/// Reads the caller's checkpoint through its own source, on its own thread,
/// up to one byte past the limit: a restore sees what was there, and one
/// past the limit is enough for it to refuse.
fn readSource(
    allocator: std.mem.Allocator,
    source: checkpoint_restore.Source,
    hard_bytes: u64,
    out: *std.ArrayList(u8),
) std.mem.Allocator.Error!checkpoint_restore.SourceReadResult {
    const ceiling: usize = @intCast(@min(hard_bytes + 1, std.math.maxInt(usize)));
    while (out.items.len < ceiling) {
        try out.ensureUnusedCapacity(allocator, @min(64 * 1024, ceiling - out.items.len));
        const room = out.unusedCapacitySlice();
        const target = room[0..@min(room.len, ceiling - out.items.len)];
        const result = source.read_fn(source.context, target);
        switch (result) {
            .bytes => |count| {
                if (count == 0 or count > target.len) return result;
                out.items.len += count;
            },
            else => return result,
        }
    }
    return .eof;
}

fn runtimeRestoreSessionRoute(context: ?*anyopaque, options: surface.SessionRestoreOptions) Allocating!port.SessionRestoreRoute {
    const owner = ownerOf(context);
    const wire_session = rpc.openOptionsToWire(options.session) catch return error.DependencyUnreachable;
    var bytes: std.ArrayList(u8) = .empty;
    defer {
        std.crypto.secureZero(u8, bytes.items);
        bytes.deinit(owner.allocator);
    }
    const end = try readSource(owner.allocator, options.source, options.checkpoint_limits.hard_bytes, &bytes);
    const generation = owner.ensure() orelse return error.DependencyUnreachable;
    defer generation.release();
    var reply = call(generation, .restore_session, 0, .{
        .session = wire_session,
        .checkpoint_limits = options.checkpoint_limits,
        .expectation = .{
            .logical_session_id = options.expectation.logical_session_id,
            .checkpoint_generation = options.expectation.checkpoint_generation,
            .last_run_id = options.expectation.last_run_id,
            .last_compact_id = options.expectation.last_compact_id,
            .model = options.expectation.model,
        },
        .source = .{ .bytes = bytes.items, .end = end },
    }) orelse return error.DependencyUnreachable;
    defer reply.deinit();
    const route = switch (reply.answer) {
        .err => |err| return narrow(Allocating, err),
        .ok => |value| value,
    };
    const remote = adopt(generation, route.route_id, route.handle) orelse {
        discardUnnamed(generation, route.handle);
        return error.OutOfMemory;
    };
    return .{ .id = route.route_id, .session = remote.sessionPort(), .report = route.report };
}

fn runtimeReleaseClosedSession(_: ?*anyopaque, session: port.SessionPort) Error!void {
    const remote = remoteOf(session.context);
    if (!remote.lost()) if (call(remote.generation, .release_closed_session, remote.handle, .{})) |reply| {
        var value = reply;
        defer value.deinit();
        switch (value.answer) {
            .err => |err| return narrow(Error, err),
            .ok => {},
        }
    };
    // Released, or its process is gone and the Session with it.
    forget(remote);
}

fn runtimeTakeEvent(context: ?*anyopaque) ?contract.OwnedCoreEvent {
    const owner = ownerOf(context);
    owner.mutex.lockUncancelable(owner.io);
    defer owner.mutex.unlock(owner.io);
    // Taken and granted under one lock, so a process started meanwhile is
    // granted from a count that already includes this one.
    const event = owner.pump.takeFair();
    if (owner.current) |generation| {
        if (event) |value| {
            generation.granted.count += 1;
            generation.granted.bytes += value.encoded_bytes;
        }
        owner.sendCreditLocked(generation, event == null);
    }
    return event;
}

fn runtimeHasPendingEvents(context: ?*anyopaque) bool {
    return ownerOf(context).pump.stats().count != 0;
}

fn runtimePendingEventCount(context: ?*anyopaque, session_id: u64) usize {
    return ownerOf(context).pump.pendingForSession(session_id);
}

fn runtimeNotifyEventConsumer(context: ?*anyopaque) control.EventReadyNotification {
    return ownerOf(context).options.wake.notify();
}

fn runtimeRequestRunTermination(context: ?*anyopaque, session_id: u64, run_id: u64, signal: control.TerminationSignal) Error!void {
    const owner = ownerOf(context);
    const generation = owner.live() orelse return error.DependencyUnreachable;
    defer generation.release();
    if (session_id < generation.floor or session_id >= generation.floor + generation_span)
        return error.DependencyUnreachable;
    var reply = call(generation, .request_run_termination, 0, .{
        .session_id = session_id,
        .run_id = run_id,
        .signal = signal,
    }) orelse return error.DependencyUnreachable;
    defer reply.deinit();
    switch (reply.answer) {
        .err => |err| return narrow(Error, err),
        .ok => {},
    }
}

fn runtimeRestoreAdmission(context: ?*anyopaque, releasing_route_id: ?u64) port.RuntimePort.RestoreAdmission {
    const owner = ownerOf(context);
    // With no process running, the answer is the one a new process would
    // give: it holds nothing yet.
    const generation = owner.live() orelse return .available;
    defer generation.release();
    const releasing: ?u64 = if (releasing_route_id) |id|
        (if (id >= generation.floor and id < generation.floor + generation_span) id else null)
    else
        null;
    var reply = call(generation, .restore_admission, 0, .{ .releasing_route_id = releasing }) orelse
        return .available;
    defer reply.deinit();
    return switch (reply.answer) {
        .ok => |value| value,
        .err => .unavailable,
    };
}

// Not offered in this step: skills, MCP, and the Run tools whose inputs they
// carry. Nothing can hand these methods a handle, because nothing that would
// issue one is ever answered.

fn runtimeActivateMcp(_: ?*anyopaque) Allocating!surface.McpActivationOutcome {
    return .empty;
}

fn runtimeCreateMcpAdmissionSelection(
    _: ?*anyopaque,
    _: *const contract.McpActivation,
    _: []const contract.McpServerAllowlist,
) Allocating!?*contract.McpSelection {
    return error.DependencyUnreachable;
}

fn runtimePrepareMcpRestoreSelection(
    _: ?*anyopaque,
    _: *const contract.McpRestoreSelection,
    _: *const contract.McpActivation,
    _: []const contract.McpActivationTool,
) Allocating!*contract.McpSelection {
    return error.DependencyUnreachable;
}

fn runtimeQuerySkillCatalog(_: ?*anyopaque, _: contract.CatalogQuery) Allocating!contract.CatalogAcquisition {
    return error.DependencyUnreachable;
}

fn runtimeReleaseSkillCatalog(_: ?*anyopaque, _: *contract.CatalogLease) Error!void {
    return error.DependencyUnreachable;
}

fn runtimeNarrowSkillRestoreInputs(_: ?*anyopaque, _: *port.SkillRestoreInputs, _: surface.SkillPolicyInput) Allocating!*port.SkillRestoreInputs {
    return error.DependencyUnreachable;
}

fn runtimeCloneSkillRestoreInputs(_: ?*anyopaque, _: *port.SkillRestoreInputs) Allocating!*port.SkillRestoreInputs {
    return error.DependencyUnreachable;
}

fn runtimeBorrowSkillRestoreInputs(_: ?*anyopaque, _: *const port.SkillRestoreInputs) ?port.SkillRestoreBorrow {
    return null;
}

fn runtimeReleaseSkillRestoreInputs(_: ?*anyopaque, _: *port.SkillRestoreInputs) Error!void {
    return error.DependencyUnreachable;
}

fn runtimeReleaseRestoreInputs(_: ?*anyopaque, _: *port.SessionRestoreInputs) Error!void {
    return error.DependencyUnreachable;
}

const runtime_vtable: port.RuntimePort.VTable = .{
    .create_session_route = runtimeCreateSessionRoute,
    .restore_session_route = runtimeRestoreSessionRoute,
    .release_closed_session = runtimeReleaseClosedSession,
    .take_event = runtimeTakeEvent,
    .has_pending_events = runtimeHasPendingEvents,
    .pending_event_count = runtimePendingEventCount,
    .notify_event_consumer = runtimeNotifyEventConsumer,
    .request_run_termination = runtimeRequestRunTermination,
    .restore_admission = runtimeRestoreAdmission,
    .activate_mcp = runtimeActivateMcp,
    .create_mcp_admission_selection = runtimeCreateMcpAdmissionSelection,
    .prepare_mcp_restore_selection = runtimePrepareMcpRestoreSelection,
    .query_skill_catalog = runtimeQuerySkillCatalog,
    .release_skill_catalog = runtimeReleaseSkillCatalog,
    .narrow_skill_restore_inputs = runtimeNarrowSkillRestoreInputs,
    .clone_skill_restore_inputs = runtimeCloneSkillRestoreInputs,
    .borrow_skill_restore_inputs = runtimeBorrowSkillRestoreInputs,
    .release_skill_restore_inputs = runtimeReleaseSkillRestoreInputs,
    .release_restore_inputs = runtimeReleaseRestoreInputs,
};

// ---------------------------------------------------------------------------
// SessionPort
// ---------------------------------------------------------------------------

/// The common shape of a Session call whose result is `Set!T` and needs no
/// conversion: the answer, the far side's error, or the gone answer.
fn sessionCall(
    remote: *RemoteSession,
    comptime method: rpc.Method,
    comptime Set: type,
    request: rpc.Request(method),
) Set!rpc.Response(method) {
    var reply = call(remote.generation, method, remote.handle, request) orelse return error.DependencyUnreachable;
    defer reply.deinit();
    return switch (reply.answer) {
        .err => |err| narrow(Set, err),
        .ok => |value| value,
    };
}

fn sessionRetainReference(context: ?*anyopaque) bool {
    return remoteOf(context).retain();
}

fn sessionReleaseReference(context: ?*anyopaque) void {
    remoteOf(context).release();
}

fn sessionStopEventDelivery(context: ?*anyopaque) void {
    const remote = remoteOf(context);
    if (call(remote.generation, .stop_event_delivery, remote.handle, .{})) |reply| {
        var value = reply;
        value.deinit();
    }
}

fn sessionCloseOutcome(context: ?*anyopaque, interruption: control.ExternalInterruption) surface.CloseOutcome {
    const remote = remoteOf(context);
    {
        remote.mutex.lockUncancelable(remote.io());
        defer remote.mutex.unlock(remote.io());
        remote.closing = true;
    }
    // The close goes first, because it is what ends a Run that may still be
    // holding a reference; then, as in process, this returns only once every
    // reference has been given back.
    var outcome: surface.CloseOutcome = .closed;
    if (call(remote.generation, .close, remote.handle, .{ .interruption = interruption })) |reply| {
        var value = reply;
        defer value.deinit();
        outcome = value.answer.ok.into() orelse .closed;
    }
    remote.mutex.lockUncancelable(remote.io());
    defer remote.mutex.unlock(remote.io());
    while (remote.refs != 0) remote.condition.waitUncancelable(remote.io(), &remote.mutex);
    // A process that went while this waited took the Session with it.
    if (remote.lost()) return .closed;
    return outcome;
}

fn sessionRefreshSkillCatalog(_: ?*anyopaque, _: *contract.CatalogLease, _: surface.SkillPolicyInput) Allocating!void {
    return error.DependencyUnreachable;
}

fn sessionSetModel(context: ?*anyopaque, model: []const u8) Error!void {
    return sessionCall(remoteOf(context), .set_model, Error, .{ .model = model });
}

fn sessionClearSkillPolicy(context: ?*anyopaque) Allocating!void {
    return sessionCall(remoteOf(context), .clear_skill_policy, Allocating, .{});
}

fn sessionSkillPolicyMatches(_: ?*anyopaque, _: *contract.CatalogLease, _: surface.SkillPolicyInput) bool {
    return false;
}

fn sessionCaptureRestoreInputs(_: ?*anyopaque) Allocating!port.SessionRestoreInputs {
    return error.DependencyUnreachable;
}

const gone_snapshot: surface.SessionSnapshot = .{
    .session_id = 0,
    .state = .poisoned,
    .workspace_root = "",
    .active_run_id = 0,
    .active_compact_id = 0,
    .pending_ui_request_id = null,
};

fn sessionSnapshot(context: ?*anyopaque) surface.SessionSnapshot {
    const remote = remoteOf(context);
    var reply = call(remote.generation, .snapshot, remote.handle, .{}) orelse return gone_snapshot;
    defer reply.deinit();
    var snapshot = reply.answer.ok;
    // The root is borrowed from the answer, which is about to go. A
    // Session's workspace is fixed when it opens, so one copy serves.
    remote.mutex.lockUncancelable(remote.io());
    defer remote.mutex.unlock(remote.io());
    if (remote.workspace_root == null)
        remote.workspace_root = remote.generation.owner.allocator.dupe(u8, snapshot.workspace_root) catch null;
    snapshot.workspace_root = remote.workspace_root orelse "";
    return snapshot;
}

fn sessionUpdatePermissionMode(context: ?*anyopaque, expected: control.PermissionMode, target: control.PermissionMode) Error!surface.PermissionModeUpdate {
    return sessionCall(remoteOf(context), .update_permission_mode, Error, .{ .expected = expected, .target = target });
}

fn sessionConversationBounds(context: ?*anyopaque) Error!surface.ConversationBounds {
    return sessionCall(remoteOf(context), .conversation_bounds, Error, .{});
}

fn sessionRewindToUserMessage(context: ?*anyopaque, position: u64) Error!surface.RewindOutcome {
    return sessionCall(remoteOf(context), .rewind_to_user_message, Error, .{ .position = position });
}

fn sessionUpdateCredential(context: ?*anyopaque, credential: []const u8) Error!void {
    return sessionCall(remoteOf(context), .update_credential, Error, .{ .credential = credential });
}

fn sessionRequestTermination(context: ?*anyopaque, run_id: u64, signal: control.TerminationSignal) Error!void {
    return sessionCall(remoteOf(context), .request_termination, Error, .{ .run_id = run_id, .signal = signal });
}

fn sessionPrepareRun(context: ?*anyopaque, input: surface.RunInput) Allocating!u64 {
    return sessionCall(remoteOf(context), .prepare_run, Allocating, .{ .input = input });
}

fn sessionPrepareRunWithTools(
    context: ?*anyopaque,
    input: surface.RunInput,
    image: ?surface.ImageGenerationRunInput,
    delivery: ?contract.FileDeliveryInput,
    mcp: ?contract.McpInstallationInput,
    video: ?contract.VideoGenerationRunInput,
) Allocating!u64 {
    // None of the four is composed when this link is in use, so a Run that
    // carries one was composed against a different Runtime.
    if (image != null or delivery != null or mcp != null or video != null) {
        std.log.warn("execution link: a Run asked for a tool this link does not carry", .{});
        return error.DependencyUnreachable;
    }
    return sessionPrepareRun(context, input);
}

const gone_begin_run: port.BeginRunOutcome = .{ .failure = .{
    .err = error.DependencyUnreachable,
    .session_disposition = .poisoned,
} };

fn sessionBeginRunOutcome(context: ?*anyopaque, run_id: u64) port.BeginRunOutcome {
    const remote = remoteOf(context);
    var reply = call(remote.generation, .begin_run, remote.handle, .{ .run_id = run_id }) orelse return gone_begin_run;
    defer reply.deinit();
    switch (reply.answer.ok) {
        .failure => |failure| return .{ .failure = failure.into() orelse return gone_begin_run },
        .run => |run| {
            // The base lease, which in process is taken inside the begin.
            // The caller holds a reference across this call, so the Session
            // cannot be closing.
            remote.mutex.lockUncancelable(remote.io());
            remote.refs += 1;
            remote.mutex.unlock(remote.io());
            return .{ .run = .{
                .context = remote,
                .vtable = &run_vtable,
                .run_id = run.run_id,
                .generation = run.generation,
                .base_lease = .{ .control = remote.runControl(run.run_id, run.generation) },
            } };
        },
    }
}

fn sessionCancelPreparedRun(context: ?*anyopaque, run_id: u64) Error!void {
    const remote = remoteOf(context);
    // A Run prepared in a process that is gone is cancelled with it.
    if (remote.lost()) return;
    sessionCall(remote, .cancel_prepared_run, Error, .{ .run_id = run_id }) catch |err| {
        if (remote.lost()) return;
        return err;
    };
}

fn sessionPrepareCompact(context: ?*anyopaque) Allocating!u64 {
    return sessionCall(remoteOf(context), .prepare_compact, Allocating, .{});
}

fn sessionCancelPreparedCompact(context: ?*anyopaque, operation_id: u64) Error!void {
    const remote = remoteOf(context);
    if (remote.lost()) return;
    sessionCall(remote, .cancel_prepared_compact, Error, .{ .operation_id = operation_id }) catch |err| {
        if (remote.lost()) return;
        return err;
    };
}

fn sessionExecutePreparedCompact(context: ?*anyopaque, operation_id: u64) Error!control.CompactTerminalResult {
    const remote = remoteOf(context);
    const value = try sessionCall(remote, .execute_prepared_compact, Error, .{ .operation_id = operation_id });
    return value.into(remote.generation.owner.allocator) catch error.DependencyUnreachable;
}

fn sessionRequestCompactCancellation(context: ?*anyopaque, operation_id: u64, interruption: control.ExternalInterruption) port.CompactCancellation!void {
    return sessionCall(remoteOf(context), .request_compact_cancellation, port.CompactCancellation, .{
        .operation_id = operation_id,
        .interruption = interruption,
    });
}

fn sessionRespondPermission(context: ?*anyopaque, run_id: u64, request_id: u64, choice: contract.PermissionChoice) Allocating!void {
    return sessionCall(remoteOf(context), .respond_permission, Allocating, .{
        .run_id = run_id,
        .request_id = request_id,
        .choice = choice,
    });
}

fn sessionFailUiRequestIdentityContract(context: ?*anyopaque, run_id: u64) Error!void {
    return sessionCall(remoteOf(context), .fail_ui_request_identity_contract, Error, .{ .run_id = run_id });
}

fn sessionPendingUiObservation(context: ?*anyopaque) ?port.SessionPort.PendingUiObservation {
    const remote = remoteOf(context);
    var reply = call(remote.generation, .pending_ui_observation, remote.handle, .{}) orelse return null;
    defer reply.deinit();
    return reply.answer.ok;
}

fn sessionPermissionStopRequest(context: ?*anyopaque) ?u64 {
    const remote = remoteOf(context);
    var reply = call(remote.generation, .permission_stop_request, remote.handle, .{}) orelse return null;
    defer reply.deinit();
    return reply.answer.ok;
}

fn sessionCopyPendingUiRequest(context: ?*anyopaque, allocator: std.mem.Allocator) Allocating!surface.PendingUiRequest {
    const remote = remoteOf(context);
    var reply = call(remote.generation, .copy_pending_ui_request, remote.handle, .{}) orelse return error.DependencyUnreachable;
    defer reply.deinit();
    return switch (reply.answer) {
        .err => |err| narrow(Allocating, err),
        .ok => |value| try value.into(allocator),
    };
}

fn sessionExportCheckpoint(
    context: ?*anyopaque,
    limits: checkpoint.Limits,
    sink: checkpoint.Sink,
    expected_last_run_id: u64,
    expected_last_compact_id: u64,
    expected_model: []const u8,
) Error!checkpoint.Outcome {
    const remote = remoteOf(context);
    var reply = call(remote.generation, .export_checkpoint, remote.handle, .{
        .limits = limits,
        .expected_last_run_id = expected_last_run_id,
        .expected_last_compact_id = expected_last_compact_id,
        .expected_model = expected_model,
    }) orelse return error.DependencyUnreachable;
    defer reply.deinit();
    const exported = switch (reply.answer) {
        .err => |err| return narrow(Error, err),
        .ok => |value| value,
    };
    switch (exported.outcome) {
        .failure => |failure| return .{ .failure = failure },
        .success => {},
    }
    // The bytes go into the caller's own sink on the caller's own thread,
    // in the chunks Core would have used.
    var offset: usize = 0;
    while (offset < exported.bytes.len) {
        const count = @min(@as(usize, limits.chunk_bytes), exported.bytes.len - offset);
        const written = sink.write_fn(sink.context, exported.bytes[offset..][0..count]);
        if (written != .ok) return .{ .failure = checkpoint.sinkWriteFailure(written) };
        offset += count;
    }
    return exported.outcome.into(remote.generation.owner.allocator) catch .{ .failure = .{
        .stage = .describe,
        .reason = .host_out_of_memory,
        .disposition = .reusable,
    } };
}

const session_vtable: port.SessionPort.VTable = .{
    .retain_reference = sessionRetainReference,
    .release_reference = sessionReleaseReference,
    .stop_event_delivery = sessionStopEventDelivery,
    .close_outcome = sessionCloseOutcome,
    .refresh_skill_catalog = sessionRefreshSkillCatalog,
    .set_model = sessionSetModel,
    .clear_skill_policy = sessionClearSkillPolicy,
    .skill_policy_matches = sessionSkillPolicyMatches,
    .capture_restore_inputs = sessionCaptureRestoreInputs,
    .snapshot = sessionSnapshot,
    .update_permission_mode = sessionUpdatePermissionMode,
    .conversation_bounds = sessionConversationBounds,
    .rewind_to_user_message = sessionRewindToUserMessage,
    .update_credential = sessionUpdateCredential,
    .request_termination = sessionRequestTermination,
    .prepare_run = sessionPrepareRun,
    .prepare_run_with_tools = sessionPrepareRunWithTools,
    .begin_run_outcome = sessionBeginRunOutcome,
    .cancel_prepared_run = sessionCancelPreparedRun,
    .prepare_compact = sessionPrepareCompact,
    .cancel_prepared_compact = sessionCancelPreparedCompact,
    .execute_prepared_compact = sessionExecutePreparedCompact,
    .request_compact_cancellation = sessionRequestCompactCancellation,
    .respond_permission = sessionRespondPermission,
    .fail_ui_request_identity_contract = sessionFailUiRequestIdentityContract,
    .pending_ui_observation = sessionPendingUiObservation,
    .permission_stop_request = sessionPermissionStopRequest,
    .copy_pending_ui_request = sessionCopyPendingUiRequest,
    .export_checkpoint = sessionExportCheckpoint,
};

// ---------------------------------------------------------------------------
// RunPort and RunControl
// ---------------------------------------------------------------------------

/// A Run whose process is gone: interrupted because its Session closed with
/// the process. `raw_status_code` stays null -- Core was not reached for this
/// answer -- which is what routes it to the signal rather than to a failure,
/// and `event_delivery_lost` says the events before it may be missing, so
/// the Run is not sealed as a complete one.
fn goneTerminal(allocator: std.mem.Allocator) control.TerminalResult {
    return .{
        .allocator = allocator,
        .diagnostic_storage = &.{},
        .diagnostic_len = 0,
        .diagnostic_truncated = false,
        .abi_status = null,
        .raw_status_code = null,
        .stop_reason = null,
        .raw_stop_reason_code = null,
        .abort_status = null,
        .raw_abort_status_code = null,
        .termination_signal = .{ .interrupted = .session_close },
        .file_changes_lost = false,
        .event_delivery_lost = true,
        .receipts = .{},
        .failure = null,
        .session_disposition_at_completion = .poisoned,
        .durable_budget = null,
        .input_counts = null,
        .first_callback_rejection = null,
        .first_host_failure = null,
        .controlled_callback_close = null,
        .model_error = null,
    };
}

fn runExecute(context: ?*anyopaque, run_id: u64, generation: u64) control.TerminalResult {
    const remote = remoteOf(context);
    const allocator = remote.generation.owner.allocator;
    var reply = call(remote.generation, .run_execute, remote.handle, .{
        .run_id = run_id,
        .generation = generation,
    }) orelse return goneTerminal(allocator);
    defer reply.deinit();
    return reply.answer.ok.into(allocator) catch goneTerminal(allocator);
}

const run_vtable: port.RunPort.VTable = .{ .execute = runExecute };

fn controlTryRetain(context: ?*anyopaque) bool {
    return remoteOf(context).retain();
}

fn controlRelease(context: ?*anyopaque) void {
    remoteOf(context).release();
}

fn controlSubmitInput(context: ?*anyopaque, run_id: u64, generation: u64, input_id: u64, text: []const u8) control.InputSubmission {
    const remote = remoteOf(context);
    var reply = call(remote.generation, .run_submit_input, remote.handle, .{
        .run_id = run_id,
        .generation = generation,
        .input_id = input_id,
        .text = text,
    }) orelse return @unionInit(control.InputSubmission, @tagName(control.InputSubmission.link_unreachable), {});
    defer reply.deinit();
    return reply.answer.ok;
}

fn controlInputObservation(context: ?*anyopaque, run_id: u64, generation: u64) ?control.InputObservation {
    const remote = remoteOf(context);
    var reply = call(remote.generation, .run_input_observation, remote.handle, .{
        .run_id = run_id,
        .generation = generation,
    }) orelse return null;
    defer reply.deinit();
    return reply.answer.ok;
}

fn controlRequestTermination(context: ?*anyopaque, run_id: u64, generation: u64, signal: control.TerminationSignal) control.TerminationRequestResult {
    const remote = remoteOf(context);
    var reply = call(remote.generation, .run_request_termination, remote.handle, .{
        .run_id = run_id,
        .generation = generation,
        .signal = signal,
    }) orelse return control.TerminationRequestResult.link_unreachable;
    defer reply.deinit();
    return reply.answer.ok;
}

const control_vtable: port.RunControl.VTable = .{
    .try_retain = controlTryRetain,
    .release = controlRelease,
    .submit_input = controlSubmitInput,
    .input_observation = controlInputObservation,
    .request_termination = controlRequestTermination,
};

pub const TestSupport = struct {
    /// Ends the running execution process the way a crash would: the UI
    /// half learns it from the end of the stream.
    pub fn killCurrent(owner: *Owner) void {
        owner.mutex.lockUncancelable(owner.io);
        defer owner.mutex.unlock(owner.io);
        if (owner.current) |generation| generation.host.terminate();
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "the credit never grants more than the pump can take" {
    // Every mix of data and control events within the credit fits the pump,
    // which is what lets the reader enqueue without ever waiting.
    const limits = pumpLimits(100);
    try std.testing.expect(credit_count <= limits.global_count - limits.global_control_reserved_count);
    try std.testing.expect(credit_bytes <= limits.global_bytes - limits.global_control_reserved_bytes);
    try std.testing.expect(credit_count <= limits.per_session_count - limits.per_session_control_reserved_count);
    try std.testing.expect(credit_bytes <= limits.per_session_bytes - limits.per_session_control_reserved_bytes);
    // And one event of the largest legal size fits in it.
    try std.testing.expect(credit_bytes >= limits.max_event_bytes);
}

test "a gone Run is interrupted by its Session closing, with its events possibly lost" {
    var terminal = goneTerminal(std.testing.allocator);
    defer terminal.deinit();
    try std.testing.expectEqual(control.ExternalInterruption.session_close, terminal.termination_signal.?.interrupted);
    try std.testing.expectEqual(@as(?control.TerminalFailure, null), terminal.failure);
    try std.testing.expect(terminal.event_delivery_lost);
    try std.testing.expect(!terminal.coreWasInvoked());
    try std.testing.expectEqual(control.SessionDisposition.poisoned, terminal.session_disposition_at_completion);
}

test "a far side's error outside the caller's set is the gone answer" {
    try std.testing.expectEqual(error.SessionClosing, narrow(Error, error.SessionClosing));
    try std.testing.expectEqual(error.DependencyUnreachable, narrow(Error, error.OutOfMemory));
}
