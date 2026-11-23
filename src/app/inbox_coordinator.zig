//! MetaTeam inbox lifecycle coordinator. Finds the installed MetaTeam
//! connection, keeps its device key in Application memory only, runs the
//! timer and the request workers, and hands typed results to Product on the
//! main thread. Jobs hold owned requests and a narrow transport, never
//! Product state, the credential store or a Native Runtime.
const std = @import("std");
const native_sdk = @import("native_sdk");
const inbox = @import("metawork_product_inbox");
const control_ports = @import("metawork_product_control_ports");
const mcp_configuration = @import("metawork_product_mcp").contract;
const mcp_platform = @import("metawork_mcp_platform");
const mcp_startup = @import("mcp_startup.zig");
const http = @import("inbox_http_transport.zig");

pub const timer_id: u64 = 0x4d57494e;
/// Wake-loss recovery while a request runs; no Renderer polling is needed
/// to finish one.
const busy_timer_ms = 100;
/// A connection whose credential could not be read is looked for again.
const find_retry_ms: u64 = 60_000;

pub const Host = struct {
    context: ?*anyopaque,
    now_ns_fn: *const fn (?*anyopaque) u64,
    wake_fn: *const fn (?*anyopaque) anyerror!void,
    start_timer_fn: *const fn (?*anyopaque, u64, u64, bool) anyerror!void,
    cancel_timer_fn: *const fn (?*anyopaque, u64) anyerror!void,
    /// Opens a web address in the system browser.
    open_fn: *const fn (?*anyopaque, []const u8) anyerror!void,
    on_main_thread_fn: *const fn (?*anyopaque) bool,
};

/// What looking for MetaTeam among the installed connections found. A found
/// connection owns its copies; the key is cleared when released.
pub const Found = struct {
    server_id: []u8,
    fingerprint: [64]u8,
    base: []u8,
    key: []u8,

    fn release(self: *Found, allocator: std.mem.Allocator) void {
        allocator.free(self.server_id);
        allocator.free(self.base);
        std.crypto.secureZero(u8, self.key);
        allocator.free(self.key);
        self.* = undefined;
    }
};

pub const FindResult = union(enum) {
    none,
    /// A credential could not be read; nothing can be said about MetaTeam.
    unavailable,
    found: Found,
};

/// Where installed connections come from. Main thread only: the credential
/// store answers nowhere else.
pub const Source = struct {
    context: *anyopaque,
    generation_fn: *const fn (*anyopaque) ?u64,
    find_fn: *const fn (*anyopaque, std.mem.Allocator, u64) FindResult,
};

/// The installed MCP connections, judged by the MCP runtime's own rule for
/// what it would connect, and the endpoint each resolves to.
pub const McpSource = struct {
    port: control_ports.McpManagementPort,
    credential_store: *mcp_platform.CredentialStore,

    pub fn source(self: *McpSource) Source {
        return .{ .context = self, .generation_fn = generation, .find_fn = find };
    }

    fn generation(context: *anyopaque) ?u64 {
        const self: *McpSource = @ptrCast(@alignCast(context));
        const inspection = self.port.inspectMcpDesiredConfiguration() orelse return null;
        if (inspection.health != .ready) return null;
        return inspection.desired_generation;
    }

    fn find(context: *anyopaque, allocator: std.mem.Allocator, expected: u64) FindResult {
        const self: *McpSource = @ptrCast(@alignCast(context));
        const storage = allocator.alloc(u8, mcp_configuration.max_store_bytes) catch return .unavailable;
        defer allocator.free(storage);
        const bytes = self.port.writeMcpDesiredConfiguration(expected, storage) catch return .none;
        var preparation = mcp_configuration.prepare(allocator, bytes, true, false, self.credential_store.resolver(), mcp_startup.configuration_limits) catch return .unavailable;
        defer preparation.deinit();
        switch (preparation.state) {
            .unavailable => |reason| return if (reason == .credential_store_unavailable) .unavailable else .none,
            else => {},
        }
        const registry = preparation.registry orelse return .none;
        return selectDeviceEndpoint(allocator, registry.value.servers, preparation.server_states, preparation.credentials);
    }
};

/// The newest eligible plain HTTP connection whose endpoint has MetaTeam's
/// published shape. Servers are appended on creation, so the last match is
/// the most recently created.
pub fn selectDeviceEndpoint(
    allocator: std.mem.Allocator,
    servers: []const mcp_configuration.ServerWire,
    states: []const mcp_configuration.ServerPreparationState,
    credentials: []const mcp_configuration.ResolvedCredential,
) FindResult {
    var index = servers.len;
    while (index > 0) {
        index -= 1;
        const server = servers[index];
        if (states[index] != .eligible) continue;
        if (!std.mem.eql(u8, server.transport.kind, "streamable_http") or
            server.auth.oauth != null or server.transport.headers.len != 0) continue;
        const url = mcp_configuration.resolveEndpoint(allocator, server.transport, credentials, mcp_startup.configuration_limits.max_url_bytes) catch continue;
        defer {
            std.crypto.secureZero(u8, url);
            allocator.free(url);
        }
        var key_buffer: [4096]u8 = undefined;
        defer std.crypto.secureZero(u8, &key_buffer);
        const match = inbox.matchDeviceEndpoint(url, &key_buffer) orelse continue;
        return foundCopy(allocator, server.id, mcp_configuration.connectionFingerprint(server), match.base, match.key) catch .unavailable;
    }
    return .none;
}

fn foundCopy(allocator: std.mem.Allocator, server_id: []const u8, fingerprint: [64]u8, base: []const u8, key: []const u8) !FindResult {
    const id = try allocator.dupe(u8, server_id);
    errdefer allocator.free(id);
    const owned_base = try allocator.dupe(u8, base);
    errdefer allocator.free(owned_base);
    const owned_key = try allocator.dupe(u8, key);
    return .{ .found = .{ .server_id = id, .fingerprint = fingerprint, .base = owned_base, .key = owned_key } };
}

/// The live binding: its Product revision and the only copy of the key that
/// outlives a request.
const Bound = struct {
    revision: u64,
    server_id: []u8,
    fingerprint: [64]u8,
    base: []u8,
    key: []u8,
    isolation: @import("metawork_http_transport").Isolation,

    fn release(self: *Bound, allocator: std.mem.Allocator) void {
        allocator.free(self.server_id);
        allocator.free(self.base);
        std.crypto.secureZero(u8, self.key);
        allocator.free(self.key);
        self.* = undefined;
    }
};

const BridgeId = struct {
    bytes: [max_bridge_id_bytes]u8 = undefined,
    len: usize = 0,

    fn slice(self: *const BridgeId) []const u8 {
        return self.bytes[0..self.len];
    }
};
pub const max_bridge_id_bytes = 128;

pub const ConversationRequest = inbox.ConversationRequest;
pub const TaskRequest = inbox.TaskRequest;
pub const FileOpenRequest = inbox.FileOpenRequest;

const Reply = struct {
    responder: native_sdk.bridge.AsyncResponder,
    bridge_id: BridgeId,
    binding: u64,
    request_id: u64,
};

const ConversationWork = struct {
    reply: Reply,
    peer: inbox.Id,
    kind: inbox.ConversationPageKind,
    anchor: ?inbox.Id,
};

const TaskWork = struct {
    reply: Reply,
    task: inbox.Id,
};

const Work = union(enum) {
    poll: u64,
    list: inbox.ListPreparation,
    conversation: ConversationWork,
    task: TaskWork,
    /// Reads the file's detail for a fresh download address to open.
    file: TaskWork,
};

