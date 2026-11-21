//! The execution half's server: one Agent Runtime, answering the calls the
//! UI half sends over the link.
//!
//! ## One failure model
//!
//! Anything this half cannot carry on from -- a frame it cannot read, a
//! handle it never issued, an allocation it cannot make -- ends the process.
//! The UI half reads that as the process being gone, which is the one
//! failure it handles, and nothing here has to answer "busy" or "half done".
//!
//! ## Threads
//!
//! The reader is the process's main thread and never runs a method: it
//! decodes, starts a thread for the request, and goes back to the pipe. Each
//! request gets its own thread, so a Run executing for minutes holds one
//! thread and a Stop sent meanwhile gets another. The UI half has a bounded
//! number of threads and each waits for its own answer, so the number of
//! request threads is bounded by the UI's.
//!
//! The forwarder is the only thread that takes events from the Runtime. It
//! sends one only when the UI half has made room for it (`Credit`), and it
//! sends a Run's or compact's terminal only once every event of that Session
//! is out, so the UI half receives the terminal after the events before it.
//!
//! ## Calling back
//!
//! What stays with the UI half -- an MCP server's transport, with its
//! connection and credentials -- is reached by a callback: the same request
//! frame and correlation table, the other way. The thread that needs the
//! effect waits for its answer, as it would have waited for the effect in
//! process. When the link is gone so is every answer, and the stand-in reports
//! the failure the in-process effect reports for a peer that went away.
//!
//! ## Being alive
//!
//! The reader answers the UI half's pings itself, between requests. A process
//! that stops answering them is one the UI half gives up on, whatever it is
//! doing, which is what keeps a UI thread waiting on this process from waiting
//! for ever.
//!
//! ## Lifetime
//!
//! Nothing here is ever freed. When the link ends, a watchdog is armed, the
//! Runtime shuts down, and the process exits without running the C runtime's
//! exit handlers (`hardExit`). Threads still inside a call may hold anything
//! in this file until the very end, so freeing it would be the bug.

const std = @import("std");
const builtin = @import("builtin");

const contract = @import("agent_contract");
const checkpoint = @import("agent_checkpoint");
const checkpoint_restore = @import("agent_checkpoint_restore");
const agent_link = @import("metawork_agent_link");
const execution_mode = @import("app_execution_mode");

const rpc = agent_link.rpc;
const shapes = agent_link.shapes;
const payload = agent_link.payload;
const channel = agent_link.channel;
const mcp_catalog = contract.mcp.catalog;
const mcp_runtime = contract.mcp.runtime;
const mcp_connector = contract.mcp.connector;

const Exit = execution_mode.Exit;

/// Stack for a thread that calls into the Agent Runtime. The same commit the
/// Product executor gives its workers, which make the same calls in process.
pub const call_stack_bytes: usize = 4 * 1024 * 1024;

/// How long tidying up may take once the link has ended.
pub const default_exit_deadline_ms: u64 = 3_000;

/// How often a callback whose caller can withdraw it looks at whether it
/// has. The answer itself wakes it at once; this only bounds how late a Stop
/// reaches an MCP exchange in flight.
pub const cancellation_poll_ms: i64 = 50;

/// Callbacks waiting at once. Each waits on the thread that needs its answer,
/// so this bounds those threads' concurrency, never the link.
const callback_slots: usize = 64;

/// Written once when the server takes the link. The acceptance checks look
/// for it in the executable to tell whether a build contains this file.
pub const serving_marker = "execution half serving an Agent Runtime";

/// What the composition root hands over: a Runtime made with the notifier
/// this server supplies, and how to shut it down.
pub const Runtime = struct {
    port: contract.port.RuntimePort,
    context: ?*anyopaque,
    shutdown_fn: *const fn (?*anyopaque) void,
};

pub const Factory = struct {
    context: ?*anyopaque,
    create_fn: *const fn (?*anyopaque, contract.control.EventReadyNotifier) ?Runtime,
};

pub const Options = struct {
    factory: Factory,
    exit_deadline_ms: u64 = default_exit_deadline_ms,
    /// Tests only: wait this long before sending each event, so that a
    /// terminal not held behind its events would observably overtake them.
    event_delay_ms: u64 = 0,
    /// Names each executing Run in the fault record, as the window's own
    /// workers do, so a fault here says which Tasks it interrupted.
    run_breadcrumbs: ?RunBreadcrumbs = null,
};

pub const RunBreadcrumbs = struct {
    begin_fn: *const fn (task_id: u64, run_id: u64) u32,
    finish_fn: *const fn (claim: u32, task_id: u64, run_id: u64) void,
};

/// Ends this process now, running nothing on the way out.
///
/// Not `std.process.exit`: with libc linked that is `exit()`, which runs
/// every registered exit handler, and a handler that waits on a thread still
/// inside the Runtime would hang the process the deadline exists to end.
pub fn hardExit(code: u8) noreturn {
    switch (builtin.os.tag) {
        .windows => {
            _ = std.os.windows.ntdll.NtTerminateProcess(
                std.os.windows.GetCurrentProcess(),
                @enumFromInt(@as(u32, code)),
            );
            unreachable;
        },
        else => if (builtin.link_libc) std.c._exit(code) else std.os.linux.exit_group(code),
    }
}

/// The execution-mode server for `options`. `options` must outlive the
/// process, which in practice means a value in the caller's `main`.
pub fn server(options: *const Options) execution_mode.Server {
    return .{ .context = @constCast(options), .serve_fn = serve };
}

fn serve(context: ?*anyopaque, link: execution_mode.Link) Exit {
    const options: *const Options = @ptrCast(@alignCast(context.?));
    const self = link.allocator.create(Server) catch return .resource_unavailable;
    self.* = .{
        .io = link.io,
        .allocator = link.allocator,
        .outbound = undefined,
        .callbacks = undefined,
        .registry = .{ .allocator = link.allocator, .io = link.io },
        .runtime = undefined,
        .event_delay_ms = options.event_delay_ms,
        .run_breadcrumbs = options.run_breadcrumbs,
    };
    self.callbacks.init(link.io, link.allocator, callback_slots) catch return .resource_unavailable;
    self.outbound.start(link.io, link.allocator, link.output, link.queue_limits) catch
        return .resource_unavailable;
    self.runtime = options.factory.create_fn(options.factory.context, .{
        .context = self,
        .notify_fn = notifyEvents,
    }) orelse return .resource_unavailable;
    std.log.info(serving_marker, .{});

    const forwarder = std.Thread.spawn(
        .{ .stack_size = channel.io_thread_stack_bytes },
        forwarderMain,
        .{self},
    ) catch return .resource_unavailable;
    forwarder.detach();

    var inbound: channel.Inbound = undefined;
    inbound.init(link.io, link.allocator, link.reader, link.message_limits, .{
        .context = self,
        .deliver_fn = deliver,
    }) catch return .resource_unavailable;
    const ended = inbound.run();

    // The link is over. From here every path ends the process, and the
    // watchdog is what bounds the one that does not end by itself. Nothing
    // will answer a callback now, so none waits for one.
    armWatchdog(link.io, options.exit_deadline_ms);
    self.callbacks.close();
    self.runtime.shutdown_fn(self.runtime.context);
    return switch (ended) {
        .peer_closed, .consumer_stopped => if (self.violated.load(.acquire)) .protocol_violation else .link_closed,
        .read_failed => .transport_failed,
        .out_of_memory => .resource_unavailable,
        .violation => .protocol_violation,
    };
}

fn armWatchdog(io: std.Io, deadline_ms: u64) void {
    const Watchdog = struct {
        fn run(watch_io: std.Io, milliseconds: u64) void {
            std.Io.sleep(watch_io, .fromMilliseconds(@intCast(milliseconds)), .awake) catch {};
            hardExit(@intFromEnum(Exit.exit_deadline));
        }
    };
    const thread = std.Thread.spawn(.{ .stack_size = 64 * 1024 }, Watchdog.run, .{ io, deadline_ms }) catch
        hardExit(@intFromEnum(Exit.exit_deadline));
    thread.detach();
}

