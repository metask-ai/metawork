//! The UI half of the execution link: the `RuntimePort` Product drives, with
//! AgentCore in a process of its own.
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
//! ## Callbacks
//!
//! The execution half calls back for what stays here: an MCP server's
//! transport, with its connection, OAuth state and credentials. A callback
//! arrives as a request on the reader thread, is served on a thread of its
//! own by the transport the MCP owners built, and its answer goes back the
//! way a call's does. When the process is gone its callbacks are cancelled
//! and the connections it opened are closed here, because nothing there will
//! close them.
//!
//! ## MCP membership
//!
//! The UI half keeps its own copy of the membership the execution process's
//! Runtime holds, in members that own the real transports. A membership is
//! composed here, from that copy, exactly as the Runtime would compose it,
//! and applied there with each member standing in for one here. A new process
//! is given the applied membership before anything else uses it, so what it
//! loses is its catalog, which Product already knows how to refresh.
//!
//! ## Liveness
//!
//! A process can be there and not answer. The UI half pings it on a clock and
//! treats one that has not answered within the deadline as gone, which ends
//! every wait on it. That is the one bound on a UI thread waiting for an
//! answer; no call has a timeout of its own, because some calls legitimately
//! last a whole Run.
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
const mcp_catalog = contract.mcp.catalog;
const mcp_runtime = contract.mcp.runtime;
const mcp_connector = contract.mcp.connector;

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

/// How often the execution process is asked whether it is alive.
pub const default_heartbeat_interval_ms: u64 = 1_000;
/// How long it may go without answering before it is treated as gone. Long
/// enough that a loaded machine does not cost a user a Run; short enough
/// that a UI thread waiting on a stopped process is released.
pub const default_heartbeat_deadline_ms: u64 = 5_000;

/// A process that ends within this of starting counts towards holding the
/// next start back.
const quick_loss_ms: i64 = 10_000;
/// Quick losses in a row before starts are held back.
const quick_losses_allowed: u32 = 3;
/// How long the first hold lasts; each further quick loss doubles it, up to
/// the cap.
const start_hold_first_ms: i64 = 2_000;
const start_hold_cap_ms: i64 = 60_000;

/// Stack for a thread that performs a callback: an MCP exchange over stdio
/// or HTTP, as an AgentCore tool thread performs it in process.
const callback_stack_bytes: usize = 4 * 1024 * 1024;

pub const RouteRange = struct {
    first: u64,
    end: u64,
    /// The latest process lost: its id, and the wall-clock time just before
    /// it was spawned. Its fault record, if it left one, carries the same id
    /// and a later start, which an older record of a reused id does not.
    process_id: u32 = 0,
    spawned_unix_ms: i64 = 0,
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
    heartbeat_interval_ms: u64 = default_heartbeat_interval_ms,
    heartbeat_deadline_ms: u64 = default_heartbeat_deadline_ms,
    /// The data root, where a process keeps its fault record. Passed on.
    data_root: ?[]const u8 = null,
    /// Tests only: called with a started process's `lost` flag before the
    /// process is published, so a test can hold a start there.
    after_start: ?StartHook = null,
};

