//! MetaTeam inbox lifecycle coordinator. Finds the installed MetaTeam
//! connection, keeps its device key in Application memory only, runs the
//! timer and the request workers, and hands typed results to Product on the
//! main thread. Jobs hold owned requests and a narrow transport, never
//! Product state, the credential store or a Native Runtime.
const std = @import("std");
const native_sdk = @import("native_sdk");
const cache_store = @import("message_store.zig");
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
        var digest = std.crypto.hash.sha2.Sha256.init(.{});
        digest.update(&mcp_configuration.connectionFingerprint(server));
        digest.update(match.key);
        return foundCopy(allocator, server.id, std.fmt.bytesToHex(digest.finalResult(), .lower), match.base, match.key) catch .unavailable;
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

    directory: ?inbox.People = null,

    fn hasMember(self: *const Bound, username: []const u8) bool {
        const directory = self.directory orelse return false;
        for (directory.items) |*member| if (member.username.eql(username)) return true;
        return false;
    }

    fn release(self: *Bound, allocator: std.mem.Allocator) void {
        if (self.directory) |*people| people.deinit(allocator);
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
    peer: inbox.Name,
    by_username: bool = false,
    kind: inbox.ConversationPageKind,
    anchor: ?inbox.Id,
    username: ?inbox.Name = null,
};

const TaskWork = struct {
    reply: Reply,
    task: inbox.Id,
};

const RequestKey = struct {
    bytes: [64]u8 = undefined,
    len: usize = 0,

    fn init(value: []const u8) ?RequestKey {
        if (!inbox.validRequestKey(value)) return null;
        var key: RequestKey = .{ .len = value.len };
        @memcpy(key.bytes[0..value.len], value);
        return key;
    }

    fn slice(self: *const RequestKey) []const u8 {
        return self.bytes[0..self.len];
    }
};

const SendWork = struct {
    reply: Reply,
    /// The JSON body, owned by the work.
    body: []u8,
    request_key: RequestKey,
    /// A member picked by username for a new conversation: once sent, the
    /// conversation it landed in is read back to put it in the list.
    resolve: ?inbox.Name = null,
};

const PeopleWork = struct {
    reply: Reply,
};

const Work = union(enum) {
    poll: u64,
    list: inbox.ListPreparation,
    conversation: ConversationWork,
    task: TaskWork,
    /// Reads the file's detail for a fresh download address to open.
    file: TaskWork,
    send: SendWork,
    people: PeopleWork,
};

const Job = struct {
    allocator: std.mem.Allocator,
    transport: http.Transport,
    base: []u8,
    key: []u8,
    isolation: @import("metawork_http_transport").Isolation,
    cache: ?cache_store.Store,
    page_mutex: *std.Io.Mutex,
    list_arena: std.heap.ArenaAllocator,
    local_list: ?inbox.ListPage = null,
    cached_has_earlier: ?bool = null,
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
    resolved_peer: ?inbox.Id = null,
    consumed_unread: bool = false,
    detail: ?inbox.Detail = null,
    /// The names a send reached, when MetaTeam took it.
    sent: ?[]inbox.Name = null,
    /// The answer to the send itself; `status` may belong to the read that
    /// follows it.
    send_status: ?u16 = null,
    people: ?inbox.People = null,

    fn run(self: *Job) void {
        defer {
            self.finished.store(true, .release);
            self.wake_fn(self.wake_context) catch {};
        }
        self.execute() catch {
            // A failed cache or allocation produces a bounded failure for this job.
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
                const cache = self.cache orelse return error.CacheUnavailable;
                self.local_list = try cache.list(self.list_arena.allocator(), preparation.anchor);
            },
            .conversation => |work| {
                const cache = self.cache orelse return error.CacheUnavailable;
                // A post-send lookup can read this same timeline from a second
                // worker. Commit pages in the order in which we fetch them.
                self.page_mutex.lockUncancelable(self.cancellation.io);
                defer self.page_mutex.unlock(self.cancellation.io);
                if (!work.by_username and work.kind == .latest) {
                    if (try cache.latest(self.allocator, work.peer.slice())) |saved| {
                        self.page = saved.page;
                        self.cached_has_earlier = saved.has_earlier;
                        return;
                    }
                }
                const query: inbox.MessagesQuery = switch (work.kind) {
                    .latest, .refresh => .{ .peer = work.peer.slice() },
                    .before => .{ .peer = work.peer.slice(), .before = work.anchor.?.slice() },
                    .after => .{ .peer = work.peer.slice(), .after = work.anchor.?.slice() },
                };
                if (try self.pageOf(query, inbox.Limits.conversation_page)) {
                    if (work.by_username) {
                        if (self.page.?.items.len == 0) return;
                        const member = inbox.conversationOf(self.page.?.items, work.peer.slice()) orelse {
                            self.page.?.deinit();
                            self.page = null;
                            return error.WrongPeer;
                        };
                        self.resolved_peer = member.id;
                    }
                    const peer = if (self.resolved_peer) |*id| id.slice() else work.peer.slice();
                    cache.save(self.allocator, peer, work.username, work.kind, work.anchor, &self.page.?, self.page_limit) catch |err| {
                        self.page.?.deinit();
                        self.page = null;
                        return err;
                    };
                }
            },
            .send => |work| {
                const buffer = try self.allocator.alloc(u8, inbox.Limits.send_bytes);
                defer self.allocator.free(buffer);
                var diagnostic: ?inbox.Diagnostic = null;
                const response: ?http.Response = self.transport.perform_fn(self.transport.context, .{ .base = self.base, .key = self.key, .isolation = self.isolation }, .{ .send = .{ .body = work.body, .request_key = work.request_key.slice() } }, buffer, &self.cancellation, &diagnostic) catch |err| switch (err) {
                    // Only a success has its body read: it was taken.
                    error.ResponseTooLarge => blk: {
                        self.send_status = 200;
                        self.sent = try self.allocator.alloc(inbox.Name, 0);
                        break :blk null;
                    },
                    // No answer: whether it arrived is unknown, and only the
                    // user's retry sends it again, under the same key.
                    else => {
                        self.failure = .{ .@"unreachable" = diagnostic };
                        return;
                    },
                };
                if (response) |answer| {
                    self.send_status = answer.status;
                    if (inbox.sendState(answer.status) != .sent) {
                        std.log.warn("inbox request consumer=inbox request=send status={d}", .{answer.status});
                        return;
                    }
                    self.sent = try inbox.parseSent(self.allocator, buffer[0..answer.body_len]);
                }
                // A new conversation: MetaTeam's newest message with that
                // member tells which conversation it is.
                if (work.resolve) |*username| {
                    self.page_mutex.lockUncancelable(self.cancellation.io);
                    defer self.page_mutex.unlock(self.cancellation.io);
                    if (try self.pageOf(.{ .peer = username.slice() }, 1)) {
                        if (inbox.conversationOf(self.page.?.items, username.slice())) |peer| {
                            const cache = self.cache orelse return error.CacheUnavailable;
                            cache.save(self.allocator, peer.id.slice(), username.*, .latest, null, &self.page.?, 1) catch |err| {
                                self.page.?.deinit();
                                self.page = null;
                                return err;
                            };
                        }
                    }
                }
            },
            .people => {
                const buffer = try self.allocator.alloc(u8, inbox.Limits.people_bytes);
                defer self.allocator.free(buffer);
                const body = (self.fetch(.people, buffer) catch return self.unusable(.people, 0)) orelse return;
                self.people = inbox.parsePeople(self.allocator, body) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.InvalidResponse => return self.unusable(.people, body.len),
                };
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
            // Cache writes restore the first observed "new" mark for display.
            // Only the mark on this HTTP response is evidence of a new read.
            for (self.page.?.items) |*message| {
                if (message.is_new) {
                    self.consumed_unread = true;
                    break;
                }
            }
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
        const body = buffer[0..response.body_len];
        if (request == .unread or request == .messages or request == .people) {
            if (responseContainsKey(self.allocator, body, self.key)) {
                self.unusable(std.meta.activeTag(request), body.len);
                return null;
            }
        }
        return body;
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
        self.list_arena.deinit();
        if (self.page) |*value| value.deinit();
        if (self.detail) |*value| value.deinit();
        if (self.sent) |names| self.allocator.free(names);
        if (self.people) |*value| value.deinit(self.allocator);
        if (self.work == .send) self.allocator.free(self.work.send.body);
        std.crypto.secureZero(u8, self.key);
        self.allocator.free(self.key);
        self.allocator.free(self.base);
        self.allocator.destroy(self);
    }
};

/// Decode escaped JSON strings as well as scanning the ordinary spelling.
fn responseContainsKey(a: std.mem.Allocator, body: []const u8, key: []const u8) bool {
    if (std.mem.indexOf(u8, body, key) != null) return true;
    if (std.mem.indexOfScalar(u8, body, '\\') == null) return false;
    var scanner = std.json.Scanner.initCompleteInput(a, body);
    defer scanner.deinit();
    while (true) switch (scanner.nextAllocMax(a, .alloc_if_needed, body.len) catch return true) {
        .allocated_string => |value| {
            defer a.free(value);
            if (std.mem.indexOf(u8, value, key) != null) return true;
        },
        .allocated_number => |value| a.free(value),
        .end_of_document => return false,
        else => {},
    };
}