const Server = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    outbound: channel.Outbound,
    /// The calls this half makes of the UI half.
    callbacks: agent_link.pending.Table,
    registry: Registry,
    runtime: Runtime,
    violated: std.atomic.Value(bool) = .init(false),
    event_delay_ms: u64 = 0,
    run_breadcrumbs: ?RunBreadcrumbs = null,

    /// The transport each MCP server in the Runtime's applied configuration
    /// reaches its server through, by server id. A member whose server and
    /// transport are both here is the Runtime's already; any other is new.
    mcp_mutex: std.Io.Mutex = .init,
    mcp_members: std.StringHashMapUnmanaged(u64) = .empty,

    /// Skill catalog leases the UI half names, each holding the reference
    /// its acquisition took until the UI half lets go of it.
    leases: Leases = .{},

    forward_mutex: std.Io.Mutex = .init,
    forward_condition: std.Io.Condition = .init,
    /// Set by anything the forwarder has to look at again.
    forward_signal: bool = false,
    granted: rpc.Credit = .{ .count = 0, .bytes = 0 },
    deferred: std.ArrayList(Deferred) = .empty,

    /// Ends the process for a fault on this side. The UI half reads the end
    /// of the stream, which is the one failure it handles.
    fn fail(self: *Server, exit: Exit) noreturn {
        _ = self;
        hardExit(@intFromEnum(exit));
    }

    fn signalForwarder(self: *Server) void {
        self.forward_mutex.lockUncancelable(self.io);
        self.forward_signal = true;
        self.forward_condition.signal(self.io);
        self.forward_mutex.unlock(self.io);
    }
};

/// A terminal waiting for its Session's events to be out.
const Deferred = struct {
    route_id: u64,
    correlation: u64,
    bytes: []u8,
};

// ---------------------------------------------------------------------------
// Sessions, named by the handle this half gave them
// ---------------------------------------------------------------------------

const Entry = struct {
    route_id: u64,
    /// Product's Task, which a fault record names.
    task_id: u64,
    session: contract.port.SessionPort,
    /// Begun Runs, until their `execute` returns.
    runs: std.AutoHashMapUnmanaged(u64, contract.port.RunPort) = .empty,
    /// The Session's control, taken from its first begun Run. A Run's
    /// control is the Session's control block plus the Run's identity, so
    /// one value serves every Run of the Session.
    control: ?contract.port.RunControl = null,
    /// What a Run of this Session hands the Host an MCP installation
    /// through, by calling back. Lives as long as the Session.
    installation: Installation = undefined,
    /// The file delivery and media stand-ins of prepared Runs, until the Run
    /// is over. Under the registry's lock.
    effects: std.AutoHashMapUnmanaged(u64, *RunEffects) = .empty,
    uses: u32 = 0,
    removed: bool = false,
};

/// The MCP installation capability a Run is given, standing in for the
/// Host's: a request goes to the UI half, which owns the capability.
const Installation = struct {
    server: *Server,
    handle: u64,

    fn input(self: *Installation, task_id: u64) contract.McpInstallationInput {
        return .{
            .context = self,
            .allocator = self.server.allocator,
            .task_id = task_id,
            .try_put_fn = tryPut,
            .wake_fn = wake,
        };
    }

    fn tryPut(
        context: *anyopaque,
        task_id: u64,
        run_id: u64,
        generation: u64,
        draft: contract.McpInstallationRequest,
    ) contract.McpInstallationResult {
        const self: *Installation = @ptrCast(@alignCast(context));
        var answer = callBack(self.server, .mcp_install_put, self.handle, .{
            .task_id = task_id,
            .run_id = run_id,
            .generation = generation,
            .json = draft.json,
        }, null) orelse return .unavailable;
        defer answer.deinit();
        // Submitted, the request is the Host's now, as its own copy; this
        // one is released here, since the caller no longer holds it.
        if (answer.value == .submitted) {
            var sent = draft;
            sent.deinit();
        }
        return answer.value;
    }

    fn wake(context: *anyopaque) void {
        const self: *Installation = @ptrCast(@alignCast(context));
        if (callBack(self.server, .mcp_install_wake, self.handle, .{}, null)) |answer| {
            var value = answer;
            value.deinit();
        }
    }
};

/// Every Session this half has opened.
///
/// Request threads use it concurrently, so it has one lock, and nothing
/// outside this struct sees the map. An entry is freed only when it has been
/// removed and no thread is still using it.
const Registry = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    entries: std.AutoHashMapUnmanaged(u64, *Entry) = .empty,
    next: u64 = 0,

    fn add(self: *Registry, half: *Server, route_id: u64, task_id: u64, session: contract.port.SessionPort) std.mem.Allocator.Error!u64 {
        const entry = try self.allocator.create(Entry);
        errdefer self.allocator.destroy(entry);
        entry.* = .{ .route_id = route_id, .task_id = task_id, .session = session };
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.entries.ensureUnusedCapacity(self.allocator, 1);
        self.next += 1;
        entry.installation = .{ .server = half, .handle = self.next };
        self.entries.putAssumeCapacity(self.next, entry);
        return self.next;
    }

    fn acquire(self: *Registry, handle: u64) ?*Entry {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const entry = self.entries.get(handle) orelse return null;
        entry.uses += 1;
        return entry;
    }

    fn release(self: *Registry, entry: *Entry) void {
        self.mutex.lockUncancelable(self.io);
        std.debug.assert(entry.uses > 0);
        entry.uses -= 1;
        const free = entry.removed and entry.uses == 0;
        self.mutex.unlock(self.io);
        if (free) self.destroy(entry);
    }

    /// Takes the handle out of use. The entry lives until its last user is
    /// done, so a thread still inside a call on it never reads freed memory.
    fn remove(self: *Registry, handle: u64) void {
        self.mutex.lockUncancelable(self.io);
        const entry = self.entries.fetchRemove(handle) orelse {
            self.mutex.unlock(self.io);
            return;
        };
        entry.value.removed = true;
        const free = entry.value.uses == 0;
        self.mutex.unlock(self.io);
        if (free) self.destroy(entry.value);
    }

    fn destroy(self: *Registry, entry: *Entry) void {
        entry.runs.deinit(self.allocator);
        var effects = entry.effects.valueIterator();
        while (effects.next()) |value| value.*.destroy();
        entry.effects.deinit(self.allocator);
        self.allocator.destroy(entry);
    }

    fn putEffects(self: *Registry, entry: *Entry, run_id: u64, effects: *RunEffects) std.mem.Allocator.Error!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try entry.effects.put(self.allocator, run_id, effects);
    }

    /// The Run is over, or will never start: its stand-ins go.
    fn dropEffects(self: *Registry, entry: *Entry, run_id: u64) void {
        self.mutex.lockUncancelable(self.io);
        const removed = entry.effects.fetchRemove(run_id);
        self.mutex.unlock(self.io);
        if (removed) |value| value.value.destroy();
    }

    fn reserveRun(self: *Registry, entry: *Entry) std.mem.Allocator.Error!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try entry.runs.ensureUnusedCapacity(self.allocator, 1);
    }

    fn putRun(self: *Registry, entry: *Entry, run: contract.port.RunPort) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        entry.runs.putAssumeCapacity(run.run_id, run);
        if (entry.control == null) entry.control = run.control();
    }

    fn takeRun(self: *Registry, entry: *Entry, run_id: u64) ?contract.port.RunPort {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const removed = entry.runs.fetchRemove(run_id) orelse return null;
        return removed.value;
    }

    fn controlOf(self: *Registry, entry: *Entry) ?contract.port.RunControl {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return entry.control;
    }
};

/// Leases by the name this half gave them. Names are never reused, so a name
/// the UI half still holds after letting go of it resolves to nothing.
const Leases = struct {
    mutex: std.Io.Mutex = .init,
    entries: std.AutoHashMapUnmanaged(u64, *contract.CatalogLease) = .empty,
    next: u64 = 0,

    fn add(self: *Leases, half: *Server, lease: *contract.CatalogLease) std.mem.Allocator.Error!u64 {
        self.mutex.lockUncancelable(half.io);
        defer self.mutex.unlock(half.io);
        try self.entries.ensureUnusedCapacity(half.allocator, 1);
        self.next += 1;
        self.entries.putAssumeCapacity(self.next, lease);
        return self.next;
    }

    fn get(self: *Leases, half: *Server, id: u64) ?*contract.CatalogLease {
        self.mutex.lockUncancelable(half.io);
        defer self.mutex.unlock(half.io);
        return self.entries.get(id);
    }

    fn take(self: *Leases, half: *Server, id: u64) ?*contract.CatalogLease {
        self.mutex.lockUncancelable(half.io);
        defer self.mutex.unlock(half.io);
        const removed = self.entries.fetchRemove(id) orelse return null;
        return removed.value;
    }
};

