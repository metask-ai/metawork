const std = @import("std");
const sdk = @import("metacodes_agentcore");

pub const Error = error{
    EventTooLarge,
    SinkFull,
};

pub const EventEnvelope = struct {
    session_id: u64,
    run_id: u64,
    encoded_bytes: usize,
    event: sdk.ParsedCoreEvent,

    /// Ownership transfers from the sink to the caller. Do not copy this
    /// value; call `deinit` exactly once after consuming the SDK parse owner.
    pub fn deinit(self: *EventEnvelope) void {
        self.event.deinit();
        self.* = undefined;
    }
};

pub const BoundedEventSink = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    entries: []?EventEnvelope,
    max_event_bytes: usize,
    count: usize = 0,
    bytes: usize = 0,
    head: usize = 0,
    tail: usize = 0,

    pub fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        capacity: usize,
        max_event_bytes: usize,
    ) std.mem.Allocator.Error!BoundedEventSink {
        const entries = try allocator.alloc(?EventEnvelope, capacity);
        @memset(entries, null);
        return .{
            .io = io,
            .allocator = allocator,
            .entries = entries,
            .max_event_bytes = max_event_bytes,
        };
    }

    pub fn push(self: *BoundedEventSink, envelope: EventEnvelope) Error!void {
        if (envelope.encoded_bytes > self.max_event_bytes) return error.EventTooLarge;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.count == self.entries.len) return error.SinkFull;
        std.debug.assert(self.entries[self.tail] == null);
        self.entries[self.tail] = envelope;
        self.tail = (self.tail + 1) % self.entries.len;
        self.count += 1;
        self.bytes += envelope.encoded_bytes;
    }

    pub fn take(self: *BoundedEventSink) ?EventEnvelope {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.count == 0) return null;
        const envelope = self.entries[self.head].?;
        self.entries[self.head] = null;
        self.head = (self.head + 1) % self.entries.len;
        self.count -= 1;
        self.bytes -= envelope.encoded_bytes;
        return envelope;
    }

    pub fn deinit(self: *BoundedEventSink) void {
        std.debug.assert(self.count <= self.entries.len);
        for (self.entries) |*entry| {
            if (entry.*) |*envelope| envelope.deinit();
        }
        self.allocator.free(self.entries);
        self.* = undefined;
    }
};
