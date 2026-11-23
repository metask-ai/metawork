//! Product-owned MetaTeam inbox facts and policy. The inbox reads MetaTeam
//! messages with the device authorization of the installed MetaTeam MCP
//! connection. Application resolves that authorization and runs the timer,
//! workers and HTTP; this aggregate owns which connection is MetaTeam, the
//! connection state, the unread facts, the conversation summaries and when to
//! ask again. It never holds the device key, and nothing here is persisted.
const std = @import("std");
const http = @import("metawork_http_contract");
const update = @import("metawork_product_update");

pub const Limits = struct {
    /// Response bodies are parsed whole. These bound what is read from the
    /// network, not what the user can see: a page that does not fit is asked
    /// for again with a smaller `limit`.
    pub const unread_bytes = 256 * 1024;
    pub const messages_bytes = 4 * 1024 * 1024;
    pub const task_bytes = 256 * 1024;
    pub const json_depth = 16;
    /// The conversation list is built from the most recent messages and grows
    /// backwards on request; a page is a transfer unit, never a visibility cap.
    pub const list_page: u32 = 200;
    /// One screen of a conversation plus scrollback; earlier pages on request.
    pub const conversation_page: u32 = 50;
    pub const id_bytes = 128;
    pub const name_bytes = 256;
    /// A list row shows one line; the preview never carries a whole message
    /// into the snapshot.
    pub const preview_codepoints = 160;
    pub const poll_interval_ms: u64 = 60_000;
    /// Returning to the foreground asks again only when the last answer is at
    /// least this old, so focus flapping cannot become a request loop.
    pub const resume_after_ms: u64 = 15_000;
    /// Background retry delays after consecutive failures; the last repeats.
    pub const retry_ms = [_]u64{ 30_000, 60_000, 120_000, 300_000 };
};

fn Text(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = undefined,
        len: usize = 0,

        pub const max = capacity;

        /// Exact copy; an identity that does not fit is not this identity.
        pub fn init(value: []const u8) error{InvalidResponse}!@This() {
            if (value.len == 0 or value.len > capacity) return error.InvalidResponse;
            var result: @This() = .{ .len = value.len };
            @memcpy(result.bytes[0..value.len], value);
            return result;
        }

        /// Display text: cut at a UTF-8 boundary when it does not fit.
        pub fn truncated(value: []const u8) @This() {
            const cut = utf8Prefix(value, capacity);
            var result: @This() = .{ .len = cut.len };
            @memcpy(result.bytes[0..cut.len], cut);
            return result;
        }

        pub fn slice(self: *const @This()) []const u8 {
            return self.bytes[0..self.len];
        }

        pub fn eql(self: *const @This(), other: []const u8) bool {
            return std.mem.eql(u8, self.slice(), other);
        }
    };
}

/// The longest prefix of `value` that is at most `bytes` long and ends on a
/// UTF-8 boundary. `value` is valid UTF-8 (the JSON parser guarantees it).
pub fn utf8Prefix(value: []const u8, bytes: usize) []const u8 {
    if (value.len <= bytes) return value;
    var end = bytes;
    while (end > 0 and value[end] & 0xc0 == 0x80) end -= 1;
    return value[0..end];
}

pub const Id = Text(Limits.id_bytes);
pub const Name = Text(Limits.name_bytes);
pub const Preview = Text(Limits.preview_codepoints * 4);

/// A u64 published as a decimal string; JSON numbers lose precision in JS.
pub const U64 = struct {
    value: u64,
    pub const wire_scalar = "u64WireInteger";

    pub fn jsonStringify(self: @This(), json: *std.json.Stringify) std.Io.Writer.Error!void {
        try json.print("\"{d}\"", .{self.value});
    }
};

// ---------------------------------------------------------------------------
// Which installed connection is MetaTeam.

/// MetaTeam's published MCP endpoint format is `<service>/agent/v1/mcp/k/<key>`.
/// The service may sit under a base path; its open API is `<base>/open/v1/...`.
pub const device_path = "/agent/v1/mcp/k/";

pub const DeviceEndpoint = struct {
    /// Scheme, authority and base path, without a trailing slash. Borrowed
    /// from the input URL.
    base: []const u8,
    /// The percent-decoded device key, written into the caller's buffer.
    key: []const u8,
};

/// Exact match against MetaTeam's own endpoint format. Host names and display
/// names take no part: a URL either has this shape or is not MetaTeam. The
/// caller owns and clears both the URL and the key buffer.
pub fn matchDeviceEndpoint(url: []const u8, key_buffer: []u8) ?DeviceEndpoint {
    for (url) |byte| if (byte <= 0x20 or byte >= 0x7f) return null;
    const uri = std.Uri.parse(url) catch return null;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) return null;
    if (uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) return null;
    const host = uri.host orelse return null;
    if (host.isEmpty()) return null;
    const authority = (std.mem.indexOf(u8, url, "://") orelse return null) + 3;
    const path_start = std.mem.indexOfScalarPos(u8, url, authority, '/') orelse return null;
    var path = url[path_start..];
    if (path.len > 1 and path[path.len - 1] == '/') path = path[0 .. path.len - 1];
    const marker = std.mem.lastIndexOf(u8, path, device_path) orelse return null;
    const segment = path[marker + device_path.len ..];
    if (segment.len == 0 or std.mem.indexOfScalar(u8, segment, '/') != null) return null;
    const key = percentDecode(segment, key_buffer) orelse return null;
    // Sent as an Authorization header: visible ASCII only.
    for (key) |byte| if (byte < 0x21 or byte > 0x7e) {
        std.crypto.secureZero(u8, key_buffer);
        return null;
    };
    return .{ .base = url[0 .. path_start + marker], .key = key };
}

fn percentDecode(value: []const u8, output: []u8) ?[]const u8 {
    var length: usize = 0;
    var index: usize = 0;
    while (index < value.len) : (length += 1) {
        if (length >= output.len) return null;
        if (value[index] == '%') {
            if (index + 2 >= value.len) return null;
            const high = std.fmt.charToDigit(value[index + 1], 16) catch return null;
            const low = std.fmt.charToDigit(value[index + 2], 16) catch return null;
            output[length] = high * 16 + low;
            index += 3;
        } else {
            output[length] = value[index];
            index += 1;
        }
    }
    if (length == 0) return null;
    return output[0..length];
}

// ---------------------------------------------------------------------------
// Requests.

pub const MessagesQuery = struct {
    peer: ?[]const u8 = null,
    after: ?[]const u8 = null,
    before: ?[]const u8 = null,
    limit: ?u32 = null,
};

pub const Request = union(enum) {
    unread,
    messages: MessagesQuery,
    task: []const u8,

    pub fn maxBytes(self: Request) usize {
        return switch (self) {
            .unread => Limits.unread_bytes,
            .messages => Limits.messages_bytes,
            .task => Limits.task_bytes,
        };
    }
};

/// The full request URL: the base of the bound connection plus the open API
/// path and query. Never carries the key; it travels as a Bearer header.
pub fn writeUrl(writer: *std.Io.Writer, base: []const u8, request: Request) std.Io.Writer.Error!void {
    try writer.writeAll(base);
    switch (request) {
        .unread => try writer.writeAll("/open/v1/unread"),
        .task => |id| {
            try writer.writeAll("/open/v1/tasks/");
            try writeComponent(writer, id);
        },
        .messages => |query| {
            try writer.writeAll("/open/v1/messages");
            var separator: u8 = '?';
            inline for (.{ .{ "peer", "peer" }, .{ "afterId", "after" }, .{ "beforeId", "before" } }) |param| {
                if (@field(query, param[1])) |value| {
                    try writer.print("{c}{s}=", .{ separator, param[0] });
                    try writeComponent(writer, value);
                    separator = '&';
                }
            }
            if (query.limit) |limit| try writer.print("{c}limit={d}", .{ separator, limit });
        },
    }
}

fn writeComponent(writer: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!void {
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "-._~", byte) != null)
            try writer.writeByte(byte)
        else
            try writer.print("%{X:0>2}", .{byte});
    }
}

/// What one task or conversation read answered. It is that request's outcome
/// only: a task the key may not see says nothing about the connection.
pub const RequestFailure = enum { forbidden, not_found, failed };

pub fn requestFailure(status: ?u16) RequestFailure {
    const value = status orelse return .failed;
    return switch (value) {
        401, 403 => .forbidden,
        404, 410 => .not_found,
        else => .failed,
    };
}

/// A task id becomes one path segment. Every byte is percent-encoded except
/// the unreserved ones, so only the dot segments could still move the path.
pub fn validTaskId(id: []const u8) bool {
    return id.len != 0 and !std.mem.eql(u8, id, ".") and !std.mem.eql(u8, id, "..");
}

/// What an answered unread or list request means for the connection. Device
/// authorization is refused with 401; an unconfirmed device cannot yet be
/// told apart, so 403 shares the state.
pub fn statusFailure(status: u16) ?Failure {
    return switch (status) {
        200...299 => null,
        401, 403 => .reauthorize,
        else => .{ .@"unreachable" = null },
    };
}

// ---------------------------------------------------------------------------
// Responses. MetaTeam publishes no response schema: only the fields used here
// are read, by the names the development client used against the real
// service, and unknown fields are ignored. A missing or mistyped required
// field makes the whole response unusable.

/// `self` is a message the user sent to themself: from one of their own
/// agents to another, or a group message that also went to them.
pub const Direction = enum { in, out, self };

/// The conversation of what the user sent to themself. MetaTeam's own name
/// for it as a `peer`; never a member id.
pub const self_peer_id = "me";

pub const Peer = struct {
    id: Id,
    name: Name,
    /// The only name MetaTeam addresses a message to exactly; absent when
    /// the service did not report it or it does not fit.
    username: ?Name = null,
};

pub const PeerUnread = struct {
    peer: Peer,
    unread: u64,
    /// When their latest unread message arrived.
    last_at_ms: ?u64 = null,
};

