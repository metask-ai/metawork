const std = @import("std");
const sdk = @import("metacodes_agentcore");
const event_sink = @import("event_sink");

pub const EventEnvelope = event_sink.EventEnvelope;

pub const EventClass = enum { data, control };

pub const Limits = struct {
    max_event_bytes: usize = 512 * 1024,
    global_count: usize = 512,
    global_bytes: usize = 8 * 1024 * 1024,
    global_control_reserved_count: usize = 64,
    global_control_reserved_bytes: usize = 2 * 1024 * 1024,
    per_session_count: usize = 128,
    per_session_bytes: usize = 2 * 1024 * 1024,
    per_session_control_reserved_count: usize = 16,
    per_session_control_reserved_bytes: usize = 512 * 1024,
    session_slots: usize,
};

pub const Error = error{
    InvalidLimits,
    InvalidIdentity,
    EventTooLarge,
    GlobalCapacity,
    SessionCapacity,
    SessionSlotCapacity,
    SequenceExhausted,
    DeadlineExceeded,
};

pub const Stats = struct {
    count: usize,
    bytes: usize,
    data_count: usize,
    data_bytes: usize,
};

const Entry = struct {
    envelope: EventEnvelope,
    order: u64,
    class: EventClass,
};

const SessionUsage = struct {
    session_id: u64 = 0,
    count: usize = 0,
    bytes: usize = 0,
    data_count: usize = 0,
    data_bytes: usize = 0,
};

/// Concurrent AgentCore callback queue. Enqueue owns an envelope only on
/// success; `takeFair` transfers ownership to the Native loop consumer.
pub const EventPump = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    limits: Limits,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    entries: []?Entry,
    sessions: []SessionUsage,
    count: usize = 0,
    bytes: usize = 0,
    data_count: usize = 0,
    data_bytes: usize = 0,
    next_order: u64 = 0,
    next_session_slot: usize = 0,

    pub fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        limits: Limits,
    ) (error{InvalidLimits} || std.mem.Allocator.Error)!EventPump {
        try validateLimits(limits);
        const entries = try allocator.alloc(?Entry, limits.global_count);
        errdefer allocator.free(entries);
        @memset(entries, null);
        const sessions = try allocator.alloc(SessionUsage, limits.session_slots);
        @memset(sessions, .{});
        return .{
            .io = io,
            .allocator = allocator,
            .limits = limits,
            .entries = entries,
            .sessions = sessions,
        };
    }

    pub fn enqueue(self: *EventPump, envelope: EventEnvelope) Error!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.enqueueLocked(envelope);
    }

    pub fn enqueueWithDeadline(
        self: *EventPump,
        envelope: EventEnvelope,
        timeout: std.Io.Duration,
    ) Error!void {
        if (timeout.nanoseconds <= 0) return error.DeadlineExceeded;
        self.mutex.lockUncancelable(self.io);
        self.enqueueLocked(envelope) catch |initial_error| {
            if (!isCapacityError(initial_error)) {
                self.mutex.unlock(self.io);
                return initial_error;
            }
            self.mutex.unlock(self.io);

            var expired = false;
            var timer = self.io.async(expireEnqueue, .{ self, &expired, timeout });
            self.mutex.lockUncancelable(self.io);
            while (true) {
                self.enqueueLocked(envelope) catch |err| {
                    if (!isCapacityError(err)) {
                        self.mutex.unlock(self.io);
                        cancelTimer(self.io, &timer);
                        return err;
                    }
                    if (expired) {
                        self.mutex.unlock(self.io);
                        cancelTimer(self.io, &timer);
                        return error.DeadlineExceeded;
                    }
                    self.condition.waitUncancelable(self.io, &self.mutex);
                    continue;
                };
                self.mutex.unlock(self.io);
                cancelTimer(self.io, &timer);
                return;
            }
        };
        self.mutex.unlock(self.io);
    }

    pub fn takeFair(self: *EventPump) ?EventEnvelope {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.count == 0) return null;
        const usage_index = self.nextNonEmptySession() orelse unreachable;
        const session_id = self.sessions[usage_index].session_id;
        const entry_index = oldestEntryForSession(self.entries, session_id) orelse unreachable;
        const entry = self.entries[entry_index].?;
        self.entries[entry_index] = null;
        self.removeUsage(&self.sessions[usage_index], entry);
        self.next_session_slot = (usage_index + 1) % self.sessions.len;
        self.condition.broadcast(self.io);
        return entry.envelope;
    }

    pub fn stats(self: *EventPump) Stats {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return .{
            .count = self.count,
            .bytes = self.bytes,
            .data_count = self.data_count,
            .data_bytes = self.data_bytes,
        };
    }

    pub fn deinit(self: *EventPump) void {
        std.debug.assert(self.count <= self.entries.len);
        for (self.entries) |*entry| if (entry.*) |*value| value.envelope.deinit();
        self.allocator.free(self.sessions);
        self.allocator.free(self.entries);
        self.* = undefined;
    }

    fn enqueueLocked(self: *EventPump, envelope: EventEnvelope) Error!void {
        if (envelope.session_id == 0 or envelope.run_id == 0) return error.InvalidIdentity;
        if (envelope.encoded_bytes != envelope.json.len or
            envelope.encoded_bytes > self.limits.max_event_bytes)
            return error.EventTooLarge;
        const class = classify(envelope.event.value);
        const usage = self.findOrReserveSession(envelope.session_id) orelse
            return error.SessionSlotCapacity;
        errdefer {
            if (usage.count == 0) usage.* = .{};
        }
        if (!fits(self.count, envelope.encoded_bytes, self.limits.global_count, self.limits.global_bytes, self.bytes))
            return error.GlobalCapacity;
        if (!fits(usage.count, envelope.encoded_bytes, self.limits.per_session_count, self.limits.per_session_bytes, usage.bytes))
            return error.SessionCapacity;
        if (class == .data) {
            const global_count = self.limits.global_count - self.limits.global_control_reserved_count;
            const global_bytes = self.limits.global_bytes - self.limits.global_control_reserved_bytes;
            if (!fits(self.data_count, envelope.encoded_bytes, global_count, global_bytes, self.data_bytes))
                return error.GlobalCapacity;
            const session_count = self.limits.per_session_count - self.limits.per_session_control_reserved_count;
            const session_bytes = self.limits.per_session_bytes - self.limits.per_session_control_reserved_bytes;
            if (!fits(usage.data_count, envelope.encoded_bytes, session_count, session_bytes, usage.data_bytes))
                return error.SessionCapacity;
        }
        if (self.next_order == std.math.maxInt(u64)) return error.SequenceExhausted;
        const slot = findEmpty(self.entries) orelse return error.GlobalCapacity;
        self.next_order += 1;
        self.entries[slot] = .{ .envelope = envelope, .order = self.next_order, .class = class };
        self.count += 1;
        self.bytes += envelope.encoded_bytes;
        usage.count += 1;
        usage.bytes += envelope.encoded_bytes;
        if (class == .data) {
            self.data_count += 1;
            self.data_bytes += envelope.encoded_bytes;
            usage.data_count += 1;
            usage.data_bytes += envelope.encoded_bytes;
        }
    }

    fn expireEnqueue(self: *EventPump, expired: *bool, timeout: std.Io.Duration) std.Io.Cancelable!void {
        try self.io.sleep(timeout, .awake);
        self.mutex.lockUncancelable(self.io);
        expired.* = true;
        self.condition.broadcast(self.io);
        self.mutex.unlock(self.io);
    }

    fn findOrReserveSession(self: *EventPump, session_id: u64) ?*SessionUsage {
        std.debug.assert(session_id != 0);
        var empty: ?*SessionUsage = null;
        for (self.sessions) |*usage| {
            if (usage.session_id == session_id) return usage;
            if (usage.session_id == 0 and empty == null) empty = usage;
        }
        const usage = empty orelse return null;
        usage.session_id = session_id;
        return usage;
    }

    fn nextNonEmptySession(self: *EventPump) ?usize {
        for (0..self.sessions.len) |offset| {
            const index = (self.next_session_slot + offset) % self.sessions.len;
            if (self.sessions[index].count != 0) return index;
        }
        return null;
    }

    fn removeUsage(self: *EventPump, usage: *SessionUsage, entry: Entry) void {
        self.count -= 1;
        self.bytes -= entry.envelope.encoded_bytes;
        usage.count -= 1;
        usage.bytes -= entry.envelope.encoded_bytes;
        if (entry.class == .data) {
            self.data_count -= 1;
            self.data_bytes -= entry.envelope.encoded_bytes;
            usage.data_count -= 1;
            usage.data_bytes -= entry.envelope.encoded_bytes;
        }
        if (usage.count == 0) usage.* = .{};
    }
};

