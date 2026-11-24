//! Application adapter for the message module's device-local SQLite store.
const std = @import("std");
const inbox = @import("metawork_product_inbox");
const sql = @import("metawork_storage_sql");
const sqlite = @import("metawork_storage_sqlite");

pub const migrations = [_]sql.Migration{.{ .version = 1, .name = "message_history", .sql = inbox.database_schema }};

pub fn open(io: std.Io, allocator: std.mem.Allocator, directory: []const u8) !*sqlite.Database {
    const path = try std.fs.path.join(allocator, &.{ directory, inbox.database_name });
    defer allocator.free(path);
    return sqlite.Database.create(io, allocator, .{ .file = path }, &migrations);
}

fn optionalName(value: sql.Value) !?inbox.Name {
    return if (value == .null_value) null else try inbox.Name.init(value.blob);
}

fn nameParam(value: *const ?inbox.Name) sql.Value {
    return if (value.*) |*name| .{ .blob = name.slice() } else .null_value;
}

fn receiveRows(comptime Rows: type) *const fn (*anyopaque, sql.Row) void {
    return struct {
        fn receive(raw: *anyopaque, row: sql.Row) void {
            const rows: *Rows = @ptrCast(@alignCast(raw));
            if (!rows.failed) rows.append(row) catch {
                rows.failed = true;
            };
        }
    }.receive;
}

// Sparse merge patches accumulate positive read receipts by recipient id.
// An empty object means read at an unknown time. An absent key means unread.
fn encodeRecipients(a: std.mem.Allocator, recipients: []const inbox.Recipient) !struct { peers: []const u8, receipts: []const u8 } {
    const peers = try a.alloc(inbox.Peer, recipients.len);
    var receipts: std.json.Value = .{ .object = .empty };
    for (recipients, peers) |recipient, *peer| {
        peer.* = recipient.peer;
        if (!recipient.read) continue;
        var receipt: std.json.Value = .{ .object = .empty };
        if (recipient.read_at_ms) |at| try receipt.object.put(a, "at", .{ .integer = @intCast(at) });
        try receipts.object.put(a, peer.id.slice(), receipt);
    }
    return .{ .peers = try std.json.Stringify.valueAlloc(a, peers, .{}), .receipts = try std.json.Stringify.valueAlloc(a, receipts, .{}) };
}

fn decodeRecipients(a: std.mem.Allocator, peers_json: []const u8, receipts_json: []const u8) ![]inbox.Recipient {
    const peers = try std.json.parseFromSliceLeaky([]inbox.Peer, a, peers_json, .{});
    const receipts = try std.json.parseFromSliceLeaky(std.json.Value, a, receipts_json, .{});
    if (receipts != .object) return error.InvalidReceipt;
    const result = try a.alloc(inbox.Recipient, peers.len);
    for (peers, result) |peer, *recipient| {
        const receipt = receipts.object.get(peer.id.slice());
        recipient.* = .{ .peer = peer, .read = receipt != null, .read_at_ms = null };
        if (receipt) |r| {
            if (r != .object) return error.InvalidReceipt;
            if (r.object.get("at")) |at| {
                if (at != .integer or at.integer < 0) return error.InvalidReceipt;
                recipient.read_at_ms = @intCast(at.integer);
            }
        }
    }
    return result;
}

const Batch = struct {
    arena: std.mem.Allocator,
    writes: std.ArrayList(sql.Mutation) = .empty,

    fn add(self: *Batch, statement: []const u8, params: []const sql.Value) !void {
        try self.writes.append(self.arena, .{ .statement = .{ .sql = statement, .params = try self.arena.dupe(sql.Value, params) } });
    }
};

