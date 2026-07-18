const std = @import("std");

pub const Limits = struct {
    inline_event_bytes: usize = 6 * 1024,
    batch_count: usize = 16,
    batch_bytes: usize = 7 * 1024,
    batch_sessions: usize = 4,
    batch_per_session: usize = 4,
    retention_count: usize = 256,
    retention_bytes: usize = 4 * 1024 * 1024,
    retention_ns: u64 = 30 * std.time.ns_per_s,
    object_count: usize = 64,
    object_bytes: usize = 4 * 1024 * 1024,
    per_session_object_count: usize = 16,
    per_session_object_bytes: usize = 1024 * 1024,
    max_object_bytes: usize = 512 * 1024,
    route_slots: usize,
};

pub const Error = error{
    InvalidLimits,
    InvalidIdentity,
    ConnectionExhausted,
    NoConnection,
    StaleConnection,
    RetentionCapacity,
    ObjectCapacity,
    ObjectTooLarge,
    RouteCapacity,
    RouteSequenceExhausted,
    OutOfOrderAcknowledgement,
    UnknownObject,
    ResponseTooLarge,
    ForeignBatch,
    StaleBatch,
};

pub const InputEvent = struct {
    session_id: u64,
    run_id: u64,
    json: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *InputEvent) void {
        self.allocator.free(self.json);
        self.* = undefined;
    }
};

pub const OwnedBatch = struct {
    owner: *Delivery,
    allocator: std.mem.Allocator,
    storage: []u8,
    selected_storage: []usize,
    json: []const u8,
    generation: u64,
    item_count: usize,

    pub fn deinit(self: *OwnedBatch) void {
        self.allocator.free(self.selected_storage);
        self.allocator.free(self.storage);
        self.* = undefined;
    }
};

pub const ExpiredRoute = struct { session_id: u64, run_id: u64 };
pub const RouteIdentity = struct { session_id: u64, run_id: u64 };

pub const Stats = struct {
    retained_count: usize,
    retained_bytes: usize,
    object_count: usize,
    object_bytes: usize,
};

const RetainedEvent = struct {
    session_id: u64,
    run_id: u64,
    sequence: u64,
    object_id: u64,
    json: []u8,
    allocator: std.mem.Allocator,
    last_sent_generation: u64 = 0,
};

const Route = struct {
    session_id: u64 = 0,
    run_id: u64 = 0,
    next_sequence: u64 = 0,
    last_acked_sequence: u64 = 0,
};

const ObjectUsage = struct { count: usize = 0, bytes: usize = 0 };

