//! A Core event, across a process.
//!
//! The event is the one thing on this link that is not a call. The execution
//! half's Runtime hands its event pump a value that owns its JSON and holds
//! parsed pointers into it, so it could never have been a response -- what
//! crosses is the bytes plus the few facts the Agent verified rather than
//! parsed, and the UI half builds the value again on its own side.
//!
//! That rebuild is why this file is Application-level rather than part of
//! `src/agent/link/`. Parsing a Core event is the Agent's own decoder, and the
//! link module deliberately links no AgentCore archive -- `build.zig` says so
//! where it creates the module. Keeping the event shape here is what lets that
//! stay true.
//!
//! ## What crosses, and what does not
//!
//! The JSON, the two identities, the byte count the pump charges against its
//! budget, and three facts the event's value cannot carry: the generated image
//! path, the generated video path, and the delivery receipt. Those three are
//! *Agent-verified* -- `deliver_file.zig` is explicit that a receipt is never
//! decoded from Core JSON or tool text -- so they are carried beside the bytes
//! rather than re-derived from them. Re-deriving them on this side would be
//! the half that did not run the model vouching for what the model said.
//!
//! The SDK parse owner does not cross and could not: it is pointers into the
//! sender's memory. The UI half parses the same bytes with the same decoder,
//! which is also the check that the bytes are what they claim to be.

const std = @import("std");

const agent = @import("metawork_agent");
const agent_link = @import("metawork_agent_link");

const client = agent_link.client;
const payload_codec = agent_link.payload;

/// What an `event` frame carries.
pub const Payload = struct {
    session_id: u64,
    run_id: u64,
    /// What the sending pump charged for this event. Carried rather than
    /// recomputed so both halves account for the same number: the receiving
    /// pump's own budget has to agree with the one that admitted it.
    encoded_bytes: usize,
    generated_image_path: ?[]const u8,
    generated_video_path: ?[]const u8,
    delivered_file: @FieldType(agent.OwnedCoreEvent, "delivered_file"),
    json: []const u8,

    pub fn from(event: *const agent.OwnedCoreEvent) Payload {
        return .{
            .session_id = event.session_id,
            .run_id = event.run_id,
            .encoded_bytes = event.encoded_bytes,
            .generated_image_path = event.generated_image_path,
            .generated_video_path = event.generated_video_path,
            .delivered_file = event.delivered_file,
            .json = event.json,
        };
    }
};

comptime {
    // No serializer: the shape is what crosses, field by field, and a field
    // that stops being carryable fails the build here rather than at the
    // first event.
    payload_codec.requireStructural(Payload);
}

/// The bytes an `event` frame carries, in an allocation the caller frees.
pub fn encode(
    allocator: std.mem.Allocator,
    event: *const agent.OwnedCoreEvent,
) std.mem.Allocator.Error![]u8 {
    return payload_codec.encodeAlloc(Payload, allocator, Payload.from(event));
}

pub const DecodeError = payload_codec.DecodeError;

/// Rebuilds the event on the receiving side, owning everything it returns.
///
/// The parse is the receiving half's own, with the Agent's decoder: a byte
/// string that does not decode means the peer is not this build, and the
/// caller ends the link rather than queueing something it cannot read.
pub fn decode(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) (DecodeError || std.mem.Allocator.Error || error{MalformedEvent})!agent.OwnedCoreEvent {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const wired = try payload_codec.decodeExact(Payload, arena.allocator(), bytes);

    const json = try allocator.dupe(u8, wired.json);
    errdefer allocator.free(json);
    const image = if (wired.generated_image_path) |path|
        try allocator.dupe(u8, path)
    else
        null;
    errdefer if (image) |owned| allocator.free(owned);
    const video = if (wired.generated_video_path) |path|
        try allocator.dupe(u8, path)
    else
        null;
    errdefer if (video) |owned| allocator.free(owned);

    // Parsed from the bytes that crossed, never from the sender's value: the
    // parse owner holds pointers into `json`, which is this side's copy.
    var parsed = agent.decodeCoreEvent(allocator, json) catch return error.MalformedEvent;
    errdefer parsed.deinit();

    return .{
        .session_id = wired.session_id,
        .run_id = wired.run_id,
        .encoded_bytes = wired.encoded_bytes,
        .generated_image_path = image,
        .generated_video_path = video,
        .delivered_file = wired.delivered_file,
        .json = json,
        .event = parsed,
        .allocator = allocator,
    };
}