pub const StartHook = struct {
    context: ?*anyopaque,
    call_fn: *const fn (?*anyopaque, *const std.atomic.Value(bool)) void,
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
    /// Processes that ended soon after they started, in a row, and the time
    /// before which no new one is started because of them. Whatever asks for
    /// a process -- a catalog refresh after a loss, a schedule, an apply, a
    /// message -- asks here, so this is where a process that dies on every
    /// start stops being started on every ask.
    quick_losses: u32 = 0,
    starts_held_until_ms: i64 = 0,
    loss: ?RouteRange = null,
    shutting_down: bool = false,
    /// Every event the reader has put in the pump, for tests.
    events_received: std.atomic.Value(u64) = .init(0),
    /// Names for transports and connections, unique across processes.
    next_name: std.atomic.Value(u64) = .init(0),

    /// The applied MCP membership, in members that own the transports; held
    /// under `mcp_mutex`, which also orders applies.
    mcp_mutex: std.Io.Mutex = .init,
    mcp_applied: mcp_runtime.Servers,
    /// Its registry generation; zero until one is applied.
    mcp_generation: u64 = 0,

    pub fn init(self: *Owner, io: std.Io, allocator: std.mem.Allocator, options: Options) !void {
        var applied = try mcp_runtime.Servers.init(allocator, &.{});
        errdefer applied.deinit();
        self.* = .{
            .io = io,
            .allocator = allocator,
            .options = options,
            .pump = try event_pump.EventPump.init(io, allocator, pumpLimits(options.session_slots)),
            .mcp_applied = applied,
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

    /// The process currently running, by the number of the start that made
    /// it, if there is one. Unique for this Owner's lifetime, which an OS
    /// process id or handle is not: Windows hands a new process the handle
    /// value of one just closed, so two processes in a row can share one.
    /// For tests and logs.
    pub fn currentProcess(self: *Owner) ?u32 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const generation = self.current orelse return null;
        if (generation.lost.load(.acquire)) return null;
        return generation.number;
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
        self.mcp_applied.deinit();
        self.pump.deinit();
        self.* = undefined;
    }

    fn nextName(self: *Owner) u64 {
        return self.next_name.fetchAdd(1, .monotonic) + 1;
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
            if (!generation.lost.load(.acquire)) {
                _ = generation.in_flight.fetchAdd(1, .acq_rel);
                self.mutex.unlock(self.io);
                return generation;
            }
            // Lost, with its `lose` not yet past this lock: no longer the
            // one to hand out, and `lose` unpublishes only itself.
            self.current = null;
        }
        // Held back: the answer is the one a process that died would give.
        if (now(self.io) < self.starts_held_until_ms) {
            self.mutex.unlock(self.io);
            return null;
        }
        self.started += 1;
        const number = self.started;
        self.mutex.unlock(self.io);

        const generation = Generation.start(self, number) orelse {
            // A process that never started is lost as soon as it is asked for.
            self.mutex.lockUncancelable(self.io);
            self.noteLossLocked(0);
            self.mutex.unlock(self.io);
            return null;
        };
        if (builtin.is_test) if (self.options.after_start) |hook| hook.call_fn(hook.context, &generation.lost);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.generations.append(self.allocator, generation) catch {
            self.mutex.unlock(self.io);
            generation.stop();
            generation.destroy();
            self.mutex.lockUncancelable(self.io);
            return null;
        };
        // A process already lost -- its watch could not start, or it ended
        // right after agreeing on identity and its reader got here first --
        // is left for the sweep and never handed out. `lose` clears only the
        // process that is current when it runs, so this one, once published,
        // would be current until the application restarts. Checked under the
        // lock `lose` takes after setting the flag, so one of the two always
        // sees the other.
        if (generation.lost.load(.acquire)) return null;
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
        self.mutex.unlock(self.io);
        // Still under the spawn lock, so whatever opens a Session in this
        // process finds the membership already there.
        self.replayMcp(generation);
        self.mutex.lockUncancelable(self.io);
        return generation;
    }

    /// Gives a new process the MCP membership the last one held. A failure
    /// leaves it without one, which the next apply repairs: it composes from
    /// the same members and the process treats each one as new.
    fn replayMcp(self: *Owner, generation: *Generation) void {
        var members: std.ArrayList(*mcp_runtime.Member) = .empty;
        defer {
            for (members.items) |member| member.release();
            members.deinit(self.allocator);
        }
        self.mcp_mutex.lockUncancelable(self.io);
        const registry_generation = self.mcp_generation;
        // Held for the call, which is made without the lock: an apply that
        // replaces the membership meanwhile does not free these.
        for (self.mcp_applied.memberList()) |member| {
            members.append(self.allocator, member) catch break;
            member.retain();
        }
        const complete = members.items.len == self.mcp_applied.memberList().len;
        self.mcp_mutex.unlock(self.io);
        if (registry_generation == 0 or members.items.len == 0) return;
        if (!complete) {
            std.log.warn("execution process started without its MCP servers: OutOfMemory", .{});
            return;
        }
        const outcome = applyMembership(generation, registry_generation, members.items) catch |err| {
            std.log.warn("execution process started without its MCP servers: {s}", .{@errorName(err)});
            return;
        };
        if (outcome != .applied)
            std.log.warn("execution process refused its MCP servers: {s}", .{@tagName(outcome)});
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

    /// Counts a process that lived `lived_ms`, and holds the next start back
    /// once enough of them in a row ended soon after starting. One that lived
    /// longer clears the count: it was not dying at start.
    fn noteLossLocked(self: *Owner, lived_ms: i64) void {
        if (lived_ms >= quick_loss_ms) {
            self.quick_losses = 0;
            return;
        }
        self.quick_losses +|= 1;
        if (self.quick_losses < quick_losses_allowed) return;
        const doublings: u6 = @intCast(@min(self.quick_losses - quick_losses_allowed, 5));
        const hold_ms = @min(start_hold_first_ms << doublings, start_hold_cap_ms);
        self.starts_held_until_ms = now(self.io) + hold_ms;
        std.log.warn("execution process ended soon after starting {d} times in a row; the next start waits {d} ms", .{ self.quick_losses, hold_ms });
    }

    fn sendCreditLocked(self: *Owner, generation: *Generation, force: bool) void {
        _ = self;
        if (generation.lost.load(.acquire)) return;
        const owed_count = generation.granted.count - generation.announced.count;
        const owed_bytes = generation.granted.bytes - generation.announced.bytes;
        if (owed_count == 0 and owed_bytes == 0) return;
        if (!force and owed_count < credit_batch_count and owed_bytes < credit_batch_bytes) return;
        var bytes: [32]u8 = undefined;
        const written = payload.encode(rpc.Control, .{ .credit = generation.granted }, &bytes);
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

    /// What this process reaches through callbacks, under `calls_mutex`.
    calls_mutex: std.Io.Mutex = .init,
    calls_idle: std.Io.Condition = .init,
    transports: std.AutoHashMapUnmanaged(u64, *Transport) = .empty,
    connections: std.AutoHashMapUnmanaged(u64, *Connection) = .empty,
    callbacks: std.AutoHashMapUnmanaged(u64, *Callback) = .empty,
    callback_threads: u32 = 0,

    watch: ?std.Thread = null,
    watch_stop: std.Io.Event = .unset,
    /// When the process last answered a ping, on the awake clock.
    answered_ns: std.atomic.Value(i64) = .init(0),
    /// When it started, on the same clock.
    started_ms: i64 = 0,
    /// Just before it was spawned, on the wall clock a fault record uses.
    spawned_unix_ms: i64 = 0,

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
        var root_text: [4096 + execution_host.data_root_flag.len]u8 = undefined;
        var arguments_storage: [2][]const u8 = undefined;
        var arguments: std.ArrayList([]const u8) = .initBuffer(&arguments_storage);
        arguments.appendAssumeCapacity(floor_argument);
        if (owner.options.data_root) |data_root| if (std.fmt.bufPrint(&root_text, "{s}{s}", .{
            execution_host.data_root_flag,
            data_root,
        })) |argument| arguments.appendAssumeCapacity(argument) else |_| {};
        var argv_storage: [16][]const u8 = undefined;
        const spawn: execution_host.Host.Spawn = switch (owner.options.spawn) {
            .self => .{ .self_with = arguments.items },
            .explicit => |prefix| explicit: {
                std.debug.assert(prefix.len + arguments.items.len <= argv_storage.len);
                @memcpy(argv_storage[0..prefix.len], prefix);
                @memcpy(argv_storage[prefix.len..][0..arguments.items.len], arguments.items);
                break :explicit .{ .explicit = argv_storage[0 .. prefix.len + arguments.items.len] };
            },
        };
        self.spawned_unix_ms = @intCast(@divTrunc(std.Io.Timestamp.now(owner.io, .real).nanoseconds, std.time.ns_per_ms));
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
        self.started_ms = now(owner.io);
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
        self.answered_ns.store(now(owner.io), .release);
        // A process nobody can watch is one nobody can give up on.
        self.watch = std.Thread.spawn(
            .{ .stack_size = channel.io_thread_stack_bytes },
            watchMain,
            .{self},
        ) catch {
            self.lose();
            return self;
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
        self.watch_stop.set(self.owner.io);
        // Whatever this process asked for is no longer wanted.
        self.calls_mutex.lockUncancelable(self.owner.io);
        var callbacks = self.callbacks.valueIterator();
        while (callbacks.next()) |callback| callback.*.withdraw();
        self.calls_mutex.unlock(self.owner.io);
        const owner = self.owner;
        owner.mutex.lockUncancelable(owner.io);
        if (owner.current == self) owner.current = null;
        if (!stopping) {
            owner.noteLossLocked(now(owner.io) - self.started_ms);
            const range: RouteRange = .{
                .first = self.floor,
                .end = self.floor + generation_span,
                .process_id = self.host.pid,
                .spawned_unix_ms = self.spawned_unix_ms,
            };
            owner.loss = if (owner.loss) |earlier| .{
                .first = @min(earlier.first, range.first),
                .end = @max(earlier.end, range.end),
                .process_id = range.process_id,
                .spawned_unix_ms = range.spawned_unix_ms,
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
        if (!(self.lost.load(.acquire) and
            self.reader_done.load(.acquire) and
            self.in_flight.load(.acquire) == 0 and
            self.sessions.items.len == 0)) return false;
        self.calls_mutex.lockUncancelable(self.owner.io);
        defer self.calls_mutex.unlock(self.owner.io);
        return self.callback_threads == 0;
    }

    fn destroy(self: *Generation) void {
        const allocator = self.owner.allocator;
        const io = self.owner.io;
        if (!self.stopped) self.stop();
        if (self.reader) |thread| thread.join();
        self.reader = null;
        if (self.watch) |thread| thread.join();
        self.watch = null;
        // Callbacks were cancelled when the process went; each still finishes
        // the exchange it is in and closes what it was the last user of.
        self.calls_mutex.lockUncancelable(io);
        while (self.callback_threads != 0) self.calls_idle.waitUncancelable(io, &self.calls_mutex);
        self.calls_mutex.unlock(io);
        self.releaseCallees();
        std.debug.assert(self.connections.count() == 0 and self.transports.count() == 0);
        self.connections.deinit(allocator);
        self.transports.deinit(allocator);
        self.callbacks.deinit(allocator);
        self.host.deinit();
        self.pending.deinit();
        for (self.sessions.items) |remote| remote.destroy(allocator);
        self.sessions.deinit(allocator);
        allocator.destroy(self);
    }

    /// Closes what the process opened and lets go of what it stood in for,
    /// once it is gone: nothing there will. A connection still in an exchange
    /// is closed by the exchange's own thread when it ends.
    fn releaseCallees(self: *Generation) void {
        const io = self.owner.io;
        var closing: std.ArrayList(*Connection) = .empty;
        defer closing.deinit(self.owner.allocator);
        var releasing: std.ArrayList(*Transport) = .empty;
        defer releasing.deinit(self.owner.allocator);
        self.calls_mutex.lockUncancelable(io);
        var connections = self.connections.iterator();
        while (connections.next()) |entry| {
            const connection = entry.value_ptr.*;
            if (connection.closing) continue;
            connection.closing = true;
            if (connection.calls != 0) continue;
            closing.append(self.owner.allocator, connection) catch {};
        }
        for (closing.items) |connection| _ = self.connections.remove(connection.id);
        var transports = self.transports.iterator();
        while (transports.next()) |entry| entry.value_ptr.*.released = true;
        self.calls_mutex.unlock(io);
        for (closing.items) |connection| self.closeConnection(connection);
        self.calls_mutex.lockUncancelable(io);
        transports = self.transports.iterator();
        while (transports.next()) |entry| {
            if (entry.value_ptr.*.connections == 0)
                releasing.append(self.owner.allocator, entry.value_ptr.*) catch {};
        }
        for (releasing.items) |transport| _ = self.transports.remove(transport.id);
        self.calls_mutex.unlock(io);
        for (releasing.items) |transport| transport.destroy(self.owner.allocator);
    }

    /// Ends a connection taken out of the table, and the transport with it
    /// if that was the transport's last connection and it is released.
    fn closeConnection(self: *Generation, connection: *Connection) void {
        const transport = connection.transport;
        transport.member.transport().close_fn(connection.backend);
        self.owner.allocator.destroy(connection);
        self.calls_mutex.lockUncancelable(self.owner.io);
        transport.connections -= 1;
        const done = transport.released and transport.connections == 0;
        if (done) _ = self.transports.remove(transport.id);
        self.calls_mutex.unlock(self.owner.io);
        if (done) transport.destroy(self.owner.allocator);
    }

    /// The name this process knows `member` by, registering it if it has
    /// none yet. Callers hold the MCP lock, so one member is never named
    /// twice.
    fn nameMember(self: *Generation, member: *mcp_runtime.Member) std.mem.Allocator.Error!u64 {
        const io = self.owner.io;
        self.calls_mutex.lockUncancelable(io);
        defer self.calls_mutex.unlock(io);
        var existing = self.transports.valueIterator();
        while (existing.next()) |transport| {
            if (transport.*.member == member and !transport.*.released) return transport.*.id;
        }
        try self.transports.ensureUnusedCapacity(self.owner.allocator, 1);
        const transport = try self.owner.allocator.create(Transport);
        member.retain();
        transport.* = .{ .id = self.owner.nextName(), .member = member };
        self.transports.putAssumeCapacity(transport.id, transport);
        return transport.id;
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
    self.releaseCallees();
}

fn now(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Timestamp.now(io, .awake).nanoseconds, std.time.ns_per_ms));
}

/// Pings the process on a clock, and gives it up when it has not answered
/// within the deadline.
fn watchMain(self: *Generation) void {
    const io = self.owner.io;
    const options = self.owner.options;
    var number: u64 = 0;
    while (!self.lost.load(.acquire)) {
        self.watch_stop.waitTimeout(io, .{ .duration = .{
            .raw = .fromMilliseconds(@intCast(options.heartbeat_interval_ms)),
            .clock = .awake,
        } }) catch {};
        if (self.lost.load(.acquire)) return;
        const silent_ms = now(io) - self.answered_ns.load(.acquire);
        if (silent_ms > @as(i64, @intCast(options.heartbeat_deadline_ms))) {
            std.log.warn("execution process has not answered for {d} ms; giving it up", .{silent_ms});
            self.lose();
            return;
        }
        number += 1;
        var bytes: [32]u8 = undefined;
        const written = payload.encode(rpc.Control, .{ .ping = number }, &bytes);
        _ = self.host.outbound.trySubmit(.control, 0, bytes[0..written]) catch {};
    }
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
        .request => {
            const header = rpc.decodeHeader(rpc.Callback, bytes) catch return .stop;
            _ = header;
            const callback = owner.allocator.create(Callback) catch return .stop;
            callback.* = .{ .generation = self, .correlation = correlation, .bytes = undefined };
            callback.bytes = owner.allocator.dupe(u8, bytes) catch {
                owner.allocator.destroy(callback);
                return .stop;
            };
            self.calls_mutex.lockUncancelable(owner.io);
            self.callbacks.put(owner.allocator, correlation, callback) catch {
                self.calls_mutex.unlock(owner.io);
                callback.destroy(owner.allocator);
                return .stop;
            };
            self.callback_threads += 1;
            self.calls_mutex.unlock(owner.io);
            const thread = std.Thread.spawn(.{ .stack_size = callback_stack_bytes }, serveCallback, .{callback}) catch {
                callback.finish();
                return .stop;
            };
            thread.detach();
            return .ok;
        },
        .control => {
            var storage: [64]u8 = undefined;
            var fixed = std.heap.FixedBufferAllocator.init(&storage);
            const value = payload.decodeExact(rpc.Control, fixed.allocator(), bytes) catch return .stop;
            switch (value) {
                .pong => self.answered_ns.store(now(owner.io), .release),
                .cancel => |target| {
                    self.calls_mutex.lockUncancelable(owner.io);
                    if (self.callbacks.get(target)) |callback| callback.withdraw();
                    self.calls_mutex.unlock(owner.io);
                },
                .credit, .ping => return .stop,
            }
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
    const image_path = if (value.generated_image_path) |path| try allocator.dupe(u8, path) else null;
    errdefer if (image_path) |path| allocator.free(path);
    const video_path = if (value.generated_video_path) |path| try allocator.dupe(u8, path) else null;
    errdefer if (video_path) |path| allocator.free(path);
    return .{
        .generated_image_path = image_path,
        .generated_video_path = video_path,
        .delivered_file = value.delivered_file,
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
// Callbacks
// ---------------------------------------------------------------------------

/// A transport the process stands in for: one member of a membership this
/// half composed, kept alive here for as long as the process may use it.
const Transport = struct {
    id: u64,
    member: *mcp_runtime.Member,
    connections: u32 = 0,
    /// The process let go of it, or is gone.
    released: bool = false,

    fn destroy(self: *Transport, allocator: std.mem.Allocator) void {
        self.member.release();
        allocator.destroy(self);
    }
};

const Connection = struct {
    id: u64,
    transport: *Transport,
    backend: *anyopaque,
    /// Exchanges in progress on it.
    calls: u32 = 0,
    closing: bool = false,
};

/// One callback being served.
const Callback = struct {
    generation: *Generation,
    correlation: u64,
    bytes: []u8,
    cancelled: std.atomic.Value(bool) = .init(false),
    /// An HTTP effect's cancellation while one runs, under `calls_mutex`:
    /// a withdrawal requests it, which also signals its transport.
    http_cancellation: ?*contract.http_transport.Cancellation = null,

    fn withdraw(self: *Callback) void {
        self.cancelled.store(true, .release);
        if (self.http_cancellation) |value| value.request();
    }

    fn watchHttp(self: *Callback, value: *contract.http_transport.Cancellation) void {
        const generation = self.generation;
        generation.calls_mutex.lockUncancelable(generation.owner.io);
        defer generation.calls_mutex.unlock(generation.owner.io);
        self.http_cancellation = value;
        if (self.cancelled.load(.acquire)) value.request();
    }

    fn unwatchHttp(self: *Callback) void {
        const generation = self.generation;
        generation.calls_mutex.lockUncancelable(generation.owner.io);
        defer generation.calls_mutex.unlock(generation.owner.io);
        self.http_cancellation = null;
    }

    fn cancellation(self: *Callback) mcp_connector.Cancellation {
        return .{ .context = self, .is_cancelled_fn = isCancelled };
    }

    fn isCancelled(context: ?*const anyopaque) bool {
        const self: *const Callback = @ptrCast(@alignCast(context.?));
        return self.cancelled.load(.acquire);
    }

    fn destroy(self: *Callback, allocator: std.mem.Allocator) void {
        std.crypto.secureZero(u8, self.bytes);
        allocator.free(self.bytes);
        allocator.destroy(self);
    }

    /// Off the table, and this thread no longer counted. Once the count is
    /// down the next sweep may destroy the generation, and an exit the Owner
    /// with it, so what is needed afterwards is taken before.
    fn finish(self: *Callback) void {
        const generation = self.generation;
        const allocator = generation.owner.allocator;
        const io = generation.owner.io;
        const wake = generation.owner.options.wake;
        generation.calls_mutex.lockUncancelable(io);
        _ = generation.callbacks.remove(self.correlation);
        generation.callback_threads -= 1;
        if (generation.callback_threads == 0) generation.calls_idle.broadcast(io);
        generation.calls_mutex.unlock(io);
        if (builtin.is_test) if (TestSupport.after_callback_counted_down) |hook| hook.call_fn(hook.context);
        self.destroy(allocator);
        _ = wake.notify();
    }
};

fn serveCallback(callback: *Callback) void {
    defer callback.finish();
    const generation = callback.generation;
    const allocator = generation.owner.allocator;
    const header = rpc.decodeHeader(rpc.Callback, callback.bytes) catch unreachable;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const answer = switch (header.method) {
        inline else => |method| answer: {
            const request = rpc.decodeRequest(method, arena, header.body) catch break :answer null;
            break :answer performCallback(callback, method, header.handle, request);
        },
    } orelse {
        // A callback this half cannot read or cannot name is not from the
        // process it started.
        generation.lose();
        return;
    };
    defer {
        std.crypto.secureZero(u8, answer);
        allocator.free(answer);
    }
    // `.closed` is the process already gone; nobody waits for this answer.
    _ = generation.host.outbound.submitWaiting(.response, callback.correlation, answer) catch {};
}

/// The encoded answer, or `null` when the request names nothing this process
/// was given.
fn performCallback(
    callback: *Callback,
    comptime method: rpc.Callback,
    handle: u64,
    request: rpc.Request(method),
) ?[]u8 {
    const generation = callback.generation;
    const owner = generation.owner;
    const allocator = owner.allocator;
    const io = owner.io;
    switch (method) {
        .mcp_open => {
            generation.calls_mutex.lockUncancelable(io);
            const transport = generation.transports.get(handle) orelse {
                generation.calls_mutex.unlock(io);
                return null;
            };
            if (transport.released) {
                generation.calls_mutex.unlock(io);
                return null;
            }
            // Counted before the open, so the transport outlives it.
            transport.connections += 1;
            generation.calls_mutex.unlock(io);
            const outcome = transport.member.transport().open_fn(
                transport.member.transport().context,
                request.purpose,
                request.era,
                request.timeout_ms,
            );
            // Whether the count taken above still has to be given back here.
            var counted = true;
            const opened: rpc.McpOpened = switch (outcome) {
                .failure => |failure| .{ .failure = failure },
                .connection => |backend| opened: {
                    const connection = allocator.create(Connection) catch {
                        transport.member.transport().close_fn(backend);
                        break :opened .{ .failure = .fatal };
                    };
                    connection.* = .{ .id = owner.nextName(), .transport = transport, .backend = backend };
                    generation.calls_mutex.lockUncancelable(io);
                    // A process that went while this opened will never close
                    // it, so it is not registered for one.
                    const registered = !generation.lost.load(.acquire) and
                        if (generation.connections.put(allocator, connection.id, connection)) true else |_| false;
                    generation.calls_mutex.unlock(io);
                    if (!registered) {
                        // Gives the count back itself.
                        generation.closeConnection(connection);
                        counted = false;
                        break :opened .{ .failure = .fatal };
                    }
                    break :opened .{ .connection = connection.id };
                },
            };
            if (opened == .failure and counted) {
                generation.calls_mutex.lockUncancelable(io);
                transport.connections -= 1;
                const done = transport.released and transport.connections == 0;
                if (done) _ = generation.transports.remove(transport.id);
                generation.calls_mutex.unlock(io);
                if (done) transport.destroy(allocator);
            }
            return rpc.encodeOk(method, allocator, opened) catch null;
        },
        .mcp_request, .mcp_notify => {
            const connection = beginExchange(generation, handle) orelse return null;
            defer endExchange(generation, connection);
            const member = connection.transport.member;
            const transport = member.transport();
            const encoded = switch (method) {
                .mcp_request => encoded: {
                    // The same fail-closed scan the in-process connector
                    // applies, here where the secrets are.
                    if (member.containsSecret(request.bytes))
                        break :encoded rpc.encodeOk(method, allocator, .{ .failure = .fatal });
                    const exchange = if (request.tool) transport.tool_request_fn orelse transport.request_fn else transport.request_fn;
                    const outcome = exchange(connection.backend, allocator, request.bytes, request.timeout_ms, callback.cancellation());
                    break :encoded switch (outcome) {
                        .failure => |failure| rpc.encodeOk(method, allocator, .{ .failure = failure }),
                        .response => |response| response: {
                            defer if (response.body.len != 0) {
                                std.crypto.secureZero(u8, response.body);
                                allocator.free(response.body);
                            };
                            if (member.containsSecret(response.body))
                                break :response rpc.encodeOk(method, allocator, .{ .failure = .fatal });
                            break :response rpc.encodeOk(method, allocator, .{ .response = .{
                                .http_status = response.http_status,
                                .body = response.body,
                            } });
                        },
                    };
                },
                .mcp_notify => encoded: {
                    if (member.containsSecret(request.bytes))
                        break :encoded rpc.encodeOk(method, allocator, .fatal);
                    break :encoded rpc.encodeOk(method, allocator, transport.notify_fn(
                        connection.backend,
                        request.bytes,
                        request.timeout_ms,
                        callback.cancellation(),
                    ));
                },
                else => comptime unreachable,
            };
            return encoded catch null;
        },
        .mcp_close => {
            generation.calls_mutex.lockUncancelable(io);
            const connection = generation.connections.get(handle) orelse {
                generation.calls_mutex.unlock(io);
                return null;
            };
            connection.closing = true;
            const now_closing = connection.calls == 0;
            if (now_closing) _ = generation.connections.remove(handle);
            generation.calls_mutex.unlock(io);
            if (now_closing) generation.closeConnection(connection);
            return rpc.encodeOk(method, allocator, {}) catch null;
        },
        .mcp_install_put => {
            const installation = installationOf(generation, handle) orelse
                return rpc.encodeOk(method, allocator, .unavailable) catch null;
            // The Host's own copy, in the allocator its capability names.
            const json = installation.allocator.dupe(u8, request.json) catch
                return rpc.encodeOk(method, allocator, .unavailable) catch null;
            const draft: contract.McpInstallationRequest = .{ .allocator = installation.allocator, .json = json };
            const result = installation.try_put_fn(installation.context, request.task_id, request.run_id, request.generation, draft);
            if (result != .submitted) {
                var refused = draft;
                refused.deinit();
            }
            return rpc.encodeOk(method, allocator, result) catch null;
        },
        .mcp_install_wake => {
            if (installationOf(generation, handle)) |installation| installation.wake_fn(installation.context);
            return rpc.encodeOk(method, allocator, {}) catch null;
        },
        .delivery_inspect => {
            const loan = EffectsLoan.take(generation, handle, request.run_id);
            defer if (loan) |value| value.giveBack();
            const input = (if (loan) |value| value.effects.delivery else null) orelse
                return rpc.encodeOk(method, allocator, .{ .failed = .unavailable }) catch null;
            return rpc.encodeOk(method, allocator, input.inspect_fn(input.context, request.path, &callback.cancelled)) catch null;
        },
        .media_credential_read => {
            const loan = EffectsLoan.take(generation, handle, request.run_id);
            defer if (loan) |value| value.giveBack();
            const reader: ?contract.ImageGenerationCredentialReader = if (loan) |value| switch (request.tool) {
                .image => if (value.effects.image) |image| image.binding.credential_reader else null,
                .video => if (value.effects.video) |video| video.credential else null,
            } else null;
            const source = reader orelse return rpc.encodeOk(method, allocator, null) catch null;
            const buffer = allocator.alloc(u8, request.capacity) catch return rpc.encodeOk(method, allocator, null) catch null;
            defer {
                std.crypto.secureZero(u8, buffer);
                allocator.free(buffer);
            }
            const count = source.read_fn(source.context, buffer) orelse return rpc.encodeOk(method, allocator, null) catch null;
            if (count > buffer.len) return rpc.encodeOk(method, allocator, null) catch null;
            return rpc.encodeOk(method, allocator, buffer[0..count]) catch null;
        },
        .media_perform => return performMedia(callback, handle, request) catch null,
        .image_commit => {
            const loan = EffectsLoan.take(generation, handle, request.run_id);
            defer if (loan) |value| value.giveBack();
            const image = (if (loan) |value| value.effects.image else null) orelse
                return rpc.encodeOk(method, allocator, .{ .failed = .{ .code = .unavailable } }) catch null;
            var cancellation: contract.http_transport.Cancellation = .{};
            callback.watchHttp(&cancellation);
            defer callback.unwatchHttp();
            const output = image.binding.output;
            return rpc.encodeOk(method, allocator, output.commit_fn(output.context, request.bytes, request.format, &cancellation)) catch null;
        },
        .video_commit => {
            const loan = EffectsLoan.take(generation, handle, request.run_id);
            defer if (loan) |value| value.giveBack();
            const video = (if (loan) |value| value.effects.video else null) orelse
                return rpc.encodeOk(method, allocator, .{ .failed = .output_failed }) catch null;
            var cancellation: contract.http_transport.Cancellation = .{};
            callback.watchHttp(&cancellation);
            defer callback.unwatchHttp();
            var reader = std.Io.Reader.fixed(request.bytes);
            const output = video.output;
            return rpc.encodeOk(method, allocator, output.commit_fn(output.context, &reader, request.length, &cancellation)) catch null;
        },
        .mcp_release => {
            generation.calls_mutex.lockUncancelable(io);
            const transport = generation.transports.get(handle) orelse {
                generation.calls_mutex.unlock(io);
                return null;
            };
            transport.released = true;
            const done = transport.connections == 0;
            if (done) _ = generation.transports.remove(handle);
            generation.calls_mutex.unlock(io);
            if (done) transport.destroy(allocator);
            return rpc.encodeOk(method, allocator, {}) catch null;
        },
    }
}

/// The effects the Run `run_id` of the Session named by `handle` was given,
/// lent to one callback while its effect runs. They point into what Product
/// prepared for the Run, which Product releases as soon as the Run is over,
/// so the Run's end waits for every loan to come back. In process the same
/// holds by construction: a Run's execute returns only after its tools have.
const EffectsLoan = struct {
    remote: *RemoteSession,
    run_id: u64,
    effects: RunEffects,

    /// `null` once the Run is over, or for a Run with no effects.
    fn take(generation: *Generation, handle: u64, run_id: u64) ?EffectsLoan {
        const owner = generation.owner;
        owner.mutex.lockUncancelable(owner.io);
        defer owner.mutex.unlock(owner.io);
        for (generation.sessions.items) |remote| {
            if (remote.handle != handle) continue;
            remote.mutex.lockUncancelable(owner.io);
            defer remote.mutex.unlock(owner.io);
            const held = remote.effects.getPtr(run_id) orelse return null;
            if (held.ending) return null;
            held.loans += 1;
            return .{ .remote = remote, .run_id = run_id, .effects = held.effects };
        }
        return null;
    }

    fn giveBack(self: EffectsLoan) void {
        const remote = self.remote;
        remote.mutex.lockUncancelable(remote.io());
        defer remote.mutex.unlock(remote.io());
        const held = remote.effects.getPtr(self.run_id).?;
        held.loans -= 1;
        if (held.loans == 0) remote.condition.broadcast(remote.io());
    }
};

/// A streamed response, read whole for the Run's receiver.
const StreamCapture = struct {
    allocator: std.mem.Allocator,
    limit: usize,
    received: bool = false,
    content_type: ?[]u8 = null,
    content_length: ?u64 = null,
    bytes: []u8 = &.{},
    failed: bool = false,

    fn receive(context: *anyopaque, content_type: ?[]const u8, content_length: ?u64, reader: *std.Io.Reader) void {
        const self: *StreamCapture = @ptrCast(@alignCast(context));
        self.received = true;
        self.content_length = content_length;
        self.content_type = if (content_type) |value| self.allocator.dupe(u8, value) catch {
            self.failed = true;
            return;
        } else null;
        self.bytes = reader.allocRemaining(self.allocator, .limited(self.limit)) catch {
            self.failed = true;
            return;
        };
    }

    fn deinit(self: *StreamCapture) void {
        if (self.content_type) |value| self.allocator.free(value);
        self.allocator.free(self.bytes);
    }
};

/// One media HTTP request, performed by the transport Product prepared, with
/// what it streamed read whole so the answer can carry it.
fn performMedia(callback: *Callback, handle: u64, request: rpc.Request(rpc.Callback.media_perform)) std.mem.Allocator.Error![]u8 {
    const generation = callback.generation;
    const owner = generation.owner;
    const allocator = owner.allocator;
    const method = rpc.Callback.media_perform;
    const loan = EffectsLoan.take(generation, handle, request.run_id);
    defer if (loan) |value| value.giveBack();
    const transport: contract.http_transport.Transport = (if (loan) |value| switch (request.tool) {
        .image => if (value.effects.image) |image| image.transport else null,
        .video => if (value.effects.video) |video| video.transport else null,
    } else null) orelse return rpc.encodeOk(method, allocator, .{ .failure = .Unexpected });
    // What one answer can carry, less room for the rest of it.
    const limit = owner.options.message_limits.response -| 64 * 1024;
    var capture: StreamCapture = .{ .allocator = allocator, .limit = limit };
    defer capture.deinit();
    const buffer = try allocator.alloc(u8, @min(request.response_capacity, limit));
    defer allocator.free(buffer);
    var cancellation = contract.http_transport.Cancellation.init(transport);
    callback.watchHttp(&cancellation);
    defer callback.unwatchHttp();
    const wire = request.request;
    const response = transport.perform(.{
        .url = wire.url,
        .headers = wire.headers,
        .body = wire.body,
        .method = wire.method,
        .stream = if (wire.streams) .{ .context = &capture, .receive_fn = StreamCapture.receive } else null,
        .connect_timeout_ms = wire.connect_timeout_ms,
        .source = wire.source,
    }, &cancellation, buffer) catch |err| {
        const failure: rpc.HttpFailure = switch (err) {
            inline else => |tag| @field(rpc.HttpFailure, @errorName(tag)),
        };
        return rpc.encodeOk(method, allocator, .{ .failure = failure });
    };
    if (capture.failed or capture.bytes.len >= limit and capture.received)
        return rpc.encodeOk(method, allocator, .{ .failure = .ResponseTooLarge });
    return rpc.encodeOk(method, allocator, .{ .response = .{
        .status = response.status,
        .body = response.body,
        .stream = if (capture.received) .{
            .content_type = capture.content_type,
            .content_length = capture.content_length,
            .bytes = capture.bytes,
        } else null,
    } });
}

/// The installation capability the Session named by `handle` gave its Runs.
/// A Session released meanwhile has none, and its Run is told the Host is
/// unavailable, as the capability itself says once it is closed.
fn installationOf(generation: *Generation, handle: u64) ?contract.McpInstallationInput {
    const owner = generation.owner;
    owner.mutex.lockUncancelable(owner.io);
    defer owner.mutex.unlock(owner.io);
    for (generation.sessions.items) |remote| {
        if (remote.handle == handle) return remote.installation;
    }
    return null;
}

fn beginExchange(generation: *Generation, id: u64) ?*Connection {
    const io = generation.owner.io;
    generation.calls_mutex.lockUncancelable(io);
    defer generation.calls_mutex.unlock(io);
    const connection = generation.connections.get(id) orelse return null;
    if (connection.closing) return null;
    connection.calls += 1;
    return connection;
}

fn endExchange(generation: *Generation, connection: *Connection) void {
    const io = generation.owner.io;
    generation.calls_mutex.lockUncancelable(io);
    connection.calls -= 1;
    const close = connection.closing and connection.calls == 0;
    if (close) _ = generation.connections.remove(connection.id);
    generation.calls_mutex.unlock(io);
    if (close) generation.closeConnection(connection);
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
    /// The MCP installation capability its Runs were last given, which a
    /// Run's request reaches by calling back. Under `owner.mutex`.
    installation: ?contract.McpInstallationInput = null,
    /// The skill catalog it is bound with, held for as long as it is: in
    /// process the Session holds its lease the same way.
    skill_lease: ?*RemoteLease = null,
    /// Each prepared Run's file delivery and media effects, which its
    /// callbacks borrow, until the Run is over. Under `mutex`.
    effects: std.AutoHashMapUnmanaged(u64, HeldEffects) = .empty,

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
        if (self.skill_lease) |lease| lease.release();
        self.effects.deinit(allocator);
        allocator.destroy(self);
    }

    /// The Run is over, or will never start; Product releases its effects
    /// as soon as this returns, so it returns once no callback still uses
    /// them. The wait is bounded: a process that is gone had its callbacks
    /// withdrawn, which requests each effect's cancellation, and a live one
    /// withdraws its own before its Run ends.
    fn dropEffects(self: *RemoteSession, run_id: u64) void {
        self.mutex.lockUncancelable(self.io());
        defer self.mutex.unlock(self.io());
        while (self.effects.getPtr(run_id)) |held| {
            held.ending = true;
            if (held.loans == 0) break;
            self.condition.waitUncancelable(self.io(), &self.mutex);
        }
        _ = self.effects.remove(run_id);
    }

    /// Now bound with `lease`, or with none; the reference moves in.
    fn rebindSkills(self: *RemoteSession, lease: ?*RemoteLease) void {
        self.mutex.lockUncancelable(self.io());
        const previous = self.skill_lease;
        self.skill_lease = lease;
        self.mutex.unlock(self.io());
        if (previous) |value| value.release();
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
    var scratch = std.heap.ArenaAllocator.init(owner.allocator);
    defer scratch.deinit();
    const generation = owner.ensure() orelse return error.DependencyUnreachable;
    defer generation.release();
    const skill_lease: ?*RemoteLease = if (options.skill_catalog) |lease| leaseOf(lease) else null;
    const skill_name: ?u64 = if (skill_lease) |lease| try lease.bind(generation) else null;
    const wire_options = try rpc.openOptionsToWire(options, skill_name, scratch.allocator());
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
    if (skill_lease) |lease| remote.rebindSkills(lease.retain());
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
    var scratch = std.heap.ArenaAllocator.init(owner.allocator);
    defer scratch.deinit();
    var bytes: std.ArrayList(u8) = .empty;
    defer {
        std.crypto.secureZero(u8, bytes.items);
        bytes.deinit(owner.allocator);
    }
    const end = try readSource(owner.allocator, options.source, options.checkpoint_limits.hard_bytes, &bytes);
    const generation = owner.ensure() orelse return error.DependencyUnreachable;
    defer generation.release();
    const skill_lease: ?*RemoteLease = if (options.session.skill_catalog) |lease| leaseOf(lease) else null;
    const skill_name: ?u64 = if (skill_lease) |lease| try lease.bind(generation) else null;
    const wire_session = try rpc.openOptionsToWire(options.session, skill_name, scratch.allocator());
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
    if (skill_lease) |lease| remote.rebindSkills(lease.retain());
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

// ---------------------------------------------------------------------------
// MCP
// ---------------------------------------------------------------------------
//
// Every MCP object that crosses is plain data and crosses as a copy: an
// activation, a selection and a restore selection are each rebuilt in the
// receiver's allocator, and the Runtime that later sees one checks its owner
// and generation exactly as it checks a value of its own.

fn runtimeActivateMcp(context: ?*anyopaque) Allocating!surface.McpActivationOutcome {
    const owner = ownerOf(context);
    // The process holds exactly the membership applied here, and a Runtime
    // with no servers activates nothing; no process is started to say so.
    owner.mcp_mutex.lockUncancelable(owner.io);
    const empty = owner.mcp_applied.memberList().len == 0;
    owner.mcp_mutex.unlock(owner.io);
    if (empty) return .empty;
    const generation = owner.ensure() orelse return error.DependencyUnreachable;
    defer generation.release();
    var reply = call(generation, .activate_mcp, 0, .{}) orelse return error.DependencyUnreachable;
    defer reply.deinit();
    return switch (reply.answer) {
        .err => |err| narrow(Allocating, err),
        .ok => |value| try rpc.activationOutcomeFromWire(value, owner.allocator, owner.io),
    };
}

fn runtimeCreateMcpAdmissionSelection(
    context: ?*anyopaque,
    activation: *const contract.McpActivation,
    allowlists: []const contract.McpServerAllowlist,
) Allocating!?*contract.McpSelection {
    const owner = ownerOf(context);
    var scratch = std.heap.ArenaAllocator.init(owner.allocator);
    defer scratch.deinit();
    const wire_activation = try mcp_catalog.activationToWire(activation, scratch.allocator());
    const generation = owner.ensure() orelse return error.DependencyUnreachable;
    defer generation.release();
    var reply = call(generation, .create_mcp_admission_selection, 0, .{
        .activation = wire_activation,
        .allowlists = allowlists,
    }) orelse return error.DependencyUnreachable;
    defer reply.deinit();
    return switch (reply.answer) {
        .err => |err| narrow(Allocating, err),
        .ok => |value| if (value) |selection| try mcp_catalog.selectionFromWire(owner.allocator, selection) else null,
    };
}

fn runtimePrepareMcpRestoreSelection(
    context: ?*anyopaque,
    original: *const contract.McpRestoreSelection,
    activation: *const contract.McpActivation,
    ceiling: []const contract.McpActivationTool,
) Allocating!*contract.McpSelection {
    const owner = ownerOf(context);
    var scratch = std.heap.ArenaAllocator.init(owner.allocator);
    defer scratch.deinit();
    const wire_activation = try mcp_catalog.activationToWire(activation, scratch.allocator());
    const generation = owner.ensure() orelse return error.DependencyUnreachable;
    defer generation.release();
    var reply = call(generation, .prepare_mcp_restore_selection, 0, .{
        .original = mcp_catalog.restoreSelectionToWire(original),
        .activation = wire_activation,
        .ceiling = ceiling,
    }) orelse return error.DependencyUnreachable;
    defer reply.deinit();
    return switch (reply.answer) {
        .err => |err| narrow(Allocating, err),
        .ok => |value| try mcp_catalog.selectionFromWire(owner.allocator, value),
    };
}

/// Composed here, from this half's copy of the applied membership, by the
/// Runtime's own composition, so a membership the process would refuse for
/// its shape is refused here first.
fn runtimePrepareMcpMembership(
    context: ?*anyopaque,
    generation: u64,
    additions: ?*const mcp_runtime.Input,
    server_ids: []const []const u8,
) Allocating!mcp_runtime.Input {
    const owner = ownerOf(context);
    owner.mcp_mutex.lockUncancelable(owner.io);
    defer owner.mcp_mutex.unlock(owner.io);
    return mcp_runtime.Input.compose(owner.allocator, generation, &owner.mcp_applied, additions, server_ids) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidConfig => error.McpConfigurationApplyFailed,
    };
}

/// Sends `members` to the process as its membership. A lost answer is a
/// failure: the process that might have applied it is gone, and the next one
/// is given the membership applied before.
fn applyMembership(
    generation: *Generation,
    registry_generation: u64,
    members: []const *mcp_runtime.Member,
) Allocating!surface.McpConfigurationApplyOutcome {
    const allocator = generation.owner.allocator;
    const wire_members = try allocator.alloc(rpc.McpMember, members.len);
    defer allocator.free(wire_members);
    {
        // Named under the MCP lock, so one member is never named twice in a
        // process.
        const owner = generation.owner;
        owner.mcp_mutex.lockUncancelable(owner.io);
        defer owner.mcp_mutex.unlock(owner.io);
        for (members, wire_members) |member, *target| target.* = .{
            .transport = try generation.nameMember(member),
            .descriptor = member.describe(),
        };
    }
    var reply = call(generation, .apply_mcp_configuration, 0, .{
        .generation = registry_generation,
        .members = wire_members,
    }) orelse return error.McpConfigurationApplyFailed;
    defer reply.deinit();
    return switch (reply.answer) {
        .err => |err| narrow(Allocating, err),
        .ok => |value| value,
    };
}

fn runtimeApplyMcpConfiguration(context: ?*anyopaque, input: *mcp_runtime.Input) Allocating!surface.McpConfigurationApplyOutcome {
    const owner = ownerOf(context);
    var candidate = input.take() catch return error.McpConfigurationApplyFailed;
    var candidate_owned = true;
    defer if (candidate_owned) candidate.deinit();
    const generation = owner.ensure() orelse return error.DependencyUnreachable;
    defer generation.release();
    // The candidate is this call's alone, so the process is asked without
    // the lock; only the swap takes it.
    const outcome = try applyMembership(generation, input.generation, candidate.memberList());
    if (outcome == .applied) {
        owner.mcp_mutex.lockUncancelable(owner.io);
        var previous = owner.mcp_applied;
        owner.mcp_applied = candidate;
        candidate_owned = false;
        owner.mcp_generation = input.generation;
        owner.mcp_mutex.unlock(owner.io);
        previous.deinit();
    }
    return outcome;
}

fn runtimeProbeMcp(context: ?*anyopaque, input: *mcp_runtime.Input) Allocating!surface.McpActivationOutcome {
    const owner = ownerOf(context);
    var servers = input.take() catch return error.McpConfigurationApplyFailed;
    defer servers.deinit();
    const generation = owner.ensure() orelse return error.DependencyUnreachable;
    defer generation.release();
    const wire_members = try owner.allocator.alloc(rpc.McpMember, servers.memberList().len);
    defer owner.allocator.free(wire_members);
    {
        owner.mcp_mutex.lockUncancelable(owner.io);
        defer owner.mcp_mutex.unlock(owner.io);
        // A probe's members are its own, so they are named afresh.
        for (servers.memberList(), wire_members) |member, *target| target.* = .{
            .transport = try generation.nameMember(member),
            .descriptor = member.describe(),
        };
    }
    var reply = call(generation, .probe_mcp, 0, .{
        .generation = input.generation,
        .members = wire_members,
    }) orelse return error.DependencyUnreachable;
    defer reply.deinit();
    return switch (reply.answer) {
        .err => |err| narrow(Allocating, err),
        .ok => |value| try rpc.activationOutcomeFromWire(value, owner.allocator, owner.io),
    };
}

// ---------------------------------------------------------------------------
// Skills
// ---------------------------------------------------------------------------
//
// A skill catalog lease is a Core handle, so it stays in the execution
// process and this half holds a stand-in that names it. The stand-in keeps
// the query that acquired it and the catalog revision Product was shown, and
// keeps the query's source lifetime pinned for as long as anything here
// refers to it. That is as long as anything there does: Product's
// acquisition, the Sessions bound with it and the restore captures made from
// them each hold a reference here and release it when theirs there is
// released. So the source lifetime never has to cross.
//
// A process that is gone took its leases with it. A stand-in used again is
// acquired anew, by the same query, in the process there is now, and is that
// catalog only if its revision is the one Product was shown; otherwise it is
// refused as a lease of another Runtime is.
//
// Restore inputs are a lease and a list of grants, so they live here whole.

const RemoteLease = struct {
    owner: *Owner,
    arena: std.heap.ArenaAllocator,
    query: rpc.SkillQuery,
    revision: []const u8 = "",
    source_lifetime: ?contract.CatalogSourceLifetime,
    mutex: std.Io.Mutex = .init,
    references: u32 = 1,
    /// The process it is acquired in, by number, and its name there.
    bound: u32 = 0,
    name: u64 = 0,

    fn retain(self: *RemoteLease) *RemoteLease {
        const io = self.owner.io;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        std.debug.assert(self.references != 0);
        self.references += 1;
        return self;
    }

    /// The last reference lets go of the lease where it lives, if that
    /// process is still there, and of the source lifetime.
    fn release(self: *RemoteLease) void {
        const io = self.owner.io;
        self.mutex.lockUncancelable(io);
        self.references -= 1;
        const last = self.references == 0;
        self.mutex.unlock(io);
        if (!last) return;
        if (self.bound != 0) releaseNamed(self.owner, self.bound, self.name);
        if (self.source_lifetime) |lifetime| lifetime.release();
        const allocator = self.owner.allocator;
        self.arena.deinit();
        allocator.destroy(self);
    }

    /// Its name in `generation`'s process, acquiring it there first if it
    /// was acquired in a process that is gone.
    fn bind(self: *RemoteLease, generation: *Generation) Allocating!u64 {
        const io = self.owner.io;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.bound == generation.number) return self.name;
        var reply = call(generation, .query_skill_catalog, 0, self.query) orelse return error.DependencyUnreachable;
        defer reply.deinit();
        const acquired = switch (reply.answer) {
            .err => |err| return narrow(Allocating, err),
            .ok => |value| value,
        };
        if (!std.mem.eql(u8, acquired.revision, self.revision)) {
            releaseNamed(self.owner, generation.number, acquired.lease);
            return error.CatalogBindingMismatch;
        }
        self.bound = generation.number;
        self.name = acquired.lease;
        return self.name;
    }
};

fn leaseOf(lease: *const contract.CatalogLease) *RemoteLease {
    return @ptrCast(@alignCast(@constCast(lease)));
}

/// Lets go of the lease named `name` in process `number`, if that is the
/// process there is now. One that is gone took the lease with it.
fn releaseNamed(owner: *Owner, number: u32, name: u64) void {
    const generation = owner.live() orelse return;
    defer generation.release();
    if (generation.number != number) return;
    if (call(generation, .release_skill_catalog, name, .{})) |reply| {
        var value = reply;
        defer value.deinit();
        if (value.answer == .err)
            std.log.warn("execution process refused to release a skill catalog: {s}", .{@errorName(value.answer.err)});
    }
}

/// The query, without its source lifetime, in `arena`.
fn copySkillQuery(arena: std.mem.Allocator, query: contract.CatalogQuery) std.mem.Allocator.Error!rpc.SkillQuery {
    const sources = try arena.alloc(contract.CatalogSource, query.additional_sources.len);
    for (query.additional_sources, sources) |source, *target| target.* = .{
        .canonical_root = try arena.dupe(u8, source.canonical_root),
        .scope = source.scope,
        .source_instance_id = try arena.dupe(u8, source.source_instance_id),
        .priority = source.priority,
    };
    return .{
        .canonical_user_home = try arena.dupe(u8, query.canonical_user_home),
        .target = switch (query.target) {
            .management => .management,
            .workspace => |workspace| .{ .workspace = .{
                .canonical_root = try arena.dupe(u8, workspace.canonical_root),
                .epoch = try arena.dupe(u8, workspace.epoch),
            } },
        },
        .additional_sources = sources,
        .default_source_priority = query.default_source_priority,
    };
}

fn runtimeQuerySkillCatalog(context: ?*anyopaque, query: contract.CatalogQuery) Allocating!contract.CatalogAcquisition {
    const owner = ownerOf(context);
    if (query.source_lifetime) |lifetime| try lifetime.retain();
    const lease = owner.allocator.create(RemoteLease) catch |err| {
        if (query.source_lifetime) |lifetime| lifetime.release();
        return err;
    };
    lease.* = .{
        .owner = owner,
        .arena = .init(owner.allocator),
        .query = undefined,
        .source_lifetime = query.source_lifetime,
    };
    // From here the stand-in owns the pin, and its release lets go of it.
    errdefer lease.release();
    lease.query = try copySkillQuery(lease.arena.allocator(), query);
    const generation = owner.ensure() orelse return error.DependencyUnreachable;
    defer generation.release();
    var reply = call(generation, .query_skill_catalog, 0, lease.query) orelse return error.DependencyUnreachable;
    defer reply.deinit();
    const acquired = switch (reply.answer) {
        .err => |err| return narrow(Allocating, err),
        .ok => |value| value,
    };
    lease.bound = generation.number;
    lease.name = acquired.lease;
    lease.revision = try lease.arena.allocator().dupe(u8, acquired.revision);
    const projection = try contract.CatalogProjection.own(
        owner.allocator,
        acquired.revision,
        acquired.health,
        acquired.skills,
        acquired.issues,
    );
    return .{ .lease = @ptrCast(lease), .projection = projection };
}

/// Never refused: a lease of a process that is gone went with it.
fn runtimeReleaseSkillCatalog(_: ?*anyopaque, lease: *contract.CatalogLease) Error!void {
    leaseOf(lease).release();
}

const RemoteSkillInputs = struct {
    lease: *RemoteLease,
    arena: std.heap.ArenaAllocator,
    grants: []const []const u8,

    /// Takes the reference to `lease` in.
    fn create(owner: *Owner, lease: *RemoteLease, grants: []const []const u8) Allocating!*port.SkillRestoreInputs {
        errdefer lease.release();
        const self = try owner.allocator.create(RemoteSkillInputs);
        errdefer owner.allocator.destroy(self);
        self.* = .{ .lease = lease, .arena = .init(owner.allocator), .grants = &.{} };
        errdefer self.arena.deinit();
        const copied = try self.arena.allocator().alloc([]const u8, grants.len);
        for (grants, copied) |grant, *target| target.* = try self.arena.allocator().dupe(u8, grant);
        self.grants = copied;
        return @ptrCast(self);
    }

    fn of(inputs: *const port.SkillRestoreInputs) *RemoteSkillInputs {
        return @ptrCast(@alignCast(@constCast(inputs)));
    }

    fn destroy(self: *RemoteSkillInputs) void {
        const lease = self.lease;
        const allocator = lease.owner.allocator;
        self.arena.deinit();
        allocator.destroy(self);
        lease.release();
    }
};

/// A current Host policy may revoke original grants, never add one.
fn runtimeNarrowSkillRestoreInputs(context: ?*anyopaque, inputs: *port.SkillRestoreInputs, ceiling: surface.SkillPolicyInput) Allocating!*port.SkillRestoreInputs {
    const owner = ownerOf(context);
    const original = RemoteSkillInputs.of(inputs);
    var kept: std.ArrayList([]const u8) = .empty;
    defer kept.deinit(owner.allocator);
    for (original.grants) |grant| {
        for (ceiling.granted_skill_ids) |allowed| if (std.mem.eql(u8, grant, allowed)) {
            try kept.append(owner.allocator, grant);
            break;
        };
    }
    return RemoteSkillInputs.create(owner, original.lease.retain(), kept.items);
}

fn runtimeCloneSkillRestoreInputs(context: ?*anyopaque, inputs: *port.SkillRestoreInputs) Allocating!*port.SkillRestoreInputs {
    const original = RemoteSkillInputs.of(inputs);
    return RemoteSkillInputs.create(ownerOf(context), original.lease.retain(), original.grants);
}

/// Always made: the inputs are here.
fn runtimeBorrowSkillRestoreInputs(_: ?*anyopaque, inputs: *const port.SkillRestoreInputs) ?port.SkillRestoreBorrow {
    const value = RemoteSkillInputs.of(inputs);
    return .{ .catalog = @ptrCast(value.lease), .policy = .{ .granted_skill_ids = value.grants } };
}

fn runtimeReleaseSkillRestoreInputs(_: ?*anyopaque, inputs: *port.SkillRestoreInputs) Error!void {
    RemoteSkillInputs.of(inputs).destroy();
}

fn runtimeReleaseRestoreInputs(context: ?*anyopaque, inputs: *port.SessionRestoreInputs) Error!void {
    if (inputs.skill) |skill| try runtimeReleaseSkillRestoreInputs(context, skill);
    if (inputs.mcp) |selection| selection.deinit();
    inputs.* = undefined;
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
    .prepare_mcp_membership = runtimePrepareMcpMembership,
    .apply_mcp_configuration = runtimeApplyMcpConfiguration,
    .probe_mcp = runtimeProbeMcp,
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

fn sessionRefreshSkillCatalog(context: ?*anyopaque, lease: *contract.CatalogLease, policy: surface.SkillPolicyInput) Allocating!void {
    const remote = remoteOf(context);
    const stand_in = leaseOf(lease);
    const name = try stand_in.bind(remote.generation);
    try sessionCall(remote, .refresh_skill_catalog, Allocating, .{ .lease = name, .policy = policy });
    remote.rebindSkills(stand_in.retain());
}

fn sessionSetModel(context: ?*anyopaque, model: []const u8) Error!void {
    return sessionCall(remoteOf(context), .set_model, Error, .{ .model = model });
}

fn sessionClearSkillPolicy(context: ?*anyopaque) Allocating!void {
    const remote = remoteOf(context);
    try sessionCall(remote, .clear_skill_policy, Allocating, .{});
    remote.rebindSkills(null);
}

/// A lease that cannot be bound, or a Session that cannot be asked, does
/// not match: the caller then refreshes, which says why.
fn sessionSkillPolicyMatches(context: ?*anyopaque, lease: *contract.CatalogLease, policy: surface.SkillPolicyInput) bool {
    const remote = remoteOf(context);
    const name = leaseOf(lease).bind(remote.generation) catch return false;
    return sessionCall(remote, .skill_policy_matches, Error, .{ .lease = name, .policy = policy }) catch false;
}

fn sessionCaptureRestoreInputs(context: ?*anyopaque) Allocating!port.SessionRestoreInputs {
    const remote = remoteOf(context);
    const owner = remote.generation.owner;
    var reply = call(remote.generation, .capture_restore_inputs, remote.handle, .{}) orelse
        return error.DependencyUnreachable;
    defer reply.deinit();
    const captured = switch (reply.answer) {
        .err => |err| return narrow(Allocating, err),
        .ok => |value| value,
    };
    const skill: ?*port.SkillRestoreInputs = if (captured.skill) |grants| skill: {
        remote.mutex.lockUncancelable(remote.io());
        const lease = if (remote.skill_lease) |value| value.retain() else null;
        remote.mutex.unlock(remote.io());
        // Grants without the lease they were made against are not a
        // capture this half can make.
        break :skill try RemoteSkillInputs.create(owner, lease orelse return error.DependencyUnreachable, grants);
    } else null;
    errdefer if (skill) |value| RemoteSkillInputs.of(value).destroy();
    return .{
        .agent = owner.runtimePort(),
        .skill = skill,
        .mcp = if (captured.mcp) |value| try mcp_catalog.restoreSelectionFromWire(owner.allocator, value) else null,
        .permission_mode = captured.permission_mode,
        .shell_policy = captured.shell_policy,
        .permission_interaction = captured.permission_interaction,
    };
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
    return sessionCall(remoteOf(context), .prepare_run, Allocating, .{
        .input = input,
        .mcp_installation = null,
        .image = null,
        .video = null,
        .delivery = false,
    });
}

/// A Run's effects that stay with the Host, by what Product prepared.
const RunEffects = struct {
    image: ?surface.ImageGenerationRunInput,
    video: ?contract.VideoGenerationRunInput,
    delivery: ?contract.FileDeliveryInput,
};

/// A Run's effects with the callbacks still using them; see `EffectsLoan`.
const HeldEffects = struct {
    effects: RunEffects,
    loans: u32 = 0,
    /// The Run is over: nothing new borrows them.
    ending: bool = false,
};

fn sessionPrepareRunWithTools(
    context: ?*anyopaque,
    input: surface.RunInput,
    image: ?surface.ImageGenerationRunInput,
    delivery: ?contract.FileDeliveryInput,
    mcp: ?contract.McpInstallationInput,
    video: ?contract.VideoGenerationRunInput,
) Allocating!u64 {
    const remote = remoteOf(context);
    const owner = remote.generation.owner;
    if (mcp) |installation| {
        owner.mutex.lockUncancelable(owner.io);
        defer owner.mutex.unlock(owner.io);
        remote.installation = installation;
    }
    const has_effects = image != null or video != null or delivery != null;
    if (has_effects) {
        remote.mutex.lockUncancelable(remote.io());
        defer remote.mutex.unlock(remote.io());
        try remote.effects.ensureUnusedCapacity(owner.allocator, 1);
    }
    const run_id = try sessionCall(remote, .prepare_run, Allocating, .{
        .input = input,
        .mcp_installation = if (mcp) |installation| .{ .task_id = installation.task_id } else null,
        .image = if (image) |value| .{
            .endpoint = value.binding.endpoint,
            .source = value.binding.source,
            .model = value.binding.model,
            .credential = value.binding.credential,
            .renews_credential = value.binding.credential_reader != null,
        } else null,
        .video = if (video) |value| .{ .endpoint = value.endpoint, .source = value.source, .model = value.model } else null,
        .delivery = delivery != null,
    });
    if (has_effects) {
        remote.mutex.lockUncancelable(remote.io());
        defer remote.mutex.unlock(remote.io());
        remote.effects.putAssumeCapacity(run_id, .{ .effects = .{ .image = image, .video = video, .delivery = delivery } });
    }
    return run_id;
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
    defer remote.dropEffects(run_id);
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
    // Whatever the outcome, the Run is over when this returns, and Product
    // releases the effects it was given.
    defer remote.dropEffects(run_id);
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
    pub const Hook = struct {
        context: ?*anyopaque,
        call_fn: *const fn (?*anyopaque) void,
    };

    /// Called by a finishing callback once it is no longer counted, which is
    /// when a sweep may free its generation.
    pub var after_callback_counted_down: ?Hook = null;

    /// The current process's OS handle (Windows) or pid (POSIX), for a test
    /// that acts on the process itself. Not an identity: see `currentProcess`.
    pub fn currentChild(owner: *Owner) ?std.process.Child.Id {
        owner.mutex.lockUncancelable(owner.io);
        defer owner.mutex.unlock(owner.io);
        const generation = owner.current orelse return null;
        return generation.host.child.id;
    }

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

test "a finishing callback reads nothing of a generation a sweep may already have freed" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Woken = struct {
        count: std.atomic.Value(u32) = .init(0),
        fn notify(context: ?*anyopaque) control.EventReadyNotification {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            _ = self.count.fetchAdd(1, .monotonic);
            return .scheduled;
        }
    };
    var woken: Woken = .{};
    var owner: Owner = undefined;
    try owner.init(io, allocator, .{
        .identity = .{ .version = "unit", .core_manifest_sha256 = @splat(0), .core_abi_revision = 1 },
        .message_limits = .{ .event = 1024, .request = 1024, .response = 1024, .ui_request = 1024, .ui_response = 1024 },
        .queue_limits = .{},
        .spawn = .{ .explicit = &.{"never-started"} },
        .wake = .{ .context = &woken, .notify_fn = Woken.notify },
    });
    defer owner.deinit();
    // A generation with one callback in it, as the reader leaves it.
    const generation = try allocator.create(Generation);
    generation.* = .{ .owner = &owner, .number = 1, .floor = 0, .host = undefined, .pending = undefined };
    const callback = try allocator.create(Callback);
    callback.* = .{ .generation = generation, .correlation = 7, .bytes = try allocator.dupe(u8, "request") };
    try generation.callbacks.put(allocator, 7, callback);
    generation.callback_threads = 1;

    const Pause = struct {
        counted_down: std.Io.Event = .unset,
        go_on: std.Io.Event = .unset,
        fn call(context: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.counted_down.set(std.testing.io);
            self.go_on.waitUncancelable(std.testing.io);
        }
    };
    var pause: Pause = .{};
    TestSupport.after_callback_counted_down = .{ .context = &pause, .call_fn = Pause.call };
    defer TestSupport.after_callback_counted_down = null;
    const thread = try std.Thread.spawn(.{}, Callback.finish, .{callback});
    pause.counted_down.waitUncancelable(io);
    // What a sweep does once nothing counts against the generation: it goes,
    // and the allocator fills what it held.
    try std.testing.expectEqual(@as(u32, 0), generation.callback_threads);
    generation.callbacks.deinit(allocator);
    allocator.destroy(generation);
    pause.go_on.set(io);
    thread.join();
    try std.testing.expectEqual(@as(u32, 1), woken.count.load(.acquire));
}

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