const Job = struct {
    allocator: std.mem.Allocator,
    transport: http.Transport,
    base: []u8,
    key: []u8,
    isolation: @import("metawork_http_transport").Isolation,
    work: Work,
    cancellation: http.Cancellation,
    wake_context: ?*anyopaque,
    wake_fn: *const fn (?*anyopaque) anyerror!void,
    finished: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    /// Main thread only: a newer Renderer request replaced this one.
    superseded: bool = false,
    /// Main thread only: its Renderer request was already answered, when the
    /// Bridge connection ended; the result is then dropped unsent.
    replied: bool = false,
    failure: ?inbox.Failure = null,
    /// The status of an answered request that was not a success.
    status: ?u16 = null,
    unread: ?inbox.Unread = null,
    page: ?inbox.Messages = null,
    page_limit: u32 = 0,
    detail: ?inbox.Detail = null,

    fn run(self: *Job) void {
        defer {
            self.finished.store(true, .release);
            self.wake_fn(self.wake_context) catch {};
        }
        self.execute() catch {
            // Only memory can fail here; the request outcome is recorded.
            self.failure = .{ .@"unreachable" = null };
        };
    }

    fn execute(self: *Job) !void {
        switch (self.work) {
            .poll => {
                const buffer = try self.allocator.alloc(u8, inbox.Limits.unread_bytes);
                defer self.allocator.free(buffer);
                const body = (self.fetch(.unread, buffer) catch return self.unusable(.unread, 0)) orelse return;
                self.unread = inbox.parseUnread(self.allocator, body) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.InvalidResponse => return self.unusable(.unread, body.len),
                };
            },
            .list => |preparation| {
                // Product never prepares a continuation without its anchor;
                // without one this is a first page, never a crash.
                const query: inbox.MessagesQuery = if (preparation.anchor) |*anchor| switch (preparation.kind) {
                    .initial => .{},
                    .newer => .{ .after = anchor.slice() },
                    .earlier => .{ .before = anchor.slice() },
                } else .{};
                _ = try self.pageOf(query, inbox.Limits.list_page);
            },
            .conversation => |work| {
                const query: inbox.MessagesQuery = switch (work.kind) {
                    .latest => .{ .peer = work.peer.slice() },
                    .before => .{ .peer = work.peer.slice(), .before = work.anchor.?.slice() },
                    .after => .{ .peer = work.peer.slice(), .after = work.anchor.?.slice() },
                };
                _ = try self.pageOf(query, inbox.Limits.conversation_page);
            },
            .task, .file => |work| {
                const buffer = try self.allocator.alloc(u8, inbox.Limits.detail_bytes);
                defer self.allocator.free(buffer);
                const body = (self.fetch(.{ .task = work.task.slice() }, buffer) catch return self.unusable(.task, 0)) orelse return;
                self.detail = inbox.parseDetail(self.allocator, body) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.InvalidResponse => return self.unusable(.task, body.len),
                };
            },
        }
    }

    /// One page with `limit`, asked again with half the limit while the
    /// answer does not fit the response bound; only a single message larger
    /// than the bound is unusable.
    fn pageOf(self: *Job, base_query: inbox.MessagesQuery, initial_limit: u32) !bool {
        const buffer = try self.allocator.alloc(u8, inbox.Limits.messages_bytes);
        defer self.allocator.free(buffer);
        var limit = initial_limit;
        while (true) {
            var query = base_query;
            query.limit = limit;
            const body = (self.fetch(.{ .messages = query }, buffer) catch {
                if (limit == 1) {
                    self.unusable(.messages, buffer.len);
                    return false;
                }
                limit /= 2;
                continue;
            }) orelse return false;
            self.page = inbox.parseMessages(self.allocator, body) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidResponse => {
                    self.unusable(.messages, body.len);
                    return false;
                },
            };
            self.page_limit = limit;
            return true;
        }
    }

    /// The body when the request was answered with success; null when it
    /// failed or was refused, with the failure recorded. `TooLarge` when the
    /// body did not fit.
    fn fetch(self: *Job, request: inbox.Request, buffer: []u8) error{TooLarge}!?[]const u8 {
        var diagnostic: ?inbox.Diagnostic = null;
        const response = self.transport.perform_fn(self.transport.context, .{ .base = self.base, .key = self.key, .isolation = self.isolation }, request, buffer, &self.cancellation, &diagnostic) catch |err| switch (err) {
            error.ResponseTooLarge => return error.TooLarge,
            else => {
                self.failure = .{ .@"unreachable" = diagnostic };
                return null;
            },
        };
        if (inbox.statusFailure(response.status)) |failure| {
            self.failure = failure;
            self.status = response.status;
            // The execution layer logs requests that failed on their way out;
            // an answered refusal is the one it cannot see. Typed facts only.
            std.log.warn("inbox request consumer=inbox request={s} status={d}", .{ @tagName(request), response.status });
            return null;
        }
        return buffer[0..response.body_len];
    }

    /// An answered request whose body this client cannot use.
    fn unusable(self: *Job, kind: std.meta.Tag(inbox.Request), body_len: usize) void {
        self.failure = .{ .@"unreachable" = null };
        std.log.warn("inbox response consumer=inbox request={s} body_bytes={d} result=invalid_response", .{ @tagName(kind), body_len });
    }

    fn join(self: *Job) void {
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }

    fn destroy(self: *Job) void {
        std.debug.assert(self.thread == null);
        if (self.unread) |*value| value.deinit(self.allocator);
        if (self.page) |*value| value.deinit();
        if (self.detail) |*value| value.deinit();
        std.crypto.secureZero(u8, self.key);
        self.allocator.free(self.key);
        self.allocator.free(self.base);
        self.allocator.destroy(self);
    }
};