/// One recipient of a message the user sent, and whether they read it.
pub const Recipient = struct {
    peer: Peer,
    read: bool,
    /// Null when unread, or read at a time this client cannot parse.
    read_at_ms: ?u64,
};

pub const Unread = struct {
    total: u64,
    by_peer: []PeerUnread,

    pub fn deinit(self: *Unread, allocator: std.mem.Allocator) void {
        allocator.free(self.by_peer);
        self.* = undefined;
    }
};

pub const Message = struct {
    id: Id,
    sent_at_ms: u64,
    direction: Direction,
    from: Peer,
    recipients: []const Recipient,
    text: []const u8,
    task_ids: []const Id,
    /// A received message the user had not read before this answer.
    is_new: bool = false,
    /// The agent that sent it, as MetaTeam names it ("client@host").
    from_agent: ?Name = null,
    /// The conversations this message belongs to, seen from this user: what
    /// came in belongs to its sender, what went out to every recipient, and
    /// what went to the user themself to `me` and every other recipient.
    conversations: []const Peer,

    pub fn peers(self: *const Message) []const Peer {
        return self.conversations;
    }
};

/// The `me` conversation, named after the user as MetaTeam reports them.
pub fn selfPeer(from: Peer) Peer {
    return .{ .id = Id.init(self_peer_id) catch unreachable, .name = from.name };
}