/// The lease a request names, which the UI half was given by this half. A
/// name it never gave is a peer that is not the UI half it serves.
fn resolveLease(self: *Server, id: ?u64) ?*contract.CatalogLease {
    const name = id orelse return null;
    return self.leases.get(self, name) orelse self.fail(.protocol_violation);
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

fn deliver(context: ?*anyopaque, kind: agent_link.Kind, correlation: u64, bytes: []const u8) channel.Flow {
    const self: *Server = @ptrCast(@alignCast(context.?));
    switch (kind) {
        .request => {
            const owned = self.allocator.dupe(u8, bytes) catch self.fail(.resource_unavailable);
            const thread = std.Thread.spawn(
                .{ .stack_size = call_stack_bytes },
                answerRequest,
                .{ self, correlation, owned },
            ) catch self.fail(.resource_unavailable);
            thread.detach();
            return .ok;
        },
        .response => {
            const owned = self.allocator.dupe(u8, bytes) catch self.fail(.resource_unavailable);
            self.callbacks.deposit(correlation, owned);
            return .ok;
        },
        .control => {
            var arena_storage: [64]u8 = undefined;
            var fixed = std.heap.FixedBufferAllocator.init(&arena_storage);
            const value = payload.decodeExact(rpc.Control, fixed.allocator(), bytes) catch {
                self.violated.store(true, .release);
                return .stop;
            };
            switch (value) {
                .credit => |credit| {
                    self.forward_mutex.lockUncancelable(self.io);
                    // Totals only grow; an older frame arriving late changes
                    // nothing.
                    self.granted.count = @max(self.granted.count, credit.count);
                    self.granted.bytes = @max(self.granted.bytes, credit.bytes);
                    self.forward_signal = true;
                    self.forward_condition.signal(self.io);
                    self.forward_mutex.unlock(self.io);
                },
                .ping => |number| sendControl(self, .{ .pong = number }),
                .pong, .cancel => {
                    self.violated.store(true, .release);
                    return .stop;
                },
            }
            return .ok;
        },
        else => {
            self.violated.store(true, .release);
            return .stop;
        },
    }
}

fn answerRequest(self: *Server, correlation: u64, bytes: []u8) void {
    defer {
        std.crypto.secureZero(u8, bytes);
        self.allocator.free(bytes);
    }
    const received = rpc.decodeRequestHeader(bytes) catch self.fail(.protocol_violation);
    switch (received.method) {
        inline else => |method| dispatch(self, method, correlation, received.handle, received.body),
    }
}

// ---------------------------------------------------------------------------
// Answering
// ---------------------------------------------------------------------------

/// A Session's own failure travels as its number; anything else is this
/// side unable to go on.
fn reply(self: *Server, comptime method: rpc.Method, result: anytype) []u8 {
    const R = rpc.Response(method);
    const bytes = if (@typeInfo(@TypeOf(result)) == .error_union)
        (if (result) |value| rpc.encodeOk(method, self.allocator, value) else |err| rpc.encodeError(self.allocator, err))
    else
        rpc.encodeOk(method, self.allocator, @as(R, result));
    return bytes catch self.fail(.resource_unavailable);
}

fn replyError(self: *Server, err: agent_link.error_code.LinkError) []u8 {
    return rpc.encodeError(self.allocator, err) catch self.fail(.resource_unavailable);
}

fn send(self: *Server, correlation: u64, bytes: []u8) void {
    defer {
        std.crypto.secureZero(u8, bytes);
        self.allocator.free(bytes);
    }
    const submitted = self.outbound.submitWaiting(.response, correlation, bytes) catch self.fail(.resource_unavailable);
    // `.closed` is the link already ending; the process ends with it.
    _ = submitted;
}

fn deferTerminal(self: *Server, route_id: u64, correlation: u64, bytes: []u8) void {
    self.forward_mutex.lockUncancelable(self.io);
    defer self.forward_mutex.unlock(self.io);
    self.deferred.append(self.allocator, .{
        .route_id = route_id,
        .correlation = correlation,
        .bytes = bytes,
    }) catch self.fail(.resource_unavailable);
    self.forward_signal = true;
    self.forward_condition.signal(self.io);
}

fn dispatch(
    self: *Server,
    comptime method: rpc.Method,
    correlation: u64,
    handle: u64,
    body: []const u8,
) void {
    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const request = rpc.decodeRequest(method, arena, body) catch self.fail(.protocol_violation);

    if (comptime !method.namesSession()) {
        const bytes = answerRuntime(self, method, handle, request, arena);
        return send(self, correlation, bytes);
    }

    // A handle this half never issued, or one already released, is a peer
    // that is not the UI half this process was started by.
    const entry = self.registry.acquire(handle) orelse self.fail(.protocol_violation);
    defer self.registry.release(entry);
    const bytes = answerSession(self, method, handle, entry, request, arena);
    if (comptime method.isTerminal())
        deferTerminal(self, entry.route_id, correlation, bytes)
    else
        send(self, correlation, bytes);
}

fn answerRuntime(self: *Server, comptime method: rpc.Method, handle: u64, request: rpc.Request(method), arena: std.mem.Allocator) []u8 {
    const runtime = self.runtime.port;
    switch (method) {
        .release_skill_catalog => {
            const lease = self.leases.take(self, handle) orelse self.fail(.protocol_violation);
            runtime.releaseSkillCatalog(lease) catch |err| return replyError(self, err);
            return reply(self, method, {});
        },
        .create_session => {
            var opened = rpc.openOptionsFromWire(request, resolveLease(self, request.skill_catalog), self.allocator) catch
                self.fail(.resource_unavailable);
            defer opened.deinit();
            const route = runtime.createSessionRoute(opened.options) catch |err| return replyError(self, err);
            const id = self.registry.add(self, route.id, request.task_id, route.session) catch self.fail(.resource_unavailable);
            return reply(self, method, rpc.SessionRoute{ .route_id = route.id, .handle = id });
        },
        .restore_session => {
            var source: MemorySource = .{ .bytes = request.source.bytes, .end = request.source.end };
            var opened = rpc.openOptionsFromWire(request.session, resolveLease(self, request.session.skill_catalog), self.allocator) catch
                self.fail(.resource_unavailable);
            defer opened.deinit();
            const options: contract.surface.SessionRestoreOptions = .{
                .session = opened.options,
                .checkpoint_limits = request.checkpoint_limits,
                .source = source.source(),
                .expectation = .{
                    .logical_session_id = request.expectation.logical_session_id,
                    .checkpoint_generation = request.expectation.checkpoint_generation,
                    .last_run_id = request.expectation.last_run_id,
                    .last_compact_id = request.expectation.last_compact_id,
                    .model = request.expectation.model,
                },
            };
            const route = runtime.restoreSessionRoute(options) catch |err| return replyError(self, err);
            const id = self.registry.add(self, route.id, request.session.task_id, route.session) catch self.fail(.resource_unavailable);
            return reply(self, method, rpc.SessionRestoreRoute{ .route_id = route.id, .handle = id, .report = route.report });
        },
        .request_run_termination => return reply(self, method, runtime.requestRunTermination(request.session_id, request.run_id, request.signal)),
        .restore_admission => return reply(self, method, runtime.restoreAdmission(request.releasing_route_id)),
        .activate_mcp => {
            const outcome = runtime.activateMcp() catch |err| return replyError(self, err);
            return replyActivation(self, method, outcome, arena);
        },
        .create_mcp_admission_selection => {
            const activation = mcp_catalog.activationFromWire(self.allocator, self.io, request.activation) catch
                self.fail(.resource_unavailable);
            defer activation.deinit();
            const selection = runtime.createMcpAdmissionSelection(activation, request.allowlists) catch |err|
                return replyError(self, err);
            defer if (selection) |value| value.deinit();
            const wire_selection = if (selection) |value|
                mcp_catalog.selectionToWire(value, arena) catch self.fail(.resource_unavailable)
            else
                null;
            return reply(self, method, wire_selection);
        },
        .prepare_mcp_restore_selection => {
            const original = mcp_catalog.restoreSelectionFromWire(self.allocator, request.original) catch
                self.fail(.resource_unavailable);
            defer original.deinit();
            const activation = mcp_catalog.activationFromWire(self.allocator, self.io, request.activation) catch
                self.fail(.resource_unavailable);
            defer activation.deinit();
            const selection = runtime.prepareMcpRestoreSelection(original, activation, request.ceiling) catch |err|
                return replyError(self, err);
            defer selection.deinit();
            return reply(self, method, mcp_catalog.selectionToWire(selection, arena) catch self.fail(.resource_unavailable));
        },
        .apply_mcp_configuration => return applyMcp(self, request, arena),
        .query_skill_catalog => {
            var acquisition = runtime.querySkillCatalog(.{
                .canonical_user_home = request.canonical_user_home,
                .target = request.target,
                .additional_sources = request.additional_sources,
                .default_source_priority = request.default_source_priority,
            }) catch |err| return replyError(self, err);
            defer acquisition.deinitProjection();
            const id = self.leases.add(self, acquisition.lease) catch self.fail(.resource_unavailable);
            const projection = acquisition.projection;
            return reply(self, method, rpc.SkillAcquisition{
                .lease = id,
                .revision = projection.revision,
                .health = projection.health,
                .skills = projection.skills,
                .issues = projection.issues,
            });
        },
        .probe_mcp => {
            var input = standInMembership(self, request, true) catch |err| switch (err) {
                error.OutOfMemory => self.fail(.resource_unavailable),
                error.InvalidConfig => return replyError(self, error.McpConfigurationApplyFailed),
            };
            defer input.deinit();
            const outcome = runtime.probeMcp(&input) catch |err| return replyError(self, err);
            return replyActivation(self, method, outcome, arena);
        },
        else => comptime unreachable,
    }
}

fn replyActivation(
    self: *Server,
    comptime method: rpc.Method,
    outcome: contract.surface.McpActivationOutcome,
    arena: std.mem.Allocator,
) []u8 {
    defer if (outcome == .activated) outcome.activated.deinit();
    const value = rpc.activationOutcomeToWire(outcome, arena) catch self.fail(.resource_unavailable);
    return reply(self, method, value);
}

/// An input whose members reach their servers through the UI half. With
/// `all`, every member is new; otherwise only those the Runtime's applied
/// configuration does not already hold with the same transport.
fn standInMembership(self: *Server, request: rpc.McpMembership, all: bool) (std.mem.Allocator.Error || mcp_runtime.Error)!mcp_runtime.Input {
    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var inputs: std.ArrayList(mcp_runtime.ServerInput) = .empty;
    var owners: std.ArrayList(*mcp_connector.TransportOwner) = .empty;
    errdefer for (owners.items) |owner| owner.deinit();
    for (request.members) |member| {
        if (!all) {
            self.mcp_mutex.lockUncancelable(self.io);
            const held = self.mcp_members.get(member.descriptor.id);
            self.mcp_mutex.unlock(self.io);
            if (held == member.transport) continue;
        }
        const owner = try arena.create(mcp_connector.TransportOwner);
        owner.* = try RemoteTransport.create(self, member.transport);
        try owners.append(arena, owner);
        try inputs.append(arena, member.descriptor.input(owner));
    }
    // Input construction takes every owner or none.
    const input = try mcp_runtime.Input.init(self.allocator, request.generation, inputs.items);
    owners.clearRetainingCapacity();
    return input;
}

fn applyMcp(self: *Server, request: rpc.McpMembership, arena: std.mem.Allocator) []u8 {
    const runtime = self.runtime.port;
    var additions = standInMembership(self, request, false) catch |err| switch (err) {
        error.OutOfMemory => self.fail(.resource_unavailable),
        error.InvalidConfig => return replyError(self, error.McpConfigurationApplyFailed),
    };
    defer additions.deinit();
    const ids = arena.alloc([]const u8, request.members.len) catch self.fail(.resource_unavailable);
    for (request.members, ids) |member, *id| id.* = member.descriptor.id;
    var input = runtime.prepareMcpMembership(request.generation, &additions, ids) catch |err|
        return replyError(self, err);
    defer input.deinit();
    const outcome = runtime.applyMcpConfiguration(&input) catch |err| return replyError(self, err);
    if (outcome == .applied) {
        // What the Runtime now holds, by server.
        var next: std.StringHashMapUnmanaged(u64) = .empty;
        for (request.members) |member| {
            const id = self.allocator.dupe(u8, member.descriptor.id) catch self.fail(.resource_unavailable);
            next.put(self.allocator, id, member.transport) catch self.fail(.resource_unavailable);
        }
        self.mcp_mutex.lockUncancelable(self.io);
        var previous = self.mcp_members;
        self.mcp_members = next;
        self.mcp_mutex.unlock(self.io);
        var keys = previous.keyIterator();
        while (keys.next()) |key| self.allocator.free(key.*);
        previous.deinit(self.allocator);
    }
    return reply(self, .apply_mcp_configuration, outcome);
}

fn answerSession(
    self: *Server,
    comptime method: rpc.Method,
    handle: u64,
    entry: *Entry,
    request: rpc.Request(method),
    arena: std.mem.Allocator,
) []u8 {
    const session = entry.session;
    return switch (method) {
        .release_closed_session => released: {
            self.runtime.port.releaseClosedSession(session) catch |err|
                break :released replyError(self, err);
            self.registry.remove(handle);
            break :released reply(self, method, {});
        },
        .stop_event_delivery => stopped: {
            session.stopEventDelivery();
            break :stopped reply(self, method, {});
        },
        .close => reply(self, method, shapes.CloseOutcome.from(session.closeOutcome(request.interruption))),
        .clear_skill_policy => reply(self, method, session.clearSkillPolicy()),
        .set_model => reply(self, method, session.setModel(request.model)),
        .snapshot => reply(self, method, session.snapshot()),
        .update_permission_mode => reply(self, method, session.updatePermissionMode(request.expected, request.target)),
        .conversation_bounds => reply(self, method, session.conversationBounds()),
        .rewind_to_user_message => reply(self, method, session.rewindToUserMessage(request.position)),
        .update_credential => reply(self, method, session.updateCredential(request.credential)),
        .request_termination => reply(self, method, session.requestTermination(request.run_id, request.signal)),
        .prepare_run => prepared: {
            const installation: ?contract.McpInstallationInput = if (request.mcp_installation) |value|
                entry.installation.input(value.task_id)
            else
                null;
            if (request.image == null and request.video == null and !request.delivery) {
                break :prepared reply(self, method, if (installation) |value|
                    session.prepareRunWithTools(request.input, null, null, value, null)
                else
                    session.prepareRun(request.input));
            }
            const effects = RunEffects.create(self, entry, request.image, request.video) catch self.fail(.resource_unavailable);
            const run_id = session.prepareRunWithTools(
                request.input,
                if (request.image != null) effects.imageInput() else null,
                if (request.delivery) effects.deliveryInput() else null,
                installation,
                if (request.video != null) effects.videoInput() else null,
            ) catch |err| {
                effects.destroy();
                break :prepared replyError(self, err);
            };
            effects.run_id = run_id;
            self.registry.putEffects(entry, run_id, effects) catch self.fail(.resource_unavailable);
            break :prepared reply(self, method, run_id);
        },
        .cancel_prepared_run => cancelled: {
            session.cancelPreparedRun(request.run_id) catch |err| break :cancelled replyError(self, err);
            self.registry.dropEffects(entry, request.run_id);
            break :cancelled reply(self, method, {});
        },
        .prepare_compact => reply(self, method, session.prepareCompact()),
        .cancel_prepared_compact => reply(self, method, session.cancelPreparedCompact(request.operation_id)),
        .request_compact_cancellation => reply(self, method, session.requestCompactCancellation(request.operation_id, request.interruption)),
        .respond_permission => reply(self, method, session.respondPermission(request.run_id, request.request_id, request.choice)),
        .fail_ui_request_identity_contract => reply(self, method, session.failUiRequestIdentityContract(request.run_id)),
        .pending_ui_observation => reply(self, method, session.pendingUiObservation()),
        .permission_stop_request => reply(self, method, session.permissionStopRequest()),
        .capture_restore_inputs => captured: {
            var inputs = session.captureRestoreInputs() catch |err| break :captured replyError(self, err);
            defer inputs.release() catch {};
            break :captured reply(self, method, rpc.RestoreInputs{
                .skill = if (inputs.skill) |skill|
                    (inputs.agent.borrowSkillRestoreInputs(skill) orelse self.fail(.resource_unavailable)).policy.granted_skill_ids
                else
                    null,
                .mcp = if (inputs.mcp) |value| mcp_catalog.restoreSelectionToWire(value) else null,
                .permission_mode = inputs.permission_mode,
                .shell_policy = inputs.shell_policy,
                .permission_interaction = inputs.permission_interaction,
            });
        },
        .refresh_skill_catalog => reply(self, method, session.refreshSkillCatalog(
            resolveLease(self, request.lease).?,
            request.policy,
        )),
        .skill_policy_matches => reply(self, method, session.skillPolicyMatches(
            resolveLease(self, request.lease).?,
            request.policy,
        )),
        .copy_pending_ui_request => copied: {
            const value = session.copyPendingUiRequest(arena) catch |err|
                break :copied replyError(self, err);
            break :copied reply(self, method, shapes.PendingUiRequest.from(&value));
        },
        .begin_run => begun: {
            // Room first: a begun Run must be kept until it is executed, and
            // it cannot be handed back.
            self.registry.reserveRun(entry) catch self.fail(.resource_unavailable);
            switch (session.beginRunOutcome(request.run_id)) {
                .run => |run| {
                    self.registry.putRun(entry, run);
                    break :begun reply(self, method, rpc.BeginRun{ .run = .{
                        .run_id = run.run_id,
                        .generation = run.generation,
                    } });
                },
                .failure => |failure| break :begun reply(self, method, rpc.BeginRun{
                    .failure = shapes.BeginRunFailure.from(failure),
                }),
            }
        },
        .execute_prepared_compact => compacted: {
            var result = session.executePreparedCompact(request.operation_id) catch |err|
                break :compacted replyError(self, err);
            defer result.deinit();
            break :compacted reply(self, method, shapes.CompactTerminalResult.from(&result));
        },
        .export_checkpoint => exported: {
            var sink: MemorySink = .{ .allocator = self.allocator };
            defer sink.deinit();
            var outcome = session.exportCheckpoint(
                request.limits,
                sink.sink(),
                request.expected_last_run_id,
                request.expected_last_compact_id,
                request.expected_model,
            ) catch |err| break :exported replyError(self, err);
            defer outcome.deinit();
            if (sink.failed) self.fail(.resource_unavailable);
            break :exported reply(self, method, rpc.ExportResponse{
                .outcome = rpc.outcomeToWire(&outcome),
                .bytes = if (outcome == .success) sink.bytes.items else "",
            });
        },
        .run_execute => executed: {
            var run = self.registry.takeRun(entry, request.run_id) orelse self.fail(.protocol_violation);
            if (run.generation != request.generation) self.fail(.protocol_violation);
            const claim = if (self.run_breadcrumbs) |crumbs| crumbs.begin_fn(entry.task_id, request.run_id) else 0;
            var result = run.execute();
            if (self.run_breadcrumbs) |crumbs| crumbs.finish_fn(claim, entry.task_id, request.run_id);
            run.deinit();
            defer result.deinit();
            self.registry.dropEffects(entry, request.run_id);
            break :executed reply(self, method, shapes.TerminalResult.from(&result));
        },
        .run_submit_input => submitted: {
            const control = self.registry.controlOf(entry) orelse self.fail(.protocol_violation);
            break :submitted reply(self, method, control.vtable.?.submit_input(
                control.context,
                request.run_id,
                request.generation,
                request.input_id,
                request.text,
            ));
        },
        .run_input_observation => observed: {
            const control = self.registry.controlOf(entry) orelse self.fail(.protocol_violation);
            break :observed reply(self, method, control.vtable.?.input_observation(
                control.context,
                request.run_id,
                request.generation,
            ));
        },
        .run_request_termination => terminated: {
            const control = self.registry.controlOf(entry) orelse self.fail(.protocol_violation);
            break :terminated reply(self, method, control.vtable.?.request_termination(
                control.context,
                request.run_id,
                request.generation,
                request.signal,
            ));
        },
        .create_session,
        .restore_session,
        .request_run_termination,
        .restore_admission,
        .activate_mcp,
        .create_mcp_admission_selection,
        .prepare_mcp_restore_selection,
        .apply_mcp_configuration,
        .probe_mcp,
        .query_skill_catalog,
        .release_skill_catalog,
        => comptime unreachable,
    };
}

/// An export's bytes, kept here until the response carries them.
const MemorySink = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    failed: bool = false,

    fn sink(self: *MemorySink) checkpoint.Sink {
        return .{ .context = self, .write_fn = write };
    }

    fn write(context: ?*anyopaque, chunk: []const u8) checkpoint.SinkWriteResult {
        const self: *MemorySink = @ptrCast(@alignCast(context.?));
        self.bytes.appendSlice(self.allocator, chunk) catch {
            self.failed = true;
            return .io_failed;
        };
        return .ok;
    }

    fn deinit(self: *MemorySink) void {
        std.crypto.secureZero(u8, self.bytes.items);
        self.bytes.deinit(self.allocator);
    }
};