pub const Coordinator = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    management: inbox.Management,
    transport: http.Transport,
    retire_fn: *const fn (*anyopaque, @import("metawork_http_transport").Isolation) void,
    retire_context: *anyopaque,
    source: Source,
    host: Host,
    stopped: bool = true,
    observed: bool = false,
    observed_generation: ?u64 = null,
    find_retry_at: ?u64 = null,
    bound: ?Bound = null,
    poll: ?*Job = null,
    list: ?*Job = null,
    conversation: ?*Job = null,
    conversation_next: ?ConversationWork = null,
    task: ?*Job = null,
    task_next: ?TaskWork = null,
    file: ?*Job = null,
    file_next: ?TaskWork = null,

    /// Every request slot, for what applies to all of them alike.
    const slots = .{ "poll", "list", "conversation", "task", "file" };

    fn now(self: *const Coordinator) u64 {
        return self.host.now_ns_fn(self.host.context) / std.time.ns_per_ms;
    }

    fn wallMilliseconds(self: *const Coordinator) u64 {
        const nanoseconds = std.Io.Timestamp.now(self.io, .real).nanoseconds;
        return if (nanoseconds <= 0) 0 else @intCast(@divTrunc(nanoseconds, std.time.ns_per_ms));
    }

    fn assertMain(self: *const Coordinator) void {
        std.debug.assert(self.host.on_main_thread_fn(self.host.context));
    }

    pub fn start(self: *Coordinator, active: bool) void {
        self.assertMain();
        self.stopped = false;
        self.management.start_fn(self.management.context, active);
        self.reconcile();
    }

    pub fn setActive(self: *Coordinator, active: bool) void {
        self.assertMain();
        if (self.stopped) return;
        self.management.set_active_fn(self.management.context, self.now(), active);
        self.reconcile();
    }

    /// Looks for MetaTeam again when the installed connections changed, a
    /// failed credential read is due for another try, or the user asked.
    fn observe(self: *Coordinator, force: bool) void {
        const generation = self.source.generation_fn(self.source.context);
        const changed = !self.observed or generation != self.observed_generation;
        const retry_due = if (self.find_retry_at) |at| self.now() >= at else false;
        if (!force and !changed and !retry_due) return;
        self.observed = true;
        self.observed_generation = generation;
        self.find_retry_at = null;
        const result = if (generation) |value| self.source.find_fn(self.source.context, self.allocator, value) else .none;
        switch (result) {
            .none => {
                self.dropBinding();
                self.management.bind_fn(self.management.context, self.now(), null);
            },
            .unavailable => {
                self.dropBinding();
                self.management.binding_failed_fn(self.management.context, self.now());
                self.find_retry_at = self.now() +| find_retry_ms;
            },
            .found => |found_value| {
                var found = found_value;
                self.management.bind_fn(self.management.context, self.now(), .{ .server_id = found.server_id, .fingerprint = found.fingerprint });
                const revision = self.management.current_binding_fn(self.management.context) orelse {
                    found.release(self.allocator);
                    self.dropBinding();
                    return;
                };
                if (self.bound) |*current| if (current.revision != revision) self.dropBinding();
                if (self.bound) |*current| current.release(self.allocator);
                self.bound = .{
                    .revision = revision,
                    .server_id = found.server_id,
                    .fingerprint = found.fingerprint,
                    .base = found.base,
                    .key = found.key,
                    .isolation = isolationOf(found.server_id, found.fingerprint),
                };
            },
        }
    }

    fn isolationOf(server_id: []const u8, fingerprint: [64]u8) @import("metawork_http_transport").Isolation {
        var identity: [256 + 65]u8 = undefined;
        const length = @min(server_id.len, 256);
        @memcpy(identity[0..length], server_id[0..length]);
        identity[length] = 0;
        @memcpy(identity[length + 1 ..][0..64], &fingerprint);
        return .of(.inbox, identity[0 .. length + 65]);
    }

    /// Forgets the binding and the key; requests in flight finish into a
    /// Product that no longer accepts them.
    fn dropBinding(self: *Coordinator) void {
        var current = self.bound orelse return;
        self.bound = null;
        self.retire_fn(self.retire_context, current.isolation);
        current.release(self.allocator);
        inline for (slots) |name| if (@field(self, name)) |job| job.cancellation.cancel();
        if (self.conversation_next) |work| {
            self.conversation_next = null;
            respondConversationState(work.reply, work.peer.slice(), .stale_binding);
        }
        if (self.task_next) |work| {
            self.task_next = null;
            respondTaskState(work.reply, .stale_binding);
        }
        if (self.file_next) |work| {
            self.file_next = null;
            respondFileState(work.reply, .stale_binding);
        }
    }

    fn startJob(self: *Coordinator, work: Work) !*Job {
        const bound = self.bound orelse return error.Unbound;
        const base = try self.allocator.dupe(u8, bound.base);
        errdefer self.allocator.free(base);
        const key = try self.allocator.dupe(u8, bound.key);
        errdefer {
            std.crypto.secureZero(u8, key);
            self.allocator.free(key);
        }
        const job = try self.allocator.create(Job);
        errdefer self.allocator.destroy(job);
        job.* = .{
            .allocator = self.allocator,
            .transport = self.transport,
            .base = base,
            .key = key,
            .isolation = bound.isolation,
            .work = work,
            .cancellation = .{ .io = self.io },
            .wake_context = self.host.context,
            .wake_fn = self.host.wake_fn,
        };
        job.thread = try std.Thread.spawn(.{}, Job.run, .{job});
        return job;
    }

    fn startPoll(self: *Coordinator) void {
        if (self.poll != null or self.bound == null) return;
        const id = self.management.begin_poll_fn(self.management.context) orelse return;
        self.poll = self.startJob(.{ .poll = id }) catch {
            self.management.complete_poll_fn(self.management.context, self.now(), self.wallMilliseconds(), id, .{ .failed = .{ .@"unreachable" = null } });
            return;
        };
    }

    fn startList(self: *Coordinator) void {
        if (self.list != null or self.bound == null) return;
        const preparation = self.management.begin_list_fn(self.management.context) orelse return;
        self.list = self.startJob(.{ .list = preparation }) catch {
            self.management.complete_list_fn(self.management.context, self.now(), preparation.id, preparation.kind, .{ .failed = .{ .@"unreachable" = null } });
            return;
        };
    }

    /// While the inbox page is open the Renderer asks for the newer end of
    /// the list; Product decides whether an automatic ask runs at all. The
    /// user's explicit retry also reads the unread facts at once, past any
    /// retry delay or refusal.
    pub fn refresh(self: *Coordinator, binding: u64, explicit: bool) inbox.CommandOutcome {
        self.assertMain();
        if (self.stopped) return .unavailable;
        if (self.bound == null) {
            // Only the user's retry reads the credential store again after a
            // failed read; the timer retries later by itself, and a new or
            // changed connection is noticed from the MCP generation.
            if (explicit and self.find_retry_at != null) self.observe(true);
            self.reconcile();
            return .rejected;
        }
        const outcome = self.management.request_refresh_fn(self.management.context, self.now(), binding, explicit);
        if (outcome == .accepted and explicit) self.startPoll();
        self.reconcile();
        return outcome;
    }

    /// The Bridge connection ended: every pending read is answered now, and
    /// a result that arrives later is dropped instead of sent.
    pub fn cancelReads(self: *Coordinator) void {
        self.assertMain();
        if (self.conversation_next) |work| respondConversationState(work.reply, work.peer.slice(), .superseded);
        if (self.task_next) |work| respondTaskState(work.reply, .superseded);
        if (self.file_next) |work| respondFileState(work.reply, .superseded);
        self.conversation_next = null;
        self.task_next = null;
        self.file_next = null;
        if (self.conversation) |job| if (!job.replied) {
            respondConversationState(job.work.conversation.reply, job.work.conversation.peer.slice(), .superseded);
            job.replied = true;
            job.superseded = true;
            job.cancellation.cancel();
        };
        if (self.task) |job| if (!job.replied) {
            respondTaskState(job.work.task.reply, .superseded);
            job.replied = true;
            job.superseded = true;
            job.cancellation.cancel();
        };
        if (self.file) |job| if (!job.replied) {
            respondFileState(job.work.file.reply, .superseded);
            job.replied = true;
            job.superseded = true;
            job.cancellation.cancel();
        };
    }

    pub fn loadEarlier(self: *Coordinator, binding: u64) inbox.CommandOutcome {
        self.assertMain();
        if (self.stopped) return .unavailable;
        const outcome = self.management.request_earlier_fn(self.management.context, binding);
        self.reconcile();
        return outcome;
    }

    fn reply(responder: native_sdk.bridge.AsyncResponder, bridge_id: []const u8, binding: u64, request_id: u64) ?Reply {
        if (bridge_id.len > max_bridge_id_bytes) return null;
        var value: Reply = .{ .responder = responder, .bridge_id = .{ .len = bridge_id.len }, .binding = binding, .request_id = request_id };
        @memcpy(value.bridge_id.bytes[0..bridge_id.len], bridge_id);
        return value;
    }

    /// Returns false when the request cannot be answered at all; the caller
    /// then fails it as a Bridge error.
    pub fn readConversation(self: *Coordinator, responder: native_sdk.bridge.AsyncResponder, bridge_id: []const u8, request: ConversationRequest) bool {
        self.assertMain();
        const target = reply(responder, bridge_id, request.binding, request.request_id) orelse return false;
        const peer = inbox.Id.init(request.peer) catch return false;
        const anchor: ?inbox.Id = if (request.anchor) |value| inbox.Id.init(value) catch return false else null;
        if ((request.kind == .latest) != (anchor == null)) return false;
        const state: ?inbox.ConversationState = if (self.stopped or self.bound == null)
            .unavailable
        else if (!self.management.accepts_fn(self.management.context, request.binding))
            .stale_binding
        else if (!self.management.knows_peer_fn(self.management.context, request.binding, request.peer))
            .unknown_peer
        else
            null;
        if (state) |value| {
            respondConversationState(target, request.peer, value);
            return true;
        }
        const work: ConversationWork = .{ .reply = target, .peer = peer, .kind = request.kind, .anchor = anchor };
        if (self.conversation_next) |previous| respondConversationState(previous.reply, previous.peer.slice(), .superseded);
        self.conversation_next = work;
        if (self.conversation) |job| if (!job.replied) {
            respondConversationState(job.work.conversation.reply, job.work.conversation.peer.slice(), .superseded);
            job.replied = true;
            job.superseded = true;
            job.cancellation.cancel();
        };
        self.reconcile();
        return true;
    }

    pub fn readTask(self: *Coordinator, responder: native_sdk.bridge.AsyncResponder, bridge_id: []const u8, request: TaskRequest) bool {
        self.assertMain();
        const target = reply(responder, bridge_id, request.binding, request.request_id) orelse return false;
        const task = inbox.Id.init(request.task) catch return false;
        if (!inbox.validTaskId(task.slice())) return false;
        const state: ?inbox.TaskState = if (self.stopped or self.bound == null)
            .unavailable
        else if (!self.management.accepts_fn(self.management.context, request.binding))
            .stale_binding
        else
            null;
        if (state) |value| {
            respondTaskState(target, value);
            return true;
        }
        if (self.task_next) |previous| respondTaskState(previous.reply, .superseded);
        self.task_next = .{ .reply = target, .task = task };
        if (self.task) |job| if (!job.replied) {
            respondTaskState(job.work.task.reply, .superseded);
            job.replied = true;
            job.superseded = true;
            job.cancellation.cancel();
        };
        self.reconcile();
        return true;
    }

    /// Reads the file's detail again for a fresh download address and opens
    /// it in the system browser. The address never reaches the Renderer.
    pub fn openFile(self: *Coordinator, responder: native_sdk.bridge.AsyncResponder, bridge_id: []const u8, request: FileOpenRequest) bool {
        self.assertMain();
        const target = reply(responder, bridge_id, request.binding, request.request_id) orelse return false;
        const file = inbox.Id.init(request.file) catch return false;
        if (!inbox.validTaskId(file.slice())) return false;
        const state: ?inbox.FileOpenState = if (self.stopped or self.bound == null)
            .unavailable
        else if (!self.management.accepts_fn(self.management.context, request.binding))
            .stale_binding
        else
            null;
        if (state) |value| {
            respondFileState(target, value);
            return true;
        }
        if (self.file_next) |previous| respondFileState(previous.reply, .superseded);
        self.file_next = .{ .reply = target, .task = file };
        if (self.file) |job| if (!job.replied) {
            respondFileState(job.work.file.reply, .superseded);
            job.replied = true;
            job.superseded = true;
            job.cancellation.cancel();
        };
        self.reconcile();
        return true;
    }

    pub fn drain(self: *Coordinator) void {
        self.assertMain();
        if (self.stopped) return;
        self.settle();
        self.reconcile();
    }

    fn settle(self: *Coordinator) void {
        const now_ms = self.now();
        if (self.poll) |job| if (job.finished.load(.acquire)) {
            job.join();
            self.poll = null;
            const completion: inbox.PollCompletion = if (job.unread) |*unread| .{ .unread = unread } else .{ .failed = job.failure orelse .{ .@"unreachable" = null } };
            self.management.complete_poll_fn(self.management.context, now_ms, self.wallMilliseconds(), job.work.poll, completion);
            job.destroy();
        };
        if (self.list) |job| if (job.finished.load(.acquire)) {
            job.join();
            self.list = null;
            const preparation = job.work.list;
            self.completeList(job, preparation, now_ms);
            job.destroy();
        };
        if (self.conversation) |job| if (job.finished.load(.acquire)) {
            job.join();
            self.conversation = null;
            const work = job.work.conversation;
            if (job.replied) {
                // Already answered; nothing is sent twice.
            } else if (job.superseded) {
                respondConversationState(work.reply, work.peer.slice(), .superseded);
            } else if (!self.management.accepts_fn(self.management.context, work.reply.binding)) {
                // The connection changed while the request ran.
                respondConversationState(work.reply, work.peer.slice(), .stale_binding);
            } else if (job.page) |page| {
                self.management.complete_conversation_fn(self.management.context, work.reply.binding, work.peer.slice(), work.kind, page.items);
                self.respondConversation(work, page.items, job.page_limit);
            } else {
                // This request's own outcome; the connection state is the
                // unread and list requests' to decide.
                respondConversationState(work.reply, work.peer.slice(), requestState(inbox.ConversationState, job.status));
            }
            job.destroy();
        };
        if (self.task) |job| if (job.finished.load(.acquire)) {
            job.join();
            self.task = null;
            const work = job.work.task;
            if (job.replied) {
                // Already answered; nothing is sent twice.
            } else if (job.superseded) {
                respondTaskState(work.reply, .superseded);
            } else if (!self.management.accepts_fn(self.management.context, work.reply.binding)) {
                respondTaskState(work.reply, .stale_binding);
            } else if (job.detail) |*detail| {
                self.respondTask(work, detail);
            } else {
                respondTaskState(work.reply, requestState(inbox.TaskState, job.status));
            }
            job.destroy();
        };
        if (self.file) |job| if (job.finished.load(.acquire)) {
            job.join();
            self.file = null;
            const work = job.work.file;
            if (job.replied) {
                // Already answered; nothing is sent twice.
            } else if (job.superseded) {
                respondFileState(work.reply, .superseded);
            } else if (!self.management.accepts_fn(self.management.context, work.reply.binding)) {
                respondFileState(work.reply, .stale_binding);
            } else if (job.detail) |*detail| {
                respondFileState(work.reply, self.openDownload(detail, job.key));
            } else {
                respondFileState(work.reply, requestState(inbox.FileOpenState, job.status));
            }
            job.destroy();
        };
    }

    fn openDownload(self: *Coordinator, detail: *const inbox.Detail, key: []const u8) inbox.FileOpenState {
        const url = switch (detail.kind) {
            .file => |file| file.download_url orelse return .not_downloadable,
            else => return .not_downloadable,
        };
        if (url.len > native_sdk.platform.max_external_url_bytes or !inbox.validDownloadUrl(url, key)) return .not_downloadable;
        self.host.open_fn(self.host.context, url) catch return .failed;
        return .opened;
    }

    fn completeList(self: *Coordinator, job: *Job, preparation: inbox.ListPreparation, now_ms: u64) void {
        const page = job.page orelse {
            self.management.complete_list_fn(self.management.context, now_ms, preparation.id, preparation.kind, .{ .failed = job.failure orelse .{ .@"unreachable" = null } });
            return;
        };
        self.management.complete_list_fn(self.management.context, now_ms, preparation.id, preparation.kind, .{ .page = .{ .messages = page.items, .limit = job.page_limit } });
    }

    fn reconcile(self: *Coordinator) void {
        if (self.stopped) return;
        self.observe(false);
        if (self.bound != null) {
            if (self.management.next_poll_fn(self.management.context)) |at| if (self.now() >= at) self.startPoll();
            self.startList();
            if (self.conversation == null) if (self.conversation_next) |work| {
                self.conversation_next = null;
                self.conversation = self.startJob(.{ .conversation = work }) catch blk: {
                    respondConversationState(work.reply, work.peer.slice(), .failed);
                    break :blk null;
                };
            };
            if (self.task == null) if (self.task_next) |work| {
                self.task_next = null;
                self.task = self.startJob(.{ .task = work }) catch blk: {
                    respondTaskState(work.reply, .failed);
                    break :blk null;
                };
            };
            if (self.file == null) if (self.file_next) |work| {
                self.file_next = null;
                self.file = self.startJob(.{ .file = work }) catch blk: {
                    respondFileState(work.reply, .failed);
                    break :blk null;
                };
            };
        }
        self.reconcileTimer();
    }

    fn running(self: *const Coordinator) bool {
        inline for (slots) |name| if (@field(self, name) != null) return true;
        return false;
    }

    fn reconcileTimer(self: *Coordinator) void {
        if (self.stopped) return;
        const busy = self.running();
        const now_ms = self.now();
        var next: ?u64 = self.management.next_poll_fn(self.management.context);
        if (self.find_retry_at) |at| next = if (next) |value| @min(value, at) else at;
        const ms: u64 = if (busy) busy_timer_ms else if (next) |at| @max(1, at -| now_ms) else {
            self.host.cancel_timer_fn(self.host.context, timer_id) catch {};
            return;
        };
        self.host.start_timer_fn(self.host.context, timer_id, ms *| std.time.ns_per_ms, false) catch self.shutdown();
    }

    pub fn onTimer(self: *Coordinator) void {
        self.assertMain();
        if (self.stopped) return;
        self.drain();
    }

    pub fn shutdown(self: *Coordinator) void {
        self.assertMain();
        if (self.stopped) return;
        self.stopped = true;
        self.host.cancel_timer_fn(self.host.context, timer_id) catch {};
        inline for (slots) |name| if (@field(self, name)) |job| job.cancellation.cancel();
        inline for (slots) |name| if (@field(self, name)) |job| {
            job.join();
            if (!job.replied) switch (job.work) {
                .conversation => |work| respondConversationState(work.reply, work.peer.slice(), .unavailable),
                .task => |work| respondTaskState(work.reply, .unavailable),
                .file => |work| respondFileState(work.reply, .unavailable),
                else => {},
            };
            job.destroy();
            @field(self, name) = null;
        };
        if (self.conversation_next) |work| respondConversationState(work.reply, work.peer.slice(), .unavailable);
        if (self.task_next) |work| respondTaskState(work.reply, .unavailable);
        if (self.file_next) |work| respondFileState(work.reply, .unavailable);
        self.conversation_next = null;
        self.task_next = null;
        self.file_next = null;
        if (self.bound) |*current| {
            self.retire_fn(self.retire_context, current.isolation);
            current.release(self.allocator);
        }
        self.bound = null;
        self.management.stop_fn(self.management.context);
    }

    fn respondConversation(self: *Coordinator, work: ConversationWork, messages: []const inbox.Message, limit: u32) void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const output = arena.allocator().alloc(u8, native_sdk.bridge.max_result_bytes - 256) catch {
            respondConversationState(work.reply, work.peer.slice(), .failed);
            return;
        };
        const views = messageViews(arena.allocator(), messages) catch {
            respondConversationState(work.reply, work.peer.slice(), .failed);
            return;
        };
        const json = fitConversationPage(output, work, views, messages.len >= limit) orelse {
            respondConversationState(work.reply, work.peer.slice(), .failed);
            return;
        };
        work.reply.responder.success(work.reply.bridge_id.slice(), json) catch {};
    }

    /// The whole detail when it fits one Bridge result; otherwise the long
    /// parts are cut, see `shrinkDetail`.
    fn respondTask(self: *Coordinator, work: TaskWork, detail: *const inbox.Detail) void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const output = arena.allocator().alloc(u8, native_sdk.bridge.max_result_bytes - 256) catch
            return respondTaskState(work.reply, .failed);
        var result = detailView(arena.allocator(), work, detail) catch
            return respondTaskState(work.reply, .failed);
        while (true) {
            var writer = std.Io.Writer.fixed(output);
            if (std.json.Stringify.value(result, .{}, &writer)) |_| {
                work.reply.responder.success(work.reply.bridge_id.slice(), writer.buffered()) catch {};
                return;
            } else |_| {}
            if (!shrinkDetail(&result)) return respondTaskState(work.reply, .failed);
        }
    }
};