/// Transport-only state. All methods are called on the Native SDK loop thread;
/// AgentCore types and credentials are deliberately absent from this module.
pub const Delivery = struct {
    allocator: std.mem.Allocator,
    limits: Limits,
    retained: []?RetainedEvent,
    routes: []Route,
    retained_count: usize = 0,
    retained_bytes: usize = 0,
    object_count: usize = 0,
    object_bytes: usize = 0,
    generation: u64 = 0,
    attached: bool = false,
    detached_ns: ?u64 = null,
    next_object_id: u64 = 0,
    next_route_slot: usize = 0,

    pub fn init(allocator: std.mem.Allocator, limits: Limits) (Error || std.mem.Allocator.Error)!Delivery {
        try validateLimits(limits);
        const retained = try allocator.alloc(?RetainedEvent, limits.retention_count);
        errdefer allocator.free(retained);
        @memset(retained, null);
        const routes = try allocator.alloc(Route, limits.route_slots);
        @memset(routes, .{});
        return .{ .allocator = allocator, .limits = limits, .retained = retained, .routes = routes };
    }

    pub fn connect(self: *Delivery) Error!u64 {
        if (self.generation == std.math.maxInt(u64)) return error.ConnectionExhausted;
        self.generation += 1;
        self.attached = true;
        self.detached_ns = null;
        return self.generation;
    }

    pub fn connectedGeneration(self: *const Delivery) ?u64 {
        return if (self.attached) self.generation else null;
    }

    pub fn retentionNanoseconds(self: *const Delivery) u64 {
        return self.limits.retention_ns;
    }

    pub fn detach(self: *Delivery, generation: u64, now_ns: u64) Error!void {
        try self.validateGeneration(generation);
        self.attached = false;
        self.detached_ns = now_ns;
    }

    /// Ownership transfers only on success. The caller must deinit `event`
    /// after an error.
    pub fn ingest(self: *Delivery, event: InputEvent) Error!void {
        if (event.session_id == 0 or event.run_id == 0) return error.InvalidIdentity;
        if (self.retained_count >= self.limits.retention_count or
            event.json.len > self.limits.retention_bytes - self.retained_bytes)
            return error.RetentionCapacity;
        const route = self.findOrReserveRoute(event.session_id, event.run_id) orelse
            return error.RouteCapacity;
        errdefer {
            if (route.next_sequence == 0) route.* = .{};
        }
        if (route.next_sequence == std.math.maxInt(u64)) return error.RouteSequenceExhausted;
        var object_id: u64 = 0;
        if (event.json.len > self.limits.inline_event_bytes) {
            if (event.json.len > self.limits.max_object_bytes) return error.ObjectTooLarge;
            const usage = self.objectUsage(event.session_id);
            if (self.object_count >= self.limits.object_count or
                event.json.len > self.limits.object_bytes - self.object_bytes or
                usage.count >= self.limits.per_session_object_count or
                event.json.len > self.limits.per_session_object_bytes - usage.bytes)
                return error.ObjectCapacity;
            if (self.next_object_id == std.math.maxInt(u64)) return error.ObjectCapacity;
            self.next_object_id += 1;
            object_id = self.next_object_id;
        }
        const slot = findEmpty(self.retained) orelse return error.RetentionCapacity;
        route.next_sequence += 1;
        self.retained[slot] = .{
            .session_id = event.session_id,
            .run_id = event.run_id,
            .sequence = route.next_sequence,
            .object_id = object_id,
            .json = event.json,
            .allocator = event.allocator,
        };
        self.retained_count += 1;
        self.retained_bytes += event.json.len;
        if (object_id != 0) {
            self.object_count += 1;
            self.object_bytes += event.json.len;
        }
    }

    pub fn buildBatch(self: *Delivery, generation: u64) (Error || std.mem.Allocator.Error || std.Io.Writer.Error)!?OwnedBatch {
        try self.validateGeneration(generation);
        const buffer = try self.allocator.alloc(u8, self.limits.batch_bytes);
        errdefer self.allocator.free(buffer);
        var writer = std.Io.Writer.fixed(buffer);
        try writer.print("{{\"generation\":\"{d}\",\"items\":[", .{generation});
        const item_buffer = try self.allocator.alloc(u8, self.limits.batch_bytes);
        defer self.allocator.free(item_buffer);
        const sessions = try self.allocator.alloc(u64, self.limits.batch_sessions);
        defer self.allocator.free(sessions);
        @memset(sessions, 0);
        const counts = try self.allocator.alloc(usize, self.limits.batch_sessions);
        defer self.allocator.free(counts);
        @memset(counts, 0);
        const selected = try self.allocator.alloc(usize, self.limits.batch_count);
        errdefer self.allocator.free(selected);
        var next_route_slot = self.next_route_slot;
        var item_count: usize = 0;
        while (item_count < self.limits.batch_count) {
            const index = self.nextUnsent(
                generation,
                sessions,
                counts,
                selected[0..item_count],
                &next_route_slot,
            ) orelse break;
            const retained = &self.retained[index].?;
            var item_writer = std.Io.Writer.fixed(item_buffer);
            try writeItem(&item_writer, retained.*);
            const item = item_writer.buffered();
            const separator: usize = if (item_count == 0) 0 else 1;
            if (writer.buffered().len + separator + item.len + 2 > self.limits.batch_bytes) break;
            if (item_count != 0) try writer.writeByte(',');
            try writer.writeAll(item);
            selected[item_count] = index;
            recordSession(retained.session_id, sessions, counts);
            item_count += 1;
        }
        if (item_count == 0) {
            self.allocator.free(selected);
            self.allocator.free(buffer);
            return null;
        }
        try writer.writeAll("]}");
        const json_len = writer.buffered().len;
        self.next_route_slot = next_route_slot;
        return .{
            .owner = self,
            .allocator = self.allocator,
            .storage = buffer,
            .selected_storage = selected,
            .json = buffer[0..json_len],
            .generation = generation,
            .item_count = item_count,
        };
    }

    /// Commit only after the transport accepted the complete batch. Until
    /// then every selected event remains eligible for the same generation.
    pub fn commitBatch(self: *Delivery, batch: *const OwnedBatch) Error!void {
        if (batch.owner != self) return error.ForeignBatch;
        try self.validateGeneration(batch.generation);
        for (batch.selected_storage[0..batch.item_count]) |index| {
            if (index >= self.retained.len) return error.StaleBatch;
            _ = self.retained[index] orelse return error.StaleBatch;
        }
        for (batch.selected_storage[0..batch.item_count]) |index| {
            const item = &self.retained[index].?;
            item.last_sent_generation = batch.generation;
        }
    }

    pub fn batchRoute(self: *Delivery, batch: *const OwnedBatch, item_index: usize) Error!RouteIdentity {
        if (batch.owner != self) return error.ForeignBatch;
        if (item_index >= batch.item_count) return error.StaleBatch;
        const retained_index = batch.selected_storage[item_index];
        if (retained_index >= self.retained.len) return error.StaleBatch;
        const item = self.retained[retained_index] orelse return error.StaleBatch;
        return .{ .session_id = item.session_id, .run_id = item.run_id };
    }

    pub fn acknowledge(self: *Delivery, generation: u64, session_id: u64, run_id: u64, sequence: u64) Error!void {
        try self.validateGeneration(generation);
        const route = self.findRoute(session_id, run_id) orelse return error.StaleConnection;
        if (sequence <= route.last_acked_sequence) return;
        if (route.last_acked_sequence == std.math.maxInt(u64) or
            sequence != route.last_acked_sequence + 1)
            return error.OutOfOrderAcknowledgement;
        for (self.retained) |*entry| {
            const item = entry.* orelse continue;
            if (item.session_id == session_id and item.run_id == run_id and
                item.sequence == sequence and item.last_sent_generation == generation)
            {
                self.remove(item);
                item.allocator.free(item.json);
                entry.* = null;
                route.last_acked_sequence = sequence;
                return;
            }
        }
        return error.StaleConnection;
    }

    pub fn fetchObject(self: *Delivery, generation: u64, session_id: u64, run_id: u64, object_id: u64, output: []u8) Error![]const u8 {
        try self.validateGeneration(generation);
        for (self.retained) |entry| {
            const item = entry orelse continue;
            if (item.object_id == object_id and item.session_id == session_id and
                item.run_id == run_id and item.last_sent_generation == generation)
            {
                var writer = std.Io.Writer.fixed(output);
                writer.print(
                    "{{\"generation\":\"{d}\",\"sessionId\":\"{d}\",\"runId\":\"{d}\",\"sequence\":\"{d}\",\"event\":",
                    .{ generation, session_id, run_id, item.sequence },
                ) catch return error.ResponseTooLarge;
                writer.writeAll(item.json) catch return error.ResponseTooLarge;
                writer.writeByte('}') catch return error.ResponseTooLarge;
                return writer.buffered();
            }
        }
        return error.UnknownObject;
    }

    pub fn firstExpired(self: *Delivery, now_ns: u64) ?ExpiredRoute {
        const detached = self.detached_ns orelse return null;
        if (now_ns < detached or now_ns - detached < self.limits.retention_ns) return null;
        for (self.retained) |entry| {
            const item = entry orelse continue;
            return .{ .session_id = item.session_id, .run_id = item.run_id };
        }
        return null;
    }

    pub fn stats(self: *const Delivery) Stats {
        return .{
            .retained_count = self.retained_count,
            .retained_bytes = self.retained_bytes,
            .object_count = self.object_count,
            .object_bytes = self.object_bytes,
        };
    }

    pub fn cleanupRun(self: *Delivery, session_id: u64, run_id: u64) void {
        for (self.retained) |*entry| {
            const item = entry.* orelse continue;
            if (item.session_id != session_id or item.run_id != run_id) continue;
            self.remove(item);
            item.allocator.free(item.json);
            entry.* = null;
        }
        for (self.routes) |*route| if (route.session_id == session_id and route.run_id == run_id) {
            route.* = .{};
            break;
        };
    }

    pub fn deinit(self: *Delivery) void {
        self.deinitOwnedBuffers();
    }

    pub fn deinitOwnedBuffers(self: *Delivery) void {
        for (self.retained) |entry| {
            const item = entry orelse continue;
            item.allocator.free(item.json);
        }
        self.allocator.free(self.routes);
        self.allocator.free(self.retained);
        self.* = undefined;
    }

    fn validateGeneration(self: *Delivery, generation: u64) Error!void {
        if (!self.attached) return error.NoConnection;
        if (generation == 0 or generation != self.generation) return error.StaleConnection;
    }

    fn findOrReserveRoute(self: *Delivery, session_id: u64, run_id: u64) ?*Route {
        var empty: ?*Route = null;
        for (self.routes) |*route| {
            if (route.session_id == session_id and route.run_id == run_id) return route;
            if (route.session_id == 0 and empty == null) empty = route;
        }
        const route = empty orelse return null;
        route.session_id = session_id;
        route.run_id = run_id;
        return route;
    }

    fn findRoute(self: *Delivery, session_id: u64, run_id: u64) ?*Route {
        for (self.routes) |*route|
            if (route.session_id == session_id and route.run_id == run_id) return route;
        return null;
    }

    fn nextUnsent(
        self: *Delivery,
        generation: u64,
        sessions: []u64,
        counts: []usize,
        selected: []const usize,
        next_route_slot: *usize,
    ) ?usize {
        for (0..self.routes.len) |offset| {
            const route_index = (next_route_slot.* + offset) % self.routes.len;
            const route = self.routes[route_index];
            if (route.session_id == 0) continue;
            const selected_session = sessionIndex(route.session_id, sessions);
            if (selected_session == null and sessionCount(sessions) >= self.limits.batch_sessions) continue;
            if (selected_session) |index| if (counts[index] >= self.limits.batch_per_session) continue;
            const event_index = oldestUnsent(
                self.retained,
                route.session_id,
                route.run_id,
                generation,
                selected,
            ) orelse continue;
            next_route_slot.* = (route_index + 1) % self.routes.len;
            return event_index;
        }
        return null;
    }

    fn objectUsage(self: *Delivery, session_id: u64) ObjectUsage {
        var result = ObjectUsage{};
        for (self.retained) |entry| {
            const item = entry orelse continue;
            if (item.session_id == session_id and item.object_id != 0) {
                result.count += 1;
                result.bytes += item.json.len;
            }
        }
        return result;
    }

    fn remove(self: *Delivery, item: RetainedEvent) void {
        self.retained_count -= 1;
        self.retained_bytes -= item.json.len;
        if (item.object_id != 0) {
            self.object_count -= 1;
            self.object_bytes -= item.json.len;
        }
    }
};