/// A restore's bytes, replayed as the caller's source returned them: the
/// bytes, then whatever its last read said.
const MemorySource = struct {
    bytes: []const u8,
    end: checkpoint_restore.SourceReadResult,
    offset: usize = 0,

    fn source(self: *MemorySource) checkpoint_restore.Source {
        return .{ .context = self, .read_fn = read };
    }

    fn read(context: ?*anyopaque, buffer: []u8) checkpoint_restore.SourceReadResult {
        const self: *MemorySource = @ptrCast(@alignCast(context.?));
        if (self.offset < self.bytes.len) {
            const count = @min(buffer.len, self.bytes.len - self.offset);
            @memcpy(buffer[0..count], self.bytes[self.offset..][0..count]);
            self.offset += count;
            return .{ .bytes = count };
        }
        return self.end;
    }
};

// ---------------------------------------------------------------------------
// Calling back
// ---------------------------------------------------------------------------

/// Never waits: a control frame that does not fit now is one the UI half
/// asks for again.
fn sendControl(self: *Server, value: rpc.Control) void {
    var bytes: [32]u8 = undefined;
    const written = payload.encode(rpc.Control, value, &bytes);
    _ = self.outbound.trySubmit(.control, 0, bytes[0..written]) catch {};
}

fn CallbackReply(comptime callback: rpc.Callback) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        bytes: []u8,
        value: rpc.Response(callback),
        allocator: std.mem.Allocator,

        fn deinit(self: *@This()) void {
            self.arena.deinit();
            std.crypto.secureZero(u8, self.bytes);
            self.allocator.free(self.bytes);
        }
    };
}