fn optionalU64(value: ?u64) ?inbox.U64 {
    return if (value) |present| .{ .value = present } else null;
}

fn noteView(note: inbox.Note) inbox.NoteView {
    return .{ .text = note.text, .atMs = optionalU64(note.at_ms), .by = note.by };
}

/// The Renderer view of one detail. The id MetaTeam returned wins over the
/// one asked for: a renamed task answers under its current id.
fn detailView(allocator: std.mem.Allocator, work: TaskWork, detail: *const inbox.Detail) !inbox.TaskDetail {
    var result: inbox.TaskDetail = .{
        .binding = .{ .value = work.reply.binding },
        .requestId = .{ .value = work.reply.request_id },
        .state = .ready,
        .task = null,
        .file = null,
        .project = null,
    };
    switch (detail.kind) {
        .task => |*task| {
            const notes = try allocator.alloc(inbox.NoteView, task.notes.len);
            for (task.notes, notes) |note, *view| view.* = noteView(note);
            const children = try allocator.alloc(inbox.ChildView, task.children.len);
            for (task.children, children) |*child, *view| view.* = .{ .id = child.id.slice(), .name = child.name, .progress = child.progress };
            result.task = .{
                .id = if (task.id) |*id| id.slice() else work.task.slice(),
                .name = task.name,
                .progress = task.progress,
                .state = task.state,
                .path = task.path,
                .description = task.description,
                .assignees = task.assignees,
                .createdBy = task.created_by,
                .updatedAtMs = optionalU64(task.updated_at_ms),
                .lastNote = if (task.last_note) |note| noteView(note) else null,
                .notes = notes,
                .children = children,
            };
        },
        .file => |*file| result.file = .{
            .id = if (file.id) |*id| id.slice() else work.task.slice(),
            .name = file.name,
            .tag = file.tag,
            .sizeBytes = optionalU64(file.size),
            .mime = file.mime,
            .description = file.description,
            .by = file.by,
            .updatedAtMs = optionalU64(file.updated_at_ms),
            .path = file.path,
            .content = file.content,
            .contentTruncated = false,
            .downloadable = file.download_url != null,
        },
        .project => |*project| {
            const files = try allocator.alloc(inbox.ProjectFileView, project.files.len);
            for (project.files, files) |*file, *view| view.* = .{
                .id = file.id.slice(),
                .name = file.name,
                .tag = file.tag,
                .sizeBytes = optionalU64(file.size),
                .mime = file.mime,
                .by = file.by,
                .updatedAtMs = optionalU64(file.updated_at_ms),
            };
            const tags = try allocator.alloc(inbox.TagCountView, project.file_tags.len);
            for (project.file_tags, tags) |tag, *view| view.* = .{ .tag = tag.tag, .count = .{ .value = tag.count } };
            result.project = .{
                .id = if (project.id) |*id| id.slice() else work.task.slice(),
                .name = project.name,
                .description = project.description,
                .path = project.path,
                .updatedAtMs = optionalU64(project.updated_at_ms),
                .files = files,
                .filesTruncated = false,
                .fileTags = tags,
            };
        },
    }
    return result;
}

fn halved(text: []const u8) ?[]const u8 {
    return if (text.len == 0) null else inbox.utf8Prefix(text, text.len / 2);
}

/// One step towards fitting a Bridge result, longest parts first: a file's
/// content, then descriptions; a task's oldest notes, then its children;
/// a project's last files. False when nothing is left to cut.
fn shrinkDetail(result: *inbox.TaskDetail) bool {
    if (result.file) |*file| {
        if (file.content) |content| {
            file.content = halved(content);
            file.contentTruncated = true;
            return true;
        }
        if (file.description) |description| {
            file.description = halved(description);
            return true;
        }
        return false;
    }
    if (result.task) |*task| {
        if (task.description) |description| if (description.len > 4096) {
            task.description = halved(description);
            return true;
        };
        if (task.notes.len != 0) {
            task.notes = task.notes[(task.notes.len + 1) / 2 ..];
            return true;
        }
        if (task.children.len != 0) {
            task.children = task.children[0 .. task.children.len / 2];
            return true;
        }
        if (task.description) |description| {
            task.description = halved(description);
            return true;
        }
        return false;
    }
    if (result.project) |*project| {
        if (project.files.len != 0) {
            project.files = project.files[0 .. project.files.len / 2];
            project.filesTruncated = true;
            return true;
        }
        if (project.description) |description| {
            project.description = halved(description);
            return true;
        }
    }
    return false;
}

fn requestState(comptime State: type, status: ?u16) State {
    return switch (inbox.requestFailure(status)) {
        .forbidden => .forbidden,
        .not_found => .not_found,
        .failed => .failed,
    };
}

fn messageViews(allocator: std.mem.Allocator, messages: []const inbox.Message) ![]inbox.MessageView {
    const views = try allocator.alloc(inbox.MessageView, messages.len);
    for (messages, views) |*message, *view| {
        const recipients = try allocator.alloc(inbox.RecipientView, message.recipients.len);
        for (message.recipients, recipients) |*entry, *recipient| recipient.* = .{
            .peerId = entry.peer.id.slice(),
            .name = entry.peer.name.slice(),
            .read = entry.read,
            .readAtMs = if (entry.read_at_ms) |at| .{ .value = at } else null,
        };
        const tasks = try allocator.alloc([]const u8, message.task_ids.len);
        for (message.task_ids, tasks) |*id, *task| task.* = id.slice();
        view.* = .{
            .id = message.id.slice(),
            .direction = message.direction,
            .fromPeerId = message.from.id.slice(),
            .fromName = message.from.name.slice(),
            .fromAgent = if (message.from_agent) |*agent| agent.slice() else null,
            .isNew = message.is_new,
            .recipients = recipients,
            .text = message.text,
            .truncated = false,
            .sentAtMs = .{ .value = message.sent_at_ms },
            .taskIds = tasks,
        };
    }
    return views;
}