fn validateLimits(limits: Limits) error{InvalidLimits}!void {
    const max_inline_envelope_overhead = 160;
    if (limits.inline_event_bytes == 0 or limits.batch_count == 0 or limits.batch_bytes == 0 or
        limits.batch_bytes >= 8 * 1024 or limits.batch_bytes <= max_inline_envelope_overhead or
        limits.inline_event_bytes > limits.batch_bytes - max_inline_envelope_overhead or
        limits.batch_sessions == 0 or limits.batch_per_session == 0 or limits.retention_count == 0 or
        limits.retention_bytes == 0 or limits.retention_ns == 0 or limits.object_count == 0 or
        limits.object_bytes == 0 or limits.per_session_object_count == 0 or
        limits.per_session_object_bytes == 0 or limits.max_object_bytes == 0 or
        limits.batch_count > limits.retention_count or limits.batch_sessions > limits.batch_count or
        limits.batch_sessions > limits.route_slots or limits.batch_per_session > limits.batch_count or
        limits.object_count > limits.retention_count or
        limits.per_session_object_count > limits.object_count or
        limits.per_session_object_bytes > limits.object_bytes or
        limits.max_object_bytes > limits.retention_bytes or
        limits.max_object_bytes > limits.object_bytes or
        limits.max_object_bytes > limits.per_session_object_bytes or limits.route_slots == 0)
        return error.InvalidLimits;
}