/// Tells the UI half once that the callback it is serving is no longer
/// wanted, when the thread waiting for it is told so by its own caller.
const Withdrawal = struct {
    server: *Server,
    correlation: u64,
    signal: Withdrawn,

    fn poll(context: ?*anyopaque) bool {
        const self: *Withdrawal = @ptrCast(@alignCast(context.?));
        if (!self.signal.poll_fn(self.signal.context)) return false;
        sendControl(self.server, .{ .cancel = self.correlation });
        return true;
    }
};

/// What says the caller of a callback no longer wants it: an MCP
/// cancellation, an HTTP one, or a delivery's flag, each read as it is.
const Withdrawn = struct {
    context: ?*const anyopaque,
    poll_fn: *const fn (?*const anyopaque) bool,

    fn mcp(cancellation: mcp_connector.Cancellation) Withdrawn {
        return .{ .context = cancellation.context, .poll_fn = cancellation.is_cancelled_fn };
    }

    fn http(cancellation: *const contract.http_transport.Cancellation) Withdrawn {
        return .{ .context = cancellation, .poll_fn = struct {
            fn poll(context: ?*const anyopaque) bool {
                const value: *const contract.http_transport.Cancellation = @ptrCast(@alignCast(context.?));
                return value.isRequested();
            }
        }.poll };
    }

    fn flag(value: *const std.atomic.Value(bool)) Withdrawn {
        return .{ .context = value, .poll_fn = struct {
            fn poll(context: ?*const anyopaque) bool {
                const set: *const std.atomic.Value(bool) = @ptrCast(@alignCast(context.?));
                return set.load(.acquire);
            }
        }.poll };
    }
};