/// The newest messages that fit one Bridge result. Older ones are left for
/// the next `before` page; only a single message larger than the whole
/// result is cut, and marked so.
fn fitConversationPage(output: []u8, work: ConversationWork, views: []inbox.MessageView, more_before: bool) ?[]const u8 {
    var start: usize = 0;
    while (true) {
        const dropped = start != 0;
        var writer = std.Io.Writer.fixed(output);
        if (std.json.Stringify.value(inbox.ConversationPage{
            .binding = .{ .value = work.reply.binding },
            .requestId = .{ .value = work.reply.request_id },
            .state = .ready,
            .peerId = work.peer.slice(),
            .messages = views[start..],
            .hasEarlier = work.kind != .after and (more_before or dropped),
            .complete = work.kind == .after and !more_before and !dropped,
        }, .{}, &writer)) |_| return writer.buffered() else |_| {}
        const remaining = views.len - start;
        if (remaining > 1) {
            start += @max(1, remaining / 2);
            continue;
        }
        if (remaining == 0) return null;
        const view = &views[start];
        if (view.text.len == 0) return null;
        view.text = inbox.utf8Prefix(view.text, view.text.len / 2);
        view.truncated = true;
    }
}

fn respondConversationState(target: Reply, peer: []const u8, state: inbox.ConversationState) void {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    std.json.Stringify.value(inbox.ConversationPage{
        .binding = .{ .value = target.binding },
        .requestId = .{ .value = target.request_id },
        .state = state,
        .peerId = peer,
        .messages = &.{},
        .hasEarlier = false,
        .complete = false,
    }, .{}, &writer) catch {
        target.responder.fail(target.bridge_id.slice(), .internal_error, "Inbox response encoding failed") catch {};
        return;
    };
    target.responder.success(target.bridge_id.slice(), writer.buffered()) catch {};
}

fn respondTaskState(target: Reply, state: inbox.TaskState) void {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    std.json.Stringify.value(inbox.TaskDetail{
        .binding = .{ .value = target.binding },
        .requestId = .{ .value = target.request_id },
        .state = state,
        .task = null,
        .file = null,
        .project = null,
    }, .{}, &writer) catch {
        target.responder.fail(target.bridge_id.slice(), .internal_error, "Inbox response encoding failed") catch {};
        return;
    };
    target.responder.success(target.bridge_id.slice(), writer.buffered()) catch {};
}

fn respondFileState(target: Reply, state: inbox.FileOpenState) void {
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    std.json.Stringify.value(inbox.FileOpen{
        .binding = .{ .value = target.binding },
        .requestId = .{ .value = target.request_id },
        .state = state,
    }, .{}, &writer) catch {
        target.responder.fail(target.bridge_id.slice(), .internal_error, "Inbox response encoding failed") catch {};
        return;
    };
    target.responder.success(target.bridge_id.slice(), writer.buffered()) catch {};
}

// ---------------------------------------------------------------------------
// Tests: a real Product inbox Runtime behind the Management capabilities, a
// scripted transport and a scripted connection source. No network.

const testing = std.testing;
const sentinel_key = "mtk-SENTINEL-7f3a";

const TestManagement = struct {
    runtime: inbox.Runtime,

    fn management(self: *TestManagement) inbox.Management {
        return .{
            .context = self,
            .start_fn = start,
            .bind_fn = bind,
            .binding_failed_fn = bindingFailed,
            .current_binding_fn = currentBinding,
            .set_active_fn = setActive,
            .next_poll_fn = nextPoll,
            .begin_poll_fn = beginPoll,
            .complete_poll_fn = completePoll,
            .request_refresh_fn = requestRefresh,
            .request_earlier_fn = requestEarlier,
            .begin_list_fn = beginList,
            .complete_list_fn = completeList,
            .knows_peer_fn = knowsPeer,
            .accepts_fn = accepts,
            .complete_conversation_fn = completeConversation,
            .stop_fn = stop,
        };
    }
    fn of(context: *anyopaque) *inbox.Runtime {
        return &@as(*TestManagement, @ptrCast(@alignCast(context))).runtime;
    }
    fn start(context: *anyopaque, active: bool) void {
        of(context).start(active);
    }
    fn bind(context: *anyopaque, now_ms: u64, key: ?inbox.BindingKey) void {
        _ = of(context).bind(now_ms, key) catch unreachable;
    }
    fn bindingFailed(context: *anyopaque, now_ms: u64) void {
        _ = of(context).bindingFailed(now_ms);
    }
    fn currentBinding(context: *anyopaque) ?u64 {
        return of(context).currentBinding();
    }
    fn setActive(context: *anyopaque, now_ms: u64, active: bool) void {
        of(context).setActive(now_ms, active);
    }
    fn nextPoll(context: *anyopaque) ?u64 {
        return of(context).nextPoll();
    }
    fn beginPoll(context: *anyopaque) ?u64 {
        return of(context).beginPoll();
    }
    fn completePoll(context: *anyopaque, now_ms: u64, wall_ms: u64, id: u64, completion: inbox.PollCompletion) void {
        _ = of(context).completePoll(now_ms, wall_ms, id, completion) catch unreachable;
    }
    fn requestRefresh(context: *anyopaque, now_ms: u64, binding: u64, explicit: bool) inbox.CommandOutcome {
        return of(context).requestRefresh(now_ms, binding, explicit);
    }
    fn requestEarlier(context: *anyopaque, binding: u64) inbox.CommandOutcome {
        return of(context).requestEarlier(binding);
    }
    fn beginList(context: *anyopaque) ?inbox.ListPreparation {
        return of(context).beginList();
    }
    fn completeList(context: *anyopaque, now_ms: u64, id: u64, kind: inbox.ListKind, completion: inbox.ListCompletion) void {
        _ = of(context).completeList(now_ms, id, kind, completion) catch unreachable;
    }
    fn knowsPeer(context: *anyopaque, binding: u64, peer: []const u8) bool {
        return of(context).knowsPeer(binding, peer);
    }
    fn accepts(context: *anyopaque, binding: u64) bool {
        return of(context).accepts(binding);
    }
    fn completeConversation(context: *anyopaque, binding: u64, peer: []const u8, kind: inbox.ConversationPageKind, messages: []const inbox.Message) void {
        _ = of(context).completeConversation(binding, peer, kind, messages) catch unreachable;
    }
    fn stop(context: *anyopaque) void {
        of(context).stop();
    }
};

const TestHost = struct {
    main_thread: std.Thread.Id,
    now_ms: u64 = 1000,
    timer_ms: ?u64 = null,
    opened: [256]u8 = undefined,
    opened_len: usize = 0,
    opens: usize = 0,

    fn host(self: *TestHost) Host {
        return .{ .context = self, .now_ns_fn = now, .wake_fn = wake, .start_timer_fn = startTimer, .cancel_timer_fn = cancelTimer, .open_fn = open, .on_main_thread_fn = onMain };
    }
    fn open(context: ?*anyopaque, url: []const u8) anyerror!void {
        const self = of(context);
        self.opens += 1;
        self.opened_len = @min(url.len, self.opened.len);
        @memcpy(self.opened[0..self.opened_len], url[0..self.opened_len]);
    }
    fn of(context: ?*anyopaque) *TestHost {
        return @ptrCast(@alignCast(context.?));
    }
    fn now(context: ?*anyopaque) u64 {
        return of(context).now_ms * std.time.ns_per_ms;
    }
    fn wake(_: ?*anyopaque) anyerror!void {}
    fn startTimer(context: ?*anyopaque, _: u64, ns: u64, _: bool) anyerror!void {
        of(context).timer_ms = ns / std.time.ns_per_ms;
    }
    fn cancelTimer(context: ?*anyopaque, _: u64) anyerror!void {
        of(context).timer_ms = null;
    }
    fn onMain(context: ?*anyopaque) bool {
        return std.Thread.getCurrentId() == of(context).main_thread;
    }
};

const TestSource = struct {
    generation: ?u64 = 1,
    result: enum { none, unavailable, found } = .found,
    fingerprint: [64]u8 = @splat('a'),
    base: []const u8 = "http://192.0.2.10:8080/team",
    finds: usize = 0,

    fn source(self: *TestSource) Source {
        return .{ .context = self, .generation_fn = generationOf, .find_fn = find };
    }
    fn generationOf(context: *anyopaque) ?u64 {
        return @as(*TestSource, @ptrCast(@alignCast(context))).generation;
    }
    fn find(context: *anyopaque, allocator: std.mem.Allocator, _: u64) FindResult {
        const self: *TestSource = @ptrCast(@alignCast(context));
        self.finds += 1;
        return switch (self.result) {
            .none => .none,
            .unavailable => .unavailable,
            .found => foundCopy(allocator, "server-1", self.fingerprint, self.base, sentinel_key) catch unreachable,
        };
    }
};

const TestTransport = struct {
    mutex: std.Io.Mutex = .init,
    urls: [32][256]u8 = undefined,
    url_lens: [32]usize = @splat(0),
    count: usize = 0,
    keys_ok: bool = true,
    status: u16 = 200,
    /// Answers for one task or one member's conversation only.
    task_status: u16 = 200,
    peer_status: u16 = 200,
    /// Holds every request until cleared, to keep a job in flight.
    block: std.atomic.Value(bool) = .init(false),
    /// Answers with `ResponseTooLarge` while the requested limit is above this.
    fits_limit: u32 = std.math.maxInt(u32),
    unread: []const u8 = "{\"data\":{\"unread\":2,\"byPeer\":[{\"peer\":{\"id\":\"ann\",\"name\":\"Ann\"},\"unread\":2}]}}",
    messages: []const u8 = "{\"data\":{\"messages\":[{\"id\":7,\"time\":1795428968292,\"direction\":\"in\",\"from\":{\"id\":\"ann\",\"name\":\"Ann\"},\"text\":\"hello\",\"taskIds\":[13066]}]}}",
    task: []const u8 = "{\"data\":{\"id\":13066,\"name\":\"Inbox\",\"progress\":\"doing\"}}",

    fn transport(self: *TestTransport) http.Transport {
        return .{ .context = self, .perform_fn = perform };
    }
    fn perform(context: *anyopaque, target: http.Target, request: inbox.Request, output: []u8, _: *const http.Cancellation, _: *?inbox.Diagnostic) http.Error!http.Response {
        const self: *TestTransport = @ptrCast(@alignCast(context));
        while (self.block.load(.acquire)) std.Thread.yield() catch {};
        self.mutex.lockUncancelable(testing.io);
        defer self.mutex.unlock(testing.io);
        if (!std.mem.eql(u8, target.key, sentinel_key)) self.keys_ok = false;
        if (self.count < self.urls.len) {
            var writer = std.Io.Writer.fixed(&self.urls[self.count]);
            inbox.writeUrl(&writer, target.base, request) catch {};
            self.url_lens[self.count] = writer.buffered().len;
            self.count += 1;
        }
        if (self.status != 200) return .{ .status = self.status };
        if (request == .task and self.task_status != 200) return .{ .status = self.task_status };
        if (request == .messages and request.messages.peer != null and self.peer_status != 200) return .{ .status = self.peer_status };
        if (request == .messages) if (request.messages.limit) |limit| if (limit > self.fits_limit) return error.ResponseTooLarge;
        const body = switch (request) {
            .unread => self.unread,
            .messages => self.messages,
            .task => self.task,
        };
        @memcpy(output[0..body.len], body);
        return .{ .status = 200, .body_len = body.len };
    }
    fn url(self: *TestTransport, index: usize) []const u8 {
        return self.urls[index][0..self.url_lens[index]];
    }
};