fn findEmpty(entries: []?RetainedEvent) ?usize {
    for (entries, 0..) |entry, index| if (entry == null) return index;
    return null;
}

fn oldestUnsent(
    entries: []?RetainedEvent,
    session_id: u64,
    run_id: u64,
    generation: u64,
    selected: []const usize,
) ?usize {
    var found: ?usize = null;
    var sequence: u64 = std.math.maxInt(u64);
    for (entries, 0..) |entry, index| {
        if (std.mem.indexOfScalar(usize, selected, index) != null) continue;
        const item = entry orelse continue;
        if (item.session_id == session_id and item.run_id == run_id and
            item.last_sent_generation != generation and item.sequence < sequence)
        {
            found = index;
            sequence = item.sequence;
        }
    }
    return found;
}

fn writeItem(writer: *std.Io.Writer, item: RetainedEvent) !void {
    try writer.print("{{\"sessionId\":\"{d}\",\"runId\":\"{d}\",\"sequence\":\"{d}\",", .{ item.session_id, item.run_id, item.sequence });
    if (item.object_id == 0) {
        try writer.writeAll("\"event\":");
        try writer.writeAll(item.json);
    } else try writer.print("\"object\":{{\"id\":\"{d}\",\"bytes\":{d}}}", .{ item.object_id, item.json.len });
    try writer.writeByte('}');
}