/// The UI half's buffer of what arrived.
///
/// `take_event`, `has_pending_events` and `pending_event_count` are answered
/// from here rather than crossing, which is what the registry's `stream`
/// classification means. The licence that makes it honest is narrow: this
/// holds nothing except what the execution half sent, so the answer is still
/// that half's fact, buffered.
///
/// It is bounded, and the bound is the in-process pump's own. That is not a
/// number chosen here: `src/agent/event_pump.zig` admits 512 events and 32 MiB
/// globally, a full pump there already ends the Run it belongs to, and sizing
/// this one to match is what keeps the condition arriving at the same depth it
/// does today.
pub const Pump = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    entries: []?agent.OwnedCoreEvent,
    head: usize = 0,
    count: usize = 0,
    bytes: usize = 0,
    limits: Limits,
    /// How this half's own consumer is woken. Product asks for a wake through
    /// `notify_event_consumer`, and across the link that is a local question:
    /// the events are already here.
    wake: agent.EventReadyNotifier,

    pub const Limits = struct {
        count: usize = 512,
        bytes: usize = 32 * 1024 * 1024,
    };

    pub fn init(
        self: *Pump,
        allocator: std.mem.Allocator,
        io: std.Io,
        limits: Limits,
        wake: agent.EventReadyNotifier,
    ) std.mem.Allocator.Error!void {
        std.debug.assert(limits.count > 0 and limits.bytes > 0);
        const entries = try allocator.alloc(?agent.OwnedCoreEvent, limits.count);
        @memset(entries, null);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .entries = entries,
            .limits = limits,
            .wake = wake,
        };
    }

    pub fn deinit(self: *Pump) void {
        for (self.entries) |*entry| if (entry.*) |*event| {
            var owned = event.*;
            owned.deinit();
            entry.* = null;
        };
        self.allocator.free(self.entries);
        self.* = undefined;
    }

    /// Takes the event if there is room, and says so.
    ///
    /// `false` means this half is at its bound, which the caller has to treat
    /// as the link failing rather than as a dropped event: an event dropped
    /// here is a conversation Product would commit short, and nothing
    /// downstream can tell a short conversation from a complete one.
    pub fn push(self: *Pump, event: agent.OwnedCoreEvent) bool {
        const charged = event.ownedBytes();
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.count == self.entries.len) return false;
        if (self.bytes + charged > self.limits.bytes) return false;
        self.entries[(self.head + self.count) % self.entries.len] = event;
        self.count += 1;
        self.bytes += charged;
        return true;
    }

    fn take(self: *Pump) ?agent.OwnedCoreEvent {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.count == 0) return null;
        const event = self.entries[self.head].?;
        self.entries[self.head] = null;
        self.head = (self.head + 1) % self.entries.len;
        self.count -= 1;
        self.bytes -= event.ownedBytes();
        return event;
    }

    fn pending(self: *Pump) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.count != 0;
    }

    /// How many of the events held here belong to one Session.
    ///
    /// Counted rather than tallied, because the tally would be a second place
    /// for the same number. What this cannot say is the thing its two Product
    /// consumers read it as -- that the stream has ended -- and that
    /// overstatement is older than the link: `unreachability.pending` records
    /// it against this method, and the fix belongs with whoever owns
    /// disconnect.
    fn pendingFor(self: *Pump, session_id: u64) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var total: usize = 0;
        var index: usize = 0;
        while (index < self.count) : (index += 1) {
            const event = self.entries[(self.head + index) % self.entries.len].?;
            if (event.session_id == session_id) total += 1;
        }
        return total;
    }

    pub fn source(self: *Pump) client.EventSource {
        return .{
            .context = self,
            .take_fn = takeEvent,
            .has_pending_fn = hasPendingEvents,
            .pending_count_fn = pendingEventCount,
            .notify_fn = notifyEventConsumer,
        };
    }

    fn takeEvent(context: ?*anyopaque) ?agent.OwnedCoreEvent {
        const self: *Pump = @ptrCast(@alignCast(context.?));
        return self.take();
    }

    fn hasPendingEvents(context: ?*anyopaque) bool {
        const self: *Pump = @ptrCast(@alignCast(context.?));
        return self.pending();
    }

    fn pendingEventCount(context: ?*anyopaque, session_id: u64) usize {
        const self: *Pump = @ptrCast(@alignCast(context.?));
        return self.pendingFor(session_id);
    }

    fn notifyEventConsumer(context: ?*anyopaque) agent.EventReadyNotification {
        const self: *Pump = @ptrCast(@alignCast(context.?));
        return self.wake.notify();
    }
};

const testing = std.testing;

/// An event the way the execution half's pump holds one.
fn heldEvent(session_id: u64, run_id: u64, json: []const u8) !agent.OwnedCoreEvent {
    const copy = try testing.allocator.dupe(u8, json);
    errdefer testing.allocator.free(copy);
    return .{
        .session_id = session_id,
        .run_id = run_id,
        .encoded_bytes = json.len,
        .json = copy,
        .event = try agent.decodeCoreEvent(testing.allocator, copy),
        .allocator = testing.allocator,
    };
}