const Capture = struct {
    responses: std.ArrayList([]u8) = .empty,

    fn responder(self: *Capture) native_sdk.bridge.AsyncResponder {
        return .{ .context = self, .source = .{}, .respond_fn = respond };
    }
    fn respond(context: *anyopaque, _: native_sdk.bridge.Source, response: []const u8) anyerror!void {
        const self: *Capture = @ptrCast(@alignCast(context));
        try self.responses.append(testing.allocator, try testing.allocator.dupe(u8, response));
    }
    fn deinit(self: *Capture) void {
        for (self.responses.items) |item| testing.allocator.free(item);
        self.responses.deinit(testing.allocator);
    }
    fn last(self: *const Capture) []const u8 {
        return self.responses.items[self.responses.items.len - 1];
    }
};

fn noRetire(_: *anyopaque, _: @import("metawork_http_transport").Isolation) void {}

const Fixture = struct {
    management: TestManagement = .{ .runtime = .init(testing.allocator) },
    host: TestHost,
    source: TestSource = .{},
    transport: TestTransport = .{},
    capture: Capture = .{},
    coordinator: Coordinator = undefined,

    fn init(self: *Fixture) void {
        self.coordinator = .{
            .allocator = testing.allocator,
            .io = testing.io,
            .management = self.management.management(),
            .transport = self.transport.transport(),
            .retire_fn = noRetire,
            .retire_context = self,
            .source = self.source.source(),
            .host = self.host.host(),
        };
    }
    fn deinit(self: *Fixture) void {
        self.coordinator.shutdown();
        self.management.runtime.deinit();
        self.capture.deinit();
    }
    /// Lets every running request finish, then delivers the results.
    fn settle(self: *Fixture) void {
        var rounds: usize = 0;
        while (rounds < 8) : (rounds += 1) {
            inline for (Coordinator.slots) |name| if (@field(self.coordinator, name)) |job| job.join();
            self.coordinator.drain();
            if (!self.coordinator.running()) return;
        }
    }
    fn view(self: *Fixture) inbox.View {
        return self.management.runtime.view();
    }
    fn snapshot(self: *Fixture, buffer: []u8) []const u8 {
        var writer = std.Io.Writer.fixed(buffer);
        std.json.Stringify.value(self.view(), .{}, &writer) catch unreachable;
        return writer.buffered();
    }
};

test "inbox coordinator binds to MetaTeam, polls in the foreground and keeps the key out of every URL and view" {
    var fixture: Fixture = .{ .host = .{ .main_thread = std.Thread.getCurrentId() } };
    fixture.init();
    defer fixture.deinit();
    fixture.coordinator.start(true);
    try testing.expectEqual(inbox.State.checking, fixture.view().state);
    fixture.settle();
    try testing.expectEqual(inbox.State.ready, fixture.view().state);
    try testing.expectEqual(@as(u64, 2), fixture.view().unreadTotal.?.value);
    try testing.expectEqualStrings("http://192.0.2.10:8080/team/open/v1/unread", fixture.transport.url(0));
    try testing.expect(fixture.transport.keys_ok);
    // The next background poll waits for the ordinary interval.
    try testing.expectEqual(@as(?u64, inbox.Limits.poll_interval_ms), fixture.host.timer_ms);
    var buffer: [16 * 1024]u8 = undefined;
    const json = fixture.snapshot(&buffer);
    try testing.expect(std.mem.indexOf(u8, json, sentinel_key) == null);
    try testing.expect(std.mem.indexOf(u8, json, "/agent/v1/mcp/k/") == null);
    try testing.expect(std.mem.indexOf(u8, json, "192.0.2.10") == null);
    for (0..fixture.transport.count) |index| try testing.expect(std.mem.indexOf(u8, fixture.transport.url(index), sentinel_key) == null);

    // In the background nothing is asked; returning after a while asks again.
    fixture.coordinator.setActive(false);
    try testing.expect(fixture.management.runtime.nextPoll() == null);
    fixture.host.now_ms += inbox.Limits.resume_after_ms;
    fixture.coordinator.setActive(true);
    try testing.expect(fixture.coordinator.poll != null);
    fixture.settle();
    try testing.expectEqual(@as(usize, 2), fixture.transport.count);
}

test "inbox coordinator: a refused key stops background polling until the user retries; a lost connection unbinds" {
    var fixture: Fixture = .{ .host = .{ .main_thread = std.Thread.getCurrentId() } };
    fixture.init();
    defer fixture.deinit();
    fixture.transport.status = 401;
    fixture.coordinator.start(true);
    fixture.settle();
    try testing.expectEqual(inbox.State.reauthorize, fixture.view().state);
    try testing.expect(fixture.view().unreadTotal == null);
    try testing.expect(fixture.host.timer_ms == null);
    const binding = fixture.view().binding.value;
    fixture.transport.status = 200;
    // The page's automatic refresh respects the refusal; the user's retry does not.
    try testing.expectEqual(inbox.CommandOutcome.rejected, fixture.coordinator.refresh(binding, false));
    try testing.expect(fixture.coordinator.poll == null);
    try testing.expectEqual(inbox.CommandOutcome.accepted, fixture.coordinator.refresh(binding, true));
    fixture.settle();
    try testing.expectEqual(inbox.State.ready, fixture.view().state);

    // The connection is removed: the inbox is not connected any more.
    fixture.source.result = .none;
    fixture.source.generation = 2;
    fixture.coordinator.drain();
    try testing.expectEqual(inbox.State.unavailable, fixture.view().state);
    try testing.expect(fixture.coordinator.bound == null);
    // Without a connection the open page keeps asking; the credential store
    // is not read for that.
    const quiet = fixture.source.finds;
    try testing.expectEqual(inbox.CommandOutcome.rejected, fixture.coordinator.refresh(fixture.view().binding.value, false));
    try testing.expectEqual(inbox.CommandOutcome.rejected, fixture.coordinator.refresh(fixture.view().binding.value, true));
    try testing.expectEqual(quiet, fixture.source.finds);

    // A credential that cannot be read is reported and looked for again.
    fixture.source.result = .unavailable;
    fixture.source.generation = 3;
    fixture.coordinator.drain();
    try testing.expectEqual(inbox.State.@"unreachable", fixture.view().state);
    const finds = fixture.source.finds;
    // The page's automatic refresh does not read the store again; the
    // user's retry does at once, and the timer later by itself.
    _ = fixture.coordinator.refresh(fixture.view().binding.value, false);
    try testing.expectEqual(finds, fixture.source.finds);
    _ = fixture.coordinator.refresh(fixture.view().binding.value, true);
    try testing.expectEqual(finds + 1, fixture.source.finds);
    fixture.source.result = .found;
    fixture.host.now_ms += find_retry_ms;
    fixture.coordinator.onTimer();
    try testing.expectEqual(finds + 2, fixture.source.finds);
    try testing.expectEqual(inbox.State.checking, fixture.view().state);
}