fn sessionIndex(session_id: u64, sessions: []const u64) ?usize {
    for (sessions, 0..) |value, index| if (value == session_id) return index;
    return null;
}

fn sessionCount(sessions: []const u64) usize {
    var count: usize = 0;
    for (sessions) |value| if (value != 0) {
        count += 1;
    };
    return count;
}

fn recordSession(session_id: u64, sessions: []u64, counts: []usize) void {
    if (sessionIndex(session_id, sessions)) |index| {
        counts[index] += 1;
        return;
    }
    for (sessions, 0..) |*value, index| if (value.* == 0) {
        value.* = session_id;
        counts[index] = 1;
        return;
    };
    unreachable;
}

test "batch routes remain exact and detached retention expires by run" {
    var delivery = try Delivery.init(std.testing.allocator, .{
        .route_slots = 4,
        .retention_ns = 10,
    });
    defer delivery.deinit();
    const generation = try delivery.connect();
    for ([_]RouteIdentity{
        .{ .session_id = 1, .run_id = 11 },
        .{ .session_id = 2, .run_id = 22 },
    }) |route| {
        const json = try std.testing.allocator.dupe(u8, "{\"stream_done\":{}}");
        try delivery.ingest(.{
            .session_id = route.session_id,
            .run_id = route.run_id,
            .json = json,
            .allocator = std.testing.allocator,
        });
    }
    var batch = (try delivery.buildBatch(generation)).?;
    defer batch.deinit();
    try std.testing.expectEqual(@as(usize, 2), batch.item_count);
    const first = try delivery.batchRoute(&batch, 0);
    const second = try delivery.batchRoute(&batch, 1);
    try std.testing.expect(first.session_id != second.session_id);
    try std.testing.expectError(error.StaleBatch, delivery.batchRoute(&batch, 2));
    try delivery.commitBatch(&batch);
    try delivery.detach(generation, 100);
    try std.testing.expectEqual(@as(?ExpiredRoute, null), delivery.firstExpired(109));
    const expired = delivery.firstExpired(110).?;
    delivery.cleanupRun(expired.session_id, expired.run_id);
    try std.testing.expect(delivery.firstExpired(110) != null);
    const remaining = delivery.firstExpired(110).?;
    delivery.cleanupRun(remaining.session_id, remaining.run_id);
    try std.testing.expectEqual(@as(usize, 0), delivery.stats().retained_count);
}

test "a new generation resends committed but unacknowledged events" {
    var delivery = try Delivery.init(std.testing.allocator, .{ .route_slots = 4 });
    defer delivery.deinit();
    const first_generation = try delivery.connect();
    for ([_][]const u8{ "{\"text_chunk\":\"one\"}", "{\"text_chunk\":\"two\"}" }) |encoded| {
        try delivery.ingest(.{
            .session_id = 1,
            .run_id = 2,
            .json = try std.testing.allocator.dupe(u8, encoded),
            .allocator = std.testing.allocator,
        });
    }
    var first_batch = (try delivery.buildBatch(first_generation)).?;
    try delivery.commitBatch(&first_batch);
    first_batch.deinit();
    try delivery.acknowledge(first_generation, 1, 2, 1);

    try delivery.detach(first_generation, 100);
    const second_generation = try delivery.connect();
    var resent = (try delivery.buildBatch(second_generation)).?;
    defer resent.deinit();
    try std.testing.expectEqual(@as(usize, 1), resent.item_count);
    try std.testing.expect(std.mem.indexOf(u8, resent.json, "\"sequence\":\"2\"") != null);
    try delivery.commitBatch(&resent);
    try delivery.acknowledge(second_generation, 1, 2, 2);
    try std.testing.expectEqual(@as(usize, 0), delivery.stats().retained_count);
}