pub const Coordinator = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    management: inbox.Management,
    database: ?@import("metawork_storage_sql").Database,
    page_mutex: std.Io.Mutex = .init,
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
    /// One message at a time. Never replaced, and never cancelled by a
    /// changed connection: a send in flight may already have arrived.
    send: ?*Job = null,
    people: ?*Job = null,
    people_next: ?PeopleWork = null,

    /// Every request slot, for what applies to all of them alike.
    const slots = .{ "poll", "list", "conversation", "task", "file", "people", "send" };
    /// The requests whose result a changed connection makes worthless.
    const read_slots = .{ "poll", "list", "conversation", "task", "file", "people" };

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
        inline for (read_slots) |name| if (@field(self, name)) |job| job.cancellation.cancel();
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
        if (self.people_next) |work| {
            self.people_next = null;
            respondPeopleState(work.reply, .stale_binding);
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
            .cache = if (self.database) |db| .{ .db = db, .scope = bound.isolation.digest } else null,
            .page_mutex = &self.page_mutex,
            .list_arena = .init(self.allocator),
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
            self.management.complete_list_fn(self.management.context, self.now(), preparation.id, .{ .failed = .{ .@"unreachable" = null } });
            return;
        };
    }

    /// Refresh loads local summaries on first entry; Product gates each
    /// automatic request before the open peer can be polled. The
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
        if (self.people_next) |work| respondPeopleState(work.reply, .superseded);
        self.conversation_next = null;
        self.task_next = null;
        self.file_next = null;
        self.people_next = null;
        if (self.people) |job| if (!job.replied) {
            respondPeopleState(job.work.people.reply, .superseded);
            job.replied = true;
            job.superseded = true;
            job.cancellation.cancel();
        };
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
        // A send runs to its end; only its answer is no longer sent.
        if (self.send) |job| if (!job.replied) {
            respondSendState(job.work.send.reply, .superseded);
            job.replied = true;
        };
    }

    /// Sends one message to a conversation the list knows. Returns false
    /// when the request cannot be answered at all; the caller then fails it
    /// as a Bridge error.
    pub fn sendMessage(self: *Coordinator, responder: native_sdk.bridge.AsyncResponder, bridge_id: []const u8, request: inbox.SendRequest) bool {
        self.assertMain();
        const target = reply(responder, bridge_id, request.binding, request.request_id) orelse return false;
        // A picked member is addressed by their exact username.
        const picked: ?inbox.Name = switch (request.to) {
            .peer => |peer| blk: {
                _ = inbox.Id.init(peer) catch return false;
                break :blk null;
            },
            .username => |username| inbox.Name.init(username) catch return false,
        };
        if (!inbox.sendableText(request.text)) return false;
        const request_key = RequestKey.init(request.request_key) orelse return false;
        if (self.stopped or self.bound == null) {
            respondSendState(target, .unavailable);
            return true;
        }
        if (!self.management.accepts_fn(self.management.context, request.binding)) {
            respondSendState(target, .stale_binding);
            return true;
        }
        if (picked) |username| {
            if (std.mem.indexOf(u8, username.slice(), self.bound.?.key) != null) {
                respondSendState(target, .unknown_peer);
                return true;
            }
        }
        const address: inbox.Address = if (picked) |username| .{ .member = username } else self.management.peer_address_fn(self.management.context, request.binding, request.to.peer) orelse {
            respondSendState(target, .unknown_peer);
            return true;
        };
        if (self.send != null) {
            respondSendState(target, .busy);
            return true;
        }
        var body: std.Io.Writer.Allocating = .init(self.allocator);
        inbox.writeSendBody(&body.writer, address, request.text) catch {
            body.deinit();
            respondSendState(target, .failed);
            return true;
        };
        const owned = body.toOwnedSlice() catch {
            body.deinit();
            respondSendState(target, .failed);
            return true;
        };
        self.send = self.startJob(.{ .send = .{ .reply = target, .body = owned, .request_key = request_key, .resolve = picked } }) catch {
            self.allocator.free(owned);
            respondSendState(target, .failed);
            return true;
        };
        self.reconcileTimer();
        return true;
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
        const peer = inbox.Name.init(request.peer) catch return false;
        if (request.by_username and request.kind != .latest) return false;
        if (!request.by_username and request.peer.len > inbox.Limits.id_bytes) return false;
        const anchor: ?inbox.Id = if (request.anchor) |value| inbox.Id.init(value) catch return false else null;
        if ((request.kind == .before or request.kind == .after) != (anchor != null)) return false;
        const state: ?inbox.ConversationState = if (self.stopped or self.bound == null)
            .unavailable
        else if (!self.management.accepts_fn(self.management.context, request.binding))
            .stale_binding
        else if (if (request.by_username) !self.bound.?.hasMember(request.peer) else !self.management.knows_peer_fn(self.management.context, request.binding, request.peer))
            .unknown_peer
        else
            null;
        if (state) |value| {
            respondConversationState(target, request.peer, value);
            return true;
        }
        const address: ?inbox.Address = if (request.by_username) .{ .member = peer } else self.management.peer_address_fn(self.management.context, request.binding, request.peer);
        const work: ConversationWork = .{ .reply = target, .peer = peer, .by_username = request.by_username, .kind = request.kind, .anchor = anchor, .username = if (address) |v| switch (v) {
            .member => |name| name,
            .self => null,
        } else null };
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
        self.settleSend();
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
            var resolved = work;
            if (job.resolved_peer) |*peer| resolved.peer = .truncated(peer.slice());
            if (job.consumed_unread) self.management.messages_marked_read_fn(self.management.context, work.reply.binding);
            const current = self.management.accepts_fn(self.management.context, work.reply.binding);
            // A completed read is already saved and may have consumed unread
            // messages even if the user selected another peer in the meantime.
            if (current) if (job.page) |page| {
                if (!work.by_username or job.resolved_peer != null)
                    self.management.complete_conversation_fn(self.management.context, work.reply.binding, resolved.peer.slice(), work.kind, page.items, work.username);
            };
            if (job.replied) {
                // Already answered; nothing is sent twice.
            } else if (job.superseded) {
                respondConversationState(work.reply, work.peer.slice(), .superseded);
            } else if (!current) {
                // The connection changed while the request ran.
                respondConversationState(work.reply, work.peer.slice(), .stale_binding);
            } else if (job.page) |page| {
                self.respondConversation(resolved, page.items, job.cached_has_earlier orelse (page.items.len >= job.page_limit));
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
        if (self.people) |job| if (job.finished.load(.acquire)) {
            job.join();
            self.people = null;
            const work = job.work.people;
            if (job.replied) {
                // Already answered; nothing is sent twice.
            } else if (job.superseded) {
                respondPeopleState(work.reply, .superseded);
            } else if (!self.management.accepts_fn(self.management.context, work.reply.binding)) {
                respondPeopleState(work.reply, .stale_binding);
            } else if (job.people) |*people| {
                if (self.bound.?.directory) |*previous| previous.deinit(self.allocator);
                self.bound.?.directory = people.*;
                job.people = null;
                respondPeople(self.allocator, work.reply, self.bound.?.directory.?.items);
            } else {
                respondPeopleState(work.reply, requestState(inbox.PeopleState, job.status));
            }
            job.destroy();
        };
    }

    /// What MetaTeam answered is a fact about the message, so it is
    /// answered even when the connection changed meanwhile.
    fn settleSend(self: *Coordinator) void {
        const job = self.send orelse return;
        if (!job.finished.load(.acquire)) return;
        job.join();
        self.send = null;
        defer job.destroy();
        const work = &job.work.send;
        if (job.consumed_unread) self.management.messages_marked_read_fn(self.management.context, work.reply.binding);
        const state = inbox.sendState(job.send_status);
        // A new conversation joins the list and becomes the one being read;
        // when its recipient is known.
        var landed: ?inbox.Peer = null;
        if (state == .sent) if (work.resolve) |*username| if (self.management.accepts_fn(self.management.context, work.reply.binding)) {
            if (job.page) |page| if (inbox.conversationOf(page.items, username.slice())) |peer| {
                landed = peer;
                self.management.complete_conversation_fn(self.management.context, work.reply.binding, peer.id.slice(), .latest, page.items, username.*);
            };
        };
        if (job.replied) return;
        const conversation: ?inbox.ConversationRef = if (landed) |*peer| .{ .peerId = peer.id.slice(), .name = peer.name.slice() } else null;
        respondSend(self.allocator, work.reply, state, job.sent orelse &.{}, conversation);
    }

    /// The members a new conversation can start with, read when the picker
    /// opens; a newer request replaces one still waiting or running.
    pub fn listPeople(self: *Coordinator, responder: native_sdk.bridge.AsyncResponder, bridge_id: []const u8, request: inbox.PeopleRequest) bool {
        self.assertMain();
        const target = reply(responder, bridge_id, request.binding, request.request_id) orelse return false;
        const state: ?inbox.PeopleState = if (self.stopped or self.bound == null)
            .unavailable
        else if (!self.management.accepts_fn(self.management.context, request.binding))
            .stale_binding
        else
            null;
        if (state) |value| {
            respondPeopleState(target, value);
            return true;
        }
        if (self.people_next) |previous| respondPeopleState(previous.reply, .superseded);
        self.people_next = .{ .reply = target };
        if (self.people) |job| if (!job.replied) {
            respondPeopleState(job.work.people.reply, .superseded);
            job.replied = true;
            job.superseded = true;
            job.cancellation.cancel();
        };
        self.reconcile();
        return true;
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
        const page = job.local_list orelse {
            self.management.complete_list_fn(self.management.context, now_ms, preparation.id, .{ .failed = job.failure orelse .{ .@"unreachable" = null } });
            return;
        };
        self.management.complete_list_fn(self.management.context, now_ms, preparation.id, .{ .page = page });
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
            if (self.people == null) if (self.people_next) |work| {
                self.people_next = null;
                self.people = self.startJob(.{ .people = work }) catch blk: {
                    respondPeopleState(work.reply, .failed);
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
                .people => |work| respondPeopleState(work.reply, .unavailable),
                // What MetaTeam answered before the cancel stands; without
                // an answer, whether it arrived is unknown.
                .send => |work| respondSend(self.allocator, work.reply, inbox.sendState(job.send_status), job.sent orelse &.{}, null),
                else => {},
            };
            job.destroy();
            @field(self, name) = null;
        };
        if (self.conversation_next) |work| respondConversationState(work.reply, work.peer.slice(), .unavailable);
        if (self.task_next) |work| respondTaskState(work.reply, .unavailable);
        if (self.file_next) |work| respondFileState(work.reply, .unavailable);
        if (self.people_next) |work| respondPeopleState(work.reply, .unavailable);
        self.conversation_next = null;
        self.task_next = null;
        self.file_next = null;
        self.people_next = null;
        if (self.bound) |*current| {
            self.retire_fn(self.retire_context, current.isolation);
            current.release(self.allocator);
        }
        self.bound = null;
        self.management.stop_fn(self.management.context);
    }

    fn respondConversation(self: *Coordinator, work: ConversationWork, messages: []const inbox.Message, full: bool) void {
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
        const json = fitConversationPage(output, work, views, full) orelse {
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

fn respondSendState(target: Reply, state: inbox.SendState) void {
    var buffer: [1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    respondSend(fixed.allocator(), target, state, &.{}, null);
}

fn respondPeopleState(target: Reply, state: inbox.PeopleState) void {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    std.json.Stringify.value(inbox.PeopleList{
        .binding = .{ .value = target.binding },
        .requestId = .{ .value = target.request_id },
        .state = state,
        .people = &.{},
    }, .{}, &writer) catch {
        target.responder.fail(target.bridge_id.slice(), .internal_error, "Inbox response encoding failed") catch {};
        return;
    };
    target.responder.success(target.bridge_id.slice(), writer.buffered()) catch {};
}

/// Every member when they fit one Bridge result; an organization too large
/// for one keeps its first members.
fn respondPeople(allocator: std.mem.Allocator, target: Reply, members: []const inbox.Member) void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const views = arena.allocator().alloc(inbox.MemberView, members.len) catch return respondPeopleState(target, .failed);
    for (members, views) |*member, *view| view.* = .{ .username = member.username.slice(), .name = member.name.slice(), .online = member.online };
    const output = arena.allocator().alloc(u8, native_sdk.bridge.max_result_bytes - 256) catch return respondPeopleState(target, .failed);
    var count = views.len;
    while (true) {
        var writer = std.Io.Writer.fixed(output);
        if (std.json.Stringify.value(inbox.PeopleList{
            .binding = .{ .value = target.binding },
            .requestId = .{ .value = target.request_id },
            .state = .ready,
            .people = views[0..count],
        }, .{}, &writer)) |_| {
            target.responder.success(target.bridge_id.slice(), writer.buffered()) catch {};
            return;
        } else |_| {}
        if (count == 0) return respondPeopleState(target, .failed);
        count /= 2;
    }
}

fn respondSend(allocator: std.mem.Allocator, target: Reply, state: inbox.SendState, names: []const inbox.Name, conversation: ?inbox.ConversationRef) void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const sent = arena.allocator().alloc([]const u8, names.len) catch return target.responder.fail(target.bridge_id.slice(), .internal_error, "Inbox response encoding failed") catch {};
    for (names, sent) |*name, *view| view.* = name.slice();
    var writer: std.Io.Writer.Allocating = .init(arena.allocator());
    std.json.Stringify.value(inbox.SendResult{
        .binding = .{ .value = target.binding },
        .requestId = .{ .value = target.request_id },
        .state = state,
        .sent = sent,
        .conversation = conversation,
    }, .{}, &writer.writer) catch {
        target.responder.fail(target.bridge_id.slice(), .internal_error, "Inbox response encoding failed") catch {};
        return;
    };
    target.responder.success(target.bridge_id.slice(), writer.written()) catch {};
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
            .messages_marked_read_fn = messagesMarkedRead,
            .complete_poll_fn = completePoll,
            .request_refresh_fn = requestRefresh,
            .request_earlier_fn = requestEarlier,
            .begin_list_fn = beginList,
            .complete_list_fn = completeList,
            .knows_peer_fn = knowsPeer,
            .accepts_fn = accepts,
            .peer_address_fn = peerAddress,
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
    fn messagesMarkedRead(context: *anyopaque, binding: u64) void {
        of(context).messagesMarkedRead(binding);
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
    fn completeList(context: *anyopaque, now_ms: u64, id: u64, completion: inbox.ListCompletion) void {
        _ = of(context).completeList(now_ms, id, completion) catch unreachable;
    }
    fn knowsPeer(context: *anyopaque, binding: u64, peer: []const u8) bool {
        return of(context).knowsPeer(binding, peer);
    }
    fn accepts(context: *anyopaque, binding: u64) bool {
        return of(context).accepts(binding);
    }
    fn peerAddress(context: *anyopaque, binding: u64, peer: []const u8) ?inbox.Address {
        return of(context).peerAddress(binding, peer);
    }
    fn completeConversation(context: *anyopaque, binding: u64, peer: []const u8, kind: inbox.ConversationPageKind, messages: []const inbox.Message, username: ?inbox.Name) void {
        _ = of(context).completeConversation(binding, peer, kind, messages, username) catch unreachable;
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
    /// What a send is answered with; `null` drops it without an answer.
    send_status: ?u16 = 200,
    sends: usize = 0,
    send_body: [256]u8 = undefined,
    send_body_len: usize = 0,
    send_key: [64]u8 = undefined,
    send_key_len: usize = 0,
    unread: []const u8 = "{\"data\":{\"unread\":2,\"byPeer\":[{\"peer\":{\"id\":\"ann\",\"username\":\"ann_u\",\"name\":\"Ann\"},\"unread\":2}]}}",
    messages: []const u8 = "{\"data\":{\"messages\":[{\"id\":7,\"time\":1795428968292,\"direction\":\"in\",\"from\":{\"id\":\"ann\",\"name\":\"Ann\"},\"text\":\"hello\",\"taskIds\":[13066]}]}}",
    task: []const u8 = "{\"data\":{\"id\":13066,\"name\":\"Inbox\",\"progress\":\"doing\"}}",
    people: []const u8 = "{\"data\":{\"count\":4,\"people\":[{\"name\":\"Ann\",\"username\":\"ann_u\",\"online\":true,\"projects\":[\"metawork\"]},{\"name\":\"Bob\",\"username\":\"bob\",\"online\":false},{\"name\":\"Ann again\",\"username\":\"ann_u\"},{\"name\":\"No username\"}]}}",

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
        if (request == .send) {
            self.sends += 1;
            self.send_body_len = @min(request.send.body.len, self.send_body.len);
            @memcpy(self.send_body[0..self.send_body_len], request.send.body[0..self.send_body_len]);
            self.send_key_len = request.send.request_key.len;
            @memcpy(self.send_key[0..self.send_key_len], request.send.request_key);
            const status = self.send_status orelse return error.Network;
            if (status != 200) return .{ .status = status };
            const answer = "{\"data\":{\"sent\":[\"Ann\"]}}";
            @memcpy(output[0..answer.len], answer);
            return .{ .status = 200, .body_len = answer.len };
        }
        if (self.status != 200) return .{ .status = self.status };
        if (request == .task and self.task_status != 200) return .{ .status = self.task_status };
        if (request == .messages and self.peer_status != 200) return .{ .status = self.peer_status };
        if (request == .messages) if (request.messages.limit) |limit| if (limit > self.fits_limit) return error.ResponseTooLarge;
        const body = switch (request) {
            .unread => self.unread,
            .messages => self.messages,
            .task => self.task,
            .people => self.people,
            .send => unreachable,
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
    db: *@import("metawork_storage_sqlite").Database = undefined,

    fn init(self: *Fixture) void {
        self.initTarget(.memory) catch unreachable;
    }

    fn initTarget(self: *Fixture, target: @import("metawork_storage_sqlite").Target) !void {
        self.db = try @import("metawork_storage_sqlite").Database.create(testing.io, testing.allocator, target, &cache_store.migrations);
        self.coordinator = .{
            .allocator = testing.allocator,
            .io = testing.io,
            .management = self.management.management(),
            .database = self.db.capability(),
            .transport = self.transport.transport(),
            .retire_fn = noRetire,
            .retire_context = self,
            .source = self.source.source(),
            .host = self.host.host(),
        };
    }
    fn deinit(self: *Fixture) void {
        self.coordinator.shutdown();
        self.db.destroy() catch unreachable;
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

test "inbox coordinator: the local list reads no bodies; only the opened peer is fetched and oversized pages shrink" {
    var fixture: Fixture = .{ .host = .{ .main_thread = std.Thread.getCurrentId() } };
    fixture.init();
    defer fixture.deinit();
    fixture.coordinator.start(true);
    fixture.settle();
    const binding = fixture.view().binding.value;
    fixture.transport.fits_limit = 25;
    try testing.expectEqual(inbox.CommandOutcome.accepted, fixture.coordinator.refresh(binding, false));
    fixture.settle();
    try testing.expect(fixture.view().conversationsLoaded);
    try testing.expectEqualStrings("ann", fixture.view().conversations[0].peerId);
    try testing.expect(fixture.view().conversations[0].latest == null);
    try testing.expectEqual(@as(usize, 1), fixture.transport.count);

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
    try testing.expectEqualStrings("hello", fixture.view().conversations[0].latest.?.preview);
    try testing.expect(std.mem.endsWith(u8, fixture.transport.url(fixture.transport.count - 1), "messages?peer=ann&limit=25"));

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

test "inbox coordinator: only the opened peer is read, and their messages survive reopening the database" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    const dir = try temp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    const path = try std.fs.path.join(testing.allocator, &.{ dir, inbox.database_name });
    defer testing.allocator.free(path);
    const both =
        \\{"data":{"unread":2,"byPeer":[{"peer":{"id":"ann","username":"ann_u","name":"Ann"},"unread":1},{"peer":{"id":"bob","name":"Bob"},"unread":1}]}}
    ;
    const bob =
        \\{"data":{"unread":1,"byPeer":[{"peer":{"id":"bob","name":"Bob"},"unread":1}]}}
    ;
    {
        var f: Fixture = .{ .host = .{ .main_thread = std.Thread.getCurrentId() } };
        try f.initTarget(.{ .file = path });
        defer f.deinit();
        f.transport.unread = both;
        f.transport.messages =
            \\{"data":{"messages":[{"id":"7","time":7,"direction":"in","from":{"id":"ann","name":"Ann"},"text":"first","new":true}]}}
        ;
        f.coordinator.start(true);
        f.settle();
        const binding = f.view().binding.value;
        _ = f.coordinator.refresh(binding, false);
        f.settle();
        try testing.expectEqual(@as(usize, 1), f.transport.count);
        try testing.expectEqual(@as(usize, 2), f.view().conversations.len);
        f.transport.unread = bob; // Next unread response, after Ann's messages are fetched.
        try testing.expect(f.coordinator.readConversation(f.capture.responder(), "r", .{ .binding = binding, .request_id = 1, .peer = "ann", .kind = .latest, .anchor = null }));
        f.settle();
        try testing.expect(std.mem.endsWith(u8, f.transport.url(1), "/messages?peer=ann&limit=50"));
        try testing.expect(std.mem.indexOf(u8, f.capture.last(), "\"isNew\":true") != null);
        try testing.expectEqual(@as(u64, 1), f.view().unreadTotal.?.value);
        try testing.expectEqual(@as(usize, 3), f.transport.count);
        try testing.expect(std.mem.endsWith(u8, f.transport.url(2), "/open/v1/unread"));
    }
    var f: Fixture = .{ .host = .{ .main_thread = std.Thread.getCurrentId() } };
    try f.initTarget(.{ .file = path });
    defer f.deinit();
    f.transport.unread = bob;
    f.coordinator.start(true);
    f.settle();
    const binding = f.view().binding.value;
    _ = f.coordinator.refresh(binding, false);
    f.settle();
    try testing.expectEqual(@as(usize, 2), f.view().conversations.len);
    try testing.expectEqualStrings("ann_u", f.management.runtime.peerAddress(binding, "ann").?.member.slice());
    try testing.expect(f.coordinator.readConversation(f.capture.responder(), "r", .{ .binding = binding, .request_id = 1, .peer = "ann", .kind = .latest, .anchor = null }));
    f.settle();
    try testing.expectEqual(@as(usize, 1), f.transport.count);
    try testing.expect(std.mem.indexOf(u8, f.capture.last(), "\"text\":\"first\"") != null);
    try testing.expect(std.mem.indexOf(u8, f.capture.last(), "\"isNew\":true") != null);
    // Reading a previously saved message remotely can still display its
    // original mark. The remote response no longer consumes any unread items.
    f.transport.messages =
        \\{"data":{"messages":[{"id":"7","time":7,"direction":"in","from":{"id":"ann","name":"Ann"},"text":"first","new":false}]}}
    ;
    try testing.expect(f.coordinator.readConversation(f.capture.responder(), "reopen", .{ .binding = binding, .request_id = 2, .peer = "ann", .kind = .refresh, .anchor = null }));
    f.settle();
    try testing.expect(std.mem.indexOf(u8, f.capture.last(), "\"isNew\":true") != null);
    try testing.expectEqual(@as(usize, 2), f.transport.count);
    try testing.expect(std.mem.endsWith(u8, f.transport.url(1), "/messages?peer=ann&limit=50"));
    try testing.expect(!f.coordinator.readConversation(f.capture.responder(), "invalid", .{ .binding = binding, .request_id = 3, .peer = "ann", .kind = .refresh, .anchor = "7" }));
    try testing.expect(f.coordinator.readConversation(f.capture.responder(), "earlier", .{ .binding = binding, .request_id = 4, .peer = "ann", .kind = .before, .anchor = "8" }));
    f.settle();
    try testing.expect(std.mem.indexOf(u8, f.capture.last(), "\"isNew\":true") != null);
    try testing.expectEqual(@as(usize, 3), f.transport.count);
    try testing.expect(std.mem.endsWith(u8, f.transport.url(2), "/messages?peer=ann&beforeId=8&limit=50"));
    f.source.generation = 2;
    f.source.fingerprint = @splat('b');
    f.coordinator.drain();
    f.settle();
    _ = f.coordinator.refresh(f.view().binding.value, false);
    f.settle();
    try testing.expect(!f.management.runtime.knowsPeer(f.view().binding.value, "ann"));
}

test "a completed read is kept in the list when another peer supersedes its reply" {
    var f: Fixture = .{ .host = .{ .main_thread = std.Thread.getCurrentId() } };
    f.init();
    defer f.deinit();
    f.transport.unread =
        \\{"data":{"unread":2,"byPeer":[{"peer":{"id":"ann","name":"Ann"},"unread":1},{"peer":{"id":"bob","name":"Bob"},"unread":1}]}}
    ;
    f.coordinator.start(true);
    f.settle();
    const binding = f.view().binding.value;
    _ = f.coordinator.refresh(binding, false);
    f.settle();
    try testing.expect(f.coordinator.readConversation(f.capture.responder(), "a", .{ .binding = binding, .request_id = 1, .peer = "ann", .kind = .latest, .anchor = null }));
    f.coordinator.conversation.?.join();
    f.transport.messages =
        \\{"data":{"messages":[]}}
    ;
    try testing.expect(f.coordinator.readConversation(f.capture.responder(), "b", .{ .binding = binding, .request_id = 2, .peer = "bob", .kind = .latest, .anchor = null }));
    f.settle();
    f.transport.unread =
        \\{"data":{"unread":0,"byPeer":[]}}
    ;
    f.host.now_ms += inbox.Limits.poll_interval_ms;
    f.coordinator.onTimer();
    f.settle();
    try testing.expectEqual(@as(usize, 1), f.view().conversations.len);
    try testing.expectEqualStrings("ann", f.view().conversations[0].peerId);
    try testing.expectEqualStrings("hello", f.view().conversations[0].latest.?.preview);
}

test "inbox response protection recognizes a JSON-escaped device key" {
    try testing.expect(responseContainsKey(testing.allocator,
        \\{"text":"fi\u0078ture"}
    , "fixture"));
    try testing.expect(!responseContainsKey(testing.allocator,
        \\{"text":"ordinary\nmessage"}
    , "fixture"));
}

test "inbox history resumes at a same-millisecond gap after reopening and reconnects pages in service order" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    const dir = try temp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    var db = try cache_store.open(testing.io, testing.allocator, dir);
    var cache: cache_store.Store = .{ .db = db.capability(), .scope = @splat(1) };
    var db_open = true;
    defer if (db_open) db.destroy() catch unreachable;
    var first = try inbox.parseMessages(testing.allocator,
        \\{"data":{"messages":[{"id":"1","time":1,"direction":"in","from":{"id":"a"},"text":"original","new":true}]}}
    );
    defer first.deinit();
    try cache.save(testing.allocator, "a", null, .latest, null, &first, 50);
    var repeat = try inbox.parseMessages(testing.allocator,
        \\{"data":{"messages":[{"id":"1","time":1,"direction":"in","from":{"id":"a"},"text":"original","new":false}]}}
    );
    defer repeat.deinit();
    try cache.save(testing.allocator, "a", null, .before, try .init("3"), &repeat, 50);
    try testing.expect(repeat.items[0].is_new);
    var newer = try inbox.parseMessages(testing.allocator,
        \\{"data":{"messages":[{"id":"8","time":8,"direction":"in","from":{"id":"a"},"text":"later"},{"id":"9","time":8,"direction":"in","from":{"id":"a"},"text":"same millisecond"}]}}
    );
    defer newer.deinit();
    try cache.save(testing.allocator, "a", null, .after, try .init("1"), &newer, 2);
    try db.destroy();
    db_open = false;
    db = try cache_store.open(testing.io, testing.allocator, dir);
    db_open = true;
    cache.db = db.capability();
    var last = (try cache.latest(testing.allocator, "a")).?;
    defer last.page.deinit();
    try testing.expect(last.has_earlier);
    try testing.expectEqual(@as(usize, 2), last.page.items.len);
    try testing.expect(last.page.items[0].id.eql("8") and last.page.items[1].id.eql("9"));
    var missing = try inbox.parseMessages(testing.allocator,
        \\{"data":{"messages":[{"id":"z","time":8,"direction":"in","from":{"id":"a"},"text":"second"},{"id":"a","time":8,"direction":"in","from":{"id":"a"},"text":"third"}]}}
    );
    defer missing.deinit();
    try cache.save(testing.allocator, "a", null, .before, try .init("8"), &missing, 2);
    var partial = (try cache.latest(testing.allocator, "a")).?;
    defer partial.page.deinit();
    try testing.expect(partial.has_earlier);
    try testing.expectEqual(@as(usize, 4), partial.page.items.len);
    // Only this next response proves adjacency to the entry cached before the gap.
    try cache.save(testing.allocator, "a", null, .before, try .init("z"), &first, 2);
    var joined = (try cache.latest(testing.allocator, "a")).?;
    defer joined.page.deinit();
    try testing.expect(!joined.has_earlier);
    const ids = [_][]const u8{ "1", "z", "a", "8", "9" };
    try testing.expectEqual(ids.len, joined.page.items.len);
    for (ids, joined.page.items) |id, msg| try testing.expect(msg.id.eql(id));
}

test "inbox group messages share one receipt history but only materialize the queried peer timeline" {
    const db = try @import("metawork_storage_sqlite").Database.create(testing.io, testing.allocator, .memory, &cache_store.migrations);
    defer db.destroy() catch unreachable;
    const cache: cache_store.Store = .{ .db = db.capability(), .scope = @splat(1) };
    const group =
        \\{"id":"group","time":8,"direction":"out","from":{"id":"me"},"text":"same","recipients":[{"id":"a","readAt":null},{"id":"b","readAt":null}]}
    ;
    var ann = try inbox.parseMessages(testing.allocator, "{\"data\":{\"messages\":[" ++ group ++ "]}}");
    defer ann.deinit();
    try cache.save(testing.allocator, "a", null, .latest, null, &ann, 50);
    try testing.expect(try cache.latest(testing.allocator, "b") == null);
    const bob_json =
        \\{"data":{"messages":[{"id":"private","time":8,"direction":"in","from":{"id":"b"},"text":"same","new":true},
        \\{"id":"group","time":8,"direction":"out","from":{"id":"me"},"text":"same","recipients":[{"id":"a","readAt":21},{"id":"b","readAt":null}]}]}}
    ;
    var bob = try inbox.parseMessages(testing.allocator, bob_json);
    defer bob.deinit();
    try cache.save(testing.allocator, "b", null, .latest, null, &bob, 50);
    // A stale null must not undo the positive receipt from the other timeline.
    try cache.save(testing.allocator, "a", null, .refresh, null, &ann, 50);
    try testing.expectEqual(@as(?u64, 21), ann.items[0].recipients[0].read_at_ms);
    var saved = (try cache.latest(testing.allocator, "b")).?;
    defer saved.page.deinit();
    try testing.expectEqual(@as(usize, 2), saved.page.items.len);
    try testing.expect(saved.page.items[0].id.eql("private") and saved.page.items[0].is_new);
    try testing.expect(saved.page.items[1].id.eql("group") and !saved.page.items[1].recipients[1].read);
    const sql = @import("metawork_storage_sql");
    const Counts = struct {
        values: [3]i64 = @splat(0),
        fn receive(raw: *anyopaque, row: sql.Row) void {
            const counts: *@This() = @ptrCast(@alignCast(raw));
            for (&counts.values, 0..) |*value, i| value.* = row.value(i).integer;
        }
    };
    var counts: Counts = .{};
    try testing.expectEqual(.ok, cache.db.query("SELECT (SELECT count(*) FROM conversations),(SELECT count(*) FROM messages),(SELECT count(*) FROM conversation_messages)", &.{}, .{ .context = &counts, .receive_fn = Counts.receive }));
    try testing.expectEqual([3]i64{ 2, 2, 3 }, counts.values);
    const another: cache_store.Store = .{ .db = db.capability(), .scope = @splat(2) };
    try testing.expect(try another.latest(testing.allocator, "b") == null);
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

test "inbox coordinator: an empty local list and repeated refreshes do not read any conversation" {
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
    try testing.expectEqual(@as(usize, 1), fixture.transport.count);
    try testing.expect(std.mem.endsWith(u8, fixture.transport.url(0), "/unread"));
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

test "inbox coordinator: a reply goes to the member's username once per user action, and a retry reuses its request key" {
    var fixture: Fixture = .{ .host = .{ .main_thread = std.Thread.getCurrentId() } };
    fixture.init();
    defer fixture.deinit();
    fixture.coordinator.start(true);
    fixture.settle();
    const binding = fixture.view().binding.value;
    const responder = fixture.capture.responder();
    const key_a = "11111111-2222-4333-8444-555555555555";
    try testing.expect(fixture.coordinator.sendMessage(responder, "s1", .{ .binding = binding, .request_id = 1, .to = .{ .peer = "ann" }, .text = "On it \"now\"", .request_key = key_a }));
    fixture.settle();
    try testing.expect(std.mem.indexOf(u8, fixture.capture.last(), "\"requestId\":\"1\",\"state\":\"sent\",\"sent\":[\"Ann\"],\"conversation\":null}") != null);
    try testing.expectEqualStrings("{\"to\":[\"ann_u\"],\"text\":\"On it \\\"now\\\"\"}", fixture.transport.send_body[0..fixture.transport.send_body_len]);
    try testing.expectEqualStrings(key_a, fixture.transport.send_key[0..fixture.transport.send_key_len]);
    try testing.expectEqualStrings("http://192.0.2.10:8080/team/agent/v1/notify", fixture.transport.url(fixture.transport.count - 1));

    // The user's own conversation goes to `me`.
    try testing.expect(fixture.coordinator.sendMessage(responder, "s2", .{ .binding = binding, .request_id = 2, .to = .{ .peer = inbox.self_peer_id }, .text = "note", .request_key = "22222222-2222-4333-8444-555555555555" }));
    fixture.settle();
    try testing.expectEqualStrings("{\"to\":\"me\",\"text\":\"note\"}", fixture.transport.send_body[0..fixture.transport.send_body_len]);

    // No answer, then the user's retry: one request each, the same key.
    fixture.transport.send_status = null;
    const sends = fixture.transport.sends;
    const key_b = "33333333-2222-4333-8444-555555555555";
    try testing.expect(fixture.coordinator.sendMessage(responder, "s3", .{ .binding = binding, .request_id = 3, .to = .{ .peer = "ann" }, .text = "again", .request_key = key_b }));
    fixture.settle();
    try testing.expect(std.mem.indexOf(u8, fixture.capture.last(), "\"state\":\"failed\"") != null);
    try testing.expectEqual(sends + 1, fixture.transport.sends);
    fixture.transport.send_status = 200;
    try testing.expect(fixture.coordinator.sendMessage(responder, "s4", .{ .binding = binding, .request_id = 4, .to = .{ .peer = "ann" }, .text = "again", .request_key = key_b }));
    fixture.settle();
    try testing.expect(std.mem.indexOf(u8, fixture.capture.last(), "\"state\":\"sent\"") != null);
    try testing.expectEqual(sends + 2, fixture.transport.sends);
    try testing.expectEqualStrings(key_b, fixture.transport.send_key[0..fixture.transport.send_key_len]);

    // A refusal is that message's outcome only.
    for ([_]struct { u16, []const u8 }{ .{ 400, "rejected" }, .{ 403, "forbidden" }, .{ 401, "forbidden" }, .{ 404, "not_found" }, .{ 503, "failed" } }) |case| {
        fixture.transport.send_status = case[0];
        try testing.expect(fixture.coordinator.sendMessage(responder, "s5", .{ .binding = binding, .request_id = 5, .to = .{ .peer = "ann" }, .text = "x", .request_key = "44444444-2222-4333-8444-555555555555" }));
        fixture.settle();
        var expected: [64]u8 = undefined;
        try testing.expect(std.mem.indexOf(u8, fixture.capture.last(), try std.fmt.bufPrint(&expected, "\"state\":\"{s}\"", .{case[1]})) != null);
        try testing.expectEqual(inbox.State.ready, fixture.view().state);
        try testing.expect(fixture.management.runtime.nextPoll() != null);
    }
    fixture.transport.send_status = 200;

    // Nothing is sent without an address, text or a usable request key.
    const before = fixture.transport.sends;
    try testing.expect(fixture.coordinator.sendMessage(responder, "s6", .{ .binding = binding, .request_id = 6, .to = .{ .peer = "nobody" }, .text = "x", .request_key = key_a }));
    try testing.expect(std.mem.indexOf(u8, fixture.capture.last(), "\"state\":\"unknown_peer\"") != null);
    try testing.expect(fixture.coordinator.sendMessage(responder, "s7", .{ .binding = binding + 1, .request_id = 7, .to = .{ .peer = "ann" }, .text = "x", .request_key = key_a }));
    try testing.expect(std.mem.indexOf(u8, fixture.capture.last(), "\"state\":\"stale_binding\"") != null);
    try testing.expect(!fixture.coordinator.sendMessage(responder, "s8", .{ .binding = binding, .request_id = 8, .to = .{ .peer = "ann" }, .text = " \n ", .request_key = key_a }));
    try testing.expect(!fixture.coordinator.sendMessage(responder, "s9", .{ .binding = binding, .request_id = 9, .to = .{ .peer = "ann" }, .text = "x", .request_key = "bad\r\nkey-value" }));
    fixture.settle();
    try testing.expectEqual(before, fixture.transport.sends);
    for (fixture.capture.responses.items) |response| {
        try testing.expect(std.mem.indexOf(u8, response, sentinel_key) == null);
        try testing.expect(std.mem.indexOf(u8, response, "192.0.2.10") == null);
    }
}

test "inbox directory opens existing remote history before a first local send, then reopens it by id" {
    var f: Fixture = .{ .host = .{ .main_thread = std.Thread.getCurrentId() } };
    f.init();
    defer f.deinit();
    f.transport.unread = "{\"data\":{\"unread\":0,\"byPeer\":[]}}";
    f.transport.messages =
        \\{"data":{"messages":[{"id":"5","time":123,"direction":"in","from":{"id":"u2","username":"bob","name":"Bob"},"text":"earlier"}]}}
    ;
    f.coordinator.start(true);
    f.settle();
    const binding = f.view().binding.value;
    const responder = f.capture.responder();
    try testing.expect(f.coordinator.listPeople(responder, "people", .{ .binding = binding, .request_id = 1 }));
    f.settle();
    try testing.expectEqual(@as(usize, 0), f.view().conversations.len);
    const before = f.transport.count;
    try testing.expect(f.coordinator.readConversation(responder, "member", .{ .binding = binding, .request_id = 2, .peer = "bob", .by_username = true, .kind = .latest, .anchor = null }));
    f.settle();
    try testing.expectEqual(before + 1, f.transport.count);
    try testing.expect(std.mem.indexOf(u8, f.transport.url(before), "messages?peer=bob&") != null);
    try testing.expect(std.mem.indexOf(u8, f.capture.last(), "\"peerId\":\"u2\",\"messages\":[{") != null);
    try testing.expectEqualStrings("bob", f.view().conversations[0].username.?);
    try testing.expectEqualStrings("u2", f.view().conversations[0].peerId);
    try testing.expect(f.coordinator.readConversation(responder, "reopen", .{ .binding = binding, .request_id = 3, .peer = "u2", .kind = .latest, .anchor = null }));
    f.settle();
    try testing.expectEqual(before + 1, f.transport.count);
    try testing.expect(std.mem.indexOf(u8, f.capture.last(), "\"text\":\"earlier\"") != null);
    try testing.expectEqual(@as(usize, 0), f.transport.sends);
}

test "inbox coordinator: members are listed on request, and a message to one starts a conversation in the list" {
    var fixture: Fixture = .{ .host = .{ .main_thread = std.Thread.getCurrentId() } };
    fixture.init();
    defer fixture.deinit();
    fixture.coordinator.start(true);
    fixture.settle();
    const binding = fixture.view().binding.value;
    const responder = fixture.capture.responder();
    try testing.expect(fixture.coordinator.listPeople(responder, "p1", .{ .binding = binding, .request_id = 1 }));
    fixture.settle();
    const people = fixture.capture.last();
    try testing.expect(std.mem.indexOf(u8, people, "\"people\":[{\"username\":\"ann_u\",\"name\":\"Ann\",\"online\":true},{\"username\":\"bob\",\"name\":\"Bob\",\"online\":false}]") != null);
    try testing.expectEqualStrings("http://192.0.2.10:8080/team/agent/v1/people", fixture.transport.url(fixture.transport.count - 1));
    try testing.expect(fixture.coordinator.listPeople(responder, "p2", .{ .binding = binding + 1, .request_id = 2 }));
    try testing.expect(std.mem.indexOf(u8, fixture.capture.last(), "\"state\":\"stale_binding\"") != null);

    // Listing/searching members reads no bodies. Only an explicit, known
    // username may open a timeline before there is a canonical peer id.
    const before = fixture.transport.count;
    const first: ConversationRequest = .{ .binding = binding, .request_id = 8, .peer = "bob", .by_username = true, .kind = .latest, .anchor = null };
    var unknown = first;
    unknown.peer = "outsider";
    try testing.expect(fixture.coordinator.readConversation(responder, "unknown", unknown));
    try testing.expect(std.mem.indexOf(u8, fixture.capture.last(), "\"unknown_peer\"") != null);
    try testing.expectEqual(before, fixture.transport.count);
    fixture.transport.messages = "{\"data\":{\"messages\":[]}}";
    try testing.expect(fixture.coordinator.readConversation(responder, "empty", first));
    fixture.settle();
    try testing.expectEqual(before + 1, fixture.transport.count);
    try testing.expect(std.mem.indexOf(u8, fixture.transport.url(before), "messages?peer=bob&") != null);
    try testing.expect(std.mem.indexOf(u8, fixture.capture.last(), "\"messages\":[]") != null);
    try testing.expect(!fixture.management.runtime.knowsPeer(binding, "bob"));

    // Bob has no conversation yet. Once sent, MetaTeam's newest message with
    // him says which conversation it is, and the list has it.
    fixture.transport.messages = "{\"data\":{\"messages\":[{\"id\":40,\"time\":1795428968292,\"direction\":\"out\",\"from\":{\"id\":\"u-me\",\"username\":\"me_u\",\"name\":\"Me\"},\"recipients\":[{\"id\":\"bob-id\",\"username\":\"Bob\",\"name\":\"Bob\",\"readAt\":null}],\"text\":\"Hello Bob\",\"taskIds\":[]}]}}";
    try testing.expect(!fixture.management.runtime.knowsPeer(binding, "bob-id"));
    try testing.expect(fixture.coordinator.sendMessage(responder, "s1", .{ .binding = binding, .request_id = 3, .to = .{ .username = "bob" }, .text = "Hello Bob", .request_key = "11111111-2222-4333-8444-555555555555" }));
    fixture.settle();
    try testing.expectEqualStrings("{\"to\":[\"bob\"],\"text\":\"Hello Bob\"}", fixture.transport.send_body[0..fixture.transport.send_body_len]);
    try testing.expectEqualStrings("http://192.0.2.10:8080/team/open/v1/messages?peer=bob&limit=1", fixture.transport.url(fixture.transport.count - 1));
    try testing.expect(std.mem.indexOf(u8, fixture.capture.last(), "\"state\":\"sent\",\"sent\":[\"Ann\"],\"conversation\":{\"peerId\":\"bob-id\",\"name\":\"Bob\"}") != null);
    try testing.expect(fixture.management.runtime.knowsPeer(binding, "bob-id"));
    try testing.expectEqualStrings("Bob", fixture.management.runtime.peerAddress(binding, "bob-id").?.member.slice());
    var listed = false;
    for (fixture.view().conversations) |row| {
        if (std.mem.eql(u8, row.peerId, "bob-id")) listed = std.mem.eql(u8, row.latest.?.preview, "Hello Bob");
    }
    try testing.expect(listed);

    try testing.expect(fixture.coordinator.readConversation(responder, "history", first));
    fixture.settle();
    try testing.expect(std.mem.indexOf(u8, fixture.capture.last(), "\"peerId\":\"bob-id\",\"messages\":[{") != null);
    const rows = fixture.view().conversations;
    for (rows) |row| {
        try testing.expect(!std.mem.eql(u8, row.peerId, "bob"));
        if (std.mem.eql(u8, row.peerId, "bob-id"))
            try testing.expectEqualStrings("Bob", row.username.?);
    }

    // An unresolved recipient never triggers a cross-peer read.
    fixture.transport.messages = "{\"data\":{\"messages\":[]}}";
    try testing.expect(fixture.coordinator.sendMessage(responder, "s2", .{ .binding = binding, .request_id = 4, .to = .{ .username = "cy" }, .text = "Hi", .request_key = "22222222-2222-4333-8444-555555555555" }));
    fixture.settle();
    try testing.expect(std.mem.indexOf(u8, fixture.capture.last(), "\"state\":\"sent\",\"sent\":[\"Ann\"],\"conversation\":null") != null);
    var refreshed = false;
    for (0..fixture.transport.count) |index| {
        if (std.mem.endsWith(u8, fixture.transport.url(index), "messages?afterId=40&limit=200") or
            std.mem.endsWith(u8, fixture.transport.url(index), "messages?limit=200")) refreshed = true;
    }
    try testing.expect(!refreshed);
    // A username that could not be an address is refused before anything is sent.
    try testing.expect(!fixture.coordinator.sendMessage(responder, "s3", .{ .binding = binding, .request_id = 5, .to = .{ .username = "" }, .text = "Hi", .request_key = "33333333-2222-4333-8444-555555555555" }));
    for (fixture.capture.responses.items) |response| try testing.expect(std.mem.indexOf(u8, response, sentinel_key) == null);
}

test "inbox coordinator: closing answers a send once, with what MetaTeam said or failed without an answer" {
    for ([_]struct { ?u16, []const u8 }{ .{ 200, "sent" }, .{ 400, "rejected" }, .{ null, "failed" } }) |case| {
        var fixture: Fixture = .{ .host = .{ .main_thread = std.Thread.getCurrentId() } };
        fixture.init();
        defer fixture.deinit();
        fixture.coordinator.start(true);
        fixture.settle();
        const binding = fixture.view().binding.value;
        const responder = fixture.capture.responder();
        fixture.transport.send_status = case[0];
        try testing.expect(fixture.coordinator.sendMessage(responder, "s1", .{ .binding = binding, .request_id = 1, .to = .{ .peer = "ann" }, .text = "x", .request_key = "11111111-2222-4333-8444-555555555555" }));
        // Answered by MetaTeam, not yet delivered when the app closes.
        fixture.coordinator.send.?.join();
        const before = fixture.capture.responses.items.len;
        fixture.coordinator.shutdown();
        try testing.expect(fixture.coordinator.send == null);
        try testing.expectEqual(before + 1, fixture.capture.responses.items.len);
        var expected: [64]u8 = undefined;
        try testing.expect(std.mem.indexOf(u8, fixture.capture.last(), try std.fmt.bufPrint(&expected, "\"requestId\":\"1\",\"state\":\"{s}\"", .{case[1]})) != null);
    }
}

test "inbox coordinator: one message at a time, and a changed connection never cancels one in flight" {
    var fixture: Fixture = .{ .host = .{ .main_thread = std.Thread.getCurrentId() } };
    fixture.init();
    defer fixture.deinit();
    fixture.coordinator.start(true);
    fixture.settle();
    const binding = fixture.view().binding.value;
    const responder = fixture.capture.responder();
    fixture.transport.block.store(true, .release);
    try testing.expect(fixture.coordinator.sendMessage(responder, "s1", .{ .binding = binding, .request_id = 1, .to = .{ .peer = "ann" }, .text = "first", .request_key = "11111111-2222-4333-8444-555555555555" }));
    const job = fixture.coordinator.send.?;
    try testing.expect(fixture.coordinator.sendMessage(responder, "s2", .{ .binding = binding, .request_id = 2, .to = .{ .peer = "ann" }, .text = "second", .request_key = "22222222-2222-4333-8444-555555555555" }));
    try testing.expect(std.mem.indexOf(u8, fixture.capture.last(), "\"state\":\"busy\"") != null);
    // The connection is replaced while the message is on its way.
    fixture.source.fingerprint = @splat('b');
    fixture.source.generation = 2;
    fixture.coordinator.drain();
    try testing.expect(fixture.view().binding.value != binding);
    try testing.expectEqual(@as(u32, 0), job.cancellation.state.load(.acquire));
    fixture.transport.block.store(false, .release);
    fixture.settle();
    try testing.expect(std.mem.indexOf(u8, fixture.capture.last(), "\"requestId\":\"1\",\"state\":\"sent\"") != null);
    try testing.expectEqual(@as(usize, 1), fixture.transport.sends);

    // A closed Bridge connection answers it at once; the send still finishes.
    const now = fixture.view().binding.value;
    fixture.settle();
    fixture.transport.block.store(true, .release);
    try testing.expect(fixture.coordinator.sendMessage(responder, "s3", .{ .binding = now, .request_id = 3, .to = .{ .peer = "ann" }, .text = "third", .request_key = "33333333-2222-4333-8444-555555555555" }));
    fixture.coordinator.cancelReads();
    try testing.expect(std.mem.indexOf(u8, fixture.capture.last(), "\"requestId\":\"3\",\"state\":\"superseded\"") != null);
    const answers = fixture.capture.responses.items.len;
    fixture.transport.block.store(false, .release);
    fixture.settle();
    try testing.expectEqual(answers, fixture.capture.responses.items.len);
    try testing.expectEqual(@as(usize, 2), fixture.transport.sends);
}

/// A local stand-in for MetaTeam over real HTTP: the open API, members and
/// notify with MetaTeam's request-key deduplication. The first new message
/// is taken and its answer lost, as when a connection drops.
const FakeMetaTeam = struct {
    listener: *std.Io.net.Server,
    stop: std.atomic.Value(bool) = .init(false),
    failure: ?anyerror = null,
    refused: usize = 0,
    posts: usize = 0,
    delivered: usize = 0,
    replayed: usize = 0,
    lose_first_answer: bool = true,
    keys: [8][64]u8 = undefined,
    key_lens: [8]usize = @splat(0),
    key_count: usize = 0,

    ann_read: bool = false,
    bob_read: bool = false,
    const ann_unread = "{\"peer\":{\"id\":\"ann-id\",\"username\":\"ann_u\",\"name\":\"Ann\"},\"unread\":1,\"lastAt\":1795428968292}";
    const bob_unread = "{\"peer\":{\"id\":\"bob-id\",\"username\":\"bob\",\"name\":\"Bob\"},\"unread\":1}";
    fn unreadBody(self: *const FakeMetaTeam) []const u8 {
        if (self.ann_read and self.bob_read) return "{\"data\":{\"unread\":0,\"byPeer\":[]}}";
        if (self.ann_read) return "{\"data\":{\"unread\":1,\"byPeer\":[" ++ bob_unread ++ "]}}";
        if (self.bob_read) return "{\"data\":{\"unread\":1,\"byPeer\":[" ++ ann_unread ++ "]}}";
        return "{\"data\":{\"unread\":2,\"byPeer\":[" ++ ann_unread ++ "," ++ bob_unread ++ "]}}";
    }
    const ann_message =
        \\{"data":{"messages":[{"id":"m2","time":"2026-11-23T08:16:08.292Z","direction":"in","from":{"id":"ann-id","username":"ann_u","name":"Ann"},"text":"see the file","taskIds":[9830],"new":true}]}}
    ;
    const file_body = "{\"data\":{\"id\":9830,\"name\":\"api.md\",\"tag\":\"API\",\"size\":7,\"mime\":\"text/markdown\",\"by\":\"Lin\",\"content\":\"# Title\",\"downloadUrl\":\"http://127.0.0.1:1/agent/v1/files/9830/dl?exp=1&sig=ab\",\"webUrl\":\"http://127.0.0.1:1/api/v1/files/9830/content\"}}";
    const people_body = "{\"data\":{\"count\":2,\"people\":[{\"name\":\"Ann\",\"username\":\"ann_u\",\"online\":true},{\"name\":\"Bob\",\"username\":\"bob\"}]}}";
    const sent_body = "{\"data\":{\"sent\":[\"Ann\"]}}";

    fn run(self: *FakeMetaTeam) void {
        while (!self.stop.load(.acquire)) self.serve() catch |err| {
            if (!self.stop.load(.acquire)) self.failure = err;
        };
    }

    fn serve(self: *FakeMetaTeam) !void {
        var connection = try self.listener.accept(testing.io);
        defer connection.close(testing.io);
        if (self.stop.load(.acquire)) return;
        var reads: [8192]u8 = undefined;
        var writes: [8192]u8 = undefined;
        var reader = connection.reader(testing.io, &reads);
        var writer = connection.writer(testing.io, &writes);
        var server: std.http.Server = .init(&reader.interface, &writer.interface);
        var request = try server.receiveHead();
        var authorized = false;
        var request_key: []const u8 = "";
        var headers = request.iterateHeaders();
        while (headers.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "Authorization")) authorized = std.mem.eql(u8, header.value, "Bearer " ++ sentinel_key);
            if (std.ascii.eqlIgnoreCase(header.name, "X-Request-Id")) request_key = header.value;
        }
        const target = request.head.target;
        if (!authorized) {
            self.refused += 1;
            return request.respond("{\"error\":{\"code\":\"401\",\"message\":\"no\"}}", .{ .status = .unauthorized, .keep_alive = false });
        }
        var key_copy: [64]u8 = undefined;
        const key = key_copy[0..@min(request_key.len, key_copy.len)];
        @memcpy(key, request_key[0..key.len]);
        if (request.head.method == .POST and std.mem.eql(u8, target, "/team/agent/v1/notify")) {
            var body: [512]u8 = undefined;
            const length: usize = @min(@as(usize, @intCast(request.head.content_length orelse 0)), body.len);
            var body_buffer: [64]u8 = undefined;
            try request.readerExpectNone(&body_buffer).readSliceAll(body[0..length]);
            self.posts += 1;
            for (self.keys[0..self.key_count], self.key_lens[0..self.key_count]) |*seen, seen_len| {
                if (std.mem.eql(u8, seen[0..seen_len], key)) {
                    self.replayed += 1;
                    return request.respond(sent_body, .{ .keep_alive = false });
                }
            }
            @memcpy(self.keys[self.key_count][0..key.len], key);
            self.key_lens[self.key_count] = key.len;
            self.key_count += 1;
            self.delivered += 1;
            if (self.lose_first_answer) {
                self.lose_first_answer = false;
                return; // Taken, but the answer never arrives.
            }
            return request.respond(sent_body, .{ .keep_alive = false });
        }
        const body: []const u8 = if (std.mem.eql(u8, target, "/team/open/v1/unread"))
            self.unreadBody()
        else if (std.mem.eql(u8, target, "/team/open/v1/messages?peer=ann-id&limit=50")) read: {
            self.ann_read = true;
            break :read ann_message;
        } else if (std.mem.eql(u8, target, "/team/open/v1/messages?peer=bob-id&limit=50")) read: {
            self.bob_read = true;
            break :read
            \\{"data":{"messages":[{"id":"m3","time":1795428968292,"direction":"in","from":{"id":"bob-id","username":"bob","name":"Bob"},"text":"hello","new":true}]}}
            ;
        } else if (std.mem.eql(u8, target, "/team/open/v1/tasks/9830"))
            file_body
        else if (std.mem.eql(u8, target, "/team/agent/v1/people"))
            people_body
        else
            return request.respond("{\"error\":{\"code\":\"404\",\"message\":\"no\"}}", .{ .status = .not_found, .keep_alive = false });
        try request.respond(body, .{ .keep_alive = false });
    }

    fn shutdown(self: *FakeMetaTeam, port: u16) void {
        self.stop.store(true, .release);
        const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
        var stream = address.connect(testing.io, .{ .mode = .stream }) catch return;
        stream.close(testing.io);
    }
};

test "inbox coordinator: against a local MetaTeam over real HTTP, with the key read from the credential store" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{ .async_limit = .nothing });
    defer threaded.deinit();
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = try address.listen(testing.io, .{ .kernel_backlog = 8 });
    defer listener.deinit(testing.io);
    const port = listener.socket.address.getPort();
    var service: FakeMetaTeam = .{ .listener = &listener };
    const thread = try std.Thread.spawn(.{}, FakeMetaTeam.run, .{&service});
    defer {
        service.shutdown(port);
        thread.join();
    }

    // The production path: a sensitive endpoint in the credential store,
    // resolved by the MCP source into a base and a key.
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{});
    defer harness.destroy(testing.allocator);
    var store: mcp_platform.CredentialStore = .{ .io = testing.io, .runtime = &harness.runtime, .main_thread_id = std.Thread.getCurrentId() };
    const locator = "mcp/endpoint-1";
    var origin_buffer: [64]u8 = undefined;
    const origin = try std.fmt.bufPrint(&origin_buffer, "http://127.0.0.1:{d}", .{port});
    var url_buffer: [160]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buffer, "{s}/team/agent/v1/mcp/k/{s}", .{ origin, sentinel_key });
    const effects = store.effects();
    try testing.expect(effects.create_fn(effects.context, locator, url));
    var server: mcp_configuration.ServerWire = .{
        .id = "server-1",
        .namespace = "metateam",
        .display_name = "MetaTeam",
        .enabled = true,
        .negotiation = "automatic",
        .timeout_ms = 30_000,
        .transport = .{ .kind = "streamable_http", .sensitive_endpoint = .{ .origin = origin, .identity = locator, .credential_refs = &.{locator} } },
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
        fn write(context: *anyopaque, _: u64, output: []u8) anyerror![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            @memcpy(output[0..self.bytes.len], self.bytes);
            return output[0..self.bytes.len];
        }
    };
    var port_state: Port = .{ .bytes = bytes };
    var management_port: control_ports.McpManagementPort = undefined;
    management_port.context = &port_state;
    management_port.inspect_fn = Port.inspect;
    management_port.write_desired_fn = Port.write;
    var mcp: McpSource = .{ .port = management_port, .credential_store = &store };

    var engine: @import("metawork_http_transport").Engine = undefined;
    engine.init(testing.allocator, threaded.io());
    defer engine.deinit();
    var adapter: http.Adapter = .{ .http = &engine };
    var management: TestManagement = .{ .runtime = .init(testing.allocator) };
    defer management.runtime.deinit();
    var host: TestHost = .{ .main_thread = std.Thread.getCurrentId() };
    var capture: Capture = .{};
    defer capture.deinit();
    const local_db = try @import("metawork_storage_sqlite").Database.create(testing.io, testing.allocator, .memory, &cache_store.migrations);
    defer local_db.destroy() catch unreachable;
    var coordinator: Coordinator = .{
        .database = local_db.capability(),
        .allocator = testing.allocator,
        .io = testing.io,
        .management = management.management(),
        .transport = adapter.transport(),
        .retire_fn = http.Adapter.retire,
        .retire_context = &adapter,
        .source = mcp.source(),
        .host = host.host(),
    };
    defer coordinator.shutdown();
    const settle = struct {
        fn run(value: *Coordinator) void {
            for (0..16) |_| {
                inline for (Coordinator.slots) |name| if (@field(value, name)) |job| job.join();
                value.drain();
                if (!value.running()) return;
            }
        }
    }.run;

    coordinator.start(true);
    settle(&coordinator);
    try testing.expectEqual(inbox.State.ready, management.runtime.view().state);
    const binding = management.runtime.view().binding.value;
    try testing.expectEqual(inbox.CommandOutcome.accepted, coordinator.refresh(binding, false));
    settle(&coordinator);
    try testing.expectEqual(@as(u64, 2), management.runtime.view().unreadTotal.?.value);
    try testing.expectEqual(@as(usize, 2), management.runtime.view().conversations.len);
    try testing.expectEqualStrings("ann-id", management.runtime.view().conversations[0].peerId);
    try testing.expect(management.runtime.view().conversations[0].latest == null);

    const responder = capture.responder();
    try testing.expect(coordinator.readConversation(responder, "read", .{ .binding = binding, .request_id = 9, .peer = "ann-id", .kind = .latest, .anchor = null }));
    settle(&coordinator);
    try testing.expect(std.mem.indexOf(u8, capture.last(), "\"isNew\":true") != null);
    try testing.expectEqual(@as(u64, 1), management.runtime.view().unreadTotal.?.value);
    for (management.runtime.view().conversations) |row| {
        if (std.mem.eql(u8, row.peerId, "ann-id")) try testing.expectEqual(@as(u64, 0), row.unread.value);
        if (std.mem.eql(u8, row.peerId, "bob-id")) try testing.expectEqual(@as(u64, 1), row.unread.value);
    }
    try testing.expect(coordinator.readConversation(responder, "read-bob", .{ .binding = binding, .request_id = 10, .peer = "bob-id", .kind = .latest, .anchor = null }));
    settle(&coordinator);
    try testing.expectEqual(@as(u64, 0), management.runtime.view().unreadTotal.?.value);
    for (management.runtime.view().conversations) |row| try testing.expectEqual(@as(u64, 0), row.unread.value);
    const key = "0b6f7c2e-7d1a-4c55-9f0e-2a4b6c8d0e1f";
    try testing.expect(coordinator.sendMessage(responder, "s1", .{ .binding = binding, .request_id = 1, .to = .{ .peer = "ann-id" }, .text = "On it", .request_key = key }));
    settle(&coordinator);
    try testing.expect(std.mem.indexOf(u8, capture.last(), "\"state\":\"failed\"") != null);
    // The user's retry: the same request key, so MetaTeam takes it once.
    try testing.expect(coordinator.sendMessage(responder, "s2", .{ .binding = binding, .request_id = 2, .to = .{ .peer = "ann-id" }, .text = "On it", .request_key = key }));
    settle(&coordinator);
    try testing.expect(std.mem.indexOf(u8, capture.last(), "\"state\":\"sent\",\"sent\":[\"Ann\"]") != null);
    try testing.expectEqual(@as(usize, 2), service.posts);
    try testing.expectEqual(@as(usize, 1), service.delivered);
    try testing.expectEqual(@as(usize, 1), service.replayed);

    try testing.expect(coordinator.listPeople(responder, "p1", .{ .binding = binding, .request_id = 3 }));
    settle(&coordinator);
    try testing.expect(std.mem.indexOf(u8, capture.last(), "{\"username\":\"bob\",\"name\":\"Bob\",\"online\":null}") != null);
    try testing.expect(coordinator.readTask(responder, "t1", .{ .binding = binding, .request_id = 4, .task = "9830" }));
    settle(&coordinator);
    try testing.expect(std.mem.indexOf(u8, capture.last(), "\"content\":\"# Title\"") != null);
    try testing.expect(coordinator.openFile(responder, "f1", .{ .binding = binding, .request_id = 5, .file = "9830" }));
    settle(&coordinator);
    try testing.expect(std.mem.indexOf(u8, capture.last(), "\"state\":\"opened\"") != null);
    try testing.expectEqualStrings("http://127.0.0.1:1/agent/v1/files/9830/dl?exp=1&sig=ab", host.opened[0..host.opened_len]);

    try testing.expectEqual(@as(?anyerror, null), service.failure);
    try testing.expectEqual(@as(usize, 0), service.refused);
    // The key reached MetaTeam only as a header: never a Renderer answer,
    // the snapshot, a download address or the address of a request.
    var snapshot: [16 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&snapshot);
    try std.json.Stringify.value(management.runtime.view(), .{}, &writer);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), sentinel_key) == null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "127.0.0.1") == null);
    for (capture.responses.items) |response| {
        try testing.expect(std.mem.indexOf(u8, response, sentinel_key) == null);
        try testing.expect(std.mem.indexOf(u8, response, "127.0.0.1") == null);
        try testing.expect(std.mem.indexOf(u8, response, "sig=") == null);
    }
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
            var expected = std.crypto.hash.sha2.Sha256.init(.{});
            expected.update(&fingerprint);
            expected.update(sentinel_key);
            try testing.expectEqualSlices(u8, &std.fmt.bytesToHex(expected.finalResult(), .lower), &found.fingerprint);
        },
        else => return error.TestUnexpectedResult,
    }
    // A disabled connection is not MetaTeam for the inbox.
    servers[0].enabled = false;
    port_state.bytes = try mcp_configuration.encode(&storage, .{ .schema_version = mcp_configuration.schema_version, .generation = 1, .oauth_operation = null, .servers = &servers }, mcp_startup.configuration_limits);
    result = source.find_fn(source.context, testing.allocator, 1);
    try testing.expect(result == .none);
}