pub fn classify(event: sdk.DecodedCoreEvent) EventClass {
    return switch (event) {
        .unknown => .data,
        .known => |known| switch (known) {
            .text_chunk,
            .tool_progress,
            .usage,
            => .data,
            .tool_start,
            .progress,
            .tool_result,
            .context_warning,
            .auto_compact,
            .retry_notice,
            .stream_done,
            => .control,
        },
    };
}

fn validateLimits(limits: Limits) error{InvalidLimits}!void {
    if (limits.max_event_bytes == 0 or limits.global_count == 0 or limits.global_bytes == 0 or
        limits.per_session_count == 0 or limits.per_session_bytes == 0 or limits.session_slots == 0 or
        limits.global_control_reserved_count >= limits.global_count or
        limits.global_control_reserved_bytes >= limits.global_bytes or
        limits.per_session_control_reserved_count >= limits.per_session_count or
        limits.per_session_control_reserved_bytes >= limits.per_session_bytes or
        limits.per_session_count > limits.global_count or limits.per_session_bytes > limits.global_bytes)
        return error.InvalidLimits;
}

fn fits(count: usize, added: usize, max_count: usize, max_bytes: usize, current: usize) bool {
    if (count >= max_count or added > max_bytes) return false;
    return current <= max_bytes - added;
}

fn isCapacityError(err: Error) bool {
    return switch (err) {
        error.GlobalCapacity, error.SessionCapacity, error.SessionSlotCapacity => true,
        error.InvalidLimits,
        error.InvalidIdentity,
        error.EventTooLarge,
        error.SequenceExhausted,
        error.DeadlineExceeded,
        => false,
    };
}

fn cancelTimer(io: std.Io, timer: anytype) void {
    timer.cancel(io) catch |err| switch (err) {
        error.Canceled => {},
    };
}

fn findEmpty(entries: []?Entry) ?usize {
    for (entries, 0..) |entry, index| if (entry == null) return index;
    return null;
}

fn oldestEntryForSession(entries: []?Entry, session_id: u64) ?usize {
    var found: ?usize = null;
    var order: u64 = std.math.maxInt(u64);
    for (entries, 0..) |entry, index| {
        const value = entry orelse continue;
        if (value.envelope.session_id == session_id and value.order < order) {
            found = index;
            order = value.order;
        }
    }
    return found;
}