pub const Messages = struct {
    arena: std.heap.ArenaAllocator,
    items: []const Message,

    pub fn deinit(self: *Messages) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Task = struct {
    arena: std.heap.ArenaAllocator,
    id: ?Id,
    name: []const u8,
    progress: ?[]const u8,
    state: ?[]const u8,
    path: ?[]const u8,
    description: ?[]const u8,
    assignees: []const []const u8,
    updated_at_ms: ?u64,

    pub fn deinit(self: *Task) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

const ParseError = error{ InvalidResponse, OutOfMemory };

// Bound nesting before building the tree; the parser keeps grammar, escapes,
// Unicode and duplicate keys.
fn boundedJson(bytes: []const u8, max: usize) bool {
    if (bytes.len == 0 or bytes.len > max) return false;
    var depth: usize = 0;
    var quoted = false;
    var escaped = false;
    for (bytes) |byte| {
        if (quoted) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') quoted = false;
        } else switch (byte) {
            '"' => quoted = true,
            '{', '[' => {
                depth += 1;
                if (depth > Limits.json_depth) return false;
            },
            '}', ']' => {
                if (depth == 0) return false;
                depth -= 1;
            },
            else => {},
        }
    }
    return !quoted and depth == 0;
}

/// Numbers stay as their JSON text so an identifier is never routed through
/// a float: ids only compare equal and travel back verbatim.
fn parseData(arena: std.mem.Allocator, bytes: []const u8, max: usize) ParseError!std.json.Value {
    if (!boundedJson(bytes, max)) return error.InvalidResponse;
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{
        .parse_numbers = false,
        .max_value_len = max,
        // Every string is copied: the response buffer is reused.
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResponse,
    };
    if (root != .object) return error.InvalidResponse;
    return root.object.get("data") orelse error.InvalidResponse;
}

/// MetaTeam ids may be JSON strings or numbers. Both become the same text:
/// a string as written, a number as its integer digits, never a float. The
/// Renderer receives ids only as strings, so a large numeric id cannot lose
/// precision in JavaScript and two messages are never confused.
fn idValue(value: std.json.Value) error{InvalidResponse}!Id {
    switch (value) {
        .string => |text| {
            for (text) |byte| if (byte < 0x21 or byte > 0x7e) return error.InvalidResponse;
            return Id.init(text);
        },
        .number_string => |text| {
            if (!integerText(text)) return error.InvalidResponse;
            return Id.init(text);
        },
        else => return error.InvalidResponse,
    }
}

fn integerText(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |byte| if (byte < '0' or byte > '9') return false;
    return true;
}

fn countValue(value: std.json.Value) error{InvalidResponse}!u64 {
    const text = switch (value) {
        .number_string => |text| text,
        else => return error.InvalidResponse,
    };
    if (!integerText(text)) return error.InvalidResponse;
    return std.fmt.parseInt(u64, text, 10) catch error.InvalidResponse;
}

fn field(object: std.json.ObjectMap, name: []const u8) ?std.json.Value {
    const value = object.get(name) orelse return null;
    return if (value == .null) null else value;
}

fn nonEmptyString(value: ?std.json.Value) ?[]const u8 {
    const present = value orelse return null;
    if (present != .string or present.string.len == 0) return null;
    return present.string;
}

fn peerValue(value: std.json.Value) error{InvalidResponse}!Peer {
    if (value != .object) return error.InvalidResponse;
    const id = try idValue(value.object.get("id") orelse return error.InvalidResponse);
    // The development client showed `name`, then `username`.
    const username = nonEmptyString(field(value.object, "username"));
    const name = nonEmptyString(field(value.object, "name")) orelse username orelse id.slice();
    // A username is an address: kept exactly or not at all.
    return .{ .id = id, .name = .truncated(name), .username = if (username) |text| Name.init(text) catch null else null };
}

/// An optional instant: absent, null or unreadable is no time at all.
fn optionalTime(object: std.json.ObjectMap, names: []const []const u8) ?u64 {
    for (names) |name| if (field(object, name)) |value| return timeValue(value) catch null;
    return null;
}

fn timeValue(value: std.json.Value) error{InvalidResponse}!u64 {
    return switch (value) {
        // MetaTeam reports instants as Unix milliseconds elsewhere.
        .number_string => |text| if (integerText(text))
            std.fmt.parseInt(u64, text, 10) catch error.InvalidResponse
        else
            error.InvalidResponse,
        .string => |text| parseIsoMilliseconds(text) orelse error.InvalidResponse,
        else => error.InvalidResponse,
    };
}

pub fn parseUnread(allocator: std.mem.Allocator, bytes: []const u8) ParseError!Unread {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const data = try parseData(arena.allocator(), bytes, Limits.unread_bytes);
    if (data != .object) return error.InvalidResponse;
    const total = try countValue(data.object.get("unread") orelse return error.InvalidResponse);
    const list = field(data.object, "byPeer");
    const items: []const std.json.Value = if (list) |value| switch (value) {
        .array => |array| array.items,
        else => return error.InvalidResponse,
    } else &.{};
    var by_peer: std.ArrayList(PeerUnread) = .empty;
    errdefer by_peer.deinit(allocator);
    try by_peer.ensureTotalCapacity(allocator, items.len);
    for (items) |item| {
        if (item != .object) return error.InvalidResponse;
        const peer = try peerValue(item.object.get("peer") orelse return error.InvalidResponse);
        const unread = try countValue(item.object.get("unread") orelse return error.InvalidResponse);
        const last_at = optionalTime(item.object, &.{ "lastAt", "lastTime" });
        // Ids are compared as text, so `7` and `"7"` are one member: one row,
        // its counts added, rather than two rows with the same key.
        for (by_peer.items) |*existing| {
            if (existing.peer.id.eql(peer.id.slice())) {
                existing.unread +|= unread;
                if (last_at) |at| existing.last_at_ms = @max(at, existing.last_at_ms orelse 0);
                break;
            }
        } else by_peer.appendAssumeCapacity(.{ .peer = peer, .unread = unread, .last_at_ms = last_at });
    }
    return .{ .total = total, .by_peer = try by_peer.toOwnedSlice(allocator) };
}

pub fn parseMessages(allocator: std.mem.Allocator, bytes: []const u8) ParseError!Messages {
    var result: Messages = .{ .arena = .init(allocator), .items = &.{} };
    errdefer result.arena.deinit();
    const arena = result.arena.allocator();
    const data = try parseData(arena, bytes, Limits.messages_bytes);
    if (data != .object) return error.InvalidResponse;
    const list = data.object.get("messages") orelse return error.InvalidResponse;
    if (list != .array) return error.InvalidResponse;
    const items = try arena.alloc(Message, list.array.items.len);
    var count: usize = 0;
    for (list.array.items) |item| {
        const message = &items[count];
        if (item != .object) return error.InvalidResponse;
        const object = item.object;
        const direction = nonEmptyString(field(object, "direction")) orelse return error.InvalidResponse;
        const text = object.get("text") orelse return error.InvalidResponse;
        if (text != .string) return error.InvalidResponse;
        const recipients: []const std.json.Value = if (field(object, "recipients")) |value| switch (value) {
            .array => |array| array.items,
            else => return error.InvalidResponse,
        } else &.{};
        const tasks: []const std.json.Value = if (field(object, "taskIds")) |value| switch (value) {
            .array => |array| array.items,
            else => return error.InvalidResponse,
        } else &.{};
        // Repeated recipients, task ids or messages are kept once: each is a
        // key on the Renderer side.
        const peer_list = try arena.alloc(Peer, recipients.len);
        const recipient_list = try arena.alloc(Recipient, recipients.len);
        var peers: usize = 0;
        for (recipients) |entry| {
            const peer = try peerValue(entry);
            // `readAt` null is unread; any other value says it was read.
            const read_at = entry.object.get("readAt");
            const read = read_at != null and read_at.? != .null;
            const at = if (read) timeValue(read_at.?) catch null else null;
            for (recipient_list[0..peers]) |*seen| {
                if (seen.peer.id.eql(peer.id.slice())) {
                    // The same member twice: read if either says so.
                    if (read and !seen.read) seen.* = .{ .peer = seen.peer, .read = true, .read_at_ms = at };
                    break;
                }
            } else {
                peer_list[peers] = peer;
                recipient_list[peers] = .{ .peer = peer, .read = read, .read_at_ms = at };
                peers += 1;
            }
        }
        const task_list = try arena.alloc(Id, tasks.len);
        var task_count: usize = 0;
        for (tasks) |entry| {
            const id = try idValue(entry);
            for (task_list[0..task_count]) |*seen| {
                if (seen.eql(id.slice())) break;
            } else {
                task_list[task_count] = id;
                task_count += 1;
            }
        }
        const from = try peerValue(object.get("from") orelse return error.InvalidResponse);
        const kind = std.meta.stringToEnum(Direction, direction) orelse return error.InvalidResponse;
        const conversations: []const Peer = switch (kind) {
            .in => (try arena.dupe(Peer, &.{from})),
            .out => peer_list[0..peers],
            .self => self: {
                // A group message that also went to the user is theirs and
                // every other recipient's.
                const mine = try arena.alloc(Peer, peers + 1);
                mine[0] = selfPeer(from);
                var count_self: usize = 1;
                for (peer_list[0..peers]) |peer| {
                    if (peer.id.eql(from.id.slice()) or peer.id.eql(self_peer_id)) continue;
                    mine[count_self] = peer;
                    count_self += 1;
                }
                break :self mine[0..count_self];
            },
        };
        message.* = .{
            .id = try idValue(object.get("id") orelse return error.InvalidResponse),
            .sent_at_ms = try timeValue(object.get("time") orelse return error.InvalidResponse),
            .direction = kind,
            .from = from,
            .recipients = recipient_list[0..peers],
            .text = text.string,
            .task_ids = task_list[0..task_count],
            // Only a literal `true` is new; anything else was seen before.
            .is_new = if (field(object, "new")) |value| value == .bool and value.bool else false,
            // Present means an agent sent it; its value only names which.
            .from_agent = if (field(object, "fromAgent")) |value| switch (value) {
                .string => |agent| Name.truncated(if (agent.len == 0) "agent" else agent),
                else => Name.truncated("agent"),
            } else null,
            .conversations = conversations,
        };
        // An outgoing message without recipients belongs to no conversation.
        if (message.direction == .out and peers == 0) return error.InvalidResponse;
        for (items[0..count]) |*seen| {
            if (seen.id.eql(message.id.slice())) break;
        } else count += 1;
    }
    result.items = items[0..count];
    return result;
}

pub fn parseTask(allocator: std.mem.Allocator, bytes: []const u8) ParseError!Task {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    var data = try parseData(a, bytes, Limits.task_bytes);
    if (data != .object) return error.InvalidResponse;
    if (field(data.object, "task")) |inner| {
        if (inner == .object) data = inner;
    }
    const object = data.object;
    const name = nonEmptyString(field(object, "name")) orelse return error.InvalidResponse;
    var assignees: std.ArrayList([]const u8) = .empty;
    if (field(object, "assignees")) |value| {
        if (value == .array) for (value.array.items) |entry| {
            const text = switch (entry) {
                .string => |text| if (text.len != 0) text else continue,
                .object => |item| nonEmptyString(field(item, "name")) orelse nonEmptyString(field(item, "username")) orelse continue,
                else => continue,
            };
            try assignees.append(a, text);
        };
    }
    const id = if (field(object, "id")) |value| idValue(value) catch null else null;
    const updated = if (field(object, "updatedAt")) |value| timeValue(value) catch null else null;
    const progress = nonEmptyString(field(object, "progress"));
    const state = nonEmptyString(field(object, "state"));
    const path = nonEmptyString(field(object, "path"));
    const description = nonEmptyString(field(object, "description")) orelse nonEmptyString(field(object, "desc"));
    return .{
        .arena = arena,
        .id = id,
        .name = name,
        .progress = progress,
        .state = state,
        .path = path,
        .description = description,
        .assignees = assignees.items,
        .updated_at_ms = updated,
    };
}

/// `YYYY-MM-DD[T ]HH:MM:SS[.fraction][Z|±HH:MM|±HHMM]`. A missing zone is UTC.
pub fn parseIsoMilliseconds(text: []const u8) ?u64 {
    if (text.len < 19) return null;
    const year = digits(text[0..4]) orelse return null;
    const month = digits(text[5..7]) orelse return null;
    const day = digits(text[8..10]) orelse return null;
    const hour = digits(text[11..13]) orelse return null;
    const minute = digits(text[14..16]) orelse return null;
    const second = digits(text[17..19]) orelse return null;
    if (text[4] != '-' or text[7] != '-' or text[13] != ':' or text[16] != ':') return null;
    if (text[10] != 'T' and text[10] != 't' and text[10] != ' ') return null;
    if (month < 1 or month > 12 or day < 1 or day > daysInMonth(year, month) or
        hour > 23 or minute > 59 or second > 60) return null;
    var index: usize = 19;
    var millis: u64 = 0;
    if (index < text.len and text[index] == '.') {
        index += 1;
        const start = index;
        while (index < text.len and std.ascii.isDigit(text[index])) : (index += 1) {
            if (index - start < 3) millis = millis * 10 + (text[index] - '0');
        }
        if (index == start) return null;
        var scale = index - start;
        while (scale < 3) : (scale += 1) millis *= 10;
    }
    var offset_seconds: i64 = 0;
    if (index < text.len) {
        const sign = text[index];
        if (sign == 'Z' or sign == 'z') {
            index += 1;
        } else if (sign == '+' or sign == '-') {
            const rest = text[index + 1 ..];
            const hours, const minutes, const used = if (rest.len >= 5 and rest[2] == ':')
                .{ digits(rest[0..2]) orelse return null, digits(rest[3..5]) orelse return null, @as(usize, 5) }
            else if (rest.len >= 4)
                .{ digits(rest[0..2]) orelse return null, digits(rest[2..4]) orelse return null, @as(usize, 4) }
            else
                return null;
            if (hours > 23 or minutes > 59) return null;
            offset_seconds = @intCast(hours * 3600 + minutes * 60);
            if (sign == '-') offset_seconds = -offset_seconds;
            index += 1 + used;
        } else return null;
    }
    if (index != text.len) return null;
    const days = daysFromCivil(@intCast(year), @intCast(month), @intCast(day));
    const seconds = days * 86_400 + @as(i64, @intCast(hour * 3600 + minute * 60 + second)) - offset_seconds;
    if (seconds < 0) return null;
    return @as(u64, @intCast(seconds)) * 1000 + millis;
}

fn digits(text: []const u8) ?u32 {
    var value: u32 = 0;
    for (text) |byte| {
        if (!std.ascii.isDigit(byte)) return null;
        value = value * 10 + (byte - '0');
    }
    return value;
}

fn daysInMonth(year: u32, month: u32) u32 {
    return switch (month) {
        2 => if ((year % 4 == 0 and year % 100 != 0) or year % 400 == 0) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}

/// Days since 1970-01-01 in the proleptic Gregorian calendar.
fn daysFromCivil(year_in: i64, month: i64, day: i64) i64 {
    const year = if (month <= 2) year_in - 1 else year_in;
    const era = @divFloor(year, 400);
    const yoe = year - era * 400;
    const mp = @mod(month + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146_097 + doe - 719_468;
}

/// The first line of a message, cut to what one list row can show.
pub fn preview(text: []const u8) Preview {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const line = trimmed[0 .. std.mem.indexOfAny(u8, trimmed, "\r\n") orelse trimmed.len];
    var end: usize = 0;
    var codepoints: usize = 0;
    while (end < line.len and codepoints < Limits.preview_codepoints) : (codepoints += 1)
        end += std.unicode.utf8ByteSequenceLength(line[end]) catch 1;
    return .truncated(line[0..@min(end, line.len)]);
}

// ---------------------------------------------------------------------------
// State.

pub const State = enum { unavailable, checking, ready, reauthorize, @"unreachable" };

/// How long the failed attempt took: the update check's buckets.
pub const Elapsed = update.Elapsed;

/// Where a failed request stopped and why. Only when the request itself
/// failed; an answered request that could not be used carries none.
pub const Diagnostic = struct {
    phase: http.Phase,
    cause: http.Cause,
    elapsed: Elapsed,
};

comptime {
    // Closed vocabularies only: a diagnostic cannot carry a URL, host,
    // header, body or key even by mistake.
    for (@typeInfo(Diagnostic).@"struct".fields) |item| switch (@typeInfo(item.type)) {
        .@"enum" => {},
        else => @compileError("an inbox diagnostic must stay typed facts, never text"),
    };
}

pub const Failure = union(enum) {
    /// The device key was refused: reconnect MetaTeam or confirm the device.
    reauthorize,
    /// Network, server error, an unusable response or an unreadable credential.
    @"unreachable": ?Diagnostic,
};

/// The connection Application found to be MetaTeam: the MCP server and the
/// exact connection it had when found. A different fingerprint is a different
/// binding even for the same server.
pub const BindingKey = struct {
    server_id: []const u8,
    fingerprint: [64]u8,
};

pub const ListKind = enum { initial, newer, earlier };

pub const ListPreparation = struct {
    id: u64,
    binding: u64,
    kind: ListKind,
    /// `afterId` for `newer`, `beforeId` for `earlier`.
    anchor: ?Id,
};

pub const ListPage = struct {
    /// The page itself, oldest first.
    messages: []const Message,
    /// The `limit` that page was finally asked with.
    limit: u32,
};

pub const ListCompletion = union(enum) { page: ListPage, failed: Failure };
pub const PollCompletion = union(enum) { unread: *const Unread, failed: Failure };
pub const CommandOutcome = enum { accepted, rejected, unavailable };
pub const ConversationPageKind = enum { latest, before, after };

/// A Renderer read of one conversation page. Borrowed for the call.
pub const ConversationRequest = struct {
    binding: u64,
    request_id: u64,
    peer: []const u8,
    kind: ConversationPageKind,
    anchor: ?[]const u8,
};

/// A Renderer read of one linked task. Borrowed for the call.
pub const TaskRequest = struct {
    binding: u64,
    request_id: u64,
    task: []const u8,
};

const Latest = struct {
    id: Id,
    direction: Direction,
    preview: Preview,
    sent_at_ms: u64,
};

const Summary = struct {
    peer: Peer,
    latest: Latest,
};

pub const LatestView = struct {
    id: []const u8,
    direction: Direction,
    preview: []const u8,
    sentAtMs: U64,
};

pub const ConversationView = struct {
    peerId: []const u8,
    name: []const u8,
    unread: U64,
    latest: ?LatestView,
    /// When their latest unread message arrived, from the unread facts.
    lastAtMs: ?U64,
};

/// Borrowed, key-free and URL-free projection; serialize from the main thread.
pub const View = struct {
    binding: U64,
    state: State,
    unreadTotal: ?U64,
    syncedAtMs: ?U64,
    conversations: []const ConversationView,
    conversationsLoaded: bool,
    loadingConversations: bool,
    hasEarlier: bool,
    diagnostic: ?Diagnostic,
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    available: bool = false,
    /// The current binding, or none. Bumped on every change so a result or a
    /// Renderer request made against an earlier connection is recognised.
    binding: u64 = 0,
    server_id: Id = .{},
    fingerprint: [64]u8 = @splat(0),
    bound: bool = false,
    state: State = .unavailable,
    active: bool = false,
    unread_total: ?u64 = null,
    by_peer: std.ArrayList(PeerUnread) = .empty,
    summaries: std.ArrayList(Summary) = .empty,
    rows: std.ArrayList(ConversationView) = .empty,
    list_loaded: bool = false,
    has_earlier: bool = false,
    newest: ?Id = null,
    oldest: ?Id = null,
    synced_at_ms: ?u64 = null,
    diagnostic: ?Diagnostic = null,
    next_poll_ms: ?u64 = null,
    last_result_ms: ?u64 = null,
    failures: u8 = 0,
    sequence: u64 = 0,
    poll_id: ?u64 = null,
    list_id: ?u64 = null,
    pending_newer: bool = false,
    pending_earlier: bool = false,
    /// The member whose conversation was read last. A rebuilt window keeps
    /// their row, so a page being read never loses its place in the list.
    viewing: ?Id = null,

    pub fn init(allocator: std.mem.Allocator) Runtime {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Runtime) void {
        self.by_peer.deinit(self.allocator);
        self.summaries.deinit(self.allocator);
        self.rows.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn start(self: *Runtime, active: bool) void {
        self.available = true;
        self.active = active;
    }

    pub fn stop(self: *Runtime) void {
        self.available = false;
        self.unbind();
    }

    fn nextId(self: *Runtime) ?u64 {
        if (self.sequence == std.math.maxInt(u64)) return null;
        self.sequence += 1;
        return self.sequence;
    }

    fn clearData(self: *Runtime) void {
        self.unread_total = null;
        self.by_peer.clearRetainingCapacity();
        self.summaries.clearRetainingCapacity();
        self.list_loaded = false;
        self.has_earlier = false;
        self.newest = null;
        self.oldest = null;
        self.synced_at_ms = null;
        self.diagnostic = null;
        self.next_poll_ms = null;
        self.last_result_ms = null;
        self.failures = 0;
        self.poll_id = null;
        self.list_id = null;
        self.pending_newer = false;
        self.pending_earlier = false;
        self.viewing = null;
    }

    /// Installs the connection Application identified, or clears it. The same
    /// key keeps everything; a different one starts over. Returns whether the
    /// projection changed.
    pub fn bind(self: *Runtime, now_ms: u64, key: ?BindingKey) std.mem.Allocator.Error!bool {
        if (!self.available) return false;
        if (key) |value| {
            if (self.bound and self.server_id.eql(value.server_id) and
                std.mem.eql(u8, &self.fingerprint, &value.fingerprint)) return false;
            const server_id = Id.init(value.server_id) catch return self.unbindChanged();
            self.clearData();
            self.bound = true;
            self.server_id = server_id;
            self.fingerprint = value.fingerprint;
            self.binding +%= 1;
            self.state = .checking;
            self.next_poll_ms = now_ms;
            try self.rebuild();
            return true;
        }
        return self.unbindChanged();
    }

    fn unbindChanged(self: *Runtime) bool {
        if (!self.bound and self.state == .unavailable) return false;
        self.unbind();
        return true;
    }

    fn unbind(self: *Runtime) void {
        const was = self.bound or self.state != .unavailable;
        self.clearData();
        self.bound = false;
        self.state = .unavailable;
        self.rows.clearRetainingCapacity();
        if (was) self.binding +%= 1;
    }

    /// A binding attempt that could not read the connection's credential.
    pub fn bindingFailed(self: *Runtime, now_ms: u64) bool {
        if (!self.available) return false;
        self.clearData();
        self.rows.clearRetainingCapacity();
        if (self.bound) self.binding +%= 1;
        self.bound = false;
        self.state = .@"unreachable";
        _ = now_ms;
        return true;
    }

    pub fn currentBinding(self: *const Runtime) ?u64 {
        return if (self.available and self.bound) self.binding else null;
    }

    pub fn setActive(self: *Runtime, now_ms: u64, active: bool) void {
        if (active and !self.active and self.bound) {
            const stale = if (self.last_result_ms) |at| now_ms -| at >= Limits.resume_after_ms else true;
            if (stale) self.next_poll_ms = if (self.next_poll_ms) |at| @min(at, now_ms) else now_ms;
        }
        self.active = active;
    }

    /// When the background poll is due, if it may run at all: bound, in the
    /// foreground, not refused and not already running.
    pub fn nextPoll(self: *const Runtime) ?u64 {
        if (!self.available or !self.bound or !self.active or self.state == .reauthorize or self.poll_id != null) return null;
        return self.next_poll_ms;
    }

    pub fn beginPoll(self: *Runtime) ?u64 {
        if (!self.available or !self.bound or self.poll_id != null) return null;
        const id = self.nextId() orelse return null;
        self.poll_id = id;
        return id;
    }

    /// The next background poll is scheduled from the result: success takes
    /// the ordinary interval, a failure the next retry delay. A refusal stops
    /// background polling until the binding changes or the user asks.
    pub fn completePoll(self: *Runtime, now_ms: u64, wall_ms: u64, id: u64, completion: PollCompletion) std.mem.Allocator.Error!bool {
        if (!self.available or self.poll_id != id) return false;
        self.poll_id = null;
        self.last_result_ms = now_ms;
        switch (completion) {
            .unread => |unread| {
                try self.by_peer.resize(self.allocator, unread.by_peer.len);
                @memcpy(self.by_peer.items, unread.by_peer);
                self.unread_total = unread.total;
                self.state = .ready;
                self.diagnostic = null;
                self.failures = 0;
                self.synced_at_ms = wall_ms;
                self.next_poll_ms = now_ms +| Limits.poll_interval_ms;
            },
            .failed => |failure| self.fail(now_ms, failure),
        }
        try self.rebuild();
        return true;
    }

    fn fail(self: *Runtime, now_ms: u64, failure: Failure) void {
        switch (failure) {
            .reauthorize => {
                self.state = .reauthorize;
                self.diagnostic = null;
                self.next_poll_ms = null;
                self.pending_newer = false;
                self.pending_earlier = false;
            },
            .@"unreachable" => |diagnostic| {
                self.state = .@"unreachable";
                self.diagnostic = diagnostic;
                self.failures +|= 1;
                const index = @min(self.failures, Limits.retry_ms.len) - 1;
                self.next_poll_ms = now_ms +| Limits.retry_ms[index];
            },
        }
    }

    /// The Renderer refreshes while the inbox page is open. An automatic
    /// refresh keeps every background rule: nothing in the background, nothing
    /// while refused, nothing before a failure's retry delay; it asks for the
    /// newer end of the list. Only the user's own retry passes those rules,
    /// and the caller then also reads the unread facts at once.
    pub fn requestRefresh(self: *Runtime, now_ms: u64, binding: u64, explicit: bool) CommandOutcome {
        if (!self.available) return .unavailable;
        if (!self.bound or binding != self.binding) return .rejected;
        if (!explicit) {
            if (!self.active or self.state == .reauthorize) return .rejected;
            if (self.state == .@"unreachable") if (self.next_poll_ms) |at| if (now_ms < at) return .rejected;
        }
        self.pending_newer = true;
        return .accepted;
    }

    pub fn requestEarlier(self: *Runtime, binding: u64) CommandOutcome {
        if (!self.available) return .unavailable;
        if (!self.bound or binding != self.binding) return .rejected;
        if (self.list_loaded and !self.has_earlier) return .rejected;
        self.pending_earlier = true;
        return .accepted;
    }

    pub fn listBusy(self: *const Runtime) bool {
        return self.list_id != null;
    }

    pub fn listPending(self: *const Runtime) bool {
        return self.bound and self.list_id == null and self.state != .reauthorize and
            (self.pending_newer or (self.pending_earlier and (!self.list_loaded or self.has_earlier)));
    }

    /// The next list page to fetch, if one was asked for. The first page
    /// always comes first; a newer page wins over an earlier one.
    pub fn beginList(self: *Runtime) ?ListPreparation {
        if (!self.available or !self.listPending()) return null;
        // An empty window has no newest message to continue from: it starts
        // over, which is the same request a first page makes.
        const kind: ListKind = if (!self.list_loaded or (self.pending_newer and self.newest == null))
            .initial
        else if (self.pending_newer) .newer else .earlier;
        const anchor: ?Id = switch (kind) {
            .initial => null,
            .newer => self.newest,
            .earlier => self.oldest,
        };
        if (kind == .earlier and anchor == null) {
            self.pending_earlier = false;
            return null;
        }
        const id = self.nextId() orelse return null;
        switch (kind) {
            .initial => {
                self.pending_newer = false;
            },
            .newer => self.pending_newer = false,
            .earlier => self.pending_earlier = false,
        }
        self.list_id = id;
        return .{ .id = id, .binding = self.binding, .kind = kind, .anchor = anchor };
    }

    pub fn completeList(self: *Runtime, now_ms: u64, id: u64, kind: ListKind, completion: ListCompletion) std.mem.Allocator.Error!bool {
        if (!self.available or self.list_id != id) return false;
        self.list_id = null;
        switch (completion) {
            .failed => |failure| {
                self.fail(now_ms, failure);
            },
            .page => |page| {
                const full = page.messages.len >= page.limit;
                switch (kind) {
                    .initial => try self.replaceWindow(page.messages, full),
                    .newer => if (full) {
                        // The gap between the old window and this page may
                        // hide someone's latest message: start over from here.
                        try self.replaceWindow(page.messages, true);
                    } else {
                        for (page.messages) |*message| try self.absorb(message, true);
                        if (page.messages.len != 0) self.newest = page.messages[page.messages.len - 1].id;
                    },
                    .earlier => {
                        for (page.messages) |*message| try self.absorb(message, false);
                        if (page.messages.len != 0) self.oldest = page.messages[0].id;
                        self.has_earlier = full;
                    },
                }
            },
        }
        try self.rebuild();
        return true;
    }

    fn replaceWindow(self: *Runtime, messages: []const Message, full: bool) std.mem.Allocator.Error!void {
        const kept: ?Summary = if (self.viewing) |*peer| if (self.summaryIndex(peer.slice())) |index| self.summaries.items[index] else null else null;
        self.summaries.clearRetainingCapacity();
        for (messages) |*message| try self.absorb(message, true);
        if (kept) |summary| if (self.summaryIndex(summary.peer.id.slice()) == null)
            try self.summaries.append(self.allocator, summary);
        self.newest = if (messages.len != 0) messages[messages.len - 1].id else null;
        self.oldest = if (messages.len != 0) messages[0].id else null;
        self.has_earlier = full;
        self.list_loaded = true;
    }

    /// Records `message` as the latest of each of its conversations. A newer
    /// message replaces the summary; an older one only fills a conversation
    /// the list does not have yet.
    fn absorb(self: *Runtime, message: *const Message, newer: bool) std.mem.Allocator.Error!void {
        const latest: Latest = .{ .id = message.id, .direction = message.direction, .preview = preview(message.text), .sent_at_ms = message.sent_at_ms };
        for (message.peers()) |peer| {
            if (self.summaryIndex(peer.id.slice())) |index| {
                const current = &self.summaries.items[index];
                if (newer or message.sent_at_ms > current.latest.sent_at_ms) {
                    current.* = .{ .peer = peer, .latest = latest };
                }
            } else try self.summaries.append(self.allocator, .{ .peer = peer, .latest = latest });
        }
    }

    fn summaryIndex(self: *const Runtime, peer: []const u8) ?usize {
        for (self.summaries.items, 0..) |*summary, index|
            if (summary.peer.id.eql(peer)) return index;
        return null;
    }

    fn unreadOf(self: *const Runtime, peer: []const u8) ?*const PeerUnread {
        for (self.by_peer.items) |*entry|
            if (entry.peer.id.eql(peer)) return entry;
        return null;
    }

    /// Whether a Renderer request about this conversation may run now.
    pub fn knowsPeer(self: *const Runtime, binding: u64, peer: []const u8) bool {
        if (!self.available or !self.bound or binding != self.binding) return false;
        if (self.summaryIndex(peer) != null) return true;
        if (self.viewing) |*viewing| if (viewing.eql(peer)) return true;
        for (self.by_peer.items) |*entry| if (entry.peer.id.eql(peer)) return true;
        return false;
    }

    pub fn accepts(self: *const Runtime, binding: u64) bool {
        return self.available and self.bound and binding == self.binding;
    }

    /// A conversation page the user read keeps the list's summary current
    /// and marks whose page is open. A failed read changes nothing here: its
    /// outcome belongs to that request alone.
    pub fn completeConversation(self: *Runtime, binding: u64, peer: []const u8, kind: ConversationPageKind, messages: []const Message) std.mem.Allocator.Error!bool {
        if (!self.accepts(binding)) return false;
        self.viewing = Id.init(peer) catch null;
        if (kind != .before and messages.len != 0) try self.absorb(&messages[messages.len - 1], false);
        try self.rebuild();
        return true;
    }

    /// Rows are rebuilt after every change so `view` only borrows. Unread
    /// conversations the list has no message for yet come first; the rest
    /// follow by their latest message, newest first.
    fn rebuild(self: *Runtime) std.mem.Allocator.Error!void {
        self.rows.clearRetainingCapacity();
        if (!self.bound) return;
        for (self.by_peer.items) |*entry| {
            if (entry.unread == 0 or self.summaryIndex(entry.peer.id.slice()) != null) continue;
            try self.rows.append(self.allocator, .{
                .peerId = entry.peer.id.slice(),
                .name = entry.peer.name.slice(),
                .unread = .{ .value = entry.unread },
                .latest = null,
                .lastAtMs = if (entry.last_at_ms) |at| .{ .value = at } else null,
            });
        }
        const pending = self.rows.items.len;
        for (self.summaries.items) |*summary| {
            const unread = self.unreadOf(summary.peer.id.slice());
            try self.rows.append(self.allocator, .{
                .peerId = summary.peer.id.slice(),
                .name = summary.peer.name.slice(),
                .unread = .{ .value = if (unread) |entry| entry.unread else 0 },
                .latest = .{ .id = summary.latest.id.slice(), .direction = summary.latest.direction, .preview = summary.latest.preview.slice(), .sentAtMs = .{ .value = summary.latest.sent_at_ms } },
                .lastAtMs = if (unread) |entry| if (entry.last_at_ms) |at| U64{ .value = at } else null else null,
            });
        }
        std.mem.sort(ConversationView, self.rows.items[0..pending], {}, struct {
            fn less(_: void, a: ConversationView, b: ConversationView) bool {
                return a.unread.value > b.unread.value;
            }
        }.less);
        std.mem.sort(ConversationView, self.rows.items[pending..], {}, struct {
            fn less(_: void, a: ConversationView, b: ConversationView) bool {
                const left = a.latest.?.sentAtMs.value;
                const right = b.latest.?.sentAtMs.value;
                if (left != right) return left > right;
                return std.mem.order(u8, a.peerId, b.peerId) == .lt;
            }
        }.less);
    }

    pub fn view(self: *const Runtime) View {
        const counted = self.bound and (self.state == .ready or self.state == .@"unreachable");
        return .{
            .binding = .{ .value = self.binding },
            .state = self.state,
            .unreadTotal = if (counted) if (self.unread_total) |total| U64{ .value = total } else null else null,
            .syncedAtMs = if (self.synced_at_ms) |at| U64{ .value = at } else null,
            .conversations = self.rows.items,
            .conversationsLoaded = self.list_loaded,
            .loadingConversations = self.list_id != null,
            .hasEarlier = self.has_earlier,
            .diagnostic = if (self.state == .@"unreachable") self.diagnostic else null,
        };
    }
};

// ---------------------------------------------------------------------------
// Renderer command results.

pub const RecipientView = struct {
    peerId: []const u8,
    name: []const u8,
    read: bool,
    readAtMs: ?U64,
};

pub const MessageView = struct {
    id: []const u8,
    direction: Direction,
    fromPeerId: []const u8,
    fromName: []const u8,
    /// The agent that sent it ("client@host"), when an agent did.
    fromAgent: ?[]const u8,
    /// Received and not read before this answer.
    isNew: bool,
    recipients: []const RecipientView,
    text: []const u8,
    /// The text was cut to fit one Bridge result; only for a single message
    /// larger than the whole result budget.
    truncated: bool,
    sentAtMs: U64,
    taskIds: []const []const u8,
};

pub const ConversationState = enum { ready, stale_binding, unknown_peer, superseded, unavailable, forbidden, not_found, failed };

pub const ConversationPage = struct {
    binding: U64,
    requestId: U64,
    state: ConversationState,
    peerId: []const u8,
    messages: []const MessageView,
    /// More messages exist before the first one returned.
    hasEarlier: bool,
    /// For `after`: every newer message was returned. When false the
    /// Renderer reloads the latest page instead of guessing the gap.
    complete: bool,
};

pub const TaskView = struct {
    id: []const u8,
    name: []const u8,
    progress: ?[]const u8,
    state: ?[]const u8,
    path: ?[]const u8,
    description: ?[]const u8,
    assignees: []const []const u8,
    updatedAtMs: ?U64,
};

pub const TaskState = enum { ready, stale_binding, superseded, unavailable, forbidden, not_found, failed };

pub const TaskDetail = struct {
    binding: U64,
    requestId: U64,
    state: TaskState,
    task: ?TaskView,
};

/// Application receives only these lifecycle capabilities, never the Control
/// owner or a mutable aggregate pointer. All callbacks run on its thread.
pub const Management = struct {
    context: *anyopaque,
    start_fn: *const fn (*anyopaque, bool) void,
    bind_fn: *const fn (*anyopaque, u64, ?BindingKey) void,
    binding_failed_fn: *const fn (*anyopaque, u64) void,
    current_binding_fn: *const fn (*anyopaque) ?u64,
    set_active_fn: *const fn (*anyopaque, u64, bool) void,
    next_poll_fn: *const fn (*anyopaque) ?u64,
    begin_poll_fn: *const fn (*anyopaque) ?u64,
    complete_poll_fn: *const fn (*anyopaque, u64, u64, u64, PollCompletion) void,
    request_refresh_fn: *const fn (*anyopaque, u64, u64, bool) CommandOutcome,
    request_earlier_fn: *const fn (*anyopaque, u64) CommandOutcome,
    begin_list_fn: *const fn (*anyopaque) ?ListPreparation,
    complete_list_fn: *const fn (*anyopaque, u64, u64, ListKind, ListCompletion) void,
    knows_peer_fn: *const fn (*anyopaque, u64, []const u8) bool,
    accepts_fn: *const fn (*anyopaque, u64) bool,
    complete_conversation_fn: *const fn (*anyopaque, u64, []const u8, ConversationPageKind, []const Message) void,
    stop_fn: *const fn (*anyopaque) void,
};

// ---------------------------------------------------------------------------
// Tests.

const testing = std.testing;

test "MetaTeam is recognised only by its published endpoint format" {
    var key: [256]u8 = undefined;
    const accepted = [_]struct { []const u8, []const u8, []const u8 }{
        .{ "https://team.example.test/agent/v1/mcp/k/abc123", "https://team.example.test", "abc123" },
        .{ "http://192.0.2.10:8080/agent/v1/mcp/k/abc", "http://192.0.2.10:8080", "abc" },
        .{ "https://example.test/metateam/agent/v1/mcp/k/k-1_2.3~/", "https://example.test/metateam", "k-1_2.3~" },
        .{ "HTTPS://example.test/agent/v1/mcp/k/a%2Bb", "HTTPS://example.test", "a+b" },
        .{ "http://[::1]:9/agent/v1/mcp/k/x", "http://[::1]:9", "x" },
    };
    for (accepted) |case| {
        const match = matchDeviceEndpoint(case[0], &key) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(case[1], match.base);
        try testing.expectEqualStrings(case[2], match.key);
    }
    const rejected = [_][]const u8{
        "ftp://example.test/agent/v1/mcp/k/abc",
        "https://user@example.test/agent/v1/mcp/k/abc",
        "https://example.test/agent/v1/mcp/k/abc?x=1",
        "https://example.test/agent/v1/mcp/k/abc#f",
        "https://example.test/agent/v1/mcp/k/",
        "https://example.test/agent/v1/mcp/k/a/b",
        "https://example.test/agent/v1/mcp/abc",
        "https://example.test/mcp/k/abc",
        "https://metateam.example.test/mcp",
        "https://example.test/agent/v1/mcp/k/a%20b",
        "https://example.test/agent/v1/mcp/k/a%zz",
        "https://example.test/agent/v1/mcp/k/a b",
        "https:///agent/v1/mcp/k/abc",
        "/agent/v1/mcp/k/abc",
    };
    for (rejected) |url| try testing.expect(matchDeviceEndpoint(url, &key) == null);
}

test "request URLs keep the key out and encode every value" {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeUrl(&writer, "http://h.test/base", .unread);
    try testing.expectEqualStrings("http://h.test/base/open/v1/unread", writer.buffered());
    writer = .fixed(&buffer);
    try writeUrl(&writer, "http://h.test", .{ .messages = .{ .peer = "a b&c", .before = "9", .limit = 50 } });
    try testing.expectEqualStrings("http://h.test/open/v1/messages?peer=a%20b%26c&beforeId=9&limit=50", writer.buffered());
    writer = .fixed(&buffer);
    try writeUrl(&writer, "http://h.test", .{ .messages = .{ .limit = 200 } });
    try testing.expectEqualStrings("http://h.test/open/v1/messages?limit=200", writer.buffered());
    writer = .fixed(&buffer);
    try writeUrl(&writer, "http://h.test", .{ .task = "13066" });
    try testing.expectEqualStrings("http://h.test/open/v1/tasks/13066", writer.buffered());
}

test "responses keep numeric and string ids as exact text" {
    var unread = try parseUnread(testing.allocator,
        \\{"data":{"unread":3,"byPeer":[{"peer":{"id":"u-1","name":"Ann","extra":1},"unread":2},{"peer":{"id":18446744073709551615,"username":"bob"},"unread":1}],"more":true}}
    );
    defer unread.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 3), unread.total);
    try testing.expectEqualStrings("u-1", unread.by_peer[0].peer.id.slice());
    try testing.expectEqualStrings("Ann", unread.by_peer[0].peer.name.slice());
    try testing.expectEqualStrings("18446744073709551615", unread.by_peer[1].peer.id.slice());
    try testing.expectEqualStrings("bob", unread.by_peer[1].peer.name.slice());

    var messages = try parseMessages(testing.allocator,
        \\{"data":{"messages":[
        \\ {"id":12,"time":1795428968292,"direction":"in","from":{"id":"u-1","name":"Ann"},"recipients":[{"id":"me","read":true}],"text":"hi","taskIds":[13066,"t-2"]},
        \\ {"id":"m-13","time":"2026-11-23T10:00:00.5+08:00","direction":"out","from":{"id":"me"},"recipients":[{"id":"u-1"},{"id":"u-2","name":"Cy"}],"text":"group","unknown":{}}
        \\]}}
    );
    defer messages.deinit();
    try testing.expectEqual(@as(usize, 2), messages.items.len);
    try testing.expectEqualStrings("12", messages.items[0].id.slice());
    try testing.expectEqual(@as(u64, 1795428968292), messages.items[0].sent_at_ms);
    try testing.expectEqualStrings("13066", messages.items[0].task_ids[0].slice());
    try testing.expectEqualStrings("t-2", messages.items[0].task_ids[1].slice());
    try testing.expectEqual(@as(usize, 1), messages.items[0].peers().len);
    try testing.expectEqual(@as(usize, 2), messages.items[1].peers().len);
    try testing.expectEqual(@as(u64, 1795399200500), messages.items[1].sent_at_ms);
}

test "unusable responses are rejected as a whole" {
    const bad = [_][]const u8{
        "",
        "[]",
        "{\"error\":{\"code\":\"401\"}}",
        "{\"data\":{\"byPeer\":[]}}",
        "{\"data\":{\"unread\":1.5}}",
        "{\"data\":{\"unread\":-1}}",
        "{\"data\":{\"unread\":1,\"byPeer\":[{\"peer\":{\"id\":1.5},\"unread\":1}]}}",
        "{\"data\":{\"unread\":1,\"byPeer\":{}}}",
    };
    for (bad) |body| try testing.expectError(error.InvalidResponse, parseUnread(testing.allocator, body));
    const bad_messages = [_][]const u8{
        "{\"data\":{}}",
        "{\"data\":{\"messages\":[{\"id\":1,\"time\":1,\"direction\":\"sideways\",\"from\":{\"id\":1},\"text\":\"\"}]}}",
        "{\"data\":{\"messages\":[{\"id\":1,\"time\":\"yesterday\",\"direction\":\"in\",\"from\":{\"id\":1},\"text\":\"\"}]}}",
        "{\"data\":{\"messages\":[{\"id\":1,\"time\":1,\"direction\":\"in\",\"from\":{\"id\":1}}]}}",
        "{\"data\":{\"messages\":[{\"id\":1,\"time\":1,\"direction\":\"out\",\"from\":{\"id\":1},\"text\":\"x\"}]}}",
        "{\"data\":{\"messages\":[{\"id\":\"a b\",\"time\":1,\"direction\":\"in\",\"from\":{\"id\":1},\"text\":\"\"}]}}",
    };
    for (bad_messages) |body| try testing.expectError(error.InvalidResponse, parseMessages(testing.allocator, body));
}

test "task details read only the fields shown" {
    var task = try parseTask(testing.allocator,
        \\{"data":{"id":13066,"name":"Inbox","progress":"doing","path":"metawork / Inbox","assignees":[{"name":"Ann"},"Bob",3],"desc":"Read only","updatedAt":1795428968292,"other":[1]}}
    );
    defer task.deinit();
    try testing.expectEqualStrings("13066", task.id.?.slice());
    try testing.expectEqualStrings("Inbox", task.name);
    try testing.expectEqualStrings("doing", task.progress.?);
    try testing.expectEqual(@as(usize, 2), task.assignees.len);
    try testing.expectEqualStrings("Read only", task.description.?);
    try testing.expectEqual(@as(?u64, 1795428968292), task.updated_at_ms);
    try testing.expectError(error.InvalidResponse, parseTask(testing.allocator, "{\"data\":{\"id\":1}}"));
}

test "ISO instants become Unix milliseconds" {
    try testing.expectEqual(@as(?u64, 0), parseIsoMilliseconds("1970-01-01T00:00:00Z"));
    try testing.expectEqual(@as(?u64, 951782400000), parseIsoMilliseconds("2000-02-29 00:00:00"));
    try testing.expectEqual(@as(?u64, 1795428968292), parseIsoMilliseconds("2026-11-23T10:16:08.292Z"));
    try testing.expectEqual(@as(?u64, 1795428968292), parseIsoMilliseconds("2026-11-23T18:16:08.292+0800"));
    try testing.expect(parseIsoMilliseconds("2026-02-30T00:00:00Z") == null);
    try testing.expect(parseIsoMilliseconds("2026-11-23T08:16:08Q") == null);
}

test "the preview is the first line, cut on a character boundary" {
    try testing.expectEqualStrings("first", preview("  first\nsecond").slice());
    const long = "你" ** 200;
    const cut = preview(long);
    try testing.expectEqual(@as(usize, Limits.preview_codepoints * 3), cut.len);
    try testing.expect(std.unicode.utf8ValidateSlice(cut.slice()));
}

fn testPeers(comptime id: []const u8) []const Peer {
    return &struct {
        const value = [1]Peer{.{ .id = Id.init(id) catch unreachable, .name = .truncated(id) }};
    }.value;
}

fn testRecipients(comptime id: []const u8) []const Recipient {
    return &struct {
        const value = [1]Recipient{.{ .peer = testPeers(id)[0], .read = false, .read_at_ms = null }};
    }.value;
}

fn testMessage(id: []const u8, at: u64, direction: Direction, comptime peer: []const u8, text: []const u8) Message {
    const person = testPeers(peer);
    const user: Peer = .{ .id = Id.init("u-self") catch unreachable, .name = .truncated("Me") };
    return .{
        .id = Id.init(id) catch unreachable,
        .sent_at_ms = at,
        .direction = direction,
        .from = if (direction == .in) person[0] else user,
        .recipients = if (direction == .in) &.{} else testRecipients(peer),
        .text = text,
        .task_ids = &.{},
        .conversations = person,
    };
}

const fingerprint_a: [64]u8 = @splat('a');
const fingerprint_b: [64]u8 = @splat('b');

test "binding, polling and backoff follow the results" {
    var runtime: Runtime = .init(testing.allocator);
    defer runtime.deinit();
    runtime.start(true);
    try testing.expect(runtime.nextPoll() == null);
    try testing.expect(try runtime.bind(1000, .{ .server_id = "s1", .fingerprint = fingerprint_a }));
    const first = runtime.binding;
    try testing.expectEqual(State.checking, runtime.state);
    try testing.expectEqual(@as(?u64, 1000), runtime.nextPoll());
    try testing.expect(!try runtime.bind(2000, .{ .server_id = "s1", .fingerprint = fingerprint_a }));

    var id = runtime.beginPoll().?;
    try testing.expect(runtime.nextPoll() == null);
    var by_peer = [_]PeerUnread{.{ .peer = .{ .id = try .init("u1"), .name = .truncated("Ann") }, .unread = 2 }};
    const unread: Unread = .{ .total = 2, .by_peer = &by_peer };
    try testing.expect(try runtime.completePoll(1000, 5, id, .{ .unread = &unread }));
    try testing.expectEqual(State.ready, runtime.state);
    try testing.expectEqual(@as(?u64, 61_000), runtime.nextPoll());
    try testing.expectEqual(@as(u64, 2), runtime.view().unreadTotal.?.value);
    try testing.expectEqual(@as(usize, 1), runtime.view().conversations.len);

    for (Limits.retry_ms ++ [_]u64{300_000}) |delay| {
        id = runtime.beginPoll().?;
        try testing.expect(try runtime.completePoll(100_000, 6, id, .{ .failed = .{ .@"unreachable" = .{ .phase = .connect, .cause = .connect_failed, .elapsed = .under_1s } } }));
        try testing.expectEqual(@as(?u64, 100_000 + delay), runtime.nextPoll());
    }
    // The last good count stays visible while the service is away.
    try testing.expectEqual(State.@"unreachable", runtime.view().state);
    try testing.expectEqual(@as(u64, 2), runtime.view().unreadTotal.?.value);
    try testing.expect(runtime.view().diagnostic != null);

    id = runtime.beginPoll().?;
    try testing.expect(try runtime.completePoll(200_000, 7, id, .{ .failed = .reauthorize }));
    try testing.expect(runtime.nextPoll() == null);
    try testing.expect(runtime.view().unreadTotal == null);
    try testing.expectEqual(CommandOutcome.accepted, runtime.requestRefresh(200_000, first, true));
    try testing.expectEqual(CommandOutcome.rejected, runtime.requestRefresh(200_000, first + 1, true));

    runtime.setActive(300_000, false);
    try testing.expect(runtime.nextPoll() == null);

    // A replaced connection starts over under a new binding.
    try testing.expect(try runtime.bind(400_000, .{ .server_id = "s1", .fingerprint = fingerprint_b }));
    try testing.expect(runtime.binding != first);
    try testing.expectEqual(State.checking, runtime.state);
    try testing.expect(runtime.view().unreadTotal == null);
    try testing.expectEqual(@as(usize, 0), runtime.view().conversations.len);
    try testing.expect(runtime.nextPoll() == null); // still in the background
    runtime.setActive(400_100, true);
    try testing.expectEqual(@as(?u64, 400_000), runtime.nextPoll());

    try testing.expect(try runtime.bind(500_000, null));
    try testing.expectEqual(State.unavailable, runtime.state);
    try testing.expect(!try runtime.bind(500_000, null));
}

test "returning to the foreground asks again only after a quiet period" {
    var runtime: Runtime = .init(testing.allocator);
    defer runtime.deinit();
    runtime.start(true);
    _ = try runtime.bind(0, .{ .server_id = "s1", .fingerprint = fingerprint_a });
    const id = runtime.beginPoll().?;
    const unread: Unread = .{ .total = 0, .by_peer = &.{} };
    _ = try runtime.completePoll(1000, 1, id, .{ .unread = &unread });
    runtime.setActive(2000, false);
    runtime.setActive(5000, true);
    try testing.expectEqual(@as(?u64, 61_000), runtime.nextPoll());
    runtime.setActive(6000, false);
    runtime.setActive(16_000, true);
    try testing.expectEqual(@as(?u64, 16_000), runtime.nextPoll());
}

test "the conversation list grows from pages and closes gaps by starting over" {
    var runtime: Runtime = .init(testing.allocator);
    defer runtime.deinit();
    runtime.start(true);
    _ = try runtime.bind(0, .{ .server_id = "s1", .fingerprint = fingerprint_a });
    const binding = runtime.binding;
    var by_peer = [_]PeerUnread{
        .{ .peer = .{ .id = try .init("ann"), .name = .truncated("Ann") }, .unread = 1 },
        .{ .peer = .{ .id = try .init("old"), .name = .truncated("Old") }, .unread = 4 },
    };
    const unread: Unread = .{ .total = 5, .by_peer = &by_peer };
    _ = try runtime.completePoll(0, 1, runtime.beginPoll().?, .{ .unread = &unread });
    try testing.expectEqual(CommandOutcome.accepted, runtime.requestRefresh(0, binding, false));

    const first = runtime.beginList().?;
    try testing.expectEqual(ListKind.initial, first.kind);
    try testing.expect(runtime.view().loadingConversations);
    const page = [_]Message{
        testMessage("1", 10, .in, "bob", "hello bob"),
        testMessage("2", 20, .in, "ann", "first"),
        testMessage("3", 30, .out, "ann", "reply"),
    };
    const window = [_]Message{ page[0], page[1], page[2] };
    try testing.expect(try runtime.completeList(0, first.id, .initial, .{ .page = .{ .messages = &window, .limit = Limits.list_page } }));
    var view = runtime.view();
    try testing.expect(view.conversationsLoaded and !view.hasEarlier);
    // An unread member outside the window still has a row, without a message.
    try testing.expectEqual(@as(usize, 3), view.conversations.len);
    try testing.expectEqualStrings("old", view.conversations[0].peerId);
    try testing.expect(view.conversations[0].latest == null);
    try testing.expectEqualStrings("ann", view.conversations[1].peerId);
    try testing.expectEqualStrings("reply", view.conversations[1].latest.?.preview);
    try testing.expectEqual(Direction.out, view.conversations[1].latest.?.direction);
    try testing.expectEqual(@as(u64, 1), view.conversations[1].unread.value);
    try testing.expectEqualStrings("bob", view.conversations[2].peerId);
    try testing.expectEqual(CommandOutcome.rejected, runtime.requestEarlier(binding));

    // A full newer page may hide a gap, so the window starts over from it.
    _ = runtime.requestRefresh(0, binding, false);
    const newer = runtime.beginList().?;
    try testing.expectEqual(ListKind.newer, newer.kind);
    try testing.expectEqualStrings("3", newer.anchor.?.slice());
    var full: [Limits.list_page]Message = undefined;
    for (&full, 0..) |*message, i| message.* = testMessage("9", 100 + i, .in, "cy", "busy");
    _ = try runtime.completeList(0, newer.id, .newer, .{ .page = .{ .messages = &full, .limit = Limits.list_page } });
    view = runtime.view();
    try testing.expect(view.hasEarlier);
    try testing.expectEqual(@as(usize, 3), view.conversations.len); // two unread without summary + cy
    try testing.expectEqualStrings("cy", view.conversations[2].peerId);

    // Earlier pages only add conversations the window does not have.
    try testing.expectEqual(CommandOutcome.accepted, runtime.requestEarlier(binding));
    const earlier = runtime.beginList().?;
    try testing.expectEqual(ListKind.earlier, earlier.kind);
    const older = [_]Message{ testMessage("1", 10, .in, "bob", "hello bob"), testMessage("8", 99, .in, "cy", "older cy") };
    _ = try runtime.completeList(0, earlier.id, .earlier, .{ .page = .{ .messages = &older, .limit = Limits.list_page } });
    view = runtime.view();
    try testing.expect(!view.hasEarlier);
    for (view.conversations) |row| if (std.mem.eql(u8, row.peerId, "cy")) try testing.expectEqualStrings("busy", row.latest.?.preview);
}

test "an empty first page is asked for again instead of continuing from nothing" {
    var runtime: Runtime = .init(testing.allocator);
    defer runtime.deinit();
    runtime.start(true);
    _ = try runtime.bind(0, .{ .server_id = "s1", .fingerprint = fingerprint_a });
    const binding = runtime.binding;
    _ = runtime.requestRefresh(0, binding, false);
    const first = runtime.beginList().?;
    _ = try runtime.completeList(0, first.id, .initial, .{ .page = .{ .messages = &.{}, .limit = Limits.list_page } });
    try testing.expect(runtime.view().conversationsLoaded);
    try testing.expect(runtime.newest == null);
    _ = runtime.requestRefresh(0, binding, false);
    const again = runtime.beginList().?;
    try testing.expectEqual(ListKind.initial, again.kind);
    try testing.expect(again.anchor == null);
}

test "an automatic refresh keeps the background rules; only an explicit retry passes them" {
    var runtime: Runtime = .init(testing.allocator);
    defer runtime.deinit();
    runtime.start(false);
    _ = try runtime.bind(0, .{ .server_id = "s1", .fingerprint = fingerprint_a });
    const binding = runtime.binding;
    // In the background nothing is asked automatically.
    try testing.expectEqual(CommandOutcome.rejected, runtime.requestRefresh(0, binding, false));
    try testing.expect(!runtime.listPending());
    runtime.setActive(0, true);
    try testing.expectEqual(CommandOutcome.accepted, runtime.requestRefresh(0, binding, false));
    runtime.pending_newer = false;
    // Inside a failure's retry delay, and while refused, it waits.
    var id = runtime.beginPoll().?;
    _ = try runtime.completePoll(1000, 1, id, .{ .failed = .{ .@"unreachable" = null } });
    try testing.expectEqual(CommandOutcome.rejected, runtime.requestRefresh(1000 + Limits.retry_ms[0] - 1, binding, false));
    try testing.expectEqual(CommandOutcome.accepted, runtime.requestRefresh(1000 + Limits.retry_ms[0], binding, false));
    runtime.pending_newer = false;
    id = runtime.beginPoll().?;
    _ = try runtime.completePoll(2000, 2, id, .{ .failed = .reauthorize });
    try testing.expectEqual(CommandOutcome.rejected, runtime.requestRefresh(10_000_000, binding, false));
    try testing.expectEqual(CommandOutcome.accepted, runtime.requestRefresh(2000, binding, true));
    try testing.expectEqual(CommandOutcome.rejected, runtime.requestRefresh(2000, binding + 1, true));
}

test "one task or conversation read never changes the connection state" {
    var runtime: Runtime = .init(testing.allocator);
    defer runtime.deinit();
    runtime.start(true);
    _ = try runtime.bind(0, .{ .server_id = "s1", .fingerprint = fingerprint_a });
    const binding = runtime.binding;
    const unread: Unread = .{ .total = 0, .by_peer = &.{} };
    _ = try runtime.completePoll(0, 1, runtime.beginPoll().?, .{ .unread = &unread });
    try testing.expect(!runtime.knowsPeer(binding, "ann"));
    const page = [_]Message{testMessage("5", 50, .in, "ann", "newest")};
    try testing.expect(try runtime.completeConversation(binding, "ann", .latest, &page));
    try testing.expect(runtime.knowsPeer(binding, "ann"));
    try testing.expect(!runtime.knowsPeer(binding + 1, "ann"));
    try testing.expect(!try runtime.completeConversation(binding + 1, "ann", .latest, &page));
    // A refused or missing task is that request's outcome alone.
    try testing.expectEqual(RequestFailure.forbidden, requestFailure(403));
    try testing.expectEqual(RequestFailure.forbidden, requestFailure(401));
    try testing.expectEqual(RequestFailure.not_found, requestFailure(404));
    try testing.expectEqual(RequestFailure.failed, requestFailure(500));
    try testing.expectEqual(RequestFailure.failed, requestFailure(null));
    try testing.expectEqual(State.ready, runtime.state);
    try testing.expect(runtime.nextPoll() != null);
    try testing.expect(!validTaskId(".."));
    try testing.expect(!validTaskId("."));
    try testing.expect(validTaskId("13066"));
}

test "a rebuilt window keeps the conversation being read" {
    var runtime: Runtime = .init(testing.allocator);
    defer runtime.deinit();
    runtime.start(true);
    _ = try runtime.bind(0, .{ .server_id = "s1", .fingerprint = fingerprint_a });
    const binding = runtime.binding;
    _ = runtime.requestRefresh(0, binding, false);
    const first = runtime.beginList().?;
    const window = [_]Message{testMessage("2", 20, .in, "ann", "first")};
    _ = try runtime.completeList(0, first.id, .initial, .{ .page = .{ .messages = &window, .limit = Limits.list_page } });
    _ = try runtime.completeConversation(binding, "ann", .latest, &window);
    _ = runtime.requestRefresh(0, binding, false);
    const newer = runtime.beginList().?;
    var full: [Limits.list_page]Message = undefined;
    for (&full, 0..) |*message, i| message.* = testMessage("9", 100 + i, .in, "cy", "busy");
    _ = try runtime.completeList(0, newer.id, .newer, .{ .page = .{ .messages = &full, .limit = Limits.list_page } });
    try testing.expect(runtime.knowsPeer(binding, "ann"));
    var found = false;
    for (runtime.view().conversations) |row| {
        if (std.mem.eql(u8, row.peerId, "ann")) found = true;
    }
    try testing.expect(found);
}

test "a member listed twice is one row" {
    var unread = try parseUnread(testing.allocator,
        \\{"data":{"unread":3,"byPeer":[{"peer":{"id":7,"name":"Ann"},"unread":1},{"peer":{"id":"7","name":"Ann"},"unread":2}]}}
    );
    defer unread.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), unread.by_peer.len);
    try testing.expectEqual(@as(u64, 3), unread.by_peer[0].unread);
    var messages = try parseMessages(testing.allocator,
        \\{"data":{"messages":[
        \\ {"id":1,"time":1,"direction":"out","from":{"id":"me"},"recipients":[{"id":"a"},{"id":"a"}],"text":"x","taskIds":[5,"5"]},
        \\ {"id":"1","time":1,"direction":"in","from":{"id":"a"},"text":"again"}
        \\]}}
    );
    defer messages.deinit();
    try testing.expectEqual(@as(usize, 1), messages.items.len);
    try testing.expectEqual(@as(usize, 1), messages.items[0].recipients.len);
    try testing.expectEqual(@as(usize, 1), messages.items[0].task_ids.len);
}