test "inbox coordinator: list pages shrink until they fit, and conversations and tasks answer by request" {
    var fixture: Fixture = .{ .host = .{ .main_thread = std.Thread.getCurrentId() } };
    fixture.init();
    defer fixture.deinit();
    fixture.coordinator.start(true);
    fixture.settle();
    const binding = fixture.view().binding.value;
    fixture.transport.fits_limit = 50;
    try testing.expectEqual(inbox.CommandOutcome.accepted, fixture.coordinator.refresh(binding, false));
    fixture.settle();
    try testing.expect(fixture.view().conversationsLoaded);
    try testing.expectEqualStrings("ann", fixture.view().conversations[0].peerId);
    try testing.expectEqualStrings("hello", fixture.view().conversations[0].latest.?.preview);
    var limits: [3]bool = @splat(false);
    for (0..fixture.transport.count) |index| {
        const value = fixture.transport.url(index);
        if (std.mem.endsWith(u8, value, "messages?limit=200")) limits[0] = true;
        if (std.mem.endsWith(u8, value, "messages?limit=100")) limits[1] = true;
        if (std.mem.endsWith(u8, value, "messages?limit=50")) limits[2] = true;
    }
    try testing.expectEqual([3]bool{ true, true, true }, limits);

    const responder = fixture.capture.responder();
    try testing.expect(fixture.coordinator.readConversation(responder, "r1", .{ .binding = binding, .request_id = 1, .peer = "nobody", .kind = .latest, .anchor = null }));
    try testing.expect(std.mem.indexOf(u8, fixture.capture.last(), "\"state\":\"unknown_peer\"") != null);
    try testing.expect(fixture.coordinator.readConversation(responder, "r2", .{ .binding = binding + 1, .request_id = 2, .peer = "ann", .kind = .latest, .anchor = null }));
    try testing.expect(std.mem.indexOf(u8, fixture.capture.last(), "\"state\":\"stale_binding\"") != null);
    try testing.expect(!fixture.coordinator.readConversation(responder, "r3", .{ .binding = binding, .request_id = 3, .peer = "ann", .kind = .before, .anchor = null }));

    // A newer request replaces one still waiting or running.
    try testing.expect(fixture.coordinator.readConversation(responder, "r4", .{ .binding = binding, .request_id = 4, .peer = "ann", .kind = .latest, .anchor = null }));
    try testing.expect(fixture.coordinator.readConversation(responder, "r5", .{ .binding = binding, .request_id = 5, .peer = "ann", .kind = .latest, .anchor = null }));
    fixture.settle();
    var superseded = false;
    var ready = false;
    for (fixture.capture.responses.items) |response| {
        if (std.mem.indexOf(u8, response, "\"requestId\":\"4\"") != null and std.mem.indexOf(u8, response, "\"state\":\"superseded\"") != null) superseded = true;
        if (std.mem.indexOf(u8, response, "\"requestId\":\"5\"") != null and std.mem.indexOf(u8, response, "\"state\":\"ready\"") != null) {
            ready = std.mem.indexOf(u8, response, "\"text\":\"hello\"") != null and
                std.mem.indexOf(u8, response, "\"taskIds\":[\"13066\"]") != null and
                std.mem.indexOf(u8, response, "\"hasEarlier\":false") != null;
        }
    }
    try testing.expect(superseded and ready);
    var saw_peer_request = false;
    for (0..fixture.transport.count) |index| {
        if (std.mem.endsWith(u8, fixture.transport.url(index), "messages?peer=ann&limit=50")) saw_peer_request = true;
    }
    try testing.expect(saw_peer_request);

    try testing.expect(fixture.coordinator.readTask(responder, "t1", .{ .binding = binding, .request_id = 9, .task = "13066" }));
    fixture.settle();
    try testing.expect(std.mem.indexOf(u8, fixture.capture.last(), "\"name\":\"Inbox\"") != null);
    try testing.expect(std.mem.indexOf(u8, fixture.capture.last(), "\"progress\":\"doing\"") != null);
    for (fixture.capture.responses.items) |response| {
        try testing.expect(std.mem.indexOf(u8, response, sentinel_key) == null);
        try testing.expect(std.mem.indexOf(u8, response, "192.0.2.10") == null);
    }
    try testing.expect(fixture.transport.keys_ok);
}

test "inbox coordinator: the newest matching MCP connection is MetaTeam; others are not" {
    const auth: mcp_configuration.AuthWire = .{ .kind = "none", .oauth = null };
    const servers = [_]mcp_configuration.ServerWire{
        .{ .id = "old", .namespace = "a", .display_name = "Old", .enabled = true, .negotiation = "automatic", .timeout_ms = 1, .transport = .{ .kind = "streamable_http", .url = "https://one.test/agent/v1/mcp/k/first" }, .auth = auth, .connection_approval = null, .tools = &.{} },
        .{ .id = "new", .namespace = "b", .display_name = "New", .enabled = true, .negotiation = "automatic", .timeout_ms = 1, .transport = .{ .kind = "streamable_http", .url = "http://two.test/agent/v1/mcp/k/second" }, .auth = auth, .connection_approval = null, .tools = &.{} },
        .{ .id = "off", .namespace = "c", .display_name = "Off", .enabled = false, .negotiation = "automatic", .timeout_ms = 1, .transport = .{ .kind = "streamable_http", .url = "http://three.test/agent/v1/mcp/k/third" }, .auth = auth, .connection_approval = null, .tools = &.{} },
        .{ .id = "other", .namespace = "d", .display_name = "MetaTeam", .enabled = true, .negotiation = "automatic", .timeout_ms = 1, .transport = .{ .kind = "streamable_http", .url = "https://metateam.test/mcp" }, .auth = auth, .connection_approval = null, .tools = &.{} },
    };
    const states = [_]mcp_configuration.ServerPreparationState{ .eligible, .eligible, .disabled, .eligible };
    var result = selectDeviceEndpoint(testing.allocator, &servers, &states, &.{});
    switch (result) {
        .found => |*found| {
            defer found.release(testing.allocator);
            try testing.expectEqualStrings("new", found.server_id);
            try testing.expectEqualStrings("http://two.test", found.base);
            try testing.expectEqualStrings("second", found.key);
        },
        else => return error.TestUnexpectedResult,
    }
    const none_states = [_]mcp_configuration.ServerPreparationState{ .disabled, .unapproved, .disabled, .eligible };
    result = selectDeviceEndpoint(testing.allocator, &servers, &none_states, &.{});
    try testing.expect(result == .none);
}

test "inbox coordinator: an empty first page and a refresh after it start over" {
    var fixture: Fixture = .{ .host = .{ .main_thread = std.Thread.getCurrentId() } };
    fixture.init();
    defer fixture.deinit();
    fixture.transport.messages = "{\"data\":{\"messages\":[]}}";
    fixture.coordinator.start(true);
    fixture.settle();
    const binding = fixture.view().binding.value;
    try testing.expectEqual(inbox.CommandOutcome.accepted, fixture.coordinator.refresh(binding, false));
    fixture.settle();
    try testing.expect(fixture.view().conversationsLoaded);
    try testing.expectEqual(inbox.CommandOutcome.accepted, fixture.coordinator.refresh(binding, false));
    fixture.settle();
    var first_pages: usize = 0;
    for (0..fixture.transport.count) |index| {
        const value = fixture.transport.url(index);
        if (std.mem.endsWith(u8, value, "messages?limit=200")) first_pages += 1;
        try testing.expect(std.mem.indexOf(u8, value, "afterId") == null);
    }
    try testing.expectEqual(@as(usize, 2), first_pages);
}

test "inbox coordinator: a refused task or conversation answers that request only" {
    var fixture: Fixture = .{ .host = .{ .main_thread = std.Thread.getCurrentId() } };
    fixture.init();
    defer fixture.deinit();
    fixture.coordinator.start(true);
    fixture.settle();
    const binding = fixture.view().binding.value;
    _ = fixture.coordinator.refresh(binding, false);
    fixture.settle();
    const responder = fixture.capture.responder();
    for ([_]struct { u16, []const u8 }{ .{ 403, "forbidden" }, .{ 401, "forbidden" }, .{ 404, "not_found" }, .{ 500, "failed" } }) |case| {
        fixture.transport.task_status = case[0];
        try testing.expect(fixture.coordinator.readTask(responder, "t", .{ .binding = binding, .request_id = 1, .task = "13066" }));
        fixture.settle();
        var expected: [64]u8 = undefined;
        try testing.expect(std.mem.indexOf(u8, fixture.capture.last(), try std.fmt.bufPrint(&expected, "\"state\":\"{s}\"", .{case[1]})) != null);
        try testing.expectEqual(inbox.State.ready, fixture.view().state);
        try testing.expectEqual(@as(u64, 2), fixture.view().unreadTotal.?.value);
        try testing.expect(fixture.management.runtime.nextPoll() != null);
    }
    fixture.transport.task_status = 200;
    fixture.transport.peer_status = 404;
    try testing.expect(fixture.coordinator.readConversation(responder, "c", .{ .binding = binding, .request_id = 2, .peer = "ann", .kind = .latest, .anchor = null }));
    fixture.settle();
    try testing.expect(std.mem.indexOf(u8, fixture.capture.last(), "\"state\":\"not_found\"") != null);
    try testing.expectEqual(inbox.State.ready, fixture.view().state);
    // A dot segment never becomes a task path.
    try testing.expect(!fixture.coordinator.readTask(responder, "t", .{ .binding = binding, .request_id = 3, .task = ".." }));
}

test "inbox coordinator: a new connection waits for the old request and drops its result" {
    var fixture: Fixture = .{ .host = .{ .main_thread = std.Thread.getCurrentId() } };
    fixture.init();
    defer fixture.deinit();
    fixture.coordinator.start(true);
    fixture.settle();
    const first = fixture.view().binding.value;
    fixture.transport.block.store(true, .release);
    _ = fixture.coordinator.refresh(first, true);
    const old = fixture.coordinator.poll.?;
    // The connection is replaced while the poll is still running.
    fixture.source.fingerprint = @splat('b');
    fixture.source.generation = 2;
    fixture.coordinator.drain();
    try testing.expect(fixture.view().binding.value != first);
    try testing.expectEqual(inbox.State.checking, fixture.view().state);
    try testing.expectEqual(old, fixture.coordinator.poll.?);
    fixture.transport.block.store(false, .release);
    old.join();
    // The old result is dropped; the new connection's poll starts after it.
    fixture.coordinator.drain();
    try testing.expectEqual(inbox.State.checking, fixture.view().state);
    try testing.expect(fixture.coordinator.poll != null);
    fixture.settle();
    try testing.expectEqual(inbox.State.ready, fixture.view().state);
}

test "inbox coordinator: a closed Bridge connection answers pending reads once" {
    var fixture: Fixture = .{ .host = .{ .main_thread = std.Thread.getCurrentId() } };
    fixture.init();
    defer fixture.deinit();
    fixture.coordinator.start(true);
    fixture.settle();
    const binding = fixture.view().binding.value;
    _ = fixture.coordinator.refresh(binding, false);
    fixture.settle();
    fixture.transport.block.store(true, .release);
    const responder = fixture.capture.responder();
    try testing.expect(fixture.coordinator.readConversation(responder, "c", .{ .binding = binding, .request_id = 7, .peer = "ann", .kind = .latest, .anchor = null }));
    try testing.expect(fixture.coordinator.readTask(responder, "t", .{ .binding = binding, .request_id = 8, .task = "13066" }));
    fixture.coordinator.cancelReads();
    try testing.expectEqual(@as(usize, 2), fixture.capture.responses.items.len);
    fixture.transport.block.store(false, .release);
    fixture.settle();
    try testing.expectEqual(@as(usize, 2), fixture.capture.responses.items.len);
    for (fixture.capture.responses.items) |response|
        try testing.expect(std.mem.indexOf(u8, response, "\"state\":\"superseded\"") != null);
}