fn silentWake() agent.EventReadyNotifier {
    return .{ .context = null, .notify_fn = struct {
        fn call(_: ?*anyopaque) agent.EventReadyNotification {
            return .scheduled;
        }
    }.call };
}

test "an event crosses as its bytes and the facts its value cannot carry" {
    var sent = try heldEvent(7, 3, "{\"text_chunk\":\"hello\"}");
    sent.generated_image_path = try testing.allocator.dupe(u8, "C:\\out\\one.png");
    sent.delivered_file = .{
        .id = @splat(9),
        .path_len = 5,
        .size_bytes = 128,
        .sha256 = @splat(4),
    };
    @memcpy(sent.delivered_file.?.path[0..5], "a.txt");
    defer sent.deinit();

    const bytes = try encode(testing.allocator, &sent);
    defer testing.allocator.free(bytes);

    var arrived = try decode(testing.allocator, bytes);
    defer arrived.deinit();

    try testing.expectEqual(@as(u64, 7), arrived.session_id);
    try testing.expectEqual(@as(u64, 3), arrived.run_id);
    try testing.expectEqual(sent.encoded_bytes, arrived.encoded_bytes);
    try testing.expectEqualStrings(sent.json, arrived.json);
    try testing.expectEqualStrings("C:\\out\\one.png", arrived.generated_image_path.?);
    try testing.expect(arrived.generated_video_path == null);
    try testing.expectEqualStrings("a.txt", arrived.delivered_file.?.pathView());
    try testing.expectEqual(@as(u64, 128), arrived.delivered_file.?.size_bytes);

    // The bytes are this side's, not the sender's: the parse owner holds
    // pointers into them, and a value that borrowed the sender's buffer would
    // be a cross-process use-after-free that reads as plausible data.
    try testing.expect(arrived.json.ptr != sent.json.ptr);
    try testing.expect(arrived.generated_image_path.?.ptr != sent.generated_image_path.?.ptr);
}

test "bytes that are not a Core event are refused rather than queued" {
    // The decode is the check that the bytes are what they claim to be. A
    // payload that carries legal framing and illegal JSON means the peer is
    // not this build, and the reader has to be able to say so rather than
    // queue something it cannot read.
    var sent = try heldEvent(1, 1, "{\"text_chunk\":\"x\"}");
    defer sent.deinit();
    const bytes = try encode(testing.allocator, &sent);
    defer testing.allocator.free(bytes);

    // The JSON rides last in the payload, so overwriting its final byte
    // leaves the framing intact and the event unreadable.
    bytes[bytes.len - 1] = '!';
    try testing.expectError(error.MalformedEvent, decode(testing.allocator, bytes));
}

test "the buffer answers in arrival order, per Session, and refuses its bound" {
    var pump: Pump = undefined;
    try pump.init(testing.allocator, testing.io, .{ .count = 2, .bytes = 1 << 20 }, silentWake());
    defer pump.deinit();

    try testing.expect(!pump.pending());
    try testing.expect(pump.push(try heldEvent(1, 1, "{\"text_chunk\":\"one\"}")));
    try testing.expect(pump.push(try heldEvent(2, 1, "{\"text_chunk\":\"other\"}")));
    try testing.expect(pump.pending());
    try testing.expectEqual(@as(usize, 1), pump.pendingFor(1));
    try testing.expectEqual(@as(usize, 1), pump.pendingFor(2));
    try testing.expectEqual(@as(usize, 0), pump.pendingFor(3));

    // At its bound it refuses rather than overwriting. The caller's answer to
    // that is to end the link: an event dropped here shortens a conversation
    // Product commits as complete.
    var refused = try heldEvent(1, 1, "{\"text_chunk\":\"third\"}");
    try testing.expect(!pump.push(refused));
    refused.deinit();

    var first = pump.take().?;
    try testing.expectEqual(@as(u64, 1), first.session_id);
    first.deinit();
    var second = pump.take().?;
    try testing.expectEqual(@as(u64, 2), second.session_id);
    second.deinit();
    try testing.expect(pump.take() == null);
    try testing.expect(!pump.pending());

    // And the budget came back with them, so a full buffer is not a permanent
    // one.
    try testing.expect(pump.push(try heldEvent(5, 1, "{\"text_chunk\":\"after\"}")));
}

test "a byte budget refuses before the slot count does" {
    // Two bounds rather than one, because one large event and five hundred
    // small ones are different failures: the in-process pump has both, and a
    // buffer with only a count would admit 512 images.
    var pump: Pump = undefined;
    try pump.init(testing.allocator, testing.io, .{ .count = 8, .bytes = 24 }, silentWake());
    defer pump.deinit();
    try testing.expect(pump.push(try heldEvent(1, 1, "{\"text_chunk\":\"ab\"}")));
    var refused = try heldEvent(1, 1, "{\"text_chunk\":\"abcdefghij\"}");
    try testing.expect(!pump.push(refused));
    refused.deinit();
}