test "new marks, sending agents, read receipts and unread times are read when present" {
    var messages = try parseMessages(testing.allocator,
        \\{"data":{"messages":[
        \\ {"id":1,"time":"2026-11-21T03:06:40.000Z","at":1795240000000,"direction":"out","from":{"id":"me-1","username":"wenlin","name":"Lin"},"text":"group","taskIds":[],
        \\  "recipients":[{"id":"a","username":"ann","name":"Ann","readAt":1795240100000},{"id":"b","name":"Bob","readAt":null},{"id":"c","name":"Cy","readAt":"yesterday"},{"id":"a","readAt":null}]},
        \\ {"id":2,"time":2,"direction":"in","from":{"id":"a","username":"ann","name":"Ann"},"text":"by agent","new":true,"readAt":5,"fromAgent":"claude-code@box"},
        \\ {"id":3,"time":3,"direction":"in","from":{"id":"a","name":"Ann"},"text":"seen","new":"yes","fromAgent":null}
        \\]}}
    );
    defer messages.deinit();
    const group = messages.items[0];
    try testing.expectEqual(@as(usize, 3), group.recipients.len);
    try testing.expect(group.recipients[0].read);
    try testing.expectEqual(@as(?u64, 1795240100000), group.recipients[0].read_at_ms);
    try testing.expect(!group.recipients[1].read);
    // Read at a time this client cannot parse is still read.
    try testing.expect(group.recipients[2].read and group.recipients[2].read_at_ms == null);
    try testing.expectEqualStrings("wenlin", group.from.username.?.slice());
    try testing.expect(group.recipients[1].peer.username == null);
    try testing.expect(!group.is_new);
    try testing.expect(messages.items[1].is_new);
    try testing.expectEqualStrings("claude-code@box", messages.items[1].from_agent.?.slice());
    try testing.expect(!messages.items[2].is_new);
    try testing.expect(messages.items[2].from_agent == null);

    var unread = try parseUnread(testing.allocator,
        \\{"data":{"unread":3,"byPeer":[{"peer":{"id":"a","username":"ann","name":"Ann"},"unread":2,"lastAt":1795241730816,"lastTime":"2026-11-21T03:35:30.816Z"},
        \\ {"peer":{"id":"b"},"unread":1,"lastTime":"2026-11-21T01:10:48.681Z"},{"peer":{"id":"c"},"unread":1,"lastAt":"soon"},{"peer":{"id":"a"},"unread":1,"lastAt":1}]}}
    );
    defer unread.deinit(testing.allocator);
    try testing.expectEqual(@as(?u64, 1795241730816), unread.by_peer[0].last_at_ms);
    try testing.expectEqual(@as(u64, 3), unread.by_peer[0].unread);
    try testing.expectEqual(parseIsoMilliseconds("2026-11-21T01:10:48.681Z"), unread.by_peer[1].last_at_ms);
    try testing.expect(unread.by_peer[2].last_at_ms == null);

    var runtime: Runtime = .init(testing.allocator);
    defer runtime.deinit();
    runtime.start(true);
    _ = try runtime.bind(0, .{ .server_id = "s1", .fingerprint = fingerprint_a });
    _ = try runtime.completePoll(0, 1, runtime.beginPoll().?, .{ .unread = &unread });
    const rows = runtime.view().conversations;
    try testing.expectEqual(@as(usize, 3), rows.len);
    for (rows) |row| if (std.mem.eql(u8, row.peerId, "a")) {
        try testing.expect(row.latest == null);
        try testing.expectEqual(@as(u64, 1795241730816), row.lastAtMs.?.value);
    };
}