/// One callback, answered, or `null` when the link is gone.
fn callBack(
    self: *Server,
    comptime callback: rpc.Callback,
    handle: u64,
    request: rpc.Request(callback),
    withdrawn: ?Withdrawn,
) ?CallbackReply(callback) {
    const bytes = rpc.encodeRequest(callback, self.allocator, handle, request) catch self.fail(.resource_unavailable);
    defer {
        std.crypto.secureZero(u8, bytes);
        self.allocator.free(bytes);
    }
    const correlation = self.callbacks.openWaiting() catch return null;
    const submitted = self.outbound.submitWaiting(.request, correlation, bytes) catch self.fail(.resource_unavailable);
    if (submitted != .queued) {
        self.callbacks.discardUnsent(correlation);
        return null;
    }
    var withdrawal: Withdrawal = undefined;
    const claimed = if (withdrawn) |value| watched: {
        withdrawal = .{ .server = self, .correlation = correlation, .signal = value };
        break :watched self.callbacks.claimWatching(correlation, .fromMilliseconds(cancellation_poll_ms), .{
            .context = &withdrawal,
            .poll_fn = Withdrawal.poll,
        });
    } else self.callbacks.claim(correlation);
    const response = switch (claimed) {
        .link_closed => return null,
        .response => |value| value,
    };
    var result: CallbackReply(callback) = .{
        .arena = .init(self.allocator),
        .bytes = response,
        .value = undefined,
        .allocator = self.allocator,
    };
    const answer = rpc.decodeResponse(callback, result.arena.allocator(), response) catch self.fail(.protocol_violation);
    result.value = switch (answer) {
        .ok => |value| value,
        // The UI half answers callbacks with data, never with an error.
        .err => self.fail(.protocol_violation),
    };
    return result;
}

/// An MCP transport whose exchanges the UI half performs, on the transport it
/// kept. AgentCore's connector drives this exactly as it drives the concrete
/// one; the UI half applies the secret scan, because that is where the
/// secrets are.
const RemoteTransport = struct {
    server: *Server,
    id: u64,

    const Connection = struct {
        transport: *RemoteTransport,
        id: u64,
    };

    fn create(half: *Server, id: u64) std.mem.Allocator.Error!mcp_connector.TransportOwner {
        const self = try half.allocator.create(RemoteTransport);
        self.* = .{ .server = half, .id = id };
        return .init(.{
            .context = self,
            .open_fn = open,
            .request_fn = request,
            .tool_request_fn = toolRequest,
            .notify_fn = notify,
            .close_fn = close,
        }, deinit);
    }

    fn open(context: *anyopaque, purpose: mcp_connector.Purpose, era: mcp_connector.Era, timeout_ms: u32) mcp_connector.OpenOutcome {
        const self: *RemoteTransport = @ptrCast(@alignCast(context));
        var answer = callBack(self.server, .mcp_open, self.id, .{
            .purpose = purpose,
            .era = era,
            .timeout_ms = timeout_ms,
        }, null) orelse return .{ .failure = .child_exit };
        defer answer.deinit();
        return switch (answer.value) {
            .failure => |failure| .{ .failure = failure },
            .connection => |id| connection: {
                const connection = self.server.allocator.create(Connection) catch {
                    closeRemote(self.server, id);
                    break :connection .{ .failure = .fatal };
                };
                connection.* = .{ .transport = self, .id = id };
                break :connection .{ .connection = connection };
            },
        };
    }

    fn exchange(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        bytes: []const u8,
        timeout_ms: u32,
        cancellation: mcp_connector.Cancellation,
        tool: bool,
    ) mcp_connector.ExchangeOutcome {
        const connection: *Connection = @ptrCast(@alignCast(context));
        var answer = callBack(connection.transport.server, .mcp_request, connection.id, .{
            .bytes = bytes,
            .timeout_ms = timeout_ms,
            .tool = tool,
        }, .mcp(cancellation)) orelse return .{ .failure = .child_exit };
        defer answer.deinit();
        return switch (answer.value) {
            .failure => |failure| .{ .failure = failure },
            .response => |response| .{ .response = .{
                .http_status = response.http_status,
                .body = if (response.body.len == 0)
                    &.{}
                else
                    allocator.dupe(u8, response.body) catch return .{ .failure = .fatal },
            } },
        };
    }

    fn request(context: *anyopaque, allocator: std.mem.Allocator, bytes: []const u8, timeout_ms: u32, cancellation: mcp_connector.Cancellation) mcp_connector.ExchangeOutcome {
        return exchange(context, allocator, bytes, timeout_ms, cancellation, false);
    }

    fn toolRequest(context: *anyopaque, allocator: std.mem.Allocator, bytes: []const u8, timeout_ms: u32, cancellation: mcp_connector.Cancellation) mcp_connector.ExchangeOutcome {
        return exchange(context, allocator, bytes, timeout_ms, cancellation, true);
    }

    fn notify(context: *anyopaque, bytes: []const u8, timeout_ms: u32, cancellation: mcp_connector.Cancellation) ?mcp_connector.Failure {
        const connection: *Connection = @ptrCast(@alignCast(context));
        var answer = callBack(connection.transport.server, .mcp_notify, connection.id, .{
            .bytes = bytes,
            .timeout_ms = timeout_ms,
        }, .mcp(cancellation)) orelse return .child_exit;
        defer answer.deinit();
        return answer.value;
    }

    fn close(context: *anyopaque) void {
        const connection: *Connection = @ptrCast(@alignCast(context));
        const half = connection.transport.server;
        closeRemote(half, connection.id);
        half.allocator.destroy(connection);
    }

    fn closeRemote(half: *Server, id: u64) void {
        if (callBack(half, .mcp_close, id, .{}, null)) |answer| {
            var value = answer;
            value.deinit();
        }
    }

    fn deinit(context: *anyopaque) void {
        const self: *RemoteTransport = @ptrCast(@alignCast(context));
        const half = self.server;
        if (callBack(half, .mcp_release, self.id, .{}, null)) |answer| {
            var value = answer;
            value.deinit();
        }
        half.allocator.destroy(self);
    }
};

