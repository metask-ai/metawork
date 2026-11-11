const std = @import("std");
const sdk = @import("metask_agentcore");
const file_delivery = @import("agent_file_delivery");

pub const Error = error{
    EventTooLarge,
    SinkFull,
};

pub const OwnedCoreEvent = struct {
    generated_image_path: ?[]u8 = null,
    generated_video_path: ?[]u8 = null,
    /// Agent-verified receipt, never decoded from Core JSON or tool text.
    delivered_file: ?file_delivery.Receipt = null,
    session_id: u64,
    run_id: u64,
    encoded_bytes: usize,
    json: []u8,
    event: sdk.ParsedCoreEvent,
    allocator: std.mem.Allocator,

    pub fn ownedBytes(self: *const OwnedCoreEvent) usize {
        return self.encoded_bytes +|
            (if (self.generated_image_path) |path| path.len else @as(usize, 0)) +|
            (if (self.generated_video_path) |path| path.len else @as(usize, 0)) +|
            (if (self.delivered_file != null) @as(usize, @sizeOf(file_delivery.Receipt)) else 0);
    }

    /// Ownership transfers from the sink to the caller. Do not copy this
    /// value; call `deinit` exactly once after consuming the SDK parse owner.
    pub fn deinit(self: *OwnedCoreEvent) void {
        if (self.generated_image_path) |path| self.allocator.free(path);
        if (self.generated_video_path) |path| self.allocator.free(path);
        self.allocator.free(self.json);
        self.event.deinit();
        self.* = undefined;
    }

    /// Drops the SDK parse owner and transfers the raw, already-validated
    /// event bytes to the transport layer without copying them again.
    pub fn takeJson(self: *OwnedCoreEvent) OwnedEventJson {
        if (self.generated_image_path) |path| self.allocator.free(path);
        if (self.generated_video_path) |path| self.allocator.free(path);
        self.event.deinit();
        const result = OwnedEventJson{
            .session_id = self.session_id,
            .run_id = self.run_id,
            .json = self.json,
            .allocator = self.allocator,
        };
        self.* = undefined;
        return result;
    }
};

pub const OwnedEventJson = struct {
    session_id: u64,
    run_id: u64,
    json: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *OwnedEventJson) void {
        self.allocator.free(self.json);
        self.* = undefined;
    }
};

pub const BoundedEventSink = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    entries: []?OwnedCoreEvent,
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
        const entries = try allocator.alloc(?OwnedCoreEvent, capacity);
        @memset(entries, null);
        return .{
            .io = io,
            .allocator = allocator,
            .entries = entries,
            .max_event_bytes = max_event_bytes,
        };
    }

    pub fn push(self: *BoundedEventSink, envelope: OwnedCoreEvent) Error!void {
        if (envelope.ownedBytes() > self.max_event_bytes) return error.EventTooLarge;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.count == self.entries.len) return error.SinkFull;
        std.debug.assert(self.entries[self.tail] == null);
        self.entries[self.tail] = envelope;
        self.tail = (self.tail + 1) % self.entries.len;
        self.count += 1;
        self.bytes += envelope.ownedBytes();
    }

    pub fn take(self: *BoundedEventSink) ?OwnedCoreEvent {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.count == 0) return null;
        const envelope = self.entries[self.head].?;
        self.entries[self.head] = null;
        self.head = (self.head + 1) % self.entries.len;
        self.count -= 1;
        self.bytes -= envelope.ownedBytes();
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