test "messages to oneself belong to the me conversation and never break the page" {
    var messages = try parseMessages(testing.allocator,
        \\{"data":{"messages":[
        \\ {"id":1,"time":1,"direction":"self","from":{"id":"u-me","username":"zj","name":"Zhu"},"text":"note to self","taskIds":[]},
        \\ {"id":2,"time":2,"direction":"self","from":{"id":"u-me","name":"Zhu"},"recipients":[{"id":"u-me","name":"Zhu","readAt":null},{"id":"ann","name":"Ann","readAt":null}],"text":"group with me"},
        \\ {"id":3,"time":3,"direction":"in","from":{"id":"ann","name":"Ann"},"text":"hi"}
        \\]}}
    );
    defer messages.deinit();
    try testing.expectEqual(@as(usize, 3), messages.items.len);
    try testing.expectEqual(Direction.self, messages.items[0].direction);
    try testing.expectEqual(@as(usize, 1), messages.items[0].peers().len);
    try testing.expectEqualStrings(self_peer_id, messages.items[0].peers()[0].id.slice());
    // A group message that also went to the user: `me` and every other
    // recipient, never the user's own member id.
    try testing.expectEqual(@as(usize, 2), messages.items[1].peers().len);
    try testing.expectEqualStrings(self_peer_id, messages.items[1].peers()[0].id.slice());
    try testing.expectEqualStrings("ann", messages.items[1].peers()[1].id.slice());

    var runtime: Runtime = .init(testing.allocator);
    defer runtime.deinit();
    runtime.start(true);
    _ = try runtime.bind(0, .{ .server_id = "s1", .fingerprint = fingerprint_a });
    _ = runtime.requestRefresh(0, runtime.binding, false);
    const first = runtime.beginList().?;
    _ = try runtime.completeList(0, first.id, .initial, .{ .page = .{ .messages = messages.items, .limit = Limits.list_page } });
    const view = runtime.view();
    try testing.expectEqual(@as(usize, 2), view.conversations.len);
    try testing.expectEqualStrings("ann", view.conversations[0].peerId);
    try testing.expectEqualStrings(self_peer_id, view.conversations[1].peerId);
    try testing.expectEqual(Direction.self, view.conversations[1].latest.?.direction);
    try testing.expect(runtime.knowsPeer(runtime.binding, self_peer_id));
}