/// A prepared Run's file delivery and media effects, standing in for the
/// Host's: each call goes to the UI half, which holds the real ones for the
/// Run. The strings the Run borrows live here until it is over.
const RunEffects = struct {
    server: *Server,
    handle: u64,
    run_id: u64 = 0,
    arena: std.heap.ArenaAllocator,
    image: ?rpc.ImageRun = null,
    video: ?rpc.VideoRun = null,
    image_side: Side = .{ .tool = .image },
    video_side: Side = .{ .tool = .video },

    /// One tool's view, so a callback knows which tool's effect it is.
    const Side = struct {
        tool: rpc.MediaTool,
        effects: *RunEffects = undefined,
    };

    fn create(half: *Server, entry: *Entry, image: ?rpc.ImageRun, video: ?rpc.VideoRun) std.mem.Allocator.Error!*RunEffects {
        const self = try half.allocator.create(RunEffects);
        errdefer half.allocator.destroy(self);
        self.* = .{ .server = half, .handle = entry.installation.handle, .arena = .init(half.allocator) };
        errdefer self.arena.deinit();
        self.image_side.effects = self;
        self.video_side.effects = self;
        const arena = self.arena.allocator();
        if (image) |value| self.image = .{
            .endpoint = try arena.dupe(u8, value.endpoint),
            .source = try arena.dupe(u8, value.source),
            .model = try arena.dupe(u8, value.model),
            .credential = try arena.dupe(u8, value.credential),
            .renews_credential = value.renews_credential,
        };
        if (video) |value| self.video = .{
            .endpoint = try arena.dupe(u8, value.endpoint),
            .source = try arena.dupe(u8, value.source),
            .model = try arena.dupe(u8, value.model),
        };
        return self;
    }

    fn destroy(self: *RunEffects) void {
        if (self.image) |value| std.crypto.secureZero(u8, @constCast(value.credential));
        const allocator = self.server.allocator;
        self.arena.deinit();
        allocator.destroy(self);
    }

    fn imageInput(self: *RunEffects) contract.surface.ImageGenerationRunInput {
        const value = self.image.?;
        return .{
            .binding = .{
                .endpoint = value.endpoint,
                .source = value.source,
                .model = value.model,
                .credential = value.credential,
                .credential_reader = if (value.renews_credential)
                    .{ .context = &self.image_side, .read_fn = readCredential }
                else
                    null,
                .output = .{ .context = self, .commit_fn = commitImage },
            },
            .transport = .{ .context = &self.image_side, .perform_fn = perform },
        };
    }

    fn videoInput(self: *RunEffects) contract.generate_video.Input {
        const value = self.video.?;
        return .{
            .endpoint = value.endpoint,
            .source = value.source,
            .model = value.model,
            .credential = .{ .context = &self.video_side, .read_fn = readCredential },
            .transport = .{ .context = &self.video_side, .perform_fn = perform },
            .output = .{ .context = self, .commit_fn = commitVideo },
        };
    }

    fn deliveryInput(self: *RunEffects) contract.FileDeliveryInput {
        return .{ .context = self, .inspect_fn = inspect };
    }

    fn sideOf(context: ?*anyopaque) *Side {
        return @ptrCast(@alignCast(context.?));
    }

    fn readCredential(context: *anyopaque, buffer: []u8) ?usize {
        const side = sideOf(context);
        const self = side.effects;
        var answer = callBack(self.server, .media_credential_read, self.handle, .{
            .run_id = self.run_id,
            .tool = side.tool,
            .capacity = std.math.cast(u32, buffer.len) orelse std.math.maxInt(u32),
        }, null) orelse return null;
        defer answer.deinit();
        const bytes = answer.value orelse return null;
        if (bytes.len > buffer.len) return null;
        @memcpy(buffer[0..bytes.len], bytes);
        return bytes.len;
    }

    fn perform(
        context: ?*anyopaque,
        request: contract.http_transport.HttpRequest,
        cancellation: *const contract.http_transport.Cancellation,
        response_buffer: []u8,
    ) contract.http_transport.Error!contract.http_transport.Response {
        const side = sideOf(context);
        const self = side.effects;
        var answer = callBack(self.server, .media_perform, self.handle, .{
            .run_id = self.run_id,
            .tool = side.tool,
            .request = .{
                .url = request.url,
                .headers = request.headers,
                .body = request.body,
                .method = request.method,
                .streams = request.stream != null,
                .connect_timeout_ms = request.connect_timeout_ms,
                .source = request.source,
            },
            .response_capacity = response_buffer.len,
        }, .http(cancellation)) orelse return error.Unexpected;
        defer answer.deinit();
        const response = switch (answer.value) {
            .failure => |failure| return httpError(failure),
            .response => |value| value,
        };
        if (response.body.len > response_buffer.len) return error.ResponseTooLarge;
        @memcpy(response_buffer[0..response.body.len], response.body);
        // The Host read the stream whole; the Run's receiver reads it now,
        // as it would have while the request was in flight.
        if (response.stream) |stream| if (request.stream) |receiver| {
            var reader = std.Io.Reader.fixed(stream.bytes);
            receiver.receive_fn(receiver.context, stream.content_type, stream.content_length, &reader);
        };
        return .{ .status = response.status, .body = response_buffer[0..response.body.len] };
    }

    fn httpError(failure: rpc.HttpFailure) contract.http_transport.Error {
        return switch (failure) {
            inline else => |tag| @field(contract.http_transport.Error, @tagName(tag)),
        };
    }

    fn commitImage(
        context: *anyopaque,
        bytes: []const u8,
        format: contract.image_generation.Format,
        cancellation: *const contract.http_transport.Cancellation,
    ) contract.image_generation.OutputResult {
        const self: *RunEffects = @ptrCast(@alignCast(context));
        var answer = callBack(self.server, .image_commit, self.handle, .{
            .run_id = self.run_id,
            .bytes = bytes,
            .format = format,
        }, .http(cancellation)) orelse return .{ .failed = .{ .code = .unavailable } };
        defer answer.deinit();
        return answer.value;
    }

    fn commitVideo(
        context: *anyopaque,
        reader: *std.Io.Reader,
        length: ?u64,
        cancellation: *const contract.http_transport.Cancellation,
    ) contract.generate_video.Outcome {
        const self: *RunEffects = @ptrCast(@alignCast(context));
        // Read whole, within the tool's own bound, and committed by the Host.
        const bytes = reader.allocRemaining(self.server.allocator, .limited(contract.generate_video.max_file_bytes + 1)) catch
            return .{ .failed = .download_failed };
        defer self.server.allocator.free(bytes);
        if (bytes.len > contract.generate_video.max_file_bytes) return .{ .failed = .download_failed };
        var answer = callBack(self.server, .video_commit, self.handle, .{
            .run_id = self.run_id,
            .bytes = bytes,
            .length = length,
        }, .http(cancellation)) orelse return .{ .failed = .output_failed };
        defer answer.deinit();
        return answer.value;
    }

    fn inspect(context: *anyopaque, path: []const u8, cancelled: *const std.atomic.Value(bool)) contract.FileDeliveryInspection {
        const self: *RunEffects = @ptrCast(@alignCast(context));
        var answer = callBack(self.server, .delivery_inspect, self.handle, .{
            .run_id = self.run_id,
            .path = path,
        }, .flag(cancelled)) orelse return .{ .failed = .unavailable };
        defer answer.deinit();
        return answer.value;
    }
};

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

fn notifyEvents(context: ?*anyopaque) contract.control.EventReadyNotification {
    const self: *Server = @ptrCast(@alignCast(context.?));
    self.signalForwarder();
    return .scheduled;
}

/// What only the forwarder thread touches.
const Forwarding = struct {
    sent: rpc.Credit = .{ .count = 0, .bytes = 0 },
    held: ?contract.OwnedCoreEvent = null,
};

fn forwarderMain(self: *Server) void {
    var forwarding: Forwarding = .{};
    while (true) {
        self.forward_mutex.lockUncancelable(self.io);
        while (!self.forward_signal)
            self.forward_condition.waitUncancelable(self.io, &self.forward_mutex);
        self.forward_signal = false;
        self.forward_mutex.unlock(self.io);
        forward(self, &forwarding);
    }
}

/// Sends as far as the credit and the Runtime allow. Nothing here holds the
/// forwarder's lock while it calls the Runtime or sends, so a Core callback
/// raising the notifier never waits on this thread.
fn forward(self: *Server, forwarding: *Forwarding) void {
    while (true) {
        self.forward_mutex.lockUncancelable(self.io);
        const granted = self.granted;
        self.forward_mutex.unlock(self.io);

        var progressed = false;
        if (forwarding.held == null and forwarding.sent.count < granted.count) {
            forwarding.held = self.runtime.port.takeEvent();
            if (forwarding.held != null) progressed = true;
        }
        if (forwarding.held) |*event| {
            const size: u64 = event.encoded_bytes;
            if (forwarding.sent.count < granted.count and forwarding.sent.bytes + size <= granted.bytes) {
                sendEvent(self, event);
                forwarding.held = null;
                forwarding.sent.count += 1;
                forwarding.sent.bytes += size;
                progressed = true;
            }
        }
        if (flushTerminals(self, forwarding.held)) progressed = true;
        if (!progressed) return;
    }
}

fn sendEvent(self: *Server, event: *contract.OwnedCoreEvent) void {
    if (self.event_delay_ms != 0)
        std.Io.sleep(self.io, .fromMilliseconds(@intCast(self.event_delay_ms)), .awake) catch {};
    const bytes = payload.encodeAlloc(rpc.Event, self.allocator, .{
        .session_id = event.session_id,
        .run_id = event.run_id,
        .encoded_bytes = event.encoded_bytes,
        .json = event.json,
        .generated_image_path = event.generated_image_path,
        .generated_video_path = event.generated_video_path,
        .delivered_file = event.delivered_file,
    }) catch self.fail(.resource_unavailable);
    event.deinit();
    defer self.allocator.free(bytes);
    _ = self.outbound.submitWaiting(.event, 0, bytes) catch self.fail(.resource_unavailable);
}