pub const Store = struct {
    db: sql.Database,
    scope: [32]u8,

    pub fn latest(self: *const Store, allocator: std.mem.Allocator, peer: []const u8) !?struct { page: inbox.Messages, has_earlier: bool } {
        var page = inbox.Messages{ .arena = .init(allocator), .items = &.{} };
        errdefer page.deinit();
        const Rows = struct {
            a: std.mem.Allocator,
            items: std.ArrayList(inbox.Message) = .empty,
            at_start: bool = false,
            failed: bool = false,

            fn append(r: *@This(), row: sql.Row) !void {
                const direction = std.meta.stringToEnum(inbox.Direction, row.value(2).text) orelse return error.InvalidDirection;
                const from = try std.json.parseFromSliceLeaky(inbox.Peer, r.a, row.value(3).text, .{});
                const recipients = try decodeRecipients(r.a, row.value(6).text, row.value(7).text);
                try r.items.append(r.a, .{
                    .id = try .init(row.value(0).text),
                    .sent_at_ms = @intCast(row.value(1).integer),
                    .direction = direction,
                    .from = from,
                    .text = try r.a.dupe(u8, row.value(4).blob),
                    .from_agent = try optionalName(row.value(5)),
                    .recipients = recipients,
                    .task_ids = try std.json.parseFromSliceLeaky([]inbox.Id, r.a, row.value(8).text, .{}),
                    .is_new = row.value(9).integer != 0,
                    .conversations = try inbox.conversationPeers(r.a, direction, from, recipients),
                });
                r.at_start = row.value(10).integer != 0;
            }
        };
        var limit: u32 = inbox.Limits.conversation_page;
        while (true) {
            var rows = Rows{ .a = page.arena.allocator() };
            const result = self.db.query(
                \\WITH RECURSIVE timeline(id,start_id,depth) AS (
                \\  SELECT latest_id,history_start_id,1 FROM conversations WHERE binding_id=?1 AND peer_id=?2
                \\  UNION ALL
                \\  SELECT cm.previous_id,t.start_id,t.depth+1 FROM timeline t JOIN conversation_messages cm
                \\    ON (cm.binding_id,cm.peer_id,cm.message_id)=(?1,?2,t.id)
                \\    WHERE cm.previous_id IS NOT NULL AND t.depth<?3
                \\)
                \\SELECT m.message_id,m.sent_at_ms,m.direction,m.sender,CAST(m.body AS BLOB),CAST(m.from_agent AS BLOB),
                \\       m.recipients,m.read_receipts,m.related_ids,m.first_seen_new,m.message_id IS t.start_id
                \\FROM timeline t JOIN messages m ON (m.binding_id,m.message_id)=(?1,t.id) ORDER BY t.depth
            , &.{ .{ .blob = &self.scope }, .{ .text = peer }, .{ .integer = limit } }, .{ .context = &rows, .receive_fn = receiveRows(Rows) });
            if (result == .resource_exhausted and limit > 1) {
                _ = page.arena.reset(.free_all);
                limit /= 2;
                continue;
            }
            if (result != .ok or rows.failed) return error.CacheRead;
            if (rows.items.items.len == 0) {
                page.deinit();
                return null;
            }
            std.mem.reverse(inbox.Message, rows.items.items);
            page.items = rows.items.items;
            return .{ .page = page, .has_earlier = !rows.at_start };
        }
    }

    pub fn save(self: *const Store, allocator: std.mem.Allocator, peer: []const u8, username: ?inbox.Name, kind: inbox.ConversationPageKind, anchor: ?inbox.Id, page: *inbox.Messages, limit: u32) !void {
        const binding: sql.Value = .{ .blob = &self.scope };
        const who: sql.Value = .{ .text = peer };
        const cursor: sql.Value = if (anchor) |*id| .{ .text = id.slice() } else .null_value;
        if (page.items.len == 0) {
            if (kind == .before and self.db.mutate(&.{.{ .statement = .{ .sql =
                \\UPDATE conversations SET history_start_id=?3 WHERE binding_id=?1 AND peer_id=?2
                \\AND EXISTS(SELECT 1 FROM conversation_messages WHERE binding_id=?1 AND peer_id=?2 AND message_id=?3)
            , .params = &.{ binding, who, cursor } } }}) != .committed) return error.CacheWrite;
            return;
        }
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var batch = Batch{ .arena = a };
        const messages = try page.arena.allocator().dupe(inbox.Message, page.items);
        const newest = &messages[messages.len - 1];
        const summary = inbox.openedSummary(peer, newest, username) orelse return error.WrongPeer;
        const reached_start = kind != .after and messages.len < limit;
        try batch.add(
            \\INSERT INTO conversations(binding_id,peer_id,display_name,username,latest_id,latest_at_ms,history_start_id)
            \\VALUES(?1,?2,CAST(?3 AS TEXT),CAST(?4 AS TEXT),?5,?6,?7)
            \\ON CONFLICT(binding_id,peer_id) DO UPDATE SET
            \\ username=coalesce(username,excluded.username), history_start_id=coalesce(excluded.history_start_id,history_start_id)
        , &.{
            binding,
            who,
            .{ .blob = summary.peer.name.slice() },
            nameParam(&summary.peer.username),
            .{ .text = newest.id.slice() },
            .{ .integer = @intCast(newest.sent_at_ms) },
            if (reached_start) .{ .text = messages[0].id.slice() } else .null_value,
        });
        // A response for older history or a repeated, already positioned message
        // cannot replace the head of a newer timeline with an older same-ms id.
        if (kind != .before) try batch.add(
            \\UPDATE conversations SET latest_id=?3, latest_at_ms=?4, display_name=CAST(?5 AS TEXT),
            \\ username=coalesce(CAST(?6 AS TEXT),username)
            \\WHERE binding_id=?1 AND peer_id=?2 AND (latest_id=?3 OR latest_at_ms<?4 OR
            \\ (latest_at_ms=?4 AND NOT EXISTS(SELECT 1 FROM conversation_messages WHERE binding_id=?1 AND peer_id=?2 AND message_id=?3)))
        , &.{
            binding,                                who,                               .{ .text = newest.id.slice() }, .{ .integer = @intCast(newest.sent_at_ms) },
            .{ .blob = summary.peer.name.slice() }, nameParam(&summary.peer.username),
        });
        for (messages, 0..) |*msg, i| {
            for (msg.peers()) |member| {
                if (member.id.eql(peer)) break;
            } else return error.WrongPeer;
            const recipients = try encodeRecipients(a, msg.recipients);
            try batch.add(
                \\INSERT INTO messages(binding_id,message_id,sent_at_ms,direction,sender,body,from_agent,recipients,read_receipts,related_ids,first_seen_new)
                \\VALUES(?,?,?,?,?,CAST(? AS TEXT),CAST(? AS TEXT),?,?,?,?)
                \\ON CONFLICT(binding_id,message_id) DO UPDATE SET read_receipts=json_patch(messages.read_receipts,excluded.read_receipts)
            , &.{
                binding,
                .{ .text = msg.id.slice() },
                .{ .integer = @intCast(msg.sent_at_ms) },
                .{ .text = @tagName(msg.direction) },
                .{ .text = try std.json.Stringify.valueAlloc(a, msg.from, .{}) },
                .{ .blob = msg.text },
                nameParam(&msg.from_agent),
                .{ .text = recipients.peers },
                .{ .text = recipients.receipts },
                .{ .text = try std.json.Stringify.valueAlloc(a, msg.task_ids, .{}) },
                .{ .integer = @intFromBool(msg.is_new) },
            });
            const previous: sql.Value = if (i > 0) .{ .text = messages[i - 1].id.slice() } else if (kind == .after and messages.len < limit) cursor else .null_value;
            try batch.add(
                \\INSERT INTO conversation_messages(binding_id,peer_id,message_id,previous_id)
                \\VALUES(?1,?2,?3,(SELECT message_id FROM conversation_messages WHERE binding_id=?1 AND peer_id=?2 AND message_id=?4))
                \\ON CONFLICT(binding_id,peer_id,message_id) DO UPDATE SET previous_id=coalesce(excluded.previous_id,previous_id)
            , &.{ binding, who, .{ .text = msg.id.slice() }, previous });
        }
        if (kind == .before) try batch.add(
            \\UPDATE conversation_messages SET previous_id=?4 WHERE binding_id=?1 AND peer_id=?2 AND message_id=?3
        , &.{ binding, who, cursor, .{ .text = newest.id.slice() } });
        if (self.db.mutate(batch.writes.items) != .committed) return error.CacheWrite;
        page.items = messages;
        try self.restoreReadState(page.arena.allocator(), messages);
    }

    fn restoreReadState(self: *const Store, a: std.mem.Allocator, messages: []inbox.Message) !void {
        const Rows = struct {
            a: std.mem.Allocator,
            messages: []inbox.Message,
            failed: bool = false,
            fn append(r: *@This(), row: sql.Row) !void {
                for (r.messages) |*msg| if (msg.id.eql(row.value(0).text)) {
                    msg.is_new = row.value(1).integer != 0;
                    msg.recipients = try decodeRecipients(r.a, row.value(2).text, row.value(3).text);
                    break;
                };
            }
        };
        var rows = Rows{ .a = a, .messages = messages };
        var statement: std.Io.Writer.Allocating = .init(a);
        try statement.writer.writeAll("SELECT message_id,first_seen_new,recipients,read_receipts FROM messages WHERE binding_id=? AND message_id IN (");
        var params: std.ArrayList(sql.Value) = .empty;
        try params.append(a, .{ .blob = &self.scope });
        for (messages, 0..) |*msg, i| {
            try statement.writer.writeAll(if (i == 0) "?" else ",?");
            try params.append(a, .{ .text = msg.id.slice() });
        }
        try statement.writer.writeByte(')');
        if (self.db.query(statement.written(), params.items, .{ .context = &rows, .receive_fn = receiveRows(Rows) }) != .ok or rows.failed) return error.CacheRead;
    }
};