test "inbox coordinator: linked files, projects and tasks answer by kind; a download opens in the browser and never reaches the Renderer" {
    var fixture: Fixture = .{ .host = .{ .main_thread = std.Thread.getCurrentId() } };
    fixture.init();
    defer fixture.deinit();
    fixture.coordinator.start(true);
    fixture.settle();
    const binding = fixture.view().binding.value;
    const responder = fixture.capture.responder();
    const download = "http://192.0.2.10:8080/team/agent/v1/files/9830/dl?exp=1&sig=ab";
    fixture.transport.task = "{\"data\":{\"id\":9830,\"name\":\"api.md\",\"tag\":\"API\",\"size\":12,\"mime\":\"text/markdown\",\"by\":\"Lin\",\"path\":\"space / api.md\",\"content\":\"# Title\",\"downloadUrl\":\"" ++ download ++ "\",\"webUrl\":\"http://192.0.2.10:8080/team/api/v1/files/9830/content\"}}";
    try testing.expect(fixture.coordinator.readTask(responder, "t1", .{ .binding = binding, .request_id = 1, .task = "9830" }));
    fixture.settle();
    const file = fixture.capture.last();
    try testing.expect(std.mem.indexOf(u8, file, "\"file\":{\"id\":\"9830\"") != null);
    try testing.expect(std.mem.indexOf(u8, file, "\"content\":\"# Title\"") != null);
    try testing.expect(std.mem.indexOf(u8, file, "\"downloadable\":true") != null);
    try testing.expect(std.mem.indexOf(u8, file, "\"task\":null") != null);
    try testing.expect(std.mem.indexOf(u8, file, "192.0.2.10") == null);
    try testing.expect(std.mem.indexOf(u8, file, "sig=") == null);

    // The download address is read again and handed to the browser only.
    try testing.expect(fixture.coordinator.openFile(responder, "f1", .{ .binding = binding, .request_id = 2, .file = "9830" }));
    fixture.settle();
    try testing.expect(std.mem.indexOf(u8, fixture.capture.last(), "\"state\":\"opened\"") != null);
    try testing.expectEqualStrings(download, fixture.host.opened[0..fixture.host.opened_len]);
    try testing.expectEqualStrings("http://192.0.2.10:8080/team/open/v1/tasks/9830", fixture.transport.url(fixture.transport.count - 1));

    // An address carrying the key, or an id that is not a file, is not opened.
    fixture.transport.task = "{\"data\":{\"id\":9830,\"name\":\"api.md\",\"mime\":\"text/plain\",\"downloadUrl\":\"http://h.test/dl?k=" ++ sentinel_key ++ "\"}}";
    try testing.expect(fixture.coordinator.openFile(responder, "f2", .{ .binding = binding, .request_id = 3, .file = "9830" }));
    fixture.settle();
    try testing.expect(std.mem.indexOf(u8, fixture.capture.last(), "\"state\":\"not_downloadable\"") != null);
    fixture.transport.task = "{\"data\":{\"id\":13067,\"name\":\"Inbox\",\"type\":\"task\",\"progress\":\"doing\",\"state\":\"active\",\"lastNote\":null,\"notes\":[{\"text\":\"started\",\"at\":1,\"by\":\"Ann\"}],\"children\":[{\"id\":13070,\"name\":\"Reply\",\"progress\":\"todo\"}]}}";
    try testing.expect(fixture.coordinator.openFile(responder, "f3", .{ .binding = binding, .request_id = 4, .file = "13066" }));
    fixture.settle();
    try testing.expect(std.mem.indexOf(u8, fixture.capture.last(), "\"state\":\"not_downloadable\"") != null);
    try testing.expectEqual(@as(usize, 1), fixture.host.opens);

    // A task answers under the id MetaTeam returned, with its notes and children.
    try testing.expect(fixture.coordinator.readTask(responder, "t2", .{ .binding = binding, .request_id = 5, .task = "13066" }));
    fixture.settle();
    const task = fixture.capture.last();
    try testing.expect(std.mem.indexOf(u8, task, "\"task\":{\"id\":\"13067\"") != null);
    try testing.expect(std.mem.indexOf(u8, task, "\"notes\":[{\"text\":\"started\",\"atMs\":\"1\",\"by\":\"Ann\"}]") != null);
    try testing.expect(std.mem.indexOf(u8, task, "\"children\":[{\"id\":\"13070\",\"name\":\"Reply\",\"progress\":\"todo\"}]") != null);

    fixture.transport.task = "{\"data\":{\"id\":740,\"name\":\"metawork\",\"type\":\"project\",\"files\":[{\"id\":1,\"name\":\"a.md\",\"tag\":\"Docs\"}],\"fileTags\":{\"Docs\":1}}}";
    try testing.expect(fixture.coordinator.readTask(responder, "t3", .{ .binding = binding, .request_id = 6, .task = "740" }));
    fixture.settle();
    const project = fixture.capture.last();
    try testing.expect(std.mem.indexOf(u8, project, "\"project\":{\"id\":\"740\"") != null);
    try testing.expect(std.mem.indexOf(u8, project, "\"fileTags\":[{\"tag\":\"Docs\",\"count\":\"1\"}]") != null);

    // A refused file read is that request's outcome only.
    fixture.transport.task_status = 403;
    try testing.expect(fixture.coordinator.openFile(responder, "f4", .{ .binding = binding, .request_id = 7, .file = "9830" }));
    fixture.settle();
    try testing.expect(std.mem.indexOf(u8, fixture.capture.last(), "\"state\":\"forbidden\"") != null);
    try testing.expectEqual(inbox.State.ready, fixture.view().state);
    for (fixture.capture.responses.items) |response| try testing.expect(std.mem.indexOf(u8, response, sentinel_key) == null);
}

test "inbox coordinator: a detail larger than one Bridge result is cut, longest parts first" {
    var fixture: Fixture = .{ .host = .{ .main_thread = std.Thread.getCurrentId() } };
    fixture.init();
    defer fixture.deinit();
    fixture.coordinator.start(true);
    fixture.settle();
    const binding = fixture.view().binding.value;
    const responder = fixture.capture.responder();
    const content = try testing.allocator.alloc(u8, native_sdk.bridge.max_result_bytes);
    defer testing.allocator.free(content);
    @memset(content, 'x');
    const body = try std.fmt.allocPrint(testing.allocator, "{{\"data\":{{\"id\":1,\"name\":\"big.txt\",\"mime\":\"text/plain\",\"content\":\"{s}\"}}}}", .{content[0 .. inbox.Limits.detail_bytes - 128]});
    defer testing.allocator.free(body);
    fixture.transport.task = body;
    try testing.expect(fixture.coordinator.readTask(responder, "t", .{ .binding = binding, .request_id = 1, .task = "1" }));
    fixture.settle();
    const answer = fixture.capture.last();
    try testing.expect(answer.len < native_sdk.bridge.max_result_bytes);
    try testing.expect(std.mem.indexOf(u8, answer, "\"state\":\"ready\"") != null);
    try testing.expect(std.mem.indexOf(u8, answer, "\"contentTruncated\":true") != null);
}

test "inbox coordinator: the MCP source resolves a sensitive MetaTeam endpoint through the credential store" {
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{});
    defer harness.destroy(testing.allocator);
    var store: mcp_platform.CredentialStore = .{ .io = testing.io, .runtime = &harness.runtime, .main_thread_id = std.Thread.getCurrentId() };
    const locator = "mcp/endpoint-1";
    const url = "http://192.0.2.10:8080/team/agent/v1/mcp/k/" ++ sentinel_key;
    const effects = store.effects();
    try testing.expect(effects.create_fn(effects.context, locator, url));

    var server: mcp_configuration.ServerWire = .{
        .id = "server-1",
        .namespace = "metateam",
        .display_name = "MetaTeam",
        .enabled = true,
        .negotiation = "automatic",
        .timeout_ms = 30_000,
        .transport = .{ .kind = "streamable_http", .sensitive_endpoint = .{ .origin = "http://192.0.2.10:8080", .identity = locator, .credential_refs = &.{locator} } },
        .auth = .{ .kind = "none", .oauth = null },
        .connection_approval = null,
        .tools = &.{},
    };
    const fingerprint = mcp_configuration.connectionFingerprint(server);
    server.connection_approval = .{ .fingerprint = &fingerprint };
    var servers = [_]mcp_configuration.ServerWire{server};
    var storage: [16 * 1024]u8 = undefined;
    const bytes = try mcp_configuration.encode(&storage, .{ .schema_version = mcp_configuration.schema_version, .generation = 1, .oauth_operation = null, .servers = &servers }, mcp_startup.configuration_limits);

    const Port = struct {
        bytes: []const u8,
        fn inspect(_: *anyopaque) ?mcp_configuration.ManagementInspection {
            return .{ .health = .ready, .desired_generation = 1, .runtime_alignment = .current, .server_count = 1 };
        }
        fn write(context: *anyopaque, generation: u64, output: []u8) anyerror![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (generation != 1) return error.McpManagementUnavailable;
            @memcpy(output[0..self.bytes.len], self.bytes);
            return output[0..self.bytes.len];
        }
    };
    var port_state: Port = .{ .bytes = bytes };
    // Only the two capabilities the source uses are reachable.
    var port: control_ports.McpManagementPort = undefined;
    port.context = &port_state;
    port.inspect_fn = Port.inspect;
    port.write_desired_fn = Port.write;
    var mcp: McpSource = .{ .port = port, .credential_store = &store };
    const source = mcp.source();
    try testing.expectEqual(@as(?u64, 1), source.generation_fn(source.context));
    var result = source.find_fn(source.context, testing.allocator, 1);
    switch (result) {
        .found => |*found| {
            defer found.release(testing.allocator);
            try testing.expectEqualStrings("server-1", found.server_id);
            try testing.expectEqualStrings("http://192.0.2.10:8080/team", found.base);
            try testing.expectEqualStrings(sentinel_key, found.key);
            try testing.expectEqualSlices(u8, &fingerprint, &found.fingerprint);
        },
        else => return error.TestUnexpectedResult,
    }
    // A disabled connection is not MetaTeam for the inbox.
    servers[0].enabled = false;
    port_state.bytes = try mcp_configuration.encode(&storage, .{ .schema_version = mcp_configuration.schema_version, .generation = 1, .oauth_operation = null, .servers = &servers }, mcp_startup.configuration_limits);
    result = source.find_fn(source.context, testing.allocator, 1);
    try testing.expect(result == .none);
}