/// Sends every waiting terminal whose Session has no event left to send.
/// The forwarder is the only thread that takes events, so "none in the
/// Runtime and none held here" is "all of them are out".
fn flushTerminals(self: *Server, held: ?contract.OwnedCoreEvent) bool {
    self.forward_mutex.lockUncancelable(self.io);
    var waiting = self.deferred;
    self.deferred = .empty;
    self.forward_mutex.unlock(self.io);
    if (waiting.items.len == 0) {
        waiting.deinit(self.allocator);
        return false;
    }
    var sent_any = false;
    var index: usize = 0;
    while (index < waiting.items.len) {
        const item = waiting.items[index];
        const held_for_it = if (held) |event| event.session_id == item.route_id else false;
        if (!held_for_it and self.runtime.port.pendingEventCount(item.route_id) == 0) {
            send(self, item.correlation, item.bytes);
            _ = waiting.orderedRemove(index);
            sent_any = true;
            continue;
        }
        index += 1;
    }
    self.forward_mutex.lockUncancelable(self.io);
    defer self.forward_mutex.unlock(self.io);
    // Anything deferred meanwhile goes after what was already waiting.
    waiting.appendSlice(self.allocator, self.deferred.items) catch self.fail(.resource_unavailable);
    self.deferred.deinit(self.allocator);
    self.deferred = waiting;
    return sent_any;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "an entry removed while a call is inside it lives until that call is done" {
    const allocator = std.testing.allocator;
    var registry: Registry = .{ .allocator = allocator, .io = std.testing.io };
    defer {
        var iterator = registry.entries.valueIterator();
        while (iterator.next()) |entry| registry.destroy(entry.*);
        registry.entries.deinit(allocator);
    }
    const session: contract.port.SessionPort = .{ .context = null, .vtable = undefined };
    const handle = try registry.add(undefined, 7, 1, session);
    const entry = registry.acquire(handle).?;
    registry.remove(handle);
    // Gone from the map, so no new call can reach it ...
    try std.testing.expectEqual(@as(?*Entry, null), registry.acquire(handle));
    // ... and still readable by the call already inside it. Freed memory in
    // a Debug build reads as 0xaa, so this would not see the route id.
    try std.testing.expectEqual(@as(u64, 7), entry.route_id);
    registry.release(entry);
}

test "handles are issued once and never reused" {
    const allocator = std.testing.allocator;
    var registry: Registry = .{ .allocator = allocator, .io = std.testing.io };
    defer registry.entries.deinit(allocator);
    const session: contract.port.SessionPort = .{ .context = null, .vtable = undefined };
    const first = try registry.add(undefined, 1, 1, session);
    registry.remove(first);
    const second = try registry.add(undefined, 2, 1, session);
    try std.testing.expect(second != first);
    registry.remove(second);
}

/// A Runtime whose only content is a queue of ready events, for the
/// forwarder's tests.
const FakeEvents = struct {
    events: std.ArrayList(contract.OwnedCoreEvent) = .empty,

    const vtable: contract.port.RuntimePort.VTable = vtable: {
        var copy = contract.port.RuntimePort.quiet.vtable.*;
        copy.take_event = take;
        copy.pending_event_count = pending;
        break :vtable copy;
    };

    fn take(context: ?*anyopaque) ?contract.OwnedCoreEvent {
        const self: *FakeEvents = @ptrCast(@alignCast(context.?));
        if (self.events.items.len == 0) return null;
        return self.events.orderedRemove(0);
    }

    fn pending(context: ?*anyopaque, session_id: u64) usize {
        const self: *FakeEvents = @ptrCast(@alignCast(context.?));
        var count: usize = 0;
        for (self.events.items) |event| {
            if (event.session_id == session_id) count += 1;
        }
        return count;
    }

    fn add(self: *FakeEvents, session_id: u64) !void {
        const allocator = std.testing.allocator;
        const json = try allocator.dupe(u8, "{\"text_chunk\":\"x\"}");
        errdefer allocator.free(json);
        try self.events.append(allocator, .{
            .session_id = session_id,
            .run_id = 1,
            .encoded_bytes = json.len,
            .json = json,
            .event = try contract.wire.decodeCoreEvent(allocator, json),
            .allocator = allocator,
        });
    }

    fn deinit(self: *FakeEvents) void {
        for (self.events.items) |*event| event.deinit();
        self.events.deinit(std.testing.allocator);
    }
};

fn noShutdown(_: ?*anyopaque) void {}

fn testServer(self: *Server, fake: *FakeEvents, file: std.Io.File) !void {
    self.* = .{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .outbound = undefined,
        .callbacks = undefined,
        .registry = .{ .allocator = std.testing.allocator, .io = std.testing.io },
        .runtime = .{
            .port = .{ .context = fake, .vtable = &FakeEvents.vtable },
            .context = null,
            .shutdown_fn = noShutdown,
        },
    };
    try self.outbound.start(std.testing.io, std.testing.allocator, file, .{});
}

/// The kinds of the frames written to `file`, in order.
fn writtenKinds(file: std.Io.File, out: []agent_link.Kind) ![]agent_link.Kind {
    const io = std.testing.io;
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    var count: usize = 0;
    while (true) {
        var header_bytes: [agent_link.frame.header_bytes]u8 = undefined;
        reader.interface.readSliceAll(&header_bytes) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        const header = try agent_link.frame.decode(&header_bytes);
        try reader.interface.discardAll(header.payload_len);
        out[count] = header.kind;
        count += 1;
    }
    return out[0..count];
}

test "an event goes out only into room the caller has granted" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "link", .{ .read = true, .truncate = true });
    defer file.close(std.testing.io);
    var fake: FakeEvents = .{};
    defer fake.deinit();
    for (0..3) |_| try fake.add(5);

    var under_test: Server = undefined;
    try testServer(&under_test, &fake, file);
    defer under_test.deferred.deinit(std.testing.allocator);
    var forwarding: Forwarding = .{};

    under_test.granted = .{ .count = 1, .bytes = 1 << 20 };
    forward(&under_test, &forwarding);
    // One out; the other two still in the Runtime, which is where the
    // backpressure belongs.
    try std.testing.expectEqual(@as(usize, 2), fake.events.items.len);

    under_test.granted = .{ .count = 3, .bytes = 1 << 20 };
    forward(&under_test, &forwarding);
    try std.testing.expectEqual(@as(usize, 0), fake.events.items.len);
    under_test.outbound.stop();
    try std.testing.expectEqual(@as(?contract.OwnedCoreEvent, null), forwarding.held);
}

test "a terminal goes out only after every event of its Session" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "link", .{ .read = true, .truncate = true });
    defer file.close(std.testing.io);
    var fake: FakeEvents = .{};
    defer fake.deinit();
    try fake.add(5);
    try fake.add(5);

    var under_test: Server = undefined;
    try testServer(&under_test, &fake, file);
    defer under_test.deferred.deinit(std.testing.allocator);
    var forwarding: Forwarding = .{};

    // No room yet, so the events stay put -- and so must the terminal.
    deferTerminal(&under_test, 5, 9, try std.testing.allocator.dupe(u8, "terminal"));
    forward(&under_test, &forwarding);
    try std.testing.expectEqual(@as(usize, 1), under_test.deferred.items.len);

    under_test.granted = .{ .count = 2, .bytes = 1 << 20 };
    forward(&under_test, &forwarding);
    try std.testing.expectEqual(@as(usize, 0), under_test.deferred.items.len);
    under_test.outbound.stop();

    var kinds: [8]agent_link.Kind = undefined;
    const written = try writtenKinds(file, &kinds);
    try std.testing.expectEqualSlices(agent_link.Kind, &.{ .event, .event, .response }, written);
}

test "a restore source replays its bytes and then its last result" {
    var source: MemorySource = .{ .bytes = "abcdef", .end = .io_failed };
    var buffer: [4]u8 = undefined;
    const reader = source.source();
    try std.testing.expectEqual(checkpoint_restore.SourceReadResult{ .bytes = 4 }, reader.read_fn(reader.context, &buffer));
    try std.testing.expectEqualStrings("abcd", &buffer);
    try std.testing.expectEqual(checkpoint_restore.SourceReadResult{ .bytes = 2 }, reader.read_fn(reader.context, &buffer));
    try std.testing.expectEqual(checkpoint_restore.SourceReadResult.io_failed, reader.read_fn(reader.context, &buffer));
}
